import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/live_transcript_editor.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';

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
      expect(ins, [(5, 5, false), (14, 9, true)]);
      expect(b.pieces.map((x) => (x.key, x.start, x.end)), [
        (0, 0, 4),
        (3000, 5, 9),
        (6000, 10, 14),
        (9000, 15, 23),
      ]);
      // nessuna frase nuova: niente
      expect(b.sync([_seg(0, 2, 'Uno.')]), isEmpty);
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
    final plain = t.widget<RichText>(reading).text.toPlainText(
      includePlaceholders: false,
    );
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
  });
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
