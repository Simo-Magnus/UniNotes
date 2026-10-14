import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'html_blocks.dart';
import 'text_formats.dart';
import 'zip_util.dart';

/// Formati delle app di appunti: mappe mentali (FreeMind/Freeplane .mm),
/// scalette (.opml), Evernote (.enex), canvas di Obsidian, contenitori ZIP
/// (Pages, Keynote, Numbers, GoodNotes, Notability) e fumetti (.cbz).

// -------------------------------------------------------------- Scalette

class OutlineNode {
  OutlineNode(this.text, {this.note, this.link, List<OutlineNode>? children})
    : children = children ?? [];
  final String text;
  final String? note;
  final String? link;
  final List<OutlineNode> children;

  /// Nodi in profondità (con il livello), nell'ordine di lettura.
  Iterable<(OutlineNode, int)> walk([int level = 0]) sync* {
    yield (this, level);
    for (final c in children) {
      yield* c.walk(level + 1);
    }
  }
}

class OutlineDoc {
  OutlineDoc(this.title, this.roots);
  final String title;
  final List<OutlineNode> roots;

  Iterable<(OutlineNode, int)> walk() sync* {
    for (final r in roots) {
      yield* r.walk();
    }
  }
}

String _htmlText(String source) =>
    html.parse(source).body?.text.replaceAll(RegExp(r'[ \t]+'), ' ').trim() ??
    '';

/// Mappa mentale FreeMind / Freeplane (.mm).
OutlineDoc parseMindMap(Uint8List bytes) {
  final doc = XmlDocument.parse(decodeText(bytes));
  OutlineNode node(XmlElement e) {
    var text = e.attr('TEXT') ?? '';
    String? note;
    for (final rc in e.kids('richcontent')) {
      final t = _htmlText(rc.innerXml);
      final type = rc.attr('TYPE');
      if (type == 'NOTE' || type == 'DETAILS') {
        note = [?note, t].join('\n');
      } else if (text.isEmpty) {
        text = t;
      }
    }
    return OutlineNode(
      text,
      note: note,
      link: e.attr('LINK'),
      children: [for (final c in e.kids('node')) node(c)],
    );
  }

  final roots = [for (final n in doc.rootElement.kids('node')) node(n)];
  return OutlineDoc(roots.isEmpty ? '' : roots.first.text, roots);
}

/// Scaletta OPML (.opml): elenchi annidati di `outline`.
OutlineDoc parseOpml(Uint8List bytes) {
  final doc = XmlDocument.parse(decodeText(bytes));
  OutlineNode node(XmlElement e) => OutlineNode(
    e.attr('text') ?? e.attr('title') ?? '',
    note: e.attr('_note'),
    link: e.attr('url') ?? e.attr('htmlUrl') ?? e.attr('xmlUrl'),
    children: [for (final c in e.kids('outline')) node(c)],
  );
  final body = doc.rootElement.kid('body');
  final title =
      doc.rootElement.kid('head')?.kid('title')?.innerText.trim() ?? '';
  return OutlineDoc(title, [
    for (final o in body?.kids('outline') ?? const <XmlElement>[]) node(o),
  ]);
}

// --------------------------------------------------------------- Evernote

