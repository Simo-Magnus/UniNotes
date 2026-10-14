import 'dart:typed_data';

/// Lettore minimo di Compound File Binary (OLE2), il contenitore dei
/// vecchi file Office (.doc .xls .ppt) e di altri formati Microsoft:
/// settori, FAT, DIFAT, mini-stream e directory. Solo lettura.
class Cfb {
  Cfb(Uint8List bytes) : _b = bytes, _d = ByteData.sublistView(bytes) {
    if (!isCfb(bytes)) throw const FormatException('Non è un file OLE2');
    _sectorSize = 1 << _d.getUint16(0x1E, Endian.little);
    _miniSize = 1 << _d.getUint16(0x20, Endian.little);
    final fatCount = _d.getUint32(0x2C, Endian.little);
    final dirStart = _d.getUint32(0x30, Endian.little);
    _miniCutoff = _d.getUint32(0x38, Endian.little);
    final miniFatStart = _d.getUint32(0x3C, Endian.little);
    var difatSector = _d.getUint32(0x44, Endian.little);
    final difatCount = _d.getUint32(0x48, Endian.little);
    if (_sectorSize != 512 && _sectorSize != 4096) {
      throw const FormatException('Dimensione dei settori non valida');
    }

    // Settori della FAT: 109 nell'intestazione, gli altri nella catena DIFAT.
    final fatSectors = <int>[];
    for (var i = 0; i < 109 && fatSectors.length < fatCount; i++) {
      final s = _d.getUint32(0x4C + i * 4, Endian.little);
      if (s < _maxReg) fatSectors.add(s);
    }
    final per = _sectorSize ~/ 4;
    for (
      var n = 0;
      n < difatCount && difatSector < _maxReg && fatSectors.length < fatCount;
      n++
    ) {
      final off = _offset(difatSector);
      if (off + _sectorSize > _b.length) break;
      for (var i = 0; i < per - 1 && fatSectors.length < fatCount; i++) {
        final s = _d.getUint32(off + i * 4, Endian.little);
        if (s < _maxReg) fatSectors.add(s);
      }
      difatSector = _d.getUint32(off + (per - 1) * 4, Endian.little);
    }
    _fat = Uint32List(fatSectors.length * per);
    for (var i = 0; i < fatSectors.length; i++) {
      final off = _offset(fatSectors[i]);
      for (var j = 0; j < per; j++) {
        final p = off + j * 4;
        _fat[i * per + j] = p + 4 <= _b.length
            ? _d.getUint32(p, Endian.little)
            : _endOfChain;
      }
    }

    // Directory.
    final dir = _chain(dirStart);
    for (var i = 0; i + 128 <= dir.length; i += 128) {
      final nameLen = dir[i + 0x40] | (dir[i + 0x41] << 8);
      final chars = <int>[];
      for (var k = 0; k + 1 < nameLen - 2 && k < 64; k += 2) {
        chars.add(dir[i + k] | (dir[i + k + 1] << 8));
      }
      final bd = ByteData.sublistView(dir, i, i + 128);
      entries.add(
        CfbEntry(
          String.fromCharCodes(chars),
          dir[i + 0x42],
          bd.getUint32(0x74, Endian.little),
          bd.getUint32(0x78, Endian.little),
          left: bd.getUint32(0x44, Endian.little),
          right: bd.getUint32(0x48, Endian.little),
          child: bd.getUint32(0x4C, Endian.little),
        ),
      );
    }
    final root = entries.isEmpty ? null : entries.first;
    if (root != null) _ministream = _chain(root.start, root.size);
    _miniFat = _readU32List(_chain(miniFatStart));
  }

  static const _endOfChain = 0xFFFFFFFE;
  static const _maxReg = 0xFFFFFFFA;

  final Uint8List _b;
  final ByteData _d;
  late final int _sectorSize;
  late final int _miniSize;
  late final int _miniCutoff;
  late final Uint32List _fat;
  late final Uint32List _miniFat;
  Uint8List _ministream = Uint8List(0);
  final entries = <CfbEntry>[];

  static bool isCfb(List<int> b) =>
      b.length >= 512 &&
      b[0] == 0xD0 &&
      b[1] == 0xCF &&
      b[2] == 0x11 &&
      b[3] == 0xE0 &&
      b[4] == 0xA1 &&
      b[5] == 0xB1 &&
      b[6] == 0x1A &&
      b[7] == 0xE1;

  int _offset(int sector) => (sector + 1) * _sectorSize;

  static Uint32List _readU32List(Uint8List b) {
    final d = ByteData.sublistView(b);
    final out = Uint32List(b.length ~/ 4);
    for (var i = 0; i < out.length; i++) {
      out[i] = d.getUint32(i * 4, Endian.little);
    }
    return out;
  }

  /// Catena di settori a partire da [start] (con [size] tronca il risultato).
  Uint8List _chain(int start, [int? size]) {
    final out = BytesBuilder(copy: false);
    var s = start;
    final seen = <int>{};
    while (s < _maxReg && s < _fat.length && seen.add(s)) {
      final off = _offset(s);
      if (off >= _b.length) break;
      final end = off + _sectorSize > _b.length ? _b.length : off + _sectorSize;
      out.add(Uint8List.sublistView(_b, off, end));
      if (size != null && out.length >= size) break;
      s = _fat[s];
    }
    final all = out.takeBytes();
    return size != null && all.length > size
        ? Uint8List.sublistView(all, 0, size)
        : all;
  }

  Uint8List _miniChain(int start, int size) {
    final out = BytesBuilder(copy: false);
    var s = start;
    final seen = <int>{};
    while (s < _maxReg &&
        s < _miniFat.length &&
        seen.add(s) &&
        out.length < size) {
      final off = s * _miniSize;
      if (off + _miniSize > _ministream.length) break;
      out.add(Uint8List.sublistView(_ministream, off, off + _miniSize));
      s = _miniFat[s];
    }
    final all = out.takeBytes();
    return all.length > size ? Uint8List.sublistView(all, 0, size) : all;
  }

  /// Nomi dei flussi (stream) nel file.
  List<String> get streamNames => [
    for (final e in entries)
      if (e.type == 2) e.name,
  ];

  /// Contenuto del flusso [name] (il primo con quel nome), o null.
  Uint8List? stream(String name) {
    final lower = name.toLowerCase();
    for (final e in entries) {
      if (e.type == 2 && e.name.toLowerCase() == lower) {
        return e.size < _miniCutoff
            ? _miniChain(e.start, e.size)
            : _chain(e.start, e.size);
      }
    }
    return null;
  }
}

class CfbEntry {
  CfbEntry(
    this.name,
    this.type,
    this.start,
    this.size, {
    required this.left,
    required this.right,
    required this.child,
  });
  final String name;

  /// 1 = cartella, 2 = flusso, 5 = radice.
  final int type;
  final int start;
  final int size;
  final int left;
  final int right;
  final int child;
}
