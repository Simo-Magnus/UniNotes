// Terzo giro della caccia ai crash (R3-D): memoria, sessioni lunghe e
// blocchi del filo dell'interfaccia. Prove veloci nella suite normale; con
// CRASH_R3_LONG=1 le stesse prove con le dimensioni vere (4 ore di lezione,
// migliaia di paragrafi e di file) e le misure stampate.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/notes/markdown_view.dart';
import 'package:university_notes/features/notes/recorder/live_agreement.dart';
import 'package:university_notes/features/notes/recorder/live_transcript.dart';
import 'package:university_notes/features/notes/recorder/live_transcript_editor.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/features/notes/spell_check.dart';
import 'package:university_notes/features/reader/files_screen.dart';

final _long = Platform.environment['CRASH_R3_LONG'] == '1';

void _say(String s) {
  // ignore: avoid_print
  if (_long) print(s);
}

const _vocab = [
  'teorema',
  'funzione',
  'derivata',
  'integrale',
  'limite',
  'continua',
  'quindi',
  'allora',
  'vediamo',
  'esempio',
  'dimostrazione',
  'insieme',
  'numero',
  'reale',
  'successione',
  'serie',
  'converge',
  'punto',
];

String _word(int i) => '${_vocab[i % _vocab.length]}${i % 7 == 0 ? i : ''}';

/// Frasi finte di una lezione: [n] frasi da 12 parole, una ogni 5,5 s
/// (2600 frasi ≈ 4 ore a ~130 parole al minuto).
List<TranscriptSegment> _lecture(int n) => [
  for (var i = 0; i < n; i++)
    TranscriptSegment(
      Duration(milliseconds: i * 5500),
      Duration(milliseconds: i * 5500 + 5000),
      '${[for (var k = 0; k < 12; k++) _word(i * 12 + k)].join(' ')}.',
    ),
];

/// Correttore finto: nessun errore, conta le richieste.
class _Counting extends SpellCheckService {
  int calls = 0;
  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    calls++;
    return const [];
  }
}

