/// Testo del documento senza unità UTF-16 spaiate.
///
/// Un XML con `&#xD800;`, un JSON con `\ud800`, un file UTF-16 troncato o un
/// RTF con un numero sbagliato danno una stringa che Flutter non sa
/// disegnare (`string is not well-formed UTF-16`): la pagina diventava una
/// schermata rossa. I parser sono tanti (e di terze parti, come `xml`, che
/// non controlla), così il documento finito passa da qui una volta sola, nel
/// punto in cui il lettore lo consegna alla vista ([parseDocument]).
library;

import '../../utils/safe_text.dart';
import 'parsers/notes_apps.dart' show OutlineDoc, OutlineNode;
import 'reader_document.dart';

/// [doc] con ogni testo passato da [wellFormed]. Senza unità spaiate
/// restituisce lo stesso documento (nessuna copia).
RDoc wellFormedDoc(RDoc doc) {
  var dirty = false;
  String? fix(String? s) {
    if (s == null || !hasLoneSurrogate(s)) return s;
    dirty = true;
    return wellFormed(s);
  }

  final sections = <RSection>[];
  for (final s in doc.sections) {
    final title = fix(s.title)!;
    final blocks = <RBlock>[];
    for (final b in s.blocks) {
      final c = _block(b, fix);
      if (!identical(c, b)) dirty = true;
      blocks.add(c);
    }
    sections.add(RSection(title, blocks));
  }
  final toc = [
    for (final t in doc.toc)
      hasLoneSurrogate(t.title)
          ? RTocEntry(
              fix(t.title)!,
              section: t.section,
              block: t.block,
              level: t.level,
            )
          : t,
  ];
  final notice = fix(doc.notice);
  final limits = [for (final l in doc.limits) fix(l)!];
  final unit = fix(doc.unitLabel)!;
  if (!dirty) return doc;
  return RDoc(
    sections: sections,
    unitLabel: unit,
    toc: toc,
    notice: notice,
    tabs: doc.tabs,
    tables: doc.tables,
    mono: doc.mono,
    limits: limits,
  );
}

RBlock _block(RBlock b, String? Function(String?) fix) {
  switch (b) {
    case RPara():
      var changed = false;
      final spans = <RSpan>[];
      for (final s in b.spans) {
        final c = _span(s, fix);
        if (!identical(c, s)) changed = true;
        spans.add(c);
      }
      final marker = fix(b.marker);
      if (!changed && identical(marker, b.marker)) return b;
      return RPara(spans, style: b.style, level: b.level, marker: marker);
    case RTableRow():
      var changed = false;
      final cells = <String>[];
      for (final c in b.cells) {
        final f = fix(c)!;
        if (!identical(f, c)) changed = true;
        cells.add(f);
      }
      final label = fix(b.label);
      if (!changed && identical(label, b.label)) return b;
      return RTableRow(cells, table: b.table, header: b.header, label: label);
    case RImage():
      final caption = fix(b.caption);
      return identical(caption, b.caption)
          ? b
          : RImage(b.bytes, caption: caption, mime: b.mime);
    case RBreak():
      final label = fix(b.label)!;
      return identical(label, b.label) ? b : RBreak(label);
    case RRule():
      return b;
    case RSlide():
      var changed = false;
      final shapes = <RShape>[];
      for (final s in b.shapes) {
        final c = _shape(s, fix);
        if (!identical(c, s)) changed = true;
        shapes.add(c);
      }
      if (!changed) return b;
      return RSlide(
        width: b.width,
        height: b.height,
        shapes: shapes,
        background: b.background,
        backgroundImage: b.backgroundImage,
      );
  }
}

RSpan _span(RSpan s, String? Function(String?) fix) {
  final text = fix(s.text)!;
  final link = fix(s.link);
  if (identical(text, s.text) && identical(link, s.link)) return s;
  return RSpan(
    text,
    bold: s.bold,
    italic: s.italic,
    underline: s.underline,
    strike: s.strike,
    mono: s.mono,
    link: link,
    seconds: s.seconds,
  );
}

RSlidePara _slidePara(RSlidePara p, String? Function(String?) fix) {
  var changed = false;
  final runs = <RRun>[];
  for (final r in p.runs) {
    final span = _span(r.span, fix);
    if (identical(span, r.span)) {
      runs.add(r);
    } else {
      changed = true;
      runs.add(RRun(span, size: r.size, color: r.color));
    }
  }
  final bullet = fix(p.bullet);
  if (!changed && identical(bullet, p.bullet)) return p;
  return RSlidePara(
    runs,
    align: p.align,
    indent: p.indent,
    hanging: p.hanging,
    bullet: bullet,
    bulletColor: p.bulletColor,
    spaceBefore: p.spaceBefore,
    lineSpacing: p.lineSpacing,
    size: p.size,
  );
}

RShape _shape(RShape s, String? Function(String?) fix) {
  var changed = false;
  final paras = <RSlidePara>[];
  for (final p in s.paras) {
    final c = _slidePara(p, fix);
    if (!identical(c, p)) changed = true;
    paras.add(c);
  }
  RSlideTable? table = s.table;
  if (table != null) {
    var tableChanged = false;
    final rows = <List<RSlideCell>>[];
    for (final row in table.cells) {
      final cells = <RSlideCell>[];
      for (final cell in row) {
        var cellChanged = false;
        final cps = <RSlidePara>[];
        for (final p in cell.paras) {
          final c = _slidePara(p, fix);
          if (!identical(c, p)) cellChanged = true;
          cps.add(c);
        }
        if (cellChanged) {
          tableChanged = true;
          cells.add(RSlideCell(cps, fill: cell.fill, span: cell.span));
        } else {
          cells.add(cell);
        }
      }
      rows.add(cells);
    }
    if (tableChanged) {
      changed = true;
      table = RSlideTable(table.columns, table.rows, rows);
    }
  }
  final label = fix(s.label);
  if (!changed && identical(label, s.label)) return s;
  return RShape(
    x: s.x,
    y: s.y,
    w: s.w,
    h: s.h,
    rotation: s.rotation,
    flipH: s.flipH,
    flipV: s.flipV,
    geometry: s.geometry,
    adjust: s.adjust,
    path: s.path,
    fill: s.fill,
    line: s.line,
    lineWidth: s.lineWidth,
    image: s.image,
    crop: s.crop,
    paras: paras,
    anchor: s.anchor,
    insets: s.insets,
    table: table,
    label: label,
  );
}

/// Come [wellFormedDoc] per una scaletta o una mappa mentale.
OutlineDoc wellFormedOutline(OutlineDoc doc) {
  var dirty = false;
  String? fix(String? s) {
    if (s == null || !hasLoneSurrogate(s)) return s;
    dirty = true;
    return wellFormed(s);
  }

  OutlineNode node(OutlineNode n) => OutlineNode(
    fix(n.text)!,
    note: fix(n.note),
    link: fix(n.link),
    children: [for (final c in n.children) node(c)],
  );

  final roots = [for (final r in doc.roots) node(r)];
  final title = fix(doc.title)!;
  return dirty ? OutlineDoc(title, roots) : doc;
}
