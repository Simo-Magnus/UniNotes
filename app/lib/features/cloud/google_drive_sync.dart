import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'folder_sync.dart';
import 'google_drive_client.dart';

export 'folder_sync.dart';

/// Sincronizzazione di una cartella locale con una cartella di Google Drive
/// (API v3); l'algoritmo è in [FolderSync]. I file eliminati su Google Drive
/// finiscono sul dispositivo nella cartella `.cestino-googledrive`.
///
/// Su Drive i file si riconoscono per id (i nomi possono ripetersi); il
/// contenuto per `md5Checksum`. Per i controlli automatici si salva il
/// segnalibro delle modifiche (`changes.getStartPageToken`): [needsSync]
/// chiede a Drive solo cosa è cambiato da allora.
///
/// Con lo scope `drive.file` elenco e modifiche comprendono solo i file
/// creati dall'app (da qualsiasi dispositivo) e quelli importati con il
/// Picker: un file messo nella cartella da altre vie non compare, quindi non
/// si scarica né si considera «eliminato». Se la cartella dell'app non si
/// vede (creata da un'altra registrazione dell'app) se ne crea una nuova e i
/// file del dispositivo si ricaricano ([FolderSync.remoteRootCreated]).
class GoogleDriveSync extends FolderSync {
  GoogleDriveSync({
    required this.drive,
    required super.localRoot,
    required super.remoteFolder,
    required super.stateFile,
    super.deviceName,
    super.include,
    super.now,
  });

  final GoogleDriveClient drive;

  @override
  String get serviceName => 'Google Drive';

  @override
  String get localTrashDir => trashDir;

  static const trashDir = '.cestino-googledrive';

  /// Sotto questa soglia il file si carica con una sola richiesta.
  static const simpleUploadLimit = 5 * 1024 * 1024;

  /// Blocchi del caricamento ripristinabile (multiplo di 256 KiB).
  static const chunkSize = 32 * 256 * 1024;

  // ------------------------------------------------------------- state

  /// Segnalibro delle modifiche di Drive (null = da rileggere tutto).
  String? pageToken;

  /// Id delle cartelle e dei file della cartella dell'app all'ultima
  /// sincronizzazione: le modifiche di Drive che non li toccano (il resto
  /// del Drive dell'utente) non fanno ripartire la sincronizzazione.
  Set<String> _ids = {};

  @override
  Map<String, Object?> extraState() => {
    'pageToken': ?pageToken,
    'ids': [..._ids],
  };

  @override
  void readExtraState(Map<Object?, Object?> m) {
    pageToken = m['pageToken'] as String?;
    _ids = {for (final x in (m['ids'] as List? ?? const [])) '$x'};
  }

  String? _nextToken;

  Future<String?> _startToken() async {
    try {
      final r = await drive.getJson('changes/startPageToken');
      return r?['startPageToken'] as String?;
    } on DriveException {
      return null;
    }
  }

  @override
  Future<void> beforeList() async {
    _mine.clear();
    _nextToken = await _startToken();
  }

  /// Il segnalibro preso prima dell'elenco avanza solo se dopo non è cambiato
  /// nulla oltre a ciò che ha fatto questa sincronizzazione.
  @override
  Future<void> afterRun() async {
    _ids = {..._dirs.values, ..._files.values};
    final start = _nextToken;
    if (start == null) {
      pageToken = await _startToken();
      return;
    }
    final (changed, next) = await _changedSince(start, _mine);
    pageToken = changed ? start : (next ?? start);
  }

  @override
  bool get canCheckChanges => pageToken != null;

  /// Novità nella cartella dell'app: un file o una cartella già noti, oppure
  /// un elemento nuovo dentro una cartella nota.
  @override
  Future<bool> remoteChanged() async {
    final (changed, next) = await _changedSince(pageToken, const {});
    pageToken = next;
    return changed;
  }

  /// Id creati, aggiornati o cestinati da questa sincronizzazione: le loro
  /// modifiche non sono «novità» da riscaricare.
  final Set<String> _mine = {};

