import 'dart:async';
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

    List<String> rel(List<Uri> requests) => [
      for (final u in requests) u.path.split('/database/').last,
    ];

    test(
      'chiamate contemporanee (doppio tocco, ritorno al riepilogo, letture): '
      'un solo download per file',
      () async {
        final requests = <Uri>[];
        final gate = Completer<void>();
        final c = fakeCatalog(
          settings,
          cacheDir: cache,
          requests: requests,
          remote: polito(),
          attesa: (r) => r.endsWith('/polito.json') ? gate.future : null,
        );
        final a = c.scaricaAteneo('polito', pulisci: false, soloCorsi: true);
        final b = c.scaricaAteneo('polito', pulisci: false, soloCorsi: true);
        final completo = c.scaricaAteneo('polito');
        while (!rel(requests).contains('corsi/polito.json')) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        // letture durante il download: aspettano lo stesso download
        final diretta = c.corsiAteneo('polito');
        final sessioni = c.sessioni('polito');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(c.progresso.value?.etichetta, 'corsi e insegnamenti');
        gate.complete();
        final esiti = await Future.wait([a, b, completo]);
        expect(esiti.every((r) => r.corsi && r.errore == null), isTrue);
        expect((await diretta)!.data.corsi.single.insegnamenti, hasLength(4));
        expect(await sessioni, isNotNull);
        final r = rel(requests);
        for (final f in [
          'corsi/polito.json',
          'sessioni/polito.json',
          'moduli/polito.json',
        ]) {
          expect(r.where((x) => x == f), hasLength(1), reason: f);
        }
        expect(c.progresso.value, isNull);
        // nessun file temporaneo rimasto
        expect(
          cache
              .listSync(recursive: true)
              .where((e) => e.path.endsWith('.part')),
          isEmpty,
        );
      },
    );

    test(
      'solo i corsi (scelta del percorso), poi il resto: i corsi non si '
      'riscaricano',
      () async {
        final requests = <Uri>[];
        final c = fakeCatalog(
          settings,
          cacheDir: cache,
          requests: requests,
          remote: polito(),
        );
        final solo = await c.scaricaAteneo(
          'polito',
          pulisci: false,
          soloCorsi: true,
        );
        expect(solo.corsi, isTrue);
        expect(rel(requests), ['meta.json', 'corsi/polito.json']);
        expect(inCache('sessioni/polito.json'), isFalse);
        requests.clear();
        final tutto = await c.scaricaAteneo('polito');
        expect(tutto.corsiAggiornati, isTrue);
        expect(rel(requests), [
          'meta.json',
          'sessioni/polito.json',
          'moduli/polito.json',
        ]);
      },
    );

    test('download interrotto: la copia salvata resta intatta', () async {
      await fakeCatalog(
        settings,
        cacheDir: cache,
        remote: polito(),
      ).scaricaAteneo('polito');
      final prima = File('${cache.path}/corsi/polito.json').readAsStringSync();
      final c = CatalogService(
        settings,
        fetcher: (uri, {onProgress}) async => throw CatalogNotFoundException(),
        fileFetcher: (uri, dest, {onProgress}) async {
          // metà file, poi la connessione cade
          await dest.writeAsString(corsi.substring(0, corsi.length ~/ 2));
          throw CatalogOfflineException('Connessione interrotta.');
        },
        assetLoader: (_) async => throw StateError('no'),
        assetBytesLoader: (_) async => throw StateError('no'),
        cacheDir: () async => cache,
      );
      final r = await c.scaricaAteneo('polito', forza: true);
      expect(r.corsi, isTrue);
      expect(r.errore, isA<CatalogOfflineException>());
      expect(
        File('${cache.path}/corsi/polito.json').readAsStringSync(),
        prima,
      );
      expect(File('${cache.path}/corsi/polito.json.part').existsSync(), isFalse);
      expect(c.progresso.value, isNull);
    });

    test('file salvato corrotto: si elimina e si riscarica', () async {
      File('${cache.path}/corsi/polito.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(corsi.substring(0, corsi.length ~/ 3));
      final requests = <Uri>[];
      final c = fakeCatalog(
        settings,
        cacheDir: cache,
        requests: requests,
        remote: polito(),
      );
      final r = (await c.corsiAteneo('polito', remote: false))!;
      expect(r.source, CatalogSource.remote);
      expect(r.data.corsi.single.insegnamenti, hasLength(4));
      expect(rel(requests), ['corsi/polito.json']);
      expect(
        (await c.corsiAteneo('polito', remote: false))!.source,
        CatalogSource.cache,
      );
    });

    test('errori: messaggi chiari per lo studente', () {
      expect(
        CatalogService.descriviErrore(const SocketException('x')),
        kServeConnessione,
      );
      expect(
        CatalogService.descriviErrore(const FileSystemException('pieno')),
        contains('spazio libero'),
      );
      expect(
        CatalogService.descriviErrore(const FormatException('x')),
        contains('non valido'),
      );
    });

    test('con corso e insegnamenti in memoria resta solo il necessario', () async {
      final due = corsiPolitoFixture();
      final altro = Map<String, Object?>.of(
        (due['corsi'] as List).single as Map<String, Object?>,
      )..['id'] = 'polito-altro';
      due['corsi'] = [...due['corsi'] as List, altro];
      final c = fakeCatalog(
        settings,
        cacheDir: cache,
        remote: {
          ...polito(),
          'corsi/polito.json': jsonEncode(due),
          'moduli/polito.json': jsonEncode({
            'schema': 1,
            'universita_id': 'polito',
            'insegnamenti': {
              for (final id in ['a', 'b', 'c'])
                id: {
                  'moduli': [
                    {
                      'nome': 'Capitolo $id',
                      'argomenti': ['x'],
                    },
                  ],
                },
            },
          }),
        },
      );
      await c.scaricaAteneo('polito');
      expect(
        (await c.corsiAteneo('polito', remote: false))!.data.corsi,
        hasLength(2),
      );
      final uno = (await c.corsiAteneo(
        'polito',
        remote: false,
        corso: 'polito-altro',
      ))!.data;
      expect(uno.corsi.single.id, 'polito-altro');
      expect(uno.corsi.single.insegnamenti, hasLength(4));
      expect(uno.universitaId, 'polito');
      final m = (await c.moduli('polito', insegnamenti: ['a', 'c']))!.data;
      expect(m.insegnamenti.keys.toSet(), {'a', 'c'});
    });

    test(
      'file grande: lettura fuori dal thread dell\'interfaccia',
      () async {
        // ~15 MB di corsi, come un ateneo grande
        final grande = {
          'schema': 1,
          'universita_id': 'polito',
          'corsi': [
            for (var c = 0; c < 400; c++)
              {
                'id': 'c$c',
                'nome': 'Corso $c',
                'tipo': 'L',
                'insegnamenti': [
                  for (var i = 0; i < 150; i++)
                    {
                      'id': 'c$c-i$i',
                      'nome': 'Insegnamento $i del corso $c',
                      'anno': 1 + i % 3,
                      'cfu': 6,
                      'docenti': ['Docente $i'],
                      'libri': [
                        {
                          'titolo': 'Manuale di riferimento $i',
                          'autori': 'Autore $i',
                          'editore': 'Editore',
                          'anno': 2020,
                        },
                      ],
                      'esami': [
                        {'tipo': 'appello', 'data': '2027-01-20'},
                      ],
                    },
                ],
              },
          ],
        };
        File('${cache.path}/corsi/polito.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode(grande));
        final c = fakeCatalog(settings, cacheDir: cache);
        var ultimo = DateTime.now();
        var pausa = Duration.zero;
        final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
          final ora = DateTime.now();
          if (ora.difference(ultimo) > pausa) pausa = ora.difference(ultimo);
          ultimo = ora;
        });
        final r = (await c.corsiAteneo(
          'polito',
          remote: false,
          scarica: false,
          corso: 'c200',
        ))!;
        timer.cancel();
        expect(r.data.corsi.single.insegnamenti, hasLength(150));
        // sul thread principale la decodifica bloccherebbe per centinaia di
        // millisecondi
        expect(pausa, lessThan(const Duration(milliseconds: 200)));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