/// Esportazione Evernote (.enex): una sezione per nota, con le immagini
/// allegate (collegate dall'hash MD5 negli `en-media`).
RDoc parseEnex(Uint8List bytes) {
  final doc = XmlDocument.parse(decodeText(bytes));
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  final tables = <RTable>[];
  for (final note in doc.rootElement.kids('note')) {
    final title = note.kid('title')?.innerText.trim() ?? 'Nota';
    final resources = <String, Uint8List>{};
    for (final r in note.kids('resource')) {
      final data = r.kid('data');
      if (data == null) continue;
      try {
        final b = base64Decode(data.innerText.replaceAll(RegExp(r'\s'), ''));
        final mime = r.kid('mime')?.innerText ?? '';
        if (mime.startsWith('image/')) resources[md5.convert(b).toString()] = b;
      } catch (_) {}
    }
    final content = note.kid('content')?.innerText ?? '';
    final conv = HtmlBlocks(
      tables: tables,
      images: (s) => s.startsWith('hash:') ? resources[s.substring(5)] : null,
    );
    final blocks = conv.convert(
      content
          .replaceFirst(RegExp(r'<\?xml[^>]*\?>'), '')
          .replaceFirst(RegExp(r'<!DOCTYPE[^>]*>'), ''),
    );
    final meta = [
      _enexDate(note.kid('created')?.innerText),
      ...note.kids('tag').map((t) => '#${t.innerText}'),
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    sections.add(
      RSection(title, [
        RPara.text(title, style: RStyle.h1),
        if (meta.isNotEmpty) RPara.text(meta, style: RStyle.caption),
        ...blocks,
      ]),
    );
    toc.add(RTocEntry(title, section: sections.length - 1));
  }
  return RDoc(sections: sections, unitLabel: 'Nota', toc: toc, tables: tables);
}

String? _enexDate(String? s) {
  if (s == null || s.length < 8) return null;
  return '${s.substring(6, 8)}/${s.substring(4, 6)}/${s.substring(0, 4)}';
}

// ------------------------------------------------------ Canvas di Obsidian

/// Canvas di Obsidian (.canvas): schede di testo (Markdown), file, link e
/// gruppi, dall'alto in basso; poi i collegamenti.
RDoc parseCanvas(Uint8List bytes) {
  final json = jsonDecode(decodeText(bytes)) as Map<String, dynamic>;
  final nodes = (json['nodes'] as List? ?? const []).cast<Map>().toList();
  num n(Object? v) => (v as num?) ?? 0;
  nodes.sort((a, b) {
    final dy = n(a['y']).compareTo(n(b['y']));
    return dy != 0 ? dy : n(a['x']).compareTo(n(b['x']));
  });
  final byId = <String, String>{};
  final blocks = <RBlock>[];
  for (final node in nodes) {
    final type = node['type'];
    final String label;
    switch (type) {
      case 'text':
        final text = (node['text'] ?? '').toString();
        label = text.split('\n').first.replaceAll(RegExp(r'^#+\s*'), '');
        blocks.add(RBreak('Scheda'));
        blocks.addAll(markdownBlocks(text));
      case 'file':
        final f = (node['file'] ?? '').toString();
        label = p.basename(f);
        blocks.add(RBreak('File'));
        blocks.add(RPara([RSpan(f, mono: true)]));
      case 'link':
        final u = (node['url'] ?? '').toString();
        label = u;
        blocks.add(RBreak('Link'));
        blocks.add(RPara([RSpan(u, link: u, underline: true)]));
      case 'group':
        label = (node['label'] ?? 'Gruppo').toString();
        blocks.add(RPara.text(label, style: RStyle.h2));
      default:
        label = type?.toString() ?? '';
    }
    final id = node['id']?.toString();
    if (id != null) byId[id] = label;
  }
  final edges = (json['edges'] as List? ?? const []).cast<Map>();
  if (edges.isNotEmpty) {
    blocks.add(RPara.text('Collegamenti', style: RStyle.h2));
    for (final e in edges) {
      final from = byId[e['fromNode']] ?? '?';
      final to = byId[e['toNode']] ?? '?';
      final l = e['label'];
      blocks.add(
        RPara.text(
          '$from → $to${l == null ? '' : ' ($l)'}',
          style: RStyle.list,
          marker: '•',
        ),
      );
    }
  }
  return RDoc(sections: [RSection('', blocks)]);
}

// ------------------------------------------------- Contenitori con anteprima

/// Contenuto mostrabile di un contenitore ZIP (iWork, GoodNotes,
/// Notability): PDF incorporati e immagini d'anteprima.
class ContainerPreview {
  ContainerPreview({this.pdf, this.pdfName, required this.images});
  final Uint8List? pdf;
  final String? pdfName;
  final List<({String name, Uint8List bytes})> images;
  bool get isEmpty => pdf == null && images.isEmpty;
}

const _imageExt = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

/// Cerca PDF e immagini in un contenitore. Prima le anteprime note
/// (QuickLook/Preview.pdf, preview.jpg), poi i PDF incorporati, poi le
/// immagini più grandi.
ContainerPreview containerPreview(Uint8List bytes) {
  final zip = Zip.tryOpen(bytes);
  if (zip == null) return ContainerPreview(images: const []);
  for (final name in ['QuickLook/Preview.pdf', 'preview.pdf']) {
    final b = zip.bytes(name);
    if (b != null) {
      return ContainerPreview(pdf: b, pdfName: name, images: const []);
    }
  }
  final pdfs = zip.names
      .where((n) => n.toLowerCase().endsWith('.pdf'))
      .toList();
  if (pdfs.isNotEmpty) {
    pdfs.sort(
      (a, b) =>
          (zip.bytes(b)?.length ?? 0).compareTo(zip.bytes(a)?.length ?? 0),
    );
    return ContainerPreview(
      pdf: zip.bytes(pdfs.first),
      pdfName: pdfs.first,
      images: const [],
    );
  }
  for (final name in [
    'preview.jpg',
    'QuickLook/Thumbnail.jpg',
    'preview-web.jpg',
    'thumbnail.jpg',
    'thumbnail.png',
  ]) {
    final b = zip.bytes(name);
    if (b != null) return ContainerPreview(images: [(name: name, bytes: b)]);
  }
  final images = <({String name, Uint8List bytes})>[];
  for (final n in zip.names) {
    final ext = p.extension(n).toLowerCase();
    if (!_imageExt.contains(ext) || n.contains('__MACOSX')) continue;
    final b = zip.bytes(n);
    if (b != null && b.length > 2048) images.add((name: n, bytes: b));
  }
  images.sort((a, b) => naturalKey(a.name).compareTo(naturalKey(b.name)));
  return ContainerPreview(images: images);
}

/// Chiave per l'ordine naturale dei nomi ("p2" prima di "p10").
String naturalKey(String s) => s.toLowerCase().replaceAllMapped(
  RegExp(r'\d+'),
  (m) => m.group(0)!.padLeft(8, '0'),
);

/// Immagini come documento (una per pagina): fumetti .cbz, anteprime.
RDoc galleryDoc(
  List<({String name, Uint8List bytes})> images, {
  String? notice,
}) => RDoc(
  sections: [
    for (var i = 0; i < images.length; i++)
      RSection('Pagina ${i + 1}', [
        RImage(images[i].bytes, caption: p.basename(images[i].name)),
      ]),
  ],
  notice: notice,
);

/// Fumetto/raccolta di immagini (.cbz): pagine in ordine naturale dei nomi.
RDoc parseCbz(Uint8List bytes) {
  final zip = Zip(bytes);
  final names =
      zip.names
          .where(
            (n) =>
                _imageExt.contains(p.extension(n).toLowerCase()) &&
                !n.contains('__MACOSX'),
          )
          .toList()
        ..sort((a, b) => naturalKey(a).compareTo(naturalKey(b)));
  return galleryDoc([for (final n in names) (name: n, bytes: zip.bytes(n)!)]);
}
