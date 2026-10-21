import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/app_tokens.dart';
import 'package:university_notes/features/notes/course_notes_screen.dart';
import 'package:university_notes/features/notes/notes_screen.dart';
import 'package:university_notes/features/notes/recently_deleted_screen.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump();
  }
}

void main() {
  late Directory tmp;
  late AppServices s;
  late Course course;

  Future<void> setUpData(WidgetTester t) async {
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('um_notes_');
      final db = await AppDatabase.openInMemory();
      s = AppServices(
        db,
        library: BookLibrary(baseDir: () async => tmp),
        materialsLibrary: BookLibrary(
          baseDir: () async => tmp,
          folderName: 'materiali',
        ),
      );
      final store = NotesStore(
        s.settings,
        root: () async => Directory(p.join(tmp.path, 'Appunti')),
      );
      s = AppServices(
        db,
        library: s.library,
        materialsLibrary: s.materialsLibrary,
        notes: store,
      );
      final id = await s.courses.insert(
        const Course(
          externalId: 'polito:course:A',
          universityId: 'polito',
          name: 'Analisi matematica I',
          cfu: 10,
        ),
      );
      course = (await s.courses.all()).firstWhere((c) => c.id == id);
      final rec = await store.newRecordingPath(
        course,
        DateTime(2026, 10, 5, 8, 30),
        '.flac',
      );
      await File(rec).writeAsBytes(List.filled(2048, 0));
      await store.writeText(
        course,
        NoteFolder.transcripts,
        '2026-10-05 08-30 Lezione',
        '# Trascrizione\n\nciao',
      );
      await store.writeText(
        course,
        NoteFolder.summaries,
        '2026-10-05 08-30 Lezione',
        '# Riassunto\n\n==chiave==',
      );
    });
  }

  tearDown(() async {
    await s.database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('elenco corsi con conteggio', (t) async {
    await setUpData(t);
    await t.pumpWidget(
      Provider.value(
        value: s,
        child: const MaterialApp(home: NotesScreen()),
      ),
    );
    await _settle(t);
    expect(find.text('Analisi matematica I'), findsOneWidget);
    expect(find.text('3 file'), findsOneWidget);
    expect(find.text('Registra lezione'), findsOneWidget);
  });

  testWidgets('pagina del corso: sezioni, stato trascritta/riassunta, AI', (
    t,
  ) async {
    await setUpData(t);
    t.view.physicalSize = const Size(900, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      Provider.value(
        value: s,
        child: MaterialApp(home: CourseNotesScreen(course: course)),
      ),
    );
    await _settle(t);
    expect(find.text('Registrazioni delle lezioni'), findsOneWidget);
    // La card «Trascrizioni» non c'è più: la trascrizione di Whisper si apre
    // da «Vedi trascrizione» sulla card della registrazione.
    expect(find.text('Trascrizioni'), findsNothing);
    expect(find.textContaining('riassunta'), findsOneWidget);
    expect(find.text('2026-10-05 08-30 Lezione'), findsNWidgets(2));
    expect(find.text("Domande d'esame"), findsOneWidget);
    expect(find.text('Studia con la tua AI di riferimento'), findsOneWidget);
    // card rinominate
    expect(find.text('Riassunti lezioni e Appunti'), findsOneWidget);
    expect(find.text('Note'), findsOneWidget);
    expect(find.text('Nessuna nota.'), findsOneWidget);
    // Whisper fatta → «Vedi trascrizione»; Gemini ancora da fare.
    expect(find.text('Trascrivi con Whisper'), findsNothing);
    expect(find.text('Vedi trascrizione'), findsOneWidget);
    expect(find.textContaining('con modello'), findsNothing);
    expect(find.text('Trascrivi con Gemini'), findsOneWidget);
    // Niente «Incolla …»; il cestino è un'icona sulla card.
    expect(find.textContaining('Incolla'), findsNothing);
    expect(find.byTooltip('Elimina la registrazione'), findsOneWidget);

    // Ctrl+F: cerca nei nomi e nel testo dei file.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(t);
    await t.enterText(find.byType(TextField), 'chiave');
    // la ricerca legge i file: su Windows ci vuole un po'
    await _settle(t);
    await _settle(t);
    expect(find.text('2026-10-05 08-30 Lezione'), findsOneWidget);
    expect(find.textContaining('==chiave=='), findsOneWidget);
    // la ricerca trova anche il testo delle trascrizioni
    await t.enterText(find.byType(TextField), 'ciao');
    await _settle(t);
    await _settle(t);
    expect(find.text('Trascrizioni'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'introvabile');
    await _settle(t);
    await _settle(t);
    expect(find.text('Nessun file contiene questo testo.'), findsOneWidget);
  });

  test('«Svuota» leggibile: colori di errore del tema, contrasto AA', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final style = emptyTrashButtonStyle(theme);
      final bg = style.backgroundColor!.resolve({})!;
      final fg = style.foregroundColor!.resolve({})!;
      expect(bg, theme.colorScheme.errorContainer);
      expect(fg, theme.colorScheme.onErrorContainer);
      expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5));
    }
  });

  test('rinomina: la lezione insieme a trascrizione e riassunto', () async {
    tmp = await Directory.systemTemp.createTemp('um_notes_');
    final db = await AppDatabase.openInMemory();
    final store = NotesStore(
      SettingsRepository(db),
      root: () async => Directory(p.join(tmp.path, 'Appunti')),
    );
    s = AppServices(db, notes: store);
    final c = const Course(id: 1, universityId: 'polito', name: 'Chimica');
    final rec = File(
      await store.newRecordingPath(c, DateTime(2026, 10, 5, 8, 30), '.m4a'),
    )..writeAsStringSync('a');
    final tr = await store.writeText(
      c,
      NoteFolder.transcripts,
      '2026-10-05 08-30 Lezione',
      'x',
    );
    File(p.setExtension(tr.path, '.pdf')).writeAsStringSync('pdf');
    await store.writeText(
      c,
      NoteFolder.transcripts,
      '2026-10-05 08-30 Lezione (Gemini)',
      'g',
    );
    await store.writeText(c, NoteFolder.notes, '2026-10-05 08-30 Lezione', 'y');
    final files = await store.list(c);
    final moves = await store.rename(
      c,
      files[NoteFolder.recordings]!.single,
      'Stechiometria: esercizi',
    );
    expect(moves, hasLength(4));
    final after = await store.list(c);
    expect(
      after[NoteFolder.recordings]!.single.name,
      'Stechiometria_ esercizi',
    );
    expect(
      after[NoteFolder.transcripts]!.map((f) => p.basename(f.file.path)),
      containsAll([
        'Stechiometria_ esercizi.md',
        'Stechiometria_ esercizi.pdf',
        'Stechiometria_ esercizi (Gemini).md',
      ]),
    );
    // Gli appunti personali non fanno parte della lezione.
    expect(after[NoteFolder.notes]!.single.name, '2026-10-05 08-30 Lezione');
    expect(rec.existsSync(), isFalse);
    // Nome già usato: errore, nessun file toccato.
    await store.writeText(c, NoteFolder.summaries, 'Occupato', 'z');
    await expectLater(
      store.rename(c, after[NoteFolder.recordings]!.single, 'Occupato'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      (await store.list(c))[NoteFolder.recordings]!.single.name,
      'Stechiometria_ esercizi',
    );
  });
}
