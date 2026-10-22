import 'dart:typed_data';

import '../reader_document.dart';
import 'cfb.dart';
import 'ooxml.dart' show excelDate, formatNumber;
import 'text_formats.dart';

/// Vecchi formati binari di Office 97–2003 (.doc .xls .ppt): solo testo,
/// estratto dai flussi del contenitore OLE2.

/// Documento protetto da password: il testo è cifrato.
class EncryptedDocumentException implements Exception {
  const EncryptedDocumentException();
  @override
  String toString() => 'Documento protetto da password';
}

const kLegacyNotice =
    'Formato Office 97–2003: mostrato solo il testo. Per impaginazione e '
    'immagini usa "Apri con…".';

/// Tipo di documento Office dentro un contenitore OLE2, dai nomi dei flussi.
String? legacyKind(Cfb cfb) {
  final names = cfb.streamNames.map((n) => n.toLowerCase()).toSet();
  if (names.contains('worddocument')) return '.doc';
  if (names.contains('workbook') || names.contains('book')) return '.xls';
  if (names.contains('powerpoint document')) return '.ppt';
  return null;
}

// ---------------------------------------------------------------- Word

/// Testo di un documento Word 97–2003 (.doc): FIB → CLX (tabella dei
/// pezzi) nel flusso 0Table/1Table → caratteri del testo principale.
RDoc parseDoc(Uint8List bytes) {
  final cfb = Cfb(bytes);
  final word = cfb.stream('WordDocument');
  if (word == null || word.length < 0x200) {
    throw const FormatException('Flusso WordDocument mancante');
  }
  final d = ByteData.sublistView(word);
  final ident = d.getUint16(0, Endian.little);
  if (ident != 0xA5EC && ident != 0xA5DC) {
    throw const FormatException('Documento Word non riconosciuto');
  }
  final nFib = d.getUint16(2, Endian.little);
  final flags = d.getUint16(0x0A, Endian.little);
  if (flags & 0x0100 != 0) throw const EncryptedDocumentException();
  final text = StringBuffer();

  if (nFib < 0x00C1) {
    // Word 6/95: testo a 8 bit tra fcMin e fcMac.
    final fcMin = d.getUint32(0x18, Endian.little);
    final fcMac = d.getUint32(0x1C, Endian.little);
    if (fcMin < fcMac && fcMac <= word.length) {
      text.write(decodeCp1252(word.sublist(fcMin, fcMac)));
    }
  } else {
    final table = cfb.stream(flags & 0x0200 != 0 ? '1Table' : '0Table');
    // Offset nella FIB: base 32 byte, poi fibRgW, fibRgLw e fibRgFcLcb.
    var o = 32;
    final csw = d.getUint16(o, Endian.little);
    o += 2 + csw * 2;
    final cslw = d.getUint16(o, Endian.little);
    final lw = o + 2;
    final ccpText = d.getUint32(lw + 3 * 4, Endian.little);
    o = lw + cslw * 4;
    final fcLcb = o + 2;
    final fcClx = d.getUint32(fcLcb + 33 * 8, Endian.little);
    final lcbClx = d.getUint32(fcLcb + 33 * 8 + 4, Endian.little);
    if (table == null || fcClx + lcbClx > table.length || lcbClx == 0) {
      throw const FormatException('Tabella dei pezzi mancante');
    }
    final clx = ByteData.sublistView(table, fcClx, fcClx + lcbClx);
    var p = 0;
    // Prc (formattazione) da saltare, poi Pcdt.
    while (p < clx.lengthInBytes && clx.getUint8(p) == 0x01) {
      p += 3 + clx.getInt16(p + 1, Endian.little);
    }
    if (p >= clx.lengthInBytes || clx.getUint8(p) != 0x02) {
      throw const FormatException('CLX non valido');
    }
    final lcb = clx.getUint32(p + 1, Endian.little);
    final plc = p + 5;
    final n = (lcb - 4) ~/ 12;
    var remaining = ccpText;
    for (var i = 0; i < n && remaining > 0; i++) {
      final cpStart = clx.getUint32(plc + i * 4, Endian.little);
      final cpEnd = clx.getUint32(plc + (i + 1) * 4, Endian.little);
      final pcd = plc + (n + 1) * 4 + i * 8;
      final fcRaw = clx.getUint32(pcd + 2, Endian.little);
      final compressed = fcRaw & 0x40000000 != 0;
      final fc = fcRaw & 0x3FFFFFFF;
      var count = cpEnd - cpStart;
      if (count > remaining) count = remaining;
      remaining -= count;
      if (compressed) {
        final start = fc ~/ 2;
        final end = (start + count).clamp(0, word.length);
        text.write(decodeCp1252(word.sublist(start, end)));
      } else {
        final end = (fc + count * 2).clamp(0, word.length);
        text.write(decodeUtf16(word, fc, end, littleEndian: true));
      }
    }
  }
  return RDoc(
    sections: [RSection('', wordTextBlocks(text.toString()))],
    notice: kLegacyNotice,
  );
}

