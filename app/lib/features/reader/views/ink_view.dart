import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../notes/markdown_view.dart' show findActiveColor, findMatchColor;
import '../parsers/ink.dart';
import '../reader_controller.dart';
import '../reader_text.dart';
import 'image_view.dart';
import 'pinch.dart';

/// Appunti a mano (Xournal++, Excalidraw): pagine con tratti, forme,
/// immagini e testi. I testi si cercano e si selezionano.
class InkView extends StatefulWidget {
  const InkView({
    super.key,
    required this.doc,
    required this.controller,
    this.initialPage,
  });
  final InkDoc doc;
  final ReaderPaneController controller;
  final int? initialPage;

  @override
  State<InkView> createState() => _InkViewState();
}

class _InkViewState extends State<InkView> {
  final _scroll = ScrollController();
  final _list = ListController();
  double _zoom = 1;

  /// Risultati: (pagina, testo).
  List<(int, int)> _matches = const [];
  int? _current;
  int _lastFirst = -1;

  ReaderPaneController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _c.update(() {
      _c
        ..unitLabel = 'Pagina'
        ..unitCount = widget.doc.pages.length
        ..unit = 1
        ..onFind = _find
        ..onStep = _step
        ..onGoToUnit = ((u) => _jump(u - 1))
        ..onGoToPosition = ((p) => _jump(p - 1))
        ..describe = ((p) => 'Pagina $p')
        ..onZoom = ((d) => setState(
          () => _zoom = d == 0
              ? 1
              : (_zoom * (d > 0 ? 1.2 : 1 / 1.2)).clamp(0.4, 5.0),
        ))
        ..plainText = (() =>
            widget.doc.pages.map((p) => p.plainText).join('\n\n'));
    });
    final start = widget.initialPage;
    if (start != null && start > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jump(start - 1));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _list.dispose();
    super.dispose();
  }

  void _jump(int page) {
    if (!_list.isAttached || !_scroll.hasClients) return;
    _list.jumpToItem(
      index: page.clamp(0, widget.doc.pages.length - 1),
      scrollController: _scroll,
      alignment: 0,
    );
  }

  void _onScroll() {
    if (!_list.isAttached) return;
    final first = _list.visibleRange?.$1;
    if (first == null || first == _lastFirst) return;
    _lastFirst = first;
    _c.update(() {
      _c
        ..unit = first + 1
        ..position = first + 1;
    });
  }

  void _find(String q) {
    final out = <(int, int)>[];
    if (q.trim().isNotEmpty) {
      for (var p = 0; p < widget.doc.pages.length; p++) {
        final texts = widget.doc.pages[p].texts;
        for (var t = 0; t < texts.length; t++) {
          for (final _ in findFolded(texts[t].text, q.trim())) {
            out.add((p, t));
          }
        }
      }
    }
    setState(() {
      _matches = out;
      _current = out.isEmpty ? null : 0;
    });
    _report();
  }

  void _step(int d) {
    if (_matches.isEmpty) return;
    setState(() => _current = ((_current ?? 0) + d) % _matches.length);
    _report();
  }

  void _report() {
    _c.update(() {
      _c
        ..matchCount = _matches.length
        ..matchIndex = _current;
    });
    final cur = _current;
    if (cur != null) _jump(_matches[cur].$1);
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final pages = widget.doc.pages;
    return ColoredBox(
      color: b == Brightness.dark
          ? const Color(0xFF050B14)
          : const Color(0xFFE7ECF2),
      child: PinchScaleListener(
        scale: _zoom,
        min: 0.4,
        max: 5,
        onScale: (v) => setState(() => _zoom = v),
        child: LayoutBuilder(
          builder: (context, c) {
            final avail = c.maxWidth - 32;
            double factor(InkPage p) => math.min(avail / p.width, 1.6) * _zoom;
            final widest = pages.fold(
              0.0,
              (w, p) => math.max(w, p.width * factor(p)),
            );
            Widget list = SelectionArea(
              child: SuperListView.builder(
                controller: _scroll,
                listController: _list,
                padding: const EdgeInsets.symmetric(vertical: 16),
                itemCount: pages.length,
                itemBuilder: (context, i) {
                  final p = pages[i];
                  final f = factor(p);
                  final cur = _current == null ? null : _matches[_current!];
                  final hits = {
                    for (final m in _matches)
                      if (m.$1 == i) m.$2,
                  };
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: _InkPageView(
                        page: p,
                        factor: f,
                        hits: hits,
                        active: cur != null && cur.$1 == i ? cur.$2 : null,
                      ),
                    ),
                  );
                },
              ),
            );
            if (widest > avail) {
              list = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: widest + 32, child: list),
              );
            }
            return list;
          },
        ),
      ),
    );
  }
}

