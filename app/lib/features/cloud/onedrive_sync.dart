import 'dart:io';
import 'dart:math' as math;

import 'folder_sync.dart';
import 'graph_client.dart';

export 'folder_sync.dart';

/// Sincronizzazione di una cartella locale con una cartella OneDrive
/// (Microsoft Graph); l'algoritmo è in [FolderSync]. I file eliminati su
/// OneDrive finiscono sul dispositivo nella cartella `.cestino-onedrive`.
///
/// Per non rileggere tutto OneDrive a ogni controllo automatico, dopo ogni
/// sincronizzazione si salva il `deltaLink` della cartella (Microsoft Graph
/// `/delta`): [needsSync] chiede a OneDrive solo cosa è cambiato da allora
/// e confronta i file locali con lo stato salvato.
///
/// Alla prima sincronizzazione un file presente da entrambe le parti con la
/// stessa dimensione si considera uguale: OneDrive dà come impronta del
/// contenuto il `quickXorHash`, che l'app non calcola (nessun
/// [FolderSync.sameContent]).
class OneDriveSync extends FolderSync {
  OneDriveSync({
    required this.graph,
    required super.localRoot,
    required super.remoteFolder,
    required super.stateFile,
    super.deviceName,
    super.include,
    super.now,
  });

  final GraphClient graph;

  @override
  String get serviceName => 'OneDrive';

  @override
  String get localTrashDir => trashDir;

  /// Sotto questa soglia il file si carica con una sola richiesta.
  static const simpleUploadLimit = 4 * 1024 * 1024;

  /// Blocchi delle sessioni di caricamento (multiplo di 320 KiB).
  static const chunkSize = 32 * 320 * 1024;

  static const trashDir = '.cestino-onedrive';

  static bool ignored(String rel) => FolderSync.ignored(rel);

  // ------------------------------------------------------------- state

  /// `deltaLink` della cartella su OneDrive (null = da rileggere tutta).
  String? deltaLink;
  String? _folderId;

  @override
  Map<String, Object?> extraState() => {
    'deltaLink': ?deltaLink,
    'folderId': ?_folderId,
  };

  @override
  void readExtraState(Map<Object?, Object?> m) {
    deltaLink = m['deltaLink'] as String?;
    _folderId = m['folderId'] as String?;
  }

  String? _nextDelta;

  /// Id caricati o eliminati da questa sincronizzazione.
  final Set<String> _mine = {};

  @override
  Future<void> beforeList() async {
    _mine.clear();
    final id = _folderId;
    _nextDelta = id == null ? null : await latestDeltaLink(id);
  }

  /// Il `deltaLink` preso prima dell'elenco avanza solo se dopo non è
  /// cambiato nulla oltre a ciò che ha fatto questa sincronizzazione.
  @override
  Future<void> afterRun() async {
    final folderId = _folderId;
    final start = _nextDelta;
    if (start == null) {
      deltaLink = folderId == null ? null : await latestDeltaLink(folderId);
      return;
    }
    deltaLink = start;
    final changed = await remoteChangedSince(start, ignore: _mine);
    if (changed) deltaLink = start;
  }

  @override
  bool get canCheckChanges => deltaLink != null && _folderId != null;

  @override
  Future<bool> remoteChanged() => remoteChangedSince(deltaLink!);

  /// `deltaLink` attuale della cartella, senza elencarne il contenuto
  /// (`token=latest`). Null se OneDrive non lo supporta per le sottocartelle
  /// (OneDrive for Business/SharePoint): allora si rilegge sempre tutto.
  Future<String?> latestDeltaLink(String folderId) async {
    try {
      final r = await graph.getJson('me/drive/items/$folderId/delta', {
        'token': 'latest',
      });
      return r?['@odata.deltaLink'] as String?;
    } on GraphException {
      return null;
    }
  }

  /// true se su OneDrive è cambiato qualcosa dopo [link] (o non si sa).
  /// Aggiorna [deltaLink].
  Future<bool> remoteChangedSince(
    String link, {
    Set<String> ignore = const {},
  }) async {
    String? next = link;
    var changed = false;
    try {
      while (next != null) {
        final page = await graph.getJson(next);
        if (page == null) return true;
        for (final it
            in (page['value'] as List? ?? const []).whereType<Map>()) {
          if (it['id'] == _folderId || ignore.contains(it['id'])) continue;
          // dopo una sincronizzazione le cartelle cambiano per i file caricati
          if (ignore.isNotEmpty && it['folder'] != null) continue;
          changed = true;
        }
        final more = page['@odata.nextLink'] as String?;
        if (more == null) {
          deltaLink = page['@odata.deltaLink'] as String? ?? deltaLink;
        }
        next = more;
      }
      return changed;
    } on GraphException {
      // 410 = da risincronizzare: si rilegge tutto.
      deltaLink = null;
      return true;
    }
  }

  // ------------------------------------------------------------- listing

  String _remotePath(String rel) => GraphClient.drivePath('$remoteFolder/$rel');

