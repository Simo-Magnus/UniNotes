import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/cloud/cloud_drive_service.dart'
    show MemoryCloudSecrets;
import 'package:university_notes/features/notes/ai_request_dialog.dart';
import 'package:university_notes/features/notes/lesson_transcripts.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/overlay_logic.dart';
import 'package:university_notes/features/notes/recorder/system_speech.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Trascrizione istantanea (riconoscimento vocale del sistema), caselle
/// delle trascrizioni, risposta dell'AI presa dagli appunti, riquadro
/// ridimensionabile e «Annulla» dopo un ripristino.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SystemSpeech.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Il sistema manda un evento a Flutter sul canale.
  Future<void> fromSystem(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        SystemSpeech.channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('lingua: quella dell\'insegnamento, altrimenti italiano', () {
    expect(speechLocaleFor(null), 'it-IT');
    expect(speechLocaleFor(''), 'it-IT');
    expect(speechLocaleFor('en'), 'en-US');
    expect(speechLocaleFor('en_GB'), 'en-GB');
    expect(speechLocaleFor('fr'), 'fr-FR');
    expect(speechUnavailableText('android<13'), contains('Android 13'));
    expect(speechUnavailableText(null), isNull);
  });

  test(
    'testo provvisorio che si aggiorna, poi definitivo con i tempi',
    () async {
      final calls = <String>[];
      final fed = <int>[];
      messenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c.method);
        switch (c.method) {
          case 'support':
            return {'available': true, 'onDevice': true, 'feedsAudio': true};
          case 'start':
            return true;
          case 'feed':
            fed.add((c.arguments as Uint8List).length);
            return null;
        }
        return null;
      });
      final speech = SystemSpeech();
      final live = LiveTranscriber(null, speech: speech, locale: 'it-IT');
      final tmp = await Directory.systemTemp.createTemp('un_speech_');
      addTearDown(() => tmp.delete(recursive: true));
      await live.begin(
        File(p.join(tmp.path, 'x.wav')),
        sampleRate: 16000,
        channels: 1,
      );
      expect(live.engine, LiveEngine.system);
      expect(live.state, LiveState.running);
      expect(live.onDevice, isTrue);
      expect(calls, containsAllInOrder(['support', 'start']));

      // l'audio della registrazione va al riconoscitore a pezzi di ~0,1 s
      live.onPcm(Uint8List(6400));
      expect(fed, [6400]);

      live.onAudio(const Duration(seconds: 5));
      await fromSystem('partial', {'session': 1, 'text': 'buongiorno'});
      expect(live.partial, 'buongiorno');
      await fromSystem('partial', {'session': 1, 'text': 'buongiorno a tutti'});
      expect(live.partial, 'buongiorno a tutti');
      expect(live.segments, isEmpty);
      live.onAudio(const Duration(seconds: 7));
      await fromSystem('result', {'session': 1, 'text': 'Buongiorno a tutti.'});
      expect(live.partial, '');
      expect(live.segments.single.text, 'Buongiorno a tutti.');
      expect(live.segments.single.start, const Duration(seconds: 4));
      expect(live.segments.single.end, const Duration(seconds: 7));
      // eventi di una sessione vecchia: scartati
      await fromSystem('result', {'session': 99, 'text': 'vecchio'});
      expect(live.segments, hasLength(1));
      expect(live.sourceLabel, contains('riconoscimento vocale del sistema'));

      // fine: il testo ancora provvisorio diventa definitivo
      await fromSystem('partial', {'session': 1, 'text': 'ultima frase'});
      await live.flush(timeout: const Duration(milliseconds: 50));
      expect(live.segments.last.text, 'ultima frase');
      await live.close();
    },
  );

  test(
    'errore del riconoscitore: si passa a Whisper, il testo resta',
    () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        return switch (c.method) {
          'support' => {'available': true},
          'start' => true,
          _ => null,
        };
      });
      final live = LiveTranscriber(null, speech: SystemSpeech());
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      live.onAudio(const Duration(seconds: 3));
      await fromSystem('result', {'session': 1, 'text': 'prima parte'});
      await fromSystem('error', {
        'session': 1,
        'message': 'rotto',
        'fatal': true,
      });
      // senza Whisper installato: nessun testo dal vivo, la registrazione va
      await Future<void>.delayed(Duration.zero);
      expect(live.engine, LiveEngine.none);
      expect(live.state, LiveState.unavailable);
      expect(live.segments.single.text, 'prima parte');
      await live.close();
    },
  );

  test('sistema senza riconoscitore: motivo e ripiego', () async {
    messenger.setMockMethodCallHandler(channel, (c) async {
      return c.method == 'support'
          ? {'available': false, 'reason': 'android<13'}
          : null;
    });
    final live = LiveTranscriber(null, speech: SystemSpeech());
    await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
    expect(live.engine, LiveEngine.none);
    expect(live.state, LiveState.unavailable);
    expect(live.systemUnavailable, 'android<13');
    // piattaforma senza canale (MissingPluginException): niente eccezioni
    messenger.setMockMethodCallHandler(channel, null);
    final other = LiveTranscriber(null, speech: SystemSpeech());
    await other.begin(File('x.wav'), sampleRate: 16000, channels: 1);
    expect(other.state, LiveState.unavailable);
  });

  test('trascrizioni della lezione: Whisper, dal vivo e Gemini', () async {
    final dir = await Directory.systemTemp.createTemp('un_tr_');
    addTearDown(() => dir.delete(recursive: true));
    const lesson = '2026-10-05 08-30 Lezione';
    expect(transcriptName(lesson, TranscriptKind.gemini), '$lesson (Gemini)');
    expect(lessonOfTranscript('$lesson (Gemini)'), lesson);
    expect(transcriptKindOf('$lesson (Gemini)'), TranscriptKind.gemini);
    expect(transcriptKindOf(lesson), TranscriptKind.whisper);

    var t = await loadLessonTranscripts(dir, lesson);
    expect(t.whisper, isNull);
    expect(t.gemini, isNull);
    File(p.join(dir.path, '$lesson.md')).writeAsStringSync(
      '# Trascrizione\n\n_Analisi · trascrizione dal vivo con il '
      'riconoscimento vocale del sistema_\n\n[00:00:00] ciao',
    );
    t = await loadLessonTranscripts(dir, lesson);
    // il testo dal vivo del sistema non conta come Whisper
    expect(t.whisper, isNull);
    expect(t.systemLive, isNotNull);
    File(p.join(dir.path, '$lesson.md')).writeAsStringSync(
      '# Trascrizione\n\n_Analisi · trascritta con Whisper base_\n\nciao',
    );
    File(p.join(dir.path, '$lesson (Gemini).md')).writeAsStringSync('g');
    t = await loadLessonTranscripts(dir, lesson);
    expect(t.whisper, isNotNull);
    expect(t.gemini, isNotNull);
    expect(t.of(TranscriptKind.gemini)!.path, endsWith('(Gemini).md'));
  });

  test('Whisper non riuscito: messaggio con cosa provare', () {
    expect(
      whisperFailureMessage('Nessun modello Whisper scaricato.'),
      allOf(
        startsWith('Impossibile trascrivere con Whisper'),
        contains('Collegamenti → Whisper'),
      ),
    );
    expect(
      whisperFailureMessage('Nessun parlato riconosciuto nell\'audio.'),
      contains('parlato'),
    );
    expect(whisperFailureMessage('boh'), contains('riprova'));
  });

  test('risposta dell\'AI presa dagli appunti (niente «Incolla»)', () {
    final long = 'x' * 300;
    expect(isCapturedResponse(long, prompt: 'prompt'), isTrue);
    expect(isCapturedResponse('corta', prompt: 'prompt'), isFalse);
    expect(isCapturedResponse(long, prompt: long), isFalse);
    expect(isCapturedResponse(long, prompt: 'p', before: long), isFalse);
    expect(isCapturedResponse(null, prompt: 'p'), isFalse);
  });

  test('riquadro: larghezza fra il minimo con i pulsanti e lo schermo', () {
    expect(pillWidth(null, 1200), kPillMaxWidth);
    expect(pillWidth(100, 1200), kPillMinWidth);
    expect(pillWidth(300, 1200), 300);
    // telefono stretto: mai oltre lo schermo, mai sotto il minimo
    expect(pillWidth(null, 360), 360 - 24 - kPillHandleWidth);
    expect(pillWidth(null, 200), kPillMinWidth);
  });

  test(
    'ripristino annullato: l\'elemento torna nel cestino com\'era',
    () async {
      final root = await Directory.systemTemp.createTemp('un_bin_');
      addTearDown(() => root.delete(recursive: true));
      final bin = RecycleBin(() async => root);
      final dir = Directory(p.join(root.path, 'Corso', 'Registrazioni'))
        ..createSync(recursive: true);
      final audio = File(p.join(dir.path, 'Lezione.m4a'))
        ..writeAsStringSync('a');
      final meta = File(p.join(dir.path, 'Lezione.json'))
        ..writeAsStringSync('{}');
      final e = (await bin.trash([audio, meta], title: 'Lezione'))!;
      final restored = await bin.restore(e);
      expect(restored, hasLength(2));
      expect(audio.existsSync(), isTrue);
      await bin.undoRestore(e, restored);
      expect(audio.existsSync(), isFalse);
      final again = await bin.list();
      expect(again.single.id, e.id);
      expect(again.single.deletedAt, e.deletedAt);
      // e si può ripristinare di nuovo
      await bin.restore(again.single);
      expect(audio.existsSync(), isTrue);
      expect(meta.existsSync(), isTrue);
    },
  );

  test('chiave API di Gemini e Antigravity: tolte una volta', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final s = AppServices(db);
    final secrets = MemoryCloudSecrets()..values['gemini.apiKey'] = 'AIzaX';
    for (final k in SettingKeys.legacyGemini) {
      await s.settings.set(k, 'vecchio');
    }
    await s.settings.set(SettingKeys.themeMode, 'dark');
    await s.removeLegacyGemini(secrets: secrets);
    for (final k in SettingKeys.legacyGemini) {
      expect(await s.settings.get(k), isNull, reason: k);
    }
    expect(secrets.values, isEmpty);
    expect(await s.settings.get(SettingKeys.themeMode), 'dark');
    // una sola volta
    secrets.values['gemini.apiKey'] = 'nuova';
    await s.removeLegacyGemini(secrets: secrets);
    expect(secrets.values, isNotEmpty);
  });

  group('Windows senza «Riconoscimento vocale online»', () {
    test('avviso con pulsante per le impostazioni e nota sulla privacy', () {
      final n = speechNotice('privacy', windows: true, whisper: true)!;
      expect(n.text, contains('Riconoscimento vocale online'));
      expect(n.settings, Uri.parse('ms-settings:privacy-speech'));
      expect(n.action, 'Apri impostazioni');
      expect(n.note, contains('servizi Microsoft'));
      expect(n.note, contains('Whisper'));
      expect(n.note, contains('prossima registrazione'));
      // anche la lingua manca: si spiega come aggiungerla
      final both = speechNotice(
        'privacy',
        windows: true,
        languageMissing: true,
      )!;
      expect(both.text, contains('Aggiungi l\'italiano'));
      expect(both.note, isNot(contains('Whisper')));
      // solo la lingua
      final lang = speechNotice('locale', windows: true, locale: 'en-US')!;
      expect(lang.text, contains('l\'inglese'));
      expect(lang.text, contains('Riconoscimento vocale'));
      expect(lang.settings, Uri.parse('ms-settings:regionlanguage'));
      // altrove nessun pulsante per le impostazioni di Windows
      expect(speechNotice('locale')!.settings, isNull);
      expect(speechNotice('dictation', mac: true)!.action, 'Apri impostazioni');
      expect(speechNotice(null, windows: true), isNull);
    });

    test('il motivo arriva dal sistema, si passa a Whisper', () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        return c.method == 'support'
            ? {
                'available': false,
                'reason': 'privacy',
                'languageOk': false,
                'engine': 'windows',
                'feedsAudio': false,
              }
            : null;
      });
      final live = LiveTranscriber(null, speech: SystemSpeech());
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      expect(live.systemUnavailable, 'privacy');
      expect(live.systemLanguageMissing, isTrue);
      expect(live.engine, LiveEngine.none);
      await live.close();
    });
  });

  group('Whisper dal vivo', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('un_live_'));
    tearDown(() => tmp.delete(recursive: true));

    WhisperService service({
      Directory? bundled,
      bool cpu = true,
      Uri? modelUrl,
      List<String>? used,
    }) => WhisperService(
      baseDir: () async => tmp,
      host: WhisperHost.windows,
      freeSpace: (_) async => null,
      bundledModels: () => bundled,
      cpuSupportsPlugin: () => cpu,
      modelUrl: modelUrl == null ? null : (_) => modelUrl,
      livePlugin: (model, id) {
        used?.add(p.basename(model.path));
        return _FakeLive(id);
      },
    );

    test('scelta del motore: modello dal vivo incluso o scaricato', () async {
      final bundle = Directory(p.join(tmp.path, 'data', 'whisper'))
        ..createSync(recursive: true);
      File(
        p.join(bundle.path, kLiveWhisperModel.fileName),
      ).writeAsBytesSync([1]);
      final used = <String>[];
      final w = service(bundled: bundle, used: used);
      final e = (await w.liveEngine())!;
      expect(e.quick, isTrue);
      expect(e.modelId, 'base-q5_1');
      expect(used, ['ggml-base-q5_1.bin']);
      // CPU senza AVX2: niente whisper.cpp nell'app (e qui né modelli né
      // whisper-cli: nessun motore)
      expect(await service(bundled: bundle, cpu: false).liveEngine(), isNull);
      // non incluso ma già scaricato
      final models = Directory(p.join(tmp.path, 'whisper', 'models'))
        ..createSync(recursive: true);
      File(
        p.join(models.path, kLiveWhisperModel.fileName),
      ).writeAsBytesSync([1]);
      expect((await service().liveModelFile())!.path, startsWith(models.path));
      // il modello dal vivo non compare fra quelli dell'utente
      expect((await service().status()).models, isEmpty);
    });

    test('finestre di 2 s: testo provvisorio, poi definitivo', () async {
      final bundle = Directory(p.join(tmp.path, 'b'))..createSync();
      File(
        p.join(bundle.path, kLiveWhisperModel.fileName),
      ).writeAsBytesSync([1]);
      final live = LiveTranscriber(service(bundled: bundle));
      final wav = File(p.join(tmp.path, 'rec.wav'));
      // 2 s di «parlato» (tono) seguiti da una pausa di 2 s
      final speech = pcm16(_tone(2));
      final samples = Int16List(speech.length + 32000)..setAll(0, speech);
      await writeWav16k(wav, samples);
      await live.begin(wav, sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.whisper);
      expect(live.quick, isTrue);
      expect(live.sourceLabel, contains('base-q5_1'));
      live.onAudio(const Duration(seconds: 2));
      expect(live.busy, isTrue);
      await live.settle();
      expect(live.partial, 'testo 2000 ms');
      expect(live.segments, isEmpty);
      // la finestra 0–4 s finisce in una pausa: definitivo
      live.onAudio(const Duration(seconds: 4));
      await live.settle();
      expect(live.partial, '');
      expect(live.segments.single.text, 'testo 4000 ms');
      expect(live.lastTook, isNotNull);
      expect(live.finish(const Duration(seconds: 4)), isEmpty);
      await live.close();
    });

    test('download del modello non riuscito: la registrazione va', () async {
      final live = LiveTranscriber(
        service(modelUrl: Uri.parse('http://127.0.0.1:9/modello')),
      );
      await live.begin(
        File(p.join(tmp.path, 'x.wav')),
        sampleRate: 16000,
        channels: 1,
      );
      expect(live.downloading, isFalse);
      expect(live.downloadError, isNotNull);
      expect(live.state, LiveState.unavailable);
      await live.close();
    });
  });
}

/// Whisper finto: un segmento con la durata del pezzo.
class _FakeLive extends LiveWhisper {
  _FakeLive(this.modelId);
  @override
  final String modelId;

  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async {
    final info = (await readWavInfo(wav16k))!;
    final ms = info.dataLength ~/ 32;
    return [
      WhisperSegment(
        Duration.zero,
        'testo $ms ms',
        end: Duration(milliseconds: ms),
      ),
    ];
  }

  @override
  Future<void> close() async {}
}

/// Tono a 16 kHz mono per [seconds].
Uint8List _tone(double seconds) {
  final n = (seconds * 16000).round();
  final s = Int16List(n);
  for (var i = 0; i < n; i++) {
    s[i] = (8000 * math.sin(2 * math.pi * 440 * i / 16000)).round();
  }
  return s.buffer.asUint8List();
}
