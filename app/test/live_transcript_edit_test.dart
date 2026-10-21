import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/live_transcript_editor.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/spell_check.dart';

TranscriptSegment _seg(int s, int e, String t) =>
    TranscriptSegment(Duration(seconds: s), Duration(seconds: e), t);

void main() {
  group('testo della trascrizione come in un editor', () {
    test('scrivere dentro una frase cambia solo quella', () {
      final b = TranscriptEditBuffer([
        _seg(0, 2, 'Ciao a tutti.'),
        _seg(2, 4, 'Oggi integrali.'),
      ]);
      expect(b.text, 'Ciao a tutti. Oggi integrali.');
      // «Oggi parliamo di integrali.»: inserimento a metà della seconda
      final edit = b.apply('Ciao a tutti. Oggi parliamo di integrali.');
      expect(edit, const TranscriptEdit([2000], 'Oggi parliamo di integrali.'));
      expect(b.pieces.map((x) => (x.start, x.end)), [(0, 13), (14, 41)]);
      // in fondo alla prima frase (prima dello spazio) va alla prima
      expect(
        b.apply('Ciao a tutti! Oggi parliamo di integrali.'),
        const TranscriptEdit([0], 'Ciao a tutti!'),
      );
    });

    test('cancellare lo spazio fra due frasi le unisce', () {
      final b = TranscriptEditBuffer([
        _seg(0, 2, 'Prima'),
        _seg(2, 4, 'seconda'),
        _seg(4, 6, 'terza.'),
      ]);
      final edit = b.apply('Primaseconda terza.');
      expect(edit, const TranscriptEdit([0, 2000], 'Primaseconda'));
      expect(b.pieces.map((x) => x.key), [0, 4000]);
      expect(b.pieces.last.start, 13);
      // selezione su due frasi sostituita da un testo incollato
      expect(
        b.apply('Prima incollato.'),
        const TranscriptEdit([0, 4000], 'Prima incollato.'),
      );
      expect(b.pieces.single.end, 16);
    });

    test('svuotare una frase la toglie', () {
      final b = TranscriptEditBuffer([_seg(0, 2, 'Ehm.'), _seg(2, 4, 'Bene.')]);
      expect(b.apply(' Bene.'), const TranscriptEdit([0], ''));
      expect(b.pieces.map((x) => x.key), [2000]);
      // scrivendo nello spazio rimasto si torna alla frase vicina
      expect(
        b.apply('Allora Bene.'),
        const TranscriptEdit([2000], 'Allora Bene.'),
      );
    });

    test('le frasi nuove arrivano al loro posto mentre si scrive', () {
      final b = TranscriptEditBuffer([_seg(0, 2, 'Uno.'), _seg(6, 8, 'Tre.')]);
      final ins = b.sync([
        _seg(0, 2, 'Uno.'),
        _seg(3, 5, 'Due.'),
        _seg(6, 8, 'Tre.'),
        _seg(9, 10, 'Quattro.'),
      ]);
      expect(b.text, 'Uno. Due. Tre. Quattro.');
      expect(ins, const [
        TranscriptChange(5, 0, 5),
        TranscriptChange(14, 0, 9, end: true),
      ]);
      // il cursore in fondo resta prima della frase nuova, a metà la segue
      expect(ins.last.map(14), 14);
      expect(ins.first.map(5), 10);
      expect(b.pieces.map((x) => (x.key, x.start, x.end)), [
        (0, 0, 4),
        (3000, 5, 9),
        (6000, 10, 14),
        (9000, 15, 23),
      ]);
      // nessuna frase nuova né cambiata: niente
      expect(
        b.sync([
          _seg(0, 2, 'Uno.'),
          _seg(3, 5, 'Due.'),
          _seg(6, 8, 'Tre.'),
          _seg(9, 10, 'Quattro.'),
        ]),
        isEmpty,
      );
    });

    test('le frasi riscritte dal programma (seconda passata, formule) si '
        'aggiornano, quelle corrette a mano no', () {
      final b = TranscriptEditBuffer([
        _seg(0, 2, 'Uno.'),
        _seg(2, 4, 'Doe.'),
        _seg(4, 6, 'Tre.'),
        _seg(6, 8, 'Quatro.'),
      ]);
      // lo studente corregge «Doe.» in «Due. » (con lo spazio in più che la
      // trascrizione toglierebbe)
      expect(
        b.apply('Uno. Due.  Tre. Quatro.'),
        const TranscriptEdit([2000], 'Due. '),
      );
      expect(b.owned, {2000});
      // la seconda passata riscrive il tratto: «Tre.» e «Quatro.» diventano
      // «Tre, quattro.» (una frase nuova), «Uno.» diventa «Uno!»; la frase
      // corretta resta com'è (anche se la trascrizione la dà senza spazio)
      final changes = b.sync([
        _seg(0, 2, 'Uno!'),
        _seg(2, 4, 'Due.'),
        _seg(4, 8, 'Tre, quattro.'),
      ]);
      expect(b.text, 'Uno! Due.  Tre, quattro.');
      expect(b.pieces.map((x) => (x.key, b.text.substring(x.start, x.end))), [
        (0, 'Uno!'),
        (2000, 'Due. '),
        (4000, 'Tre, quattro.'),
      ]);
      // il cursore dopo «Due.» (posizione 9) resta lì
      var cursor = 9;
      for (final c in changes) {
        cursor = c.map(cursor);
      }
      expect(cursor, 9);
      // il cursore dentro una frase tolta va dove c'era la frase
      final c = TranscriptEditBuffer([_seg(0, 2, 'Uno.'), _seg(2, 4, 'Due.')]);
      final gone = c.sync([_seg(0, 2, 'Uno.')]);
      expect(c.text, 'Uno.');
      expect(gone.single.map(7), 4);
    });

    test('LiveTranscriber: le frasi toccate diventano una, gli altri tempi '
        'restano', () {
      final live = LiveTranscriber(null);
      live.restore([
        _seg(0, 2, 'Prima'),
        _seg(2, 4, 'seconda'),
        _seg(4, 6, 'terza.'),
      ]);
      live.replaceSegments([0, 2000], '  Primaseconda ');
      expect(live.segments.map((s) => (s.start, s.end, s.text)), [
        (Duration.zero, const Duration(seconds: 4), 'Primaseconda'),
        (const Duration(seconds: 4), const Duration(seconds: 6), 'terza.'),
      ]);
      expect(live.isEdited(0), isTrue);
      live.replaceSegments([4000], ' ');
      expect(live.segments.map((s) => s.text), ['Primaseconda']);
    });
  });

  testWidgets('un tocco mette il cursore nel punto toccato; si scrive nel '
      'testo mentre arrivano frasi nuove; le formule si disegnano in lettura', (
    t,
  ) async {
    final edits = <TranscriptEdit>[];
    var segs = [_seg(0, 2, 'Prima frase.'), _seg(2, 4, r'Vale $\frac{2}{3}$.')];
    late StateSetter update;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StatefulBuilder(
                builder: (context, set) {
                  update = set;
                  return EditableLiveTranscript(
                    segments: segs,
                    partial: 'in corso',
                    onEdit: edits.add,
                  );
                },
              ),
              const SizedBox(height: 40),
              const Text('fuori'),
            ],
          ),
        ),
      ),
    );
    // lettura: formula disegnata, testo provvisorio in coda
    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining('in corso', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('live-edit')), findsNothing);

    // tocco fra «Prima» e « frase»: il cursore va lì (posizione 5)
    final rp = t.renderObject<RenderParagraph>(find.byType(RichText).first);
    final caret = rp.getOffsetForCaret(
      const TextPosition(offset: 5),
      Rect.zero,
    );
    await t.tapAt(rp.localToGlobal(caret + const Offset(1, 6)));
    await t.pump();
    await t.pump();
    final field = find.byKey(const Key('live-edit'));
    expect(field, findsOneWidget);
    final editable = t.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, r'Prima frase. Vale $\frac{2}{3}$.');
    expect(
      editable.controller.selection,
      const TextSelection.collapsed(offset: 5),
    );
    // il provvisorio resta sotto, più chiaro
    expect(find.text('in corso'), findsOneWidget);

    // si scrive nel punto del cursore
    t.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: r'Prima vera frase. Vale $\frac{2}{3}$.',
        selection: TextSelection.collapsed(offset: 10),
      ),
    );
    await t.pump();
    expect(edits, [
      const TranscriptEdit([0], 'Prima vera frase.'),
    ]);

    // intanto arriva una frase nuova: si aggiunge in fondo, il cursore resta
    update(() => segs = [...segs, _seg(4, 6, 'Terza frase.')]);
    await t.pump();
    expect(
      editable.controller.text,
      r'Prima vera frase. Vale $\frac{2}{3}$. Terza frase.',
    );
    expect(editable.controller.selection.baseOffset, 10);

    // Esc: di nuovo in lettura, con la formula disegnata
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const Key('live-edit')), findsNothing);
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('il tocco non apre nessun riquadro (anche con i bordi dei campi '
      'nel tema); le frasi che arrivano o cambiano mentre si scrive restano '
      'modificabili e la tastiera non perde la parola', (t) async {
    final edits = <TranscriptEdit>[];
    var segs = [_seg(0, 2, 'Prima frase.'), _seg(2, 4, 'Seconda.')];
    late StateSetter update;
    final border = OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.cyan, width: 1.5),
      borderRadius: BorderRadius.circular(12),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.black12,
            border: border,
            enabledBorder: border,
            focusedBorder: border,
          ),
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return EditableLiveTranscript(
                segments: segs,
                partial: 'ancora in corso',
                onEdit: edits.add,
              );
            },
          ),
        ),
      ),
    );
    final rp = t.renderObject<RenderParagraph>(find.byType(RichText).first);
    final caret = rp.getOffsetForCaret(
      const TextPosition(offset: 13),
      Rect.zero,
    );
    await t.tapAt(rp.localToGlobal(caret + const Offset(1, 6)));
    await t.pump();
    await t.pump();
    final editable = t.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue, reason: 'tastiera aperta');
    expect(editable.controller.selection.baseOffset, 13);
    // nessun bordo né fondo, in nessuno stato
    final deco = t.widget<InputDecorator>(find.byType(InputDecorator));
    expect(deco.isFocused, isTrue);
    final d = deco.decoration;
    expect(d.filled, isFalse);
    for (final b in [
      d.border,
      d.enabledBorder,
      d.focusedBorder,
      d.disabledBorder,
      d.errorBorder,
      d.focusedErrorBorder,
    ]) {
      expect(b, InputBorder.none);
    }
    expect(d.contentPadding, EdgeInsets.zero);
    // il provvisorio resta visibile sotto, più chiaro
    expect(find.text('ancora in corso'), findsOneWidget);

    // si scrive «Seconda parte.» con la tastiera che compone «parte»
    t.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Prima frase. Seconda parte.',
        selection: TextSelection.collapsed(offset: 26),
        composing: TextRange(start: 21, end: 26),
      ),
    );
    await t.pump();
    expect(edits.last, const TranscriptEdit([2000], 'Seconda parte.'));

    // la seconda passata riscrive la prima frase e il provvisorio diventa
    // una frase: tutto nello stesso campo, la correzione resta, cursore e
    // parola in composizione si spostano con il testo
    update(
      () => segs = [
        _seg(0, 2, 'La prima frase.'),
        _seg(2, 4, 'Seconda.'),
        _seg(4, 6, 'Ancora in corso.'),
      ],
    );
    await t.pump();
    expect(
      editable.controller.text,
      'La prima frase. Seconda parte. Ancora in corso.',
    );
    expect(editable.controller.selection.baseOffset, 29);
    expect(
      editable.controller.value.composing,
      const TextRange(start: 24, end: 29),
    );
    // anche la frase appena arrivata si modifica
    t.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'La prima frase. Seconda parte. Ancora in corso!',
        selection: TextSelection.collapsed(offset: 47),
      ),
    );
    await t.pump();
    expect(edits.last, const TranscriptEdit([4000], 'Ancora in corso!'));
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('in lettura le parole errate hanno la linea ondulata rossa, '
      'senza entrare nella modifica', (t) async {
    final service = _FakeSpell();
    var segs = [
      _seg(0, 2, 'Prima ciaoo frase.'),
      _seg(2, 4, r'Vale $\frac{2}{3}$ e ciaoo.'),
    ];
    late StateSetter update;
    final edits = <TranscriptEdit>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return EditableLiveTranscript(
                segments: segs,
                partial: 'ciaoo provvisorio',
                spellService: service,
                onEdit: edits.add,
              );
            },
          ),
        ),
      ),
    );
    final reading = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains('Prima'),
    );
    List<String> wavy() {
      final out = <String>[];
      t.widget<RichText>(reading).text.visitChildren((s) {
        if (s is TextSpan &&
            s.style?.decoration == TextDecoration.underline &&
            s.style?.decorationStyle == TextDecorationStyle.wavy) {
          out.add(s.text ?? '');
        }
        return true;
      });
      return out;
    }

    // all'inizio il testo si vede com'è, il controllo parte dopo un attimo
    expect(wavy(), isEmpty);
    expect(service.calls, isEmpty);
    await t.pump(const Duration(milliseconds: 700));
    await t.pump();
    // le frasi (non il provvisorio) sono state controllate una volta
    expect(service.calls, [
      'Prima ciaoo frase.',
      r'Vale $\frac{2}{3}$ e ciaoo.',
    ]);
    expect(wavy(), ['ciaoo', 'ciaoo']);
    expect(find.byKey(const Key('live-edit')), findsNothing);
    // il testo (e quindi quello dei lettori di schermo) non cambia
    final plain = t
        .widget<RichText>(reading)
        .text
        .toPlainText(includePlaceholders: false);
    expect(plain, 'Prima ciaoo frase. Vale  e ciaoo. ciaoo provvisorio');
    expect(find.byType(Math), findsOneWidget);

    // ridisegnando il testo non si richiede nulla; una frase nuova sì, da sola
    update(() => segs = [...segs, _seg(4, 6, 'Terza ciaoo.')]);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(service.calls, hasLength(2));
    await t.pump(const Duration(milliseconds: 700));
    await t.pump();
    expect(service.calls.last, 'Terza ciaoo.');
    expect(service.calls, hasLength(3));
    expect(wavy(), ['ciaoo', 'ciaoo', 'ciaoo']);

    // il tocco mette ancora il cursore nel punto toccato (posizione 8 dentro
    // «Prima ciaoo frase.»: fra «ci» e «aoo»)
    final rp = t.renderObject<RenderParagraph>(reading);
    final caret = rp.getOffsetForCaret(
      const TextPosition(offset: 8),
      Rect.zero,
    );
    await t.tapAt(rp.localToGlobal(caret + const Offset(1, 6)));
    await t.pump();
    await t.pump();
    final editable = t.widget<EditableText>(find.byType(EditableText));
    expect(
      editable.controller.selection,
      const TextSelection.collapsed(offset: 8),
    );

    // in modifica la linea rossa resta (risultati della lettura, nessuna
    // nuova richiesta) e arriva anche sulle frasi nuove
    List<String> wavyInField() {
      final out = <String>[];
      final field = t.state<EditableTextState>(find.byType(EditableText));
      field.renderEditable.text?.visitChildren((s) {
        if (s is TextSpan &&
            s.style?.decorationStyle == TextDecorationStyle.wavy) {
          out.add(s.text ?? '');
        }
        return true;
      });
      return out;
    }

    await t.pump();
    await t.pump();
    expect(wavyInField(), ['ciaoo', 'ciaoo', 'ciaoo']);
    expect(service.calls, hasLength(3));
    update(() => segs = [...segs, _seg(6, 8, 'Quarta ciaoo.')]);
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    await t.pump();
    expect(service.calls.last, 'Quarta ciaoo.');
    expect(service.calls, hasLength(4), reason: 'solo la frase nuova');
    expect(wavyInField(), ['ciaoo', 'ciaoo', 'ciaoo', 'ciaoo']);
    await t.pump(const Duration(seconds: 1));
  });

  test(
    'controllo per frasi: divisione (mai dentro una formula) e memoria',
    () async {
      expect(
        SentenceSpellCheck.sentences(
          r'Uno. Vale $a. b$ ok! Tre?'
          '\nQuattro',
        ),
        [(0, 'Uno.'), (5, r'Vale $a. b$ ok!'), (21, 'Tre?'), (26, 'Quattro')],
      );
      final fake = _FakeSpell();
      final cache = <String, List<SuggestionSpan>>{};
      final s = SentenceSpellCheck(fake, cache: cache);
      final r = await s.fetchSpellCheckSuggestions(
        const Locale('it'),
        'Bene. Poi ciaoo.',
      );
      expect(r!.single.range, const TextRange(start: 10, end: 15));
      await SentenceSpellCheck(fake, cache: cache).fetchSpellCheckSuggestions(
        const Locale('it'),
        'Bene. Poi ciaoo. Altro.',
      );
      expect(fake.calls, ['Bene.', 'Poi ciaoo.', 'Altro.']);
    },
  );
}

/// Servizio del controllo ortografico finto: «ciaoo» è errato.
class _FakeSpell extends SpellCheckService {
  final calls = <String>[];

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    calls.add(text);
    return [
      for (final m in RegExp('ciaoo').allMatches(text))
        SuggestionSpan(TextRange(start: m.start, end: m.end), const ['ciao']),
    ];
  }
}
