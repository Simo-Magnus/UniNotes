import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../reader_document.dart';

/// Immagine di un `src` (relativo al documento), se disponibile.
typedef ImageResolver = Uint8List? Function(String src);

/// HTML/XHTML → blocchi del lettore. Serve a pagine web, capitoli EPUB,
/// note Evernote (ENML), MOBI e celle Markdown dei notebook.
class HtmlBlocks {
  HtmlBlocks({this.images, List<RTable>? tables}) : tables = tables ?? [];

  final ImageResolver? images;

  /// Tabelle del documento (condivise tra più capitoli).
  final List<RTable> tables;

  final _out = <RBlock>[];
  final _para = RParaBuilder();

  /// Ancore `id` → indice del blocco (per l'indice degli EPUB).
  final anchors = <String, int>{};

  static List<RBlock> parse(String source, {ImageResolver? images}) =>
      HtmlBlocks(images: images).convert(source);

  List<RBlock> convert(String source) {
    final doc = html.parse(source);
    final body = doc.body ?? doc.documentElement;
    if (body != null) _walk(body, const _Fmt());
    _flush();
    return List.of(_out);
  }

  static String _title(String source) =>
      html.parse(source).querySelector('title')?.text.trim() ?? '';

  /// Titolo della pagina (`<title>`), vuoto se manca.
  static String titleOf(String source) => _title(source);

  void _flush({RStyle style = RStyle.body, int level = 0, String? marker}) {
    if (_para.isEmpty) {
      _para.clear();
      return;
    }
    _out.add(_para.build(style: style, level: level, marker: marker));
  }

