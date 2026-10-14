// Fixture dei test del lettore: piccoli file costruiti nel codice. Fanno
// eccezione quelli prodotti da strumenti esterni (DjVuLibre, gcab), in
// test/fixtures/.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

Uint8List zipOf(Map<String, Object> files) {
  final a = Archive();
  files.forEach((name, content) {
    a.addFile(
      content is String
          ? ArchiveFile.string(name, content)
          : ArchiveFile.bytes(name, content as List<int>),
    );
  });
  return ZipEncoder().encodeBytes(a);
}

/// PNG 1×1 valido.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _w =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
const _rels =
    'xmlns="http://schemas.openxmlformats.org/package/2006/relationships"';
const _relBase =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

String _root(String target) =>
    '<Relationships $_rels><Relationship Id="rId1" Type="$_relBase/officeDocument" Target="$target"/></Relationships>';

Uint8List buildDocx() => zipOf({
  '[Content_Types].xml': '<Types/>',
  '_rels/.rels': _root('word/document.xml'),
  'word/_rels/document.xml.rels':
      '<Relationships $_rels><Relationship Id="rId5" Type="$_relBase/image" Target="media/image1.png"/></Relationships>',
  'word/media/image1.png': tinyPng,
  'word/styles.xml':
      '<w:styles $_w><w:style w:type="paragraph" w:styleId="Titolo1"><w:name w:val="heading 1"/></w:style></w:styles>',
  'word/numbering.xml':
      '<w:numbering $_w><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>',
  'word/document.xml':
      '<w:document $_w><w:body>'
      '<w:p><w:pPr><w:pStyle w:val="Titolo1"/></w:pPr><w:r><w:t>Introduzione</w:t></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">Il </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>teorema</w:t></w:r><w:r><w:t xml:space="preserve"> di Rolle, perché sì.</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>primo punto</w:t></w:r></w:p>'
      '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>secondo punto</w:t></w:r></w:p>'
      '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
      '<w:p><w:r><w:br w:type="page"/></w:r><w:r><w:t>Seconda pagina</w:t></w:r></w:p>'
      '<w:p><w:r><w:drawing><a:graphic><a:graphicData><a:blip r:embed="rId5"/></a:graphicData></a:graphic></w:drawing></w:r></w:p>'
      '</w:body></w:document>',
});

const _p =
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

String _slide(String title, String body) =>
    '<p:sld $_p><p:cSld><p:spTree>'
    '<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp>'
    '<p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:pPr lvl="1"/><a:r><a:t>$body</a:t></a:r></a:p></p:txBody></p:sp>'
    '</p:spTree></p:cSld></p:sld>';

/// Due diapositive in ordine inverso rispetto ai nomi dei file.
Uint8List buildPptx() => zipOf({
  '_rels/.rels': _root('ppt/presentation.xml'),
  'ppt/presentation.xml':
      '<p:presentation $_p><p:sldIdLst><p:sldId id="257" r:id="rId3"/><p:sldId id="256" r:id="rId2"/></p:sldIdLst></p:presentation>',
  'ppt/_rels/presentation.xml.rels':
      '<Relationships $_rels>'
      '<Relationship Id="rId2" Type="$_relBase/slide" Target="slides/slide1.xml"/>'
      '<Relationship Id="rId3" Type="$_relBase/slide" Target="slides/slide2.xml"/>'
      '</Relationships>',
  'ppt/slides/slide1.xml': _slide('Seconda', 'dettagli'),
  'ppt/slides/slide2.xml': _slide('Prima', 'città'),
  'ppt/slides/_rels/slide2.xml.rels':
      '<Relationships $_rels><Relationship Id="rId9" Type="$_relBase/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>',
  'ppt/notesSlides/notesSlide1.xml':
      '<p:notes $_p><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>ricordati la demo</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>',
});

const _x =
    'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

