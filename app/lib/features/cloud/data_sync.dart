import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/database/app_database.dart';
import '../../core/database/sync_schema.dart';
import 'data_sync_snapshot.dart';

export 'data_sync_snapshot.dart';

/// Esito di un'unione dei dati con una cartella cloud.
class DataMergeResult {
  const DataMergeResult({
    required this.applied,
    required this.ownChanged,
    required this.devices,
    required this.firstJoin,
  });

  /// Righe aggiunte, modificate o eliminate su questo dispositivo.
  final int applied;

  /// Il registro di questo dispositivo è cambiato (da caricare).
  final bool ownChanged;

  /// Registri di altri dispositivi letti.
  final int devices;

  /// Primo collegamento di questo dispositivo a dati già presenti nel cloud.
  final bool firstJoin;
}

/// Sincronizzazione dei dati dell'app (database locale) tra i dispositivi
/// collegati allo stesso OneDrive o Google Drive. Vedi
/// `docs/sincronizzazione_dati.md`.
///
/// Ogni dispositivo scrive solo il proprio registro (`Dati/<nome>.json.gz`,
/// [SyncSnapshot]) con tutte le righe delle tabelle sincronizzate
/// ([SyncSchema.tables]) e legge quelli degli altri, che il motore dei file
/// ([CloudDriveService]) porta e riporta come qualsiasi altro file. Unione
/// ([mergeFolder]):
/// 1. righe di questo dispositivo, con l'orario di modifica di ogni colonna:
///    quello della base (ultima unione) se il valore non è cambiato, quello
///    della riga (trigger) se è cambiato;
/// 2. unione con i registri degli altri ([mergeSnapshots]): righe nuove
///    aggiunte, per ogni colonna vince la modifica più recente, eliminazioni
///    con segnaposto datato; le sessioni di studio hanno identificativi
///    propri e quindi si sommano;
/// 3. il risultato si applica al database in una transazione e diventa la
///    nuova base e il registro di questo dispositivo.
/// Due dispositivi che scrivono insieme non si sovrascrivono mai (ognuno ha
/// il suo file) e unire di nuovo gli stessi registri non cambia nulla.
class DataSync {
  DataSync(
    this._db, {
    Future<Directory> Function()? stateDir,
    this.notesRoot,
    this.onApplied,
  }) : _stateDir = stateDir ?? getApplicationSupportDirectory;

  final AppDatabase _db;
  final Future<Directory> Function() _stateDir;

  /// Cartella degli appunti (percorsi degli allegati collegati agli appunti).
  final Future<String> Function()? notesRoot;

  /// Dopo un'unione che ha cambiato il database (aggiornare le schermate).
  final FutureOr<void> Function()? onApplied;

  /// Base: risultato dell'ultima unione su questo dispositivo, comune a
  /// OneDrive e Google Drive (il nome rientra nello «stato della
  /// sincronizzazione» che «Elimina dati» toglie).
  static const baseName = 'dati_sync_base.json.gz';

  /// Estensione dei registri nella cartella `Dati`.
  static const extension = '.json.gz';

  /// Prefisso dei percorsi relativi alla cartella degli appunti.
  static const notesPrefix = 'appunti:';

  Future<File> _baseFile() async =>
      File(p.join((await _stateDir()).path, baseName));

  /// Un'unione alla volta (OneDrive e Google Drive possono sincronizzare
  /// insieme).
  Future<void> _lock = Future.value();

