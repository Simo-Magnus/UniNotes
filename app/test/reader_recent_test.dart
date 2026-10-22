// «File» → «Recenti»: ricordati gli ultimi 50 file aperti, mostrati i primi
// 20 con «Mostra altri».
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
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

Future<void> _settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  test('memoria dei recenti: al massimo 50, il più recente in cima', () async {
    final db = await AppDatabase.openInMemory();
    final store = ReaderStore(SettingsRepository(db));
    for (var i = 0; i < 60; i++) {
      await store.addRecent(
        '/f/file$i.pdf',
        now: DateTime(2026, 1, 1).add(Duration(minutes: i)),
      );
    }
    final recent = await store.recent();
    expect(ReaderStore.maxRecent, 50);
    expect(ReaderStore.shownRecent, 20);
    expect(recent, hasLength(50));
    expect(recent.first.name, 'file59.pdf');
    expect(recent.last.name, 'file10.pdf');
    await db.close();
  });

  testWidgets('File: 20 recenti, poi «Mostra altri»', (t) async {
    t.view.physicalSize = const Size(1000, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late Directory tmp;
    late AppServices s;
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('um_recent_');
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
      final store = ReaderStore(s.settings);
      for (var i = 0; i < 26; i++) {
        final f = File(p.join(tmp.path, 'materiali', 'dispensa$i.txt'));
        await f.parent.create(recursive: true);
        await f.writeAsString('testo $i');
        await store.addRecent(
          f.path,
          now: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
    });
    addTearDown(() => tmp.deleteSync(recursive: true));
    await t.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(theme: AppTheme.dark(), home: const FilesScreen()),
      ),
    );
    await _settle(t, 40);
    expect(find.text('dispensa25.txt'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('recent-more')));
    await t.pump();
    expect(find.text('Mostra altri (6)'), findsOneWidget);
    expect(find.text('dispensa6.txt'), findsOneWidget);
    expect(find.text('dispensa5.txt'), findsNothing);
    await t.tap(find.byKey(const Key('recent-more')));
    await _settle(t, 4);
    await t.ensureVisible(find.text('dispensa0.txt'));
    await t.pump();
    expect(find.text('dispensa0.txt'), findsOneWidget);
    expect(find.text('Mostra meno'), findsOneWidget);

    // «Togli dai recenti» con «Annulla» nell'avviso in basso
    final tile = find.widgetWithText(ListTile, 'dispensa0.txt');
    await t.tap(
      find.descendant(of: tile, matching: find.byTooltip('Togli dai recenti')),
    );
    await _settle(t, 30);
    expect(find.text('dispensa0.txt'), findsNothing);
    expect(find.text('«dispensa0.txt» tolto dai recenti.'), findsOneWidget);
    await t.tap(find.widgetWithText(SnackBarAction, 'Annulla'));
    await _settle(t, 20);
    final back = (await t.runAsync(() => ReaderStore(s.settings).recent()))!;
    expect(back, hasLength(26));
    expect(back.last.name, 'dispensa0.txt');
    await t.runAsync(s.database.close);
  });
}
