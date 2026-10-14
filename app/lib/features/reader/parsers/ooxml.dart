import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'text_formats.dart';
import 'zip_util.dart';

/// Office Open XML: Word (.docx .docm .dotx), PowerPoint (.pptx .ppsx
/// .potx) ed Excel (.xlsx .xlsm). Testo con formattazione, titoli (indice),
/// elenchi, tabelle e immagini; diapositive e fogli come sezioni.

bool _on(XmlElement? e) {
  if (e == null) return false;
  final v = e.attr('val');
  return v == null || !(v == '0' || v == 'false' || v == 'none' || v == 'off');
}

// ---------------------------------------------------------------- Word

class _DocxStyles {
  _DocxStyles(Zip zip) {
    final styles = zip.xml('word/styles.xml');
    if (styles != null) {
      for (final s in styles.rootElement.kids('style')) {
        final id = s.attr('styleId');
        if (id == null) continue;
        final name = (s.kid('name')?.attr('val') ?? id).toLowerCase();
        final outline = s.kid('pPr')?.kid('outlineLvl')?.attr('val');
        int? level;
        final m = RegExp(r'^(heading|titolo|überschrift|titre)\s*(\d)')
            .firstMatch(name);
        if (m != null) {
          level = int.parse(m.group(2)!);
        } else if (name == 'title' || name == 'titolo') {
          level = 1;
        } else if (outline != null) {
          level = (int.tryParse(outline) ?? 8) + 1;
        }
        if (level != null && level <= 9) headings[id] = level;
        if (name.contains('quote') || name.contains('citazione')) {
          quotes.add(id);
        }
      }
    }
    final numbering = zip.xml('word/numbering.xml');
    if (numbering != null) {
      final abstract = <String, Map<int, String>>{};
      for (final a in numbering.rootElement.kids('abstractNum')) {
        final id = a.attr('abstractNumId');
        if (id == null) continue;
        abstract[id] = {
          for (final l in a.kids('lvl'))
            int.tryParse(l.attr('ilvl') ?? '') ?? 0:
                l.kid('numFmt')?.attr('val') ?? 'bullet',
        };
      }
      for (final n in numbering.rootElement.kids('num')) {
        final id = n.attr('numId');
        final a = n.kid('abstractNumId')?.attr('val');
        if (id != null && a != null && abstract[a] != null) {
          formats[id] = abstract[a]!;
        }
      }
    }
  }

  final headings = <String, int>{};
  final quotes = <String>{};
  final formats = <String, Map<int, String>>{};
}

/// Documento Word (.docx, .docm, .dotx).
RDoc parseDocx(Uint8List bytes) {
  final zip = Zip(bytes);
  var part = 'word/document.xml';
  final root = readRels(zip, '');
  for (final r in root.values) {
    if (r.type.endsWith('/officeDocument')) part = r.target;
  }
  final doc = zip.xml(part);
  if (doc == null) throw const FormatException('document.xml mancante');
  final rels = readRels(zip, part);
  final styles = _DocxStyles(zip);
  final w = _DocxWriter(zip, rels, styles);
  final body = doc.rootElement.kid('body');
  if (body != null) w.blocks(body);
  w.endSection();
  final sections = w.sections.where((s) => s.blocks.isNotEmpty).toList();
  if (sections.isEmpty) sections.add(RSection(''));
  final paged = sections.length > 1;
  return RDoc(
    sections: [
      for (var i = 0; i < sections.length; i++)
        RSection(paged ? 'Pagina ${i + 1}' : '', sections[i].blocks),
    ],
    tables: w.tables,
  );
}

class _DocxWriter {
  _DocxWriter(this.zip, this.rels, this.styles);
  final Zip zip;
  final Map<String, ({String target, String type, bool external})> rels;
  final _DocxStyles styles;

  final sections = <RSection>[];
  final tables = <RTable>[];
  var _current = <RBlock>[];
  final _counters = <String, List<int>>{};

  void endSection() {
    sections.add(RSection('', _current));
    _current = <RBlock>[];
  }

  void blocks(XmlElement parent) {
    for (final e in parent.childElements) {
      switch (e.local) {
        case 'p':
          paragraph(e);
        case 'tbl':
          table(e);
        case 'sdt':
          final c = e.kid('sdtContent');
          if (c != null) blocks(c);
        case 'customXml' || 'ins' || 'smartTag':
          blocks(e);
      }
    }
  }

