// Campioni e mutazioni per il fuzz del lettore (reader_fuzz_test.dart per i
// parser, reader_view_fuzz_test.dart per le viste).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../reader_fixtures.dart';

Uint8List _u(String s) => Uint8List.fromList(utf8.encode(s));

/// Campioni validi da cui partono le mutazioni (estensione → byte).
Map<String, List<Uint8List>> fuzzCorpus() {
  List<Uint8List> fx(String dir, String ext) => [
    for (final f in Directory(p.join('test', 'fixtures', dir)).listSync())
      if (f is File && f.path.endsWith(ext)) f.readAsBytesSync(),
  ];
  const rtf =
      r'{\rtf1\ansi\ansicpg1252{\fonttbl{\f0 Arial;}}{\*\generator x;}'
      r'{\outlinelevel0 Titolo\par}'
      r"Testo \b grassetto\b0  e perch\'e8 荤? euro.\par"
      r'{\pict\pngblip 89504e47}\trowd\intbl A\cell B\cell\row'
      r'\pard Fine\par}';
  const ps = '%!PS-Adobe-3.0\n%%Pages: 2\n/S { show } bind def\n%%Page: 1 1\n'
      '/Times-Roman findfont 12 scalefont setfont\n'
      '72 700 moveto (Moto) show 72 660 moveto <4369616f> S\n'
      '72 640 moveto (xshow) [6 6 6 6 6] xshow\nshowpage\n';
  final fb2 =
      '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body>'
      '<section><title><p>Parte prima</p></title><p>Testo <emphasis>corsivo</emphasis></p><image l:href="#i1"/>'
      '<section><title><p>Sotto</p></title><p>dentro</p></section></section></body>'
      '<binary id="i1" content-type="image/png">${base64Encode(tinyPng)}</binary></FictionBook>';
  String page(String a) =>
      '<FixedPage><Glyphs OriginX="200" OriginY="100" UnicodeString="$a"/></FixedPage>';
  final xps = zipOf({
    'FixedDocSeq.fdseq':
        '<FixedDocumentSequence><DocumentReference Source="Documents/1/FixedDoc.fdoc"/></FixedDocumentSequence>',
    'Documents/1/FixedDoc.fdoc':
        '<FixedDocument><PageContent Source="Pages/1.fpage"/></FixedDocument>',
    'Documents/1/Pages/1.fpage': page('Ciao'),
  });
  final excalidraw = jsonEncode({
    'type': 'excalidraw',
    'elements': [
      {'type': 'rectangle', 'x': 100, 'y': 100, 'width': 50, 'height': 40},
      {'type': 'text', 'x': 1, 'y': 1, 'text': 'A', 'fontSize': 16},
      {
        'type': 'arrow',
        'x': 150,
        'y': 120,
        'points': [
          [0, 0],
          [50, 0],
        ],
      },
      {'type': 'freedraw', 'x': 0, 'y': 0, 'points': [[0, 0], [3, 4]]},
    ],
  });
  const inkml =
      '<?xml version="1.0"?><ink xmlns="http://www.w3.org/2003/InkML"><definitions>'
      '<brush xml:id="r"><brushProperty name="color" value="#FF0000"/></brush>'
      '<traceFormat><channel name="X" type="decimal"/><channel name="Y" type="decimal"/></traceFormat>'
      "</definitions><trace brushRef=\"#r\">10 10, 20 30, 40 70</trace><trace>100 100, '10 '0, \"5\"0</trace></ink>";
  const mm =
      '<map version="1.0.1"><node TEXT="Fisica"><node TEXT="Meccanica"><node TEXT="Cinematica"/></node>'
      '<node><richcontent TYPE="NOTE"><html><body><p>leggi</p></body></html></richcontent></node></node></map>';
  const opml =
      '<opml><head><title>S</title></head><body><outline text="Uno" _note="n"><outline text="Due"/></outline></body></opml>';
  final canvas = jsonEncode({
    'nodes': [
      {'id': 'a', 'type': 'text', 'text': '# T\nx', 'x': 0, 'y': 0},
      {'id': 'f', 'type': 'file', 'file': 'n.md', 'x': 3, 'y': 0},
    ],
    'edges': [
      {'fromNode': 'a', 'toNode': 'f', 'label': 'q'},
    ],
  });
  const acsm =
      '<?xml version="1.0"?><fulfillmentToken xmlns="http://ns.adobe.com/adept">'
      '<expiration>2026-10-11T12:00:00+00:00</expiration><resourceItemInfo><metadata>'
      '<dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">A</dc:title></metadata></resourceItemInfo></fulfillmentToken>';
  const ipynb =
      '{"cells":[{"cell_type":"markdown","source":["# T"]},{"cell_type":"code","source":"x=1","outputs":[{"text":["1"]}]}],"metadata":{}}';
  const srt = '1\n00:00:01,000 --> 00:00:02,500\nCiao\n\n2\n00:00:03,000 --> 00:00:04,000\nMondo\n';
  const md = '# Titolo\n\n- [ ] a\n- [x] b\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![[foto.png]] [[nota]] #tag\n\n```dart\nx\n```\n';
  final pages = zipOf({
    'Index/Document.iwa': 'x',
    'QuickLook/Preview.pdf': '%PDF-1.4 finto',
    'preview.jpg': tinyPng,
  });
  final comic = zipOf({'p10.png': tinyPng, 'p2.png': tinyPng, 'a.txt': 'x'});
  return {
    '.docx': [buildDocx()],
    '.pptx': [buildPptx(), ...fx('office', '.pptx')],
    '.xlsx': [buildXlsx(), ...fx('office', '.xlsx')],
    '.odt': [buildOdt()],
    '.odp': [buildOdp(), ...fx('office', '.odp')],
    '.ods': [buildOds(), ...fx('office', '.ods')],
    '.epub': [buildEpub()],
    '.xopp': [buildXopp()],
    '.enex': [buildEnex()],
    '.doc': [buildDoc('Ciao mondo, perché sì.')],
    '.xls': [buildXls(), ...fx('office', '.xls')],
    '.ppt': [buildPpt(), ...fx('office', '.ppt')],
    '.mobi': [buildMobi('<p>Capitolo</p><p>Era una notte</p>')],
    '.rar': [
      buildRar4({'a.txt': utf8.encode('ciao'), 'b/c.md': utf8.encode('# x')}),
      buildRar5({'a.txt': utf8.encode('ciao')}),
    ],
    '.cbr': [buildRar4({'p1.png': tinyPng, 'p2.png': tinyPng})],
    '.cbz': [comic],
    '.zip': [
      zipOf({'a.md': '# Nota\n[b](b.md)', 'b.md': 'x', 'img/x.png': tinyPng}),
    ],
    '.onepkg': [buildCab({'Esercizi.one': buildOneNote()}), ...fx('onenote', '.onepkg')],
    '.one': [buildOneNote()],
    '.isf': [buildIsf()],
    '.inkml': [_u(inkml)],
    '.excalidraw': [_u(excalidraw)],
    '.kfx': [buildKfx()],
    '.djvu': fx('djvu', '.djvu'),
    '.rtf': [_u(rtf)],
    '.ps': [Uint8List.fromList(latin1.encode(ps))],
    '.fb2': [_u(fb2)],
    '.xps': [xps],
    '.mm': [_u(mm)],
    '.opml': [_u(opml)],
    '.canvas': [_u(canvas)],
    '.acsm': [_u(acsm)],
    '.ipynb': [_u(ipynb)],
    '.srt': [_u(srt)],
    '.vtt': [_u('WEBVTT\n\n00:01.000 --> 00:02.000\nCiao\n')],
    '.md': [_u(md)],
    '.html': [_u('<html><body><h1>T</h1><p>a<b>b</b></p><table><tr><td>1</td></tr></table></body></html>')],
    '.xml': [_u('<?xml version="1.0"?><a><b x="1">t</b></a>')],
    '.json': [_u('{"a":[1,2,{"b":null}]}')],
    '.csv': [_u('a;b;c\n1;"2;3";4\n')],
    '.tex': [_u(r'\section{A} testo $x^2$ \begin{itemize}\item a\end{itemize}')],
    '.pages': [pages],
    '.goodnotes': [pages],
    '.tga': [Uint8List.fromList([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 24, 0, 1, 2, 3])],
    '.tif': [_tiny(Endian.little)],
    '.txt': [_u('ciao\nmondo')],
  };
}

