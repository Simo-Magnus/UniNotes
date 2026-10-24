import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/academic/academic_year.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/features/courses/course_detail_screen.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/courses_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/exams/exam_form.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/exams/previous_years_screen.dart';
import 'package:university_notes/features/links/links_screen.dart';
import 'package:university_notes/features/notes/course_notes_screen.dart';
import 'package:university_notes/features/notes/notes_screen.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recently_deleted_screen.dart';
import 'package:university_notes/features/notes/transcript_search_screen.dart';
import 'package:university_notes/features/onboarding/onboarding_flow.dart';
import 'package:university_notes/features/reader/files_screen.dart';
import 'package:university_notes/features/settings/settings_screen.dart';
import 'package:university_notes/features/study/focus/focus_screen.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/study_sessions_tab.dart';
import 'package:university_notes/features/books/book_form.dart';
import 'package:university_notes/features/books/unsaved_books_dialog.dart';
import 'package:university_notes/features/cloud/incoming_files_host.dart';
import 'package:university_notes/features/courses/course_rename.dart';
import 'package:university_notes/core/router/error_screens.dart';
import 'package:university_notes/features/exams/exam_status.dart';
import 'package:university_notes/features/links/ai_assistants.dart';
import 'package:university_notes/features/links/microsoft_consent_sheet.dart';
import 'package:university_notes/features/notes/ai_request_dialog.dart';
import 'package:university_notes/features/notes/formula_dialog.dart';
import 'package:university_notes/features/notes/recorder/better_transcription.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/settings/dialogs/exclusion_confirm_dialog.dart';
import 'package:university_notes/features/settings/dialogs/text_edit_dialog.dart';
import 'package:university_notes/features/settings/erase_all.dart';
import 'package:university_notes/features/settings/logic/exclusion_cleanup.dart';
import 'package:university_notes/features/settings/widgets/async_action_button.dart';
import 'package:university_notes/features/study/course_catalog.dart';
import 'package:university_notes/features/study/focus/focus_cards.dart';
import 'package:university_notes/features/study/module_order_dialog.dart';
import 'package:university_notes/features/study/session_dialog.dart';
import 'package:university_notes/features/study/topic_dialog.dart';
import 'package:university_notes/features/study/topics_tab.dart';
import 'package:university_notes/widgets/common.dart';
import 'package:university_notes/widgets/copyable_text.dart';
import 'package:university_notes/features/notes/markdown_lite.dart';
import 'package:university_notes/features/notes/markdown_view.dart';
import 'package:university_notes/widgets/math_text.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/dashboard/dashboard_data.dart';
import 'package:university_notes/features/notes/background_jobs.dart';
import 'package:university_notes/features/study/minutes_bar_chart.dart';
import 'package:university_notes/features/study/study_stats.dart'
    hide formatMinutes;
import 'package:university_notes/features/study/study_widgets.dart';
import 'package:university_notes/widgets/glass.dart';
import 'package:university_notes/models/attachment.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/study.dart';

/// Prova «a tappeto» (secondo giro, categoria disegno/impaginazione/
/// risorse): apre le schermate principali con tre database (vuoto, pieno di
/// casi limite, con migliaia di righe) a 320×568 e 1920×1080, con caratteri
/// ×1 e ×3, e raccoglie ogni FlutterError. Le eccezioni vere (asserzioni,
/// vincoli non limitati, NaN…) fanno fallire il test; gli overflow di
/// RenderFlex sono solo un difetto d'aspetto e si riportano a parte.
/// Giri lunghi (tutte le combinazioni, migliaia di righe): `CRASH_R2_FULL=1`.
/// Nella suite normale bastano poche combinazioni, in pochi minuti.
final _full = Platform.environment['CRASH_R2_FULL'] == '1';

/// Quinto giro (R5-B): con `CRASH_R5_FULL=1` anche le finestre intermedie e
/// in orizzontale, con i caratteri fino al massimo dell'app (×2).
final _r5 = Platform.environment['CRASH_R5_FULL'] == '1';

/// Finestre aggiunte dal quinto giro (larghezza, altezza, caratteri).
const _r5Combos = <(double, double, double)>[
  (568, 320, 2),
  (360, 640, 1.3),
  (768, 1024, 2),
  (1366, 768, 2),
];

const _long =
    'Insegnamento dal nome lunghissimo con parole come '
    'Elettrotecnicaapplicataallemacchineelettricheeaisistemidipotenza e '
    'ancora altre parole per riempire tutte le righe disponibili';

const _hugeWord =
    'Supercalifragilistichespiralidosoelettrotecnicaapplicataallemacchine'
    'elettricheeaisistemidipotenzaperl\'ingegneriaedellenergiasostenibile';

enum _Data { vuoto, limite, enorme }

class _Env {
  _Env(this.s, this.tmp, this.courses);
  final AppServices s;
  final Directory tmp;
  final List<Course> courses;

  /// Il corso con più contenuti (per le schermate di dettaglio).
  Course get first => courses.first;
}

StudentProfile _profile() => StudentProfile(
  universityId: 'polito',
  universityName: 'Politecnico di Torino',
  universityShort: 'PoliTo',
  degreeId: 'deg1',
  degreeName: _long,
  degreeType: 'L',
  durationYears: 3,
  currentYear: 2,
  referenceAa: AcademicYear.tryParse('2026/27')!,
  startYear: 1,
);

