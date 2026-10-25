import 'dart:convert';
import 'dart:io' show RawZLibFilter, gzip;
import 'dart:math' as math;
import 'dart:typed_data';

/// Registro dei dati dell'app di un dispositivo (file
/// `Dati/<dispositivo>.json.gz` nella cartella cloud dell'app): per ogni
/// tabella le righe con identificativo stabile, i valori, l'orario
/// dell'ultima modifica di ogni colonna e, per le righe eliminate, l'orario
/// dell'eliminazione. L'unione ([mergeSnapshots]) non dipende dall'ordine
/// dei registri ed è idempotente: ogni dispositivo che unisce gli stessi
/// registri arriva agli stessi dati. Vedi `docs/sincronizzazione_dati.md`.
class SyncEntry {
  SyncEntry({Map<String, Object?>? values, Map<String, int>? times, this.deleted})
    : values = values ?? {},
      times = times ?? {};

  /// Valori delle colonne (numeri, testo o null; i riferimenti ad altre
  /// righe sono i loro identificativi).
  final Map<String, Object?> values;

  /// Ultima modifica di ogni colonna (millisecondi dal 1970).
  final Map<String, int> times;

  /// Orario dell'eliminazione (null = mai eliminata).
  int? deleted;

  /// Ultima modifica di una qualsiasi colonna.
  int get latest => times.values.fold(-1, math.max);

  /// La riga esiste: ha valori e nessuna eliminazione più recente
  /// dell'ultima modifica (a parità di orario vince la riga).
  bool get alive => values.isNotEmpty && (deleted == null || latest >= deleted!);

  SyncEntry copy() => SyncEntry(
    values: Map.of(values),
    times: Map.of(times),
    deleted: deleted,
  );

  Object toJson() {
    final t = times.values.toSet();
    return {
      if (values.isNotEmpty) 'v': values,
      // stesso orario per tutte le colonne: un numero solo
      if (values.isNotEmpty) 't': t.length == 1 ? t.first : times,
      'd': ?deleted,
    };
  }

  static SyncEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final v = j['v'];
    final values = <String, Object?>{};
    if (v is Map) {
      for (final e in v.entries) {
        final x = e.value;
        // solo valori semplici (un file modificato a mano non entra nel
        // database con oggetti o liste); un numero infinito («1e999») non
        // si può riscrivere in JSON: l'unione fallirebbe a ogni sincronizzazione
        if (x == null || x is String || (x is num && x.isFinite)) {
          values['${e.key}'] = x;
        }
      }
    }
    final times = <String, int>{};
    final t = j['t'];
    if (t is num) {
      for (final c in values.keys) {
        times[c] = t.isFinite ? t.toInt() : 0;
      }
    } else if (t is Map) {
      for (final c in values.keys) {
        final x = t[c];
        times[c] = x is num && x.isFinite ? x.toInt() : 0;
      }
    } else {
      for (final c in values.keys) {
        times[c] = 0;
      }
    }
    final d = j['d'];
    return SyncEntry(
      values: values,
      times: times,
      deleted: d is num && d.isFinite ? d.toInt() : null,
    );
  }
}

class SyncSnapshot {
  SyncSnapshot({
    Map<String, Map<String, SyncEntry>>? tables,
    this.device,
    this.installId,
  }) : tables = tables ?? {};

  static const format = 'uninotes-sync';
  static const version = 1;

  /// tabella → identificativo → riga.
  final Map<String, Map<String, SyncEntry>> tables;

  /// Nome e identificativo del dispositivo che ha scritto il registro.
  final String? device;
  final String? installId;

  Map<String, SyncEntry> table(String t) => tables.putIfAbsent(t, () => {});

  SyncEntry? entry(String t, String id) => tables[t]?[id];

  int get rowCount =>
      tables.values.fold(0, (n, t) => n + t.values.where((e) => e.alive).length);

  /// JSON con tabelle e righe in ordine: stessi dati, stessi byte (il file
  /// non cambia, e non si ricarica, se i dati non cambiano).
  String encodeJson() {
    final t = <String, Object?>{};
    for (final name in tables.keys.toList()..sort()) {
      final rows = tables[name]!;
      if (rows.isEmpty) continue;
      t[name] = {
        for (final id in rows.keys.toList()..sort()) id: rows[id]!.toJson(),
      };
    }
    return jsonEncode({
      'format': format,
      'version': version,
      'device': ?device,
      'installId': ?installId,
      'tables': t,
    });
  }

  List<int> encode() => gzip.encode(utf8.encode(encodeJson()));

  /// Registro da [bytes] (gzip o JSON semplice); null se non è un registro
  /// di UniNotes o è di una versione futura.
  static SyncSnapshot? decode(List<int> bytes) {
    try {
      final raw = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
          ? gunzipLimited(bytes, maxDecodedBytes)
          : bytes;
      if (raw.length > maxDecodedBytes) return null;
      return fromJson(jsonDecode(utf8.decode(raw)));
    } catch (_) {
      return null;
    }
  }