Uint8List buildXlsx() => zipOf({
  '_rels/.rels': _root('xl/workbook.xml'),
  'xl/workbook.xml':
      '<workbook $_x><sheets><sheet name="Voti" sheetId="1" r:id="rId1"/><sheet name="Note" sheetId="2" r:id="rId2"/></sheets></workbook>',
  'xl/_rels/workbook.xml.rels':
      '<Relationships $_rels>'
      '<Relationship Id="rId1" Type="$_relBase/worksheet" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="$_relBase/worksheet" Target="/xl/worksheets/sheet2.xml"/>'
      '<Relationship Id="rId3" Type="$_relBase/sharedStrings" Target="sharedStrings.xml"/>'
      '<Relationship Id="rId4" Type="$_relBase/styles" Target="styles.xml"/>'
      '</Relationships>',
  'xl/sharedStrings.xml':
      '<sst $_x><si><t>Esame</t></si><si><t>Voto</t></si><si><r><t>Anal</t></r><r><t>isi</t></r></si></sst>',
  'xl/styles.xml':
      '<styleSheet $_x><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>',
  'xl/worksheets/sheet1.xml':
      '<worksheet $_x><sheetData>'
      '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="inlineStr"><is><t>Data</t></is></c></row>'
      '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>28.5</v></c><c r="C2" s="1"><v>45200</v></c></row>'
      '<row r="4"><c r="D4" t="b"><v>1</v></c></row>'
      '</sheetData></worksheet>',
  'xl/worksheets/sheet2.xml':
      '<worksheet $_x><sheetData><row r="1"><c r="A1" t="str"><v>ok</v></c></row></sheetData></worksheet>',
});

const _odf =
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
    'xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" '
    'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
    'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
    'xmlns:xlink="http://www.w3.org/1999/xlink"';

Uint8List buildOdt() => zipOf({
  'mimetype': 'application/vnd.oasis.opendocument.text',
  'Pictures/a.png': tinyPng,
  'content.xml':
      '<office:document-content $_odf>'
      '<office:automatic-styles><style:style style:name="T1"><style:text-properties fo:font-weight="bold"/></style:style></office:automatic-styles>'
      '<office:body><office:text>'
      '<text:h text:outline-level="1">Capitolo uno</text:h>'
      '<text:p>Testo con <text:span text:style-name="T1">grassetto</text:span> e<text:s text:c="2"/>spazi.</text:p>'
      '<text:list><text:list-item><text:p>voce</text:p></text:list-item></text:list>'
      '<table:table><table:table-row><table:table-cell><text:p>x</text:p></table:table-cell><table:table-cell><text:p>y</text:p></table:table-cell></table:table-row></table:table>'
      '<text:p><draw:frame><draw:image xlink:href="Pictures/a.png"/></draw:frame></text:p>'
      '</office:text></office:body></office:document-content>',
});

Uint8List buildOdp() => zipOf({
  'content.xml':
      '<office:document-content $_odf><office:body><office:presentation>'
      '<draw:page draw:name="p1"><draw:frame presentation:class="title"><draw:text-box><text:p>Benvenuti</text:p></draw:text-box></draw:frame>'
      '<draw:frame presentation:class="outline"><draw:text-box><text:list><text:list-item><text:p>agenda</text:p></text:list-item></text:list></draw:text-box></draw:frame>'
      '<presentation:notes><draw:frame><draw:text-box><text:p>nota segreta</text:p></draw:text-box></draw:frame></presentation:notes></draw:page>'
      '<draw:page draw:name="p2"><draw:frame presentation:class="title"><draw:text-box><text:p>Fine</text:p></draw:text-box></draw:frame></draw:page>'
      '</office:presentation></office:body></office:document-content>',
});

Uint8List buildOds() => zipOf({
  'content.xml':
      '<office:document-content $_odf><office:body><office:spreadsheet>'
      '<table:table table:name="Foglio1">'
      '<table:table-row><table:table-cell><text:p>a</text:p></table:table-cell><table:table-cell table:number-columns-repeated="2"><text:p>b</text:p></table:table-cell></table:table-row>'
      '<table:table-row table:number-rows-repeated="1048570"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>'
      '</table:table></office:spreadsheet></office:body></office:document-content>',
});

