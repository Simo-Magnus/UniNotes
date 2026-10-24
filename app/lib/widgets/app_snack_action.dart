import 'dart:math';

import 'package:flutter/material.dart';

/// Pulsante di un avviso in basso (SnackBar) che non esce dallo spazio.
///
/// Il [SnackBarAction] di Flutter dà alla scritta una larghezza illimitata e
/// ne misura l'ingombro senza la grandezza dei caratteri scelta: con la scritta
/// lunga («Aggiungi nota») e i caratteri grandi, su una finestra stretta, il
/// pulsante usciva dall'avviso (RenderFlex overflowed). Qui il pulsante non
/// supera il 55% dello schermo e la scritta va a capo. Dentro c'è un vero
/// [SnackBarAction]: si comporta come l'originale (preme una volta sola,
/// esegue [onPressed], chiude l'avviso) e i test lo trovano come prima.
/// Quinto giro della caccia ai crash (R5-B).
class AppSnackBarAction extends SnackBarAction {
  const AppSnackBarAction({
    super.key,
    required super.label,
    required super.onPressed,
  });

  @override
  State<SnackBarAction> createState() => _AppSnackBarActionState();
}

class _AppSnackBarActionState extends State<SnackBarAction> {
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: max(96, width * 0.55)),
      child: SnackBarAction(label: widget.label, onPressed: widget.onPressed),
    );
  }
}
