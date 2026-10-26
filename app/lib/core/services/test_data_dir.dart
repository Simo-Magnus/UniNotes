import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages (arriva con path_provider)
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/settings/app_info.dart';
import '../reminders/windows_aumid.dart';
import 'install_check.dart';

/// Cartella dei dati delle build di prova: solo con
/// `--dart-define=UNINOTES_CARTELLA_PROVA=<cartella>` (vuota in tutte le
/// build normali, che non cambiano in nulla). Serve per misurare la finestra
/// sul PC (schermo nero al ripristino, tempi di chiusura: vedi
/// docs/registratore.md) con una copia dell'app che non legge e non scrive
/// i dati veri dell'utente.
const String kTestDataDir = String.fromEnvironment('UNINOTES_CARTELLA_PROVA');

/// Build di prova con la cartella dei dati separata.
bool get testDataMode => kTestDataDir.isNotEmpty;

/// Da chiamare per prima cosa in main(): con [kTestDataDir] le cartelle
/// dell'app (dati, Documenti, temporanei, download) sono dentro quella
/// cartella e le preferenze restano in memoria, già segnate come «app
/// avviata prima» (niente pulizia delle credenziali del primo avvio né
/// passaggio dell'AUMID dei toast, che toccherebbero il portachiavi e il
/// registro dell'utente).
void installTestDataDir() {
  if (!testDataMode) return;
  final paths = TestPathProvider(kTestDataDir);
  for (final name in TestPathProvider.names) {
    Directory(paths._dir(name)).createSync(recursive: true);
  }
  PathProviderPlatform.instance = paths;
  // ignore: invalid_use_of_visible_for_testing_member (solo build di prova)
  SharedPreferences.setMockInitialValues({
    InstallCheck.versionKey: kAppVersion,
    WindowsAumidMigration.doneKey: true,
  });
  debugPrint('Build di prova: dati in $kTestDataDir');
}

/// Cartelle dell'app dentro [base].
class TestPathProvider extends PathProviderPlatform {
  TestPathProvider(this.base);
  final String base;

  static const names = ['temp', 'supporto', 'documenti', 'cache', 'download'];

  String _dir(String name) => p.join(base, 'dati', name);

  @override
  Future<String?> getTemporaryPath() async => _dir('temp');

  @override
  Future<String?> getApplicationSupportPath() async => _dir('supporto');

  @override
  Future<String?> getApplicationDocumentsPath() async => _dir('documenti');

  @override
  Future<String?> getApplicationCachePath() async => _dir('cache');

  @override
  Future<String?> getDownloadsPath() async => _dir('download');
}
