// Formati per appunti ed e-book aggiunti al lettore: RAR/CBR, OneNote e
// pacchetti .onepkg (CAB), Windows Ink (InkML, ISF), Kindle KFX,
// PostScript/EPS, token ACSM, note Obsidian e Notion, EPUB 3 e DRM.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:university_notes/features/reader/parsers/archives.dart';
import 'package:university_notes/features/reader/parsers/ebooks.dart';
import 'package:university_notes/features/reader/parsers/kfx.dart';
import 'package:university_notes/features/reader/parsers/onenote.dart';
import 'package:university_notes/features/reader/parsers/postscript.dart';
import 'package:university_notes/features/reader/parsers/text_formats.dart';
import 'package:university_notes/features/reader/parsers/windows_ink.dart';
import 'package:university_notes/features/reader/parsers/zip_util.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/features/reader/reader_formats.dart';
import 'package:university_notes/features/reader/reader_loader.dart';

import 'reader_fixtures.dart';

/// Archivio finto per provare i fumetti senza un vero RAR.
class _FakeArchive implements ReaderArchive {
  _FakeArchive(this.files);
  final Map<String, Uint8List> files;
  final reads = <String>[];

  @override
  List<ArchiveItem> get items => [
    for (final e in files.entries) ArchiveItem(e.key, e.value.length),
  ];

