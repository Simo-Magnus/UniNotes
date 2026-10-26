import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// Caccia alle falle di sicurezza, terzo giro, «repository, build e resti»
/// (S3-B). Controlli statici: esportazione e controllo della copia pubblica
/// (niente pipe con git, codice d'uscita, flussi compressi dei PDF, autori nei
/// metadati, percorsi con il nome dell'utente), Inno Setup con l'impronta,
/// valori interni del workflow del database come variabili d'ambiente, nessun
/// percorso personale nei file pubblicati (docs/sicurezza.md, «Giro 3 —
/// Repository, build e resti»). I file che esistono solo nella repo privata si
/// saltano nella copia pubblica.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  // i nomi dei file privati si compongono a pezzi (vedi sicurezza_g1_repo_test)
  String nome(List<String> parti) => parti.join();
  final scriptCopia = '../tools/${nome(['esporta_', 'pubblica.py'])}';
  final repoPrivata = File(scriptCopia).existsSync();

  // C:\Users\<nome>, /Users/<nome>, /home/<nome> (scritto a pezzi: questo file
  // va nella copia pubblica, che controlla gli stessi percorsi)
  final percorsoUtente = RegExp(
    '(?:[A-Za-z]:[\\\\/]{1,2}${nome(['Us', 'ers'])}|'
    '(?<![\\w.:-])/(?:${nome(['Us', 'ers'])}|${nome(['ho', 'me'])}))'
    '[\\\\/]{1,2}([A-Za-z0-9._-]{1,64})',
    caseSensitive: false,
  );
  const nomiAmmessi = {
    'x',
    'u',
    'ada',
    'studente',
    'utente',
    'nome',
    'runner',
    'public',
  };

  group('copia pubblica (repo privata)', () {
    String? script() {
      if (!repoPrivata) {
        markTestSkipped(
          'lo script della copia pubblica è solo nella repo privata',
        );
        return null;
      }
      return read(scriptCopia);
    }

    test('git archive in un file, con limite di tempo, mai in una pipe', () {
      final s = script();
      if (s == null) return;
      // la pipe git archive | tarfile si è bloccata il 25/10/2026 a fine estrazione
      expect(s, isNot(contains('stdout=subprocess.PIPE')));
      expect(s, isNot(contains('mode="r|"')));
      expect(s, contains('"git", "archive", "--format=tar", "-o", str(tar)'));
      expect(s, contains('timeout=GIT_TIMEOUT'));
      expect(
        s,
        contains(
          'except (subprocess.CalledProcessError, subprocess.TimeoutExpired)',
        ),
      );
    });

    test('codice d\'uscita 1 per ogni problema', () {
      final s = script();
      if (s == null) return;
      // anche i riferimenti a file privati rimasti, prima solo stampati
      expect(
        s,
        contains('    if verifica(dest):\n        return 1\n    if rimasti:\n'),
      );
      expect(s, contains('riferimenti a file privati.")\n        return 1'));
      expect(s, contains('Codice d\'uscita: 0 solo con la copia pronta'));
    });

    test('controllo veloce: byte letti una volta, processi in parallelo', () {
      final s = script();
      if (s == null) return;
      // niente decodifica dei file né seconda lettura «da binario»
      expect(s, isNot(contains('b.decode("latin-1")')));
      expect(s, isNot(contains('errors="ignore") if testo')));
      expect(s, contains('ProcessPoolExecutor(processi)'));
      // le espressioni dei segreti sono sui byte e non cominciano con \b
      // (impedirebbe la ricerca veloce della prima lettera fissa)
      final regole = RegExp(
        r'^CONTENUTI_VIETATI = \[\n([\s\S]*?)^\]',
        multiLine: true,
      ).firstMatch(s)![1]!;
      expect(regole, isNot(contains(r'compile(r"')));
      expect(regole, isNot(contains(r'compile(rb"\b')));
      expect(
        RegExp(r're\.compile\(rb"').allMatches(regole).length,
        greaterThanOrEqualTo(10),
      );
      // l'indirizzo email si cerca dalla «@» (carattere fisso)
      expect(s, contains('DOMINIO_EMAIL = re.compile(rb"@('));
      expect(s, isNot(contains(RegExp(r'(?<![A-Z_])EMAIL\.finditer\('))));
    });

    test('metadati compressi dei PDF e autori nei documenti', () {
      final s = script();
      if (s == null) return;
      expect(s, contains('def _flussi_pdf('));
      expect(s, contains('zlib.decompressobj()'));
      // limite di decompressione per flusso e per file
      expect(s, contains('MAX_VOCE_ZIP)'));
      expect(s, contains('if letti > MAX_TESTO:'));
      expect(s, contains('/ObjStm'));
      expect(s, contains('/Metadata'));
      // /Author dei PDF (anche in UTF-16), dc:creator e cp:lastModifiedBy
      expect(s, contains(r'AUTORE_PDF = re.compile(rb"/Author'));
      expect(s, contains('utf-16-be'));
      expect(s, contains('cp:lastModifiedBy'));
      expect(s, contains('AUTORI_AMMESSI = {"", "uninotes", "simo-magnus"}'));
      // anche il contenuto dei .gz
      expect(s, contains('zlib.decompressobj(16 + zlib.MAX_WBITS)'));
    });

    test(
      'percorsi con il nome dell\'utente: problema, nel database avviso',
      () {
        final s = script();
        if (s == null) return;
        expect(s, contains('PERCORSO_UTENTE = re.compile('));
        expect(s, contains('(avvisi if dati else out).append('));
        expect(
          s,
          contains(': percorso con il nome dell\'utente del computer ('),
        );
      },
    );
  });

  group('workflow', () {
    test('database: valori interni dei comandi come variabili d\'ambiente', () {
      final f = File('../.github/workflows/${nome(['database', '.yml'])}');
      if (!f.existsSync()) {
        markTestSkipped('workflow solo nella repo privata');
        return;
      }
      final src = read(f.path);
      // testo dei comandi (blocchi «run: |» e righe «run: …»)
      final comandi = <String>[];
      final righe = src.split('\n');
      for (var i = 0; i < righe.length; i++) {
        final m = RegExp(r'^( *)(?:- )?run: (.*)$').firstMatch(righe[i]);
        if (m == null) continue;
        if (m[2] != '|') {
          comandi.add(m[2]!);
          continue;
        }
        final rientro = m[1]!.length;
        for (var j = i + 1; j < righe.length; j++) {
          final r = righe[j];
          if (r.trim().isNotEmpty &&
              r.length - r.trimLeft().length <= rientro) {
            break;
          }
          comandi.add(r);
        }
      }
      expect(comandi, isNotEmpty);
      for (final c in comandi) {
        expect(c, isNot(contains('\${{')), reason: c);
      }
      expect(src, contains('SHARD: \${{ matrix.shard }}'));
      expect(src, contains('EVENTO: \${{ github.event_name }}'));
      expect(src, contains('args="--shard \$SHARD/12"'));
      expect(src, contains('if [ "\$EVENTO" = "schedule" ]; then'));
    });

    test('Inno Setup: installatore ufficiale controllato con lo SHA-256', () {
      final app = read('../.github/workflows/app.yml');
      // il pacchetto di Chocolatey non controlla l'installatore che contiene
      expect(app, isNot(contains('choco install')));
      final i = app.indexOf('Invoke-WebRequest');
      expect(i, greaterThan(0));
      final passo = app.substring(i, app.indexOf('Start-Process', i));
      expect(
        passo,
        contains(
          "-Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_1/innosetup-6.7.1.exe'",
        ),
      );
      expect(passo, contains('Get-FileHash -Algorithm SHA256'));
      expect(passo, contains(RegExp(r"-ne '[0-9A-F]{64}'")));
      expect(passo, contains('exit 1'));
    });

    test('firma Android: secret completi, errore solo per i tag v*', () {
      final app = read('../.github/workflows/app.yml');
      final firma = app.substring(
        app.indexOf('- name: Chiave di firma'),
        app.indexOf('# APK per GitHub Releases'),
      );
      for (final s in [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_KEYSTORE_PASSWORD',
        'ANDROID_KEY_ALIAS',
        'ANDROID_KEY_PASSWORD',
      ]) {
        expect(firma, contains('\${{ secrets.$s }}'), reason: s);
      }
      // le quattro variabili controllate tutte, prima di scrivere la chiave
      expect(
        firma,
        contains(
          'if [ -n "\$KEYSTORE_B64" ] && [ -n "\$KEYSTORE_PASSWORD" ] && [ -n "\$KEY_ALIAS" ] && [ -n "\$KEY_PASSWORD" ]; then',
        ),
      );
      // un push normale prosegue con la chiave di prova (nessun exit)
      final ramoDebug = firma.substring(firma.indexOf('          else'));
      expect(ramoDebug, isNot(contains('exit 1')));
      expect(firma.split('exit 1').length, 2);
    });
  });

  group('nessun dato personale nei file pubblicati', () {
    Iterable<File> file(String cartella) =>
        Directory(cartella)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) {
              final p = f.path.replaceAll('\\', '/');
              return !p.contains('/build/') &&
                  !p.contains('/.dart_tool/') &&
                  !p.contains('/__pycache__/') &&
                  !p.contains('/Pods/') &&
                  !p.contains('/ephemeral/') &&
                  !p.endsWith('local.properties') &&
                  !p.endsWith('.flutter-plugins-dependencies') &&
                  !p.endsWith('cartella_lavoro.txt');
            });

    test('nessun percorso con il nome dell\'utente del computer', () {
      final trovati = <String>[];
      for (final c in [
        'lib',
        'test',
        'tool',
        'android/app/src',
        'ios/Runner',
        'macos/Runner',
        'windows/runner',
        'windows/installer',
        '../tools',
        '../sito',
        '../docs',
        '../.github',
      ]) {
        if (!Directory(c).existsSync()) continue;
        for (final f in file(c)) {
          final List<int> b;
          try {
            b = f.readAsBytesSync();
          } on FileSystemException {
            continue;
          }
          if (b.length > 8 * 1024 * 1024) continue;
          final testi = <String>[String.fromCharCodes(b)];
          if (f.path.endsWith('.xlsx') ||
              f.path.endsWith('.docx') ||
              f.path.endsWith('.pptx')) {
            for (final voce in ZipDecoder().decodeBytes(b)) {
              if (voce.isFile) testi.add(String.fromCharCodes(voce.content));
            }
          }
          for (final t in testi) {
            for (final m in percorsoUtente.allMatches(t)) {
              final n = m[1]!.toLowerCase();
              if (!nomiAmmessi.contains(n)) {
                trovati.add(
                  '${f.path} (${n.substring(0, n.length.clamp(0, 4))}…)',
                );
              }
            }
          }
        }
      }
      expect(trovati, isEmpty);
    });

    test('cache dei semestri: cartella locale fuori dal repository', () {
      for (final a in ['cineca', 'unimi', 'unistrasi']) {
        final s = read('../tools/db_builder/adapters/periodi_$a.py');
        expect(s, contains('SP = periodi.cartella_lavoro()'), reason: a);
      }
      expect(
        read('../tools/db_builder/adapters/periodi.py'),
        contains('def cartella_lavoro() -> str:'),
      );
      expect(
        read('../.gitignore'),
        contains('tools/db_builder/cartella_lavoro.txt\n'),
      );
    });

    test('fogli di prova senza la cartella del computer (absPath)', () {
      for (final f in ['foglio.xlsx', 'foglio_grafico.xlsx']) {
        final z = ZipDecoder().decodeBytes(
          File('test/fixtures/office/$f').readAsBytesSync(),
        );
        final wb = z.findFile('xl/workbook.xml')!;
        expect(
          String.fromCharCodes(wb.content),
          isNot(contains('absPath')),
          reason: f,
        );
      }
    });

    test('controllo del database: tutti i file pubblici', () {
      final s = read('../tools/db_builder/togli_email.py');
      expect(
        s,
        contains(
          'PUBBLICHE = ("corsi", "moduli", "per_corso", "sessioni", "argomenti")',
        ),
      );
      expect(s, contains('for cartella in PUBBLICHE + (".",):'));
    });
  });
}