  Future<T> _locked<T>(Future<T> Function() f) {
    final run = _lock.then((_) => f());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  String? _signature;

  /// Impronta delle tabelle sincronizzate (righe, ultima modifica,
  /// eliminazioni): se non cambia dall'ultima unione non c'è nulla di nuovo
  /// da scrivere.
  Future<String> _currentSignature() async {
    final db = _db.db;
    final parts = <String>[];
    for (final s in SyncSchema.tables) {
      // impostazioni: solo quelle sincronizzate (le altre cambiano spesso,
      // es. l'esito dell'ultima sincronizzazione)
      final where = s.table == 'app_settings'
          ? ' WHERE ${SyncSchema.syncedSettingSql('key')}'
          : '';
      try {
        final r = await db.rawQuery(
          'SELECT COUNT(*) AS n, MAX(ABS(sync_mtime)) AS m FROM ${s.table}'
          '$where',
        );
        parts.add('${r.first['n']}:${r.first['m']}');
      } on DatabaseException {
        parts.add('-');
      }
    }
    try {
      final r = await db.rawQuery(
        'SELECT COUNT(*) AS n, MAX(deleted_at) AS m FROM ${SyncSchema.tombstones}',
      );
      parts.add('${r.first['n']}:${r.first['m']}');
    } on DatabaseException {
      parts.add('-');
    }
    return parts.join('|');
  }

  /// Ci sono modifiche ai dati dall'ultima unione (o non ce n'è ancora
  /// stata una in questa sessione).
  Future<bool> hasLocalChanges() async =>
      _signature == null || await _currentSignature() != _signature;

  /// C'è già stata almeno un'unione su questo dispositivo.
  Future<bool> hasBase() async => (await _baseFile()).exists();

  /// Nome del registro di questo dispositivo.
  static String ownFileName(String deviceName, String installId) {
    final safe = '$deviceName $installId'
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '$safe$extension';
  }

  /// Unisce il database con i registri nella cartella locale [dir] (copia
  /// della cartella `Dati` sul servizio) e riscrive [ownName], il registro
  /// di questo dispositivo.
  Future<DataMergeResult> mergeFolder(
    Directory dir, {
    required String ownName,
    String? device,
    String? installId,
  }) => _locked(() async {
    await dir.create(recursive: true);
    final baseFile = await _baseFile();
    final base = await baseFile.exists()
        ? SyncSnapshot.decode(await baseFile.readAsBytes())
        : null;
    final remotes = <SyncSnapshot>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith(extension)) continue;
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      // il proprio registro conta solo senza base (dati eliminati o app
      // reinstallata su questo dispositivo: si riprendono dal cloud)
      if (name == ownName && base != null) continue;
      final s = SyncSnapshot.decode(await e.readAsBytes());
      if (s == null) continue;
      if (base != null && installId != null && s.installId == installId) {
        continue;
      }
      remotes.add(s);
    }
    final firstJoin = base == null && remotes.isNotEmpty;
    final root = await notesRoot?.call();
    late SyncSnapshot merged;
    var applied = 0;
    await _db.db.transaction((txn) async {
      await SyncSchema.dedupe(txn);
      final ctx = await _Ctx.load(txn, root);
      final local = await _export(txn, ctx, base, firstJoin: firstJoin);
      merged = mergeSnapshots(
        [local, ...remotes],
        special: _union,
        device: device,
        installId: installId,
      );
      applied = await _apply(txn, ctx, merged);
      // le eliminazioni sono ora nel registro (e quelle fatte qui sopra
      // vengono dall'unione stessa)
      await txn.delete(SyncSchema.tombstones);
    });
    final bytes = merged.encode();
    await _writeAtomic(baseFile, bytes);
    final own = File(p.join(dir.path, ownName));
    var ownChanged = true;
    if (await own.exists()) {
      final old = SyncSnapshot.decode(await own.readAsBytes());
      ownChanged = old == null || old.encodeJson() != merged.encodeJson();
    }
    if (ownChanged) await _writeAtomic(own, bytes);
    _signature = await _currentSignature();
    if (applied > 0) await onApplied?.call();
    return DataMergeResult(
      applied: applied,
      ownChanged: ownChanged,
      devices: remotes.length,
      firstJoin: firstJoin,
    );
  });

  static Future<void> _writeAtomic(File f, List<int> bytes) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  /// Impostazioni che sono insiemi: unione delle righe di tutte le versioni.
  static Object? _union(
    String table,
    String id,
    String column,
    List<Object?> values,
  ) {
    if (table != 'app_settings' ||
        column != 'value' ||
        !SyncSchema.unionSettings.contains(id)) {
      return null;
    }
    final all = <String>{
      for (final v in values)
        if (v is String)
          for (final x in v.split('\n'))
            if (x.trim().isNotEmpty) x.trim(),
    };
    return (all.toList()..sort()).join('\n');
  }

  // ------------------------------------------------------------- export

  /// Stato locale come registro: righe del database con gli orari per
  /// colonna, righe della base non presenti qui (non applicabili, es. il
  /// loro insegnamento manca) ed eliminazioni fatte qui.
  Future<SyncSnapshot> _export(
    Transaction txn,
    _Ctx ctx,
    SyncSnapshot? base, {
    required bool firstJoin,
  }) async {
    final out = SyncSnapshot();
    final tombs = <String, Map<String, int>>{};
    // senza base le eliminazioni precedenti non riguardano nessun altro
    // dispositivo (o vengono da «Elimina dati»): non si propagano
    if (base != null) {
      for (final r in await txn.query(SyncSchema.tombstones)) {
        tombs.putIfAbsent(r['tbl'] as String, () => {})[r['sync_id']
            as String] = (r['deleted_at'] as num).toInt();
      }
    }
    for (final s in SyncSchema.tables) {
      final cols = ctx.columns[s.table];
      if (cols == null) continue;
      final data = _syncedColumns(s, cols);
      final table = out.table(s.table);
      for (final row in ctx.rows[s.table]!) {
        final id = ctx.idOf(s, row);
        if (id == null || !_wanted(s, id)) continue;
        final m = (row['sync_mtime'] as num?)?.toInt() ?? 0;
        final stamp = m > 0 ? m : (firstJoin ? 0 : -m);
        final b = base?.entry(s.table, id);
        final bAlive = b != null && b.alive;
        final e = SyncEntry(deleted: b?.deleted);
        for (final c in data) {
          final v = _exportValue(s, c, row[c], ctx);
          if (v is _Skip) continue;
          if (bAlive && b.values.containsKey(c) && sameValue(b.values[c], v)) {
            e.values[c] = v;
            e.times[c] = b.times[c] ?? stamp;
            continue;
          }
          final ref = s.refs[c];
          if (bAlive &&
              ref != null &&
              v == null &&
              b.values[c] is String &&
              !ctx.resolvable(ref, b.values[c] as String)) {
            // riferimento a una riga che qui non c'è (es. argomento
            // eliminato): non è una modifica di questo dispositivo
            e.values[c] = b.values[c];
            e.times[c] = b.times[c] ?? stamp;
            continue;
          }
          e.values[c] = v;
          e.times[c] = stamp;
        }
        if (bAlive) {
          // colonne di una versione più recente dell'app: restano
          for (final c in b.values.keys) {
            if (e.values.containsKey(c) || cols.contains(c)) continue;
            e.values[c] = b.values[c];
            e.times[c] = b.times[c] ?? 0;
          }
        }
        // la riga c'è: un'eliminazione precedente fatta qui non vale più
        if (e.deleted != null && e.latest < e.deleted!) {
          final at = e.deleted!;
          for (final c in e.times.keys) {
            if (e.times[c]! < at) e.times[c] = at;
          }
        }
        table[id] = e;
      }
      final localTombs = tombs[s.table] ?? const {};
      for (final entry in base?.tables[s.table]?.entries ??
          const <MapEntry<String, SyncEntry>>[]) {
        if (table.containsKey(entry.key)) continue;
        final e = entry.value.copy();
        final t = localTombs[entry.key];
        if (t != null && (e.deleted == null || t > e.deleted!)) e.deleted = t;
        table[entry.key] = e;
      }
      for (final t in localTombs.entries) {
        if (!table.containsKey(t.key)) {
          table[t.key] = SyncEntry(deleted: t.value);
        }
      }
    }
    return out;
  }

  static bool _wanted(SyncTableSpec s, String id) =>
      s.table != 'app_settings' || SyncSchema.isSyncedSetting(id);

  /// Colonne della riga che vanno nel registro.
  static List<String> _syncedColumns(SyncTableSpec s, List<String> cols) => [
    for (final c in SyncSchema.dataColumns(s, cols))
      if (c != s.key && !s.localOnly.contains(c)) c,
  ];

  Object? _exportValue(SyncTableSpec s, String c, Object? v, _Ctx ctx) {
    final ref = s.refs[c];
    if (ref != null) {
      if (v == null) return null;
      return ctx.syncIdOf(ref, (v as num).toInt());
    }
    if (s.notePaths.contains(c) && v is String && ctx.notesRoot != null) {
      final root = ctx.notesRoot!;
      if (p.isWithin(root, v)) {
        return '$notesPrefix${p.split(p.relative(v, from: root)).join('/')}';
      }
      return v;
    }
    if (v == null || v is num || v is String) return v;
    return const _Skip();
  }

  // ------------------------------------------------------------- apply

  /// Applica [merged] al database: prima le eliminazioni (figli prima dei
  /// genitori), poi aggiunte e modifiche (genitori prima dei figli).
  /// Restituisce le righe toccate.
  Future<int> _apply(Transaction txn, _Ctx ctx, SyncSnapshot merged) async {
    var n = 0;
    for (final s in SyncSchema.tables.reversed) {
      if (!ctx.columns.containsKey(s.table) || !s.syncDeletes) continue;
      final rows = merged.tables[s.table];
      if (rows == null) continue;
      for (final id in rows.keys.toList()..sort()) {
        if (rows[id]!.alive || !_wanted(s, id)) continue;
        final local = ctx.rowById(s, id);
        if (local == null) continue;
        n += await txn.delete(
          s.table,
          where: 'rowid = ?',
          whereArgs: [local[_Ctx.rowid]],
        );
        ctx.forget(s, id);
      }
    }
    for (final s in SyncSchema.tables) {
      final cols = ctx.columns[s.table];
      final rows = merged.tables[s.table];
      if (cols == null || rows == null) continue;
      final data = _syncedColumns(s, cols).toSet();
      for (final id in rows.keys.toList()..sort()) {
        final e = rows[id]!;
        if (!e.alive || !_wanted(s, id)) continue;
        final local = ctx.rowById(s, id);
        final want = <String, Object?>{};
        var skip = false;
        for (final c in e.values.keys) {
          if (!data.contains(c)) continue;
          final v = _importValue(s, c, e.values[c], ctx);
          if (v is _Unresolved) {
            // riga puntata assente: colonna obbligatoria → la riga non si
            // importa (resta nel registro); facoltativa → vuota
            if (!v.nullable) {
              if (local == null) skip = true;
              continue;
            }
            want[c] = null;
            continue;
          }
          want[c] = v;
        }
        if (skip) continue;
        final mtime = e.latest < 1 ? 1 : e.latest;
        if (local == null) {
          // stessa riga del database dei corsi con un altro identificativo
          // (es. insegnamento sostituito): si collega a quella, senza doppioni
          final ext = want['external_id'];
          if (cols.contains('external_id') && ext is String) {
            final same = await txn.query(
              s.table,
              columns: ['id'],
              where: 'external_id = ?',
              whereArgs: [ext],
            );
            if (same.isNotEmpty) {
              ctx.alias(s, id, (same.first['id'] as num).toInt());
              continue;
            }
          }
          final row = {
            ...want,
            if (s.hasSyncId) 'sync_id': id else s.key!: ctx.keyValue(s, id),
            'sync_mtime': mtime,
          };
          try {
            final rowid = await txn.insert(s.table, row);
            ctx.remember(s, id, rowid, row);
            n++;
          } on DatabaseException {
            // vincolo non rispettato (dato incompleto): resta nel registro
          }
          continue;
        }
        final changed = <String, Object?>{
          for (final c in want.keys)
            if (!sameValue(local[c], want[c])) c: want[c],
        };
        if (changed.isEmpty) continue;
        try {
          await txn.update(
            s.table,
            {...changed, 'sync_mtime': mtime},
            where: 'rowid = ?',
            whereArgs: [local[_Ctx.rowid]],
          );
          local.addAll(changed);
          n++;
        } on DatabaseException {
          // es. external_id già usato da un'altra riga: resta com'è
        }
      }
    }
    return n;
  }

  Object? _importValue(SyncTableSpec s, String c, Object? v, _Ctx ctx) {
    final ref = s.refs[c];
    if (ref != null) {
      if (v == null) return null;
      final local = v is String ? ctx.localIdOf(ref, v) : null;
      return local ?? _Unresolved(ref.nullable);
    }
    if (s.notePaths.contains(c) &&
        v is String &&
        v.startsWith(notesPrefix) &&
        ctx.notesRoot != null) {
      final rel = v.substring(notesPrefix.length).split('/');
      if (rel.any((x) => x.isEmpty || x == '.' || x == '..')) return null;
      final full = p.joinAll([ctx.notesRoot!, ...rel]);
      return p.isWithin(ctx.notesRoot!, full) ? full : null;
    }
    return v;
  }
}

