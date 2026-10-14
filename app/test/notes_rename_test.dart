import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

void main() {
  test('rinomina del corso: registrazioni e appunti seguono il nome', () async {
    final tmp = await Directory.systemTemp.createTemp('un_rename_');
    final db = await AppDatabase.openInMemory();
    addTearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });
    final store = NotesStore(SettingsRepository(db), root: () async => tmp);
    const it = Course(name: 'Analisi matematica I', universityId: 'polito');
    const en = Course(name: 'Mathematical analysis I', universityId: 'polito');
    final rec = await store.courseDir(it, NoteFolder.recordings);
    File(p.join(rec.path, 'lezione.m4a')).writeAsStringSync('audio');
    await store.renameCourse(it, en);
    final moved = File(
      p.join(
        tmp.path,
        NotesStore.folderName(en),
        NoteFolder.recordings.dirName,
        'lezione.m4a',
      ),
    );
    expect(moved.existsSync(), isTrue);
    expect(
      Directory(p.join(tmp.path, NotesStore.folderName(it))).existsSync(),
      isFalse,
    );
  });
}
