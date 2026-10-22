/// Documento del lettore: rappresentazione comune dei formati di testo
/// (Word, ODF, RTF, presentazioni, fogli, e-book, testo, codice, ...).
///
/// I parser producono un [RDoc]; la vista lo mostra, ci cerca dentro e ne
/// ricava indice, posizione e segnalibri. Niente Flutter qui: i parser
/// girano anche in un isolate e nei test puri.
library;

import 'dart:typed_data';

/// Numero decimale letto da un file, solo se finito: `double.tryParse`
/// accetta anche «NaN» e «Infinity» (e «1e999» diventa infinito), valori
/// che rompono l'impaginazione e il disegno delle pagine.
double? parseFinite(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s.trim());
  return v != null && v.isFinite ? v : null;
}

enum RStyle { body, h1, h2, h3, h4, quote, code, caption, list }

/// Un tratto di testo con la stessa formattazione.
class RSpan {
  const RSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.mono = false,
    this.link,
    this.seconds,
  });
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool mono;
  final String? link;

  /// Istante della registrazione (sottotitoli e trascrizioni): toccando il
  /// tratto il lettore salta lì.
  final double? seconds;

  RSpan withText(String t) => RSpan(
    t,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    mono: mono,
    link: link,
    seconds: seconds,
  );
}

sealed class RBlock {
  const RBlock();

  /// Testi cercabili del blocco (una cella per elemento nelle tabelle).
  List<String> get texts;
}

/// Paragrafo, titolo, citazione, codice o voce di elenco.
class RPara extends RBlock {
  const RPara(
    this.spans, {
    this.style = RStyle.body,
    this.level = 0,
    this.marker,
  });
  RPara.text(
    String text, {
    RStyle style = RStyle.body,
    int level = 0,
    String? marker,
  }) : this([RSpan(text)], style: style, level: level, marker: marker);

  final List<RSpan> spans;
  final RStyle style;

  /// Rientro (elenchi annidati).
  final int level;

  /// Segno dell'elenco ("•", "1.").
  final String? marker;

  String get text => spans.map((s) => s.text).join();

  bool get isHeading =>
      style == RStyle.h1 ||
      style == RStyle.h2 ||
      style == RStyle.h3 ||
      style == RStyle.h4;

  int get headingLevel => switch (style) {
    RStyle.h1 => 1,
    RStyle.h2 => 2,
    RStyle.h3 => 3,
    RStyle.h4 => 4,
    _ => 0,
  };

  @override
  List<String> get texts => [text];
}

/// Riga di una tabella. Le righe della stessa tabella hanno lo stesso
/// [table] e condividono le larghezze di colonna di [RDoc.tables].
class RTableRow extends RBlock {
  const RTableRow(
    this.cells, {
    required this.table,
    this.header = false,
    this.label,
  });
  final List<String> cells;
  final int table;
  final bool header;

  /// Etichetta a sinistra (numero di riga nei fogli di calcolo).
  final String? label;

  @override
  List<String> get texts => cells;
}

class RImage extends RBlock {
  const RImage(this.bytes, {this.caption, this.mime});
  final Uint8List bytes;
  final String? caption;
  final String? mime;

  @override
  List<String> get texts => [caption ?? ''];
}

/// Intestazione di una sezione (pagina, diapositiva, foglio, nota).
class RBreak extends RBlock {
  const RBreak(this.label);
  final String label;

  @override
  List<String> get texts => [label];
}

class RRule extends RBlock {
  const RRule();

  @override
  List<String> get texts => const [''];
}

enum RAlign { left, center, right, justify }

enum RAnchor { top, middle, bottom }

/// Tratto di testo di una diapositiva: dimensione in punti e colore (ARGB).
class RRun {
  const RRun(this.span, {this.size = 18, this.color});
  final RSpan span;
  final double size;
  final int? color;
}

/// Paragrafo di una casella di testo di una diapositiva.
class RSlidePara {
  const RSlidePara(
    this.runs, {
    this.align = RAlign.left,
    this.indent = 0,
    this.hanging = 0,
    this.bullet,
    this.bulletColor,
    this.spaceBefore = 0,
    this.lineSpacing = 1,
    this.size = 18,
  });
  final List<RRun> runs;
  final RAlign align;

  /// Rientro a sinistra del testo, in punti.
  final double indent;

  /// Spazio del segno dell'elenco a sinistra del testo, in punti.
  final double hanging;

