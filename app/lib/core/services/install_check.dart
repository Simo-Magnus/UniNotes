import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/app_database.dart';
import 'app_uninstall.dart';
import 'local_data.dart';

/// Esito del controllo all'avvio.
class InstallStatus {
  const InstallStatus({
    this.fresh = false,
    this.leftover = false,
    this.sharedNotes = const [],
  });

  /// Primo avvio dopo una nuova installazione (o dopo un'eliminazione
  /// completa dei dati).
  final bool fresh;

  /// App reinstallata con i dati della precedente ancora nelle sue
  /// cartelle (macOS dopo il trascinamento nel Cestino, Windows se alla
  /// disinstallazione i dati si sono tenuti): da usare o eliminare.
  final bool leftover;

  /// Cartelle condivise con gli appunti di un'installazione precedente (sul
  /// PC in Documenti): da usare o ignorare.
  final List<Directory> sharedNotes;

  bool get needsAnswer => leftover || sharedNotes.isNotEmpty;
}

/// Confronto di versioni «2026.9.0» (anche con «+build»): <0, 0, >0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final x in v.split('+').first.split(RegExp(r'[.\-]')))
      int.tryParse(x) ?? 0,
  ];
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Primo avvio dopo una (re)installazione, uguale su tutte le piattaforme
/// con le parti specifiche in [AppUninstall.installIdentity] e
/// [LocalData.sharedNotesDirs].
///
/// Nelle preferenze (shared_preferences: UserDefaults su iOS e macOS,
/// `shared_prefs` su Android, file nella cartella dell'app su Windows) si
/// salvano la versione più recente avviata e l'identità dell'installazione.
/// - Niente versione salvata e niente database: nuova installazione. Si
///   svuotano le credenziali dell'app rimaste nel portachiavi (iOS e macOS
///   lo conservano dopo la disinstallazione) e, se in Documenti ci sono
///   appunti di un'installazione precedente (PC), si chiede se usarli o
///   ignorarli invece di rileggerli da soli.
/// - Niente versione salvata ma database presente: aggiornamento da una
///   versione che non la salvava. Nessuna domanda.
/// - Identità cambiata con una versione uguale o più vecchia di quella
///   salvata: l'app è stata reinstallata e i dati della precedente sono
///   rimasti (macOS dopo il trascinamento nel Cestino): si chiede se usarli
///   o eliminarli. Un aggiornamento a una versione più nuova non chiede mai
///   nulla.
class InstallCheck {
  InstallCheck({
    required this.version,
    required this.databaseExists,
    required this.wipeSecrets,
    required this.sharedNotes,
    required this.identity,
  });

  /// Controllo con le cartelle, il portachiavi e la versione veri.
  factory InstallCheck.standard(String version) => InstallCheck(
    version: version,
    databaseExists: () async => File(await AppDatabase.defaultPath()).exists(),
    wipeSecrets: LocalData.wipeSecrets,
    sharedNotes: () async =>
        LocalData.withFiles(await LocalData.sharedNotesDirs()),
    identity: AppUninstall.installIdentity,
  );

  final String version;
  final Future<bool> Function() databaseExists;
  final Future<void> Function() wipeSecrets;
  final Future<List<Directory>> Function() sharedNotes;
  final Future<String?> Function() identity;

  static const versionKey = 'uninotes.versione';
  static const identityKey = 'uninotes.installazione';
  static const pendingLeftoverKey = 'uninotes.dati_precedenti';
  static const pendingSharedKey = 'uninotes.appunti_precedenti';

  /// Da chiamare all'avvio, prima di aprire il database.
  Future<InstallStatus> run() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedVersion = prefs.getString(versionKey);
      final savedId = prefs.getString(identityKey);
      final id = await identity();
      var fresh = false;
      if (savedVersion == null) {
        fresh = !await databaseExists();
        if (fresh) {
          try {
            await wipeSecrets();
          } catch (e) {
            debugPrint('Credenziali precedenti non eliminate: $e');
          }
          if ((await sharedNotes()).isNotEmpty) {
            await prefs.setBool(pendingSharedKey, true);
          }
        }
      } else if (id != null &&
          savedId != null &&
          id != savedId &&
          compareVersions(version, savedVersion) <= 0 &&
          await databaseExists()) {
        await prefs.setBool(pendingLeftoverKey, true);
      }
      if (savedVersion == null || compareVersions(version, savedVersion) > 0) {
        await prefs.setString(versionKey, version);
      }
      if (id != null) await prefs.setString(identityKey, id);

      var shared = const <Directory>[];
      if (prefs.getBool(pendingSharedKey) == true) {
        shared = await sharedNotes();
        if (shared.isEmpty) await prefs.remove(pendingSharedKey);
      }
      return InstallStatus(
        fresh: fresh,
        leftover: prefs.getBool(pendingLeftoverKey) == true,
        sharedNotes: shared,
      );
    } catch (e) {
      debugPrint('Controllo dell\'installazione non riuscito: $e');
      return const InstallStatus();
    }
  }

  /// Risposta data alla domanda [key] ([pendingLeftoverKey] o
  /// [pendingSharedKey]): non si chiede più.
  static Future<void> answered(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}