/// TIFF 1×1 non compresso.
Uint8List _tiny(Endian e) {
  final b = ByteData(64);
  b.setUint16(0, 0x4949);
  b.setUint16(2, 42, e);
  b.setUint32(4, 8, e);
  b.setUint16(8, 4, e);
  void tag(int i, int t, int type, int v) {
    final o = 10 + i * 12;
    b.setUint16(o, t, e);
    b.setUint16(o + 2, type, e);
    b.setUint32(o + 4, 1, e);
    b.setUint32(o + 8, v, e);
  }

  tag(0, 256, 4, 1);
  tag(1, 257, 4, 1);
  tag(2, 273, 4, 60);
  tag(3, 279, 4, 1);
  return b.buffer.asUint8List();
}

const _smash = [
  [0xFF, 0xFF, 0xFF, 0xFF],
  [0x7F, 0xFF, 0xFF, 0xFF],
  [0x80, 0x00, 0x00, 0x00],
  [0x00, 0x00, 0x00, 0x00],
  [0x00, 0x01, 0x00, 0x00],
  [0xFF, 0xFF, 0x00, 0x00],
];

/// Elementi annidati [n] volte (div: in HTML non si richiudono da soli).
String _deepXml(int n) => '${'<div>' * n}x${'</div>' * n}';

/// [inner] dentro l'elemento radice del documento XML [b] (così il parser
/// del formato lo visita davvero).
String _wrapInRoot(Uint8List b, String inner) {
  final s = utf8.decode(b, allowMalformed: true);
  final close = s.lastIndexOf('</');
  return close < 0 ? s : '${s.substring(0, close)}$inner${s.substring(close)}';
}

