import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/live_agreement.dart';
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

/// Audio finto: silenzio (zeri, o un fruscio debolissimo mai zero con
/// [noise]) o parlato (un tono, ampiezza [level]).
Float32List _audio(
  double seconds, {
  bool speech = false,
  bool noise = false,
  double level = 0.3,
}) {
  final n = (seconds * 16000).round();
  return Float32List.fromList([
    for (var i = 0; i < n; i++)
      speech
          ? level * math.sin(2 * math.pi * 220 * i / 16000)
          : noise
          ? 0.001 + 0.0005 * math.sin(2 * math.pi * 50 * i / 16000)
          : 0.0,
  ]);
}

Float32List _joined(List<Float32List> parts) =>
    Float32List.fromList([for (final x in parts) ...x]);

/// [audio] a pezzi da 0,1 s dal campione [at] della registrazione.
void _feedAll(
  VadLiveSegmenter seg,
  Float32List audio,
  int at,
  void Function(LiveStep s) onStep, {
  bool partial = true,
}) {
  for (var i = 0; i < audio.length; i += 1600) {
    final chunk = Float32List.sublistView(
      audio,
      i,
      math.min(i + 1600, audio.length),
    );
    onStep(seg.feed(at + i, chunk, partial: partial));
  }
  onStep(seg.flush());
}

/// Audio ricevuto da [_ScriptDecoder]: lunghezza e zeri all'inizio e alla
/// fine.
class _Input {
  _Input(Float32List s)
    : length = s.length,
      leadingZeros = _zeros(s, true),
      trailingZeros = _zeros(s, false),
      onset = s.indexWhere((x) => x.abs() > 0.05);
  final int length;
  final int leadingZeros;
  final int trailingZeros;

  /// Primo campione di «voce» (-1 = nessuno).
  final int onset;

  static int _zeros(Float32List s, bool head) {
    var n = 0;
    while (n < s.length && s[head ? n : s.length - 1 - n] == 0) {
      n++;
    }
    return n;
  }
}

/// Decodificatore finto: il testo lo decide [text] (audio ricevuto, numero
/// della chiamata da 1); un pezzo per parola, il primo dove inizia la voce
/// e poi uno ogni 0,3 s.
class _ScriptDecoder implements SpeechDecoder {
  _ScriptDecoder(this.text, {this.delay});
  final String Function(_Input x, int call) text;