  void paragraph(XmlElement p) {
    final ppr = p.kid('pPr');
    final styleId = ppr?.kid('pStyle')?.attr('val');
    var level = styleId == null ? null : styles.headings[styleId];
    final outline = ppr?.kid('outlineLvl')?.attr('val');
    if (outline != null) level = (int.tryParse(outline) ?? 8) + 1;
    final b = RParaBuilder();
    final images = <RImage>[];
    var breakBefore = false;
    var breakAfter = false;
    void pageBreak() {
      if (b.isEmpty) {
        breakBefore = true;
      } else {
        breakAfter = true;
      }
    }

    void run(XmlElement r, {String? link}) {
      final rpr = r.kid('rPr');
      final bold = _on(rpr?.kid('b'));
      final italic = _on(rpr?.kid('i'));
      final underline = _on(rpr?.kid('u'));
      final strike = _on(rpr?.kid('strike')) || _on(rpr?.kid('dstrike'));
      for (final c in r.childElements) {
        switch (c.local) {
          case 't':
            b.add(
              RSpan(
                c.innerText,
                bold: bold,
                italic: italic,
                underline: underline,
                strike: strike,
                link: link,
              ),
            );
          case 'tab':
            b.write('\t');
          case 'br' || 'cr':
            if (c.attr('type') == 'page') {
              pageBreak();
            } else {
              b.write('\n');
            }
          case 'lastRenderedPageBreak':
            pageBreak();
          case 'noBreakHyphen':
            b.write('-');
          case 'drawing' || 'pict' || 'object':
            for (final blip in [...c.desc('blip'), ...c.desc('imagedata')]) {
              final id = blip.attr('embed') ?? blip.attr('id', prefixed: true);
              final rel = id == null ? null : rels[id];
              final data = rel == null || rel.external
                  ? null
                  : zip.bytes(rel.target);
              if (data != null) images.add(RImage(data));
            }
            // Caselle di testo dentro il disegno.
            for (final t in c.desc('txbxContent')) {
              for (final tp in t.desc('t')) {
                b.write(' ${tp.innerText} ');
              }
            }
        }
      }
    }

    void inline(XmlElement parent, {String? link}) {
      for (final c in parent.childElements) {
        switch (c.local) {
          case 'r':
            run(c, link: link);
          case 'hyperlink':
            final id = c.attr('id', prefixed: true);
            final target = id == null ? null : rels[id]?.target;
            inline(c, link: target ?? link);
          case 'ins' ||
              'smartTag' ||
              'customXml' ||
              'fldSimple' ||
              'sdtContent' ||
              'sdt':
            inline(c, link: link);
          case 'oMath' || 'oMathPara':
            b.write(c.desc('t').map((t) => t.innerText).join());
        }
      }
    }

    inline(p);
    if (breakBefore && _current.isNotEmpty) endSection();

    RStyle style = RStyle.body;
    String? marker;
    var indent = 0;
    if (level != null && !b.isEmpty) {
      style = switch (level) {
        1 => RStyle.h1,
        2 => RStyle.h2,
        3 => RStyle.h3,
        _ => RStyle.h4,
      };
    } else if (styleId != null && styles.quotes.contains(styleId)) {
      style = RStyle.quote;
    }
    final numPr = ppr?.kid('numPr');
    if (numPr != null && level == null) {
      final numId = numPr.kid('numId')?.attr('val');
      final ilvl = int.tryParse(numPr.kid('ilvl')?.attr('val') ?? '') ?? 0;
      if (numId != null && numId != '0') {
        style = RStyle.list;
        indent = ilvl;
        final fmt = styles.formats[numId]?[ilvl] ?? 'bullet';
        if (fmt == 'bullet' || fmt == 'none') {
          marker = '•';
        } else {
          final c = _counters.putIfAbsent(numId, () => List.filled(10, 0));
          c[ilvl.clamp(0, 9)]++;
          for (var i = ilvl + 1; i < 10; i++) {
            c[i] = 0;
          }
          final n = c[ilvl.clamp(0, 9)];
          marker = switch (fmt) {
            'lowerLetter' => '${String.fromCharCode(96 + ((n - 1) % 26) + 1)})',
            'upperLetter' => '${String.fromCharCode(64 + ((n - 1) % 26) + 1)}.',
            'lowerRoman' => '${_roman(n).toLowerCase()}.',
            'upperRoman' => '${_roman(n)}.',
            _ => '$n.',
          };
        }
      }
    }
    if (!b.isEmpty) {
      _current.add(b.build(style: style, level: indent, marker: marker));
    }
    _current.addAll(images);
    if (breakAfter) endSection();
  }