Uint8List buildEpub() => zipOf({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
  'OEBPS/content.opf':
      '<package xmlns="http://www.idpf.org/2007/opf"><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Libro</dc:title></metadata>'
      '<manifest><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>'
      '<item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="img" href="img/a.png" media-type="image/png"/></manifest>'
      '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
  'OEBPS/nav.xhtml':
      '<html><body><nav epub:type="toc"><ol><li><a href="text/c1.xhtml">Uno</a></li>'
      '<li><a href="text/c2.xhtml">Due</a><ol><li><a href="text/c2.xhtml#sec">Sezione</a></li></ol></li></ol></nav></body></html>',
  'OEBPS/text/c1.xhtml': '<html><head><title>c1</title></head><body><h1>Capitolo 1</h1><p>Primo <em>capitolo</em>.</p><img src="../img/a.png" alt="figura"/></body></html>',
  'OEBPS/text/c2.xhtml': '<html><body><h1>Capitolo 2</h1><p>testo</p><h2 id="sec">Sezione</h2><p>fine</p></body></html>',
  'OEBPS/img/a.png': tinyPng,
});

Uint8List buildXopp() {
  final xml =
      '<?xml version="1.0" standalone="no"?><xournal creator="Xournal++" fileversion="4">'
      '<page width="595" height="842"><background type="solid" color="#ffffffff" style="lined"/>'
      '<layer><stroke tool="pen" color="#ff0000ff" width="1.4 1.2 1.6">10 10 50 50 90 20</stroke>'
      '<text font="Sans" size="12" x="100" y="200" color="#000000ff">Derivata parziale</text>'
      '<image left="0" top="0" right="10" bottom="10">${base64Encode(tinyPng)}</image></layer></page>'
      '<page width="595" height="842"><background type="pdf" domain="absolute" filename="x.pdf" pageno="1"/><layer/></page>'
      '</xournal>';
  return GZipEncoder().encodeBytes(utf8.encode(xml));
}

Uint8List buildEnex() => Uint8List.fromList(
  utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?><en-export>'
    '<note><title>Lezione 1</title><content><![CDATA[<?xml version="1.0"?><!DOCTYPE en-note SYSTEM "x"><en-note><div>Integrali <b>impropri</b></div><en-todo checked="true"/>fatto<en-media type="image/png" hash="${md5.convert(tinyPng)}"/></en-note>]]></content>'
    '<created>20261005T083000Z</created><tag>analisi</tag>'
    '<resource><data encoding="base64">${base64Encode(tinyPng)}</data><mime>image/png</mime></resource></note>'
    '<note><title>Lezione 2</title><content><![CDATA[<en-note><ul><li>serie</li></ul></en-note>]]></content></note>'
    '</en-export>',
  ),
);

// ------------------------------------------------------------------ OLE2

Uint8List _u16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// Word 97: FIB minima, testo a 8 bit in un unico pezzo della CLX.
Uint8List buildDoc(String text) {
  final latin = latin1.encode(text);
  final word = Uint8List(0x800 + latin.length + 16);
  final d = ByteData.sublistView(word);
  d.setUint16(0, 0xA5EC, Endian.little);
  d.setUint16(2, 0x00C1, Endian.little);
  d.setUint16(0x0A, 0x0200, Endian.little); // testo delle tabelle in 1Table
  d.setUint16(32, 14, Endian.little); // csw
  d.setUint16(62, 22, Endian.little); // cslw
  d.setUint32(64 + 12, latin.length, Endian.little); // ccpText
  d.setUint16(152, 93, Endian.little); // cbRgFcLcb
  final table = Uint8List.fromList([
    0x02,
    ..._u32(4 + 4 + 8),
    ..._u32(0),
    ..._u32(latin.length),
    ..._u16(0),
    ..._u32(0x40000000 | (0x800 * 2)),
    ..._u16(0),
  ]);
  d.setUint32(418, 0, Endian.little); // fcClx
  d.setUint32(422, table.length, Endian.little); // lcbClx
  word.setAll(0x800, latin);
  return buildCfb({'WordDocument': word, '1Table': table});
}

List<int> _rec(int type, List<int> data) => [
  ..._u16(type),
  ..._u16(data.length),
  ...data,
];

List<int> _xlStr(String s, {bool short = false}) => [
  if (short) s.length else ..._u16(s.length),
  0,
  ...latin1.encode(s),
];

