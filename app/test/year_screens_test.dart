import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/academic/student_profile.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/academic/new_year_check.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/main.dart';
import 'package:university_notes/models/book.dart';

import 'support/plan_services.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}

Future<AppServices> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(1000, 1400),
  AppServices? services,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final s = services ?? (await tester.runAsync(planServices))!;
  addTearDown(() => tester.runAsync(s.database.close));
  await tester.pumpWidget(
    Provider.value(
      value: s,
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
  await _settle(tester);
  return s;
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  testWidgets('"Segna come completato": solo i voti, poi completato', (
    tester,
  ) async {
    final s = await _pump(tester, const YearGradesScreen(year: 1));
    expect(find.text('Segna come completato'), findsOneWidget);
    expect(find.text('Analisi matematica I'), findsOneWidget);
    expect(find.text('Fisica I'), findsOneWidget);
    // Algoritmi è del 2° anno: non c'è.
    expect(find.text('Algoritmi e programmazione'), findsNothing);
    final courses = (await tester.runAsync(() => yearCourses(s, 1)))!;
    final analisi = courses.first;
    final fisica = courses.last;

    // Analisi 27.
    await tester.tap(find.byKey(Key('grade-${analisi.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('27').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grades-save')));
    await _settle(tester);
    final py = (await tester.runAsync(() => s.profiles.planYear(1)))!;
    expect(py.status, PlanYearStatus.completatoParziale);

    // Riprende: Fisica come idoneità superata → completato.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      Provider.value(
        value: s,
        child: const MaterialApp(home: YearGradesScreen(year: 1)),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('Idoneità').last);
    await tester.pump();
    await tester.tap(find.byKey(Key('pass-${fisica.id}')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('grades-save')));
    await _settle(tester);
    final py2 = await tester.runAsync(() => s.profiles.planYear(1));
    expect(py2!.status, PlanYearStatus.completato);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Libri: Tieni / Rimuovi, libri da aggiungere, anni', (
    tester,
  ) async {
    final s = (await tester.runAsync(planServices))!;
    s.selectedYear.value = 1;
    await _pump(tester, const BooksScreen(), services: s);
    // l'anno si sceglie solo nella Home: niente selettore nella barra
    expect(find.byKey(const Key('year-selector')), findsNothing);
    expect(find.text('Analisi Matematica 1'), findsOneWidget);
    // Fisica non ha libri nel catalogo.
    expect(find.text('Libri da aggiungere'), findsOneWidget);
    expect(find.text('Da aggiungere'), findsOneWidget);
    expect(find.text('Segnala i libri'), findsOneWidget);
    // cerchi «tieni» (spunta) e «rimuovi» (X) accanto al titolo, solo sui
    // libri consigliati, non sugli obbligatori
    expect(find.byTooltip('Tieni'), findsOneWidget);
    expect(find.text('Tieni'), findsNothing);

    final books = (await tester.runAsync(s.books.all))!;
    final suggested = books.singleWhere(
      (b) => b.title == 'Esercizi di Analisi',
    );
    await tester.tap(find.byKey(ValueKey('remove-${suggested.id}')));
    await _settle(tester);
    expect(find.text('Esercizi di Analisi'), findsNothing);
    expect(find.text('Libri rimossi (1)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('removed-books-filter')));
    await tester.pump();
    expect(find.text('Esercizi di Analisi'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('restore-${suggested.id}')));
    await _settle(tester);
    final after = (await tester.runAsync(() => s.books.byId(suggested.id!)))!;
    expect(after.catalogChoice, isNull);
    await tester.tap(find.byKey(const Key('removed-books-filter')));
    await tester.pump();

    // Anno 3: Reti di calcolatori senza libri previsti.
    s.selectYear(3);
    await _settle(tester);
    expect(find.text('Nessun libro previsto'), findsOneWidget);
    expect(find.text('Analisi Matematica 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home: corso e anno senza ripetizioni, anno scelto toccandolo', (
    tester,
  ) async {
    final s = await _pump(tester, const DashboardScreen());
    await _settle(tester);
    // nessun selettore nella barra in alto
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('year-selector')),
      ),
      findsNothing,
    );
    final p = s.profile.value!;
    // il nome del corso una volta sola, senza l'anno attaccato
    expect(find.text(p.degreeName), findsOneWidget);
    expect(find.textContaining('${p.degreeName} ·'), findsNothing);
    // l'anno (con l'anno accademico) accanto al nome del corso
    final pill = find.byKey(const Key('year-selector'));
    expect(pill, findsOneWidget);
    expect(find.text(p.yearChipLabel(2)), findsOneWidget);
    // l'anno accademico non si ripete sotto, accanto all'università
    expect(find.text(p.universityName), findsOneWidget);
    expect(
      find.textContaining('${p.universityName} · ${p.academicYearOf(2).label}'),
      findsNothing,
    );
    // stessa riga del nome del corso (su schermo largo)
    expect(
      tester.getCenter(pill).dy,
      closeTo(tester.getCenter(find.text(p.degreeName)).dy, 12),
    );
    await tester.tap(pill);
    await tester.pumpAndSettle();
    await tester.tap(find.text(p.yearChipLabel(1)).last);
    await tester.pumpAndSettle();
    expect(s.selectedYear.value, 1);
    await _settle(tester);
    expect(find.text(p.yearChipLabel(1)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esami: anno passato da completare, date da aggiungere', (
    tester,
  ) async {
    final s = (await tester.runAsync(planServices))!;
    s.selectedYear.value = 1;
    await _pump(tester, const ExamsScreen(), services: s);
    expect(find.text('Anno da completare'), findsOneWidget);
    expect(find.text('Segna come completato'), findsOneWidget);
    expect(find.text('Analisi matematica I'), findsWidgets);
    expect(find.text('Fisica I'), findsOneWidget);
    expect(find.textContaining('Prossimo appello'), findsOneWidget);
    expect(find.textContaining('Data da aggiungere'), findsWidgets);
    expect(find.text('Da aggiungere'), findsOneWidget);
    expect(find.text('Segnala date d\'esame'), findsOneWidget);
    expect(find.text('Algoritmi e programmazione'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('avvio: senza profilo onboarding, con profilo l\'app', (
    tester,
  ) async {
    final s = (await tester.runAsync(planServices))!;
    final p = s.profile.value;
    s.profile.value = null;
    await _pump(tester, const AppRoot(), services: s);
    // primo passo dell'onboarding: contrasto e grandezza del testo
    expect(find.text('Come preferisci leggere?'), findsOneWidget);
    s.profile.value = p;
    await _settle(tester);
    expect(find.text('Come preferisci leggere?'), findsNothing);
    expect(find.textContaining('Ingegneria Informatica'), findsOneWidget);
    // Libro non toccato (sanity sull'avvio).
    expect(Book.fromMap(const {'title': 'x'}).catalogChoice, isNull);
  });

  testWidgets('nuovo anno accademico: "sei al 3° anno?" → voti → 3° anno', (
    tester,
  ) async {
    final s = (await tester.runAsync(planServices))!;
    NewYearAnswer? answer;
    await _pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => checkNewAcademicYear(
              context,
              now: DateTime(2027, 9, 1),
            ).then((v) => answer = v),
            child: const Text('controlla'),
          ),
        ),
      ),
      services: s,
    );
    await tester.tap(find.text('controlla'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'È iniziato il nuovo anno accademico 2027/28: sei al 3° anno?',
      ),
      findsOneWidget,
    );
    // due soli pulsanti: «Più tardi» è chiudere il riquadro
    expect(find.text('Più tardi'), findsNothing);
    await tester.tap(find.byKey(const Key('new-year-yes')));
    await _settle(tester);
    await tester.pumpAndSettle();
    await _settle(tester);
    expect(find.text('Com\'è andato il 2° anno?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('grades-save')));
    for (var i = 0; i < 100 && answer == null; i++) {
      await _settle(tester, 1);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(answer, NewYearAnswer.yes);
    final p = s.profile.value!;
    expect(p.currentYear, 3);
    expect(p.referenceAa.label, '2027/28');
    expect(s.selectedYear.value, 3);
    final y2 = await tester.runAsync(() => s.profiles.planYear(2));
    // Nessun voto inserito: 2° anno completato solo in parte.
    expect(y2!.status, PlanYearStatus.completatoParziale);
  });
}
