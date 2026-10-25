import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/whisper_service.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late int port;
  final hits = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('um_whisper_');
    hits.clear();
    // Zip con un finto whisper-cli e un "modello" da 3000 byte.
    // Il servizio del test simula Linux (host: linux): il programma si chiama
    // «whisper-cli» su qualsiasi sistema esegua il test.
    const cliName = 'whisper-cli';
    final arch = Archive()
      ..addFile(ArchiveFile.string('Release/$cliName', '#!/bin/sh\n'));
    final zipBytes = ZipEncoder().encode(arch);
    final model = List<int>.generate(3000, (i) => i % 256);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) async {
      hits.add('${req.uri.path} ${req.headers.value('range') ?? ''}');
      if (req.uri.path == '/redirect') {
        req.response.statusCode = 302;
        req.response.headers.set('location', '/zip');
      } else if (req.uri.path == '/zip') {
        req.response.add(zipBytes);
      } else {
        final range = req.headers.value('range');
        if (range != null) {
          final from = int.parse(range.split('=')[1].split('-')[0]);
          req.response.statusCode = 206;
          req.response.add(model.sublist(from));
        } else {
          req.response.add(model);
        }
      }
      await req.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test(
    'install: segue i redirect, estrae il programma, riprende il modello',
    () async {
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.linux,
        freeSpace: (_) async => null,
        binariesUrl: Uri.parse('http://127.0.0.1:$port/redirect'),
        modelUrl: (_) => Uri.parse('http://127.0.0.1:$port/model'),
      );
      // Modello senza impronta (il file finto non la rispetterebbe): dal
      // 25/10/2026 tutti i modelli dell'elenco ne hanno una, quindi se ne usa
      // una copia senza.
      final base = whisperModelById('large-v3-turbo-q8_0')!;
      final m = WhisperModelInfo(
        id: base.id,
        params: base.params,
        disk: base.disk,
        approxBytes: base.approxBytes,
        ram: base.ram,
        gpu: base.gpu,
        speed: base.speed,
        italian: base.italian,
        multilingual: base.multilingual,
        italianOk: base.italianOk,
        minHardware: base.minHardware,
        platforms: base.platforms,
        quantized: base.quantized,
      );
      // Download del modello interrotto a metà: resta un .part da riprendere.
      final models = Directory(p.join(tmp.path, 'whisper', 'models'))
        ..createSync(recursive: true);
      File(p.join(models.path, '${m.fileName}.part'))
          .writeAsBytesSync(List<int>.generate(1000, (i) => i % 256));
      expect(await w.partialBytes(m), 1000);
      expect((await w.status()).ready, isFalse);
      final events = await w.install(m).toList();
      expect(events.last.phase, 'Pronto');
      final st = await w.status();
      expect(st.cli, isNotNull);
      expect(st.models, {m.id});
      expect(st.ready, isTrue);
      final model = File(p.join(models.path, m.fileName));
      expect(model.readAsBytesSync(), List<int>.generate(3000, (i) => i % 256));
      expect(hits, contains('/model bytes=1000-'));
      expect(hits.first, startsWith('/redirect'));
      // Già installato: nessun nuovo download.
      hits.clear();
      await w.install(m).toList();
      expect(hits, isEmpty);
      // SHA-1 diverso da quello pubblicato: file scartato.
      final tiny = whisperModelById('tiny')!;
      await expectLater(
        w.downloadModel(tiny).toList(),
        throwsA(
          isA<WhisperException>().having(
            (e) => e.message,
            'm',
            contains('danneggiato'),
          ),
        ),
      );
      expect((await w.status()).models, {m.id});
      expect(await w.partialBytes(tiny), 0);
    },
  );

  test('parseSegments e Markdown senza orari delle frasi', () {
    final json = jsonEncode({
      'transcription': [
        {
          'offsets': {'from': 0, 'to': 4000},
          'text': ' Buongiorno a tutti.',
        },
        {
          'offsets': {'from': 60000, 'to': 65000},
          'text': ' Oggi parliamo di limiti.',
        },
        {
          'offsets': {'from': 130000, 'to': 135000},
          'text': ' Teorema del confronto.',
        },
        {
          'offsets': {'from': 140000, 'to': 141000},
          'text': '  ',
        },
      ],
    });
    final segs = WhisperService.parseSegments(json);
    expect(segs, hasLength(3));
    expect(segs[2].start, const Duration(seconds: 130));
    final md = segmentsToMarkdown(
      segs,
      title: 'Lezione',
      subtitle: 'Analisi I',
    );
    // paragrafi di ~2 minuti, senza [hh:mm:ss]
    expect(
      md,
      '# Lezione\n\n_Analisi I_\n\n'
      'Buongiorno a tutti. Oggi parliamo di limiti.\n\n'
      'Teorema del confronto.\n\n',
    );
    expect(md, isNot(contains('[00:')));
    expect(
      () => WhisperService.parseSegments('nope'),
      throwsA(isA<WhisperException>()),
    );
  });

  test(
    'transcribe: senza installazione spiega cosa fare; formato non supportato',
    () async {
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
      );
      await expectLater(
        w.transcribe(File(p.join(tmp.path, 'a.flac'))),
        throwsA(
          isA<WhisperException>().having(
            (e) => e.message,
            'm',
            contains('Collegamenti'),
          ),
        ),
      );
    },
  );

  test(
    'transcribe: esegue whisper-cli, legge il JSON e l\'avanzamento',
    () async {
      if (Platform.isWindows) return;
      final bin = Directory(p.join(tmp.path, 'whisper', 'bin'))
        ..createSync(recursive: true);
      final models = Directory(p.join(tmp.path, 'whisper', 'models'))
        ..createSync(recursive: true);
      File(p.join(models.path, whisperModelById('large-v3-turbo')!.fileName))
          .writeAsStringSync('m');
      // Finto whisper-cli: scrive l'avanzamento su stderr e il JSON in -of.
      final cli = File(p.join(bin.path, 'whisper-cli'))
        ..writeAsStringSync(r'''#!/bin/sh
while [ "$1" != "" ]; do
  if [ "$1" = "-of" ]; then shift; OUT="$1"; fi
  if [ "$1" = "-l" ]; then shift; LANG_ARG="$1"; fi
  shift
done
echo "whisper_print_progress_callback: progress =  50%" 1>&2
echo "{\"transcription\":[{\"offsets\":{\"from\":0},\"text\":\" ciao ($LANG_ARG)\"}]}" > "$OUT.json"
''');
      await Process.run('chmod', ['+x', cli.path]);
      final audio = File(p.join(tmp.path, 'lezione.flac'))
        ..writeAsStringSync('x');
      final steps = <String>[];
      final segs = await WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.linux,
      ).transcribe(audio, onProgress: (p) => steps.add(p.phase));
      expect(segs.single.text, 'ciao (it)');
      expect(steps, contains('Trascrizione con Whisper: 50%'));
      // Registrazione del telefono (.m4a): convertita con ffmpeg, poi Whisper.
      final m4a = File(p.join(tmp.path, 'telefono.m4a'));
      ProcessResult? ff;
      try {
        ff = await Process.run('ffmpeg', [
          '-nostdin',
          '-y',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=1',
          '-c:a',
          'aac',
          m4a.path,
        ]);
      } on ProcessException {
        ff = null; // ffmpeg non installato (es. CI)
      }
      if (ff == null) {
        // Senza ffmpeg: messaggio che spiega cosa scaricare.
        m4a.writeAsStringSync('x');
        await expectLater(
          WhisperService(
            baseDir: () async => tmp,
            host: WhisperHost.linux,
          ).transcribe(m4a),
          throwsA(
            isA<WhisperException>().having(
              (e) => e.message,
              'm',
              contains('ffmpeg'),
            ),
          ),
        );
      } else if (ff.exitCode == 0) {
        steps.clear();
        final s2 = await WhisperService(
          baseDir: () async => tmp,
          host: WhisperHost.linux,
        ).transcribe(m4a, onProgress: (p) => steps.add(p.phase));
        expect(s2.single.text, 'ciao (it)');
        expect(steps, contains('Converto l\'audio…'));
      }
    },
  );
}
