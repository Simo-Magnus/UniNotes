import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoRouteTransitionMixin;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

import '../../widgets/glass.dart' show AppBackground;
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

/// Fondo opaco di una pagina SOLO mentre la transizione è in corso.
///
/// Le schermate hanno lo Scaffold trasparente (il fondo a strati sta sopra
/// il Navigator, vedi [AppBackground]) e le card sono di vetro traslucido:
/// durante il cambio di pagina la pagina precedente restava visibile
/// attraverso quella nuova e il telefono doveva comporre due schermate piene
/// di strati semitrasparenti a ogni fotogramma, da cui lo scatto. Qui sotto
/// la pagina si stende lo stesso fondo dell'app, ma pieno e salvato come
/// immagine (RepaintBoundary): la pagina vecchia non traspare e si compone
/// una sola pagina alla volta. Il fondo scorre con la pagina (è dentro lo
/// scorrimento della transizione), quindi della pagina sotto si vede solo
/// la parte scoperta, come su iOS. A transizione finita il fondo si toglie
/// (è identico a quello dell'app, non si nota) e la pagina torna
/// trasparente com'era: da ferma le pagine sotto non si disegnano più (la
/// route è opaca).
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({super.key, required this.animation, required this.child});

  /// Animazione della pagina (0 = fuori, 1 = ferma al suo posto).
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, bg) =>
                  // pagina ferma: nessun fondo (nessun costo a regime)
                  animation.isCompleted ? const SizedBox.shrink() : bg!,
              child: const RepaintBoundary(
                child: AppBackground(child: SizedBox.expand()),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Molla di iOS a smorzamento critico (rigidità 522,35 di
/// `CASpringAnimation`, quella di avvisi e fogli di iOS): parte veloce e si
/// posa senza rimbalzo. Con 404 ms di durata è la molla di iOS; con durate
/// diverse ne conserva la forma.
class IosSpringCurve extends Curve {
  const IosSpringCurve();

  // ω·T: ω = √522,35 ≈ 22,855 rad/s, T = 0,404 s
  static const double _k = 9.2335;
  // a t = 1 la molla è a 1/1000 dalla fine: si normalizza per chiudere su 1
  static final double _end = 1 - (1 + _k) * math.exp(-_k);

  @override
  double transformInternal(double t) {
    final x = _k * t;
    return (1 - (1 + x) * math.exp(-x)) / _end;
  }
}

/// La molla di iOS ([IosSpringCurve]).
const Curve kIosSpring = IosSpringCurve();

/// Finestre (avvisi): entrata con la molla di iOS in 404 ms, uscita con una
/// dissolvenza rapida (nella prima metà del tempo, poi solo la barriera).
const AnimationStyle kIosDialogAnimation = AnimationStyle(
  curve: kIosSpring,
  duration: Duration(milliseconds: 404),
  reverseCurve: Interval(0.5, 1, curve: Curves.easeIn),
);

/// Fogli dal basso: salgono con la molla di iOS e scendono con la stessa
/// molla rovesciata (partono svelti e rallentano fuori dallo schermo).
const AnimationStyle kIosSheetAnimation = AnimationStyle(
  curve: kIosSpring,
  duration: Duration(milliseconds: 450),
  reverseCurve: FlippedCurve(kIosSpring),
  reverseDuration: Duration(milliseconds: 320),
);

/// Riquadri che si aprono e si chiudono (ExpansionTile), con la molla
/// (prima: 200 ms che acceleravano verso la fine).
const AnimationStyle kIosExpansionAnimation = AnimationStyle(
  curve: kIosSpring,
  duration: Duration(milliseconds: 360),
  reverseCurve: FlippedCurve(kIosSpring),
);

/// Transizioni tra le pagine come su iOS, su tutte le piattaforme.
///
/// - Pagina normale: entra da destra (curva di iOS, 500 ms) con l'ombra sul
///   bordo sinistro; quella sotto scorre a sinistra di un terzo (parallasse)
///   e si scurisce appena. Si torna indietro trascinando dal bordo sinistro
///   (dito; su PC anche il mouse), con il gesto «Indietro» di Android (la
///   pagina segue il dito), con due dita sul touchpad del PC e con il tasto
///   «Indietro» del mouse.
/// - Pagina «a schermo intero» (moduli: aggiungi libro, esame, ...): sale
///   dal basso come i moduli di iOS; la pagina sotto resta ferma.
///
/// La pagina che si muove è opaca ([PageBackdrop]). Con «Riduci animazioni»
/// le pagine compaiono e scompaiono subito, ma durante un gesto «Indietro»
/// seguono comunque il dito.
class IosPageTransitionsBuilder extends PageTransitionsBuilder {
  const IosPageTransitionsBuilder();

  @override
  Duration get transitionDuration =>
      CupertinoRouteTransitionMixin.kTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    var primary = animation;
    var secondary = secondaryAnimation;
    if (reduceMotion(context)) {
      final i = _InstantAnimations.of(route, animation, secondaryAnimation);
      primary = i.primary;
      secondary = i.secondary;
    }
    // costruito a ogni fotogramma della transizione: solo widget leggeri; la
    // pagina (child) ha già il suo RepaintBoundary nella route e non si
    // ridisegna, si sposta soltanto
    return _UnderPageDim(
      animation: secondary,
      child: CupertinoRouteTransitionMixin.buildPageTransitions<T>(
        route,
        context,
        primary,
        secondary,
        _BackGestures(
          route: route,
          child: PageBackdrop(animation: animation, child: child),
        ),
      ),
    );
  }
}

/// Tema delle transizioni dell'app: [IosPageTransitionsBuilder] ovunque.
const PageTransitionsTheme kIosPageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: IosPageTransitionsBuilder(),
    TargetPlatform.iOS: IosPageTransitionsBuilder(),
    TargetPlatform.macOS: IosPageTransitionsBuilder(),
    TargetPlatform.windows: IosPageTransitionsBuilder(),
    TargetPlatform.linux: IosPageTransitionsBuilder(),
    TargetPlatform.fuchsia: IosPageTransitionsBuilder(),
  },
);

