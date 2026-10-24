import 'package:flutter/material.dart';

import 'motion.dart';

/// Finestre e fogli dal basso dell'app, con le curve di iOS (molla a
/// smorzamento critico, [kIosSpring]) al posto di quelle di Material, e
/// subito fermi con «Riduci animazioni» (che [showDialog] e
/// [showModalBottomSheet] da soli ignorano). Tutta l'app usa questi due: lo
/// controlla `test/ios_motion_test.dart`.

/// Come [showDialog]: la finestra compare con una dissolvenza e un leggero
/// ingrandimento all'indietro (da 1,15 a 1, come gli avvisi di iOS) sulla
/// molla di iOS; si chiude con una dissolvenza rapida, senza scala. Il fondo
/// si scurisce come prima (colore della barriera del tema).
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  final reduce = reduceMotion(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    animationStyle: reduce ? AnimationStyle.noAnimation : kIosDialogAnimation,
    builder: reduce
        ? builder
        : (context) => _DialogEntrance(child: builder(context)),
  );
}

/// Come [showModalBottomSheet] (con i parametri usati nell'app): il foglio
/// sale con la molla di iOS e scende con la stessa molla rovesciata.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool? showDragHandle,
  bool useSafeArea = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  BoxConstraints? constraints,
  Color? backgroundColor,
}) => showModalBottomSheet<T>(
  context: context,
  builder: builder,
  isScrollControlled: isScrollControlled,
  showDragHandle: showDragHandle,
  useSafeArea: useSafeArea,
  isDismissible: isDismissible,
  enableDrag: enableDrag,
  useRootNavigator: useRootNavigator,
  constraints: constraints,
  backgroundColor: backgroundColor,
  sheetAnimationStyle: reduceMotion(context)
      ? AnimationStyle.noAnimation
      : kIosSheetAnimation,
);

/// Ingrandimento d'entrata della finestra, sull'animazione della sua route.
class _DialogEntrance extends StatefulWidget {
  const _DialogEntrance({required this.child});
  final Widget child;

  @override
  State<_DialogEntrance> createState() => _DialogEntranceState();
}

class _DialogEntranceState extends State<_DialogEntrance> {
  Animation<double>? _route;
  Animation<double>? _scale;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = ModalRoute.of(context)?.animation;
    if (a != _route) {
      _route = a;
      _scale = a == null ? null : _EntranceScale(a);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _scale;
    // solo la trasformazione cambia a ogni fotogramma: la finestra non si
    // ricostruisce
    return s == null
        ? widget.child
        : ScaleTransition(scale: s, child: widget.child);
  }
}

/// Scala da 1,15 a 1 sulla molla di iOS entrando; 1 uscendo (solo
/// dissolvenza, come su iOS).
class _EntranceScale extends Animation<double>
    with AnimationWithParentMixin<double> {
  _EntranceScale(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value => parent.status == AnimationStatus.reverse
      ? 1
      : 1 + 0.15 * (1 - kIosSpring.transform(parent.value.clamp(0.0, 1.0)));
}
