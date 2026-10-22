import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/live_agreement.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/live_transcript.dart';
import 'package:university_notes/features/notes/recorder/live_transcript_editor.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/speech_language.dart';
import 'package:university_notes/features/notes/recorder/vad_segmenter.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';

import 'support/fake_parakeet.dart';

Duration ms(int v) => Duration(milliseconds: v);

/// Ipotesi con una parola ogni 300 ms da [from].
List<HypWord> hyp(String text, {int from = 0}) {
  final words = text.split(' ');
  return [
    for (var i = 0; i < words.length; i++)
      HypWord(
        words[i],
        start: ms(from + i * 300),
        end: ms(from + i * 300 + 280),
      ),
  ];
}

TranscriptSegment seg(int s, int e, String t) =>
    TranscriptSegment(ms(s), ms(e), t);

void main() {
  group('conferma per accordo (LocalAgreement-2)', () {
    late TranscriptMerger merger;
    late Set<int> edited;
    late LiveAgreement a;
    setUp(() {
      merger = TranscriptMerger();
      edited = {};
      a = LiveAgreement(merger, isEdited: edited.contains);
    });
    String text() => merger.segments.map((s) => s.text).join(' | ');

    test('le parole uguali in due ipotesi di fila si confermano subito', () {
      a.hypothesis(hyp('oggi parliamo'), now: ms(700));
      // una sola ipotesi: niente di confermato
      expect(merger.segments, isEmpty);
      expect(a.pending, 'oggi parliamo');
      a.hypothesis(hyp('oggi parliamo di'), now: ms(1000));
      expect(text(), 'oggi parliamo');
      expect(a.pending, 'di');
      a.hypothesis(hyp('oggi parliamo di fisica quantistica'), now: ms(1600));
      expect(text(), 'oggi parliamo di');
      expect(a.pending, 'fisica quantistica');
      // un solo segmento che cresce, con l'inizio della prima parola
      expect(merger.segments.single.start, Duration.zero);
      expect(merger.segments.single.end, ms(880));
      expect(a.openFrom, Duration.zero);
    });

    test('fine frase: il testo definitivo sostituisce le parole confermate, '
        'con punteggiatura e frasi; la chiave della prima frase resta', () {
      a.hypothesis(hyp('buongiorno a tutti oggi'), now: ms(1200));
      a.hypothesis(hyp('buongiorno a tutti oggi vediamo'), now: ms(1500));
      expect(text(), 'buongiorno a tutti oggi');
      a.finish([
        seg(0, 900, 'Buongiorno a tutti.'),
        seg(900, 2400, 'Oggi vediamo gli integrali.'),
      ]);
      expect(text(), 'Buongiorno a tutti. | Oggi vediamo gli integrali.');
      expect(merger.segments.first.start, Duration.zero);
      expect(merger.segments.last.start, ms(900));
      expect(merger.segments.last.end, ms(2400));
      expect(a.open, isFalse);
      expect(a.pending, '');
    });

    test('correzione del riconoscitore: si applica se uguale due volte, '
        'mai sulle frasi modificate a mano; niente doppioni', () {
      a.hypothesis(hyp('il teorema di pitagora dice'), now: ms(1500));
      a.hypothesis(hyp('il teorema di pitagora dice che'), now: ms(1800));
      expect(text(), 'il teorema di pitagora dice');
      // il riconoscitore riscrive «teorema» in «teoremi» (una volta: no)
      a.hypothesis(hyp('il teoremi di pitagora dice che il'), now: ms(2100));
      expect(text(), 'il teorema di pitagora dice che');
      // due volte di fila: sì
      a.hypothesis(hyp('il teoremi di pitagora dice che il'), now: ms(2100));
      expect(text(), 'il teoremi di pitagora dice che il');
      // la frase corretta a mano non cambia più: le parole nuove vanno in
      // un segmento nuovo, senza ripetere quelle già scritte
      final key = merger.segments.single.start.inMilliseconds;
      edited.add(key);
      a.hypothesis(
        hyp('il teorema di pitagora dice che il quadrato'),
        now: ms(2400),
      );
      a.hypothesis(
        hyp('il teorema di pitagora dice che il quadrato costruito'),
        now: ms(2700),
      );
      expect(merger.segments, hasLength(2));
      expect(merger.segments.first.text, 'il teoremi di pitagora dice che il');
      expect(merger.segments.last.text, 'quadrato');
      // fine frase: la frase modificata resta, il resto si sostituisce
      a.finish([
        seg(0, 3000, 'Il teorema di Pitagora dice che il quadrato costruito.'),
      ]);
      expect(merger.segments.first.text, 'il teoremi di pitagora dice che il');
      expect(merger.segments.last.text, 'quadrato costruito.');
      expect(merger.segments.first.start.inMilliseconds, key);
      expect(merger.segments.last.start.inMilliseconds, greaterThan(key));
    });

    test('il riconoscitore riparte da capo: la frase si chiude, niente '
        'doppioni', () {
      a.hypothesis(hyp('allora vediamo un esempio pratico'), now: ms(1500));
      a.hypothesis(hyp('allora vediamo un esempio pratico di'), now: ms(1800));
      expect(text(), 'allora vediamo un esempio pratico');
      // testo provvisorio nuovo, senza le parole di prima (iOS dopo una pausa)
      a.hypothesis(hyp('prendiamo la funzione', from: 2000), now: ms(2900));
      a.hypothesis(
        hyp('prendiamo la funzione seno', from: 2000),
        now: ms(3200),
      );
      expect(merger.segments.map((s) => s.text), [
        'allora vediamo un esempio pratico',
        'prendiamo la funzione',
      ]);
      expect(merger.segments.last.start, ms(2000));
    });

    test('frase lunghissima senza pause: le parole si confermano man mano, '
        'un segmento nuovo dopo ogni punto', () {
      final all = [
        for (var i = 0; i < 60; i++) i % 10 == 9 ? 'parola$i.' : 'parola$i',
      ];
      for (var n = 4; n <= all.length; n += 3) {
        a.hypothesis(hyp(all.sublist(0, n).join(' ')), now: ms(n * 300));
        // a ogni ipotesi si conferma quello che c'era già nella precedente:
        // un passo di ritardo, mai tutto alla fine
        expect(a.confirmedCount, n == 4 ? 0 : n - 3);
      }
      expect(a.confirmedCount, greaterThanOrEqualTo(all.length - 6));
      expect(merger.segments.length, greaterThanOrEqualTo(5));
      expect(merger.segments.first.text.split(' '), hasLength(10));
      expect(merger.segments.first.text, endsWith('parola9.'));
      // tempi in ordine e chiavi diverse
      for (var i = 1; i < merger.segments.length; i++) {
        expect(
          merger.segments[i].start,
          greaterThan(merger.segments[i - 1].start),
        );
      }
    });

    test('Whisper con la finestra piena: le parole confermate dell\'ultima '
        'frase passano alla finestra dopo', () {
      a.hypothesis(hyp('primo pezzo di testo poi'), now: ms(1500));
      a.hypothesis(hyp('primo pezzo di testo poi ancora'), now: ms(1800));
      expect(a.confirmedCount, 5);
      // definitivo solo «Primo pezzo di testo.», «poi ancora» resta
      // provvisoria e si ritrascrive nella finestra dopo
      a.finish([seg(0, 1100, 'Primo pezzo di testo.')], carry: true);
      expect(merger.segments.first.text, 'Primo pezzo di testo.');
      expect(merger.segments.last.text, 'poi');
      expect(a.open, isTrue);
      a.hypothesis(hyp('poi ancora qualcosa', from: 1200), now: ms(2400));
      a.hypothesis(hyp('poi ancora qualcosa altro', from: 1200), now: ms(2700));
      expect(merger.segments.last.text, 'poi ancora qualcosa');
      expect(merger.text, 'Primo pezzo di testo. poi ancora qualcosa');
    });

    test('senza parole confermate il testo definitivo si aggiunge come '
        'prima (senza la sovrapposizione)', () {
      merger.segments.add(seg(0, 1000, 'la funzione derivata'));
      a.finish([seg(900, 2000, 'derivata è continua')]);
      expect(merger.text, 'la funzione derivata è continua');
    });
  });

  group('lingua della trascrizione', () {
    test('frasi in altre lingue (Parakeet) riconosciute, italiano e '
        'inglese restano', () {
      // dalla registrazione di prova del 22/10/2026 (Parakeet su PC)
      expect(
        outsideLecture(
          'Eu sou um que se cheguei que venga na minha doutorana, se está '
          'enxergando o meu grupo fazia.',
        ),
        isTrue,
      );
      expect(outsideLecture('Nossa allora sentir la nostra.'), isFalse);
      expect(outsideLecture('Allora, un epilogo rapido, è le trate.'), isFalse);
      expect(outsideLecture('I don\'t think.'), isFalse);
      // in una lezione in italiano gli intercalari inglesi del rumore no
      expect(outsideLecture('Thank you.'), isTrue);
      expect(outsideLecture('Yeah.'), isTrue);
      expect(outsideLecture('Thank you.', lecture: 'en'), isFalse);
      expect(
        outsideLecture('Der Satz ist nicht so einfach, aber wir haben Zeit.'),
        isTrue,
      );
      expect(
        outsideLecture('El problema es que no tenemos tiempo para esto.'),
        isTrue,
      );
      expect(outsideLecture('Это совсем не итальянский'), isTrue);
      expect(
        outsideLecture('Oggi vediamo il teorema di Müller e la sua prova.'),
        isFalse,
      );
      expect(outsideLecture('Ok.'), isFalse);
    });
  });

  test('parole di Parakeet con i tempi dei pezzi', () {
    const d = DecodedText(
      'Buongiorno a tutti.',
      tokens: ['▁Buon', 'giorno', '▁a', '▁tutti', '.'],
      timestamps: [0.0, 0.2, 0.5, 0.6, 0.9],
    );
    final w = wordsOfDecoded(d, ms(10000), ms(11000));
    expect(w.map((x) => x.text), ['Buongiorno', 'a', 'tutti.']);
    expect(w.map((x) => x.start), [ms(10000), ms(10500), ms(10600)]);
    expect(w.last.end, ms(11000));
    // senza pezzi: tempi in proporzione ai caratteri
    final t = wordsOfDecoded(const DecodedText('uno due'), ms(0), ms(800));
    expect(t.first.start, Duration.zero);
    expect(t.last.end, ms(800));
  });

  test('frasi del riconoscitore del sistema divise alla punteggiatura', () {
    final s = splitTextSentences(
      'Buongiorno a tutti. Oggi vediamo le serie. Bene.',
      ms(0),
      ms(4800),
    );
    expect(s.map((x) => x.text), [
      'Buongiorno a tutti.',
      'Oggi vediamo le serie. Bene.',
    ]);
    expect(s.first.start, Duration.zero);
    expect(s.last.end, ms(4800));
    expect(s.last.start, greaterThan(Duration.zero));
  });

  test('editor: le parole confermate in fondo alla frase si aggiungono, il '
      'cursore alla fine della frase resta lì', () {
    final b = TranscriptEditBuffer([
      seg(0, 1000, 'Prima frase.'),
      seg(1000, 2000, 'oggi'),
    ]);
    final changes = b.sync([
      seg(0, 1000, 'Prima frase.'),
      seg(1000, 2400, 'oggi parliamo'),
    ]);
    expect(b.text, 'Prima frase. oggi parliamo');
    var cursor = 'Prima frase. oggi'.length;
    for (final c in changes) {
      cursor = c.map(cursor);
    }
    expect(cursor, 'Prima frase. oggi'.length);
    // a metà della prima frase non si sposta
    var mid = 3;
    for (final c in changes) {
      mid = c.map(mid);
    }
    expect(mid, 3);
  });

  group('LiveTranscriber con motori finti', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('un_agree_'));
    tearDown(() => tmp.delete(recursive: true));

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

    Uint8List pcm(double seconds) => Uint8List((seconds * 16000).round() * 2);

    WhisperService service(FakeParakeet pk, {List<String>? whisper}) {
      if (whisper != null) {
        final models = Directory(p.join(tmp.path, 'whisper', 'models'))
          ..createSync(recursive: true);
        File(p.join(models.path, 'ggml-small.bin')).writeAsStringSync('m');
      }
      return WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.macos,
        freeSpace: (_) async => null,
        parakeet: pk,
        macCliCandidates: const [],
        processRunner: (_, _) async => ProcessResult(0, 1, '', ''),
        livePlugin: (model, id) => _ItalianWhisper(id, whisper),
      );
    }

    test('Parakeet: parole confermate mentre si parla, testo definitivo '
        'alla pausa; la frase corretta a mano resta', () async {
      final eng = _ScriptVad([
        _partial('oggi parliamo', 0),
        _partial('oggi parliamo di', 0),
        _partial('oggi parliamo di limiti e', 0),
        _partial('oggi parliamo di limiti e derivate', 0),
        LiveStep(
          committed: [seg(0, 2600, 'Oggi parliamo di limiti e derivate.')],
          partial: '',
          stableUntil: ms(3000),
        ),
      ]);
      final live = LiveTranscriber(service(FakeParakeet(tmp, engine: eng)));
      final saves = <int>[];
      live.onSegments = () => saves.add(live.segments.length);
      await live.begin(await wav(4), sampleRate: 16000, channels: 1);
      expect(live.engine, LiveEngine.parakeet);
      Future<void> step() async {
        live.onPcm(pcm(0.25));
        await live.settle();
      }

      await step();
      expect(live.segments, isEmpty);
      expect(live.partial, 'oggi parliamo');
      await step();
      // ~1 s dopo: già nei segmenti e modificabili
      expect(live.segments.single.text, 'oggi parliamo');
      expect(live.partial, 'di');
      await step();
      expect(live.segments.single.text, 'oggi parliamo di');
      // lo studente corregge la frase mentre si parla
      live.editSegment(0, 'Oggi parliamo di');
      await step();
      expect(live.segments.map((s) => s.text), [
        'Oggi parliamo di',
        'limiti e',
      ]);
      await step();
      // alla pausa: la frase modificata resta, il resto con la punteggiatura
      expect(live.segments.map((s) => s.text), [
        'Oggi parliamo di',
        'limiti e derivate.',
      ]);
      expect(live.partial, '');
      expect(live.isEdited(0), isTrue);
      expect(saves, isNotEmpty);
      await live.close();
    });

    test('Parakeet: frase in un\'altra lingua tolta e ritrascritta con '
        'Whisper in italiano', () async {
      final eng = _ScriptVad([
        LiveStep(
          committed: [
            seg(0, 1500, 'Buongiorno a tutti.'),
            seg(1500, 3800, 'Eu sou um que se cheguei na minha doutorana.'),
          ],
          partial: '',
          stableUntil: ms(4000),
        ),
      ]);
      final heard = <String>[];
      final live = LiveTranscriber(
        service(FakeParakeet(tmp, engine: eng), whisper: heard),
      );
      final f = await wav(4);
      await live.begin(f, sampleRate: 16000, channels: 1);
      live.onPcm(pcm(0.25));
      await live.settle();
      expect(live.foreignDropped, 1);
      final pending = live.finish(const Duration(seconds: 4));
      await live.recover(pending, f);
      expect(live.segments.map((s) => s.text), [
        'Buongiorno a tutti.',
        'testo in italiano',
      ]);
      expect(live.foreignRescued, 1);
      // Whisper con la lingua fissata
      expect(heard.single, 'it');
      expect(live.note, contains('Whisper la ritrascrive in italiano'));
      await live.close();
    });

    test('Parakeet senza modello Whisper: la frase in un\'altra lingua si '
        'toglie e la card lo dice', () async {
      final eng = _ScriptVad([
        LiveStep(
          committed: [
            seg(0, 2000, 'El problema es que no tenemos tiempo para esto.'),
          ],
          partial: '',
          stableUntil: ms(2500),
        ),
      ]);
      final live = LiveTranscriber(service(FakeParakeet(tmp, engine: eng)));
      final f = await wav(3);
      await live.begin(f, sampleRate: 16000, channels: 1);
      live.onPcm(pcm(0.25));
      await live.settle();
      await live.recover(live.finish(const Duration(seconds: 3)), f);
      expect(live.segments, isEmpty);
      expect(live.note, contains('è stata tolta'));
      await live.close();
    });

    test('fine registrazione a metà frase: il recupero sostituisce le parole '
        'confermate (niente doppioni)', () async {
      final eng = _ScriptVad([
        _partial('ultima frase della', 0, stable: 0),
        _partial('ultima frase della lezione', 0, stable: 0),
      ], recovered: 'Ultima frase della lezione di oggi.');
      final live = LiveTranscriber(service(FakeParakeet(tmp, engine: eng)));
      final f = await wav(3);
      await live.begin(f, sampleRate: 16000, channels: 1);
      live.onPcm(pcm(0.25));
      await live.settle();
      live.onPcm(pcm(0.25));
      await live.settle();
      expect(live.segments.single.text, 'ultima frase della');
      final pending = live.finish(const Duration(seconds: 3));
      expect(pending.single.start, Duration.zero);
      await live.recover(pending, f);
      expect(live.segments.map((s) => s.text), [
        'Ultima frase della lezione di oggi.',
      ]);
      await live.close();
    });
  });
}

