import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'html_blocks.dart';
import 'markdown_notes.dart';

export 'markdown_notes.dart';

/// Testo da byte: BOM UTF-8/UTF-16, altrimenti UTF-8 e, se non valido,
/// Windows-1252 (i vecchi .txt salvati con il Blocco note).
String decodeText(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return decodeUtf16(bytes, 2, bytes.length, littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return decodeUtf16(bytes, 2, bytes.length, littleEndian: false);
  }
  // UTF-16 senza BOM: molti zeri nei byte dispari (testo latino).
  if (bytes.length >= 8) {
    var zeros = 0;
    final n = bytes.length < 400 ? bytes.length : 400;
    for (var i = 1; i < n; i += 2) {
      if (bytes[i] == 0) zeros++;
    }
    if (zeros > n / 4) {
      return decodeUtf16(bytes, 0, bytes.length, littleEndian: true);
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return decodeCp1252(bytes);
  }
}

String decodeUtf16(
  List<int> b,
  int start,
  int end, {
  required bool littleEndian,
}) {
  final units = <int>[];
  for (var i = start; i + 1 < end; i += 2) {
    units.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return String.fromCharCodes(units);
}

const _cp1252 = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

/// Windows-1252 (Latin-1 con le virgolette tipografiche in 0x80–0x9F).
String decodeCp1252(List<int> bytes) => String.fromCharCodes([
  for (final b in bytes) (b >= 0x80 && b < 0xA0) ? _cp1252[b - 0x80] : b,
]);

/// Righe raggruppate in blocchi (vista pigra, salti precisi).
List<RBlock> _lineBlocks(List<String> lines, {int chunk = 30}) {
  final out = <RBlock>[];
  final buf = <String>[];
  void flush() {
    if (buf.isEmpty) return;
    out.add(RPara.text(buf.join('\n')));
    buf.clear();
  }

  for (final l in lines) {
    if (l.trim().isEmpty) {
      flush();
      continue;
    }
    buf.add(l);
    if (buf.length >= chunk) flush();
  }
  flush();
  return out;
}

List<String> _lines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

/// Testo semplice (.txt, .log): paragrafi separati da righe vuote.
RDoc plainTextDoc(String text) =>
    RDoc(sections: [RSection('', _lineBlocks(_lines(text)))]);

/// Codice sorgente e dati (.py, .json, .xml, ...): a spaziatura fissa,
/// righe vuote comprese.
RDoc codeDoc(String text, {String? notice}) {
  final lines = _lines(text);
  final out = <RBlock>[];
  for (var i = 0; i < lines.length; i += 40) {
    final end = i + 40 < lines.length ? i + 40 : lines.length;
    out.add(RPara.text(lines.sublist(i, end).join('\n')));
  }
  return RDoc(sections: [RSection('', out)], mono: true, notice: notice);
}

/// JSON formattato con rientri (se valido).
RDoc jsonDoc(String text) {
  try {
    final v = jsonDecode(text);
    return codeDoc(const JsonEncoder.withIndent('  ').convert(v));
  } on FormatException {
    return codeDoc(text);
  } on StackOverflowError {
    // decine di migliaia di livelli annidati: il JSON si mostra com'è
    return codeDoc(text);
  }
}

/// XML formattato con rientri (se valido).
RDoc xmlDoc(String text) {
  try {
    return codeDoc(XmlDocument.parse(text).toXmlString(pretty: true));
  } catch (_) {
    return codeDoc(text);
  }
}

/// Sorgenti con titoli riconoscibili (LaTeX, reStructuredText, Org,
/// AsciiDoc): il testo resta quello originale, i titoli formano l'indice.
RDoc markupDoc(String text, String ext) {
  final lines = _lines(text);
  final out = <RBlock>[];
  final buf = <String>[];
  final rstLevels = <String>[];
  void flush() {
    if (buf.isEmpty) return;
    out.addAll(_lineBlocks(List.of(buf)));
    buf.clear();
  }

  void heading(String title, int level) {
    flush();
    out.add(
      RPara.text(
        title,
        style: switch (level) {
          0 => RStyle.h1,
          1 => RStyle.h2,
          2 => RStyle.h3,
          _ => RStyle.h4,
        },
      ),
    );
  }

  final tex = RegExp(
    r'^\s*\\(part|chapter|section|subsection|subsubsection)\*?\s*(?:\[[^\]]*\])?\{(.*)\}',
  );
  final org = RegExp(r'^(\*+)\s+(.*)$');
  final adoc = RegExp(r'^(=+)\s+(.*)$');
  final rstUnder = RegExp(r'^([=\-~^"#*+`:.])\1{2,}\s*$');
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    switch (ext) {
      case '.tex' || '.latex' || '.ltx' || '.sty' || '.cls':
        final m = tex.firstMatch(l);
        if (m != null) {
          const order = {
            'part': 0,
            'chapter': 0,
            'section': 1,
            'subsection': 2,
            'subsubsection': 3,
          };
          heading(m.group(2)!, order[m.group(1)!]!);
          continue;
        }
      case '.org':
        final m = org.firstMatch(l);
        if (m != null) {
          heading(m.group(2)!, m.group(1)!.length - 1);
          continue;
        }
      case '.adoc' || '.asciidoc':
        final m = adoc.firstMatch(l);
        if (m != null) {
          heading(m.group(2)!, m.group(1)!.length - 1);
          continue;
        }
      case '.rst':
        if (i + 1 < lines.length &&
            l.trim().isNotEmpty &&
            rstUnder.hasMatch(lines[i + 1]) &&
            lines[i + 1].trim().length >= l.trim().length) {
          final c = lines[i + 1].trim()[0];
          if (!rstLevels.contains(c)) rstLevels.add(c);
          heading(l.trim(), rstLevels.indexOf(c));
          i++;
          continue;
        }
    }
    if (l.trim().isEmpty) {
      flush();
    } else {
      buf.add(l);
    }
  }
  flush();
  return RDoc(sections: [RSection('', out)]);
}

/// Pagina web salvata (.html, .htm, .xhtml).
RDoc htmlDoc(String text, {ImageResolver? images}) {
  final conv = HtmlBlocks(images: images);
  final blocks = conv.convert(text);
  return RDoc(
    sections: [RSection(HtmlBlocks.titleOf(text), blocks)],
    tables: conv.tables,
  );
}

/// Righe di un CSV/TSV, con i campi tra virgolette (anche su più righe).
List<List<String>> parseCsv(String text, {String? delimiter}) {
  final d = delimiter ?? _guessDelimiter(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && field.isEmpty) {
      quoted = true;
    } else if (c == d) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

String _guessDelimiter(String text) {
  final first = text.split('\n').first;
  final counts = {
    for (final d in [',', ';', '\t', '|']) d: d.allMatches(first).length,
  };
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// Limite di righe mostrate per foglio (i file enormi restano leggibili).
const kMaxSheetRows = 20000;

/// Foglio come sezione con le righe numerate (stesso aspetto per tutti i
/// formati di foglio di calcolo: CSV, Excel, ODS, Numbers).
RSection sheetSection(
  String title,
  List<List<String>> rows,
  List<RTable> tables,
) {
  final id = tables.length;
  final t = RTable([]);
  tables.add(t);
  final blocks = <RBlock>[];
  final n = rows.length > kMaxSheetRows ? kMaxSheetRows : rows.length;
  for (var i = 0; i < n; i++) {
    if (rows[i].isEmpty) {
      blocks.add(RTableRow(const [''], table: id, label: '${i + 1}'));
      continue;
    }
    t.fit(rows[i]);
    blocks.add(RTableRow(rows[i], table: id, label: '${i + 1}'));
  }
  if (rows.length > n) {
    blocks.add(
      RPara.text(
        'Mostrate le prime $n righe di ${rows.length}.',
        style: RStyle.caption,
      ),
    );
  }
  if (blocks.isEmpty) {
    blocks.add(RPara.text('Foglio vuoto', style: RStyle.caption));
  }
  return RSection(title, blocks);
}

RDoc csvDoc(String text, {String? delimiter}) {
  final tables = <RTable>[];
  return RDoc(
    sections: [sheetSection('', parseCsv(text, delimiter: delimiter), tables)],
    tables: tables,
    unitLabel: 'Foglio',
  );
}

/// Battuta di sottotitoli o trascrizione con tempo.
class Cue {
  const Cue(this.start, this.end, this.text);
  final double start;
  final double? end;
  final String text;
}

final _cueTime = RegExp(
  r'(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?',
);

double _secs(String? h, String m, String s, String? ms) =>
    (int.tryParse(h ?? '') ?? 0) * 3600 +
    int.parse(m) * 60 +
    int.parse(s) +
    (ms == null ? 0 : int.parse(ms.padRight(3, '0')) / 1000);

/// Battute di un file .srt o .vtt.
List<Cue> parseCues(String text) {
  final lines = _lines(text);
  final out = <Cue>[];
  for (var i = 0; i < lines.length; i++) {
    final m = _cueTime.firstMatch(lines[i]);
    if (m == null) continue;
    final start = _secs(m.group(1), m.group(2)!, m.group(3)!, m.group(4));
    final end = _secs(m.group(5), m.group(6)!, m.group(7)!, m.group(8));
    final body = <String>[];
    for (i++; i < lines.length && lines[i].trim().isNotEmpty; i++) {
      body.add(lines[i].replaceAll(RegExp(r'<[^>]+>'), ''));
    }
    out.add(Cue(start, end, body.join('\n')));
  }
  return out;
}

final _inlineTime = RegExp(r'[\[(]?\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b[\])]?');

/// Battute di una trascrizione con tempi a inizio riga ("[01:02] testo",
/// "00:01:02 testo"); vuoto se il testo non ne ha.
List<Cue> parseTimedLines(String text) {
  final out = <Cue>[];
  for (final l in _lines(text)) {
    final t = l.replaceFirst(RegExp(r'^[\s#*>-]+'), '');
    final m = _inlineTime.matchAsPrefix(t);
    if (m == null) continue;
    final start = _secs(m.group(1), m.group(2)!, m.group(3)!, null);
    out.add(Cue(start, null, t.substring(m.end).trim()));
  }
  return out;
}

String formatClock(double seconds) {
  final s = seconds.floor();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// Battute come documento: il tempo è toccabile.
RDoc cuesDoc(List<Cue> cues) => RDoc(
  sections: [
    RSection('', [
      for (final c in cues)
        RPara([
          RSpan(formatClock(c.start), mono: true, seconds: c.start),
          RSpan('  ${c.text}'),
        ]),
    ]),
  ],
);

RDoc subtitlesDoc(String text) {
  final cues = parseCues(text);
  return cues.isEmpty ? plainTextDoc(text) : cuesDoc(cues);
}

/// Notebook Jupyter: celle Markdown formattate, celle di codice con i
/// risultati (testo e immagini).
RDoc ipynbDoc(String text) {
  final Map<String, dynamic> nb;
  try {
    nb = jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
    return codeDoc(text, notice: 'Notebook non valido: mostrato il sorgente.');
  }
  String src(Object? v) => v is List ? v.join() : (v?.toString() ?? '');
  final cells =
      (nb['cells'] as List?) ??
      [
        for (final w in (nb['worksheets'] as List? ?? const []))
          ...((w as Map)['cells'] as List? ?? const []),
      ];
  final out = <RBlock>[];
  for (final c in cells.cast<Map>()) {
    final type = c['cell_type'];
    final source = src(c['source'] ?? c['input']);
    if (type == 'markdown') {
      out.addAll(markdownBlocks(source));
    } else if (type == 'code') {
      final n = c['execution_count'] ?? c['prompt_number'];
      out.add(RPara.text('In [${n ?? ' '}]:', style: RStyle.caption));
      out.add(RPara([RSpan(source, mono: true)], style: RStyle.code));
      for (final o in (c['outputs'] as List? ?? const []).cast<Map>()) {
        final data = (o['data'] as Map?) ?? o;
        final png = data['image/png'];
        if (png != null) {
          try {
            out.add(RImage(base64Decode(src(png).replaceAll('\n', ''))));
            continue;
          } catch (_) {}
        }
        final t = o['text'] ?? data['text/plain'] ?? o['traceback'];
        if (t != null) {
          var s = src(t is List && o['traceback'] != null ? t.join('\n') : t);
          s = s.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
          out.add(RPara([RSpan(s.trimRight(), mono: true)]));
        }
      }
    } else {
      out.add(RPara([RSpan(source, mono: true)]));
    }
  }
  return RDoc(sections: [RSection('', out)]);
}

/// Byte → testo e documento per i formati di testo.
RDoc textFormatDoc(Uint8List bytes, String ext) {
  final text = decodeText(bytes);
  return switch (ext) {
    '.md' || '.markdown' || '.mdown' || '.mkd' => markdownDoc(text),
    '.html' || '.htm' || '.xhtml' || '.mht' => htmlDoc(text),
    '.json' || '.geojson' => jsonDoc(text),
    '.xml' || '.svgz' || '.plist' => xmlDoc(text),
    '.csv' => csvDoc(text),
    '.tsv' || '.tab' => csvDoc(text, delimiter: '\t'),
    '.srt' || '.vtt' => subtitlesDoc(text),
    '.ipynb' => ipynbDoc(text),
    '.tex' ||
    '.latex' ||
    '.ltx' ||
    '.sty' ||
    '.cls' ||
    '.rst' ||
    '.org' ||
    '.adoc' ||
    '.asciidoc' => markupDoc(text, ext),
    '.txt' || '.text' || '.log' || '' => plainTextDoc(text),
    _ => codeDoc(text),
  };
}
