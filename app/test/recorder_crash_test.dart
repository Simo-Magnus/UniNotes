import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/lesson_transcripts.dart';
import 'package:university_notes/features/notes/markdown_lite.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/live_transcript_editor.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/recording_save.dart';
import 'package:university_notes/features/notes/recorder/recording_session.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/features/notes/spell_check.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Casi che facevano chiudere, bloccare o perdere dati al registratore e
/// agli appunti (caccia ai crash del 22/10/2026, area «Registra»).

Duration sec(num v) => Duration(milliseconds: (v * 1000).round());

TranscriptSegment seg(num a, num b, String t) =>
    TranscriptSegment(sec(a), sec(b), t);

Uint8List tone(double seconds) {
  final n = (seconds * 16000).round();
  final s = Int16List(n);
  for (var i = 0; i < n; i++) {
    s[i] = (8000 * math.sin(2 * math.pi * 440 * i / 16000)).round();
  }
  return s.buffer.asUint8List();
}

/// Registratore del sistema finto, con i guasti da provare.
class _Recorder implements AudioRecorder {
  StreamController<Uint8List> pcm = StreamController<Uint8List>.broadcast();
  void Function(RecordConfig c)? onConfig;
  bool failResume = false;
  bool failStart = false;
  int starts = 0;
  Completer<void>? startGate;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> setOnConfigChanged(void Function(RecordConfig c)? cb) async =>
      onConfig = cb;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    starts++;
    await startGate?.future;
    if (failStart) throw Exception('microfono occupato');
    return pcm.stream;
  }

  @override
  Stream<RecordState> onStateChanged() => const Stream.empty();
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {
    if (failResume) throw Exception('sessione audio non attiva');
  }

  @override
  Future<String?> stop() async {
    await pcm.close();
    return null;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('un_crash_'));
  tearDown(() async {
    for (var i = 0; i < 10 && await tmp.exists(); i++) {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  LectureRecorder recorder(_Recorder fake) => LectureRecorder(
    recorder: () => fake,
    workDir: () async => Directory(p.join(tmp.path, 'lavoro')),
    controls: () => const NoBackgroundControls(),
  );
  String target() =>
      p.join(tmp.path, 'Appunti', 'Analisi', 'Registrazioni', 'L.m4a');

  group('WAV oltre i 4 GB', () {
    test('l\'intestazione non ricomincia da zero (prima 5 GB = 705 MB)', () {
      final h = wavHeader(sampleRate: 16000, channels: 1, dataLength: 5e9 ~/ 1);
      final b = ByteData.sublistView(h);
      expect(b.getUint32(40, Endian.little), 0xFFFFFFFF);
      expect(b.getUint32(4, Endian.little), 0xFFFFFFFF);
      // letto con la lunghezza vera del file: tutti i dati, non 705 MB
      final info = parseWavHeader(h, fileLength: 44 + 5000000000)!;
      expect(info.dataLength, 5000000000);
    });

    test('formato senza frequenza o canali: niente divisioni per zero', () {
      final h = wavHeader(sampleRate: 0, channels: 1, dataLength: 100);
      expect(parseWavHeader(h), isNull);
      expect(toMono16k(Int16List(10), 0, 1), isEmpty);
      expect(toMono16k(Int16List(10), 16000, 0), isEmpty);
    });

    test('scrittura: formato 0 Hz ignorato, durata calcolabile', () async {
      final w = await WavWriter.create(
        File(p.join(tmp.path, 'a.wav')),
        sampleRate: 16000,
        channels: 1,
      );
      w.setFormat(0, 0);
      w.add(tone(0.5));
      expect(w.duration, sec(0.5));
      await w.close();
    });
  });

  group('registratore', () {
    test(
      'formato del sistema non valido: l\'interfaccia non si rompe',
      () async {
        final fake = _Recorder();
        final rec = recorder(fake);
        await rec.start(target(), course: 'Analisi');
        // microfono scollegato mentre parte: 0 Hz, nessun canale
        fake.onConfig!(const RecordConfig(sampleRate: 0, numChannels: 0));
        fake.pcm.add(tone(1));
        await Future<void>.delayed(Duration.zero);
        expect(rec.elapsed, sec(1));
        final take = await rec.stop();
        await take?.live?.close();
        await take?.session.delete();
        rec.dispose();
      },
    );

    test('doppio tocco su «Registra»: una sola registrazione', () async {
      final fake = _Recorder()..startGate = Completer<void>();
      final rec = recorder(fake);
      final first = rec.start(target(), course: 'Analisi');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        rec.start(target(), course: 'Analisi'),
        throwsA(isA<RecorderException>()),
      );
      fake.startGate!.complete();
      await first;
      expect(fake.starts, 1);
      final take = await rec.stop();
      await take?.live?.close();
      await take?.session.delete();
      rec.dispose();
    });

    test('microfono occupato: errore chiaro, nessun file di lavoro', () async {
      final fake = _Recorder()..failStart = true;
      final rec = recorder(fake);
      await expectLater(
        rec.start(target(), course: 'Analisi'),
        throwsA(isA<RecorderException>()),
      );
      expect(rec.active, isFalse);
      expect(await rec.orphans(), isEmpty);
      rec.dispose();
    });

    test(
      'doppio «Salva»: la stessa registrazione, salvata una volta',
      () async {
        final fake = _Recorder();
        final rec = recorder(fake);
        await rec.start(target(), course: 'Analisi');
        fake.pcm.add(tone(1));
        await Future<void>.delayed(Duration.zero);
        final a = rec.stop();
        final b = rec.stop();
        final ta = await a, tb = await b;
        expect(ta, isNotNull);
        expect(identical(ta, tb), isTrue);
        expect(rec.active, isFalse);
        await ta?.live?.close();
        await ta?.session.delete();
        rec.dispose();
      },
    );

    test('la ripresa non riesce (dopo una telefonata): resta in pausa con il '
        'motivo, niente eccezione', () async {
      final fake = _Recorder()..failResume = true;
      final rec = recorder(fake);
      await rec.start(target(), course: 'Analisi');
      await rec.pause();
      await rec.resume();
      expect(rec.paused, isTrue);
      expect(rec.writeError, isNotNull);
      final take = await rec.stop();
      await take?.live?.close();
      await take?.session.delete();
      rec.dispose();
    });

    test(
      'il sistema chiude il microfono: pausa con il motivo, l\'audio resta',
      () async {
        final fake = _Recorder();
        final rec = recorder(fake);
        await rec.start(target(), course: 'Analisi');
        fake.pcm.add(tone(1));
        await fake.pcm.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(rec.paused, isTrue);
        expect(rec.writeError, contains('microfono'));
        fake.pcm = StreamController<Uint8List>.broadcast();
        final take = (await rec.stop())!;
        expect(take.duration, sec(1));
        await take.live?.close();
        await take.session.delete();
        rec.dispose();
      },
    );
  });

  group('file di lavoro e cestino', () {
    test('salvataggi della sessione insieme: nessun errore', () async {
      final s = RecordingSession(
        wav: File(p.join(tmp.path, 'r.wav')),
        targetDir: tmp.path,
        baseName: 'L',
        course: 'Analisi',
        started: DateTime(2026, 10, 22),
      );
      await Future.wait([for (var i = 0; i < 20; i++) s.save()]);
      expect(await s.file.exists(), isTrue);
      expect(await File('${s.file.path}.part').exists(), isFalse);
    });

    test('app chiusa mentre salvava i dati: la registrazione si recupera '
        'dalla copia nuova', () async {
      final wav = File(p.join(tmp.path, 'registrazione_1.wav'));
      await wav.writeAsBytes([
        ...wavHeader(sampleRate: 16000, channels: 1, dataLength: 0),
        ...tone(0.2),
      ]);
      final s = RecordingSession(
        wav: wav,
        targetDir: tmp.path,
        baseName: 'L',
        course: 'Analisi',
        started: DateTime(2026, 10, 22),
      );
      await File('${s.file.path}.part').writeAsString(jsonEncode(s.toJson()));
      final found = await RecordingSession.orphans(tmp);
      expect(found.single.wav.path, wav.path);
    });

    test(
      'dati di un\'altra versione con tipi diversi: si leggono lo stesso',
      () {
        final s = RecordingSession.fromJson(File('x.wav'), {
          'cartella': 'c',
          'nome': 'n',
          'segnalibri': 'non una lista',
          'segmenti': {'s': 1},
        });
        expect(s, isNotNull);
        final m = RecordingMeta.fromJson({'segnalibri': 3, 'segmenti': 'x'});
        expect(m.bookmarks, isEmpty);
      },
    );

    test('«Elimina» con il cestino irraggiungibile: l\'audio resta nel WAV di '
        'lavoro', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final store = NotesStore(
        SettingsRepository(db),
        root: () async =>
            throw const FileSystemException('cartella non raggiungibile'),
      );
      final s = AppServices(db, notes: store);
      final wav = File(p.join(tmp.path, 'lavoro', 'registrazione_2.wav'));
      await wav.parent.create(recursive: true);
      await wav.writeAsBytes(tone(0.2));
      final session = RecordingSession(
        wav: wav,
        targetDir: tmp.path,
        baseName: 'L',
        course: 'Analisi',
        started: DateTime(2026, 10, 22),
      );
      await session.save();
      await expectLater(trashSession(s, session), throwsA(anything));
      expect(await wav.exists(), isTrue);
      expect(await wav.length(), tone(0.2).length);
    });

    test('ripristino ripreso dopo un\'interruzione: i dati restano collegati '
        'alla registrazione', () async {
      final bin = RecycleBin(() async => tmp);
      final dir = Directory(p.join(tmp.path, 'Registrazioni'))..createSync();
      final audio = File(p.join(dir.path, 'L.m4a'))..writeAsStringSync('a');
      final meta = File(p.join(dir.path, 'L.json'))..writeAsStringSync('{}');
      final e = (await bin.trash([audio, meta], title: 'L'))!;
      // il primo ripristino ha rimesso a posto solo l'audio
      final folder = p.join((await bin.dir()).path, e.id);
      await File(p.join(folder, 'L.m4a')).rename(audio.path);
      final out = await bin.restore(e);
      expect(out.map((f) => p.basename(f.path)), ['L.json']);
    });

    test('dati della registrazione già salvata ma non scritti: si rifanno '
        'dalla sessione', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      final saved = File(p.join(tmp.path, 'L.m4a'))..writeAsStringSync('a');
      final session = RecordingSession(
        wav: File(p.join(tmp.path, 'lavoro.wav')),
        targetDir: tmp.path,
        baseName: 'L',
        course: 'Analisi',
        started: DateTime(2026, 10, 22),
        bookmarks: [Bookmark(sec(5), 'definizione')],
        savedAs: saved.path,
      );
      await recoverSession(s, session);
      final m = await RecordingMeta.load(saved.path);
      expect(m.bookmarks.single.note, 'definizione');
    });
  });

  group('testo enorme o strano', () {
    test('paragrafo di 400 KB con molti «\$» e «**»: niente blocco', () {
      final sw = Stopwatch()..start();
      final text = List.filled(100000, r'$a ** _b').join(' ');
      final spans = parseInline(text);
      expect(spans, isNotEmpty);
      // prima: copia del resto del testo a ogni carattere (minuti)
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('le formule si riconoscono come prima', () {
      final s = parseInline(r'Vale $x^2$ e costa $5 al mese, poi $$y$$.');
      expect(
        [
          for (final x in s)
            if (x.math) x.text,
        ],
        ['x^2', 'y'],
      );
    });

    test('trascrizione importata con migliaia di righe di seguito', () {
      final md = '[00:00:00] inizio\n${List.filled(30000, 'riga').join('\n')}';
      final sw = Stopwatch()..start();
      final segs = segmentsFromMarkdown(md);
      expect(segs.single.text.length, greaterThan(100000));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('correzione con la stessa frase due volte: nessun indice fuori '
        'intervallo', () {
      final live = LiveTranscriber(null);
      live.restore([seg(0, 2, 'Uno'), seg(2, 4, 'Due')]);
      live.replaceSegments([2000, 2000], 'Due bis');
      expect(live.segments.map((s) => s.text), ['Uno', 'Due bis']);
      live.restore([seg(0, 2, 'Uno'), seg(0, 3, 'Uno bis'), seg(3, 4, 'Tre')]);
      live.replaceSegments([0, 3000], '');
      expect(live.segments.map((s) => s.text), ['Uno bis']);
    });

    test('modifiche casuali mentre arrivano frasi nuove: nessun errore', () {
      final r = math.Random(7);
      for (var round = 0; round < 300; round++) {
        var segs = [
          for (var i = 0; i < r.nextInt(6); i++)
            seg(i * 2, i * 2 + 2, 'frase ${r.nextInt(99)}'),
        ];
        final b = TranscriptEditBuffer(segs);
        for (var step = 0; step < 20; step++) {
          if (r.nextBool()) {
            // modifica dell'utente in un punto qualsiasi
            final t = b.text;
            final a = t.isEmpty ? 0 : r.nextInt(t.length + 1);
            final e = math.min(t.length, a + r.nextInt(4));
            final ins = ['', 'x', ' ', 'ab '][r.nextInt(4)];
            b.apply(t.replaceRange(a, e, ins));
          } else {
            // il programma: frasi nuove, cambiate o tolte
            segs = [
              for (final s in segs)
                if (r.nextInt(5) > 0)
                  r.nextInt(4) == 0 ? s.copyWith(text: '${s.text} più') : s,
              if (r.nextBool())
                seg(segs.length * 2 + 2, segs.length * 2 + 4, 'nuova'),
            ];
            final changes = b.sync(segs);
            for (final c in changes) {
              c.map(r.nextInt(b.text.length + 1));
            }
          }
          for (final x in b.pieces) {
            expect(x.start, inInclusiveRange(0, b.text.length));
            expect(x.end, inInclusiveRange(x.start, b.text.length));
          }
        }
      }
    });

    test('pulizia della trascrizione chiesta due volte insieme: il testo non '
        'si perde', () async {
      final md = File(p.join(tmp.path, 'L.md'));
      final body = List.generate(
        200,
        (i) => '[00:${(i % 60).toString().padLeft(2, '0')}:00] frase $i',
      ).join('\n\n');
      await md.writeAsString(
        '# Trascrizione – L\n\n_Analisi · trascrizione dal vivo_\n\n$body\n',
      );
      await Future.wait([
        removeTranscriptTimes(md),
        removeTranscriptTimes(md),
        removeTranscriptTimes(md),
      ]);
      expect(await md.readAsString(), contains('frase 199'));
    });

    test('suggerimento dell\'ortografia scelto mentre arriva testo nuovo: '
        'la parola si trova al suo posto nuovo', () {
      // «ciao» era a 0; intanto davanti è arrivata una frase
      expect(nearestOccurrence('Nuova frase. caio a tutti', 'caio', 0), 13);
      expect(nearestOccurrence('caio a tutti', 'caio', 0), 0);
      expect(nearestOccurrence('niente', 'caio', 0), -1);
    });

    test('rinomina della lezione: un file con il nome nuovo non si '
        'sovrascrive', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final store = NotesStore(SettingsRepository(db), root: () async => tmp);
      const c = Course(name: 'Analisi', universityId: 'polito');
      final rec = await store.courseDir(c, NoteFolder.recordings);
      final tr = await store.courseDir(c, NoteFolder.transcripts);
      final audio = File(p.join(rec.path, 'A.m4a'))..writeAsStringSync('a');
      File(p.join(tr.path, 'A (Gemini).md')).writeAsStringSync('di A');
      final other = File(p.join(tr.path, 'B (Gemini).md'))
        ..writeAsStringSync('di B');
      await expectLater(
        store.rename(
          c,
          NoteFile(audio, NoteFolder.recordings, DateTime.now(), 1),
          'B',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(other.readAsStringSync(), 'di B');
      expect(audio.existsSync(), isTrue);
    });
  });
}