Future<_Env> _build(_Data kind) async {
  final tmp = await Directory.systemTemp.createTemp('um_r2_');
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
  final base = AppServices(db);
  final s = AppServices(
    db,
    library: BookLibrary(baseDir: () async => tmp),
    materialsLibrary: BookLibrary(
      baseDir: () async => tmp,
      folderName: BookLibrary.materialsFolder,
    ),
    attachmentsLibrary: BookLibrary(
      baseDir: () async => tmp,
      folderName: BookLibrary.attachmentsFolder,
    ),
    notes: NotesStore(
      base.settings,
      root: () async => Directory(p.join(tmp.path, 'Appunti')),
    ),
  );
  if (kind == _Data.vuoto) return _Env(s, tmp, const []);

  await db.db.insert('universities', {
    'id': 'polito',
    'name': 'Politecnico di Torino',
    'short_name': 'PoliTo',
    'color': 0xFF1565C0,
  });
  await s.profiles.save(_profile(), now: DateTime(2026, 10, 4));
  await s.loadProfile();

  final n = kind == _Data.enorme ? 600 : 6;
  final now = DateTime.now();
  final ids = <int>[];
  // insegnamenti: CFU zero, infiniti, negativi, nomi lunghissimi
  for (var i = 0; i < n; i++) {
    final cfu = switch (i % 6) {
      0 => 0.0,
      1 => double.infinity,
      2 => -6.0,
      3 => 6.0,
      4 => double.nan,
      _ => 12.5,
    };
    ids.add(
      await s.courses.insert(
        Course(
          name: switch (i % 4) {
            0 => '$_long $i',
            1 => '$_hugeWord$i',
            2 => 'Fisica $i',
            _ => '',
          },
          degreeId: 'deg1',
          universityId: 'polito',
          year: [1, 2, 3, 0, -1, 99][i % 6],
          semester: ['1', '2', null, '', '1° semestre', 'annuale'][i % 6],
          cfu: cfu,
          difficulty: [null, 0.0, 5.0, 9.0, -2.0, 3.0][i % 6],
          status: CourseStatus.values[i % CourseStatus.values.length],
          description: i % 5 == 0 ? List.filled(80, _long).join('\n') : null,
          teacher: i % 3 == 0
              ? List.filled(40, 'Mario Rossi').join(', ')
              : null,
          code: i % 7 == 0 ? _hugeWord : null,
        ),
      ),
    );
  }
  final b = db.db.batch();
  for (var i = 0; i < ids.length; i++) {
    final c = ids[i];
    final examCount = kind == _Data.enorme ? 2 : 3;
    for (var k = 0; k < examCount; k++) {
      b.insert(
        'exams',
        Exam(
          courseId: c,
          date: [
            DateTime(1900, 1, 1),
            now.add(Duration(days: i % 400)),
            DateTime(2300, 12, 31),
            null,
            now.subtract(Duration(days: i % 900)),
          ][(i + k) % 5],
          time: ['99:99', '14:00', null, '', 'x'][(i + k) % 5],
          kind: ExamKind.values[(i + k) % ExamKind.values.length],
          status: ExamStatus.values[(i * 3 + k) % ExamStatus.values.length],
          grade: [null, 0, 18, 30, 31, 110, -5, 999][(i + k) % 8],
          laude: (i + k) % 7 == 0,
          cfu: [null, 0.0, 6.0, double.infinity, -1.0][(i + k) % 5],
          title: (i + k) % 3 == 0 ? _long : null,
          location: (i + k) % 4 == 0 ? _hugeWord : null,
          notes: (i + k) % 9 == 0 ? List.filled(60, _long).join('\n') : null,
        ).toMap()..remove('id'),
      );
    }
  }
  await b.commit(noResult: true);

  final mods = <int>[];
  final mb = db.db.batch();
  for (var i = 0; i < ids.length; i += kind == _Data.enorme ? 2 : 1) {
    for (var k = 0; k < 2; k++) {
      mb.insert(
        'modules',
        StudyModule(
          courseId: ids[i],
          name: k == 0 ? _long : 'Modulo $k',
          sort: i * 2 + k,
        ).toMap()..remove('id'),
      );
    }
  }
  await mb.commit(noResult: true);
  for (final r in await db.db.query('modules', columns: ['id'])) {
    mods.add(r['id']! as int);
  }
  final tb = db.db.batch();
  for (var i = 0; i < mods.length; i++) {
    for (var k = 0; k < 3; k++) {
      tb.insert(
        'topics',
        Topic(
          moduleId: mods[i],
          name: k == 0 ? _long : 'Argomento $k',
          status: TopicStatus.values[(i + k) % TopicStatus.values.length],
          notes: k == 1 ? r'Formula $\frac{a}{b}$ e $\sum_{i=0}^{n}$' : null,
          sort: k,
        ).toMap()..remove('id'),
      );
    }
  }
  await tb.commit(noResult: true);

  // sessioni: durata zero, enorme, fine prima dell'inizio, in ogni giorno
  final sb = db.db.batch();
  final sessions = kind == _Data.enorme ? 4000 : 6;
  for (var i = 0; i < sessions; i++) {
    final start = now.subtract(Duration(hours: i * 7 % 24000, minutes: i));
    final minutes = [0, 1, 30, 600, 100000, -5][i % 6];
    sb.insert(
      'study_sessions',
      StudySession(
        courseId: ids[i % ids.length],
        start: start,
        end: i % 5 == 0
            ? start.subtract(const Duration(minutes: 10))
            : start.add(Duration(minutes: minutes.abs())),
        durationMinutes: minutes,
        activityType: ActivityType.values[i % ActivityType.values.length],
        focus: i % 3 == 0,
        plannedMinutes: i % 4 == 0 ? 0 : 25,
      ).toMap()..remove('id'),
    );
  }
  await sb.commit(noResult: true);

  // libri e materiali
  final bb = db.db.batch();
  final books = kind == _Data.enorme ? 1500 : 6;
  for (var i = 0; i < books; i++) {
    bb.insert(
      'books',
      Book(
        courseId: i % 5 == 0 ? null : ids[i % ids.length],
        title: i % 2 == 0 ? '$_long $i' : 'Libro $i',
        author: i % 3 == 0 ? _hugeWord : null,
        format: BookFormat.values[i % BookFormat.values.length],
        ownership: BookOwnership.values[i % BookOwnership.values.length],
        required: [true, false, null][i % 3],
        lastPage: [null, 0, 5, 99999][i % 4],
        pageCount: [null, 0, 300, 3][i % 4],
        storedFile: i % 7 == 0 ? 'inesistente$i.pdf' : null,
      ).toMap()..remove('id'),
    );
    bb.insert(
      'materials',
      StudyMaterial(
        courseId: ids[i % ids.length],
        title: i % 2 == 0 ? _long : 'Dispensa $i',
        kind: MaterialKind.values[i % MaterialKind.values.length],
        lastPage: [null, 0, 5, 99999][i % 4],
        pageCount: [null, 0, 300, 3][i % 4],
      ).toMap()..remove('id'),
    );
  }
  await bb.commit(noResult: true);
  if (mods.isNotEmpty) {
    final ab = db.db.batch();
    for (var i = 0; i < (kind == _Data.enorme ? 500 : 3); i++) {
      ab.insert(
        'attachments',
        Attachment(
          moduleId: mods[i % mods.length],
          title: i % 2 == 0 ? _long : 'Allegato $i',
          path: '/non/esiste/$i.pdf',
          createdAt: now,
          kinds: {AttachmentKind.values[i % 3]},
        ).toMap()..remove('id'),
      );
    }
    await ab.commit(noResult: true);
  }

  // appunti del primo corso (e di qualcuno in più)
  final courses = await s.courses.all();
  for (final c in courses.take(kind == _Data.enorme ? 5 : 2)) {
    final files = kind == _Data.enorme && c == courses.first ? 400 : 3;
    for (var i = 0; i < files; i++) {
      final t = DateTime(2026, 1, 1).add(Duration(hours: i * 5));
      final rec = await s.notes.newRecordingPath(c, t, '.flac');
      await File(rec).writeAsBytes(List.filled(64, 0));
      await s.notes.writeText(
        c,
        NoteFolder.transcripts,
        p.basenameWithoutExtension(rec),
        '# Trascrizione\n\n${List.filled(30, _long).join('\n\n')}',
      );
      await s.notes.writeText(
        c,
        NoteFolder.summaries,
        p.basenameWithoutExtension(rec),
        '# Riassunto\n\n==chiave== ${List.filled(10, _hugeWord).join(' ')}',
      );
      await s.notes.writeText(c, NoteFolder.notes, 'Nota $i $_hugeWord', 'x');
    }
  }
  return _Env(s, tmp, courses);
}

