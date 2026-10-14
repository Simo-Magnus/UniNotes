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
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
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
    if (await tmp.exists()) await tmp.delete(recursive: true);
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
    test('pezzi da ~10 s con 1 s di sovrapposizione', () {
      final pl = LiveChunkPlanner();
      pl.advance(sec(8));
      expect(pl.waiting, isEmpty);
      pl.advance(sec(9.2));
      expect(pl.waiting.single, LiveChunk(0, Duration.zero, sec(9)));
      final c = pl.takeNext()!;
      expect(c.index, 0);
      expect(pl.takeNext(), isNull); // uno alla volta
      pl.advance(sec(18));
      expect(pl.waiting.single, LiveChunk(1, sec(8), sec(18)));
    });

    test(
      'Whisper indietro: si saltano i pezzi vecchi e si recuperano alla fine',
      () {
        final pl = LiveChunkPlanner();
        pl.advance(sec(9));
        pl.takeNext(); // in lavorazione
        pl.advance(sec(36)); // tre pezzi nuovi, ne aspetta solo uno
        expect(pl.waiting.map((c) => c.index), [3]);
        expect(pl.skipped.map((c) => c.index), [1, 2]);
        pl.done();
        final rest = pl.finish(sec(40));
        expect(rest.map((c) => c.index), [1, 2, 3, 4]);
        expect(rest.last.start, sec(35));
        expect(rest.last.end, sec(40));
        expect(pl.skipped, isEmpty);
        // coda troppo corta: niente pezzo finale
        final pl2 = LiveChunkPlanner()..advance(sec(9));
        expect(pl2.finish(sec(9.3)).map((c) => c.index), [0]);
      },
    );

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
      expect(md, contains('[00:00:00] Buongiorno.'));
      expect(md, contains('[00:02:10] Seconda parte.'));
      // e si rilegge con i tempi
      expect(segmentsFromMarkdown(md).length, 2);
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
