import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;
import 'package:koni_rar/koni_rar.dart';
import 'package:path/path.dart' as p;

import '../reader_document.dart';
import 'notes_apps.dart' show galleryDoc, naturalKey;
import 'zip_util.dart';

/// Archivi del lettore: ZIP, RAR (RAR4 e RAR5 con koni_rar, puro Dart) e
/// CAB (pacchetti OneNote .onepkg). Elenco delle voci e lettura di una
/// voce; i fumetti .cbz/.cbr diventano pagine di immagini.

class ArchiveItem {
  const ArchiveItem(this.name, this.size);
  final String name;
  final int size;
}

/// Archivio aperto: voci e lettura (asincrona: il RAR decomprime a flussi).
abstract class ReaderArchive {
  List<ArchiveItem> get items;
  Future<Uint8List?> read(String name);

  /// Apre [bytes] secondo i primi byte (ZIP, RAR o CAB).
  static Future<ReaderArchive> open(Uint8List bytes) async {
    if (isRar(bytes)) return RarArchive.open(bytes);
    if (isCab(bytes)) return CabArchive(bytes);
    return ZipArchive(Zip(bytes));
  }
}

bool _sig(Uint8List b, List<int> s) {
  if (b.length < s.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[i] != s[i]) return false;
  }
  return true;
}

/// "Rar!\x1A\x07" (RAR 1.5–4 e RAR5).
bool isRar(Uint8List b) => _sig(b, const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]);

/// "MSCF": archivio Microsoft Cabinet.
bool isCab(Uint8List b) => _sig(b, const [0x4D, 0x53, 0x43, 0x46]);

class ZipArchive implements ReaderArchive {
  ZipArchive(this.zip);
  final Zip zip;

  @override
  List<ArchiveItem> get items => [
    for (final f in zip.archive.files)
      if (f.isFile && !f.name.contains('__MACOSX/'))
        ArchiveItem(f.name, f.size),
  ];

  @override
  Future<Uint8List?> read(String name) async => zip.bytes(name);
}

/// Archivio RAR: le voci protette da password non si leggono.
class RarArchive implements ReaderArchive {
  RarArchive._(this._reader);
  final koni.ArchiveReader _reader;

  static Future<RarArchive> open(Uint8List bytes) async {
    final reader = await const RarFormat().createReader(
      koni.MemoryByteSource(bytes),
      const koni.ArchiveReadOptions(),
    );
    return RarArchive._(reader);
  }

  @override
  List<ArchiveItem> get items => [
    for (final e in _reader.entries)
      if (e.isFile) ArchiveItem(e.path, e.uncompressedSize),
  ];

  @override
  Future<Uint8List?> read(String name) async {
    for (final e in _reader.entries) {
      if (!e.isFile || e.path != name) continue;
      if (e.isEncrypted) {
        throw const FormatException('voce dell\'archivio protetta da password');
      }
      // stesso limite delle voci ZIP (dimensione dichiarata o reale)
      final limit = Zip.maxEntryBytes;
      if (e.uncompressedSize > limit) {
        throw FormatException('voce dell\'archivio troppo grande: $name');
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in _reader.openRead(e)) {
        out.add(chunk);
        if (out.length > limit) {
          throw FormatException('voce dell\'archivio troppo grande: $name');
        }
      }
      return out.takeBytes();
    }
    return null;
  }
}

// ------------------------------------------------------------------ CAB

class _CabFile {
  const _CabFile(this.name, this.size, this.offset, this.folder);
  final String name;
  final int size;
  final int offset;
  final int folder;
}

/// Microsoft Cabinet (specifica MS-CAB): voci non compresse o MSZIP
/// (deflate a blocchi con la finestra di 32 KB tra un blocco e l'altro).
/// LZX e Quantum non sono supportati.
class CabArchive implements ReaderArchive {
  CabArchive(this._b) {
    final d = ByteData.sublistView(_b);
    if (_b.length < 36 || !isCab(_b)) {
      throw const FormatException('Archivio CAB non valido');
    }
    final coffFiles = d.getUint32(16, Endian.little);
    final nFolders = d.getUint16(26, Endian.little);
    final nFiles = d.getUint16(28, Endian.little);
    final flags = d.getUint16(30, Endian.little);
    var pos = 36;
    var folderReserve = 0;
    if (flags & 0x0004 != 0) {
      final headerReserve = d.getUint16(36, Endian.little);
      folderReserve = _b[38];
      _dataReserve = _b[39];
      pos = 40 + headerReserve;
    }
    String zstr() {
      final s = pos;
      while (pos < _b.length && _b[pos] != 0) {
        pos++;
      }
      final t = String.fromCharCodes(_b, s, pos);
      pos++;
      return t;
    }

    if (flags & 0x0001 != 0) {
      zstr();
      zstr();
    }
    if (flags & 0x0002 != 0) {
      zstr();
      zstr();
    }
    for (var i = 0; i < nFolders; i++) {
      _folders.add((
        start: d.getUint32(pos, Endian.little),
        blocks: d.getUint16(pos + 4, Endian.little),
        type: d.getUint16(pos + 6, Endian.little) & 0x0F,
      ));
      pos += 8 + folderReserve;
    }
    pos = coffFiles;
    for (var i = 0; i < nFiles && pos + 16 < _b.length; i++) {
      final size = d.getUint32(pos, Endian.little);
      final off = d.getUint32(pos + 4, Endian.little);
      final folder = d.getUint16(pos + 8, Endian.little);
      final attribs = d.getUint16(pos + 14, Endian.little);
      pos += 16;
      final s = pos;
      while (pos < _b.length && _b[pos] != 0) {
        pos++;
      }
      final raw = Uint8List.sublistView(_b, s, pos);
      pos++;
      // Attributo 0x80: nome in UTF-8, altrimenti codepage (latin-1).
      final name = attribs & 0x80 != 0
          ? utf8.decode(raw, allowMalformed: true)
          : String.fromCharCodes(raw);
      _files.add(_CabFile(name.replaceAll('\\', '/'), size, off, folder));
    }
  }

