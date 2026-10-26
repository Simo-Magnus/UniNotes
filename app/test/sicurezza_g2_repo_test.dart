import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Caccia alle falle di sicurezza, secondo giro, «repository, build, sito e
/// database» (S2-B). Controlli statici sui file del progetto: firma Android,
/// download nei workflow, dipendenze Python, pagine del sito, filtro degli
/// indirizzi email personali nella costruzione del database, SECURITY.md e
/// .gitignore (docs/sicurezza.md, «Giro 2 — Repository, build, sito e
/// database»). I file che esistono solo nella repo privata si saltano nella
/// copia pubblica.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  // i nomi dei file privati si compongono a pezzi (vedi sicurezza_g1_repo_test)
  String nome(List<String> parti) => parti.join();
  final scriptCopia = '../tools/${nome(['esporta_', 'pubblica.py'])}';
  final repoPrivata = File(scriptCopia).existsSync();

  /// Testo del job [job] di un workflow (dalla riga «  job:» alla successiva
  /// con lo stesso rientro).
  String job(String src, String job) {
    final m = RegExp(
      '^  ${RegExp.escape(job)}:\\n((?:    .*\\n|\\n)*)',
      multiLine: true,
    ).firstMatch(src);
    expect(m, isNotNull, reason: job);
    return m![1]!;
  }

  group('firma Android', () {
    final gradle = read('android/app/build.gradle.kts');
    final app = read('../.github/workflows/app.yml');

    test('Gradle si ferma senza la chiave quando la firma è obbligatoria', () {
      expect(
        gradle,
        contains('System.getenv("UNINOTES_FIRMA_OBBLIGATORIA") == "1"'),
      );
      expect(
        gradle,
        contains(
          'if (firmaObbligatoria && !chiaveDiRilascio) {\n    throw GradleException(',
        ),
      );
      // key.properties completo e keystore presente, non solo «file non vuoto»
      for (final k in [
        'keyAlias',
        'keyPassword',
        'storeFile',
        'storePassword',
      ]) {
        expect(gradle, contains('"$k"'), reason: k);
      }
      expect(gradle, contains('.isFile'));
      expect(gradle, isNot(contains('keyProperties.isNotEmpty()')));
      // la chiave di debug solo come ripiego delle build di prova
      expect(
        gradle,
        contains(
          'signingConfig = if (chiaveDiRilascio) signingConfigs.getByName("release")\n'
          '                else signingConfigs.getByName("debug")',
        ),
      );
    });

    test('tag v*: firma obbligatoria, release solo con la chiave vera', () {
      final android = job(app, 'android');
      expect(
        android,
        contains(
          "UNINOTES_FIRMA_OBBLIGATORIA: \${{ startsWith(github.ref, 'refs/tags/v') && '1' || '0' }}",
        ),
      );
      expect(android, contains('firma: \${{ steps.firma.outputs.firma }}'));
      // senza secret: errore con il tag, altrimenti «debug» dichiarato
      expect(
        android,
        contains('elif [ "\$UNINOTES_FIRMA_OBBLIGATORIA" = "1" ]; then'),
      );
      expect(android, contains('echo "firma=release" >> "\$GITHUB_OUTPUT"'));
      expect(android, contains('echo "firma=debug" >> "\$GITHUB_OUTPUT"'));
      final release = job(app, 'release');
      expect(
        release,
        contains(
          "if: startsWith(github.ref, 'refs/tags/v') && needs.android.outputs.firma == 'release'",
        ),
      );
    });

    test('AAB per Google Play mai firmato con la chiave di debug', () {
      final android = job(app, 'android');
      final i = android.indexOf('flutter build appbundle');
      expect(i, greaterThan(0));
      final passo = android.substring(android.lastIndexOf('      - ', i), i);
      expect(passo, contains("if: steps.firma.outputs.firma == 'release'"));
      expect(passo, contains('UNINOTES_FIRMA_OBBLIGATORIA: "1"'));
    });

    test('«ultima-build» dice quando gli APK hanno la chiave di prova', () {
      final ultima = job(app, 'ultima-build');
      expect(ultima, contains("needs.android.outputs.firma == 'release'"));
      expect(ultima, contains("needs.android.outputs.firma != 'release'"));
      expect(ultima, contains('APK firmati con una chiave di prova'));
    });

    test(
      'plugin Gradle di Kotlin con la correzione di GHSA-r937-wjx7-w2jp',
      () {
        final m = RegExp(
          r'id\("org\.jetbrains\.kotlin\.android"\) version "(\d+)\.(\d+)\.(\d+)"',
        ).firstMatch(read('android/settings.gradle.kts'))!;
        final v = [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
        final corretta =
            v[0] > 2 || (v[0] == 2 && (v[1] > 4 || (v[1] == 4 && v[2] >= 20)));
        expect(corretta, isTrue, reason: v.join('.'));
      },
    );
  });

  group('download nei workflow', () {
    test('Inno Setup con versione fissa', () {
      final app = read('../.github/workflows/app.yml');
      final choco = RegExp(r'choco install (\S+)([^\n]*)').allMatches(app);
      for (final m in choco) {
        expect(m[2], matches(RegExp(r'--version \d+\.\d+\.\d+')), reason: m[0]);
      }
      // dal giro 3: installatore ufficiale di una versione fissa, con
      // l'impronta (sicurezza_g3_repo_test)
      expect(
        app,
        contains(
          RegExp(
            r'releases/download/is-\d+_\d+_\d+/innosetup-\d+\.\d+\.\d+\.exe',
          ),
        ),
      );
    });

    test('prova di trascrizione: modelli con SHA-256, whisper.cpp fissato', () {
      final t = read('../.github/workflows/transcription.yml');
      // revisione fissa di Hugging Face, non il ramo principale
      expect(t, isNot(contains('/resolve/main/')));
      expect(t, contains(RegExp(r'HF_REV: [0-9a-f]{40}\n')));
      final curl = RegExp(r'curl [^\n]*-o (\S+)').allMatches(t).toList();
      expect(curl, isNotEmpty);
      for (final c in curl) {
        expect(c[0], contains("--proto '=https'"));
        final dopo = t.substring(c.end, c.end + 200);
        expect(dopo, contains('sha256sum -c -'), reason: c[0]);
      }
      expect(
        RegExp(r'\) sha=[0-9a-f]{64} ;;').allMatches(t).length,
        greaterThanOrEqualTo(2),
      );
      expect(
        t,
        contains('test "\$(git -C /tmp/whisper.cpp rev-parse HEAD)" = '),
      );
    });

    test('dipendenze Python del database con versione fissata', () {
      final righe = read('../tools/db_builder/requirements.txt')
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'));
      expect(righe, isNotEmpty);
      for (final r in righe) {
        expect(
          r,
          matches(RegExp(r'^[A-Za-z0-9_.\-]+==\d+(\.\d+)+$')),
          reason: r,
        );
      }
    });
  });

  group('sito', () {
    test(
      'selettore di Google Drive: CSP con lo script in linea per impronta',
      () {
        final s = read('../sito/drive-picker.html');
        final m = RegExp(
          r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">',
        ).firstMatch(s);
        expect(m, isNotNull);
        final csp = m![1]!;
        expect(s.indexOf(m[0]!), lessThan(s.indexOf('<title')));
        final direttive = <String, String>{
          for (final d in csp.split(';').map((x) => x.trim()))
            if (d.isNotEmpty)
              d.split(' ').first: d.substring(d.indexOf(' ') + 1),
        };
        expect(direttive['default-src'], "'none'");
        expect(direttive['object-src'], "'none'");
        expect(direttive['base-uri'], "'none'");
        expect(direttive['form-action'], "'none'");
        // script: solo quello della pagina (impronta) e il caricatore di Google
        final scripts = RegExp(r'<script>([\s\S]*?)</script>')
            .allMatches(s)
            .toList();
        expect(scripts, hasLength(1));
        final impronta = base64.encode(
          sha256.convert(utf8.encode(scripts.single[1]!)).bytes,
        );
        expect(
          direttive['script-src'],
          "'sha256-$impronta' https://apis.google.com",
          reason: 'impronta dello script cambiata: aggiorna la CSP',
        );
        // riquadri, immagini e richieste solo verso Google
        for (final d in ['frame-src', 'img-src', 'connect-src']) {
          for (final o in direttive[d]!.split(' ')) {
            expect(
              o == "'self'" ||
                  o == 'data:' ||
                  RegExp(r'^https://[a-z]+\.(google|gstatic)\.com$')
                      .hasMatch(o),
              isTrue,
              reason: '$d: $o',
            );
          }
        }
        expect(direttive['frame-src'], contains('https://docs.google.com'));
        // il file resta con gli a capo LF (l'impronta è calcolata su quelli)
        expect(
          read('../.gitattributes'),
          contains('sito/drive-picker.html text eol=lf'),
        );
        expect(
          File('../sito/drive-picker.html').readAsStringSync(),
          isNot(contains('\r')),
        );
      },
    );

    test(
      'amministratori: niente testo dell\'errore scelto da chi manda il link',
      () {
        final s = read('../sito/amministratori.html');
        expect(s, isNot(contains('.slice(0, 400)')));
        // error_description solo per estrarne il codice AADSTS (solo cifre)
        final usi = RegExp(r'error_description').allMatches(s).length;
        expect(
          s,
          contains(
            r'/^AADSTS(\d{5,7})\b/.exec(q.get("error_description") || "")',
          ),
        );
        expect(usi, 2); // il commento e l'estrazione del codice
        expect(s, contains('noti.indexOf(codice) >= 0'));
      },
    );

    test(
      'il sito non nomina il contatore delle visite (solo il suo indirizzo)',
      () {
        final pagine = Directory('../sito')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.html'));
        for (final f in pagine) {
          final s = read(f.path)
              .toLowerCase()
              .replaceAll('uninotes.goatcounter.com', '');
          expect(s, isNot(contains('goatcounter')), reason: f.path);
        }
        // nemmeno i modelli delle pagine generate
        for (final g in [
          '../tools/pagine_legali.py',
          '../tools/genera_link_sito.py',
        ]) {
          for (final c in RegExp(r'<!--[\s\S]*?-->').allMatches(read(g))) {
            expect(
              c[0]!.toLowerCase(),
              isNot(contains('goatcounter')),
              reason: g,
            );
          }
          expect(read(g), isNot(contains('#toggle-goatcounter')), reason: g);
        }
      },
    );
  });

  group('database', () {
    test('la build toglie gli indirizzi email personali', () {
      final pulizia = read('../tools/db_builder/pulizia.py');
      expect(pulizia, contains('def senza_email_personali('));
      for (final d in ['gmail', 'libero', 'tiscali', 'hotmail', 'yahoo']) {
        expect(pulizia, contains('$d\\.'), reason: d);
      }
      final build = read('../tools/db_builder/build_db.py');
      final scrivi = build.indexOf('write_json(path, doc)');
      expect(
        build.substring(scrivi - 120, scrivi),
        contains('doc = pulizia.senza_email_personali(doc)'),
      );
      final dividi = read('../tools/db_builder/dividi_per_corso.py');
      expect(
        dividi,
        contains(
          'doc = senza_email_personali(json.loads(src.read_text(encoding="utf-8")))',
        ),
      );
      expect(
        dividi,
        contains(
          'moduli = {k: senza_email_personali(v) for k, v in moduli.items()}',
        ),
      );
      // strumento per i file già costruiti, con il controllo
      final togli = read('../tools/db_builder/togli_email.py');
      expect(togli, contains('"--verifica"'));
      expect(togli, contains('dividi_per_corso.py'));
    });

    test('moduli di Studio: filtro anche nell\'unione (repo privata)', () {
      final f = File(
        '../${nome(['privato', '/libri/strumenti/moduli_unisci.py'])}',
      );
      if (!repoPrivata || !f.existsSync()) {
        markTestSkipped('strumento solo nella repo privata');
        return;
      }
      final s = read(f.path);
      expect(s, contains('from pulizia import senza_email_personali'));
      expect(s, contains('senza_email_personali(v)'));
    });
  });

  group('repository', () {
    test('SECURITY.md: segnalazioni private, niente email personali', () {
      final s = read('../SECURITY.md');
      expect(
        s,
        contains(
          'https://github.com/Simo-Magnus/UniNotes/security/advisories/new',
        ),
      );
      expect(s, contains('Report a vulnerability'));
      final email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
      for (final m in email.allMatches(s)) {
        expect(m[0], 'uninotes-supporto@googlegroups.com');
      }
    });

    test('.gitignore: file di lavoro della radice', () {
      final gi = read('../.gitignore');
      for (final p in [
        '/nuovi_ids.json',
        '/ct_mapping.json',
        '/x',
        '/red_backup/',
      ]) {
        expect(gi, contains('$p\n'), reason: p);
      }
    });

    test(
      'controllo della copia pubblica: radice, binari, archivi, dati personali',
      () {
        if (!repoPrivata) {
          markTestSkipped(
            'lo script della copia pubblica è solo nella repo privata',
          );
          return;
        }
        final s = read(scriptCopia);
        expect(s, contains('"SECURITY.md"'));
        // anche i file con un'estensione non prevista e i binari (metadati):
        // dal giro 3 ogni file si controlla sui suoi byte, letto una volta
        expect(s, contains('b = f.read_bytes()\n    yield rel, b\n'));
        // dentro i documenti Office, OpenDocument ed EPUB
        expect(s, contains('ARCHIVI_ZIP = {'));
        expect(s, contains('zipfile.ZipFile(f)'));
        // database, registri, rubriche e cartelle private a qualsiasi livello
        expect(
          s,
          contains(
            r'\.(sqlite3?|db|vcf|eml|mbox|msg|pst|har|log|bak|danneggiato)$',
          ),
        );
        expect(
          s,
          contains('(^|/)(privato|private|red_backup|backup|backups)/'),
        );
        // un indirizzo personale nel database blocca la copia
        expect(
          s,
          contains('from pulizia import EMAIL_PERSONALE as EMAIL_PERSONALE_DB'),
        );
        // un file troppo grande non passa senza controllo
        expect(s, contains('file troppo grande da controllare'));
      },
    );
  });
}
