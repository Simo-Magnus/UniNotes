import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Caccia alle falle di sicurezza, quarto giro, «database e strumenti»
/// (S4-B): link a file del computer di chi ha scritto la pagina dell'ateneo
/// tolti nella build, controllo del database veloce e completo, controllo della
/// copia pubblica che blocca i percorsi con il nome dell'utente anche nel
/// database (docs/sicurezza.md, «Giro 4 — Database e strumenti»). Le prove che
/// eseguono Python si saltano se `python` non c'è; i controlli sui file della
/// sola repo privata si saltano nella copia pubblica.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  // i nomi dei file privati e dei percorsi si compongono a pezzi (questo file
  // va nella copia pubblica, che controlla gli stessi testi)
  String nome(List<String> parti) => parti.join();
  final scriptCopia = '../tools/${nome(['esporta_', 'pubblica.py'])}';
  final repoPrivata = File(scriptCopia).existsSync();
  final utenti = nome(['Us', 'ers']);

  /// Esegue Python con gli argomenti dati; null se Python non c'è.
  Future<ProcessResult?> python(List<String> args) async {
    for (final exe in ['python', 'python3']) {
      try {
        return await Process.run(
          exe,
          ['-X', 'utf8', '-I', ...args],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  // programma Python (senza barre rovesciate) che carica il filtro della build
  const caricaPulizia =
      'import sys; sys.path.insert(0, "../tools/db_builder"); import pulizia as p; ';

  group('link a file locali nel database', () {
    test('la build li toglie in tutti i punti dove toglie le email', () {
      final pulizia = read('../tools/db_builder/pulizia.py');
      expect(pulizia, contains('def senza_percorsi_locali('));
      expect(pulizia, contains('def ha_percorsi_locali('));
      expect(pulizia, contains('PERCORSO_LOCALE = re.compile('));
      final build = read('../tools/db_builder/build_db.py');
      final scrivi = build.indexOf('write_json(path, doc)');
      final prima = build.substring(scrivi - 400, scrivi);
      expect(prima, contains('doc = pulizia.senza_percorsi_locali(doc)'));
      expect(prima, contains('doc = pulizia.senza_parametri_di_accesso(doc)'));
      final dividi = read('../tools/db_builder/dividi_per_corso.py');
      expect(dividi, contains('doc = senza_percorsi_locali(doc)'));
      expect(dividi, contains('doc = senza_parametri_di_accesso(doc)'));
      expect(
        dividi,
        contains('moduli = {k: senza_parametri_di_accesso(v) for k, v in moduli.items()}'),
      );
      expect(
        dividi,
        contains('moduli = {k: senza_percorsi_locali(v) for k, v in moduli.items()}'),
      );
      // strumento per i file già costruiti
      final togli = read('../tools/db_builder/togli_email.py');
      expect(togli, contains('senza_percorsi_locali(senza_email_personali(dati))'));
    });

    test('unione dei moduli (repo privata): stesso filtro', () {
      final f = File(
        '../${nome(['privato', '/libri/strumenti/moduli_unisci.py'])}',
      );
      if (!repoPrivata || !f.existsSync()) {
        markTestSkipped('strumento solo nella repo privata');
        return;
      }
      expect(
        read(f.path),
        contains(
          'senza_parametri_di_accesso(senza_percorsi_locali(senza_email_personali(v)))',
        ),
      );
    });

    test('il filtro toglie il link e lascia il testo della citazione', () async {
      final link = 'file:///C:/$utenti/Mario/Downloads/Dispensa%20(1).pdf';
      final r = await python([
        '-c',
        '${caricaPulizia}print(p.senza_percorsi_locali(sys.argv[1]))',
        'Rossi, Libro, 2020 (disponibile in $link), cap. 3',
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(
        (r.stdout as String).trim(),
        'Rossi, Libro, 2020 (disponibile in [link non disponibile]), cap. 3',
      );
    });

    test('il filtro non tocca i link web e gli altri testi', () async {
      const testo =
          'https://www.esempio.it/users/mario/profile:/x e orario 10:/ e C:/temp';
      final r = await python([
        '-c',
        '${caricaPulizia}print(p.senza_percorsi_locali(sys.argv[1]) == sys.argv[1])',
        testo,
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect((r.stdout as String).trim(), 'True');
    });

    test('il filtro toglie anche i percorsi di disco con il nome utente', () async {
      final r = await python([
        '-c',
        '${caricaPulizia}print(p.ha_percorsi_locali(sys.argv[1]), '
            'p.ha_percorsi_locali(p.senza_percorsi_locali(sys.argv[1])))',
        'vedi C:/$utenti/Mario/Desktop/dispensa.docx e basta',
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect((r.stdout as String).trim(), 'True False');
    });

    test('il database pubblico non ne contiene (controllo dello strumento)', () async {
      final r = await python(['../tools/db_builder/togli_email.py', '--verifica']);
      if (r == null || !Directory('../database/corsi').existsSync()) {
        markTestSkipped('Python o database non disponibili');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('parametri di accesso e di sessione nei link', () {
    test('il filtro toglie token, sessioni e codici di riunione, non il resto', () async {
      const testo =
          'a https://proxy.esempio.it/book/1?login=true&token=eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjE.abc123def456 '
          'b https://web.ebsco.com/pdf?vid=3&sid=11111111-2222-3333-4444-555555555555&bdata=JnNpdGU9ZWhvc3QtbGl2ZQ%3d%3d&db=nlebk '
          'c https://unix.esempio.it/Guida/Pagina.do;jsessionid=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.node1?cds_id=2 '
          'd https://zoom.us/j/123456789?pwd=abcdEFGH1234 '
          'e https://x.it/p?sid=12&code=777&key=catalogo_2026 '
          'f https://books.google.com/books?id=x&sig=ACfU3U0abcdefghijklmnop '
          'g Per accedere a Moodle inserire la password: Corso2026xyz, la password è necessaria '
          'h video privato https://vimeo.com/123 Password: segreto99';
      final r = await python([
        '-c',
        '${caricaPulizia}print(p.senza_parametri_di_accesso(sys.argv[1]))',
        testo,
      ]);
      if (r == null) {
        markTestSkipped('Python non disponibile');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = (r.stdout as String).trim();
      expect(out, isNot(contains('eyJ')));
      expect(out, isNot(contains('11111111')));
      expect(out, isNot(contains('JnNpdGU9')));
      expect(out, isNot(contains('AAAAAAAA')));
      expect(out, isNot(contains('abcdEFGH')));
      // il resto del collegamento resta
      expect(out, contains('https://proxy.esempio.it/book/1?login=true '));
      expect(out, contains('https://web.ebsco.com/pdf?vid=3&db=nlebk '));
      expect(out, contains('Pagina.do?cds_id=2 '));
      expect(out, contains('https://zoom.us/j/123456789 '));
      // valori corti o parametri di catalogo: invariati
      expect(out, contains('https://x.it/p?sid=12&code=777&key=catalogo_2026 '));
      expect(out, contains('sig=ACfU3U0abcdefghijklmnop'));
      // password scritte nei testi: il valore si toglie, il resto della frase resta
      expect(out, isNot(contains('Corso2026xyz')));
      expect(out, isNot(contains('segreto99')));
      expect(out, contains('inserire la password: [rimossa], la password è necessaria'));
      expect(out, contains('https://vimeo.com/123 Password: [rimossa]'));
    });

    test('la build e gli strumenti usano lo stesso elenco', () {
      final pulizia = read('../tools/db_builder/pulizia.py');
      expect(pulizia, contains('def senza_parametri_di_accesso('));
      expect(pulizia, contains('def parametri_di_accesso_in('));
      for (final n in ['token', 'jsessionid', 'sid', 'pwd', 'bdata']) {
        expect(pulizia, contains('"$n"'), reason: n);
      }
      expect(
        read('../tools/db_builder/togli_email.py'),
        contains('parametri_di_accesso_in(b)'),
      );
    });
  });

  group('controllo veloce del database (togli_email.py --verifica)', () {
    test('byte, ricerca dalla «@» e processi paralleli', () {
      final s = read('../tools/db_builder/togli_email.py');
      expect(s, contains('ProcessPoolExecutor'));
      expect(s, contains('_CANDIDATO_EMAIL = re.compile('));
      expect(s, contains('_CANDIDATO_PERCORSO = re.compile('));
      expect(s, contains('b = Path(percorso).read_bytes()'));
      // non più la lettura come testo di ogni file con l'espressione completa
      expect(s, isNot(contains('f.read_text(encoding="utf-8")\n            if "@" not in s')));
    });

    test('trova indirizzi personali e link locali, non gli indirizzi istituzionali', () async {
      final dir = Directory.systemTemp.createTempSync('uninotes_g4_');
      try {
        Directory('${dir.path}/corsi').createSync();
        for (var i = 0; i < 10; i++) {
          File('${dir.path}/corsi/a$i.json').writeAsStringSync(
            '{"t":"scrivere a docente@unibo.it o a segreteria@ateneo.edu"}',
          );
        }
        final pulito = await python([
          '-c',
          'import sys, pathlib; sys.path.insert(0, "../tools/db_builder"); '
              'import togli_email as t; '
              'sys.exit(t.verifica(pathlib.Path(sys.argv[1]), 2))',
          dir.path,
        ]);
        if (pulito == null) {
          markTestSkipped('Python non disponibile');
          return;
        }
        expect(pulito.exitCode, 0, reason: '${pulito.stdout}${pulito.stderr}');

        File('${dir.path}/corsi/a3.json').writeAsStringSync(
          '{"t":"scrivere a mario.rossi@gmail.com per la dispensa"}',
        );
        File('${dir.path}/corsi/a4.json').writeAsStringSync(
          '{"t":"dispensa in file:///C:/$utenti/Mario/Downloads/x.pdf"}',
        );
        final sporco = await python([
          '-c',
          'import sys, pathlib; sys.path.insert(0, "../tools/db_builder"); '
              'import togli_email as t; '
              'sys.exit(t.verifica(pathlib.Path(sys.argv[1]), 2))',
          dir.path,
        ]);
        expect(sporco!.exitCode, 1, reason: '${sporco.stdout}${sporco.stderr}');
        final out = sporco.stdout as String;
        expect(out, contains('a3.json: indirizzo personale (mari…)'));
        expect(out, contains('a4.json: link a un file del computer'));
        expect(out, isNot(contains('a0.json')));
        // il resoconto non ripete i dati
        expect(out, isNot(contains('mario.rossi@gmail.com')));
        expect(out, isNot(contains('Mario')));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('controllo della copia pubblica (repo privata)', () {
    test('i percorsi con il nome dell\'utente nel database bloccano', () {
      if (!repoPrivata) {
        markTestSkipped('lo script della copia pubblica è solo nella repo privata');
        return;
      }
      final s = read(scriptCopia);
      expect(s, isNot(contains('(avvisi if dati else out).append(\n            f"{rel}:{_riga(b, i)}: percorso')));
      expect(s, contains('LINK_FILE_LOCALE = re.compile('));
      expect(s, contains('link a un file locale (file:…)'));
      expect(s, contains('parametri_di_accesso_in(b)'));
      // i numeri di telefono degli uffici restano un avviso
      expect(s, contains('avvisi if dati and nome == "numero di cellulare" else out'));
    });

    test('prova: un percorso locale nel database blocca la copia', () async {
      if (!repoPrivata) {
        markTestSkipped('lo script della copia pubblica è solo nella repo privata');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('uninotes_g4c_');
      try {
        Directory('${dir.path}/database/corsi').createSync(recursive: true);
        File('${dir.path}/database/corsi/x.json').writeAsStringSync(
          '{"t":"dispensa file:///C:/$utenti/Mario/Downloads/x.pdf e basta"}',
        );
        File('${dir.path}/database/corsi/y.json').writeAsStringSync(
          '{"t":"dispensa file:///C:/$utenti/admin/x.pdf e basta"}',
        );
        final r = await python([
          '-c',
          'import sys, pathlib; sys.path.insert(0, "../tools"); '
              'import esporta_pubblica as e; '
              'a = []; '
              'p = e.problemi_copia(pathlib.Path(sys.argv[1]), a, 1); '
              'print("PROBLEMI", len(p)); '
              'print("AVVISI", len(a)); '
              '[print(x) for x in p]',
          dir.path,
        ]);
        if (r == null) {
          markTestSkipped('Python non disponibile');
          return;
        }
        final out = r.stdout as String;
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(out, contains('AVVISI 0'));
        expect(
          out,
          contains(
            "x.json:1: percorso con il nome dell'utente del computer (Mari…)",
          ),
        );
        // anche un link file: con un nome generico si blocca nel database
        expect(out, contains('y.json:1: link a un file locale'));
        expect(out, isNot(contains('Mario')));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
