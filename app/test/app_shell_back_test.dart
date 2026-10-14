import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/dashboard/dashboard_screen.dart';
import 'package:university_notes/features/exams/exams_screen.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  testWidgets('telefono: «indietro» da una sezione torna alla Home', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      (await tester.runAsync(AppDatabase.openInMemory))!,
    );
    addTearDown(() => tester.runAsync(() => services.database.close()));
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: services,
        child: const MaterialApp(
          locale: Locale('it', 'IT'),
          supportedLocales: [Locale('it', 'IT')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: AppShell(),
        ),
      ),
    );
    await _settle(tester);
    expect(find.byType(DashboardScreen), findsOneWidget);
    // dalla Home «indietro» esce dall'app
    final popScope = find.byWidgetPredicate((w) => w is PopScope).first;
    expect(tester.widget<PopScope>(popScope).canPop, true);

    await tester.tap(
      find.descendant(
        of: find.byType(GlassNavBar),
        matching: find.text('Esami'),
      ),
    );
    await _settle(tester);
    expect(find.byType(ExamsScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(ExamsScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
