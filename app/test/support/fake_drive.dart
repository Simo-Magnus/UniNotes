import 'dart:convert';
import 'dart:typed_data';

import 'package:university_notes/features/cloud/graph_client.dart';

/// OneDrive finto in memoria: percorsi → contenuto, con cTag, cestino,
/// cartelle e `/delta` (registro delle modifiche).
class FakeDrive {
  final Map<String, Uint8List> files = {};
  final Map<String, int> versions = {};
  final Set<String> folders = {};
  final List<String> trash = [];
  final Map<String, Uint8List> _sessions = {};

  /// Modifiche in ordine: (numero, percorso).
  final List<(int, String)> changes = [];
  int _seq = 0;
  int requests = 0;
  final List<String> log = [];

  /// Se vero, `/delta` sulle sottocartelle risponde 400 (come OneDrive for
  /// Business).
  bool deltaUnsupported = false;

  String _id(String path) => 'id:$path';
  String _path(String id) => id.substring(3);
  String _ctag(String path) => 'c${versions[path]}';

  GraphResponse _json(int status, Object body) =>
      GraphResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(body))));

  Map<String, Object?> _item(String path) => {
    'id': _id(path),
    'name': path.split('/').last,
    if (files.containsKey(path)) ...{
      'size': files[path]!.length,
      'cTag': _ctag(path),
      'file': <String, Object?>{},
      '@microsoft.graph.downloadUrl':
          'https://dl.example/${Uri.encodeComponent(_id(path))}',
    } else
      'folder': <String, Object?>{'childCount': _kids(path).length},
  };

  Iterable<String> _kids(String parent) => {...folders, ...files.keys}.where(
    (x) => parent.isEmpty
        ? !x.contains('/')
        : x.startsWith('$parent/') &&
              !x.substring(parent.length + 1).contains('/'),
  );

  void _changed(String path) => changes.add((++_seq, path));

  void addFolder(String path) {
    final parts = path.split('/');
    for (var i = 1; i <= parts.length; i++) {
      folders.add(parts.take(i).join('/'));
    }
    _changed(path);
  }

  /// Un file aggiunto «dal sito di OneDrive» (da un altro dispositivo).
  void put(String path, String text) =>
      _put(path, Uint8List.fromList(utf8.encode(text)));

  void _put(String path, Uint8List data) {
    files[path] = data;
    versions[path] = (versions[path] ?? 0) + 1;
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      folders.add(parts.take(i).join('/'));
    }
    _changed(path);
  }

  Future<GraphResponse> call(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    requests++;
    log.add('$method ${url.path}${url.hasQuery ? '?${url.query}' : ''}');
    if (url.host == 'dl.example') {
      return GraphResponse(200, files[_path(url.pathSegments.single)]!);
    }
    if (url.host == 'upload.example') {
      final key = url.pathSegments.single;
      final range = RegExp(r'bytes (\d+)-(\d+)/(\d+)')
          .firstMatch(headers['Content-Range']!)!;
      final total = int.parse(range[3]!);
      if (_sessions[key]!.length != total) _sessions[key] = Uint8List(total);
      final buf = _sessions[key]!;
      buf.setRange(int.parse(range[1]!), int.parse(range[2]!) + 1, body!);
      if (int.parse(range[2]!) + 1 == total) {
        _put(key, buf);
        return _json(201, _item(key));
      }
      return _json(202, {'nextExpectedRanges': []});
    }
    final rest = Uri.decodeComponent(url.path.replaceFirst('/v1.0/', ''));
    if (method == 'GET' && rest.startsWith('me/drive/root:/')) {
      final path = rest.substring('me/drive/root:/'.length);
      return folders.contains(path)
          ? _json(200, _item(path))
          : _json(404, {
              'error': {'code': 'itemNotFound'},
            });
    }
    if (method == 'GET' && rest == 'me/drive/root/children') {
      return _json(200, {'value': _kids('').map(_item).toList()});
    }
    if (method == 'POST' && rest == 'me/drive/root/children') {
      final name = (jsonDecode(utf8.decode(body!)) as Map)['name'] as String;
      if (folders.contains(name)) {
        return _json(409, {
          'error': {'code': 'nameAlreadyExists', 'message': 'esiste'},
        });
      }
      addFolder(name);
      return _json(201, _item(name));
    }
    final postChild = RegExp(r'^me/drive/items/(.+)/children$')
        .firstMatch(rest);
    if (method == 'POST' && postChild != null) {
      final parent = _path(postChild[1]!);
      final name = (jsonDecode(utf8.decode(body!)) as Map)['name'] as String;
      final path = '$parent/$name';
      if (folders.contains(path)) {
        return _json(409, {
          'error': {'code': 'nameAlreadyExists', 'message': 'esiste'},
        });
      }
      addFolder(path);
      return _json(201, _item(path));
    }
    final delta = RegExp(r'^me/drive/items/(.+)/delta$').firstMatch(rest);
    if (method == 'GET' && delta != null) {
      if (deltaUnsupported) {
        return _json(400, {
          'error': {
            'code': 'invalidRequest',
            'message': 'delta solo sulla radice',
          },
        });
      }
      final folder = _path(delta[1]!);
      final token = url.queryParameters['token'];
      final since = token == 'latest' ? _seq : int.tryParse(token ?? '') ?? 0;
      final changed = token == 'latest'
          ? const <String>[]
          : [
              for (final c in changes)
                if (c.$1 > since &&
                    (c.$2 == folder || c.$2.startsWith('$folder/')))
                  c.$2,
            ];
      return _json(200, {
        'value': [
          // Come Graph: la cartella stessa compare tra gli elementi.
          if (changed.isNotEmpty) _item(folder),
          for (final p in changed.toSet())
            if (p != folder)
              files.containsKey(p) || folders.contains(p)
                  ? _item(p)
                  : {'id': _id(p), 'deleted': <String, Object?>{}},
        ],
        '@odata.deltaLink':
            'https://graph.microsoft.com/v1.0/me/drive/items/${Uri.encodeComponent(_id(folder))}/delta?token=$_seq',
      });
    }
    final children = RegExp(r'^me/drive/items/(.+)/children$').firstMatch(rest);
    if (method == 'GET' && children != null) {
      final parent = _path(children[1]!);
      return _json(200, {'value': _kids(parent).map(_item).toList()});
    }
    final content = RegExp(r'^me/drive/root:/(.+):/content$').firstMatch(rest);
    if (method == 'PUT' && content != null) {
      _put(content[1]!, Uint8List.fromList(body!));
      return _json(201, _item(content[1]!));
    }
    final session = RegExp(r'^me/drive/root:/(.+):/createUploadSession$')
        .firstMatch(rest);
    if (method == 'POST' && session != null) {
      _sessions[session[1]!] = Uint8List(0);
      return _json(200, {
        'uploadUrl':
            'https://upload.example/${Uri.encodeComponent(session[1]!)}',
      });
    }
    final item = RegExp(r'^me/drive/items/(.+)$').firstMatch(rest);
    if (method == 'DELETE' && item != null) {
      final path = _path(item[1]!);
      files.remove(path);
      // una cartella va nel cestino con tutto il contenuto
      if (folders.remove(path)) {
        folders.removeWhere((f) => f.startsWith('$path/'));
        files.removeWhere((f, _) => f.startsWith('$path/'));
      }
      trash.add(path);
      _changed(path);
      return GraphResponse(204, Uint8List(0));
    }
    if (method == 'GET' && rest == 'me') {
      return _json(200, {
        'displayName': 'Studente Prova',
        'mail': 'studente@example.com',
      });
    }
    return _json(400, {
      'error': {'message': 'non gestito: $method $rest'},
    });
  }
}
