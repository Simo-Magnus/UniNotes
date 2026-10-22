/// Metadati per la sincronizzazione dei dati tra i dispositivi (OneDrive,
/// Google Drive, vedi `lib/features/cloud/data_sync.dart` e
/// `docs/sincronizzazione_dati.md`).
///
/// Ogni tabella personale sincronizzata ha:
/// - `sync_id`: identificativo stabile della riga, uguale su tutti i
///   dispositivi (gli `id` locali sono numeri diversi su ognuno). Per le
///   righe del database dei corsi deriva dall'`external_id`, per moduli e
///   argomenti dal genitore e dal nome (gli stessi argomenti importati su due
///   dispositivi sono la stessa riga), per le sessioni di studio da inizio e
///   durata; le righe create a mano hanno un codice casuale. Le tabelle con
///   una chiave naturale (impostazioni, profilo, anni del piano, note sui
///   luoghi) usano quella e non hanno la colonna.
/// - `sync_mtime`: ultima modifica della riga su questo dispositivo, in
///   millisecondi dal 1970. Positivo = riga modificata dopo l'inserimento;
///   negativo = riga solo inserita (es. dall'import del database dei corsi),
///   così al primo collegamento i dati già nel cloud hanno la precedenza sui
///   valori iniziali di un dispositivo nuovo.
///
/// Trigger SQLite tengono aggiornati i due campi a ogni INSERT/UPDATE e
/// scrivono in `sync_tombstones` le righe eliminate: nessun repository deve
/// ricordarsene. Lo schema si prepara a ogni apertura del database
/// ([SyncSchema.ensure]), in modo idempotente e indipendente dal numero di
/// versione: le colonne si aggiungono solo se mancano (le migrazioni future
/// che aggiungono colonne sono coperte da sole, perché i trigger si rifanno
/// con l'elenco attuale delle colonne) e nessun dato viene cancellato.
library;

import 'package:sqflite/sqflite.dart';

/// Tabella sincronizzata.
class SyncTableSpec {
  const SyncTableSpec(
    this.table, {
    this.key,
    this.idSql,
    this.refs = const {},
    this.localOnly = const {},
    this.notePaths = const {},
    this.syncDeletes = true,
  }) : assert((key == null) != (idSql == null));

  /// false = le eliminazioni restano su questo dispositivo (profilo e anni
  /// del piano: «Rifai l'onboarding» su un dispositivo non deve togliere il
  /// percorso agli altri).
  final bool syncDeletes;

  final String table;

  /// Chiave naturale (tabelle senza `sync_id`).
  final String? key;

  /// Espressione SQL del `sync_id` di una riga nuova (con `NEW.`).
  final String? idSql;

  /// Colonne che puntano a un'altra tabella: nel registro valgono il suo
  /// `sync_id` (o, per i luoghi pubblici, l'`external_id`).
  final Map<String, SyncRef> refs;

  /// Colonne legate a questo dispositivo (percorsi assoluti): non si
  /// sincronizzano.
  final Set<String> localOnly;

  /// Colonne con il percorso di un file degli appunti: nel registro relativo
  /// alla cartella degli appunti, sul dispositivo assoluto.
  final Set<String> notePaths;

  bool get hasSyncId => key == null;

  /// Espressione SQL dell'identificativo della riga [alias] (`OLD`, `NEW` o
  /// il nome della tabella).
  String idOf(String alias) => switch (key) {
    null => '$alias.sync_id',
    final k => 'CAST($alias.$k AS TEXT)',
  };
}

/// Riferimento a un'altra tabella.
class SyncRef {
  const SyncRef(this.table, {this.column = 'sync_id', this.nullable = true});
  final String table;

  /// Colonna della tabella puntata che identifica la riga nel registro.
  final String column;

  /// false = colonna NOT NULL: senza la riga puntata la riga non si importa.
  final bool nullable;
}

abstract final class SyncSchema {
  /// Millisecondi dal 1970 in SQL.
  static const nowSql =
      "CAST(ROUND((julianday('now') - 2440587.5) * 86400000) AS INTEGER)";

