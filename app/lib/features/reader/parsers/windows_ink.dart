import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'ink.dart';
import 'zip_util.dart' show XmlLocal;

/// Inchiostro digitale di Windows: InkML (XML del W3C) e Ink Serialized
/// Format (ISF, binario, specifica pubblicata da Microsoft). Si riconosce
/// dal contenuto, non dall'estensione (.ink può essere l'uno o l'altro).

/// Compressione ISF non gestita (si mostra un messaggio e "Apri con…").
class UnsupportedInkException implements Exception {
  const UnsupportedInkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tratti con coordinate qualsiasi → una pagina che li contiene (con un
/// margine), spessori proporzionati alla pagina.
InkDoc _page(List<InkStroke> strokes, {String? notice}) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final s in strokes) {
    for (var i = 0; i + 1 < s.points.length; i += 2) {
      minX = math.min(minX, s.points[i]);
      maxX = math.max(maxX, s.points[i]);
      minY = math.min(minY, s.points[i + 1]);
      maxY = math.max(maxY, s.points[i + 1]);
    }
  }
  if (minX.isInfinite) {
    return InkDoc([InkPage(800, 600)], notice: notice ?? 'Nessun tratto.');
  }
  final w = math.max(1.0, maxX - minX), h = math.max(1.0, maxY - minY);
  final pad = math.max(w, h) * 0.04;
  final page = InkPage(w + 2 * pad, h + 2 * pad);
  final fallback = math.max(w, h) / 300;
  for (final s in strokes) {
    final pts = [
      for (var i = 0; i + 1 < s.points.length; i += 2) ...[
        s.points[i] - minX + pad,
        s.points[i + 1] - minY + pad,
      ],
    ];
    if (pts.length == 2) pts.addAll([pts[0] + fallback / 2, pts[1]]);
    var width = s.width;
    if (width <= 0 || width > math.max(w, h) / 10) width = fallback;
    page.strokes.add(
      InkStroke(pts, color: s.color, width: width, highlighter: s.highlighter),
    );
  }
  return InkDoc([page], notice: notice);
}

/// .ink, .isf, .inkml: InkML se il file è XML, altrimenti ISF (anche in
/// base64).
InkDoc parseWindowsInk(Uint8List bytes) {
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  while (start < bytes.length &&
      (bytes[start] == 0x20 ||
          bytes[start] == 0x0A ||
          bytes[start] == 0x0D ||
          bytes[start] == 0x09)) {
    start++;
  }
  if (start < bytes.length && bytes[start] == 0x3C) {
    return parseInkml(utf8.decode(bytes.sublist(start), allowMalformed: true));
  }
  final head = String.fromCharCodes(bytes.take(7));
  if (head == 'base64:') {
    return parseIsf(
      base64Decode(
        String.fromCharCodes(bytes.sublist(7)).replaceAll(RegExp(r'\s'), ''),
      ),
    );
  }
  return parseIsf(bytes);
}

// ---------------------------------------------------------------- InkML

int _cssHex(String? v, int fallback) {
  if (v == null) return fallback;
  var s = v.trim();
  if (s.startsWith('#')) s = s.substring(1);
  final n = int.tryParse(s, radix: 16);
  if (n == null) return fallback;
  if (s.length == 6) return 0xFF000000 | n;
  if (s.length == 8) return n; // AARRGGBB (Windows Ink)
  return fallback;
}

