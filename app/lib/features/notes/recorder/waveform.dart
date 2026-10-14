import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Forma d'onda della registrazione in corso: una barra per ogni campione
/// (0,1 s), le più recenti a destra; scorre verso sinistra mentre si
/// registra.
class LiveWavePainter extends CustomPainter {
  LiveWavePainter({
    required this.levels,
    required this.color,
    required this.idle,
  });

  final List<double> levels;
  final Color color;
  final Color idle;

  static const _bar = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final n = (size.width / (_bar + _gap)).floor();
    final mid = size.height / 2;
    final paint = Paint()..strokeCap = StrokeCap.round;
    final start = math.max(0, levels.length - n);
    final shown = levels.sublist(start);
    for (var i = 0; i < n; i++) {
      final k = shown.length - n + i;
      final v = k >= 0 ? shown[k] : 0.0;
      final h = math.max(2.0, v * size.height);
      final x = i * (_bar + _gap) + _bar / 2;
      paint
        ..color = k >= 0 ? color.withValues(alpha: 0.35 + 0.65 * v) : idle
        ..strokeWidth = _bar;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  // la lista dei livelli cresce (e scorre) a ogni campione: si ridisegna sempre
  @override
  bool shouldRepaint(LiveWavePainter old) => true;
}

/// Forma d'onda in riproduzione, come Memo Vocali: la linea di lettura
/// resta al centro e l'audio scorre sotto. Le parti già ascoltate sono
/// piene, le altre attenuate; i segnalibri sono tacche arancioni.
///
/// Con [positionOf] e [repaint] la posizione si legge a ogni disegno: la
/// forma d'onda scorre a ogni fotogramma senza ricostruire la pagina.
class PlaybackWavePainter extends CustomPainter {
  PlaybackWavePainter({
    required this.peaks,
    required this.every,
    this.position = Duration.zero,
    this.positionOf,
    super.repaint,
    required this.color,
    required this.muted,
    required this.playhead,
    required this.marks,
    required this.markColor,
    this.selection,
    this.selectionColor,
  });

  final Uint8List peaks;
  final Duration every;
  final Duration position;
  final Duration Function()? positionOf;

  Duration get _position => positionOf?.call() ?? position;
  final Color color;
  final Color muted;
  final Color playhead;
  final List<Duration> marks;
  final Color markColor;

  /// Tratto selezionato (taglio).
  final (Duration, Duration)? selection;
  final Color? selectionColor;

  /// Pixel per campione (0,1 s → 5 px: 50 px al secondo).
  static const step = 5.0;

  double _xOf(Duration t, Size size, double pos) {
    final i = t.inMicroseconds / every.inMicroseconds;
    return size.width / 2 + (i - pos) * step;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final pos = _position.inMicroseconds / every.inMicroseconds;
    final first = math.max(0, (pos - size.width / 2 / step).floor());
    final last = math.min(
      peaks.length - 1,
      (pos + size.width / 2 / step).ceil(),
    );
    final sel = selection;
    if (sel != null && selectionColor != null) {
      final a = _xOf(sel.$1, size, pos), b = _xOf(sel.$2, size, pos);
      canvas.drawRect(
        Rect.fromLTRB(math.min(a, b), 0, math.max(a, b), size.height),
        Paint()..color = selectionColor!,
      );
    }
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    for (var i = first; i <= last; i++) {
      final v = peaks[i] / 255;
      final h = math.max(2.0, v * (size.height - 8));
      final x = size.width / 2 + (i - pos) * step;
      paint.color = i <= pos ? color : muted;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
    final mark = Paint()
      ..color = markColor
      ..strokeWidth = 2;
    for (final m in marks) {
      final x = _xOf(m, size, pos);
      if (x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, 10), mark);
      canvas.drawCircle(Offset(x, 4), 3, mark);
    }
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      Paint()
        ..color = playhead
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(PlaybackWavePainter old) =>
      old.position != position ||
      old.positionOf != positionOf ||
      old.peaks != peaks ||
      old.marks != marks ||
      old.selection != selection ||
      old.color != color;
}
