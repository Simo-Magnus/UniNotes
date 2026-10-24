import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/links/whisper_card.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/vad_segmenter.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_parakeet.dart';

/// Whisper small q5_1 incluso nelle app per PC e Mac (dal 24/10/2026):
/// scelta del modello e ritrascrizione delle frasi di Parakeet in un'altra
/// lingua, con motori finti (niente whisper.cpp né modelli veri).

const _gb = 1000 * 1000 * 1000;

/// Dimensione finta del modello incluso (quella vera è 190085487 byte).
const _bytes = 16;

Duration _ms(int v) => Duration(milliseconds: v);

/// Motore finto per «Trascrivi con…»: registra il file del modello.
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
    WhisperOptions options = WhisperOptions.none,
  }) async {
    models.add(model.path);
    return const [WhisperSegment(Duration.zero, 'Buongiorno')];
  }
}

/// Whisper finto dal vivo: «testo in italiano», con il modello e la lingua
/// con cui è stato chiamato.
class _FakeLive extends LiveWhisper {
  _FakeLive(this.modelId, this.model, this.heard);
  @override
  final String modelId;
  final File model;
  final List<String> heard;

  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async {
    heard.add('${p.basename(model.path)} ${options.whisperLanguage}');
    return const [
      WhisperSegment(Duration.zero, 'testo in italiano', end: Duration(milliseconds: 500)),
    ];
  }

  @override
  Future<void> close() async {}
}

/// Parakeet finto per «Trascrivi con Parakeet»: una frase in italiano e una
/// in portoghese; quella fuori lingua passa a [rescue] come fa il vero.
class _RescueParakeet extends FakeParakeet {
  _RescueParakeet(super.dir, this.wav);
  final File wav;
  bool rescued = false;

  @override
  Future<List<WhisperSegment>> transcribeFile(
    File audio, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    String language = 'it',
    Future<List<WhisperSegment>> Function(File wav16k)? rescue,
  }) async {
    transcribed.add(audio.path);
    final out = [const WhisperSegment(Duration.zero, 'Buongiorno a tutti.')];
    if (rescue != null) {
      rescued = true;
      out.addAll(await rescue(wav));
    }
    return out;
  }
}

/// Parakeet finto dal vivo: un solo passo con una frase italiana e una
/// portoghese (quella che Parakeet scrive con l'audio cattivo).
class _ForeignVad implements VadLiveEngine {
  var _done = false;
  @override
  String get modelId => kParakeetId;

  @override
  Future<LiveStep> feed(
    int start,
    Float32List samples, {
    bool partial = true,
  }) async {
    if (_done) return const LiveStep();
    _done = true;
    return LiveStep(
      committed: [
        TranscriptSegment(_ms(0), _ms(1500), 'Buongiorno a tutti.'),
        TranscriptSegment(
          _ms(1500),
          _ms(3800),
          'Eu sou um que se cheguei na minha doutorana.',
        ),
      ],
      partial: '',
      stableUntil: _ms(4000),
    );
  }

  @override
  Future<List<TranscriptSegment>> transcribeRange(
    File wav,
    Duration start,
    Duration end,
  ) async => const [];

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late Directory bundle;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('whisper_included_');
    db = await AppDatabase.openInMemory();
    bundle = Directory(p.join(tmp.path, 'data', 'whisper'))
      ..createSync(recursive: true);
    File(
      p.join(bundle.path, 'ggml-$kDesktopWhisperModel.bin'),
    ).writeAsBytesSync(List.filled(_bytes, 1));
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  WhisperService service({
    WhisperHost host = WhisperHost.windows,
    FakeParakeet? parakeet,
    _FakeEngine? engine,
    bool cpu = true,
    int bytes = _bytes,
    List<String>? heard,
    List<String>? cli,
  }) => WhisperService(
    settings: SettingsRepository(db),
    baseDir: () async => tmp,
    host: host,
    freeSpace: (_) async => null,
    bundledModels: () => bundle,
    includedBytes: bytes,
    cpuSupportsPlugin: () => cpu,
    pluginEngine: engine,
    parakeet: parakeet ?? FakeParakeet(tmp, isInstalled: false, host: host),
    macCliCandidates: const [],
    processRunner: (_, _) async => ProcessResult(0, 1, '', ''),
    livePlugin: (model, id) => _FakeLive(id, model, heard ?? []),
    builtInAsset: false,
    deviceProbe: () async => DeviceProfile(
      platform: host == WhisperHost.android
          ? WhisperPlatform.phone
          : (host == WhisperHost.macos ? WhisperPlatform.mac : WhisperPlatform.pc),
      ramBytes: 16 * _gb,
    ),
  );

