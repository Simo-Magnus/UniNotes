import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Caricamento su App Store Connect dalla build automatica, senza Mac
/// (guida alla pubblicazione §6.4, §7.2 e §7.5): job «testflight» (iPhone e iPad) e
/// «mac-app-store» (Mac), notarizzazione del DMG con la chiave API nel job
/// «macos», IPA ad hoc da installare con Safari sugli iPhone registrati
/// (manifest itms-services, release «ultima-build», pagina sito/ios-prova/).
/// Controlli statici sulle regole dei giri di sicurezza
/// (docs/sicurezza.md): secret solo come variabili d'ambiente, chiave in un
/// file temporaneo cancellato anche in caso di errore, job solo per main e
/// l'avvio manuale, passi condizionati dai secret.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  final app = read('../.github/workflows/app.yml');
  final script = read('tool/app_store_connect.sh');

  /// Testo di un job (da «  nome:» al job successivo).
  String job(String nome) {
    final i = app.indexOf('\n  $nome:\n');
    if (i < 0) throw StateError('job $nome assente in app.yml');
    final dopo = RegExp(r'\n  [a-z][a-z-]*:\n')
        .firstMatch(app.substring(i + 1));
    return dopo == null
        ? app.substring(i)
        : app.substring(i, i + 1 + dopo.start);
  }

  /// Passi di un job, ognuno dal suo «      - ».
  List<String> passi(String testo) {
    final inizio = testo.indexOf('\n    steps:\n');
    if (inizio < 0) throw StateError('job senza passi');
    return testo
        .substring(inizio)
        .split(RegExp(r'\n(?=      - )'))
        .skip(1)
        .toList();
  }

  /// Testo dei comandi (righe «run: …» e blocchi «run: |»).
  List<String> comandi(String testo) {
    final out = <String>[];
    final righe = testo.split('\n');
    for (var i = 0; i < righe.length; i++) {
      final m = RegExp(r'^( *)(?:- )?run: (.*)$').firstMatch(righe[i]);
      if (m == null) continue;
      if (m[2] != '|') {
        out.add(m[2]!);
        continue;
      }
      final rientro = m[1]!.length;
      for (var j = i + 1; j < righe.length; j++) {
        final r = righe[j];
        if (r.trim().isNotEmpty && r.length - r.trimLeft().length <= rientro) {
          break;
        }
        out.add(r);
      }
    }
    return out;
  }

  const soloMain =
      "    if: github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && github.ref == 'refs/heads/main')\n";
  const conSecret = "if: steps.testflight.outputs.testflight == 'si'";

  for (final nome in ['testflight', 'mac-app-store']) {
    group('job $nome', () {
      final testo = job(nome);
      final elenco = passi(testo);

      test('solo push su main e avvio manuale, mai pull request', () {
        expect(testo, contains(soloMain));
        expect(testo, isNot(contains('pull_request')));
        // nessun permesso in più: vale contents: read del workflow
        expect(testo, isNot(contains('    permissions:')));
        expect(testo, contains('    needs: test\n'));
        expect(
          testo,
          contains(
            '      testflight: \${{ steps.testflight.outputs.testflight }}\n',
          ),
        );
      });

      test('i secret si controllano prima, poi ogni passo dipende da loro', () {
        expect(elenco.first, contains('uses: actions/checkout@'));
        expect(elenco.first, contains('persist-credentials: false'));
        expect(elenco[1], contains('id: testflight'));
        expect(
          elenco[1],
          contains('run: bash tool/app_store_connect.sh controlla testflight'),
        );
        for (final s in [
          'ASC_KEY_ID',
          'ASC_ISSUER_ID',
          'ASC_KEY_P8_BASE64',
          'APPLE_TEAM_ID',
        ]) {
          expect(elenco[1], contains('$s: \${{ secrets.$s }}'), reason: s);
        }
        final pulizia = elenco.last;
        for (final p in elenco.sublist(2, elenco.length - 1)) {
          expect(p, contains(conSecret), reason: p.split('\n').first);
        }
        expect(pulizia, contains('if: always()'));
        expect(pulizia, isNot(contains(conSecret)));
      });

      test('secret solo come variabili d\'ambiente, nessuna espressione nei comandi', () {
        for (final r in testo.split('\n')) {
          if (!r.contains('secrets.')) continue;
          expect(
            r,
            matches(
              RegExp(
                r'^          [A-Z0-9_]+: \$\{\{ secrets\.[A-Z0-9_]+ \}\}$',
              ),
            ),
          );
        }
        final c = comandi(testo);
        expect(c, isNotEmpty);
        for (final r in c) {
          expect(r, isNot(contains('\${{')), reason: r);
        }
        // la chiave entra solo nel passo che scrive il file
        final conChiave = elenco
            .where((p) => p.contains('ASC_KEY_P8_BASE64: '))
            .map((p) => p.split('\n').first)
            .toList();
        expect(conChiave, hasLength(2));
        expect(
          elenco.where(
            (p) =>
                p.contains('ASC_KEY_P8_BASE64: ') &&
                p.contains('run: bash tool/app_store_connect.sh chiave'),
          ),
          hasLength(1),
        );
      });

      test('chiave cancellata alla fine, anche dopo un errore', () {
        expect(
          elenco.last,
          contains(
            'run: rm -rf "\$HOME/.appstoreconnect/private_keys" "\$RUNNER_TEMP/asc"',
          ),
        );
        // senza dipendere dal checkout o dalla cartella app/
        expect(elenco.last, contains('working-directory: .'));
      });

      test('firma nel cloud ed esportazione per l\'App Store', () {
        expect(testo, contains('app_store_connect.sh esporta '));
        expect(testo, contains(' app-store-connect\n'));
        expect(testo, contains('--dart-define=STORE=appstore'));
        expect(testo, contains('--dart-define=DONATIONS=none'));
        expect(testo, contains('APP_BUILD: \${{ needs.test.outputs.build }}'));
        expect(
          testo,
          contains('APP_VERSION: \${{ needs.test.outputs.version }}'),
        );
        expect(testo, contains('--config-only'));
        expect(testo, contains('xcodebuild archive -quiet'));
        // App Store Connect: solo Xcode 26 o successivo
        expect(testo, contains(r'if [ "${major:-0}" -lt 26 ]; then'));
      });
    });
  }

  group('iPhone e iPad', () {
    final testo = job('testflight');

    test(
      'archivio senza firma, team e firma automatica da riga di comando',
      () {
        expect(
          testo,
          contains(
            '"DEVELOPMENT_TEAM=\$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=NO',
          ),
        );
        expect(testo, contains("-destination 'generic/platform=iOS'"));
        expect(
          testo,
          contains('flutter build ios --release --config-only --no-codesign'),
        );
        expect(testo, contains(r'"--build-number=$APP_BUILD"'));
        expect(
          testo,
          contains('carica "\$ipa" ios io.github.simomagnus.universitynotes'),
        );
      },
    );
  });

  group('ad hoc da Safari (iPhone registrati, sito/ios-prova/)', () {
    final testo = job('testflight');
    final elenco = passi(testo);
    const ipaFisso =
        'releases/download/ultima-build/UniNotes-ios-adhoc.ipa';
    const bundle = 'io.github.simomagnus.universitynotes';

    int indice(String s) => elenco.indexWhere((p) => p.contains(s));

    test('stesso archivio, metodo release-testing, dopo l\'export per l\'App '
        'Store e prima del caricamento', () {
      final i = indice('id: adhoc');
      expect(i, greaterThan(0));
      final passo = elenco[i];
      expect(
        passo,
        contains(
          'esporta "\$RUNNER_TEMP/asc/Runner.xcarchive" "\$RUNNER_TEMP/asc/ios-adhoc" release-testing',
        ),
      );
      expect(i, greaterThan(indice(' app-store-connect\n')));
      expect(i, lessThan(indice('Caricamento su App Store Connect (TestFlight)')));
      // un solo archivio: nessuna seconda compilazione
      expect('xcodebuild archive -quiet'.allMatches(testo), hasLength(1));
      expect(passo, contains(conSecret));
      // nessun secret in più: la chiave .p8 resta solo nei due passi previsti
      expect(passo, isNot(contains('ASC_KEY_P8_BASE64')));
    });

    test('export ad hoc non bloccante: senza dispositivi solo un avviso', () {
      final passo = elenco[indice('id: adhoc')];
      expect(passo, contains('if bash tool/app_store_connect.sh esporta '));
      expect(passo, contains('echo "adhoc=si" >> "\$GITHUB_OUTPUT"'));
      expect(passo, contains('echo "adhoc=no" >> "\$GITHUB_OUTPUT"'));
      expect(passo, contains('::warning title=Ad hoc::'));
      expect(passo, isNot(contains('exit 1')));
      expect(passo, isNot(contains('::error')));
      // ogni passaggio dentro la condizione di if (catena con &&)
      final condizione = passo.substring(
        passo.indexOf('if bash tool/app_store_connect.sh esporta '),
        passo.indexOf('; then'),
      );
      for (final r in condizione.split('\n').skip(1)) {
        expect(r.trimLeft(), startsWith('&& '), reason: r);
      }
      final artefatto = elenco[indice('name: uninotes-ios-adhoc')];
      expect(
        artefatto,
        contains(
          "if: steps.testflight.outputs.testflight == 'si' && steps.adhoc.outputs.adhoc == 'si'",
        ),
      );
      expect(artefatto, contains('continue-on-error: true'));
      expect(artefatto, contains('uses: actions/upload-artifact@'));
      // la chiave si cancella dopo, sempre
      expect(elenco.last, contains('if: always()'));
    });

    test('manifest della build: bundle ID e IPA fisso in HTTPS', () {
      final passo = elenco[indice('id: adhoc')];
      expect(
        passo,
        contains(
          'manifesto "\$uscita/UniNotes-ios-adhoc-manifest.plist" $bundle "\$APP_VERSION" "https://github.com/\$GITHUB_REPOSITORY/$ipaFisso"',
        ),
      );
      expect(passo, contains('cp "\$ipa" "\$uscita/UniNotes-ios-adhoc.ipa"'));
      // diagnosi: tipo, scadenza e numero di dispositivi del profilo
      expect(passo, contains('app_store_connect.sh profilo '));
    });

    test('«ultima-build» pubblica IPA e manifest senza dipendere da '
        'TestFlight', () {
      final ultima = job('ultima-build');
      expect(
        ultima,
        contains('    needs: [android, windows, macos, ios, testflight]\n'),
      );
      expect(ultima, contains('!cancelled()'));
      for (final j in ['android', 'windows', 'macos', 'ios']) {
        expect(ultima, contains("needs.$j.result == 'success'"), reason: j);
      }
      expect(ultima, isNot(contains("needs.testflight.result == 'success'")));
      expect(
        ultima,
        contains(
          'cp dist/uninotes-ios-adhoc/UniNotes-ios-adhoc.ipa out/UniNotes-ios-adhoc.ipa',
        ),
      );
      expect(
        ultima,
        contains(
          'cp dist/uninotes-ios-adhoc/UniNotes-ios-adhoc-manifest.plist out/UniNotes-ios-adhoc-manifest.plist',
        ),
      );
      expect(
        ultima,
        contains('          TESTFLIGHT_ESITO: \${{ needs.testflight.result }}\n'),
      );
      // l'ad hoc non entra nella release dei tag v*
      expect(job('release'), isNot(contains('adhoc')));
    });

    test('manifest del sito: bundle ID, IPA in HTTPS, nessun reindirizzamento '
        'per il manifest', () {
      final m = read('../sito/ios-prova/manifest.plist');
      String valore(String chiave) {
        final r = RegExp(
          '<key>$chiave</key>\\s*<string>([^<]+)</string>',
        ).allMatches(m).map((x) => x[1]!).toList();
        expect(r, hasLength(1), reason: chiave);
        return r.single;
      }

      expect(valore('bundle-identifier'), bundle);
      expect(valore('url'), 'https://github.com/Simo-Magnus/UniNotes/$ipaFisso');
      expect(valore('title'), 'UniNotes');
      expect(valore('bundle-version'), isNotEmpty);
      expect(m, contains('<string>software-package</string>'));
      expect(m, contains('<string>software</string>'));
      // tutti gli indirizzi in HTTPS (il DOCTYPE di Apple non è un valore)
      expect(m, isNot(contains('<string>http://')));
    });

    test('pagina di installazione: link itms-services, solo Safari, '
        'non collegata dalla home', () {
      final p = read('../sito/ios-prova/index.html');
      expect(
        p,
        contains(
          'href="itms-services://?action=download-manifest&amp;url=https://simo-magnus.github.io/UniNotes/ios-prova/manifest.plist"',
        ),
      );
      // alternativa: il manifest della release, con la versione della build
      expect(
        p,
        contains(
          'href="itms-services://?action=download-manifest&amp;url=https://github.com/Simo-Magnus/UniNotes/releases/download/ultima-build/UniNotes-ios-adhoc-manifest.plist"',
        ),
      );
      // ogni itms-services punta a un manifest in HTTPS
      for (final l in RegExp(r'itms-services://[^"]*').allMatches(p)) {
        expect(l[0], contains('&amp;url=https://'), reason: l[0]);
        expect(l[0], endsWith('.plist'), reason: l[0]);
      }
      expect(p, contains('Safari'));
      expect(p, contains('Modalità sviluppatore'));
      expect(p, contains('iOS 15'));
      expect(p, contains('<meta name="robots" content="noindex">'));
      expect(p.toLowerCase(), isNot(contains('goatcounter.com/count')));
      expect(read('../sito/index.html'), isNot(contains('ios-prova')));
      expect(read('../sito/link/index.html'), isNot(contains('ios-prova')));
    });
  });

  group('macOS (DMG e zip)', () {
    final testo = job('macos');

    test('nuova firma dopo i modelli, poi controllo di app, zip e DMG', () {
      // fino al 30/10/2026 i modelli entravano dopo la firma di flutter build
      // e, senza certificato, nessuno firmava di nuovo: «app danneggiata»
      final modelli = testo.indexOf(
        'prepara_modello_whisper_desktop.py --installa',
      );
      final firma = testo.indexOf(
        'codesign --force --sign - --entitlements macos/Runner/Release.entitlements "\$app"',
      );
      final certificato = testo.indexOf('--sign "\$MACOS_SIGN_IDENTITY"');
      final controllo = testo.indexOf('controlla_build_macos.sh app ');
      final zip = testo.indexOf('ditto -c -k --keepParent');
      expect(modelli, greaterThan(0));
      expect(firma, greaterThan(modelli));
      expect(certificato, greaterThan(modelli));
      expect(controllo, greaterThan(firma));
      expect(zip, greaterThan(controllo));
      expect(testo, contains("if: env.HAS_MACOS_CERT != 'true'"));
      expect(testo, contains('controlla_build_macos.sh zip uninotes-macos.zip'));
      expect(testo, contains('controlla_build_macos.sh dmg UniNotes.dmg'));
      final s = read('tool/controlla_build_macos.sh');
      expect(s, contains('codesign --verify --deep --strict'));
      expect(s, contains('kill -0'));
      expect(s, contains('Contents/Resources/'));
    });
  });

  group('Mac App Store', () {
    final testo = job('mac-app-store');

    test('firma locale con gli entitlement della sandbox, poi nel cloud', () {
      expect(testo, contains('CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-'));
      expect(
        testo,
        contains(
          'codesign --force --sign - --entitlements macos/Runner/Release.entitlements "\$app"',
        ),
      );
      expect(testo, contains("-destination 'generic/platform=macOS'"));
      // numero di build diverso da quello dell'iPhone, sempre crescente
      expect(testo, contains(r'"--build-number=$APP_BUILD.1"'));
      expect(
        testo,
        contains('carica "\$pkg" macos io.github.simomagnus.universitynotes'),
      );
      // modelli inclusi prima della nuova firma
      final modelli = testo.indexOf('prepara_modello_parakeet.py --installa');
      expect(modelli, greaterThan(0));
      expect(testo.indexOf('codesign --force --sign -'), greaterThan(modelli));
    });

    test(
      'entitlement ammessi dal Mac App Store, niente eccezioni temporanee',
      () {
        final e = read('macos/Runner/Release.entitlements');
        expect(
          e,
          contains('<key>com.apple.security.app-sandbox</key>\n\t<true/>'),
        );
        expect(e, isNot(contains('temporary-exception')));
        expect(e, isNot(contains('com.apple.security.cs.allow-jit')));
        expect(e, isNot(contains('get-task-allow')));
      },
    );
  });

  group('DMG notarizzato con la chiave API', () {
    final testo = job('macos');

    test('solo per main, tag v* e avvio manuale; chiave cancellata', () {
      expect(
        testo,
        contains(
          "RAMO_PUBBLICATO: \${{ github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v'))) }}",
        ),
      );
      final i = testo.indexOf('con la chiave API (solo con i secret)');
      expect(i, greaterThan(0));
      final passo = testo.substring(i, testo.indexOf('\n      - ', i));
      expect(passo, contains("env.RAMO_PUBBLICATO == 'true'"));
      expect(passo, contains("env.HAS_APPLE_NOTARY != 'true'"));
      expect(
        passo,
        contains('bash tool/app_store_connect.sh notarizza UniNotes.dmg'),
      );
      final pulizia = testo.substring(
        testo.indexOf('- name: Cancella la chiave API, il certificato'),
      );
      expect(pulizia, contains('if: always()'));
      expect(pulizia, contains(r'"$HOME/.appstoreconnect/private_keys"'));
    });
  });

  group('script della chiave (app/tool/app_store_connect.sh)', () {
    test('valori controllati prima di entrare in percorsi e file', () {
      expect(script, contains('set -euo pipefail'));
      expect(script, contains(r'=~ ^[A-Z0-9]{10}$ ]]'));
      expect(
        script,
        contains(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ),
      );
      expect(script, contains(r'=~ ^[0-9]{6,12}$ ]]'));
    });

    test('chiave con permessi ristretti, mai nel log', () {
      expect(script, contains('umask 077'));
      expect(script, contains(r'chmod 600 "$f"'));
      expect(script, isNot(contains('set -x')));
      expect(script, isNot(contains(r'echo "$ASC_KEY_P8_BASE64')));
      expect(script, isNot(contains(r'echo $ASC_KEY_P8_BASE64')));
      expect(
        script,
        contains(r'CARTELLA_CHIAVI="$HOME/.appstoreconnect/private_keys"'),
      );
      expect(script, contains(r'rm -rf "$CARTELLA_CHIAVI" "$TEMP_ASC"'));
    });

    test('firma nel cloud: chiave API e aggiornamento dei profili', () {
      for (final a in [
        '-allowProvisioningUpdates',
        r'-authenticationKeyPath "$f"',
        r'-authenticationKeyID "$ASC_KEY_ID"',
        r'-authenticationKeyIssuerID "$ASC_ISSUER_ID"',
        '<string>automatic</string>',
        '<key>manageAppVersionAndBuildNumber</key>\n\t<false/>',
      ]) {
        expect(script, contains(a), reason: a);
      }
    });

    test('esportazione: solo i metodi previsti, opzioni dell\'App Store '
        'solo per l\'App Store', () {
      expect(script, contains('    app-store-connect | release-testing) ;;'));
      expect(script, contains('if [ "\$metodo" = "app-store-connect" ]; then'));
      expect(script, contains('\$solo_app_store\n</dict>'));
    });

    test('manifest e profilo dell\'ad hoc: valori controllati, UDID mai '
        'stampati', () {
      expect(
        script,
        contains(r'[[ "$url" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)+\.ipa$ ]]'),
      );
      expect(
        script,
        contains(r'[[ "$bundle" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]'),
      );
      expect(script, contains(r'[[ "$versione" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]'));
      for (final k in [
        '<string>software-package</string>',
        '<key>bundle-identifier</key>',
        '<key>bundle-version</key>',
        '<string>software</string>',
        '<key>title</key>\n\t\t\t\t<string>UniNotes</string>',
      ]) {
        expect(script, contains(k), reason: k);
      }
      // gli UDID del profilo si contano soltanto
      expect(
        script,
        contains(
          "\"\$pb\" -c 'Print :ProvisionedDevices' \"\$tmp/profilo.plist\" 2> /dev/null | grep -c '^ '",
        ),
      );
    });

    test('caricamento: codice d\'uscita e testo di altool controllati', () {
      expect(script, contains(r'local stato=${PIPESTATUS[0]}'));
      expect(script, contains("grep -Eiq 'UPLOAD FAILED|(^|[^a-z])error[: ]'"));
      expect(script, contains('--upload-package'));
      expect(script, contains('--upload-app'));
      expect(script, contains("grep -q 'status: Accepted'"));
    });

    test('a capo LF (gira su macOS)', () {
      expect(
        File('tool/app_store_connect.sh').readAsStringSync(),
        isNot(contains('\r')),
      );
      expect(read('../.gitattributes'), contains('*.sh text eol=lf'));
    });
  });

  group('requisiti di Apple al caricamento', () {
    test('crittografia esente dichiarata (iPhone e Mac)', () {
      for (final f in ['ios/Runner/Info.plist', 'macos/Runner/Info.plist']) {
        expect(
          read(f),
          contains('<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>'),
          reason: f,
        );
      }
      expect(
        read('macos/Runner/Info.plist'),
        contains(
          '<key>LSApplicationCategoryType</key>\n\t<string>public.app-category.education</string>',
        ),
      );
    });

    test(
      'motivi d\'uso in italiano per microfono, voce, calendario e foto',
      () {
        final ios = read('ios/Runner/Info.plist');
        for (final k in [
          'NSMicrophoneUsageDescription',
          'NSSpeechRecognitionUsageDescription',
          'NSCalendarsUsageDescription',
          'NSCalendarsFullAccessUsageDescription',
          'NSPhotoLibraryAddUsageDescription',
        ]) {
          final m = RegExp('<key>$k</key>\\n\\t<string>([^<]+)</string>')
              .firstMatch(ios);
          expect(m, isNotNull, reason: k);
          expect(
            m![1],
            matches(RegExp(r'\b(il|la|le|per|solo|quando)\b')),
            reason: k,
          );
        }
        expect(ios, contains('<string>LaunchScreen</string>'));
        expect(
          ios,
          contains('<string>audio</string>\n\t\t<string>fetch</string>'),
        );
      },
    );

    test('privacy manifest dell\'app nel target (iPhone e Mac)', () {
      for (final d in ['ios', 'macos']) {
        final pbx = read('$d/Runner.xcodeproj/project.pbxproj');
        expect(
          RegExp(r'/\* PrivacyInfo\.xcprivacy in Resources \*/')
              .allMatches(pbx)
              .length,
          2,
          reason: '$d: file di build e fase Resources',
        );
        expect(
          pbx,
          contains('path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };'),
        );
        final m = read('$d/Runner/PrivacyInfo.xcprivacy');
        expect(m, contains('<key>NSPrivacyTracking</key>\n\t<false/>'));
        for (final r in [
          'NSPrivacyAccessedAPICategoryUserDefaults',
          'CA92.1',
          'NSPrivacyAccessedAPICategoryFileTimestamp',
          'C617.1',
          'NSPrivacyAccessedAPICategoryDiskSpace',
          'E174.1',
          'NSPrivacyAccessedAPICategorySystemBootTime',
          '35F9.1',
        ]) {
          expect(m, contains(r), reason: '$d: $r');
        }
      }
    });

    test('icone senza trasparenza (PNG RGB) e icona 1024 per l\'App Store', () {
      final dir = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
      final png = dir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.png'),
      );
      expect(png, isNotEmpty);
      for (final f in png) {
        final b = f.readAsBytesSync();
        // IHDR: larghezza (16), altezza (20), tipo di colore (25): 2 = RGB
        expect(b[25], 2, reason: f.path);
      }
      final grande = File('${dir.path}/Icon-App-1024x1024@1x.png')
          .readAsBytesSync();
      expect((grande[18] << 8) | grande[19], 1024);
    });
  });
}
