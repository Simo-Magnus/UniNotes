// Resa dei formati nel lettore: diapositive di PowerPoint disegnate come
// nell'originale (file veri salvati da PowerPoint ed Excel in
// test/fixtures/office/), parti non disegnate segnalate (grafici, SmartArt
// senza disegno, immagini EMF, formule), tabella dei formati completa /
// semplificata / non supportata e domanda all'apertura con «Non chiedere
// più».
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/external_launcher.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/reader/parsers/ooxml.dart';
import 'package:university_notes/features/reader/parsers/legacy_office.dart';
import 'package:university_notes/features/reader/parsers/odf.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/features/reader/reader_fidelity.dart';
import 'package:university_notes/features/reader/reader_formats.dart';
import 'package:university_notes/features/reader/reader_loader.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/features/reader/views/document_view.dart';
import 'package:university_notes/features/reader/views/slide_view.dart';
import 'package:university_notes/features/reader/reader_controller.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/features/settings/sections/questions_reset.dart';

import 'reader_fixtures.dart';

Uint8List _office(String name) =>
    File(p.join('test', 'fixtures', 'office', name)).readAsBytesSync();

List<RSlide> _slides(RDoc d) => [
  for (final s in d.sections)
    for (final b in s.blocks)
      if (b is RSlide) b,
];

RShape _withText(RSlide s, String text) =>
    s.shapes.firstWhere((x) => x.paras.any((p) => p.text == text));

const _p =
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
    'xmlns:a14="http://schemas.microsoft.com/office/drawing/2010/main"';
const _rels =
    'xmlns="http://schemas.openxmlformats.org/package/2006/relationships"';
const _rb =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

String _xfrm(int x, int y, int w, int h, {String tag = 'a:xfrm'}) =>
    '<$tag><a:off x="${x * 12700}" y="${y * 12700}"/>'
    '<a:ext cx="${w * 12700}" cy="${h * 12700}"/></$tag>';

/// EMF minimo (intestazione con la firma " EMF").
Uint8List _emf() {
  final b = Uint8List(64);
  b[0] = 1;
  b.setAll(40, ' EMF'.codeUnits);
  return b;
}

