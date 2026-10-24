// Terzo giro della caccia ai crash, categoria testo, input e accessibilità
// (sigla E): coppie surrogate spezzate o spaiate che Flutter non sa disegnare
// («string is not well-formed UTF-16»), campi di ricerca senza tetto,
// controllo ortografico su testi enormi, modifica della trascrizione dal
// vivo, scorciatoie e lettore di schermo.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/features/courses/course_detail_screen.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/links/links_screen.dart';
import 'package:university_notes/features/notes/notes_screen.dart';
import 'package:university_notes/features/settings/settings_screen.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/utils/exclusion_filter.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/features/notes/markdown_view.dart';
import 'package:university_notes/features/notes/recorder/live_transcript_editor.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/spell_check.dart';
import 'package:university_notes/features/notes/transcript_search_screen.dart';
import 'package:university_notes/features/reader/reader_controller.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/features/reader/reader_text.dart';
import 'package:university_notes/features/reader/reader_loader.dart';
import 'package:university_notes/features/reader/views/document_view.dart';
import 'package:university_notes/widgets/find_bar.dart';

/// Indipendente dal codice dell'app: c'è almeno una unità UTF-16 spaiata.
bool _lone(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < s.length &&
          s.codeUnitAt(i + 1) >= 0xDC00 &&
          s.codeUnitAt(i + 1) <= 0xDFFF) {
        i++;
        continue;
      }
      return true;
    }
    if (u >= 0xDC00 && u <= 0xDFFF) return true;
  }
  return false;
}

const _emoji = '\u{1F600}';

/// Nomi pensati per rompere il testo: emoji (anche in famiglia, con ZWJ),
/// caratteri combinati a decine, destra-sinistra, controlli bidi, nullo, a
/// capo di Windows, spazi strani, righe enormi.
final _hostile = <String>[
  'Fisica $_emoji',
  '\u202Eelacitamatam\u202C Analisi',
  'Analisi\u0000Uno',
  'Riga1\r\nRiga2\rRiga3',
  'e${'\u0301' * 60}',
  '\u0645\u0631\u062D\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}' * 8,
  '\u200B\u200B',
  ' \u00A0\u2003\u3000 ',
  'Parola' * 400,
  '\u{1F600}' * 120,
];