  /// Codice casuale (righe create a mano).
  static const _rand = "lower(hex(randomblob(8)))";

  static const tombstones = 'sync_tombstones';

  /// Impostazioni sincronizzate: scelte di studio dello studente, uguali su
  /// tutti i dispositivi. Tutte le altre (aspetto, notifiche, account,
  /// percorsi, stato dei servizi, domande già fatte) restano del dispositivo.
  static const syncedSettings = {
    'exclusion_patterns',
    'focus_daily_goal',
    'focus_settings',
    'links_reference_ai',
    'removed_catalog_courses',
    'prefilled_modules',
    // ordine degli insegnamenti in Studio
    'study_course_order',
    // scelte delle notifiche (tipi e anticipi; il consenso e il permesso
    // restano del dispositivo)
    'notif_exams',
    'notif_exam_offsets',
    'notif_exam_hours',
    'notif_sessions',
    'notif_outcome',
    'notif_links',
    'notif_review',
    'notif_donation',
    'notif_previous_years',
    // formule dette a voce nella trascrizione istantanea
    'live_formulas',
    // dispositivo che scrive nel calendario di ogni account (un solo
    // dispositivo per account, gli altri leggono: niente doppioni)
    'syscal_writers',
  };

  /// Famiglie di impostazioni sincronizzate (per prefisso): posizione e
  /// segnalibri del lettore di ogni file dell'app (`reader:<chiave>`, chiave
  /// uguale su tutti i dispositivi per i file in libri/materiali/allegati) e
  /// risposte «Non chiedere più» (`dont_ask_…`).
  static const syncedSettingPrefixes = {'reader:', 'dont_ask_'};

  /// L'impostazione [key] si sincronizza fra i dispositivi.
  static bool isSyncedSetting(String key) =>
      syncedSettings.contains(key) ||
      syncedSettingPrefixes.any((p) => key.startsWith(p));

  /// Condizione SQL «impostazione sincronizzata» sulla colonna [column].
  static String syncedSettingSql(String column) => [
    '$column IN (${syncedSettings.map((k) => "'$k'").join(', ')})',
    for (final p in syncedSettingPrefixes)
      "substr($column, 1, ${p.length}) = '$p'",
  ].join(' OR ');

  /// Impostazioni che sono insiemi (una voce per riga): si uniscono invece
  /// di vincere l'ultima modifica (un insegnamento rimosso su un dispositivo
  /// resta rimosso anche se un altro ne rimuove un secondo).
  static const unionSettings = {'removed_catalog_courses', 'prefilled_modules'};

