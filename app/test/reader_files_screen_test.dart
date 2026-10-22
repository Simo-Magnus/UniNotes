import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/reader/files_screen.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/reader/reader_store.dart';

import 'reader_fixtures.dart';

Future<void> _settle(WidgetTester t, [int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets(
    'File: cartelle dell\'app, ricerca per nome, apertura nel lettore, recenti',
    (t) async {
      t.view.physicalSize = const Size(1000, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      late Directory tmp;
      late AppServices s;
      await t.runAsync(() async {
        tmp = await Directory.systemTemp.createTemp('um_files_');
        final db = await AppDatabase.openInMemory();
        final base = AppServices(db);
        s = AppServices(
          db,
          library: BookLibrary(baseDir: () async => tmp),
          materialsLibrary: BookLibrary(
            baseDir: () async => tmp,
            folderName: BookLibrary.materialsFolder,
          ),
          attachmentsLibrary: BookLibrary(
            baseDir: () async => tmp,
            folderName: BookLibrary.attachmentsFolder,
          ),
          notes: NotesStore(
            base.settings,
            root: () async => Directory(p.join(tmp.path, 'Appunti')),
          ),
        );
        Future<void> put(String rel, List<int> bytes) async {
          final f = File(p.join(tmp.path, rel));
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes);
        }

        await put('libri/Analisi I.pdf', ascii.encode('%PDF-1.4'));
        await put('materiali/Slide termodinamica.pptx', buildPptx());
        await put('materiali/.nascosto', [1]);
        await put(
          'Appunti/Fisica/Trascrizioni/Lezione 1.md',
          utf8.encode('# Lezione'),
        );
      });
      addTearDown(() => tmp.deleteSync(recursive: true));

      await t.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(theme: AppTheme.dark(), home: const FilesScreen()),
        ),
      );
      await _settle(t);

      for (final label in ['Appunti', 'Libri', 'Materiali', 'Allegati']) {
        expect(
          find.widgetWithText(ListTile, label),
          findsOneWidget,
          reason: label,
        );
      }
      // niente più «Apri un file…»: la sezione mostra i file dell'app
      expect(find.text('Apri un file…'), findsNothing);
      expect(
        find.text('I file aperti nel lettore compaiono qui.'),
        findsOneWidget,
      );
      // Conteggi: un file per cartella (il file nascosto non conta).
      final materiali = find.widgetWithText(ListTile, 'Materiali');
      expect(
        find.descendant(of: materiali, matching: find.text('1')),
        findsOneWidget,
      );

      // Ricerca per nome (senza accenti né maiuscole).
      await t.enterText(find.byType(TextField), 'TERMODINAMICA');
      await t.pump();
      expect(find.text('Slide termodinamica.pptx'), findsOneWidget);
      expect(find.text('Materiali'), findsOneWidget);

      await t.tap(find.text('Slide termodinamica.pptx'));
      await _settle(t);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.text('Diapositiva 1 di 2'), findsOneWidget);

      await t.pageBack();
      await _settle(t);
      await t.tap(find.byTooltip('Cancella'));
      await _settle(t);
      expect(
        find.widgetWithText(ListTile, 'Slide termodinamica.pptx'),
        findsOneWidget,
      );
      final recent = (await t.runAsync(
        () => ReaderStore(s.settings).recent(),
      ))!;
      expect(recent.single.name, 'Slide termodinamica.pptx');

      // Esplora una cartella e apri un file.
      await t.tap(find.widgetWithText(ListTile, 'Appunti'));
      await _settle(t);
      expect(find.text('Fisica'), findsOneWidget);
      await t.tap(find.text('Fisica'));
      await _settle(t);
      await t.tap(find.text('Trascrizioni'));
      await _settle(t);
      await t.tap(find.text('Lezione 1.md'));
      await _settle(t);
      expect(find.textContaining('Lezione', findRichText: true), findsWidgets);
      expect(find.byType(ReaderScreen), findsOneWidget);

      // Elenco dei formati supportati.
      t
          .state<NavigatorState>(find.byType(Navigator))
          .popUntil((r) => r.isFirst);
      await _settle(t, 12);
      await t.tap(find.byTooltip('Formati supportati'));
      await t.pumpAndSettle();
      expect(find.textContaining('.docx'), findsOneWidget);
      expect(find.textContaining('.djvu'), findsOneWidget);
      expect(find.textContaining('(Apri con…)'), findsNothing);
      // formati con la resa semplificata, spiegati in cima all'elenco
      expect(find.textContaining('.ppt (semplificato)'), findsOneWidget);
      expect(find.textContaining('«Semplificato»'), findsOneWidget);
      await t.scrollUntilVisible(
        find.textContaining('Apple Notes', findRichText: true),
        300,
        scrollable: find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.textContaining('Apple Notes', findRichText: true),
        findsOneWidget,
      );
      await t.runAsync(s.database.close);
    },
  );
}