Future<AppServices> _hostileServices() async {
  final db = await AppDatabase.openInMemory();
  for (final t in [
    'courses',
    'universities',
    'degrees',
    'books',
    'exams',
    'modules',
    'topics',
    'study_sessions',
    'attachments',
    'materials',
    'profile',
    'plan_years',
  ]) {
    await db.db.delete(t);
  }
  final s = AppServices(db);
  for (var i = 0; i < _hostile.length; i++) {
    final id = await s.courses.insert(
      Course(
        name: _hostile[i],
        year: 1 + i % 3,
        semester: '1',
        cfu: 6,
        teacher: _hostile[(i + 3) % _hostile.length],
        description: _hostile[(i + 5) % _hostile.length],
      ),
    );
    await s.exams.save(
      Exam(
        courseId: id,
        date: DateTime(2026, 11, 3 + i),
        status: i.isEven ? ExamStatus.passed : ExamStatus.planned,
        grade: i.isEven ? 24 + i % 7 : null,
        title: _hostile[(i + 1) % _hostile.length],
        location: _hostile[(i + 2) % _hostile.length],
        notes: _hostile[(i + 4) % _hostile.length],
      ),
    );
  }
  return s;
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('lettore di schermo e testi ostili', () {
    for (final (width, scale) in [(360.0, 1.0), (1000.0, 2.0)]) {
      testWidgets(
        'schermate principali con il lettore attivo, ${width.toInt()} px '
        '×$scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final handle = tester.ensureSemantics();
          final s = (await tester.runAsync(_hostileServices))!;
          addTearDown(() => tester.runAsync(s.database.close));
          final courses = (await tester.runAsync(s.courses.all))!;
          final previous = FlutterError.onError;
          final errors = <String>[];
          var where = '';
          FlutterError.onError = (d) {
            if (d.toString().contains('overflowed by')) return;
            errors.add('$where: ${d.exceptionAsString().split('\n').first}');
          };
          addTearDown(() => FlutterError.onError = previous);

          final screens = <(String, Widget)>[
            ('AppShell', const AppShell()),
            ('Dashboard', const DashboardScreen()),
            ('Insegnamenti', const CoursesScreen()),
            ('Esami', const ExamsScreen()),
            ('Studio', const StudyScreen()),
            ('Libri', const BooksScreen()),
            ('Appunti', const NotesScreen()),
            ('Collegamenti', const LinksScreen()),
            ('Impostazioni', const SettingsScreen()),
            ('Voti', const YearGradesScreen(year: 1)),
            ('Modulo esame', const ExamFormPage()),
            ('Modulo insegnamento', CourseFormPage(course: courses.first)),
            ('Dettaglio', CourseDetailScreen(courseId: courses.first.id!)),
          ];
          for (final (name, screen) in screens) {
            where = name;
            final watch = Stopwatch()..start();
            await tester.pumpWidget(const SizedBox());
            await tester.pumpWidget(
              Provider<AppServices>.value(
                value: s,
                child: MaterialApp(
                  theme: AppTheme.dark(),
                  locale: const Locale('it', 'IT'),
                  supportedLocales: const [Locale('it', 'IT')],
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  home: screen,
                ),
              ),
            );
            for (var i = 0; i < 5; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 40)),
              );
              await tester.pump();
            }
            // l'albero semantico si costruisce davvero (asserzioni incluse)
            tester.getSemantics(find.byType(Scaffold).first);
            final e = tester.takeException();
            if (e != null) errors.add('$name: $e');
            // ignore: avoid_print
            print('$name: ${watch.elapsedMilliseconds} ms');
          }
          FlutterError.onError = previous;
          handle.dispose();
          expect(errors, isEmpty, reason: errors.join('\n'));
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }
  });

  group('coppie surrogate', () {
    test('frammento attorno alla parola cercata: non taglia un\'emoji', () {
      // la parola è al carattere 41: il frammento comincia al 1° (metà emoji)
      final text = '$_emoji${'a' * 39}zzz${'b' * 100}$_emoji$_emoji';
      final s = searchSnippet(text, 'zzz');
      expect(s, isNotNull);
      expect(_lone(s!), isFalse, reason: s);
      // anche la fine: la parola vicina all'ultima emoji
      final t = '${'a' * 40}zzz${'b' * 59}$_emoji$_emoji';
      final e = searchSnippet(t, 'zzz');
      expect(_lone(e!), isFalse, reason: e);
      // qualunque posizione della parola
      for (var pad = 0; pad < 120; pad++) {
        final u = '${_emoji * pad}zzz${_emoji * pad}';
        expect(_lone(searchSnippet(u, 'zzz')!), isFalse, reason: 'pad $pad');
      }
    });

    test('file UTF-16 con una metà spaiata: il documento è disegnabile', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xFE, // BOM
        0x61, 0x00, 0x3D, 0xD8, 0x62, 0x00, // a, <alta spaiata>, b
      ]);
      final doc = parseDocument(bytes, '.txt');
      expect(_lone(doc.plainText), isFalse, reason: doc.plainText);
      expect(doc.plainText, contains('a'));
      expect(doc.plainText, contains('b'));
    });

    test('JSON con \\ud800 aperto come documento: disegnabile', () {
      final bytes = Uint8List.fromList(
        utf8.encode('{"nome": "x\\ud800y", "k\\udc00": [1, "\\udbff"]}'),
      );
      final doc = parseDocument(bytes, '.json');
      expect(_lone(doc.plainText), isFalse, reason: doc.plainText);
    });

    test('XML con un riferimento a una metà spaiata: disegnabile', () {
      final bytes = Uint8List.fromList(
        utf8.encode('<a><b>x&#xD800;y&#xDC00;z</b></a>'),
      );
      final doc = parseDocument(bytes, '.xml');
      expect(_lone(doc.plainText), isFalse, reason: doc.plainText);
    });

    testWidgets('scaletta OPML con una metà spaiata: disegnabile', (t) async {
      final dir = Directory.systemTemp.createTempSync('r3e_opml');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.opml')
        ..writeAsStringSync(
          '<opml><body><outline text="x&#xD800;y" _note="n&#xDC00;"/>'
          '</body></opml>',
        );
      final (_, content) = (await t.runAsync(() => loadReaderContent(f.path)))!;
      expect(content, isA<OutlineContent>());
      final doc = (content as OutlineContent).doc;
      for (final (n, _) in doc.walk()) {
        expect(_lone(n.text), isFalse, reason: n.text);
        expect(_lone(n.note ?? ''), isFalse);
      }
      expect(doc.walk().isNotEmpty, isTrue);
    });

    test(
      'dati della registrazione con metà spaiate: testi disegnabili',
      () async {
        final dir = Directory.systemTemp.createTempSync('r3e_meta');
        addTearDown(() => dir.deleteSync(recursive: true));
        final audio = '${dir.path}/lezione.flac';
        File('${dir.path}/lezione.json').writeAsStringSync(
          '{"segmenti": [{"s": 0, "e": 1000, "t": "ciao x\\ud83dy"}]}',
        );
        final meta = await RecordingMeta.load(audio);
        expect(meta.segments, hasLength(1));
        expect(_lone(meta.segments.single.text), isFalse);
        expect(meta.segments.single.text, startsWith('ciao x'));
      },
    );

    testWidgets('paragrafo lunghissimo di emoji: nessun taglio a metà', (
      t,
    ) async {
      // 7000 emoji = 14000 unità: il paragrafo si divide in pezzi da 6000
      // unità, e 6000 è pari ma con lo spazio prima... qui senza spazi
      final doc = RDoc(
        sections: [
          RSection('', [
            RPara([RSpan('a${_emoji * 7000}')]),
            RPara([RSpan(_emoji * 4000), RSpan('${_emoji * 4000}b')]),
          ]),
        ],
      );
      final controller = ReaderPaneController();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentView(
              doc: doc,
              controller: controller,
              initialPosition: 0,
            ),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      for (var i = 0; i < 30; i++) {
        await t.drag(find.byType(Scrollable).first, const Offset(0, -800));
        await t.pump();
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('cella di tabella di emoji oltre 2000: disegnabile', (t) async {
      final doc = RDoc(
        sections: [
          RSection('', [
            RTableRow(['a${_emoji * 3000}', 'x'], table: 0),
          ]),
        ],
        tables: [
          RTable([10, 5]),
        ],
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentView(doc: doc, controller: ReaderPaneController()),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });

  group('campi di ricerca', () {
    test('metà di un\'emoji cercata: nessun risultato che spezzi una coppia', () {
      const text = 'a\u{1F600}b\u{1F601}c';
      // «\u{1F600}» = D83D DE00: cercare solo D83D troverebbe entrambe le emoji
      for (final half in [
        String.fromCharCode(0xD83D),
        String.fromCharCode(0xDE00),
      ]) {
        final hits = findFolded(text, half);
        for (final i in hits) {
          expect(
            _lone(text.substring(i, i + half.length)),
            isFalse,
            reason: 'taglio a $i',
          );
        }
      }
      expect(findFolded(text, '\u{1F600}'), [1]);
    });

    testWidgets('«Trova nel testo» ha un tetto: una pagina incollata no', (
      t,
    ) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FindBar(
              controller: c,
              focusNode: FocusNode(),
              onChanged: (_) {},
              onNext: () {},
              onPrevious: () {},
              onClose: () {},
              total: 0,
              current: null,
            ),
          ),
        ),
      );
      await t.enterText(find.byType(TextField), 'x' * 5000);
      expect(c.text.length, lessThanOrEqualTo(1000));
      // le emoji contano come caratteri interi: niente metà in fondo
      await t.enterText(find.byType(TextField), _emoji * 5000);
      expect(_lone(c.text), isFalse);
    });
  });

  group('filtri scritti dall\'utente', () {
    test('alternative sovrapposte con quantificatore: niente blocco', () {
      final watch = Stopwatch()..start();
      final f = ExclusionFilter(['(a|aa)+c', '(x|x?)*y']);
      expect(f.isExcluded(['${'a' * 60}b', '${'x' * 60}z']), isFalse);
      expect(watch.elapsedMilliseconds, lessThan(2000));
      // il filtro normale con alternative funziona ancora
      expect(
        ExclusionFilter(['(ofa|inglese)']).isExcluded(['Inglese B1']),
        isTrue,
      );
      // anche il testo letterale del filtro scartato
      expect(f.isExcluded(['(a|aa)+c']), isTrue);
    });

    test('caratteri speciali digitati: testo semplice o pattern valido', () {
      for (final p in [
        '.*+?',
        '(',
        ')',
        '[',
        ']',
        r'\',
        '*',
        '+a',
        '{1,',
        '(?<',
        '[z-a]',
      ]) {
        expect(
          () => ExclusionFilter([p]).isExcluded(['Analisi 1']),
          returnsNormally,
          reason: p,
        );
      }
    });
  });

  group('fuoco e controller dopo la chiusura', () {
    testWidgets('«Trova» aperta mentre la schermata si chiude: nessun errore', (
      t,
    ) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SearchableMarkdownView('Testo da cercare')),
        ),
      );
      final state = t.state<SearchableMarkdownViewState>(
        find.byType(SearchableMarkdownView),
      );
      state.openFind();
      // la schermata sparisce nello stesso fotogramma: la richiesta di
      // fuoco e la selezione del testo partono dopo, a controller eliminato
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });

  group('controllo ortografico', () {
    test('righe enormi e troppe righe insieme non vanno al correttore '
        'nativo', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final received = <List<String>>[];
      const channel = MethodChannel('prova/ortografia');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final texts = ((call.arguments as Map)['texts'] as List)
                .cast<String>();
            received.add(texts);
            return [for (final _ in texts) <Object?>[]];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final service = SystemSpellCheckService(
        channel: channel,
        platform: TargetPlatform.windows,
      );
      final giant = 'parola ' * 300000; // ~2 MB su una riga
      final normal = [for (var i = 0; i < 3000; i++) 'riga numero $i ' * 3];
      final text = '$giant\n${normal.join('\n')}';
      await service.fetchSpellCheckSuggestions(const Locale('it'), text);
      final sent = received.expand((l) => l).toList();
      expect(sent.any((l) => l.length > 100000), isFalse);
      final total = sent.fold<int>(0, (a, l) => a + l.length);
      expect(total, lessThan(300000), reason: 'caratteri inviati: $total');
      // il giro dopo prosegue con le righe rimaste
      received.clear();
      await service.fetchSpellCheckSuggestions(const Locale('it'), text);
      expect(received, isNotEmpty);
    });
  });

  group('trascrizione dal vivo', () {
    test('modifiche casuali con emoji, accenti e a capo: nessun errore', () {
      final rnd = Random(7);
      const alphabet = [
        'a',
        'b',
        ' ',
        'è',
        _emoji,
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}',
        '\n',
        '\r\n',
        'e\u0301',
        '\u202E',
        '\u0000',
        '\u060C',
      ];
      for (var round = 0; round < 300; round++) {
        final segs = [
          for (var i = 0; i < 1 + rnd.nextInt(6); i++)
            TranscriptSegment(
              Duration(seconds: i * 3),
              Duration(seconds: i * 3 + 2),
              [
                for (var k = 0; k < 1 + rnd.nextInt(8); k++)
                  alphabet[rnd.nextInt(alphabet.length)],
              ].join(),
            ),
        ];
        final b = TranscriptEditBuffer(segs);
        for (var step = 0; step < 12; step++) {
          var text = b.text;
          final a = rnd.nextInt(text.length + 1);
          final z = a + rnd.nextInt(min(4, text.length - a) + 1);
          final ins = rnd.nextBool()
              ? alphabet[rnd.nextInt(alphabet.length)]
              : '';
          text = text.replaceRange(a, z, ins);
          try {
            b.apply(text);
            if (rnd.nextInt(3) == 0) {
              b.sync([
                for (final s in segs)
                  if (rnd.nextBool()) s,
                TranscriptSegment(
                  Duration(seconds: 100 + step),
                  Duration(seconds: 101 + step),
                  alphabet[rnd.nextInt(alphabet.length)],
                ),
              ]);
            }
          } catch (e, st) {
            fail('round $round passo $step: $e\n$st');
          }
        }
      }
    });
  });
}