/// Excel 97 (BIFF8): un foglio con testi condivisi, un numero e un RK.
Uint8List buildXls() {
  final bof = _rec(0x0809, [
    ..._u16(0x0600),
    ..._u16(0x0005),
    ...List.filled(12, 0),
  ]);
  final sst = _rec(0x00FC, [
    ..._u32(2),
    ..._u32(2),
    ..._xlStr('Materia'),
    ..._xlStr('Analisi'),
  ]);
  final eof = _rec(0x000A, []);
  List<int> bound(int pos) =>
      _rec(0x0085, [..._u32(pos), 0, 0, ..._xlStr('Esami', short: true)]);
  final globalsLen = bof.length + bound(0).length + sst.length + eof.length;
  final globals = [...bof, ...bound(globalsLen), ...sst, ...eof];
  final sheetBof = _rec(0x0809, [
    ..._u16(0x0600),
    ..._u16(0x0010),
    ...List.filled(12, 0),
  ]);
  final number = Uint8List(8)
    ..buffer.asByteData().setFloat64(0, 27.5, Endian.little);
  final sheet = [
    ...sheetBof,
    ..._rec(0x00FD, [..._u16(0), ..._u16(0), ..._u16(0), ..._u32(0)]),
    ..._rec(0x00FD, [..._u16(1), ..._u16(0), ..._u16(0), ..._u32(1)]),
    ..._rec(0x0203, [..._u16(1), ..._u16(1), ..._u16(0), ...number]),
    ..._rec(0x027E, [
      ..._u16(1),
      ..._u16(2),
      ..._u16(0),
      ..._u32((30 << 2) | 2),
    ]),
    ...eof,
  ];
  return buildCfb({
    'Workbook': Uint8List.fromList([...globals, ...sheet]),
  });
}

/// PowerPoint 97: elenco delle diapositive con titoli e testo.
Uint8List buildPpt() {
  List<int> atom(int type, List<int> data) => [
    ..._u16(0),
    ..._u16(type),
    ..._u32(data.length),
    ...data,
  ];
  List<int> container(int type, List<int> data) => [
    ..._u16(0xF),
    ..._u16(type),
    ..._u32(data.length),
    ...data,
  ];
  List<int> utf16(String s) => [
    for (final c in s.codeUnits) ...[c & 0xFF, c >> 8],
  ];
  final slides = container(0x0FF0, [
    ...atom(0x03F3, List.filled(20, 0)),
    ...atom(0x0F9F, _u32(0)),
    ...atom(0x0FA0, utf16('Termodinamica')),
    ...atom(0x0F9F, _u32(1)),
    ...atom(0x0FA8, latin1.encode('Primo principio\rSecondo principio')),
    ...atom(0x03F3, List.filled(20, 0)),
    ...atom(0x0F9F, _u32(0)),
    ...atom(0x0FA0, utf16('Entropia')),
  ]);
  final doc = container(0x03E8, [
    ...atom(0x03E9, List.filled(40, 0)),
    ...slides,
  ]);
  return buildCfb({'PowerPoint Document': Uint8List.fromList(doc)});
}

Uint8List _be16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.big);
Uint8List _be32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

/// MOBI senza compressione, testo HTML in UTF-8.
Uint8List buildMobi(String html, {int encryption = 0}) {
  final text = utf8.encode(html);
  final title = utf8.encode('Romanzo');
  final mobi = Uint8List(0xE8);
  final md = ByteData.sublistView(mobi);
  mobi.setAll(0, 'MOBI'.codeUnits);
  md.setUint32(4, 0xE8, Endian.big);
  md.setUint32(12, 65001, Endian.big);
  md.setUint32(0x54 - 16, 16 + 0xE8, Endian.big);
  md.setUint32(0x58 - 16, title.length, Endian.big);
  md.setUint32(0x6C - 16, 0xFFFFFFFF, Endian.big);
  final rec0 = Uint8List.fromList([
    ..._be16(1),
    ..._be16(0),
    ..._be32(text.length),
    ..._be16(1),
    ..._be16(4096),
    ..._be16(encryption),
    ..._be16(0),
    ...mobi,
    ...title,
  ]);
  const n = 2;
  const headerLen = 78 + n * 8 + 2;
  final out = BytesBuilder()
    ..add(Uint8List(60))
    ..add('BOOKMOBI'.codeUnits)
    ..add(Uint8List(8))
    ..add(_be16(n));
  var off = headerLen;
  for (final r in [rec0, text]) {
    out
      ..add(_be32(off))
      ..add(Uint8List(4));
    off += r.length;
  }
  out
    ..add(Uint8List(2))
    ..add(rec0)
    ..add(text);
  return out.toBytes();
}

