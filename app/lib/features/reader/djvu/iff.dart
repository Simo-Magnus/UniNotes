/// Contenitore IFF 85 dei file DjVu: blocchi con identificatore di 4
/// caratteri e lunghezza a 32 bit (big endian); i blocchi "FORM" ne
/// contengono altri e hanno un secondo identificatore (DJVU, DJVM, DJVI,
/// THUM).
library;

import 'dart:typed_data';

class IffChunk {
  IffChunk._(
    this.id,
    this.buffer,
    this.headerOffset,
    this.start,
    this.length, {
    this.formType,
    List<IffChunk>? children,
  }) : children = children ?? const [];

  /// "FORM", "INFO", "Sjbz", ...
  final String id;
  final Uint8List buffer;

  /// Posizione dell'intestazione del blocco nel file.
  final int headerOffset;

  /// Inizio e lunghezza del contenuto (per i FORM, dopo il secondo
  /// identificatore).
  final int start;
  final int length;

  /// Secondo identificatore dei FORM ("DJVU", "DJVM", ...).
  final String? formType;
  final List<IffChunk> children;

  int get end => start + length;

  Uint8List get bytes => Uint8List.sublistView(buffer, start, end);

  /// Nome completo: "FORM:DJVU" o l'identificatore.
  String get kind => formType == null ? id : '$id:$formType';

  IffChunk? child(String id) {
    for (final c in children) {
      if (c.id == id) return c;
    }
    return null;
  }

  Iterable<IffChunk> all(String id) => children.where((c) => c.id == id);

  static bool _isForm(String id) =>
      id == 'FORM' || id == 'LIST' || id == 'PROP' || id == 'CAT ';

  /// Blocco con intestazione in [offset].
  static IffChunk parse(Uint8List buffer, int offset, [int? limit]) {
    final max = limit ?? buffer.length;
    if (offset + 8 > max) {
      throw const FormatException('Blocco IFF troncato');
    }
    final id = String.fromCharCodes(buffer, offset, offset + 4);
    final d = ByteData.sublistView(buffer, offset + 4, offset + 8);
    var len = d.getUint32(0);
    var start = offset + 8;
    // File troncato: si legge il possibile.
    if (start + len > max) len = max - start;
    if (!_isForm(id)) return IffChunk._(id, buffer, offset, start, len);
    if (len < 4) throw const FormatException('FORM senza tipo');
    final type = String.fromCharCodes(buffer, start, start + 4);
    final end = start + len;
    start += 4;
    final kids = <IffChunk>[];
    var pos = start;
    while (pos + 8 <= end) {
      final c = parse(buffer, pos, end);
      kids.add(c);
      pos = c.end;
      if (pos.isOdd) pos++;
    }
    return IffChunk._(
      id,
      buffer,
      offset,
      start,
      end - start,
      formType: type,
      children: kids,
    );
  }
}

/// File DjVu: "AT&T" seguito da un blocco FORM.
IffChunk parseDjvuFile(Uint8List bytes) {
  if (bytes.length < 16 ||
      String.fromCharCodes(bytes, 0, 4) != 'AT&T' ||
      String.fromCharCodes(bytes, 4, 8) != 'FORM') {
    throw const FormatException('Non è un file DjVu');
  }
  return IffChunk.parse(bytes, 4);
}

/// Interi big endian dei blocchi DjVu.
int be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int be24(Uint8List b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
int be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
