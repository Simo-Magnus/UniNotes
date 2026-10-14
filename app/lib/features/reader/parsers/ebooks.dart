import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'html_blocks.dart';
import 'text_formats.dart';
import 'zip_util.dart';

/// E-book: EPUB (capitoli XHTML con immagini, indice da nav/NCX), MOBI/AZW
/// senza DRM (PalmDOC), FictionBook (.fb2), XPS/OXPS (testo dei glifi).

/// Tipo di protezione (per spiegare con quale app aprire il libro).
enum DrmKind { generic, adobe, lcp, apple, kindle, kfx }

/// E-book protetto da DRM: il testo non è leggibile (e l'app non prova a
/// togliere la protezione).
class DrmProtectedException implements Exception {
  const DrmProtectedException({this.kind = DrmKind.generic});
  final DrmKind kind;
  @override
  String toString() => 'E-book protetto da DRM';
}

/// Protezione di un EPUB dai file in META-INF (null se si può leggere:
/// i soli caratteri offuscati non impediscono la lettura).
DrmKind? epubDrm(Zip zip) {
  if (zip.has('META-INF/license.lcpl')) return DrmKind.lcp;
  if (zip.has('META-INF/sinf.xml')) return DrmKind.apple;
  final rights = zip.text('META-INF/rights.xml') ?? '';
  if (rights.contains('adobe.com/adept')) return DrmKind.adobe;
  if (!zip.has('META-INF/encryption.xml')) return null;
  final enc = zip.text('META-INF/encryption.xml') ?? '';
  final algos = RegExp(r'Algorithm="([^"]+)"')
      .allMatches(enc)
      .map((m) => m.group(1)!)
      .toList();
  // Offuscamento dei caratteri (IDPF e Adobe): il testo resta leggibile.
  final real = algos.where(
    (a) =>
        !a.contains('obfuscation') &&
        !a.contains('font') &&
        a != 'http://www.idpf.org/2008/embedding' &&
        a != 'http://ns.adobe.com/pdf/enc#RC',
  );
  if (real.isEmpty) return null;
  if (enc.contains('adobe.com/adept') || rights.isNotEmpty) {
    return DrmKind.adobe;
  }
  if (enc.contains('readium.org/2014/01/lcp')) return DrmKind.lcp;
  return DrmKind.generic;
}

// ----------------------------------------------------------------- EPUB

