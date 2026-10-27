import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Widget della schermata Home e Live Activity della registrazione su
/// iPhone, aggiunti dalla build automatica senza Mac (docs/widget.md): script
/// app/tool/aggiungi_estensioni_ios.rb nel job «testflight» prima
/// dell'archivio, firma locale con l'App Group e ricaduta senza estensioni se
/// un passo non riesce. Il codice Swift non si compila da Windows: qui si
/// controllano coerenza dei nomi, delle versioni minime e delle regole dei
/// workflow (docs/sicurezza.md).
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  const appGroup = 'group.io.github.simomagnus.universitynotes';
  const bundleApp = 'io.github.simomagnus.universitynotes';
  const nome = 'WidgetUniNotes';
  const bundleEstensione = '$bundleApp.$nome';
  const sorgenti = [
    'UniNotesWidgets.swift',
    'RecordingLiveActivity.swift',
    'RecordingActivityAttributes.swift',
    'RecordingIntents.swift',
  ];

  final app = read('../.github/workflows/app.yml');
  final rb = read('tool/aggiungi_estensioni_ios.rb');
  final sh = read('tool/app_store_connect.sh');
  final delegate = read('ios/Runner/AppDelegate.swift');
  final widget = read('ios/$nome/UniNotesWidgets.swift');
  final live = read('ios/$nome/RecordingLiveActivity.swift');
  final intents = read('ios/$nome/RecordingIntents.swift');
  final attributi = read('ios/$nome/RecordingActivityAttributes.swift');

  /// Testo di un job (da «  nome:» al job successivo).
  String job(String nome) {
    final i = app.indexOf('\n  $nome:\n');
    if (i < 0) throw StateError('job $nome assente in app.yml');
    final dopo = RegExp(r'\n  [a-z][a-z-]*:\n').firstMatch(app.substring(i + 1));
    return dopo == null ? app.substring(i) : app.substring(i, i + 1 + dopo.start);
  }

  List<String> passi(String testo) => testo
      .substring(testo.indexOf('\n    steps:\n'))
      .split(RegExp(r'\n(?=      - )'))
      .skip(1)
      .toList();

  /// Righe dei comandi (run: … e blocchi run: |).
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
      for (var j = i + 1; j < righe.length; j++) {
        final r = righe[j];
        if (r.trim().isNotEmpty && r.length - r.trimLeft().length <= m[1]!.length) {
          break;
        }
        out.add(r);
      }
    }
    return out;
  }

  final testflight = job('testflight');
  final elenco = passi(testflight);
  int indice(String s) => elenco.indexWhere((p) => p.contains(s));
  final passoEstensioni = elenco[indice('id: estensioni')];
  final passoArchivio = elenco[indice('id: archivio')];

  group('script nel job «testflight»', () {
    test('richiamato dopo il progetto Xcode e prima dell\'archivio', () {
      final i = indice('ruby tool/aggiungi_estensioni_ios.rb');
      expect(i, greaterThan(0));
      expect(elenco[i], contains('id: estensioni'));
      expect(i, greaterThan(indice('--config-only')));
      expect(i, lessThan(indice('xcodebuild archive -quiet')));
      expect(i, lessThan(indice(' app-store-connect\n')));
      expect(passoEstensioni, contains("if: steps.testflight.outputs.testflight == 'si'"));
      expect(File('tool/aggiungi_estensioni_ios.rb').existsSync(), isTrue);
      // il progetto del repository resta senza estensioni
      expect(read('ios/Runner.xcodeproj/project.pbxproj'), isNot(contains(nome)));
    });

    test('gemma xcodeproj di versione fissa con lo SHA-256 controllato', () {
      final v = RegExp(r"XCODEPROJ_VERSIONE = '(\d+\.\d+\.\d+)'").firstMatch(rb)![1]!;
      expect(rb, contains("gem 'xcodeproj', XCODEPROJ_VERSIONE"));
      expect(passoEstensioni, contains('gem fetch xcodeproj -v $v '));
      expect(passoEstensioni, contains('xcodeproj-$v.gem'));
      expect(passoEstensioni, contains('--source https://rubygems.org/'));
      expect(
        passoEstensioni,
        contains(RegExp(r'echo "[0-9a-f]{64}  \$gemma" \| shasum -a 256 -c -')),
      );
      // installata dal file controllato, non dal nome
      expect(passoEstensioni, contains(r'gem install "$gemma" --user-install --no-document'));
      expect(passoEstensioni, isNot(contains('sudo')));
    });

    test('nessun secret e nessuna espressione nei comandi', () {
      for (final r in comandi(testflight)) {
        expect(r, isNot(contains(r'${{')), reason: r);
      }
      expect(passoEstensioni, isNot(contains('secrets.')));
      expect(passoArchivio, contains(r'ESTENSIONI: ${{ steps.estensioni.outputs.estensioni }}'));
      // la chiave .p8 resta solo nei due passi previsti
      expect(passoEstensioni, isNot(contains('ASC_KEY_P8_BASE64')));
      expect(passoArchivio, isNot(contains('ASC_KEY_P8_BASE64')));
    });
  });

  group('ricaduta senza estensioni (nessun peggioramento)', () {
    test('aggiunta non riuscita: progetto originale e solo un avviso', () {
      expect(
        passoEstensioni,
        contains(r'cp ios/Runner.xcodeproj/project.pbxproj "$copia/project.pbxproj"'),
      );
      final condizione = passoEstensioni.substring(
        passoEstensioni.indexOf('if (cd '),
        passoEstensioni.indexOf('; then'),
      );
      for (final r in condizione.split('\n').skip(1)) {
        expect(r.trimLeft(), startsWith('&& '), reason: r);
      }
      final altrimenti = passoEstensioni.substring(passoEstensioni.indexOf('else'));
      expect(
        altrimenti,
        contains(r'cp "$copia/project.pbxproj" ios/Runner.xcodeproj/project.pbxproj'),
      );
      expect(altrimenti, contains('::warning title=Widget iOS::'));
      expect(passoEstensioni, contains(r'echo "estensioni=si" >> "$GITHUB_OUTPUT"'));
      expect(passoEstensioni, contains(r'echo "estensioni=no" >> "$GITHUB_OUTPUT"'));
      expect(passoEstensioni, isNot(contains('exit 1')));
      expect(passoEstensioni, isNot(contains('::error')));
    });

    test('archivio non riuscito con l\'estensione: rifatto senza', () {
      // un solo comando di archivio nel testo (funzione), seconda
      // compilazione solo dopo un errore
      expect('xcodebuild archive -quiet'.allMatches(testflight), hasLength(1));
      expect(passoArchivio, contains('archivia() {'));
      expect(passoArchivio, contains('elif ! archivia; then'));
      final ricaduta = passoArchivio.substring(passoArchivio.indexOf('elif ! archivia; then'));
      expect(
        ricaduta,
        contains(r'cp "$RUNNER_TEMP/estensioni/project.pbxproj" ios/Runner.xcodeproj/project.pbxproj'),
      );
      expect(ricaduta, contains('estensioni=no\n'));
      expect(ricaduta, contains('::warning title=Widget iOS::'));
      // firma locale con l'App Group, altrimenti archivio senza estensioni
      expect(
        passoArchivio,
        contains(r'bash tool/app_store_connect.sh firma-locale "$archivio" "$APP_VERSION" "$APP_BUILD"'),
      );
      expect(passoArchivio, contains(r'bash tool/app_store_connect.sh senza-estensioni "$archivio"'));
      expect(passoArchivio, contains(r'echo "estensioni=$estensioni" >> "$GITHUB_OUTPUT"'));
    });

    test('esportazione non riuscita: riprova da una copia senza estensioni', () {
      expect(sh, contains('if esporta_da "\$archivio" "\$uscita" "\$opzioni" "\$f"; then'));
      expect(sh, contains(r'local copia="${archivio%.xcarchive}-senza-estensioni.xcarchive"'));
      expect(sh, contains(r'senza_estensioni "$archivio" "$copia"'));
      expect(sh, contains(r'esporta_da "$copia" "$uscita" "$opzioni" "$f"'));
      // l'avviso dice cosa registrare nel portale Apple
      final i = sh.indexOf('::warning title=Widget iOS::esportazione');
      expect(i, greaterThan(0));
      final avviso = sh.substring(i, sh.indexOf('\n', i));
      for (final s in ['App Groups', r'$APP_GROUP', r'$BUNDLE_APP.$ESTENSIONE', 'Configure']) {
        expect(avviso, contains(s), reason: s);
      }
      // gli stessi passi di esportazione (App Store e ad hoc) non cambiano
      expect(testflight, contains('esporta "\$RUNNER_TEMP/asc/Runner.xcarchive" "\$RUNNER_TEMP/asc/ios" app-store-connect'));
      expect(testflight, contains('esporta "\$RUNNER_TEMP/asc/Runner.xcarchive" "\$RUNNER_TEMP/asc/ios-adhoc" release-testing'));
    });

    test('senza estensioni: niente PlugIns e niente firma con gli entitlement', () {
      final f = sh.substring(sh.indexOf('senza_estensioni() {'));
      expect(f, contains(r'rm -rf "$app/PlugIns"'));
      expect(f, contains('codesign --remove-signature'));
    });

    test('firma locale: senza certificati, versione dell\'estensione uguale all\'app', () {
      final f = sh.substring(sh.indexOf('firma_locale() {'), sh.indexOf('senza_estensioni() {'));
      expect(f, contains('codesign --force --sign - --timestamp=none'));
      expect(f, contains(r'"$CARTELLA_APP/ios/$ESTENSIONE/$ESTENSIONE.entitlements"'));
      expect(f, contains(r'"$CARTELLA_APP/ios/Runner/Runner.entitlements"'));
      expect(f, contains("Print :CFBundleShortVersionString' \"\$plist\" 2> /dev/null)\" != \"\$versione\""));
      expect(f, contains("Print :CFBundleVersion' \"\$plist\" 2> /dev/null)\" != \"\$build\""));
      expect(f, isNot(contains('security import')));
      expect(f, isNot(contains('::error')));
      // app ed estensione partono su iOS 15: ActivityKit e AppIntents
      // collegati come facoltativi
      expect(f, contains(r'collegamenti "$app/Runner" || return 1'));
      expect(f, contains(r'collegamenti "$estensione/$ESTENSIONE" || return 1'));
      expect(sh, contains('*"LC_LOAD_DYLIB "*)'));
      expect(
        passoArchivio,
        contains(r'bash tool/app_store_connect.sh collegamenti "$archivio/Products/Applications/Runner.app/Runner" || true'),
      );
    });
  });

  group('nomi coerenti fra app, estensione, entitlement e script', () {
    test('App Group', () {
      expect(delegate, contains('static let appGroup = "$appGroup"'));
      expect(widget, contains('private let appGroup = "$appGroup"'));
      for (final f in ['ios/$nome/$nome.entitlements', 'ios/Runner/Runner.entitlements']) {
        expect(
          read(f),
          contains(
            '<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>$appGroup</string>\n\t</array>',
          ),
          reason: f,
        );
      }
      expect(rb, contains("APP_GROUP = '$appGroup'"));
      expect(sh, contains('APP_GROUP="$appGroup"'));
    });

    test('bundle ID, nome dell\'estensione e dati della Live Activity', () {
      expect(rb, contains("BUNDLE_APP = '$bundleApp'"));
      expect(rb, contains("NOME = '$nome'"));
      expect(rb, contains(r'BUNDLE_ESTENSIONE = "#{BUNDLE_APP}.#{NOME}"'));
      expect(sh, contains('BUNDLE_APP="$bundleApp"'));
      expect(sh, contains('ESTENSIONE="$nome"'));
      expect(testflight, contains('manifesto "\$uscita/UniNotes-ios-adhoc-manifest.plist" $bundleApp '));
      expect(bundleEstensione, startsWith('$bundleApp.'));
      // l'app cerca proprio questa estensione prima di avviare la Live Activity
      expect(delegate, contains('static let extensionName = "$nome.appex"'));
      // stessi nomi e campi nell'app e nell'estensione
      for (final s in [
        'struct RecordingActivityAttributes: ActivityAttributes {',
        'var paused: Bool',
        'var timerStart: Date',
        'var elapsedSeconds: Int',
        'var course: String',
      ]) {
        expect(delegate, contains(s), reason: s);
        expect(attributi, contains(s), reason: s);
      }
      // pulsanti: stessa notifica dell'AppDelegate
      expect(
        intents,
        contains('"io.github.simomagnus.universitynotes.recordingCommand"'),
      );
      expect(
        delegate,
        contains('"io.github.simomagnus.universitynotes.recordingCommand"'),
      );
      expect(delegate, contains('"io.github.simomagnus.universitynotes/live_activity"'));
    });

    test('sorgenti dell\'estensione: quelli dello script, un solo @main', () {
      for (final f in sorgenti) {
        expect(File('ios/$nome/$f').existsSync(), isTrue, reason: f);
        expect(rb, contains(f), reason: f);
      }
      expect(rb, contains('SWIFT_ANCHE_IN_RUNNER = %w[RecordingIntents.swift].freeze'));
      var main = 0;
      for (final f in sorgenti) {
        final s = read('ios/$nome/$f');
        main += RegExp(r'^@main\b', multiLine: true).allMatches(s).length;
        // nessun simbolo dell'app Flutter nell'estensione
        expect(s, isNot(contains('import Flutter')), reason: f);
        expect(s, isNot(contains('FlutterMethodChannel')), reason: f);
      }
      expect(main, 1);
      expect(widget, contains('@main\nstruct UniNotesWidgets: WidgetBundle {'));
    });
  });

  group('Info.plist e versioni minime', () {
    test('l\'app dichiara le Live Activity', () {
      expect(
        read('ios/Runner/Info.plist'),
        contains('<key>NSSupportsLiveActivities</key>\n\t<true/>'),
      );
    });

    test('estensione WidgetKit con la versione e la build dell\'app', () {
      final p = read('ios/$nome/Info.plist');
      expect(
        p,
        contains(
          '<key>NSExtensionPointIdentifier</key>\n\t\t<string>com.apple.widgetkit-extension</string>',
        ),
      );
      final runner = read('ios/Runner/Info.plist');
      for (final k in ['CFBundleShortVersionString', 'CFBundleVersion']) {
        final atteso = RegExp('<key>$k</key>\\n\\t<string>([^<]+)</string>').firstMatch(runner)![1];
        expect(p, contains('<key>$k</key>\n\t<string>$atteso</string>'), reason: k);
      }
      expect(rb, contains("'MARKETING_VERSION' => '\$(FLUTTER_BUILD_NAME)'"));
      expect(rb, contains("'CURRENT_PROJECT_VERSION' => '\$(FLUTTER_BUILD_NUMBER)'"));
      expect(rb, contains("DEPLOYMENT = '15.6'"));
      expect(rb, contains("'CODE_SIGN_STYLE' => 'Automatic'"));
      expect(read('ios/$nome/PrivacyInfo.xcprivacy'), contains('1C8F.1'));
    });

    test('Live Activity solo da iOS 16.2, pulsanti da iOS 17', () {
      expect(widget, contains('if #available(iOS 16.2, *) {\n      RecordingLiveActivity()'));
      expect(live, contains('@available(iOS 16.2, *)\nstruct RecordingLiveActivity: Widget {'));
      expect(live, contains('if #available(iOS 17.0, *) {'));
      expect(
        RegExp(r'@available\(iOS 17\.0, \*\)\nstruct \w+: LiveActivityIntent').allMatches(intents),
        hasLength(2),
      );
      expect(attributi, contains('@available(iOS 16.1, *)'));
      // stesso controllo nell'app (ActivityContent è di iOS 16.2)
      expect(delegate, contains('if #available(iOS 16.2, *), RecordingLiveActivity.available {'));
    });

    test('ActivityKit e AppIntents collegati come facoltativi (iOS 15)', () {
      for (final f in ['ios/Flutter/Release.xcconfig', 'ios/Flutter/Debug.xcconfig']) {
        final c = read(f);
        expect(c, startsWith('#include "Generated.xcconfig"\n'), reason: f);
        expect(
          c,
          contains('OTHER_LDFLAGS = \$(inherited) -weak_framework ActivityKit -weak_framework AppIntents\n'),
          reason: f,
        );
      }
    });

    test('nessuna funzione con il nome del modificatore widgetURL', () {
      for (final s in [widget, live]) {
        expect(s, isNot(contains('func widgetURL')));
        expect(RegExp(r'[^.\w]widgetURL\(').hasMatch(s), isFalse);
      }
    });
  });

  group('progetto Xcode generato dallo script', () {
    test('fase di embed prima di «Thin Binary», dipendenza, entitlement', () {
      expect(rb, contains("FASE_EMBED = 'Embed Foundation Extensions'"));
      expect(rb, contains("FASE_FLUTTER = 'Thin Binary'"));
      expect(rb, contains('embed.symbol_dst_subfolder_spec = :plug_ins'));
      expect(rb, contains('runner.build_phases.move(embed, indice_flutter)'));
      expect(rb, contains('runner.add_dependency(estensione)'));
      expect(rb, contains("ENTITLEMENT_RUNNER = 'Runner/Runner.entitlements'"));
      // controllo finale del progetto salvato, poi uscita 1 con il motivo
      expect(rb, contains("esegui('xcodebuild', '-list', '-project', PROGETTO)"));
      expect(rb, contains("esegui('plutil', '-lint', f)"));
      expect(rb, contains('exit 1'));
      // comandi senza shell
      expect(rb, isNot(contains('system(')));
      expect(rb, isNot(contains('`')));
    });

    test('a capo LF negli script che girano su macOS', () {
      for (final f in ['tool/aggiungi_estensioni_ios.rb', 'tool/app_store_connect.sh']) {
        expect(File(f).readAsStringSync(), isNot(contains('\r')), reason: f);
      }
      expect(read('../.gitattributes'), contains('*.rb text eol=lf'));
    });
  });
}