  /// Secondi fra l'inizio della voce e il primo pezzo (parole perse).
  final double Function(_Input x)? delay;
  final inputs = <_Input>[];
  @override
  DecodedText decode(Float32List samples) {
    final x = _Input(samples);
    inputs.add(x);
    final t = text(x, inputs.length);
    final words = t.split(' ').where((w) => w.isNotEmpty).toList();
    final at = math.max(0, x.onset) / 16000 + (delay?.call(x) ?? 0);
    return DecodedText(
      t,
      tokens: [for (final w in words) '▁$w'],
      timestamps: [for (var k = 0; k < words.length; k++) at + 0.3 * k],
    );
  }
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
    test('ipotesi ogni ~0,75 s mentre si parla, confermato alla pausa, '
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
      // 3 s di parlato: un'ipotesi 3 o 4 volte (~0,75 s), non a ogni pezzo
      expect(partials.length, inInclusiveRange(3, 4));
      expect(committed, hasLength(1));
      final c = committed.single;
      // parlato da 2,5 s a 5,5 s della registrazione (con 0,3 s prima,
      // per non tagliare la prima parola)
      expect(c.start.inMilliseconds, closeTo(2200, 50));
      expect(c.end.inMilliseconds, closeTo(5500, 50));
      // 3 s di parlato + 0,3 s prima (il primo campione del tono è 0), con
      // 0,25 s di silenzio digitale prima e dopo
      expect(c.text, matches(RegExp(r'^parlato di (3799|3800) ms$')));
      // dopo la frase, solo silenzio: niente più decodifiche
      final calls = dec.calls;
      for (var k = 0; k < 10; k++) {
        seg.feed(at, _audio(0.1));
        at += 1600;
      }
      expect(dec.calls, calls);
      expect(seg.flush().committed, isEmpty);
    });

    test('ipotesi vuota a metà del parlato: il testo provvisorio resta quello '
        'di prima (non è la fine della frase)', () {
      final dec = _ScriptDecoder((n, call) => call == 2 ? '' : 'parola $call');
      final seg = VadLiveSegmenter(_EnergyVad(), dec);
      final audio = _joined([_audio(0.5), _audio(4, speech: true)]);
      final partials = <String?>[];
      _feedAll(seg, audio, 0, (s) => partials.add(s.partial));
      final texts = partials.whereType<String>().toList();
      // vuoto solo alla fine dell'audio (flush)
      expect(texts.last, '');
      expect(texts.sublist(0, texts.length - 1), isNot(contains('')));
      expect(texts.first, 'parola 1');
      expect(texts[1], 'parola 3');
    });

    test('0,25 s di silenzio digitale prima e dopo l\'audio dato a Parakeet; '
        'i tempi restano quelli della registrazione', () {
      final dec = _ScriptDecoder((n, call) => 'una frase');
      final seg = VadLiveSegmenter(_EnergyVad(), dec);
      final audio = _joined([
        _audio(1, noise: true),
        _audio(3, speech: true),
        _audio(1, noise: true),
      ]);
      final words = <HypWord>[];
      final committed = <TranscriptSegment>[];
      _feedAll(seg, audio, 16000, (s) {
        words.addAll(s.partialWords);
        committed.addAll(s.committed);
      });
      expect(dec.inputs, isNotEmpty);
      for (final x in dec.inputs) {
        expect(x.leadingZeros, 4000);
        expect(x.trailingZeros, 4000);
      }
      // il primo pezzo inizia dove inizia la voce (2 s della registrazione)
      expect(words.first.start!.inMilliseconds, closeTo(2000, 30));
      final c = committed.single;
      expect(c.start.inMilliseconds, closeTo(1700, 30));
      expect(c.end.inMilliseconds, closeTo(5000, 30));
    });

    test('testo definitivo vuoto o molto più corto dell\'ultima ipotesi: un '
        'secondo tentativo con 1 s di silenzio, si tiene il più lungo', () {
      String text(_Input x, int call) => x.leadingZeros == 16000
          ? 'oggi parliamo di limiti e derivate.'
          : x.length > 3.5 * 16000
          ? 'derivate.'
          : 'oggi parliamo di limiti e';
      final dec = _ScriptDecoder(text);
      // ipotesi ogni 1,5 s: al massimo ~2,8 s di audio, il tratto intero
      // (con gli zeri) è più lungo di 3,5 s
      final seg = VadLiveSegmenter(_EnergyVad(), dec, partialEvery: 24000);
      final audio = _joined([
        _audio(0.5, noise: true),
        _audio(3, speech: true),
        _audio(1, noise: true),
      ]);
      final committed = <TranscriptSegment>[];
      _feedAll(seg, audio, 0, (s) => committed.addAll(s.committed));
      expect(committed.single.text, 'oggi parliamo di limiti e derivate.');
      expect(dec.inputs.where((x) => x.leadingZeros == 16000), hasLength(1));

      // trascrizione di un file (niente ipotesi): solo se il testo è vuoto
      final empty = _ScriptDecoder(
        (x, call) => x.leadingZeros == 16000 ? 'eccolo' : '',
      );
      final file = VadLiveSegmenter(_EnergyVad(), empty);
      final out = <TranscriptSegment>[];
      _feedAll(file, audio, 0, (s) => out.addAll(s.committed), partial: false);
      expect(out.single.text, 'eccolo');
      expect(empty.inputs, hasLength(2));

      // testo definitivo senza le prime parole delle ipotesi (inizia 1 s
      // dopo): secondo tentativo anche se le parole sono abbastanza
      bool whole(_Input x) => x.length > 3.5 * 16000;
      final head = _ScriptDecoder(
        (x, call) => !whole(x)
            ? 'ragazzi ditemi se non è assurdo'
            : x.leadingZeros == 16000
            ? 'ragazzi ditemi se non è assurdo siamo arrivati al punto.'
            : 'non è assurdo siamo arrivati al punto.',
        delay: (x) => whole(x) && x.leadingZeros != 16000 ? 1.0 : 0,
      );
      final lost = VadLiveSegmenter(_EnergyVad(), head, partialEvery: 24000);
      final kept = <TranscriptSegment>[];
      _feedAll(lost, audio, 0, (s) => kept.addAll(s.committed));
      expect(
        kept.single.text,
        'ragazzi ditemi se non è assurdo siamo arrivati al punto.',
      );
    });

    test('parlato continuo oltre 12 s: il tratto si chiude nel punto più '
        'silenzioso, il VAD riparte da lì, niente audio trascritto due '
        'volte', () {
      final vad = _EnergyVad();
      final dec = _ScriptDecoder((x, call) => 'pezzo $call');
      final seg = VadLiveSegmenter(vad, dec);
      final audio = _joined([
        _audio(0.5, noise: true),
        _audio(8, speech: true),
        // la pausa più breve di quelle del VAD: per lui è ancora parlato
        _audio(0.2, speech: true, level: 0.06),
        _audio(6.3, speech: true),
        _audio(1, noise: true),
      ]);
      final committed = <TranscriptSegment>[];
      _feedAll(seg, audio, 0, (s) {
        committed.addAll(s.committed);
        if (s.committed.isNotEmpty && s.speaking) {
          expect(s.stableUntil, committed.last.end);
        }
      });
      expect(vad.resets, 1);
      expect(committed, hasLength(2));
      // taglio nella pausa (8,5–8,7 s della registrazione)
      expect(committed[0].end.inMilliseconds, closeTo(8600, 120));
      expect(committed[1].start, committed[0].end);
      expect(committed[1].end.inMilliseconds, closeTo(15000, 30));
      // le ipotesi non decodificano mai più di ~12,75 s di audio
      for (final x in dec.inputs) {
        expect(x.length - 8000, lessThanOrEqualTo(12.8 * 16000));
      }
    });

    test('parole ripetute a ciclo tolte, le ripetizioni vere restano', () {
      expect(
        collapseRepeats(
          'Non è veramente gestando, stiamo stando stando stando stando '
          'stando.',
        ),
        'Non è veramente gestando, stiamo stando.',
      );
      expect(collapseRepeats('bene, bene, bene noi'), 'bene, bene, bene noi');
      expect(collapseRepeats('seminando piano piano'), 'seminando piano piano');
      expect(collapseRepeats('a metà a metà a metà a Apple'), 'a metà a Apple');
      final ws = collapseRepeatedWords([
        for (var i = 0; i < 5; i++)
          HypWord('stando', start: sec(i), end: sec(i + 1)),
      ]);
      expect(ws.single.text, 'stando');
      expect((ws.single.start, ws.single.end), (sec(0), sec(5)));
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

    test(
      'modello incluso nell\'app: subito Parakeet, nessun download',
      () async {
        final pk = FakeParakeet(
          tmp,
          isInstalled: false,
          engine: FakeVadEngine(),
        )..bundled = true;
        final live = LiveTranscriber(service(pk));
        await live.begin(await wav(1), sampleRate: 16000, channels: 1);
        expect(pk.downloadStarted, isFalse);
        expect(live.downloading, isFalse);
        expect(live.engine, LiveEngine.parakeet);
        expect(live.state, LiveState.running);
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
