import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
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
    // «Cambia corso» in alto, nella barra
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('change-path')),
      ),
      findsOneWidget,
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
}