/// Testo Word con i caratteri speciali (paragrafi, celle, campi) → blocchi.
List<RBlock> wordTextBlocks(String raw) {
  final out = <RBlock>[];
  final para = StringBuffer();
  final cells = <String>[];
  var tableId = -1;
  RTable? table;
  final tables = <RTable>[];
  var fieldDepth = 0;
  var fieldCode = <bool>[]; // true finché siamo nel codice del campo
  var lastWasCell = false;

  void endPara() {
    final t = para.toString().trim();
    para.clear();
    if (t.isNotEmpty) out.add(RPara.text(t));
  }

  for (final c in raw.codeUnits) {
    if (fieldDepth > 0 &&
        fieldCode.isNotEmpty &&
        fieldCode.last &&
        c != 0x14 &&
        c != 0x15 &&
        c != 0x13) {
      continue;
    }
    switch (c) {
      case 0x13: // inizio campo
        fieldDepth++;
        fieldCode = [...fieldCode, true];
      case 0x14: // separatore: segue il risultato
        if (fieldCode.isNotEmpty) fieldCode[fieldCode.length - 1] = false;
      case 0x15: // fine campo
        if (fieldDepth > 0) fieldDepth--;
        if (fieldCode.isNotEmpty) fieldCode.removeLast();
      case 0x0D:
        if (cells.isNotEmpty || lastWasCell) {
          para.write('\n');
        } else {
          endPara();
        }
      case 0x07: // fine cella; due di fila = fine riga
        if (lastWasCell && para.isEmpty) {
          if (table == null) {
            tableId = tables.length;
            table = RTable([]);
            tables.add(table);
          }
          table.fit(cells);
          out.add(RTableRow(List.of(cells), table: tableId));
          cells.clear();
          lastWasCell = false;
          continue;
        }
        cells.add(para.toString().trim());
        para.clear();
        lastWasCell = true;
        continue;
      case 0x0B:
        para.write('\n');
      case 0x0C:
        endPara();
      case 0x09:
        para.write('\t');
      case 0x1E:
        para.write('-');
      case 0x1F || 0x01 || 0x08 || 0x02 || 0x05 || 0x03 || 0x04:
        break;
      case 0xA0:
        para.write(' ');
      default:
        if (c >= 0x20) para.writeCharCode(c);
    }
    if (c != 0x0D) lastWasCell = false;
    if (cells.isEmpty && c == 0x0D) table = null;
  }
  endPara();
  return out;
}

// ---------------------------------------------------------- PowerPoint

class _PptText {
  _PptText(this.type, this.text);
  final int type;
  final String text;
}

