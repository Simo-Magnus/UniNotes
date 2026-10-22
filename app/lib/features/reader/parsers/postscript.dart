import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../reader_document.dart';

/// PostScript (.ps) ed EPS (.eps): per disegnarli servirebbe un
/// interprete completo, qui si estrae il testo (le stringhe passate agli
/// operatori show/ashow/widthshow/awidthshow/xshow/yshow/xyshow/kshow/
/// cshow e alle procedure che li chiamano, una pagina per showpage) e si
/// mostra l'anteprima incorporata degli EPS: TIFF nell'intestazione
/// binaria DOS (C5D0D3C6) o bitmap EPSI (%%BeginPreview).

const _showOps = {
  'show', 'ashow', 'widthshow', 'awidthshow', 'xshow', 'yshow', 'xyshow', //
  'kshow', 'cshow', 'glyphshow',
};

/// Sezione PostScript, anteprima TIFF/WMF: (inizio, lunghezza).
class _DosEps {
  _DosEps(this.ps, this.tiff, this.wmf);
  final (int, int) ps;
  final (int, int) tiff;
  final (int, int) wmf;
}

_DosEps? _dosHeader(Uint8List b) {
  if (b.length < 30 ||
      b[0] != 0xC5 ||
      b[1] != 0xD0 ||
      b[2] != 0xD3 ||
      b[3] != 0xC6) {
    return null;
  }
  final d = ByteData.sublistView(b);
  int u(int o) => d.getUint32(o, Endian.little);
  return _DosEps((u(4), u(8)), (u(20), u(24)), (u(12), u(16)));
}

/// Immagine EPSI: "%%BeginPreview: w h profondità righe", poi righe "% hex".
Uint8List? _epsiPreview(String src) {
  final m = RegExp(r'%%BeginPreview:\s*(\d+)\s+(\d+)\s+(\d+)\s+\d+')
      .firstMatch(src);
  if (m == null) return null;
  final w = int.parse(m.group(1)!);
  final h = int.parse(m.group(2)!);
  final depth = int.parse(m.group(3)!);
  if (w <= 0 || h <= 0 || w > 4000 || h > 4000) return null;
  if (!const {1, 2, 4, 8}.contains(depth)) return null;
  final end = src.indexOf('%%EndPreview', m.end);
  final body = src.substring(m.end, end < 0 ? src.length : end);
  final hex = StringBuffer();
  for (final line in const LineSplitter().convert(body)) {
    final t = line.trim();
    if (t.startsWith('%')) {
      hex.write(t.substring(1).replaceAll(RegExp(r'\s'), ''));
    }
  }
  final s = hex.toString();
  final bytes = Uint8List(s.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.tryParse(s.substring(2 * i, 2 * i + 2), radix: 16) ?? 0;
  }
  final row = (w * depth + 7) ~/ 8;
  if (bytes.length < row * h) return null;
  final im = img.Image(width: w, height: h, numChannels: 1);
  final max = (1 << depth) - 1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final bit = x * depth;
      final byte = bytes[y * row + (bit >> 3)];
      final v = (byte >> (8 - depth - (bit & 7))) & max;
      // EPSI: 0 è bianco, il massimo è nero.
      final g = 255 - (v * 255 ~/ max);
      im.setPixelRgb(x, y, g, g, g);
    }
  }
  return img.encodePng(im);
}

class _Lexer {
  _Lexer(this.s);
  final String s;
  int i = 0;

