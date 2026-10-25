import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/section_active.dart';
import '../feedback/motion.dart' show motion;

/// Durata del passaggio da una sezione principale all'altra.
const kSectionSwitchDuration = Duration(milliseconds: 240);

/// Parte del passaggio in cui la sezione uscente sparisce; nel resto entra
/// la nuova (le due non si vedono mai insieme).
const double kSectionOutPart = 0.35;

/// Scala da cui parte la sezione che entra.
const double kSectionInScale = 0.96;

/// Le sezioni principali dell'app (Home, Registra, Studio…), una sopra
/// l'altra come le schede di iOS.
///
/// - Ogni sezione si costruisce la prima volta che si apre e poi resta viva
///   nascosta: stato, scorrimento, scheda interna e dati restano, e tornando
///   nella sezione non c'è nessun cerchio di caricamento. I dati restano
///   aggiornati: `RevisionBuilder` li rilegge al ritorno nella sezione (e a
///   ogni `revision.bump()` mentre è visibile).
/// - Le sezioni nascoste non si disegnano, non ricevono tocchi, tasti né
///   fuoco, non sono lette dal lettore dello schermo, le loro animazioni sono
///   ferme (`TickerMode`) e i loro `Hero` spenti ([SectionActive] dice ai
///   widget se la sezione è visibile).
/// - Passaggio: dissolvenza «fade through» di Material ([kSectionSwitchDuration],
///   easeOutCubic): la sezione uscente sparisce nel primo terzo, poi la nuova
///   compare con un leggero ingrandimento (da [kSectionInScale] a 1). Le due
///   non si sovrappongono mai: le schermate hanno il fondo trasparente sopra
///   quello dell'app, e una non traspare attraverso l'altra. Con «Riduci
///   animazioni» il cambio è istantaneo.
/// - [prefetch]: sezioni costruite in anticipo, nascoste, una alla volta dopo
///   [prefetchDelay] dall'avvio (a riposo): la prima apertura è già pronta.
/// - [resetKey] diverso (corso o anno cambiati): le sezioni nascoste si
///   buttano e si ricostruiscono da zero alla prossima apertura, come prima;
///   quella visibile resta.
/// - Con poca memoria (avviso del sistema) si buttano le sezioni nascoste.
class SectionStack extends StatefulWidget {
  const SectionStack({
    super.key,
    required this.index,
    required this.count,
    required this.builder,
    required this.controllers,
    this.resetKey,
    this.prefetch = const [],
    this.prefetchDelay = const Duration(milliseconds: 1500),
  });

  /// Sezione visibile.
  final int index;
  final int count;
  final IndexedWidgetBuilder builder;

  /// Controllo dello scorrimento principale di ogni sezione
  /// ([PrimaryScrollController] della sezione: liste delle sezioni nascoste
  /// separate da quella visibile, «torna in cima» e tocco sulla barra di
  /// stato di iOS).
  final List<ScrollController> controllers;
  final Object? resetKey;
  final List<int> prefetch;
  final Duration prefetchDelay;

  @override
  State<SectionStack> createState() => SectionStackState();
}

