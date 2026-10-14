import 'dart:convert';

import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'catalog_fixtures.dart';

/// Servizi con il piano di Ingegneria Informatica (PoliTO, fixture)
/// importato e lo studente al 2° anno nel 2026/27.
Future<AppServices> planServices() async {
  final db = await AppDatabase.openInMemory();
  final s = AppServices(
    db,
    catalog: fakeCatalog(
      SettingsRepository(db),
      remote: {'corsi/polito.json': jsonEncode(corsiPolitoFixture())},
    ),
  );
  await PathSetupService(s).apply(
    PathSelection(
      ateneo: UniversitaCatalog.fromJson(kUniversitaFixture).byId('polito')!,
      tipo: TipoCorso.l,
      corso: IndiceCorsi.fromJson(kIndiceFixture).corsi.first,
      year: 2,
    ),
    now: DateTime(2026, 10, 4),
  );
  await s.loadProfile();
  return s;
}
