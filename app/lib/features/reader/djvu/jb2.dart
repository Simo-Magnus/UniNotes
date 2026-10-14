/// Immagini bitonali JB2 dei file DjVu (blocchi Sjbz e dizionari Djbz),
/// dalla specifica DjVu v3, appendice 2: record codificati con lo
/// ZP-Coder, simboli codificati direttamente o per raffinamento di un
/// simbolo della libreria, posizioni relative alla riga di testo.
library;

import 'dart:typed_data';

import 'zp_decoder.dart';

/// Forma (simbolo) bitonale: righe dall'alto, un byte per pixel, con un
/// bordo bianco di [pad] pixel su ogni lato (niente controlli ai bordi).
class Jb2Shape {
  Jb2Shape(this.width, this.height)
    : bits = Uint8List((width + 2 * pad) * (height + 2 * pad));

  static const pad = 2;
  final int width;
  final int height;
  final Uint8List bits;

  int get stride => width + 2 * pad;

  /// Indice del pixel (x, y) (anche nel bordo, da −2).
  int at(int x, int y) => (y + pad) * stride + x + pad;

  int pixel(int x, int y) {
    if (x < -pad || y < -pad || x >= width + pad || y >= height + pad) {
      return 0;
    }
    return bits[at(x, y)];
  }

  /// Copia senza righe e colonne vuote ai bordi (per la libreria).
  Jb2Shape trimmed() {
    var x0 = width, y0 = height, x1 = -1, y1 = -1;
    for (var y = 0; y < height; y++) {
      final row = at(0, y);
      for (var x = 0; x < width; x++) {
        if (bits[row + x] != 0) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
    }
    if (x1 < 0) return Jb2Shape(0, 0);
    if (x0 == 0 && y0 == 0 && x1 == width - 1 && y1 == height - 1) return this;
    final out = Jb2Shape(x1 - x0 + 1, y1 - y0 + 1);
    for (var y = 0; y < out.height; y++) {
      final src = at(x0, y0 + y);
      final dst = out.at(0, y);
      for (var x = 0; x < out.width; x++) {
        out.bits[dst + x] = bits[src + x];
      }
    }
    return out;
  }
}

/// Forma posata sull'immagine: colonna sinistra e riga in alto (da 0,
/// dall'alto).
class Jb2Blit {
  const Jb2Blit(this.shape, this.left, this.top);
  final Jb2Shape shape;
  final int left;
  final int top;
}

class Jb2Image {
  Jb2Image(this.width, this.height, this.blits);
  final int width;
  final int height;
  final List<Jb2Blit> blits;

  /// Maschera piena: un byte per pixel (1 = nero), righe dall'alto.
  Uint8List toMask() {
    final out = Uint8List(width * height);
    for (final b in blits) {
      final s = b.shape;
      for (var y = 0; y < s.height; y++) {
        final ty = b.top + y;
        if (ty < 0 || ty >= height) continue;
        final src = s.at(0, y);
        for (var x = 0; x < s.width; x++) {
          final tx = b.left + x;
          if (tx < 0 || tx >= width) continue;
          if (s.bits[src + x] != 0) out[ty * width + tx] = 1;
        }
      }
    }
    return out;
  }
}

/// Contesto di un intero multivalore: albero binario di contesti creato
/// mentre lo si percorre (specifica, 11.2.2).
class _NumContext {
  final ctx = <int>[0];
  final left = <int>[0];
  final right = <int>[0];

  void reset() {
    ctx
      ..clear()
      ..add(0);
    left
      ..clear()
      ..add(0);
    right
      ..clear()
      ..add(0);
  }

  int child(int node, bool one) {
    final list = one ? right : left;
    var c = list[node];
    if (c == 0) {
      c = ctx.length;
      ctx.add(0);
      left.add(0);
      right.add(0);
      list[node] = c;
    }
    return c;
  }
}

const _big = 262142;

class _Jb2Decoder {
  _Jb2Decoder(Uint8List data, int start, int end)
    : zp = ZpDecoder(data, start, end);

  final ZpDecoder zp;
  final _direct = Uint8List(1024);
  final _refine = Uint8List(2048);
  final _offsetType = Uint8List(1);
  final _refinementFlag = Uint8List(1);
  final _recordType = _NumContext();
  final _imageSize = _NumContext();
  final _matchIndex = _NumContext();
  final _symWidth = _NumContext();
  final _symHeight = _NumContext();
  final _symWidthDiff = _NumContext();
  final _symHeightDiff = _NumContext();
  final _symCol = _NumContext();
  final _symRow = _NumContext();
  final _sameLineCol = _NumContext();
  final _sameLineRow = _NumContext();
  final _newLineCol = _NumContext();
  final _newLineRow = _NumContext();
  final _commentLength = _NumContext();
  final _commentOctet = _NumContext();
  final _dictSize = _NumContext();

