import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:url_launcher/url_launcher.dart';

/// Nome del comando (app Comandi/Shortcuts) che su iOS e macOS attiva il
/// Non disturbare fino alla fine della sessione.
const kAppleFocusShortcut = 'UniNotes Focus';

/// «Non disturbare» del sistema durante la sessione Focus: si bloccano le
/// notifiche di tutte le app tranne quelle vitali.
/// - **Android**: Non disturbare del telefono con regole proprie della
///   sessione (passano solo sveglie, chiamate ripetute, chiamate dai
///   contatti preferiti e l'audio dei contenuti), con il permesso «Accesso a
///   Non disturbare» dato dall'utente; alla fine si torna a filtro e regole
///   di prima, anche ad app chiusa (allarme nativo in FocusDnd.kt);
/// - **Windows 11**: sessione di concentrazione del sistema
///   (Windows.UI.Shell.FocusSessionManager, runner/focus_session.cpp), che
///   attiva il «Non disturbare» di Windows; se il sistema la rifiuta si
///   spiega come attivarlo a mano;
/// - **iOS e macOS**: nessuna API pubblica permette a un'app di attivare una
///   Full immersion. Se l'utente ha creato il comando [kAppleFocusShortcut]
///   (Impostazioni → Focus e Non disturbare) l'app lo avvia con l'ora di
///   fine e il comando attiva il Non disturbare fino a quell'ora;
///   altrimenti si spiega come farlo dal Centro di Controllo.
class FocusSystem {
  const FocusSystem();

  static const _channel = MethodChannel(
    'io.github.simomagnus.universitynotes/focus',
  );

  static bool get _test => Platform.environment.containsKey('FLUTTER_TEST');

  /// Che cosa sa fare questa piattaforma.
  FocusSystemKind get kind {
    if (_test) return FocusSystemKind.none;
    if (Platform.isAndroid) return FocusSystemKind.androidDnd;
    if (Platform.isWindows) return FocusSystemKind.windowsFocus;
    if (Platform.isIOS || Platform.isMacOS) return FocusSystemKind.appleFocus;
    return FocusSystemKind.none;
  }

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('Non disturbare del sistema: $method non riuscito ($e)');
      return null;
    }
  }

  /// Android: l'utente ha dato l'accesso a «Non disturbare».
  Future<bool> hasDndAccess() async =>
      kind == FocusSystemKind.androidDnd &&
      (await _call<bool>('dndAccess') ?? false);

  /// Android: apre la pagina del sistema dove dare l'accesso.
  Future<void> openDndAccessSettings() async {
    await _call<void>('openDndSettings');
  }

  /// Attiva il silenzio del sistema fino a [until]. true se è attivo.
  Future<bool> enable(DateTime until) async => switch (kind) {
    FocusSystemKind.androidDnd =>
      await _call<bool>('setDnd', {
            'on': true,
            'untilMs': until.millisecondsSinceEpoch,
          }) ??
          false,
    FocusSystemKind.windowsFocus =>
      await _call<bool>('winFocusStart', {
            'endMs': until.millisecondsSinceEpoch,
          }) ??
          false,
    FocusSystemKind.appleFocus => await _runAppleShortcut(until),
    _ => false,
  };

  /// iOS/macOS: avvia il comando [kAppleFocusShortcut] passandogli l'ora di
  /// fine come testo ("2026-10-14 18:30"). true se il comando è partito.
  Future<bool> _runAppleShortcut(DateTime until) async {
    final uri = appleShortcutUri(until);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Comando «$kAppleFocusShortcut» non avviato: $e');
      return false;
    }
  }

  /// Torna all'impostazione di prima.
  Future<void> disable() async {
    switch (kind) {
      case FocusSystemKind.androidDnd:
        await _call<bool>('setDnd', {'on': false});
      case FocusSystemKind.windowsFocus:
        await _call<void>('winFocusEnd');
      default:
        break;
    }
  }

  /// Windows: impostazioni delle notifiche (per «Non disturbare»).
  Future<void> openWindowsNotificationSettings() async {
    // indirizzo fisso del sistema (non un link arrivato da fuori)
    try {
      await launchUrl(Uri.parse('ms-settings:notifications'));
    } catch (e) {
      debugPrint('Impostazioni di Windows non aperte: $e');
    }
  }
}

/// Indirizzo che avvia il comando di iOS/macOS con l'ora di fine (spazi
/// come %20: l'app Comandi non legge il «+»).
Uri appleShortcutUri(DateTime until) {
  String enc(String v) => Uri.encodeComponent(v);
  final text = DateFormat('yyyy-MM-dd HH:mm').format(until);
  return Uri.parse(
    'shortcuts://run-shortcut?name=${enc(kAppleFocusShortcut)}'
    '&input=text&text=${enc(text)}',
  );
}

enum FocusSystemKind { androidDnd, windowsFocus, appleFocus, none }

/// Silenzio del sistema durante le sessioni Focus (Impostazioni → Focus e
/// Non disturbare): sempre o mai. `ask` è il valore non ancora scelto (e
/// quello delle versioni precedenti, che chiedevano a ogni sessione): vale
/// «sempre» su Android e Windows, «mai» su iOS e macOS, dove serve prima
/// creare il comando.
enum DndChoice {
  ask('chiedi'),
  always('sempre'),
  never('mai');

  const DndChoice(this.key);
  final String key;

  static DndChoice fromKey(String? k) => switch (k) {
    'sempre' => DndChoice.always,
    'mai' => DndChoice.never,
    _ => DndChoice.ask,
  };
}

/// Il silenzio del sistema è attivo con questa scelta su questo sistema.
bool systemQuietOn(FocusSystemKind kind, DndChoice choice) => switch (kind) {
  FocusSystemKind.none => false,
  FocusSystemKind.appleFocus => choice == DndChoice.always,
  _ => choice != DndChoice.never,
};

/// Spiegazione in una riga per i sistemi dove l'app non può attivare il
/// silenzio da sola.
String? focusSystemHint(
  FocusSystemKind kind, {
  bool windowsFailed = false,
  bool quiet = false,
}) => switch (kind) {
      FocusSystemKind.appleFocus when quiet =>
        'Il comando «$kAppleFocusShortcut» ha attivato il Non disturbare fino '
            'alla fine prevista: se termini prima, spegnilo dal Centro di '
            'Controllo.',
      FocusSystemKind.appleFocus when Platform.isMacOS =>
        'Per silenziare anche le altre app: Centro di Controllo nella barra '
            'dei menu, Full immersion, Non disturbare.',
      FocusSystemKind.appleFocus =>
        'Per silenziare anche le altre app: apri il Centro di Controllo, '
            'tocca Full immersion e scegli Non disturbare o Studio.',
      FocusSystemKind.windowsFocus when windowsFailed =>
        'Per silenziare Windows attiva «Non disturbare» dal centro '
            'notifiche (Win+N) o dalle impostazioni.',
      _ => null,
    };
