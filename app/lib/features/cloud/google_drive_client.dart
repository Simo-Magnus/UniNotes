import 'dart:convert';
import 'dart:io';

import 'graph_client.dart'
    show
        GraphDownload,
        GraphResponse,
        GraphTransport,
        bufferedDownload,
        ioDownload,
        ioTransport;
import 'onedrive_folders.dart';

export 'graph_client.dart' show GraphResponse, GraphTransport;

class DriveException implements Exception {
  DriveException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// Client minimo per Google Drive API v3 con lo scope `drive.file`: ogni
/// richiesta (ricerca, elenco, modifiche) vede solo ciò che l'app ha creato
/// o che lo studente ha scelto con «Importa da Drive». I file messi nella
/// cartella UniNotes dal sito o dalle app di Drive restano invisibili finché
/// non si importano; per Google una cartella creata da un'altra
/// registrazione dell'app (un altro progetto Google Cloud) non esiste.
class GoogleDriveClient {
  GoogleDriveClient(
    this._token, {
    GraphTransport? transport,
    GraphDownload? download,
  }) : _send = transport ?? ioTransport,
       _download =
           download ??
           (transport == null ? ioDownload : bufferedDownload(transport));

  final Future<String> Function() _token;
  final GraphTransport _send;
  final GraphDownload _download;

  static final base = Uri.https('www.googleapis.com', '/drive/v3/');
  static final uploadBase = Uri.https(
    'www.googleapis.com',
    '/upload/drive/v3/',
  );

  static const folderMime = 'application/vnd.google-apps.folder';

  Uri url(String path, [Map<String, String>? query]) {
    final u = path.startsWith('https://')
        ? Uri.parse(path)
        : base.resolve(path);
    return query == null
        ? u
        : u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  /// Richiesta autenticata. Gli stati in [accept] (oltre ai 2xx) non sono
  /// errori: es. 404 (file assente) o 308 (caricamento da continuare).
  Future<GraphResponse> request(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Set<int> accept = const {404},
  }) async {
    final h = {'Authorization': 'Bearer ${await _token()}', ...headers};
    final r = await _send(method, url, headers: h, body: body);
    if (!r.ok && !accept.contains(r.status)) _fail(r, method, url);
    return r;
  }

  Never _fail(GraphResponse r, String method, Uri url) {
    String msg;
    try {
      final err = r.json['error'];
      msg = err is Map ? '${err['message'] ?? err['code']}' : r.text;
    } catch (_) {
      msg = r.text;
    }
    throw DriveException(r.status, 'Google Drive ($method ${url.path}): $msg');
  }

  /// Contenuto di un file scritto in [to] a pezzi ([GraphDownload]), senza
  /// tenerlo tutto in memoria; ogni stato non 2xx è un errore.
  Future<void> download(Uri url, File to) async {
    final h = {'Authorization': 'Bearer ${await _token()}'};
    final r = await _download(url, to, headers: h);
    if (!r.ok) _fail(r, 'GET', url);
  }

  Future<Map<String, Object?>?> getJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    final r = await request('GET', url(path, query));
    return r.status == 404 ? null : r.json;
  }

  Future<Map<String, Object?>> sendJson(
    String method,
    Uri url,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) async {
    final r = await request(
      method,
      url,
      headers: {'Content-Type': 'application/json; charset=UTF-8', ...headers},
      body: utf8.encode(jsonEncode(body)),
    );
    return r.json;
  }

  /// Valore per le query `q` di Drive (apici e barre rovesciate protetti).
  static String quote(String v) =>
      "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// Tutti i file che rispondono a [q] (pagine `nextPageToken`).
  ///
  /// Con [strict] (elenco dei file da sincronizzare) una risposta 404 o
  /// senza `files` è un errore, non un elenco vuoto: i file mancanti
  /// sembrerebbero «eliminati su Google Drive».
  Future<List<Map<String, Object?>>> files(
    String q, {
    String fields = 'id,name,mimeType,size,md5Checksum',
    bool strict = false,
  }) async {
    final out = <Map<String, Object?>>[];
    String? page;
    do {
      final r = await getJson('files', {
        'q': q,
        'fields': 'nextPageToken,files($fields)',
        'pageSize': '1000',
        'spaces': 'drive',
        'pageToken': ?page,
      });
      if (r == null) {
        if (strict) {
          throw DriveException(404, 'Google Drive: elenco non disponibile');
        }
        break;
      }
      final list = r['files'];
      if (strict && list is! List) {
        throw DriveException(502, 'Google Drive: risposta inattesa (elenco mancante)');
      }
      out.addAll(
        (list is List ? list : const []).whereType<Map>().map(
          (m) => m.cast<String, Object?>(),
        ),
      );
      final next = r['nextPageToken'];
      page = next is String ? next : null;
    } while (page != null);
    return out;
  }

