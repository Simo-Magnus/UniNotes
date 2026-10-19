import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/settings/sections/profile_section.dart';
import 'package:university_notes/features/settings/sections/questions_reset.dart';
import 'package:university_notes/features/settings/settings_screen.dart';

Future<AppServices> _services() async {
  final db = await AppDatabase.openInMemory();
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
    'color': 0xFF1976D2,
  });
  return AppServices(db);
}

Future<void> _pump(WidgetTester tester, AppServices s, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  // Lascia completare le query SQLite (isolate reale) e ridisegna.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

/// Animazioni dei dialoghi (la pagina ha indicatori sempre in movimento:
/// niente pumpAndSettle).
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('mostra tutte le sezioni (desktop)', (tester) async {
    final s = (await tester.runAsync(_services))!;
    await _pump(tester, s, const Size(1400, 2400));

    for (final title in [
      'Il mio percorso',
      'Calendario',
      'Esclusioni',
      'Focus e Non disturbare',
      'Esporta/importa dati',
      'Privacy e informazioni',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // «Cambia corso» dentro la card «Il mio percorso», non nella barra
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('change-path')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(ProfileSection),
        matching: find.byKey(const Key('change-path')),
      ),
      findsOneWidget,
    );
    // accanto al titolo della card
    expect(
      tester.getCenter(find.byKey(const Key('change-path'))).dy,
      closeTo(tester.getCenter(find.text('Il mio percorso')).dy, 8),
    );
    expect(find.text('Cambia corso'), findsOneWidget);
    // «Aggiorna database» e «Indirizzo del database» sulla stessa riga
    final refresh = tester.getRect(find.byKey(const Key('catalog-refresh')));
    final url = tester.getRect(find.byKey(const Key('catalog-url')));
    expect(refresh.center.dy, closeTo(url.center.dy, 1));
    // niente più import di corsi ed esami; file .ics solo dove il calendario
    // di sistema non si collega (macOS, e Linux su cui girano i test in CI)
    expect(find.text('Importa corsi ed esami'), findsNothing);
    expect(find.text('Aggiungi indirizzo'), findsNothing);
    expect(
      find.byKey(const Key('calendar-switch')),
      s.reminders.calendar.supported ? findsNothing : findsOneWidget,
    );
    // Esporta/importa dati: due sole caselle
    expect(find.text('Esporta dati (.json)'), findsOneWidget);
    expect(find.text('Importa dati (.json)'), findsOneWidget);
    expect(find.text('Esporta copia database'), findsNothing);
    expect(find.text('Nascondi: OFA e obblighi formativi'), findsOneWidget);
    // licenze open source dentro «Privacy e informazioni»
    expect(find.text('Licenze'), findsOneWidget);
    expect(find.text('Filtri personalizzati'), findsNothing);
    expect(find.textContaining('pmtiles'), findsNothing);
    await tester.runAsync(() => s.database.close());
  });

  testWidgets('layout a colonna singola su telefono', (tester) async {
    final s = (await tester.runAsync(_services))!;
    await _pump(tester, s, const Size(400, 800));
    expect(find.text('Il mio percorso'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => s.database.close());
  });

  for (final (label, width) in [('largo', 700.0), ('stretto', 360.0)]) {
    testWidgets('«Accesso e OFA» nella riga «Accesso» ($label)', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccessoRow(
              value: 'programmato',
              action: TextButton(
                key: const Key('accesso-ofa'),
                onPressed: () => opened = true,
                child: const Text('Accesso e OFA'),
              ),
            ),
          ),
        ),
      );
      final row = tester.getRect(find.byKey(const Key('accesso-row')));
      final button = tester.getRect(find.byKey(const Key('accesso-ofa')));
      // dentro la riga «Accesso»
      expect(row.contains(button.center), isTrue);
      final label = tester.getRect(find.text('Accesso'));
      if (width >= 480) {
        // stessa riga dell'etichetta
        expect(button.center.dy, closeTo(label.center.dy, 12));
      }
      expect(find.text('Requisiti di accesso e OFA'), findsNothing);
      await tester.tap(find.byKey(const Key('accesso-ofa')));
      expect(opened, isTrue);
    });
  }

  test('«Ripristina le domande»: via solo le chiavi dont_ask_', () async {
    final s = await _services();
    await s.settings.set('dont_ask_attachment_kind', 'theory');
    await s.settings.set('dont_ask_delete_recording', '1');
    await s.settings.set('theme_mode', 'dark');
    expect(await resetDontAskQuestions(s.settings), 2);
    expect(await s.settings.get('dont_ask_attachment_kind'), isNull);
    expect(await s.settings.get('dont_ask_delete_recording'), isNull);
    expect(await s.settings.get('theme_mode'), 'dark');
    expect(await resetDontAskQuestions(s.settings), 0);
    await s.database.close();
  });

  testWidgets('«Ripristina le domande» chiede conferma', (tester) async {
    final s = (await tester.runAsync(_services))!;
    await tester.runAsync(
      () => s.settings.set('dont_ask_attachment_kind', 'theory'),
    );
    await _pump(tester, s, const Size(1400, 2400));
    await tester.ensureVisible(find.byKey(const Key('reset-questions')));
    await tester.tap(find.byKey(const Key('reset-questions')));
    await _frames(tester);
    expect(find.text('Ripristinare le domande?'), findsOneWidget);
    // Annulla: resta tutto com'era
    await tester.tap(find.text('Annulla'));
    await _frames(tester);
    expect(
      await tester.runAsync(() => s.settings.get('dont_ask_attachment_kind')),
      'theory',
    );
    await tester.tap(find.byKey(const Key('reset-questions')));
    await _frames(tester);
    await tester.tap(find.text('Conferma'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(
      await tester.runAsync(() => s.settings.get('dont_ask_attachment_kind')),
      isNull,
    );
    expect(
      find.text('Domande ripristinate: l\'app chiederà di nuovo.'),
      findsOneWidget,
    );
    await tester.runAsync(() => s.database.close());
  });
}