LiveStep _partial(String text, int from, {int stable = 0}) => LiveStep(
  partial: text,
  partialWords: hyp(text, from: from),
  speaking: true,
  stableUntil: ms(stable),
);

/// Parakeet finto: a ogni pezzo di audio il passo successivo del copione.
class _ScriptVad implements VadLiveEngine {
  _ScriptVad(this.steps, {this.recovered});
  final List<LiveStep> steps;
  final String? recovered;
  var _i = 0;

  @override
  String get modelId => kParakeetId;

  @override
  Future<LiveStep> feed(
    int start,
    Float32List samples, {
    bool partial = true,
  }) async => _i < steps.length ? steps[_i++] : const LiveStep();

  @override
  Future<List<TranscriptSegment>> transcribeRange(
    File wav,
    Duration start,
    Duration end,
  ) async => [if (recovered != null) TranscriptSegment(start, end, recovered!)];

  @override
  Future<void> close() async {}
}

/// Whisper finto: «testo in italiano» e la lingua con cui è stato chiamato.
class _ItalianWhisper extends LiveWhisper {
  _ItalianWhisper(this.modelId, this.heard);
  @override
  final String modelId;
  final List<String>? heard;

  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async {
    heard?.add(options.whisperLanguage);
    return const [
      WhisperSegment(
        Duration.zero,
        'testo in italiano',
        end: Duration(milliseconds: 500),
      ),
    ];
  }

  @override
  Future<void> close() async {}
}