  @override
  Future<Uint8List?> read(String name) async {
    reads.add(name);
    return files[name];
  }
}

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('um_formats_');
    readerTempDir = () async => Directory(p.join(tmp.path, 'tmp'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f.path;
  }

  group('RAR e fumetti CBR', () {
    final files = {
      'pagine/p10.png': tinyPng,
      'pagine/p2.png': tinyPng,
      'note.txt': utf8.encode('Ciao dal RAR'),
    };

    test('RAR4 e RAR5 memorizzati: elenco e lettura delle voci', () async {
      for (final rar in [buildRar4(files), buildRar5(files)]) {
        expect(isRar(rar), isTrue);
        final a = await ReaderArchive.open(rar);
        expect(a, isA<RarArchive>());
        expect(a.items.map((i) => (i.name, i.size)), [
          ('pagine/p10.png', 70),
          ('pagine/p2.png', 70),
          ('note.txt', 12),
        ]);
        expect(utf8.decode((await a.read('note.txt'))!), 'Ciao dal RAR');
        expect(await a.read('manca.txt'), isNull);
      }
    });

    test('fumetto: immagini in ordine naturale (archivio finto)', () async {
      final fake = _FakeArchive({
        'Fumetto/10.jpg': tinyPng,
        'Fumetto/2.png': tinyPng,
        'Fumetto/info.txt': _bytes(utf8.encode('x')),
        '__MACOSX/._2.png': tinyPng,
      });
      final doc = await comicDoc(fake);
      expect(doc.sections.length, 2);
      expect(doc.sections.map((s) => (s.blocks.single as RImage).caption), [
        '2.png',
        '10.jpg',
      ]);
      expect(fake.reads, isNot(contains('Fumetto/info.txt')));
    });

    test('.cbr (anche un .cbz che è un RAR) e .rar nel lettore', () async {
      final (f, cbr) = await loadReaderContent(
        await write('Topolino.cbr', buildRar5(files)),
      );
      expect(f.viewer, ReaderViewer.document);
      final pages = (cbr as DocContent).doc.sections;
      expect(pages.length, 2);
      expect((pages.first.blocks.single as RImage).caption, 'p2.png');
      final (_, cbz) = await loadReaderContent(
        await write('finto.cbz', buildRar4(files)),
      );
      expect((cbz as DocContent).doc.sections.length, 2);
      // Un .cbr che in realtà è uno ZIP.
      final (_, zipCbr) = await loadReaderContent(
        await write('zip.cbr', zipOf({'a.png': tinyPng})),
      );
      expect((zipCbr as DocContent).doc.sections.length, 1);
      // Archivio .rar: elenco, ogni voce si apre nel lettore.
      final rar = await write('materiale.rar', buildRar4(files));
      final (af, archive) = await loadReaderContent(rar);
      expect(af.viewer, ReaderViewer.archive);
      expect((archive as ArchiveContent).entries.length, 3);
      final out = await extractArchiveEntry(rar, 'note.txt');
      expect(File(out).readAsStringSync(), 'Ciao dal RAR');
    });
  });

  group('OneNote', () {
    test('sezione .one: testo e immagini, senza nomi di caratteri', () {
      final doc = parseOneNote(buildOneNote(), title: 'Analisi');
      final texts = [
        for (final b in doc.sections.single.blocks)
          if (b is RPara) b.text,
      ];
      expect(texts, [
        'Lezione 3: serie numeriche',
        'Una serie converge se la successione delle somme parziali converge.',
        'Criterio del rapporto.',
        'Esempio: la serie geometrica di ragione 1/2',
      ]);
      expect(doc.sections.single.blocks.whereType<RImage>().length, 1);
      expect(doc.notice, contains('OneNote'));
      expect(isOneNoteSection(buildOneNote()), isTrue);
    });

    test(
      '.one nel lettore: documento con i pulsanti OneNote e Apri con…',
      () async {
        final (f, c) = await loadReaderContent(
          await write('Analisi.one', buildOneNote()),
        );
        expect(f.viewer, ReaderViewer.document);
        final d = c as DocContent;
        expect(d.actions, {ReaderAction.oneNote, ReaderAction.openWith});
        expect(d.doc.plainText, contains('serie geometrica'));
      },
    );

    test('pacchetto .onepkg (CAB): sezioni elencate e aperte', () async {
      // CAB "memorizzato" costruito qui.
      final cab = buildCab({
        'Analisi.one': buildOneNote(),
        'Fisica/Onde.one': buildOneNote(),
      });
      final pkg = await write('Blocco.onepkg', cab);
      final (f, c) = await loadReaderContent(pkg);
      expect(f.viewer, ReaderViewer.archive);
      final a = c as ArchiveContent;
      expect(a.entries.map((e) => e.name), ['Analisi.one', 'Fisica/Onde.one']);
      expect(a.actions, contains(ReaderAction.oneNote));
      final out = await extractArchiveEntry(pkg, 'Fisica/Onde.one');
      final (_, sec) = await loadReaderContent(out);
      expect((sec as DocContent).doc.plainText, contains('serie numeriche'));
    });

    test('CAB MSZIP di gcab: blocchi deflate con la storia di 32 KB', () async {
      final cab = CabArchive(
        File('test/fixtures/onenote/sezioni.onepkg').readAsBytesSync(),
      );
      expect(cab.items.map((i) => (i.name, i.size)), [
        ('Lezioni.one', 190890),
        ('Esercizi.one', 1000),
      ]);
      final expected = [
        for (var i = 0; i < 6000; i++) 'Riga $i della sezione Lezioni\n',
      ].join();
      expect(utf8.decode((await cab.read('Lezioni.one'))!), expected);
      expect(
        utf8.decode((await cab.read('Esercizi.one'))!),
        'Esercizi di analisi\n' * 50,
      );
    });
  });

  group('Windows Ink', () {
    test('InkML: tracce, differenze prime e seconde, pennelli', () {
      const inkml = '''<?xml version="1.0"?>
<ink xmlns="http://www.w3.org/2003/InkML">
  <definitions>
    <brush xml:id="rosso"><brushProperty name="color" value="#FF0000"/><brushProperty name="width" value="4"/></brush>
    <traceFormat><channel name="X" type="decimal"/><channel name="Y" type="decimal"/><channel name="F" type="integer"/></traceFormat>
  </definitions>
  <trace brushRef="#rosso">10 10 100, 20 30 120, 40 70 90</trace>
  <traceGroup brushRef="#rosso"><trace>100 100 0, '10 '0 0, "5"0 0</trace></traceGroup>
</ink>''';
      final doc = parseWindowsInk(_bytes(utf8.encode(inkml)));
      final page = doc.pages.single;
      expect(page.strokes.length, 2);
      final s1 = page.strokes.first;
      expect(s1.color, 0xFFFF0000);
      expect(s1.width, 4);
      // Coordinate spostate nella pagina: differenze relative uguali.
      expect(s1.points[2] - s1.points[0], 10);
      expect(s1.points[3] - s1.points[1], 20);
      // Seconda traccia: 100, 110 (prima differenza), 125 (seconda: +15).
      final s2 = page.strokes[1].points;
      expect(s2[2] - s2[0], 10);
      expect(s2[4] - s2[2], 15);
      expect(page.width, greaterThan(90));
    });

    test('ISF: attributi di disegno e tratti con compressione Gorilla', () {
      final doc = parseWindowsInk(buildIsf());
      final page = doc.pages.single;
      expect(page.strokes.length, 2);
      final s = page.strokes.first;
      expect(s.color, 0xFFFF0000); // COLORREF 0x0000FF = rosso
      expect(s.width, 100);
      expect(s.points.length, 8);
      expect(s.points[2] - s.points[0], 500);
      expect(s.points[3] - s.points[1], 300);
      expect(s.points[7] - s.points[1], 300);
      final t = page.strokes[1].points;
      expect(t[3] - t[1], 50);
    });

    test('ISF con compressione sconosciuta: messaggio chiaro', () async {
      final bad = [0, 6, 10, 4, 1, 0xC0, 0, 0];
      expect(
        () => parseIsf(_bytes(bad)),
        throwsA(isA<UnsupportedInkException>()),
      );
      final (f, c) = await loadReaderContent(await write('firma.isf', bad));
      expect(f.viewer, ReaderViewer.ink);
      expect((c as InfoContent).message, contains('Windows Ink'));
      // Un .ink XML è InkML.
      final (_, ink) = await loadReaderContent(
        await write(
          'schizzo.ink',
          utf8.encode('<ink><trace>0 0, 5 5</trace></ink>'),
        ),
      );
      expect((ink as InkContent).doc.pages.single.strokes.length, 1);
    });
  });

  group('Kindle KFX', () {
    test('KFX con DRM: spiegazione, nessun tentativo di lettura', () async {
      final drm = [0xEA, ...ascii.encode('DRMION'), 0xEE, 1, 2, 3, 4];
      expect(isKfxDrm(_bytes(drm)), isTrue);
      final (f, c) = await loadReaderContent(await write('libro.kfx', drm));
      expect(f.viewer, ReaderViewer.document);
      final m = (c as InfoContent).message;
      expect(m, contains('Kindle'));
      expect(m, contains('DRM'));
      // Anche dentro un .kfx-zip.
      final (_, z) = await loadReaderContent(
        await write('libro.kfx-zip', zipOf({'book.kfx': drm})),
      );
      expect((z as InfoContent).message, contains('Kindle'));
    });

    test('KFX senza DRM: testi dei frammenti Ion, non i simboli', () async {
      final doc = parseKfx(buildKfx());
      expect(doc.plainText.split('\n'), [
        'Capitolo primo: il teorema di Lagrange.',
        'Ogni funzione derivabile ha un punto medio.',
      ]);
      final (_, c) = await loadReaderContent(await write('a.kfx', buildKfx()));
      expect((c as DocContent).actions, contains(ReaderAction.openWith));
    });
  });

  group('PostScript', () {
    const ps = r'''%!PS-Adobe-3.0
%%Title: (Appunti di fisica)
%%Pages: 2
/S { show } bind def
%%Page: 1 1
/Times-Roman findfont 12 scalefont setfont
72 700 moveto (Moto uniformemente) show ( accelerato) show
72 680 moveto 0 0 (perch\351 \(sempre\)) ashow
72 660 moveto <4369616f> S
72 640 moveto (xshow) [6 6 6 6 6] xshow
showpage
%%Page: 2 2
72 700 moveto (Seconda pagina) S
showpage
''';

    test('testo dagli operatori show, una pagina per showpage', () {
      final doc = parsePostScript(_bytes(latin1.encode(ps)));
      expect(doc.sections.length, 2);
      expect(
        [for (final b in doc.sections[0].blocks) (b as RPara).text],
        ['Moto uniformemente accelerato', 'perché (sempre)', 'Ciao', 'xshow'],
      );
      expect((doc.sections[1].blocks.single as RPara).text, 'Seconda pagina');
      expect(doc.notice, contains('testo'));
    });

    test('EPS: anteprima TIFF (intestazione DOS) ed EPSI', () async {
      final psPart = latin1.encode(
        '%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 16 4\n'
        '0 0 moveto (Figura) show\n',
      );
      final tiff = img.encodeTiff(img.Image(width: 4, height: 2));
      final header = ByteData(30)
        ..setUint32(0, 0xC6D3D0C5, Endian.little)
        ..setUint32(4, 30, Endian.little)
        ..setUint32(8, psPart.length, Endian.little)
        ..setUint32(20, 30 + psPart.length, Endian.little)
        ..setUint32(24, tiff.length, Endian.little)
        ..setUint16(28, 0xFFFF, Endian.little);
      final eps = [...header.buffer.asUint8List(), ...psPart, ...tiff];
      final (f, c) = await loadReaderContent(await write('figura.eps', eps));
      expect(f.extension, '.eps');
      final doc = (c as DocContent).doc;
      final image = doc.sections.first.blocks.first as RImage;
      expect(img.decodePng(image.bytes)!.width, 4);
      expect(doc.plainText, contains('Figura'));
      // EPSI: bitmap esadecimale nei commenti (1 = nero).
      final epsi = parsePostScript(
        _bytes(
          latin1.encode(
            '%!PS-Adobe-3.0 EPSF-3.0\n%%BeginPreview: 8 2 1 2\n% F0\n% 0F\n'
            '%%EndPreview\n(Grafico) show\n',
          ),
        ),
      );
      final prev = img.decodePng(
        (epsi.sections.first.blocks.first as RImage).bytes,
      )!;
      expect((prev.width, prev.height), (8, 2));
      expect(prev.getPixel(0, 0).r, 0);
      expect(prev.getPixel(7, 0).r, 255);
      expect(prev.getPixel(7, 1).r, 0);
    });
  });

  group('ACSM', () {
    const acsm = '''<?xml version="1.0"?>
<fulfillmentToken fulfillmentType="buy" xmlns="http://ns.adobe.com/adept">
  <distributor>urn:uuid:0</distributor>
  <operatorURL>https://acs.example.org/fulfillment</operatorURL>
  <transaction>123</transaction>
  <expiration>2026-10-11T12:00:00+00:00</expiration>
  <resourceItemInfo>
    <resource>urn:uuid:1</resource>
    <metadata>
      <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Analisi matematica 1</dc:title>
      <dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Mario Rossi</dc:creator>
      <dc:publisher xmlns:dc="http://purl.org/dc/elements/1.1/">Editore Universitario</dc:publisher>
      <dc:format xmlns:dc="http://purl.org/dc/elements/1.1/">application/epub+zip</dc:format>
    </metadata>
  </resourceItemInfo>
</fulfillmentToken>''';

    test('dati del libro, scadenza e spiegazione', () {
      final doc = parseAcsm(
        _bytes(utf8.encode(acsm)),
        now: DateTime.utc(2026, 10, 20),
      );
      final text = doc.plainText;
      expect(text, contains('Analisi matematica 1'));
      expect(text, contains('Mario Rossi'));
      expect(text, contains('Editore Universitario'));
      expect(text, contains('EPUB'));
      expect(text, contains('Adobe Digital Editions'));
      expect(text, contains('scaduto'));
      expect(
        parseAcsm(
          _bytes(utf8.encode(acsm)),
          now: DateTime.utc(2026, 10, 1),
        ).plainText,
        isNot(contains('scaduto')),
      );
    });

    test('nel lettore: documento con "Apri con…"', () async {
      final (f, c) = await loadReaderContent(
        await write('URLLink.acsm', utf8.encode(acsm)),
      );
      expect(f.label, 'Token Adobe (ACSM)');
      expect((c as DocContent).actions, {ReaderAction.openWith});
    });
  });

  group('Note di Obsidian e Notion', () {
    test('collegamenti, alias, immagini incorporate, etichette, tabelle', () {
      final doc = markdownDoc(
        '# Derivate\n\nVedi [[Limiti]] e [[Integrali|gli integrali]] '
        '#analisi/1 e [sito](https://example.org).\n\n![[grafico.png]]\n\n'
        '| Regola | Formula |\n|---|---|\n| Somma | (f+g)\' |\n\n'
        '`[[non è un link]]`',
        embed: (name) => name == 'grafico.png' ? tinyPng : null,
      );
      final blocks = doc.sections.single.blocks;
      final para = blocks[1] as RPara;
      final links = {
        for (final s in para.spans)
          if (s.link != null) s.text: s.link,
      };
      expect(links, {
        'Limiti': 'note:Limiti',
        'gli integrali': 'note:Integrali',
        '#analisi/1': 'tag:#analisi/1',
        'sito': 'https://example.org',
      });
      expect(blocks.whereType<RImage>().single.caption, 'grafico.png');
      final rows = blocks.whereType<RTableRow>().toList();
      expect(rows.first.header, isTrue);
      expect(rows.last.cells, ['Somma', "(f+g)'"]);
      expect(doc.tables.length, 1);
      expect(doc.plainText, contains('[[non è un link]]'));
    });

    test(
      'immagini accanto alla nota e nelle cartelle degli allegati',
      () async {
        await write('vault/attachments/foto.png', tinyPng);
        final note = await write(
          'vault/Lezione.md',
          utf8.encode('Testo ![[foto.png]] e ![](manca.png)'),
        );
        final (_, c) = await loadReaderContent(note);
        final blocks = (c as DocContent).doc.sections.single.blocks;
        expect(blocks.whereType<RImage>().length, 1);
        expect((blocks.first as RPara).text, contains('[manca.png]'));
      },
    );

    test('esportazione di Notion: pagine annidate e tabelle CSV', () async {
      final zip = await write(
        'Export.zip',
        zipOf({
          'Export/Corso abc123.md':
              '# Corso\n\n[Esami](Corso%20abc123/Esami%20def.md)',
          'Export/Corso abc123/Esami def.md': '# Esami\n\nAppello di giugno',
          'Export/Corso abc123/Voti.csv': 'Esame,Voto\nAnalisi,28\n',
        }),
      );
      final page = await extractArchiveEntry(zip, 'Export/Corso abc123.md');
      // Tutto l'archivio estratto: la pagina collegata esiste accanto.
      final linked = File(
        p.join(p.dirname(page), 'Corso abc123', 'Esami def.md'),
      );
      expect(linked.existsSync(), isTrue);
      final (_, c) = await loadReaderContent(page);
      final span = (c as DocContent).doc.sections.single.blocks
          .whereType<RPara>()
          .expand((b) => b.spans)
          .firstWhere((s) => s.link != null);
      expect(span.link, 'Corso%20abc123/Esami%20def.md');
      final csv = await extractArchiveEntry(
        zip,
        'Export/Corso abc123/Voti.csv',
      );
      final (_, t) = await loadReaderContent(csv);
      final rows = (t as DocContent).doc.sections.single.blocks;
      expect((rows[1] as RTableRow).cells, ['Analisi', '28']);
    });
  });

  group('EPUB 3 e DRM', () {
    test('impaginazione fissa, SVG, MathML e audio/video', () {
      final epub = zipOf({
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/p.opf"/></rootfiles></container>',
        'OPS/p.opf':
            '<package xmlns="http://www.idpf.org/2007/opf"><metadata>'
            '<meta property="rendition:layout">pre-paginated</meta></metadata>'
            '<manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
        'OPS/a.xhtml':
            '<html><body><svg xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="i.png"/>'
            '</svg></body></html>',
        'OPS/b.xhtml':
            '<html><body><p>Area: <math alttext="\\pi r^2"><mi>π</mi></math></p>'
            '<audio src="x.mp3">Il lettore non supporta l\'audio</audio></body></html>',
        'OPS/i.png': tinyPng,
      });
      final doc = parseEpub(epub);
      expect(doc.unitLabel, 'Pagina');
      expect(doc.sections.map((s) => s.title), ['Pagina 1', 'Pagina 2']);
      expect(doc.sections[0].blocks.whereType<RImage>().length, 1);
      final text = doc.sections[1].blocks.map((b) => b.texts.join()).join('|');
      expect(text, contains(r'\pi r^2'));
      expect(text, contains('[Audio'));
      expect(text, isNot(contains('non supporta')));
    });

    test('messaggi precisi per Adobe, LCP, Apple e PDF protetti', () async {
      Uint8List epubWith(Map<String, Object> extra) => zipOf({
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="p.opf"/></rootfiles></container>',
        'p.opf': '<package/>',
        ...extra,
      });
      for (final (name, extra, word) in [
        (
          'adobe.epub',
          {
            'META-INF/rights.xml':
                '<rights xmlns="http://ns.adobe.com/adept"/>',
            'META-INF/encryption.xml': '<encryption><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></encryption>',
          },
          'Adobe Digital Editions',
        ),
        ('lcp.epub', {'META-INF/license.lcpl': '{}'}, 'Thorium'),
        ('apple.epub', {'META-INF/sinf.xml': '<sinf/>'}, 'Apple Libri'),
      ]) {
        final (_, c) = await loadReaderContent(
          await write(name, epubWith(extra)),
        );
        expect((c as InfoContent).message, contains(word), reason: name);
      }
      // Solo caratteri offuscati: si legge.
      expect(
        epubDrm(
          Zip(
            epubWith({
              'META-INF/encryption.xml': '<encryption><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></encryption>',
            }),
          ),
        ),
        isNull,
      );
      final (_, pdf) = await loadReaderContent(
        await write(
          'protetto.pdf',
          latin1.encode('%PDF-1.6\n1 0 obj << /Filter /EBX_HANDLER >> endobj'),
        ),
      );
      expect((pdf as InfoContent).message, contains('Adobe'));
      final (_, ok) = await loadReaderContent(
        await write('normale.pdf', latin1.encode('%PDF-1.4\n')),
      );
      expect(ok, isA<PdfContent>());
    });
  });
}