/// Velo appena scuro sulla pagina coperta da quella che entra (come la
/// barriera delle pagine di iOS). Non si disegna a velo spento.
class _UnderPageDim extends StatelessWidget {
  const _UnderPageDim({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      Positioned.fill(
        child: IgnorePointer(
          child: FadeTransition(
            opacity: animation,
            child: const ColoredBox(color: Color(0x18000000)),
          ),
        ),
      ),
    ],
  );
}

/// «Riduci animazioni»: animazione della pagina che salta subito alla fine
/// (1 entrando, 0 uscendo), tranne durante un gesto «Indietro», quando segue
/// il dito.
class _InstantAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _InstantAnimation(this.parent, this.route);

  @override
  final Animation<double> parent;
  final Route<dynamic> route;

  @override
  double get value {
    if (route.navigator?.userGestureInProgress ?? false) return parent.value;
    return parent.status.isForwardOrCompleted ? 1 : 0;
  }
}

/// Le due animazioni istantanee di una route, create una volta sola (la
/// transizione si ricostruisce a ogni fotogramma).
class _InstantAnimations {
  _InstantAnimations(
    Route<dynamic> route,
    Animation<double> a,
    Animation<double> s,
  ) : primary = _InstantAnimation(a, route),
      secondary = _InstantAnimation(s, route);

  final _InstantAnimation primary;
  final _InstantAnimation secondary;

  static final Expando<_InstantAnimations> _cache = Expando('instant');

  static _InstantAnimations of(
    Route<dynamic> route,
    Animation<double> a,
    Animation<double> s,
  ) {
    final c = _cache[route];
    if (c != null && c.primary.parent == a && c.secondary.parent == s) {
      return c;
    }
    return _cache[route] = _InstantAnimations(route, a, s);
  }
}