  /// Tabelle in ordine di dipendenza (i genitori prima).
  static const tables = <SyncTableSpec>[
    SyncTableSpec(
      'courses',
      idSql: "'c:' || COALESCE(NEW.external_id, '#' || $_rand)",
    ),
    SyncTableSpec(
      'events',
      idSql: "'e:' || COALESCE(NEW.external_id, '#' || $_rand)",
      refs: {
        'course_id': SyncRef('courses'),
        'place_id': SyncRef('places', column: 'external_id'),
      },
    ),
    SyncTableSpec(
      'exams',
      idSql: "'x:' || COALESCE(NEW.external_id, '#' || $_rand)",
      refs: {'course_id': SyncRef('courses')},
    ),
    SyncTableSpec(
      'modules',
      idSql:
          "'m:' || COALESCE((SELECT p.sync_id FROM courses p WHERE p.id = "
          "NEW.course_id), '#') || '/' || lower(trim(NEW.name))",
      refs: {'course_id': SyncRef('courses', nullable: false)},
    ),
    SyncTableSpec(
      'topics',
      idSql:
          "'t:' || COALESCE((SELECT p.sync_id FROM modules p WHERE p.id = "
          "NEW.module_id), '#') || '/' || lower(trim(NEW.name))",
      refs: {'module_id': SyncRef('modules', nullable: false)},
    ),
    SyncTableSpec(
      'attachments',
      idSql: "'a:#' || $_rand",
      refs: {'module_id': SyncRef('modules'), 'topic_id': SyncRef('topics')},
      notePaths: {'path'},
    ),
    SyncTableSpec(
      'study_sessions',
      // stessa sessione (es. da un backup ripristinato) = stessa riga
      idSql: "'s:' || NEW.start_at || '|' || NEW.duration_minutes",
      refs: {
        'course_id': SyncRef('courses'),
        'topic_id': SyncRef('topics'),
        'module_id': SyncRef('modules'),
      },
    ),
    SyncTableSpec(
      'books',
      idSql: "'b:' || COALESCE(NEW.external_id, '#' || $_rand)",
      refs: {'course_id': SyncRef('courses')},
      localOnly: {'file_path'},
    ),
    SyncTableSpec(
      'materials',
      idSql: "'k:' || COALESCE(NEW.external_id, '#' || $_rand)",
      refs: {'course_id': SyncRef('courses')},
      localOnly: {'local_path'},
    ),
    SyncTableSpec('place_personal', key: 'place_external_id'),
    SyncTableSpec('app_settings', key: 'key'),
    SyncTableSpec('profile', key: 'id', syncDeletes: false),
    SyncTableSpec('plan_years', key: 'year', syncDeletes: false),
  ];

  static SyncTableSpec? spec(String table) {
    for (final s in tables) {
      if (s.table == table) return s;
    }
    return null;
  }

  /// Colonne di servizio (non sono dati della riga).
  static const metaColumns = {'sync_id', 'sync_mtime'};

  /// Colonne con i dati di [s] (senza id locale e colonne di servizio).
  static List<String> dataColumns(SyncTableSpec s, Iterable<String> columns) =>
      [
        for (final c in columns)
          if (!metaColumns.contains(c) && (s.key != null || c != 'id')) c,
      ];

  static Future<List<String>> columnsOf(DatabaseExecutor ex, String t) async =>
      [
        for (final c in await ex.rawQuery('PRAGMA table_info($t)'))
          c['name'] as String,
      ];