  List<_NumContext> get _numbers => [
    _recordType,
    _imageSize,
    _matchIndex,
    _symWidth,
    _symHeight,
    _symWidthDiff,
    _symHeightDiff,
    _symCol,
    _symRow,
    _sameLineCol,
    _sameLineRow,
    _newLineCol,
    _newLineRow,
    _commentLength,
    _commentOctet,
    _dictSize,
  ];

  /// Intero in [low, high] (fasi 1–4 della specifica, 11.2.5).
  int number(int low, int high, _NumContext c) {
    var node = 0;
    var negative = false;
    var cutoff = 0;
    var phase = 1;
    var range = -1;
    while (range != 1) {
      final bool d;
      if (low >= cutoff) {
        d = true;
      } else if (high < cutoff) {
        d = false;
      } else {
        d = zp.decode(c.ctx, node) != 0;
      }
      node = c.child(node, d);
      switch (phase) {
        case 1:
          negative = !d;
          if (negative) {
            final t = -low - 1;
            low = -high - 1;
            high = t;
          }
          phase = 2;
          cutoff = 1;
        case 2:
          if (!d) {
            phase = 3;
            range = (cutoff + 1) >> 1;
            if (range == 1) {
              cutoff = 0;
            } else {
              cutoff -= range >> 1;
            }
          } else {
            cutoff = 2 * cutoff + 1;
          }
        default:
          range >>= 1;
          if (range != 1) {
            cutoff += d ? range >> 1 : -(range >> 1);
          } else if (!d) {
            cutoff--;
          }
      }
    }
    return negative ? -cutoff - 1 : cutoff;
  }

  Jb2Shape direct(int w, int h) {
    final s = Jb2Shape(w, h);
    final b = s.bits;
    final ctx = _direct;
    for (var y = 0; y < h; y++) {
      final r0 = s.at(0, y), r1 = s.at(0, y - 1), r2 = s.at(0, y - 2);
      var a = (b[r2 - 1] << 2) | (b[r2] << 1) | b[r2 + 1];
      var m =
          (b[r1 - 2] << 4) |
          (b[r1 - 1] << 3) |
          (b[r1] << 2) |
          (b[r1 + 1] << 1) |
          b[r1 + 2];
      var c = (b[r0 - 2] << 1) | b[r0 - 1];
      for (var x = 0; x < w; x++) {
        final px = zp.decode(ctx, (a << 7) | (m << 2) | c);
        b[r0 + x] = px;
        a = ((a << 1) & 7) | b[r2 + x + 2];
        m = ((m << 1) & 31) | b[r1 + x + 3];
        c = ((c << 1) & 3) | px;
      }
    }
    return s;
  }

  Jb2Shape refine(int w, int h, Jb2Shape ref) {
    final s = Jb2Shape(w, h);
    final b = s.bits;
    final ctx = _refine;
    // Allineamento dei centri: colonna centrale a sinistra, riga centrale
    // in basso quando sono pari.
    final dx = ((ref.width - 1) >> 1) - ((w - 1) >> 1);
    final dy = (ref.height >> 1) - (h >> 1);
    for (var y = 0; y < h; y++) {
      final r0 = s.at(0, y), r1 = s.at(0, y - 1);
      final my = y + dy;
      var a = (b[r1 - 1] << 2) | (b[r1] << 1) | b[r1 + 1];
      var c = b[r0 - 1];
      final mx0 = dx;
      var mm =
          (ref.pixel(mx0 - 1, my) << 2) |
          (ref.pixel(mx0, my) << 1) |
          ref.pixel(mx0 + 1, my);
      var md =
          (ref.pixel(mx0 - 1, my + 1) << 2) |
          (ref.pixel(mx0, my + 1) << 1) |
          ref.pixel(mx0 + 1, my + 1);
      for (var x = 0; x < w; x++) {
        final mx = x + dx;
        final up = ref.pixel(mx, my - 1);
        final px = zp.decode(
          ctx,
          (a << 8) | (c << 7) | (up << 6) | (mm << 3) | md,
        );
        b[r0 + x] = px;
        a = ((a << 1) & 7) | b[r1 + x + 2];
        c = px;
        mm = ((mm << 1) & 7) | ref.pixel(mx + 2, my);
        md = ((md << 1) & 7) | ref.pixel(mx + 2, my + 1);
      }
    }
    return s;
  }

  // Stato della riga di testo (colonne da 1, righe dal basso da 1).
  int _height = 0;
  int _firstLeft = 0;
  int _firstBottom = 0;
  int _prevRight = 0;
  final _bottoms = [0, 0, 0];
  int _baseline = 0;

