/// Immagini IW44 dei file DjVu (BG44, FG44, TH44, PM44, BM44), dalla
/// specifica DjVu v3, appendice 1: coefficienti di una trasformata a
/// ondine (Dubuc–Deslauriers–Lemire 4,4) decodificati a "fette"
/// progressive con lo ZP-Coder, poi trasformata inversa e conversione da
/// YCbCr a RGB.
library;

import 'dart:typed_data';

import 'zp_decoder.dart';

/// Primo coefficiente e numero di gruppi (bucket) di ogni banda (tab. 2).
const _bandFirst = [0, 1, 2, 3, 4, 8, 12, 16, 32, 48];
const _bandCount = [1, 1, 1, 1, 4, 4, 4, 16, 16, 16];

/// Valori iniziali dei passi di quantizzazione (tab. 4).
const _initialSteps = [
  0x04000, 0x08000, 0x08000, 0x10000, 0x10000, 0x10000, 0x20000, 0x20000, //
  0x20000, 0x40000, 0x40000, 0x40000, 0x80000, 0x40000, 0x40000, 0x80000,
];

/// Indice nella tabella dei passi per coefficiente (tab. 3).
final Uint8List _stepIndex = () {
  final t = Uint8List(1024);
  for (var i = 0; i < 1024; i++) {
    t[i] = switch (i) {
      < 4 => i,
      < 8 => 4,
      < 12 => 5,
      < 16 => 6,
      < 32 => 7,
      < 48 => 8,
      < 64 => 9,
      < 128 => 10,
      < 192 => 11,
      < 256 => 12,
      < 512 => 13,
      < 768 => 14,
      _ => 15,
    };
  }
  return t;
}();

/// Posizione nel blocco 32×32 (riga dal basso << 5 | colonna) di ogni
/// coefficiente: bit dispari → riga, bit pari → colonna (10.6.3).
final Uint16List _position = () {
  final t = Uint16List(1024);
  for (var i = 0; i < 1024; i++) {
    var row = 0, col = 0;
    for (var b = 0; b < 5; b++) {
      // b1 (bit 1) è il più significativo della riga, b0 della colonna.
      row |= ((i >> (2 * b + 1)) & 1) << (4 - b);
      col |= ((i >> (2 * b)) & 1) << (4 - b);
    }
    t[i] = (row << 5) | col;
  }
  return t;
}();

class _Component {
  _Component(int blocks) : coeffs = Int16List(blocks * 1024);

  final Int16List coeffs;
  final steps = Int32List.fromList(_initialSteps);
  int band = 0;
  final ctxRoot = Uint8List(1);
  final ctxBucket = Uint8List(80);
  final ctxStart = Uint8List(16);
  final ctxMant = Uint8List(1);
}

/// Immagine IW44 in decodifica: si aggiungono i blocchi uno dopo l'altro.
class Iw44Image {
  int width = 0;
  int height = 0;
  bool color = false;
  int _delay = 0;

  /// Crominanza a metà risoluzione (bit alto del ritardo a 0, come nei file
  /// di "c44 -crcbhalf"): Cb e Cr si ricostruiscono fino alla scala 2 e
  /// ogni campione vale per 2×2 pixel.
  bool _chromaHalf = false;
  int _serial = 0;
  int _blocksW = 0;
  List<_Component> _comps = const [];

  bool get isEmpty => _comps.isEmpty;

  /// Aggiunge i dati di un blocco BG44/FG44/TH44 (in ordine).
  void addChunk(Uint8List data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    if (stop - start < 2) return;
    final serial = data[start];
    final slices = data[start + 1];
    var pos = start + 2;
    if (serial == 0) {
      if (stop - start < 9) throw const FormatException('IW44: intestazione');
      color = data[pos] & 0x80 == 0;
      width = (data[pos + 2] << 8) | data[pos + 3];
      height = (data[pos + 4] << 8) | data[pos + 5];
      _delay = data[pos + 6] & 0x7F;
      _chromaHalf = data[pos + 6] & 0x80 == 0;
      pos += 7;
      _blocksW = (width + 31) >> 5;
      final blocks = _blocksW * ((height + 31) >> 5);
      _comps = [for (var i = 0; i < (color ? 3 : 1); i++) _Component(blocks)];
      _serial = 0;
    } else if (_comps.isEmpty || serial != _serial) {
      // Blocco fuori sequenza: lo si ignora.
      return;
    }
    _serial++;
    final zp = ZpDecoder(data, pos, stop);
    final blocks = _comps.first.coeffs.length >> 10;
    for (var s = 0; s < slices; s++) {
      final chroma = color && _delay == 0;
      for (var c = 0; c < (chroma ? 3 : 1); c++) {
        final comp = _comps[c];
        final band = comp.band;
        if (!_nullBand(comp, band)) {
          for (var b = 0; b < blocks; b++) {
            _decodeBlockBand(zp, comp, b << 10, band);
          }
        }
        // Fine della fetta: passi dimezzati e banda successiva.
        if (band == 0) {
          for (var i = 0; i < 7; i++) {
            comp.steps[i] >>= 1;
          }
        } else {
          comp.steps[band + 6] >>= 1;
        }
        comp.band = band == 9 ? 0 : band + 1;
      }
      if (_delay > 0) _delay--;
    }
  }