  /// Prepara colonne, tabella delle eliminazioni e trigger (a ogni apertura
  /// del database; idempotente).
  static Future<void> ensure(Database db) => db.transaction((txn) async {
    await txn.execute(
      'CREATE TABLE IF NOT EXISTS $tombstones ('
      'tbl TEXT NOT NULL, sync_id TEXT NOT NULL, deleted_at INTEGER NOT NULL, '
      'PRIMARY KEY (tbl, sync_id))',
    );
    for (final s in tables) {
      var cols = await columnsOf(txn, s.table);
      if (cols.isEmpty) continue; // tabella assente (versione precedente)
      if (!cols.contains('sync_mtime')) {
        await txn.execute(
          'ALTER TABLE ${s.table} ADD COLUMN sync_mtime INTEGER',
        );
      }
      if (s.hasSyncId && !cols.contains('sync_id')) {
        await txn.execute('ALTER TABLE ${s.table} ADD COLUMN sync_id TEXT');
      }
      if (s.hasSyncId) {
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_${s.table}_sync_id '
          'ON ${s.table}(sync_id)',
        );
      }
      cols = await columnsOf(txn, s.table);
      // righe già presenti prima della sincronizzazione: dati veri di questo
      // dispositivo, modificati «ora»
      await txn.execute(
        'UPDATE ${s.table} SET sync_mtime = $nowSql WHERE sync_mtime IS NULL',
      );
      if (s.hasSyncId) {
        await txn.execute(
          'UPDATE ${s.table} SET sync_id = '
          '${s.idSql!.replaceAll('NEW.', '${s.table}.')} '
          'WHERE sync_id IS NULL',
        );
      }
      await _triggers(txn, s, cols);
    }
    await dedupe(txn);
  });

  static Future<void> _triggers(
    DatabaseExecutor ex,
    SyncTableSpec s,
    List<String> cols,
  ) async {
    final t = s.table;
    for (final kind in ['ins', 'upd', 'del']) {
      await ex.execute('DROP TRIGGER IF EXISTS sync_${kind}_$t');
    }
    final ins = s.hasSyncId
        ? 'NEW.sync_mtime IS NULL OR NEW.sync_id IS NULL'
        : 'NEW.sync_mtime IS NULL';
    final setId = s.hasSyncId
        ? ', sync_id = COALESCE(NEW.sync_id, ${s.idSql})'
        : '';
    await ex.execute(
      'CREATE TRIGGER sync_ins_$t AFTER INSERT ON $t WHEN $ins BEGIN '
      'UPDATE $t SET sync_mtime = COALESCE(NEW.sync_mtime, -$nowSql)$setId '
      'WHERE rowid = NEW.rowid; END',
    );
    final data = dataColumns(s, cols);
    if (data.isNotEmpty) {
      final changed = data.map((c) => 'NEW."$c" IS NOT OLD."$c"').join(' OR ');
      await ex.execute(
        'CREATE TRIGGER sync_upd_$t AFTER UPDATE ON $t '
        'WHEN NEW.sync_mtime IS OLD.sync_mtime AND ($changed) BEGIN '
        'UPDATE $t SET sync_mtime = ${afterSql('OLD')} '
        'WHERE rowid = NEW.rowid; END',
      );
    }
    if (!s.syncDeletes) return;
    final only = t == 'app_settings'
        ? ' AND (${syncedSettingSql('OLD.key')})'
        : '';
    await ex.execute(
      'CREATE TRIGGER sync_del_$t AFTER DELETE ON $t '
      'WHEN ${s.idOf('OLD')} IS NOT NULL$only BEGIN '
      'INSERT OR REPLACE INTO $tombstones (tbl, sync_id, deleted_at) '
      "VALUES ('$t', ${s.idOf('OLD')}, ${afterSql('OLD')}); END",
    );
  }

  /// Orario di una modifica o eliminazione della riga [alias]: adesso, ma
  /// sempre dopo l'orario che la riga ha già. Un dispositivo con l'orologio
  /// avanti scrive orari nel futuro; senza questo, una modifica fatta dopo
  /// su un dispositivo con l'ora giusta avrebbe un orario più vecchio e
  /// l'unione la annullerebbe (e un'eliminazione farebbe tornare la riga),
  /// finché l'ora vera non raggiunge quella sbagliata.
  static String afterSql(String alias) =>
      'MAX($nowSql, COALESCE(ABS($alias.sync_mtime), 0) + 1)';

  /// Identificativi doppi sullo stesso dispositivo (es. due moduli con lo
  /// stesso nome nello stesso insegnamento): dal secondo in poi si aggiunge
  /// «#2», «#3»… nell'ordine di creazione, così due dispositivi con la stessa
  /// struttura arrivano agli stessi identificativi.
  static Future<void> dedupe(DatabaseExecutor ex) async {
    for (final s in tables.where((s) => s.hasSyncId)) {
      final dup = await ex.rawQuery(
        'SELECT sync_id FROM ${s.table} WHERE sync_id IS NOT NULL '
        'GROUP BY sync_id HAVING COUNT(*) > 1',
      );
      for (final d in dup) {
        final id = d['sync_id'] as String;
        final rows = await ex.query(
          s.table,
          columns: ['rowid AS r'],
          where: 'sync_id = ?',
          whereArgs: [id],
          orderBy: 'rowid',
        );
        for (var i = 1; i < rows.length; i++) {
          var n = i + 1;
          String next() => '$id#$n';
          while ((await ex.query(
            s.table,
            columns: ['rowid'],
            where: 'sync_id = ?',
            whereArgs: [next()],
          )).isNotEmpty) {
            n++;
          }
          await ex.update(
            s.table,
            {'sync_id': next()},
            where: 'rowid = ?',
            whereArgs: [rows[i]['r']],
          );
        }
      }
    }
  }
}
