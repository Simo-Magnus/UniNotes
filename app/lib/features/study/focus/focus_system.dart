import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:intl/intl.dart';

import 'package:url_launcher/url_launcher.dart';

/// Nome del comando (app Comandi/Shortcuts) che su iOS e macOS attiva il
/// Non disturbare fino alla fine della sessione.
const kAppleFocusShortcut = 'UniNotes Focus';

/// Windows: token e attestazione della funzione ad accesso limitato
/// `com.microsoft.windows.focussessionmanager.1`, dati da Microsoft su
/// richiesta (`--dart-define=WINDOWS_FOCUS_LAF_TOKEN=…` e
/// `WINDOWS_FOCUS_LAF_ATTESTATION=…`). Senza, Windows 11 rifiuta l'avvio
/// della sessione di concentrazione (verificato su Windows 11 25H2).
const kWindowsFocusLafToken = String.fromEnvironment('WINDOWS_FOCUS_LAF_TOKEN');
const kWindowsFocusLafAttestation = String.fromEnvironment(
  'WINDOWS_FOCUS_LAF_ATTESTATION',
);

/// «Non disturbare» del sistema durante la sessione Focus: si bloccano le
/// notifiche di tutte le app tranne quelle vitali.
/// - **Android**: Non disturbare del telefono con regole proprie della
///   sessione (passano solo sveglie, chiamate ripetute, chiamate dai
///   contatti preferiti e l'audio dei contenuti), con il permesso «Accesso a
///   Non disturbare» dato dall'utente; il sistema conferma che è attivo
///   (altrimenti la sessione lo dice), alla fine si torna a filtro e regole
///   di prima, anche ad app chiusa (allarme nativo in FocusDnd.kt);
/// - **Windows 11**: sessione di concentrazione del sistema
///   (Windows.UI.Shell.FocusSessionManager, runner/focus_session.cpp), che
///   attiva il «Non disturbare» di Windows. È una funzione ad accesso
///   limitato: senza il token di Microsoft ([kWindowsFocusLafToken])
///   Windows la rifiuta e la sessione spiega come attivarlo a mano;
/// - **iOS e macOS**: nessuna API pubblica permette a un'app di attivare una
///   Full immersion. Se l'utente ha creato il comando [kAppleFocusShortcut]
///   (Impostazioni → Focus e Non disturbare) l'app lo avvia con l'ora di
///   fine (x-callback-url): il comando attiva il Non disturbare fino a
///   quell'ora e Comandi torna su UniNotes con l'esito
///   (`uninotes://focus/ok|errore|annullato`, vedi [appleResults]);
///   altrimenti si spiega come farlo dal Centro di Controllo.
class FocusSystem {
  /// [forcedKind] serve solo ai test (nei test l'app non tocca il sistema).
  const FocusSystem({this.forcedKind});
  final FocusSystemKind? forcedKind;

  static const channel = MethodChannel(
    'io.github.simomagnus.universitynotes/focus',
  );

  static bool get _test => Platform.environment.containsKey('FLUTTER_TEST');