class SectionStackState extends State<SectionStack>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Sezioni nell'albero (visibile, uscente e nascoste).
  final Set<int> _built = {};

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: kSectionSwitchDuration,
    value: 1,
  )..addStatusListener(_onStatus);

  late final CurvedAnimation _inCurve = CurvedAnimation(
    parent: _anim,
    curve: const Interval(kSectionOutPart, 1, curve: Curves.easeOutCubic),
  );
  late final CurvedAnimation _outCurve = CurvedAnimation(
    parent: _anim,
    curve: const Interval(0, kSectionOutPart, curve: Curves.easeOut),
  );
  late final Animation<double> _inScale = Tween<double>(
    begin: kSectionInScale,
    end: 1,
  ).animate(_inCurve);
  Animation<double> _outOpacity = kAlwaysDismissedAnimation;

  /// Sezione che sta uscendo (durante il passaggio).
  int? _leaving;
  Timer? _prefetchTimer;

  /// Sezioni costruite (per le prove).
  @visibleForTesting
  Set<int> get builtSections => Set.unmodifiable(_built);

  /// Passaggio in corso (per le prove).
  @visibleForTesting
  bool get switching => _leaving != null;

  @override
  void initState() {
    super.initState();
    _built.add(widget.index);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _schedulePrefetch(widget.prefetchDelay),
    );
  }

  @override
  void didUpdateWidget(covariant SectionStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetKey != oldWidget.resetKey) {
      // corso o anno cambiati: via le sezioni nascoste, niente passaggio
      _built.removeWhere((i) => i != widget.index);
      _built.add(widget.index);
      _leaving = null;
      _anim.value = 1;
      _schedulePrefetch(widget.prefetchDelay);
    } else if (widget.index != oldWidget.index) {
      _switchFrom(oldWidget.index);
    }
  }

  void _switchFrom(int from) {
    _built.add(widget.index);
    final d = motion(context, kSectionSwitchDuration);
    if (d == Duration.zero) {
      _leaving = null;
      _anim.value = 1;
      return;
    }
    // la sezione che esce parte dall'opacità che ha adesso (se stava ancora
    // entrando, tocco veloce su un'altra voce: niente salto a piena vista)
    final from0 = _anim.isAnimating ? _inCurve.value : 1.0;
    _outOpacity = Tween<double>(begin: from0, end: 0).animate(_outCurve);
    _leaving = from;
    _anim.duration = d;
    _anim.forward(from: 0);
  }

  void _onStatus(AnimationStatus s) {
    if (s.isCompleted && _leaving != null && mounted) {
      setState(() => _leaving = null);
    }
  }

  void _schedulePrefetch(Duration delay) {
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    if (!mounted || _nextPrefetch() == null) return;
    _prefetchTimer = Timer(delay, _prefetchOne);
  }

  int? _nextPrefetch() {
    for (final i in widget.prefetch) {
      if (i >= 0 && i < widget.count && !_built.contains(i)) return i;
    }
    return null;
  }

  /// Costruisce (nascosta) la prossima sezione da preparare; la successiva
  /// dopo un po', a fotogramma disegnato.
  void _prefetchOne() {
    _prefetchTimer = null;
    if (!mounted) return;
    if (_anim.isAnimating) {
      _schedulePrefetch(const Duration(milliseconds: 400));
      return;
    }
    final next = _nextPrefetch();
    if (next == null) return;
    setState(() => _built.add(next));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _schedulePrefetch(const Duration(milliseconds: 500)),
    );
  }

  /// Riporta in cima le liste della sezione visibile (tocco sulla voce già
  /// attiva della barra, come su iOS).
  void scrollToTop() {
    final c = widget.controllers[widget.index];
    final d = motion(context, const Duration(milliseconds: 350));
    for (final p in c.positions.toList()) {
      if (!p.hasPixels || p.pixels <= p.minScrollExtent) continue;
      if (d == Duration.zero) {
        p.jumpTo(p.minScrollExtent);
      } else {
        p.animateTo(p.minScrollExtent, duration: d, curve: Curves.easeOutCubic);
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (!mounted) return;
    final keep = {widget.index, ?_leaving};
    if (_built.every(keep.contains)) return;
    setState(() => _built.removeWhere((i) => !keep.contains(i)));
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _inCurve.dispose();
    _outCurve.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leaving = _leaving;
    final order = _built.toList()..sort();
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final i in order)
          _SectionSlot(
            key: ValueKey<int>(i),
            active: i == widget.index,
            visible: i == widget.index || i == leaving,
            opacity: leaving == null
                ? kAlwaysCompleteAnimation
                : i == widget.index
                ? _inCurve
                : i == leaving
                ? _outOpacity
                : kAlwaysCompleteAnimation,
            scale: leaving != null && i == widget.index
                ? _inScale
                : kAlwaysCompleteAnimation,
            controller: widget.controllers[i],
            child: widget.builder(context, i),
          ),
      ],
    );
  }
}

/// Una sezione nella pila: sempre la stessa struttura (lo stato non si
/// perde), cambiano solo visibilità, opacità e scala.
class _SectionSlot extends StatelessWidget {
  const _SectionSlot({
    super.key,
    required this.active,
    required this.visible,
    required this.opacity,
    required this.scale,
    required this.controller,
    required this.child,
  });

  /// Sezione scelta (riceve tocchi, tasti, fuoco; animazioni attive).
  final bool active;

  /// Si disegna: la sezione scelta e, durante il passaggio, quella uscente.
  final bool visible;
  final Animation<double> opacity;
  final Animation<double> scale;
  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: active,
        child: HeroMode(
          enabled: active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(
              excluding: !active,
              child: IgnorePointer(
                ignoring: !active,
                child: SectionActive(
                  active: active,
                  // i suggerimenti si disegnano sopra tutto (nell'Overlay,
                  // fuori dalla sezione): uno aperto con una pressione
                  // lunga restava sopra la sezione nuova, fermo a metà
                  // dissolvenza (animazioni spente)
                  child: TooltipVisibility(
                    visible: active,
                    child: PrimaryScrollController(
                      controller: controller,
                      child: FadeTransition(
                        opacity: opacity,
                        child: ScaleTransition(
                          scale: scale,
                          // la sezione si disegna una volta e durante il
                          // passaggio si compone soltanto
                          child: RepaintBoundary(child: child),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