/// Testo di una presentazione PowerPoint 97–2003 (.ppt): atomi di testo
/// (TextCharsAtom/TextBytesAtom) per diapositiva, nell'ordine della
/// presentazione.
RDoc parsePpt(Uint8List bytes) {
  final cfb = Cfb(bytes);
  final doc = cfb.stream('PowerPoint Document');
  if (doc == null) throw const FormatException('Flusso PowerPoint mancante');
  if (cfb.stream('EncryptedSummary') != null) {
    throw const EncryptedDocumentException();
  }
  final d = ByteData.sublistView(doc);

  // Directory delle parti persistenti: persistId → posizione nel flusso.
  final persist = <int, int>{};
  final user = cfb.stream('Current User');
  try {
    if (user != null && user.length >= 20) {
      final u = ByteData.sublistView(user);
      var edit = u.getUint32(16, Endian.little);
      final seen = <int>{};
      while (edit > 0 && edit + 8 + 28 <= doc.length && seen.add(edit)) {
        if (d.getUint16(edit + 2, Endian.little) != 0x0FF5) break;
        final lastEdit = d.getUint32(edit + 8 + 8, Endian.little);
        final dirOff = d.getUint32(edit + 8 + 12, Endian.little);
        if (dirOff + 8 <= doc.length &&
            d.getUint16(dirOff + 2, Endian.little) == 0x1772) {
          final len = d.getUint32(dirOff + 4, Endian.little);
          var p = dirOff + 8;
          final end = dirOff + 8 + len;
          while (p + 4 <= end && end <= doc.length) {
            final h = d.getUint32(p, Endian.little);
            final id = h & 0xFFFFF;
            final count = h >> 20;
            p += 4;
            for (var k = 0; k < count && p + 4 <= end; k++) {
              persist.putIfAbsent(id + k, () => d.getUint32(p, Endian.little));
              p += 4;
            }
          }
        }
        edit = lastEdit;
      }
    }
  } catch (_) {
    persist.clear();
  }

  // Atomi di testo dentro un record (ricorsivo nei contenitori).
  void texts(int start, int end, List<_PptText> out) {
    var p = start;
    var type = 4;
    while (p + 8 <= end) {
      final verInst = d.getUint16(p, Endian.little);
      final recType = d.getUint16(p + 2, Endian.little);
      final len = d.getUint32(p + 4, Endian.little);
      final body = p + 8;
      if (body + len > end) break;
      if ((verInst & 0xF) == 0xF) {
        texts(body, body + len, out);
      } else if (recType == 0x0F9F && len >= 4) {
        type = d.getUint32(body, Endian.little);
      } else if (recType == 0x0FA0) {
        out.add(
          _PptText(
            type,
            decodeUtf16(doc, body, body + len, littleEndian: true),
          ),
        );
      } else if (recType == 0x0FA8) {
        out.add(
          _PptText(type, String.fromCharCodes(doc.sublist(body, body + len))),
        );
      }
      p = body + len;
    }
  }

  int? recordEnd(int at) {
    if (at + 8 > doc.length) return null;
    final len = d.getUint32(at + 4, Endian.little);
    return at + 8 + len <= doc.length ? at + 8 + len : null;
  }

  // Elenco delle diapositive (SlideListWithText, istanza 0).
  final slides = <List<_PptText>>[];
  void scan(int start, int end) {
    var p = start;
    while (p + 8 <= end) {
      final verInst = d.getUint16(p, Endian.little);
      final recType = d.getUint16(p + 2, Endian.little);
      final len = d.getUint32(p + 4, Endian.little);
      final body = p + 8;
      if (body + len > end) break;
      if (recType == 0x0FF0 && (verInst >> 4) == 0) {
        var q = body;
        List<_PptText>? current;
        var type = 4;
        while (q + 8 <= body + len) {
          final t = d.getUint16(q + 2, Endian.little);
          final l = d.getUint32(q + 4, Endian.little);
          final b = q + 8;
          if (t == 0x03F3) {
            current = <_PptText>[];
            slides.add(current);
            // Testo delle caselle nella diapositiva (forme non segnaposto).
            final ref = d.getUint32(b, Endian.little);
            final at = persist[ref];
            final e = at == null ? null : recordEnd(at);
            if (at != null &&
                e != null &&
                d.getUint16(at + 2, Endian.little) == 0x03EE) {
              texts(at + 8, e, current);
            }
          } else if (t == 0x0F9F && l >= 4) {
            type = d.getUint32(b, Endian.little);
          } else if (t == 0x0FA0 || t == 0x0FA8) {
            final s = t == 0x0FA0
                ? decodeUtf16(doc, b, b + l, littleEndian: true)
                : String.fromCharCodes(doc.sublist(b, b + l));
            if (current != null && !current.any((x) => x.text == s)) {
              current.add(_PptText(type, s));
            }
          }
          q = b + l;
        }
      } else if ((verInst & 0xF) == 0xF && recType == 0x03E8) {
        scan(body, body + len); // DocumentContainer
      }
      p = body + len;
    }
  }

  scan(0, doc.length);
  if (slides.isEmpty || slides.every((s) => s.isEmpty)) {
    // Nessun elenco: tutti i contenitori di diapositiva nell'ordine del flusso.
    slides.clear();
    var p = 0;
    while (p + 8 <= doc.length) {
      final recType = d.getUint16(p + 2, Endian.little);
      final len = d.getUint32(p + 4, Endian.little);
      if (p + 8 + len > doc.length) break;
      if (recType == 0x03EE) {
        final s = <_PptText>[];
        texts(p + 8, p + 8 + len, s);
        slides.add(s);
      }
      p += 8 + len;
    }
  }

  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  for (final s in slides) {
    final blocks = <RBlock>[];
    String? title;
    for (final t in s) {
      final text = t.text
          .replaceAll('\r', '\n')
          .replaceAll('\u000B', '\n')
          .trim();
      if (text.isEmpty || text == '*') continue;
      final isTitle = t.type == 0 || t.type == 6;
      if (isTitle) title ??= text.replaceAll('\n', ' ');
      if (isTitle) {
        blocks.add(RPara.text(text, style: RStyle.h2));
      } else {
        for (final line in text.split('\n')) {
          if (line.trim().isNotEmpty) {
            blocks.add(
              RPara.text(
                line.trim(),
                style: t.type == 1 || t.type == 7 || t.type == 8
                    ? RStyle.list
                    : RStyle.body,
                marker: t.type == 1 || t.type == 7 || t.type == 8 ? '•' : null,
              ),
            );
          }
        }
      }
    }
    final label = 'Diapositiva ${sections.length + 1}';
    sections.add(RSection(title == null ? label : '$label · $title', blocks));
    toc.add(RTocEntry(title ?? label, section: sections.length - 1));
  }
  // immagini della presentazione (senza la diapositiva in cui stanno)
  final pictures = pptPictures(cfb.stream('Pictures'));
  if (pictures.isNotEmpty) {
    sections.add(
      RSection('Immagini della presentazione', [
        for (final p in pictures) RImage(p),
      ]),
    );
    toc.add(
      RTocEntry('Immagini della presentazione', section: sections.length - 1),
    );
  }
  return RDoc(
    sections: sections,
    unitLabel: 'Diapositiva',
    toc: toc,
    notice: pictures.isEmpty
        ? kLegacyNotice
        : 'Formato PowerPoint 97–2003: mostrati il testo delle diapositive e, '
              'in fondo, le immagini. Per l\'impaginazione usa "Apri con…".',
  );
}