RDoc parseEpub(Uint8List bytes) {
  final zip = Zip(bytes);
  final drm = epubDrm(zip);
  if (drm != null) throw DrmProtectedException(kind: drm);
  final container = zip.xml('META-INF/container.xml');
  final opfPath =
      container?.rootElement.firstDesc('rootfile')?.attr('full-path') ??
      zip.names.firstWhere(
        (n) => n.toLowerCase().endsWith('.opf'),
        orElse: () => '',
      );
  final opf = zip.xml(opfPath);
  if (opf == null) throw const FormatException('Pacchetto OPF mancante');
  final manifest = <String, ({String href, String type, String props})>{};
  for (final item in opf.rootElement.desc('item')) {
    final id = item.attr('id');
    final href = item.attr('href');
    if (id == null || href == null) continue;
    manifest[id] = (
      href: Zip.resolve(opfPath, Uri.decodeFull(href)),
      type: item.attr('media-type') ?? '',
      props: item.attr('properties') ?? '',
    );
  }
  final spine = opf.rootElement.firstDesc('spine');
  final order = [
    for (final ref in spine?.kids('itemref') ?? const <XmlElement>[])
      if (manifest[ref.attr('idref')] != null)
        manifest[ref.attr('idref')]!.href,
  ];
  final title = opf.rootElement.firstDesc('title')?.innerText.trim() ?? '';
  // EPUB 3 a impaginazione fissa: ogni elemento dello spine è una pagina.
  final fixed = opf.rootElement
      .desc('meta')
      .any(
        (m) =>
            m.attr('property') == 'rendition:layout' &&
            m.innerText.trim() == 'pre-paginated',
      );

  final tables = <RTable>[];
  final sections = <RSection>[];
  final anchorsByFile = <String, ({int section, Map<String, int> anchors})>{};
  for (final href in order) {
    final src = zip.text(href);
    if (src == null) continue;
    final conv = HtmlBlocks(
      tables: tables,
      images: (s) => zip.bytes(Zip.resolve(href, s.split('#').first)),
    );
    final blocks = conv.convert(src);
    final head = blocks
        .whereType<RPara>()
        .where((b) => b.isHeading)
        .firstOrNull
        ?.text;
    final name = HtmlBlocks.titleOf(src);
    sections.add(
      RSection(
        fixed
            ? 'Pagina ${sections.length + 1}'
            : head ??
                  (name.isNotEmpty ? name : 'Capitolo ${sections.length + 1}'),
        blocks,
      ),
    );
    anchorsByFile[href.toLowerCase()] = (
      section: sections.length - 1,
      anchors: conv.anchors,
    );
  }

  RTocEntry? entry(String label, String target, int level) {
    final parts = target.split('#');
    final file = parts.first.toLowerCase();
    final a = anchorsByFile[file];
    if (a == null) return null;
    final block = parts.length > 1 ? (a.anchors[parts[1]] ?? 0) : 0;
    return RTocEntry(
      label.trim(),
      section: a.section,
      block: block,
      level: level,
    );
  }

  final toc = <RTocEntry>[];
  // EPUB 3: documento di navigazione.
  final nav = manifest.values.where((m) => m.props.contains('nav')).firstOrNull;
  if (nav != null) {
    final src = zip.text(nav.href);
    if (src != null) {
      final doc = html.parse(src);
      final navEl =
          doc.querySelectorAll('nav').where((n) {
            final t = n.attributes['epub:type'] ?? n.attributes['type'] ?? '';
            return t.contains('toc');
          }).firstOrNull ??
          doc.querySelector('nav');
      void walk(dom.Element ol, int level) {
        for (final li in ol.children.where((c) => c.localName == 'li')) {
          final a = li.querySelector('a');
          final href = a?.attributes['href'];
          if (a != null && href != null) {
            final e = entry(
              a.text,
              Zip.resolve(nav.href, Uri.decodeFull(href)),
              level,
            );
            if (e != null) toc.add(e);
          }
          for (final sub in li.children.where((c) => c.localName == 'ol')) {
            walk(sub, level + 1);
          }
        }
      }

      final ol = navEl?.querySelector('ol');
      if (ol != null) walk(ol, 0);
    }
  }
  // EPUB 2: NCX.
  if (toc.isEmpty) {
    final ncxId = spine?.attr('toc');
    final ncx =
        manifest[ncxId] ??
        manifest.values.where((m) => m.type.contains('dtbncx')).firstOrNull;
    final doc = ncx == null ? null : zip.xml(ncx.href);
    void walk(XmlElement parent, int level) {
      for (final np in parent.kids('navPoint')) {
        final label = np.firstDesc('text')?.innerText ?? '';
        final src = np.kid('content')?.attr('src');
        if (src != null) {
          final e = entry(
            label,
            Zip.resolve(ncx!.href, Uri.decodeFull(src)),
            level,
          );
          if (e != null) toc.add(e);
        }
        walk(np, level + 1);
      }
    }

    final map = doc?.rootElement.firstDesc('navMap');
    if (map != null) walk(map, 0);
  }
  return RDoc(
    sections: sections.isEmpty ? [RSection(title)] : sections,
    unitLabel: fixed ? 'Pagina' : 'Capitolo',
    toc: toc,
    tables: tables,
  );
}

// ----------------------------------------------------------------- ACSM

