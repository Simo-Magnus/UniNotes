import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../reader_document.dart';

/// Tratti di un testo della diapositiva: [index] è la posizione del testo
/// in [RSlide.texts] (per evidenziare la ricerca), [styles] lo stile di
/// ogni tratto.
typedef SlideSpans =
    List<InlineSpan> Function(
      int index,
      List<RSpan> spans,
      List<TextStyle> styles,
    );

/// Tratti con la formattazione di base (grassetto, corsivo, ...), senza
/// ricerca.
List<InlineSpan> plainSlideSpans(
  int index,
  List<RSpan> spans,
  List<TextStyle> styles,
) => [
  for (var k = 0; k < spans.length; k++)
    TextSpan(
      text: spans[k].text,
      style: styles[k].copyWith(
        fontWeight: spans[k].bold ? FontWeight.w700 : null,
        fontStyle: spans[k].italic ? FontStyle.italic : null,
        decoration: TextDecoration.combine([
          if (spans[k].underline || spans[k].link != null)
            TextDecoration.underline,
          if (spans[k].strike) TextDecoration.lineThrough,
        ]),
      ),
    ),
];

/// Diapositiva disegnata alla larghezza [width]: sfondo, forme, immagini,
/// tabelle e testi nelle posizioni dell'originale. I colori sono quelli
/// della presentazione (non del tema dell'app).
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({
    super.key,
    required this.slide,
    required this.width,
    this.spans = plainSlideSpans,
    this.keyOf,
  });

  final RSlide slide;
  final double width;
  final SlideSpans spans;

  /// Chiave del testo [index] (il risultato attivo della ricerca).
  final Key? Function(int index)? keyOf;

  @override
  Widget build(BuildContext context) {
    final k = slide.width <= 0 ? 1.0 : width / slide.width;
    final height = slide.height * k;
    var index = 0;
    final children = <Widget>[
      if (slide.backgroundImage != null)
        Positioned.fill(
          child: Image.memory(
            slide.backgroundImage!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
    ];
    for (final s in slide.shapes) {
      final first = index;
      index += s.paras.length;
      if (s.table != null) {
        for (final row in s.table!.cells) {
          index += row.length;
        }
      }
      children.add(_shape(s, k, first));
    }
    return Semantics(
      container: true,
      label: 'Diapositiva',
      child: Container(
        width: width,
        height: height,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: Color(slide.background),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Stack(clipBehavior: Clip.hardEdge, children: children),
      ),
    );
  }

  Widget _shape(RShape s, double k, int firstText) {
    final w = math.max(s.w * k, 1.0);
    final h = math.max(s.h * k, 1.0);
    final layers = <Widget>[];
    final drawn = s.fill != null || s.line != null;
    Widget flip(Widget child) => (s.flipH || s.flipV)
        ? Transform.flip(flipX: s.flipH, flipY: s.flipV, child: child)
        : child;
    if (drawn && s.table == null) {
      layers.add(
        Positioned.fill(
          child: flip(
            CustomPaint(
              painter: _GeometryPainter(
                geometry: s.geometry,
                adjust: s.adjust,
                path: s.path,
                fill: s.fill == null ? null : Color(s.fill!),
                line: s.line == null ? null : Color(s.line!),
                lineWidth: math.max(s.lineWidth * k, 0.5),
              ),
            ),
          ),
        ),
      );
    }
    if (s.image != null) {
      layers.add(Positioned.fill(child: flip(_image(s, w, h))));
    }
    if (s.label != null) {
      layers.add(Positioned.fill(child: _label(s.label!, k)));
    }
    if (s.table != null) {
      layers.add(Positioned.fill(child: _table(s, k, firstText + s.paras.length)));
    }
    if (s.paras.isNotEmpty) {
      layers.add(Positioned.fill(child: _text(s, k, firstText)));
    }
    Widget box = SizedBox(
      width: w,
      height: h,
      child: Stack(clipBehavior: Clip.none, children: layers),
    );
    if (s.rotation != 0) {
      box = Transform.rotate(angle: s.rotation * math.pi / 180, child: box);
    }
    return Positioned(left: s.x * k, top: s.y * k, width: w, height: h, child: box);
  }

  Widget _image(RShape s, double w, double h) {
    final l = s.crop[0], t = s.crop[1], r = s.crop[2], b = s.crop[3];
    final iw = w / math.max(0.05, 1 - l - r);
    final ih = h / math.max(0.05, 1 - t - b);
    Widget img = Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: -l * iw,
          top: -t * ih,
          width: iw,
          height: ih,
          child: Image.memory(
            s.image!,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
    switch (s.geometry) {
      case 'ellipse':
        img = ClipOval(child: img);
      case 'roundRect':
        img = ClipRRect(
          borderRadius: BorderRadius.circular(math.min(w, h) * 0.1667),
          child: img,
        );
      default:
        img = ClipRect(child: img);
    }
    return img;
  }

  Widget _label(String label, double k) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFFF1F5F9),
      border: Border.all(color: const Color(0xFF94A3B8)),
    ),
    alignment: Alignment.center,
    padding: EdgeInsets.all(6 * k),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label.startsWith('Grafico')
                ? Icons.bar_chart
                : Icons.image_not_supported_outlined,
            size: math.max(16 * k, 10),
            color: const Color(0xFF475569),
          ),
          SizedBox(width: 6 * k),
          Text(
            label,
            style: TextStyle(
              fontSize: math.max(16 * k, 8),
              color: const Color(0xFF475569),
            ),
          ),
        ],
      ),
    ),
  );

  List<Widget> _paras(List<RSlidePara> paras, double k, int firstText) {
    final out = <Widget>[];
    for (var i = 0; i < paras.length; i++) {
      final p = paras[i];
      final idx = firstText + i;
      final lineHeight = 1.2 * p.lineSpacing;
      final top = i == 0 ? 0.0 : p.spaceBefore * k;
      if (p.runs.isEmpty || p.text.isEmpty) {
        out.add(SizedBox(height: top + p.size * k * lineHeight));
        continue;
      }
      final styles = [
        for (final r in p.runs)
          TextStyle(
            fontSize: math.max(r.size * k, 1),
            height: lineHeight,
            color: Color(r.color ?? 0xFF000000),
          ),
      ];
      final align = switch (p.align) {
        RAlign.center => TextAlign.center,
        RAlign.right => TextAlign.right,
        RAlign.justify => TextAlign.justify,
        RAlign.left => TextAlign.left,
      };
      Widget text = Text.rich(
        key: keyOf?.call(idx),
        TextSpan(children: spans(idx, [for (final r in p.runs) r.span], styles)),
        textAlign: align,
      );
      final bullet = p.bullet;
      if (bullet != null) {
        final style = styles.first.copyWith(
          color: Color(p.bulletColor ?? p.runs.first.color ?? 0xFF000000),
        );
        final hang = p.hanging > 0 ? p.hanging * k : styles.first.fontSize! * 1.1;
        text = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: hang, child: Text(bullet, style: style)),
            Expanded(child: text),
          ],
        );
      }
      final left = math.max(0.0, (p.indent - p.hanging) * k);
      out.add(
        Padding(
          padding: EdgeInsets.only(top: top, left: left),
          child: text,
        ),
      );
    }
    return out;
  }

  Widget _text(RShape s, double k, int firstText) {
    final ins = s.insets;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ins[0] * k,
        ins[1] * k,
        ins[2] * k,
        ins[3] * k,
      ),
      child: OverflowBox(
        minHeight: 0,
        maxHeight: double.infinity,
        alignment: switch (s.anchor) {
          RAnchor.top => Alignment.topCenter,
          RAnchor.middle => Alignment.center,
          RAnchor.bottom => Alignment.bottomCenter,
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _paras(s.paras, k, firstText),
        ),
      ),
    );
  }

  Widget _table(RShape s, double k, int firstText) {
    final t = s.table!;
    final total = t.columns.fold(0.0, (a, b) => a + b);
    // larghezze adattate al riquadro della tabella
    final f = total <= 0 ? 1.0 : s.w / total;
    final border = BorderSide(
      color: Color(s.line ?? 0xFF000000),
      width: math.max(1 * k, 0.5),
    );
    var idx = firstText;
    final rows = <Widget>[];
    for (var r = 0; r < t.cells.length; r++) {
      final cells = <Widget>[];
      var col = 0;
      for (final c in t.cells[r]) {
        var cw = 0.0;
        for (var j = 0; j < c.span && col + j < t.columns.length; j++) {
          cw += t.columns[col + j];
        }
        if (cw == 0) cw = total / math.max(1, t.columns.length);
        col += c.span;
        final first = idx;
        idx++;
        cells.add(
          Container(
            width: cw * f * k,
            constraints: BoxConstraints(
              minHeight: r < t.rows.length ? t.rows[r] * k : 0,
            ),
            padding: EdgeInsets.fromLTRB(7.2 * k, 3.6 * k, 7.2 * k, 3.6 * k),
            decoration: BoxDecoration(
              color: c.fill == null ? null : Color(c.fill!),
              border: Border(right: border, bottom: border),
            ),
            child: Text.rich(
              key: keyOf?.call(first),
              TextSpan(
                children: [
                  for (var pi = 0; pi < c.paras.length; pi++) ...[
                    if (pi > 0) const TextSpan(text: '\n'),
                    ..._cellSpans(c.paras[pi], k, first),
                  ],
                ],
              ),
              textAlign: c.paras.isEmpty
                  ? TextAlign.left
                  : switch (c.paras.first.align) {
                      RAlign.center => TextAlign.center,
                      RAlign.right => TextAlign.right,
                      _ => TextAlign.left,
                    },
            ),
          ),
        );
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    return OverflowBox(
      minHeight: 0,
      maxHeight: double.infinity,
      alignment: Alignment.topLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: border, left: border)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  /// Una cella è un solo testo per la ricerca: i suoi paragrafi si
  /// uniscono con un a capo (come in [RSlideCell.text]).
  List<InlineSpan> _cellSpans(RSlidePara p, double k, int index) {
    final styles = [
      for (final r in p.runs)
        TextStyle(
          fontSize: math.max(r.size * k, 1),
          height: 1.2,
          color: Color(r.color ?? 0xFF000000),
        ),
    ];
    return plainSlideSpans(index, [for (final r in p.runs) r.span], styles);
  }
}

/// Forma predefinita o a mano libera, con riempimento e contorno.
class _GeometryPainter extends CustomPainter {
  _GeometryPainter({
    required this.geometry,
    required this.adjust,
    required this.path,
    required this.fill,
    required this.line,
    required this.lineWidth,
  });

  final String geometry;
  final double? adjust;
  final List<List<RPathCmd>>? path;
  final Color? fill;
  final Color? line;
  final double lineWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final p = slideGeometry(geometry, size, path, adjust);
    final isLine = geometry == 'line' ||
        geometry.contains('Connector') ||
        geometry == 'arc';
    if (fill != null && !isLine) {
      canvas.drawPath(p, Paint()..color = fill!);
    }
    if (line != null) {
      canvas.drawPath(
        p,
        Paint()
          ..color = line!
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_GeometryPainter old) =>
      old.geometry != geometry ||
      old.adjust != adjust ||
      old.fill != fill ||
      old.line != line ||
      old.lineWidth != lineWidth ||
      old.path != path;
}

/// Tracciato di una forma di PowerPoint nel riquadro [s] con la
/// regolazione [adj] (le forme non riconosciute diventano rettangoli).
Path slideGeometry(
  String g,
  Size s, [
  List<List<RPathCmd>>? custom,
  double? adj,
]) {
  final w = s.width, h = s.height;
  Path poly(List<double> xy) {
    final p = Path()..moveTo(xy[0] * w, xy[1] * h);
    for (var i = 2; i + 1 < xy.length; i += 2) {
      p.lineTo(xy[i] * w, xy[i + 1] * h);
    }
    return p..close();
  }

  if (custom != null) {
    final p = Path();
    for (final sub in custom) {
      for (final c in sub) {
        final q = c.points;
        switch (c.op) {
          case 0:
            p.moveTo(q[0] * w, q[1] * h);
          case 1:
            p.lineTo(q[0] * w, q[1] * h);
          case 2:
            p.cubicTo(q[0] * w, q[1] * h, q[2] * w, q[3] * h, q[4] * w, q[5] * h);
          case 3:
            p.close();
        }
      }
    }
    return p;
  }
  final m = math.min(w, h);
  switch (g) {
    case 'roundRect' || 'flowChartAlternateProcess':
      final r = m * (adj ?? 0.16667).clamp(0.0, 0.5);
      return Path()
        ..addRRect(RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(r)));
    case 'flowChartTerminator':
      return Path()..addRRect(
        RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(m / 2)),
      );
    case 'ellipse' || 'flowChartConnector' || 'cloud' || 'donut':
      return Path()..addOval(Offset.zero & s);
    case 'line' || 'straightConnector1' || 'bentConnector2' ||
        'bentConnector3' || 'curvedConnector3':
      return Path()
        ..moveTo(0, 0)
        ..lineTo(w, h);
    case 'triangle' || 'flowChartExtract':
      return poly([(adj ?? 0.5).clamp(0.0, 1.0), 0, 1, 1, 0, 1]);
    case 'rtTriangle':
      return poly([0, 0, 1, 1, 0, 1]);
    case 'diamond' || 'flowChartDecision':
      return poly([0.5, 0, 1, 0.5, 0.5, 1, 0, 0.5]);
    case 'parallelogram' || 'flowChartInputOutput':
      final a = math.min(0.9, (adj ?? 0.25) * m / w);
      return poly([a, 0, 1, 0, 1 - a, 1, 0, 1]);
    case 'trapezoid':
      final a = math.min(0.5, (adj ?? 0.25) * m / w);
      return poly([a, 0, 1 - a, 0, 1, 1, 0, 1]);
    case 'homePlate':
      final a = 1.0 - math.min(1.0, (adj ?? 0.5) * m / w);
      return poly([0, 0, a, 0, 1, 0.5, a, 1, 0, 1]);
    case 'chevron':
      final a = math.min(0.5, (adj ?? 0.5) * m / w);
      return poly([0, 0, 1 - a, 0, 1, 0.5, 1 - a, 1, 0, 1, a, 0.5]);
    case 'pentagon':
      return poly([0.5, 0, 1, 0.38, 0.81, 1, 0.19, 1, 0, 0.38]);
    case 'hexagon':
      final a = math.min(0.5, (adj ?? 0.25) * m / w);
      return poly([a, 0, 1 - a, 0, 1, 0.5, 1 - a, 1, a, 1, 0, 0.5]);
    case 'octagon':
      final ax = 0.29 * m / w, ay = 0.29 * m / h;
      return poly([
        ax, 0, 1 - ax, 0, 1, ay, 1, 1 - ay, 1 - ax, 1, ax, 1, 0, 1 - ay, 0, ay, //
      ]);
    case 'plus':
      final ax = 0.25 * m / w, ay = 0.25 * m / h;
      return poly([
        ax, 0, 1 - ax, 0, 1 - ax, ay, 1, ay, 1, 1 - ay, 1 - ax, 1 - ay, //
        1 - ax, 1, ax, 1, ax, 1 - ay, 0, 1 - ay, 0, ay, ax, ay,
      ]);
    case 'rightArrow':
      final a = 1.0 - math.min(1.0, 0.5 * h / w);
      return poly([0, 0.25, a, 0.25, a, 0, 1, 0.5, a, 1, a, 0.75, 0, 0.75]);
    case 'leftArrow':
      final a = math.min(1.0, 0.5 * h / w);
      return poly([1, 0.25, a, 0.25, a, 0, 0, 0.5, a, 1, a, 0.75, 1, 0.75]);
    case 'downArrow':
      final a = 1.0 - math.min(1.0, 0.5 * w / h);
      return poly([0.25, 0, 0.75, 0, 0.75, a, 1, a, 0.5, 1, 0, a, 0.25, a]);
    case 'upArrow':
      final a = math.min(1.0, 0.5 * w / h);
      return poly([0.25, 1, 0.75, 1, 0.75, a, 1, a, 0.5, 0, 0, a, 0.25, a]);
    case 'star5':
      final pts = <double>[];
      for (var i = 0; i < 10; i++) {
        final r = i.isEven ? 0.5 : 0.19;
        final a = -math.pi / 2 + i * math.pi / 5;
        pts
          ..add(0.5 + r * math.cos(a))
          ..add(0.5 + r * math.sin(a) * 1.05);
      }
      return poly(pts);
    default:
      return Path()..addRect(Offset.zero & s);
  }
}

/// Diapositiva a tutto schermo con zoom (pizzico, rotellina) e
/// trascinamento.
class SlideViewerPage extends StatelessWidget {
  const SlideViewerPage({super.key, required this.slide, required this.title});
  final RSlide slide;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF111111),
    appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
    body: LayoutBuilder(
      builder: (context, c) {
        final ratio = slide.height <= 0 ? 0.5625 : slide.height / slide.width;
        final w = math.min(c.maxWidth - 16, (c.maxHeight - 16) / ratio);
        return InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: SlideCanvas(slide: slide, width: math.max(w, 100)),
          ),
        );
      },
    ),
  );
}
