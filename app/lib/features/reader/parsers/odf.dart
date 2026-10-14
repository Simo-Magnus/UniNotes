import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'text_formats.dart';
import 'zip_util.dart';

/// OpenDocument (LibreOffice): testo (.odt .ott), presentazioni (.odp
/// .otp) e fogli di calcolo (.ods .ots), da `content.xml`.

class _OdfFmt {
  const _OdfFmt({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
  });
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
}

class OdfReader {
  OdfReader(Uint8List bytes) : zip = Zip(bytes) {
    content = zip.xml('content.xml');
    if (content == null) throw const FormatException('content.xml mancante');
    for (final source in [zip.xml('styles.xml'), content]) {
      if (source == null) continue;
      for (final s in source.rootElement.desc('style')) {
        final name = s.attr('name');
        final tp = s.kid('text-properties');
        if (name == null) continue;
        if (tp != null) {
          final u = tp.attr('text-underline-style');
          final st = tp.attr('text-line-through-style');
          styles[name] = _OdfFmt(
            bold:
                tp.attr('font-weight') == 'bold' ||
                (int.tryParse(tp.attr('font-weight') ?? '') ?? 0) >= 600,
            italic: tp.attr('font-style') == 'italic',
            underline: u != null && u != 'none',
            strike: st != null && st != 'none',
          );
        }
        final parent = s.attr('parent-style-name');
        if (parent != null) parents[name] = parent;
      }
    }
  }

  final Zip zip;
  late final XmlDocument? content;
  final styles = <String, _OdfFmt>{};
  final parents = <String, String>{};
  final tables = <RTable>[];

  _OdfFmt _fmt(String? style, _OdfFmt base) {
    var s = style;
    for (var i = 0; s != null && i < 5; i++) {
      final f = styles[s];
      if (f != null) {
        return _OdfFmt(
          bold: base.bold || f.bold,
          italic: base.italic || f.italic,
          underline: base.underline || f.underline,
          strike: base.strike || f.strike,
        );
      }
      s = parents[s];
    }
    return base;
  }

  XmlElement? get body => content!.rootElement.kid('body');

  /// Testo in linea di un paragrafo/titolo.
  void _inline(
    XmlNode n,
    RParaBuilder b,
    _OdfFmt f,
    List<RImage> images, {
    String? link,
  }) {
    for (final c in n.children) {
      if (c is XmlText) {
        b.add(
          RSpan(
            c.value.replaceAll(RegExp(r'\s+'), ' '),
            bold: f.bold,
            italic: f.italic,
            underline: f.underline,
            strike: f.strike,
            link: link,
          ),
        );
        continue;
      }
      if (c is! XmlElement) continue;
      switch (c.local) {
        case 's':
          b.write(' ' * (int.tryParse(c.attr('c') ?? '') ?? 1));
        case 'tab':
          b.write('\t');
        case 'line-break':
          b.write('\n');
        case 'span':
          _inline(c, b, _fmt(c.attr('style-name'), f), images, link: link);
        case 'a':
          _inline(c, b, f, images, link: c.attr('href'));
        case 'note':
          // Nota a piè di pagina: in linea, tra parentesi quadre.
          final body = c.kid('note-body');
          if (body != null) {
            b.write(' [${body.innerText.trim()}]');
          }
        case 'frame':
          _frame(c, images, b);
        case 'annotation' ||
            'bookmark' ||
            'bookmark-start' ||
            'bookmark-end' ||
            'soft-page-break':
          break;
        default:
          _inline(c, b, f, images, link: link);
      }
    }
  }

  void _frame(XmlElement frame, List<RImage> images, RParaBuilder b) {
    final img = frame.kid('image');
    final href = img?.attr('href');
    if (href != null) {
      final data = zip.bytes(href);
      if (data != null) images.add(RImage(data));
    }
    final box = frame.kid('text-box');
    if (box != null) {
      b.write(' ${box.innerText.trim()} ');
    }
  }

  /// Blocchi di testo (corpo di un documento, casella di testo, cella).
  void blocks(
    XmlElement parent,
    List<RBlock> out, {
    int listLevel = 0,
    String? marker,
    RStyle? force,
  }) {
    for (final e in parent.childElements) {
      switch (e.local) {
        case 'h' || 'p':
          final b = RParaBuilder();
          final images = <RImage>[];
          _inline(e, b, _fmt(e.attr('style-name'), const _OdfFmt()), images);
          if (!b.isEmpty) {
            if (e.local == 'h') {
              final lvl = int.tryParse(e.attr('outline-level') ?? '') ?? 1;
              out.add(
                b.build(
                  style: switch (lvl) {
                    1 => RStyle.h1,
                    2 => RStyle.h2,
                    3 => RStyle.h3,
                    _ => RStyle.h4,
                  },
                ),
              );
            } else if (marker != null) {
              out.add(
                b.build(style: RStyle.list, level: listLevel, marker: marker),
              );
              marker = null;
            } else {
              out.add(b.build(style: force ?? RStyle.body));
            }
          }
          out.addAll(images);
        case 'list':
          var n = 1;
          final numbered = _numberedList(e);
          for (final item in e.childElements) {
            if (item.local != 'list-item' && item.local != 'list-header') {
              continue;
            }
            blocks(
              item,
              out,
              listLevel: listLevel + (parent.local == 'list-item' ? 1 : 0),
              marker: numbered ? '${n++}.' : '•',
            );
          }
        case 'table':
          _table(e, out);
        case 'section' ||
            'index-body' ||
            'table-of-content' ||
            'text-box' ||
            'illustration-index' ||
            'alphabetical-index':
          blocks(e, out, listLevel: listLevel);
        case 'frame':
          final images = <RImage>[];
          final b = RParaBuilder();
          _frame(e, images, b);
          if (!b.isEmpty) out.add(b.build());
          out.addAll(images);
      }
    }
  }

