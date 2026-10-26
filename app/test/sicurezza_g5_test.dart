// Quinto giro della caccia alle falle di sicurezza e privacy (conferma
// finale): build automatica su Linux, ricontrollo delle correzioni del giro 4
// e superfici non ancora guardate a fondo (docs/sicurezza.md, «Giro 5»).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/router/app_link_guard.dart';
import 'package:university_notes/core/router/back_guard.dart';
import 'package:university_notes/core/services/external_launcher.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/utils/exclusion_filter.dart';

void main() {
  group('1. percorsi incompleti con le regole del sistema che apre il file', () {
    tearDown(() {
      ExternalLauncher.pathContext = () => p.context;
      ExternalLauncher.platform = () => defaultTargetPlatform;
    });

    test('su Android, Mac e Linux un percorso di Windows è relativo', () {
      // (con «assoluto per Windows o per Unix» un libro con «C:\…» arrivato
      // da un backup del PC passava: sul telefono «Apri» apriva la cartella
      // di lavoro dell'app, «.»)
      ExternalLauncher.pathContext = () => p.posix;
      for (final t in [
        r'C:\Corsi\libro.pdf',
        r'C:/Corsi/libro.pdf',
        r'D:libro.pdf',
        'libro.pdf',
        '.',
      ]) {
        expect(ExternalLauncher.unsafePathReason(t), contains('incompleto'),
            reason: t);
      }
      expect(ExternalLauncher.unsafePathReason('/home/x/libro.pdf'), isNull);
    });

    test('su Windows: unità senza barra, rete e «\\\\?\\» non passano', () {
      ExternalLauncher.pathContext = () => p.windows;
      for (final t in [r'C:relativo\libro.pdf', 'libro.pdf', r'.\x.pdf']) {
        expect(ExternalLauncher.unsafePathReason(t), contains('incompleto'),
            reason: t);
      }
      for (final t in [
        r'\\server\cartella\libro.pdf',
        r'\\?\C:\Corsi\libro.pdf',
        r'\\.\C:\Corsi\libro.pdf',
        '//server/cartella/libro.pdf',
      ]) {
        expect(ExternalLauncher.unsafePathReason(t), contains('rete'),
            reason: t);
      }
      expect(ExternalLauncher.unsafePathReason(r'C:\Corsi\libro.pdf'), isNull);
      // sull'unità della cartella di lavoro: un percorso completo per Windows
      expect(ExternalLauncher.unsafePathReason(r'\Corsi\libro.pdf'), isNull);
    });

    test('i programmi restano bloccati con le regole di entrambi i sistemi',
        () {
      for (final c in [p.windows, p.posix]) {
        ExternalLauncher.pathContext = () => c;
        final root = c == p.windows ? r'C:\x\' : '/x/';
        for (final n in ['setup.exe', 'a.bat', 'avvio.desktop', 'a.AppImage']) {
          expect(
            ExternalLauncher.unsafePathReason('$root$n', explicitChoice: true),
            isNotNull,
            reason: '$c $n',
          );
        }
      }
    });
  });

  group('2. «Indietro» su una pagina appena aperta', () {
    final key = GlobalKey<NavigatorState>();
    Widget app() => MaterialApp(
          navigatorKey: key,
          home: const Scaffold(body: Text('home')),
        );

    Route<void> page({bool canPop = true, ValueChanged<bool>? popped}) =>
        MaterialPageRoute<void>(
          builder: (_) => PopScope<Object?>(
            canPop: canPop,
            onPopInvokedWithResult: (didPop, _) => popped?.call(didPop),
            child: const Scaffold(body: Text('pagina')),
          ),
        );

    testWidgets('senza la guardia: asserzione di ModalRoute.willPop', (t) async {
      await t.pumpWidget(app());
      key.currentState!.push(page());
      // nessun fotogramma: la pagina non è ancora costruita
      expect(BackGuard.topRouteUnbuilt(key.currentState!), isTrue);
      await t.binding.handlePopRoute();
      // lo stesso errore della build automatica su Linux (scimmia R6)
      expect(t.takeException().toString(), contains("'scope != null'"));
      await t.pumpAndSettle();
    });

    testWidgets('con la guardia l\'«Indietro» arriva al fotogramma dopo',
        (t) async {
      installBackGuard(key);
      addTearDown(removeBackGuard);
      await t.pumpWidget(app());
      key.currentState!.push(page());
      expect(await t.binding.handlePopRoute(), isTrue);
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('pagina'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('con la guardia i PopScope della pagina valgono anche appena '
        'aperta', (t) async {
      installBackGuard(key);
      addTearDown(removeBackGuard);
      await t.pumpWidget(app());
      final calls = <bool>[];
      key.currentState!.push(page(canPop: false, popped: calls.add));
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('pagina'), findsOneWidget);
      expect(calls, [false]);
    });

    testWidgets('pagina costruita: nessun rinvio', (t) async {
      installBackGuard(key);
      addTearDown(removeBackGuard);
      await t.pumpWidget(app());
      key.currentState!.push(page());
      await t.pumpAndSettle();
      expect(BackGuard.topRouteUnbuilt(key.currentState!), isFalse);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('pagina'), findsNothing);
    });
  });

  group('3. esclusioni: nomi lunghi', () {
    final presets = kAllPresetPatterns;
    final long =
        '${'Tecniche della prevenzione nell\'ambiente e nei luoghi di lavoro ' * 3}'
        '- Lingua inglese';

    test('i filtri delle Impostazioni valgono su tutto il nome', () {
      expect(long.length, greaterThan(ExclusionFilter.maxTextLength));
      // (con il giro 4 si guardavano solo i primi 150 caratteri)
      expect(ExclusionFilter(presets).isExcluded([long]), isTrue);
      expect(
        ExclusionFilter([r'\bOFA\b']).isExcluded(['${'x ' * 700}OFA']),
        isTrue,
      );
      expect(ExclusionFilter(['tirocinio']).isExcluded(['${'a' * 1500}tirocinio']),
          isTrue);
      expect(ExclusionFilter(presets).isExcluded(['${'a' * 300}analisi']),
          isFalse);
    });

    test('espressioni con quantificatori sui primi '
        '${ExclusionFilter.maxTextLength} caratteri (nomi del database)', () {
      final f = ExclusionFilter([r'prevenzione.*inglese']);
      final name = 'Tecniche della prevenzione ${'x' * 100} lingua inglese';
      expect(name.length, lessThanOrEqualTo(ExclusionFilter.maxTextLength));
      expect(f.isExcluded([name]), isTrue);
      expect(
        f.isExcluded(['prevenzione ${'a' * 300} inglese']),
        isFalse,
      );
    });

    test('testi enormi: tempo limitato anche per i filtri senza '
        'quantificatori', () {
      final f = ExclusionFilter([
        ...presets,
        for (var i = 0; i < 30; i++) 'parola$i',
      ]);
      final sw = Stopwatch()..start();
      expect(f.isExcluded(['a' * 5000000]), isFalse);
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  group("4. indirizzi mandati da altre app all'attività principale", () {
    Future<void> push(WidgetTester t, String url) async {
      await t.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation',
        const JSONMethodCodec().encodeMethodCall(
          MethodCall('pushRouteInformation', {'location': url}),
        ),
        (_) {},
      );
      await t.pump();
    }

    testWidgets('nessun percorso cercato, nessun errore nel registro',
        (t) async {
      installAppLinkGuard();
      await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      for (final url in [
        'https://esempio.invalid/Scrivi a questo indirizzo',
        '/registra:avvia',
        'intent://x#Intent;end',
        'msauth.io.github.simomagnus.universitynotes://auth?code=x',
        'uninotes://widget/registra:avvia',
      ]) {
        await push(t, url);
        expect(t.takeException(), isNull, reason: url);
      }
      expect(find.text('home'), findsOneWidget);
    });
  });
}