  static bool _nullBand(_Component c, int band) {
    if (band == 0) {
      for (var i = 0; i < 7; i++) {
        final s = c.steps[i];
        if (s > 0 && s < 0x8000) return false;
      }
      return true;
    }
    final s = c.steps[band + 6];
    return !(s > 0 && s < 0x8000);
  }

  // Stati dei coefficienti.
  static const _active = 1;
  static const _potential = 2;

  final _state = Uint8List(256);
  final _bucketState = Uint8List(16);
  final _decodeBucket = Uint8List(16);

  void _decodeBlockBand(ZpDecoder zp, _Component comp, int base, int band) {
    final coeffs = comp.coeffs;
    final first = _bandFirst[band];
    final nb = _bandCount[band];
    final c0 = first << 4;
    final n = nb << 4;
    // Calcolo preliminare dei flag (10.5.1).
    var bbActive = false, bbPotential = false;
    for (var k = 0; k < nb; k++) {
      var st = 0;
      for (var j = 0; j < 16; j++) {
        final i = (k << 4) + j;
        final idx = c0 + i;
        final step = comp.steps[_stepIndex[idx]];
        var f = 0;
        if (step > 0 && step < 0x8000) {
          f = coeffs[base + idx] != 0 ? _active : _potential;
        }
        _state[i] = f;
        st |= f;
      }
      _bucketState[k] = st;
      if (st & _active != 0) bbActive = true;
      if (st & _potential != 0) bbPotential = true;
    }
    if (!bbActive && !bbPotential) return;
    // Passo 1: decidere se decodificare i gruppi.
    var go = false;
    if (nb < 16 || bbActive) {
      go = true;
    } else if (bbPotential) {
      go = zp.decode(comp.ctxRoot, 0) != 0;
    }
    if (go) {
      // Passo 2: gruppi da decodificare.
      for (var k = 0; k < nb; k++) {
        _decodeBucket[k] = 0;
        if (_bucketState[k] & _potential == 0) continue;
        var ctx = 0;
        if (band != 0) {
          final t = base + ((first + k) << 2);
          for (var j = 0; j < 4; j++) {
            if (coeffs[t + j] != 0) ctx++;
          }
          if (ctx == 4) ctx = 3;
        }
        if (bbActive) ctx |= 4;
        _decodeBucket[k] = zp.decode(comp.ctxBucket, (band << 3) | ctx);
      }
      // Passo 3: coefficienti che diventano attivi, con il segno.
      for (var k = 0; k < nb; k++) {
        if (_decodeBucket[k] == 0) continue;
        var np = 0;
        for (var j = 0; j < 16; j++) {
          if (_state[(k << 4) + j] == _potential) np++;
        }
        final activeBucket = _bucketState[k] & _active != 0;
        for (var j = 0; j < 16; j++) {
          final i = (k << 4) + j;
          if (_state[i] != _potential) continue;
          var ctx = np > 7 ? 7 : np;
          if (activeBucket) ctx |= 8;
          if (zp.decode(comp.ctxStart, ctx) != 0) {
            final idx = c0 + i;
            final step = comp.steps[_stepIndex[idx]];
            final v = step + (step >> 1);
            coeffs[base + idx] = zp.passThrough() != 0 ? -v : v;
            np = 0;
          }
          if (np > 0) np--;
        }
      }
    }
    // Passo 4: un bit in più per i coefficienti già attivi.
    if (!bbActive) return;
    for (var i = 0; i < n; i++) {
      if (_state[i] != _active) continue;
      final idx = c0 + i;
      final step = comp.steps[_stepIndex[idx]];
      final v = coeffs[base + idx];
      var a = v < 0 ? -v : v;
      final bit = a <= 3 * step ? zp.decode(comp.ctxMant, 0) : zp.passThrough();
      if (bit != 0) {
        a += step >> 1;
      } else {
        a += (step >> 1) - step;
      }
      coeffs[base + idx] = v < 0 ? -a : a;
    }
  }

