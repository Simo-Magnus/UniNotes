import 'dart:typed_data';

import '../../notes/markdown_lite.dart';
import '../reader_document.dart';

/// Immagine incorporata in una nota (`![[foto.png]]`, `![](foto.png)`):
/// byte del file accanto alla nota, se c'è.
typedef EmbedResolver = Uint8List? Function(String name);

/// Collegamenti in linea: `![[x]]`/`[[x|alias]]` (Obsidian),
/// `![alt](src)`/`[testo](url)` e `#etichette`.
final _mdInline = RegExp(
  r'(!?)\[\[([^\[\]\n]+?)\]\]'
  r'|(!?)\[([^\[\]\n]*)\]\(<?([^()\s<>]+(?:\([^()\s]*\)[^()\s<>]*)?)>?(?:\s+"[^"]*")?\)'
  r'|(?<![\w/#&=\-])#([\p{L}\p{N}_/\-]*\p{L}[\p{L}\p{N}_/\-]*)',
  unicode: true,
);

/// Segnaposto di un collegamento durante l'analisi del Markdown (caratteri
/// ad uso privato: il parser non li tocca).
final _placeholder = RegExp('(\\d+)');

class _Inline {
  _Inline(this.source, this.text, {this.link, this.embed});
  final String source;
  final String text;
  final String? link;
  final String? embed;
}

final _tableSep = RegExp(r'^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$');

List<String> _cells(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return [for (final c in t.split('|')) c.trim()];
}

/// Testo visibile di una cella con collegamenti.
String _plain(String c) => c.replaceAllMapped(_mdInline, (m) {
  final wiki = m.group(2);
  if (wiki != null) return wiki.split('|').last.split('#').first;
  final label = m.group(4);
  if (label != null) return label;
  return '#${m.group(6)}';
});

/// Markdown (stesso parser degli appunti) → blocchi, con i collegamenti di
/// Obsidian (`[[nota]]`, `[[nota|alias]]`, `![[immagine.png]]`), quelli
/// standard (`[testo](url)`, `![alt](immagine)`), le `#etichette` e le
/// tabelle con `|` (se c'è [tables]). I collegamenti alle note hanno
/// `link` "note:nome", le etichette "tag:#nome".
List<RBlock> markdownBlocks(
  String text, {
  List<RTable>? tables,
  EmbedResolver? embed,
}) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final out = <RBlock>[];
  final buf = <String>[];
  void flush() {
    if (buf.isEmpty) return;
    out.addAll(_segment(buf.join('\n'), embed));
    buf.clear();
  }

  var fence = false;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.trim().startsWith('```')) fence = !fence;
    if (!fence &&
        tables != null &&
        l.contains('|') &&
        i + 1 < lines.length &&
        lines[i + 1].contains('-') &&
        _tableSep.hasMatch(lines[i + 1])) {
      flush();
      final id = tables.length;
      final t = RTable([]);
      tables.add(t);
      final head = [for (final c in _cells(l)) _plain(c)];
      t.fit(head);
      out.add(RTableRow(head, table: id, header: true));
      var j = i + 2;
      for (; j < lines.length && lines[j].contains('|'); j++) {
        final cells = [for (final c in _cells(lines[j])) _plain(c)];
        t.fit(cells);
        out.add(RTableRow(cells, table: id));
      }
      i = j - 1;
      continue;
    }
    buf.add(l);
  }
  flush();
  return out;
}