/// Scrittore minimo di CFB (versione 3, settori da 512 byte) per costruire
/// file .doc/.xls/.ppt finti. Senza mini-stream: cutoff a 0, tutti i flussi
/// nella FAT normale.
Uint8List buildCfb(Map<String, Uint8List> streams) {
  const ss = 512;
  final names = streams.keys.toList();
  final dataSectors = <List<int>>[];
  final starts = <int>[];
  final dirSectors = ((1 + names.length) * 128 + ss - 1) ~/ ss;
  var streamSectors = 0;
  for (final n in names) {
    streamSectors += (streams[n]!.length + ss - 1) ~/ ss;
  }
  var fatSectors = 1;
  while (fatSectors * (ss ~/ 4) < fatSectors + dirSectors + streamSectors) {
    fatSectors++;
  }
  final total = fatSectors + dirSectors + streamSectors;
  final fat = List<int>.filled(fatSectors * (ss ~/ 4), 0xFFFFFFFF);
  for (var i = 0; i < fatSectors; i++) {
    fat[i] = 0xFFFFFFFD;
  }
  final dirStart = fatSectors;
  for (var i = 0; i < dirSectors; i++) {
    fat[dirStart + i] = i == dirSectors - 1 ? 0xFFFFFFFE : dirStart + i + 1;
  }
  var next = dirStart + dirSectors;
  for (final n in names) {
    final data = streams[n]!;
    final count = (data.length + ss - 1) ~/ ss;
    starts.add(count == 0 ? 0xFFFFFFFE : next);
    for (var i = 0; i < count; i++) {
      fat[next + i] = i == count - 1 ? 0xFFFFFFFE : next + i + 1;
      final chunk = List<int>.filled(ss, 0);
      final end = (i + 1) * ss > data.length ? data.length : (i + 1) * ss;
      chunk.setRange(0, end - i * ss, data, i * ss);
      dataSectors.add(chunk);
    }
    next += count;
  }
  final out = Uint8List((1 + total) * ss);
  final d = ByteData.sublistView(out);
  out.setAll(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
  d.setUint16(0x18, 0x003E, Endian.little);
  d.setUint16(0x1A, 0x0003, Endian.little);
  d.setUint16(0x1C, 0xFFFE, Endian.little);
  d.setUint16(0x1E, 9, Endian.little);
  d.setUint16(0x20, 6, Endian.little);
  d.setUint32(0x2C, fatSectors, Endian.little);
  d.setUint32(0x30, dirStart, Endian.little);
  d.setUint32(0x38, 0, Endian.little);
  d.setUint32(0x3C, 0xFFFFFFFE, Endian.little);
  d.setUint32(0x44, 0xFFFFFFFE, Endian.little);
  for (var i = 0; i < 109; i++) {
    d.setUint32(0x4C + i * 4, i < fatSectors ? i : 0xFFFFFFFF, Endian.little);
  }
  for (var i = 0; i < fat.length; i++) {
    d.setUint32(ss + i * 4, fat[i], Endian.little);
  }
  void entry(
    int idx,
    String name,
    int type,
    int start,
    int size,
    int child,
    int right,
  ) {
    final o = ss * (1 + dirStart) + idx * 128;
    final units = name.codeUnits;
    for (var k = 0; k < units.length; k++) {
      d.setUint16(o + k * 2, units[k], Endian.little);
    }
    d.setUint16(o + 0x40, (units.length + 1) * 2, Endian.little);
    out[o + 0x42] = type;
    d.setUint32(o + 0x44, 0xFFFFFFFF, Endian.little);
    d.setUint32(o + 0x48, right, Endian.little);
    d.setUint32(o + 0x4C, child, Endian.little);
    d.setUint32(o + 0x74, start, Endian.little);
    d.setUint32(o + 0x78, size, Endian.little);
  }

  entry(
    0,
    'Root Entry',
    5,
    0xFFFFFFFE,
    0,
    names.isEmpty ? 0xFFFFFFFF : 1,
    0xFFFFFFFF,
  );
  for (var i = 0; i < names.length; i++) {
    entry(
      1 + i,
      names[i],
      2,
      starts[i],
      streams[names[i]]!.length,
      0xFFFFFFFF,
      i + 2 <= names.length ? i + 2 : 0xFFFFFFFF,
    );
  }
  for (var i = 0; i < dataSectors.length; i++) {
    out.setAll(ss * (1 + dirStart + dirSectors + i), dataSectors[i]);
  }
  return out;
}

// ------------------------------------------------------------------- RAR

/// RAR 4 "memorizzato" (senza compressione), costruito secondo la nota
/// tecnica di RAR 4: marcatore, intestazione dell'archivio, una
/// intestazione per file (metodo 0x30) seguita dai dati, fine archivio.
Uint8List buildRar4(Map<String, List<int>> files) {
  final out = BytesBuilder()..add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);
  void block(List<int> body) {
    final crc = getCrc32(body) & 0xFFFF;
    out
      ..add(_u16(crc))
      ..add(body);
  }

  // Intestazione dell'archivio: tipo 0x73, 13 byte.
  block([0x73, ..._u16(0), ..._u16(13), ..._u16(0), ..._u32(0)]);
  files.forEach((name, data) {
    final n = utf8.encode(name);
    block([
      0x74,
      ..._u16(0x8000),
      ..._u16(32 + n.length),
      ..._u32(data.length), // dimensione compressa
      ..._u32(data.length), // dimensione originale
      2, // sistema: Win32
      ..._u32(getCrc32(data)),
      ..._u32(0x5A210000), // data e ora DOS
      29, // versione per estrarre
      0x30, // metodo: memorizzato
      ..._u16(n.length),
      ..._u32(0x20),
      ...n,
    ]);
    out.add(data);
  });
  block([0x7B, ..._u16(0x4000), ..._u16(7)]);
  return out.toBytes();
}