  void table(XmlElement tbl) {
    final id = tables.length;
    final t = RTable([]);
    tables.add(t);
    var first = true;
    for (final tr in tbl.kids('tr')) {
      final cells = <String>[];
      for (final tc in tr.childElements) {
        if (tc.local == 'tc') {
          cells.add(_cellText(tc));
        } else if (tc.local == 'sdt') {
          for (final inner in tc.desc('tc')) {
            cells.add(_cellText(inner));
          }
        }
      }
      if (cells.isEmpty) continue;
      final header = first && (tr.kid('trPr')?.kid('tblHeader') != null);
      t.fit(cells);
      _current.add(RTableRow(cells, table: id, header: header));
      first = false;
    }
  }

  String _cellText(XmlElement tc) => [
    for (final p in tc.desc('p'))
      p
          .desc('t')
          .where((t) => t.parentElement?.local == 'r')
          .map((t) => t.innerText)
          .join(),
  ].where((s) => s.isNotEmpty).join('\n');
}

String _roman(int n) {
  const v = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const s = [
    'M',
    'CM',
    'D',
    'CD',
    'C',
    'XC',
    'L',
    'XL',
    'X',
    'IX',
    'V',
    'IV',
    'I',
  ];
  final b = StringBuffer();
  for (var i = 0; i < v.length; i++) {
    while (n >= v[i]) {
      b.write(s[i]);
      n -= v[i];
    }
  }
  return b.toString();
}

// ---------------------------------------------------------- PowerPoint

/// Testo DrawingML (`a:txBody`) come paragrafi.
List<RBlock> drawingText(XmlElement txBody, {bool title = false}) {
  final out = <RBlock>[];
  for (final p in txBody.kids('p')) {
    final b = RParaBuilder();
    for (final c in p.childElements) {
      switch (c.local) {
        case 'r' || 'fld':
          final rpr = c.kid('rPr');
          final u = rpr?.attr('u');
          b.add(
            RSpan(
              c.kid('t')?.innerText ?? '',
              bold: rpr?.attr('b') == '1' || rpr?.attr('b') == 'true',
              italic: rpr?.attr('i') == '1' || rpr?.attr('i') == 'true',
              underline: u != null && u != 'none',
              strike: (rpr?.attr('strike') ?? 'noStrike') != 'noStrike',
            ),
          );
        case 'br':
          b.write('\n');
      }
    }
    if (b.isEmpty) continue;
    final ppr = p.kid('pPr');
    final lvl = int.tryParse(ppr?.attr('lvl') ?? '') ?? 0;
    final bullet = ppr?.kid('buChar') != null || ppr?.kid('buAutoNum') != null;
    if (title) {
      out.add(b.build(style: RStyle.h2));
    } else if (bullet || lvl > 0) {
      out.add(b.build(style: RStyle.list, level: lvl, marker: '•'));
    } else {
      out.add(b.build());
    }
  }
  return out;
}

