import 'package:flutter/widgets.dart';

/// Pizzico con due dita sopra una lista che scorre: non entra nell'arena
/// dei gesti (lo scorrimento resta della lista) e riporta solo la scala
/// rispetto all'inizio del pizzico.
class PinchScaleListener extends StatefulWidget {
  const PinchScaleListener({
    super.key,
    required this.scale,
    required this.onScale,
    required this.child,
    this.min = 0.6,
    this.max = 3.0,
  });

  /// Scala attuale (punto di partenza del pizzico).
  final double scale;
  final ValueChanged<double> onScale;
  final double min;
  final double max;
  final Widget child;

  @override
  State<PinchScaleListener> createState() => _PinchScaleListenerState();
}

class _PinchScaleListenerState extends State<PinchScaleListener> {
  final _pointers = <int, Offset>{};
  double? _startDistance;
  double _startScale = 1;

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      final v = _pointers.values.toList();
      _startDistance = (v[0] - v[1]).distance;
      _startScale = widget.scale;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _startDistance;
    if (_pointers.length != 2 || start == null || start < 20) return;
    final v = _pointers.values.toList();
    final s = (_startScale * (v[0] - v[1]).distance / start).clamp(
      widget.min,
      widget.max,
    );
    if ((s - widget.scale).abs() > 0.02) widget.onScale(s);
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _startDistance = null;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    child: widget.child,
  );
}
