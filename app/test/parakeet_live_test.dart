import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/vad_segmenter.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';

import 'support/fake_parakeet.dart';

/// VAD finto: parlato dove il campione supera 0,05; un tratto si chiude
/// dopo 0,5 s di silenzio (come Silero con minSilenceDuration 0,5).
class _EnergyVad implements SpeechVad {
  int _pos = 0;
  int? _start;
  int _silence = 0;
  final _done = <VadSegment>[];
  final _buf = <double>[];
  int _bufStart = 0;
  int resets = 0;

  @override
  void accept(Float32List samples) {
    for (final s in samples) {
      _buf.add(s);
      if (s.abs() > 0.05) {
        _start ??= _pos;
        _silence = 0;
      } else if (_start != null) {
        _silence++;
        if (_silence >= 8000) _close(_pos - _silence + 1);
      }
      _pos++;
    }
  }

  void _close(int end) {
    final s = _start!;
    _done.add(
      VadSegment(
        s,
        Float32List.fromList(_buf.sublist(s - _bufStart, end - _bufStart)),
      ),
    );
    _start = null;
    _silence = 0;
  }

  @override
  bool get speaking => _start != null;

  @override
  bool get hasSegment => _done.isNotEmpty;

  @override
  VadSegment pop() => _done.removeAt(0);

  @override
  void flush() {
    if (_start != null) _close(_pos);
  }

  @override
  void reset() {
    resets++;
    _pos = 0;
    _start = null;
    _silence = 0;
    _done.clear();
    _buf.clear();
    _bufStart = 0;
  }
}

/// Decodificatore finto: «parlato di N ms».
class _LenDecoder implements SpeechDecoder {
  int calls = 0;
  @override
  DecodedText decode(Float32List samples) {
    calls++;
    return DecodedText('parlato di ${samples.length ~/ 16} ms');
  }
}

Float32List _audio(double seconds, {bool speech = false}) {
  final n = (seconds * 16000).round();
  return Float32List.fromList([
    for (var i = 0; i < n; i++)
      speech ? 0.3 * math.sin(2 * math.pi * 220 * i / 16000) : 0.0,
  ]);
}

/// PCM 16 bit mono a 16 kHz (byte), parlato finto.
Uint8List _pcm(double seconds) {
  final n = (seconds * 16000).round();
  final s = Int16List(n);
  for (var i = 0; i < n; i++) {
    s[i] = (8000 * math.sin(2 * math.pi * 220 * i / 16000)).round();
  }
  return s.buffer.asUint8List();
}

