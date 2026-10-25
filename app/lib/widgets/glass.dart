import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/feedback/feedback_service.dart';
import '../core/feedback/motion.dart';
import '../core/theme/app_tokens.dart';

/// Fondo a strati dell'app: base lineare, luci di sezione e d'angolo, bordi
/// in ombra. Nel fondo non compare mai l'arancione.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return CustomPaint(painter: _BackgroundPainter(t), child: child);
  }
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.t);
  final AppTokens t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.07, -1),
          end: const Alignment(0.07, 1),
          colors: t.background,
          stops: const [0, 0.30, 0.55, 0.80, 1],
        ).createShader(rect),
    );
    // Luci ellittiche, proporzionate allo schermo (cerchio scalato).
    for (final l in t.lights) {
      final c = l.center.alongSize(size);
      final rx = l.radii.width * size.width;
      final ry = l.radii.height * size.height;
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.scale(rx, ry);
      canvas.drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [l.color, l.color.withValues(alpha: 0)],
            stops: const [0, 0.72],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
      );
      canvas.restore();
    }
    if (t.vignette.a > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, -0.1),
            radius: 1.05,
            colors: [t.vignette.withValues(alpha: 0), t.vignette],
            stops: const [0.52, 1],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => old.t != t;
}

/// Card di vetro: stesso materiale per tutte le card di una schermata, filo
/// di luce in alto e faretto interno. Sostituisce `Card` nelle schermate.
///
/// Il vetro non usa BackdropFilter: sul fondo a gradienti morbidi la
/// sfocatura non si vede e peserebbe sullo scorrimento dei telefoni.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.color,
    this.shape,
    this.clipBehavior = Clip.antiAlias,
    this.elevation,
    this.inner = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? margin;

  /// Tinta aggiuntiva (es. stato) sopra il materiale.
  final Color? color;

  /// Accettato per compatibilità con `Card`: se ha un bordo colorato, lo usa.
  final ShapeBorder? shape;
  final Clip clipBehavior;
  final double? elevation;

  /// Card interna (riquadri dentro una card): materiale attenuato, raggio 16.
  final bool inner;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final radius = BorderRadius.circular(
      inner ? AppScale.radiusInner : AppScale.radiusCard,
    );
    final side = shape is RoundedRectangleBorder
        ? (shape! as RoundedRectangleBorder).side
        : null;
    final border = (side != null && side != BorderSide.none)
        ? side.color
        : (inner ? t.innerBorder : t.cardBorder);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: CustomPaint(
        painter: inner ? null : OutsetShadowPainter(t.cardShadows, radius),
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: clipBehavior,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              color: inner ? t.innerCard : null,
              gradient: inner
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: t.cardGradient,
                      stops: const [0, 0.34, 0.66, 1],
                    ),
              border: Border.all(color: border),
            ),
            child: Stack(
              children: [
                if (!inner)
                  Positioned(
                    top: -34,
                    left: 0,
                    right: 0,
                    height: 150,
                    child: IgnorePointer(
                      child: Center(
                        child: SizedBox(
                          width: 250,
                          height: 150,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                colors: [
                                  t.spotlight,
                                  t.spotlight.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (color != null)
                  Positioned.fill(
                    child: IgnorePointer(child: ColoredBox(color: color!)),
                  ),
                if (!inner && t.lightThread != null)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 1,
                    child: IgnorePointer(
                      child: FractionallySizedBox(
                        widthFactor: 0.68,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                t.lightThread!.withValues(alpha: 0),
                                t.lightThread!,
                                t.lightThread!.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Material(type: MaterialType.transparency, child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Intestazione di una card: titolo piccolo (11, 600) e il simbolo
/// dell'area come filigrana a destra, mai sotto un testo o un pulsante.
class CardHeader extends StatelessWidget {
  const CardHeader({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 8, 6),
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            // titoli delle card più grandi e leggibili (prima 11 px, grigi)
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                color: t.textPrimary,
              ),
            ),
          ),
          if (icon != null)
            Padding(
              padding: EdgeInsets.only(right: trailing == null ? 8 : 4),
              child: Icon(
                icon,
                size: 22,
                color: t.textPrimary.withValues(alpha: 0.18),
              ),
            ),
          // se il pulsante a destra è largo (caratteri grandi) cede
          // spazio invece di uscire dalla card
          if (trailing != null) Flexible(flex: 2, child: trailing!),
        ],
      ),
    );
  }
}

/// Anello di avanzamento (contenitore 94, spessore 9, estremità arrotondate,
/// partenza in alto). Azzurro: valore calcolato dalla macchina.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    required this.label,
    this.caption,
    this.icon,
    this.size = 94,
  });

  /// 0–1 (oltre 1 l'anello resta pieno).
  final double value;
  final String label;
  final String? caption;
  final IconData? icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: RingPainter(
          // NaN (0/0 a monte) disegnerebbe un arco senza misura: anello vuoto
          value: value.isNaN ? 0 : value.clamp(0, 1).toDouble(),
          track: t.textPrimary.withValues(alpha: 0.09),
          colors: [const Color(0xFF0EA5E9), t.cyanBright],
        ),
        // Il testo sta in un riquadro dentro il bordo interno dell'anello
        // (raggio interno = 39,5/104 della misura): le sue diagonali restano
        // dentro il cerchio con un po' di margine. Se è più largo («100%»,
        // «150%», «1000%», caratteri grandi) si rimpicciolisce, non esce.
        child: Center(
          child: SizedBox(
            width: size * 0.56,
            height: size * 0.46,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) Icon(icon, size: 14, color: t.cyanSoft),
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: t.textPrimary,
                    ),
                  ),
                  if (caption != null)
                    Text(
                      caption!,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(fontSize: 11, color: t.textMuted),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Anello di Design 3 (§7.2) su viewBox 104: raggio 44, spessore 9,
/// partenza in alto; usato anche dal timer grande della sessione Focus.
class RingPainter extends CustomPainter {
  RingPainter({required this.value, required this.track, required this.colors});
  final double value;
  final Color track;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 104;
    final stroke = 9 * scale;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: 44 * scale,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    final sweep = math.pi * 2 * value;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: colors,
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    // Bagliore leggero, non tagliato dal riquadro.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = colors.last.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(RingPainter old) =>
      old.value != value || old.colors != colors;
}

/// Valore mancante: "- -", senza colore.
const String kMissing = '- -';

/// Pulsante flottante arancione: l'unico con l'alone, perché galleggia sul
/// contenuto; anello scuro per staccarlo dallo sfondo. Con la tastiera
/// aperta (telefono) si nasconde: salirebbe sopra campi e pulsanti.
class GlowFab extends StatefulWidget {
  const GlowFab({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.heroTag,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;
  final Object? heroTag;
  final String? tooltip;

  @override
  State<GlowFab> createState() => _GlowFabState();
}

class _GlowFabState extends State<GlowFab> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // La tastiera cambia le misure della finestra.
  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Misure della finestra, non del MediaQuery: lo Scaffold toglie la
    // tastiera da quello del suo contenuto.
    if (View.of(context).viewInsets.bottom > 0) return const SizedBox.shrink();
    final t = context.tokens;
    return Pressable(
      enabled: widget.onPressed != null,
      child: _fab(context, t),
    );
  }

  Widget _fab(BuildContext context, AppTokens t) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        // tema chiaro: alone più corto e niente anello (sul fondo chiaro
        // sembrava una seconda pillola sotto il pulsante)
        boxShadow: dark
            ? [
                BoxShadow(
                  color: t.orangeGradient[1].withValues(alpha: 0.55),
                  offset: const Offset(0, 14),
                  blurRadius: 30,
                  spreadRadius: -8,
                ),
                const BoxShadow(color: Color(0xA6030A16), spreadRadius: 6),
              ]
            : [
                BoxShadow(
                  color: t.orangeGradient[2].withValues(alpha: 0.38),
                  offset: const Offset(0, 8),
                  blurRadius: 20,
                  spreadRadius: -6,
                ),
                const BoxShadow(
                  color: Color(0x140F172A),
                  offset: Offset(0, 2),
                  blurRadius: 4,
                ),
              ],
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.orangeGradient,
            stops: const [0, 0.52, 1],
          ),
        ),
        child: FloatingActionButton.extended(
          onPressed: widget.onPressed == null
              ? null
              : () {
                  // azione principale: vibrazione leggera (sul telefono)
                  AppFeedback.of(context).tap();
                  widget.onPressed!();
                },
          icon: widget.icon,
          label: widget.label,
          heroTag: widget.heroTag,
          tooltip: widget.tooltip,
          backgroundColor: Colors.transparent,
        ),
      ),
    );
  }
}

/// Ombra solo all'esterno della forma (come `box-shadow` CSS): sotto una
/// card traslucida l'ombra non deve trasparire.
class OutsetShadowPainter extends CustomPainter {
  OutsetShadowPainter(this.shadows, this.radius);
  final List<BoxShadow> shadows;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = radius.toRRect(Offset.zero & size);
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect((Offset.zero & size).inflate(80)),
        Path()..addRRect(rrect),
      ),
    );
    for (final s in shadows) {
      canvas.drawRRect(
        rrect.shift(s.offset).inflate(s.spreadRadius),
        Paint()
          ..color = s.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurSigma),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(OutsetShadowPainter old) =>
      old.shadows != shadows || old.radius != radius;
}