  /// Segno dell'elenco ("•", "1.").
  final String? bullet;
  final int? bulletColor;

  /// Spazio prima, in punti.
  final double spaceBefore;

  /// Interlinea (1 = singola).
  final double lineSpacing;

  /// Dimensione del testo del paragrafo (anche vuoto), in punti.
  final double size;

  String get text => runs.map((r) => r.span.text).join();
}

/// Cella di una tabella di una diapositiva.
class RSlideCell {
  const RSlideCell(this.paras, {this.fill, this.span = 1});
  final List<RSlidePara> paras;
  final int? fill;

  /// Colonne occupate (celle unite).
  final int span;

  String get text => paras.map((p) => p.text).join('\n');
}

/// Tabella di una diapositiva: larghezze delle colonne e altezze delle
/// righe in punti.
class RSlideTable {
  const RSlideTable(this.columns, this.rows, this.cells);
  final List<double> columns;
  final List<double> rows;

  /// Righe di celle (le celle coperte da un'unione non ci sono).
  final List<List<RSlideCell>> cells;
}

/// Comando di un tracciato, con i punti in frazioni del riquadro (0–1):
/// 0 sposta, 1 linea, 2 curva cubica (3 punti), 3 chiude.
class RPathCmd {
  const RPathCmd(this.op, [this.points = const []]);
  final int op;
  final List<double> points;
}

/// Forma di una diapositiva: riquadro in punti, riempimento, contorno,
/// immagine, testo o tabella.
class RShape {
  const RShape({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.rotation = 0,
    this.flipH = false,
    this.flipV = false,
    this.geometry = 'rect',
    this.adjust,
    this.path,
    this.fill,
    this.line,
    this.lineWidth = 1,
    this.image,
    this.crop = const [0, 0, 0, 0],
    this.paras = const [],
    this.anchor = RAnchor.top,
    this.insets = const [7.2, 3.6, 7.2, 3.6],
    this.table,
    this.label,
  });
  final double x;
  final double y;
  final double w;
  final double h;

  /// Gradi, in senso orario.
  final double rotation;
  final bool flipH;
  final bool flipV;

  /// Forma predefinita ("rect", "roundRect", "ellipse", "line", ...).
  final String geometry;

  /// Regolazione della forma predefinita (es. punta del triangolo, raggio
  /// degli angoli), in frazione; null = valore predefinito.
  final double? adjust;

  /// Tracciati di una forma disegnata a mano (al posto di [geometry]).
  final List<List<RPathCmd>>? path;
  final int? fill;
  final int? line;
  final double lineWidth;
  final Uint8List? image;

  /// Ritaglio dell'immagine: sinistra, alto, destra, basso (frazioni).
  final List<double> crop;
  final List<RSlidePara> paras;
  final RAnchor anchor;

  /// Margini interni del testo: sinistra, alto, destra, basso (punti).
  final List<double> insets;
  final RSlideTable? table;

  /// Contenuto che l'app non disegna (es. "Grafico"): riquadro con il nome.
  final String? label;
}

/// Diapositiva disegnata come nell'originale: forme, immagini, tabelle e
/// caselle di testo al loro posto (misure in punti).
class RSlide extends RBlock {
  const RSlide({
    required this.width,
    required this.height,
    required this.shapes,
    this.background = 0xFFFFFFFF,
    this.backgroundImage,
  });
  final double width;
  final double height;
  final List<RShape> shapes;
  final int background;
  final Uint8List? backgroundImage;

  /// Testi nell'ordine delle forme: un paragrafo (o una cella) per testo.
  @override
  List<String> get texts => [
    for (final s in shapes) ...[
      for (final p in s.paras) p.text,
      if (s.table != null)
        for (final row in s.table!.cells)
          for (final c in row) c.text,
    ],
  ];
}

/// Pagina, diapositiva, foglio, capitolo o nota.
class RSection {
  RSection(this.title, [List<RBlock>? blocks]) : blocks = blocks ?? [];
  final String title;
  final List<RBlock> blocks;
}

class RTocEntry {
  const RTocEntry(
    this.title, {
    required this.section,
    this.block = 0,
    this.level = 0,
  });
  final String title;
  final int section;

  /// Blocco dentro la sezione.
  final int block;
  final int level;
}

/// Larghezze di una tabella, in caratteri (stimate dal contenuto).
class RTable {
  RTable(this.columns);
  final List<int> columns;