/// Gesti «Indietro» oltre al trascinamento dal bordo (che sta nella
/// transizione di iOS):
/// - Android: il gesto «Indietro» del sistema (predittivo, Android 14+)
///   porta la pagina con il dito; i tasti di navigazione e le versioni
///   precedenti chiudono la pagina come prima;
/// - PC: due dita verso destra sul touchpad e il tasto «Indietro» del mouse.
/// Non partono se la pagina non si può chiudere (moduli con modifiche non
/// salvate, prima pagina, pagina «a schermo intero», transizione in corso).
class _BackGestures extends StatefulWidget {
  const _BackGestures({required this.route, required this.child});
  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_BackGestures> createState() => _BackGesturesState();
}

class _BackGesturesState extends State<_BackGestures>
    with WidgetsBindingObserver {
  TargetPlatform _platform = defaultTargetPlatform;
  HorizontalDragGestureRecognizer? _trackpad;
  bool _predictive = false;
  bool _dragging = false;

  /// Posizione della pagina durante il gesto del touchpad (1 = al suo posto).
  double _value = 1;

  PageRoute<dynamic> get _route => widget.route;
  bool get _enabled => _route.isCurrent && _route.popGestureEnabled;
  bool get _desktop => switch (_platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
  bool get _rtl => Directionality.of(context) == TextDirection.rtl;
  double get _width => math.max(1, context.size?.width ?? 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trackpad?.dispose();
    super.dispose();
  }

  // --- Android: «Indietro» predittivo -------------------------------------

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (_platform != TargetPlatform.android ||
        backEvent.isButtonEvent ||
        !_enabled) {
      return false;
    }
    _predictive = true;
    _route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_predictive) return;
    _route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (!_predictive) return;
    _predictive = false;
    _route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (!_predictive) return;
    _predictive = false;
    _popAfterBackGesture(_route);
  }

  // --- PC: touchpad e tasto «Indietro» del mouse --------------------------

  void _panZoomStart(PointerPanZoomStartEvent e) {
    if (!_desktop || !_enabled) return;
    (_trackpad ??=
            HorizontalDragGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {PointerDeviceKind.trackpad},
              )
              ..onStart = _dragStart
              ..onUpdate = _dragUpdate
              ..onEnd = _dragEnd
              ..onCancel = _dragCancel)
        .addPointerPanZoom(e);
  }

  void _dragStart(DragStartDetails d) {
    if (!_enabled) return;
    _dragging = true;
    _value = 1;
    _route.handleStartBackGesture(progress: 1);
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final delta = (d.primaryDelta ?? 0) / _width;
    _value = (_value - (_rtl ? -delta : delta)).clamp(0.0, 1.0);
    _route.handleUpdateBackGestureProgress(progress: _value);
  }

  void _dragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    var v = (d.primaryVelocity ?? 0) / _width;
    if (_rtl) v = -v;
    // come su iOS: un colpo deciso decide la direzione, altrimenti conta
    // dove è arrivata la pagina
    final pop = v.abs() >= 1 ? v > 0 : _value < 0.5;
    if (pop) {
      _popAfterBackGesture(_route);
    } else {
      _route.handleCancelBackGesture();
    }
  }

  void _dragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _route.handleCancelBackGesture();
  }

  void _pointerDown(PointerDownEvent e) {
    if (!_desktop || e.buttons & kBackMouseButton == 0) return;
    if (_route.isCurrent && !_route.isFirst) _route.navigator?.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    _platform = Theme.of(context).platform;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerPanZoomStart: _panZoomStart,
      onPointerDown: _pointerDown,
      child: widget.child,
    );
  }
}

/// Chiude [route] alla fine di un gesto «Indietro» (Android, touchpad): la
/// pagina continua a scorrere da dove l'ha lasciata il dito. Il gesto resta
/// «in corso» finché la pagina non è uscita, così la transizione resta
/// lineare e non salta.
void _popAfterBackGesture(PageRoute<dynamic> route) {
  final nav = route.navigator;
  if (nav == null) return;
  final anim = route.animation!;
  if (route.isCurrent) nav.pop();
  if (!anim.isAnimating) {
    nav.didStopUserGesture();
    return;
  }
  late final AnimationStatusListener done;
  done = (status) {
    if (status.isAnimating) return;
    anim.removeStatusListener(done);
    nav.didStopUserGesture();
  };
  anim.addStatusListener(done);
}
