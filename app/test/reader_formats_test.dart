import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/features/reader/reader_formats.dart';
import 'package:university_notes/features/reader/reader_loader.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'reader_fixtures.dart';

/// Elenco di controllo: ogni formato richiesto deve stare nella tabella.
const _required = {
  ReaderViewer.pdf: ['.pdf'],
  ReaderViewer.djvu: ['.djvu', '.djv'],
  ReaderViewer.document: [
    '.docx', '.docm', '.dotx', '.doc', '.odt', '.ott', '.rtf', //
    '.pptx', '.ppsx', '.potx', '.ppt', '.odp',
    '.xlsx', '.xlsm', '.xls', '.ods', '.csv', '.tsv',
    '.txt', '.md', '.markdown', '.html', '.htm', '.xhtml', '.xml', '.json',
    '.yaml', '.yml', '.tex', '.bib', '.rst', '.org', '.adoc', '.log', '.srt',
    '.vtt', '.py', '.java', '.c', '.cpp', '.h', '.js', '.ts', '.dart', '.kt',
    '.swift', '.m', '.r', '.sql', '.sh', '.ipynb',
    '.epub', '.mobi', '.azw', '.azw3', '.fb2', '.cbz', '.cbr', '.xps', '.oxps',
    '.kfx', '.kfx-zip', '.kpf', '.acsm', '.ps', '.eps',
    '.enex', '.canvas', '.one',
  ],
  ReaderViewer.container: [
    '.pages',
    '.key',
    '.numbers',
    '.goodnotes',
    '.note',
    '.notability',
  ],
  ReaderViewer.image: [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
    '.svg',
    '.tif',
    '.tiff',
  ],
  ReaderViewer.media: [
    '.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.opus', '.wma', //
    '.mp4', '.mov', '.mkv', '.webm', '.avi',
  ],
  ReaderViewer.ink: ['.xopp', '.excalidraw', '.ink', '.isf', '.inkml'],
  ReaderViewer.outline: ['.mm', '.opml'],
  ReaderViewer.archive: ['.zip', '.rar', '.onepkg'],
};

/// Formati per appunti ed e-book chiesti dagli utenti: tutti con una vista
/// vera (i KFX con DRM e i DjVu indiretti mostrano una spiegazione precisa
/// al caricamento, vedi i test dei formati).
const _notesAndBooks = [
  '.txt', '.md', '.rtf', '.docx', '.doc', '.odt', '.html', '.htm', '.tex', //
  '.org', '.ipynb', '.one', '.onepkg', '.notability', '.note', '.goodnotes',
  '.xopp', '.ink', '.isf', '.inkml', '.svg', '.png', '.jpg', '.pdf', '.epub',
  '.mobi', '.azw', '.azw3', '.kfx', '.cbz', '.cbr', '.rar', '.djvu', '.djv',
  '.fb2', '.xps', '.ps', '.eps', '.acsm', '.csv',
];