  /// Che cosa sa fare questa piattaforma.
  FocusSystemKind get kind {
    final k = forcedKind;
    if (k != null) return k;
    if (_test) return FocusSystemKind.none;
    if (Platform.isAndroid) return FocusSystemKind.androidDnd;
    if (Platform.isWindows) return FocusSystemKind.windowsFocus;
    if (Platform.isIOS || Platform.isMacOS) return FocusSystemKind.appleFocus;
    return FocusSystemKind.none;
  }

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('Non disturbare del sistema: $method non riuscito ($e)');
      return null;
    }
  }

  // ------------------------------------------------- esito del comando Apple

  static final _appleResults = StreamController<QuietFailure?>.broadcast();
  static bool _listening = false;

  /// iOS/macOS: esito del comando [kAppleFocusShortcut] riportato da
  /// Comandi (null = Non disturbare attivo).
  static Stream<QuietFailure?> get appleResults => _appleResults.stream;

  /// Riceve dal codice nativo `shortcutResult` (ok | errore | annullato).
  static void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'shortcutResult') return null;
      _appleResults.add(appleShortcutOutcome('${call.arguments}'));
      return null;
    });
  }

  // ------------------------------------------------------------ permessi

  /// Android: l'utente ha dato l'accesso a «Non disturbare».
  Future<bool> hasDndAccess() async =>
      kind == FocusSystemKind.androidDnd &&
      (await _call<bool>('dndAccess') ?? false);

  /// Android: apre la pagina del sistema dove dare l'accesso.
  Future<void> openDndAccessSettings() async {
    await _call<void>('openDndSettings');
  }

  /// Android: apre la pagina dell'accesso e aspetta che l'utente torni
  /// nell'app; true se adesso l'accesso c'è. Se la pagina non si apre
  /// (l'app non va in secondo piano) risponde subito.
  Future<bool> requestDndAccess({
    Duration leaveTimeout = const Duration(seconds: 3),
    Duration backTimeout = const Duration(minutes: 10),
  }) async {
    if (kind != FocusSystemKind.androidDnd) return false;
    final left = Completer<void>();
    final back = Completer<void>();
    AppLifecycleListener? l;
    try {
      l = AppLifecycleListener(
        onHide: () {
          if (!left.isCompleted) left.complete();
        },
        onResume: () {
          if (left.isCompleted && !back.isCompleted) back.complete();
        },
      );
    } catch (_) {}
    try {
      await openDndAccessSettings();
      var away = true;
      await left.future.timeout(leaveTimeout, onTimeout: () => away = false);
      if (away) await back.future.timeout(backTimeout, onTimeout: () {});
    } finally {
      l?.dispose();
    }
    return hasDndAccess();
  }

  // ------------------------------------------------------------ sessione

  /// Attiva il silenzio del sistema fino a [until] e dice se è attivo o
  /// perché no. Su iOS/macOS «attivo» vuol dire che il comando è partito:
  /// l'esito vero arriva poi da [appleResults].
  Future<QuietResult> enable(DateTime until) async {
    switch (kind) {
      case FocusSystemKind.androidDnd:
        if (!await hasDndAccess()) {
          return const QuietResult.off(QuietFailure.noAccess);
        }
        final ok =
            await _call<bool>('setDnd', {
              'on': true,
              'untilMs': until.millisecondsSinceEpoch,
            }) ??
            false;
        if (ok) return const QuietResult.on();
        // permesso tolto nel frattempo o sistema che non l'ha applicato
        return QuietResult.off(
          await hasDndAccess() ? QuietFailure.notApplied : QuietFailure.noAccess,
        );
      case FocusSystemKind.windowsFocus:
        final r = await _call<Object>('winFocusStart', {
          'endMs': until.millisecondsSinceEpoch,
          if (kWindowsFocusLafToken.isNotEmpty) ...{
            'lafToken': kWindowsFocusLafToken,
            'lafAttestation': kWindowsFocusLafAttestation,
          },
        });
        return windowsFocusOutcome(r);
      case FocusSystemKind.appleFocus:
        _listen();
        return await _runAppleShortcut(until)
            ? const QuietResult.on()
            : const QuietResult.off(QuietFailure.shortcutFailed);
      case FocusSystemKind.none:
        return const QuietResult.off(QuietFailure.other);
    }
  }

  /// iOS/macOS: avvia il comando [kAppleFocusShortcut] passandogli l'ora di
  /// fine come testo ("2026-10-14 18:30"). true se Comandi si è aperto.
  Future<bool> _runAppleShortcut(DateTime until) async {
    final uri = appleShortcutUri(until);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Comando «$kAppleFocusShortcut» non avviato: $e');
      return false;
    }
  }

  /// Il silenzio attivato dall'app è ancora acceso (l'utente può averlo
  /// spento a mano). null dove il sistema non lo dice (iOS, macOS).
  Future<bool?> isActive() => switch (kind) {
    FocusSystemKind.androidDnd => _call<bool>('dndActive'),
    FocusSystemKind.windowsFocus => _call<bool>('winFocusActive'),
    _ => Future.value(null),
  };

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

/// Perché il silenzio del sistema non è attivo.
enum QuietFailure {
  /// Android: manca l'«Accesso a Non disturbare» (o è stato tolto).
  noAccess,

  /// Android: il sistema non l'ha attivato (es. la modalità «UniNotes» è
  /// disattivata nelle impostazioni del telefono).
  notApplied,

  /// L'utente l'ha spento a mano durante la sessione.
  turnedOff,

  /// Windows: funzione riservata da Windows alle app autorizzate da
  /// Microsoft (accesso limitato).
  windowsDenied,

  /// Windows senza sessioni di concentrazione (Windows 10, 11 non
  /// aggiornato).
  windowsUnsupported,

  /// iOS/macOS: comando non trovato o non riuscito.
  shortcutFailed,

  /// iOS/macOS: comando annullato dall'utente.
  shortcutCancelled,

  /// Altro errore.
  other,
}

/// Esito dell'attivazione del silenzio del sistema.
class QuietResult {
  const QuietResult.on() : failure = null;
  const QuietResult.off(QuietFailure this.failure);

