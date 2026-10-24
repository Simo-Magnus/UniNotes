import 'package:flutter/widgets.dart';

/// Chiude, alla fine di un'attesa (salvataggio, eliminazione, lettura), la
/// pagina o il riquadro a cui appartiene [context], e solo quella:
/// - se è in cima, come `Navigator.pop`;
/// - se nel frattempo se n'è aperta un'altra sopra (tocco su una notifica o
///   su un widget della Home), toglie questa e lascia l'altra in vista;
/// - se si sta già chiudendo (Indietro, gesto «indietro», Esc durante
///   l'attesa) o è già chiusa, non fa nulla.
///
/// Con un semplice `if (mounted) Navigator.pop(context)` la pagina che si
/// sta chiudendo è ancora montata (animazione di uscita) e il `pop` toglieva
/// quella sotto; con una pagina aperta sopra si chiudeva quella al posto
/// del modulo. Restituisce true se la pagina è stata chiusa qui.
bool popIfCurrent<T extends Object?>(BuildContext context, [T? result]) {
  if (!context.mounted) return false;
  final route = ModalRoute.of(context);
  final nav = Navigator.maybeOf(context);
  if (route == null || nav == null) return false;
  if (route.isCurrent) {
    nav.pop<T>(result);
    return true;
  }
  if (route.isActive) {
    nav.removeRoute(route, result);
    return true;
  }
  return false;
}

/// La pagina di [context] è montata e in cima: si può aprire qualcosa al
/// suo posto (`pushReplacement`) o sopra di lei dopo un'attesa. Con la
/// pagina che si sta chiudendo `pushReplacement` sostituirebbe quella sotto.
bool isCurrentRoute(BuildContext context) =>
    context.mounted && (ModalRoute.isCurrentOf(context) ?? false);
