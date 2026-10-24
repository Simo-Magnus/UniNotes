import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/services/local_data.dart';
import 'package:university_notes/core/services/temp_files.dart';
import 'package:university_notes/features/cloud/incoming_files.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/features/notes/safe_files.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Terzo giro della caccia ai crash, categoria «file system e percorsi»:
/// nomi scelti dall'utente che diventano nomi di file, cartelle che spariscono
/// o non si leggono durante un elenco, copie interrotte, cestino con
/// l'orologio avanti, file temporanei rimasti.
void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('un_r3file_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// Toglie il permesso di leggere l'elenco di [d] (solo Windows, con
  /// icacls): la cartella esiste ma `list()` fallisce, come con una cartella
  /// senza permessi o a metà di un'unità che si scollega.
  Future<void> denyList(Directory d) async {
    final user = Platform.environment['USERNAME']!;
    final r = await Process.run('icacls', [d.path, '/deny', '$user:(RD)']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    addTearDown(() => Process.run('icacls', [d.path, '/remove:d', user]));
  }

  const skipAcl = 'serve Windows (icacls) per negare la lettura';
  final onWindows = Platform.isWindows;

  group('nomi che diventano file e cartelle', () {
    test('safeName: «Analisi I / II: esercizi?» senza caratteri vietati', () {
      expect(
        NotesStore.safeName('Analisi I / II: esercizi?', windows: true),
        'Analisi I _ II_ esercizi_',
      );
    });

    test('safeName: i nomi riservati di Windows (CON, aux.txt, COM1…)', () {
      expect(NotesStore.safeName('CON', windows: true), 'CON_');
      expect(NotesStore.safeName('con', windows: true), 'con_');
      expect(NotesStore.safeName('aux.txt', windows: true), 'aux_.txt');
      expect(NotesStore.safeName('Com1', windows: true), 'Com1_');
      expect(NotesStore.safeName('LPT9', windows: true), 'LPT9_');
      // non sono riservati: contengono solo il nome
      expect(NotesStore.safeName('Console', windows: true), 'Console');
      expect(NotesStore.safeName('Com10', windows: true), 'Com10');
      expect(NotesStore.safeName('Fisica AUX', windows: true), 'Fisica AUX');
      // altrove i nomi restano com'erano (cartelle già esistenti)
      expect(NotesStore.safeName('CON', windows: false), 'CON');
    });

    test('safeName: punti iniziali e finali, spazi, nome vuoto', () {
      // un file «.nota.md» sparirebbe dagli elenchi (nascosto) e una
      // cartella «.eliminati» sarebbe il cestino
      expect(NotesStore.safeName('.eliminati'), 'eliminati');
      expect(NotesStore.safeName('...'), 'Senza nome');
      expect(NotesStore.safeName(' . Fisica . '), 'Fisica');
      expect(NotesStore.safeName(''), 'Senza nome');
    });

    test('safeName: 300 caratteri e emoji tagliate a metà', () {
      final long = NotesStore.safeName('a' * 300);
      expect(long.length, 90);
      // 89 lettere + una coppia surrogata al limite dei 90: non si spezza
      final emoji = NotesStore.safeName('${'a' * 89}\u{1F600}coda');
      expect(emoji, 'a' * 89);
      for (final u in emoji.codeUnits) {
        expect(u >= 0xD800 && u <= 0xDFFF, isFalse);
      }
      // dopo il taglio non restano punti o spazi finali
      expect(NotesStore.safeName('${'a' * 89}. coda'), 'a' * 89);
    });

    test('cutText e isWindowsReservedName', () {
      expect(cutText('abc', 5), 'abc');
      expect(cutText('abcdef', 3), 'abc');
      expect(cutText('ab\u{1F600}', 3), 'ab');
      expect(cutText('ab\u{1F600}', 4), 'ab\u{1F600}');
      expect(isWindowsReservedName('NUL'), isTrue);
      expect(isWindowsReservedName('nul.tar.gz'), isTrue);
      expect(isWindowsReservedName('nul .txt'), isTrue);
      expect(isWindowsReservedName('nulla'), isFalse);
    });

    test('fitToPath: su Windows il percorso resta sotto i 260 caratteri', () {
      final dir = 'C:\\${'x' * 150}';
      final name = 'n' * 90;
      final fitted = NotesStore.fitToPath(name, dir, reserve: 20, windows: true);
      expect(dir.length + 1 + fitted.length + 20, lessThanOrEqualTo(240));
      expect(fitted.length, lessThan(name.length));
      // percorsi cortissimi: nome intero; altri sistemi: mai tagliato
      expect(NotesStore.fitToPath(name, 'C:\\a', windows: true), name);
      expect(NotesStore.fitToPath(name, dir, windows: false), name);
      // anche con una radice enorme resta un nome utilizzabile
      expect(
        NotesStore.fitToPath(name, 'C:\\${'y' * 500}', windows: true).length,
        20,
      );
    });

    test('rinominare con un nome lunghissimo su Windows non esce dal limite '
        'e le tre cartelle restano collegate', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final store = NotesStore(SettingsRepository(db), root: () async => tmp);
      const c = Course(name: 'Analisi', universityId: 'polito');
      final rec = await store.courseDir(c, NoteFolder.recordings);
      final tr = await store.courseDir(c, NoteFolder.transcripts);
      File(p.join(rec.path, 'L.m4a')).writeAsStringSync('a');
      File(p.join(tr.path, 'L.md')).writeAsStringSync('t');
      final files = await store.list(c);
      final moves = await store.rename(c, files[NoteFolder.recordings]!.single,
          'X' * 200);
      expect(moves.length, 2);
      for (final to in moves.values) {
        expect(File(to).existsSync(), isTrue);
        if (Platform.isWindows) {
          expect(to.length, lessThanOrEqualTo(260));
        }
      }
      expect(
        p.basenameWithoutExtension(moves.values.first),
        p.basenameWithoutExtension(moves.values.last),
      );
    });

    test('libri: «CON.pdf», estensioni enormi, nomi vuoti e emoji', () {
      expect(BookLibrary.uniqueName(tmp, 'CON.pdf'), 'CON_.pdf');
      expect(BookLibrary.uniqueName(tmp, 'nul'), 'nul_');
      final huge = BookLibrary.uniqueName(tmp, 'libro.${'z' * 400}');
      expect(huge.length, lessThanOrEqualTo(80 + 16));
      final emoji = BookLibrary.uniqueName(
        tmp,
        '${'a' * 79}\u{1F600}${'b' * 20}.pdf',
      );
      expect(emoji, '${'a' * 79}.pdf');
      expect(BookLibrary.uniqueName(tmp, '...pdf'), isNotEmpty);
      expect(BookLibrary.uniqueName(tmp, 'x.'), 'x');
      File(p.join(tmp.path, 'libro.pdf')).writeAsStringSync('1');
      expect(BookLibrary.uniqueName(tmp, 'libro.pdf'), 'libro (2).pdf');
    });

    test('file ricevuti da fuori: estensione limitata e senza punto finale',
        () {
      final n = IncomingFiles.safeFileName('relazione.${'q' * 300}');
      expect(n.length, lessThanOrEqualTo(90 + 16));
      expect(IncomingFiles.safeFileName('appunti.'), 'appunti');
      expect(IncomingFiles.safeFileName('CON.pdf'),
          Platform.isWindows ? 'CON_.pdf' : 'CON.pdf');
    });
  });

  group('cartelle che spariscono o non si leggono', () {
    test('renameCourse non lancia con la cartella degli appunti irraggiungibile',
        () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final store = NotesStore(
        SettingsRepository(db),
        root: () async =>
            throw const FileSystemException('unità non raggiungibile'),
      );
      const a = Course(name: 'Analisi', universityId: 'polito');
      const b = Course(name: 'Analisi 1', universityId: 'polito');
      // prima l'aggiornamento del catalogo si interrompeva a metà e il corso
      // salvato mostrava «Errore nel salvataggio»
      await store.renameCourse(a, b);
    });

    test('elenco degli appunti con una cartella che non si legge', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final store = NotesStore(SettingsRepository(db), root: () async => tmp);
      const c = Course(name: 'Analisi', universityId: 'polito');
      final rec = await store.courseDir(c, NoteFolder.recordings);
      final notes = await store.courseDir(c, NoteFolder.notes);
      File(p.join(rec.path, 'L.m4a')).writeAsStringSync('a');
      File(p.join(notes.path, 'nota.md')).writeAsStringSync('n');
      await denyList(rec);
      final files = await store.list(c);
      expect(files[NoteFolder.recordings], isEmpty);
      expect(files[NoteFolder.notes]!.single.name, 'nota');
      expect(await store.count(c), 1);
    }, skip: onWindows ? false : skipAcl);

    test('cestino con la cartella che non si legge: elenco vuoto, non errore',
        () async {
      final bin = RecycleBin(() async => tmp);
      final f = File(p.join(tmp.path, 'a.md'))..writeAsStringSync('x');
      await bin.trash([f], title: 'a');
      await denyList(await bin.dir());
      expect(await bin.list(), isEmpty);
    }, skip: onWindows ? false : skipAcl);

    test('svuotare una cartella che non si legge non lancia', () async {
      final d = Directory(p.join(tmp.path, 'x'))..createSync();
      File(p.join(d.path, 'a')).writeAsStringSync('x');
      await denyList(d);
      await LocalData.clearDirectory(d);
    }, skip: onWindows ? false : skipAcl);
  });

  group('copie e scritture interrotte', () {
    test('copyFileSafely: file di partenza sparito, nessun .part', () async {
      final src = File(p.join(tmp.path, 'manca.pdf'));
      final dest = p.join(tmp.path, 'dest.pdf');
      await expectLater(
        copyFileSafely(src, dest),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('copyFileSafely: copia completa e nessun .part', () async {
      final src = File(p.join(tmp.path, 'a.pdf'))..writeAsStringSync('dati');
      final dest = p.join(tmp.path, 'b.pdf');
      final out = await copyFileSafely(src, dest);
      expect(out.readAsStringSync(), 'dati');
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('scrittura sicura: errore -> niente file temporaneo, file intatto',
        () async {
      final f = File(p.join(tmp.path, 'nota.md'))..writeAsStringSync('vecchio');
      // il .part è una cartella: la scrittura fallisce
      Directory('${f.path}.part').createSync();
      await expectLater(writeStringAtomic(f, 'nuovo'), throwsA(anything));
      expect(f.readAsStringSync(), 'vecchio');
      await writeBytesAtomic(
        File(p.join(tmp.path, 'b.bin')),
        const [1, 2, 3],
      );
      expect(File(p.join(tmp.path, 'b.bin')).readAsBytesSync(), [1, 2, 3]);
      expect(File(p.join(tmp.path, 'b.bin.part')).existsSync(), isFalse);
    });
  });

  group('percorsi esterni', () {
    test('fileExistsQuick: esiste, non esiste, percorso impossibile', () async {
      final f = File(p.join(tmp.path, 'a.pdf'))..writeAsStringSync('x');
      expect(await fileExistsQuick(f.path), isTrue);
      expect(await fileExistsQuick(p.join(tmp.path, 'manca.pdf')), isFalse);
      expect(await fileExistsQuick(''), isFalse);
      expect(await fileExistsQuick('a\u0000b'), isFalse);
    });
  });

  group('cestino e orologio', () {
    test('orologio portato avanti per errore: nulla sparisce subito, e tornando '
        'indietro tutto resta', () async {
      var now = DateTime(2026, 10, 1, 12);
      final bin = RecycleBin(() async => tmp, now: () => now);
      final f = File(p.join(tmp.path, 'lezione.m4a'))..writeAsStringSync('a');
      await bin.trash([f], title: 'Lezione');
      // l'orologio salta di un anno
      now = DateTime(2027, 10, 1, 12);
      expect(await bin.purge(), 0);
      expect((await bin.list()).length, 1);
      // l'utente se ne accorge e lo corregge: si annulla l'annotazione
      now = DateTime(2026, 10, 2, 12);
      expect((await bin.list()).length, 1);
      final folder = Directory(p.join((await bin.dir()).path, (await bin.list()).single.id));
      expect(File(p.join(folder.path, RecycleBin.expiredMark)).existsSync(),
          isFalse);
      // una scadenza vera: annotata, poi cancellata dopo la tolleranza
      now = DateTime(2026, 11, 2, 12);
      expect(await bin.purge(), 0);
      now = now.add(RecycleBin.grace - const Duration(hours: 1));
      expect(await bin.purge(), 0);
      expect((await bin.list()).length, 1);
      now = now.add(const Duration(hours: 2));
      expect(await bin.purge(), 1);
      expect(await bin.list(), isEmpty);
    });

    test('l\'annotazione di scadenza non entra nel ripristino', () async {
      var now = DateTime(2026, 10, 1, 12);
      final bin = RecycleBin(() async => tmp, now: () => now);
      final f = File(p.join(tmp.path, 'a.md'))..writeAsStringSync('x');
      final e = (await bin.trash([f], title: 'a'))!;
      now = DateTime(2026, 12, 1);
      await bin.purge();
      final back = await bin.restore(e);
      expect(back.single.path, f.path);
      expect(f.readAsStringSync(), 'x');
    });
  });

  group('file temporanei rimasti', () {
    test('le cartelle di lavoro vecchie si tolgono, quelle recenti e quella '
        'dell\'audio eliminato a metà no', () async {
      final stale = Directory(p.join(tmp.path, 'whisper_old'))..createSync();
      File(p.join(stale.path, 'audio.wav')).writeAsStringSync('x');
      final live = Directory(p.join(tmp.path, 'uninotes_live_old'))
        ..createSync();
      final trash = Directory(p.join(tmp.path, 'uninotes_cestino_old'))
        ..createSync();
      File(p.join(trash.path, 'lezione.wav')).writeAsStringSync('audio');
      final other = Directory(p.join(tmp.path, 'altro_programma'))
        ..createSync();
      // tutto è "vecchio" di un giorno
      await clearTempFiles(
        temp: tmp,
        now: () => DateTime.now().add(const Duration(days: 1)),
      );
      expect(stale.existsSync(), isFalse);
      expect(live.existsSync(), isFalse);
      expect(trash.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
      // e quelle appena create restano (un lavoro in corso)
      final fresh = Directory(p.join(tmp.path, 'whisper_fresh'))..createSync();
      await clearTempFiles(temp: tmp);
      expect(fresh.existsSync(), isTrue);
    });
  });
}
