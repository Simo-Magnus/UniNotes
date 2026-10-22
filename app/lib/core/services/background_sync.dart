import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import '../../features/cloud/cloud_drive_service.dart';
import '../database/app_database.dart';
import 'app_services.dart';
import 'portable_path.dart';

/// Sincronizzazione con OneDrive e Google Drive con l'app in background.
///
/// - PC e Mac: l'app resta aperta (anche con la finestra nascosta
///   nell'area di notifica) e i controlli automatici di
///   [CloudDriveService.startAutoSync] continuano da soli.
/// - Android: lavoro periodico del JobScheduler (android/.../
///   BackgroundSync.kt), al massimo ogni 15 minuti e solo con la rete, anche
///   ad app chiusa; con l'app aperta in secondo piano chiede `run` al motore
///   dell'app, altrimenti avvia [runBackgroundSync] senza interfaccia.
/// - iPhone e iPad: aggiornamento in background di iOS (BGAppRefreshTask
///   `io.github.simomagnus.universitynotes.sync`, AppDelegate.swift): il
///   sistema decide quando, di solito alcune volte al giorno se l'app si
///   usa spesso; ogni volta chiede `run`.
abstract final class BackgroundSync {
  static const channel = MethodChannel(
    'io.github.simomagnus.universitynotes/sincronizzazione',
  );

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// Nell'app: risponde a `run` e tiene pianificato il lavoro periodico
  /// (tolto se nessun servizio è collegato).
  static void attach(AppServices s) {
    if (!supported) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'run') return runOnce(s);
      return null;
    });
    CloudDriveService.onScheduleChanged = () => unawaited(schedule(s));
    unawaited(schedule(s));
  }

  /// Ogni quanti minuti: il più breve tra i servizi collegati (null =
  /// nessuno collegato).
  static Future<int?> intervalFor(Iterable<CloudDriveService> clouds) async {
    int? best;
    for (final c in clouds) {
      if (!await c.connected()) continue;
      final m = await c.intervalMinutes();
      if (best == null || m < best) best = m;
    }
    return best;
  }

  static Future<void> schedule(AppServices s) async {
    if (!supported) return;
    try {
      final m = await intervalFor(s.clouds);
      if (m == null) {
        await channel.invokeMethod<void>('cancel');
      } else {
        await channel.invokeMethod<bool>('schedule', {'minutes': m});
      }
    } catch (e) {
      debugPrint('Sincronizzazione in background non pianificata: $e');
    }
  }

  /// Una sincronizzazione di tutti i servizi collegati (solo le novità),
  /// poi calendario e notifiche. true se è andata a buon fine.
  static Future<bool> runOnce(AppServices s, {bool reminders = false}) async {
    var ok = true;
    for (final c in s.clouds) {
      try {
        if (!await c.connected()) continue;
        final r = await c.sync(force: false, auto: true);
        if (r == null && c.lastError != null) ok = false;
      } catch (_) {
        ok = false;
      }
    }
    if (reminders || s.remindersStarted) {
      try {
        await s.reminders.refresh();
      } catch (_) {}
    }
    return ok;
  }
}

/// Motore senza interfaccia avviato dal lavoro periodico di Android ad app
/// chiusa (vedi `backgroundSyncMain` in lib/main.dart): apre il database,
/// sincronizza, aggiorna calendario e notifiche e lo dice al sistema
/// (`done`).
Future<void> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  AppDatabase? db;
  try {
    db = await AppDatabase.open();
    await initPortableBase();
    final s = AppServices(db);
    await s.loadProfile();
    await BackgroundSync.runOnce(s, reminders: true);
  } catch (e) {
    debugPrint('Sincronizzazione in background non riuscita: $e');
  } finally {
    try {
      await db?.close();
    } catch (_) {}
    try {
      await BackgroundSync.channel.invokeMethod<void>('done');
    } catch (_) {}
  }
}