class _Err {
  _Err(this.where, this.details)
    : overflow = details.exceptionAsString().contains('overflowed by') {
    // la descrizione completa si legge subito, finché gli elementi ci sono
    // ancora (dopo la chiusura della schermata non si può più)
    var text = '';
    if (overflow) {
      try {
        text = details.toDiagnosticsNode().toStringDeep();
      } catch (_) {
        text = details.exceptionAsString();
      }
    }
    deep = text;
  }

  final String where;
  final FlutterErrorDetails details;
  final bool overflow;

  /// Descrizione completa (solo per gli overflow).
  late final String deep;

  /// Catena dei widget attorno al RenderFlex che esce dallo spazio.
  String get creator {
    final i = deep.indexOf('creator:');
    if (i < 0) return '?';
    final end = i + 170 > deep.length ? deep.length : i + 170;
    return deep
        .substring(i + 9, end)
        .split('\n')
        .map((l) => l.trim())
        .join(' ');
  }

  String get summary {
    final text = details.exceptionAsString().split('\n').first;
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}

class _Run {
  _Run(this.tester, this.env, this.width, this.height, this.scale);
  final WidgetTester tester;
  final _Env env;
  final double width, height, scale;
  final errors = <_Err>[];
  final slow = <String>[];
  String where = '';

  /// Tempo speso a costruire e disegnare (senza le attese sul database).
  final pumpWatch = Stopwatch();

  Future<void> settle([int n = 6, int ms = 40]) async {
    for (var i = 0; i < n; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      pumpWatch.start();
      await tester.pump();
      pumpWatch.stop();
    }
  }

