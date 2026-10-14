/// Documento DjVu: pagina singola (FORM:DJVU) o documento a più pagine
/// raggruppato (FORM:DJVM con la cartella DIRM), indice dai segnalibri
/// NAVM, testo nascosto delle pagine e disegno di una pagina alla volta
/// (maschera JB2, sfondo e primo piano IW44 o JPEG, colori FGbz).
///
/// Scritto dalla specifica pubblica DjVu v3 (LizardTech, 2005).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'bzz.dart';
import 'djvu_text.dart';
import 'iff.dart';
import 'iw44.dart';
import 'jb2.dart';

/// Documento "indiretto": le pagine sono in file separati.
class DjvuIndirectException implements Exception {
  const DjvuIndirectException();
  @override
  String toString() => 'Documento DjVu indiretto';
}

class DjvuPage {
  const DjvuPage({
    required this.id,
    required this.width,
    required this.height,
    required this.dpi,
    required this.rotation,
    required this.form,
  });

  /// Identificatore del componente ("p0001.djvu").
  final String id;

  /// Dimensioni in pixel come memorizzate (prima della rotazione).
  final int width;
  final int height;
  final int dpi;

  /// Rotazione in quarti di giro antiorari (0–3).
  final int rotation;
  final IffChunk form;

  /// Dimensioni mostrate (dopo la rotazione).
  int get viewWidth => rotation.isOdd ? height : width;
  int get viewHeight => rotation.isOdd ? width : height;
}

class DjvuOutlineItem {
  const DjvuOutlineItem(this.title, this.page, this.level);
  final String title;

  /// Pagina (da 0), −1 se il segnalibro porta fuori dal documento.
  final int page;
  final int level;
}

