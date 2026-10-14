import 'dart:convert';
import 'dart:typed_data';

import '../reader_document.dart';
import 'ebooks.dart' show DrmKind, DrmProtectedException;
import 'zip_util.dart';

/// Kindle KFX (.kfx, .kfx-zip, .kpf): estrazione del testo, al meglio.
///
/// I KFX acquistati sono quasi sempre protetti da DRM ("\xeaDRMION\xee"):
/// l'app non può e non deve toglierlo, si spiega di usare l'app Kindle.
/// Quelli senza DRM sono un contenitore ("CONT", o un database SQLite nei
/// .kpf di Kindle Create) di frammenti in Amazon Ion binario (specifica
/// Ion 1.0 pubblica): si leggono tutti i valori Ion e si raccolgono le
/// liste di testi dei frammenti di contenuto ($145, campo $146), nell'ordine
/// in cui compaiono. Limiti: niente immagini, stili, indice né ordine di
/// lettura ricostruito dalle "storyline"; i testi sono paragrafi semplici.

const _drmion = [0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E, 0xEE];
const _bvm = [0xE0, 0x01, 0x00, 0xEA];

bool _at(Uint8List b, int o, List<int> s) {
  if (o < 0 || o + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[o + i] != s[i]) return false;
  }
  return true;
}

bool isKfxDrm(Uint8List b) => _at(b, 0, _drmion);

/// Simbolo Ion (id nella tabella dei simboli).
class _Sym {
  const _Sym(this.sid);
  final int sid;
}

class _IonError implements Exception {
  const _IonError();
}

/// Lettore minimo di Ion binario 1.0.
class _Ion {
  _Ion(this.b, this.pos, this.end);
  final Uint8List b;
  int pos;
  final int end;

  int _byte() {
    if (pos >= end) throw const _IonError();
    return b[pos++];
  }

  int varUInt() {
    var v = 0;
    for (var i = 0; i < 9; i++) {
      final c = _byte();
      v = (v << 7) | (c & 0x7F);
      if (c & 0x80 != 0) return v;
    }
    throw const _IonError();
  }

  int _uint(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | _byte();
    }
    return v;
  }

  /// Un valore; [annotations] riceve le annotazioni (es. la tabella dei
  /// simboli, $3) del valore.
  Object? value([List<int>? annotations]) {
    final td = _byte();
    final t = td >> 4;
    var l = td & 0x0F;
    if (t == 0xE && l == 0) {
      // Marcatore di versione (BVM): E0 01 00 EA.
      pos += 3;
      return value(annotations);
    }
    if (l == 15) return null;
    if (t == 1) return l != 0;
    if (l == 14 || (t == 13 && l == 1)) l = varUInt();
    final stop = pos + l;
    if (stop > end) throw const _IonError();
    Object? out;
    switch (t) {
      case 0: // riempimento
        out = null;
      case 2:
        out = l > 7 ? null : _uint(l);
      case 3:
        out = l > 7 ? null : -_uint(l);
      case 7:
        out = _Sym(l > 7 ? 0 : _uint(l));
      case 8:
        out = utf8.decode(
          Uint8List.sublistView(b, pos, stop),
          allowMalformed: true,
        );
      case 11 || 12:
        final list = <Object?>[];
        while (pos < stop) {
          list.add(value());
        }
        out = list;
      case 13:
        final map = <int, Object?>{};
        while (pos < stop) {
          final field = varUInt();
          map[field] = value();
        }
        out = map;
      case 14:
        final alen = varUInt();
        final aend = pos + alen;
        final ann = <int>[];
        while (pos < aend) {
          ann.add(varUInt());
        }
        annotations?.addAll(ann);
        out = value();
      default: // decimali, date, float, blob, clob
        out = null;
    }
    pos = stop;
    return out;
  }
}

/// Testi dei frammenti di contenuto ($146: lista di stringhe) in [v].
void _collect(Object? v, List<String> out, List<List<String>> lists) {
  if (v is Map<int, Object?>) {
    final content = v[146];
    if (content is List &&
        content.isNotEmpty &&
        content.every((e) => e is String)) {
      out.addAll(content.cast<String>());
    }
    for (final e in v.values) {
      if (!identical(e, content)) _collect(e, out, lists);
    }
  } else if (v is List) {
    if (v.length >= 2 && v.every((e) => e is String)) {
      lists.add(v.cast<String>());
    }
    for (final e in v) {
      _collect(e, out, lists);
    }
  }
}

/// Paragrafi da tutti i valori Ion che seguono un marcatore di versione.
List<String> _ionTexts(Uint8List b) {
  final out = <String>[];
  final lists = <List<String>>[];
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] != 0xE0 || !_at(b, i, _bvm)) continue;
    final r = _Ion(b, i + 4, b.length);
    while (r.pos < b.length && !_at(b, r.pos, _bvm)) {
      final start = r.pos;
      try {
        final ann = <int>[];
        final v = r.value(ann);
        // Tabelle dei simboli ($3): sono nomi, non testo.
        if (!ann.contains(3)) _collect(v, out, lists);
      } on _IonError {
        r.pos = start + 1;
        break;
      } on RangeError {
        break;
      }
    }
    i = r.pos - 1;
  }
  if (out.isEmpty) {
    // Ripiego: liste di frasi (testi lunghi), se mancano i frammenti $145.
    for (final l in lists) {
      final total = l.fold(0, (s, t) => s + t.length);
      if (total / l.length > 25) out.addAll(l);
    }
  }
  return out;
}

RDoc parseKfx(Uint8List bytes) {
  if (isKfxDrm(bytes)) throw const DrmProtectedException(kind: DrmKind.kfx);
  final texts = <String>[];
  final zip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B
      ? Zip.tryOpen(bytes)
      : null;
  if (zip != null) {
    // .kfx-zip / .kpf: i KFX o il database .kdf dentro l'archivio.
    for (final n in zip.names) {
      final b = zip.bytes(n);
      if (b == null) continue;
      if (isKfxDrm(b) || n.toLowerCase().contains('voucher')) {
        throw const DrmProtectedException(kind: DrmKind.kfx);
      }
      texts.addAll(_ionTexts(b));
    }
  } else {
    texts.addAll(_ionTexts(bytes));
  }
  final blocks = <RBlock>[
    for (final t in texts)
      for (final p in t.split('\n'))
        if (p.trim().isNotEmpty) RPara.text(p.trim()),
  ];
  if (blocks.isEmpty) {
    throw const FormatException(
      'nessun testo trovato nel file KFX (senza DRM ma di un tipo non '
      'riconosciuto)',
    );
  }
  return RDoc(
    sections: [RSection('', blocks)],
    notice:
        'Testo estratto dal KFX (senza immagini, stili e indice). Per la '
        'resa completa usa l\'app Kindle.',
  );
}