  Future<void> show(String name, Widget screen, {int rounds = 6}) async {
    where = name;
    pumpWatch
      ..reset()
      ..start();
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: env.s,
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('it', 'IT'),
          supportedLocales: const [Locale('it', 'IT')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // come in main.dart: la scala del sistema non va oltre ×2
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: AppTextScaler(media.textScaler, 1),
              ),
              child: child!,
            );
          },
          home: screen,
        ),
      ),
    );
    pumpWatch.stop();
    await settle(rounds);
    if (pumpWatch.elapsedMilliseconds > 800) {
      slow.add('$name: ${pumpWatch.elapsedMilliseconds} ms');
    }
  }

  Future<void> clear() async {
    where = 'chiusura';
    await tester.pumpWidget(const SizedBox());
    await settle(2);
  }

  /// Tocca il primo testo [label], se c'è, e attende.
  Future<void> tapText(String label) async {
    final f = find.text(label);
    if (f.evaluate().isEmpty) return;
    where = '$where / $label';
    await tester.ensureVisible(f.first);
    await tester.tap(f.first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(4);
  }

  /// Scorre il primo elemento scorrevole fino in fondo e ritorno.
  Future<void> scrollAll() async {
    final s = find.byType(Scrollable);
    if (s.evaluate().isEmpty) return;
    where = '$where / scorri';
    try {
      await tester.fling(s.first, const Offset(0, -3000), 5000);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.fling(s.first, const Offset(0, 3000), 5000);
      await tester.pump(const Duration(milliseconds: 300));
    } catch (_) {}
    await settle(3);
  }
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  void Function(FlutterErrorDetails)? previous;

  final combos = <(double, double, double)>[
    if (_full) (320, 568, 1),
    (320, 568, 3),
    (1920, 1080, 1),
    if (_full) (1920, 1080, 3),
    if (_r5) ..._r5Combos,
  ];

  for (final data in _full ? _Data.values : const [_Data.limite]) {
    for (final (w, h, scale) in combos) {
      testWidgets(
        '${data.name}, ${w.toInt()}x${h.toInt()}, caratteri ×$scale',
        (tester) async {
          tester.view.physicalSize = Size(w, h);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final env = (await tester.runAsync(() => _build(data)))!;
          addTearDown(() async {
            await tester.runAsync(env.s.database.close);
            try {
              env.tmp.deleteSync(recursive: true);
            } catch (_) {}
          });
          final run = _Run(tester, env, w, h, scale);
          previous = FlutterError.onError;
          FlutterError.onError = (d) => run.errors.add(_Err(run.where, d));
          addTearDown(() => FlutterError.onError = previous);

          final c = env.courses.isEmpty ? null : env.first;
          final exams = (await tester.runAsync(env.s.exams.all))!;
          final screens = <(String, Widget Function())>[
            ('AppShell', () => const AppShell()),
            ('Dashboard', () => const DashboardScreen()),
            ('Insegnamenti', () => const CoursesScreen()),
            ('Esami', () => const ExamsScreen()),
            ('Studio', () => const StudyScreen()),
            ('Sessioni', () => const StudySessionsPage()),
            ('Libri', () => const BooksScreen()),
            ('Appunti', () => const NotesScreen()),
            ('Cestino appunti', () => const RecentlyDeletedScreen()),
            ('Cerca trascrizioni', () => const TranscriptSearchScreen()),
            ('File', () => const FilesScreen()),
            ('Collegamenti', () => const LinksScreen()),
            ('Impostazioni', () => const SettingsScreen()),
            ('Anni precedenti', () => const PreviousYearsScreen()),
            ('Focus', () => const FocusScreen()),
            ('Onboarding', () => const OnboardingFlow()),
            ('Voti anno 1', () => const YearGradesScreen(year: 1)),
            ('Voti anno 2', () => const YearGradesScreen(year: 2)),
            ('Modulo esame', () => const ExamFormPage()),
            ('Modulo insegnamento', () => const CourseFormPage()),
            if (c != null) ...[
              (
                'Dettaglio insegnamento',
                () => CourseDetailScreen(courseId: c.id!),
              ),
              (
                'Modulo insegnamento (modifica)',
                () => CourseFormPage(course: c),
              ),
              ('Appunti del corso', () => CourseNotesScreen(course: c)),
            ],
            for (final e in exams.take(_full ? 8 : 2))
              (
                'Dettaglio esame ${e.id}',
                () => ExamDetailScreen(examId: e.id!),
              ),
            for (final e in exams.take(_full ? 4 : 1))
              ('Modulo esame ${e.id}', () => ExamFormPage(exam: e)),
          ];
          for (final (name, build) in screens) {
            await run.show(name, build(), rounds: data == _Data.enorme ? 8 : 6);
            await run.scrollAll();
            await run.clear();
          }

          // schede delle schermate a schede, con i dati
          for (final (name, build, tabs)
              in <(String, Widget Function(), List<String>)>[
                (
                  'Esami',
                  () => const ExamsScreen(),
                  ['Sostenuti', 'Medie', 'Da sostenere'],
                ),
                (
                  'Studio',
                  () => const StudyScreen(),
                  ['Sessioni Studio', 'Statistiche'],
                ),
              ]) {
            await run.show(name, build());
            for (final t in tabs) {
              await run.tapText(t);
              await run.scrollAll();
            }
            await run.clear();
          }

          // la shell con tutte le sezioni
          await run.show('AppShell', const AppShell());
          for (final t in ['Esami', 'Studio', 'Libri', 'Appunti', 'Home']) {
            await run.tapText(t);
            await run.scrollAll();
          }
          await run.clear();

          // le ultime letture in corso finiscono prima di chiudere il database
          await run.settle(_full ? 40 : 12);
          final real = run.errors.where((e) => !e.overflow).toList();
          final over = run.errors.where((e) => e.overflow).toList();
          final report = StringBuffer();
          final seen = <String>{};
          for (final e in real) {
            if (seen.add('${e.where}|${e.summary}')) {
              report.writeln('[${e.where}] ${e.summary}');
            }
          }
          final overSeen = <String>{};
          for (final e in over) {
            final at = RegExp(r'app/(lib/[\w/]+\.dart:\d+)')
                .firstMatch(e.deep.replaceAll(r'\', '/'));
            overSeen.add(
              '${e.where.split(' / ').first}@${at?.group(1) ?? e.creator}',
            );
          }
          // ignore: avoid_print
          print(
            'RIEPILOGO ${data.name} ${w.toInt()}x${h.toInt()} ×$scale: '
            '${real.length} eccezioni, overflow in: ${overSeen.join(', ')}; '
            'lente: ${run.slow.join('; ')}',
          );
          FlutterError.onError = previous;
          // ignore: avoid_print
          if (real.isNotEmpty) print('ECCEZIONI:\n$report');
          expect(real, isEmpty, reason: report.toString());
          // con i caratteri al massimo dell'app (×2) niente deve uscire dallo
          // spazio; nel giro lungo gli overflow si riportano soltanto
          if (!_full) {
            expect(
              overSeen,
              isEmpty,
              reason:
                  'RenderFlex fuori misura (320 px o 1920 px, caratteri ×2)',
            );
          }
        },
        timeout: Timeout(Duration(minutes: _full ? 30 : 3)),
      );
    }
  }

  _dialogTests();
  _deepTests();
  _regressionTests();
}

/// Contesto della finestra di prova per aprire riquadri e fogli.
BuildContext? _hostContext;

class _DialogHost extends StatelessWidget {
  const _DialogHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Builder(
      builder: (c) {
        _hostContext = c;
        return const SizedBox();
      },
    ),
  );
}

void _dialogTests() {
  for (final (w, h, scale) in <(double, double, double)>[
    if (_full) (320, 568, 1),
    (320, 568, 3),
    if (_full) (1920, 1080, 1),
    if (_r5) ..._r5Combos,
  ]) {
    testWidgets(
      'riquadri e fogli, ${w.toInt()}x${h.toInt()}, caratteri ×$scale',
      (tester) async {
        tester.view.physicalSize = Size(w, h);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final env = (await tester.runAsync(
          () => _build(_full ? _Data.enorme : _Data.limite),
        ))!;
        addTearDown(() async {
          await tester.runAsync(env.s.database.close);
          try {
            env.tmp.deleteSync(recursive: true);
          } catch (_) {}
        });
        final run = _Run(tester, env, w, h, scale);
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => run.errors.add(_Err(run.where, d));
        addTearDown(() => FlutterError.onError = previous);

        final catalog = (await tester.runAsync(
          () => CourseCatalog.load(env.s),
        ))!;
        final exams = (await tester.runAsync(env.s.exams.all))!;
        final modules = (await tester.runAsync(
          () => env.s.study.modules(env.first.id!),
        ))!;
        final longModules = [
          for (var i = 0; i < 300; i++)
            StudyModule(id: i + 1, courseId: env.first.id!, name: '$_long $i'),
        ];
        final session = StudySession(
          courseId: env.first.id!,
          start: DateTime(2026, 1, 1),
          end: DateTime(2025, 1, 1),
          durationMinutes: 100000,
          activityType: ActivityType.theory,
        );
        Future<Object?> dlg(BuildContext c, Widget d) =>
            showDialog<Object?>(context: c, builder: (_) => d);
        Future<Object?> page(BuildContext c, Widget d) =>
            Navigator.of(c)
                .push<Object?>(MaterialPageRoute<Object?>(builder: (_) => d));
        final dialogs = <(String, Future<Object?> Function(BuildContext))>[
          (
            'confirmDialog',
            (c) => confirmDialog(c, _long, '$_long\n$_hugeWord $_long'),
          ),
          (
            'showTextEditDialog',
            (c) => showTextEditDialog(
              c,
              title: _long,
              initialValue: _long * 3,
              label: _long,
              hint: _long,
              helper: _long,
              presets: [
                for (var i = 0; i < 12; i++) (label: '$_long $i', value: '$i'),
              ],
            ),
          ),
          (
            'askTwoChoices',
            (c) => askTwoChoices(
              c,
              title: _long,
              body: '$_long $_long',
              no: _long,
              yes: _hugeWord,
              danger: true,
            ),
          ),
          (
            'showErrorDialog',
            (c) => showErrorDialog(
              c,
              _long,
              Exception(_long * 8),
            ).then<Object?>((_) => null),
          ),
          (
            'showPromptDialog',
            (c) => showPromptDialog(
              c,
              title: _long,
              intro: _long,
              prompt: _long * 30,
            ).then<Object?>((_) => null),
          ),
          (
            'showNoteDialog',
            (c) =>
                showNoteDialog(c, title: _long, name: _long, note: _long * 5),
          ),
          (
            'showFormulaDialog',
            (c) => showFormulaDialog(c, initial: _long * 20),
          ),
          (
            'showSessionDialog',
            (c) => showSessionDialog(c, catalog: catalog, session: session),
          ),
          (
            'showSessionDialog nuova',
            (c) => showSessionDialog(c, catalog: catalog),
          ),
          (
            'showBetterTranscriptionDialog',
            (c) => showBetterTranscriptionDialog(
              c,
              model: _hugeWord,
              eta: const Duration(days: 4000),
              liveBy: _long,
            ),
          ),
          (
            'showBetterTranscriptionDialog eta negativa',
            (c) => showBetterTranscriptionDialog(
              c,
              model: 'small',
              eta: const Duration(minutes: -5),
            ),
          ),
          ('askSaveRecording', askSaveRecording),
          (
            'confirmDeleteRecording',
            (c) => confirmDeleteRecording(c, name: _long, inProgress: true),
          ),
          ('askFinishFocus', askFinishFocus),
          ('editDailyGoal', (c) => editDailyGoal(c).then<Object?>((_) => null)),
          (
            'showModuleOrderDialog',
            (c) => showModuleOrderDialog(
              c,
              modules: longModules,
              selectedId: 5,
            ).then<Object?>((_) => null),
          ),
          (
            'showModuleOrderDialog vuoto',
            (c) => showModuleOrderDialog(
              c,
              modules: const [],
            ).then<Object?>((_) => null),
          ),
          (
            'showModuleOrderDialog reale',
            (c) => showModuleOrderDialog(
              c,
              modules: modules,
              selectedId: 99999,
            ).then<Object?>((_) => null),
          ),
          ('pickCourse', (c) => pickCourse(c, catalog, env.first.id)),
          ('pickCourse sconosciuto', (c) => pickCourse(c, catalog, 987654321)),
          for (final e in exams.take(3))
            ('changeExamStatus ${e.id}', (c) => changeExamStatus(c, e)),
          ('renameCourseDialog', (c) => renameCourseDialog(c, env.first)),
          (
            'showUniversityBlockedSheet',
            (c) => showUniversityBlockedSheet(
              c,
              clientId: _hugeWord,
              declined: true,
            ),
          ),
          (
            'showAdminRequestSheet',
            (c) => showAdminRequestSheet(
              c,
              clientId: _hugeWord,
            ).then<Object?>((_) => null),
          ),
          (
            'confirmDeleteUnsavedBooks',
            (c) => confirmDeleteUnsavedBooks(c, course: _long, count: 99999),
          ),
          (
            'showIncomingDestinationDialog',
            (c) => showIncomingDestinationDialog(c, count: 3, title: _long),
          ),
          (
            'showAiRequestDialog',
            (c) => showAiRequestDialog(
              c,
              title: _long,
              ai: ReferenceAi.values.first,
              prompt: _long * 40,
              intro: _long,
              steps: [for (var i = 0; i < 8; i++) _long],
            ).then<Object?>((_) => null),
          ),
          (
            'showBookForm',
            (c) => showBookForm(
              c,
              catalog: catalog,
              book: Book(title: _long, author: _hugeWord, notes: _long * 50),
            ),
          ),
          ('showBookForm nuovo', (c) => showBookForm(c, catalog: catalog)),
          ('openExamForm', (c) => openExamForm(c)),
          ('openCourseForm', (c) => openCourseForm(c)),
          (
            'GradeDialog',
            (c) => dlg(
              c,
              const GradeDialog(
                midterm: false,
                status: ExamStatus.passed,
                grade: 999,
                laude: true,
                title: _long,
              ),
            ),
          ),
          (
            'GradeDialog itinere',
            (c) => dlg(
              c,
              const GradeDialog(
                midterm: true,
                status: ExamStatus.taken,
                grade: -3,
              ),
            ),
          ),
          (
            'GoToDialog',
            (c) => dlg(c, const GoToDialog(label: _long, current: 0, count: 0)),
          ),
          (
            'GoToDialog grande',
            (c) => dlg(
              c,
              const GoToDialog(label: 'Pagina', current: 99999, count: 3),
            ),
          ),
          (
            'SupportedFormatsDialog',
            (c) => dlg(c, const SupportedFormatsDialog()),
          ),
          (
            'showExclusionConfirmDialog',
            (c) => showExclusionConfirmDialog(
              c,
              ExclusionMatches(
                courses: [for (var i = 0; i < 200; i++) ExcludedItem(i, _long)],
                events: [
                  for (var i = 0; i < 50; i++) ExcludedItem(i, _hugeWord),
                ],
                exams: const [],
              ),
            ),
          ),
          (
            'AppErrorWidget',
            (c) => page(
              c,
              AppErrorWidget(
                details: FlutterErrorDetails(
                  exception: Exception(_long * 30),
                  stack: StackTrace.current,
                ),
              ),
            ),
          ),
          (
            'AppErrorWidget senza dettagli',
            (c) => page(c, const AppErrorWidget()),
          ),
          (
            'StartupErrorApp',
            (c) => page(
              c,
              StartupErrorApp(
                error: Exception(_long * 30),
                onRetry: () async {},
              ),
            ),
          ),
        ];
        for (final (name, open) in dialogs) {
          await run.show('host', const _DialogHost());
          run.where = name;
          final ctx = _hostContext!;
          final f = open(ctx);
          unawaited(
            f.then<void>(
              (_) {},
              onError: (Object e, StackTrace st) {
                run.errors.add(
                  _Err(name, FlutterErrorDetails(exception: e, stack: st)),
                );
              },
            ),
          );
          await run.settle(6);
          // chiude tutto quello che si è aperto
          final nav = tester.state<NavigatorState>(
            find.byType(Navigator).first,
          );
          nav.popUntil((r) => r.isFirst);
          await run.settle(4);
          // timer brevi rimasti dopo la chiusura (attese di mezzo secondo)
          await tester.pump(const Duration(seconds: 2));
        }
        await run.clear();
        await run.settle(12);
        final real = run.errors.where((e) => !e.overflow).toList();
        final over = run.errors.where((e) => e.overflow).toList();
        final report = StringBuffer();
        final seen = <String>{};
        for (final e in real) {
          if (seen.add('${e.where}|${e.summary}')) {
            report.writeln('[${e.where}] ${e.summary}');
          }
        }
        final overSeen = <String>{};
        for (final e in over) {
          final at = RegExp(r'app/(lib/[\w/]+\.dart:\d+)')
              .firstMatch(e.deep.replaceAll(r'\', '/'));
          overSeen.add('${e.where}@${at?.group(1) ?? e.creator}');
        }
        // ignore: avoid_print
        print(
          'RIEPILOGO riquadri ${w.toInt()}x${h.toInt()} ×$scale: '
          '${real.length} eccezioni, overflow in: ${overSeen.join(', ')}',
        );
        FlutterError.onError = previous;
        // ignore: avoid_print
        if (real.isNotEmpty) print('ECCEZIONI:\n$report');
        expect(real, isEmpty, reason: report.toString());
      },
      timeout: Timeout(Duration(minutes: _full ? 30 : 3)),
    );
  }
}

/// Ricorsioni profonde e testi enormi (appunti, trascrizioni, risposte
/// dell'AI): niente eccezioni non gestite né attese infinite.
void _deepTests() {
  // dimensioni ridotte nella suite normale: i casi estremi veri (centinaia di migliaia di
  // caratteri) sono nel giro lungo, CRASH_R2_FULL=1
  int sz(int v) => v ~/ (_full ? 4 : 40);
  final inputs = <String, String>{
    'graffe annidate': [('{' * sz(20000)), 'x', ('}' * sz(20000))].join(),
    'frazioni annidate': [
      List.filled(sz(3000), r'\frac{1}{').join(),
      'x',
      '}' * sz(3000),
    ].join(),
    'radici annidate': [
      List.filled(sz(3000), r'\sqrt{').join(),
      'x',
      '}' * sz(3000),
    ].join(),
    'apici annidati': [
      List.filled(sz(5000), 'x^{').join(),
      '1',
      '}' * sz(5000),
    ].join(),
    'comando senza fine': r'\frac' * sz(20000),
    'solo dollari': r'$' * sz(100000),
    'solo asterischi': '*' * sz(200000),
    'grassetti annidati': '**a ' * sz(50000),
    'quote annidate': ['> ' * sz(20000), 'x'].join(),
    'elenco rientrato': [
      for (var i = 0; i < sz(3000); i++) '${'  ' * i}- voce $i',
    ].join('\n'),
    'riga di un megabyte': 'parola ' * sz(150000),
    'righe di soli simboli': '- ' * sz(100000),
    'trattini separati': ['- ' * sz(5000), 'x'].join(),
    'blocchi di formula non chiusi': List.filled(sz(20000), r'$$ x').join('\n'),
    'titoli': List.filled(sz(50000), '# titolo').join('\n'),
    'codice non chiuso': '```\n${List.filled(sz(50000), 'riga').join('\n')}',
    'link annidati': '[a](' * sz(10000),
    'caratteri di controllo': String.fromCharCodes([
      for (var i = 0; i < sz(50000); i++) i % 32,
    ]),
  };
  for (final e in inputs.entries) {
    test('parseMarkdown: ${e.key}', () {
      final sw = Stopwatch()..start();
      parseMarkdown(e.value);
      expect(
        sw.elapsedMilliseconds,
        lessThan(8000),
        reason: 'troppo lento: ${sw.elapsedMilliseconds} ms',
      );
    });
  }
  testWidgets('MathFormula e MarkdownLiteView con testi profondi', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);
    for (final e in inputs.entries) {
      for (final body in <Widget>[
        MathFormula(e.value),
        MathBlock(e.value),
        MarkdownLiteView(e.value),
        MarkdownLiteView('\$\$ ${e.value} \$\$\n\ntesto \$${e.value}\$ fine'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: body)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    await tester.pumpWidget(const SizedBox());
    FlutterError.onError = previous;
    // le formule in linea molto larghe escono dalla riga (solo aspetto)
    final real = [
      for (final d in errors)
        if (!d.exceptionAsString().contains('overflowed by'))
          d.exceptionAsString().split('\n').first,
    ];
    expect(real, isEmpty, reason: real.take(10).join('\n'));
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// Regressioni dei casi trovati dalla prova a tappeto (ognuno era rosso
/// prima della correzione).
void _regressionTests() {
  testWidgets('CourseDropdown: insegnamento nascosto dal filtro', (
    tester,
  ) async {
    final a = Course(id: 1, name: 'A');
    final b = Course(id: 2, name: 'B');
    // B esiste (byId) ma non è tra i corsi mostrati: il menù non può avere
    // B come valore, altrimenti si rompe
    final catalog = CourseCatalog([a, b], const [], visible: (c) => c.id == 1);
    expect(catalog.byId.containsKey(2), isTrue);
    expect(catalog.courses.map((c) => c.id), [1]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseDropdown(
            catalog: catalog,
            value: 2,
            label: 'Materia',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'topicsByCourse: stessi argomenti e stesso ordine di topicsOfCourse',
    () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      final ids = [
        for (var i = 0; i < 4; i++) await s.courses.insert(Course(name: 'C$i')),
      ];
      for (final c in ids.take(3)) {
        for (var m = 0; m < 2; m++) {
          final mid = await s.study.insertModule(
            StudyModule(courseId: c, name: 'M$m', sort: 5 - m),
          );
          for (var t = 0; t < 3; t++) {
            await s.study.insertTopic(
              Topic(moduleId: mid, name: 'T$t', sort: 3 - t),
            );
          }
        }
      }
      final all = await s.study.topicsByCourse();
      expect(all.keys.toSet(), ids.take(3).toSet());
      for (final c in ids) {
        final one = await s.study.topicsOfCourse(c);
        expect(
          (all[c] ?? const <Topic>[]).map((t) => t.id).toList(),
          one.map((t) => t.id).toList(),
        );
      }
    },
  );

  test('NotesStore.count: stesso numero di file di list', () async {
    final tmp = await Directory.systemTemp.createTemp('um_r2_count_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final s = AppServices(db);
    final store = NotesStore(s.settings, root: () async => tmp);
    final c = Course(id: 1, name: 'Analisi');
    expect(await store.count(c), 0);
    for (var i = 0; i < 4; i++) {
      final rec = await store.newRecordingPath(
        c,
        DateTime(2026, 1, 1 + i),
        '.flac',
      );
      await File(rec).writeAsBytes([1, 2, 3]);
      await File(p.setExtension(rec, '.json')).writeAsString('{}');
      await File('$rec.part').writeAsBytes([0]);
    }
    await store.writeText(c, NoteFolder.notes, 'Nota', 'x');
    await store.writeText(c, NoteFolder.summaries, 'Riassunto', 'x');
    final listed = (await store.list(c)).values
        .fold<int>(0, (a, l) => a + l.length);
    expect(listed, 6);
    expect(await store.count(c), listed);
  });

  testWidgets('EmptyState in poco spazio con caratteri grandi', (tester) async {
    tester.view.physicalSize = const Size(320, 300);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 160,
            child: EmptyState(
              icon: Icons.event,
              message: 'Nessun esame in programma: aggiungine uno.',
              action: FilledButton(
                onPressed: () {},
                child: const Text('Aggiungi'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('foglio «Stato» della prova con caratteri grandi', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = (await tester.runAsync(AppDatabase.openInMemory))!;
    addTearDown(() => tester.runAsync(db.close));
    final s = AppServices(db);
    late BuildContext ctx;
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    unawaited(
      changeExamStatus(ctx, Exam(courseId: 1, status: ExamStatus.planned)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  test('avanzamenti non numerici diventano indeterminati', () async {
    expect(const WhisperProgress('x', double.nan).fraction, isNull);
    expect(const WhisperProgress('x', double.infinity).fraction, isNull);
    expect(const WhisperProgress('x', 2.5).fraction, 1);
    expect(const WhisperProgress('x', -1).fraction, 0);
    expect(const WhisperProgress('x', 0.25).fraction, 0.25);
    expect(const WhisperProgress('x', null).fraction, isNull);
    final jobs = BackgroundJobs();
    final seen = <double?>[];
    final done = Completer<void>();
    jobs.start('prova', (report) async {
      for (final v in [double.nan, double.negativeInfinity, 7.0, 0.5]) {
        report('fase', v);
        seen.add(jobs.all.single.fraction);
      }
      done.complete();
      return null;
    });
    await done.future;
    expect(seen, [null, null, 1.0, 0.5]);
  });

  testWidgets('formula lunghissima: resta testo, senza bloccare', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sw = Stopwatch()..start();
    final tex = 'x+' * (kMaxFormulaChars);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: MathFormula(tex))),
      ),
    );
    expect(find.textContaining('x+x+x+'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(sw.elapsedMilliseconds, lessThan(4000));
  });

  test('formatMinutes con durata negativa', () {
    expect(formatMinutes(-5), '0 min');
    expect(formatMinutes(125), '2 h 5 min');
  });

  testWidgets('istogramma e anello con valori fuori scala', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sw = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MinutesBarChart(
                totals: [
                  PeriodTotal(DateTime(2026, 1, 1), 1 << 40),
                  PeriodTotal(DateTime(2026, 1, 2), -50),
                  PeriodTotal(DateTime(2026, 1, 3), 0),
                ],
                labelOf: (d) => '${d.day}',
                tooltipOf: (d) => '${d.day}',
                color: Colors.blue,
              ),
              const ProgressRing(value: double.nan, label: 'x'),
              const ProgressRing(value: double.infinity, label: 'y'),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
