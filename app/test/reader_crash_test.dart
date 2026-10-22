// Casi di blocco e chiusura del lettore trovati con il fuzz
// (reader_fuzz_test.dart, reader_view_fuzz_test.dart) e con la lettura
// del codice: file rovinati, troncati o costruiti apposta, file illeggibili
// o enormi. Ogni caso deve finire presto con un messaggio, non bloccare
// l'app né finirne la memoria.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/reader/djvu/bzz.dart';
import 'package:university_notes/features/reader/djvu/djvu_document.dart';
import 'package:university_notes/features/reader/parsers/cfb.dart';
import 'package:university_notes/features/reader/parsers/html_blocks.dart';
import 'package:university_notes/features/reader/parsers/ink.dart';
import 'package:university_notes/features/reader/parsers/legacy_office.dart';
import 'package:university_notes/features/reader/parsers/notes_apps.dart';
import 'package:university_notes/features/reader/parsers/text_formats.dart';
import 'package:university_notes/features/reader/parsers/windows_ink.dart';
import 'package:university_notes/features/reader/parsers/zip_util.dart';
import 'package:university_notes/features/reader/reader_controller.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/features/reader/reader_formats.dart';
import 'package:university_notes/features/reader/reader_loader.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/features/reader/views/document_view.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'reader_fixtures.dart';

Uint8List _u(String s) => Uint8List.fromList(utf8.encode(s));

