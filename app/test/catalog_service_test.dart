import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  const corso = 'polito-l8-ingegneria-informatica';
  const relCorso = 'per_corso/polito/$corso.json';
  const relIndice = 'per_corso/polito/indice.json';

  /// L'indice per corso di [remote] con un'impronta diversa per ogni corso
  /// (il corso sul dispositivo risulta da riscaricare).
  String indiceCambiato(Map<String, String> remote) => fileDaPerAteneo(
    remote,
    relIndice,
  )!.replaceAll(RegExp(r'"sha256":"[0-9a-f]+"'), '"sha256":"diversa"');

  test('senza rete e senza cache: elenchi dagli asset, corso no', () async {
    final c = fakeCatalog(settings, cacheDir: cache);
    final u = await c.universita();
    expect(u.universita, hasLength(5));
    final i = await c.indiceCorsi();
    expect(i.corsi, hasLength(4));
    // I file del corso non sono negli asset e senza rete non si
    // scaricano: null.
    expect(await c.corsiAteneo('polito', corso: corso), isNull);
    expect(await c.sessioni('polito'), isNull);
    expect(await c.moduli('polito', corso: corso), isNull);
  });

  test('download del corso → copia su disco → usata offline', () async {
    final requests = <Uri>[];
    final online = fakeCatalog(
      settings,
      cacheDir: cache,
      requests: requests,
      remote: {'corsi/polito.json': jsonEncode(corsiPolitoFixture())},
    );
    final r = (await online.corsiAteneo('polito', corso: corso))!;
    expect(r.source, CatalogSource.remote);
    expect(r.offline, isFalse);
    expect(r.data.corsi.single.insegnamenti, hasLength(4));
    expect(
      requests.map((u) => u.toString()),
      containsAllInOrder([
        '$kDefaultCatalogBaseUrl/$relIndice',
        '$kDefaultCatalogBaseUrl/$relCorso',
      ]),
    );
    // mai il file di tutto l'ateneo
    expect(requests.where((u) => u.path.contains('/corsi/')), isEmpty);
    expect(File('${cache.path}/$relCorso').existsSync(), isTrue);

    final offline = fakeCatalog(settings, cacheDir: cache);
    final again = (await offline.corsiAteneo('polito', corso: corso))!;
    expect(again.source, CatalogSource.cache);
    expect(again.offline, isTrue);
    expect(again.error, isNotNull);
  });

  test('un file scaricato non valido non sostituisce la cache', () async {
    final remote = {'corsi/polito.json': jsonEncode(corsiPolitoFixture())};
    await fakeCatalog(
      settings,
      cacheDir: cache,
      remote: remote,
    ).corsiAteneo('polito', corso: corso);
    final bad = fakeCatalog(
      settings,
      cacheDir: cache,
      remote: {
        // impronta diversa: si riscarica, ma il file non è valido
        relIndice: indiceCambiato(remote),
        relCorso: '<html>errore</html>',
      },
    );
    final r = (await bad.corsiAteneo('polito', corso: corso))!;
    expect(r.source, CatalogSource.cache);
    expect(r.data.universitaId, 'polito');
    expect(r.data.corsi.single.insegnamenti, hasLength(4));
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

  group('dati del corso scelto', () {
    final corsi = jsonEncode(corsiPolitoFixture());
    final sessioni = jsonEncode({
      'schema': 1,
      'universita_id': 'polito',
      'sessioni': <Object>[],
    });
    final moduli = jsonEncode({
      'schema': 1,
      'universita_id': 'polito',
      'insegnamenti': {
        for (final id in [
          'polito-l8-ingegneria-informatica-01rkcpl',
          'polito-l8-ingegneria-informatica-02fisica',
          'polito-l8-ingegneria-informatica-03algo',
          'altro-corso-insegnamento',
        ])
          id: {
            'moduli': [
              {
                'nome': 'Capitolo $id',
                'argomenti': ['x'],
              },
            ],
          },
      },
    });
    // file per ateneo da cui il finto server ricava i file per corso
    // (come tools/db_builder/dividi_per_corso.py)
    Map<String, String> polito() => {
      'corsi/polito.json': corsi,
      'sessioni/polito.json': sessioni,
      'moduli/polito.json': moduli,
      // un altro ateneo: si scarica solo se scelto
      'corsi/unimib.json': corsi.replaceAll('polito', 'unimib'),
    };
    const altroCorso = 'unimib-l8-ingegneria-informatica';
    bool inCache(String rel) => File('${cache.path}/$rel').existsSync();
    List<String> rel(List<Uri> requests) => [
      for (final u in requests) u.path.split('/database/').last,
    ];

    test('scelta del corso: scarica solo il suo file e le sessioni, con '
        'avanzamento', () async {
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
      final r = await c.scaricaCorso('polito', corso);
      expect(r.corsi, isTrue);
      expect(r.corsiAggiornati, isTrue);
      expect(r.senzaRete, isFalse);
      expect(r.errore, isNull);
      expect(r.scaricati, 2);
      expect(r.byte, greaterThan(0));
      expect(rel(requests), [
        'meta.json',
        relIndice,
        relCorso,
        'sessioni/polito.json',
      ]);
      expect(inCache(relCorso), isTrue);
      expect(inCache('sessioni/polito.json'), isTrue);
      expect(inCache('per_corso/unimib/$altroCorso.json'), isFalse);
      // avanzamento: un file alla volta, poi nessun download in corso
      expect(visti.map((p) => p.indice).toSet(), {1, 2});
      expect(visti.every((p) => p.totale == 2), isTrue);
      expect(c.progresso.value, isNull);

      // Offline: tutto dalla copia salvata, nessuna richiesta.
      requests.clear();
      final offline = fakeCatalog(
        settings,
        cacheDir: cache,
        requests: requests,
      );
      final letti = (await offline.corsiAteneo(
        'polito',
        corso: corso,
        remote: false,
      ))!;
      expect(letti.source, CatalogSource.cache);
      expect(letti.data.corsi.single.insegnamenti, hasLength(4));
      expect((await offline.sessioni('polito'))!.source, CatalogSource.cache);
      final m = (await offline.moduli('polito', corso: corso))!;
      expect(m.source, CatalogSource.cache);
      // solo i moduli degli insegnamenti del corso
      expect(m.data.insegnamenti, hasLength(3));
      expect(requests, isEmpty);
      final dati = await offline.datiCorso('polito', corso);
      expect(dati.corsi, isTrue);
      expect(dati.byte, greaterThan(0));
      expect(dati.scaricatoIl, isNotNull);
    });

    test('senza rete e senza copia: serve una connessione', () async {
      final c = fakeCatalog(settings, cacheDir: cache);
      final r = await c.scaricaCorso('polito', corso);
      expect(r.senzaRete, isTrue);
      expect(r.corsi, isFalse);
      expect(r.errore, isA<SocketException>());
      expect(
        await c.corsiAteneo('polito', corso: corso, remote: false),
        isNull,
      );
      expect((await c.datiCorso('polito', corso)).corsi, isFalse);
      expect(c.progresso.value, isNull);
    });

    test('senza rete ma con la copia salvata: si usa quella', () async {
      await fakeCatalog(
        settings,
        cacheDir: cache,
        remote: polito(),
      ).scaricaCorso('polito', corso);
      final offline = fakeCatalog(settings, cacheDir: cache);
      final r = await offline.scaricaCorso('polito', corso, forza: true);
      expect(r.senzaRete, isFalse);
      expect(r.corsi, isTrue);
      expect(r.corsiAggiornati, isFalse);
      expect(r.errore, isNotNull);
      expect(inCache(relCorso), isTrue);
    });

    test(
      'lettura senza copia salvata: download automatico, una volta',
      () async {
        final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
        // chiamante che legge "dalla cache" (es. promemoria, statistiche)
        final r = (await c.sessioni('polito'))!;
        expect(r.source, CatalogSource.remote);
        expect(inCache('sessioni/polito.json'), isTrue);
        expect((await c.sessioni('polito'))!.source, CatalogSource.cache);
        final m = (await c.moduli('polito', corso: corso))!;
        expect(m.source, CatalogSource.remote);
        expect(inCache(relCorso), isTrue);
      },
    );

    test(
      'cambio di corso o d\'ateneo: i file del precedente si eliminano',
      () async {
        final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
        await c.scaricaCorso('polito', corso);
        expect(inCache(relCorso), isTrue);
        final r = await c.scaricaCorso('unimib', altroCorso);
        expect(r.corsi, isTrue);
        expect(inCache('per_corso/unimib/$altroCorso.json'), isTrue);
        expect(inCache(relCorso), isFalse);
        expect(inCache('sessioni/polito.json'), isFalse);
        expect((await c.datiCorso('polito', corso)).corsi, isFalse);
        expect((await c.datiCorso('unimib', altroCorso)).corsi, isTrue);
      },
    );

    test('i file per ateneo delle versioni precedenti e community/ si '
        'eliminano', () async {
      for (final d in ['community', 'corsi', 'moduli']) {
        File('${cache.path}/$d/polito.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      }
      final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
      await c.scaricaCorso('polito', corso);
      for (final d in ['community', 'corsi', 'moduli']) {
        expect(Directory('${cache.path}/$d').existsSync(), isFalse);
      }
      expect(inCache(relCorso), isTrue);
    });

    test('ateneo o corso non ancora nel database (404): non è un errore di '
        'rete', () async {
      final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
      for (final (a, k) in [('unina', 'unina-x'), ('polito', 'polito-x')]) {
        final r = await c.scaricaCorso(a, k);
        expect(r.corsiAssenti, isTrue, reason: k);
        expect(r.senzaRete, isFalse, reason: k);
        expect(r.corsi, isFalse, reason: k);
      }
    });

    test(
      'aggiornamento: con meta.json riscarica solo ciò che è cambiato',
      () async {
        final requests = <Uri>[];
        Map<String, String> remote(String versione, String shaIndice) => {
          ...polito(),
          'meta.json': jsonEncode({
            'schema': 1,
            'versione': versione,
            'atenei': {
              'polito': {
                'file': 'corsi/polito.json',
                'per_corso': relIndice,
                'sha256_per_corso': shaIndice,
              },
            },
          }),
        };
        Future<List<String>> scarica(String versione, String sha) async {
          requests.clear();
          await fakeCatalog(
            settings,
            cacheDir: cache,
            requests: requests,
            remote: remote(versione, sha),
          ).scaricaCorso('polito', corso, forza: true);
          return [
            for (final r in rel(requests))
              if (r != 'meta.json') r,
          ];
        }

        expect(await scarica('2026.10.13', 'a'), [
          relIndice,
          relCorso,
          'sessioni/polito.json',
        ]);
        // stessa versione e stesso indice: nulla da riscaricare
        expect(await scarica('2026.10.13', 'a'), isEmpty);
        // nuova versione, stesso indice: solo le sessioni
        expect(await scarica('2026.10.20', 'a'), ['sessioni/polito.json']);
        // indice cambiato (altri corsi) ma il corso è identico: solo l'indice
        expect(await scarica('2026.10.20', 'b'), [relIndice]);
      },
    );

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
          attesa: (r) => r == relCorso ? gate.future : null,
        );
        final a = c.scaricaCorso(
          'polito',
          corso,
          pulisci: false,
          soloCorso: true,
        );
        final b = c.scaricaCorso(
          'polito',
          corso,
          pulisci: false,
          soloCorso: true,
        );
        final completo = c.scaricaCorso('polito', corso);
        while (!rel(requests).contains(relCorso)) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        // letture durante il download: aspettano lo stesso download
        final diretta = c.corsiAteneo('polito', corso: corso);
        final sessioniF = c.sessioni('polito');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(c.progresso.value?.etichetta, 'corso di laurea');
        gate.complete();
        final esiti = await Future.wait([a, b, completo]);
        expect(esiti.every((r) => r.corsi && r.errore == null), isTrue);
        expect((await diretta)!.data.corsi.single.insegnamenti, hasLength(4));
        expect(await sessioniF, isNotNull);
        final r = rel(requests);
        for (final f in [relCorso, 'sessioni/polito.json']) {
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

    test('solo il corso (scelta del percorso), poi il resto: il corso non si '
        'riscarica', () async {
      final requests = <Uri>[];
      final c = fakeCatalog(
        settings,
        cacheDir: cache,
        requests: requests,
        remote: polito(),
      );
      final solo = await c.scaricaCorso(
        'polito',
        corso,
        pulisci: false,
        soloCorso: true,
      );
      expect(solo.corsi, isTrue);
      expect(rel(requests), ['meta.json', relIndice, relCorso]);
      expect(inCache('sessioni/polito.json'), isFalse);
      requests.clear();
      final tutto = await c.scaricaCorso('polito', corso);
      expect(tutto.corsiAggiornati, isTrue);
      expect(rel(requests), ['meta.json', 'sessioni/polito.json']);
    });

    test('download interrotto: la copia salvata resta intatta', () async {
      await fakeCatalog(
        settings,
        cacheDir: cache,
        remote: polito(),
      ).scaricaCorso('polito', corso);
      final prima = File('${cache.path}/$relCorso').readAsStringSync();
      final indice = indiceCambiato(polito());
      final c = CatalogService(
        settings,
        fetcher: (uri, {onProgress}) async {
          if (uri.path.endsWith('/indice.json')) return indice;
          throw CatalogNotFoundException();
        },
        fileFetcher: (uri, dest, {onProgress}) async {
          // metà file, poi la connessione cade
          await dest.writeAsString(prima.substring(0, prima.length ~/ 2));
          throw CatalogOfflineException('Connessione interrotta.');
        },
        assetLoader: (_) async => throw StateError('no'),
        assetBytesLoader: (_) async => throw StateError('no'),
        cacheDir: () async => cache,
      );
      final r = await c.scaricaCorso('polito', corso, forza: true);
      expect(r.corsi, isTrue);
      expect(r.errore, isA<CatalogOfflineException>());
      expect(File('${cache.path}/$relCorso').readAsStringSync(), prima);
      expect(File('${cache.path}/$relCorso.part').existsSync(), isFalse);
      expect(c.progresso.value, isNull);
    });

    test('file salvato corrotto: si elimina e si riscarica', () async {
      final intero = fileDaPerAteneo(polito(), relCorso)!;
      File('${cache.path}/$relCorso')
        ..createSync(recursive: true)
        ..writeAsStringSync(intero.substring(0, intero.length ~/ 3));
      final requests = <Uri>[];
      final c = fakeCatalog(
        settings,
        cacheDir: cache,
        requests: requests,
        remote: polito(),
      );
      final r = (await c.corsiAteneo('polito', corso: corso, remote: false))!;
      expect(r.source, CatalogSource.remote);
      expect(r.data.corsi.single.insegnamenti, hasLength(4));
      expect(rel(requests), containsAllInOrder([relIndice, relCorso]));
      expect(
        (await c.corsiAteneo('polito', corso: corso, remote: false))!.source,
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

    test('moduli: con gli insegnamenti indicati solo i loro', () async {
      final c = fakeCatalog(settings, cacheDir: cache, remote: polito());
      await c.scaricaCorso('polito', corso);
      final m = (await c.moduli(
        'polito',
        corso: corso,
        insegnamenti: [
          'polito-l8-ingegneria-informatica-01rkcpl',
          'polito-l8-ingegneria-informatica-03algo',
        ],
      ))!.data;
      expect(m.insegnamenti.keys.toSet(), {
        'polito-l8-ingegneria-informatica-01rkcpl',
        'polito-l8-ingegneria-informatica-03algo',
      });
    });

    test('file grande: lettura fuori dal thread dell\'interfaccia', () async {
      // un corso enorme (~10 MB), molto più grande di quelli veri
      final grande = {
        'schema': 1,
        'universita_id': 'polito',
        'corsi': [
          {
            'id': 'c200',
            'nome': 'Corso 200',
            'tipo': 'L',
            'insegnamenti': [
              for (var i = 0; i < 40000; i++)
                {
                  'id': 'c200-i$i',
                  'nome': 'Insegnamento $i del corso',
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
        'moduli': <String, Object>{},
      };
      File('${cache.path}/per_corso/polito/c200.json')
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
        corso: 'c200',
        remote: false,
        scarica: false,
      ))!;
      timer.cancel();
      expect(r.data.corsi.single.insegnamenti, hasLength(40000));
      // sul thread principale la decodifica bloccherebbe per centinaia di
      // millisecondi
      expect(pausa, lessThan(const Duration(milliseconds: 200)));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
