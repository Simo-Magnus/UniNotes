import 'package:flutter/material.dart';

/// Vero se le schede di una [TabBar] a larghezza uguale non bastano per le
/// scritte intere («Sessioni Studio» a 360 dp, caratteri grandi): allora la
/// barra va resa scorrevole ([TabBar.isScrollable]) invece di tagliare le
/// parole. [width] è la larghezza della barra (di norma quella dello
/// schermo).
bool tabsNeedScroll(BuildContext context, List<String> labels, double width) {
  if (labels.isEmpty || !width.isFinite) return false;
  final style =
      Theme.of(context).tabBarTheme.labelStyle ??
      Theme.of(context).textTheme.titleSmall;
  final dir = Directionality.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final l in labels) {
    final p = TextPainter(
      text: TextSpan(text: l, style: style),
      textDirection: dir,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    if (p.width > widest) widest = p.width;
    p.dispose();
  }
  // margine interno di una scheda: 16 + 16, più un po' di scorta
  return widest + 36 > width / labels.length;
}
