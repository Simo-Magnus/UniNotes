// Pulsante «Libri» di Studio: conta i libri dell'insegnamento (salvati,
// proposti, aggiunti a mano) senza i rimossi, indipendentemente dai file.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/features/books/book_filters.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 25; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
  }
}

void main() {
  test('studyBooks: senza i rimossi, i file non contano', () {
    const books = [
      Book(id: 1, title: 'Salvato con file', storedFile: 'a.pdf',
          catalogChoice: CatalogChoice.kept, externalId: 'x1'),
      Book(id: 2, title: 'Proposto', externalId: 'x2'),
      Book(id: 3, title: 'Aggiunto a mano'),
      Book(id: 4, title: 'Rimosso', externalId: 'x4',
          catalogChoice: CatalogChoice.removed),
      Book(id: 5, title: 'Rimosso con file', storedFile: 'b.pdf',
          externalId: 'x5', catalogChoice: CatalogChoice.removed),
    ];
    final shown = studyBooks(books);
    expect(shown.map((b) => b.id), [1, 2, 3]);
    expect(studyBooksLabel(shown), 'Libri (3)');
    // tolta la copia del file dall'app: il libro resta nel conteggio
    final noFile = [
      shown.first.withFile(storedFile: () => null),
      ...shown.skip(1),
    ];
    expect(studyBooksLabel(studyBooks(noFile)), 'Libri (3)');
    expect(studyBooksLabel(const []), 'Nessun libro');
  });

  testWidgets('Studio: il numero dei libri segue «Libri» (rimozioni e file)', (
    t,
  ) async {
    t.view.physicalSize = const Size(420, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await initializeDateFormatting('it_IT');
    late AppServices s;
    late int courseId;
    late Directory tmp;
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('um_study_books_');
      s = AppServices(
        await AppDatabase.openInMemory(),
        library: BookLibrary(baseDir: () async => tmp),
      );
      courseId = await s.courses.insert(
        const Course(name: 'Analisi I', universityId: 'polito'),
      );
      final m = await s.study.insertModule(
        StudyModule(courseId: courseId, name: 'Limiti'),
      );
      await s.study.insertTopic(Topic(moduleId: m, name: 'Limiti notevoli'));
      for (final b in [
        Book(courseId: courseId, title: 'Analisi 1', externalId: 'a',
            storedFile: 'analisi.pdf', catalogChoice: CatalogChoice.kept),
        Book(courseId: courseId, title: 'Esercizi', externalId: 'b'),
        Book(courseId: courseId, title: 'Vecchio', externalId: 'c',
            catalogChoice: CatalogChoice.removed),
      ]) {
        await s.books.insert(b);
      }
    });
    addTearDown(() => t.runAsync(s.database.close));
    addTearDown(() => tmp.deleteSync(recursive: true));
    await t.pumpWidget(
      Provider.value(
        value: s,
        child: const MaterialApp(home: StudyScreen()),
      ),
    );
    await _settle(t);
    expect(find.text('Libri (2)'), findsOneWidget);

    // «Rimuovi il file dall'app» in Libri: il libro resta contato
    await t.runAsync(() async {
      final b = (await s.books.all(courseId: courseId))
          .firstWhere((b) => b.title == 'Analisi 1');
      await s.books.update(b.withFile(storedFile: () => null));
      s.revision.bump();
    });
    await _settle(t);
    expect(find.text('Libri (2)'), findsOneWidget);

    // libro rimosso in Libri: esce dal conteggio; ripristinato, rientra
    late Book esercizi;
    await t.runAsync(() async {
      esercizi = (await s.books.all(courseId: courseId))
          .firstWhere((b) => b.title == 'Esercizi');
      await s.books.update(
        esercizi.withChoice(catalogChoice: () => CatalogChoice.removed),
      );
      s.revision.bump();
    });
    await _settle(t);
    expect(find.text('Libri (1)'), findsOneWidget);
    await t.runAsync(() async {
      await s.books.update(esercizi.withChoice(catalogChoice: () => null));
      s.revision.bump();
    });
    await _settle(t);
    expect(find.text('Libri (2)'), findsOneWidget);
  });
}
