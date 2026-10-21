import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/file_downloader.dart';
import 'package:university_notes/core/services/whisper_service.dart';

void main() {
  group('download di Parakeet', () {
    late Directory tmp;
    late HttpServer server;
    final bodies = <String, List<int>>{
      'tokens.txt': List.generate(3000, (i) => i % 97),
      'encoder.int8.onnx': List.generate(120000, (i) => i % 251),
    };
    final hits = <String>[];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pk_dl_');
      hits.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final name = req.uri.pathSegments.last;
        hits.add(name);
        final body = bodies[name];
        if (body == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        req.response.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    ParakeetService service(List<ParakeetFile> files, {int? free}) =>
        ParakeetService(
          baseDir: () async => tmp,
          host: WhisperHost.windows,
          downloader: FileDownloader(freeSpace: (_) async => free),
          fileUrl: (f) =>
              Uri.parse('http://127.0.0.1:${server.port}/${f.name}'),
          files: files,
        );

    ParakeetFile file(String name, {String? sha}) => ParakeetFile(
      name,
      bodies[name]!.length,
      sha ?? sha256.convert(bodies[name]!).toString(),
    );

    test('tutti i file, avanzamento complessivo, poi installato', () async {
      final pk = service([file('tokens.txt'), file('encoder.int8.onnx')]);
      expect(await pk.installed(), isFalse);
      final events = await pk.download().toList();
      expect(events.last.fraction, 1);
      expect(
        events.map((e) => e.fraction ?? 0).toList(),
        orderedEquals([...events.map((e) => e.fraction ?? 0)]..sort()),
      );
      expect(await pk.installed(), isTrue);
      expect(await pk.downloadedBytes(), 123000);
      // già scaricato: niente richieste
      hits.clear();
      await pk.download().toList();
      expect(hits, isEmpty);
      await pk.delete();
      expect(await pk.installed(), isFalse);
    });

    test('SHA-256 diverso: file scartato, errore chiaro', () async {
      final pk = service([file('tokens.txt', sha: 'a' * 64)]);
      await expectLater(
        pk.download().toList(),
        throwsA(
          isA<WhisperException>().having(
            (e) => e.message,
            'm',
            contains('SHA-256'),
          ),
        ),
      );
      expect(await pk.installed(), isFalse);
      expect(await pk.downloadedBytes(), 0);
    });

    test('spazio insufficiente: niente download', () async {
      final pk = service([file('encoder.int8.onnx')], free: 1000);
      await expectLater(
        pk.download().toList(),
        throwsA(isA<WhisperException>()),
      );
      expect(hits, isEmpty);
    });

    test('un download solo, seguito da più parti', () async {
      final pk = service([file('tokens.txt'), file('encoder.int8.onnx')]);
      final a = pk.download().toList();
      final b = pk.download().toList();
      expect(pk.downloading, isTrue);
      await Future.wait([a, b]);
      expect(hits.where((h) => h == 'encoder.int8.onnx'), hasLength(1));
      expect(pk.downloading, isFalse);
    });

    test('modello incluso nell\'app: si usa da lì, niente download', () async {
      final inc = Directory(p.join(tmp.path, 'app', 'data', 'parakeet'))
        ..createSync(recursive: true);
      final files = [file('tokens.txt'), file('encoder.int8.onnx')];
      for (final f in files) {
        File(p.join(inc.path, f.name)).writeAsBytesSync(bodies[f.name]!);
      }
      final vad = File(
        p.join(Directory.current.path, 'assets', 'vad', 'silero_vad.onnx'),
      );
      vad.copySync(p.join(inc.path, 'silero_vad.onnx'));
      ParakeetService make(Directory? d) => ParakeetService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        downloader: FileDownloader(freeSpace: (_) async => null),
        fileUrl: (f) => Uri.parse('http://127.0.0.1:${server.port}/${f.name}'),
        files: files,
        bundledDir: () => d,
      );
      final pk = make(inc);
      expect(await pk.isBundled(), isTrue);
      expect(await pk.installed(), isTrue);
      expect((await pk.modelDir()).path, inc.path);
      expect((await pk.vadModel())!.path, p.join(inc.path, 'silero_vad.onnx'));
      // «scarica» non scarica niente, «elimina» non tocca il modello incluso
      expect((await pk.download().toList()).last.fraction, 1);
      expect(hits, isEmpty);
      await pk.delete();
      expect(File(p.join(inc.path, 'encoder.int8.onnx')).existsSync(), isTrue);

      // modello incluso incompleto (build a mano): ripiego sul download
      File(p.join(inc.path, 'tokens.txt')).writeAsStringSync('rotto');
      final broken = make(inc);
      expect(await broken.isBundled(), isFalse);
      expect(await broken.installed(), isFalse);
      await broken.download().toList();
      expect(hits, contains('tokens.txt'));
      expect(await broken.installed(), isTrue);
      expect((await broken.modelDir()).path, isNot(inc.path));
      // nessuna cartella inclusa (telefono, build senza modello)
      expect(await make(null).isBundled(), isFalse);
    });

    test('Silero VAD copiato dall\'asset solo se integro', () async {
      final ok = File(
        p.join(Directory.current.path, 'assets', 'vad', 'silero_vad.onnx'),
      ).readAsBytesSync();
      ParakeetService withAsset(List<int> bytes) => ParakeetService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        assetLoader: (_) async =>
            ByteData.sublistView(Uint8List.fromList(bytes)),
      );
      expect(await withAsset([1, 2, 3]).vadModel(), isNull);
      final f = await withAsset(ok).vadModel();
      expect(f, isNotNull);
      expect(f!.lengthSync(), kSileroVadBytes);
    });

    test('file del modello pubblicati: pesi e impronte', () {
      expect(kParakeetFiles, hasLength(4));
      expect(kParakeetBytes, 670478772);
      expect(kParakeetModel.approxBytes, kParakeetBytes);
      for (final f in kParakeetFiles) {
        expect(f.sha256, hasLength(64));
        expect(parakeetFileUrl(f).toString(), contains(kParakeetRepo));
      }
      expect(
        File(
          p.join(
            Directory.current.path,
            'assets',
            'vad',
            'ggml-silero-v5.1.2.bin',
          ),
        ).lengthSync(),
        kWhisperVadBytes,
      );
    });
  });
}