/// InkML (W3C): tracce con punti "x y, x y, …", anche come differenze
/// prime (') e seconde ("), pennelli con colore e spessore.
InkDoc parseInkml(String source) {
  final doc = XmlDocument.parse(source);
  final root = doc.rootElement;
  final brushes = <String, ({int color, double width, bool hl})>{};
  for (final b in root.desc('brush')) {
    final id = b.attr('id');
    if (id == null) continue;
    var color = 0xFF000000;
    var width = 0.0;
    var hl = false;
    for (final p in b.desc('brushProperty')) {
      final name = (p.attr('name') ?? '').toLowerCase();
      final value = p.attr('value');
      switch (name) {
        case 'color':
          color = _cssHex(value, color);
        case 'width':
          width = double.tryParse(value ?? '') ?? width;
        case 'transparency':
          final t = int.tryParse(value ?? '') ?? 0;
          color = (color & 0x00FFFFFF) | ((255 - t.clamp(0, 255)) << 24);
        case 'tip':
          hl = hl || value == 'rectangle';
        case 'rasterop':
          hl = hl || (value ?? '').toLowerCase().contains('mask');
      }
    }
    brushes[id] = (color: color, width: width, hl: hl);
  }
  // Canali delle tracce (di solito X Y, poi pressione o tempo).
  var channels = <String>['X', 'Y'];
  final tf = root.firstDesc('traceFormat');
  if (tf != null) {
    final names = [for (final c in tf.desc('channel')) c.attr('name') ?? ''];
    if (names.isNotEmpty) channels = names;
  }
  final ix = channels.indexOf('X'), iy = channels.indexOf('Y');
  final xi = ix < 0 ? 0 : ix, yi = iy < 0 ? 1 : iy;
  final token = RegExp(
    r"""[!'"]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|[TF?*]""",
  );
  final strokes = <InkStroke>[];
  String? brushOf(XmlElement e) {
    for (XmlNode? n = e; n is XmlElement; n = n.parent) {
      final r = n.attr('brushRef');
      if (r != null) return r.replaceFirst('#', '');
    }
    return null;
  }

  for (final t in root.desc('trace')) {
    final n = channels.length;
    final value = List<double>.filled(n, 0);
    final velocity = List<double>.filled(n, 0);
    final mode = List<int>.filled(
      n,
      0,
    ); // 0 esplicito, 1 diff., 2 diff. seconda
    final pts = <double>[];
    for (final point in t.innerText.split(',')) {
      if (point.trim().isEmpty) continue;
      var ch = 0;
      var pending = -1;
      for (final m in token.allMatches(point)) {
        final tok = m.group(0)!;
        if (tok == '!' || tok == "'" || tok == '"') {
          pending = tok == '!' ? 0 : (tok == "'" ? 1 : 2);
          continue;
        }
        if (ch >= n) break;
        if (pending >= 0) {
          mode[ch] = pending;
          pending = -1;
        }
        final v = double.tryParse(tok);
        if (v != null) {
          switch (mode[ch]) {
            case 0:
              velocity[ch] = v - value[ch];
              value[ch] = v;
            case 1:
              velocity[ch] = v;
              value[ch] += v;
            default:
              velocity[ch] += v;
              value[ch] += velocity[ch];
          }
        }
        ch++;
      }
      pts
        ..add(value[xi])
        ..add(value[yi]);
    }
    if (pts.isEmpty) continue;
    final brush = brushes[brushOf(t)];
    strokes.add(
      InkStroke(
        pts,
        color: brush?.color ?? 0xFF1E1E1E,
        width: brush?.width ?? 0,
        highlighter: brush?.hl ?? false,
      ),
    );
  }
  return _page(strokes);
}

// ------------------------------------------------------------------ ISF

/// Tabelle delle quantità di bit dei codici di Huffman predefiniti
/// dell'ISF (indice nei 5 bit bassi del byte di compressione).
const _huffBits = [
  [0, 1, 2, 4, 6, 8, 12, 16, 24, 32],
  [0, 1, 1, 2, 4, 8, 12, 16, 24, 32],
  [0, 1, 1, 1, 2, 4, 8, 14, 22, 32],
  [0, 2, 2, 3, 5, 8, 12, 16, 24, 32],
  [0, 3, 4, 5, 8, 12, 16, 24, 32],
  [0, 4, 6, 8, 12, 16, 24, 32],
  [0, 6, 8, 12, 16, 24, 32],
  [0, 7, 8, 12, 16, 24, 32],
];

class _Bits {
  _Bits(this.b, this.pos);
  final Uint8List b;
  int pos;
  int _bit = 0;