  /// Allarga le colonne per contenere [cells].
  void fit(List<String> cells) {
    for (var i = 0; i < cells.length; i++) {
      final w = cells[i].length.clamp(1, 60);
      if (i >= columns.length) {
        columns.add(w);
      } else if (w > columns[i]) {
        columns[i] = w;
      }
    }
  }
}

class RDoc {
  RDoc({
    required this.sections,
    this.unitLabel = 'Pagina',
    List<RTocEntry>? toc,
    this.notice,
    this.tabs = false,
    List<RTable>? tables,
    this.mono = false,
    this.limits = const [],
  }) : toc = toc ?? [],
       tables = tables ?? [];

  /// Parti del file che l'app non mostra (es. "grafici", "formule"): se ce
  /// ne sono, all'apertura si propone l'app di riferimento.
  final List<String> limits;

  final List<RSection> sections;

  /// Nome dell'unità di navigazione ("Pagina", "Diapositiva", "Foglio", ...).
  final String unitLabel;
  final List<RTocEntry> toc;

  /// Avviso sopra il documento (es. "solo testo estratto").
  final String? notice;

  /// Sezioni come schede (fogli di calcolo).
  final bool tabs;
  final List<RTable> tables;

  /// Testo a spaziatura fissa (codice, registri).
  final bool mono;

  /// Testo semplice dell'intero documento (test, copia, ricerca).
  String get plainText => [
    for (final s in sections)
      for (final b in s.blocks) b.texts.join('\t'),
  ].join('\n');

  /// Indice: quello del formato o, se manca, dai titoli.
  List<RTocEntry> get outline {
    if (toc.isNotEmpty) return toc;
    final out = <RTocEntry>[];
    for (var s = 0; s < sections.length; s++) {
      final blocks = sections[s].blocks;
      for (var b = 0; b < blocks.length; b++) {
        final block = blocks[b];
        if (block is RPara && block.isHeading && block.text.trim().isNotEmpty) {
          out.add(
            RTocEntry(
              block.text.trim(),
              section: s,
              block: b,
              level: block.headingLevel - 1,
            ),
          );
        }
      }
    }
    if (out.isEmpty && sections.length > 1) {
      for (var s = 0; s < sections.length; s++) {
        out.add(RTocEntry(sections[s].title, section: s));
      }
    }
    return out;
  }
}

/// Costruttore comodo di paragrafi con formattazione mista.
class RParaBuilder {
  final _spans = <RSpan>[];

  /// Ultimo tratto ancora aperto: i pezzi con la stessa formattazione si
  /// accumulano qui. Prima si univano con `testo + pezzo`, che con centinaia
  /// di migliaia di pezzi piccoli (un RTF con una riga per carattere)
  /// copiava gigabyte di testo e bloccava l'app.
  RSpan? _open;
  final _buf = StringBuffer();

  void _close() {
    final o = _open;
    if (o == null) return;
    _spans.add(o.withText(_buf.toString()));
    _buf.clear();
    _open = null;
  }

  bool get isEmpty {
    _close();
    return _spans.every((s) => s.text.trim().isEmpty);
  }

  String get text {
    _close();
    return _spans.map((s) => s.text).join();
  }

  void add(RSpan s) {
    if (s.text.isEmpty) return;
    final last = _open;
    if (last != null &&
        last.bold == s.bold &&
        last.italic == s.italic &&
        last.underline == s.underline &&
        last.strike == s.strike &&
        last.mono == s.mono &&
        last.link == s.link &&
        last.seconds == s.seconds) {
      _buf.write(s.text);
    } else {
      _close();
      _open = s;
      _buf.write(s.text);
    }
  }

  void write(String t) => add(RSpan(t));

  /// Paragrafo con gli spazi in eccesso ai bordi tolti.
  RPara build({RStyle style = RStyle.body, int level = 0, String? marker}) {
    _close();
    final spans = List<RSpan>.of(_spans);
    _spans.clear();
    if (spans.isNotEmpty) {
      spans[0] = spans[0].withText(spans[0].text.trimLeft());
      final l = spans.length - 1;
      spans[l] = spans[l].withText(spans[l].text.trimRight());
    }
    return RPara(spans, style: style, level: level, marker: marker);
  }

  void clear() {
    _spans.clear();
    _buf.clear();
    _open = null;
  }
}
