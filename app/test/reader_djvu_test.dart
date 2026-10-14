// Decodificatore DjVu dell'app confrontato con DjVuLibre: i file in
// test/fixtures/djvu/ e le immagini di riferimento (ddjvu) sono prodotti da
// test/fixtures/djvu/make_fixtures.sh (cjb2, c44, cpaldjvu, djvm, djvused,
// minidjvu). JB2 deve coincidere pixel per pixel; IW44 entro piccole
// differenze di arrotondamento.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:university_notes/features/reader/djvu/bzz.dart';
import 'package:university_notes/features/reader/djvu/djvu_document.dart';
import 'package:university_notes/features/reader/djvu/iff.dart';
import 'package:university_notes/features/reader/djvu/iw44.dart';
import 'package:university_notes/features/reader/djvu/jb2.dart';
import 'package:university_notes/features/reader/reader_formats.dart';
import 'package:university_notes/features/reader/reader_loader.dart';

Uint8List fixture(String name) =>
    File(p.join('test', 'fixtures', 'djvu', name)).readAsBytesSync();

/// PBM P4 → un byte per pixel (1 = nero).
(int, int, Uint8List) readPbm(Uint8List b) {
  var pos = 0;
  String token() {
    while (b[pos] <= 32 || b[pos] == 35) {
      if (b[pos] == 35) {
        while (b[pos] != 10) {
          pos++;
        }
      }
      pos++;
    }
    final s = pos;
    while (b[pos] > 32) {
      pos++;
    }
    return String.fromCharCodes(b, s, pos);
  }

  expect(token(), 'P4');
  final w = int.parse(token()), h = int.parse(token());
  pos++;
  final out = Uint8List(w * h);
  final row = (w + 7) >> 3;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out[y * w + x] = (b[pos + y * row + (x >> 3)] >> (7 - (x & 7))) & 1;
    }
  }
  return (w, h, out);
}

/// Errore medio assoluto per canale e massimo rispetto a un PNG.
(List<double>, int) compare(Uint8List rgba, int w, int h, String png) {
  final ref = img
      .decodePng(fixture(png))!
      .convert(format: img.Format.uint8, numChannels: 3);
  expect((ref.width, ref.height), (w, h), reason: png);
  final sum = [0, 0, 0];
  var max = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = ref.getPixel(x, y);
      final o = (y * w + x) * 4;
      final d = [
        (rgba[o] - px.r.toInt()).abs(),
        (rgba[o + 1] - px.g.toInt()).abs(),
        (rgba[o + 2] - px.b.toInt()).abs(),
      ];
      for (var c = 0; c < 3; c++) {
        sum[c] += d[c];
        if (d[c] > max) max = d[c];
      }
    }
  }
  return ([for (final s in sum) s / (w * h)], max);
}