/// Data e ora brevi da una data ISO ("11/10/2026 12:00").
String _shortDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Token di Adobe Content Server (.acsm): non è il libro ma il "biglietto"
/// per scaricarlo con Adobe Digital Editions (o un lettore compatibile).
/// Si mostrano i dati del libro e la spiegazione; il token non si usa per
/// scaricare né per togliere protezioni.
RDoc parseAcsm(Uint8List bytes, {DateTime? now}) {
  final doc = XmlDocument.parse(decodeText(bytes));
  final root = doc.rootElement;
  if (root.local != 'fulfillmentToken') {
    throw const FormatException('non è un token ACSM (fulfillmentToken)');
  }
  final meta = root.firstDesc('metadata') ?? root;
  String? field(XmlElement e, String local) {
    final t = e.firstDesc(local)?.innerText.trim();
    return t == null || t.isEmpty ? null : t;
  }

  final title = field(meta, 'title');
  final authors = [
    for (final c in meta.desc('creator'))
      if (c.innerText.trim().isNotEmpty) c.innerText.trim(),
  ];
  final format = field(meta, 'format');
  final formatLabel = switch (format) {
    'application/epub+zip' => 'EPUB',
    'application/pdf' => 'PDF',
    null => null,
    _ => format,
  };
  final expiry = field(root, 'expiration');
  final expiryDate = expiry == null ? null : DateTime.tryParse(expiry);
  final expired =
      expiryDate != null && expiryDate.isBefore(now ?? DateTime.now());
  final rows = <(String, String?)>[
    ('Titolo', title),
    ('Autore', authors.isEmpty ? null : authors.join(', ')),
    ('Editore', field(meta, 'publisher')),
    ('Formato', formatLabel),
    ('Lingua', field(meta, 'language')),
    ('Identificativo', field(meta, 'identifier')),
    (
      'Scadenza',
      expiryDate == null
          ? expiry
          : '${_shortDate(expiryDate.toLocal())}${expired ? ' (scaduto)' : ''}',
    ),
    ('Venditore', field(root, 'operatorURL')),
  ];
  final tables = <RTable>[];
  final t = RTable([]);
  tables.add(t);
  final blocks = <RBlock>[
    RPara.text(title ?? 'E-book Adobe (ACSM)', style: RStyle.h1),
    RPara.text(
      'Questo file .acsm non contiene il libro: è il "biglietto" del negozio '
      'per scaricarlo. Aprilo con Adobe Digital Editions (o con un lettore '
      'compatibile con Adobe, come Thorium Reader, Kobo o PocketBook): il '
      'programma scarica l\'e-book${formatLabel == null ? '' : ' in $formatLabel'} '
      'e lo associa al tuo Adobe ID. Usa "Apri con…".',
    ),
    if (expired)
      RPara.text(
        'Il biglietto è scaduto: scaricalo di nuovo dal negozio.',
        style: RStyle.quote,
      ),
    RPara.text(
      'Il libro scaricato è protetto da DRM: l\'app non può e non deve '
      'toglierlo, si legge nel programma di Adobe.',
      style: RStyle.caption,
    ),
  ];
  for (final (label, value) in rows) {
    if (value == null) continue;
    final cells = [label, value];
    t.fit(cells);
    blocks.add(RTableRow(cells, table: 0));
  }
  return RDoc(
    sections: [RSection('', blocks)],
    tables: tables,
    notice:
        'Token di download di Adobe: il libro si scarica con Adobe Digital '
        'Editions.',
  );
}

// ----------------------------------------------------------------- MOBI

/// Decompressione PalmDOC (LZ77 semplice dei file .mobi/.prc/.azw).
Uint8List palmDocDecompress(Uint8List src) {
  final out = BytesBuilder(copy: false);
  final buf = <int>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i++];
    if (c == 0 || (c >= 0x09 && c <= 0x7F)) {
      buf.add(c);
    } else if (c >= 0x01 && c <= 0x08) {
      for (var k = 0; k < c && i < src.length; k++) {
        buf.add(src[i++]);
      }
    } else if (c >= 0x80 && c <= 0xBF) {
      if (i >= src.length) break;
      final pair = (c << 8) | src[i++];
      final dist = (pair >> 3) & 0x7FF;
      final len = (pair & 0x7) + 3;
      for (var k = 0; k < len; k++) {
        final at = buf.length - dist;
        buf.add(at >= 0 && at < buf.length ? buf[at] : 0x20);
      }
    } else {
      buf
        ..add(0x20)
        ..add(c ^ 0x80);
    }
  }
  out.add(buf);
  return out.takeBytes();
}

/// Byte finali di un record di testo da ignorare (flag "extra data").
int _trailing(Uint8List rec, int flags) {
  var size = 0;
  var end = rec.length;
  for (var bit = 15; bit >= 1; bit--) {
    if (flags & (1 << bit) == 0) continue;
    // Intero a lunghezza variabile letto all'indietro.
    var v = 0;
    var shift = 0;
    for (var k = 0; k < 4 && end - size - 1 - k >= 0; k++) {
      final b = rec[end - size - 1 - k];
      v |= (b & 0x7F) << shift;
      shift += 7;
      if (b & 0x80 != 0) break;
    }
    size += v;
  }
  if (flags & 1 != 0 && end - size - 1 >= 0) {
    size += (rec[end - size - 1] & 0x3) + 1;
  }
  return size.clamp(0, rec.length);
}