  bool _numberedList(XmlElement list) {
    final style = list.attr('style-name');
    if (style == null) return false;
    for (final s in content!.rootElement.desc('list-style')) {
      if (s.attr('name') == style) {
        return s.childElements.isNotEmpty &&
            s.childElements.first.local == 'list-level-style-number';
      }
    }
    return false;
  }

  void _table(XmlElement t, List<RBlock> out) {
    final id = tables.length;
    final table = RTable([]);
    tables.add(table);
    for (final row in t.desc('table-row')) {
      final cells = [
        for (final c in row.childElements)
          if (c.local == 'table-cell')
            c.desc('p').map((p) => p.innerText).join('\n'),
      ];
      table.fit(cells);
      out.add(RTableRow(cells, table: id));
    }
  }
}

/// Documento di testo OpenDocument (.odt, .ott).
RDoc parseOdt(Uint8List bytes) {
  final r = OdfReader(bytes);
  final text = r.body?.kid('text');
  final out = <RBlock>[];
  if (text != null) r.blocks(text, out);
  return RDoc(sections: [RSection('', out)], tables: r.tables);
}

/// Presentazione OpenDocument (.odp, .otp): una sezione per diapositiva.
RDoc parseOdp(Uint8List bytes) {
  final r = OdfReader(bytes);
  final pres = r.body?.kid('presentation');
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  for (final page in pres?.kids('page') ?? const <XmlElement>[]) {
    final out = <RBlock>[];
    String? title;
    for (final frame in page.desc('frame')) {
      if (frame.ancestors.any((a) => a is XmlElement && a.local == 'notes')) {
        continue;
      }
      final cls = frame.attr('class');
      final box = frame.kid('text-box');
      if (box != null) {
        final before = out.length;
        r.blocks(box, out, force: cls == 'title' ? RStyle.h2 : null);
        if (cls == 'title' && title == null && out.length > before) {
          title = (out[before] as RPara).text;
        }
      }
      final img = frame.kid('image');
      final href = img?.attr('href');
      final data = href == null ? null : r.zip.bytes(href);
      if (data != null) out.add(RImage(data));
      final table = frame.firstDesc('table');
      if (table != null) r._table(table, out);
    }
    final notes = page.kid('notes');
    if (notes != null) {
      final n = <RBlock>[];
      for (final box in notes.desc('text-box')) {
        r.blocks(box, n, force: RStyle.quote);
      }
      if (n.isNotEmpty) {
        out.add(RPara.text('Note del relatore', style: RStyle.caption));
        out.addAll(n);
      }
    }
    final label = 'Diapositiva ${sections.length + 1}';
    sections.add(RSection(title == null ? label : '$label · $title', out));
    toc.add(
      RTocEntry(
        title ?? page.attr('name') ?? label,
        section: sections.length - 1,
      ),
    );
  }
  return RDoc(
    sections: sections,
    unitLabel: 'Diapositiva',
    toc: toc,
    tables: r.tables,
  );
}

/// Foglio di calcolo OpenDocument (.ods, .ots): un foglio per sezione.
RDoc parseOds(Uint8List bytes) {
  final r = OdfReader(bytes);
  final ss = r.body?.kid('spreadsheet');
  final tables = <RTable>[];
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  for (final t in ss?.kids('table') ?? const <XmlElement>[]) {
    final rows = <List<String>>[];
    void addRows(XmlElement parent) {
      for (final row in parent.childElements) {
        if (row.local == 'table-row-group' ||
            row.local == 'table-header-rows' ||
            row.local == 'table-rows') {
          addRows(row);
          continue;
        }
        if (row.local != 'table-row') continue;
        final cells = <String>[];
        for (final c in row.childElements) {
          if (c.local != 'table-cell' && c.local != 'covered-table-cell') {
            continue;
          }
          final rep =
              (int.tryParse(c.attr('number-columns-repeated') ?? '') ?? 1)
                  .clamp(1, 300);
          final paras = c.kids('p').map((p) => p.innerText).join('\n');
          final text = paras.isNotEmpty ? paras : (c.attr('value') ?? '');
          for (var i = 0; i < rep && cells.length < 300; i++) {
            cells.add(text);
          }
        }
        while (cells.isNotEmpty && cells.last.isEmpty) {
          cells.removeLast();
        }
        final rep = (int.tryParse(row.attr('number-rows-repeated') ?? '') ?? 1);
        // Le righe vuote ripetute in fondo (fino a un milione) si saltano.
        final times = cells.isEmpty ? rep.clamp(1, 50) : rep.clamp(1, 1000);
        for (var i = 0; i < times; i++) {
          rows.add(List.of(cells));
        }
      }
    }

    addRows(t);
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    final name = t.attr('name') ?? 'Foglio ${sections.length + 1}';
    sections.add(sheetSection(name, rows, tables));
    toc.add(RTocEntry(name, section: sections.length - 1));
  }
  return RDoc(
    sections: sections,
    unitLabel: 'Foglio',
    toc: toc,
    tabs: true,
    tables: tables,
  );
}