  void _startLines(int height) {
    _height = height;
    _firstLeft = 0;
    _firstBottom = height;
    _prevRight = 0;
    _bottoms.fillRange(0, 3, height);
    _baseline = height;
  }

  /// Posizione relativa (11.5.8) → (colonna sinistra, riga in alto) da 0
  /// e dall'alto.
  (int, int) location(int w, int h) {
    final newLine = zp.decode(_offsetType, 0) != 0;
    int left, bottom;
    if (newLine) {
      left = _firstLeft + number(-_big - 1, _big, _newLineCol);
      final top = _firstBottom + number(-_big - 1, _big, _newLineRow);
      bottom = top - h + 1;
      _firstLeft = left;
      _firstBottom = bottom;
      _bottoms.fillRange(0, 3, bottom);
      _baseline = bottom;
    } else {
      left = _prevRight + number(-_big - 1, _big, _sameLineCol);
      bottom = _baseline + number(-_big - 1, _big, _sameLineRow);
      _bottoms
        ..removeAt(0)
        ..add(bottom);
      final s = List.of(_bottoms)..sort();
      _baseline = s[1];
    }
    _prevRight = left + w - 1;
    final top = bottom + h - 1;
    return (left - 1, _height - top);
  }

  Jb2Image decode({List<Jb2Shape>? dictionary, List<Jb2Shape>? library}) {
    final lib = library ?? <Jb2Shape>[];
    final blits = <Jb2Blit>[];
    var width = 0, height = 0;
    var started = false;
    loop:
    while (true) {
      final type = number(0, 11, _recordType);
      switch (type) {
        case 0:
          width = number(0, _big, _imageSize);
          height = number(0, _big, _imageSize);
          zp.decode(_refinementFlag, 0);
          _startLines(height);
          started = true;
        case 1 || 2 || 3:
          final w = number(0, _big, _symWidth);
          final h = number(0, _big, _symHeight);
          final s = direct(w, h);
          if (type != 2) {
            final (x, y) = location(w, h);
            blits.add(Jb2Blit(s, x, y));
          }
          if (type != 3) lib.add(s.trimmed());
        case 4 || 5 || 6:
          if (lib.isEmpty) throw const FormatException('JB2: libreria vuota');
          final ref = lib[number(0, lib.length - 1, _matchIndex)];
          final w = ref.width + number(-_big - 1, _big, _symWidthDiff);
          final h = ref.height + number(-_big - 1, _big, _symHeightDiff);
          if (w < 0 || h < 0) {
            throw const FormatException('JB2: forma non valida');
          }
          final s = refine(w, h, ref);
          if (type != 5) {
            final (x, y) = location(w, h);
            blits.add(Jb2Blit(s, x, y));
          }
          if (type != 6) lib.add(s.trimmed());
        case 7:
          if (lib.isEmpty) throw const FormatException('JB2: libreria vuota');
          final s = lib[number(0, lib.length - 1, _matchIndex)];
          final (x, y) = location(s.width, s.height);
          blits.add(Jb2Blit(s, x, y));
        case 8:
          final w = number(0, _big, _symWidth);
          final h = number(0, _big, _symHeight);
          final s = direct(w, h);
          final left = number(1, width < 1 ? 1 : width, _symCol);
          final top = number(1, height < 1 ? 1 : height, _symRow);
          blits.add(Jb2Blit(s, left - 1, height - top));
        case 9:
          if (!started) {
            final n = number(0, _big, _dictSize);
            final shared = dictionary ?? const <Jb2Shape>[];
            if (n > shared.length) {
              throw const FormatException('JB2: dizionario condiviso mancante');
            }
            lib.addAll(shared.take(n));
          } else {
            for (final c in _numbers) {
              c.reset();
            }
          }
        case 10:
          final n = number(0, _big, _commentLength);
          for (var i = 0; i < n; i++) {
            number(0, 255, _commentOctet);
          }
        default:
          break loop;
      }
    }
    return Jb2Image(width, height, blits);
  }
}

/// Immagine di un blocco Sjbz; [dictionary] sono le forme del Djbz
/// incluso (se il blocco lo richiede).
Jb2Image decodeJb2(
  Uint8List data, {
  int start = 0,
  int? end,
  List<Jb2Shape>? dictionary,
}) =>
    _Jb2Decoder(data, start, end ?? data.length).decode(dictionary: dictionary);

/// Forme di un dizionario Djbz.
List<Jb2Shape> decodeJb2Dictionary(
  Uint8List data, {
  int start = 0,
  int? end,
  List<Jb2Shape>? dictionary,
}) {
  final lib = <Jb2Shape>[];
  _Jb2Decoder(
    data,
    start,
    end ?? data.length,
  ).decode(dictionary: dictionary, library: lib);
  return lib;
}
