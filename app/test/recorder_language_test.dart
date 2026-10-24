import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/lecture_language.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/live_transcript.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/system_speech.dart';
import 'package:university_notes/features/notes/recorder/vad_segmenter.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_parakeet.dart';

/// Lingua delle lezioni (onboarding, Registra, registrazione salvata),
/// riconoscitore di Apple prima di Parakeet sul Mac con macOS 26 e
/// maiuscole a inizio pezzo per tutti i motori (24/10/2026).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SystemSpeech.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> fromSystem(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        SystemSpeech.channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('un_lang_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('lingua delle lezioni', () {
    test('scelta: insegnamento, insegnamento in inglese, onboarding, '
        'italiano', () {
      expect(pickLectureLanguage(), 'it');
      expect(pickLectureLanguage(general: 'en'), 'en');
      expect(pickLectureLanguage(examLanguage: 'en', general: 'it'), 'en');
      expect(
        pickLectureLanguage(course: 'it', examLanguage: 'en', general: 'en'),
        'it',
      );
      expect(pickLectureLanguage(course: 'en'), 'en');
      // valori strani: mai altre lingue
      expect(pickLectureLanguage(course: 'fr', general: 'de'), 'it');
      expect(lectureLanguageLabel('en'), 'Inglese');
      expect(lectureLanguageLabel('it'), 'Italiano');
    });

    test('impostazioni: generale e per insegnamento; la registrazione '
        'salvata ricorda la sua', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = SettingsRepository(db);
      const c = Course(id: 7, name: 'Analisi 1');
      expect(await lectureLanguageOf(s, c), 'it');
      await setGeneralLectureLanguage(s, 'en');
      expect(await lectureLanguageOf(s, c), 'en');
      expect(await lectureLanguageOf(s, null), 'en');
      await setCourseLectureLanguage(s, 7, 'it');
      expect(await lectureLanguageOf(s, c), 'it');
      expect(
        await lectureLanguageOf(
          s,
          const Course(id: 8, name: 'Physics'),
        ),
        'en',
      );

      final audio = p.join(tmp.path, 'lezione.m4a');
      // senza dati: quella dell'insegnamento
      expect(await recordingLanguageOf(s, c, audio), 'it');
      await RecordingMeta(language: 'en').save(audio);
      expect((await RecordingMeta.load(audio)).language, 'en');
      expect(await recordingLanguageOf(s, c, audio), 'en');
      // valore non valido nel file: si ignora
      expect(RecordingMeta.fromJson({'lingua': 'fr'}).language, isNull);
    });
  });

  group('Mac con macOS 26: riconoscitore di Apple, poi Parakeet', () {
    test('ordine dei motori e versione di macOS', () {
      expect(liveEngineOrder(phone: false, appleSpeech: true), [
        LiveEngine.system,
        LiveEngine.parakeet,
        LiveEngine.whisper,
      ]);
      // Windows e Mac precedenti: come prima
      expect(liveEngineOrder(phone: false), [
        LiveEngine.parakeet,
        LiveEngine.whisper,
      ]);
      // il telefono non cambia
      expect(liveEngineOrder(phone: true, appleSpeech: true), [
        LiveEngine.system,
        LiveEngine.whisper,
      ]);
      expect(macOSMajor('Version 26.0 (Build 25A354)'), 26);
      expect(macOSMajor('Version 15.6.1 (Build 24G90)'), 15);
      expect(macOSMajor('sconosciuta'), isNull);
      expect(
        macAppleSpeech(macOS: true, osVersion: 'Version 26.1 (Build 25B78)'),
        isTrue,
      );
      expect(
        macAppleSpeech(macOS: true, osVersion: 'Version 15.6 (Build 24G84)'),
        isFalse,
      );
      expect(
        macAppleSpeech(macOS: false, osVersion: 'Version 26.0 (Build 1)'),
        isFalse,
      );
    });

    WhisperService service(FakeParakeet pk) => WhisperService(
      baseDir: () async => tmp,
      host: WhisperHost.macos,
      freeSpace: (_) async => null,
      parakeet: pk,
      modelUrl: (_) => Uri.parse('http://127.0.0.1:9/m'),
    );

    test('modello della lingua sul Mac: trascrive Apple, solo '
        'SpeechAnalyzer', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        return switch (c.method) {
          'support' => {
            'available': true,
            'onDevice': true,
            'engine': 'speechanalyzer',
            'analyzer': 'installed',
          },
          'start' => true,
          _ => null,
        };
      });
      final eng = FakeVadEngine();
      final live = LiveTranscriber(
        service(FakeParakeet(tmp, engine: eng, host: WhisperHost.macos)),
        speech: SystemSpeech(),
        appleSpeech: true,
        locale: 'en-US',
      );
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.system);
      expect(live.state, LiveState.running);
      final support = calls.firstWhere((c) => c.method == 'support');
      expect((support.arguments as Map)['prepare'], isTrue);
      final start = calls.firstWhere((c) => c.method == 'start');
      expect((start.arguments as Map)['analyzerOnly'], isTrue);
      expect((start.arguments as Map)['locale'], 'en-US');
      // niente Parakeet mentre trascrive Apple
      live.onPcm(_pcm(0.5));
      expect(eng.feeds, isEmpty);
      await live.close();
    });

    test('modello della lingua non ancora sul Mac: Parakeet subito, il '
        'motivo nella card', () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (c) async {
        methods.add(c.method);
        return switch (c.method) {
          'support' => {
            'available': true,
            'engine': 'speechanalyzer',
            'analyzer': 'downloading',
          },
          'start' => true,
          _ => null,
        };
      });
      final live = LiveTranscriber(
        service(
          FakeParakeet(tmp, engine: FakeVadEngine(), host: WhisperHost.macos),
        ),
        speech: SystemSpeech(),
        appleSpeech: true,
      );
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.parakeet);
      expect(methods, isNot(contains('start')));
      expect(live.systemUnavailable, 'analyzer-downloading');
      expect(
        speechNotice(live.systemUnavailable, mac: true)?.text,
        contains('Parakeet'),
      );
      await live.close();
    });

    test('Apple che si ferma a metà lezione: continua Parakeet da lì, il '
        'testo resta e non si ritrascrive', () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        return switch (c.method) {
          'support' => {
            'available': true,
            'engine': 'speechanalyzer',
            'analyzer': 'installed',
          },
          'start' => true,
          _ => null,
        };
      });
      final eng = FakeVadEngine();
      final live = LiveTranscriber(
        service(FakeParakeet(tmp, engine: eng, host: WhisperHost.macos)),
        speech: SystemSpeech(),
        appleSpeech: true,
      );
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      // 3 s di lezione con Apple
      for (var i = 0; i < 15; i++) {
        live.onPcm(_pcm(0.2));
      }
      live.onAudio(const Duration(seconds: 3));
      await fromSystem('result', {'session': 1, 'text': 'Prima parte.'});
      await fromSystem('error', {
        'session': 1,
        'message': 'rotto',
        'fatal': true,
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(live.engine, LiveEngine.parakeet);
      for (var i = 0; i < 5; i++) {
        live.onPcm(_pcm(0.2));
        live.onAudio(Duration(milliseconds: 3000 + 200 * (i + 1)));
        await live.settle();
      }
      // Parakeet riceve solo l'audio dopo l'errore
      expect(eng.feeds, isNotEmpty);
      expect(eng.feeds.first.$1, 48000);
      expect(live.segments.first.text, 'Prima parte.');
      // niente da recuperare prima dell'errore
      final rest = live.finish(const Duration(seconds: 4));
      expect(rest.every((c) => c.start >= const Duration(seconds: 3)), isTrue);
      await live.close();
    });
  });

  group('maiuscole a inizio pezzo, tutti i motori', () {
    test('riconoscitore del sistema (telefono, Apple sul Mac): parole '
        'confermate e testo definitivo', () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        return switch (c.method) {
          'support' => {'available': true, 'onDevice': true},
          'start' => true,
          _ => null,
        };
      });
      final live = LiveTranscriber(
        null,
        speech: SystemSpeech(),
        vocabulary: const ['Teorema di Lagrange'],
      );
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      live.onAudio(const Duration(seconds: 2));
      await fromSystem('result', {'session': 1, 'text': 'Oggi parliamo'});
      live.onAudio(const Duration(seconds: 3));
      // il pezzo dopo arriva con la maiuscola anche se continua la frase
      await fromSystem('partial', {'session': 1, 'text': 'Di integrali'});
      await fromSystem('partial', {'session': 1, 'text': 'Di integrali e'});
      expect(live.segments.map((s) => s.text), [
        'Oggi parliamo',
        'di integrali',
      ]);
      live.onAudio(const Duration(seconds: 4));
      await fromSystem('result', {'session': 1, 'text': 'Di integrali.'});
      expect(live.segments.map((s) => s.text), [
        'Oggi parliamo',
        'di integrali.',
      ]);
      // dopo il punto la maiuscola resta, i nomi propri noti anche
      live.onAudio(const Duration(seconds: 5));
      await fromSystem('result', {'session': 1, 'text': 'Vediamo il'});
      live.onAudio(const Duration(seconds: 6));
      await fromSystem('result', {'session': 1, 'text': 'Lagrange e poi'});
      live.onAudio(const Duration(seconds: 7));
      await fromSystem('result', {'session': 1, 'text': 'Il resto.'});
      expect(live.segments.map((s) => s.text).toList().sublist(2), [
        'Vediamo il',
        'Lagrange e poi',
        'il resto.',
      ]);
      await live.close();
    });

    test('Parakeet: parole confermate e frase definitiva dopo una pausa a '
        'metà frase', () async {
      final eng = _CapsVad();
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        freeSpace: (_) async => null,
        parakeet: FakeParakeet(tmp, engine: eng),
      );
      final live = LiveTranscriber(w);
      await live.begin(File('x.wav'), sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.parakeet);
      final seen = <List<String>>[];
      for (var i = 0; i < 4; i++) {
        live.onPcm(_pcm(0.5));
        live.onAudio(Duration(milliseconds: 500 * (i + 1)));
        await live.settle();
        seen.add([for (final s in live.segments) s.text]);
      }
      // le parole confermate per accordo: già minuscole
      expect(seen[2], ['La derivata', 'della funzione']);
      // il testo definitivo della frase: anche
      expect(seen[3], ['La derivata', 'della funzione è continua.']);
      await live.close();
    });

    test('trascrizione dopo il salvataggio (Whisper, Parakeet)', () {
      expect(
        TranscriptMerger.recaseTexts(
          ['Il teorema di', 'Lagrange dice che', 'Esiste un punto.', 'Poi'],
          names: const ['Teorema di Lagrange'],
        ),
        ['Il teorema di', 'Lagrange dice che', 'esiste un punto.', 'Poi'],
      );
      expect(
        TranscriptMerger.recaseTexts(['so', 'I think', 'That is'], english: true),
        ['so', 'I think', 'that is'],
      );
    });
  });
}

