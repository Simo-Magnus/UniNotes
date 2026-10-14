import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:university_notes/features/cloud/google_drive_client.dart';

class FakeItem {
  FakeItem(this.id, this.name, this.parent, this.mime, [List<int>? bytes])
    : bytes = bytes ?? const [];
  final String id;
  String name;
  final String parent;
  final String mime;
  List<int> bytes;
  bool trashed = false;

  bool get folder => mime == GoogleDriveClient.folderMime;

  Map<String, Object?> json() => {
    'id': id,
    'name': name,
    'mimeType': mime,
    if (!folder && !mime.startsWith('application/vnd.google-apps.')) ...{
      'size': '${bytes.length}',
      'md5Checksum': md5.convert(bytes).toString(),
    },
  };
}

/// Google Drive v3 finto in memoria: le sole chiamate usate dall'app.
class FakeGoogleDrive {
  final Map<String, FakeItem> items = {};
  final List<String> changes = [];
  final Map<String, (String?, String?, String, String, List<int>)> _sessions =
      {};
  int _next = 0;
  int requests = 0;
  int resumableChunks = 0;

  String _id() => 'id${_next++}';

  /// Percorsi dei file (non cartelle, non nel cestino) → contenuto.
  Map<String, String> get files => {
    for (final it in items.values)
      if (!it.folder && !it.trashed && _path(it) != null)
        _path(it)!: utf8.decode(it.bytes, allowMalformed: true),
  };

  List<String> get trash => [
    for (final it in items.values)
      if (it.trashed) _path(it) ?? it.name,
  ];

  List<String> get folders => [
    for (final it in items.values)
      if (it.folder && !it.trashed) _path(it) ?? it.name,
  ]..sort();

  String? _path(FakeItem it) {
    if (it.parent == 'root') return it.name;
    final p = items[it.parent];
    if (p == null) return null;
    final pp = _path(p);
    return pp == null ? null : '$pp/${it.name}';
  }

  /// Aggiunge un elemento creato «dal sito» (es. un documento Google).
  FakeItem add(String parent, String name, String mime, [List<int>? b]) {
    final it = FakeItem(_id(), name, parent, mime, b);
    items[it.id] = it;
    changes.add(it.id);
    return it;
  }

  GraphResponse _json(Object body, [int status = 200]) =>
      GraphResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(body))));

  static String _unquote(String v) =>
      v.replaceAll(r"\'", "'").replaceAll(r'\\', r'\');

  Future<GraphResponse> call(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    requests++;
    final path = url.path;
    final q = url.queryParameters;
    if (path.startsWith('/upload/drive/v3/session/')) {
      return _chunk(path.split('/').last, headers, body ?? const []);
    }
    if (path.startsWith('/upload/drive/v3/files')) {
      return _upload(method, path, q, headers, body ?? const []);
    }
    if (path == '/drive/v3/about') {
      return _json({
        'user': {'displayName': 'Studente', 'emailAddress': 's@gmail.com'},
      });
    }
    if (path == '/drive/v3/changes/startPageToken') {
      return _json({'startPageToken': '${changes.length}'});
    }
    if (path == '/drive/v3/changes') {
      final from = int.parse(q['pageToken']!);
      return _json({
        'newStartPageToken': '${changes.length}',
        'changes': [
          for (final id in changes.skip(from))
            {
              'fileId': id,
              'file': {
                'parents': [?items[id]?.parent],
              },
            },
        ],
      });
    }
    if (path == '/drive/v3/files' && method == 'GET') {
      final query = q['q']!;
      final parent = RegExp(r"'([^']+)' in parents").firstMatch(query)![1]!;
      final name = RegExp(
        r"name = '((?:[^'\\]|\\.)*)'",
      ).firstMatch(query)?.group(1);
      final onlyFolders = query.contains('mimeType =');
      final out = [
        for (final it in items.values)
          if (it.parent == parent &&
              !it.trashed &&
              (name == null || it.name == _unquote(name)) &&
              (!onlyFolders || it.folder))
            it.json(),
      ];
      return _json({'files': out});
    }
    if (path == '/drive/v3/files' && method == 'POST') {
      final m = jsonDecode(utf8.decode(body!)) as Map;
      final it = add(
        (m['parents'] as List).first as String,
        m['name'] as String,
        m['mimeType'] as String,
      );
      return _json({'id': it.id});
    }
    final id = path.split('/').last;
    final it = items[id];
    if (it == null) return _json({'error': {'message': 'not found'}}, 404);
    if (method == 'GET' && q['alt'] == 'media') {
      return GraphResponse(200, Uint8List.fromList(it.bytes));
    }
    if (method == 'PATCH') {
      final m = jsonDecode(utf8.decode(body!)) as Map;
      if (m['trashed'] == true) it.trashed = true;
      changes.add(it.id);
      return _json({'id': it.id});
    }
    return _json({'error': {'message': 'unsupported $method $path'}}, 400);
  }

  GraphResponse _done(FakeItem it) {
    changes.add(it.id);
    return _json(it.json());
  }

  GraphResponse _upload(
    String method,
    String path,
    Map<String, String> q,
    Map<String, String> headers,
    List<int> body,
  ) {
    final type = q['uploadType'];
    final existing = path.endsWith('/files') ? null : path.split('/').last;
    if (type == 'media') {
      final it = items[existing]!..bytes = body;
      return _done(it);
    }
    if (type == 'multipart') {
      final boundary = headers['Content-Type']!.split('boundary=').last;
      final text = latin1.decode(body);
      final parts = text.split('--$boundary');
      final meta = jsonDecode(
        utf8.decode(latin1.encode(parts[1].split('\r\n\r\n')[1].trim())),
      ) as Map;
      final media = parts[2].substring(parts[2].indexOf('\r\n\r\n') + 4);
      final bytes = latin1.encode(media.substring(0, media.length - 2));
      final it = add(
        (meta['parents'] as List).first as String,
        meta['name'] as String,
        'application/octet-stream',
        bytes,
      );
      return _done(it);
    }
    // resumable: si apre una sessione
    final m = jsonDecode(utf8.decode(body)) as Map;
    final sid = 's${_next++}';
    _sessions[sid] = (
      existing,
      (m['parents'] as List?)?.first as String?,
      m['name'] as String? ?? '',
      headers['X-Upload-Content-Length']!,
      <int>[],
    );
    return GraphResponse(200, Uint8List(0), {
      'location': 'https://www.googleapis.com/upload/drive/v3/session/$sid',
    });
  }

  GraphResponse _chunk(String sid, Map<String, String> headers, List<int> b) {
    resumableChunks++;
    final s = _sessions[sid]!;
    s.$5.addAll(b);
    if (s.$5.length < int.parse(s.$4)) return GraphResponse(308, Uint8List(0));
    final it = s.$1 != null
        ? (items[s.$1]!..bytes = s.$5)
        : add(s.$2!, s.$3, 'application/octet-stream', s.$5);
    return _done(it);
  }
}