  @override
  Future<Map<String, RemoteFile>> listRemote() async {
    final out = <String, RemoteFile>{};
    final root = await graph.getJson(
      'me/drive/root:/${GraphClient.drivePath(remoteFolder)}',
    );
    if (root == null) {
      // Cartella assente: la si crea alla prima sincronizzazione.
      _folderId = await ensureFolder(graph, remoteFolder);
      remoteRootCreated = true;
      return out;
    }
    final rootId = root['id'];
    if (rootId is! String) {
      throw GraphException(
        502,
        'Microsoft Graph: risposta inattesa per la cartella $remoteFolder',
      );
    }
    _folderId = rootId;
    Future<void> walk(String id, String prefix) async {
      // elenco completo o errore (cartella sparita a metà, risposta senza
      // elenco): mai un elenco vuoto che farebbe «eliminare» i file qui
      for (final it in await graph.list(
        'me/drive/items/$id/children',
        null,
        true,
      )) {
        final name = it['name'];
        final itemId = it['id'];
        if (name is! String || name.isEmpty || itemId is! String) {
          throw GraphException(
            502,
            'Microsoft Graph: elemento senza nome o id in $remoteFolder',
          );
        }
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (it['folder'] != null) {
          await walk(itemId, rel);
        } else if (it['file'] != null) {
          final url = it['@microsoft.graph.downloadUrl'];
          final ctag = it['cTag'] ?? it['eTag'];
          out[rel] = RemoteFile(
            id: itemId,
            size: (it['size'] as num?)?.toInt() ?? 0,
            ctag: ctag is String ? ctag : '',
            downloadUrl: url is String ? url : null,
          );
        }
      }
    }

    await walk(rootId, '');
    return out;
  }

  /// Crea (se mancano) le cartelle di [path] su OneDrive; restituisce l'id
  /// dell'ultima.
  static Future<String?> ensureFolder(GraphClient graph, String path) async {
    final parts = path.split('/').where((s) => s.trim().isNotEmpty).toList();
    String? parentId;
    for (var i = 0; i < parts.length; i++) {
      final sub = parts.take(i + 1).join('/');
      final existing = await graph.getJson(
        'me/drive/root:/${GraphClient.drivePath(sub)}',
      );
      if (existing != null) {
        parentId = existing['id'] as String?;
        continue;
      }
      final created = await graph.sendJson(
        'POST',
        parentId == null
            ? 'me/drive/root/children'
            : 'me/drive/items/$parentId/children',
        {
          'name': parts[i],
          'folder': <String, Object?>{},
          '@microsoft.graph.conflictBehavior': 'fail',
        },
      );
      parentId = created['id'] as String?;
    }
    return parentId;
  }

  // ------------------------------------------------------------- transfer

  @override
  Future<SyncedFile> upload(String rel, File f) async {
    final size = await f.length();
    Map<String, Object?> item;
    if (size <= simpleUploadLimit) {
      final r = await graph.request(
        'PUT',
        'me/drive/root:/${_remotePath(rel)}:/content',
        headers: {'Content-Type': 'application/octet-stream'},
        body: await f.readAsBytes(),
      );
      // 404 (non è un errore per GraphClient.request): file non caricato
      if (!r.ok) {
        throw GraphException(r.status, 'Caricamento non riuscito: $rel');
      }
      item = r.json;
    } else {
      final session = await graph.sendJson(
        'POST',
        'me/drive/root:/${_remotePath(rel)}:/createUploadSession',
        {
          'item': {'@microsoft.graph.conflictBehavior': 'replace'},
        },
      );
      final uploadUrl = session['uploadUrl'];
      if (uploadUrl is! String) {
        throw GraphException(502, 'OneDrive non ha aperto il caricamento: $rel');
      }
      final raf = await f.open();
      try {
        var offset = 0;
        item = const {};
        while (offset < size) {
          final n = math.min(chunkSize, size - offset);
          await raf.setPosition(offset);
          final chunk = await raf.read(n);
          final r = await graph.request(
            'PUT',
            uploadUrl,
            auth: false,
            headers: {'Content-Range': 'bytes $offset-${offset + n - 1}/$size'},
            body: chunk,
          );
          // sessione scaduta o annullata (404): il file non c'è
          if (!r.ok) {
            throw GraphException(r.status, 'Caricamento interrotto: $rel');
          }
          offset += n;
          if (r.status == 200 || r.status == 201) item = r.json;
        }
      } finally {
        await raf.close();
      }
    }
    final st = await f.stat();
    final id = item['id'];
    // senza l'id del file caricato lo stato direbbe «sincronizzato» per un
    // file che su OneDrive non c'è (e la volta dopo verrebbe tolto da qui)
    if (id is! String) {
      throw GraphException(502, 'OneDrive non ha confermato il caricamento: $rel');
    }
    final itemId = id;
    _mine.add(itemId);
    return SyncedFile(
      size: st.size,
      mtime: st.modified.millisecondsSinceEpoch,
      ctag: item['cTag'] as String? ?? item['eTag'] as String? ?? '',
      remoteId: itemId,
    );
  }

  @override
  Future<SyncedFile> download(String rel, RemoteFile r) async {
    final target = localFile(rel);
    await target.parent.create(recursive: true);
    // a pezzi in «nome.part» accanto al file (ignorato dalla
    // sincronizzazione), poi rinominato: un file a metà non sostituisce
    // quello buono
    final part = File('${target.path}.part');
    try {
      final res = r.downloadUrl != null
          ? await graph.download(r.downloadUrl!, part, auth: false)
          : await graph.download('me/drive/items/${r.id}/content', part);
      if (!res.ok) {
        throw GraphException(res.status, 'Download non riuscito: $rel');
      }
      await FolderSync.checkDownloaded(part, r.size);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    final st = await target.stat();
    return SyncedFile(
      size: st.size,
      mtime: st.modified.millisecondsSinceEpoch,
      ctag: r.ctag,
      remoteId: r.id,
    );
  }

  @override
  Future<void> deleteRemote(RemoteFile r) {
    _mine.add(r.id);
    return graph.request('DELETE', 'me/drive/items/${r.id}');
  }
}