/// Immagini PNG, JPEG e TIFF del flusso "Pictures" di un PowerPoint 97–2003
/// (record OfficeArtBlip: intestazione di 8 byte, uno o due UID da 16 byte
/// secondo l'istanza, un byte di etichetta, poi l'immagine). EMF, WMF e PICT
/// si saltano (Flutter non li disegna).
List<Uint8List> pptPictures(Uint8List? data) {
  final out = <Uint8List>[];
  if (data == null) return out;
  var pos = 0;
  while (pos + 8 <= data.length && out.length < 500) {
    final verInst = data[pos] | (data[pos + 1] << 8);
    final type = data[pos + 2] | (data[pos + 3] << 8);
    final len =
        data[pos + 4] |
        (data[pos + 5] << 8) |
        (data[pos + 6] << 16) |
        (data[pos + 7] << 24);
    final start = pos + 8;
    final end = start + len;
    if (len < 0 || end > data.length || type < 0xF018 || type > 0xF117) break;
    final instance = verInst >> 4;
    // istanza dispari: due UID
    final skip = (instance.isOdd ? 32 : 16) + 1;
    if ((type == 0xF01D || type == 0xF01E || type == 0xF029 || type == 0xF02A) &&
        len > skip) {
      out.add(Uint8List.sublistView(data, start + skip, end));
    }
    pos = end;
  }
  return out;
}

// --------------------------------------------------------------- Excel

/// Lettore dei record BIFF (Excel 97–2003), con i CONTINUE uniti.
class _Biff {
  _Biff(this.b) : d = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData d;

  /// Record: (tipo, posizione, dati, confini dei CONTINUE nei dati).
  Iterable<({int type, int pos, Uint8List data, List<int> breaks})>
  records() sync* {
    var p = 0;
    while (p + 4 <= b.length) {
      final type = d.getUint16(p, Endian.little);
      final len = d.getUint16(p + 2, Endian.little);
      if (p + 4 + len > b.length) break;
      final pos = p;
      final data = BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(b, p + 4, p + 4 + len));
      final breaks = <int>[];
      p += 4 + len;
      while (p + 4 <= b.length && d.getUint16(p, Endian.little) == 0x003C) {
        final l = d.getUint16(p + 2, Endian.little);
        if (p + 4 + l > b.length) break;
        breaks.add(data.length);
        data.add(Uint8List.sublistView(b, p + 4, p + 4 + l));
        p += 4 + l;
      }
      yield (type: type, pos: pos, data: data.takeBytes(), breaks: breaks);
    }
  }
}