  final Uint8List _b;
  int _dataReserve = 0;
  final _folders = <({int start, int blocks, int type})>[];
  final _files = <_CabFile>[];
  final _decoded = <int, Uint8List>{};

  @override
  List<ArchiveItem> get items => [
    for (final f in _files) ArchiveItem(f.name, f.size),
  ];

  Uint8List _folder(int i) {
    final cached = _decoded[i];
    if (cached != null) return cached;
    final f = _folders[i];
    if (f.type != 0 && f.type != 1) {
      throw FormatException(
        'compressione CAB ${f.type == 3 ? 'LZX' : 'Quantum'} non supportata',
      );
    }
    final d = ByteData.sublistView(_b);
    final out = BytesBuilder(copy: false);
    var window = Uint8List(0);
    var pos = f.start;
    for (var k = 0; k < f.blocks && pos + 8 <= _b.length; k++) {
      final cb = d.getUint16(pos + 4, Endian.little);
      final ucb = d.getUint16(pos + 6, Endian.little);
      final s = pos + 8 + _dataReserve;
      final data = Uint8List.sublistView(_b, s, (s + cb).clamp(s, _b.length));
      pos = s + cb;
      Uint8List block;
      if (f.type == 0) {
        block = data;
      } else {
        if (data.length < 2 || data[0] != 0x43 || data[1] != 0x4B) {
          throw const FormatException('blocco MSZIP senza "CK"');
        }
        block = _inflateWithHistory(Uint8List.sublistView(data, 2), window);
        if (out.length + block.length > Zip.maxEntryBytes) {
          throw const FormatException('cartella CAB troppo grande');
        }
        if (ucb > 0 && block.length > ucb) {
          block = Uint8List.sublistView(block, 0, ucb);
        }
        // Finestra per il blocco successivo: gli ultimi 32 KB.
        final joined = Uint8List(window.length + block.length)
          ..setAll(0, window)
          ..setAll(window.length, block);
        window = joined.length > 32768
            ? Uint8List.sublistView(joined, joined.length - 32768)
            : joined;
      }
      out.add(block);
    }
    return _decoded[i] = out.takeBytes();
  }

  /// Deflate con una storia iniziale: la si mette davanti come blocco non
  /// compresso, così i riferimenti all'indietro la trovano.
  static Uint8List _inflateWithHistory(Uint8List deflate, Uint8List history) {
    // Un blocco MSZIP ha al più 32 KB di dati: il limite ferma i blocchi
    // costruiti per decomprimersi in gigabyte.
    const limit = 64 * 1024;
    if (history.isEmpty) return inflateRaw(deflate, limit: limit);
    final n = history.length;
    final prefix = Uint8List(5 + n);
    prefix[0] = 0; // non finale, non compresso
    prefix[1] = n & 0xFF;
    prefix[2] = n >> 8;
    prefix[3] = (~n) & 0xFF;
    prefix[4] = ((~n) >> 8) & 0xFF;
    prefix.setAll(5, history);
    final all = Uint8List(prefix.length + deflate.length)
      ..setAll(0, prefix)
      ..setAll(prefix.length, deflate);
    final out = inflateRaw(all, limit: n + limit);
    return Uint8List.sublistView(out, n.clamp(0, out.length));
  }

  @override
  Future<Uint8List?> read(String name) async => readSync(name);

  Uint8List? readSync(String name) {
    for (final f in _files) {
      if (f.name != name) continue;
      if (f.folder >= _folders.length) return null;
      final data = _folder(f.folder);
      final end = (f.offset + f.size).clamp(0, data.length);
      return Uint8List.sublistView(data, f.offset.clamp(0, end), end);
    }
    return null;
  }
}

// --------------------------------------------------------------- Fumetti

const _imageExt = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

/// Pagine di un fumetto (.cbz, .cbr o un archivio di immagini): le
/// immagini in ordine naturale dei nomi.
Future<RDoc> comicDoc(ReaderArchive archive) async {
  final names = [
    for (final i in archive.items)
      if (_imageExt.contains(p.extension(i.name).toLowerCase()) &&
          !i.name.contains('__MACOSX'))
        i.name,
  ]..sort((a, b) => naturalKey(a).compareTo(naturalKey(b)));
  final images = <({String name, Uint8List bytes})>[];
  for (final n in names) {
    final b = await archive.read(n);
    if (b != null) images.add((name: n, bytes: b));
  }
  return galleryDoc(images);
}