  /// Dimensione massima di un registro decompresso. Quelli veri sono di
  /// pochi MB; un file manipolato nella cartella cloud (pochi KB che
  /// diventano GB, «gzip bomb») esaurirebbe la memoria e chiuderebbe l'app a
  /// ogni sincronizzazione: oltre il limite il registro si ignora.
  static int maxDecodedBytes = 256 * 1024 * 1024;

  /// gzip decompresso a pezzi, fermandosi oltre [limit] byte
  /// ([FormatException]): la memoria usata non supera mai il limite di molto.
  static Uint8List gunzipLimited(List<int> data, int limit) {
    final filter = RawZLibFilter.inflateFilter(gzip: true);
    final out = BytesBuilder(copy: false);
    void drain({bool end = false}) {
      while (true) {
        final part = filter.processed(end: end);
        if (part == null) return;
        out.add(part);
        if (out.length > limit) {
          throw const FormatException('registro troppo grande');
        }
      }
    }

    const chunk = 64 * 1024;
    for (var o = 0; o < data.length; o += chunk) {
      filter.process(data, o, o + chunk < data.length ? o + chunk : data.length);
      drain();
    }
    drain(end: true);
    return out.takeBytes();
  }

  static SyncSnapshot? fromJson(Object? j) {
    if (j is! Map || j['format'] != format) return null;
    final v = j['version'];
    if (v is! num || v.toInt() < 1 || v.toInt() > version) return null;
    final out = SyncSnapshot(
      device: j['device'] is String ? j['device'] as String : null,
      installId: j['installId'] is String ? j['installId'] as String : null,
    );
    final tables = j['tables'];
    if (tables is! Map) return out;
    for (final t in tables.entries) {
      final rows = t.value;
      if (rows is! Map) continue;
      final table = out.table('${t.key}');
      for (final r in rows.entries) {
        final e = SyncEntry.fromJson(r.value);
        if (e != null) table['${r.key}'] = e;
      }
    }
    return out;
  }
}

/// Unione di due valori della stessa colonna con lo stesso orario: vince
/// sempre lo stesso su ogni dispositivo (testo JSON maggiore).
bool _wins(Object? a, Object? b) =>
    jsonEncode(a).compareTo(jsonEncode(b)) > 0;

bool sameValue(Object? a, Object? b) => a == b;

/// Valore di una colonna che si unisce in modo speciale (es. insiemi);
/// null = regola normale (vince la modifica più recente).
typedef FieldMerger =
    Object? Function(
      String table,
      String id,
      String column,
      List<Object?> values,
    );

/// Unione dei registri: per ogni riga e colonna vince il valore modificato
/// per ultimo (a parità di orario un criterio fisso, uguale ovunque);
/// l'eliminazione più recente vale se è successiva a ogni modifica, e allora
/// la riga resta solo come segnaposto «eliminato» datato. Commutativa,
/// associativa e idempotente.
SyncSnapshot mergeSnapshots(
  Iterable<SyncSnapshot> inputs, {
  FieldMerger? special,
  String? device,
  String? installId,
}) {
  final out = SyncSnapshot(device: device, installId: installId);
  final list = inputs.toList();
  final names = {for (final s in list) ...s.tables.keys};
  for (final t in names) {
    final ids = {
      for (final s in list) ...?s.tables[t]?.keys,
    };
    final table = out.table(t);
    for (final id in ids) {
      final versions = [for (final s in list) ?s.tables[t]?[id]];
      table[id] = _mergeEntry(t, id, versions, special);
    }
  }
  return out;
}

SyncEntry _mergeEntry(
  String table,
  String id,
  List<SyncEntry> versions,
  FieldMerger? special,
) {
  final out = SyncEntry();
  for (final v in versions) {
    final d = v.deleted;
    if (d != null && (out.deleted == null || d > out.deleted!)) out.deleted = d;
    for (final c in v.values.keys) {
      final t = v.times[c] ?? 0;
      final value = v.values[c];
      if (!out.times.containsKey(c)) {
        out.times[c] = t;
        out.values[c] = value;
        continue;
      }
      final cur = out.times[c]!;
      if (t > cur ||
          (t == cur && !sameValue(value, out.values[c]) &&
              _wins(value, out.values[c]))) {
        out.times[c] = t;
        out.values[c] = value;
      }
    }
  }
  if (special != null) {
    for (final c in out.values.keys.toList()) {
      final merged = special(table, id, c, [
        for (final v in versions)
          if (v.values.containsKey(c)) v.values[c],
      ]);
      if (merged != null) out.values[c] = merged;
    }
  }
  if (!out.alive) {
    // eliminata: resta il segnaposto datato
    out.values.clear();
    out.times.clear();
  }
  return out;
}
