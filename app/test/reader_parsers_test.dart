import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/reader/parsers/cfb.dart';
import 'package:university_notes/features/reader/parsers/ebooks.dart';
import 'package:university_notes/features/reader/parsers/ink.dart';
import 'package:university_notes/features/reader/parsers/legacy_office.dart';
import 'package:university_notes/features/reader/parsers/notes_apps.dart';
import 'package:university_notes/features/reader/parsers/odf.dart';
import 'package:university_notes/features/reader/parsers/ooxml.dart';
import 'package:university_notes/features/reader/parsers/rtf.dart';
import 'package:university_notes/features/reader/parsers/text_formats.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/features/reader/reader_text.dart';

import 'reader_fixtures.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

List<RPara> _paras(RDoc d) => [
  for (final s in d.sections) ...s.blocks.whereType<RPara>(),
];

List<RTableRow> _rows(RSection s) => s.blocks.whereType<RTableRow>().toList();

void main() {
  group('ricerca senza accenti', () {
    test('piegatura a lunghezza costante', () {
      expect(foldText('Perché CITTÀ'), 'perche citta');
      expect(foldText('Perché').length, 'Perché'.length);
    });

    test('perche trova perché, anche in maiuscolo', () {
      expect(findFolded('Ma perché? PERCHÉ!', 'perche'), [3, 11]);
      expect(findFolded('nulla', ''), isEmpty);
      expect(findFolded('l’analisi', "l'analisi"), [0]);
    });

    test('espressione per il PDF', () {
      final re = accentInsensitivePattern('perche');
      expect(re.hasMatch('Perché sì'), isTrue);
      expect(re.hasMatch('percha'), isFalse);
      expect(accentInsensitivePattern('a.b').hasMatch('axb'), isFalse);
    });
  });

  group('testo', () {
    test('codifiche: UTF-8 con BOM, UTF-16, Windows-1252', () {
      expect(decodeText([0xEF, 0xBB, 0xBF, ...utf8.encode('città')]), 'città');
      expect(decodeText([0xFF, 0xFE, 0x63, 0, 0xE0, 0]), 'cà');
      expect(decodeText([0x93, 0x63, 0x94, 0xE8]), '“c”è');
    });

    test('txt in paragrafi, codice a spaziatura fissa', () {
      final d = plainTextDoc('uno\ndue\n\ntre');
      expect(_paras(d).map((p) => p.text), ['uno\ndue', 'tre']);
      final c = codeDoc('a\n\nb');
      expect(c.mono, isTrue);
      expect(c.plainText, 'a\n\nb');
    });

    test('Markdown con titoli nell\'indice', () {
      final d = markdownDoc('# Uno\n\ntesto **forte**\n\n## Due\n\n- voce');
      expect(d.outline.map((e) => e.title), ['Uno', 'Due']);
      expect(_paras(d).last.marker, '•');
    });

    test('LaTeX, Org, AsciiDoc, reStructuredText: titoli', () {
      expect(
        markupDoc(
          '\\section{Limiti}\ntesto\n\\subsection*{Destro}',
          '.tex',
        ).outline.map((e) => (e.title, e.level)),
        [('Limiti', 1), ('Destro', 2)],
      );
      expect(markupDoc('* Uno\n** Due\ncorpo', '.org').outline.length, 2);
      expect(
        markupDoc('= Titolo\n== Sezione', '.adoc').outline.first.title,
        'Titolo',
      );
      expect(
        markupDoc(
          'Titolo\n======\n\nSotto\n-----\n',
          '.rst',
        ).outline.map((e) => e.level),
        [0, 1],
      );
    });

    test('HTML: titoli, elenchi, tabelle, link', () {
      final d = htmlDoc(
        '<html><head><title>Pagina</title><style>p{}</style></head><body><h1>Titolo</h1>'
        '<p>Un <a href="https://x.it">link</a> e <b>grassetto</b></p>'
        '<ol><li>uno</li><li>due<ul><li>sotto</li></ul></li></ol>'
        '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>',
      );
      expect(d.sections.first.title, 'Pagina');
      final paras = _paras(d);
      expect(paras.first.isHeading, isTrue);
      expect(paras[1].spans.any((s) => s.link == 'https://x.it'), isTrue);
      expect(paras.map((p) => p.marker).whereType<String>(), ['1.', '2.', '•']);
      final rows = _rows(d.sections.first);
      expect(rows.first.header, isTrue);
      expect(rows.last.cells, ['1', '2']);
      expect(d.plainText, isNot(contains('p{}')));
    });

    test('JSON e XML formattati', () {
      expect(jsonDoc('{"a":[1,2]}').plainText, contains('"a": ['));
      expect(xmlDoc('<a><b>x</b></a>').plainText, contains('\n'));
      expect(jsonDoc('{rotto').plainText, '{rotto');
    });

    test('CSV con virgolette e punto e virgola', () {
      expect(parseCsv('a;b\n"x;y";"di ""lui"""\n'), [
        ['a', 'b'],
        ['x;y', 'di "lui"'],
      ]);
      final d = csvDoc('n,v\n1,2');
      expect(_rows(d.sections.first).map((r) => r.cells), [
        ['n', 'v'],
        ['1', '2'],
      ]);
      expect(csvDoc('a\tb', delimiter: '\t').plainText, 'a\tb');
    });

    test('sottotitoli SRT/VTT con tempi toccabili', () {
      const srt =
          '1\n00:00:01,500 --> 00:00:03,000\nCiao a tutti\n\n2\n00:01:02,000 --> 00:01:05,000\n<i>Oggi</i> derivate\n';
      final cues = parseCues(srt);
      expect(cues.map((c) => c.start), [1.5, 62.0]);
      expect(cues.last.text, 'Oggi derivate');
      expect(
        parseCues('WEBVTT\n\n01:00.000 --> 01:02.000\nx').single.start,
        60,
      );
      final d = subtitlesDoc(srt);
      expect(_paras(d).first.spans.first.seconds, 1.5);
      expect(formatClock(3725), '1:02:05');
      expect(
        parseTimedLines('[00:10] uno\n00:01:00 due\nniente')
            .map((c) => c.start),
        [10, 60],
      );
    });

    test('notebook Jupyter: celle e risultati', () {
      final nb = jsonEncode({
        'cells': [
          {
            'cell_type': 'markdown',
            'source': ['# Esercizio\n', 'testo'],
          },
          {
            'cell_type': 'code',
            'execution_count': 3,
            'source': 'print(1+1)',
            'outputs': [
              {
                'output_type': 'stream',
                'text': ['2\n'],
              },
              {
                'output_type': 'display_data',
                'data': {'image/png': base64Encode(tinyPng)},
              },
            ],
          },
        ],
      });
      final d = ipynbDoc(nb);
      expect(d.outline.first.title, 'Esercizio');
      expect(d.plainText, contains('In [3]:'));
      expect(d.plainText, contains('print(1+1)'));
      expect(d.sections.first.blocks.whereType<RImage>(), hasLength(1));
    });
  });

  group('Office Open XML', () {
    test(
      'docx: titoli, grassetto, elenchi numerati, tabelle, immagini, pagine',
      () {
        final d = parseDocx(buildDocx());
        expect(d.sections, hasLength(2));
        expect(d.sections.first.title, 'Pagina 1');
        final paras = _paras(d);
        expect(paras.first.style, RStyle.h1);
        expect(d.outline.single.title, 'Introduzione');
        expect(
          paras[1].spans.firstWhere((s) => s.text == 'teorema').bold,
          isTrue,
        );
        expect(paras[1].text, 'Il teorema di Rolle, perché sì.');
        expect(
          paras.where((p) => p.style == RStyle.list).map((p) => p.marker),
          ['1.', '2.'],
        );
        expect(_rows(d.sections.first).single.cells, ['A1', 'B1']);
        expect(d.sections[1].blocks.whereType<RImage>(), hasLength(1));
        expect(d.plainText, contains('Seconda pagina'));
      },
    );

    test('pptx: diapositive nell\'ordine della presentazione, note', () {
      final d = parsePptx(buildPptx());
      expect(d.unitLabel, 'Diapositiva');
      expect(d.toc.map((e) => e.title), ['Prima', 'Seconda']);
      expect(d.sections.first.title, 'Diapositiva 1 · Prima');
      expect(
        d.sections.first.blocks.whereType<RPara>().map((p) => p.text),
        contains('città'),
      );
      expect(d.plainText, contains('ricordati la demo'));
    });

    test('xlsx: fogli, testi condivisi, numeri, date, booleani', () {
      final d = parseXlsx(buildXlsx());
      expect(d.tabs, isTrue);
      expect(d.toc.map((e) => e.title), ['Voti', 'Note']);
      final rows = _rows(d.sections.first);
      expect(rows[0].cells, ['Esame', 'Voto', 'Data']);
      expect(rows[1].cells, ['Analisi', '28,5', '01/10/2023']);
      expect(rows[3].cells, ['', '', '', 'VERO']);
      expect(rows[1].label, '2');
      expect(_rows(d.sections[1]).single.cells, ['ok']);
    });

    test('numeri e colonne', () {
      expect(columnIndex('A1'), 0);
      expect(columnIndex('AB3'), 27);
      expect(formatNumber(3), '3');
      expect(formatNumber(0.1 + 0.2), '0,3');
      expect(excelDate(45200), '01/10/2023');
    });
  });

  group('OpenDocument', () {
    test('odt: titolo, stile grassetto, spazi, elenco, tabella, immagine', () {
      final d = parseOdt(buildOdt());
      final paras = _paras(d);
      expect(paras.first.style, RStyle.h1);
      expect(paras[1].text, 'Testo con grassetto e  spazi.');
      expect(
        paras[1].spans.firstWhere((s) => s.text == 'grassetto').bold,
        isTrue,
      );
      expect(paras.firstWhere((p) => p.text == 'voce').marker, '•');
      expect(_rows(d.sections.first).single.cells, ['x', 'y']);
      expect(d.sections.first.blocks.whereType<RImage>(), hasLength(1));
    });

    test('odp: diapositive con titolo e note', () {
      final d = parseOdp(buildOdp());
      expect(d.toc.map((e) => e.title), ['Benvenuti', 'Fine']);
      expect(d.plainText, contains('agenda'));
      expect(d.plainText, contains('nota segreta'));
    });

    test('ods: celle ripetute, righe vuote finali ignorate', () {
      final d = parseOds(buildOds());
      final rows = _rows(d.sections.single);
      expect(rows, hasLength(1));
      expect(rows.single.cells, ['a', 'b', 'b']);
    });
  });

  test('rtf: paragrafi, formattazione, unicode, esadecimale, tabelle', () {
    const rtf =
        r'{\rtf1\ansi\ansicpg1252{\fonttbl{\f0 Arial;}}{\*\generator x;}'
        r'{\outlinelevel0 Titolo\par}'
        r"Testo \b grassetto\b0  e perch\'e8 \u8364? euro.\par"
        r'\trowd\intbl A\cell B\cell\row'
        r'\pard Fine\par}';
    final d = parseRtf(Uint8List.fromList(latin1.encode(rtf)));
    final paras = _paras(d);
    expect(paras.first.style, RStyle.h1);
    expect(paras.first.text, 'Titolo');
    expect(paras[1].text, 'Testo grassetto e perchè € euro.');
    expect(
      paras[1].spans.firstWhere((s) => s.text.contains('grassetto')).bold,
      isTrue,
    );
    expect(_rows(d.sections.first).single.cells, ['A', 'B']);
    expect(paras.last.text, 'Fine');
    expect(d.plainText, isNot(contains('Arial')));
  });

  group('Office 97–2003 (OLE2)', () {
    test('contenitore CFB: flussi', () {
      final cfb = Cfb(buildCfb({'Uno': _utf8('ciao'), 'Due': Uint8List(1500)}));
      expect(cfb.streamNames, ['Uno', 'Due']);
      expect(utf8.decode(cfb.stream('uno')!), 'ciao');
      expect(cfb.stream('Due'), hasLength(1500));
      expect(cfb.stream('Tre'), isNull);
    });

    test('doc: testo dalla tabella dei pezzi, campi e tabelle', () {
      final raw =
          'Primo paragrafo\rSecondo con perché\r'
          '\u0013 HYPERLINK "x" \u0014link\u0015 fine\r'
          'A\u0007B\u0007\u0007Dopo\r';
      final cfb = buildDoc(raw);
      expect(legacyKind(Cfb(cfb)), '.doc');
      final d = parseDoc(cfb);
      expect(d.notice, kLegacyNotice);
      final paras = _paras(d).map((p) => p.text).toList();
      expect(paras, [
        'Primo paragrafo',
        'Secondo con perché',
        'link fine',
        'Dopo',
      ]);
      expect(_rows(d.sections.first).single.cells, ['A', 'B']);
    });

    test('xls: SST, LABELSST, NUMBER, RK', () {
      final d = parseXls(buildXls());
      expect(d.toc.single.title, 'Esami');
      final rows = _rows(d.sections.single);
      expect(rows[0].cells, ['Materia']);
      expect(rows[1].cells, ['Analisi', '27,5', '30']);
    });

    test('ppt: diapositive da SlideListWithText', () {
      final d = parsePpt(buildPpt());
      expect(d.toc.map((e) => e.title), ['Termodinamica', 'Entropia']);
      expect(d.sections.first.blocks.whereType<RPara>().map((p) => p.text), [
        'Termodinamica',
        'Primo principio',
        'Secondo principio',
      ]);
    });
  });

  group('e-book', () {
    test('epub: capitoli dallo spine, immagini, indice dal nav', () {
      final d = parseEpub(buildEpub());
      expect(d.sections.map((s) => s.title), ['Capitolo 1', 'Capitolo 2']);
      expect(d.sections.first.blocks.whereType<RImage>(), hasLength(1));
      expect(d.toc.map((e) => (e.title, e.section, e.level)), [
        ('Uno', 0, 0),
        ('Due', 1, 0),
        ('Sezione', 1, 1),
      ]);
      final sec = d.toc.last;
      expect((d.sections[1].blocks[sec.block] as RPara).text, 'Sezione');
    });

    test('epub con DRM: segnalato', () {
      final bytes = zipOf({
        'META-INF/encryption.xml': '<encryption><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></encryption>',
      });
      expect(() => parseEpub(bytes), throwsA(isA<DrmProtectedException>()));
    });

    test('PalmDOC: letterali, richiami e spazio+carattere', () {
      final out = palmDocDecompress(
        Uint8List.fromList([
          0x61,
          0x62,
          0x63,
          0x80,
          0x1B,
          0xE1,
          0x02,
          0x78,
          0x79,
        ]),
      );
      expect(String.fromCharCodes(out), 'abcabcabc axy');
    });

    test('mobi: testo HTML, titolo, DRM', () {
      final d = parseMobi(
        buildMobi(
          '<html><body><h1>Capitolo</h1><p>Era una notte buia</p><mbp:pagebreak/><p>fine</p></body></html>',
        ),
      );
      expect(d.sections.single.title, 'Romanzo');
      expect(_paras(d).map((p) => p.text), [
        'Capitolo',
        'Era una notte buia',
        'fine',
      ]);
      expect(
        () => parseMobi(buildMobi('x', encryption: 2)),
        throwsA(isA<DrmProtectedException>()),
      );
    });

    test('fb2: sezioni, titoli, enfasi, immagini', () {
      final fb2 =
          '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body>'
          '<section><title><p>Parte prima</p></title><p>Testo <emphasis>corsivo</emphasis></p><image l:href="#i1"/>'
          '<section><title><p>Sotto</p></title><p>dentro</p></section></section></body>'
          '<binary id="i1" content-type="image/png">${base64Encode(tinyPng)}</binary></FictionBook>';
      final d = parseFb2(_utf8(fb2));
      expect(d.sections.single.title, 'Parte prima');
      expect(d.toc.map((e) => e.title), ['Parte prima', 'Sotto']);
      expect(_paras(d)[1].spans.last.italic, isTrue);
      expect(d.sections.single.blocks.whereType<RImage>(), hasLength(1));
    });

    test('xps: glifi in ordine di lettura, pagine', () {
      String page(String a, String b) =>
          '<FixedPage><Glyphs OriginX="200" OriginY="100" UnicodeString="$b"/><Glyphs OriginX="10" OriginY="100" UnicodeString="$a"/>'
          '<Glyphs OriginX="10" OriginY="50" UnicodeString="Titolo"/></FixedPage>';
      final bytes = zipOf({
        'FixedDocSeq.fdseq': '<FixedDocumentSequence><DocumentReference Source="Documents/1/FixedDoc.fdoc"/></FixedDocumentSequence>',
        'Documents/1/FixedDoc.fdoc': '<FixedDocument><PageContent Source="Pages/1.fpage"/><PageContent Source="Pages/2.fpage"/></FixedDocument>',
        'Documents/1/Pages/1.fpage': page('Ciao', 'mondo'),
        'Documents/1/Pages/2.fpage': page('Seconda', 'pagina'),
      });
      final d = parseXps(bytes);
      expect(d.sections.map((s) => s.title), ['Pagina 1', 'Pagina 2']);
      expect(_paras(d).take(2).map((p) => p.text), ['Titolo', 'Ciao mondo']);
    });

    test('cbz: pagine in ordine naturale', () {
      final d = parseCbz(
        zipOf({'p10.png': tinyPng, 'p2.png': tinyPng, 'leggimi.txt': 'x'}),
      );
      expect(d.sections.map((s) => (s.blocks.single as RImage).caption), [
        'p2.png',
        'p10.png',
      ]);
    });
  });

  group('appunti a mano', () {
    test('xopp: tratti con pressione, testo, immagini, sfondo PDF', () {
      final d = parseXopp(buildXopp());
      expect(d.pages, hasLength(2));
      final p = d.pages.first;
      expect(p.strokes.single.points, [10, 10, 50, 50, 90, 20]);
      expect(p.strokes.single.color, 0xFFFF0000);
      expect(p.strokes.single.widths, [1.2, 1.6]);
      expect(p.texts.single.text, 'Derivata parziale');
      expect(p.images, hasLength(1));
      expect(p.ruling, 'lined');
      expect(d.notice, isNotNull);
      expect(xoppColor('#3333ccff'), 0xFF3333CC);
      expect(xoppColor('blue'), 0xFF3333CC);
    });

    test('excalidraw: forme, frecce, testi, eliminati esclusi', () {
      final json = jsonEncode({
        'type': 'excalidraw',
        'elements': [
          {
            'type': 'rectangle',
            'x': 100,
            'y': 100,
            'width': 50,
            'height': 40,
            'strokeColor': '#1e1e1e',
            'backgroundColor': 'transparent',
          },
          {
            'type': 'text',
            'x': 110,
            'y': 110,
            'width': 30,
            'height': 20,
            'text': 'Nodo A',
            'fontSize': 16,
            'strokeColor': '#e03131',
          },
          {
            'type': 'arrow',
            'x': 150,
            'y': 120,
            'width': 50,
            'height': 0,
            'points': [
              [0, 0],
              [50, 0],
            ],
          },
          {
            'type': 'ellipse',
            'x': 0,
            'y': 0,
            'width': 10,
            'height': 10,
            'isDeleted': true,
          },
        ],
      });
      final d = parseExcalidraw(_utf8(json));
      final p = d.pages.single;
      expect(p.shapes.single.kind, InkShapeKind.rectangle);
      expect(p.shapes.single.x, 20); // margine di 20 dal bordo
      expect(p.texts.single.text, 'Nodo A');
      expect(p.texts.single.color, 0xFFE03131);
      expect(p.strokes, hasLength(3)); // freccia + due tratti della punta
      expect(p.width, 140);
    });
  });

  group('app di appunti', () {
    test('mappa mentale FreeMind con note e testo ricco', () {
      const mm =
          '<map version="1.0.1"><node TEXT="Fisica"><node TEXT="Meccanica"><node TEXT="Cinematica"/></node>'
          '<node><richcontent TYPE="NODE"><html><body><p>Termo</p></body></html></richcontent>'
          '<richcontent TYPE="NOTE"><html><body><p>leggi</p></body></html></richcontent></node></node></map>';
      final d = parseMindMap(_utf8(mm));
      expect(d.title, 'Fisica');
      expect(d.walk().map((e) => (e.$1.text, e.$2)), [
        ('Fisica', 0),
        ('Meccanica', 1),
        ('Cinematica', 2),
        ('Termo', 1),
      ]);
      expect(d.roots.single.children.last.note, 'leggi');
    });

    test('OPML', () {
      const opml =
          '<opml><head><title>Scaletta</title></head><body><outline text="Uno" _note="n"><outline text="Due"/></outline></body></opml>';
      final d = parseOpml(_utf8(opml));
      expect(d.title, 'Scaletta');
      expect(d.walk().map((e) => e.$1.text), ['Uno', 'Due']);
    });

    test('Evernote: note come sezioni, immagini per hash, caselle', () {
      final d = parseEnex(buildEnex());
      expect(d.toc.map((e) => e.title), ['Lezione 1', 'Lezione 2']);
      expect(d.unitLabel, 'Nota');
      expect(d.plainText, contains('Integrali impropri'));
      expect(d.plainText, contains('☑ fatto'));
      expect(d.plainText, contains('05/10/2026 · #analisi'));
      expect(d.sections.first.blocks.whereType<RImage>(), hasLength(1));
      expect(_paras(d).last.marker, '•');
    });

    test('canvas di Obsidian: schede ordinate e collegamenti', () {
      final json = jsonEncode({
        'nodes': [
          {
            'id': 'b',
            'type': 'text',
            'text': '# Secondo\nsotto',
            'x': 0,
            'y': 200,
          },
          {'id': 'a', 'type': 'text', 'text': 'Primo', 'x': 0, 'y': 0},
          {
            'id': 'f',
            'type': 'file',
            'file': 'cartella/nota.md',
            'x': 300,
            'y': 0,
          },
        ],
        'edges': [
          {'fromNode': 'a', 'toNode': 'b', 'label': 'quindi'},
        ],
      });
      final d = parseCanvas(_utf8(json));
      final text = d.plainText;
      expect(text.indexOf('Primo'), lessThan(text.indexOf('Secondo')));
      expect(text, contains('cartella/nota.md'));
      expect(text, contains('Primo → Secondo (quindi)'));
    });

    test('contenitori: PDF di anteprima, immagini, niente', () {
      final pdf = Uint8List.fromList(latin1.encode('%PDF-1.4 finto'));
      final pages = containerPreview(
        zipOf({'Index/Document.iwa': 'x', 'QuickLook/Preview.pdf': pdf}),
      );
      expect(pages.pdf, pdf);
      final big = Uint8List.fromList([...tinyPng, ...List.filled(4096, 0)]);
      final key = containerPreview(
        zipOf({'preview.jpg': big, 'Data/x.png': big}),
      );
      expect(key.images.single.name, 'preview.jpg');
      final note = containerPreview(
        zipOf({'Nota/Assets/b.png': big, 'Nota/Assets/a.png': big}),
      );
      expect(note.images.map((i) => i.name), [
        'Nota/Assets/a.png',
        'Nota/Assets/b.png',
      ]);
      expect(containerPreview(zipOf({'Session.plist': 'x'})).isEmpty, isTrue);
      expect(containerPreview(Uint8List.fromList([1, 2, 3])).isEmpty, isTrue);
    });
  });
}