  /// Prossimo elemento: (tipo, testo). Tipi: 's' stringa, 'n' nome,
  /// 'l' nome letterale (/x), '{' '}' '[' ']', 'c' commento DSC, '' fine.
  (String, String) next() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x25) {
        // Commento: si tengono quelli DSC (%%Page:).
        final e = s.indexOf('\n', i);
        final line = s.substring(i, e < 0 ? s.length : e);
        i = e < 0 ? s.length : e + 1;
        if (line.startsWith('%%')) return ('c', line);
        continue;
      }
      if (c <= 0x20) {
        i++;
        continue;
      }
      if (c == 0x28) return ('s', _string());
      if (c == 0x3C) {
        if (i + 1 < s.length && s[i + 1] == '<') {
          i += 2;
          return ('n', '<<');
        }
        if (i + 1 < s.length && s[i + 1] == '~') {
          final e = s.indexOf('~>', i);
          i = e < 0 ? s.length : e + 2;
          continue;
        }
        return ('s', _hex());
      }
      if (c == 0x3E && i + 1 < s.length && s[i + 1] == '>') {
        i += 2;
        return ('n', '>>');
      }
      if ('{}[]'.contains(s[i])) {
        i++;
        return (s[i - 1], s[i - 1]);
      }
      final literal = c == 0x2F;
      if (literal) i++;
      final st = i;
      while (i < s.length) {
        final d = s.codeUnitAt(i);
        if (d <= 0x20 || '()<>[]{}/%'.contains(s[i])) break;
        i++;
      }
      if (i == st && !literal) {
        i++;
        continue;
      }
      return (literal ? 'l' : 'n', s.substring(st, i));
    }
    return ('', '');
  }

  String _string() {
    i++; // (
    final out = StringBuffer();
    var depth = 1;
    while (i < s.length) {
      final ch = s[i];
      if (ch == '\\') {
        i++;
        if (i >= s.length) break;
        final e = s[i];
        switch (e) {
          case 'n':
            out.write('\n');
          case 'r':
            out.write('\r');
          case 't':
            out.write('\t');
          case 'b' || 'f':
            break;
          case '\n':
            break; // continuazione di riga
          case '\r':
            if (i + 1 < s.length && s[i + 1] == '\n') i++;
          default:
            if ('01234567'.contains(e)) {
              var n = 0, k = 0;
              while (k < 3 && i < s.length && '01234567'.contains(s[i])) {
                n = n * 8 + int.parse(s[i]);
                i++;
                k++;
              }
              out.writeCharCode(n & 0xFF);
              continue;
            }
            out.write(e);
        }
        i++;
        continue;
      }
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) {
          i++;
          break;
        }
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  String _hex() {
    i++; // <
    final e = s.indexOf('>', i);
    final h = s
        .substring(i, e < 0 ? s.length : e)
        .replaceAll(RegExp(r'\s'), '');
    i = e < 0 ? s.length : e + 1;
    final bytes = <int>[];
    for (var k = 0; k + 1 < h.length; k += 2) {
      bytes.add(int.tryParse(h.substring(k, k + 2), radix: 16) ?? 0);
    }
    if (h.length.isOdd) {
      bytes.add((int.tryParse(h[h.length - 1], radix: 16) ?? 0) << 4);
    }
    // Due byte per carattere (font CID) se metà sono zeri: UTF-16BE.
    final zeros = [for (var k = 0; k < bytes.length; k += 2) bytes[k]]
        .where((v) => v == 0)
        .length;
    if (bytes.length >= 4 &&
        bytes.length.isEven &&
        zeros * 2 >= bytes.length / 2) {
      return String.fromCharCodes([
        for (var k = 0; k + 1 < bytes.length; k += 2)
          (bytes[k] << 8) | bytes[k + 1],
      ]);
    }
    return String.fromCharCodes(bytes);
  }
}