  int bit() {
    if (pos >= b.length) throw const FormatException('ISF: dati troncati');
    final v = (b[pos] >> (7 - _bit)) & 1;
    _bit++;
    if (_bit == 8) {
      _bit = 0;
      pos++;
    }
    return v;
  }

  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  /// Fine al byte successivo.
  int align() {
    if (_bit != 0) {
      _bit = 0;
      pos++;
    }
    return pos;
  }
}

class _IsfReader {
  _IsfReader(this.b);
  final Uint8List b;
  int pos = 0;

  int byte() {
    if (pos >= b.length) throw const FormatException('ISF: dati troncati');
    return b[pos++];
  }

  /// Intero senza segno a lunghezza variabile (7 bit per byte, prima i
  /// bit bassi).
  int mbuint() {
    var v = 0, shift = 0;
    while (true) {
      final c = byte();
      v |= (c & 0x7F) << shift;
      // oltre i 62 bit il valore diventerebbe negativo: con una lunghezza
      // negativa la lettura tornerebbe indietro e girerebbe per sempre
      if (v < 0 || shift > 56) {
        throw const FormatException('ISF: intero non valido');
      }
      if (c & 0x80 == 0) return v;
      shift += 7;
    }
  }

  /// Con segno: il bit basso è il segno.
  int mbsint() {
    final v = mbuint();
    return v & 1 != 0 ? -(v >> 1) : v >> 1;
  }

  /// Valori di una proprietà dei punti (X, Y, …): [count] interi.
  List<int> packets(int count) {
    final algo = byte();
    final delta = algo & 0x20 != 0;
    final out = List<int>.filled(count, 0);
    final r = _Bits(b, pos);
    if (algo & 0xC0 == 0x00) {
      // "Gorilla": ogni valore in [width] bit con segno.
      final width = algo & 0x1F;
      for (var i = 0; i < count && width > 0; i++) {
        var v = r.bits(width);
        if (v & (1 << (width - 1)) != 0) v -= 1 << width;
        out[i] = v;
      }
    } else if (algo & 0xC0 == 0x80) {
      final index = algo & 0x1F;
      if (index >= _huffBits.length) {
        throw const UnsupportedInkException(
          'Questo file ISF usa un codice di Huffman personalizzato, non '
          'supportato.',
        );
      }
      final bits = _huffBits[index];
      final mins = List<int>.filled(bits.length, 0);
      var lower = 1;
      for (var n = 1; n < bits.length; n++) {
        mins[n] = lower;
        lower += 1 << (bits[n] - 1);
      }
      for (var i = 0; i < count; i++) {
        var n = 0;
        while (r.bit() == 1) {
          n++;
          if (n > bits.length) throw const FormatException('ISF: codice');
        }
        if (n == 0) {
          out[i] = 0;
        } else if (n < bits.length) {
          final off = r.bits(bits[n]);
          final mag = (off >> 1) + mins[n];
          out[i] = off & 1 != 0 ? -mag : mag;
        } else {
          // Valore fuori tabella: 64 bit con segno nel bit basso.
          final off = r.bits(32) * 0x100000000 + r.bits(32);
          out[i] = off & 1 != 0 ? -(off >> 1) : off >> 1;
        }
      }
    } else {
      throw const UnsupportedInkException(
        'Questo file ISF usa una compressione dei punti non supportata.',
      );
    }
    pos = r.align();
    if (delta) {
      // Trasformazione "delta-delta": x[i] = d[i] + 2·x[i−1] − x[i−2].
      var p1 = 0, p2 = 0;
      for (var i = 0; i < count; i++) {
        final x = out[i] + 2 * p1 - p2;
        p2 = p1;
        p1 = x;
        out[i] = x;
      }
    }
    return out;
  }
}

class _Attrs {
  int color = 0xFF000000;
  double width = 53; // 2 pt circa in HIMETRIC
  bool highlighter = false;
}

const _tagColor = 68, _tagPenWidth = 69, _tagTransparency = 80, _tagRop = 87;