/// Presentazione PowerPoint (.pptx, .ppsx, .potx): una sezione per
/// diapositiva, con titolo, testo, tabelle, immagini e note del relatore.
RDoc parsePptx(Uint8List bytes) {
  final zip = Zip(bytes);
  var part = 'ppt/presentation.xml';
  for (final r in readRels(zip, '').values) {
    if (r.type.endsWith('/officeDocument')) part = r.target;
  }
  final pres = zip.xml(part);
  final presRels = readRels(zip, part);
  final slides = <String>[];
  final list = pres?.rootElement.kid('sldIdLst');
  if (list != null) {
    for (final s in list.kids('sldId')) {
      final id = s.attr('id', prefixed: true);
      final rel = id == null ? null : presRels[id];
      if (rel != null) slides.add(rel.target);
    }
  }
  if (slides.isEmpty) {
    final names =
        zip.names
            .where((n) => RegExp(r'slides/slide\d+\.xml$').hasMatch(n))
            .toList()
          ..sort((a, b) => _num(a).compareTo(_num(b)));
    slides.addAll(names);
  }
  final tables = <RTable>[];
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  for (var i = 0; i < slides.length; i++) {
    final xml = zip.xml(slides[i]);
    if (xml == null) continue;
    final rels = readRels(zip, slides[i]);
    final blocks = <RBlock>[];
    String? title;
    void tree(XmlElement e) {
      for (final c in e.childElements) {
        switch (c.local) {
          case 'sp':
            final ph = c.firstDesc('ph')?.attr('type');
            final isTitle = ph == 'title' || ph == 'ctrTitle';
            final body = c.kid('txBody');
            if (body == null) continue;
            final text = drawingText(body, title: isTitle);
            if (isTitle && title == null && text.isNotEmpty) {
              title = text
                  .map((b) => (b as RPara).text)
                  .join(' ')
                  .replaceAll('\n', ' ');
            }
            blocks.addAll(text);
          case 'pic':
            final blip = c.firstDesc('blip');
            final id = blip?.attr('embed');
            final rel = id == null ? null : rels[id];
            final data = rel == null || rel.external
                ? null
                : zip.bytes(rel.target);
            if (data != null) blocks.add(RImage(data));
          case 'graphicFrame':
            final tbl = c.firstDesc('tbl');
            if (tbl != null) {
              final tid = tables.length;
              final t = RTable([]);
              tables.add(t);
              for (final tr in tbl.kids('tr')) {
                final cells = [
                  for (final tc in tr.kids('tc'))
                    tc.desc('t').map((x) => x.innerText).join(' ').trim(),
                ];
                t.fit(cells);
                blocks.add(RTableRow(cells, table: tid));
              }
            }
          case 'grpSp':
            tree(c);
          case 'AlternateContent':
            final choice = c.kid('Choice') ?? c.kid('Fallback');
            if (choice != null) tree(choice);
        }
      }
    }

    final spTree = xml.rootElement.firstDesc('spTree');
    if (spTree != null) tree(spTree);
    // Note del relatore.
    for (final r in rels.values) {
      if (!r.type.endsWith('/notesSlide')) continue;
      final notes = zip.xml(r.target);
      if (notes == null) continue;
      final paras = <RBlock>[];
      for (final sp in notes.rootElement.desc('sp')) {
        if (sp.firstDesc('ph')?.attr('type') != 'body') continue;
        final body = sp.kid('txBody');
        if (body != null) paras.addAll(drawingText(body));
      }
      if (paras.isNotEmpty) {
        blocks.add(RPara.text('Note del relatore', style: RStyle.caption));
        blocks.addAll([
          for (final p in paras)
            if (p is RPara) RPara(p.spans, style: RStyle.quote) else p,
        ]);
      }
    }
    final label = 'Diapositiva ${sections.length + 1}';
    sections.add(RSection(title == null ? label : '$label · $title', blocks));
    toc.add(RTocEntry(title ?? label, section: sections.length - 1));
  }
  return RDoc(
    sections: sections,
    unitLabel: 'Diapositiva',
    toc: toc,
    tables: tables,
  );
}

int _num(String s) =>
    int.tryParse(RegExp(r'(\d+)\D*$').firstMatch(s)?.group(1) ?? '') ?? 0;

// --------------------------------------------------------------- Excel

/// Indice di colonna (0-based) da un riferimento "BC12".
int columnIndex(String ref) {
  var n = 0;
  for (final c in ref.codeUnits) {
    if (c >= 65 && c <= 90) {
      n = n * 26 + (c - 64);
    } else if (c >= 97 && c <= 122) {
      n = n * 26 + (c - 96);
    } else {
      break;
    }
  }
  return n - 1;
}

/// Numero come lo mostrerebbe un foglio italiano (virgola decimale).
String formatNumber(double v) {
  if (v.isNaN || v.isInfinite) return '$v';
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  var s = v.toStringAsPrecision(12);
  if (s.contains('e')) return s.replaceAll('.', ',');
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s.replaceAll('.', ',');
}

/// Data da numero seriale di Excel (sistema 1900).
String excelDate(double serial, {bool time = false}) {
  final d = DateTime.utc(
    1899,
    12,
    30,
  ).add(Duration(milliseconds: (serial * 86400000).round()));
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${two(d.day)}/${two(d.month)}/${d.year}';
  if (!time) return date;
  final t = '${two(d.hour)}:${two(d.minute)}';
  return serial < 1 ? t : '$date $t';
}