double _rk(int rk) {
  double v;
  if (rk & 0x02 != 0) {
    v = (rk >> 2).toSigned(30).toDouble();
  } else {
    final bd = ByteData(8)..setUint32(4, rk & 0xFFFFFFFC, Endian.little);
    v = bd.getFloat64(0, Endian.little);
  }
  return rk & 0x01 != 0 ? v / 100 : v;
}

/// Stringa BIFF8 (XLUnicodeString) in [data] da [p]; restituisce testo e
/// fine. [breaks]: confini dei CONTINUE, dove ricomincia il byte dei flag.
(String, int) _xlString(
  Uint8List data,
  int p,
  List<int> breaks, {
  bool lenByte = false,
  bool biff8 = true,
}) {
  final d = ByteData.sublistView(data);
  if (p >= data.length) return ('', p);
  int cch;
  if (lenByte) {
    cch = data[p];
    p += 1;
  } else {
    if (p + 2 > data.length) return ('', data.length);
    cch = d.getUint16(p, Endian.little);
    p += 2;
  }
  if (!biff8) {
    final end = (p + cch).clamp(0, data.length);
    return (decodeCp1252(data.sublist(p, end)), end);
  }
  if (p >= data.length) return ('', p);
  final flags = data[p++];
  var high = flags & 0x01 != 0;
  var runs = 0;
  var ext = 0;
  if (flags & 0x08 != 0) {
    runs = d.getUint16(p, Endian.little);
    p += 2;
  }
  if (flags & 0x04 != 0) {
    ext = d.getInt32(p, Endian.little);
    p += 4;
  }
  final out = StringBuffer();
  var read = 0;
  while (read < cch && p < data.length) {
    if (breaks.contains(p) && read > 0) {
      high = data[p] & 0x01 != 0;
      p++;
      continue;
    }
    if (high) {
      if (p + 2 > data.length) break;
      out.writeCharCode(d.getUint16(p, Endian.little));
      p += 2;
    } else {
      out.write(decodeCp1252([data[p]]));
      p += 1;
    }
    read++;
  }
  p += runs * 4 + ext;
  return (out.toString(), p);
}

