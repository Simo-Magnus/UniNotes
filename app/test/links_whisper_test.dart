import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/file_downloader.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Motore finto (telefono): registra le chiamate.
class _FakeEngine implements WhisperEngine {
  final calls = <(String, String)>[];
  @override
  String get name => 'finto';
  @override
  Future<List<WhisperSegment>> transcribe(
    File audio,
    File model, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    WhisperOptions options = WhisperOptions.none,
  }) async {
    calls.add((p.basename(audio.path), p.basename(model.path)));
    onProgress?.call(
      const WhisperProgress('Trascrizione con Whisper: 50%', .5),
    );
    return const [WhisperSegment(Duration.zero, 'Buongiorno')];
  }
}

void main() {
  group('tabella dei modelli', () {
    test('ogni modello ha peso, RAM, URL e indicazioni per l\'italiano', () {
      final ids = <String>{};
      for (final m in kWhisperModels) {
        expect(ids.add(m.id), isTrue, reason: 'id duplicato ${m.id}');
        expect(m.params, isNotEmpty, reason: m.id);
        expect(m.disk, isNotEmpty, reason: m.id);
        expect(m.approxBytes, greaterThan(10 * 1024 * 1024), reason: m.id);
        expect(m.ram, isNotEmpty, reason: m.id);
        expect(m.gpu, isNotEmpty, reason: m.id);
        expect(m.speed, isNotEmpty, reason: m.id);
        expect(m.italian, isNotEmpty, reason: m.id);
        expect(m.minHardware, isNotEmpty, reason: m.id);
        expect(m.platforms, isNotEmpty, reason: m.id);
        expect(m.downloadUrl.scheme, 'https');
        expect(m.downloadUrl.host, 'huggingface.co');
        expect(m.downloadUrl.path, endsWith('/resolve/main/ggml-${m.id}.bin'));
        expect(m.pageUrl.path, contains('/blob/main/'));
        if (m.sha1 != null) {
          expect(m.sha1, matches(RegExp(r'^[0-9a-f]{40}$')), reason: m.id);
        }
        // Solo inglese ⇒ non adatto all'italiano.
        if (!m.multilingual) expect(m.italianOk, isFalse, reason: m.id);
      }
    });

    test('modelli richiesti presenti; .en e distil non adatti', () {
      for (final id in [
        'tiny',
        'base',
        'small',
        'medium',
        'large-v1',
        'large-v2',
        'large-v3',
        'large-v3-turbo',
        'medium-q5_0',
        'medium-q8_0',
        'large-v3-q5_0',
        'large-v3-turbo-q5_0',
        'large-v3-turbo-q8_0',
      ]) {
        final m = whisperModelById(id);
        expect(m, isNotNull, reason: id);
        expect(m!.italianOk, isTrue, reason: id);
        expect(m.multilingual, isTrue, reason: id);
      }
      // nessun modello solo inglese: l'app trascrive lezioni in italiano
      expect(
        kWhisperModels.every((m) => m.multilingual && m.italianOk),
        isTrue,
      );
      expect(whisperModelById('tiny.en'), isNull);
      expect(whisperModelById('distil-large-v3'), isNull);
      expect(
        whisperModelById('large-v3-turbo-q5_0')!.downloadUrl.toString(),
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
      );
      expect(
        whisperModelById('large-v3-turbo-q5_0')!.sha1,
        'e050f7970618a659205450ad97eb95a18d69c9ee',
      );
    });

    test('consigliati: turbo q5_0 su PC, small/base sul telefono', () {
      expect(recommendedWhisperModel(phone: false).id, 'large-v3-turbo-q5_0');
      expect(recommendedWhisperModel(phone: true).id, 'small');
      final phone = whisperModelsFor(WhisperPlatform.phone);
      expect(phone.map((m) => m.id), containsAll(['tiny', 'base', 'small']));
      expect(phone.map((m) => m.id), isNot(contains('large-v3')));
      expect(phone.every((m) => m.italianOk), isTrue);
    });
  });

  group('download con avanzamento, annullamento e ripresa', () {
    late Directory tmp;
    late HttpServer server;
    late List<String?> ranges;
    final data = List<int>.generate(200000, (i) => i % 251);
    var slow = false;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('links_dl_');
      ranges = [];
      slow = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final range = req.headers.value('range');
        ranges.add(range);
        var from = 0;
        if (range != null) {
          from = int.parse(range.split('=')[1].split('-')[0]);
          req.response.statusCode = 206;
        }
        final body = data.sublist(from);
        req.response.contentLength = body.length;
        for (var i = 0; i < body.length; i += 10000) {
          req.response.add(body.sublist(i, (i + 10000).clamp(0, body.length)));
          await req.response.flush();
          if (slow) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }
        await req.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/ggml-x.bin');

    test('avanzamento fino al 100% e file completo', () async {
      final d = FileDownloader(freeSpace: (_) async => null);
      final target = File(p.join(tmp.path, 'm.bin'));
      final events = await d.download(url(), target).toList();
      expect(events.first.received, 0);
      expect(events.last.received, data.length);
      expect(events.last.fraction, 1);
      expect(await target.readAsBytes(), data);
      expect(await File('${target.path}.part').exists(), isFalse);
    });

    test('annulla a metà, poi riprende da dove si era fermato', () async {
      slow = true;
      final d = FileDownloader(freeSpace: (_) async => null);
      final target = File(p.join(tmp.path, 'm.bin'));
      final cancel = CancelToken();
      final seen = <double?>[];
      await expectLater(() async {
        await for (final e in d.download(url(), target, cancel: cancel)) {
          seen.add(e.fraction);
          if ((e.fraction ?? 0) > 0.2) cancel.cancel();
        }
      }(), throwsA(isA<DownloadCancelled>()));
      final part = File('${target.path}.part');
      expect(await part.exists(), isTrue);
      final partial = await part.length();
      expect(partial, greaterThan(0));
      expect(partial, lessThan(data.length));
      expect(await target.exists(), isFalse);

      slow = false;
      await d.download(url(), target).toList();
      expect(ranges.last, 'bytes=$partial-');
      expect(await target.readAsBytes(), data);
    });

    test('spazio insufficiente: errore chiaro prima di scaricare', () async {
      final d = FileDownloader(freeSpace: (_) async => 1024);
      await expectLater(
        d
            .download(
              url(),
              File(p.join(tmp.path, 'm.bin')),
              expectedBytes: 5 << 20,
            )
            .toList(),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'm',
            contains('Spazio insufficiente'),
          ),
        ),
      );
      expect(ranges, isEmpty);
    });

    test('SHA-1 verificato quando è noto', () async {
      final ok = await FileDownloader.sha1Of(
        await File(p.join(tmp.path, 'x')).writeAsBytes(data),
      );
      final d = FileDownloader(freeSpace: (_) async => null);
      final target = File(p.join(tmp.path, 'verificato.bin'));
      await d.download(url(), target, sha1: ok).toList();
      expect(await target.exists(), isTrue);
    });
  });

  group('motore per piattaforma', () {
    late Directory tmp;
    late AppDatabase db;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('links_engine_');
      db = await AppDatabase.openInMemory();
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<void> fakeModel(String id) async {
      final dir = Directory(p.join(tmp.path, 'whisper', 'models'))
        ..createSync(recursive: true);
      await File(p.join(dir.path, whisperModelById(id)!.fileName))
          .writeAsString('m');
    }

    test(
      'telefono: whisper.cpp nell\'app con il modello consigliato',
      () async {
        final engine = _FakeEngine();
        final w = WhisperService(
          settings: SettingsRepository(db),
          baseDir: () async => tmp,
          host: WhisperHost.android,
          pluginEngine: engine,
        );
        expect(w.isPhone, isTrue);
        expect(w.platform, WhisperPlatform.phone);
        expect(await w.engineKind(), WhisperEngineKind.plugin);
        expect((await w.status()).engineReady, isTrue);
        await fakeModel('tiny');
        await fakeModel('small');
        final audio = File(p.join(tmp.path, 'lezione.m4a'))
          ..writeAsStringSync('a');
        final segs = await w.transcribe(audio);
        expect(segs.single.text, 'Buongiorno');
        expect(engine.calls.single, ('lezione.m4a', 'ggml-small.bin'));
        // Modello scelto dallo studente.
        await w.setSelectedModel('tiny');
        await w.transcribe(audio);
        expect(engine.calls.last.$2, 'ggml-tiny.bin');
      },
    );

    test(
      'Mac senza whisper-cli: versione nell\'app; con Homebrew: cli',
      () async {
        final brew = File(p.join(tmp.path, 'brew', 'whisper-cli'))
          ..createSync(recursive: true);
        final without = WhisperService(
          baseDir: () async => tmp,
          host: WhisperHost.macos,
          macCliCandidates: [p.join(tmp.path, 'manca', 'whisper-cli')],
        );
        // `which` può trovare un whisper-cli installato sul PC dei test.
        final found = await without.findCli();
        if (found == null) {
          expect(await without.engineKind(), WhisperEngineKind.plugin);
        }
        final withBrew = WhisperService(
          baseDir: () async => tmp,
          host: WhisperHost.macos,
          macCliCandidates: [brew.path],
        );
        expect((await withBrew.findCli())?.path, brew.path);
        expect(await withBrew.engineKind(), WhisperEngineKind.cli);
        expect(withBrew.canDownloadCli, isFalse);
        expect(
          WhisperService(host: WhisperHost.windows).canDownloadCli,
          isTrue,
        );
      },
    );

    test('PC: preferisce turbo q5_0 tra i modelli scaricati', () async {
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
      );
      final m = await w.pickModel({'small', 'large-v3-turbo-q5_0', 'tiny.en'});
      expect(m!.id, 'large-v3-turbo-q5_0');
      expect((await w.pickModel({'small'}, requested: 'small'))!.id, 'small');
      expect(await w.pickModel({}), isNull);
    });
  });
}
