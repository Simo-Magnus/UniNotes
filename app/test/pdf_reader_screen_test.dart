import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/books/pdf_reader_screen.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/repositories/book_repository.dart';

/// PDF minimo di [pages] pagine, con tabella xref corretta.
List<int> _pdf(int pages) {
  final objs = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < pages; i++) '${3 + i} 0 R'].join(' ')}] /Count $pages >>',
    for (var i = 0; i < pages; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(out.toString());
}

/// Attende (fino a ~20 s) che compaia [text]: PDFium carica il documento in
/// modo asincrono e il lettore conosce il numero di pagine solo dopo.
Future<void> _waitText(WidgetTester t, String text) async {
  for (var i = 0; i < 200 && find.text(text).evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Serve la libreria PDFium nativa: impostare PDFIUM_PATH (ad esempio
/// libpdfium.so da github.com/bblanchon/pdfium-binaries). Nota: con alcune
/// versioni di pdfrx il visualizzatore non diventa «pronto» dentro
/// flutter_test; la ripresa dall'ultima pagina è verificata anche a mano
/// nell'app (apri un PDF, vai a pagina 3, chiudi e riapri: «Pagina 3 di N»).
final _pdfium = Platform.environment['PDFIUM_PATH'];

void main() {
  testWidgets('il lettore riapre all\'ultima pagina letta e salva la nuova', (
    t,
  ) async {
    Pdfrx.pdfiumModulePath = _pdfium;
    t.view.physicalSize = const Size(500, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final tmp = Directory.systemTemp.createTempSync('um_pdf_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tmp.path,
        );
    final file = File(p.join(tmp.path, 'cinque.pdf'))
      ..writeAsBytesSync(_pdf(5));

    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final repo = BookRepository(db);
    final id = (await t.runAsync(
      () => repo.insert(
        const Book(title: 'Cinque', storedFile: 'cinque.pdf', lastPage: 3),
      ),
    ))!;
    final book = (await t.runAsync(() => repo.byId(id)))!;

    await t.pumpWidget(
      MaterialApp(
        home: PdfReaderScreen(
          title: book.title,
          file: file,
          lastPage: book.lastPage,
          pageCount: book.pageCount,
          savePosition: (page, count) =>
              repo.saveReadingPosition(id, page: page, pageCount: count),
        ),
      ),
    );
    await _waitText(t, 'Pagina 3 di 5');
    expect(find.text('Pagina 3 di 5'), findsOneWidget);

    await t.tap(find.byIcon(Icons.find_in_page_outlined));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '5');
    await t.tap(find.text('Vai'));
    await _waitText(t, 'Pagina 5 di 5');
    expect(find.text('Pagina 5 di 5'), findsOneWidget);

    // Chiudendo il lettore la pagina viene salvata subito.
    await t.pumpWidget(const SizedBox());
    await _settle(t, 5);
    final after = (await t.runAsync(() => repo.byId(id)))!;
    expect(after.lastPage, 5);
    expect(after.pageCount, 5);
    await t.runAsync(db.close);
  }, skip: _pdfium == null);
}
