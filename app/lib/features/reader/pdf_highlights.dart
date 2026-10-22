import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/services/portable_path.dart';

/// Colori dell'evidenziatore: distinti tra loro e leggibili sotto il testo
/// nero (si disegnano in trasparenza).
const kHighlightColors = <(String, Color)>[
  ('Giallo', Color(0xFFFFEB3B)),
  ('Verde', Color(0xFF66BB6A)),
  ('Azzurro', Color(0xFF4FC3F7)),
  ('Rosa', Color(0xFFF06292)),
  ('Arancione', Color(0xFFFFA726)),
];

/// Un tratto evidenziato: pagina, rettangoli (uno per riga, in coordinate
/// PDF), colore e testo.
class PdfHighlight {
  const PdfHighlight({
    required this.page,
    required this.rects,
    required this.color,
    required this.text,
  });

  final int page;
  final List<PdfRect> rects;
  final int color;
  final String text;

  Map<String, Object?> toJson() => {
    'page': page,
    'color': color,
    'text': text,
    'rects': [
      for (final r in rects) [r.left, r.top, r.right, r.bottom],
    ],
  };

  static PdfHighlight fromJson(Map<String, Object?> m) => PdfHighlight(
    page: m['page'] as int,
    color: m['color'] as int,
    text: (m['text'] as String?) ?? '',
    rects: [
      for (final r in (m['rects'] as List).cast<List>())
        PdfRect(
          (r[0] as num).toDouble(),
          (r[1] as num).toDouble(),
          (r[2] as num).toDouble(),
          (r[3] as num).toDouble(),
        ),
    ],
  );
}

/// Evidenziazioni di un PDF, salvate nell'app (il file PDF non viene mai
/// modificato): una per documento, in base al percorso.
class PdfHighlights extends ChangeNotifier {
  PdfHighlights(this.path);
  final String path;
  final List<PdfHighlight> items = [];

  /// File delle evidenziazioni: per i PDF dentro l'app il nome viene dal
  /// percorso relativo (uguale su tutti i dispositivi, la cartella si
  /// sincronizza con OneDrive e Google Drive); quello delle versioni
  /// precedenti (dal percorso assoluto) si rinomina alla prima apertura.
  Future<File> _file() async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'evidenziazioni'),
    );
    await dir.create(recursive: true);
    String name(String s) => '${sha1.convert(utf8.encode(s))}.json';
    final f = File(p.join(dir.path, name(portablePath(path))));
    final old = File(p.join(dir.path, name(p.normalize(path))));
    if (old.path != f.path && !await f.exists() && await old.exists()) {
      try {
        await old.rename(f.path);
      } catch (_) {
        return old;
      }
    }
    return f;
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      // Una voce rovinata (file sincronizzato da un'altra versione, scritto a
      // metà) si salta: non deve far perdere le altre al prossimo salvataggio.
      final loaded = <PdfHighlight>[];
      for (final e in list) {
        try {
          loaded.add(PdfHighlight.fromJson((e as Map).cast<String, Object?>()));
        } catch (_) {}
      }
      items
        ..clear()
        ..addAll(loaded);
      notifyListeners();
    } catch (_) {
      // file danneggiato: si riparte senza evidenziazioni
    }
  }

  Future<void> _save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode([for (final h in items) h.toJson()]));
    notifyListeners();
  }

  /// Evidenzia i tratti selezionati con [color].
  Future<void> add(List<PdfPageTextRange> ranges, Color color) async {
    for (final r in ranges) {
      final lines = lineRects(r.pageText.charRects.sublist(r.start, r.end));
      if (lines.isEmpty) continue;
      items.add(
        PdfHighlight(
          page: r.pageNumber,
          rects: lines,
          color: color.toARGB32(),
          text: r.text,
        ),
      );
    }
    await _save();
  }

  /// Toglie le evidenziazioni che toccano i tratti selezionati.
  Future<void> removeOverlapping(List<PdfPageTextRange> ranges) async {
    items.removeWhere((h) {
      for (final r in ranges) {
        if (r.pageNumber != h.page) continue;
        final b = r.bounds;
        for (final x in h.rects) {
          final overlap = x.left < b.right &&
              b.left < x.right &&
              x.bottom < b.top &&
              b.bottom < x.top;
          if (overlap) return true;
        }
      }
      return false;
    });
    await _save();
  }

  /// Disegno sulla pagina (da usare in `pagePaintCallbacks`).
  void paint(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    for (final h in items) {
      if (h.page != page.pageNumber) continue;
      final paint = Paint()
        ..color = Color(h.color).withValues(alpha: 0.38)
        ..blendMode = BlendMode.multiply;
      for (final r in h.rects) {
        canvas.drawRect(
          r.toRect(page: page, scaledPageSize: pageRect.size).translate(
            pageRect.left,
            pageRect.top,
          ),
          paint,
        );
      }
    }
  }
}

/// Riunisce i rettangoli dei caratteri in un rettangolo per riga (i caratteri
/// della stessa riga hanno la base quasi uguale).
List<PdfRect> lineRects(List<PdfRect> chars) {
  final out = <PdfRect>[];
  PdfRect? cur;
  for (final c in chars) {
    if (c.right - c.left <= 0 && c.top - c.bottom <= 0) continue;
    final h = (c.top - c.bottom).abs();
    if (cur != null && ((c.bottom - cur.bottom).abs() <= h * 0.5)) {
      cur = cur.merge(c);
    } else {
      if (cur != null) out.add(cur);
      cur = c;
    }
  }
  if (cur != null) out.add(cur);
  return out;
}