void main() {
  test('tabella dei formati: tutti i formati richiesti, ognuno una volta', () {
    final exts = kReaderFormats.map((f) => f.extension).toList();
    expect(exts.toSet().length, exts.length, reason: 'estensioni duplicate');
    for (final e in _required.entries) {
      for (final ext in e.value) {
        final f = formatOfExtension(ext);
        expect(f, isNotNull, reason: '$ext manca');
        expect(f!.viewer, e.key, reason: '$ext: vista');
      }
    }
    for (final ext in _notesAndBooks) {
      final f = formatOfExtension(ext);
      expect(f, isNotNull, reason: '$ext manca');
      expect(f!.supported, isTrue, reason: '$ext senza vista');
    }
    expect(
      kReaderFormats.where((f) => !f.supported).map((f) => f.extension),
      isEmpty,
    );
    expect(kReaderHints.map((h) => h.$1), contains('Apple Notes'));
    expect(detectFormat('/x/Libro.kfx-zip').label, 'Kindle KFX (archivio)');
    expect(detectFormat('/x/Disegno.excalidraw.json').extension, '.excalidraw');
    expect(detectFormat('/x/NOTE.PDF').viewer, ReaderViewer.pdf);
    expect(detectFormat('/x/strano.qwerty').viewer, ReaderViewer.info);
  });

  test('riconoscimento dai primi byte', () {
    expect(sniffExtension(ascii.encode('%PDF-1.7')), '.pdf');
    expect(sniffExtension(tinyPng), '.png');
    expect(sniffExtension([0xFF, 0xD8, 0xFF, 0xE0]), '.jpg');
    expect(sniffExtension([0x50, 0x4B, 3, 4]), '.zip');
    expect(sniffExtension(buildDoc('x').sublist(0, 512)), '.doc');
    expect(sniffExtension([...ascii.encode('ID3'), 3, 0]), '.mp3');
    expect(
      sniffExtension([0, 0, 0, 0x18, ...ascii.encode('ftypheic')]),
      '.heic',
    );
    expect(
      sniffExtension([0, 0, 0, 0x18, ...ascii.encode('ftypM4A ')]),
      '.m4a',
    );
    expect(sniffExtension(ascii.encode(r'{\rtf1 x')), '.rtf');
    expect(sniffExtension(utf8.encode('<!DOCTYPE html><p>')), '.html');
    expect(sniffExtension(utf8.encode('Appunti')), '.txt');
    expect(sniffExtension([1, 0, 2, 0, 0, 0]), isNull);
    expect(sniffExtension(ascii.encode('Rar!\x1A\x07\x01\x00')), '.rar');
    expect(sniffExtension(ascii.encode('%!PS-Adobe-3.0\n')), '.ps');
    expect(sniffExtension(ascii.encode('%!PS-Adobe-3.0 EPSF-3.0\n')), '.eps');
    expect(sniffExtension([0xC5, 0xD0, 0xD3, 0xC6, 0, 0]), '.eps');
    expect(sniffExtension([0xEA, ...ascii.encode('DRMION'), 0xEE]), '.kfx');
    expect(
      sniffExtension([...ascii.encode('CONT'), 2, 0, 18, 0, 0, 0]),
      '.kfx',
    );
    expect(sniffExtension(ascii.encode('CONTRATTO di affitto')), '.txt');
    // Senza estensione: dai byte.
    expect(
      detectFormat('/x/senza_nome', ascii.encode('%PDF-1.4')).viewer,
      ReaderViewer.pdf,
    );
    // Un "PDF" che è un documento Word.
    expect(
      detectFormat('/x/finto.pdf', buildDoc('x').sublist(0, 512)).extension,
      '.doc',
    );
  });

  group('caricamento', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('um_reader_');
      readerTempDir = () async => Directory(p.join(tmp.path, 'tmp'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<String> write(String name, List<int> bytes) async {
      final f = File(p.join(tmp.path, name));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      return f.path;
    }

    test('ogni famiglia trova la sua vista', () async {
      final cases = <String, List<int>>{
        'a.docx': buildDocx(),
        'a.pptx': buildPptx(),
        'a.xlsx': buildXlsx(),
        'a.odt': buildOdt(),
        'a.epub': buildEpub(),
        'a.doc': buildDoc('Ciao\r'),
        'a.xls': buildXls(),
        'a.ppt': buildPpt(),
        'a.md': utf8.encode('# Titolo'),
        'a.py': utf8.encode('print(1)'),
        'a.enex': buildEnex(),
        'b.mobi': buildMobi('<p>x</p>'),
      };
      for (final e in cases.entries) {
        final (format, content) = await loadReaderContent(
          await write(e.key, e.value),
        );
        expect(content, isA<DocContent>(), reason: e.key);
        expect(format.extension, p.extension(e.key));
      }
      expect(
        (await loadReaderContent(
          await write('a.pdf', ascii.encode('%PDF-1.4')),
        )).$2,
        isA<PdfContent>(),
      );
      expect(
        (await loadReaderContent(await write('a.png', tinyPng))).$2,
        isA<ImageContent>(),
      );
      expect(
        (await loadReaderContent(await write('a.xopp', buildXopp()))).$2,
        isA<InkContent>(),
      );
      expect(
        (await loadReaderContent(
          await write('a.mm', utf8.encode('<map><node TEXT="x"/></map>')),
        )).$2,
        isA<OutlineContent>(),
      );
      final zip = (await loadReaderContent(
        await write('a.zip', zipOf({'dentro/n.txt': 'ciao'})),
      )).$2;
      expect((zip as ArchiveContent).entries.single.name, 'dentro/n.txt');
      final one = (await loadReaderContent(await write('a.one', [1, 2, 3]))).$2;
      expect((one as DocContent).actions, contains(ReaderAction.oneNote));
      expect(
        (await loadReaderContent(
          await write('a.djvu', ascii.encode('AT&TFORM')),
        )).$2,
        isA<InfoContent>(),
      );
      expect(
        (await loadReaderContent(p.join(tmp.path, 'manca.txt'))).$2,
        isA<InfoContent>(),
      );
    });

    test('contenitori: anteprima PDF estratta, altrimenti messaggio', () async {
      final pdf = ascii.encode('%PDF-1.4 anteprima');
      final (_, pages) = await loadReaderContent(
        await write('Relazione.pages', zipOf({'QuickLook/Preview.pdf': pdf})),
      );
      final path = (pages as PdfContent).path;
      expect(File(path).readAsBytesSync(), pdf);
      expect(pages.notice, contains('anteprima'));
      final (_, empty) = await loadReaderContent(
        await write('Vuoto.key', zipOf({'Index.zip': 'x'})),
      );
      expect(empty, isA<InfoContent>());
    });

    test('DRM e password: messaggio chiaro', () async {
      final (_, mobi) = await loadReaderContent(
        await write('drm.azw', buildMobi('x', encryption: 2)),
      );
      expect((mobi as InfoContent).message, contains('DRM'));
      final enc = buildCfb({
        'EncryptedPackage': Uint8List(10),
        'EncryptionInfo': Uint8List(10),
      });
      final (_, docx) = await loadReaderContent(
        await write('segreto.docx', enc),
      );
      expect((docx as InfoContent).message, contains('password'));
    });

    test(
      'registrazione: trascrizione con lo stesso nome nella cartella vicina',
      () async {
        final audio = await write(
          'Corso/Registrazioni/2026-10-05 Lezione.flac',
          [0x66, 0x4C, 0x61, 0x43],
        );
        await write(
          'Corso/Trascrizioni/2026-10-05 Lezione.md',
          utf8.encode('# Trascrizione\n\nOggi derivate.'),
        );
        final (format, media) = await loadReaderContent(audio);
        expect(format.family, ReaderFamily.audio);
        final m = media as MediaContent;
        expect(m.video, isFalse);
        expect(m.transcript!.plainText, contains('Oggi derivate.'));
        // .srt accanto al video: tempi toccabili.
        final video = await write('v/lezione.mp4', [
          0,
          0,
          0,
          0x18,
          ...ascii.encode('ftypisom'),
        ]);
        await write(
          'v/lezione.srt',
          utf8.encode('1\n00:00:05,000 --> 00:00:07,000\nCiao\n'),
        );
        final (_, v) = await loadReaderContent(video);
        final first =
            (v as MediaContent).transcript!.sections.first.blocks.first
                as RPara;
        expect(first.spans.first.seconds, 5);
      },
    );

    test('voce di un archivio estratta per il lettore', () async {
      final zip = await write('a.zip', zipOf({'cartella/nota.md': '# Ciao'}));
      final out = await extractArchiveEntry(zip, 'cartella/nota.md');
      expect(p.basename(out), 'nota.md');
      expect(File(out).readAsStringSync(), '# Ciao');
    });
  });

  test(
    'memoria del lettore: posizione e segnalibri per file, recenti',
    () async {
      final db = await AppDatabase.openInMemory();
      final store = ReaderStore(SettingsRepository(db));
      final tmp = Directory.systemTemp.createTempSync('um_store_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final f = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('uno');

      expect((await store.load(f.path)).position, isNull);
      await store.savePosition(f.path, 12);
      await store.addBookmark(
        f.path,
        ReaderBookmark(30, 'Capitolo 2', DateTime(2026)),
      );
      await store.addBookmark(
        f.path,
        ReaderBookmark(5, 'Inizio', DateTime(2026)),
      );
      var s = await store.load(f.path);
      expect(s.position, 12);
      expect(s.bookmarks.map((b) => b.label), ['Inizio', 'Capitolo 2']);
      await store.removeBookmark(f.path, 5);
      expect((await store.load(f.path)).bookmarks.single.position, 30);

      // Stesso percorso, contenuto di dimensione diversa: si riparte da capo.
      f.writeAsStringSync('un altro file più lungo');
      s = await store.load(f.path);
      expect(s.position, isNull);

      await store.addRecent('/a/uno.pdf', now: DateTime(2026, 1, 1));
      await store.addRecent(
        '/a/due.docx',
        title: 'Due',
        now: DateTime(2026, 1, 2),
      );
      await store.addRecent('/a/uno.pdf', now: DateTime(2026, 1, 3));
      final recent = await store.recent();
      expect(recent.map((r) => r.name), ['uno.pdf', 'due.docx']);
      expect(recent.last.title, 'Due');
      await store.removeRecent('/a/uno.pdf');
      expect((await store.recent()).single.path, '/a/due.docx');
      await store.clearRecent();
      expect(await store.recent(), isEmpty);
      await db.close();
    },
  );
}