/// Foglio di calcolo Excel (.xlsx, .xlsm): un foglio per sezione (schede).
RDoc parseXlsx(Uint8List bytes) {
  final zip = Zip(bytes);
  var part = 'xl/workbook.xml';
  for (final r in readRels(zip, '').values) {
    if (r.type.endsWith('/officeDocument')) part = r.target;
  }
  final wb = zip.xml(part);
  final rels = readRels(zip, part);
  final shared = <String>[];
  for (final r in rels.values) {
    if (!r.type.endsWith('/sharedStrings')) continue;
    final sst = zip.xml(r.target);
    if (sst == null) continue;
    for (final si in sst.rootElement.kids('si')) {
      shared.add(
        si
            .desc('t')
            .where((t) => t.parentElement?.local != 'rPh')
            .map((t) => t.innerText)
            .join(),
      );
    }
  }
  // Stili delle celle: quali sono date.
  final dateStyles = <int>{};
  final timeStyles = <int>{};
  for (final r in rels.values) {
    if (!r.type.endsWith('/styles')) continue;
    final st = zip.xml(r.target);
    if (st == null) continue;
    final custom = <int, String>{
      for (final f in st.rootElement.desc('numFmt'))
        int.tryParse(f.attr('numFmtId') ?? '') ?? -1:
            f.attr('formatCode') ?? '',
    };
    final xfs = st.rootElement.kid('cellXfs')?.kids('xf').toList() ?? const [];
    for (var i = 0; i < xfs.length; i++) {
      final id = int.tryParse(xfs[i].attr('numFmtId') ?? '') ?? 0;
      final code = (custom[id] ?? '')
          .replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]'), '')
          .toLowerCase();
      if ((id >= 14 && id <= 17) ||
          id == 22 ||
          RegExp(r'[dy]').hasMatch(code)) {
        dateStyles.add(i);
        if (id == 22 || code.contains('h')) timeStyles.add(i);
      } else if ((id >= 18 && id <= 21) ||
          (id >= 45 && id <= 47) ||
          RegExp(r'h.*m|m.*s').hasMatch(code)) {
        timeStyles.add(i);
      }
    }
  }
  final tables = <RTable>[];
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  final sheets =
      wb?.rootElement.kid('sheets')?.kids('sheet') ?? const <XmlElement>[];
  for (final s in sheets) {
    final name = s.attr('name') ?? 'Foglio ${sections.length + 1}';
    final id = s.attr('id', prefixed: true);
    final rel = id == null ? null : rels[id];
    final xml = rel == null ? null : zip.xml(rel.target);
    final rows = <List<String>>[];
    final data = xml?.rootElement.kid('sheetData');
    if (data != null) {
      for (final row in data.kids('row')) {
        final r = (int.tryParse(row.attr('r') ?? '') ?? (rows.length + 1)) - 1;
        if (r > kMaxRowsGap + rows.length) break;
        while (rows.length < r) {
          rows.add(<String>[]);
        }
        final cells = <String>[];
        for (final c in row.kids('c')) {
          final ref = c.attr('r');
          final col = ref == null ? cells.length : columnIndex(ref);
          if (col < 0 || col > 300) continue;
          while (cells.length < col) {
            cells.add('');
          }
          final t = c.attr('t');
          final v = c.kid('v')?.innerText;
          final style = int.tryParse(c.attr('s') ?? '') ?? 0;
          String text;
          switch (t) {
            case 's':
              final i = int.tryParse(v ?? '');
              text = i != null && i < shared.length ? shared[i] : '';
            case 'inlineStr':
              text = c.desc('t').map((e) => e.innerText).join();
            case 'b':
              text = v == '1' ? 'VERO' : 'FALSO';
            case 'str' || 'e':
              text = v ?? '';
            default:
              final d = double.tryParse(v ?? '');
              if (d == null) {
                text = v ?? '';
              } else if (dateStyles.contains(style)) {
                text = excelDate(d, time: timeStyles.contains(style));
              } else if (timeStyles.contains(style)) {
                text = excelDate(d, time: true);
              } else {
                text = formatNumber(d);
              }
          }
          cells.add(text);
        }
        rows.add(cells);
      }
    }
    _trim(rows);
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

/// Righe vuote tra i dati oltre le quali il foglio si considera finito.
const kMaxRowsGap = 5000;

void _trim(List<List<String>> rows) {
  for (final r in rows) {
    while (r.isNotEmpty && r.last.isEmpty) {
      r.removeLast();
    }
  }
  while (rows.isNotEmpty && rows.last.isEmpty) {
    rows.removeLast();
  }
}
