import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../reader_document.dart' show parseFinite;
import 'zip_util.dart' show XmlLocal;

/// Appunti a mano libera: Xournal++ (.xopp, XML compresso con gzip) ed
/// Excalidraw (.excalidraw, JSON). Tratti, forme, testi (cercabili) e
/// immagini, su pagine da disegnare.

class InkStroke {
  InkStroke(
    this.points, {
    required this.color,
    required this.width,
    this.widths,
    this.highlighter = false,
    this.closed = false,
  });

  /// Coppie x, y.
  final List<double> points;

  /// Colore ARGB.
  final int color;
  final double width;

  /// Spessore per segmento (pressione), se presente.
  final List<double>? widths;
  final bool highlighter;
  final bool closed;
}

enum InkShapeKind { rectangle, ellipse, diamond }

/// Coordinata finita (i file rovinati possono dare NaN o infinito, che
/// romperebbero l'impaginazione della pagina).
double _finite(double v, [double fallback = 0]) =>
    v.isFinite ? v.clamp(-1e7, 1e7).toDouble() : fallback;

class InkShape {
  InkShape(
    this.kind,
    double x,
    double y,
    double w,
    double h, {
    required this.stroke,
    this.fill,
    this.width = 1,
  }) : x = _finite(x),
       y = _finite(y),
       w = _finite(w),
       h = _finite(h);
  final InkShapeKind kind;
  final double x;
  final double y;
  final double w;
  final double h;
  final int stroke;
  final int? fill;
  final double width;
}

class InkText {
  InkText(
    double x,
    double y,
    this.text, {
    double size = 12,
    this.color = 0xFF000000,
    double? width,
  }) : x = _finite(x),
       y = _finite(y),
       // corpo del testo valido per Flutter (> 0, finito, non enorme)
       size = size.isFinite && size > 0 ? math.min(size, 2000) : 12,
       width = width == null || !width.isFinite ? null : width.abs();
  final double x;
  final double y;
  final String text;
  final double size;
  final int color;

  /// Larghezza della casella, se nota.
  final double? width;
}

class InkImage {
  InkImage(double left, double top, double right, double bottom, this.bytes)
    : left = _finite(left),
      top = _finite(top),
      right = _finite(right),
      bottom = _finite(bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;
  final Uint8List bytes;
}

class InkPage {
  /// Le dimensioni restano tra 1 e 100000 punti: con 0, negative, NaN o
  /// miliardi (file rovinati) la pagina non si impagina o la rigatura
  /// chiederebbe miliardi di linee.
  InkPage(
    double width,
    double height, {
    this.background = 0xFFFFFFFF,
    this.ruling,
  }) : width = _dim(width, 595),
       height = _dim(height, 842);

  static double _dim(double v, double fallback) =>
      v.isFinite && v > 0 ? v.clamp(1, 100000).toDouble() : fallback;

  final double width;
  final double height;
  final int background;

  /// Rigatura dello sfondo Xournal++ ("lined", "ruled", "graph", "dotted").
  final String? ruling;
  final strokes = <InkStroke>[];
  final shapes = <InkShape>[];
  final texts = <InkText>[];
  final images = <InkImage>[];