/// Testo PostScript → righe per pagina.
List<List<String>> postScriptPages(String src) {
  final lx = _Lexer(src);
  final pages = <List<String>>[[]];
  final shows = Set<String>.of(_showOps);
  final line = StringBuffer();
  String? last;
  double? lineY;
  final nums = <double>[];
  // Definizioni "/nome { … show … } def": il nome diventa un operatore
  // di testo.
  String? defining;
  var braceDepth = 0;
  var bodyShows = false;

  void endLine() {
    final t = line.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (t.isNotEmpty) pages.last.add(t);
    line.clear();
  }

  while (true) {
    final (type, tok) = lx.next();
    if (type.isEmpty) break;
    switch (type) {
      case 'c':
        if (tok.startsWith('%%Page:') && pages.last.isNotEmpty) {
          endLine();
          pages.add([]);
          lineY = null;
        }
        continue;
      case 's':
        if (braceDepth == 0) last = tok;
        continue;
      case 'l':
        if (braceDepth == 0) defining = tok;
        nums.clear();
        continue;
      case '{':
        braceDepth++;
        if (braceDepth == 1) bodyShows = false;
        continue;
      case '}':
        if (braceDepth > 0) braceDepth--;
        continue;
      case '[' || ']':
        continue;
    }
    // Nome (operatore o procedura).
    final n = parseFinite(tok);
    if (n != null) {
      nums.add(n);
      if (nums.length > 6) nums.removeAt(0);
      continue;
    }
    if (braceDepth > 0) {
      if (shows.contains(tok)) bodyShows = true;
      continue;
    }
    if ((tok == 'def' || tok == 'bind') && defining != null) {
      if (bodyShows && tok == 'def') shows.add(defining);
      if (tok == 'def') {
        defining = null;
        bodyShows = false;
      }
      nums.clear();
      continue;
    }
    if (tok == 'moveto' && nums.length >= 2) {
      final y = nums[nums.length - 1];
      if (lineY != null && (y - lineY).abs() > 0.5) endLine();
      lineY = y;
    } else if (tok == 'rmoveto' && nums.length >= 2) {
      final dy = nums[nums.length - 1];
      if (dy.abs() > 0.5) {
        endLine();
        lineY = (lineY ?? 0) + dy;
      } else if (nums[nums.length - 2] > 0.5 && line.isNotEmpty) {
        line.write(' ');
      }
    } else if (shows.contains(tok)) {
      final s = last;
      if (s != null) {
        if (line.isNotEmpty &&
            !line.toString().endsWith(' ') &&
            !s.startsWith(' ')) {
          line.write(' ');
        }
        line.write(s);
        last = null;
      }
    } else if (tok == 'showpage' || tok == 'copypage') {
      endLine();
      if (pages.last.isNotEmpty) pages.add([]);
      lineY = null;
    }
    nums.clear();
  }
  endLine();
  if (pages.length > 1 && pages.last.isEmpty) pages.removeLast();
  return pages;
}

RDoc parsePostScript(Uint8List bytes) {
  final dos = _dosHeader(bytes);
  Uint8List? preview;
  var notice =
      'Solo il testo della pagina: i disegni PostScript non si '
      'possono mostrare. Per la resa completa aprilo con un\'altra app o '
      'convertilo in PDF.';
  String src;
  if (dos != null) {
    final (ps, psLen) = dos.ps;
    src = latin1.decode(
      Uint8List.sublistView(
        bytes,
        ps.clamp(0, bytes.length),
        (ps + psLen).clamp(0, bytes.length),
      ),
    );
    final (t, tl) = dos.tiff;
    if (tl > 0 && t + tl <= bytes.length) {
      final im = img.decodeTiff(Uint8List.sublistView(bytes, t, t + tl));
      if (im != null) preview = img.encodePng(im);
    }
    if (preview == null && dos.wmf.$2 > 0) {
      notice = 'L\'anteprima WMF incorporata non si può mostrare. $notice';
    }
  } else {
    src = latin1.decode(bytes);
  }
  preview ??= _epsiPreview(src);
  final title = RegExp(
    r'^%%Title:\s*(.+)$',
    multiLine: true,
  ).firstMatch(src)?.group(1)?.trim().replaceAll(RegExp(r'^\(|\)$'), '');
  final pages = postScriptPages(src);
  final sections = <RSection>[];
  for (var i = 0; i < pages.length; i++) {
    sections.add(
      RSection('Pagina ${i + 1}', [for (final l in pages[i]) RPara.text(l)]),
    );
  }
  if (sections.isEmpty) sections.add(RSection('Pagina 1'));
  if (preview != null) {
    sections.first.blocks.insert(
      0,
      RImage(preview, caption: 'Anteprima incorporata'),
    );
  }
  if (sections.every((s) => s.blocks.isEmpty)) {
    sections.first.blocks.add(
      RPara.text(
        'Nessun testo trovato: il file disegna il testo come curve o '
        'immagini.',
        style: RStyle.caption,
      ),
    );
  }
  if (title != null && title.isNotEmpty && sections.length == 1) {
    sections.first.blocks.insert(0, RPara.text(title, style: RStyle.h1));
  }
  return RDoc(
    sections: sections,
    notice: preview != null
        ? 'Anteprima incorporata e testo estratto: i disegni PostScript non '
              'si possono mostrare.'
        : notice,
  );
}
