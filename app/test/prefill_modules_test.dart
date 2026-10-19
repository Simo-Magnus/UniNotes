import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';

const _corso = 'polito-l8-ingegneria-informatica';

void main() {
  test('moduli proposti dal database: creati una sola volta', () async {
    final db = await AppDatabase.openInMemory();
    final settings = SettingsRepository(db);
    final moduli = jsonEncode({
      'schema': 1,
      'universita_id': 'polito',
      'insegnamenti': {
        'polito-l8-ingegneria-informatica-01rkcpl': {
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
      catalog: fakeCatalog(
        settings,
        remote: {
          'corsi/polito.json': jsonEncode(corsiPolitoFixture()),
          'moduli/polito.json': moduli,
        },
      ),
    );
    final analisi = await s.courses.insert(
      const Course(
        name: 'Analisi I',
        externalId: 'polito:course:polito-l8-ingegneria-informatica-01rkcpl',
      ),
    );
    final fisica = await s.courses.insert(
      const Course(name: 'Fisica I', externalId: 'polito:course:fisica-1'),
    );
    final setup = PathSetupService(s);

    expect(
      await setup.prefillModules('polito', corso: _corso, remote: true),
      1,
    );
    final mods = await s.study.modules(analisi);
    expect(mods.map((m) => m.name), ['Limiti', 'Derivate']);
    expect((await s.study.topics(mods.first.id!)).map((t) => t.name), [
      'Successioni',
      'Limiti di funzioni',
    ]);
    expect(await s.study.modules(fisica), isEmpty);

    // cancellati dallo studente: non tornano
    for (final m in mods) {
      await s.study.deleteModule(m.id!);
    }
    expect(await setup.prefillModules('polito', corso: _corso), 0);
    expect(await s.study.modules(analisi), isEmpty);

    // insegnamento con moduli propri: non si tocca
    await s.study.insertModule(
      StudyModule(courseId: fisica, name: 'Mio modulo'),
    );
    expect(await setup.prefillModules('polito', corso: _corso), 0);
    await db.close();
  });
}