  /// Testo cercabile della pagina.
  String get plainText => texts.map((t) => t.text).join('\n');
}

class InkDoc {
  InkDoc(this.pages, {this.notice});
  final List<InkPage> pages;
  final String? notice;
}

/// Colore Xournal++: "#RRGGBBAA" o nome.
int xoppColor(String? c, {int fallback = 0xFF000000}) {
  if (c == null) return fallback;
  const names = {
    'black': 0xFF000000,
    'blue': 0xFF3333CC,
    'red': 0xFFFF0000,
    'green': 0xFF008000,
    'gray': 0xFF808080,
    'lightblue': 0xFF00C0FF,
    'lightgreen': 0xFF00FF00,
    'magenta': 0xFFFF00FF,
    'orange': 0xFFFF8000,
    'yellow': 0xFFFFFF00,
    'white': 0xFFFFFFFF,
  };
  final n = names[c.toLowerCase()];
  if (n != null) return n;
  final hex = c.replaceFirst('#', '');
  final v = int.tryParse(hex, radix: 16);
  if (v == null) return fallback;
  if (hex.length == 8) {
    return ((v & 0xFF) << 24) | (v >> 8); // RRGGBBAA → AARRGGBB
  }
  if (hex.length == 6) return 0xFF000000 | v;
  return fallback;
}

/// Xournal++ / Xournal (.xopp, .xoj).
InkDoc parseXopp(Uint8List bytes) {
  final raw = bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B
      ? GZipDecoder().decodeBytes(bytes)
      : bytes;
  final doc = XmlDocument.parse(utf8.decode(raw, allowMalformed: true));
  final pages = <InkPage>[];
  var pdfBackground = false;
  for (final p in doc.rootElement.kids('page')) {
    final bg = p.kid('background');
    final type = bg?.attr('type');
    if (type == 'pdf') pdfBackground = true;
    final page = InkPage(
      parseFinite(p.attr('width') ?? '') ?? 595,
      parseFinite(p.attr('height') ?? '') ?? 842,
      background: type == 'solid'
          ? xoppColor(bg?.attr('color'), fallback: 0xFFFFFFFF)
          : 0xFFFFFFFF,
      ruling: type == 'solid' ? bg?.attr('style') : null,
    );
    for (final layer in p.kids('layer')) {
      for (final e in layer.childElements) {
        switch (e.local) {
          case 'stroke':
            final nums = e.innerText
                .trim()
                .split(RegExp(r'\s+'))
                .map(parseFinite)
                .whereType<double>()
                .toList();
            final ws = (e.attr('width') ?? '1')
                .trim()
                .split(RegExp(r'\s+'))
                .map(parseFinite)
                .whereType<double>()
                .toList();
            if (nums.length < 2) continue;
            page.strokes.add(
              InkStroke(
                nums.length.isOdd ? nums.sublist(0, nums.length - 1) : nums,
                color: xoppColor(e.attr('color')),
                width: ws.isEmpty ? 1 : ws.first,
                widths: ws.length > 1 ? ws.sublist(1) : null,
                highlighter: e.attr('tool') == 'highlighter',
              ),
            );
          case 'text':
            page.texts.add(
              InkText(
                parseFinite(e.attr('x') ?? '') ?? 0,
                parseFinite(e.attr('y') ?? '') ?? 0,
                e.innerText,
                size: parseFinite(e.attr('size') ?? '') ?? 12,
                color: xoppColor(e.attr('color')),
              ),
            );
          case 'image':
            try {
              page.images.add(
                InkImage(
                  parseFinite(e.attr('left')) ?? 0,
                  parseFinite(e.attr('top')) ?? 0,
                  parseFinite(e.attr('right')) ?? 0,
                  parseFinite(e.attr('bottom')) ?? 0,
                  base64Decode(e.innerText.replaceAll(RegExp(r'\s'), '')),
                ),
              );
            } catch (_) {}
          case 'teximage':
            final t = e.attr('text');
            if (t != null) {
              page.texts.add(
                InkText(
                  parseFinite(e.attr('left') ?? '') ?? 0,
                  parseFinite(e.attr('top') ?? '') ?? 0,
                  t,
                ),
              );
            }
        }
      }
    }
    pages.add(page);
  }
  return InkDoc(
    pages,
    notice: pdfBackground
        ? 'Lo sfondo PDF annotato non è incluso nel file .xopp: sono mostrate solo le annotazioni.'
        : null,
  );
}

int _cssColor(Object? c, {int? fallback}) {
  final s = c?.toString().trim().toLowerCase() ?? '';
  if (s.isEmpty || s == 'transparent') return fallback ?? 0;
  if (s.startsWith('#')) {
    final hex = s.substring(1);
    if (hex.length == 3) {
      return 0xFF000000 |
          int.parse(hex.split('').map((c) => '$c$c').join(), radix: 16);
    }
    if (hex.length == 6) return 0xFF000000 | int.parse(hex, radix: 16);
    if (hex.length == 8) return xoppColor(s);
  }
  return fallback ?? 0xFF1E1E1E;
}

/// Excalidraw (.excalidraw, .excalidraw.json): una pagina che contiene
/// tutti gli elementi.
InkDoc parseExcalidraw(Uint8List bytes) {
  final json = jsonDecode(
    utf8.decode(bytes, allowMalformed: true),
  ) as Map<String, dynamic>;
  final elements = (json['elements'] as List? ?? const [])
      .cast<Map>()
      .where((e) => e['isDeleted'] != true)
      .toList();
  final files = (json['files'] as Map?) ?? const {};
  double n(Object? v) => (v as num?)?.toDouble() ?? 0;
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final e in elements) {
    final x = n(e['x']), y = n(e['y']);
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x + n(e['width']));
    maxY = math.max(maxY, y + n(e['height']));
  }
  if (elements.isEmpty) {
    minX = minY = 0;
    maxX = 800;
    maxY = 600;
  }
  const pad = 20.0;
  final ox = minX - pad, oy = minY - pad;
  final bg = _cssColor(
    json['appState'] is Map
        ? (json['appState'] as Map)['viewBackgroundColor']
        : null,
    fallback: 0xFFFFFFFF,
  );
  final page = InkPage(
    maxX - minX + 2 * pad,
    maxY - minY + 2 * pad,
    background: bg == 0 ? 0xFFFFFFFF : bg,
  );
  var rotated = false;
  for (final e in elements) {
    final x = n(e['x']) - ox, y = n(e['y']) - oy;
    final w = n(e['width']), h = n(e['height']);
    final stroke = _cssColor(e['strokeColor'], fallback: 0xFF1E1E1E);
    final fill = _cssColor(e['backgroundColor']);
    final sw = n(e['strokeWidth']) == 0 ? 1.0 : n(e['strokeWidth']);
    if (n(e['angle']) != 0) rotated = true;
    switch (e['type']) {
      case 'rectangle' || 'frame' || 'embeddable':
        page.shapes.add(
          InkShape(
            InkShapeKind.rectangle,
            x,
            y,
            w,
            h,
            stroke: stroke,
            fill: fill == 0 ? null : fill,
            width: sw,
          ),
        );
      case 'ellipse':
        page.shapes.add(
          InkShape(
            InkShapeKind.ellipse,
            x,
            y,
            w,
            h,
            stroke: stroke,
            fill: fill == 0 ? null : fill,
            width: sw,
          ),
        );
      case 'diamond':
        page.shapes.add(
          InkShape(
            InkShapeKind.diamond,
            x,
            y,
            w,
            h,
            stroke: stroke,
            fill: fill == 0 ? null : fill,
            width: sw,
          ),
        );
      case 'line' || 'arrow' || 'freedraw':
        final pts = <double>[];
        for (final p in (e['points'] as List? ?? const [])) {
          final l = p as List;
          pts
            ..add(x + (l[0] as num).toDouble())
            ..add(y + (l[1] as num).toDouble());
        }
        if (pts.length >= 4) {
          page.strokes.add(
            InkStroke(
              pts,
              color: stroke,
              width: e['type'] == 'freedraw' ? sw * 1.5 : sw,
            ),
          );
          if (e['type'] == 'arrow') {
            // Punta della freccia.
            final l = pts.length;
            final ang = math.atan2(
              pts[l - 1] - pts[l - 3],
              pts[l - 2] - pts[l - 4],
            );
            const len = 14.0;
            for (final d in [-0.45, 0.45]) {
              page.strokes.add(
                InkStroke(
                  [
                    pts[l - 2],
                    pts[l - 1],
                    pts[l - 2] - len * math.cos(ang + d),
                    pts[l - 1] - len * math.sin(ang + d),
                  ],
                  color: stroke,
                  width: sw,
                ),
              );
            }
          }
        }
      case 'text':
        final t = (e['text'] ?? e['originalText'] ?? '').toString();
        page.texts.add(
          InkText(
            x,
            y,
            t,
            size: n(e['fontSize']) == 0 ? 20 : n(e['fontSize']),
            color: stroke,
            width: w,
          ),
        );
      case 'image':
        final f = files[e['fileId']];
        final url = f is Map ? f['dataURL']?.toString() : null;
        final comma = url?.indexOf(',') ?? -1;
        if (url != null && comma > 0) {
          try {
            page.images.add(
              InkImage(
                x,
                y,
                x + w,
                y + h,
                base64Decode(url.substring(comma + 1)),
              ),
            );
          } catch (_) {}
        }
    }
  }
  return InkDoc(
    [page],
    notice: rotated
        ? 'Gli elementi ruotati sono mostrati senza rotazione.'
        : null,
  );
}
