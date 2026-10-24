import 'package:flutter/widgets.dart';

/// Scorrimento con la tastiera (Pagina giù/su, frecce, Spazio) senza errori.
///
/// Con il fuoco fuori da una lista, [ScrollAction] di Flutter scorre la
/// lista del [PrimaryScrollController] della pagina; sul telefono e sul
/// tablet (Android, iOS) ogni lista verticale vi si aggancia da sola e in
/// molte schermate ce n'è più d'una (lista principale e liste interne):
/// Flutter allora lanciava «more than one ScrollPosition is attached» a ogni
/// tasto (in release «Too many elements»), con una tastiera collegata. Qui
/// il tasto vale solo se la lista da scorrere è una sola; altrimenti non fa
/// niente e passa oltre.
class SafeScrollAction extends ScrollAction {
  @override
  bool isEnabled(ScrollIntent intent, [BuildContext? context]) {
    if (context == null) return false;
    if (Scrollable.maybeOf(context) != null) return true;
    final c = PrimaryScrollController.maybeOf(context);
    return c != null && c.positions.length == 1;
  }
}

/// [SafeScrollAction] per tutte le pagine sotto [child] (nel `builder` di
/// MaterialApp, sopra il Navigator).
class SafeScrollActions extends StatelessWidget {
  const SafeScrollActions({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{ScrollIntent: SafeScrollAction()},
    child: child,
  );
}