  /// Novità dopo [start] (ignorando [ignore]) e segnalibro successivo.
  Future<(bool, String?)> _changedSince(
    String? start,
    Set<String> ignore,
  ) async {
    String? token = start;
    String? pageToken = start;
    var changed = false;
    try {
      while (token != null) {
        final page = await drive.getJson('changes', {
          'pageToken': token,
          'fields':
              'nextPageToken,newStartPageToken,changes(fileId,file(parents))',
          'pageSize': '1000',
          'spaces': 'drive',
        });
        if (page == null) return (true, null);
        for (final c
            in (page['changes'] as List? ?? const []).whereType<Map>()) {
          final parents =
              ((c['file'] as Map?)?['parents'] as List?) ?? const [];
          if (ignore.contains(c['fileId'])) continue;
          if (_ids.isEmpty ||
              _ids.contains(c['fileId']) ||
              parents.any((p) => _ids.contains(p))) {
            changed = true;
          }
        }
        final next = page['nextPageToken'] as String?;
        if (next == null) {
          pageToken = page['newStartPageToken'] as String? ?? pageToken;
        }
        token = next;
      }
      return (changed, pageToken);
    } on DriveException {
      return (true, null);
    }
  }

  // ------------------------------------------------------------- listing

  /// Id delle cartelle per percorso relativo ('' = cartella dell'app).
  final Map<String, String> _dirs = {};

  /// Id dei file per percorso relativo (dall'ultimo elenco).
  final Map<String, String> _files = {};

  static bool _native(String mime) =>
      mime.startsWith('application/vnd.google-apps.');

  @override
  Future<Map<String, RemoteFile>> listRemote() async {
    final out = <String, RemoteFile>{};
    _dirs.clear();
    _files.clear();
    var root = await drive.folderPath(remoteFolder, create: false);
    if (root == null) {
      root = await drive.folderPath(remoteFolder);
      remoteRootCreated = true;
      if (root != null) _mine.add(root);
    }
    final rootId = root!;
    _dirs[''] = rootId;
    Future<void> walk(String id, String prefix) async {
      for (final it in await drive.children(id)) {
        final name = it['name'] as String? ?? '';
        final mime = it['mimeType'] as String? ?? '';
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        final fid = it['id'] as String;
        if (mime == GoogleDriveClient.folderMime) {
          _dirs[rel] = fid;
          await walk(fid, rel);
        } else if (!_native(mime) && !out.containsKey(rel)) {
          // Documenti Google (senza file da scaricare) esclusi; con due file
          // dello stesso nome vale il primo.
          _files[rel] = fid;
          out[rel] = RemoteFile(
            id: fid,
            size: int.tryParse('${it['size'] ?? ''}') ?? 0,
            ctag: it['md5Checksum'] as String? ?? '',
          );
        }
      }
    }

    await walk(rootId, '');
    return out;
  }

  /// Id della cartella [dir] (relativa), creata se manca.
  Future<String> _dir(String dir) async {
    if (dir == '.' || dir.isEmpty) {
      return _dirs[''] ??= (await drive.folderPath(remoteFolder))!;
    }
    final known = _dirs[dir];
    if (known != null) return known;
    final parent = await _dir(p.posix.dirname(dir));
    final name = p.posix.basename(dir);
    var id = await drive.findFolder(parent, name);
    if (id == null) {
      id = await drive.createFolder(parent, name);
      _mine.add(id);
    }
    return _dirs[dir] = id;
  }

  // ------------------------------------------------------------- transfer

  static const _fields = {'fields': 'id,md5Checksum,size'};

