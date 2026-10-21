import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/power.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart'
    show endsInPause;
import 'package:university_notes/features/notes/recorder/live_transcript.dart';
import 'package:university_notes/features/notes/recorder/overlay_logic.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/recording_save.dart';
import 'package:university_notes/features/notes/recorder/recording_session.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/features/notes/transcript_search_screen.dart';
import 'package:university_notes/repositories/settings_repository.dart';

Duration ms(int v) => Duration(milliseconds: v);
Duration sec(num v) => Duration(milliseconds: (v * 1000).round());

TranscriptSegment seg(num a, num b, String t) =>
    TranscriptSegment(sec(a), sec(b), t);

/// Tono a 16 kHz mono (ampiezza [amp]) per [seconds].
Uint8List tone(double seconds, {int amp = 8000}) {
  final n = (seconds * 16000).round();
  final s = Int16List(n);
  for (var i = 0; i < n; i++) {
    s[i] = (amp * math.sin(2 * math.pi * 440 * i / 16000)).round();
  }
  return s.buffer.asUint8List();
}

/// Registratore di sistema finto: il flusso PCM lo fornisce il test.
class _FakeRecorder implements AudioRecorder {
  final pcm = StreamController<Uint8List>.broadcast();
  bool paused = false;
  bool stopped = false;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> setOnConfigChanged(void Function(RecordConfig c)? cb) async {}
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      pcm.stream;
  @override
  Stream<RecordState> onStateChanged() => const Stream.empty();
  @override
  Future<void> pause() async => paused = true;
  @override
  Future<void> resume() async => paused = false;
  @override
  Future<String?> stop() async {
    stopped = true;
    return null;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('un_rec_');
  });
  tearDown(() async {
    // su Linux un lavoro in background appena chiuso (download del modello,
    // file di sessione) può scrivere ancora per un attimo: si riprova
    for (var i = 0; i < 10 && await tmp.exists(); i++) {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  group('WAV', () {
    test('intestazione: scrittura e lettura', () {
      final h = wavHeader(sampleRate: 16000, channels: 1, dataLength: 3200);
      expect(h.length, 44);
      final info = parseWavHeader(h)!;
      expect(info.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.dataOffset, 44);
      expect(info.dataLength, 3200);
      expect(info.duration, ms(100));
      expect(
        parseWavHeader(Uint8List.fromList('RIFFxxxxNOPE'.codeUnits)),
        isNull,
      );
    });

    test('dimensioni mancanti: ricavate dalla lunghezza del file', () {
      final h = wavHeader(sampleRate: 16000, channels: 1, dataLength: 0);
      final info = parseWavHeader(h, fileLength: 44 + 1001)!;
      // mezzo campione finale scartato
      expect(info.dataLength, 1000);
      final big = wavHeader(sampleRate: 16000, channels: 2, dataLength: 999999);
      expect(parseWavHeader(big, fileLength: 44 + 64)!.dataLength, 64);
    });

    test('riparazione di un WAV rimasto a metà (app chiusa)', () async {
      final f = File(p.join(tmp.path, 'lavoro.wav'));
      await f.writeAsBytes([
        ...wavHeader(sampleRate: 16000, channels: 1, dataLength: 0),
        ...List.filled(32001, 7),
      ]);
      final info = (await repairWav(f))!;
      expect(info.dataLength, 32000);
      expect(info.duration, sec(1));
      expect(await f.length(), 44 + 32000);
      final again = parseWavHeader(await f.readAsBytes())!;
      expect(again.dataLength, 32000);
      final riff = ByteData.sublistView(await f.readAsBytes())
          .getUint32(4, Endian.little);
      expect(riff, 36 + 32000);
      expect(await repairWav(File(p.join(tmp.path, 'manca.wav'))), isNull);
    });

    test('scrittura progressiva: pezzi dispari, intestazione a stop', () async {
      final f = File(p.join(tmp.path, 'scritto.wav'));
      final w = await WavWriter.create(f, sampleRate: 16000, channels: 1);
      w.add(Uint8List.fromList([1, 2, 3]));
      w.add(Uint8List.fromList([4, 5, 6, 7, 8]));
      expect(w.dataBytes, 8);
      await w.updateHeader();
      expect(parseWavHeader(await f.readAsBytes())!.dataLength, 8);
      w.add(tone(0.5));
      await w.close();
      final info = (await readWavInfo(f))!;
      expect(info.dataLength, 8 + 16000);
      expect(
        w.duration,
        Duration(microseconds: (8 + 16000) * 1000000 ~/ 32000),
      );
      final bytes = await f.readAsBytes();
      expect(bytes.sublist(44, 52), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('lettura di un tratto, mono 16 kHz, livelli e taglio', () async {
      final f = File(p.join(tmp.path, 'tono.wav'));
      final w = await WavWriter.create(f, sampleRate: 16000, channels: 1);
      w.add(tone(1));
      w.add(Uint8List(32000)); // 1 s di silenzio
      await w.close();
      final info = (await readWavInfo(f))!;
      final a = await readWavRange(f, info, Duration.zero, sec(1));
      expect(a.length, 16000);
      expect(pcmLevel(a), greaterThan(0.7));
      final b = await readWavRange(f, info, sec(1), sec(2));
      expect(pcmLevel(b), 0);
      // 48 kHz stereo → 16 kHz mono
      final stereo = Int16List(48000 * 2);
      expect(toMono16k(stereo, 48000, 2).length, 16000);
      final peaks = await computePeaks(f);
      expect(peaks.length, 20);
      expect(peaks.first, greaterThan(150));
      expect(peaks.last, 0);
      final cut = File(p.join(tmp.path, 'tagliato.wav'));
      final out = await cutWav(f, info, cut, [
        (ms(500), sec(1)),
        (ms(1500), sec(2)),
      ]);
      expect(out.duration, sec(1));
      expect((await readWavInfo(cut))!.dataLength, 32000);
    });

    test('livelli ogni 100 ms', () {
      final b = LevelBinner(sampleRate: 16000, channels: 1);
      final levels = b.add(Int16List.view(tone(0.35).buffer));
      expect(levels.length, 3);
      expect(levels.every((l) => l > 0.7), isTrue);
    });
  });

  group('trascrizione dal vivo', () {
    test('finestre corte: testo provvisorio che si aggiorna', () {
      final pl = LiveWindowPlanner();
      expect(pl.next(sec(1.5)), isNull); // meno di un passo
      final a = pl.next(sec(2))!;
      expect((a.start, a.end), (Duration.zero, sec(2)));
      expect(pl.next(sec(4)), isNull); // una finestra alla volta
      var out = pl.done(a, [seg(0, 1.8, 'Buongiorno a')]);
      expect(out.committed, isEmpty);
      expect(out.provisional, 'Buongiorno a');
      // la finestra si allunga: stesso inizio, 2 s in più
      final b = pl.next(sec(4))!;
      expect((b.start, b.end), (Duration.zero, sec(4)));
      out = pl.done(b, [seg(0, 3.5, 'Buongiorno a tutti, oggi')]);
      expect(out.provisional, 'Buongiorno a tutti, oggi');
      // pausa del parlato: il testo diventa definitivo e si riparte da lì
      final c = pl.next(sec(6))!;
      out = pl.done(c, [
        seg(0, 3, 'Buongiorno a tutti,'),
        seg(3, 5.2, 'oggi parliamo di limiti.'),
      ], silentTail: true);
      expect(out.committed.map((s) => s.text), [
        'Buongiorno a tutti,',
        'oggi parliamo di limiti.',
      ]);
      expect(out.provisional, '');
      expect(pl.anchor, sec(6));
      // la finestra dopo inizia poco prima (sovrapposizione)
      final d = pl.next(sec(8))!;
      expect((d.start, d.end), (sec(5.7), sec(8)));
    });

    test('finestra piena: l\'ultima frase resta provvisoria', () {
      final pl = LiveWindowPlanner();
      for (final t in [2, 4]) {
        pl.done(pl.next(sec(t))!, [seg(0, t - 0.2, 'parlato continuo')]);
      }
      final full = pl.next(sec(6))!;
      expect(full.end, sec(6)); // 6 s: il massimo
      final out = pl.done(full, [
        seg(0, 2.4, 'Il teorema di Rolle'),
        seg(2.4, 4.6, 'vale per le funzioni continue'),
        seg(4.6, 6, 'e deriva'),
      ]);
      expect(out.committed.map((s) => s.text), [
        'Il teorema di Rolle',
        'vale per le funzioni continue',
      ]);
      // «e deriva» (forse tagliata) si ritrascrive nella finestra dopo
      expect(out.provisional, 'e deriva');
      expect(pl.anchor, sec(4.6));
      final next = pl.next(sec(8))!;
      expect(next.start, sec(4.3));
      // una sola frase lunga: definitiva tutta, si riparte dalla fine
      final pl2 = LiveWindowPlanner();
      pl2.next(sec(7));
      final out2 = pl2.done(LiveChunk(0, Duration.zero, sec(6)), [
        seg(0, 6, 'una frase lunghissima senza pause'),
      ]);
      expect(out2.committed, hasLength(1));
      expect(pl2.anchor, sec(6));
    });

    test('silenzio e frasi inventate: niente testo, la finestra riparte', () {
      final pl = LiveWindowPlanner();
      final a = pl.next(sec(2))!;
      final out = pl.done(a, const [], silentTail: true);
      expect(out.committed, isEmpty);
      expect(out.provisional, '');
      expect(pl.anchor, sec(2));
      final b = pl.next(sec(4))!;
      expect(
        pl.done(b, [seg(2, 4, 'Sottotitoli creati dalla comunità Amara.org')]),
        isA<WindowOutcome>().having((o) => o.provisional, 'provvisorio', ''),
      );
    });

    test('Whisper lento: passo più lungo, poi salto e recupero alla fine', () {
      final pl = LiveWindowPlanner();
      final a = pl.next(sec(2))!;
      pl.done(a, [seg(0, 2, 'uno')], took: sec(3));
      expect(pl.currentStep, sec(3.6)); // 3 s × 1,2
      expect(pl.next(sec(4)), isNull); // 2 s nuovi non bastano più
      final b = pl.next(sec(5.6))!;
      expect(b.end, sec(5.6));
      pl.done(b, [seg(0, 5, 'uno due')], took: sec(10));
      expect(pl.currentStep, sec(5)); // al massimo 5 s
      // molto indietro (oltre 3 finestre): il tratto vecchio si salta
      final c = pl.next(sec(40))!;
      expect(pl.lagSkips, 1);
      expect(pl.skipped.single.end, sec(34));
      expect((c.start, c.end), (sec(33.7), sec(40)));
      pl.abandon();
      final rest = pl.finish(sec(41));
      // saltato (0–34 s, diviso in pezzi da 30 s) e coda non definitiva
      expect(rest.map((c) => (c.start, c.end)), [
        (Duration.zero, sec(30)),
        (sec(29.7), sec(34)),
        (sec(33.7), sec(41)),
      ]);
      expect(pl.skipped, isEmpty);
      // coda troppo corta: niente pezzo finale
      final pl2 = LiveWindowPlanner();
      pl2.done(pl2.next(sec(2))!, const [], silentTail: true);
      expect(pl2.finish(sec(2.3)), isEmpty);
    });

    test('modello in download: il tratto registrato intanto si recupera', () {
      final pl = LiveWindowPlanner()..skipTo(sec(25));
      expect(pl.lagSkips, 0);
      expect(pl.next(sec(26)), isNull);
      expect(pl.next(sec(27))!.start, sec(24.7));
      expect(pl.skipped.single, LiveChunk(0, Duration.zero, sec(25)));
    });

    test('modello pesante: pezzi da ~10 s, definitivi subito', () {
      final pl = LiveWindowPlanner.slow();
      expect(pl.next(sec(8)), isNull);
      final a = pl.next(sec(9.2))!;
      expect((a.start, a.end), (Duration.zero, sec(9)));
      final out = pl.done(a, [
        seg(0, 4, 'Buongiorno a tutti,'),
        seg(4, 9, 'oggi parliamo di integrali'),
      ]);
      expect(out.committed, hasLength(2));
      expect(out.provisional, '');
      final b = pl.next(sec(18))!;
      expect((b.start, b.end), (sec(8), sec(18)));
    });

    test('pausa alla fine della finestra', () {
      Int16List samples(double speech, double pause) {
        final s = pcm16(tone(speech));
        final out = Int16List(s.length + (pause * 16000).round());
        out.setAll(0, s);
        return out;
      }

      expect(endsInPause(samples(2, 0.6)), isTrue);
      expect(endsInPause(samples(2.6, 0)), isFalse);
      expect(endsInPause(samples(0.3, 0)), isFalse); // troppo corta
    });
    test('parole della sovrapposizione', () {
      List<String> w(String s) => s.split(' ');
      expect(
        overlapWords(
          w('oggi parliamo di derivate parziali'),
          w('derivate parziali e gradiente'),
        ),
        2,
      );
      // punteggiatura e maiuscole diverse
      expect(
        overlapWords(w('il teorema di Lagrange.'), w('Lagrange, che dice')),
        1,
      );
      // Whisper aggiunge una parola al bordo
      expect(
        overlapWords(
          w('limite della funzione continua'),
          w('una funzione continua in un punto'),
        ),
        3,
      );
      // parole corte isolate non bastano
      expect(overlapWords(w('studio e'), w('e poi')), 0);
      expect(overlapWords(w('niente in comune'), w('davvero diverso')), 0);
    });

    test('unione dei pezzi senza doppioni', () {
      final m = TranscriptMerger();
      m.add([
        seg(0, 4, 'Buongiorno a tutti,'),
        seg(4, 9, 'oggi parliamo di integrali'),
      ]);
      m.add([
        seg(8, 12, 'di integrali definiti'),
        seg(12, 18, 'e del teorema fondamentale.'),
      ]);
      expect(
        m.text,
        'Buongiorno a tutti, oggi parliamo di integrali definiti e del teorema fondamentale.',
      );
      // pezzo tutto ripetuto: scompare
      m.add([seg(17, 18, 'fondamentale.')]);
      expect(m.segments.length, 4);
      // frasi inventate sul silenzio
      m.add([seg(30, 33, 'Sottotitoli creati dalla comunità Amara.org')]);
      expect(m.segments.length, 4);
    });

    test('pezzo recuperato alla fine: inserito al suo posto', () {
      final m = TranscriptMerger();
      m.add([seg(0, 9, 'la derivata di una funzione')]);
      m.add([seg(17, 27, 'quindi il limite esiste sempre')]);
      // pezzo saltato (8–18 s): si sovrappone a entrambi
      m.add([seg(8, 18, 'una funzione misura la pendenza quindi il limite')]);
      expect(m.segments.map((s) => s.start), [sec(0), sec(8), sec(17)]);
      expect(
        m.text,
        'la derivata di una funzione misura la pendenza quindi il limite esiste sempre',
      );
    });

    test('frasi inventate', () {
      expect(isHallucination('Grazie per la visione!'), isTrue);
      expect(isHallucination('[Musica]'), isTrue);
      expect(isHallucination(''), isTrue);
      expect(isHallucination('La visione di Kant'), isFalse);
    });
  });

  group('dati della registrazione', () {
    test('JSON: segnalibri, segmenti e forma d\'onda', () async {
      final audio = p.join(tmp.path, 'Lezione.m4a');
      final m = RecordingMeta(
        duration: sec(90),
        started: DateTime(2026, 10, 12, 8, 30),
        course: 'Analisi I',
        bookmarks: [Bookmark(sec(30), 'teorema'), Bookmark(sec(5))],
        segments: [seg(0, 4, 'ciao'), seg(4, 9, 'a tutti')],
        transcriptSource: 'dal vivo',
        peaks: Uint8List.fromList([0, 128, 255]),
      );
      await m.save(audio);
      expect(
        RecordingMeta.sidecarOf(audio).path,
        p.join(tmp.path, 'Lezione.json'),
      );
      final r = await RecordingMeta.load(audio);
      expect(r.duration, sec(90));
      expect(r.course, 'Analisi I');
      expect(r.bookmarks.map((b) => b.at), [sec(5), sec(30)]);
      expect(r.bookmarks.last.note, 'teorema');
      expect(r.segments.map((s) => s.text), ['ciao', 'a tutti']);
      expect(r.peaks, [0, 128, 255]);
      // file mancante o rovinato: dati vuoti
      expect(
        (await RecordingMeta.load(p.join(tmp.path, 'x.m4a'))).isEmpty,
        isTrue,
      );
      await File(p.join(tmp.path, 'y.json')).writeAsString('{rotto');
      expect(
        (await RecordingMeta.load(p.join(tmp.path, 'y.m4a'))).isEmpty,
        isTrue,
      );
    });

    test('trascrizione Markdown → segmenti con i tempi', () {
      const md =
          '# Trascrizione – Lezione\n\n_Analisi · Whisper_\n\n'
          '[00:00:00] Buongiorno a tutti.\n\n'
          '[00:02:05] Oggi parliamo\ndi derivate.\n\n'
          '[01:00:00] Fine.\n';
      final s = segmentsFromMarkdown(
        md,
        total: const Duration(hours: 1, minutes: 1),
      );
      expect(s.length, 3);
      expect(s[1].start, const Duration(minutes: 2, seconds: 5));
      expect(s[1].text, 'Oggi parliamo di derivate.');
      expect(s[0].end, s[1].start);
      expect(s[2].end, const Duration(hours: 1, minutes: 1));
      expect(segmentsFromMarkdown('testo senza tempi'), isEmpty);
    });

    test('segmento in corso per un istante', () {
      final s = [seg(0, 4, 'a'), seg(4, 9, 'b'), seg(12, 15, 'c')];
      expect(segmentIndexAt(s, ms(0)), 0);
      expect(segmentIndexAt(s, sec(3.9)), 0);
      expect(segmentIndexAt(s, sec(4)), 1);
      expect(segmentIndexAt(s, sec(10)), 1);
      expect(segmentIndexAt(s, sec(100)), 2);
      expect(segmentIndexAt(const [], sec(1)), -1);
      expect(segmentIndexAt([seg(2, 3, 'x')], sec(1)), -1);
    });

    test('«Salta silenzi»', () {
      // 1 s di voce, 3 s di silenzio, voce
      final peaks = Uint8List.fromList([
        ...List.filled(10, 200),
        ...List.filled(30, 5),
        ...List.filled(10, 200),
      ]);
      expect(silenceSkipTarget(peaks, ms(100), sec(0.5)), isNull);
      expect(silenceSkipTarget(peaks, ms(100), sec(1.2)), sec(3.75));
      // silenzio breve: si ascolta
      final short = Uint8List.fromList([200, 200, 5, 5, 5, 200]);
      expect(silenceSkipTarget(short, ms(100), ms(250)), isNull);
    });

    test('taglio: tempi riportati sulla registrazione tagliata', () {
      final total = sec(60);
      expect(keptRanges(total, sec(10), sec(20), removeInside: false), [
        (sec(10), sec(20)),
      ]);
      final keep = keptRanges(total, sec(20), sec(10), removeInside: true);
      expect(keep, [(Duration.zero, sec(10)), (sec(20), sec(60))]);
      expect(mapThroughCut(sec(5), keep), sec(5));
      expect(mapThroughCut(sec(15), keep), isNull);
      expect(mapThroughCut(sec(25), keep), sec(15));
      final m = cutMeta(
        RecordingMeta(
          bookmarks: [
            Bookmark(sec(5)),
            Bookmark(sec(15), 'tolto'),
            Bookmark(sec(30)),
          ],
          segments: [
            seg(0, 8, 'uno'),
            seg(8, 12, 'due'),
            seg(12, 18, 'tre'),
            seg(18, 25, 'quattro'),
          ],
          peaks: Uint8List.fromList(List.generate(600, (i) => i ~/ 100)),
        ),
        keep,
      );
      expect(m.duration, sec(50));
      expect(m.bookmarks.map((b) => b.at), [sec(5), sec(20)]);
      expect(m.segments.map((s) => s.text), ['uno', 'due', 'quattro']);
      expect(m.segments[1].end, sec(10));
      expect(m.segments[2].start, sec(10));
      expect(m.peaks!.length, 500);
    });
  });

  group('Eliminati di recente', () {
    test('cestino di 30 giorni con ripristino', () async {
      var now = DateTime(2026, 10, 1, 12);
      final root = Directory(p.join(tmp.path, 'Appunti'));
      final bin = RecycleBin(() async => root, now: () => now);
      final dir = Directory(p.join(root.path, 'Analisi', 'Registrazioni'))
        ..createSync(recursive: true);
      final audio = File(p.join(dir.path, 'Lezione.m4a'))
        ..writeAsStringSync('audio');
      final meta = File(p.join(dir.path, 'Lezione.json'))
        ..writeAsStringSync('{}');
      final e = (await bin.trash(
        [audio, meta, File(p.join(dir.path, 'manca.md'))],
        title: 'Lezione',
        course: 'Analisi',
      ))!;
      expect(audio.existsSync(), isFalse);
      expect(e.files.length, 2);
      expect(e.isAudio, isTrue);
      expect(
        Directory(p.join(root.path, RecycleBin.dirName)).existsSync(),
        isTrue,
      );
      var list = await bin.list();
      expect(list.single.title, 'Lezione');
      expect(RecycleBin.daysLeft(list.single.deletedAt, now), 30);
      now = now.add(const Duration(days: 29, hours: 1));
      expect(RecycleBin.daysLeft(e.deletedAt, now), 1);
      // nel frattempo una nuova registrazione con lo stesso nome
      audio.writeAsStringSync('nuova');
      final restored = await bin.restore(list.single);
      expect(restored.map((f) => p.basename(f.path)).toSet(), {
        'Lezione (ripristinato).m4a',
        'Lezione (ripristinato).json',
      });
      expect(audio.readAsStringSync(), 'nuova');
      expect(await bin.list(), isEmpty);
      // dopo 30 giorni si cancella da solo
      await bin.trash([audio], title: 'Vecchia');
      expect((await bin.list()).length, 1);
      now = now.add(const Duration(days: 30));
      expect(
        RecycleBin.expired(DateTime(2026, 10, 1), DateTime(2026, 10, 31)),
        isTrue,
      );
      expect(await bin.list(), isEmpty);
    });

    test(
      'origine diversa (registrazione eliminata durante la registrazione)',
      () async {
        final root = Directory(p.join(tmp.path, 'Appunti'))..createSync();
        final bin = RecycleBin(() async => root);
        final work = File(p.join(tmp.path, 'lavoro.wav'))
          ..writeAsStringSync('x');
        final target = p.join(root.path, 'Corso', 'Registrazioni');
        final e = (await bin.trash(
          [work],
          title: 'Lezione',
          originDir: target,
        ))!;
        final back = await bin.restore(e);
        expect(back.single.path, p.join(target, 'lavoro.wav'));
      },
    );
  });

  group('riquadro e tasto Indietro', () {
    test('quando si vede il riquadro', () {
      expect(
        showRecordingPill(recording: true, recorderVisible: false),
        isTrue,
      );
      expect(
        showRecordingPill(recording: true, recorderVisible: true),
        isFalse,
      );
      expect(
        showRecordingPill(recording: false, recorderVisible: false),
        isFalse,
      );
      expect(
        showRecordingPill(
          recording: false,
          recorderVisible: false,
          saving: true,
        ),
        isTrue,
      );
    });

    test('Indietro alla radice', () {
      expect(
        rootBackAction(index: 2, recording: true, android: true),
        RootBack.home,
      );
      expect(
        rootBackAction(index: 0, recording: true, android: true),
        RootBack.background,
      );
      expect(
        rootBackAction(index: 0, recording: false, android: true),
        RootBack.exit,
      );
      expect(
        rootBackAction(index: 0, recording: true, android: false),
        RootBack.exit,
      );
    });

    test('posizione: dentro lo schermo e nelle aree sicure', () {
      const screen = Size(400, 800);
      const pill = Size(376, 64);
      const safe = EdgeInsets.only(top: 40, bottom: 30);
      final d = defaultPillOffset(screen, pill, safe);
      expect(d.dx, 12);
      expect(d.dy, 40 + 56 + 8);
      // trascinato fuori: torna dentro, sopra la barra in basso
      final o = clampPillOffset(
        const Offset(-50, 2000),
        screen,
        pill,
        safe: safe,
        bottomReserve: kPillBottomReserve,
      );
      expect(o.dx, 8);
      expect(o.dy, 800 - 30 - 8 - kPillBottomReserve - 64);
      expect(
        clampPillOffset(const Offset(10, -5), screen, pill, safe: safe).dy,
        48,
      );
    });
  });

  test('ricerca nelle trascrizioni: frammento e testo pulito', () {
    const md =
        '# Trascrizione – Lezione\n\n_Analisi · Whisper_\n\n'
        '[00:00:00] Oggi parliamo del teorema di Rolle e delle sue conseguenze.\n';
    final body = transcriptBody(md);
    expect(body, 'Oggi parliamo del teorema di Rolle e delle sue conseguenze.');
    expect(
      searchSnippet(body, 'ROLLE', before: 10, after: 5),
      '…eorema di Rolle e de…',
    );
    expect(searchSnippet(body, 'assente'), isNull);
    expect(searchSnippet(body, '  '), isNull);
  });

  test('file di sessione: dati e registrazioni da recuperare', () async {
    final wav = File(p.join(tmp.path, 'registrazione_1.wav'))
      ..writeAsBytesSync([1]);
    final s = RecordingSession(
      wav: wav,
      targetDir: p.join(tmp.path, 'Corso', 'Registrazioni'),
      baseName: '2026-10-12 08-30 Lezione',
      course: 'Fisica',
      courseId: 3,
      started: DateTime(2026, 10, 12, 8, 30),
      bookmarks: [Bookmark(sec(12), 'esercizio')],
      segments: [seg(0, 5, 'ciao')],
    );
    await s.save();
    final list = await RecordingSession.orphans(tmp);
    expect(list.single.course, 'Fisica');
    expect(list.single.courseId, 3);
    expect(list.single.bookmarks.single.note, 'esercizio');
    expect(list.single.segments.single.text, 'ciao');
    expect(await RecordingSession.orphans(tmp, except: wav.path), isEmpty);
    await s.delete();
    expect(wav.existsSync(), isFalse);
    expect(await RecordingSession.orphans(tmp), isEmpty);
  });

  test('motore dal vivo per piattaforma: il telefono usa il riconoscitore del '
      'sistema, il PC no', () async {
    Power.debugOnWifi = () async => false;
    addTearDown(() => Power.debugOnWifi = null);
    Future<LectureRecorder> started(WhisperHost host) async {
      final rec = LectureRecorder(
        recorder: _FakeRecorder.new,
        workDir: () async => Directory(p.join(tmp.path, 'lavoro_$host')),
        controls: () => const NoBackgroundControls(),
        whisper: WhisperService(
          baseDir: () async => Directory(p.join(tmp.path, 'w_$host')),
          host: host,
          builtInAsset: false,
          freeSpace: (_) async => null,
          modelUrl: (_) => Uri.parse('http://127.0.0.1:9/m'),
        ),
      );
      await rec.start(
        p.join(tmp.path, 'Appunti', 'Analisi', 'Registrazioni', 'L.m4a'),
        course: 'Analisi',
      );
      return rec;
    }

    for (final host in [WhisperHost.android, WhisperHost.ios]) {
      final rec = await started(host);
      expect(rec.live!.speech, isNotNull, reason: '$host');
      final take = await rec.stop();
      await take?.live?.close();
      // il file di lavoro (WAV) va tolto prima della cartella temporanea
      await take?.session.delete();
      rec.dispose();
    }
    for (final host in [WhisperHost.windows, WhisperHost.macos]) {
      final rec = await started(host);
      expect(rec.live!.speech, isNull, reason: '$host');
      final take = await rec.stop();
      await take?.live?.close();
      // il file di lavoro (WAV) va tolto prima della cartella temporanea
      await take?.session.delete();
      rec.dispose();
    }
  });

  test(
    'registratore: audio su disco, pausa, segnalibri e salvataggio',
    () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final store = NotesStore(
        SettingsRepository(db),
        root: () async => Directory(p.join(tmp.path, 'Appunti')),
      );
      final fake = _FakeRecorder();
      final rec = LectureRecorder(
        recorder: () => fake,
        workDir: () async => Directory(p.join(tmp.path, 'lavoro')),
        controls: () => const NoBackgroundControls(),
      );
      final s = AppServices(db, notes: store);
      final target = p.join(
        tmp.path,
        'Appunti',
        'Analisi',
        'Registrazioni',
        '2026-10-12 08-30 Lezione.m4a',
      );
      await rec.start(target, course: 'Analisi', courseId: 1);
      expect(rec.active, isTrue);
      // il file di lavoro esiste già: niente audio perso se l'app si chiude
      final orphans = await RecordingSession.orphans(
        Directory(p.join(tmp.path, 'lavoro')),
      );
      expect(orphans.single.course, 'Analisi');

      fake.pcm.add(tone(1));
      await Future<void>.delayed(Duration.zero);
      expect(rec.elapsed, sec(1));
      expect(rec.history.length, 10);
      final b = rec.addBookmark('definizione');
      expect(b.at, sec(1));
      await rec.pause();
      expect(fake.paused, isTrue);
      expect(rec.paused, isTrue);
      // durante la pausa l'audio non si scrive
      fake.pcm.add(tone(1));
      await Future<void>.delayed(Duration.zero);
      expect(rec.elapsed, sec(1));
      await rec.resume();
      fake.pcm.add(tone(0.5));
      await Future<void>.delayed(Duration.zero);
      final take = (await rec.stop())!;
      expect(fake.stopped, isTrue);
      expect(rec.active, isFalse);
      expect(take.duration, sec(1.5));
      expect(take.peaks.length, 15);
      expect(take.session.bookmarks.single.note, 'definizione');
      expect((await readWavInfo(take.session.wav))!.dataLength, 48000);

      // salvataggio: nei test la compressione non c'è → resta il WAV
      final out = await finishTake(s, take);
      expect(p.basename(out.path), '2026-10-12 08-30 Lezione.wav');
      final meta = await RecordingMeta.load(out.path);
      expect(meta.duration, sec(1.5));
      expect(meta.bookmarks.single.at, sec(1));
      expect(meta.peaks!.length, 15);
      expect(take.session.file.existsSync(), isFalse);
      // la registrazione appare negli appunti del corso (il .json no)
      final dir = Directory(p.dirname(out.path));
      expect(dir.listSync().map((e) => p.basename(e.path)).toSet(), {
        '2026-10-12 08-30 Lezione.wav',
        '2026-10-12 08-30 Lezione.json',
      });
      rec.dispose();
    },
  );

  test(
    'trascrizione dal vivo salvata come trascrizione della registrazione',
    () async {
      final audio = p.join(
        tmp.path,
        'Corso',
        NoteFolder.recordings.dirName,
        'Lezione.m4a',
      );
      final f = await writeTranscriptFor(
        audio,
        [seg(0, 4, 'Buongiorno.'), seg(130, 140, 'Seconda parte.')],
        course: 'Fisica',
        source: 'trascrizione dal vivo',
      );
      expect(f.path, p.join(tmp.path, 'Corso', 'Trascrizioni', 'Lezione.md'));
      final md = f.readAsStringSync();
      expect(md, contains('# Trascrizione – Lezione'));
      expect(md, contains('_Fisica · trascrizione dal vivo_'));
      // niente orari delle frasi: i tempi restano nel .json
      expect(md, contains('Buongiorno.'));
      expect(md, contains('Seconda parte.'));
      expect(md, isNot(contains('[00:')));
      expect(segmentsFromMarkdown(md), isEmpty);
      expect(
        await uniqueLessonName(
          Directory(p.dirname(audio))..createSync(recursive: true),
          'Lezione',
        ),
        'Lezione',
      );
    },
  );
}