_Attrs _drawAttrs(_IsfReader r, int end) {
  final a = _Attrs();
  while (r.pos < end) {
    final tag = r.mbuint();
    switch (tag) {
      case _tagColor:
        final c = r.mbuint(); // 0x00BBGGRR
        a.color =
            (a.color & 0xFF000000) |
            ((c & 0xFF) << 16) |
            (c & 0xFF00) |
            ((c >> 16) & 0xFF);
      case _tagPenWidth:
        a.width = r.mbuint().toDouble();
      case _tagTransparency:
        final t = r.mbuint().clamp(0, 255);
        a.color = (a.color & 0x00FFFFFF) | ((255 - t) << 24);
      case _tagRop:
        a.highlighter = r.mbuint() == 9; // maschera: evidenziatore
      default:
        if (tag >= 100) {
          // Proprietà personalizzata: dimensione e dati.
          final n = r.mbuint();
          r.pos += n;
        } else {
          r.mbuint();
        }
    }
  }
  r.pos = end;
  return a;
}

/// Ink Serialized Format: tratti (X, Y) con gli attributi di disegno.
InkDoc parseIsf(Uint8List bytes) {
  final r = _IsfReader(bytes);
  if (r.mbuint() != 0) throw const FormatException('ISF: versione sconosciuta');
  final size = r.mbuint();
  final end = math.min(bytes.length, r.pos + size);
  final attrs = <_Attrs>[];
  var current = 0;
  final strokes = <InkStroke>[];
  var noX = false, noY = false;
  while (r.pos < end) {
    final tag = r.mbuint();
    switch (tag) {
      case 0: // INK_SPACE_RECT
        for (var i = 0; i < 4; i++) {
          r.mbsint();
        }
      case 2: // DRAW_ATTRS_TABLE
        final tn = r.mbuint();
        final tableEnd = math.min(end, r.pos + tn);
        while (r.pos < tableEnd) {
          final n = r.mbuint();
          attrs.add(_drawAttrs(r, r.pos + n));
        }
        r.pos = tableEnd;
      case 3: // DRAW_ATTRS_BLOCK
        final n = r.mbuint();
        attrs.add(_drawAttrs(r, r.pos + n));
      case 7:
        noX = true;
      case 8:
        noY = true;
      case 9 || 13 || 23 || 26: // DIDX, SIDX, TIDX, MIDX
        final v = r.mbuint();
        if (tag == 9) current = v;
      case 10: // STROKE
        final n = r.mbuint();
        final sEnd = r.pos + n;
        final count = r.mbuint();
        // ogni punto occupa almeno un bit (anche nel codice di Huffman):
        // un conteggio più grande dei dati è un file rovinato, e chiederebbe
        // liste di miliardi di elementi
        if (count > (math.min(sEnd, bytes.length) - r.pos) * 8 + 64) {
          throw const FormatException('ISF: numero di punti non valido');
        }
        final xs = noX ? List<int>.filled(count, 0) : r.packets(count);
        final ys = noY ? List<int>.filled(count, 0) : r.packets(count);
        r.pos = sEnd;
        final a = current < attrs.length ? attrs[current] : _Attrs();
        strokes.add(
          InkStroke(
            [
              for (var i = 0; i < count; i++) ...[
                xs[i].toDouble(),
                ys[i].toDouble(),
              ],
            ],
            color: a.color,
            width: a.width,
            highlighter: a.highlighter,
          ),
        );
      case 16: // TRANSFORM: 6 float
        r.pos += 24;
      case 17: // TRANSFORM_ISOTROPIC_SCALE
        r.pos += 4;
      case 18 || 20: // scala anisotropa, traslazione
        r.pos += 8;
      case 19: // TRANSFORM_ROTATE
        r.mbuint();
      case 21: // TRANSFORM_SCALE_AND_TRANSLATE
        r.pos += 16;
      default:
        // Tutti gli altri blocchi: dimensione e contenuto.
        final n = r.mbuint();
        r.pos += n;
    }
  }
  return _page(strokes);
}
