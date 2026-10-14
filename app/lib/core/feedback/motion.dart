import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'feedback_service.dart';

/// Microinterazioni: pressione con leggera scala, contatori animati,
/// conferme animate e transizioni tra le pagine. Tutte rispettano «Riduci
/// animazioni» (del sistema o dell'app, vedi MediaQuery.disableAnimations).

/// Le animazioni sono da evitare (impostazione del sistema o dell'app).
bool reduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Durata [d], o zero con «Riduci animazioni».
Duration motion(BuildContext context, Duration d) =>
    reduceMotion(context) ? Duration.zero : d;

/// Pulsante che si abbassa appena (scala 0,96) mentre lo si preme. Avvolge
/// il pulsante: il tocco resta al pulsante, qui c'è solo l'effetto. Con
/// [feedback] vibra (o suona) al rilascio del dito.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.scale = 0.96,
    this.feedback,
    this.enabled = true,
  });

  final Widget child;
  final double scale;
  final FeedbackEvent? feedback;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final reduce = reduceMotion(context);
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) {
        _set(false);
        final f = widget.feedback;
        if (f != null) AppFeedback.of(context).play(f);
      },
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !reduce ? widget.scale : 1,
        duration: Duration(milliseconds: reduce ? 0 : 90),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Numero che scorre fino al nuovo valore (minuti, percentuali, serie).
class AnimatedCount extends StatelessWidget {
  const AnimatedCount({
    super.key,
    required this.value,
    this.format,
    this.style,
    this.duration = const Duration(milliseconds: 600),
    this.semanticsLabel,
  });

  final int value;
  final String Function(int v)? format;
  final TextStyle? style;
  final Duration duration;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final f = format ?? (v) => '$v';
    return Semantics(
      label: semanticsLabel,
      value: f(value),
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value.toDouble()),
        duration: motion(context, duration),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text(f(v.round()), style: style),
      ),
    );
  }
}

/// Spunta che compare con un piccolo rimbalzo (conferme).
class AnimatedCheck extends StatelessWidget {
  const AnimatedCheck({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.tokens.cyanSoft;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduceMotion(context) ? 1 : 0, end: 1),
      duration: motion(context, const Duration(milliseconds: 420)),
      curve: Curves.elasticOut,
      builder: (context, v, child) =>
          Transform.scale(scale: v.clamp(0, 1.3), child: child),
      child: Icon(Icons.check_circle_rounded, size: size, color: c),
    );
  }
}

/// Avviso di conferma con la spunta animata, suono e vibrazione di
/// conferma.
void showSuccessSnack(
  BuildContext context,
  String message, {
  ScaffoldMessengerState? messenger,
}) {
  AppFeedback.of(context).confirm();
  (messenger ?? ScaffoldMessenger.maybeOf(context))
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const AnimatedCheck(size: 20, color: Color(0xFF7DD3FC)),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Transizioni tra le pagine uguali in tutta l'app (dissolvenza in avanti);
/// con «Riduci animazioni» la pagina compare subito.
class CalmPageTransitionsBuilder extends PageTransitionsBuilder {
  const CalmPageTransitionsBuilder(this.inner);
  final PageTransitionsBuilder inner;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion(context)) return child;
    return inner.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// Tema delle transizioni dell'app.
const PageTransitionsTheme kCalmPageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: CalmPageTransitionsBuilder(
      FadeForwardsPageTransitionsBuilder(),
    ),
    TargetPlatform.windows: CalmPageTransitionsBuilder(
      FadeForwardsPageTransitionsBuilder(),
    ),
    TargetPlatform.linux: CalmPageTransitionsBuilder(
      FadeForwardsPageTransitionsBuilder(),
    ),
    TargetPlatform.fuchsia: CalmPageTransitionsBuilder(
      FadeForwardsPageTransitionsBuilder(),
    ),
    // iOS e macOS: la transizione del sistema porta con sé il gesto per
    // tornare indietro, che deve restare anche con «Riduci animazioni».
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
  },
);