  /// null = attivo.
  final QuietFailure? failure;
  bool get on => failure == null;
}

/// Risposta di `winFocusStart` (runner/focus_session.cpp).
QuietResult windowsFocusOutcome(Object? r) => switch (r) {
  'ok' || true => const QuietResult.on(),
  'negato' => const QuietResult.off(QuietFailure.windowsDenied),
  'non_supportato' => const QuietResult.off(QuietFailure.windowsUnsupported),
  _ => const QuietResult.off(QuietFailure.other),
};

/// Esito del comando Apple da `uninotes://focus/<esito>` (null = attivo).
QuietFailure? appleShortcutOutcome(String result) => switch (result) {
  'ok' => null,
  'annullato' => QuietFailure.shortcutCancelled,
  _ => QuietFailure.shortcutFailed,
};

/// Indirizzo che avvia il comando di iOS/macOS con l'ora di fine (spazi
/// come %20: l'app Comandi non legge il «+»). Con x-callback-url Comandi
/// torna su UniNotes con l'esito (schema `uninotes` nell'Info.plist).
Uri appleShortcutUri(DateTime until) {
  String enc(String v) => Uri.encodeComponent(v);
  final text = DateFormat('yyyy-MM-dd HH:mm').format(until);
  return Uri.parse(
    'shortcuts://x-callback-url/run-shortcut?name=${enc(kAppleFocusShortcut)}'
    '&input=text&text=${enc(text)}'
    '&x-success=${enc('uninotes://focus/ok')}'
    '&x-cancel=${enc('uninotes://focus/annullato')}'
    '&x-error=${enc('uninotes://focus/errore')}',
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

/// Spiegazione in una riga durante la sessione: perché il silenzio del
/// sistema non è partito, o come attivarlo dove l'app non può farlo da sola.
/// [macOS] distingue il Mac dall'iPhone (nei test si sceglie).
String? focusSystemHint(
  FocusSystemKind kind, {
  QuietFailure? failure,
  bool quiet = false,
  bool? macOS,
}) {
  final mac = macOS ?? Platform.isMacOS;
  const winManual =
      'attiva «Non disturbare» dal centro notifiche (Win+N) o dalle '
      'impostazioni.';
  return switch (kind) {
    FocusSystemKind.appleFocus when quiet =>
      'Non disturbare attivato dal comando «$kAppleFocusShortcut» fino alla '
          'fine prevista: se termini prima, spegnilo dal Centro di Controllo.',
    FocusSystemKind.appleFocus
        when failure == QuietFailure.shortcutCancelled =>
      'Comando «$kAppleFocusShortcut» annullato: il Non disturbare non è '
          'attivo.',
    FocusSystemKind.appleFocus when failure != null =>
      'Il comando «$kAppleFocusShortcut» non è riuscito: controlla di averlo '
          'creato con questo nome (Impostazioni → Focus e Non disturbare).',
    FocusSystemKind.appleFocus when mac =>
      'Per silenziare anche le altre app: Centro di Controllo nella barra '
          'dei menu, Full immersion, Non disturbare.',
    FocusSystemKind.appleFocus =>
      'Per silenziare anche le altre app: apri il Centro di Controllo, '
          'tocca Full immersion e scegli Non disturbare o Studio.',
    FocusSystemKind.androidDnd when failure == QuietFailure.noAccess =>
      'Non disturbare non attivato: manca l\'«Accesso a Non disturbare» '
          '(Impostazioni → Focus e Non disturbare).',
    FocusSystemKind.androidDnd when failure == QuietFailure.turnedOff =>
      'Hai spento il Non disturbare: le notifiche delle altre app arrivano '
          'di nuovo.',
    FocusSystemKind.androidDnd when failure != null =>
      'Android non ha attivato il Non disturbare: nelle impostazioni del '
          'telefono (Modalità o Non disturbare) controlla che «UniNotes» non '
          'sia disattivata.',
    FocusSystemKind.windowsFocus when failure == QuietFailure.windowsDenied =>
      'Windows permette di avviare la sessione di concentrazione solo alle '
          'app autorizzate da Microsoft: $winManual',
    FocusSystemKind.windowsFocus
        when failure == QuietFailure.windowsUnsupported =>
      'Questa versione di Windows non ha le sessioni di concentrazione: '
          '$winManual',
    FocusSystemKind.windowsFocus when failure == QuietFailure.turnedOff =>
      'La sessione di concentrazione di Windows è stata chiusa: le notifiche '
          'delle altre app arrivano di nuovo.',
    FocusSystemKind.windowsFocus when failure != null =>
      'Per silenziare Windows $winManual',
    _ => null,
  };
}
