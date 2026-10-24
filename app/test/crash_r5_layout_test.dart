// Quinto giro della caccia ai crash (sigla R5-B): testi ed elementi che
// escono dal loro spazio («A RenderFlex overflowed by N pixels», bordi a
// strisce gialle e nere in debug, testo tagliato in release).
//
// Ogni luogo trovato dalla prova a caso (crash_r4_monkey_test.dart, giro
// lungo con CRASH_R5_COLLECT=1) ha qui la sua prova: il widget si apre in
// finestre da 320×568 a 1920×1080 (anche in orizzontale), con caratteri ×1,
// ×1,3 e ×2 (il massimo dell'app) e tema chiaro e scuro, e non deve
// segnalare nessun overflow.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/features/notes/recorder_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/features/academic/year_widgets.dart';
import 'package:university_notes/features/books/book_form.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/books/book_tile.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/features/exams/previous_years.dart';
import 'package:university_notes/features/exams/previous_years_screen.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/study/course_catalog.dart';
import 'package:university_notes/features/study/sessions_tab.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/widgets/adaptive_row.dart';
import 'package:university_notes/widgets/common.dart';
import 'package:university_notes/widgets/date_pick.dart';
import 'package:university_notes/widgets/math_text.dart';
import 'package:university_notes/widgets/app_snack_action.dart';

/// Finestre provate (larghezza, altezza): telefono piccolo, telefono in
/// orizzontale, telefono normale, tablet, portatile, schermo grande.
const _sizes = [
  Size(320, 568),
  Size(568, 320),
  Size(360, 640),
  Size(768, 1024),
  Size(1366, 768),
  Size(1920, 1080),
];
const _scales = [1.0, 1.3, 2.0];

bool get _full => Platform.environment['CRASH_R5_FULL'] == '1';

/// Combinazioni da provare: tutte con CRASH_R5_FULL=1, altrimenti le più
/// strette e le più larghe.
Iterable<(Size, double, bool)> _combos() sync* {
  for (final s in _sizes) {
    for (final k in _scales) {
      for (final dark in const [false, true]) {
        if (!_full) {
          final extreme =
              (s == _sizes.first || s == _sizes[1] || s == _sizes.last) &&
              k != 1.3;
          if (!extreme) continue;
        }
        yield (s, k, dark);
      }
    }
  }
}

/// Che cosa si sta provando (per il messaggio d'errore).
String _what = '';

String _name(Size s, double k, bool dark) =>
    '${s.width.toInt()}x${s.height.toInt()}, caratteri ×$k, '
    'tema ${dark ? 'scuro' : 'chiaro'}';

/// Finestra, caratteri e tema come nell'app: la scala del sistema passa
/// dall'AppTextScaler (massimo ×2), il tema è quello vero.
Widget _app(Widget home, bool dark, {AppServices? services}) {
  final app = MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(textScaler: AppTextScaler(media.textScaler, 1)),
        child: child!,
      );
    },
    home: home,
  );
  return services == null
      ? app
      : Provider<AppServices>.value(value: services, child: app);
}

