import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../repositories/settings_repository.dart';

/// Stato di batteria e rete per le scelte di risparmio energetico (sync
/// automatica, trascrizione solo in carica, registrazioni solo con Wi‑Fi).
///
/// Senza batteria (PC fisso) o se il sistema non risponde si comporta come
/// «in carica» e «batteria ok»: le funzioni non si bloccano mai per un errore.
class Power {
  Power._();

  static final _battery = Battery();

  /// Sostituibili nei test.
  static Future<bool> Function()? debugCharging;
  static Future<bool> Function()? debugOnWifi;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// In carica, carica completa o senza batteria.
  static Future<bool> charging() async {
    if (debugCharging != null) return debugCharging!();
    try {
      final s = await _battery.batteryState;
      return s != BatteryState.discharging;
    } catch (_) {
      return true;
    }
  }

  static Future<int?> Function()? debugBatteryLevel;

  /// Carica della batteria in percentuale (null = senza batteria o non si
  /// sa).
  static Future<int?> batteryLevel() async {
    if (debugBatteryLevel != null) return debugBatteryLevel!();
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  /// Connessi con Wi‑Fi o cavo (non con i dati mobili).
  static Future<bool> onWifi() async {
    if (debugOnWifi != null) return debugOnWifi!();
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) ||
          r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  /// Attende che il dispositivo sia in carica (o che [cancelled] diventi
  /// vero). Controlla al cambio di stato della batteria e ogni 30 secondi.
  static Future<void> waitForCharging({bool Function()? cancelled}) async {
    while (!await charging()) {
      if (cancelled?.call() ?? false) return;
      final done = Completer<void>();
      StreamSubscription<BatteryState>? sub;
      try {
        sub = _battery.onBatteryStateChanged.listen((s) {
          if (s != BatteryState.discharging && !done.isCompleted) {
            done.complete();
          }
        }, onError: (_) {});
      } catch (_) {}
      await Future.any([
        done.future,
        Future<void>.delayed(const Duration(seconds: 30)),
      ]);
      await sub?.cancel();
    }
  }

  // --------------------------------------------------------- preferenze

  static const whisperOnlyChargingKey = 'whisper_only_charging';

  /// «Trascrivi solo in carica» (predefinito: no).
  static Future<bool> whisperOnlyCharging(SettingsRepository s) async =>
      (await s.get(whisperOnlyChargingKey)) == '1';
  static Future<void> setWhisperOnlyCharging(SettingsRepository s, bool v) =>
      s.set(whisperOnlyChargingKey, v ? '1' : '0');
}