/// Valore da non mettere nel registro (tipo non supportato).
class _Skip {
  const _Skip();
}

/// Riferimento a una riga che su questo dispositivo non c'è.
class _Unresolved {
  const _Unresolved(this.nullable);
  final bool nullable;
}

/// Righe e corrispondenze fra identificativi locali e del registro, lette
/// una volta per unione (dentro la transazione).
class _Ctx {
  _Ctx(this.notesRoot);

  /// Nome della colonna con il rowid nelle righe lette (con una chiave
  /// INTEGER PRIMARY KEY SQLite chiamerebbe «rowid» come la chiave).
  static const rowid = '_sync_rowid';

  final String? notesRoot;
  final Map<String, List<String>> columns = {};
  final Map<String, List<Map<String, Object?>>> rows = {};

  /// tabella → identificativo del registro → riga (modificabile).
  final Map<String, Map<String, Map<String, Object?>>> _byId = {};

  /// tabella → id locale → identificativo del registro (e viceversa).
  final Map<String, Map<int, String>> _toSync = {};
  final Map<String, Map<String, int>> _toLocal = {};

  static Future<_Ctx> load(Transaction txn, String? notesRoot) async {
    final ctx = _Ctx(notesRoot);
    for (final s in SyncSchema.tables) {
      final cols = await SyncSchema.columnsOf(txn, s.table);
      if (cols.isEmpty) continue;
      ctx.columns[s.table] = cols;
      final list = [
        for (final r in await txn.rawQuery(
          'SELECT rowid AS $rowid, * FROM ${s.table}',
        ))
          Map<String, Object?>.of(r),
      ];
      ctx.rows[s.table] = list;
      final byId = ctx._byId[s.table] = {};
      final toSync = ctx._toSync[s.table] = {};
      final toLocal = ctx._toLocal[s.table] = {};
      for (final r in list) {
        final id = ctx.idOf(s, r);
        if (id == null) continue;
        byId[id] = r;
        if (s.hasSyncId) {
          final local = (r['id'] as num).toInt();
          toSync[local] = id;
          toLocal[id] = local;
        }
      }
    }
    // luoghi pubblici: identificati dall'external_id
    final toSync = ctx._toSync['places'] = {};
    final toLocal = ctx._toLocal['places'] = {};
    try {
      for (final r in await txn.query('places', columns: ['id', 'external_id'])) {
        final id = (r['id'] as num).toInt();
        final ext = r['external_id'] as String;
        toSync[id] = ext;
        toLocal[ext] = id;
      }
    } on DatabaseException {
      // tabella assente
    }
    return ctx;
  }