/// Una diapositiva con grafico, SmartArt (con il disegno), immagine EMF e
/// formula con l'immagine di ripiego.
Uint8List _pptxWithObjects() => zipOf({
  '_rels/.rels':
      '<Relationships $_rels><Relationship Id="rId1" Type="$_rb/officeDocument" Target="ppt/presentation.xml"/></Relationships>',
  'ppt/presentation.xml':
      '<p:presentation $_p><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>'
      '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
  'ppt/_rels/presentation.xml.rels':
      '<Relationships $_rels><Relationship Id="rId2" Type="$_rb/slide" Target="slides/slide1.xml"/></Relationships>',
  'ppt/slides/_rels/slide1.xml.rels':
      '<Relationships $_rels>'
      '<Relationship Id="rId3" Type="$_rb/chart" Target="../charts/chart1.xml"/>'
      '<Relationship Id="rId4" Type="$_rb/diagramData" Target="../diagrams/data1.xml"/>'
      '<Relationship Id="rId5" Type="http://schemas.microsoft.com/office/2007/relationships/diagramDrawing" Target="../diagrams/drawing1.xml"/>'
      '<Relationship Id="rId6" Type="$_rb/image" Target="../media/image1.emf"/>'
      '<Relationship Id="rId7" Type="$_rb/image" Target="../media/image2.png"/>'
      '</Relationships>',
  'ppt/charts/chart1.xml':
      '<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><c:chart><c:title><c:tx><c:rich><a:p><a:r><a:t>Voti</a:t></a:r></a:p></c:rich></c:tx></c:title></c:chart></c:chartSpace>',
  'ppt/diagrams/data1.xml':
      '<dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" '
      'xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dgm:extLst><a:ext><dsp:dataModelExt relId="rId5"/></a:ext></dgm:extLst></dgm:dataModel>',
  'ppt/diagrams/drawing1.xml':
      '<dsp:drawing xmlns:dsp="http://schemas.microsoft.com/office/drawing/2008/diagram" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dsp:spTree>'
      '<dsp:sp><dsp:spPr>${_xfrm(0, 0, 100, 50)}<a:prstGeom prst="roundRect"/><a:solidFill><a:srgbClr val="4472C4"/></a:solidFill></dsp:spPr>'
      '<dsp:txBody><a:bodyPr anchor="ctr"/><a:p><a:r><a:rPr sz="2000"/><a:t>Fase 1</a:t></a:r></a:p></dsp:txBody></dsp:sp>'
      '</dsp:spTree></dsp:drawing>',
  'ppt/media/image1.emf': _emf(),
  'ppt/media/image2.png': tinyPng,
  'ppt/slides/slide1.xml':
      '<p:sld $_p><p:cSld><p:spTree>'
      // grafico
      '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="2" name="g"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
      '${_xfrm(10, 10, 300, 200, tag: 'p:xfrm')}<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">'
      '<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="rId3"/></a:graphicData></a:graphic></p:graphicFrame>'
      // SmartArt
      '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="d"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
      '${_xfrm(400, 10, 300, 200, tag: 'p:xfrm')}<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/diagram">'
      '<dgm:relIds xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" r:dm="rId4" r:lo="x" r:qs="y" r:cs="z"/></a:graphicData></a:graphic></p:graphicFrame>'
      // immagine EMF
      '<p:pic><p:nvPicPr><p:cNvPr id="4" name="e"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>'
      '<p:blipFill><a:blip r:embed="rId6"/></p:blipFill><p:spPr>${_xfrm(10, 300, 100, 100)}</p:spPr></p:pic>'
      // formula con l'immagine di ripiego
      '<mc:AlternateContent><mc:Choice Requires="a14"><p:sp><p:nvSpPr><p:cNvPr id="5" name="m"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
      '<p:spPr>${_xfrm(400, 300, 200, 50)}</p:spPr><p:txBody><a:bodyPr/><a:p><a14:m><m:oMathPara xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><m:oMath><m:r><m:t>x^2</m:t></m:r></m:oMath></m:oMathPara></a14:m></a:p></p:txBody></p:sp></mc:Choice>'
      '<mc:Fallback><p:sp><p:nvSpPr><p:cNvPr id="5" name="m"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
      '<p:spPr>${_xfrm(400, 300, 200, 50)}<a:blipFill><a:blip r:embed="rId7"/></a:blipFill></p:spPr></p:sp></mc:Fallback></mc:AlternateContent>'
      '</p:spTree></p:cSld></p:sld>',
});