  @override
  Future<SyncedFile> upload(String rel, File f) async {
    final size = await f.length();
    final existing = _files[rel];
    Map<String, Object?> item;
    if (size <= simpleUploadLimit) {
      final bytes = await f.readAsBytes();
      if (existing != null) {
        final r = await drive.request(
          'PATCH',
          GoogleDriveClient.uploadBase
              .resolve('files/$existing')
              .replace(queryParameters: {'uploadType': 'media', ..._fields}),
          headers: {'Content-Type': 'application/octet-stream'},
          body: bytes,
        );
        item = r.json;
      } else {
        final parent = await _dir(p.posix.dirname(rel));
        final boundary = 'un${DateTime.now().microsecondsSinceEpoch}';
        final meta = jsonEncode({
          'name': p.posix.basename(rel),
          'parents': [parent],
        });
        final body = <int>[
          ...utf8.encode(
            '--$boundary\r\n'
            'Content-Type: application/json; charset=UTF-8\r\n\r\n'
            '$meta\r\n'
            '--$boundary\r\n'
            'Content-Type: application/octet-stream\r\n\r\n',
          ),
          ...bytes,
          ...utf8.encode('\r\n--$boundary--\r\n'),
        ];
        final r = await drive.request(
          'POST',
          GoogleDriveClient.uploadBase
              .resolve('files')
              .replace(
                queryParameters: {'uploadType': 'multipart', ..._fields},
              ),
          headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
          body: body,
        );
        item = r.json;
      }
    } else {
      item = await _resumable(rel, f, size, existing);
    }
    final id = item['id'] as String?;
    if (id != null) {
      _files[rel] = id;
      _mine.add(id);
    }
    final st = await f.stat();
    return SyncedFile(
      size: st.size,
      mtime: st.modified.millisecondsSinceEpoch,
      ctag: item['md5Checksum'] as String? ?? '',
      remoteId: id,
    );
  }

  /// Caricamento ripristinabile a blocchi (file grandi: libri, registrazioni).
  Future<Map<String, Object?>> _resumable(
    String rel,
    File f,
    int size,
    String? existing,
  ) async {
    final query = {'uploadType': 'resumable', ..._fields};
    final start = existing != null
        ? await drive.request(
            'PATCH',
            GoogleDriveClient.uploadBase
                .resolve('files/$existing')
                .replace(queryParameters: query),
            headers: {
              'Content-Type': 'application/json; charset=UTF-8',
              'X-Upload-Content-Length': '$size',
            },
            body: utf8.encode('{}'),
          )
        : await drive.request(
            'POST',
            GoogleDriveClient.uploadBase
                .resolve('files')
                .replace(queryParameters: query),
            headers: {
              'Content-Type': 'application/json; charset=UTF-8',
              'X-Upload-Content-Length': '$size',
            },
            body: utf8.encode(
              jsonEncode({
                'name': p.posix.basename(rel),
                'parents': [await _dir(p.posix.dirname(rel))],
              }),
            ),
          );
    final session = start.headers['location'];
    if (session == null) {
      throw DriveException(start.status, 'Google Drive: caricamento rifiutato');
    }
    final raf = await f.open();
    try {
      var offset = 0;
      Map<String, Object?> item = const {};
      while (offset < size) {
        final n = math.min(chunkSize, size - offset);
        await raf.setPosition(offset);
        final chunk = await raf.read(n);
        final r = await drive.request(
          'PUT',
          Uri.parse(session),
          headers: {'Content-Range': 'bytes $offset-${offset + n - 1}/$size'},
          body: chunk,
          accept: const {308},
        );
        offset += n;
        if (r.status == 200 || r.status == 201) item = r.json;
      }
      return item;
    } finally {
      await raf.close();
    }
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
      await drive.download(drive.url('files/${r.id}', {'alt': 'media'}), part);
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

  /// Prima sincronizzazione: Drive dà l'MD5 del contenuto (`md5Checksum`,
  /// qui [RemoteFile.ctag]), confrontato con quello del file locale letto a
  /// pezzi.
  @override
  Future<bool?> sameContent(LocalFile l, RemoteFile r) async {
    if (r.ctag.isEmpty) return null;
    final local = await md5.bind(l.file.openRead()).first;
    return local.toString() == r.ctag.toLowerCase();
  }

  /// Nel cestino di Google Drive (recuperabile per 30 giorni).
  @override
  Future<void> deleteRemote(RemoteFile r) {
    _mine.add(r.id);
    return drive.sendJson(
      'PATCH',
      drive.url('files/${r.id}', {'fields': 'id'}),
      {'trashed': true},
    );
  }
}
