import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/widgets/catalog_download.dart';

import 'support/catalog_fixtures.dart';

/// «Aggiorna database» senza connessione: stesso comportamento in tutta
/// l'app ([aggiornaDatabase]) e lo stesso avviso con «Riprova».
void main() {
  late AppServices s;
  late Map<String, String> remote;
  late List<Uri> requests;

  setUp(() async {
    final db = await AppDatabase.openInMemory();
    remote = {'corsi/polito.json': jsonEncode(corsiPolitoFixture())};
    requests = [];
    s = AppServices(
      db,
      catalog: fakeCatalog(
        SettingsRepository(db),
        remote: remote,
        requests: requests,
      ),
    );
    await PathSetupService(s).apply(
      PathSelection(
        ateneo: UniversitaCatalog.fromJson(kUniversitaFixture).byId('polito')!,
        tipo: TipoCorso.l,
        corso: IndiceCorsi.fromJson(kIndiceFixture).corsi.first,
        year: 2,
      ),
      now: DateTime(2026, 10, 4),
    );
    await s.loadProfile();
  });

  tearDown(() async {
    Rete.debugOffline = null;
    await s.database.close();
  });

  test('con la rete: aggiornato, nessun avviso', () async {
    final r = await aggiornaDatabase(s);
    expect(r.offline, isFalse);
    expect(r.result!.imported, isTrue);
  });

  test('database che non risponde: piano dalla copia, ma avviso', () async {
    // ogni richiesta fallisce come senza connessione
    remote.clear();
    final r = await aggiornaDatabase(s);
    expect(r.offline, isTrue);
    // il piano resta quello salvato (reimportato dalla copia)
    expect(r.result!.imported, isTrue);
    expect(r.messaggioOffline, kServeConnessioneAggiornamento);
  });

  test('sistema senza rete: non si prova nemmeno', () async {
    Rete.debugOffline = () async => true;
    final before = requests.length;
    final r = await aggiornaDatabase(s);
    expect(r.offline, isTrue);
    expect(r.result, isNull);
    expect(requests.length, before);
    expect(r.messaggioOffline, kServeConnessioneAggiornamento);
  });

  test('dati del corso mai scaricati: «Serve una connessione…»', () {
    const r = AggiornamentoDatabase(
      PlanImportResult(imported: false, senzaRete: true),
      offline: true,
    );
    expect(r.messaggioOffline, kServeConnessione);
  });

  testWidgets('avviso con «Riprova»', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => mostraServeConnessione(
                context,
                message: kServeConnessioneAggiornamento,
                onRetry: () => retried++,
              ),
              child: const Text('aggiorna'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('aggiorna'));
    await tester.pumpAndSettle();
    expect(find.text(kServeConnessioneAggiornamento), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    await tester.tap(find.text('Riprova'));
    expect(retried, 1);
  });
}