/// Esegue [body] per ogni combinazione e riunisce gli overflow trovati
/// (testo di Flutter con il widget responsabile).
Future<void> _forEachCombo(
  WidgetTester t,
  Future<void> Function(
    Size size,
    double scale,
    bool dark,
    void Function() reset,
  )
  body,
) async {
  final found = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    final text = d.exceptionAsString();
    if (text.contains('overflowed by')) {
      final loc = RegExp(
        r'file:///[A-Za-z]:/[^\s]*?/app/(lib/[^\s:]+\.dart:\d+)',
      ).firstMatch(d.toString());
      found.add(
        '$_what ${text.split('\n').first} (${loc?[1] ?? 'fuori dall\'app'})',
      );
    } else {
      previous?.call(d);
    }
  };
  addTearDown(() => FlutterError.onError = previous);
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  for (final (s, k, dark) in _combos()) {
    t.view.physicalSize = s;
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = k;
    final before = found.length;
    await body(s, k, dark, () {});
    for (var i = before; i < found.length; i++) {
      found[i] = '${_name(s, k, dark)}: ${found[i]}';
    }
  }
  FlutterError.onError = previous;
  expect(found.toSet(), isEmpty);
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('avvisi in basso', () {
    // «Segnalibro a 00:12 / Aggiungi nota» e simili: il pulsante dell'avviso
    // non esce dallo spazio.
    testWidgets('avviso con pulsante, messaggio lungo e corto', (t) async {
      await _forEachCombo(t, (s, k, dark, _) async {
        for (final (msg, label) in const [
          ('Segnalibro a 00:12', 'Aggiungi nota'),
          ('Sessione eliminata.', 'Annulla'),
          (
            'Eliminato: «Elettrotecnica applicata alle macchine» tolto dal piano',
            'Annulla',
          ),
        ]) {
          _what = '[$msg / $label]';
          await t.pumpWidget(_app(const Scaffold(body: SizedBox()), dark));
          final ctx = t.element(find.byType(Scaffold));
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(
              content: Text(msg),
              action: AppSnackBarAction(label: label, onPressed: () {}),
            ),
          );
          await t.pump();
          await t.pump(const Duration(milliseconds: 600));
        }
      });
    });
  });

  group('registratore', () {
    // «Segna», pulsante grande e «Salva» sulla stessa riga: non escono dallo
    // spazio in nessuna finestra e con nessuna grandezza dei caratteri.
    testWidgets('schermata «Registra lezione»', (t) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[Registra lezione]';
        await t.pumpWidget(
          _app(
            const RecorderScreen(initialCourse: Course(id: 1, name: 'Fisica')),
            dark,
            services: s,
          ),
        );
        for (var i = 0; i < 4; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 50));
        }
      });
    });
  });

  group('righe con testo e pulsante', () {
    const body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Anno da completare'),
        Text('Segna l\'anno come completato inserendo solo i voti.'),
      ],
    );

    testWidgets('AdaptiveActionRow: in riga se c\'è posto, sotto se no', (
      t,
    ) async {
      var inline = 0;
      var stacked = 0;
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[AdaptiveActionRow]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: AdaptiveActionRow(
                    leading: const Icon(Icons.history_edu_rounded),
                    gap: 12,
                    body: body,
                    actionLabel: 'Segna come completato',
                    action: OutlinedButton(
                      onPressed: () {},
                      child: const Text('Segna come completato'),
                    ),
                  ),
                ),
              ),
            ),
            dark,
          ),
        );
        final b = t.getRect(find.byType(OutlinedButton));
        final txt = t.getRect(find.text('Anno da completare'));
        if (b.top >= txt.bottom) {
          stacked++;
        } else {
          inline++;
        }
      });
      // la finestra grande a caratteri normali resta in una riga, quella
      // stretta a caratteri grandi no
      expect(inline, greaterThan(0));
      expect(stacked, greaterThan(0));
    });

    testWidgets('intestazione di sezione con pulsante dalla scritta lunga', (
      t,
    ) async {
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[SectionHeader]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: SectionHeader(
                '1° anno',
                trailing: TextButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.done_all_rounded, size: 18),
                  label: const Text('Segna tutti come sostenuti'),
                ),
              ),
            ),
            dark,
          ),
        );
      });
    });

    testWidgets('intestazione della materia nelle sessioni', (t) async {
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[SubjectSessionsHeader]';
        await t.pumpWidget(
          _app(
            const Scaffold(
              body: Column(
                children: [
                  SubjectSessionsHeader(
                    name: 'Elettrotecnica applicata alle macchine elettriche',
                    color: Colors.teal,
                    minutes: 59999,
                    count: 1234,
                  ),
                  SubjectSessionsHeader(
                    name: 'Fisica',
                    color: Colors.teal,
                    minutes: 70,
                    count: 2,
                  ),
                ],
              ),
            ),
            dark,
          ),
        );
      });
    });

    testWidgets('titolo delle sessioni con «Aggiungi»', (t) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      final catalog = CourseCatalog(const [
        Course(id: 1, name: 'Analisi I'),
      ], const []);
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[SessionHistory]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: ListView(children: [SessionHistory(catalog: catalog)]),
            ),
            dark,
            services: s,
          ),
        );
        await _settle(t);
      });
    });
  });

  group('anni precedenti e anno mostrato', () {
    StudentProfile profile({int current = 3, int start = 2}) => StudentProfile(
      universityId: 'u',
      universityName: 'Università',
      degreeId: 'd',
      degreeName: 'Ingegneria',
      degreeType: 'L',
      durationYears: 3,
      currentYear: current,
      referenceAa: AcademicYear.tryParse('2026/27')!,
      startYear: start,
    );

    testWidgets('riquadro «Anni precedenti» (da completare e completati)', (
      t,
    ) async {
      final todo = PreviousYearsData(
        profile: profile(),
        years: [
          PreviousYear(1, [
            const PreviousCourse(
              Course(id: 1, name: 'Analisi matematica I'),
              Exam(id: 1, courseId: 1, status: ExamStatus.toComplete),
            ),
            const PreviousCourse(
              Course(id: 2, name: 'Fisica generale'),
              Exam(id: 2, courseId: 2, status: ExamStatus.toComplete),
            ),
          ]),
        ],
      );
      final done = PreviousYearsData(
        profile: profile(),
        years: [
          PreviousYear(1, [
            const PreviousCourse(
              Course(id: 1, name: 'Analisi matematica I'),
              Exam(id: 1, courseId: 1, status: ExamStatus.passed, grade: 28),
            ),
          ]),
        ],
      );
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[PreviousYearsBanner]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: ListView(
                children: [
                  PreviousYearsBanner(data: todo),
                  PreviousYearsBanner(data: done),
                ],
              ),
            ),
            dark,
            services: s,
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
      });
    });

    testWidgets('riquadro dell\'anno mostrato (passato e futuro)', (t) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      s.profile.value = profile(current: 2, start: 1);
      await _forEachCombo(t, (size, k, dark, _) async {
        for (final year in [1, 3]) {
          _what = '[YearStatusBanner anno $year]';
          s.selectedYear.value = year;
          await t.pumpWidget(
            _app(const Scaffold(body: YearStatusBanner()), dark, services: s),
          );
          await _settle(t);
        }
      });
    });
  });

  group('fogli, riquadri e selettori', () {
    testWidgets('foglio «Altro» della barra in basso', (t) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      var opened = 0;
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[AppShell: Altro]';
        await t.pumpWidget(_app(const AppShell(), dark, services: s));
        await _settle(t);
        final more = find.text('Altro');
        if (more.evaluate().isEmpty) return; // finestra larga: nessuna barra
        await t.tap(more.first, warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 500));
        opened++;
      });
      expect(opened, greaterThan(0));
    });

    testWidgets('foglio «Nuova prova»', (t) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      var opened = 0;
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[ExamsScreen: Nuova prova]';
        await t.pumpWidget(_app(const ExamsScreen(), dark, services: s));
        await _settle(t);
        final add = find.text('Nuova prova');
        if (add.evaluate().isEmpty) return;
        await t.tap(add.first, warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 500));
        opened++;
      });
      expect(opened, greaterThan(0));
    });

    testWidgets('modulo del libro: lingua e stato di possesso affiancati', (
      t,
    ) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      final catalog = CourseCatalog(const [
        Course(id: 1, name: 'Analisi I'),
      ], const []);
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[BookForm]';
        await t.pumpWidget(_app(BookForm(catalog: catalog), dark, services: s));
        await _settle(t);
      });
    });

    testWidgets('«Eliminare la registrazione?» in una finestra bassa', (
      t,
    ) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[confirmDeleteRecording]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () => confirmDeleteRecording(
                    c,
                    name: 'Lezione di Elettrotecnica applicata',
                  ),
                  child: const Text('Apri'),
                ),
              ),
            ),
            dark,
            services: s,
          ),
        );
        await t.tap(find.text('Apri'));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 500));
        // chiude: la finestra seguente riparte da zero
        await t.pumpWidget(const SizedBox());
      });
    });

    testWidgets('selettore dell\'ora', (t) async {
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[showSafeTimePicker]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () => showSafeTimePicker(
                    context: c,
                    initialTime: const TimeOfDay(hour: 9, minute: 30),
                  ),
                  child: const Text('Apri'),
                ),
              ),
            ),
            dark,
          ),
        );
        await t.tap(find.text('Apri'));
        await t.pump(const Duration(milliseconds: 600));
        await t.pumpWidget(const SizedBox());
      });
    });
  });

  group('schede dei libri', () {
    // La scheda di un libro (titolo, etichette, «Aggiungi» e menu a destra)
    // in colonne di ogni larghezza, con la finestra grande e piccola e i
    // caratteri ×1,3 e ×2: nessun overflow e nessun «Trailing widget consumes
    // the entire tile width».
    testWidgets('colonne da 280 a 1200 px', (t) async {
      const books = [
        Book(id: 1, title: 'Analisi matematica'),
        Book(
          id: 2,
          title: 'Fondamenti di elettrotecnica e di macchine elettriche',
          author: 'Autore Molto Lungo e Altri',
          edition: '12',
          publisher: 'Casa Editrice Universitaria',
          year: 2024,
          required: true,
        ),
        Book(
          id: 3,
          externalId: 'x',
          title: 'Fisica 1',
          catalogChoice: CatalogChoice.removed,
        ),
        Book(id: 4, externalId: 'y', title: 'Chimica generale e inorganica'),
      ];
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exceptionAsString();
        if (text.contains('overflowed by') ||
            text.contains('consumes the entire tile width')) {
          errors.add(text.split('\n').first);
        } else {
          previous?.call(d);
        }
      };
      addTearDown(() => FlutterError.onError = previous);
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      for (final window in const [Size(360, 640), Size(1920, 1080)]) {
        for (final k in const [1.3, 2.0]) {
          t.view.physicalSize = window;
          t.view.devicePixelRatio = 1;
          t.platformDispatcher.textScaleFactorTestValue = k;
          for (var w = 280.0; w <= 1200; w += 20) {
            final before = errors.length;
            await t.pumpWidget(
              _app(
                Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: min(w, window.width),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final b in books)
                              BookTile(
                                book: b,
                                onOpen: () {},
                                onAction: (_) {},
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                false,
              ),
            );
            await t.pump();
            for (var i = before; i < errors.length; i++) {
              errors[i] =
                  'finestra ${window.width.toInt()}, ×$k, colonna ${w.toInt()}: ${errors[i]}';
            }
          }
        }
      }
      FlutterError.onError = previous;
      expect(errors.toSet(), isEmpty);
    });

    // La schermata Libri con la finestra che cambia misura sotto i piedi
    // (telefono → schermo grande e ritorno) e i caratteri che cambiano: le
    // schede non devono mai trovarsi con «Trailing widget consumes the
    // entire tile width» né uscire dallo spazio.
    testWidgets('schermata Libri con la finestra che cambia', (t) async {
      final s = (await t.runAsync(
        () async => AppServices(await AppDatabase.openInMemory()),
      ))!;
      addTearDown(() => t.runAsync(s.database.close));
      await t.runAsync(() async {
        for (final b in const [
          Book(title: 'Analisi matematica'),
          Book(
            title: 'Fondamenti di elettrotecnica e di macchine elettriche',
            author: 'Autore Molto Lungo e Altri',
            edition: '12',
            publisher: 'Casa Editrice Universitaria',
            year: 2024,
            required: true,
          ),
          Book(externalId: 'y', title: 'Chimica generale e inorganica'),
          Book(
            externalId: 'z',
            title: 'Fisica 1',
            catalogChoice: CatalogChoice.removed,
          ),
        ]) {
          await s.books.insert(b);
        }
      });
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exceptionAsString();
        if (text.contains('overflowed by') ||
            text.contains('consumes the entire tile width')) {
          errors.add(text.split('\n').first);
        } else {
          previous?.call(d);
        }
      };
      addTearDown(() => FlutterError.onError = previous);
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(_app(const BooksScreen(), false, services: s));
      await _settle(t);
      const steps = <(Size, double)>[
        (Size(360, 640), 1),
        (Size(1920, 1080), 2),
        (Size(360, 640), 2),
        (Size(1920, 1080), 1),
        (Size(1366, 768), 1.3),
        (Size(568, 320), 2),
        (Size(768, 1024), 1),
        (Size(1920, 1080), 2),
        (Size(320, 568), 1.3),
        (Size(1100, 800), 2),
        (Size(480, 800), 2),
        (Size(1920, 1080), 1.3),
      ];
      for (final (size, k) in steps) {
        final before = errors.length;
        t.view.physicalSize = size;
        t.platformDispatcher.textScaleFactorTestValue = k;
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        await _settle(t);
        for (var i = before; i < errors.length; i++) {
          errors[i] =
              '${size.width.toInt()}x${size.height.toInt()}, ×$k: ${errors[i]}';
        }
      }
      FlutterError.onError = previous;
      expect(errors.toSet(), isEmpty);
    });
  });

  group('formule', () {
    // Una formula in linea più larga della riga non si spezza: si
    // rimpicciolisce invece di uscire dal bordo.
    testWidgets('formula in linea più larga dello spazio', (t) async {
      final wide = List.generate(40, (i) => 'x_{$i}').join('+');
      await _forEachCombo(t, (size, k, dark, _) async {
        _what = '[MathText]';
        await t.pumpWidget(
          _app(
            Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: MathText(
                    'Se vale \$$wide=\\frac{a}{b}\$ allora \$x^2\$ resta uguale.',
                  ),
                ),
              ),
            ),
            dark,
          ),
        );
        await t.pump();
      });
    });
  });
}

/// Qualche giro per lasciar finire le letture dal database.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}
