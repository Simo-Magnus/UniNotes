import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/router/app_link_guard.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/reader/parsers/ink.dart';
import 'package:university_notes/features/reader/pdf_highlights.dart';
import 'package:university_notes/features/reader/reader_controller.dart';
import 'package:university_notes/features/reader/views/ink_view.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/utils/exclusion_filter.dart';
import 'package:university_notes/utils/parse.dart';

/// Secondo giro della caccia ai crash, categoria «dati esterni letti in modo
/// rigido»: valori che un'altra versione dell'app, una sincronizzazione o un
/// file rovinato possono portare (infiniti, numeri enormi, tipi diversi,
/// elenchi vuoti).
void main() {
  group('numeri infiniti', () {
    test('asInt: infinito e NaN valgono «assente», non lanciano', () {
      expect(asInt(double.infinity), isNull);
      expect(asInt(double.negativeInfinity), isNull);
      expect(asInt(double.nan), isNull);
      expect(asInt(7.9), 7);
      expect(asInt('12'), 12);
      expect(asInt(null), isNull);
    });

    test('una colonna intera con un REAL infinito nel database non rompe la '
        'lettura degli insegnamenti', () async {
      final db = await AppDatabase.openInMemory();
      await db.db.delete('courses');
      await db.db.insert('courses', {'name': 'Analisi', 'year': 1});
      // 1e999 in SQL è +infinito (file sincronizzato da un altro
      // dispositivo con un numero fuori scala)
      await db.db.execute('UPDATE courses SET year = 1e999');
      final rows = await db.db.query('courses');
      expect(rows.single['year'], double.infinity);
      final c = Course.fromMap(rows.single);
      expect(c.name, 'Analisi');
      expect(c.year, isNull);
      await db.close();
    });
  });

  group('filtri di esclusione', () {
    test('quantificatori annidati (filtri avanzati di versioni precedenti): '
        'testo semplice, nessun blocco', () {
      final sw = Stopwatch()..start();
      final f = ExclusionFilter([r'(a+)+$', r'(.*)*x', r'(\d+)*-', r'\bOFA\b']);
      // con la vecchia espressione 24 «a» impiegano oltre 4 secondi, 40 ore
      expect(f.isExcluded(['${'a' * 24}!']), isFalse);
      expect(f.isExcluded(['Corso OFA Matematica']), isTrue);
      expect(f.isExcluded(['il filtro (a+)+\$ come testo']), isTrue);
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('i filtri normali restano espressioni regolari', () {
      final f = ExclusionFilter([r'^lab(oratorio)?\s*\d*$', r'(inglese|english)']);
      expect(f.isExcluded(['Laboratorio 2']), isTrue);
      expect(f.isExcluded(['English B2']), isTrue);
      expect(f.isExcluded(['Analisi']), isFalse);
      // espressione non valida: testo semplice
      expect(ExclusionFilter(['(']).isExcluded(['a ( b']), isTrue);
    });
  });

  group('collegamenti uninotes:// con app aperta', () {
    Future<void> push(WidgetTester t, String url) async {
      await t.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation',
        const JSONMethodCodec().encodeMethodCall(
          MethodCall('pushRouteInformation', {'location': url}),
        ),
        (_) {},
      );
      await t.pump();
    }

    testWidgets('senza osservatore Flutter cerca un percorso e lancia '
        '(causa dell errore nel registro)', (t) async {
      await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      await push(t, 'uninotes://widget/exams');
      expect(
        t.takeException().toString(),
        contains('Could not find a generator for route'),
      );
    });

    testWidgets('con AppLinkGuard i collegamenti non lanciano e '
        'la home resta dov era', (t) async {
      installAppLinkGuard();
      await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      for (final url in [
        'uninotes://widget/exams',
        'uninotes://widget/registra',
        'uninotes://focus/ok',
        'uninotes://auth?esito=ok',
        'uninotes://auth',
      ]) {
        await push(t, url);
        expect(t.takeException(), isNull, reason: url);
      }
      expect(find.text('home'), findsOneWidget);
    });
  });

  group('orario di una prova', () {
    test('ore enormi o fuori quadrante: giornata intera, nessun errore', () {
      final d = DateTime(2026, 11, 3);
      for (final t in [
        '99999999999:00',
        '9223372036854775807:00',
        '09:99999999999',
        '99:99',
        '24:00',
        '-1:30',
      ]) {
        final e = Exam(courseId: 1, kind: ExamKind.finalExam, date: d, time: t);
        expect(e.dateTime, DateTime(2026, 11, 3), reason: t);
      }
      final ok = Exam(
        courseId: 1,
        kind: ExamKind.finalExam,
        date: d,
        time: '09:30',
      );
      expect(ok.dateTime, DateTime(2026, 11, 3, 9, 30));
    });
  });

  group('file di Xournal++ senza pagine', () {
    testWidgets('saltare a una pagina o riaprire alla posizione salvata non '
        'lancia (clamp con limiti invertiti)', (t) async {
      final doc = parseXopp(
        Uint8List.fromList(
          utf8.encode(
            '<?xml version="1.0"?><xournal version="0.4.8"><title>x</title>'
            '</xournal>',
          ),
        ),
      );
      expect(doc.pages, isEmpty);
      final pane = ReaderPaneController();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: InkView(doc: doc, controller: pane, initialPage: 3),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 50));
      pane.goToPosition(1);
      pane.goToUnit(1);
      pane.find('a');
      await t.pump(const Duration(milliseconds: 50));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      pane.dispose();
    });
  });

  group('coda dei pulsanti delle notifiche', () {
    test('una voce rovinata si salta, le altre restano', () {
      final taps = NotificationTap.parseQueue([
        jsonEncode({'payload': 'prova:3', 'action': 'later'}),
        '{"payload": "prova:4", "act', // scritta a metà
        'non json',
        jsonEncode({'payload': 'sezione:Esami', 'action': null}),
        jsonEncode([1, 2, 3]),
        jsonEncode({'payload': 7}),
      ]);
      expect([for (final t in taps) (t.payload, t.action)], [
        ('prova:3', 'later'),
        ('sezione:Esami', null),
      ]);
    });
  });

  group('JSON con numeri infiniti', () {
    test('output di whisper-cli con un tempo infinito', () {
      final segs = WhisperService.parseSegments(
        '{"transcription":[{"text":"ciao","offsets":{"from":0,"to":1e999}},'
        '{"text":"mondo","offsets":{"from":-1e999,"to":2000}}]}',
      );
      expect(segs, hasLength(2));
      expect(segs[0].end, isNull);
      expect(segs[1].start, Duration.zero);
      expect(segs[1].end, const Duration(seconds: 2));
    });

    test('dati accanto alla registrazione con tempi infiniti: gli altri '
        'restano', () {
      final j =
          jsonDecode(
                '{"durataMs":1e999,"formaOndaMs":1e999,'
                '"segnalibri":[{"ms":1e999},{"ms":5000,"nota":"ok"}],'
                '"segmenti":[{"s":1e999,"e":2,"t":"x"},'
                '{"s":1000,"e":1e999,"t":"y"},{"s":2000,"e":3000,"t":"z"}]}',
              )
              as Map<String, Object?>;
      final m = RecordingMeta.fromJson(j);
      expect(m.duration, isNull);
      expect(m.peakEvery, const Duration(milliseconds: 100));
      expect([for (final b in m.bookmarks) b.at], [
        const Duration(seconds: 5),
      ]);
      expect([for (final s in m.segments) (s.start, s.end, s.text)], [
        (const Duration(seconds: 1), const Duration(seconds: 1), 'y'),
        (const Duration(seconds: 2), const Duration(seconds: 3), 'z'),
      ]);
    });
  });


  group('registro di un altro dispositivo con numeri infiniti', () {
    const text =
        '{"format":"uninotes-sync","version":1,"installId":"B","tables":{'
        '"courses":{"c:polito:course:X":{"v":{"name":"Analisi",'
        '"external_id":"polito:course:X","cfu":1e999,"year":-1e999},'
        '"t":{"name":1792679582304,"cfu":1e999,"year":1792679582305,'
        '"external_id":1792679582304},"d":1e999}}}}';

    test('unione e riscrittura in JSON non lanciano', () {
      final s = SyncSnapshot.decode(utf8.encode(text));
      expect(s, isNotNull);
      final e = s!.tables['courses']!['c:polito:course:X']!;
      expect(e.values.keys, unorderedEquals(['name', 'external_id']));
      expect(e.deleted, isNull);
      final merged = mergeSnapshots([s]);
      expect(() => merged.encodeJson(), returnsNormally);
      expect(SyncSnapshot.decode(merged.encode()), isNotNull);
    });

    test('mergeFolder applica la riga e finisce senza errori', () async {
      final tmp = Directory.systemTemp.createTempSync('uninotes_inf_');
      final db = await AppDatabase.open(path: p.join(tmp.path, 'c.sqlite'));
      addTearDown(() async {
        await db.close();
        tmp.deleteSync(recursive: true);
      });
      final dati = Directory(p.join(tmp.path, 'dati'))..createSync();
      File(p.join(dati.path, 'B altro.json.gz')).writeAsBytesSync(
        gzip.encode(utf8.encode(text)),
      );
      final sync = DataSync(
        db,
        stateDir: () async => tmp,
        notesRoot: () async => p.join(tmp.path, 'appunti'),
      );
      final r = await sync.mergeFolder(
        dati,
        ownName: DataSync.ownFileName('C', 'C'),
        device: 'C',
        installId: 'C',
      );
      expect(r.applied, greaterThan(0));
      final rows = await db.db.query(
        'courses',
        where: 'external_id = ?',
        whereArgs: ['polito:course:X'],
      );
      expect(rows.single['name'], 'Analisi');
      expect(rows.single['cfu'], isNull);
    });
  });

  group('evidenziazioni dei PDF', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('uninotes_hl_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final (name, content) in [
      ('testo non JSON', '[{"page":1,"color":1,"rects":'),
      ('oggetto al posto dell\'elenco (altra versione)', '{"versione":2}'),
    ]) {
      test('file illeggibile ($name): ne resta una copia prima del primo '
          'salvataggio', () async {
        final f = File(p.join(tmp.path, 'a.json'))..writeAsStringSync(content);
        final h = PdfHighlights('/x.pdf', file: f);
        await h.load();
        expect(h.items, isEmpty);
        // il primo salvataggio riscrive il file con la lista nuova
        await h.removeOverlapping(const []);
        expect(f.readAsStringSync(), '[]');
        final copy = File('${f.path}.danneggiato');
        expect(copy.existsSync(), isTrue);
        expect(copy.readAsStringSync(), content);
      });
    }

    test('file buono: si legge e il salvataggio non lascia file a metà',
        () async {
      final f = File(p.join(tmp.path, 'b.json'))
        ..writeAsStringSync(
          jsonEncode([
            {
              'page': 2,
              'color': 0xFFFFEB3B,
              'text': 'ciao',
              'rects': [
                [1.0, 5.0, 4.0, 2.0],
              ],
            },
            {'page': 'x'}, // voce rovinata: si salta
          ]),
        );
      final h = PdfHighlights('/x.pdf', file: f);
      await h.load();
      expect(h.items, hasLength(1));
      await h.removeOverlapping(const []);
      expect(File('${f.path}.part').existsSync(), isFalse);
      expect(File('${f.path}.danneggiato').existsSync(), isFalse);
      expect((jsonDecode(f.readAsStringSync()) as List), hasLength(1));
    });
  });
}
