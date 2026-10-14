// Viste del lettore per i nuovi formati: pagine DjVu (Ctrl+F nel testo
// nascosto, indice dai segnalibri, vai alla pagina) e note di Obsidian
// (collegamenti tra note, etichette).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/features/reader/views/djvu_view.dart';
import 'package:university_notes/features/reader/views/document_view.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/widgets/find_bar.dart';

Future<void> _settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ReaderStore store;

  setUp(() => tmp = Directory.systemTemp.createTempSync('um_pages_ui_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> write(WidgetTester t, String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await t.runAsync(() async {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
    });
    return f.path;
  }

  Future<void> open(WidgetTester t, String path) async {
    t.view.physicalSize = const Size(1000, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: ReaderScreen(key: ValueKey(path), path: path, store: store),
      ),
    );
    await _settle(t);
  }

  testWidgets('DjVu: pagine, Ctrl+F nel testo nascosto, segnalibri', (t) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final bytes = File('test/fixtures/djvu/bundled.djvu').readAsBytesSync();
    final path = await write(t, 'Dispense.djvu', bytes);
    await open(t, path);
    expect(find.byType(DjvuView), findsOneWidget);
    expect(find.text('Pagina 1 di 3'), findsOneWidget);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(find.byType(FindBar), findsOneWidget);
    await t.enterText(find.byType(TextField), 'perche');
    await t.pump();
    expect(find.text('1 di 1'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'teorema di');
    await t.pump();
    expect(find.text('1 di 1'), findsOneWidget);

    // Indice dai segnalibri NAVM.
    await t.tap(find.byTooltip('Indice e segnalibri'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Composta'), findsOneWidget);
    await t.tap(find.widgetWithText(ListTile, 'Composta'));
    await _settle(t, 6);
    expect(find.text('Pagina 3 di 3'), findsOneWidget);
    // Le pagine si disegnano (nell'isolate) senza errori.
    await _settle(t, 20);
    expect(find.text('Pagina non decodificabile'), findsNothing);
    await t.runAsync(db.close);
  });

  testWidgets(
    'Obsidian: [[collegamento]] apre l\'altra nota, #etichetta cerca',
    (t) async {
      db = (await t.runAsync(AppDatabase.openInMemory))!;
      store = ReaderStore(SettingsRepository(db));
      await write(t, 'vault/Limiti.md', utf8.encode('# Limiti\n\nIl limite.'));
      final path = await write(
        t,
        'vault/Derivate.md',
        utf8.encode(
          '# Derivate\n\nPrima i [[Limiti]], poi #analisi.\n\n#analisi',
        ),
      );
      await open(t, path);
      expect(find.byType(DocumentView), findsOneWidget);

      // L'etichetta apre la ricerca con il suo nome.
      final view = t.widget<DocumentView>(find.byType(DocumentView));
      view.onLink!('tag:#analisi');
      await t.pump();
      expect(find.byType(FindBar), findsOneWidget);
      expect(find.text('1 di 2'), findsOneWidget);

      view.onLink!('note:Limiti');
      await _settle(t);
      expect(find.byType(ReaderScreen, skipOffstage: false), findsNWidgets(2));
      expect(find.text('Limiti.md'), findsOneWidget);
      expect(
        find.textContaining('Il limite.', findRichText: true),
        findsOneWidget,
      );

      // Nota inesistente: avviso.
      t.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(t, 6);
      view.onLink!('note:Integrali');
      await _settle(t, 4);
      expect(find.textContaining('Nota non trovata'), findsWidgets);
      await t.runAsync(db.close);
    },
  );
}