void main() {
  test('BZZ: blocchi decompressi come bzz di DjVuLibre', () {
    expect(
      utf8.decode(bzzDecode(base64Decode('///z/z3LQXMjwpcREw=='))),
      'abracadabra',
    );
    expect(
      utf8.decode(
        bzzDecode(
          base64Decode(
            '//+b/okMjS0NQ307nXz9XFwl6yY6agP+aAI6yAN6tRRIBPtqs51+TVYyYkAv55FxZ360nw==',
          ),
        ),
      ),
      'Lezione di analisi: limiti, derivate e integrali. '
      'Lezione di analisi: limiti, derivate e integrali.',
    );
  });

  test('JB2 (Sjbz di cjb2): identico pixel per pixel a ddjvu', () {
    final bytes = fixture('bitonal.djvu');
    final form = parseDjvuFile(bytes);
    expect(form.kind, 'FORM:DJVU');
    final sjbz = form.child('Sjbz')!;
    final image = decodeJb2(bytes, start: sjbz.start, end: sjbz.end);
    final (w, h, ref) = readPbm(fixture('bitonal.pbm'));
    expect((image.width, image.height), (w, h));
    expect(image.toMask(), ref);
    // Stessa cosa dalla pagina disegnata (bianco e nero).
    final doc = DjvuDocument.parse(bytes);
    final bm = renderDjvuPage(doc.pageData(0));
    var diff = 0;
    for (var i = 0; i < w * h; i++) {
      if ((bm.rgba[i * 4] == 0 ? 1 : 0) != ref[i]) diff++;
    }
    expect(diff, 0);
  });

  test(
    'IW44 a colori e in grigio (c44): come ddjvu entro l\'arrotondamento',
    () {
      for (final (file, png) in [
        ('photo.djvu', 'photo.png'),
        ('chroma_half.djvu', 'chroma_half.png'), // c44 -crcbhalf
        ('gray.djvu', 'gray.png'),
      ]) {
        final doc = DjvuDocument.parse(fixture(file));
        final bm = renderDjvuPage(doc.pageData(0));
        final (mae, max) = compare(bm.rgba, bm.width, bm.height, png);
        for (final m in mae) {
          expect(m, lessThan(3), reason: '$file: $mae');
        }
        expect(max, lessThan(40), reason: file);
      }
      // Blocchi BG44 progressivi: anche i soli primi danno l'immagine intera.
      final bytes = fixture('photo.djvu');
      final chunks = parseDjvuFile(bytes).all('BG44').toList();
      expect(chunks.length, greaterThan(1));
      final first = Iw44Image()
        ..addChunk(bytes, chunks[0].start, chunks[0].end);
      final rgb = first.toRgb();
      expect((rgb.width, rgb.height), (160, 120));
      // Ridotta di 2: metà dimensioni, decodificando meno livelli.
      expect(first.toRgb(1).width, 80);
    },
  );

  test('pagina composta: maschera JB2, primo piano FG44, sfondo BG44', () {
    final doc = DjvuDocument.parse(fixture('compound.djvu'));
    final bm = renderDjvuPage(doc.pageData(0));
    final (mae, _) = compare(bm.rgba, bm.width, bm.height, 'compound.png');
    for (final m in mae) {
      expect(m, lessThan(3), reason: '$mae');
    }
  });

  test('colori per forma (FGbz di cpaldjvu)', () {
    final doc = DjvuDocument.parse(fixture('palette.djvu'));
    final bm = renderDjvuPage(doc.pageData(0));
    final (mae, _) = compare(bm.rgba, bm.width, bm.height, 'palette.png');
    for (final m in mae) {
      expect(m, lessThan(3), reason: '$mae');
    }
  });

  test('documento raggruppato: pagine, segnalibri, rotazione, testo', () {
    final doc = DjvuDocument.parse(fixture('bundled.djvu'));
    expect(doc.pages.length, 3);
    expect(doc.pages.map((pg) => pg.id), [
      'bitonal.djvu',
      'photo.djvu',
      'compound.djvu',
    ]);
    expect(
      [for (final o in doc.outline) (o.title, o.page, o.level)],
      [('Inizio', 0, 0), ('Foto', 1, 0), ('Composta', 2, 1)],
    );
    // Pagina 2 ruotata di 90°: dimensioni scambiate, pixel come ddjvu.
    final p2 = doc.pages[1];
    expect(p2.rotation, 1);
    expect((p2.viewWidth, p2.viewHeight), (120, 160));
    final bm = renderDjvuPage(doc.pageData(1));
    expect((bm.width, bm.height), (120, 160));
    final (mae, _) = compare(bm.rgba, bm.width, bm.height, 'bundled_p2.png');
    for (final m in mae) {
      expect(m, lessThan(3), reason: '$mae');
    }
    // Testo nascosto (TXTz) con le parole e i loro rettangoli.
    final t = doc.text(0);
    expect(t.text, contains('perché continua'));
    expect(t.words.map((w) => w.text), ['Teorema', 'di', 'perché', 'continua']);
    final w = t.words.first;
    expect((w.left, w.top, w.right, w.bottom), (20, 30, 270, 70));
    expect(doc.text(1).text, isEmpty);
  });

  test('dizionario di forme condiviso (Djbz in FORM:DJVI, INCL)', () {
    final bytes = fixture('shared.djvu');
    final doc = DjvuDocument.parse(bytes);
    expect(doc.pages.length, 2);
    final data = doc.pageData(1);
    expect(data.includes, isNotEmpty);
    final bm = renderDjvuPage(data);
    final (mae, max) = compare(bm.rgba, bm.width, bm.height, 'shared_p2.png');
    expect(max, 0, reason: 'JB2 esatto: $mae');
    // Ridotta di 3: dimensioni arrotondate per eccesso.
    final small = renderDjvuPage(data, reduction: 3);
    expect(small.width, (doc.pages[1].width + 2) ~/ 3);
  });

  test('documento indiretto: spiegazione precisa', () async {
    expect(
      () => DjvuDocument.parse(fixture('indirect.djvu')),
      throwsA(isA<DjvuIndirectException>()),
    );
    final tmp = Directory.systemTemp.createTempSync('um_djvu_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File(p.join(tmp.path, 'libro.djvu'))
      ..writeAsBytesSync(fixture('indirect.djvu'));
    final (format, content) = await loadReaderContent(f.path);
    expect(format.viewer, ReaderViewer.djvu);
    expect((content as InfoContent).message, contains('indiretto'));
  });

  test('il lettore apre i DjVu con la vista a pagine', () async {
    final tmp = Directory.systemTemp.createTempSync('um_djvu_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File(p.join(tmp.path, 'scansione.djv'))
      ..writeAsBytesSync(fixture('bundled.djvu'));
    final (format, content) = await loadReaderContent(f.path);
    expect(format.label, 'DjVu');
    final c = content as DjvuContent;
    expect(c.doc.pages.length, 3);
    expect(c.texts.first.words.length, 4);
    expect(c.notice, isNull);
    // Senza testo nascosto: avviso.
    final g = File(p.join(tmp.path, 'foto.djvu'))
      ..writeAsBytesSync(fixture('photo.djvu'));
    final (_, photo) = await loadReaderContent(g.path);
    expect((photo as DjvuContent).notice, contains('testo'));
    // Senza estensione: dai primi byte.
    final h = File(p.join(tmp.path, 'senza_nome'))
      ..writeAsBytesSync(fixture('bitonal.djvu'));
    expect((await loadReaderContent(h.path)).$2, isA<DjvuContent>());
  });

  test('dati non validi: errore chiaro, nessun blocco', () {
    expect(
      () => DjvuDocument.parse(Uint8List.fromList(ascii.encode('AT&TFORM'))),
      throwsFormatException,
    );
    final shape = Jb2Shape(3, 2);
    expect(shape.trimmed().width, 0);
  });
}
