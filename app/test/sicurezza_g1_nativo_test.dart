import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/services/windows_tools.dart';

/// Caccia alle falle di sicurezza, primo giro, «superfici native e
/// installatori» (S1-C): componenti Android esportati e permessi, file
/// condivisi da altre app, argomenti dello schema uninotes: su Windows,
/// disinstallatore, programmi di sistema avviati dall'app, diritti di
/// macOS e del pacchetto MSIX. Swift, Kotlin, C++ e Inno Setup non si
/// eseguono qui: si controllano i sorgenti (Kotlin e C++ sono compilati a
/// parte, vedi docs/sicurezza.md, «Giro 1 — Superfici native e
/// installatori»).
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// Testo da [start] a [end] (escluso).
  String between(String src, String start, String end) {
    final from = src.indexOf(start);
    expect(from, greaterThanOrEqualTo(0), reason: start);
    final to = src.indexOf(end, from + start.length);
    expect(to, greaterThan(from), reason: end);
    return src.substring(from, to);
  }

  const kt = 'android/app/src/main/kotlin/io/github/simomagnus/universitynotes';
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';

  group('Android: componenti, permessi e backup', () {
    final manifest = read(manifestPath);

    test('esportati solo il lanciatore, «Condividi/Apri con» e il ritorno '
        'dall\'accesso, tutti con taskAffinity vuota', () {
      final exported = RegExp(r'<(activity|receiver|service|provider)\b[^>]*>')
          .allMatches(manifest)
          .map((m) => m.group(0)!)
          .where((c) => c.contains('android:exported="true"'))
          .toList();
      final names = [
        for (final c in exported)
          RegExp(r'android:name="([^"]+)"').firstMatch(c)!.group(1),
      ];
      expect(names, [
        '.MainActivity',
        '.ShareReceiverActivity',
        'com.linusu.flutter_web_auth_2.CallbackActivity',
      ]);
      // niente «task hijacking» (StrandHogg): le attività esportate non
      // entrano nel task di un'altra app
      for (final c in exported) {
        expect(c, contains('android:taskAffinity=""'), reason: c);
      }
    });

    test('backup automatico e trasferimento tra telefoni esclusi', () {
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, contains('android:fullBackupContent="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      final rules = read(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      for (final part in ['cloud-backup', 'device-transfer']) {
        final body = between(rules, '<$part>', '</$part>');
        for (final domain in [
          'root',
          'file',
          'database',
          'sharedpref',
          'external',
        ]) {
          expect(
            body,
            contains('<exclude domain="$domain" path="." />'),
            reason: '$part/$domain',
          );
        }
        expect(body, isNot(contains('<include')), reason: part);
      }
    });

    test('niente traffico in chiaro né build di debug forzata', () {
      expect(manifest, isNot(contains('usesCleartextTraffic="true"')));
      expect(manifest, isNot(contains('android:debuggable')));
      final gradle = read('android/app/build.gradle.kts');
      expect(gradle, isNot(contains('isDebuggable = true')));
      expect(gradle, isNot(contains('isMinifyEnabled = false')));
    });

    test('accesso a foto e video (aggiunto da open_filex) tolto dal '
        'manifest finale', () {
      expect(
        manifest,
        contains('xmlns:tools="http://schemas.android.com/tools"'),
      );
      for (final p in ['READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO']) {
        expect(
          manifest,
          contains(
            '<uses-permission android:name="android.permission.$p" '
            'tools:node="remove"/>',
          ),
          reason: p,
        );
      }
    });

    test('ogni PendingIntent dei sorgenti Kotlin è immutabile', () {
      final files = Directory(kt)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'));
      var count = 0;
      for (final f in files) {
        final src = read(f.path);
        for (final m in RegExp(
          r'PendingIntent\.get(Activity|Broadcast|Service)\(([^;]*?)\)\s*\n',
          dotAll: true,
        ).allMatches(src)) {
          count++;
          expect(m.group(2), contains('FLAG_IMMUTABLE'), reason: f.path);
          expect(m.group(2), isNot(contains('FLAG_MUTABLE')), reason: f.path);
        }
      }
      expect(count, greaterThanOrEqualTo(3));
    });
  });

  group('Android: file condivisi da altre app', () {
    final share = read('$kt/IncomingShare.kt');

    test('i fornitori dell\'app si riconoscono anche scritti con l\'utente '
        'davanti (content://0@…)', () {
      // ContentResolver toglie «0@» prima di cercare il fornitore: con il
      // solo controllo sul nome, content://0@<pacchetto>.fileProvider…/root/…
      // (FileProvider di open_filex con root-path) faceva copiare all'app i
      // suoi file privati, poi proposti per il salvataggio e il cloud
      expect(share, contains("uri.authority?.substringAfterLast('@')"));
      final own = between(share, 'fun isOwnProvider(', '\n    }\n');
      expect(own, contains('authorityOf(uri)'));
      expect(own, contains('resolveContentProvider(authority, 0)'));
      expect(own, contains('packageName == context.packageName'));
      final collect = between(share, 'fun collect(', '// Solo testo');
      expect(collect, contains('if (uri.scheme != "content") continue'));
      expect(collect, contains('if (isOwnProvider(context, uri)) continue'));
      expect(collect, isNot(contains('uri.authority?.startsWith')));
    });

    test(
      'il nome scelto dall\'altra app non esce dalla cartella condivisi',
      () {
        final name = between(share, 'private fun nameOf(', 'fun collect(');
        expect(name, contains(".substringAfterLast('/')"));
        expect(name, contains('n == "." || n == ".."'));
      },
    );
  });

  group('Windows: schema uninotes: e programmi di sistema', () {
    test('un collegamento non passa argomenti all\'app (niente '
        '«--disinstalla» iniettato con le virgolette)', () {
      final main = read('windows/runner/main.cpp');
      final fromLink = between(main, 'bool FromLink(', '\n}\n');
      // solo il primo argomento, lo schema senza maiuscole/minuscole
      expect(fromLink, contains('args.front()'));
      expect(fromLink, contains("c - 'A' + 'a'"));
      expect(
        main,
        contains(
          'from_link ? std::vector<std::string>() : GetCommandLineArguments()',
        ),
      );
      // gli argomenti di Dart sono gli stessi controllati per --disinstalla
      expect(
        main,
        contains(
          'std::vector<std::string> command_line_arguments = launch_args;',
        ),
      );
      final dart = between(
        main,
        'int APIENTRY wWinMain(',
        'FlutterWindow window(',
      );
      expect(
        RegExp('GetCommandLineArguments\\(\\)').allMatches(dart).length,
        2,
      );
    });

    test('lo schema si registra con l\'indirizzo fra virgolette', () {
      final iss = read('windows/installer/uninotes.iss');
      expect(iss, contains(r'ValueData: """{app}\uninotes.exe"" ""%1"""'));
    });

    test('reg, cmdkey, PowerShell, rundll32 ed Esplora file con il percorso '
        'completo', () {
      expect(WindowsTools.reg, endsWith(r'\System32\reg.exe'));
      expect(WindowsTools.cmdkey, endsWith(r'\System32\cmdkey.exe'));
      expect(WindowsTools.rundll32, endsWith(r'\System32\rundll32.exe'));
      expect(
        WindowsTools.powershell,
        endsWith(r'\System32\WindowsPowerShell\v1.0\powershell.exe'),
      );
      expect(WindowsTools.explorer, endsWith(r'\explorer.exe'));
      expect(RegExp(r'^[A-Za-z]:\\').hasMatch(WindowsTools.reg), isTrue);
      // nessun programma di Windows avviato con il solo nome
      final bare = RegExp(
        r'''Process\.(run|start|runSync)\(\s*['"](reg|cmdkey|powershell|'''
        r'''explorer|rundll32|cmd|taskkill|schtasks|wmic|certutil)'''
        r'''(\.exe)?['"]''',
      );
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (bare.hasMatch(read(f.path))) hits.add(f.path);
      }
      expect(hits, isEmpty);
    });
  });

  group('installatore di Windows', () {
    final iss = read('windows/installer/uninotes.iss');

    test('per utente, senza amministratore', () {
      expect(iss, contains('PrivilegesRequired=lowest'));
      expect(iss, contains(r'DefaultDirName={localappdata}\Programs\UniNotes'));
      expect(iss, isNot(contains('PrivilegesRequiredOverridesAllowed')));
      expect(iss, isNot(contains('runascurrentuser')));
    });

    test('la cartella si toglie per intero solo se è quella di UniNotes '
        '(mai «D:\\Programmi» o Documenti scritti a mano)', () {
      final line = iss
          .split('\n')
          .firstWhere((l) => l.startsWith('Type: filesandordirs'));
      expect(line, contains('Check: CartellaDelProgramma'));
      final check = between(
        iss,
        'function CartellaDelProgramma(): Boolean;',
        '\nend;',
      );
      expect(check, contains("'UniNotes'"));
      expect(check, contains('{userdocs}'));
      // DelTree solo dopo lo stesso controllo
      final step = between(
        iss,
        'procedure CurUninstallStepChanged',
        '\nend;\n',
      );
      expect(
        RegExp(r'if CartellaDelProgramma\(\) then\s+DelTree\(').hasMatch(step),
        isTrue,
      );
      expect(RegExp('DelTree\\(').allMatches(iss).length, 1);
    });
  });

  group('pacchetti per Microsoft Store e macOS', () {
    test('MSIX: solo internet in uscita, microfono e runFullTrust', () {
      final m = read('windows/msix/AppxManifest.xml');
      final caps =
          RegExp(r'<(?:rescap:|uap:)?(?:Device)?Capability Name="([^"]+)"')
              .allMatches(between(m, '<Capabilities>', '</Capabilities>'))
              .map((x) => x.group(1))
              .toList();
      expect(caps, ['internetClient', 'runFullTrust', 'microphone']);
    });

    test('macOS: sandbox, ascolto solo su localhost, nessun diritto largo '
        'sui file', () {
      for (final f in [
        'macos/Runner/Release.entitlements',
        'macos/Runner/DebugProfile.entitlements',
      ]) {
        final e = read(f);
        expect(
          e,
          contains('<key>com.apple.security.app-sandbox</key>\n\t<true/>'),
          reason: f,
        );
        for (final wide in [
          'files.all',
          'files.downloads',
          'assets.',
          'cs.disable-library-validation',
          'cs.allow-unsigned-executable-memory',
          'cs.disable-executable-page-protection',
          'temporary-exception',
        ]) {
          expect(e, isNot(contains(wide)), reason: '$f: $wide');
        }
      }
      expect(
        read('macos/Runner/Release.entitlements'),
        isNot(contains('allow-jit')),
      );
      // network.server serve solo al ritorno dall'accesso: ogni server
      // dell'app ascolta su localhost
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final m in RegExp(
          r'(HttpServer|ServerSocket|RawServerSocket)\.bind\(\s*([^,]+),',
        ).allMatches(read(f.path))) {
          expect(m.group(2), contains('loopback'), reason: f.path);
        }
      }
    });

    test('iOS e macOS: nessuna eccezione ad App Transport Security', () {
      for (final f in ['ios/Runner/Info.plist', 'macos/Runner/Info.plist']) {
        final plist = read(f);
        expect(plist, isNot(contains('NSAllowsArbitraryLoads')), reason: f);
        expect(plist, isNot(contains('NSExceptionDomains')), reason: f);
      }
    });
  });
}
