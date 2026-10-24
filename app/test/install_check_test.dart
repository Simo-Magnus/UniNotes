import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:university_notes/core/services/install_check.dart';
import 'package:university_notes/core/services/local_data.dart';
import 'package:university_notes/features/onboarding/install_questions.dart';

void main() {
  late Directory tmp;
  var dbExists = false;
  var wiped = 0;
  String? identity;
  var shared = <Directory>[];

  InstallCheck check(String version) => InstallCheck(
    version: version,
    databaseExists: () async => dbExists,
    wipeSecrets: () async => wiped++,
    sharedNotes: () async => LocalData.withFiles(shared),
    identity: () async => identity,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('install_');
    dbExists = false;
    wiped = 0;
    identity = null;
    shared = [];
  });
  tearDown(() => tmp.delete(recursive: true));

  group('primo avvio dopo l\'installazione', () {
    test(
      'nuova installazione: via le credenziali rimaste, una volta',
      () async {
        final st = await check('2026.9.0').run();
        expect(st.fresh, isTrue);
        expect(st.needsAnswer, isFalse);
        expect(wiped, 1);
        dbExists = true; // l'app ha creato il database
        final again = await check('2026.9.0').run();
        expect(again.fresh, isFalse);
        expect(wiped, 1);
      },
    );

    test(
      'aggiornamento da una versione senza segno: nessuna pulizia',
      () async {
        dbExists = true;
        final st = await check('2026.9.0').run();
        expect(st.fresh, isFalse);
        expect(st.needsAnswer, isFalse);
        expect(wiped, 0);
      },
    );

    test('reinstallazione con i dati rimasti (Mac, PC): si chiede', () async {
      identity = 'mac:1:100';
      await check('2026.9.0').run();
      dbExists = true;
      // app trascinata nel Cestino e reinstallata (stessa versione)
      identity = 'mac:2:200';
      final st = await check('2026.9.0').run();
      expect(st.leftover, isTrue);
      expect(wiped, 1); // solo alla prima installazione
      // senza risposta la domanda torna
      expect((await check('2026.9.0').run()).leftover, isTrue);
      await InstallCheck.answered(InstallCheck.pendingLeftoverKey);
      expect((await check('2026.9.0').run()).leftover, isFalse);
    });

    test('reinstallazione di una versione più vecchia: si chiede', () async {
      identity = 'a';
      await check('2026.10.0').run();
      dbExists = true;
      identity = 'b';
      expect((await check('2026.9.0').run()).leftover, isTrue);
    });

    test('aggiornamento a una versione più nuova: mai domande', () async {
      identity = 'a';
      await check('2026.9.0').run();
      dbExists = true;
      identity = 'b';
      final st = await check('2026.10.0').run();
      expect(st.leftover, isFalse);
      expect(st.fresh, isFalse);
    });

    test('stessa installazione: nessuna domanda', () async {
      identity = 'a';
      await check('2026.9.0').run();
      dbExists = true;
      expect((await check('2026.9.0').run()).needsAnswer, isFalse);
    });

    test('appunti in Documenti (PC): usa o ignora', () async {
      final corsi = Directory(p.join(tmp.path, 'UniNotes', 'Corsi'));
      File(p.join(corsi.path, 'Analisi', 'a.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
      shared = [corsi, Directory(p.join(tmp.path, 'vuota'))];
      final st = await check('2026.9.0').run();
      expect(st.fresh, isTrue);
      expect(st.sharedNotes.map((d) => d.path), [corsi.path]);
      // «Ignora»: la cartella si mette da parte, i file restano
      expect(await LocalData.setAside(st.sharedNotes), isEmpty);
      expect(corsi.existsSync(), isFalse);
      expect(
        File(
          p.join('${corsi.path}${LocalData.ignoredSuffix}', 'Analisi', 'a.md'),
        ).existsSync(),
        isTrue,
      );
      dbExists = true;
      expect((await check('2026.9.0').run()).sharedNotes, isEmpty);
    });
  });

  test('confronto delle versioni', () {
    expect(compareVersions('2026.9.0', '2026.9.0+3'), 0);
    expect(compareVersions('2026.10.0', '2026.9.0'), greaterThan(0));
    expect(compareVersions('2026.9', '2026.9.1'), lessThan(0));
  });

  test('voci del Gestore credenziali di Windows dell\'app', () {
    const out = '''
Destinazione: LegacyGeneric:target=key_uninotes_VGhpcyBpcyB0aGUgcHJlZml4IGZv_
Destinazione: LegacyGeneric:target=uninotes_VGhpcyBpcyB0aGUgcHJlZml4IGZv_onedrive.refreshToken
Destinazione: LegacyGeneric:target=git:https://github.com
Destinazione: LegacyGeneric:target=altro_VGhpcyBpcyB0aGUgcHJlZml4IGZv_x
''';
    expect(LocalData.windowsCredentialTargets(out), [
      'key_uninotes_VGhpcyBpcyB0aGUgcHJlZml4IGZv_',
      'uninotes_VGhpcyBpcyB0aGUgcHJlZml4IGZv_onedrive.refreshToken',
    ]);
  });

  group('domande all\'avvio', () {
    Future<void> pump(
      WidgetTester tester,
      Future<void> Function(BuildContext) run,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => run(context),
              child: const Text('via'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('via'));
      await tester.pumpAndSettle();
    }

    testWidgets('dati rimasti: «Elimina» pulisce e ricontrolla', (
      tester,
    ) async {
      var erased = false;
      var answeredKeys = <String>[];
      await pump(
        tester,
        (c) => askInstallQuestions(
          c,
          const InstallStatus(leftover: true),
          eraseLeftover: () async => erased = true,
          recheck: () async => const InstallStatus(fresh: true),
          answered: (k) async => answeredKeys.add(k),
        ),
      );
      expect(find.textContaining('li usi o li elimini?'), findsOneWidget);
      expect(find.byType(TextButton), findsNWidgets(2)); // «via» + «Elimina»
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.text('Elimina'));
      await tester.pumpAndSettle();
      expect(erased, isTrue);
      expect(answeredKeys, [InstallCheck.pendingLeftoverKey]);
    });

    testWidgets('appunti in Documenti: «Usa» non sposta nulla', (tester) async {
      var setAside = false;
      final answeredKeys = <String>[];
      await pump(
        tester,
        (c) => askInstallQuestions(
          c,
          InstallStatus(
            sharedNotes: [Directory('C:/Documenti/UniNotes/Corsi')],
          ),
          eraseLeftover: () async {},
          recheck: () async => const InstallStatus(),
          setAside: (d) async {
            setAside = true;
            return const [];
          },
          answered: (k) async => answeredKeys.add(k),
        ),
      );
      expect(find.textContaining('li usi o li ignori?'), findsOneWidget);
      await tester.tap(find.text('Usa'));
      await tester.pumpAndSettle();
      expect(setAside, isFalse);
      expect(answeredKeys, [InstallCheck.pendingSharedKey]);
    });
  });
}