class _InkPageView extends StatelessWidget {
  const _InkPageView({
    required this.page,
    required this.factor,
    required this.hits,
    this.active,
  });
  final InkPage page;
  final double factor;
  final Set<int> hits;
  final int? active;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final f = factor;
    return Container(
      width: page.width * f,
      height: page.height * f,
      decoration: BoxDecoration(
        color: Color(page.background),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _InkPainter(page, f))),
            for (final img in page.images)
              Positioned(
                left: img.left * f,
                top: img.top * f,
                width: math.max(1, (img.right - img.left) * f),
                height: math.max(1, (img.bottom - img.top) * f),
                child: Image(
                  image: limitedMemoryImage(img.bytes),
                  fit: BoxFit.fill,
                  errorBuilder: (_, _, _) => const SizedBox(),
                ),
              ),
            for (var t = 0; t < page.texts.length; t++)
              Positioned(
                left: page.texts[t].x * f,
                top: page.texts[t].y * f,
                width: page.texts[t].width == null
                    ? null
                    : math.max(page.texts[t].width! * f, 8),
                child: Container(
                  color: hits.contains(t)
                      ? (t == active ? findActiveColor(b) : findMatchColor(b))
                      : null,
                  child: Text(
                    page.texts[t].text,
                    style: TextStyle(
                      fontSize: page.texts[t].size * f,
                      height: 1.2,
                      color: Color(page.texts[t].color),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.page, this.f);
  final InkPage page;
  final double f;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(f);
    _ruling(canvas);
    for (final s in page.shapes) {
      final r = Rect.fromLTWH(s.x, s.y, s.w, s.h);
      final path = switch (s.kind) {
        InkShapeKind.rectangle =>
          Path()
            ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(4))),
        InkShapeKind.ellipse => Path()..addOval(r),
        InkShapeKind.diamond =>
          Path()
            ..moveTo(r.center.dx, r.top)
            ..lineTo(r.right, r.center.dy)
            ..lineTo(r.center.dx, r.bottom)
            ..lineTo(r.left, r.center.dy)
            ..close(),
      };
      if (s.fill != null) {
        canvas.drawPath(path, Paint()..color = Color(s.fill!));
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.width
          ..color = Color(s.stroke),
      );
    }
    for (final s in page.strokes) {
      final pts = s.points;
      if (pts.length < 4) continue;
      final color = Color(s.color);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = s.highlighter ? StrokeCap.square : StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = s.highlighter ? color.withValues(alpha: 0.45) : color
        ..strokeWidth = s.width;
      final widths = s.widths;
      if (widths != null && widths.isNotEmpty) {
        // Spessore variabile (pressione): un segmento alla volta.
        for (var i = 0; i + 3 < pts.length; i += 2) {
          final w = widths[math.min(i ~/ 2, widths.length - 1)];
          paint.strokeWidth = w;
          canvas.drawLine(
            Offset(pts[i], pts[i + 1]),
            Offset(pts[i + 2], pts[i + 3]),
            paint,
          );
        }
      } else {
        final path = Path()..moveTo(pts[0], pts[1]);
        for (var i = 2; i + 1 < pts.length; i += 2) {
          path.lineTo(pts[i], pts[i + 1]);
        }
        if (s.closed) path.close();
        canvas.drawPath(path, paint);
      }
    }
  }

  void _ruling(Canvas canvas) {
    final style = page.ruling;
    if (style == null || style == 'plain') return;
    final line = Paint()
      ..color = const Color(0x553A7BD5)
      ..strokeWidth = 0.5;
    const step = 24.0;
    switch (style) {
      case 'lined' || 'ruled':
        for (var y = 80.0; y < page.height; y += step) {
          canvas.drawLine(Offset(0, y), Offset(page.width, y), line);
        }
        if (style == 'lined') {
          canvas.drawLine(
            const Offset(72, 0),
            Offset(72, page.height),
            Paint()
              ..color = const Color(0x66FF4040)
              ..strokeWidth = 0.6,
          );
        }
      case 'graph':
        for (var y = 0.0; y < page.height; y += 14.17) {
          canvas.drawLine(Offset(0, y), Offset(page.width, y), line);
        }
        for (var x = 0.0; x < page.width; x += 14.17) {
          canvas.drawLine(Offset(x, 0), Offset(x, page.height), line);
        }
      case 'dotted':
        // pagina enorme (file rovinato): niente milioni di punti a ogni disegno
        if (page.width * page.height > 4e7) return;
        final dot = Paint()..color = const Color(0x803A7BD5);
        for (var y = 14.17; y < page.height; y += 14.17) {
          for (var x = 14.17; x < page.width; x += 14.17) {
            canvas.drawCircle(Offset(x, y), 0.7, dot);
          }
        }
    }
  }

  @override
  bool shouldRepaint(_InkPainter old) => old.page != page || old.f != f;
}
