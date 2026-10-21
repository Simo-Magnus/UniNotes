import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/cloud/incoming_files.dart';
import 'package:university_notes/features/cloud/incoming_files_host.dart';
import 'package:university_notes/models/course.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 40]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('file condivisi: si sceglie l\'insegnamento (due pulsanti) e '
      'finiscono in Materiali', (tester) async {
    late AppServices s;
    late Directory tmp;
    late File shared;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('incoming_host_');
      final db = await AppDatabase.openInMemory();
      s = AppServices(
        db,
        materialsLibrary: BookLibrary(
          baseDir: () async => tmp,
          folderName: BookLibrary.materialsFolder,
        ),
      );
      await s.courses.insert(
        const Course(name: 'Fisica I', universityId: 'polito'),
      );
      shared = File(p.join(tmp.path, 'cache_slide.pdf'))
        ..writeAsStringSync('pdf');
    });
    bool? saved;
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await saveIncomingFiles(context, [
                    IncomingFile(shared.path, 'slide.pdf', temporary: true),
                  ]);
                },
                child: const Text('ricevi'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ricevi'));
    await _settle(tester);
    expect(find.text('Dove salvare il file?'), findsOneWidget);
    // al massimo due pulsanti nel dialogo
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
    expect(find.text('Da ordinare'), findsOneWidget);
    await tester.tap(find.text('Da ordinare'));
    await _settle(tester, 10);
    // solo il nome dell'insegnamento, senza sigla dell'ateneo
    expect(find.text('Fisica I').last, findsOneWidget);
    expect(find.textContaining('PoliTo'), findsNothing);
    await tester.tap(find.text('Fisica I').last);
    await _settle(tester, 10);
    await tester.tap(find.text('Salva'));
    await _settle(tester);
    expect(saved, isTrue);
    final out = File(p.join(tmp.path, 'materiali', 'Fisica I', 'slide.pdf'));
    await tester.runAsync(() async {
      expect(await out.readAsString(), 'pdf');
      expect(await shared.exists(), isFalse);
    });
    // nessun servizio collegato: lo dice il messaggio
    expect(
      find.textContaining('Collega Google Drive o OneDrive'),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await s.database.close();
      await tmp.delete(recursive: true);
    });
  });
}