/// Pagina disegnata: RGBA, righe dall'alto.
class DjvuBitmap {
  const DjvuBitmap(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

/// Dati di una pagina da disegnare (anche in un isolate): il suo FORM e i
/// componenti inclusi (dizionari di forme, annotazioni condivise).
class DjvuPageData {
  const DjvuPageData(this.page, this.includes);
  final Uint8List page;
  final Map<String, Uint8List> includes;
}

(int, int, int, int) _info(IffChunk? info) {
  if (info == null || info.length < 4) {
    throw const FormatException('DjVu: blocco INFO mancante');
  }
  final b = info.buffer, o = info.start;
  final w = be16(b, o), h = be16(b, o + 2);
  var dpi = 300, flags = 1;
  if (info.length >= 8) dpi = b[o + 6] | (b[o + 7] << 8);
  if (info.length >= 10) flags = b[o + 9];
  if (dpi < 25 || dpi > 6000) dpi = 300;
  final rot = switch (flags & 7) {
    6 => 1, // 90° antiorario
    2 => 2,
    5 => 3, // 90° orario
    _ => 0,
  };
  return (w, h, dpi, rot);
}

class DjvuDocument {
  DjvuDocument._(this.bytes, this.pages, this.outline, this._components);

  final Uint8List bytes;
  final List<DjvuPage> pages;
  final List<DjvuOutlineItem> outline;
  final Map<String, IffChunk> _components;

  static DjvuDocument parse(Uint8List bytes) {
    final root = parseDjvuFile(bytes);
    final components = <String, IffChunk>{};
    final pages = <DjvuPage>[];
    var outline = <DjvuOutlineItem>[];
    DjvuPage page(String id, IffChunk form) {
      final (w, h, dpi, rot) = _info(form.child('INFO'));
      return DjvuPage(
        id: id,
        width: w,
        height: h,
        dpi: dpi,
        rotation: rot,
        form: form,
      );
    }

    switch (root.formType) {
      case 'DJVU':
        pages.add(page('', root));
      case 'DJVM':
        final dirm = root.child('DIRM');
        if (dirm == null || dirm.length < 3) {
          throw const FormatException('DjVu: cartella DIRM mancante');
        }
        final b = dirm.buffer, o = dirm.start;
        final bundled = b[o] & 0x80 != 0;
        if (!bundled) throw const DjvuIndirectException();
        final n = be16(b, o + 1);
        final offsets = [for (var i = 0; i < n; i++) be32(b, o + 3 + 4 * i)];
        final meta = bzzDecode(b, o + 3 + 4 * n, dirm.end);
        var pos = 3 * n; // dimensioni (non servono)
        final flags = [for (var i = 0; i < n; i++) meta[pos + i]];
        pos += n;
        String zstr() {
          final s = pos;
          while (pos < meta.length && meta[pos] != 0) {
            pos++;
          }
          final t = utf8.decode(
            Uint8List.sublistView(meta, s, pos),
            allowMalformed: true,
          );
          pos++;
          return t;
        }

        final byOffset = {for (final c in root.children) c.headerOffset: c};
        for (var i = 0; i < n; i++) {
          final id = zstr();
          if (flags[i] & 0x80 != 0) zstr();
          if (flags[i] & 0x40 != 0) zstr();
          final form = byOffset[offsets[i]];
          if (form == null) continue;
          components[id] = form;
          if (flags[i] & 0x3F == 1 && form.formType == 'DJVU') {
            pages.add(page(id, form));
          }
        }
        final navm = root.child('NAVM');
        if (navm != null) {
          try {
            outline = _parseNavm(bzzDecode(b, navm.start, navm.end), pages);
          } catch (_) {}
        }
      default:
        throw FormatException('DjVu: contenitore ${root.kind} non supportato');
    }
    if (pages.isEmpty) throw const FormatException('DjVu senza pagine');
    return DjvuDocument._(bytes, pages, outline, components);
  }

  static List<DjvuOutlineItem> _parseNavm(Uint8List d, List<DjvuPage> pages) {
    if (d.length < 2) return const [];
    final count = be16(d, 0);
    var pos = 2;
    final out = <DjvuOutlineItem>[];
    final ids = {for (var i = 0; i < pages.length; i++) pages[i].id: i};
    String str() {
      final n = be24(d, pos);
      pos += 3;
      final s = utf8.decode(
        Uint8List.sublistView(d, pos, math.min(d.length, pos + n)),
        allowMalformed: true,
      );
      pos += n;
      return s;
    }

    int target(String url) {
      if (!url.startsWith('#')) return -1;
      final t = url.substring(1);
      final byId = ids[t];
      if (byId != null) return byId;
      final n = int.tryParse(t);
      if (n != null && n >= 1 && n <= pages.length) return n - 1;
      return -1;
    }

    void item(int level) {
      if (pos + 7 > d.length || out.length >= count) return;
      final kids = d[pos++];
      final title = str();
      final url = str();
      out.add(DjvuOutlineItem(title.trim(), target(url.trim()), level));
      for (var i = 0; i < kids; i++) {
        item(level + 1);
      }
    }

    while (pos < d.length && out.length < count) {
      final before = pos;
      item(0);
      if (pos == before) break;
    }
    return out;
  }

  /// Componenti inclusi (INCL) da una pagina, anche annidati.
  List<IffChunk> _includes(IffChunk form, [Set<String>? seen]) {
    final out = <IffChunk>[];
    final s = seen ?? <String>{};
    for (final c in form.all('INCL')) {
      final id = utf8
          .decode(c.bytes, allowMalformed: true)
          .replaceAll('\u0000', '')
          .trim();
      final inc = _components[id];
      if (inc == null || !s.add(id)) continue;
      out
        ..add(inc)
        ..addAll(_includes(inc, s));
    }
    return out;
  }

  /// Testo nascosto della pagina [i] (vuoto se non c'è).
  DjvuPageText text(int i) {
    final p = pages[i];
    for (final form in [p.form, ..._includes(p.form)]) {
      for (final c in form.children) {
        try {
          if (c.id == 'TXTz') {
            return parseDjvuText(bzzDecode(c.buffer, c.start, c.end), p.height);
          }
          if (c.id == 'TXTa') return parseDjvuText(c.bytes, p.height);
        } catch (_) {
          return DjvuPageText.empty;
        }
      }
    }
    return DjvuPageText.empty;
  }

  /// Byte della pagina [i] e dei suoi inclusi (copie, per un isolate).
  DjvuPageData pageData(int i) {
    final form = pages[i].form;
    Uint8List copy(IffChunk c) => Uint8List.fromList(
      Uint8List.sublistView(c.buffer, c.headerOffset, c.end),
    );
    final inc = <String, Uint8List>{};
    var n = 0;
    for (final c in _includes(form)) {
      inc['${n++}'] = copy(c);
    }
    return DjvuPageData(copy(form), inc);
  }
}

// ------------------------------------------------------------- Disegno

class _Layer {
  _Layer(this.width, this.height, this.rgb);
  final int width;
  final int height;
  final Uint8List rgb;

  /// Colore interpolato in (u, v) (coordinate del livello, centri dei
  /// pixel su interi).
  void sample(double u, double v, List<int> out) {
    if (u < 0) u = 0;
    if (v < 0) v = 0;
    final mu = width - 1.0, mv = height - 1.0;
    if (u > mu) u = mu;
    if (v > mv) v = mv;
    final x0 = u.floor(), y0 = v.floor();
    final x1 = x0 + 1 < width ? x0 + 1 : x0;
    final y1 = y0 + 1 < height ? y0 + 1 : y0;
    final fx = u - x0, fy = v - y0;
    for (var c = 0; c < 3; c++) {
      final a = rgb[(y0 * width + x0) * 3 + c];
      final b = rgb[(y0 * width + x1) * 3 + c];
      final d = rgb[(y1 * width + x0) * 3 + c];
      final e = rgb[(y1 * width + x1) * 3 + c];
      final top = a + (b - a) * fx;
      final bot = d + (e - d) * fx;
      out[c] = (top + (bot - top) * fy).round();
    }
  }
}

/// Fattore di sottocampionamento (1–12) di un livello largo [layer] su
/// una pagina larga [full].
double _factor(int full, int layer) {
  if (layer <= 0) return 1;
  for (var f = 1; f <= 12; f++) {
    if ((full + f - 1) ~/ f == layer) return f.toDouble();
  }
  return full / layer;
}

_Layer? _iwLayer(List<IffChunk> chunks, String id, int full, int reduction) {
  final list = chunks.where((c) => c.id == id).toList();
  if (list.isEmpty) return null;
  final iw = Iw44Image();
  for (final c in list) {
    iw.addChunk(c.buffer, c.start, c.end);
  }
  if (iw.isEmpty) return null;
  final f = _factor(full, iw.width);
  // Si decodifica direttamente a risoluzione ridotta quando la pagina è
  // rimpicciolita (meno memoria e meno calcoli).
  var shift = 0;
  while (shift < 4 && f * (1 << (shift + 1)) <= reduction) {
    shift++;
  }
  final r = iw.toRgb(shift);
  return _Layer(r.width, r.height, r.rgb);
}

_Layer? _jpegLayer(List<IffChunk> chunks, String id) {
  for (final c in chunks) {
    if (c.id != id) continue;
    final im = img.decodeJpg(c.bytes);
    if (im == null) return null;
    final rgb = Uint8List(im.width * im.height * 3);
    var i = 0;
    for (final p in im) {
      rgb[i++] = p.r.toInt();
      rgb[i++] = p.g.toInt();
      rgb[i++] = p.b.toInt();
    }
    return _Layer(im.width, im.height, rgb);
  }
  return null;
}

/// Colori FGbz: tavolozza (RGB) e indice di colore per ogni forma posata.
(Uint8List, Int32List?)? _palette(List<IffChunk> chunks) {
  for (final c in chunks) {
    if (c.id != 'FGbz' || c.length < 3) continue;
    final b = c.buffer, o = c.start;
    final version = b[o];
    final n = be16(b, o + 1);
    final pal = Uint8List(n * 3);
    for (var i = 0; i < n && o + 3 + 3 * i + 2 < c.end; i++) {
      final p = o + 3 + 3 * i;
      pal[3 * i] = b[p + 2];
      pal[3 * i + 1] = b[p + 1];
      pal[3 * i + 2] = b[p];
    }
    Int32List? idx;
    final pos = o + 3 + 3 * n;
    if (version & 0x80 != 0 && pos + 3 <= c.end) {
      final count = be24(b, pos);
      final data = bzzDecode(b, pos + 3, c.end);
      idx = Int32List(count);
      for (var i = 0; i < count && 2 * i + 1 < data.length; i++) {
        idx[i] = be16(data, 2 * i);
      }
    }
    return (pal, idx);
  }
  return null;
}

/// Disegna una pagina ridotta di [reduction] volte (1 = dimensione piena).
DjvuBitmap renderDjvuPage(DjvuPageData data, {int reduction = 1}) {
  final r = math.max(1, reduction);
  final form = IffChunk.parse(data.page, 0);
  final chunks = <IffChunk>[...form.children];
  for (final inc in data.includes.values) {
    chunks.addAll(IffChunk.parse(inc, 0).children);
  }
  final (w, h, _, rot) = _info(form.child('INFO'));
  IffChunk? first(String id) {
    for (final c in chunks) {
      if (c.id == id) return c;
    }
    return null;
  }

  // Maschera (testo e disegni).
  Jb2Image? mask;
  final sjbz = first('Sjbz');
  if (sjbz != null) {
    final djbz = first('Djbz');
    final dict = djbz == null
        ? null
        : decodeJb2Dictionary(djbz.buffer, start: djbz.start, end: djbz.end);
    mask = decodeJb2(
      sjbz.buffer,
      start: sjbz.start,
      end: sjbz.end,
      dictionary: dict,
    );
  }
  final bg = _iwLayer(chunks, 'BG44', w, r) ?? _jpegLayer(chunks, 'BGjp');
  final fg = _iwLayer(chunks, 'FG44', w, r) ?? _jpegLayer(chunks, 'FGjp');
  final palette = fg == null ? _palette(chunks) : null;

  final ow = (w + r - 1) ~/ r, oh = (h + r - 1) ~/ r;
  final out = Uint8List(ow * oh * 4);
  final px = [255, 255, 255];
  final bgF = bg == null ? 1.0 : w / bg.width;
  final bgFy = bg == null ? 1.0 : h / bg.height;
  for (var oy = 0; oy < oh; oy++) {
    final py = (oy + 0.5) * r;
    for (var ox = 0; ox < ow; ox++) {
      final o = (oy * ow + ox) * 4;
      if (bg != null) {
        bg.sample((ox + 0.5) * r / bgF - 0.5, py / bgFy - 0.5, px);
      }
      out[o] = px[0];
      out[o + 1] = px[1];
      out[o + 2] = px[2];
      out[o + 3] = 255;
    }
  }
  if (mask != null) {
    final cov = Uint16List(ow * oh);
    final sums = palette == null ? null : Uint32List(ow * oh * 3);
    final (pal, idx) = palette ?? (null, null);
    for (var bi = 0; bi < mask.blits.length; bi++) {
      final blit = mask.blits[bi];
      final s = blit.shape;
      var cr = 0, cg = 0, cb = 0;
      if (pal != null && pal.isNotEmpty) {
        var ci = idx != null && bi < idx.length ? idx[bi] : 0;
        if (ci < 0 || 3 * ci + 2 >= pal.length) ci = 0;
        cr = pal[3 * ci];
        cg = pal[3 * ci + 1];
        cb = pal[3 * ci + 2];
      }
      for (var y = 0; y < s.height; y++) {
        final ty = blit.top + y;
        if (ty < 0 || ty >= h) continue;
        final row = (ty ~/ r) * ow;
        final src = s.at(0, y);
        for (var x = 0; x < s.width; x++) {
          if (s.bits[src + x] == 0) continue;
          final tx = blit.left + x;
          if (tx < 0 || tx >= w) continue;
          final o = row + tx ~/ r;
          cov[o]++;
          if (sums != null) {
            sums[o * 3] += cr;
            sums[o * 3 + 1] += cg;
            sums[o * 3 + 2] += cb;
          }
        }
      }
    }
    final fgF = fg == null ? 1.0 : w / fg.width;
    final fgFy = fg == null ? 1.0 : h / fg.height;
    final fc = [0, 0, 0];
    for (var oy = 0; oy < oh; oy++) {
      final ah = math.min(r, h - oy * r);
      for (var ox = 0; ox < ow; ox++) {
        final i = oy * ow + ox;
        final n = cov[i];
        if (n == 0) continue;
        final area = ah * math.min(r, w - ox * r);
        final a = n >= area ? 1.0 : n / area;
        if (sums != null) {
          fc[0] = sums[i * 3] ~/ n;
          fc[1] = sums[i * 3 + 1] ~/ n;
          fc[2] = sums[i * 3 + 2] ~/ n;
        } else if (fg != null) {
          fg.sample(
            (ox + 0.5) * r / fgF - 0.5,
            (oy + 0.5) * r / fgFy - 0.5,
            fc,
          );
        } else {
          fc[0] = fc[1] = fc[2] = 0;
        }
        final o = i * 4;
        for (var c = 0; c < 3; c++) {
          out[o + c] = (out[o + c] * (1 - a) + fc[c] * a).round();
        }
      }
    }
  }
  return _rotate(DjvuBitmap(ow, oh, out), rot);
}

/// Rotazione di [q] quarti di giro antiorari.
DjvuBitmap _rotate(DjvuBitmap b, int q) {
  if (q == 0) return b;
  final w = b.width, h = b.height;
  final nw = q.isOdd ? h : w, nh = q.isOdd ? w : h;
  final out = Uint8List(b.rgba.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (nx, ny) = switch (q) {
        1 => (y, w - 1 - x),
        2 => (w - 1 - x, h - 1 - y),
        _ => (h - 1 - y, x),
      };
      final s = (y * w + x) * 4, d = (ny * nw + nx) * 4;
      out[d] = b.rgba[s];
      out[d + 1] = b.rgba[s + 1];
      out[d + 2] = b.rgba[s + 2];
      out[d + 3] = b.rgba[s + 3];
    }
  }
  return DjvuBitmap(nw, nh, out);
}