  Future<void> fakeDownloaded(String id) async {
    final dir = Directory(p.join(tmp.path, 'whisper', 'models'))
      ..createSync(recursive: true);
    await File(
      p.join(dir.path, whisperModelById(id)!.fileName),
    ).writeAsString('m');
  }

  group('modello incluso nell\'app desktop', () {
    test('si trova accanto all\'eseguibile, con la dimensione giusta', () async {
      final f = await service().includedModelFile();
      expect(f!.path, p.join(bundle.path, 'ggml-small-q5_1.bin'));
      expect(await service(host: WhisperHost.macos).includedModelFile(), isNotNull);
      // file incompleto (build interrotta): non si usa
      expect(await service(bytes: _bytes + 1).includedModelFile(), isNull);
      // Windows senza AVX2 e senza whisper-cli: niente modo di usarlo
      expect(await service(cpu: false).includedModelFile(), isNull);
      // nessun cambiamento sui telefoni
      expect(await service(host: WhisperHost.android).includedModelFile(), isNull);
      expect(kDesktopWhisperModel, 'small-q5_1');
      expect(whisperModelById(kDesktopWhisperModel)!.approxBytes, 190085487);
    });

    test('senza download: fra i motori, ma Parakeet resta il predefinito', () async {
      final pk = FakeParakeet(tmp);
      final w = service(parakeet: pk);
      expect((await w.availableModels()).map((m) => m.id), [
        kParakeetId,
        'small-q5_1',
      ]);
      // «Automatico»: Parakeet (più preciso e più veloce di small)
      expect((await w.resolveModel())!.id, kParakeetId);
      // lo studente lo può scegliere come predefinito
      await w.setSelectedModel('small-q5_1');
      expect((await w.resolveModel())!.id, 'small-q5_1');
      // non è «scaricato»: non compare fra i modelli dell'utente
      expect((await w.status()).models, isEmpty);
    });

    test('Parakeet non può girare: «Trascrivi con…» usa small incluso, con '
        'whisper.cpp dentro l\'app', () async {
      final engine = _FakeEngine();
      final w = service(
        parakeet: FakeParakeet(tmp, reason: 'poca RAM'),
        engine: engine,
      );
      final audio = File(p.join(tmp.path, 'lezione.m4a'))
        ..writeAsStringSync('a');
      final r = await w.transcribeWith(audio);
      expect(r.model.id, 'small-q5_1');
      expect(r.segments.single.text, 'Buongiorno');
      expect(engine.models.single, p.join(bundle.path, 'ggml-small-q5_1.bin'));
    });

    test('una copia scaricata non fa doppioni; un modello più accurato '
        'scaricato viene prima', () async {
      final engine = _FakeEngine();
      // Mac: whisper.cpp dentro l'app, i modelli scaricati si usano subito
      final w = service(host: WhisperHost.macos, engine: engine);
      await fakeDownloaded('small-q5_1');
      expect((await w.availableModels()).map((m) => m.id), ['small-q5_1']);
      final audio = File(p.join(tmp.path, 'a.m4a'))..writeAsStringSync('a');
      await w.transcribeWith(audio);
      // la copia scaricata (stesso modello)
      expect(engine.models.single, startsWith(p.join(tmp.path, 'whisper')));
      await fakeDownloaded('large-v3');
      expect((await w.availableModels()).map((m) => m.id), [
        'large-v3',
        'small-q5_1',
      ]);
      expect((await w.resolveModel())!.id, 'large-v3');
    });

    test('dal vivo: Whisper di ripiego senza download (pezzi da ~10 s)', () async {
      final heard = <String>[];
      final w = service(heard: heard);
      final e = (await w.liveEngine(
        options: const WhisperOptions(language: 'en'),
      ))!;
      expect(e.modelId, 'small-q5_1');
      expect(e.quick, isFalse);
      await e.transcribeWav(File('pezzo.wav'));
      expect(heard.single, 'ggml-small-q5_1.bin en');
      // telefono: niente modello incluso, niente motore (qui senza modelli)
      expect(await service(host: WhisperHost.android).liveEngine(), isNull);
    });
  });