void main() {
  group('PowerPoint disegnato', () {
    test('file vero: titolo, elenco, immagine, forma, sfondo e tabella', () {
      final doc = parsePptx(_office('presentazione.pptx'));
      final slides = _slides(doc);
      expect(slides, hasLength(3));
      expect(doc.limits, isEmpty);
      for (final s in slides) {
        expect(s.width, 960);
        expect(s.height, 540);
      }
      // 1: titolo centrato, grande (dal layout «Diapositiva titolo»)
      final title = _withText(slides[0], 'Analisi Matematica I');
      expect(title.paras.single.align, RAlign.center);
      expect(title.paras.single.runs.single.size, greaterThan(40));
      expect(_withText(slides[0], 'Lezione 3: limiti').y, greaterThan(title.y));

      // 2: sfondo giallo chiaro, elenco puntato, immagine e rettangolo blu
      final s2 = slides[1];
      expect(s2.background, 0xFFFFF7E6);
      final list = s2.shapes.firstWhere(
        (x) => x.paras.any((p) => p.text == 'Dominio'),
      );
      expect(list.paras.map((p) => p.text), [
        'Dominio',
        'Limiti agli estremi',
        'Asintoti',
      ]);
      expect(list.paras.every((p) => p.bullet == '•'), isTrue);
      final pic = s2.shapes.firstWhere((x) => x.image != null);
      expect(pic.x, closeTo(520, 0.5));
      expect(pic.y, closeTo(150, 0.5));
      expect(pic.w, closeTo(320, 0.5));
      expect(pic.image!.sublist(1, 4), 'PNG'.codeUnits);
      final box = _withText(s2, 'Nota importante');
      expect(box.fill, 0xFF1E3A8B);
      expect(box.anchor, RAnchor.middle);
      final run = box.paras.single.runs.single;
      expect(run.size, 20);
      expect(run.color, 0xFFFFFFFF);

      // 3: tabella con la riga d'intestazione dello stile
      final table = slides[2].shapes.firstWhere((x) => x.table != null).table!;
      expect(table.cells, hasLength(3));
      expect(table.cells.first.map((c) => c.text), [
        'Funzione',
        'Dominio',
        'Limite',
      ]);
      expect(table.cells[2][1].text, r'R\{0}');
      final head = table.cells.first.first;
      expect(head.paras.single.runs.single.span.bold, isTrue);
      expect(head.paras.single.runs.single.color, 0xFFFFFFFF);
      expect(head.fill, isNot(table.cells[1].first.fill));

      // la ricerca trova i testi delle diapositive (anche nelle celle)
      expect(doc.plainText, contains('Nota importante'));
      expect(doc.plainText, contains('Limite'));
      expect(doc.outline.map((e) => e.title), contains('Riepilogo'));
    });

    test('tema vero (Facet): forme dello schema e del layout, regolazioni, '
        'gruppi, rotazioni e ritagli', () {
      final slides = _slides(parsePptx(_office('presentazione_tema.pptx')));
      expect(slides, hasLength(3));
      // forme del layout del titolo (lo schema è nascosto): triangoli con
      // la punta regolata e ruotati
      final triangles = slides[0].shapes.where(
        (x) => x.geometry == 'triangle',
      );
      expect(triangles, isNotEmpty);
      expect(triangles.every((x) => x.adjust == 1.0), isTrue);
      expect(triangles.any((x) => x.rotation == 180), isTrue);
      // forme a mano libera dello schema, semitrasparenti
      final custom = slides[1].shapes.where((x) => x.path != null).toList();
      expect(custom, isNotEmpty);
      expect(custom.any((x) => (x.fill! >>> 24) < 0xFF), isTrue);
      // titolo nel colore del tema e casella di testo personalizzata
      final title = _withText(slides[1], 'Moto rettilineo');
      expect(title.paras.single.runs.single.color, isNot(0xFF000000));
      final formula = _withText(slides[1], 'v = dx / dt');
      final r = formula.paras.single.runs.single;
      expect(r.size, 32);
      expect(r.span.bold, isTrue);
      expect(r.color, 0xFFC00000);
      // elenco con il simbolo del tema e il secondo livello rientrato
      final list = slides[1].shapes.firstWhere(
        (x) => x.paras.any((p) => p.text == 'Posizione'),
      );
      expect(list.paras.first.bullet, '▸');
      expect(list.paras.last.indent, greaterThan(list.paras.first.indent));
      // gruppo (ellisse e freccia ruotata) nelle posizioni della pagina
      final ellipse = slides[1].shapes.firstWhere(
        (x) => x.geometry == 'ellipse',
      );
      expect(ellipse.x, closeTo(520, 1));
      expect(ellipse.fill, 0xFFFFA500);
      final arrow = slides[1].shapes.firstWhere(
        (x) => x.geometry == 'rightArrow',
      );
      expect(arrow.rotation, closeTo(20, 0.01));
      // immagine ritagliata a destra
      final pic = slides[2].shapes.firstWhere((x) => x.image != null);
      expect(pic.crop[2], greaterThan(0.1));
      expect(pic.crop[0], 0);
    });

    test('grafici, SmartArt, EMF e formule: riquadri e limiti', () {
      final doc = parsePptx(_pptxWithObjects());
      final s = _slides(doc).single;
      expect(doc.limits, containsAll(['grafici', 'immagini EMF/WMF']));
      expect(doc.limits, isNot(contains('SmartArt')));
      expect(doc.limits, isNot(contains('formule')));
      // grafico: riquadro con il titolo
      expect(s.shapes.map((x) => x.label), contains('Grafico: Voti'));
      // SmartArt dal disegno, spostato nel riquadro dell'oggetto
      final fase = _withText(s, 'Fase 1');
      expect(fase.x, closeTo(400, 0.01));
      expect(fase.geometry, 'roundRect');
      // EMF: riquadro «Immagine»
      expect(s.shapes.map((x) => x.label), contains('Immagine'));
      // formula: l'immagine di ripiego al posto del testo
      final math = s.shapes.firstWhere((x) => x.x == 400 && x.y == 300);
      expect(math.image, isNotNull);
    });

    test('OpenDocument vero (salvato da PowerPoint): pagine disegnate', () {
      final doc = parseOdp(_office('presentazione.odp'));
      final slides = _slides(doc);
      expect(slides, hasLength(3));
      expect(slides.first.width, closeTo(960, 0.5));
      expect(slides.first.height, closeTo(540, 0.5));
      final title = _withText(slides[0], 'Analisi Matematica I');
      expect(title.paras.single.align, RAlign.center);
      expect(title.paras.single.runs.single.size, closeTo(60, 0.5));
      final s2 = slides[1];
      expect(s2.background, 0xFFFFF7E6);
      expect(s2.shapes.where((x) => x.image != null), hasLength(1));
      final box = _withText(s2, 'Nota importante');
      expect(box.fill, 0xFF1E3A8B);
      expect(box.anchor, RAnchor.middle);
      final list = s2.shapes.firstWhere(
        (x) => x.paras.any((p) => p.text == 'Dominio'),
      );
      expect(list.paras.every((p) => p.bullet == '•'), isTrue);
      final table = slides[2].shapes.firstWhere((x) => x.table != null).table!;
      expect(table.cells[1].map((c) => c.text), ['x^2', 'R', '+inf']);
      expect(doc.limits, isEmpty);
      // senza posizioni (file minimi): il testo in sequenza
      expect(_slides(parseOdp(buildOdp())), isEmpty);
    });

    test('OpenDocument come LibreOffice: forme, tracciati, rotazione, '
        'stile predefinito e oggetti', () {
      const ns =
          'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
          'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
          'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
          'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
          'xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" '
          'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
          'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
          'xmlns:xlink="http://www.w3.org/1999/xlink"';
      final odp = zipOf({
        'mimetype': 'application/vnd.oasis.opendocument.presentation',
        'styles.xml':
            '<office:document-styles $ns><office:styles>'
            '<style:default-style style:family="graphic"><style:graphic-properties draw:fill="solid" draw:fill-color="#729fcf" draw:stroke="solid" svg:stroke-color="#3465a4"/></style:default-style>'
            '</office:styles><office:automatic-styles>'
            '<style:page-layout style:name="PM1"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15.75cm"/></style:page-layout>'
            '<style:style style:name="Mdp1" style:family="drawing-page"><style:drawing-page-properties draw:fill="solid" draw:fill-color="#102030"/></style:style>'
            '</office:automatic-styles><office:master-styles>'
            '<style:master-page style:name="Default" style:page-layout-name="PM1" draw:style-name="Mdp1">'
            '<draw:frame presentation:class="title" svg:x="1cm" svg:y="1cm" svg:width="20cm" svg:height="2cm"><draw:text-box><text:p>Modello</text:p></draw:text-box></draw:frame>'
            '<draw:rect svg:x="0cm" svg:y="15cm" svg:width="28cm" svg:height="0.75cm"/>'
            '</style:master-page></office:master-styles></office:document-styles>',
        'content.xml':
            '<office:document-content $ns><office:automatic-styles>'
            '<style:style style:name="T1" style:family="text"><style:text-properties fo:font-size="32pt" fo:color="#ffcc00" fo:font-weight="bold"/></style:style>'
            '<style:style style:name="gr1" style:family="graphic"><style:graphic-properties draw:fill="none" draw:stroke="none"/></style:style>'
            '</office:automatic-styles><office:body><office:presentation>'
            '<draw:page draw:name="p1" draw:master-page-name="Default">'
            '<draw:frame draw:style-name="gr1" svg:x="2cm" svg:y="3cm" svg:width="10cm" svg:height="3cm"><draw:text-box>'
            '<text:p><text:span text:style-name="T1">Onde</text:span></text:p>'
            '<text:list><text:list-item><text:p>ampiezza</text:p></text:list-item></text:list>'
            '</draw:text-box></draw:frame>'
            '<draw:custom-shape svg:x="14cm" svg:y="3cm" svg:width="4cm" svg:height="4cm"><draw:enhanced-geometry svg:viewBox="0 0 21600 21600" draw:type="ellipse"/></draw:custom-shape>'
            '<draw:custom-shape svg:x="19cm" svg:y="3cm" svg:width="4cm" svg:height="4cm"><draw:enhanced-geometry svg:viewBox="0 0 100 100" draw:type="mia" draw:enhanced-path="M 0 0 L 100 0 50 100 Z N"/></draw:custom-shape>'
            '<draw:custom-shape svg:width="4cm" svg:height="2cm" draw:transform="rotate (1.5707963267949) translate (2cm 12cm)"><draw:enhanced-geometry draw:type="rectangle"/></draw:custom-shape>'
            '<draw:frame svg:x="14cm" svg:y="9cm" svg:width="4cm" svg:height="2cm"><draw:object xlink:href="./Object 1"/><draw:image xlink:href="./ObjectReplacements/Object 1"/></draw:frame>'
            '<draw:line svg:x1="1cm" svg:y1="14cm" svg:x2="27cm" svg:y2="13cm"/>'
            '</draw:page></office:presentation></office:body></office:document-content>',
        'ObjectReplacements/Object 1': [0x56, 0x43, 0x4C, 0x4D, 0x54, 0x46, 0, 0],
      });
      final doc = parseOdp(odp);
      final s = _slides(doc).single;
      expect(s.width, closeTo(28 * 72 / 2.54, 0.01));
      expect(s.background, 0xFF102030);
      // forma dello schema (non il segnaposto del titolo)
      expect(
        s.shapes.any((x) => x.paras.any((p) => p.text == 'Modello')),
        isFalse,
      );
      expect(s.shapes.first.y, closeTo(15 * 72 / 2.54, 0.01));
      final text = _withText(s, 'Onde');
      expect(text.fill, isNull);
      final run = text.paras.first.runs.single;
      expect(run.size, 32);
      expect(run.color, 0xFFFFCC00);
      expect(run.span.bold, isTrue);
      expect(text.paras.last.bullet, '•');
      // stile predefinito di LibreOffice per le forme
      final ellipse = s.shapes.firstWhere((x) => x.geometry == 'ellipse');
      expect(ellipse.fill, 0xFF729FCF);
      expect(ellipse.line, 0xFF3465A4);
      final custom = s.shapes.firstWhere((x) => x.geometry == 'custom');
      expect(custom.path!.single.map((c) => c.op), [0, 1, 1, 3]);
      final rotated = s.shapes.firstWhere((x) => x.rotation != 0);
      expect(rotated.rotation, closeTo(-90, 0.01));
      // oggetto (formula o grafico) con l'anteprima vettoriale
      expect(doc.limits, contains('formule o grafici'));
      expect(s.shapes.map((x) => x.label), contains(startsWith('Oggetto')));
      final line = s.shapes.firstWhere((x) => x.geometry == 'line');
      expect(line.flipV, isTrue);
    });

    test('presentazione senza layout: si torna al testo in sequenza', () {
      final doc = parsePptx(buildPptx());
      expect(_slides(doc), isEmpty);
      expect(doc.plainText, contains('dettagli'));
    });

    testWidgets('vista: diapositiva disegnata, ricerca e tutto schermo', (
      t,
    ) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final doc = parsePptx(_office('presentazione.pptx'));
      final pane = ReaderPaneController();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: DocumentView(doc: doc, controller: pane),
          ),
        ),
      );
      await t.pump();
      expect(find.byType(SlideCanvas), findsWidgets);
      expect(
        find.textContaining('Analisi Matematica I', findRichText: true),
        findsWidgets,
      );
      pane.find('importante');
      await t.pump();
      expect(pane.matchCount, 1);
      await t.tap(
        find.byTooltip('Diapositiva a tutto schermo').hitTestable().first,
      );
      await t.pumpAndSettle();
      expect(find.byType(SlideViewerPage), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });
  });

  group('limiti degli altri documenti', () {
    test('Excel vero: grafico segnalato, foglio semplice completo', () {
      expect(parseXlsx(_office('foglio.xlsx')).limits, isEmpty);
      final withChart = parseXlsx(_office('foglio_grafico.xlsx'));
      expect(withChart.limits, contains('grafici'));
      expect(withChart.plainText, contains('Analisi'));
      // salvati da Excel in OpenDocument: valori letti
      expect(parseOds(_office('foglio.ods')).plainText, contains('Fisica'));
    });

    test('PowerPoint 97–2003 vero: testo e immagini, formato semplificato', () {
      final doc = parsePpt(_office('presentazione.ppt'));
      expect(doc.plainText, contains('Grafico della funzione'));
      expect(doc.plainText, contains('Nota importante'));
      final images = doc.sections.last.blocks.whereType<RImage>().toList();
      expect(doc.sections.last.title, 'Immagini della presentazione');
      expect(images, isNotEmpty);
      expect(images.first.bytes.sublist(1, 4), 'PNG'.codeUnits);
      expect(
        formatOfExtension('.ppt')!.fidelity,
        ReaderFidelity.partial,
      );
    });

    test('Excel 97–2003 vero: valori letti, formato semplificato', () async {
      final tmp = Directory.systemTemp.createTempSync('um_fid_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final f = File(p.join(tmp.path, 'foglio.xls'))
        ..writeAsBytesSync(_office('foglio.xls'));
      final (format, content) = await loadReaderContent(f.path);
      expect((content as DocContent).doc.plainText, contains('Analisi'));
      expect(format.fidelity, ReaderFidelity.partial);
      expect(readerShortfall(format, content), contains('grafici'));
    });

    test('Word: formule, grafici ed EMF segnalati', () {
      final docx = zipOf({
        '_rels/.rels':
            '<Relationships $_rels><Relationship Id="rId1" Type="$_rb/officeDocument" Target="word/document.xml"/></Relationships>',
        'word/_rels/document.xml.rels':
            '<Relationships $_rels><Relationship Id="rId5" Type="$_rb/image" Target="media/a.emf"/></Relationships>',
        'word/media/a.emf': _emf(),
        'word/document.xml':
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
            'xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" '
            'xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><w:body>'
            '<w:p><w:r><w:t>Testo</w:t></w:r><m:oMath><m:r><m:t>x</m:t></m:r></m:oMath></w:p>'
            '<w:p><w:r><w:drawing><a:graphic><a:graphicData><a:blip r:embed="rId5"/></a:graphicData></a:graphic></w:drawing></w:r></w:p>'
            '<w:p><w:r><w:drawing><a:graphic><a:graphicData><c:chart r:id="rId9"/></a:graphicData></a:graphic></w:drawing></w:r></w:p>'
            '</w:body></w:document>',
      });
      final doc = parseDocx(docx);
      expect(doc.limits, containsAll(['formule', 'immagini EMF/WMF', 'grafici']));
      expect(doc.sections.expand((s) => s.blocks).whereType<RImage>(), isEmpty);
      expect(parseDocx(buildDocx()).limits, isEmpty);
    });
  });

  test('tabella dei formati: completa, semplificata o non supportata', () {
    final partial = {
      for (final f in kReaderFormats)
        if (f.fidelity == ReaderFidelity.partial) f.extension,
    };
    expect(partial, {
      '.doc', '.dot', '.ps', '.eps', '.pages', //
      '.ppt', '.pps', '.pot', '.key',
      '.xls', '.xlt', '.numbers',
      '.xps', '.oxps', '.kfx', '.kfx-zip', '.kpf', '.acsm',
      '.goodnotes', '.note', '.notability', '.one', '.onepkg', '.canvas',
    });
    // i formati principali hanno la resa completa (salvo i limiti del file)
    for (final ext in [
      '.pdf', '.docx', '.pptx', '.odp', '.xlsx', '.odt', '.ods', '.rtf', //
      '.epub',
      '.md', '.png', '.mp3', '.mp4', '.djvu', '.xopp', '.zip',
    ]) {
      expect(formatOfExtension(ext)!.fidelity, ReaderFidelity.full, reason: ext);
    }
    expect(unknownFormat('.qwerty').fidelity, ReaderFidelity.unsupported);
    // i file non mostrati affatto non chiedono (hanno già «Apri con…»)
    expect(
      readerShortfall(formatOfExtension('.doc')!, const InfoContent('x')),
      isNull,
    );
    expect(
      readerShortfall(
        formatOfExtension('.pptx')!,
        DocContent(RDoc(sections: [], limits: const ['grafici', 'formule'])),
      ),
      'grafici e formule',
    );
  });

  group('domanda all\'apertura', () {
    late Directory tmp;
    late AppDatabase db;
    late ReaderStore store;
    final calls = <MethodCall>[];

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('um_fid_ui_');
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalLauncher.openWithChannel, (c) async {
            calls.add(c);
            return 'ok';
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalLauncher.openWithChannel, null);
      tmp.deleteSync(recursive: true);
    });

    Future<String> write(WidgetTester t, String name, List<int> bytes) async {
      final f = File(p.join(tmp.path, name));
      await t.runAsync(() => f.writeAsBytes(bytes));
      return f.path;
    }

    Future<void> settle(WidgetTester t, [int n = 12]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> open(WidgetTester t, String path) async {
      t.view.physicalSize = const Size(1000, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(c).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderScreen(path: path, store: store),
                    ),
                  ),
                  child: const Text('apri'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('apri'));
      await settle(t);
    }

    testWidgets('anteprima semplificata e «Non chiedere più»', (t) async {
      db = (await t.runAsync(AppDatabase.openInMemory))!;
      final settings = SettingsRepository(db);
      store = ReaderStore(settings);
      final path = await write(t, 'vecchio.doc', buildDoc('Ciao mondo\r'));
      await open(t, path);
      expect(find.text('Anteprima semplificata'), findsOneWidget);
      expect(find.textContaining('Word 97–2003'), findsOneWidget);
      // due pulsanti al massimo, più la casella
      expect(find.byType(TextButton), findsWidgets);
      expect(find.text('Vedi anteprima semplificata'), findsOneWidget);
      expect(find.text('Apri con un\'altra app'), findsOneWidget);
      await t.tap(find.text('Non chiedere più'));
      await t.pump();
      await t.tap(find.text('Vedi anteprima semplificata'));
      await settle(t, 4);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(
        await t.runAsync(() => settings.get('${kReaderPartialPrefix}doc')),
        'preview',
      );
      // riaperto: niente domanda
      await t.pageBack();
      await settle(t, 4);
      await t.tap(find.text('apri'));
      await settle(t);
      expect(find.text('Anteprima semplificata'), findsNothing);
      // «Ripristina le domande» la fa tornare
      expect(
        await t.runAsync(() => resetDontAskQuestions(settings)),
        greaterThanOrEqualTo(1),
      );
      await t.pageBack();
      await settle(t, 4);
      await t.tap(find.text('apri'));
      await settle(t);
      expect(find.text('Anteprima semplificata'), findsOneWidget);
      await t.runAsync(db.close);
    });

    testWidgets('«Apri con un\'altra app»: scelta del sistema, lettore chiuso', (
      t,
    ) async {
      db = (await t.runAsync(AppDatabase.openInMemory))!;
      store = ReaderStore(SettingsRepository(db));
      final path = await write(t, 'slide vecchie.ppt', buildPpt());
      await open(t, path);
      await t.tap(find.text('Apri con un\'altra app'));
      await settle(t, 16);
      expect(calls.single.method, 'openWith');
      expect(
        p.normalize((calls.single.arguments as Map)['path'] as String),
        p.normalize(path),
      );
      expect(find.byType(ReaderScreen), findsNothing);
      await t.runAsync(db.close);
    });

    testWidgets('file completo: nessuna domanda', (t) async {
      db = (await t.runAsync(AppDatabase.openInMemory))!;
      store = ReaderStore(SettingsRepository(db));
      final path = await write(t, 'deck.pptx', _office('presentazione.pptx'));
      await open(t, path);
      expect(find.text('Anteprima semplificata'), findsNothing);
      expect(find.byType(SlideCanvas), findsWidgets);
      await t.runAsync(db.close);
    });
  });
}
