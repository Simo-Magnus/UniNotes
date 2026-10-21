import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'graph_client.dart' show GraphException;

/// L'errore viene dalla rete (nessuna connessione, servizio non
/// raggiungibile, tempo scaduto, connessione caduta), non dal file o
/// dall'account: [ioTransport] e [ioDownload] lo trasformano in
/// [GraphException] con stato 0 (anche per Google Drive).
bool isNetworkError(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    e is HttpException ||
    (e is GraphException && e.status == 0);

/// Stato di un file all'ultima sincronizzazione riuscita.
class SyncedFile {
  const SyncedFile({
    required this.size,
    required this.mtime,
    required this.ctag,
    this.remoteId,
  });
  final int size;

  /// Ultima modifica locale (millisecondi).
  final int mtime;

  /// Impronta del contenuto sul servizio (OneDrive `cTag`, Google Drive
  /// `md5Checksum`): cambia quando cambia il contenuto.
  final String ctag;
  final String? remoteId;

  Map<String, Object?> toJson() => {
    'size': size,
    'mtime': mtime,
    'ctag': ctag,
    'id': remoteId,
  };

  factory SyncedFile.fromJson(Map<String, Object?> m) => SyncedFile(
    size: (m['size'] as num?)?.toInt() ?? -1,
    mtime: (m['mtime'] as num?)?.toInt() ?? 0,
    ctag: m['ctag'] as String? ?? '',
    remoteId: m['id'] as String?,
  );
}

class RemoteFile {
  const RemoteFile({
    required this.id,
    required this.size,
    required this.ctag,
    this.downloadUrl,
  });
  final String id;
  final int size;
  final String ctag;
  final String? downloadUrl;
}

class LocalFile {
  const LocalFile(this.file, this.size, this.mtime);
  final File file;
  final int size;
  final int mtime;
}

/// Esito di una sincronizzazione.
class SyncReport {
  int uploaded = 0;
  int downloaded = 0;
  int deletedRemote = 0;
  int deletedLocal = 0;
  int conflicts = 0;

  /// Righe dei dati dell'app aggiornate dagli altri dispositivi (DataSync).
  int dataChanges = 0;
  final List<String> errors = [];

  bool get changed =>
      uploaded +
          downloaded +
          deletedRemote +
          deletedLocal +
          conflicts +
          dataChanges >
      0;

  /// Somma l'esito di un'altra cartella sincronizzata.
  void add(SyncReport o) {
    uploaded += o.uploaded;
    downloaded += o.downloaded;
    deletedRemote += o.deletedRemote;
    deletedLocal += o.deletedLocal;
    conflicts += o.conflicts;
    dataChanges += o.dataChanges;
    errors.addAll(o.errors);
  }

  @override
  String toString() {
    final parts = [
      if (uploaded > 0) '$uploaded caricati',
      if (downloaded > 0) '$downloaded scaricati',
      if (deletedRemote + deletedLocal > 0)
        '${deletedRemote + deletedLocal} eliminati',
      if (conflicts > 0) '$conflicts conflitti (tenute entrambe le versioni)',
      if (dataChanges > 0)
        dataChanges == 1
            ? '1 dato aggiornato dagli altri dispositivi'
            : '$dataChanges dati aggiornati dagli altri dispositivi',
    ];
    final base = parts.isEmpty ? 'Tutto già sincronizzato' : parts.join(', ');
    return errors.isEmpty ? base : '$base · ${errors.length} errori';
  }
}

/// Sincronizzazione bidirezionale di una cartella locale con una cartella su
/// un servizio cloud (OneDrive, Google Drive): l'algoritmo è comune, ogni
/// servizio implementa elenco, caricamento, scaricamento ed eliminazione.
///
/// Per ogni file confronta lo stato attuale (locale e remoto) con quello
/// dell'ultima sincronizzazione riuscita:
/// - cambiato solo da una parte → copiato dall'altra;
/// - cambiato da entrambe → conflitto: la versione locale viene rinominata
///   «nome (conflitto dispositivo data).ext» e caricata, quella remota
///   scaricata col nome originale;
/// - eliminato da una parte e invariato dall'altra → eliminato anche lì (sul
///   servizio va nel cestino, sul dispositivo nella cartella [localTrashDir]).
/// File e cartelle che iniziano con «.» non si sincronizzano; [include]
/// limita la sincronizzazione a una parte dei file (es. senza registrazioni).
abstract class FolderSync {
  FolderSync({
    required this.localRoot,
    required this.remoteFolder,
    required this.stateFile,
    this.deviceName = 'dispositivo',
    this.include,
    DateTime Function()? now,
  }) : clock = now ?? DateTime.now;

  /// Percorsi relativi da sincronizzare (null = tutti).
  final bool Function(String rel)? include;
  final Directory localRoot;

  /// Percorso della cartella sul servizio (es. «UniNotes/Corsi»).
  final String remoteFolder;
  final File stateFile;
  final String deviceName;
  final DateTime Function() clock;

  /// Nome del servizio nei messaggi («OneDrive», «Google Drive»).
  String get serviceName;

  /// Cartella locale (nascosta) dove finiscono i file eliminati altrove.
  String get localTrashDir;

  static bool ignored(String rel) {
    final parts = rel.split('/');
    final name = parts.last.toLowerCase();
    return parts.any((s) => s.startsWith('.')) ||
        name.startsWith('~\$') ||
        name.endsWith('.part') ||
        name.endsWith('.tmp') ||
        name == 'desktop.ini' ||
        name == 'thumbs.db';
  }

  bool wanted(String rel) => !ignored(rel) && (include?.call(rel) ?? true);

  static final _reserved = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$',
    caseSensitive: false,
  );

  /// Nome remoto sicuro da scrivere sul dispositivo: niente percorsi assoluti,
  /// «..», barre rovesciate, «:» o caratteri di controllo (un file chiamato
  /// «x\..\..\Startup\a.cmd» su Google Drive non deve uscire dalla
  /// cartella dell'app), né nomi riservati di Windows.
  static bool safeRel(String rel) {
    if (rel.isEmpty || rel.startsWith('/')) return false;
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.' || seg == '..') return false;
      if (RegExp(r'[\\:*?"<>|\x00-\x1f]').hasMatch(seg)) return false;
      if (seg.endsWith(' ') || seg.endsWith('.')) return false;
      if (_reserved.hasMatch(seg)) return false;
    }
    return true;
  }

  /// File locale di [rel], garantito dentro [localRoot].
  File localFile(String rel) {
    final target = p.normalize(p.joinAll([localRoot.path, ...rel.split('/')]));
    if (!safeRel(rel) || !p.isWithin(p.normalize(localRoot.path), target)) {
      throw FileSystemException('Percorso non valido', rel);
    }
    return File(target);
  }

  /// La cartella dell'app sul servizio non c'era (rinominata, spostata o
  /// eliminata dal sito) ed è stata creata ora: i file sul dispositivo vanno
  /// ricaricati, non considerati «eliminati altrove».
  bool remoteRootCreated = false;

  /// Prima dell'elenco remoto (es. segnalibro delle modifiche, così quelle
  /// fatte durante la sincronizzazione non si perdono).
  Future<void> beforeList() async {}

  // ------------------------------------------------- operazioni del servizio

  Future<Map<String, RemoteFile>> listRemote();
  Future<SyncedFile> upload(String rel, File f);
  Future<SyncedFile> download(String rel, RemoteFile r);

  /// Elimina il file sul servizio (nel suo cestino).
  Future<void> deleteRemote(RemoteFile r);

  /// Prima sincronizzazione con il file da entrambe le parti e la stessa
  /// dimensione: true/false se il servizio permette di confrontare il
  /// contenuto, null se non si sa (allora vale la sola dimensione).
  Future<bool?> sameContent(LocalFile l, RemoteFile r) async => null;

  /// Dati propri del servizio salvati con lo stato (es. `deltaLink`).
  Map<String, Object?> extraState() => const {};
  void readExtraState(Map<Object?, Object?> m) {}

  /// Dopo una sincronizzazione completa (es. nuovo `deltaLink`).
  Future<void> afterRun() async {}

  /// true se il servizio sa dire cosa è cambiato dall'ultima volta
  /// ([remoteChanged]) senza rileggere tutta la cartella.
  bool get canCheckChanges => false;

  /// true se sul servizio è cambiato qualcosa dall'ultima sincronizzazione.
  Future<bool> remoteChanged() async => true;

  /// Controllo leggero: serve una sincronizzazione? (file locali cambiati
  /// rispetto all'ultima volta, oppure novità sul servizio).
  Future<bool> needsSync() async {
    final state = await loadState();
    if (!canCheckChanges) return true;
    final local = await listLocal();
    final paths = {...local.keys, ...state.keys}
      ..removeWhere((r) => !wanted(r));
    for (final rel in paths) {
      final l = local[rel];
      final prev = state[rel];
      if (l == null || prev == null) return true;
      if (l.size != prev.size || l.mtime != prev.mtime) return true;
    }
    final changed = await remoteChanged();
    if (!changed) await saveState(state);
    return changed;
  }

  // ------------------------------------------------------------- state

  Future<Map<String, SyncedFile>> loadState() async {
    try {
      if (!await stateFile.exists()) return {};
      final m = jsonDecode(await stateFile.readAsString()) as Map;
      if (m['remoteFolder'] != remoteFolder) return {};
      readExtraState(m);
      return {
        for (final e in (m['files'] as Map? ?? const {}).entries)
          e.key as String: SyncedFile.fromJson(
            (e.value as Map).cast<String, Object?>(),
          ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveState(Map<String, SyncedFile> s) async {
    await stateFile.parent.create(recursive: true);
    final tmp = File('${stateFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'remoteFolder': remoteFolder,
        ...extraState(),
        'files': {for (final e in s.entries) e.key: e.value.toJson()},
      }),
    );
    await tmp.rename(stateFile.path);
  }

  Future<Map<String, LocalFile>> listLocal() async {
    final out = <String, LocalFile>{};
    if (!await localRoot.exists()) return out;
    await for (final e in localRoot.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p
          .relative(e.path, from: localRoot.path)
          .split(p.separator)
          .join('/');
      final st = await e.stat();
      out[rel] = LocalFile(e, st.size, st.modified.millisecondsSinceEpoch);
    }
    return out;
  }

  Future<void> _trashLocal(String rel, File f) async {
    localFile(rel); // il file da spostare è dentro la cartella dell'app
    final dest = File(
      p.joinAll([localRoot.path, localTrashDir, ...rel.split('/')]),
    );
    await dest.parent.create(recursive: true);
    if (await dest.exists()) await dest.delete();
    await f.rename(dest.path);
  }

  String conflictName(String rel) {
    final ext = p.posix.extension(rel);
    final base = rel.substring(0, rel.length - ext.length);
    final d = clock();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}.${two(d.minute)}';
    return '$base (conflitto $deviceName $stamp)$ext';
  }

  // ------------------------------------------------------------- sync

  Future<SyncReport> run({void Function(String step)? onProgress}) async {
    final report = SyncReport();
    final state = await loadState();
    onProgress?.call('Elenco dei file su $serviceName…');
    remoteRootCreated = false;
    await beforeList();
    final remote = await listRemote();
    for (final rel in remote.keys.where((r) => !safeRel(r)).toList()) {
      remote.remove(rel);
      report.errors.add('$rel: nome non valido, ignorato');
    }
    if (remoteRootCreated && state.isNotEmpty) {
      // cartella remota nuova: si riparte da zero, senza eliminare nulla
      state.clear();
    }
    final local = await listLocal();
    final paths = {...remote.keys, ...local.keys, ...state.keys}
      ..removeWhere((r) => !wanted(r));
    final sorted = paths.toList()..sort();
    // connessione caduta a metà: si salva quanto fatto e ci si ferma (i
    // file successivi fallirebbero tutti allo stesso modo)
    Object? offline;
    for (final rel in sorted) {
      final l = local[rel];
      final r = remote[rel];
      final prev = state[rel];
      final localChanged =
          l != null &&
          (prev == null || l.size != prev.size || l.mtime != prev.mtime);
      final remoteChanged = r != null && (prev == null || r.ctag != prev.ctag);
      try {
        if (l != null && r != null) {
          if (prev == null &&
              l.size == r.size &&
              await sameContent(l, r) != false) {
            // Prima sincronizzazione: stesso file già presente da entrambe le
            // parti (es. copiato a mano). Si considera allineato. Con
            // contenuto diverso ([sameContent]) è un conflitto (sotto):
            // senza stato precedente vale «cambiato da entrambe le parti».
            state[rel] = SyncedFile(
              size: l.size,
              mtime: l.mtime,
              ctag: r.ctag,
              remoteId: r.id,
            );
          } else if (localChanged && remoteChanged) {
            onProgress?.call('Conflitto: $rel');
            final renamed = conflictName(rel);
            final moved = localFile(renamed);
            await l.file.rename(moved.path);
            state[renamed] = await upload(renamed, moved);
            state[rel] = await download(rel, r);
            report.conflicts++;
          } else if (localChanged) {
            onProgress?.call('Carico $rel');
            state[rel] = await upload(rel, l.file);
            report.uploaded++;
          } else if (remoteChanged) {
            onProgress?.call('Scarico $rel');
            state[rel] = await download(rel, r);
            report.downloaded++;
          }
        } else if (l != null) {
          if (prev != null && !localChanged) {
            // Eliminato sul servizio da un altro dispositivo.
            await _trashLocal(rel, l.file);
            state.remove(rel);
            report.deletedLocal++;
          } else {
            onProgress?.call('Carico $rel');
            state[rel] = await upload(rel, l.file);
            report.uploaded++;
          }
        } else if (r != null) {
          if (prev != null && !remoteChanged) {
            // Eliminato su questo dispositivo: sul servizio va nel cestino.
            await deleteRemote(r);
            state.remove(rel);
            report.deletedRemote++;
          } else {
            onProgress?.call('Scarico $rel');
            state[rel] = await download(rel, r);
            report.downloaded++;
          }
        } else {
          state.remove(rel); // sparito da entrambe le parti
        }
      } catch (e) {
        if (isNetworkError(e)) {
          offline = e;
          break;
        }
        report.errors.add('$rel: $e');
      }
    }
    if (offline != null) {
      await saveState(state);
      throw offline;
    }
    await afterRun();
    await saveState(state);
    return report;
  }
}