void main() {
  test('misura: forma d\'onda di 40 ore con BytesBuilder', () {
    if (!_long) return;
    for (final copy in [false, true]) {
      final b = BytesBuilder(copy: copy);
      final before = ProcessInfo.currentRss;
      for (var i = 0; i < 1440000; i++) {
        b.addByte(i & 255);
      }
      final grown = ProcessInfo.currentRss - before;
      _say('BytesBuilder(copy: $copy): +${grown >> 20} MB per 1,44 M livelli');
      expect(b.takeBytes().length, 1440000);
    }
  });

  group('trascrizione dal vivo di ore', () {
    Widget card(List<TranscriptSegment> segs, String partial, _Counting sp) =>
        MaterialApp(
          home: Scaffold(
            body: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: EditableLiveTranscript(
                  segments: segs,
                  partial: partial,
                  spellService: sp,
                  onEdit: (_) {},
                ),
              ),
            ),
          ),
        );

    testWidgets('una parola nuova reimpagina solo l\'ultimo blocco', (
      tester,
    ) async {
      // Prima: un paragrafo unico con tutta la lezione, reimpaginato a ogni
      // testo provvisorio (2600 frasi: ~115 ms sul PC per ogni parola).
      final n = _long ? 2600 : 400;
      final segs = _lecture(n);
      final sp = _Counting();
      var sw = Stopwatch()..start();
      await tester.pumpWidget(card(segs, '', sp));
      _say('primo disegno, $n frasi: ${sw.elapsedMilliseconds} ms');
      final blocks = (n / kLiveReadingBlock).ceil();
      expect(find.byType(RichText), findsNWidgets(blocks));
      final first = tester.widget<RichText>(find.byType(RichText).first);
      final firstBox = tester.renderObject<RenderParagraph>(
        find.byType(RichText).first,
      );
      sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        await tester.pumpWidget(card(segs, 'parola $i', sp));
      }
      final perWord = sw.elapsedMilliseconds / 10;
      _say('testo provvisorio cambiato: $perWord ms');
      sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        await tester.pumpWidget(card(segs, 'parola 9', sp));
      }
      _say('orologio (niente cambia): ${sw.elapsedMilliseconds / 10} ms');
      // il primo blocco è lo stesso paragrafo, non ricostruito
      expect(
        identical(tester.widget<RichText>(find.byType(RichText).first), first),
        isTrue,
      );
      expect(firstBox.debugNeedsLayout, isFalse);
      expect(
        find.textContaining('parola 9', findRichText: true),
        findsOneWidget,
      );
      // una frase nuova: cambia solo l'ultimo blocco
      final more = [
        ...segs,
        TranscriptSegment(
          Duration(milliseconds: n * 5500),
          Duration(milliseconds: n * 5500 + 3000),
          'frase nuova.',
        ),
      ];
      await tester.pumpWidget(card(more, '', sp));
      expect(
        identical(tester.widget<RichText>(find.byType(RichText).first), first),
        isTrue,
      );
      expect(find.textContaining('frase nuova.', findRichText: true), findsOne);
      if (_long) expect(perWord, lessThan(60));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('modifica a blocchi: nel campo solo il blocco toccato', (
      tester,
    ) async {
      // Prima tutto il testo finiva in un campo solo: con ore di lezione ogni
      // tasto e ogni parola confermata reimpaginavano tutto (2600 frasi:
      // ~140 ms sul PC per tasto).
      var segs = _lecture(kLiveReadingBlock * 2 + 5);
      final edits = <TranscriptEdit>[];
      late StateSetter set;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) {
                  set = setState;
                  return EditableLiveTranscript(
                    segments: segs,
                    partial: 'in corso',
                    spellService: _Counting(),
                    onEdit: edits.add,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byType(RichText).at(1));
      await tester.pumpAndSettle();
      final rp = tester.renderObject<RenderParagraph>(
        find.byType(RichText).at(1),
      );
      await tester.tapAt(rp.localToGlobal(const Offset(1, 6)));
      await tester.pump();
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final block = segs.sublist(kLiveReadingBlock, kLiveReadingBlock * 2);
      // il campo ha le frasi del secondo blocco, il cursore all'inizio
      expect(editable.controller.text, block.map((s) => s.text).join(' '));
      expect(editable.controller.selection.baseOffset, 0);
      // gli altri blocchi restano in lettura, prima e dopo il campo
      expect(
        find.textContaining(segs.first.text, findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining(segs.last.text, findRichText: true),
        findsOneWidget,
      );
      // una modifica tocca solo le frasi del blocco
      await tester.enterText(
        find.byType(EditableText),
        'Corretto ${editable.controller.text}',
      );
      await tester.pump();
      expect(edits.single.keys, [block.first.start.inMilliseconds]);
      // una frase nuova arriva in fondo, fuori dal campo
      set(
        () => segs = [
          ...segs,
          const TranscriptSegment(
            Duration(hours: 3),
            Duration(hours: 3, seconds: 2),
            'arrivata adesso.',
          ),
        ],
      );
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isNot(contains('arrivata adesso.')),
      );
      expect(
        find.textContaining('arrivata adesso.', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      "modifica nell'ultimo blocco: le frasi nuove entrano nel campo",
      (tester) async {
        var segs = _lecture(kLiveReadingBlock + 5);
        late StateSetter set;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    set = setState;
                    return EditableLiveTranscript(
                      segments: segs,
                      partial: '',
                      spellService: _Counting(),
                      onEdit: (_) {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.byType(RichText).at(1));
        await tester.pumpAndSettle();
        final rp = tester.renderObject<RenderParagraph>(
          find.byType(RichText).at(1),
        );
        await tester.tapAt(rp.localToGlobal(const Offset(1, 6)));
        await tester.pump();
        set(
          () => segs = [
            ...segs,
            const TranscriptSegment(
              Duration(hours: 3),
              Duration(hours: 3, seconds: 2),
              'arrivata adesso.',
            ),
          ],
        );
        await tester.pump();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          endsWith('arrivata adesso.'),
        );
      },
    );
  });

  testWidgets('misura: modifica della trascrizione dopo ore', (tester) async {
    if (!_long) return;
    final segs = _lecture(2600);
    Widget app(List<TranscriptSegment> s) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: EditableLiveTranscript(
            segments: s,
            partial: '',
            spellService: _Counting(),
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(segs));
    final rp = tester.renderObject<RenderParagraph>(
      find.byType(RichText).first,
    );
    var sw = Stopwatch()..start();
    await tester.tapAt(rp.localToGlobal(const Offset(1, 6)));
    await tester.pump();
    await tester.pump();
    _say('entrata nella modifica: ${sw.elapsedMilliseconds} ms');
    sw = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      final more = [
        ...segs,
        TranscriptSegment(
          const Duration(hours: 5),
          const Duration(hours: 5, seconds: 1),
          'parola ' * (i + 1),
        ),
      ];
      await tester.pumpWidget(app(more));
    }
    _say(
      'parola confermata durante la modifica: ${sw.elapsedMilliseconds / 5} ms',
    );
    sw = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      await tester.enterText(
        find.byType(EditableText),
        '${tester.widget<EditableText>(find.byType(EditableText)).controller.text}x',
      );
      await tester.pump();
    }
    _say('tasto durante la modifica: ${sw.elapsedMilliseconds / 5} ms');
  });

  group('controllo ortografico in lettura', () {
    test('più di 4000 frasi mostrate: nessun ricontrollo senza fine', () async {
      // Prima a 4000 testi la memoria si svuotava tutta: con 4500 frasi
      // sullo schermo ogni giro ricontrollava ~4000 frasi (e ridisegnava
      // tutto ogni 25), per sempre.
      final sp = _Counting();
      final c = ReadingSpellChecker(service: sp, delay: Duration.zero);
      final texts = [for (final s in _lecture(4500)) s.text];
      for (var pass = 0; pass < 3; pass++) {
        for (final t in texts) {
          c.errorsOf(t);
        }
        await pumpEventQueue(times: 30000);
      }
      expect(sp.calls, texts.length);
      expect(c.cachedCount, texts.length);
      c.dispose();
    });

    test(
      'le versioni vecchie della frase in corso escono dalla memoria',
      () async {
        final sp = _Counting();
        final c = ReadingSpellChecker(service: sp, delay: Duration.zero);
        final shown = [for (final s in _lecture(_long ? 2600 : 1000)) s.text];
        // la frase in corso cresce di una parola alla volta (ogni versione è
        // un testo nuovo)
        final words = _long ? 30000 : 6000;
        var tail = '';
        for (var w = 0; w < words; w++) {
          tail = w % 12 == 0 ? _word(w) : '$tail ${_word(w)}';
          for (final t in shown) {
            c.errorsOf(t);
          }
          c.errorsOf(tail);
          if (w % 50 == 0) await pumpEventQueue(times: 300);
        }
        await pumpEventQueue(times: 3000);
        // le frasi mostrate si sono controllate una volta sola
        expect(sp.calls, lessThanOrEqualTo(shown.length + words));
        expect(c.cachedCount, lessThanOrEqualTo(4000));
        for (final t in shown) {
          expect(c.known(t), isNotNull);
        }
        c.dispose();
      },
    );

    test(
      'campo di modifica con più di 4000 frasi: nessun ricontrollo',
      () async {
        final inner = _Counting();
        final cache = <String, List<SuggestionSpan>>{};
        final text = [
          for (var i = 0; i < 4500; i++) 'frase numero $i del testo.',
        ].join(' ');
        await SentenceSpellCheck(
          inner,
          cache: cache,
        ).fetchSpellCheckSuggestions(const Locale('it'), text);
        final first = inner.calls;
        expect(first, 4500);
        await SentenceSpellCheck(
          inner,
          cache: cache,
        ).fetchSpellCheckSuggestions(const Locale('it'), '$text Nuova.');
        expect(inner.calls, first + 1);
      },
    );
  });

  group('documenti lunghi (MarkdownLiteView)', () {
    String doc(int n) => [for (final s in _lecture(n)) s.text].join('\n\n');

    testWidgets(
      'migliaia di paragrafi: si costruisce solo quello che si vede',
      (tester) async {
        // Prima: 5000 paragrafi ≈ 3,2 s di interfaccia ferma all'apertura e a
        // ogni ridisegno del controllo ortografico (ogni 25 controlli).
        final n = _long ? 5000 : 1500;
        final sp = _Counting();
        final sw = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MarkdownLiteView(
                doc(n),
                spellLanguage: 'it',
                spellService: sp,
              ),
            ),
          ),
        );
        _say(
          'markdown $n paragrafi, primo disegno: ${sw.elapsedMilliseconds} ms',
        );
        expect(find.byType(RichText).evaluate().length, lessThan(200));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        // si controllano i paragrafi costruiti, non tutto il documento
        expect(sp.calls, lessThan(200));
        expect(tester.takeException(), isNull);
        expect(sw.elapsedMilliseconds, lessThan(_long ? 3000 : 2000));
      },
    );

    testWidgets('la ricerca porta in vista un risultato lontano', (
      tester,
    ) async {
      final text =
          '${doc(_long ? 5000 : 1200)}\n\nparola introvabile alla fine.';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchableMarkdownView(text, initialQuery: 'introvabile'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hit = find.descendant(
        of: find.byType(MarkdownLiteView),
        matching: find.textContaining('introvabile', findRichText: true),
      );
      expect(hit, findsOneWidget);
      final box = tester.getRect(hit);
      final screen = tester.getRect(find.byType(Scaffold));
      expect(screen.overlaps(box), isTrue);
      expect(find.text('1 di 1'), findsOneWidget);
    });

    testWidgets('documento breve: tutto costruito come prima', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: MarkdownLiteView(doc(50)))),
      );
      expect(find.byType(RichText), findsNWidgets(50));
    });
  });

  test('accordo delle parole: nessuna crescita con la durata', () {
    // 4 ore a 130 parole al minuto, un'ipotesi ogni ~0,9 s (Parakeet): il
    // costo per ipotesi resta piccolo anche con migliaia di frasi
    final minutes = _long ? 240 : 40;
    final merger = TranscriptMerger();
    final agree = LiveAgreement(merger, isEdited: (_) => false);
    final words = minutes * 130;
    final firstQuarter = Stopwatch();
    final lastQuarter = Stopwatch();
    var sentence = <HypWord>[];
    var t = Duration.zero;
    for (var w = 0; w < words;) {
      final q = w * 4 ~/ words;
      final sw = q == 0 ? firstQuarter : (q == 3 ? lastQuarter : null);
      sw?.start();
      for (var k = 0; k < 2 && w < words; k++, w++) {
        t += const Duration(milliseconds: 460);
        sentence.add(HypWord(_word(w), start: t, end: t));
      }
      agree.hypothesis([...sentence, const HypWord('forse')], now: t);
      if (sentence.length >= 12) {
        agree.finish([
          TranscriptSegment(
            sentence.first.start!,
            t,
            '${sentence.map((x) => x.text).join(' ')}.',
          ),
        ], now: t);
        sentence = [];
      }
      sw?.stop();
    }
    _say(
      'accordo $minutes min: primo quarto ${firstQuarter.elapsedMilliseconds} '
      'ms, ultimo ${lastQuarter.elapsedMilliseconds} ms, '
      '${merger.segments.length} frasi',
    );
    expect(merger.segments.length, closeTo(words / 12, 2));
    // ultimo quarto non molto più lento del primo (niente O(n²) che pesa)
    expect(
      lastQuarter.elapsedMilliseconds,
      lessThan(firstQuarter.elapsedMilliseconds * 8 + 200),
    );
  });

  testWidgets('cartella con migliaia di file', (tester) async {
    final n = _long ? 2000 : 400;
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('r3d_cartella_'),
    );
    addTearDown(() => dir!.deleteSync(recursive: true));
    await tester.runAsync(() async {
      for (var i = 0; i < n; i++) {
        await File(p.join(dir!.path, 'lezione_$i.pdf')).writeAsString('x');
      }
    });
    final sw = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: FolderBrowserScreen(dir: dir!, title: 'Cartella'),
      ),
    );
    for (var i = 0; i < 50 && find.byType(ListTile).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    final ms = sw.elapsedMilliseconds;
    _say(
      'cartella con $n file: $ms ms, ${find.byType(ListTile).evaluate().length} righe costruite',
    );
    expect(find.byType(ListTile), findsWidgets);
    expect(find.byType(ListTile).evaluate().length, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  test(
    'taglio del WAV con l\'originale sparito: nessun file lasciato aperto',
    () async {
      final dir = await Directory.systemTemp.createTemp('r3d_wav_');
      addTearDown(() => dir.delete(recursive: true));
      final dst = File(p.join(dir.path, 'tagliato.wav'));
      final info = WavInfo(sampleRate: 16000, channels: 1, dataLength: 32000);
      await expectLater(
        cutWav(File(p.join(dir.path, 'manca.wav')), info, dst, [
          (Duration.zero, const Duration(seconds: 1)),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      // su Windows un file ancora aperto non si cancella
      await dst.delete();
      expect(await dst.exists(), isFalse);
    },
  );
}
