import 'dart:convert';
import 'dart:typed_data';

import '../reader_document.dart';

/// OneNote (.one): estrazione in sola lettura di testo e immagini.
///
/// Il formato (MS-ONESTORE/MS-ONE, specifiche aperte di Microsoft) è un
/// archivio di revisioni con oggetti e proprietà. Qui si usa un'euristica
/// documentata invece di ricostruire le revisioni:
/// - testo: i valori delle proprietà RichEditTextUnicode e
///   TextExtendedAscii sono memorizzati come "lunghezza a 4 byte seguita
///   dai dati" (UTF-16LE o ASCII esteso): si cercano questi blocchi e si
///   tengono quelli che sembrano testo (lettere, punteggiatura), scartando
///   nomi di caratteri, stili e lingue;
/// - immagini e allegati: gli oggetti FileDataStoreObject sono racchiusi
///   da due GUID noti (intestazione e coda); in più si cercano PNG e JPEG
///   incorporati direttamente.
/// Tutto in ordine di posizione nel file (di solito l'ordine della pagina).
/// Non si ricostruiscono pagine, sezioni annidate, tabelle né disegni.

/// {7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}: sezione OneNote (.one).
const _oneGuid = [
  0xE4, 0x52, 0x5C, 0x7B, 0x8C, 0xD8, 0xA7, 0x4D, //
  0xAE, 0xB1, 0x53, 0x78, 0xD0, 0x29, 0x96, 0xD3,
];

/// {43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}: indice del blocco (.onetoc2).
const _tocGuid = [
  0xA1, 0x2F, 0xFF, 0x43, 0xD9, 0xEF, 0x76, 0x4C, //
  0x9E, 0xE2, 0x10, 0xEA, 0x57, 0x22, 0x76, 0x5F,
];

/// {BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}: inizio di FileDataStoreObject.
const _fileDataHeader = [
  0xE7, 0x16, 0xE3, 0xBD, 0x65, 0x26, 0x11, 0x45, //
  0xA4, 0xC4, 0x8D, 0x4D, 0x0B, 0x7A, 0x9E, 0xAC,
];

bool _at(Uint8List b, int o, List<int> s) {
  if (o < 0 || o + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[o + i] != s[i]) return false;
  }
  return true;
}

bool isOneNoteSection(Uint8List b) => _at(b, 0, _oneGuid);
bool isOneNoteToc(Uint8List b) => _at(b, 0, _tocGuid);

/// Nomi che compaiono come testo ma sono impostazioni (caratteri, stili,
/// lingue): non sono contenuto.
const _noise = {
  'calibri', 'calibri light', 'arial', 'times new roman', 'segoe ui', //
  'segoe ui light', 'cambria', 'cambria math', 'consolas', 'courier new',
  'verdana', 'tahoma', 'aptos', 'aptos display', 'georgia', 'wingdings',
  'symbol', 'helvetica', 'pagetitle', 'page title', 'normal', 'heading 1',
  'heading 2', 'heading 3', 'heading 4', 'heading 5', 'heading 6',
  'citation', 'quote', 'code', 'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'cite', 'blockquote', 'titolo 1', 'titolo 2', 'titolo 3', 'citazione',
};

final _langTag = RegExp(r'^[a-z]{2,3}(-[A-Za-z]{2,4})*$');
final _guidLike = RegExp(r'^\{?[0-9A-Fa-f-]{20,}\}?$');

/// Testo plausibile: lettere e cifre in maggioranza, niente controlli.
bool _plausible(String s) {
  final t = s.trim();
  if (t.isEmpty) return false;
  var letters = 0, bad = 0;
  for (final r in t.runes) {
    if (r == 9 || r == 10 || r == 11 || r == 13) continue;
    if (r < 0x20 || (r >= 0x7F && r < 0xA0) || r == 0xFFFD) {
      bad++;
    } else if (r >= 0xD800 && r <= 0xDFFF) {
      bad++;
    } else if (r >= 0xE000 && r <= 0xF8FF) {
      bad++;
    } else if ((r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A) ||
        (r >= 0x30 && r <= 0x39) ||
        (r >= 0xC0 && r <= 0x24F) ||
        (r >= 0x370 && r <= 0x52F) ||
        (r >= 0x4E00 && r <= 0x9FFF)) {
      letters++;
    }
  }
  if (bad > 0) return false;
  if (letters * 2 < t.runes.length) return false;
  final lower = t.toLowerCase();
  if (_noise.contains(lower)) return false;
  if (t.length <= 12 && _langTag.hasMatch(t)) return false;
  if (_guidLike.hasMatch(t)) return false;
  return true;
}

class _Item {
  _Item(this.offset, {this.text, this.image});
  final int offset;
  final String? text;
  final Uint8List? image;
}

/// Fine di un PNG (dopo il blocco IEND), o −1.
int _pngEnd(Uint8List b, int start) {
  var p = start + 8;
  while (p + 12 <= b.length) {
    final len = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    if (len < 0 || p + 12 + len > b.length) return -1;
    if (_at(b, p + 4, const [0x49, 0x45, 0x4E, 0x44])) return p + 12 + len;
    p += 12 + len;
  }
  return -1;
}

/// Fine di un JPEG: segmenti fino a SOS, poi i dati fino a FFD9.
int _jpegEnd(Uint8List b, int start) {
  var p = start + 2;
  while (p + 4 <= b.length) {
    if (b[p] != 0xFF) return -1;
    final m = b[p + 1];
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01) {
      p += 2;
      continue;
    }
    final len = (b[p + 2] << 8) | b[p + 3];
    if (m == 0xDA) {
      p += 2 + len;
      while (p + 1 < b.length) {
        if (b[p] == 0xFF && b[p + 1] == 0xD9) return p + 2;
        p++;
      }
      return -1;
    }
    p += 2 + len;
  }
  return -1;
}