/// Parakeet finto come il modello vero quando il VAD taglia a una pausa a
/// metà frase: ogni tratto inizia con la maiuscola.
class _CapsVad extends FakeVadEngine {
  int _n = 0;

  @override
  Future<LiveStep> feed(
    int start,
    Float32List samples, {
    bool partial = true,
  }) async {
    Duration at(int n) => Duration(microseconds: n * 1000000 ~/ 16000);
    final e = at(start + samples.length);
    return switch (_n++) {
      0 => LiveStep(
        committed: [TranscriptSegment(Duration.zero, e, 'La derivata')],
        partial: '',
        stableUntil: e,
      ),
      1 => LiveStep(partial: 'Della funzione', stableUntil: at(start)),
      2 => LiveStep(partial: 'Della funzione è', stableUntil: at(start)),
      _ => LiveStep(
        committed: [
          TranscriptSegment(
            const Duration(milliseconds: 500),
            e,
            'Della funzione è continua.',
          ),
        ],
        partial: '',
        stableUntil: e,
      ),
    };
  }
}

Uint8List _pcm(double seconds) {
  final n = (seconds * 16000).round();
  final s = Int16List(n);
  for (var i = 0; i < n; i++) {
    s[i] = (8000 * math.sin(2 * math.pi * 220 * i / 16000)).round();
  }
  return s.buffer.asUint8List();
}