  /// Contenuto (non nel cestino) della cartella [parentId]; [strict] come
  /// in [files].
  Future<List<Map<String, Object?>>> children(
    String parentId, {
    bool strict = false,
  }) => files(
    '${quote(parentId)} in parents and trashed = false',
    strict: strict,
  );

  /// Sottocartella [name] di [parentId] (`root` = Il mio Drive), se c'è.
  Future<String?> findFolder(String parentId, String name) async {
    final found = await files(
      'name = ${quote(name)} and ${quote(parentId)} in parents and '
      "mimeType = '$folderMime' and trashed = false",
      fields: 'id',
    );
    return found.isEmpty ? null : found.first['id'] as String?;
  }

  Future<String> createFolder(String parentId, String name) async {
    final r = await sendJson('POST', url('files', {'fields': 'id'}), {
      'name': name,
      'mimeType': folderMime,
      'parents': [parentId],
    });
    return r['id'] as String;
  }

  /// Id della cartella [path] («UniNotes/Corsi»), creando le parti
  /// che mancano se [create]; null se manca e non va creata.
  Future<String?> folderPath(String path, {bool create = true}) async {
    var id = 'root';
    for (final part in path.split('/').where((s) => s.trim().isNotEmpty)) {
      final found = await findFolder(id, part);
      if (found != null) {
        id = found;
      } else if (create) {
        id = await createFolder(id, part);
      } else {
        return null;
      }
    }
    return id;
  }

  /// Dati di un file o di una cartella (null se assente o non accessibile
  /// all'app: con `drive.file` Google risponde 404).
  Future<Map<String, Object?>?> fileMeta(
    String id, {
    String fields = 'id,name,mimeType,parents,size,trashed',
  }) => getJson('files/$id', {'fields': fields});

  /// Copia del file [id] nella cartella [parentId] col nome [name]: la copia
  /// è creata dall'app, quindi si sincronizza su tutti i dispositivi.
  Future<String> copyFile(String id, String parentId, String name) async {
    final r = await sendJson('POST', url('files/$id/copy', {'fields': 'id'}), {
      'name': name,
      'parents': [parentId],
    });
    return r['id'] as String;
  }

  /// Nome e indirizzo dell'account (`about.user`).
  Future<String> accountLabel() async {
    final r = await getJson('about', {
      'fields': 'user(displayName,emailAddress)',
    });
    final u = r?['user'];
    if (u is! Map) return '';
    return [
      u['displayName'],
      u['emailAddress'],
    ].whereType<String>().join(' · ');
  }
}

/// Cartelle di Google Drive per il selettore (come per OneDrive).
class GoogleDriveFolderBrowser extends FolderBrowser {
  GoogleDriveFolderBrowser(this.drive);
  final GoogleDriveClient drive;

  @override
  String get serviceName => 'Google Drive';

  @override
  DriveFolder get root =>
      const DriveFolder(id: 'root', name: 'Il mio Drive', path: '');

  @override
  Future<List<DriveFolder>> children(DriveFolder parent) async {
    final items = await drive.files(
      '${GoogleDriveClient.quote(parent.id)} in parents and '
      "mimeType = '${GoogleDriveClient.folderMime}' and trashed = false",
      fields: 'id,name',
    );
    return [
      for (final it in items)
        DriveFolder(
          id: '${it['id']}',
          name: '${it['name']}',
          path: parent.childPath('${it['name']}'),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  @override
  String? validate(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Scrivi un nome.';
    if (n.contains('/')) return 'Il nome non può contenere /';
    return null;
  }

  @override
  Future<DriveFolder> createFolder(DriveFolder parent, String name) async {
    final n = name.trim();
    final err = validate(n);
    if (err != null) throw DriveException(400, err);
    if (await drive.findFolder(parent.id, n) != null) {
      throw DriveException(409, 'Esiste già una cartella «$n» qui.');
    }
    final id = await drive.createFolder(parent.id, n);
    return DriveFolder(id: id, name: n, path: parent.childPath(n));
  }
}