List<int> _vint(int v) {
  final out = <int>[];
  do {
    var b = v & 0x7F;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

/// RAR 5 "memorizzato", secondo il formato RAR 5.0: firma, intestazione
/// principale (tipo 1), file (tipo 2, area dati), fine archivio (tipo 5).
Uint8List buildRar5(Map<String, List<int>> files) {
  final out = BytesBuilder()
    ..add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);
  void header(List<int> fields) {
    final h = [..._vint(fields.length), ...fields];
    out
      ..add(_u32(getCrc32(h)))
      ..add(h);
  }

  header([1, 0, 0]); // principale: tipo, flag, flag dell'archivio
  files.forEach((name, data) {
    final n = utf8.encode(name);
    header([
      2, // file
      0x02, // flag: c'è l'area dati
      ..._vint(data.length),
      0x04, // flag del file: CRC32 presente
      ..._vint(data.length),
      ..._vint(0x20), // attributi
      ..._u32(getCrc32(data)),
      0, // compressione: versione 0, metodo 0 (memorizzato)
      0, // sistema: Windows
      ..._vint(n.length),
      ...n,
    ]);
    out.add(data);
  });
  header([5, 0, 0]);
  return out.toBytes();
}

// ------------------------------------------------------------------- CAB

/// Microsoft Cabinet con una cartella "memorizzata" (MS-CAB: CFHEADER,
/// CFFOLDER, CFFILE, CFDATA).
Uint8List buildCab(Map<String, List<int>> files) {
  final names = files.keys.toList();
  final data = <int>[for (final n in names) ...files[n]!];
  final fileRecs = <int>[];
  var off = 0;
  for (final n in names) {
    fileRecs
      ..addAll(_u32(files[n]!.length))
      ..addAll(_u32(off))
      ..addAll(_u16(0)) // cartella 0
      ..addAll(_u16(0x5A21))
      ..addAll(_u16(0))
      ..addAll(_u16(0x20))
      ..addAll(latin1.encode(n))
      ..add(0);
    off += files[n]!.length;
  }
  const header = 36, folder = 8;
  final coffFiles = header + folder;
  final dataStart = coffFiles + fileRecs.length;
  final blocks = <int>[];
  var nBlocks = 0;
  for (var i = 0; i < data.length || nBlocks == 0; i += 32768) {
    final end = i + 32768 > data.length ? data.length : i + 32768;
    final chunk = data.sublist(i, end);
    blocks
      ..addAll(_u32(0)) // somma di controllo non calcolata
      ..addAll(_u16(chunk.length))
      ..addAll(_u16(chunk.length))
      ..addAll(chunk);
    nBlocks++;
    if (end >= data.length) break;
  }
  final total = dataStart + blocks.length;
  return Uint8List.fromList([
    ...ascii.encode('MSCF'),
    ..._u32(0),
    ..._u32(total),
    ..._u32(0),
    ..._u32(coffFiles),
    ..._u32(0),
    3, 1, // versione 1.3
    ..._u16(1), // cartelle
    ..._u16(names.length),
    ..._u16(0), // flag
    ..._u16(0),
    ..._u16(0),
    // CFFOLDER
    ..._u32(dataStart),
    ..._u16(nBlocks),
    ..._u16(0), // nessuna compressione
    ...fileRecs,
    ...blocks,
  ]);
}

// --------------------------------------------------------------- OneNote

/// Sezione OneNote sintetica: GUID del tipo di file, poi proprietà di
/// testo "lunghezza + UTF-16LE" (come RichEditTextUnicode), un nome di
/// carattere (da scartare), un testo ASCII esteso e un'immagine in un
/// FileDataStoreObject.
Uint8List buildOneNote() {
  List<int> utf16(String s) => [
    for (final c in s.codeUnits) ...[c & 0xFF, c >> 8],
  ];
  List<int> prop(List<int> data) => [..._u32(data.length), ...data];
  final guid = [
    0xE4, 0x52, 0x5C, 0x7B, 0x8C, 0xD8, 0xA7, 0x4D, //
    0xAE, 0xB1, 0x53, 0x78, 0xD0, 0x29, 0x96, 0xD3,
  ];
  final fileData = [
    0xE7, 0x16, 0xE3, 0xBD, 0x65, 0x26, 0x11, 0x45, //
    0xA4, 0xC4, 0x8D, 0x4D, 0x0B, 0x7A, 0x9E, 0xAC,
  ];
  final footer = [
    0x22, 0xA7, 0xFB, 0x71, 0x79, 0x0F, 0x0B, 0x4A, //
    0xBB, 0x13, 0x89, 0x92, 0x56, 0x42, 0x6B, 0x24,
  ];
  return Uint8List.fromList([
    ...guid,
    ...List.filled(1008, 0),
    ...prop(utf16('Lezione 3: serie numeriche')),
    ..._u32(7), 1, 2, 3, // dati qualsiasi
    ...prop(utf16('Calibri')),
    ...prop(
      utf16(
        'Una serie converge se la successione delle somme parziali '
        'converge.\rCriterio del rapporto.',
      ),
    ),
    ...prop(latin1.encode('Esempio: la serie geometrica di ragione 1/2')),
    ...List.filled(13, 0xAB),
    ...fileData,
    ..._u32(tinyPng.length), ..._u32(0), // lunghezza (8 byte)
    ..._u32(0), ..._u32(0), ..._u32(0), // non usati, riservati
    ...tinyPng,
    ...footer,
    ...prop(
      utf16(
        'Una serie converge se la successione delle somme parziali '
        'converge.\rCriterio del rapporto.',
      ),
    ), // revisione ripetuta
  ]);
}

// ------------------------------------------------------------------- ISF

List<int> _mbuint(int v) {
  final out = <int>[];
  do {
    var b = v & 0x7F;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

/// Valori di un canale ISF con la compressione "Gorilla" (larghezza fissa
/// in bit) e la trasformazione delta-delta, come nella specifica ISF.
List<int> isfGorilla(List<int> values, {int width = 12}) {
  final deltas = <int>[];
  var p1 = 0, p2 = 0;
  for (final v in values) {
    deltas.add(v - 2 * p1 + p2);
    p2 = p1;
    p1 = v;
  }
  final bits = <int>[];
  for (final d in deltas) {
    final u = d & ((1 << width) - 1);
    for (var b = width - 1; b >= 0; b--) {
      bits.add((u >> b) & 1);
    }
  }
  final out = <int>[0x20 | width];
  for (var i = 0; i < bits.length; i += 8) {
    var byte = 0;
    for (var k = 0; k < 8; k++) {
      byte = (byte << 1) | (i + k < bits.length ? bits[i + k] : 0);
    }
    out.add(byte);
  }
  return out;
}

/// File ISF: attributi di disegno (colore, spessore) e due tratti.
Uint8List buildIsf() {
  final attrs = [68, ..._mbuint(0x0000FF), 69, ..._mbuint(100)]; // rosso
  List<int> stroke(List<int> xs, List<int> ys) {
    final body = [..._mbuint(xs.length), ...isfGorilla(xs), ...isfGorilla(ys)];
    return [10, ..._mbuint(body.length), ...body];
  }

  final tags = [
    3, ..._mbuint(attrs.length), ...attrs, // DRAW_ATTRS_BLOCK
    ...stroke([100, 600, 1100, 1600], [100, 400, 100, 400]),
    ...stroke([200, 220, 240], [900, 950, 1000]),
  ];
  return Uint8List.fromList([0, ..._mbuint(tags.length), ...tags]);
}

// ------------------------------------------------------------------- KFX

/// Contenitore KFX senza DRM ("CONT" con entità "ENTY") con valori Ion
/// binari: una tabella dei simboli (da ignorare) e un frammento di
/// contenuto $145 con la lista di testi $146.
Uint8List buildKfx() {
  List<int> str(String s) {
    final b = utf8.encode(s);
    return b.length < 14
        ? [0x80 | b.length, ...b]
        : [0x8E, 0x80 | b.length, ...b];
  }

  List<int> list(List<List<int>> items) {
    final body = [for (final i in items) ...i];
    return body.length < 14
        ? [0xB0 | body.length, ...body]
        : [0xBE, ..._ionLen(body.length), ...body];
  }

  List<int> struct(Map<int, List<int>> fields) {
    final body = [
      for (final e in fields.entries) ...[..._ionLen(e.key), ...e.value],
    ];
    return body.length < 14
        ? [0xD0 | body.length, ...body]
        : [0xDE, ..._ionLen(body.length), ...body];
  }

  const bvm = [0xE0, 0x01, 0x00, 0xEA];
  final symbols = struct({
    7: list([str('kfx_simbolo_lungo_uno'), str('kfx_simbolo_lungo_due')]),
  });
  final wrapped = [0x81, 0x83, ...symbols]; // annotazione $3
  final annotated = wrapped.length < 14
      ? [0xE0 | wrapped.length, ...wrapped]
      : [0xEE, ..._ionLen(wrapped.length), ...wrapped];
  final content = struct({
    4: [0x71, 10],
    146: list([
      str('Capitolo primo: il teorema di Lagrange.'),
      str('Ogni funzione derivabile ha un punto medio.'),
    ]),
  });
  List<int> entity(List<int> ion) => [
    ...ascii.encode('ENTY'),
    ..._u16(1),
    ..._u32(10),
    ...bvm,
    ...ion,
  ];
  return Uint8List.fromList([
    ...ascii.encode('CONT'),
    ..._u16(2),
    ..._u32(18),
    ..._u32(0),
    ..._u32(0),
    ...entity(annotated),
    ...entity(content),
  ]);
}

/// Lunghezza Ion (VarUInt: 7 bit per byte, l'ultimo con il bit alto).
List<int> _ionLen(int n) {
  final out = <int>[n & 0x7F | 0x80];
  n >>= 7;
  while (n > 0) {
    out.insert(0, n & 0x7F);
    n >>= 7;
  }
  return out;
}