List<int> _mb(int v) {
  final out = <int>[];
  do {
    var b = v & 0x7F;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

/// Disegno di una pagina DjVu in un isolate con tempo massimo: deve finire
/// (con la pagina o con un errore di formato), non restare appeso.
Future<void> _rendersOrFails(Uint8List bytes) async {
  await runIsolated(() {
    try {
      final doc = DjvuDocument.parse(bytes);
      for (var i = 0; i < doc.pages.length; i++) {
        doc.text(i);
        try {
          renderDjvuPage(doc.pageData(i), reduction: 8);
        } on FormatException {
          // pagina rovinata: «Pagina non decodificabile»
        }
      }
    } on FormatException {
      // documento rovinato: messaggio nel lettore
    }
  }, timeout: const Duration(seconds: 30));
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reader_crash');
    readerTempDir = () async => Directory(p.join(tmp.path, 'temp'));
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<String> write(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(bytes);
    return f.path;
  }

  group('DjVu troncati o rovinati', () {
    // Prima: con i dati finiti lo ZP-Coder legge bit a 1 per sempre e la
    // maschera JB2 (o l'immagine IW44) non arrivava mai al record di fine.
    test('troncato: il disegno della pagina finisce', () async {
      final b = File('test/fixtures/djvu/bitonal.djvu').readAsBytesSync();
      await _rendersOrFails(Uint8List.sublistView(b, 0, 328));
      final s = File('test/fixtures/djvu/shared.djvu').readAsBytesSync();
      await _rendersOrFails(Uint8List.sublistView(s, 0, 1469));
      final ph = File('test/fixtures/djvu/photo.djvu').readAsBytesSync();
      await _rendersOrFails(Uint8List.sublistView(ph, 0, ph.length ~/ 2));
    });

    test('un byte cambiato o un intero enorme: il disegno finisce', () async {
      final b = File('test/fixtures/djvu/compound.djvu').readAsBytesSync();
      for (final o in [40, 155, 268, 300, 400, 500, 600]) {
        if (o + 4 > b.length) continue;
        for (final v in const [
          [0x7F, 0xFF, 0xFF, 0xFF],
          [0, 0, 0, 0],
          [0xFF, 0xFF, 0xFF, 0xFF],
        ]) {
          final m = Uint8List.fromList(b)..setAll(o, v);
          await _rendersOrFails(m);
        }
      }
    });

    test('BZZ senza blocco di fine: errore di formato, non un ciclo', () {
      final garbage = Uint8List.fromList(List.generate(64, (i) => i * 37));
      final sw = Stopwatch()..start();
      expect(() => bzzDecode(garbage), throwsFormatException);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('pagina di 0 pixel o di 65535×65535: non si disegna', () {
      final b = File('test/fixtures/djvu/bitonal.djvu').readAsBytesSync();
      final doc = DjvuDocument.parse(b);
      final data = doc.pageData(0);
      // INFO subito dopo FORM:DJVU (12 byte) e l'intestazione (8)
      final zero = Uint8List.fromList(data.page)..setAll(20, [0, 0, 0, 0]);
      expect(
        () => renderDjvuPage(DjvuPageData(zero, data.includes)),
        throwsFormatException,
      );
      final huge = Uint8List.fromList(data.page)
        ..setAll(20, [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(
        () => renderDjvuPage(DjvuPageData(huge, data.includes)),
        throwsFormatException,
      );
    });
  });

  group('lunghezze enormi o negative', () {
    test('ISF: milioni di punti dichiarati → errore, niente liste enormi', () {
      // Prima: List.filled(0x7FFFFFFF) → memoria finita (o app chiusa).
      final body = [..._mb(0x7FFFFFFF), 0x2C, 1, 2, 3];
      final tags = [10, ..._mb(body.length), ...body];
      final isf = Uint8List.fromList([0, ..._mb(tags.length), ...tags]);
      expect(() => parseWindowsInk(isf), throwsFormatException);
    });

    test('ISF: lunghezza che diventa negativa → errore, non un ciclo', () {
      // 9 byte con il bit alto: valore oltre i 63 bit
      final tags = [
        99,
        ...List.filled(9, 0xFF),
        0x7F,
      ];
      final isf = Uint8List.fromList([0, ..._mb(tags.length), ...tags]);
      expect(() => parseWindowsInk(isf), throwsFormatException);
    });

    test('OLE2: catena DIFAT circolare e conteggio FAT enorme', () async {
      // Prima: la catena che punta a sé stessa aggiungeva settori FAT
      // finché la memoria non finiva.
      final doc = buildDoc('Testo di prova');
      final d = ByteData.sublistView(doc);
      d.setUint32(0x2C, 0xFFFFFFFF, Endian.little); // settori FAT
      d.setUint32(0x44, 0, Endian.little); // primo settore DIFAT
      d.setUint32(0x48, 0xFFFFFFFF, Endian.little); // settori DIFAT
      d.setUint32(512 + 508, 0, Endian.little); // il settore 0 punta a sé
      await runIsolated(() {
        try {
          final cfb = Cfb(doc);
          cfb.streamNames;
          parseDoc(doc);
        } on FormatException {
          // va bene: documento rovinato
        }
      }, timeout: const Duration(seconds: 30));
    });

    test('ZIP: una voce che si decomprime oltre il limite si ferma', () {
      final saved = Zip.maxEntryBytes;
      addTearDown(() => Zip.maxEntryBytes = saved);
      Zip.maxEntryBytes = 1024 * 1024;
      final bomb = zipOf({'word/document.xml': Uint8List(4 * 1024 * 1024)});
      final zip = Zip(bomb);
      expect(() => zip.bytes('word/document.xml'), throwsFormatException);
      // dimensione falsa nell'indice: la decompressione si ferma lo stesso
      final archive = ZipDecoder().decodeBytes(bomb);
      archive.files.single.size = 10;
      expect(
        () => Zip.readEntry(archive.files.single),
        throwsFormatException,
      );
      // le voci normali si leggono come prima
      expect(Zip(buildDocx()).text('word/document.xml'), contains('teorema'));
    });

    test('deflate troncato: si tiene quanto decompresso', () {
      // testo poco comprimibile: metà dei dati compressi = molti caratteri
      var x = 7;
      final data = [
        for (var i = 0; i < 200000; i++) 97 + (x = (x * 1103515245 + 12345) & 0x7FFFFFFF) % 26,
      ];
      final raw = Deflate(data).getBytes();
      final half = inflateRaw(raw.sublist(0, raw.length ~/ 2), limit: 1 << 20);
      expect(half.length, greaterThan(1000));
      expect(half.sublist(0, 50), data.sublist(0, 50));
      expect(inflateRaw(raw, limit: 1 << 20), data);
    });
  });

  group('annidamenti esagerati', () {
    test('mappa mentale con 5000 livelli: al massimo kOutlineMaxDepth', () {
      final mm = '<map>${'<node TEXT="n">' * 5000}${'</node>' * 5000}</map>';
      final d = parseMindMap(_u(mm));
      expect(d.walk().length, kOutlineMaxDepth + 1);
    });

    test('HTML con 50000 div annidati: niente stack esaurito', () {
      final html = '<html><body>${'<div>' * 50000}fondo${'</div>' * 50000}'
          '<p>dopo</p></body></html>';
      // Prima: il parser HTML impiegava minuti (tempo quadratico) e, sotto i
      // 384 KB, sul thread dell'interfaccia: app bloccata.
      final sw = Stopwatch()..start();
      final blocks = HtmlBlocks.parse(html);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect(
        blocks.whereType<RPara>().any((b) => b.text.contains('dopo')),
        isTrue,
      );
      expect(htmlNesting('<p>a<br><img src=x/><b>b</b></p>'), 2);
      // le pagine normali restano HTML vero
      final normal = htmlDoc('<html><body><h1>T</h1><p>x</p></body></html>');
      expect(normal.sections.single.blocks.first, isA<RPara>());
      expect((normal.sections.single.blocks.first as RPara).isHeading, isTrue);
    });

    test('RTF con 400000 righe: lettura in tempo lineare', () {
      // Prima: ogni pezzo di testo si aggiungeva con «testo + pezzo» e
      // 400000 pezzi copiavano decine di GB (oltre 20 s, app ferma).
      final sw = Stopwatch()..start();
      final d = parseDocument(_u('{\\rtf1 ${'x\n' * 400000}}'), '.rtf');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect(d.plainText.replaceAll(RegExp(r'\s'), '').length, 400000);
    });

    test('JSON con 100000 livelli: si mostra il testo com\'è', () {
      final json = '${'[' * 100000}${']' * 100000}';
      final d = jsonDoc(json);
      expect(d.mono, isTrue);
      expect(d.plainText.length, json.length);
    });
  });

  group('valori non finiti', () {
    test('parseFinite rifiuta NaN, infinito e numeri fuori scala', () {
      expect(parseFinite('NaN'), isNull);
      expect(parseFinite('Infinity'), isNull);
      expect(parseFinite('-Infinity'), isNull);
      expect(parseFinite('1e999'), isNull);
      expect(parseFinite(' 2.5 '), 2.5);
      expect(parseFinite(null), isNull);
    });

    test('appunti a mano: pagine e testi con misure impossibili', () {
      final page = InkPage(double.nan, -3);
      expect((page.width, page.height), (595.0, 842.0));
      expect(InkPage(1e12, 0).width, 100000);
      final t = InkText(double.infinity, double.nan, 'x', size: double.nan);
      expect((t.x, t.y, t.size), (0.0, 0.0, 12.0));
      final xopp = GZipEncoder().encodeBytes(
        utf8.encode(
          '<xournal><page width="NaN" height="Infinity"><layer>'
          '<text size="NaN" x="1e999" y="2">t</text>'
          '<image left="a" top="NaN" right="1" bottom="1">AAAA</image>'
          '</layer></page></xournal>',
        ),
      );
      final d = parseXopp(Uint8List.fromList(xopp));
      final p0 = d.pages.single;
      expect(p0.width.isFinite && p0.height.isFinite, isTrue);
      expect(p0.texts.single.size, 12);
      expect(p0.images.single.left, 0);
    });
  });

  group('caricamento', () {
    test('file più grande del limite: messaggio, niente lettura in memoria',
        () async {
      final saved = readerMaxBytes;
      addTearDown(() => readerMaxBytes = saved);
      readerMaxBytes = 100;
      final path = await write('grande.txt', List.filled(1000, 65));
      final (_, c) = await loadReaderContent(path);
      expect((c as InfoContent).message, contains('troppo grande'));
      expect(c.message, contains('altra app'));
    });

    test('una cartella al posto del file', () async {
      final dir = Directory(p.join(tmp.path, 'cartella.pdf'))..createSync();
      final (_, c) = await loadReaderContent(dir.path);
      expect((c as InfoContent).message, contains('cartella'));
    });

    test('file bloccato da un altro programma: messaggio, non un errore',
        () async {
      // Prima: la lettura dei primi byte era fuori dal try e l'errore
      // arrivava alla schermata («Impossibile aprire il file: ...»).
      final path = await write('bloccato.docx', buildDocx());
      final raf = await File(path).open(mode: FileMode.append);
      await raf.lock(FileLock.blockingExclusive);
      addTearDown(() async {
        await raf.unlock();
        await raf.close();
      });
      final (_, c) = await loadReaderContent(path);
      expect(c, isA<InfoContent>());
      expect((c as InfoContent).message, contains('in uso'));
    }, skip: !Platform.isWindows);

    test('errore interno del parser: messaggio in italiano senza RangeError',
        () {
      final m = unreadableMessage(
        formatOfExtension('.docx')!,
        RangeError.range(40, 0, 12),
      );
      expect(m, isNot(contains('RangeError')));
      expect(m, contains('altra app'));
      expect(
        unreadableMessage(
          formatOfExtension('.docx')!,
          const FormatException('manca word/document.xml'),
        ),
        contains('manca word/document.xml'),
      );
    });

    test('isolate: tempo massimo, isolate fermato, eccezioni col loro tipo',
        () async {
      await expectLater(
        runIsolated<int>(() {
          var i = 0;
          while (true) {
            i++;
            if (i < 0) return i;
          }
        }, timeout: const Duration(milliseconds: 500)),
        throwsA(isA<ReaderTimeoutException>()),
      );
      await expectLater(
        runIsolated<int>(() => throw const EncryptedDocumentException()),
        throwsA(isA<EncryptedDocumentException>()),
      );
      expect(await runIsolated(() => 6 * 7), 42);
    });
  });

  group('archivi', () {
    test('nomi non validi su Windows: la nota si estrae lo stesso', () async {
      final zip = await write(
        'export.zip',
        zipOf({
          'Corso: lezione?.md': '# Lezione\n[altra](altra.md)',
          'altra.md': 'x',
          'CON.md': 'riservato',
        }),
      );
      final out = await extractArchiveEntry(zip, 'Corso: lezione?.md');
      expect(File(out).readAsStringSync(), contains('Lezione'));
      final con = await extractArchiveEntry(zip, 'CON.md');
      expect(File(con).readAsStringSync(), 'riservato');
    });

    test('safeFileName', () {
      expect(safeFileName('a:b?.md', windows: true), 'a_b_.md');
      expect(safeFileName('nul.txt', windows: true), '_nul.txt');
      expect(safeFileName('fine. ', windows: true), 'fine');
      expect(safeFileName('a:b?.md', windows: false), 'a:b?.md');
      expect(safeFileName('..', windows: true), '..');
      expect(safeFileName('x' * 300, windows: false).length, 120);
    });
  });

  group('dati salvati rovinati', () {
    late AppDatabase db;
    setUp(() async => db = await AppDatabase.openInMemory());
    tearDown(() => db.close());

    test('posizione decimale: i segnalibri restano', () async {
      final settings = SettingsRepository(db);
      final store = ReaderStore(settings);
      final path = await write('libro.txt', 'ciao'.codeUnits);
      await settings.set(
        await ReaderStore.keyOf(path),
        jsonEncode({
          'pos': 12.0,
          'bm': [
            {'p': 3, 'l': 'tre', 'c': 'x'},
            {'p': 'rotto'},
            {'p': 5.0, 'l': 'cinque'},
          ],
        }),
      );
      final s = await store.load(path);
      expect(s.position, 12);
      expect(s.bookmarks.map((b) => b.position), [3, 5]);
      await settings.set(
        ReaderStore.recentKey,
        jsonEncode([
          {'path': path, 'title': 'Libro'},
          42,
          {'title': 'senza percorso'},
        ]),
      );
      expect((await store.recent()).map((r) => r.title), ['Libro']);
    });
  });

  group('archivio dei libri', () {
    test('nomi con percorsi: non si legge né si cancella fuori', () async {
      final base = Directory(p.join(tmp.path, 'base'))..createSync();
      final outside = File(p.join(base.path, 'fuori.pdf'))
        ..writeAsStringSync('x');
      final lib = BookLibrary(baseDir: () async => base);
      await lib.directory();
      await lib.remove('../fuori.pdf');
      await lib.remove(r'..\fuori.pdf');
      await lib.remove(outside.path);
      expect(outside.existsSync(), isTrue);
      expect(await lib.fileNamed('../fuori.pdf'), isNull);
      expect(await lib.fileNamed(outside.path), isNull);
      // i nomi normali funzionano come prima
      final src = File(p.join(tmp.path, 'Analisi 1.pdf'))
        ..writeAsStringSync('%PDF');
      final name = await lib.store(src.path);
      expect(await lib.fileNamed(name), isNotNull);
    });
  });

  testWidgets('paragrafo di 2 milioni di caratteri: diviso in pezzi', (
    t,
  ) async {
    final long = List.generate(200000, (i) => 'parola$i').join(' ');
    final doc = RDoc(
      sections: [
        RSection('', [
          RPara.text('Inizio'),
          RPara.text(long),
          RPara.text('Fine', style: RStyle.h1),
        ]),
      ],
      toc: [RTocEntry('Fine', section: 0, block: 2)],
    );
    final pane = ReaderPaneController();
    addTearDown(pane.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: DocumentView(doc: doc, controller: pane),
        ),
      ),
    );
    await t.pump();
    expect(t.takeException(), isNull);
    pane.find('parola199999');
    await t.pump();
    expect(pane.matchCount, 1);
    // l'indice punta ancora al titolo dopo il paragrafo diviso
    final fine = pane.outline.single.position;
    expect(pane.describe!(fine), contains('Fine'));
    expect(pane.plainText!(), contains('parola199999'));
  });
}
