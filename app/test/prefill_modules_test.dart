import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';

void main() {
  test('moduli proposti dal database: creati una sola volta', () async {
    final db = await AppDatabase.openInMemory();
    final settings = SettingsRepository(db);
    final moduli = jsonEncode({
      'schema': 1,
      'universita_id': 'polito',
      'insegnamenti': {
        'analisi-1': {
          'fonte': 'Indice del libro di riferimento',
          'moduli': [
            {
              'nome': 'Limiti',
              'argomenti': ['Successioni', 'Limiti di funzioni'],
            },
            {'nome': 'Derivate'},
          ],
        },
      },
    });
    final s = AppServices(
      db,
      catalog: fakeCatalog(settings, remote: {'moduli/polito.json': moduli}),
    );
    final analisi = await s.courses.insert(
      const Course(name: 'Analisi I', externalId: 'polito:course:analisi-1'),
    );
    final fisica = await s.courses.insert(
      const Course(name: 'Fisica I', externalId: 'polito:course:fisica-1'),
    );
    final setup = PathSetupService(s);

    expect(await setup.prefillModules('polito', remote: true), 1);
    final mods = await s.study.modules(analisi);
    expect(mods.map((m) => m.name), ['Limiti', 'Derivate']);
    expect(
      (await s.study.topics(mods.first.id!)).map((t) => t.name),
      ['Successioni', 'Limiti di funzioni'],
    );
    expect(await s.study.modules(fisica), isEmpty);

    // cancellati dallo studente: non tornano
    for (final m in mods) {
      await s.study.deleteModule(m.id!);
    }
    expect(await setup.prefillModules('polito'), 0);
    expect(await s.study.modules(analisi), isEmpty);

    // insegnamento con moduli propri: non si tocca
    await s.study.insertModule(
      StudyModule(courseId: fisica, name: 'Mio modulo'),
    );
    expect(await setup.prefillModules('polito'), 0);
    await db.close();
  });
}
