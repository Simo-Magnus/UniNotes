import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/utils/parse.dart';

Future<AppServices> _seed() async {
  final db = await AppDatabase.openInMemory();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  await db.db.insert('universities', {
    'id': 'polito',
    'name': 'Politecnico di Torino',
    'short_name': 'PoliTo',
    'color': 0xFF1565C0,
  });
  await db.db.insert('universities', {
    'id': 'unito',
    'name': 'Università di Torino',
    'short_name': 'UniTO',
    'color': 0xFFC62828,
  });
  final c1 = await db.db.insert('courses', {
    'name': 'Analisi matematica I',
    'university_id': 'polito',
    'teacher': 'Prof. Rossi',
  });
  final c2 = await db.db.insert('courses', {
    'name': 'Psicologia generale',
    'university_id': 'unito',
  });
  Future<void> ev(
    int? course,
    String uni,
    String title,
    int h,
    int m,
    int dur, {
    String type = 'lecture',
    int dayOffset = 0,
    bool allDay = false,
  }) async {
    final s = DateTime(today.year, today.month, today.day + dayOffset, h, m);
    await db.db.insert('events', {
      'course_id': course,
      'university_id': uni,
      'type': type,
      'title': title,
      'start_at': isoLocal(s),
      'end_at': isoLocal(
        allDay
            ? DateTime(s.year, s.month, s.day + 1)
            : s.add(Duration(minutes: dur)),
      ),
      'all_day': allDay ? 1 : 0,
      'room': 'Aula 1',
      'building': 'Sede centrale',
    });
  }

  await ev(c1, 'polito', 'Analisi matematica I', 8, 30, 90);
  await ev(c2, 'unito', 'Psicologia generale', 9, 0, 120);
  await ev(c2, 'unito', 'Psicologia (laboratorio)', 9, 30, 60);
  await ev(
    c1,
    'polito',
    'Esame Analisi disponibile',
    0,
    0,
    0,
    type: 'exam_window',
    dayOffset: 1,
    allDay: true,
  );
  await ev(
    null,
    'polito',
    'Scadenza iscrizione',
    23,
    0,
    30,
    type: 'deadline',
    dayOffset: 2,
  );
  await db.db.insert('exams', {
    'course_id': c1,
    'kind': 'midterm',
    'title': 'Prima prova in itinere',
    'date': isoDate(today.add(const Duration(days: 3))),
    'time': '14:00',
    'status': 'planned',
    'topics': 'Limiti e derivate',
    'study_materials': jsonEncode(['Lezioni 1-8', r'D:\Materiale\L01.pdf']),
  });
  final module = await db.db.insert('modules', {'course_id': c1, 'name': 'M1'});
  await db.db.insert('topics', {
    'module_id': module,
    'name': 'Limiti',
    'status': 'completed',
  });
  await db.db.insert('topics', {
    'module_id': module,
    'name': 'Derivate',
    'status': 'not_started',
  });
  await db.db.insert('study_sessions', {
    'course_id': c1,
    'start_at': isoLocal(today.add(const Duration(hours: 7))),
    'duration_minutes': 90,
    'activity_type': 'exercises',
  });
  return AppServices(db);
}

Future<void> _pumpApp(
  WidgetTester tester,
  AppServices services,
  Widget home,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: services,
        child: MaterialApp(
          locale: const Locale('it', 'IT'),
          supportedLocales: const [Locale('it', 'IT')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: home,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  // le card caricano i loro dati (obiettivo di oggi) dopo la Home
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  await tester.pump();
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  for (final (label, size) in [
    ('smartphone', const Size(400, 860)),
    ('desktop', const Size(1400, 900)),
  ]) {
    testWidgets('home con dati ($label)', (tester) async {
      final services = await tester.runAsync(_seed);
      addTearDown(() => tester.runAsync(() => services!.database.close()));
      await _pumpApp(tester, services!, const DashboardScreen(), size);
      // «Inizia»: studio di oggi, Sessione Studio, Registra lezione; niente
      // più AI di riferimento
      expect(find.text('Inizia'), findsOneWidget);
      expect(find.byKey(const Key('home-today')), findsOneWidget);
      expect(find.byKey(const Key('home-study')), findsOneWidget);
      expect(find.byKey(const Key('home-record')), findsOneWidget);
      expect(find.text('Apri ChatGPT'), findsNothing);
      expect(find.textContaining('AI di riferimento'), findsNothing);
      // minuti di oggi dalle sessioni salvate (90 min, obiettivo 1 h)
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('home-today')),
          matching: find.text('Oggi 1 h 30 min'),
        ),
        findsOneWidget,
      );
      expect(find.text('Obiettivo raggiunto (1 h)'), findsOneWidget);
      // niente pulsante «Obiettivo»: si tocca il riquadro di oggi
      expect(find.text('Obiettivo'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-today')),
          matching: find.byKey(const Key('home-goal-edit')),
        ),
        findsOneWidget,
      );
      // niente più scritte blu con il nome della sezione nelle card: si
      // tocca la card intera
      for (final section in ['Esami', 'Studio', 'Registra', 'Libri']) {
        expect(
          find.widgetWithText(TextButton, section),
          findsNothing,
          reason: section,
        );
      }
      // niente «Cambia corso» nella Home (è nelle Impostazioni) né selettore
      // dell'anno nella barra in alto
      expect(find.text('Cambia corso'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const Key('year-selector')),
        ),
        findsNothing,
      );
      // prossime prove con lo stato semplificato
      expect(find.text('Prossime prove'), findsOneWidget);
      expect(find.text('Prima prova in itinere'), findsOneWidget);
      expect(find.text('Da prenotare'), findsOneWidget);
      // niente «Materiali da studiare» nelle prossime prove
      expect(find.text('Materiali da studiare'), findsNothing);
      expect(find.text('Lezioni 1-8'), findsNothing);
      expect(find.text('Argomenti: Limiti e derivate'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Moduli e argomenti'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('1/2 argomenti completati'), findsOneWidget);
      // una sola suddivisione (qui senza semestre): niente menu
      expect(find.text('Semestre non indicato'), findsOneWidget);
      expect(find.byKey(const Key('progress-group')), findsNothing);
      expect(find.text('Ultime registrazioni'), findsOneWidget);
      // niente card dei Libri
      expect(
        find.textContaining('Nessun libro per i tuoi insegnamenti'),
        findsNothing,
      );
      // l'obiettivo di oggi è nel riquadro «Inizia», non in una card a parte
      expect(find.text('Obiettivo di oggi'), findsNothing);
      // niente card dei gruppi degli studenti
      expect(find.text('Gruppi del tuo corso'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('home con DB vuoto ($label)', (tester) async {
      final empty = AppServices(
        (await tester.runAsync(AppDatabase.openInMemory))!,
      );
      addTearDown(() => tester.runAsync(() => empty.database.close()));
      await _pumpApp(tester, empty, const DashboardScreen(), size);
      expect(find.text('Home'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