void main() {
  group('VAD: frasi guidate dalle pause', () {
    test('provvisorio ogni ~1 s mentre si parla, confermato alla pausa, '
        'niente testo nei silenzi, tempi della registrazione', () {
      final vad = _EnergyVad();
      final dec = _LenDecoder();
      final seg = VadLiveSegmenter(vad, dec);
      // la registrazione è già a 2 s (Parakeet partito dopo)
      var at = 32000;
      final audio = Float32List.fromList([
        ..._audio(0.5),
        ..._audio(3, speech: true),
        ..._audio(1),
      ]);
      final partials = <String>[];
      final committed = <TranscriptSegment>[];
      Duration stable = Duration.zero;
      for (var i = 0; i < audio.length; i += 1600) {
        final chunk = Float32List.sublistView(
          audio,
          i,
          math.min(i + 1600, audio.length),
        );
        final step = seg.feed(at, chunk);
        at += chunk.length;
        if (step.partial != null && step.partial!.isNotEmpty) {
          partials.add(step.partial!);
        }
        committed.addAll(step.committed);
        expect(step.stableUntil, greaterThanOrEqualTo(stable));
        expect(step.stableUntil, lessThanOrEqualTo(samplesToDuration(at)));
        stable = step.stableUntil;
      }
      // 3 s di parlato: testo provvisorio 2 o 3 volte, non a ogni pezzo
      expect(partials.length, inInclusiveRange(2, 3));
      expect(committed, hasLength(1));
      final c = committed.single;
      // parlato da 2,5 s a 5,5 s della registrazione (con 0,3 s prima,
      // per non tagliare la prima parola)
      expect(c.start.inMilliseconds, closeTo(2200, 50));
      expect(c.end.inMilliseconds, closeTo(5500, 50));
      // 3 s di parlato + 0,3 s prima (il primo campione del tono è 0)
      expect(c.text, matches(RegExp(r'^parlato di (3299|3300) ms$')));
      // dopo la frase, solo silenzio: niente più decodifiche
      final calls = dec.calls;
      for (var k = 0; k < 10; k++) {
        seg.feed(at, _audio(0.1));
        at += 1600;
      }
      expect(dec.calls, calls);
      expect(seg.flush().committed, isEmpty);
    });

    test('tratto saltato: il VAD riparte dal nuovo punto', () {
      final vad = _EnergyVad();
      final seg = VadLiveSegmenter(vad, _LenDecoder());
      seg.feed(0, _audio(1));
      expect(vad.resets, 0);
      // buco di 20 s (PC indietro): il pezzo dopo parte a 21 s
      seg.feed(21 * 16000, _audio(1, speech: true));
      expect(vad.resets, 1);
      final out = seg.flush().committed.single;
      expect(out.start.inMilliseconds, closeTo(21000, 10));
      expect(out.end.inMilliseconds, closeTo(22000, 10));
    });

    test('frasi divise alla punteggiatura con i tempi dei pezzi', () {
      const d = DecodedText(
        'Buongiorno a tutti. Oggi parliamo di integrali. Bene.',
        tokens: [
          '▁Buon',
          'giorno',
          '▁a',
          '▁tutti',
          '.',
          '▁Oggi',
          '▁parliamo',
          '▁di',
          '▁integrali',
          '.',
          '▁Bene',
          '.',
        ],
        timestamps: [
          0.0,
          0.2,
          0.5,
          0.6,
          0.9,
          1.4,
          1.7,
          2.0,
          2.2,
          2.8,
          3.2,
          3.5,
        ],
      );
      final out = splitSentences(
        d,
        const Duration(seconds: 10),
        const Duration(seconds: 14),
      );
      expect(out.map((s) => s.text), [
        'Buongiorno a tutti.',
        // «Bene.» (una parola) si unisce alla frase prima
        'Oggi parliamo di integrali. Bene.',
      ]);
      expect(out[0].start, const Duration(seconds: 10));
      expect(out[0].end, const Duration(milliseconds: 11400));
      expect(out[1].start, const Duration(milliseconds: 11400));
      expect(out[1].end, const Duration(seconds: 14));
      // senza pezzi: una frase sola con i tempi del tratto
      final one = splitSentences(
        const DecodedText('ciao'),
        Duration.zero,
        sec(1),
      ).single;
      expect((one.start, one.end, one.text), (Duration.zero, sec(1), 'ciao'));
      expect(splitSentences(const DecodedText(' '), Duration.zero, sec(1)), []);
    });

    test('audio in attesa: si manda tutto, oltre 30 s si salta il vecchio', () {
      final b = PcmBacklog();
      expect(b.take(), isNull);
      b.add(0, _audio(0.1));
      expect(b.take(), isNull, reason: 'meno di 0,2 s');
      b.add(1600, _audio(0.3));
      final t = b.take()!;
      expect(t.start, 0);
      expect(t.samples.length, 6400);
      expect(t.dropped, isNull);
      // 40 s in attesa: restano gli ultimi ~8 s, il resto è da recuperare
      for (var i = 0; i < 400; i++) {
        b.add(6400 + i * 1600, _audio(0.1));
      }
      final late = b.take()!;
      expect(late.dropped!.from, 6400);
      expect(late.dropped!.to, late.start);
      expect(late.samples.length, 8 * 16000);
      expect(late.start + late.samples.length, 6400 + 400 * 1600);
    });
  });

  group('Parakeet nel registratore (PC e Mac)', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('un_pk_'));
    tearDown(() => tmp.delete(recursive: true));

    WhisperService service(
      FakeParakeet pk, {
      WhisperHost host = WhisperHost.windows,
      List<String>? used,
    }) => WhisperService(
      baseDir: () async => tmp,
      host: host,
      freeSpace: (_) async => null,
      parakeet: pk,
      livePlugin: (model, id) {
        used?.add(id);
        return _NoLive(id);
      },
    );

    Future<File> wav(double seconds) async {
      final f = File(p.join(tmp.path, 'rec.wav'));
      await writeWav16k(f, Int16List.view(_pcm(seconds).buffer));
      return f;
    }

    test('testo dal vivo con Parakeet, tratti mancanti recuperati', () async {
      final eng = FakeVadEngine();
      final live = LiveTranscriber(service(FakeParakeet(tmp, engine: eng)));
      final f = await wav(3);
      await live.begin(f, sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.parakeet);
      expect(live.state, LiveState.running);
      expect(live.sourceLabel, 'trascrizione dal vivo con Parakeet');
      for (var i = 0; i < 10; i++) {
        live.onPcm(_pcm(0.2));
        live.onAudio(Duration(milliseconds: 200 * (i + 1)));
        await live.settle();
      }
      expect(live.segments, isNotEmpty);
      expect(live.segments.first.start, Duration.zero);
      // orari continui: ogni pezzo parte dove finisce il precedente
      final starts = eng.feeds.map((f) => f.$1).toList();
      for (var i = 1; i < eng.feeds.length; i++) {
        expect(starts[i], eng.feeds[i - 1].$1 + eng.feeds[i - 1].$2);
      }
      // fine: l'audio dopo l'ultimo tratto definitivo si recupera
      final pending = live.finish(const Duration(seconds: 3));
      expect(
        pending.single.start,
        lessThanOrEqualTo(const Duration(seconds: 2)),
      );
      expect(pending.single.end, const Duration(seconds: 3));
      await live.recover(pending, f);
      expect(eng.ranges.single.$2, const Duration(seconds: 3));
      expect(live.segments.where((s) => s.text.startsWith('recupero')), [
        isA<TranscriptSegment>(),
      ]);
      await live.close();
      expect(eng.closed, isTrue);
    });

    test(
      'modello da scaricare: si registra intanto, poi tutto con Parakeet',
      () async {
        final eng = FakeVadEngine();
        final pk = FakeParakeet(tmp, isInstalled: false, engine: eng);
        final live = LiveTranscriber(service(pk));
        final f = await wav(4);
        final started = live.begin(f, sampleRate: 16000, channels: 1);
        await Future<void>.delayed(Duration.zero);
        expect(pk.downloadStarted, isTrue);
        expect(live.downloading, isTrue);
        expect(live.downloadWhat, contains('Parakeet'));
        for (var i = 0; i < 20; i++) {
          live.onPcm(_pcm(0.2));
          live.onAudio(Duration(milliseconds: 200 * (i + 1)));
        }
        expect(eng.feeds, isEmpty);
        // fine registrazione con il download ancora in corso
        final pending = live.finish(const Duration(seconds: 4));
        expect(pending.first.start, Duration.zero);
        expect(pending.last.end, const Duration(seconds: 4));
        expect(live.busy, isTrue);
        pk.finishDownload();
        await started;
        await live.recover(pending, f);
        expect(eng.ranges.first.$1, Duration.zero);
        expect(live.segments.first.text, 'recupero 0');
        await live.close();
      },
    );

    test('download annullato: niente Parakeet, la registrazione va', () async {
      final pk = FakeParakeet(tmp, isInstalled: false);
      final live = LiveTranscriber(service(pk));
      final started = live.begin(
        File(p.join(tmp.path, 'x.wav')),
        sampleRate: 16000,
        channels: 1,
      );
      await Future<void>.delayed(Duration.zero);
      live.cancelDownload();
      await started;
      expect(live.downloading, isFalse);
      // nessun modello Whisper scaricato: niente testo dal vivo
      expect(live.engine, LiveEngine.none);
      expect(live.state, LiveState.unavailable);
      await live.close();
    });

    test(
      'Parakeet non può girare (RAM): ripiego sul modello Whisper scaricato',
      () async {
        final models = Directory(p.join(tmp.path, 'whisper', 'models'))
          ..createSync(recursive: true);
        File(p.join(models.path, 'ggml-small.bin')).writeAsStringSync('m');
        final used = <String>[];
        final pk = FakeParakeet(tmp, reason: 'Servono 4 GB di RAM.');
        final w = WhisperService(
          baseDir: () async => tmp,
          host: WhisperHost.macos,
          freeSpace: (_) async => null,
          parakeet: pk,
          macCliCandidates: const [],
          processRunner: (_, _) async => ProcessResult(0, 1, '', ''),
          livePlugin: (model, id) {
            used.add(id);
            return _NoLive(id);
          },
        );
        final live = LiveTranscriber(w);
        await live.begin(
          File(p.join(tmp.path, 'x.wav')),
          sampleRate: 16000,
          channels: 1,
        );
        expect(live.parakeetUnavailable, 'Servono 4 GB di RAM.');
        expect(live.engine, LiveEngine.whisper);
        expect(used, ['small']);
        expect(live.quick, isFalse);
        await live.close();
      },
    );

    test('Parakeet si rompe a metà: si passa a Whisper se c\'è', () async {
      final eng = FakeVadEngine();
      final live = LiveTranscriber(service(FakeParakeet(tmp, engine: eng)));
      await live.begin(await wav(2), sampleRate: 16000, channels: 1);
      live.onPcm(_pcm(0.5));
      await live.settle();
      eng.failWith = StateError('rotto');
      live.onPcm(_pcm(0.5));
      await live.settle();
      await Future<void>.delayed(Duration.zero);
      // Windows senza modelli Whisper scaricati: testo dal vivo interrotto
      expect(live.state, LiveState.failed);
      expect(live.error, contains('rotto'));
      expect(eng.closed, isTrue);
      await live.close();
    });
  });

  group('scelta del motore per piattaforma', () {
    test('telefono: riconoscitore del sistema, poi Whisper; PC e Mac: '
        'Parakeet, poi Whisper (mai il riconoscitore del sistema)', () {
      expect(liveEngineOrder(phone: true), [
        LiveEngine.system,
        LiveEngine.whisper,
      ]);
      expect(liveEngineOrder(phone: false), [
        LiveEngine.parakeet,
        LiveEngine.whisper,
      ]);
    });

    test('sul telefono Parakeet non si usa mai', () async {
      final tmp = await Directory.systemTemp.createTemp('un_pk_phone_');
      addTearDown(() => tmp.delete(recursive: true));
      final pk = FakeParakeet(
        tmp,
        engine: FakeVadEngine(),
        host: WhisperHost.android,
      );
      expect(pk.platformSupported, isFalse);
      expect(await pk.installed(), isFalse);
      final w = WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.android,
        parakeet: pk,
      );
      expect(await w.parakeetReady(), isFalse);
      expect(w.builtInSupported, isTrue);
      expect(
        WhisperService(
          baseDir: () async => tmp,
          host: WhisperHost.windows,
        ).builtInSupported,
        isFalse,
      );
    });
  });
}

Duration sec(num s) => Duration(milliseconds: (s * 1000).round());

/// Whisper finto che non trascrive niente.
class _NoLive extends LiveWhisper {
  _NoLive(this.modelId);
  @override
  final String modelId;
  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async => const [];
  @override
  Future<void> close() async {}
}