RDoc parseMobi(Uint8List bytes) {
  if (bytes.length < 78) throw const FormatException('File MOBI troppo corto');
  final d = ByteData.sublistView(bytes);
  final n = d.getUint16(76, Endian.big);
  final offsets = <int>[
    for (var i = 0; i < n; i++) d.getUint32(78 + i * 8, Endian.big),
  ];
  Uint8List record(int i) {
    final start = offsets[i];
    final end = i + 1 < n ? offsets[i + 1] : bytes.length;
    return Uint8List.sublistView(bytes, start, end.clamp(start, bytes.length));
  }

  final r0 = record(0);
  final h = ByteData.sublistView(r0);
  final compression = h.getUint16(0, Endian.big);
  final textRecords = h.getUint16(8, Endian.big);
  final encryption = h.getUint16(12, Endian.big);
  if (encryption != 0) {
    throw const DrmProtectedException(kind: DrmKind.kindle);
  }
  var utf8Text = false;
  var extraFlags = 0;
  var firstImage = -1;
  var title = '';
  final isMobi =
      r0.length > 20 && String.fromCharCodes(r0.sublist(16, 20)) == 'MOBI';
  if (isMobi) {
    final headerLen = h.getUint32(20, Endian.big);
    utf8Text = h.getUint32(28, Endian.big) == 65001;
    if (headerLen >= 0xE4 && r0.length >= 0xF4) {
      extraFlags = h.getUint16(0xF2, Endian.big);
    }
    if (r0.length >= 0x70) firstImage = h.getUint32(0x6C, Endian.big);
    final nameOff = h.getUint32(0x54, Endian.big);
    final nameLen = h.getUint32(0x58, Endian.big);
    if (nameOff + nameLen <= r0.length) {
      title = utf8.decode(
        r0.sublist(nameOff, nameOff + nameLen),
        allowMalformed: true,
      );
    }
  }
  if (compression == 17480) {
    throw const FormatException('Compressione HUFF/CDIC non supportata');
  }
  final text = BytesBuilder(copy: false);
  for (var i = 1; i <= textRecords && i < n; i++) {
    var rec = record(i);
    final cut = _trailing(rec, extraFlags);
    rec = Uint8List.sublistView(rec, 0, rec.length - cut);
    text.add(compression == 2 ? palmDocDecompress(rec) : rec);
  }
  final raw = text.takeBytes();
  final source = utf8Text
      ? utf8.decode(raw, allowMalformed: true)
      : decodeCp1252(raw);
  // Immagini: <img recindex="00001"> → record firstImage + indice - 1.
  final withImages = firstImage > 0 && firstImage < n
      ? source.replaceAllMapped(
          RegExp(r'recindex="?(\d+)"?', caseSensitive: false),
          (m) => 'src="rec:${m.group(1)}"',
        )
      : source;
  final conv = HtmlBlocks(
    images: (s) {
      if (!s.startsWith('rec:')) return null;
      final idx = firstImage + int.parse(s.substring(4)) - 1;
      return idx > 0 && idx < n ? Uint8List.fromList(record(idx)) : null;
    },
  );
  final isHtml = withImages.contains('<');
  final blocks = isHtml
      ? conv.convert(
          withImages.replaceAll(
            RegExp(r'<mbp:pagebreak\s*/?>', caseSensitive: false),
            '<hr/>',
          ),
        )
      : plainTextDoc(withImages).sections.first.blocks;
  return RDoc(sections: [RSection(title, blocks)], tables: conv.tables);
}

// ------------------------------------------------------------------ FB2

RDoc parseFb2(Uint8List bytes) {
  final doc = XmlDocument.parse(decodeText(bytes));
  final binaries = <String, Uint8List>{};
  for (final b in doc.rootElement.desc('binary')) {
    final id = b.attr('id');
    if (id == null) continue;
    try {
      binaries[id] = base64Decode(b.innerText.replaceAll(RegExp(r'\s'), ''));
    } catch (_) {}
  }
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  List<RSpan> spans(XmlElement e, {bool bold = false, bool italic = false}) {
    final out = <RSpan>[];
    for (final c in e.children) {
      if (c is XmlText) {
        out.add(
          RSpan(
            c.value.replaceAll(RegExp(r'\s+'), ' '),
            bold: bold,
            italic: italic,
          ),
        );
      } else if (c is XmlElement) {
        out.addAll(
          spans(
            c,
            bold: bold || c.local == 'strong',
            italic: italic || c.local == 'emphasis',
          ),
        );
      }
    }
    return out;
  }

  void section(XmlElement s, int level, List<RBlock> into) {
    for (final c in s.childElements) {
      switch (c.local) {
        case 'title':
          final t = c.kids('p').map((p) => p.innerText.trim()).join(' ');
          into.add(
            RPara.text(
              t,
              style: level == 0
                  ? RStyle.h1
                  : (level == 1 ? RStyle.h2 : RStyle.h3),
            ),
          );
        case 'p' || 'subtitle' || 'v' || 'text-author':
          into.add(
            RPara(
              spans(c),
              style: c.local == 'subtitle' ? RStyle.h4 : RStyle.body,
            ),
          );
        case 'epigraph' || 'cite' || 'poem' || 'stanza':
          final inner = <RBlock>[];
          section(c, level, inner);
          into.addAll([
            for (final b in inner)
              if (b is RPara) RPara(b.spans, style: RStyle.quote) else b,
          ]);
        case 'empty-line':
          break;
        case 'image':
          final href = (c.attr('href') ?? '').replaceFirst('#', '');
          final data = binaries[href];
          if (data != null) into.add(RImage(data));
        case 'section':
          section(c, level + 1, into);
      }
    }
  }

  for (final body in doc.rootElement.kids('body')) {
    final tops = body.kids('section').toList();
    if (tops.isEmpty) {
      final blocks = <RBlock>[];
      section(body, 0, blocks);
      sections.add(RSection('', blocks));
      continue;
    }
    for (final s in tops) {
      final blocks = <RBlock>[];
      section(s, 0, blocks);
      final t = s
          .kid('title')
          ?.innerText
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      sections.add(RSection(t ?? 'Capitolo ${sections.length + 1}', blocks));
    }
  }
  for (var i = 0; i < sections.length; i++) {
    final s = sections[i];
    if (s.title.isNotEmpty) toc.add(RTocEntry(s.title, section: i));
    for (var b = 0; b < s.blocks.length; b++) {
      final blk = s.blocks[b];
      if (blk is RPara && (blk.style == RStyle.h2 || blk.style == RStyle.h3)) {
        toc.add(RTocEntry(blk.text, section: i, block: b, level: 1));
      }
    }
  }
  return RDoc(sections: sections, unitLabel: 'Capitolo', toc: toc);
}