const _laughs =
    '<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa">'
    '<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">'
    '<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">'
    '<!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">'
    '<!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">'
    '<!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;">]><l>&f;&f;&f;</l>';

/// Varianti rovinate di [b] (deterministiche con [rnd]).
Iterable<(String, Uint8List)> fuzzMutations(
  Uint8List b,
  Random rnd,
  int rounds,
) sync* {
  yield ('vuoto', Uint8List(0));
  for (final n in {1, 4, 8, 16, 64, b.length ~/ 4, b.length ~/ 2, b.length - 1}) {
    if (n > 0 && n < b.length) {
      yield ('troncato a $n', Uint8List.sublistView(b, 0, n));
    }
  }
  for (var r = 0; r < rounds; r++) {
    for (final k in [1, 4, 32]) {
      final m = Uint8List.fromList(b);
      for (var i = 0; i < k && m.isNotEmpty; i++) {
        m[rnd.nextInt(m.length)] = rnd.nextInt(256);
      }
      yield ('$k byte cambiati (giro $r)', m);
    }
    for (final s in _smash) {
      if (b.length < 8) break;
      final m = Uint8List.fromList(b);
      final o = rnd.nextInt(m.length - 4);
      m.setAll(o, s);
      yield ('intero ${s.first} in $o (giro $r)', m);
    }
    final noise = Uint8List(64 + rnd.nextInt(4096));
    for (var i = 0; i < noise.length; i++) {
      noise[i] = rnd.nextInt(256);
    }
    noise.setAll(0, b.take(min(8, noise.length)));
    yield ('rumore con intestazione (giro $r)', noise);
  }
  // Testi strutturati (XML, HTML, JSON, RTF): annidamento esagerato, righe
  // enormi, entità a catena.
  final head = utf8
      .decode(b.take(64).toList(), allowMalformed: true)
      .trimLeft();
  if (head.startsWith('<')) {
    yield ('XML annidato', _u('<?xml version="1.0"?>${_deepXml(30000)}'));
    yield ('XML annidato nella radice', _u(_wrapInRoot(b, _deepXml(30000))));
    yield ('XML con entità a catena', _u(_laughs));
    yield ('XML con 200000 attributi', _u('<a ${List.generate(200000, (i) => 'x$i="1"').join(' ')}/>'));
  }
  if (head.startsWith('{') || head.startsWith('[')) {
    yield ('JSON annidato', _u('${'[' * 100000}${']' * 100000}'));
    yield ('JSON con oggetti annidati', _u('${'{"a":' * 50000}1${'}' * 50000}'));
    yield ('JSON con numeri enormi', _u(utf8.decode(b, allowMalformed: true).replaceAll(RegExp(r'\d+'), '1e308')));
  }
  if (head.startsWith('{\\rtf')) {
    yield ('RTF annidato', _u('{\\rtf1 ${'{' * 100000}x${'}' * 100000}}'));
    yield ('RTF con immagine enorme', _u('{\\rtf1 {\\pict\\pngblip ${'f' * 4000000}}}'));
  }
  if (b.isNotEmpty && b.length < 1 << 20) {
    yield ('riga lunghissima', _u('${'a' * 3000000}\n'));
    yield ('molte righe', _u('x\n' * 400000));
  }
  // ZIP: voci rovinate una alla volta e XML patologici.
  Archive? zip;
  try {
    if (b.length > 4 && b[0] == 0x50 && b[1] == 0x4B) {
      zip = ZipDecoder().decodeBytes(b);
    }
  } catch (_) {}
  if (zip == null) return;
  final files = [for (final f in zip.files) if (f.isFile) f];
  final contents = [for (final f in files) f.readBytes() ?? Uint8List(0)];
  Uint8List rebuild(int which, List<int> data) {
    final a = Archive();
    for (var i = 0; i < files.length; i++) {
      a.addFile(ArchiveFile.bytes(files[i].name, i == which ? data : contents[i]));
    }
    return ZipEncoder().encodeBytes(a);
  }

  final deep = _deepXml(20000);
  const laughs = _laughs;
  for (var i = 0; i < files.length; i++) {
    final c = contents[i];
    final name = files[i].name;
    yield ('voce $name vuota', rebuild(i, const []));
    if (c.length > 2) {
      yield ('voce $name a metà', rebuild(i, c.sublist(0, c.length ~/ 2)));
    }
    for (var r = 0; r < rounds; r++) {
      final m = Uint8List.fromList(c);
      for (var k = 0; k < 8 && m.isNotEmpty; k++) {
        m[rnd.nextInt(m.length)] = rnd.nextInt(256);
      }
      yield ('voce $name con byte cambiati (giro $r)', rebuild(i, m));
    }
    final lower = name.toLowerCase();
    if (lower.endsWith('.xml') ||
        lower.endsWith('.rels') ||
        lower.endsWith('.opf') ||
        lower.endsWith('html') ||
        lower.endsWith('.fdoc') ||
        lower.endsWith('.fpage') ||
        lower.endsWith('.fdseq')) {
      yield ('voce $name annidata', rebuild(i, utf8.encode(deep)));
      yield ('voce $name con entità', rebuild(i, utf8.encode(laughs)));
    }
  }
}

