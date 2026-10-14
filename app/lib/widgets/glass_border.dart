import 'package:flutter/material.dart';

import '../core/theme/app_tokens.dart';

/// Bordo «di vetro» per le superfici che compaiono sopra la pagina
/// (finestre di dialogo, card che salgono dal basso, menu): stesso
/// materiale delle sezioni-card di Design 3 invece di un fondo piatto.
/// Sopra il colore della superficie disegna la luce dall'alto che sfuma, il
/// faretto azzurro, il filo di luce, il bordo sottile e i rilievi interni
/// (chiaro in alto, scuro in basso). Le luci sono tenui: il testo sotto
/// resta leggibile.
class GlassBorder extends RoundedRectangleBorder {
  const GlassBorder({
    required this.tokens,
    required this.dark,
    super.borderRadius,
    this.spotlight = true,
  }) : super(side: BorderSide.none);

  final AppTokens tokens;
  final bool dark;

  /// Faretto azzurro in alto (non nei menu, che sono superfici piccole).
  final bool spotlight;

  @override
  GlassBorder copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
  }) => GlassBorder(
    tokens: tokens,
    dark: dark,
    borderRadius: borderRadius ?? this.borderRadius,
    spotlight: spotlight,
  );

  @override
  GlassBorder scale(double t) => GlassBorder(
    tokens: tokens,
    dark: dark,
    borderRadius: borderRadius * t,
    spotlight: spotlight,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => t < 0.5 ? a : this;

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => t < 0.5 ? this : b;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final rrect = borderRadius.resolve(textDirection).toRRect(rect);
    canvas.save();
    canvas.clipRRect(rrect);

    // luce dall'alto che sfuma e base appena più scura (materiale della card)
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [
                  Color(0x14FFFFFF),
                  Color(0x06FFFFFF),
                  Color(0x00FFFFFF),
                  Color(0x1E000814),
                ]
              : const [
                  Color(0x00FFFFFF),
                  Color(0x00FFFFFF),
                  Color(0x00FFFFFF),
                  Color(0x0A0B2545),
                ],
          stops: const [0, 0.34, 0.66, 1],
        ).createShader(rect),
    );

    // faretto azzurro 250×150 ancorato a −34 px dal bordo alto
    if (spotlight) {
      final spot = Rect.fromCenter(
        center: Offset(rect.center.dx, rect.top - 34 + 75),
        width: 250,
        height: 150,
      );
      canvas.drawRect(
        spot,
        Paint()
          ..shader = RadialGradient(
            colors: [tokens.spotlight, tokens.spotlight.withValues(alpha: 0)],
          ).createShader(spot),
      );
    }

    // rilievi interni: chiaro in alto, scuro in basso
    final topEdge = Paint()
      ..color = dark ? const Color(0x2EFFFFFF) : const Color(0xB3FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(rect.left + rrect.tlRadiusX, rect.top + 1.5),
      Offset(rect.right - rrect.trRadiusX, rect.top + 1.5),
      topEdge,
    );
    if (dark) {
      canvas.drawLine(
        Offset(rect.left + rrect.blRadiusX, rect.bottom - 1.5),
        Offset(rect.right - rrect.brRadiusX, rect.bottom - 1.5),
        Paint()
          ..color = const Color(0x6B000000)
          ..strokeWidth = 1,
      );
    }

    // filo di luce: dal 16% all'84% della larghezza
    final thread = tokens.lightThread;
    if (thread != null) {
      final line = Rect.fromLTWH(
        rect.left + rect.width * 0.16,
        rect.top,
        rect.width * 0.68,
        1,
      );
      canvas.drawRect(
        line,
        Paint()
          ..shader = LinearGradient(
            colors: [
              thread.withValues(alpha: 0),
              thread,
              thread.withValues(alpha: 0),
            ],
          ).createShader(line),
      );
    }
    canvas.restore();

    // bordo sottile
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark ? const Color(0x2EA0CDFF) : tokens.cardBorder,
    );
  }
}