// ------------------------------------------------------------------ XPS

/// Documento XPS/OXPS: testo dei glifi (`UnicodeString`) pagina per pagina,
/// nell'ordine di lettura approssimato (dall'alto, da sinistra).
RDoc parseXps(Uint8List bytes) {
  final zip = Zip(bytes);
  final pages = <String>[];
  // Sequenza → documenti → pagine.
  String? seq;
  for (final r in readRels(zip, '').values) {
    if (r.type.toLowerCase().contains('fixedrepresentation')) seq = r.target;
  }
  seq ??= zip.names
      .where((n) => n.toLowerCase().endsWith('.fdseq'))
      .firstOrNull;
  final seqXml = seq == null ? null : zip.xml(seq);
  for (final ref
      in seqXml?.rootElement.desc('DocumentReference') ??
          const <XmlElement>[]) {
    final docPath = Zip.resolve(seq!, ref.attr('Source') ?? '');
    final fdoc = zip.xml(docPath);
    for (final pc
        in fdoc?.rootElement.desc('PageContent') ?? const <XmlElement>[]) {
      pages.add(Zip.resolve(docPath, pc.attr('Source') ?? ''));
    }
  }
  if (pages.isEmpty) {
    pages.addAll(
      zip.names.where((n) => n.toLowerCase().endsWith('.fpage')).toList()
        ..sort((a, b) => _natural(a).compareTo(_natural(b))),
    );
  }
  final sections = <RSection>[];
  for (final page in pages) {
    final xml = zip.xml(page);
    if (xml == null) continue;
    final glyphs = <({double x, double y, String text})>[];
    for (final g in xml.rootElement.desc('Glyphs')) {
      final t = g.attr('UnicodeString');
      if (t == null || t.trim().isEmpty) continue;
      glyphs.add((
        x: double.tryParse(g.attr('OriginX') ?? '') ?? 0,
        y: double.tryParse(g.attr('OriginY') ?? '') ?? 0,
        text: t.startsWith('{}') ? t.substring(2) : t,
      ));
    }
    // Righe: glifi con la stessa linea di base (entro 2 unità).
    final lines = <List<({double x, double y, String text})>>[];
    for (final g in glyphs) {
      final line = lines.where((l) => (l.first.y - g.y).abs() < 2).firstOrNull;
      if (line != null) {
        line.add(g);
      } else {
        lines.add([g]);
      }
    }
    lines.sort((a, b) => a.first.y.compareTo(b.first.y));
    final blocks = <RBlock>[
      for (final l in lines)
        RPara.text(
          (l..sort((a, b) => a.x.compareTo(b.x))).map((g) => g.text).join(' '),
        ),
    ];
    sections.add(RSection('Pagina ${sections.length + 1}', blocks));
  }
  return RDoc(sections: sections, unitLabel: 'Pagina');
}

String _natural(String s) => p
    .basenameWithoutExtension(s)
    .replaceAllMapped(RegExp(r'\d+'), (m) => m.group(0)!.padLeft(8, '0'));
