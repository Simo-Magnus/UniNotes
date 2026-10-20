import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Risposta HTTP essenziale (corpo già letto).
class GraphResponse {
  const GraphResponse(this.status, this.body, [this.headers = const {}]);
  final int status;
  final Uint8List body;
  final Map<String, String> headers;

  bool get ok => status >= 200 && status < 300;
  String get text => utf8.decode(body, allowMalformed: true);
  Map<String, Object?> get json {
    if (body.isEmpty) return const {};
    final v = jsonDecode(text);
    return v is Map ? v.cast<String, Object?>() : const {};
  }
}

/// Trasporto HTTP (nei test: un server finto in memoria).
typedef GraphTransport = Future<GraphResponse> Function(
  String method,
  Uri url, {
  Map<String, String> headers,
  List<int>? body,
});

class GraphException implements Exception {
  GraphException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// Nome del servizio nei messaggi di rete, dall'indirizzo della richiesta
/// (lo stesso trasporto serve Microsoft Graph e Google Drive).
String networkServiceName(Uri url) {
  final h = url.host.toLowerCase();
  bool any(List<String> domains) =>
      domains.any((d) => h == d || h.endsWith('.$d'));
  if (any(const ['googleapis.com', 'google.com', 'googleusercontent.com'])) {
    return 'Google';
  }
  if (any(const [
    'microsoft.com',
    'microsoftonline.com',
    'live.com',
    '1drv.com',
    'sharepoint.com',
    'office.com',
    'onenote.com',
  ])) {
    return 'Microsoft';
  }
  return 'Il servizio';
}

GraphException _offline(Uri url, SocketException e) => GraphException(
  0,
  '${networkServiceName(url)} non raggiungibile (${e.message}).',
);

Future<GraphResponse> ioTransport(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  List<int>? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close();
    return GraphResponse(res.statusCode, await _readAll(res), _headers(res));
  } on SocketException catch (e) {
    throw _offline(url, e);
  } finally {
    client.close();
  }
}

Future<Uint8List> _readAll(Stream<List<int>> s) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in s) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Map<String, String> _headers(HttpClientResponse res) {
  final h = <String, String>{};
  res.headers.forEach((k, v) => h[k] = v.join(','));
  return h;
}

/// Scaricamento (GET) scritto in [to]: per una risposta 2xx il corpo va nel
/// file e la risposta torna senza corpo; per gli altri stati il corpo (il
/// messaggio d'errore) torna nella risposta e [to] non si scrive.
typedef GraphDownload = Future<GraphResponse> Function(
  Uri url,
  File to, {
  Map<String, String> headers,
});

/// Scaricamento in streaming: il file arriva a pezzi sul disco, senza
/// tenerlo tutto in memoria (libri e registrazioni possono essere grandi).
Future<GraphResponse> ioDownload(
  Uri url,
  File to, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.getUrl(url);
    headers.forEach(req.headers.set);
    final res = await req.close();
    final h = _headers(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return GraphResponse(res.statusCode, await _readAll(res), h);
    }
    final sink = to.openWrite();
    try {
      await sink.addStream(res);
    } catch (_) {
      await sink.close().catchError((_) => null);
      rethrow;
    }
    await sink.close();
    return GraphResponse(res.statusCode, Uint8List(0), h);
  } on SocketException catch (e) {
    throw _offline(url, e);
  } finally {
    client.close();
  }
}

/// Scaricamento con un [GraphTransport] qualsiasi (nei test: i server finti):
/// la risposta arriva intera e si scrive nel file.
GraphDownload bufferedDownload(GraphTransport send) =>
    (url, to, {headers = const {}}) async {
      final r = await send('GET', url, headers: headers);
      if (!r.ok) return r;
      await to.writeAsBytes(r.body, flush: true);
      return GraphResponse(r.status, Uint8List(0), r.headers);
    };

/// Client minimo per Microsoft Graph v1.0 (OneDrive e OneNote).
class GraphClient {
  GraphClient(this._token, {GraphTransport? transport, GraphDownload? download})
    : _send = transport ?? ioTransport,
      _download =
          download ??
          (transport == null ? ioDownload : bufferedDownload(transport));

  final Future<String> Function() _token;
  final GraphTransport _send;
  final GraphDownload _download;

  static final base = Uri.https('graph.microsoft.com', '/v1.0/');

  Uri url(String path, [Map<String, String>? query]) {
    final u = path.startsWith('https://')
        ? Uri.parse(path)
        : base.resolve(path);
    return query == null ? u : u.replace(queryParameters: query);
  }

  /// Percorso OneDrive codificato per l'indirizzamento `root:/percorso:`.
  static String drivePath(String path) => path
      .split('/')
      .where((s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');

  Future<GraphResponse> request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String> headers = const {},
    List<int>? body,
    bool auth = true,
  }) async {
    final h = {
      if (auth) 'Authorization': 'Bearer ${await _token()}',
      ...headers,
    };
    final r = await _send(method, url(path, query), headers: h, body: body);
    if (!r.ok && r.status != 404) _fail(r, method, path);
    return r;
  }

  Never _fail(GraphResponse r, String method, String path) {
    String msg;
    try {
      final err = r.json['error'];
      msg = err is Map ? '${err['message'] ?? err['code']}' : r.text;
    } catch (_) {
      msg = r.text;
    }
    throw GraphException(r.status, 'Microsoft Graph ($method $path): $msg');
  }

  /// Contenuto di un file scritto in [to] a pezzi ([GraphDownload]); 404
  /// non è un errore (risposta non `ok`, [to] non scritto).
  Future<GraphResponse> download(
    String path,
    File to, {
    bool auth = true,
  }) async {
    final h = {if (auth) 'Authorization': 'Bearer ${await _token()}'};
    final r = await _download(url(path), to, headers: h);
    if (!r.ok && r.status != 404) _fail(r, 'GET', path);
    return r;
  }

  Future<Map<String, Object?>?> getJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    final r = await request('GET', path, query: query);
    return r.status == 404 ? null : r.json;
  }

  /// Tutte le pagine di una collezione (`value` + `@odata.nextLink`).
  Future<List<Map<String, Object?>>> list(
    String path, [
    Map<String, String>? query,
  ]) async {
    final out = <Map<String, Object?>>[];
    String? next = path;
    var q = query;
    while (next != null) {
      final page = await getJson(next, q);
      if (page == null) break;
      out.addAll(
        (page['value'] as List? ?? const []).whereType<Map>().map(
          (m) => m.cast<String, Object?>(),
        ),
      );
      next = page['@odata.nextLink'] as String?;
      q = null;
    }
    return out;
  }

  Future<Map<String, Object?>> sendJson(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final r = await request(
      method,
      path,
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode(jsonEncode(body)),
    );
    return r.json;
  }
}