  String? idOf(SyncTableSpec s, Map<String, Object?> row) {
    if (s.hasSyncId) return row['sync_id'] as String?;
    final v = row[s.key];
    return v == null ? null : '$v';
  }

  Object keyValue(SyncTableSpec s, String id) =>
      (s.key == 'id' || s.key == 'year') ? (int.tryParse(id) ?? id) : id;

  Map<String, Object?>? rowById(SyncTableSpec s, String id) =>
      _byId[s.table]?[id];

  String? syncIdOf(SyncRef ref, int local) => _toSync[ref.table]?[local];

  int? localIdOf(SyncRef ref, String id) => _toLocal[ref.table]?[id];

  bool resolvable(SyncRef ref, String id) => localIdOf(ref, id) != null;

  void remember(SyncTableSpec s, String id, int row, Map<String, Object?> r) {
    _byId[s.table]![id] = {...r, rowid: row, if (s.hasSyncId) 'id': row};
    if (s.hasSyncId) {
      _toSync[s.table]![row] = id;
      _toLocal[s.table]![id] = row;
    }
  }

  /// [id] del registro è la riga locale [local] (stesso external_id).
  void alias(SyncTableSpec s, String id, int local) {
    _toLocal[s.table]![id] = local;
  }

  void forget(SyncTableSpec s, String id) {
    _byId[s.table]?.remove(id);
    final local = _toLocal[s.table]?.remove(id);
    if (local != null) _toSync[s.table]?.remove(local);
  }
}
