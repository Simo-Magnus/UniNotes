import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// «Indietro» (tasto del telefono, Esc della finestra, gesto) che arriva
/// mentre la pagina in cima è stata appena aperta e non è ancora disegnata:
/// una pagina aperta dopo un fotogramma (es. il registratore aperto da un
/// widget o da una notifica) resta così fino al fotogramma successivo.
/// `Navigator.maybePop` chiede allora alla pagina se si può chiudere prima
/// che esista il suo contenuto: in debug l'asserzione `scope != null` di
/// `ModalRoute.willPop` ferma l'app; nella build pubblicata la pagina si
/// chiude senza sentire i suoi `PopScope` (domande come «Salvare?»).
///
/// Questo osservatore (installato prima di `runApp`, come `AppLinkGuard`,
/// così risponde prima del Navigator) rimanda l'«Indietro» al fotogramma
/// successivo, quando la pagina è costruita. Dopo [maxDeferrals] rinvii di
/// fila (pagina che non si costruisce) lascia passare l'«Indietro».
class BackGuard with WidgetsBindingObserver {
  BackGuard(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  /// Rinvii di fila al massimo.
  static const maxDeferrals = 3;

  int _deferrals = 0;

  /// Vero se la pagina in cima al Navigator è aperta ma non ancora
  /// costruita.
  @visibleForTesting
  static bool topRouteUnbuilt(NavigatorState nav) {
    Route<dynamic>? top;
    // con un predicato vero alla prima pagina popUntil non chiude nulla:
    // è il modo pubblico di leggere la pagina in cima
    nav.popUntil((r) {
      top = r;
      return true;
    });
    final t = top;
    return t is ModalRoute && t.subtreeContext == null;
  }

  @override
  Future<bool> didPopRoute() async {
    final nav = navigatorKey.currentState;
    if (nav == null || !nav.mounted) return false;
    if (!topRouteUnbuilt(nav) || _deferrals >= maxDeferrals) {
      _deferrals = 0;
      return false;
    }
    _deferrals++;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => _redispatch());
    binding.scheduleFrame();
    return true;
  }

  /// Come `WidgetsBinding.handlePopRoute` dopo il fotogramma: di nuovo da
  /// questo osservatore, poi il Navigator (quello che fa `WidgetsApp`) e, se
  /// non c'è nulla da chiudere, l'uscita come per l'«Indietro» del sistema.
  Future<void> _redispatch() async {
    try {
      if (await didPopRoute()) return;
      final nav = navigatorKey.currentState;
      if (nav != null && nav.mounted && await nav.maybePop()) return;
      await SystemNavigator.pop();
    } catch (e, st) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: st, library: 'back_guard'),
      );
    }
  }
}

BackGuard? _guard;

/// Aggiunge il [BackGuard] per il Navigator di [navigatorKey] (uno solo
/// anche se chiamata di nuovo).
void installBackGuard(GlobalKey<NavigatorState> navigatorKey) {
  final binding = WidgetsBinding.instance;
  if (_guard case final g?) binding.removeObserver(g);
  binding.addObserver(_guard = BackGuard(navigatorKey));
}

/// Toglie il [BackGuard] (prove).
@visibleForTesting
void removeBackGuard() {
  if (_guard case final g?) WidgetsBinding.instance.removeObserver(g);
  _guard = null;
}
