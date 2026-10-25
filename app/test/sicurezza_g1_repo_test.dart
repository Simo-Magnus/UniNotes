import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Caccia alle falle di sicurezza, primo giro, «repository, GitHub, build
/// automatica, dipendenze e sito» (S1-D). Controlli statici sui file del
/// progetto: workflow di GitHub Actions, configurazione di Dependabot, script
/// della copia pubblica e pagine del sito (docs/sicurezza.md, «Giro 1 —
/// Repository, build e sito»). Alcuni file esistono solo nella repo privata:
/// nella copia pubblica quei controlli si saltano.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  // I nomi dei file privati si compongono a pezzi: lo script della copia
  // pubblica segnala ogni file che li cita per intero.
  String nome(List<String> parti) => parti.join();
  final scriptCopia = '../tools/${nome(['esporta_', 'pubblica.py'])}';
  final repoPrivata = File(scriptCopia).existsSync();

  final workflows =
      Directory('../.github/workflows')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  String base(File f) => f.uri.pathSegments.last;

  /// Permessi dichiarati a livello di workflow (blocco `permissions:` senza
  /// rientro): nome → valore.
  Map<String, String> permessiGlobali(String src) {
    final out = <String, String>{};
    final lines = src.split('\n');
    final i = lines.indexWhere((l) => l.startsWith('permissions:'));
    if (i < 0) return out;
    for (final l in lines.skip(i + 1)) {
      final m = RegExp(r'^  ([a-z-]+): *([a-z-]+)').firstMatch(l);
      if (m == null) break;
      out[m[1]!] = m[2]!;
    }
    return out;
  }

  group('build automatica (GitHub Actions)', () {
    test('ci sono i workflow da controllare', () {
      final nomi = workflows.map(base).toSet();
      expect(nomi, containsAll(['app.yml', 'pagina.yml', 'transcription.yml']));
    });

    test('permessi del token: sola lettura per tutto il workflow', () {
      for (final f in workflows) {
        final p = permessiGlobali(read(f.path));
        expect(
          p['contents'],
          'read',
          reason: '${base(f)}: permissions.contents',
        );
        for (final e in p.entries) {
          // GitHub Pages: il job di pubblicazione deve scrivere la pagina
          final ammesso =
              e.value == 'read' ||
              e.value == 'none' ||
              (base(f) == 'pagina.yml' &&
                  {'pages', 'id-token'}.contains(e.key));
          expect(ammesso, isTrue, reason: '${base(f)}: ${e.key}: ${e.value}');
        }
      }
    });

    test(
      'scrivono solo i job che pubblicano (release, ultima build, database)',
      () {
        final app = read('../.github/workflows/app.yml');
        // un job ha "permissions:" con 4 spazi di rientro
        final conPermessi = RegExp(
          r'^  ([a-z-]+):\n(?:    .*\n|\n)*?    permissions:',
          multiLine: true,
        ).allMatches(app).map((m) => m[1]).toSet();
        expect(conPermessi, {'ultima-build', 'release'});
      },
    );

    test('nessun trigger che esegue codice non fidato con permessi', () {
      for (final f in workflows) {
        final src = read(f.path);
        final trigger = RegExp(
          r'^(  )?(pull_request_target|workflow_run)\s*:|^on:.*\b(pull_request_target|workflow_run)\b',
          multiLine: true,
        );
        expect(trigger.hasMatch(src), isFalse, reason: base(f));
      }
    });

    test(
      'azioni fissate allo SHA del commit, con la versione nel commento',
      () {
        final uses = RegExp(
          r'^\s*(?:-\s+)?uses:\s*(\S+)(.*)$',
          multiLine: true,
        );
        for (final f in workflows) {
          for (final m in uses.allMatches(read(f.path))) {
            final ref = m[1]!;
            expect(
              RegExp(r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$').hasMatch(ref),
              isTrue,
              reason: '${base(f)}: $ref non è fissata a uno SHA',
            );
            expect(
              m[2],
              matches(RegExp(r'^\s+# v\d')),
              reason: '${base(f)}: $ref',
            );
          }
        }
      },
    );

    test('checkout non lascia il token nella cartella .git', () {
      for (final f in workflows) {
        final lines = read(f.path).split('\n');
        var checkout = 0, senzaToken = 0;
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('uses: actions/checkout@')) continue;
          checkout++;
          final dopo = lines.skip(i + 1).take(4).join('\n');
          if (dopo.contains('persist-credentials: false')) senzaToken++;
        }
        // il job «build» del database fa il push delle modifiche: lì serve
        final ammessi = base(f) == nome(['database', '.yml']) ? 1 : 0;
        expect(
          checkout - senzaToken,
          lessThanOrEqualTo(ammessi),
          reason: base(f),
        );
      }
    });

    test('secret e valori scritti a mano solo come variabili d\'ambiente', () {
      // una riga con ${{ secrets.X }} (o con i dati inseriti a mano o della
      // pull request) è ammessa solo come assegnazione di una variabile;
      // dentro il testo di uno script finirebbe nel file del passo e
      // potrebbe cambiare il comando
      final sensibile = RegExp(
        r'\$\{\{\s*(secrets\.|github\.event\.(inputs|pull_request|issue|comment|head_commit)|github\.head_ref|inputs\.)',
      );
      final assegnazione = RegExp(
        r"^\s+[A-Za-z0-9_]+:\s+\$\{\{\s*[a-z_.A-Z0-9]+(\s*!=\s*''(\s*&&\s*secrets\.[A-Z0-9_]+\s*!=\s*'')*)?\s*\}\}\s*$",
      );
      for (final f in workflows) {
        final lines = read(f.path).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('#') || !sensibile.hasMatch(l)) continue;
          expect(
            assegnazione.hasMatch(l),
            isTrue,
            reason: '${base(f)}:${i + 1}: $l',
          );
        }
      }
    });

    test('nessuno script scaricato ed eseguito al volo', () {
      final alVolo = RegExp(
        r'(curl|wget)[^\n|]*\|\s*(sudo\s+)?(ba|z)?sh\b|iex\s*\(|Invoke-Expression',
      );
      for (final f in workflows) {
        expect(alVolo.hasMatch(read(f.path)), isFalse, reason: base(f));
      }
    });
  });

  group('dipendenze', () {
    test('Dependabot per pub, Gradle, azioni e pip (repo privata)', () {
      final f = File('../.github/${nome(['dependabot', '.yml'])}');
      if (!repoPrivata) {
        markTestSkipped('copia pubblica: Dependabot lavora sulla repo privata');
        return;
      }
      final src = read(f.path);
      for (final eco in ['github-actions', 'pub', 'gradle', 'pip']) {
        expect(src, contains('package-ecosystem: $eco'), reason: eco);
      }
      expect(src, contains('directory: /app\n'));
      expect(src, contains('directory: /app/android'));
    });

    test(
      'pacchetti Dart solo da pub.dev o dall\'SDK (niente git o percorsi)',
      () {
        final lock = read('pubspec.lock');
        final fonti = RegExp(
          r'^    source: (\S+)',
          multiLine: true,
        ).allMatches(lock).map((m) => m[1]).toSet();
        expect(fonti.difference({'hosted', 'sdk'}), isEmpty);
        expect(lock, isNot(contains('url: "http://')));
      },
    );
  });

  group('copia pubblica (repo privata)', () {
    test('esclude i file privati e si controlla da sola', () {
      if (!repoPrivata) {
        markTestSkipped(
          'lo script della copia pubblica è solo nella repo privata',
        );
        return;
      }
      final src = read(scriptCopia);
      for (final p in [
        nome(['PIANO_', 'MARKETING.md']),
        nome(['PUBBLI', 'CAZIONE.md']),
        nome(['ISTRUZIONI_CLAUDE_', 'CODE_LOCALE.md']),
        'docs/${nome(['messaggi_', 'outreach.md'])}',
        'docs/${nome(['enti_', 'media.md'])}',
        'docs/${nome(['contatti', '.md'])}',
        'database/${nome(['conta', 'tti'])}',
        'database/${nome(['commu', 'nity'])}',
        'data/raw',
        'privato',
        'docs/libri',
        'grafica_play',
        '.github/workflows/${nome(['database', '.yml'])}',
        '.github/${nome(['dependabot', '.yml'])}',
      ]) {
        expect(src, contains('"$p"'), reason: p);
      }
      // controllo automatico alla fine dell'esportazione e con --verifica
      expect(src, contains('def problemi_copia('));
      expect(src, contains('"--verifica"'));
      expect(src, contains('if verifica(dest):'));
      // radice ammessa: le cartelle e i file nuovi non passano da soli
      expect(src, contains('RADICE_PUBBLICA = {'));
    });

    test('il .gitignore tiene fuori keystore e chiavi di firma', () {
      final gi = read('android/.gitignore');
      for (final p in ['key.properties', '**/*.keystore', '**/*.jks']) {
        expect(gi, contains(p), reason: p);
      }
    });
  });

  group('sito (GitHub Pages)', () {
    final pagine = Directory('../sito')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'))
        .toList();
    String rel(File f) => f.path.replaceAll('\\', '/').split('/sito/').last;

    test('ci sono le pagine del sito', () {
      expect(pagine.length, greaterThan(20));
    });

    test('nessuno script né carattere da server di terzi', () {
      final scriptEsterno = RegExp(
        r'<script[^>]*\ssrc="(https?:)?//',
        caseSensitive: false,
      );
      final cssEsterno = RegExp(
        r'<link[^>]*href="(https?:)?//[^"]*"[^>]*rel="stylesheet"|<link[^>]*rel="stylesheet"[^>]*href="(https?:)?//',
        caseSensitive: false,
      );
      for (final f in pagine) {
        final s = read(f.path);
        expect(scriptEsterno.hasMatch(s), isFalse, reason: rel(f));
        expect(cssEsterno.hasMatch(s), isFalse, reason: rel(f));
        expect(s, isNot(contains('fonts.googleapis.com')), reason: rel(f));
        expect(s, isNot(contains('fonts.gstatic.com')), reason: rel(f));
        expect(s, isNot(contains('gc.zgo.at')), reason: rel(f));
      }
      // i caratteri serviti dal sito, con la licenza
      expect(File('../sito/fonts/ibm-plex-sans.css').existsSync(), isTrue);
      expect(File('../sito/fonts/OFL.txt').existsSync(), isTrue);
    });

    test(
      'Content-Security-Policy: solo file del sito e il contatore delle visite',
      () {
        final csp = RegExp(
          r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">',
        );
        for (final f in pagine) {
          // la pagina del selettore di Google Drive carica gli script di Google
          if (rel(f) == 'drive-picker.html') continue;
          final s = read(f.path);
          final m = csp.firstMatch(s);
          expect(m, isNotNull, reason: rel(f));
          final c = m![1]!;
          expect(c, contains("default-src 'self'"), reason: rel(f));
          expect(c, contains("object-src 'none'"), reason: rel(f));
          expect(c, contains("base-uri 'none'"), reason: rel(f));
          final script = RegExp(r'script-src ([^;]+)').firstMatch(c)![1]!;
          expect(script, isNot(contains('http')), reason: rel(f));
          final connect = RegExp(r'connect-src ([^;]+)')
              .firstMatch(c)![1]!
              .trim();
          expect(connect, 'https://uninotes.goatcounter.com', reason: rel(f));
          // la policy è la prima cosa dopo la codifica, prima di stili e script
          expect(
            s.indexOf(m[0]!),
            lessThan(s.indexOf('<title')),
            reason: rel(f),
          );
        }
      },
    );

    test('il contatore riceve solo il percorso della pagina', () {
      for (final f in pagine) {
        final s = read(f.path);
        if (!s.contains('sendBeacon(')) continue;
        final chiamata = RegExp(r"sendBeacon\('[^']+\?p=' \+ e\(([^)]+)\)")
            .firstMatch(s);
        expect(chiamata, isNotNull, reason: rel(f));
        final percorso = chiamata![1]!;
        if (rel(f) == 'link/index.html') {
          // la sigla della bio (?s=ig), filtrata: niente fbclid o altro
          expect(percorso, 'location.pathname + s');
          expect(
            s,
            contains("/^[a-z]{1,4}\$/.test(fonte) ? '?s=' + fonte : ''"),
          );
        } else {
          expect(percorso, 'location.pathname', reason: rel(f));
        }
      }
    });

    test('link in una nuova scheda sempre con rel="noopener"', () {
      final blank = RegExp(r'<a\s[^>]*target="_blank"[^>]*>');
      for (final f in pagine) {
        for (final m in blank.allMatches(read(f.path))) {
          expect(m[0], contains('noopener'), reason: '${rel(f)}: ${m[0]}');
        }
      }
    });

    test('nessun reindirizzamento verso un indirizzo preso dalla richiesta', () {
      for (final f in pagine) {
        final s = read(f.path);
        // drive-picker torna solo all'app (indirizzo controllato con una
        // espressione regolare, vedi sotto)
        if (rel(f) == 'drive-picker.html') continue;
        for (final m in RegExp(
          r'location\.(replace|assign)\(([^)]*)\)',
        ).allMatches(s)) {
          expect(m[2], startsWith('"https://'), reason: '${rel(f)}: ${m[0]}');
        }
        expect(
          RegExp(r'location\.href\s*=').hasMatch(s),
          isFalse,
          reason: rel(f),
        );
        final refresh = RegExp(r'http-equiv="refresh" content="0; url=([^"]+)"')
            .allMatches(s);
        for (final r in refresh) {
          expect(r[1], startsWith('https://'), reason: rel(f));
        }
      }
      final picker = read('../sito/drive-picker.html');
      expect(
        picker,
        contains(r'/^http:\/\/127\.0\.0\.1:\d{1,5}\/picker$/.test(ret)'),
      );
      expect(
        picker,
        contains(
          r'/^com\.googleusercontent\.apps\.[A-Za-z0-9-]+:\/picker$/.test(ret)',
        ),
      );
      expect(picker, contains('<meta name="referrer" content="no-referrer">'));
      expect(picker, isNot(contains('goatcounter')));
    });

    test('nelle pagine solo gli indirizzi email pubblici del progetto', () {
      const pubblici = {
        'uninotes-supporto@googlegroups.com',
        'uninotes-stampa.stir677@passinbox.com',
        'uninotes-partner.stem084@passinbox.com',
        'simomagnus.dev@gmail.com',
      };
      final email = RegExp(
        r'[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}',
      );
      for (final f in pagine) {
        for (final m in email.allMatches(read(f.path))) {
          expect(
            pubblici,
            contains(m[0]!.toLowerCase()),
            reason: '${rel(f)}: ${m[0]!.substring(0, 4)}…',
          );
        }
      }
    });
  });
}
