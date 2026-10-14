import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late Directory cache;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    settings = SettingsRepository(db);
    cache = Directory.systemTemp.createTempSync('catalog_service_test');
  });

  tearDown(() async {
    await db.close();
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test('senza rete e senza cache usa gli asset inclusi', () async {
    final c = fakeCatalog(settings, cacheDir: cache);
    final u = await c.universita();
    expect(u.universita, hasLength(5));
    final i = await c.indiceCorsi();
    expect(i.corsi, hasLength(4));
    // I file per ateneo non sono negli asset (build leggera) e senza rete
    // non si scaricano: null.
    expect(await c.corsiAteneo('polito'), isNull);
    expect(await c.sessioni('polito'), isNull);
    expect(await c.moduli('polito'), isNull);
  });

  test('download → copia su disco → usata offline', () async {
    final requests = <Uri>[];
    final online = fakeCatalog(
      settings,
      cacheDir: cache,
      requests: requests,
      remote: {'corsi/polito.json': jsonEncode(corsiPolitoFixture())},
    );
    final r = (await online.corsiAteneo('polito'))!;
    expect(r.source, CatalogSource.remote);
    expect(r.offline, isFalse);
    expect(r.data.corsi.single.insegnamenti, hasLength(4));
    expect(
      requests.single.toString(),
      '$kDefaultCatalogBaseUrl/corsi/polito.json',
    );
    expect(File('${cache.path}/corsi/polito.json').existsSync(), isTrue);

    final offline = fakeCatalog(settings, cacheDir: cache);
    final again = (await offline.corsiAteneo('polito'))!;
    expect(again.source, CatalogSource.cache);
    expect(again.offline, isTrue);
    expect(again.error, isNotNull);
  });

  test(
    'build locale completa (sync_assets.py --completo): file compresso '
    'negli asset',
    () async {
      final c = fakeCatalog(
        settings,
        cacheDir: cache,
        assets: {
          'assets/database/corsi/polito.json.gz': jsonEncode(
            corsiPolitoFixture(),
          ),
        },
      );
      final r = (await c.corsiAteneo('polito'))!;
      expect(r.source, CatalogSource.bundled);
      expect(r.data.corsi.single.insegnamenti, hasLength(4));
    },
  );

  test('un file scaricato non valido non sostituisce la cache', () async {
    final good = fakeCatalog(
      settings,
      cacheDir: cache,
      remote: {'corsi/polito.json': jsonEncode(corsiPolitoFixture())},
    );
    await good.corsiAteneo('polito');
    final bad = fakeCatalog(
      settings,
      cacheDir: cache,
      remote: {'corsi/polito.json': '<html>errore</html>'},
    );
    final r = (await bad.corsiAteneo('polito'))!;
    expect(r.source, CatalogSource.cache);
    expect(r.data.universitaId, 'polito');
  });

  test('indirizzo del database configurabile', () async {
    final requests = <Uri>[];
    final c = fakeCatalog(settings, cacheDir: cache, requests: requests);
    expect(await c.baseUrl(), kDefaultCatalogBaseUrl);
    await c.setBaseUrl('https://example.org/db/');
    expect(await c.baseUrl(), 'https://example.org/db');
    await c.remoteMeta();
    expect(requests.single.toString(), 'https://example.org/db/meta.json');
    expect(() => c.setBaseUrl('ftp://x'), throwsA(isA<CatalogException>()));
    await c.setBaseUrl('');
    expect(await c.baseUrl(), kDefaultCatalogBaseUrl);
  });

  test('aggiornamento degli indici da internet', () async {
    final c = fakeCatalog(
      settings,
      cacheDir: cache,
      remote: {
        'universita.json': jsonEncode({
          ...kUniversitaFixture,
          'universita': [
            ...(kUniversitaFixture['universita'] as List),
            {
              'id': 'unibo',
              'nome': 'Università degli Studi di Bologna',
              'tipo': 'statale',
              'regioni': ['Emilia-Romagna'],
            },
          ],
        }),
      },
    );
    expect((await c.universita()).universita, hasLength(5));
    expect(await c.refreshIndexes(), isTrue);
    expect((await c.universita()).universita, hasLength(6));
    // L'indice dei corsi non era online: resta quello incluso.
    expect((await c.indiceCorsi()).corsi, hasLength(4));
  });
  group('dati dell\'ateneo scelto', () {
    final corsi = jsonEncode(corsiPolitoFixture());
    final sessioni = jsonEncode({
      'schema': 1,
      'universita_id': 'polito',
      'sessioni': <Object>[],
    });
    final moduli = jsonEncode({
      'schema': 1,
      'universita_id': 'polito',
      'insegnamenti': <String, Object>{},
    });
    Map<String, String> polito() => {
      'corsi/polito.json': corsi,
      'sessioni/polito.json': sessioni,
      'moduli/polito.json': moduli,
      // un altro ateneo: si scarica solo se scelto
      'corsi/unimib.json': corsi.replaceAll('polito', 'unimib'),
    };
    bool inCache(String rel) => File('${cache.path}/$rel').existsSync();

    test(
      'scelta dell\'ateneo: scarica solo i suoi file, con avanzamento',
      () async {
        final requests = <Uri>[];
        final c = fakeCatalog(
          settings,
          cacheDir: cache,
          requests: requests,
          remote: polito(),
        );
        final visti = <CatalogProgress>[];
        c.progresso.addListener(() {
          if (c.progresso.value case final p?) visti.add(p);
        });
        final r = await c.scaricaAteneo('polito');
        expect(r.corsi, isTrue);
        expect(r.corsiAggiornati, isTrue);
        expect(r.senzaRete, isFalse);
        expect(r.errore, isNull);
        expect(r.scaricati, 3);
        expect(r.byte, greaterThan(corsi.length));
        expect(requests.map((u) => u.path.split('/database/').last), [
          'meta.json',
          'corsi/polito.json',
          'sessioni/polito.json',
          'moduli/polito.json',
        ]);
        expect(inCache('corsi/polito.json'), isTrue);
        expect(inCache('sessioni/polito.json'), isTrue);
        expect(inCache('moduli/polito.json'), isTrue);
        expect(inCache('corsi/unimib.json'), isFalse);
        // avanzamento: un file alla volta, poi nessun download in corso
        expect(visti.map((p) => p.indice).toSet(), {1, 2, 3});
        expect(visti.every((p) => p.totale == 3), isTrue);
        expect(c.progresso.value, isNull);

        // Offline: tutto dalla copia salvata, nessuna richiesta.
        requests.clear();
        final offline = fakeCatalog(
          settings,
          cacheDir: cache,
          requests: requests,
        );
        final letti = (await offline.corsiAteneo('polito', remote: false))!;
        expect(letti.source, CatalogSource.cache);
        expect(letti.data.corsi.single.insegnamenti, hasLength(4));
        expect((await offline.sessioni('polito'))!.source, CatalogSource.cache);
        expect((await offline.moduli('polito'))!.source, CatalogSource.cache);
        expect(requests, isEmpty);
        final dati = await offline.datiAteneo('polito');
        expect(dati.corsi, isTrue);
        expect(dati.byte, greaterThan(corsi.length));
        expect(dati.scaricatoIl, isNotNull);
      },
    );

    test('senza rete e senza copia: serve una connessione', () async {
      final c = fakeCatalog(settings, cacheDir: cache);
      final r = await c.scaricaAteneo('polito');
      expect(r.senzaRete, isTrue);
      expect(r.corsi, isFalse);
      expect(r.errore, isA<SocketException>());
      expect(await c.corsiAteneo('polito', remote: false), isNull);
      expect((await c.datiAteneo('polito')).corsi, isFalse);
      expect(c.progresso.value, isNull);
    });

    test('senza rete ma con la copia salvata: si usa quella', () async {
      await fakeCatalog(
        settings,
        cacheDir: cache,
        remote: polito(),
      ).scaricaAteneo('polito');
      final offline = fakeCatalog(settings, cacheDir: cache);
      final r = await offline.scaricaAteneo('polito', forza: true);
      expect(r.senzaRete, isFalse);
      expect(r.corsi, isTrue);
      expect(r.corsiAggiornati, isFalse);
      expect(r.errore, isNotNull);
      expect(inCache('corsi/polito.json'), isTrue);
    });

    test(
      'lettura senza copia salvata: download automatico, una volta',
      () async {
        final requests = <Uri>[];
        final c = fakeCatalog(
          settings,
          cacheDir: cache,
          requests: requests,
          remote: polito(),
        );
        // chiamante che legge "dalla cache" (es. promemoria, statistiche)
        final r = (await c.sessioni('polito'))!;
        expect(r.source, CatalogSource.remote);
        expect(inCache('sessioni/polito.json'), isTrue);
        expect((await c.sessioni('polito'))!.source, CatalogSource.cache);
      },
    );

    test('cambio d\'ateneo: i file del precedente si eliminano', () async {
      final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
      await c.scaricaAteneo('polito');
      expect(inCache('corsi/polito.json'), isTrue);
      final r = await c.scaricaAteneo('unimib');
      expect(r.corsi, isTrue);
      expect(inCache('corsi/unimib.json'), isTrue);
      expect(inCache('corsi/polito.json'), isFalse);
      expect(inCache('sessioni/polito.json'), isFalse);
      expect(inCache('moduli/polito.json'), isFalse);
      expect((await c.datiAteneo('polito')).corsi, isFalse);
      expect((await c.datiAteneo('unimib')).corsi, isTrue);
    });

    test('la vecchia cartella community/ nella cache si elimina', () async {
      final vecchia = Directory('${cache.path}/community')
        ..createSync(recursive: true);
      File('${vecchia.path}/polito.json').writeAsStringSync('{}');
      final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
      await c.scaricaAteneo('polito');
      expect(vecchia.existsSync(), isFalse);
      expect(inCache('corsi/polito.json'), isTrue);
    });

    test('ateneo non ancora nel database (404): non è un errore di rete', () async {
      final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
      final r = await c.scaricaAteneo('unina');
      expect(r.corsiAssenti, isTrue);
      expect(r.senzaRete, isFalse);
      expect(r.corsi, isFalse);
    });

    test(
      'aggiornamento: con meta.json riscarica solo ciò che è cambiato',
      () async {
        final requests = <Uri>[];
        Map<String, String> remote(String versione) => {
          ...polito(),
          'meta.json': jsonEncode({
            'schema': 1,
            'versione': versione,
            'atenei': {
              'polito': {
                'file': 'corsi/polito.json',
                'sha256': crypto.sha256.convert(utf8.encode(corsi)).toString(),
              },
            },
          }),
        };
        Future<List<String>> scarica(String versione) async {
          requests.clear();
          await fakeCatalog(
            settings,
            cacheDir: cache,
            requests: requests,
            remote: remote(versione),
          ).scaricaAteneo('polito', forza: true);
          return [
            for (final u in requests)
              if (u.path.contains('/polito.json'))
                u.path.split('/database/').last,
          ];
        }

        expect(await scarica('2026.10.13'), hasLength(3));
        // stessa versione: nulla da riscaricare
        expect(await scarica('2026.10.13'), isEmpty);
        // nuova versione ma corsi identici (stessa impronta): solo gli altri
        expect(await scarica('2026.10.20'), [
          'sessioni/polito.json',
          'moduli/polito.json',
        ]);
      },
    );
  });
}