  void _walk(dom.Node node, _Fmt f, {int listLevel = 0}) {
    if (node is dom.Text) {
      var t = node.text;
      if (!f.pre) t = t.replaceAll(RegExp(r'\s+'), ' ');
      if (t.isEmpty) return;
      _para.add(
        RSpan(
          t,
          bold: f.bold,
          italic: f.italic,
          underline: f.underline,
          strike: f.strike,
          mono: f.mono,
          link: f.link,
        ),
      );
      return;
    }
    if (node is! dom.Element) {
      for (final c in node.nodes) {
        _walk(c, f, listLevel: listLevel);
      }
      return;
    }
    final tag = node.localName?.toLowerCase() ?? '';
    final id = node.id;
    if (id.isNotEmpty) anchors[id] = _out.length;
    switch (tag) {
      case 'script' ||
          'style' ||
          'head' ||
          'title' ||
          'noscript' ||
          'iframe' ||
          'embed':
        return;
      case 'svg':
        // SVG (pagine degli EPUB a impaginazione fissa): immagini e testi.
        for (final e in node.querySelectorAll('*')) {
          final t = e.localName?.toLowerCase();
          if (t == 'image') {
            _walk(e, f, listLevel: listLevel);
          } else if (t == 'text' && e.text.trim().isNotEmpty) {
            _para.write('${e.text.trim()} ');
          }
        }
        _flush();
        return;
      case 'math':
        // MathML: il testo alternativo se c'è, altrimenti i simboli.
        final alt = node.attributes['alttext'];
        final t = alt != null && alt.trim().isNotEmpty
            ? alt.trim()
            : node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isNotEmpty) _para.add(RSpan(t, italic: true));
        return;
      case 'audio' || 'video':
        _flush();
        _out.add(
          RPara.text(
            tag == 'audio'
                ? '[Audio: non riproducibile nel testo]'
                : '[Video: non riproducibile nel testo]',
            style: RStyle.caption,
          ),
        );
        return;
      case 'br':
        _para.write('\n');
        return;
      case 'hr':
        _flush();
        _out.add(const RRule());
        return;
      case 'img' || 'image':
        // Negli SVG l'attributo è xlink:href (chiave con prefisso).
        var src = node.attributes['src'] ?? node.attributes['href'];
        if (src == null) {
          for (final e in node.attributes.entries) {
            if (e.key.toString().endsWith('href')) src = e.value;
          }
        }
        src ??= '';
        final bytes = src.isEmpty ? null : images?.call(src);
        if (bytes != null) {
          _flush();
          _out.add(RImage(bytes, caption: node.attributes['alt']));
        } else {
          final alt = node.attributes['alt'];
          if (alt != null && alt.isNotEmpty) _para.write('[$alt]');
        }
        return;
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _flush();
        _children(node, f.copy(bold: true), listLevel);
        final n = int.parse(tag.substring(1));
        _flush(
          style: switch (n) {
            1 => RStyle.h1,
            2 => RStyle.h2,
            3 => RStyle.h3,
            _ => RStyle.h4,
          },
        );
        return;
      case 'pre':
        _flush();
        _children(node, f.copy(pre: true, mono: true), listLevel);
        _flush(style: RStyle.code);
        return;
      case 'blockquote':
        _flush();
        _children(node, f, listLevel);
        _flush(style: RStyle.quote);
        return;
      case 'ul' || 'ol':
        _flush();
        var n = int.tryParse(node.attributes['start'] ?? '') ?? 1;
        for (final li in node.children) {
          if (li.localName != 'li') {
            _walk(li, f, listLevel: listLevel + 1);
            continue;
          }
          _listItem(li, f, listLevel, tag == 'ol' ? '${n++}.' : '•');
        }
        return;
      case 'li':
        _listItem(node, f, listLevel, '•');
        return;
      case 'table':
        _flush();
        _table(node);
        return;
      case 'figcaption' || 'caption':
        _flush();
        _children(node, f.copy(italic: true), listLevel);
        _flush(style: RStyle.caption);
        return;
      case 'p' ||
          'div' ||
          'section' ||
          'article' ||
          'header' ||
          'footer' ||
          'aside' ||
          'nav' ||
          'main' ||
          'figure' ||
          'dt' ||
          'dd' ||
          'address' ||
          'en-note' ||
          'center' ||
          'body' ||
          'html':
        _flush();
        _children(node, f, listLevel);
        _flush();
        return;
      case 'b' || 'strong' || 'th':
        _children(node, f.copy(bold: true), listLevel);
        return;
      case 'i' || 'em' || 'cite' || 'var':
        _children(node, f.copy(italic: true), listLevel);
        return;
      case 'u' || 'ins':
        _children(node, f.copy(underline: true), listLevel);
        return;
      case 's' || 'strike' || 'del':
        _children(node, f.copy(strike: true), listLevel);
        return;
      case 'code' || 'kbd' || 'samp' || 'tt':
        _children(node, f.copy(mono: true), listLevel);
        return;
      case 'a':
        _children(node, f.copy(link: node.attributes['href']), listLevel);
        return;
      case 'en-media':
        // Allegato Evernote: l'immagine arriva dal risolutore (hash).
        final hash = node.attributes['hash'];
        final bytes = hash == null ? null : images?.call('hash:$hash');
        if (bytes != null) {
          _flush();
          _out.add(RImage(bytes));
        } else {
          _para.write('[allegato]');
        }
        // Il parser HTML non chiude i tag sconosciuti "/>": il resto della
        // nota finisce dentro l'elemento.
        _children(node, f, listLevel);
        return;
      case 'en-todo':
        _para.write(node.attributes['checked'] == 'true' ? '☑ ' : '☐ ');
        _children(node, f, listLevel);
        return;
      default:
        _children(node, f, listLevel);
    }
  }

  void _children(dom.Element e, _Fmt f, int listLevel) {
    for (final c in e.nodes) {
      _walk(c, f, listLevel: listLevel);
    }
  }

  void _listItem(dom.Element li, _Fmt f, int level, String marker) {
    _flush();
    final nested = <dom.Element>[];
    for (final c in li.nodes) {
      if (c is dom.Element && (c.localName == 'ul' || c.localName == 'ol')) {
        nested.add(c);
      } else {
        _walk(c, f, listLevel: level);
      }
    }
    _flush(style: RStyle.list, level: level, marker: marker);
    for (final n in nested) {
      _walk(n, f, listLevel: level + 1);
    }
  }

  void _table(dom.Element table) {
    final id = tables.length;
    final t = RTable([]);
    tables.add(t);
    final rows = table.querySelectorAll('tr');
    for (var i = 0; i < rows.length; i++) {
      final cells = [
        for (final c in rows[i].children)
          if (c.localName == 'td' || c.localName == 'th')
            c.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      ];
      if (cells.isEmpty) continue;
      t.fit(cells);
      final header = rows[i].children.every((c) => c.localName == 'th');
      _out.add(RTableRow(cells, table: id, header: header));
    }
  }
}

class _Fmt {
  const _Fmt({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.mono = false,
    this.pre = false,
    this.link,
  });
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool mono;
  final bool pre;
  final String? link;

  _Fmt copy({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? mono,
    bool? pre,
    String? link,
  }) => _Fmt(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    mono: mono ?? this.mono,
    pre: pre ?? this.pre,
    link: link ?? this.link,
  );
}
