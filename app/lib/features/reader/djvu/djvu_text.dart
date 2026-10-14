/// Testo nascosto delle pagine DjVu (blocchi TXTa/TXTz, specifica 8.3.5):
/// testo UTF-8 e zone annidate (pagina, colonna, regione, paragrafo, riga,
/// parola, carattere) con i rettangoli sulla pagina.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'iff.dart';

/// Parola (o riga) con il rettangolo in pixel della pagina, origine in
/// alto a sinistra.
class DjvuWord {
  const DjvuWord(this.text, this.left, this.top, this.right, this.bottom);
  final String text;
  final int left;
  final int top;
  final int right;
  final int bottom;
}

class DjvuPageText {
  const DjvuPageText(this.text, this.words);

  /// Testo della pagina (separatori di zona convertiti in a capo).
  final String text;

  /// Parole nell'ordine di lettura (vuoto se il livello non c'è).
  final List<DjvuWord> words;

  static const empty = DjvuPageText('', []);
}

class _Zone {
  _Zone(this.type, this.x0, this.y0, this.x1, this.y1, this.start, this.len);
  final int type;
  final int x0, y0, x1, y1; // dal basso
  final int start, len;
  final children = <_Zone>[];
}

/// Separatori di zona (VT, GS, RS, US) e NUL → spazi o a capo.
String _clean(String s) => s
    .replaceAll(RegExp('[\u000B\u001D\u001E\u001F]'), '\n')
    .replaceAll('\u0000', '')
    .replaceAll(RegExp(r'[ \t]+\n'), '\n');

/// Testo di un blocco TXTa (o di un TXTz già decompresso) di una pagina
/// alta [pageHeight] pixel.
DjvuPageText parseDjvuText(Uint8List b, int pageHeight) {
  if (b.length < 3) return DjvuPageText.empty;
  final len = be24(b, 0);
  if (3 + len > b.length) return DjvuPageText.empty;
  final raw = Uint8List.sublistView(b, 3, 3 + len);
  final text = _clean(utf8.decode(raw, allowMalformed: true));
  var pos = 3 + len;
  if (pos >= b.length) return DjvuPageText(text, const []);
  pos++; // versione
  final roots = <_Zone>[];

  _Zone? read(_Zone? parent, _Zone? prev) {
    if (pos + 17 > b.length) return null;
    final type = b[pos];
    var x = be16(b, pos + 1) - 0x8000;
    var y = be16(b, pos + 3) - 0x8000;
    final w = be16(b, pos + 5) - 0x8000;
    final h = be16(b, pos + 7) - 0x8000;
    final off = be16(b, pos + 9) - 0x8000;
    final tlen = be24(b, pos + 11);
    final kids = be24(b, pos + 14);
    pos += 17;
    var start = off;
    if (prev != null) {
      if (type == 1 || type == 4 || type == 5) {
        // Pagina, paragrafo, riga: dall'angolo in basso a sinistra del
        // precedente, y verso il basso.
        x += prev.x0;
        y = prev.y0 - (y + h);
      } else {
        // Colonna, parola, carattere: dall'angolo in basso a destra.
        x += prev.x1;
        y += prev.y0;
      }
      start += prev.start + prev.len;
    } else if (parent != null) {
      x += parent.x0;
      y = parent.y1 - (y + h);
      start += parent.start;
    }
    final z = _Zone(type, x, y, x + w, y + h, start, tlen);
    _Zone? last;
    for (var i = 0; i < kids && pos < b.length; i++) {
      final c = read(z, last);
      if (c == null) break;
      z.children.add(c);
      last = c;
    }
    return z;
  }

  _Zone? last;
  while (pos + 17 <= b.length) {
    final z = read(null, last);
    if (z == null) break;
    roots.add(z);
    last = z;
  }
  // Parole (zona 6); se mancano, le righe (5) o le zone più fini.
  final words = <DjvuWord>[];
  String slice(_Zone z) {
    final s = z.start.clamp(0, raw.length);
    final e = (z.start + z.len).clamp(s, raw.length);
    return _clean(
      utf8.decode(Uint8List.sublistView(raw, s, e), allowMalformed: true),
    ).trim();
  }

  void walk(_Zone z) {
    final leaf =
        z.type >= 6 ||
        z.children.isEmpty ||
        (z.type == 5 && z.children.every((c) => c.type == 7));
    if (leaf) {
      final t = slice(z);
      if (t.isNotEmpty) {
        words.add(
          DjvuWord(t, z.x0, pageHeight - z.y1, z.x1, pageHeight - z.y0),
        );
      }
      return;
    }
    for (final c in z.children) {
      walk(c);
    }
  }

  for (final r in roots) {
    walk(r);
  }
  return DjvuPageText(text, words);
}
