import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Identità dell'app nei toast di Windows (AppUserModelID, «AUMID»).
///
/// Versione del sito (installatore Inno Setup, non pacchettizzata): l'AUMID
/// è [current], lo stesso del collegamento nel menu Start
/// (`windows/installer/uninotes.iss`, AppUserModelID) e del processo
/// (`windows/runner/notification_identity.cpp`,
/// SetCurrentProcessExplicitAppUserModelID): finestra, collegamento e toast
/// sono la stessa app per la barra delle applicazioni.
///
/// Fino alla versione di ottobre 2026 era [legacy]: Windows aveva memorizzato
/// nome e icona di quell'AUMID al primo toast, quando la chiave del registro
/// non aveva ancora l'IconUri, e non mostrava più il logo neanche con
/// l'IconUri corretto. Con l'AUMID nuovo l'IconUri c'è prima del primo toast
/// (lo scrive il pacchetto delle notifiche all'inizializzazione).
///
/// Microsoft Store (MSIX): l'AUMID lo decide il pacchetto e il valore dato
/// al pacchetto delle notifiche si ignora per i toast; si passa [legacy]
/// come prima, così lì non cambia nulla.
abstract final class WindowsAumid {
  static const current = 'SimoMagnus.UniNotes';
  static const legacy = 'io.github.simomagnus.universitynotes';

  /// AUMID da dare al pacchetto delle notifiche: [packaged] = processo con
  /// identità di pacchetto (MSIX).
  static String of({required bool packaged}) => packaged ? legacy : current;
}

/// Passaggio una volta sola all'AUMID nuovo (solo Windows non
/// pacchettizzato): il codice nativo (canale [channelName], metodo
/// `migraAumid {vecchio}`) toglie i toast pianificati e la cronologia
/// dell'AUMID vecchio, così i promemoria non arrivano doppi, ed elimina le
/// sue chiavi del registro. Poi il servizio dei promemoria ripianifica tutto
/// con l'AUMID nuovo (a ogni avvio, `RemindersService.start` → `refresh`).
/// Fatto, si segna nelle impostazioni ([doneKey]) e non si ripete; un errore
/// non blocca l'avvio (si riprova al prossimo).
class WindowsAumidMigration {
  WindowsAumidMigration({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.simomagnus.universitynotes/notifiche';
  static const doneKey = 'uninotes_aumid_windows_migrato';

  final MethodChannel _channel;

  /// true se il passaggio è stato fatto ora.
  Future<bool> run({required bool packaged}) async {
    if (packaged) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(doneKey) ?? false) return false;
      await _channel
          .invokeMethod<Object?>('migraAumid', {'vecchio': WindowsAumid.legacy})
          .timeout(const Duration(seconds: 10));
      await prefs.setBool(doneKey, true);
      return true;
    } catch (e) {
      debugPrint('Notifiche: AUMID vecchio non tolto: $e');
      return false;
    }
  }
}
