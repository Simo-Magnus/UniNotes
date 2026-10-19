import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/lesson_transcripts.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/repositories/settings_repository.dart';

const _gb = 1000 * 1000 * 1000;

/// Motore finto: registra il modello usato.
class _FakeEngine implements WhisperEngine {
  final models = <String>[];
  @override
  String get name => 'finto';
  @override
  Future<List<WhisperSegment>> transcribe(
    File audio,
    File model, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    models.add(p.basename(model.path));
    return const [WhisperSegment(Duration.zero, 'Buongiorno')];
  }
}

void main() {
  group('consiglio del modello per il dispositivo', () {
    WhisperRecommendation rec(
      WhisperPlatform pl, {
      int? ram,
      int cores = 8,
      int? free,
    }) => recommendWhisperModel(
      DeviceProfile(platform: pl, ramBytes: ram, cores: cores, freeBytes: free),
    );

    test('PC e Mac: turbo q5_0 con 8 GB, small con 4 GB, base con meno', () {
      expect(
        rec(WhisperPlatform.pc, ram: 16 * _gb).model.id,
        'large-v3-turbo-q5_0',
      );
      expect(
        rec(WhisperPlatform.mac, ram: 8 * _gb, cores: 8).model.id,
        'large-v3-turbo-q5_0',
      );
      expect(rec(WhisperPlatform.pc, ram: 4 * _gb, cores: 2).model.id, 'small');
      expect(rec(WhisperPlatform.pc, ram: 2 * _gb).model.id, 'base');
      // RAM sconosciuta: il consiglio di sempre
      expect(rec(WhisperPlatform.pc).model.id, 'large-v3-turbo-q5_0');
    });

    test('telefono: small con 6 GB e 6 core, altrimenti base', () {
      expect(rec(WhisperPlatform.phone, ram: 8 * _gb).model.id, 'small');
      expect(rec(WhisperPlatform.phone, ram: 4 * _gb).model.id, 'base');
      expect(
        rec(WhisperPlatform.phone, ram: 8 * _gb, cores: 4).model.id,
        'base',
      );
    });

    test('poco spazio libero: si scende al modello che ci sta', () {
      final r = rec(WhisperPlatform.pc, ram: 16 * _gb, free: 900 * 1000000);
      expect(r.model.approxBytes, lessThan(900 * 1000000));
      expect(r.model.id, isNot('tiny'));
      expect(r.reason, contains('spazio libero'));
    });

    test('il dispositivo regge il modello: piattaforma e RAM', () {
      final large = whisperModelById('large-v3')!;
      final small = whisperModelById('small')!;
      const pc4 = DeviceProfile(
        platform: WhisperPlatform.pc,
        ramBytes: 4 * _gb,
      );
      const phone = DeviceProfile(
        platform: WhisperPlatform.phone,
        ramBytes: 12 * _gb,
      );
      expect(deviceCanRun(large, pc4), isFalse);
      expect(deviceCanRun(small, pc4), isTrue);
      // large-v3 non è per il telefono
      expect(deviceCanRun(large, phone), isFalse);
      expect(large.ramBytes, closeTo(3.9e9, 1e6));
      expect(
        parseMemInfo('MemTotal:        7864320 kB\nMemFree: 1 kB'),
        7864320 * 1024,
      );
      expect(parseMemInfo('niente'), isNull);
    });
  });

  group('scelta del modello con più modelli scaricati', () {
    late Directory tmp;
    late AppDatabase db;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('whisper_choice_');
      db = await AppDatabase.openInMemory();
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    WhisperService service({
      WhisperHost host = WhisperHost.android,
      int ram = 8 * _gb,
      Directory? bundled,
      _FakeEngine? engine,
      Future<ByteData> Function(String)? asset,
    }) => WhisperService(
      settings: SettingsRepository(db),
      baseDir: () async => tmp,
      host: host,
      pluginEngine: engine,
      bundledModels: () => bundled,
      cpuSupportsPlugin: () => true,
      builtInAsset: asset != null,
      assetLoader: asset,
      deviceProbe: () async => DeviceProfile(
        platform: host == WhisperHost.android
            ? WhisperPlatform.phone
            : WhisperPlatform.pc,
        ramBytes: ram,
      ),
    );

    Future<void> fakeModel(String id) async {
      final dir = Directory(p.join(tmp.path, 'whisper', 'models'))
        ..createSync(recursive: true);
      await File(p.join(dir.path, whisperModelById(id)!.fileName))
          .writeAsString('m');
    }

    test(
      'il più accurato che il dispositivo regge, poi il predefinito',
      () async {
        final w = service(host: WhisperHost.windows, ram: 4 * _gb);
        final set = {'small', 'large-v3', 'tiny'};
        // 4 GB: large-v3 (3,9 GB) è troppo pesante → small
        expect((await w.pickModel(set))!.id, 'small');
        // 16 GB: il più accurato
        final big = service(host: WhisperHost.windows, ram: 16 * _gb);
        expect((await big.pickModel(set))!.id, 'large-v3');
        // predefinito scelto nelle impostazioni (anche se meno accurato)
        await big.setSelectedModel('tiny');
        expect((await big.pickModel(set))!.id, 'tiny');
        // scelta per una sola trascrizione
        expect((await big.pickModel(set, requested: 'small'))!.id, 'small');
        // predefinito non più scaricato: di nuovo automatico
        expect((await big.pickModel({'small', 'large-v3'}))!.id, 'large-v3');
        await big.setSelectedModel(null);
        expect(await big.selectedModelId(), isNull);
      },
    );

    test(
      'senza modelli scaricati: il modello integrato (anche su Windows)',
      () async {
        final bundle = Directory(p.join(tmp.path, 'data', 'whisper'))
          ..createSync(recursive: true);
        File(p.join(bundle.path, kBuiltInWhisperModel.fileName))
            .writeAsBytesSync([1]);
        final engine = _FakeEngine();
        final w = service(
          host: WhisperHost.windows,
          bundled: bundle,
          engine: engine,
        );
        final audio = File(p.join(tmp.path, 'lezione.m4a'))
          ..writeAsStringSync('a');
        expect((await w.availableModels()).map((m) => m.id), ['base-q5_1']);
        expect((await w.resolveModel())!.id, 'base-q5_1');
        final r = await w.transcribeWith(audio);
        expect(r.model.id, 'base-q5_1');
        expect(r.segments.single.text, 'Buongiorno');
        // whisper.cpp dentro l'app, anche se su Windows manca whisper-cli
        expect(engine.models.single, 'ggml-base-q5_1.bin');
        expect(whisperModelLabel('base-q5_1'), 'modello integrato');
      },
    );

    test('modelli scaricati e integrato: dal più accurato', () async {
      final bundle = Directory(p.join(tmp.path, 'b'))..createSync();
      File(p.join(bundle.path, kBuiltInWhisperModel.fileName))
          .writeAsBytesSync([1]);
      final engine = _FakeEngine();
      final w = service(bundled: bundle, engine: engine);
      await fakeModel('tiny');
      await fakeModel('small');
      expect((await w.availableModels()).map((m) => m.id), [
        'small',
        'base-q5_1',
        'tiny',
      ]);
      final audio = File(p.join(tmp.path, 'a.m4a'))..writeAsStringSync('a');
      expect((await w.transcribeWith(audio)).model.id, 'small');
      // «Trascrivi con…» il modello integrato
      expect(
        (await w.transcribeWith(audio, model: 'base-q5_1')).model.id,
        'base-q5_1',
      );
      expect(engine.models, ['ggml-small.bin', 'ggml-base-q5_1.bin']);
    });

    test('asset del modello integrato: copia controllata', () async {
      // asset diverso dal modello pubblicato (SHA-1): scartato, si scaricherà
      final w = service(
        asset: (_) async => ByteData.sublistView(Uint8List.fromList([1, 2])),
      );
      expect(await w.builtInModelFile(), isNull);
      final models = Directory(p.join(tmp.path, 'whisper', 'models'));
      expect(
        models.existsSync() ? models.listSync().map((e) => e.path) : const [],
        isEmpty,
      );
      // build senza asset (Windows lo installa accanto all'eseguibile)
      final win = service(host: WhisperHost.windows);
      expect(await win.builtInModelFile(), isNull);
    });
  });

  group('trascrizioni senza gli orari delle frasi', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('times_'));
    tearDown(() => tmp.delete(recursive: true));

    const old =
        '# Trascrizione – Lezione\n\n_Analisi · trascritta con Whisper small_'
        '\n\n[00:00:00] Buongiorno a tutti.\n\n[00:02:05] Oggi le derivate.\n';

    test('testo: via [hh:mm:ss] solo nel formato dell\'app', () {
      expect(hasTranscriptTimes(old), isTrue);
      final clean = stripTranscriptTimes(old);
      expect(clean, contains('\n\nBuongiorno a tutti.\n\nOggi le derivate.'));
      expect(clean, isNot(contains('[00:')));
      expect(hasTranscriptTimes(clean), isFalse);
      // altri file (es. Gemini, appunti) restano com'erano
      const other = '# Appunti\n\n[00:01:00] nota';
      expect(stripTranscriptTimes(other), other);
      expect(whisperModelInHead(old), 'small');
      expect(
        whisperModelInHead('_trascrizione dal vivo con Whisper base-q5_1_'),
        'base-q5_1',
      );
      expect(
        whisperModelInHead('_Fisica · trascritta con Whisper large-v3-q5_0_'),
        'large-v3-q5_0',
      );
    });

    test('file del vecchio formato: tempi nel .json, testo pulito', () async {
      final course = Directory(p.join(tmp.path, 'Analisi'));
      final recs = Directory(p.join(course.path, 'Registrazioni'))
        ..createSync(recursive: true);
      final trs = Directory(p.join(course.path, 'Trascrizioni'))
        ..createSync(recursive: true);
      final audio = File(p.join(recs.path, 'Lezione.m4a'))
        ..writeAsStringSync('a');
      File(p.join(trs.path, 'Lezione.md')).writeAsStringSync(old);
      final gemini = File(p.join(trs.path, 'Lezione (Gemini).md'))
        ..writeAsStringSync('# Trascrizione\n\n[00:00:00] Gemini');
      final t = await loadLessonTranscripts(
        trs,
        'Lezione',
        audioPath: audio.path,
      );
      expect(t.whisperModel, 'small');
      final md = t.whisper!.readAsStringSync();
      expect(md, isNot(contains('[00:')));
      expect(md, contains('Buongiorno a tutti.'));
      // il lettore resta sincronizzato: i tempi sono ora nel .json
      final meta = await RecordingMeta.load(audio.path);
      expect(meta.segments.map((s) => s.start.inSeconds), [0, 125]);
      // Gemini non si tocca
      expect(gemini.readAsStringSync(), contains('[00:00:00] Gemini'));
      // la seconda volta non c'è più niente da fare
      expect(await removeTranscriptTimes(t.whisper!), isFalse);
    });
  });

  group('trascrizione dal vivo: correzioni e formule', () {
    test('correggere una frase, toglierla, formule in LaTeX', () {
      final live = LiveTranscriber(null);
      var saved = 0;
      live.onSegments = () => saved++;
      live.restore([
        const TranscriptSegment(
          Duration.zero,
          Duration(seconds: 2),
          'ciao a tutti',
        ),
        const TranscriptSegment(
          Duration(seconds: 2),
          Duration(seconds: 5),
          'vale due terzi',
        ),
        const TranscriptSegment(
          Duration(seconds: 5),
          Duration(seconds: 8),
          'frase sbagliata',
        ),
      ]);
      live.editSegment(0, ' Ciao a tutti! ');
      expect(live.segments.first.text, 'Ciao a tutti!');
      expect(live.isEdited(0), isTrue);
      // il testo originale resta per unire le finestre di Whisper
      expect(live.merger.segments.first.text, 'ciao a tutti');
      live.editSegment(2, '   ');
      expect(live.segments, hasLength(2));
      expect(live.segments[1].text, 'vale due terzi');
      live.formulas = true;
      expect(live.segments[1].text, r'vale $\frac{2}{3}$');
      // la correzione dello studente non si converte
      expect(live.segments[0].text, 'Ciao a tutti!');
      live.partial = 'integrale da 2 a pi greco';
      expect(live.partialShown, r'$\int_{2}^{\pi}$');
      live.formulas = false;
      expect(live.segments[1].text, 'vale due terzi');
      expect(saved, 4);
    });
  });
}