/// Tipo di un allegato dai primi byte (immagine mostrabile o PDF).
String? _kind(Uint8List b) {
  if (_at(b, 0, const [0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (_at(b, 0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (_at(b, 0, const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (_at(b, 0, const [0x42, 0x4D])) return 'bmp';
  if (_at(b, 0, const [0x25, 0x50, 0x44, 0x46])) return 'pdf';
  return null;
}

/// Sezione OneNote → documento (testo e immagini in ordine).
RDoc parseOneNote(Uint8List b, {String title = ''}) {
  if (isOneNoteToc(b)) {
    return RDoc(
      sections: [
        RSection(title, [
          RPara.text(
            'Questo è l\'indice del blocco appunti (.onetoc2): le pagine sono '
            'nei file .one delle sezioni, nella stessa cartella.',
          ),
        ]),
      ],
    );
  }
  final items = <_Item>[];
  // Intervalli già usati (dati di file e immagini), aggiunti in ordine
  // crescente da ciascuno dei due passaggi: ricerca binaria invece di
  // scorrerli tutti per ogni byte (sezioni di centinaia di MB con migliaia
  // di immagini).
  final covered = <(int, int)>[];
  final coveredImages = <(int, int)>[];
  bool within(List<(int, int)> list, int o) {
    var lo = 0, hi = list.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final r = list[mid];
      if (o < r.$1) {
        hi = mid - 1;
      } else if (o >= r.$2) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  bool inside(int o) => within(covered, o) || within(coveredImages, o);
  final d = ByteData.sublistView(b);
  var attachments = 0;
  // Oggetti FileDataStoreObject: GUID, lunghezza (8), 12 byte, dati.
  for (var i = 0; i + 36 <= b.length; i++) {
    if (b[i] != 0xE7 || !_at(b, i, _fileDataHeader)) continue;
    final len = d.getUint64(i + 16, Endian.little);
    final s = i + 36;
    if (len <= 0 || s + len > b.length) continue;
    final data = Uint8List.sublistView(b, s, s + len);
    final k = _kind(data);
    if (k == 'pdf' || k == null) {
      attachments++;
    } else {
      items.add(_Item(i, image: Uint8List.fromList(data)));
    }
    covered.add((i, s + len));
    i = s + len - 1;
  }
  // PNG e JPEG incorporati direttamente.
  for (var i = 0; i + 8 < b.length; i++) {
    final c = b[i];
    if (c != 0x89 && c != 0xFF) continue;
    if (inside(i)) continue;
    int end = -1;
    if (c == 0x89 && _at(b, i, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) {
      end = _pngEnd(b, i);
    } else if (c == 0xFF && _at(b, i, const [0xFF, 0xD8, 0xFF])) {
      end = _jpegEnd(b, i);
    }
    if (end > i + 64) {
      items.add(_Item(i, image: Uint8List.fromList(b.sublist(i, end))));
      coveredImages.add((i, end));
      i = end - 1;
    }
  }
  // Testo: lunghezza a 4 byte + UTF-16LE (o ASCII esteso).
  final seen = <String>{};
  for (var i = 0; i + 8 < b.length; i++) {
    final len = d.getUint32(i, Endian.little);
    if (len < 2 || len > 200000 || i + 4 + len > b.length) continue;
    if (inside(i)) continue;
    final s = i + 4;
    String? text;
    final u0 = b[s] | (b[s + 1] << 8);
    if (len.isEven && u0 >= 0x20 && u0 < 0xD800) {
      final units = Uint16List(len ~/ 2);
      for (var k = 0; k < units.length; k++) {
        units[k] = b[s + 2 * k] | (b[s + 2 * k + 1] << 8);
      }
      var t = String.fromCharCodes(units);
      if (t.endsWith('\u0000')) t = t.substring(0, t.length - 1);
      if (!t.contains('\u0000') && _plausible(t)) text = t;
    }
    if (text == null && len >= 3 && b[s] >= 0x20 && b[s] != 0x7F) {
      // Testo ASCII esteso: nessun byte nullo, almeno una parola.
      var ok = true;
      for (var k = 0; k < len; k++) {
        final c = b[s + k];
        if (c == 0 || (c < 0x20 && c != 9 && c != 10 && c != 13 && c != 11)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        final t = latin1.decode(Uint8List.sublistView(b, s, s + len));
        if (_plausible(t) && t.contains(RegExp(r'[A-Za-zÀ-ÿ]{2}'))) text = t;
      }
    }
    if (text == null) continue;
    final clean = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u000B', '\n')
        .trim();
    // Lo stesso testo compare in più revisioni: una volta sola.
    if (clean.isEmpty || !seen.add(clean)) {
      i = s + len - 1;
      continue;
    }
    items.add(_Item(i, text: clean));
    i = s + len - 1;
  }
  items.sort((a, c) => a.offset.compareTo(c.offset));
  final blocks = <RBlock>[];
  for (final it in items) {
    if (it.image != null) {
      blocks.add(RImage(it.image!));
    } else {
      for (final para in it.text!.split('\n')) {
        if (para.trim().isNotEmpty) blocks.add(RPara.text(para.trim()));
      }
    }
  }
  if (blocks.isEmpty) {
    blocks.add(
      RPara.text(
        'Nessun testo riconoscibile in questa sezione OneNote.',
        style: RStyle.caption,
      ),
    );
  }
  return RDoc(
    sections: [RSection(title, blocks)],
    notice:
        'Testo e immagini estratti dalla sezione OneNote, senza '
        'impaginazione${attachments > 0 ? ' ($attachments allegati non mostrati)' : ''}. '
        'Per le pagine complete usa OneNote.',
  );
}
