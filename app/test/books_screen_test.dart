import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/books/book_tile.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';

Future<AppServices> _seed() async {
  final s = AppServices(await AppDatabase.openInMemory());
  final c = await s.courses.insert(const Course(name: 'Analisi I'));
  await s.books.insert(
    Book(
      courseId: c,
      title: 'Analisi Matematica 1',
      format: BookFormat.pdf,
      ownership: BookOwnership.owned,
      filePath: '/percorso/inesistente/analisi.pdf',
      language: 'italiano',
      required: true,
    ),
  );
  await s.books.insert(
    const Book(title: 'Manuale da comprare', required: false),
  );
  await s.books.insert(
    Book(
      courseId: c,
      title: 'Chimica nell app',
      format: BookFormat.pdf,
      ownership: BookOwnership.owned,
      storedFile: 'chimica.pdf',
      lastPage: 12,
      pageCount: 300,
    ),
  );
  return s;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

Future<void> _run(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = (await tester.runAsync(_seed))!;
  addTearDown(() => tester.runAsync(services.database.close));
  await tester.pumpWidget(
    Provider.value(
      value: services,
      child: const MaterialApp(home: BooksScreen()),
    ),
  );
  await _settle(tester);

  expect(find.text('Analisi Matematica 1'), findsOneWidget);
  expect(find.text('Obbligatorio'), findsOneWidget);
  // senza indicazioni nel database il libro è «Consigliato»
  expect(find.text('Consigliato'), findsNWidgets(2));
  expect(find.text('Scaricato (italiano)'), findsOneWidget);
  expect(find.text('Da procurare'), findsWidgets);
  expect(find.text('Senza materia'), findsOneWidget);
  expect(find.text("Nell'app"), findsOneWidget);
  expect(find.text('p. 12/300'), findsOneWidget);
  // «n/m»: posseduti (scaricati o segnati) su totali, senza «Libri».
  expect(find.text('2/3'), findsOneWidget);
  expect(find.text('2/3 Libri'), findsNothing);
  // niente «Tutti» tra i segmenti, niente formato né riquadro dell'ateneo
  expect(find.text('Tutti'), findsNothing);
  expect(find.text('PDF'), findsNothing);
  // «Da procurare» solo per gli obbligatori: il manuale consigliato no.
  expect(find.byKey(const Key('books-owned-count')), findsOneWidget);

  // Filtro "Da procurare": solo obbligatori senza file (qui nessuno).
  await tester.tap(find.text('Da procurare').first);
  await tester.pump();
  expect(find.text('Analisi Matematica 1'), findsNothing);
  expect(find.text('Manuale da comprare'), findsNothing);

  // Ricerca (toccando di nuovo «Da procurare» si torna a tutti i libri).
  await tester.tap(find.text('Da procurare').first);
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'matematica');
  await tester.pump();
  expect(find.text('Analisi Matematica 1'), findsOneWidget);
  expect(find.text('Manuale da comprare'), findsNothing);

  // Nuovo libro: niente formato, posizione fisica né nome file previsto.
  await tester.tap(find.text('Aggiungi libro').first);
  await tester.pumpAndSettle();
  expect(find.text('Nuovo libro'), findsOneWidget);
  expect(find.byKey(const Key('book-course')), findsOneWidget);
  expect(find.text('Formato'), findsNothing);
  expect(find.text('Posizione fisica'), findsNothing);
  expect(find.text('Nome file previsto'), findsNothing);
}

void main() {
  testWidgets('BooksScreen su smartphone', (tester) async {
    await _run(tester, const Size(420, 900));
  });

  testWidgets('BooksScreen su desktop', (tester) async {
    await _run(tester, const Size(1400, 900));
  });

  testWidgets('«Aggiungi» alla stessa distanza dal bordo del titolo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookTile(
            book: const Book(id: 7, title: 'Manuale da comprare'),
            onOpen: () {},
            onAction: (_) {},
          ),
        ),
      ),
    );
    final title = tester.getTopLeft(find.text('Manuale da comprare'));
    final attach = find.byKey(const ValueKey('attach-7'));
    expect(attach, findsOneWidget);
    final icon = tester.getTopLeft(
      find.descendant(of: attach, matching: find.byIcon(Icons.attach_file)),
    );
    // sotto il titolo e allineato a sinistra con lui
    expect(icon.dy, greaterThan(title.dy));
    expect(icon.dx, closeTo(title.dx, 0.5));
  });
}
