/// Decompressione BZZ dei file DjVu (specifica DjVu v3, appendice 4):
/// trasformata di Burrows-Wheeler con un elenco "move to front" ordinato
/// per frequenza e i numeri codificati con lo ZP-Coder.
library;

import 'dart:typed_data';

import 'zp_decoder.dart';

/// Dati BZZ → byte. Blocchi uno dopo l'altro fino a quello di dimensione 0.
Uint8List bzzDecode(Uint8List data, [int start = 0, int? end]) {
  final zp = ZpDecoder(data, start, end);
  final ctx = Uint8List(300);
  final out = BytesBuilder(copy: false);
  while (true) {
    // Dati finiti senza il blocco di fine: oltre la fine i bit valgono 1 e
    // la dimensione letta sarebbe la massima (16 MB) per ogni blocco.
    if (zp.exhausted) throw const FormatException('Dati BZZ troncati');
    final block = _decodeBlock(zp, ctx);
    if (block == null) break;
    out.add(block);
  }
  return out.takeBytes();
}

int _raw(ZpDecoder zp, int bits) {
  var n = 1;
  final m = 1 << bits;
  while (n < m) {
    n = (n << 1) | zp.passThrough();
  }
  return n - m;
}

int _bin(ZpDecoder zp, Uint8List ctx, int offset, int bits) {
  var n = 1;
  final m = 1 << bits;
  while (n < m) {
    n = (n << 1) | zp.decode(ctx, offset + n - 1);
  }
  return n - m;
}

Uint8List? _decodeBlock(ZpDecoder zp, Uint8List ctx) {
  final size = _raw(zp, 24);
  if (size == 0) return null;
  var fshift = 0;
  if (zp.passThrough() != 0) fshift = zp.passThrough() != 0 ? 2 : 1;
  final mtf = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    mtf[i] = i;
  }
  final freq = Int32List(4);
  var fadd = 4;
  var mtfno = 3;
  var marker = -1;
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    if (i & 0xFFF == 0 && zp.exhausted) {
      throw const FormatException('Dati BZZ troncati');
    }
    final c = mtfno <= 1 ? mtfno : 2;
    if (zp.decode(ctx, c) != 0) {
      mtfno = 0;
    } else if (zp.decode(ctx, c + 3) != 0) {
      mtfno = 1;
    } else if (zp.decode(ctx, 6) != 0) {
      mtfno = 2 + _bin(zp, ctx, 7, 1);
    } else if (zp.decode(ctx, 8) != 0) {
      mtfno = 4 + _bin(zp, ctx, 9, 2);
    } else if (zp.decode(ctx, 12) != 0) {
      mtfno = 8 + _bin(zp, ctx, 13, 3);
    } else if (zp.decode(ctx, 20) != 0) {
      mtfno = 16 + _bin(zp, ctx, 21, 4);
    } else if (zp.decode(ctx, 36) != 0) {
      mtfno = 32 + _bin(zp, ctx, 37, 5);
    } else if (zp.decode(ctx, 68) != 0) {
      mtfno = 64 + _bin(zp, ctx, 69, 6);
    } else if (zp.decode(ctx, 132) != 0) {
      mtfno = 128 + _bin(zp, ctx, 133, 7);
    } else {
      // Fine del blocco (EOB).
      mtfno = 256;
      data[i] = 0;
      marker = i;
      continue;
    }
    final sym = mtf[mtfno];
    data[i] = sym;
    fadd += fadd >> fshift;
    if (fadd > 0x10000000) {
      fadd >>= 24;
      for (var j = 0; j < 4; j++) {
        freq[j] >>= 24;
      }
    }
    final fc = fadd + (mtfno < 4 ? freq[mtfno] : 0);
    var k = mtfno;
    for (; k > 3; k--) {
      mtf[k] = mtf[k - 1];
    }
    for (; k > 0 && fc >= freq[k - 1]; k--) {
      mtf[k] = mtf[k - 1];
      freq[k] = freq[k - 1];
    }
    mtf[k] = sym;
    freq[k] = fc;
  }
  if (marker <= 0 || marker >= size) {
    throw const FormatException('Dati BZZ non validi');
  }
  // Trasformata inversa di Burrows-Wheeler.
  final posn = Int32List(size);
  final count = Int32List(256);
  for (var i = 0; i < size; i++) {
    if (i == marker) {
      posn[i] = 0;
    } else {
      final c = data[i];
      posn[i] = count[c];
      count[c]++;
    }
  }
  var last = 1;
  for (var i = 0; i < 256; i++) {
    final n = count[i];
    count[i] = last;
    last += n;
  }
  final out = Uint8List(size - 1);
  var k = 0;
  for (var j = size - 1; j > 0;) {
    j--;
    final c = data[k];
    out[j] = c;
    k = count[c] + posn[k];
  }
  return out;
}