  group('frasi di Parakeet in un\'altra lingua con il modello incluso', () {
    Future<File> wav(double seconds) async {
      final f = File(p.join(tmp.path, 'rec.wav'));
      final n = (seconds * 16000).round();
      final s = Int16List(n);
      for (var i = 0; i < n; i++) {
        s[i] = (8000 * math.sin(2 * math.pi * 220 * i / 16000)).round();
      }
      await writeWav16k(f, s);
      return f;
    }

    test('dal vivo: tolta e ritrascritta con small incluso, lingua fissata',
        () async {
      final heard = <String>[];
      final live = LiveTranscriber(
        service(
          parakeet: FakeParakeet(tmp, engine: _ForeignVad()),
          heard: heard,
        ),
      );
      final f = await wav(4);
      await live.begin(f, sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.parakeet);
      live.onPcm(Uint8List(4000 * 2));
      await live.settle();
      expect(live.foreignDropped, 1);
      await live.recover(live.finish(const Duration(seconds: 4)), f);
      expect(live.segments.map((s) => s.text), [
        'Buongiorno a tutti.',
        'testo in italiano',
      ]);
      expect(live.foreignRescued, 1);
      expect(heard.single, 'ggml-small-q5_1.bin it');
      expect(live.note, contains('Whisper la ritrascrive in italiano'));
      await live.close();
    });

    test('build senza il modello incluso e senza download: la frase si toglie',
        () async {
      File(p.join(bundle.path, 'ggml-$kDesktopWhisperModel.bin')).deleteSync();
      final live = LiveTranscriber(
        service(parakeet: FakeParakeet(tmp, engine: _ForeignVad())),
      );
      final f = await wav(4);
      await live.begin(f, sampleRate: 16000, channels: 1);
      live.onPcm(Uint8List(4000 * 2));
      await live.settle();
      await live.recover(live.finish(const Duration(seconds: 4)), f);
      expect(live.segments.map((s) => s.text), ['Buongiorno a tutti.']);
      expect(live.note, contains('è stata tolta'));
      await live.close();
    });

    test('«Trascrivi con Parakeet»: il tratto fuori lingua va a small incluso',
        () async {
      final heard = <String>[];
      final piece = await wav(1);
      final pk = _RescueParakeet(tmp, piece);
      final w = service(parakeet: pk, heard: heard);
      final audio = File(p.join(tmp.path, 'lezione.m4a'))
        ..writeAsStringSync('a');
      final r = await w.transcribeWith(audio, language: 'it');
      expect(r.model.id, kParakeetId);
      expect(pk.rescued, isTrue);
      expect(r.segments.map((s) => s.text), [
        'Buongiorno a tutti.',
        'testo in italiano',
      ]);
      expect(heard.single, 'ggml-small-q5_1.bin it');
    });
  });

  testWidgets('Collegamenti → Whisper: small q5_1 «incluso nell\'app», senza '
      'Scarica né Elimina', (tester) async {
    tester.view.physicalSize = const Size(1300, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppServices(db, whisper: service(parakeet: FakeParakeet(tmp)));
    await tester.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: WhisperCard()),
          ),
        ),
      ),
    );
    // le letture dei file avvengono fuori dal tempo finto: attese reali e
    // ridisegni finché la card ha finito di caricare
    Future<void> settle() async {
      bool loading() =>
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      for (var i = 0; i < 20 || (i < 600 && loading()); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
    }

    await settle();
    expect(find.text('Testo istantaneo: Parakeet'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SelectableText &&
            (w.data ?? '').startsWith(
              'Whisper small-q5_1 incluso nell\'app (181 MiB)',
            ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('whisper-models')));
    await settle();
    expect(find.byKey(const Key('whisper-included')), findsOneWidget);
    // un «Scarica» per ogni modello della tabella, tranne quello incluso
    expect(
      find.text('Scarica'),
      findsNWidgets(whisperModelsFor(WhisperPlatform.pc).length - 1),
    );
    expect(tester.takeException(), isNull);
  });
}
