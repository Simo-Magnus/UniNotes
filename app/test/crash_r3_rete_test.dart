import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/core/services/file_downloader.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/cloud/folder_sync.dart';
import 'package:university_notes/features/cloud/graph_client.dart';

/// Caccia ai crash, terzo giro, categoria «rete e download»: risposte lente,
/// troncate, pagine HTML al posto dei file (Wi‑Fi con pagina di accesso),
/// 416/206 sbagliati, 429, certificati non validi, download doppi dello
/// stesso file. Server HTTP locali (127.0.0.1); senza testWidgets: il
/// binding dei widget sostituirebbe l'HttpClient vero.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('r3_rete_');
  });
  tearDown(() async {
    networkIdleTimeout = const Duration(seconds: 60);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// Server locale: [handle] risponde a ogni richiesta.
  Future<HttpServer> serve(Future<void> Function(HttpRequest r) handle) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((r) async {
      try {
        await handle(r);
      } catch (_) {}
    });
    addTearDown(() => s.close(force: true));
    return s;
  }

  Uri at(HttpServer s, String path) =>
      Uri.parse('http://127.0.0.1:${s.port}$path');

  FileDownloader downloader() => FileDownloader(freeSpace: (_) async => null);

  final body = List<int>.generate(1500, (i) => i % 251);

  group('FileDownloader', () {
    test('dati che si fermano a metà: errore dopo l\'attesa massima, non un '
        'download appeso per sempre', () async {
      networkIdleTimeout = const Duration(milliseconds: 400);
      final never = Completer<void>();
      addTearDown(() => never.isCompleted ? null : never.complete());
      final s = await serve((req) async {
        req.response.contentLength = 10000;
        req.response.add(List.filled(100, 1));
        await req.response.flush();
        await never.future;
      });
      final f = File(p.join(tmp.path, 'm.bin'));
      await expectLater(
        downloader()
            .download(at(s, '/m'), f)
            .drain<void>()
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<DownloadException>()),
      );
      expect(f.existsSync(), isFalse);
    });

    test('server che non risponde mai: errore dopo l\'attesa massima',
        () async {
      networkIdleTimeout = const Duration(milliseconds: 400);
      final never = Completer<void>();
      addTearDown(() => never.isCompleted ? null : never.complete());
      final s = await serve((req) => never.future);
      await expectLater(
        downloader()
            .download(at(s, '/m'), File(p.join(tmp.path, 'm.bin')))
            .drain<void>()
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<DownloadException>()),
      );
    });

    test('pagina HTML (Wi‑Fi con pagina di accesso) al posto del file: '
        'scartata, il download a metà resta per riprendere', () async {
      final s = await serve((req) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html><body>Accedi alla rete Wi-Fi</body></html>');
        await req.response.close();
      });
      final f = File(p.join(tmp.path, 'ggml-small.bin'));
      final part = File('${f.path}.part')
        ..writeAsBytesSync(List.filled(1000, 7));
      await expectLater(
        downloader().download(at(s, '/m'), f).drain<void>(),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('pagina'),
          ),
        ),
      );
      expect(f.existsSync(), isFalse);
      expect(part.lengthSync(), 1000);
    });

    test('416 con una parte più lunga del file: non diventa il file, si '
        'riscarica da capo', () async {
      final s = await serve((req) async {
        final range = req.headers.value('range');
        if (range != null) {
          final from = int.parse(range.split('=')[1].split('-')[0]);
          if (from >= body.length) {
            req.response.statusCode = 416;
            req.response.headers.set('content-range', 'bytes */${body.length}');
            await req.response.close();
            return;
          }
          req.response.statusCode = 206;
          req.response.headers.set(
            'content-range',
            'bytes $from-${body.length - 1}/${body.length}',
          );
          req.response.add(body.sublist(from));
        } else {
          req.response.add(body);
        }
        await req.response.close();
      });
      final f = File(p.join(tmp.path, 'm.bin'));
      File('${f.path}.part').writeAsBytesSync(List.filled(2000, 9));
      await downloader().download(at(s, '/m'), f).drain<void>();
      expect(f.readAsBytesSync(), body);
    });

    test('206 con un intervallo diverso da quello chiesto: niente file '
        'doppio, si riscarica da capo', () async {
      final s = await serve((req) async {
        if (req.headers.value('range') != null) {
          // server che ignora l'inizio chiesto e manda tutto il file
          req.response.statusCode = 206;
          req.response.headers.set(
            'content-range',
            'bytes 0-${body.length - 1}/${body.length}',
          );
        }
        req.response.add(body);
        await req.response.close();
      });
      final f = File(p.join(tmp.path, 'm.bin'));
      File('${f.path}.part').writeAsBytesSync(body.sublist(0, 1000));
      await downloader().download(at(s, '/m'), f).drain<void>();
      expect(f.readAsBytesSync(), body);
    });

    test('due download dello stesso file insieme: uno solo scarica, l\'altro '
        'lo aspetta; file intero e giusto', () async {
      final big = List<int>.generate(300000, (i) => (i * 7) % 256);
      var hits = 0;
      final s = await serve((req) async {
        hits++;
        req.response.contentLength = big.length;
        for (var i = 0; i < big.length; i += 30000) {
          req.response.add(big.sublist(i, i + 30000));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await req.response.close();
      });
      final f = File(p.join(tmp.path, 'm.bin'));
      final sha = sha256.convert(big).toString();
      await Future.wait([
        downloader().download(at(s, '/m'), f, sha256: sha).drain<void>(),
        downloader().download(at(s, '/m'), f, sha256: sha).drain<void>(),
      ]);
      expect(hits, 1);
      expect(f.readAsBytesSync(), big);
      expect(File('${f.path}.part').existsSync(), isFalse);
    });

    test('https verso un server che non parla TLS (certificato o rete con '
        'pagina di accesso): errore chiaro', () async {
      final s = await serve((req) async {
        await req.response.close();
      });
      await expectLater(
        downloader()
            .download(
              Uri.parse('https://127.0.0.1:${s.port}/m'),
              File(p.join(tmp.path, 'm.bin')),
            )
            .drain<void>()
            .timeout(const Duration(seconds: 20)),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('sicura'),
          ),
        ),
      );
    });

    test('cartella di destinazione impossibile (al suo posto c\'è un file): '
        'errore del download, non un\'eccezione del disco', () async {
      final s = await serve((req) async {
        req.response.add(body);
        await req.response.close();
      });
      final blocker = File(p.join(tmp.path, 'blocco'))..writeAsStringSync('x');
      await expectLater(
        downloader()
            .download(at(s, '/m'), File(p.join(blocker.path, 'm.bin')))
            .drain<void>(),
        throwsA(isA<DownloadException>()),
      );
    });

    test('429 con Retry-After: il messaggio dice quando riprovare', () async {
      final s = await serve((req) async {
        req.response.statusCode = 429;
        req.response.headers.set('retry-after', '120');
        await req.response.close();
      });
      await expectLater(
        downloader()
            .download(at(s, '/m'), File(p.join(tmp.path, 'm.bin')))
            .drain<void>(),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('2 minuti'),
          ),
        ),
      );
    });
  });

  group('whisper.cpp e ffmpeg (Windows)', () {
    test('due installazioni di whisper.cpp insieme (due modelli scaricati '
        'subito, doppio tocco): un solo download, programma pronto', () async {
      final zip = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile.string('Release/whisper-cli.exe', 'MZ finto'))
          ..addFile(
            ArchiveFile.bytes(
              'Release/whisper.dll',
              List<int>.generate(200000, (i) => i % 256),
            ),
          ),
      );
      var hits = 0;
      final s = await serve((req) async {
        hits++;
        req.response.contentLength = zip.length;
        for (var i = 0; i < zip.length; i += 20000) {
          req.response.add(zip.sublist(i, (i + 20000).clamp(0, zip.length)));
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        await req.response.close();
      });
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        freeSpace: (_) async => null,
        binariesUrl: at(s, '/whisper-bin-x64.zip'),
      );
      await Future.wait([w.installCli().drain<void>(), w.installCli().drain<void>()]);
      expect(hits, 1);
      final cli = await w.findCli();
      expect(cli, isNotNull);
      expect(cli!.readAsStringSync(), 'MZ finto');
    });

    test('pagina di accesso al posto dell\'archivio di ffmpeg: lo dice, '
        'nessun ffmpeg a metà', () async {
      final s = await serve((req) async {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html><body>Accedi alla rete</body></html>');
        await req.response.close();
      });
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        freeSpace: (_) async => null,
        ffmpegUrl: at(s, '/ffmpeg.zip'),
      );
      await expectLater(
        w.installFfmpeg().drain<void>(),
        throwsA(
          isA<WhisperException>().having(
            (e) => e.message,
            'message',
            contains('pagina'),
          ),
        ),
      );
      final dir = Directory(p.join(tmp.path, 'whisper', 'ffmpeg'));
      expect(File(p.join(dir.path, 'ffmpeg.exe')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'ffmpeg.zip')).existsSync(), isFalse);
    });

    test('archivio di ffmpeg non valido: errore del download (non '
        'un\'eccezione dell\'archivio)', () async {
      final s = await serve((req) async {
        req.response.headers.contentType = ContentType.binary;
        // inizio di uno zip vero (intestazione locale) e poi niente
        req.response.add([0x50, 0x4b, 0x03, 0x04, ...List.filled(40, 0)]);
        await req.response.close();
      });
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        freeSpace: (_) async => null,
        ffmpegUrl: at(s, '/ffmpeg.zip'),
      );
      await expectLater(
        w.installFfmpeg().drain<void>(),
        throwsA(isA<WhisperException>()),
      );
      final dir = Directory(p.join(tmp.path, 'whisper', 'ffmpeg'));
      expect(File(p.join(dir.path, 'ffmpeg.exe')).existsSync(), isFalse);
    });
  });

  group('Microsoft Graph e Google Drive', () {
    test('200 con una pagina HTML al posto del JSON: errore di rete (stato '
        '0), non FormatException', () async {
      final g = GraphClient(
        () async => 'token',
        transport: (method, url, {headers = const {}, body}) async =>
            GraphResponse(
              200,
              utf8.encode('<html><body>Accedi alla rete</body></html>'),
              const {'content-type': 'text/html'},
            ),
      );
      Object? err;
      try {
        await g.list('me/drive/root/children');
      } catch (e) {
        err = e;
      }
      expect(err, isA<GraphException>().having((e) => e.status, 'status', 0));
      expect(isNetworkError(err!), isTrue);
    });

    test('429 (troppe richieste): la sincronizzazione si ferma al primo file '
        'invece di riprovare con tutti', () async {
      final root = Directory(p.join(tmp.path, 'Corsi'))..createSync();
      for (final n in ['a.txt', 'b.txt', 'c.txt']) {
        File(p.join(root.path, n)).writeAsStringSync(n);
      }
      final sync = _Throttled(root, File(p.join(tmp.path, 'stato.json')));
      Object? err;
      try {
        await sync.run();
      } catch (e) {
        err = e;
      }
      expect(sync.uploads, 1);
      expect(err, isA<GraphException>());
    });
  });

  group('accesso OAuth', () {
    test('risposta del server dei token non UTF-8: errore dell\'accesso, non '
        'FormatException', () async {
      final s = await serve((req) async {
        await req.drain<void>();
        req.response.statusCode = 502;
        req.response.add([0xff, 0xfe, 0x00, 0xc3]);
        await req.response.close();
      });
      final oauth = LoopbackOAuth(
        providerName: 'Microsoft',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: at(s, '/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => false,
      );
      await expectLater(oauth.refresh('r'), throwsA(isA<OAuthException>()));
    });
  });

  group('catalogo', () {
    test('https verso un server che non parla TLS: «senza rete», non '
        'HandshakeException', () async {
      final s = await serve((req) async {
        await req.response.close();
      });
      final url = Uri.parse('https://127.0.0.1:${s.port}/meta.json');
      await expectLater(
        CatalogService.defaultFetcher(timeout: const Duration(seconds: 10))(url),
        throwsA(isA<CatalogOfflineException>()),
      );
      await expectLater(
        CatalogService.defaultFileFetcher(
          timeout: const Duration(seconds: 10),
        )(url, File(p.join(tmp.path, 'meta.json'))),
        throwsA(isA<CatalogOfflineException>()),
      );
    });
  });
}

/// Servizio che risponde sempre 429 ai caricamenti.
class _Throttled extends FolderSync {
  _Throttled(Directory root, File state)
    : super(localRoot: root, remoteFolder: 'UniNotes/Corsi', stateFile: state);

  int uploads = 0;

  @override
  String get serviceName => 'OneDrive';

  @override
  String get localTrashDir => '.cestino';

  @override
  Future<Map<String, RemoteFile>> listRemote() async => {};

  @override
  Future<SyncedFile> upload(String rel, File f) async {
    uploads++;
    throw GraphException(429, 'Microsoft Graph (PUT $rel): Too Many Requests');
  }

  @override
  Future<SyncedFile> download(String rel, RemoteFile r) =>
      throw UnimplementedError();

  @override
  Future<void> deleteRemote(RemoteFile r) async {}
}