List<RBlock> _segment(String text, EmbedResolver? embed) {
  final inl = <_Inline>[];
  final protected = text.replaceAllMapped(_mdInline, (m) {
    final i = inl.length;
    final wiki = m.group(2);
    final url = m.group(5);
    if (wiki != null) {
      final bar = wiki.indexOf('|');
      final target = (bar < 0 ? wiki : wiki.substring(0, bar)).trim();
      final alias = bar < 0 ? null : wiki.substring(bar + 1).trim();
      final page = target.split('#').first;
      if (m.group(1) == '!') {
        inl.add(
          _Inline(
            m.group(0)!,
            alias != null && int.tryParse(alias) == null ? alias : page,
            embed: page,
            link: 'note:$page',
          ),
        );
      } else {
        inl.add(
          _Inline(
            m.group(0)!,
            alias ?? target.replaceAll('#', ' › '),
            link: page.isEmpty ? null : 'note:$page',
          ),
        );
      }
    } else if (url != null) {
      final label = m.group(4) ?? '';
      if (m.group(3) == '!') {
        String name;
        try {
          name = Uri.decodeFull(url);
        } catch (_) {
          name = url;
        }
        inl.add(_Inline(m.group(0)!, label, embed: name));
      } else {
        inl.add(_Inline(m.group(0)!, label.isEmpty ? url : label, link: url));
      }
    } else {
      final tag = '#${m.group(6)}';
      inl.add(_Inline(m.group(0)!, tag, link: 'tag:$tag'));
    }
    return '$i';
  });
  String restore(String s) => s.replaceAllMapped(
    _placeholder,
    (m) => inl[int.parse(m.group(1)!)].source,
  );
  final out = <RBlock>[];
  for (final b in parseMarkdown(protected)) {
    final images = <RBlock>[];
    final sp = <RSpan>[];
    for (final s in b.spans) {
      // formule: il LaTeX con i delimitatori, in carattere monospaziato
      if (s.code || s.math) {
        sp.add(RSpan(restore(s.source), mono: true));
        continue;
      }
      var pos = 0;
      for (final m in _placeholder.allMatches(s.text)) {
        if (m.start > pos) {
          sp.add(
            RSpan(
              s.text.substring(pos, m.start),
              bold: s.bold,
              italic: s.italic,
            ),
          );
        }
        final it = inl[int.parse(m.group(1)!)];
        final name = it.embed;
        final bytes = name == null ? null : embed?.call(name);
        if (bytes != null) {
          images.add(RImage(bytes, caption: it.text.isEmpty ? null : it.text));
        } else if (name != null && it.link == null) {
          sp.add(RSpan('[${it.text.isEmpty ? name : it.text}]', italic: true));
        } else {
          sp.add(RSpan(it.text, bold: s.bold, italic: s.italic, link: it.link));
        }
        pos = m.end;
      }
      if (pos < s.text.length) {
        sp.add(RSpan(s.text.substring(pos), bold: s.bold, italic: s.italic));
      }
    }
    final empty = sp.every((s) => s.text.trim().isEmpty);
    switch (b.type) {
      case MdBlockType.heading:
        out.add(
          RPara(
            sp,
            style: switch (b.level) {
              1 => RStyle.h1,
              2 => RStyle.h2,
              3 => RStyle.h3,
              _ => RStyle.h4,
            },
          ),
        );
      case MdBlockType.paragraph:
        if (!empty) out.add(RPara(sp));
      case MdBlockType.bullet:
        out.add(RPara(sp, style: RStyle.list, level: b.level, marker: '•'));
      case MdBlockType.numbered:
        out.add(
          RPara(sp, style: RStyle.list, level: b.level, marker: '${b.number}.'),
        );
      case MdBlockType.quote:
        out.add(RPara(sp, style: RStyle.quote));
      case MdBlockType.rule:
        out.add(const RRule());
      case MdBlockType.code:
        out.add(
          RPara([RSpan(restore(b.raw ?? ''), mono: true)], style: RStyle.code),
        );
      case MdBlockType.math:
        out.add(
          RPara([
            RSpan('\$\$${restore(b.raw ?? '')}\$\$', mono: true),
          ], style: RStyle.code),
        );
    }
    out.addAll(images);
  }
  return out;
}

/// Nota Markdown come documento (tabelle comprese).
RDoc markdownDoc(String text, {EmbedResolver? embed}) {
  final tables = <RTable>[];
  return RDoc(
    sections: [
      RSection('', markdownBlocks(text, tables: tables, embed: embed)),
    ],
    tables: tables,
  );
}
