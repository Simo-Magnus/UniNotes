/// Documento del lettore: rappresentazione comune dei formati di testo
/// (Word, ODF, RTF, presentazioni, fogli, e-book, testo, codice, ...).
///
/// I parser producono un [RDoc]; la vista lo mostra, ci cerca dentro e ne
/// ricava indice, posizione e segnalibri. Niente Flutter qui: i parser
/// girano anche in un isolate e nei test puri.
library;

import 'dart:typed_data';

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
  }) : toc = toc ?? [],
       tables = tables ?? [];

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

  bool get isEmpty => _spans.every((s) => s.text.trim().isEmpty);
  String get text => _spans.map((s) => s.text).join();

  void add(RSpan s) {
    if (s.text.isEmpty) return;
    final last = _spans.isEmpty ? null : _spans.last;
    if (last != null &&
        last.bold == s.bold &&
        last.italic == s.italic &&
        last.underline == s.underline &&
        last.strike == s.strike &&
        last.mono == s.mono &&
        last.link == s.link &&
        last.seconds == s.seconds) {
      _spans[_spans.length - 1] = last.withText(last.text + s.text);
    } else {
      _spans.add(s);
    }
  }

  void write(String t) => add(RSpan(t));

  /// Paragrafo con gli spazi in eccesso ai bordi tolti.
  RPara build({RStyle style = RStyle.body, int level = 0, String? marker}) {
    final spans = List<RSpan>.of(_spans);
    _spans.clear();
    if (spans.isNotEmpty) {
      spans[0] = spans[0].withText(spans[0].text.trimLeft());
      final l = spans.length - 1;
      spans[l] = spans[l].withText(spans[l].text.trimRight());
    }
    return RPara(spans, style: style, level: level, marker: marker);
  }

  void clear() => _spans.clear();
}