/// Fogli di un file Excel 97–2003 (.xls, BIFF8; BIFF5 in parte): testi
/// condivisi (SST), etichette, numeri, RK, formule calcolate.
RDoc parseXls(Uint8List bytes) {
  final cfb = Cfb(bytes);
  final stream = cfb.stream('Workbook') ?? cfb.stream('Book');
  if (stream == null) throw const FormatException('Flusso Workbook mancante');
  final biff = _Biff(stream);
  final sst = <String>[];
  final sheets = <({int pos, String name})>[];
  final formats = <int, String>{};
  final xfFormat = <int>[];
  var biff8 = true;
  final data = <String, List<List<String>>>{};
  String? current;
  var inGlobals = true;
  int? pendingStringRow;
  int? pendingStringCol;

  bool isDate(int xf) {
    if (xf >= xfFormat.length) return false;
    final f = xfFormat[xf];
    if ((f >= 14 && f <= 22) || (f >= 45 && f <= 47)) return true;
    final code = (formats[f] ?? '')
        .replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]'), '')
        .toLowerCase();
    return RegExp(r'[dy]').hasMatch(code) || RegExp(r'h.*m').hasMatch(code);
  }

  void put(int row, int col, String v) {
    final rows = data[current];
    if (rows == null || row > 65535 || col > 255) return;
    while (rows.length <= row) {
      rows.add(<String>[]);
    }
    final r = rows[row];
    while (r.length <= col) {
      r.add('');
    }
    r[col] = v;
  }

  String num(double v, int xf) =>
      isDate(xf) ? excelDate(v, time: v != v.floorToDouble()) : formatNumber(v);

  for (final r in biff.records()) {
    final x = ByteData.sublistView(r.data);
    switch (r.type) {
      case 0x0809 || 0x0409 || 0x0209 || 0x0009: // BOF
        if (r.data.length >= 2) biff8 = x.getUint16(0, Endian.little) == 0x0600;
        if (!inGlobals) {
          final s = sheets.where((s) => s.pos == r.pos).firstOrNull;
          current = s?.name;
          if (current != null) data[current] = [];
        }
      case 0x000A: // EOF
        if (inGlobals) inGlobals = false;
        current = null;
      case 0x002F:
        throw const EncryptedDocumentException();
      case 0x0085: // BOUNDSHEET
        final pos = x.getUint32(0, Endian.little);
        final kind = r.data[5];
        final (name, _) = _xlString(
          r.data,
          6,
          r.breaks,
          lenByte: true,
          biff8: biff8,
        );
        if (kind == 0) sheets.add((pos: pos, name: name));
      case 0x041E: // FORMAT
        final id = x.getUint16(0, Endian.little);
        final (s, _) = biff8
            ? _xlString(r.data, 2, r.breaks)
            : _xlString(r.data, 2, r.breaks, lenByte: true, biff8: false);
        formats[id] = s;
      case 0x00E0: // XF
        if (r.data.length >= 4) xfFormat.add(x.getUint16(2, Endian.little));
      case 0x00FC: // SST
        final unique = x.getUint32(4, Endian.little);
        var p = 8;
        for (var i = 0; i < unique && p < r.data.length; i++) {
          final (s, end) = _xlString(r.data, p, r.breaks);
          sst.add(s);
          p = end;
        }
      case 0x00FD: // LABELSST
        if (current == null) break;
        final i = x.getUint32(6, Endian.little);
        put(
          x.getUint16(0, Endian.little),
          x.getUint16(2, Endian.little),
          i < sst.length ? sst[i] : '',
        );
      case 0x0204 || 0x00D6: // LABEL, RSTRING
        if (current == null) break;
        final (s, _) = _xlString(r.data, 6, r.breaks, biff8: biff8);
        put(x.getUint16(0, Endian.little), x.getUint16(2, Endian.little), s);
      case 0x0203: // NUMBER
        if (current == null) break;
        put(
          x.getUint16(0, Endian.little),
          x.getUint16(2, Endian.little),
          num(x.getFloat64(6, Endian.little), x.getUint16(4, Endian.little)),
        );
      case 0x027E: // RK
        if (current == null) break;
        put(
          x.getUint16(0, Endian.little),
          x.getUint16(2, Endian.little),
          num(
            _rk(x.getUint32(6, Endian.little)),
            x.getUint16(4, Endian.little),
          ),
        );
      case 0x00BD: // MULRK
        if (current == null) break;
        final row = x.getUint16(0, Endian.little);
        var col = x.getUint16(2, Endian.little);
        for (var p = 4; p + 6 <= r.data.length - 2; p += 6) {
          put(
            row,
            col++,
            num(
              _rk(x.getUint32(p + 2, Endian.little)),
              x.getUint16(p, Endian.little),
            ),
          );
        }
      case 0x0205: // BOOLERR
        if (current == null) break;
        final v = r.data[6];
        final err = r.data[7] == 1;
        put(
          x.getUint16(0, Endian.little),
          x.getUint16(2, Endian.little),
          err ? '#ERR' : (v == 1 ? 'VERO' : 'FALSO'),
        );
      case 0x0006: // FORMULA: risultato già calcolato
        if (current == null) break;
        final row = x.getUint16(0, Endian.little);
        final col = x.getUint16(2, Endian.little);
        if (x.getUint16(12, Endian.little) == 0xFFFF) {
          switch (r.data[6]) {
            case 0:
              pendingStringRow = row;
              pendingStringCol = col;
            case 1:
              put(row, col, r.data[8] == 1 ? 'VERO' : 'FALSO');
            case 2:
              put(row, col, '#ERR');
          }
        } else {
          put(
            row,
            col,
            num(x.getFloat64(6, Endian.little), x.getUint16(4, Endian.little)),
          );
        }
      case 0x0207: // STRING (risultato di formula)
        if (current == null || pendingStringRow == null) break;
        final (s, _) = _xlString(r.data, 0, r.breaks, biff8: biff8);
        put(pendingStringRow, pendingStringCol!, s);
        pendingStringRow = null;
    }
  }

  final tables = <RTable>[];
  final sections = <RSection>[];
  final toc = <RTocEntry>[];
  for (final s in sheets) {
    final rows = data[s.name] ?? <List<String>>[];
    for (final r in rows) {
      while (r.isNotEmpty && r.last.isEmpty) {
        r.removeLast();
      }
    }
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    sections.add(sheetSection(s.name, rows, tables));
    toc.add(RTocEntry(s.name, section: sections.length - 1));
  }
  return RDoc(
    sections: sections,
    unitLabel: 'Foglio',
    toc: toc,
    tabs: true,
    tables: tables,
    notice: kLegacyNotice,
  );
}
