import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/schema.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/services/datapack_importer.dart';
import 'package:university_notes/features/books/book_filters.dart';
import 'package:university_notes/features/books/reading_position.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/repositories/book_repository.dart';

void main() {
  late Directory tmp;
  late BookLibrary library;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('um_books_');
    library = BookLibrary(baseDir: () async => tmp);
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<File> source(String name, [String content = '%PDF-1.4 test']) async {
    final f = File(p.join(tmp.path, 'esterni', name));
    await f.parent.create(recursive: true);
    return f.writeAsString(content);
  }

  group('BookLibrary', () {
    test('copia il file nella cartella libri e lo ritrova', () async {
      final src = await source('Analisi 1.pdf');
      final name = await library.store(src.path);
      expect(name, 'Analisi 1.pdf');
      final f = await library.fileOf(Book(title: 'A', storedFile: name));
      expect(f, isNotNull);
      expect(p.dirname(f!.path), p.join(tmp.path, BookLibrary.booksFolder));
      expect(await f.readAsString(), '%PDF-1.4 test');

      // L'originale può sparire: la copia nell'app resta.
      await src.delete();
      expect(
        await library.fileOf(Book(title: 'A', storedFile: name)),
        isNotNull,
      );
      expect(await library.totalBytes(), 13);
    });

    test('nomi uguali non si sovrascrivono; caratteri non validi', () async {
      final a = await library.store((await source('libro.pdf')).path);
      final b = await library.store((await source('libro.pdf', 'altro')).path);
      expect(a, 'libro.pdf');
      expect(b, 'libro (2).pdf');
      // Su Windows un file con ':' o '?' non si può nemmeno creare.
      if (!Platform.isWindows) {
        final c = await library.store((await source('a:b?.epub')).path);
        expect(c, 'a_b_.epub');
      }
    });

    test('remove elimina la copia; file mancante = null', () async {
      final name = await library.store((await source('x.pdf')).path);
      await library.remove(name);
      expect(await library.fileOf(Book(title: 'x', storedFile: name)), isNull);
      await library.remove(name); // nessun errore se manca già
      await library.remove(null);
      expect(await library.fileOf(const Book(title: 'nessuno')), isNull);
    });

    test('store di un file inesistente fallisce', () async {
      expect(
        () => library.store(p.join(tmp.path, 'manca.pdf')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('database', () {
    test('migrazione v1 → v2 conserva i libri e aggiunge le colonne', () async {
      sqfliteFfiInit();
      final path = p.join(tmp.path, 'v1.db');
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final s in kSchemaV1) {
              await db.execute(s);
            }
          },
        ),
      );
      await v1.insert('books', {
        'title': 'Vecchio libro',
        'file_path': 'D:/x.pdf',
      });
      await v1.close();

      final db = await AppDatabase.open(path: path);
      addTearDown(db.close);
      expect(await db.db.getVersion(), kSchemaVersion);
      final repo = BookRepository(db);
      final b = (await repo.all()).single;
      expect(b.title, 'Vecchio libro');
      expect(b.filePath, 'D:/x.pdf');
      expect(b.storedFile, isNull);
      await repo.saveReadingPosition(b.id!, page: 7, pageCount: 120);
      final r = await repo.byId(b.id!);
      expect(r!.lastPage, 7);
      expect(r.pageCount, 120);
      expect(r.lastOpenedAt, isNotNull);
    });

    test('importLinked copia i libri con un percorso valido', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final repo = BookRepository(db);
      final src = await source('chimica.pdf');
      await repo.insert(Book(title: 'Chimica', filePath: src.path));
      await repo.insert(
        const Book(title: 'Perso', filePath: '/non/esiste.pdf'),
      );
      await repo.insert(const Book(title: 'Senza file'));

      final r = await library.importLinked(repo);
      expect(r.copied, 1);
      expect(r.missing, 1);
      expect(r.errors, isEmpty);
      final chimica = (await repo.all()).firstWhere(
        (b) => b.title == 'Chimica',
      );
      expect(chimica.storedFile, 'chimica.pdf');
      expect(chimica.filePath, src.path);
      expect(isInApp(chimica), isTrue);

      // Già copiato: la seconda volta non fa nulla.
      expect((await library.importLinked(repo)).copied, 0);
    });

    test(
      'un nuovo data pack non cancella file nell\'app e pagina letta',
      () async {
        final db = await AppDatabase.openInMemory();
        addTearDown(db.close);
        final importer = DataPackImporter(db);
        Map<String, Object?> pack(String title) => {
          'format': 'university-manager-datapack',
          'version': 1,
          'source': 'test',
          'books': [
            {
              'externalId': 'book:1',
              'title': title,
              'filePath': 'D:/Libri/a.pdf',
            },
          ],
        };
        await importer.importMap(pack('Titolo'), exclusionPatterns: const []);
        final repo = BookRepository(db);
        final b = (await repo.all()).single;
        await repo.update(b.withFile(storedFile: () => 'a.pdf'));
        await repo.saveReadingPosition(b.id!, page: 42, pageCount: 300);

        await importer.importMap(
          pack('Titolo nuovo'),
          exclusionPatterns: const [],
        );
        final after = (await repo.all()).single;
        expect(after.title, 'Titolo nuovo');
        expect(after.storedFile, 'a.pdf');
        expect(after.lastPage, 42);
        expect(readingProgress(after), 'p. 42/300');
      },
    );
  });

  group('materiali', () {
    test('copiati nell\'app; il data pack non li cancella', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final repo = BookRepository(db);
      final mats = BookLibrary(
        baseDir: () async => tmp,
        folderName: BookLibrary.materialsFolder,
      );
      final src = await source('lezione1.pdf');
      Map<String, Object?> pack(String title) => {
        'format': 'university-manager-datapack',
        'version': 1,
        'materials': [
          {
            'externalId': 'm1',
            'title': title,
            'localPath': src.path,
            'kind': 'lecture',
          },
          {
            'externalId': 'm2',
            'title': 'Perso',
            'localPath': '/non/esiste.pdf',
          },
        ],
      };
      final importer = DataPackImporter(db);
      await importer.importMap(pack('Lezione 1'), exclusionPatterns: const []);
      final r = await mats.importLinkedMaterials(repo);
      expect(r.copied, 1);
      expect(r.missing, 1);
      var m = (await repo.materials()).firstWhere((x) => x.externalId == 'm1');
      expect(m.storedFile, 'lezione1.pdf');
      expect(
        p.basename(p.dirname((await mats.fileNamed(m.storedFile))!.path)),
        'materiali',
      );
      await repo.saveMaterialPosition(m.id!, page: 4, pageCount: 20);

      await importer.importMap(
        pack('Lezione 1 (rev.)'),
        exclusionPatterns: const [],
      );
      m = (await repo.materials()).firstWhere((x) => x.externalId == 'm1');
      expect(m.title, 'Lezione 1 (rev.)');
      expect(m.storedFile, 'lezione1.pdf');
      expect(m.lastPage, 4);
      expect(m.pageCount, 20);
    });
  });

  group('posizione di lettura', () {
    test('salva con ritardo solo l\'ultima pagina; flush immediato', () {
      fakeAsync((async) {
        final saved = <(int, int?)>[];
        final s = ReadingPositionSaver(
          initialPage: 5,
          save: (page, count) async => saved.add((page, count)),
        )..pageCount = 200;
        s.pageChanged(6);
        s.pageChanged(7);
        s.pageChanged(8);
        async.elapse(const Duration(milliseconds: 500));
        expect(saved, isEmpty);
        async.elapse(const Duration(milliseconds: 400));
        expect(saved, [(8, 200)]);

        s.pageChanged(8); // stessa pagina: niente scrittura
        s.flush();
        async.flushMicrotasks();
        expect(saved, [(8, 200)]);

        s.pageChanged(9);
        s.flush(); // chiusura del lettore
        async.flushMicrotasks();
        expect(saved.last, (9, 200));
        s.dispose();
      });
    });

    test('resumePage', () {
      expect(resumePage(null, null), 1);
      expect(resumePage(0, 10), 1);
      expect(resumePage(45, 300), 45);
      expect(resumePage(400, 300), 300);
      expect(resumePage(12, null), 12);
    });
  });
}