  /// Componente [c] ricostruita: valori a 8 bit con segno (−128..127),
  /// righe dal basso, ridotta di 2^[shift] (0–4) in ogni direzione.
  Int8List _plane(int c, int shift, {bool half = false}) {
    final w = width, h = height;
    final plane = Int32List(w * h);
    final coeffs = _comps[c].coeffs;
    final bw = _blocksW;
    final blocks = coeffs.length >> 10;
    for (var b = 0; b < blocks; b++) {
      final bx = (b % bw) << 5, by = (b ~/ bw) << 5;
      final base = b << 10;
      for (var i = 0; i < 1024; i++) {
        final v = coeffs[base + i];
        if (v == 0) continue;
        final pos = _position[i];
        final x = bx + (pos & 31), y = by + (pos >> 5);
        if (x < w && y < h) plane[y * w + x] = v;
      }
    }
    final buf = Int32List((w > h ? w : h) + 1);
    final last = half && shift == 0 ? 2 : 1 << shift;
    for (var s = 16; s >= last; s >>= 1) {
      // Colonne, poi righe.
      final kmaxV = (h - 1) ~/ s;
      for (var x = 0; x < w; x += s) {
        for (var k = 0; k <= kmaxV; k++) {
          buf[k] = plane[(k * s) * w + x];
        }
        _inverse1d(buf, kmaxV);
        for (var k = 0; k <= kmaxV; k++) {
          plane[(k * s) * w + x] = buf[k];
        }
      }
      final kmaxH = (w - 1) ~/ s;
      for (var y = 0; y < h; y += s) {
        final row = y * w;
        for (var k = 0; k <= kmaxH; k++) {
          buf[k] = plane[row + k * s];
        }
        _inverse1d(buf, kmaxH);
        for (var k = 0; k <= kmaxH; k++) {
          plane[row + k * s] = buf[k];
        }
      }
    }
    final step = 1 << shift;
    final ow = (w + step - 1) >> shift, oh = (h + step - 1) >> shift;
    final out = Int8List(ow * oh);
    for (var y = 0; y < oh; y++) {
      for (var x = 0; x < ow; x++) {
        final sx = last > step ? (x >> 1) << 1 : x << shift;
        final sy = last > step ? (y >> 1) << 1 : y << shift;
        var v = (plane[sy * w + sx] + 32) >> 6;
        if (v < -128) v = -128;
        if (v > 127) v = 127;
        out[y * ow + x] = v;
      }
    }
    return out;
  }

  static void _inverse1d(Int32List c, int kmax) {
    int at(int k) => k < 0 || k > kmax ? 0 : c[k];
    // Sollevamento (coefficienti pari).
    for (var k = 0; k <= kmax; k += 2) {
      c[k] -= (9 * (at(k - 1) + at(k + 1)) - (at(k - 3) + at(k + 3)) + 16) >> 5;
    }
    // Predizione (coefficienti dispari).
    for (var k = 1; k <= kmax; k += 2) {
      if (k - 3 >= 0 && k + 3 <= kmax) {
        c[k] += (9 * (c[k - 1] + c[k + 1]) - (c[k - 3] + c[k + 3]) + 8) >> 4;
      } else if (k + 1 <= kmax) {
        c[k] += (c[k - 1] + c[k + 1] + 1) >> 1;
      } else {
        c[k] += c[k - 1];
      }
    }
  }

  /// Pixel RGB (3 byte per pixel, righe dall'alto), ridotti di 2^[shift].
  ({int width, int height, Uint8List rgb}) toRgb([int shift = 0]) {
    final step = 1 << shift;
    final ow = (width + step - 1) >> shift, oh = (height + step - 1) >> shift;
    final out = Uint8List(ow * oh * 3);
    if (_comps.isEmpty) return (width: ow, height: oh, rgb: out);
    final y = _plane(0, shift);
    if (!color) {
      for (var r = 0; r < oh; r++) {
        final src = (oh - 1 - r) * ow;
        for (var x = 0; x < ow; x++) {
          final g = 127 - y[src + x];
          final o = (r * ow + x) * 3;
          out[o] = out[o + 1] = out[o + 2] = g;
        }
      }
      return (width: ow, height: oh, rgb: out);
    }
    final cb = _plane(1, shift, half: _chromaHalf);
    final cr = _plane(2, shift, half: _chromaHalf);
    int clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    for (var r = 0; r < oh; r++) {
      final src = (oh - 1 - r) * ow;
      for (var x = 0; x < ow; x++) {
        final i = src + x;
        final yy = y[i] + 128, b = cb[i], rr = cr[i];
        final t2 = rr + (rr >> 1);
        final t3 = yy - (b >> 2);
        final o = (r * ow + x) * 3;
        out[o] = clamp(yy + t2);
        out[o + 1] = clamp(t3 - (t2 >> 1));
        out[o + 2] = clamp(t3 + (b << 1));
      }
    }
    return (width: ow, height: oh, rgb: out);
  }
}
