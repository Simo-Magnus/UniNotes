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
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res) {
      bytes.add(chunk);
    }
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return GraphResponse(res.statusCode, bytes.takeBytes(), h);
  } on SocketException catch (e) {
    throw GraphException(0, 'Microsoft non raggiungibile (${e.message}).');
  } finally {
    client.close();
  }
}

/// Client minimo per Microsoft Graph v1.0 (OneDrive e OneNote).
class GraphClient {
  GraphClient(this._token, {GraphTransport? transport})
    : _send = transport ?? ioTransport;

  final Future<String> Function() _token;
  final GraphTransport _send;

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
    if (!r.ok && r.status != 404) {
      String msg;
      try {
        final err = r.json['error'];
        msg = err is Map ? '${err['message'] ?? err['code']}' : r.text;
      } catch (_) {
        msg = r.text;
      }
      throw GraphException(r.status, 'Microsoft Graph ($method $path): $msg');
    }
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
