import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/formula_dialog.dart';
import 'package:university_notes/features/notes/markdown_lite.dart';
import 'package:university_notes/features/notes/markdown_view.dart';
import 'package:university_notes/widgets/math_text.dart';

/// Formule trovate in una riga (in ordine).
List<String> _math(String line) => [
  for (final s in parseInline(line))
    if (s.math) s.text,
];

/// Testo semplice ricomposto (senza le formule).
String _plain(String line) => [
  for (final s in parseInline(line))
    if (!s.math) s.text,
].join();

void main() {
  group('formule in linea', () {
    test(r'$…$ e \(…\)', () {
      expect(_math(r'La derivata di $x^2$ è $2x$.'), ['x^2', '2x']);
      expect(_math(r'Area \(\pi r^2\) del cerchio'), [r'\pi r^2']);
      expect(_plain(r'La derivata di $x^2$ è $2x$.'), 'La derivata di  è .');
    });

    test(r'$$…$$ dentro una riga: formula «a sé»', () {
      final spans = parseInline(r'Ricorda $$E = mc^2$$ sempre');
      final f = spans.where((s) => s.math).single;
      expect(f.text, 'E = mc^2');
      expect(f.display, isTrue);
      expect(f.source, r'$$E = mc^2$$');
    });

    test(r'il $ usato come valuta non apre una formula', () {
      expect(_math(r'Il libro costa $5 al mese'), isEmpty);
      expect(_math(r'Prezzi: $10,50 e $3'), isEmpty);
      expect(_math(r'Costa $5, poi $6.'), isEmpty);
      expect(_math(r'Da 5$ a 10$ al giorno'), isEmpty);
      expect(_math(r'US$ 20 o $ 30'), isEmpty);
      expect(_math(r'Solo $5.'), isEmpty);
      expect(
        _plain(r'Il libro costa $5 al mese'),
        r'Il libro costa $5 al mese',
      );
    });

    test('valuta e formula nella stessa riga', () {
      expect(_math(r'Con $5 compri $x$ penne'), ['x']);
    });

    test(r'\$ scrive un dollaro', () {
      expect(_math(r'Costa \$5 e \$x\$'), isEmpty);
      expect(_plain(r'Costa \$5'), r'Costa $5');
    });

    test('una formula senza chiusura resta testo', () {
      expect(_math(r'Inizio $x senza fine'), isEmpty);
      expect(_plain(r'Inizio $$ senza fine'), r'Inizio $$ senza fine');
    });

    test('dentro una formula * e _ non sono corsivo', () {
      final spans = parseInline(r'Sia $a_i * b_j$ e *corsivo*');
      expect(spans.firstWhere((s) => s.math).text, 'a_i * b_j');
      expect(spans.firstWhere((s) => s.italic).text, 'corsivo');
    });

    test('solo formule: il resto resta com\'è scritto', () {
      final spans = parseMathOnly(r'x_1 e *non corsivo* con $y_1$');
      expect(spans.map((s) => s.text).toList(), [
        'x_1 e *non corsivo* con ',
        'y_1',
      ]);
      expect(spans.last.math, isTrue);
    });
  });

  group('formule a blocco', () {
    test(r'$$ su più righe e \[ … \]', () {
      final b = parseMarkdown(r'''
Testo prima.

$$
\int_0^1 x\,dx = \frac{1}{2}
$$

\[ a^2 + b^2 = c^2 \]
$$ \sum_i i $$
Dopo.
''');
      expect(b.map((x) => x.type).toList(), [
        MdBlockType.paragraph,
        MdBlockType.math,
        MdBlockType.math,
        MdBlockType.math,
        MdBlockType.paragraph,
      ]);
      expect(b[1].raw, r'\int_0^1 x\,dx = \frac{1}{2}');
      expect(b[2].raw, 'a^2 + b^2 = c^2');
      expect(b[3].raw, r'\sum_i i');
      expect(hasMath(r'nessuna formula, solo $5 al mese'), isFalse);
      expect(hasMath(r'una $x$'), isTrue);
    });

    test(r'$$ senza chiusura non diventa una formula', () {
      final b = parseMarkdown('\$\$\nprezzo\n\nAltro');
      expect(b.every((x) => x.type != MdBlockType.math), isTrue);
    });

    test('nei blocchi di codice niente formule', () {
      final b = parseMarkdown('```\n\$x\$\n```');
      expect(b.single.type, MdBlockType.code);
      expect(b.single.raw, r'$x$');
    });
  });

  group('inserimento dall\'editor', () {
    test('in linea, a blocco e la forma che non si confonde con un prezzo', () {
      expect(
        formulaMarkdown((tex: 'x^2', block: false), before: 'a ', after: ''),
        r'$x^2$',
      );
      expect(
        formulaMarkdown((tex: '2 x', block: false), before: '', after: ''),
        r'\(2 x\)',
      );
      expect(
        formulaMarkdown(
          (tex: r'\frac12', block: true),
          before: 'Testo',
          after: 'x',
        ),
        '\n\$\$\n\\frac12\n\$\$\n',
      );
      final c = TextEditingController(text: 'Area: ')
        ..selection = const TextSelection.collapsed(offset: 6);
      insertFormula(c, (tex: r'\pi r^2', block: false));
      expect(c.text, r'Area: $\pi r^2$');
      expect(_math(c.text), [r'\pi r^2']);
    });
  });

  group('vista', () {
    testWidgets('formule disegnate; un errore mostra il testo originale', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MarkdownLiteView(
              r'Energia $E = mc^2$ e prezzo $5 al kg.'
              '\n\n'
              r'$$'
              '\n'
              r'\frac{a}{b}'
              '\n'
              r'$$'
              '\n\n'
              r'Rotta: $\frac{1}{$ fine.',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsWidgets);
      // il prezzo resta testo
      expect(
        find.textContaining(r'prezzo $5 al kg.', findRichText: true),
        findsOneWidget,
      );
      // formula con errore: testo originale, nessun crash
      expect(find.text(r'$\frac{1}{$'), findsOneWidget);
      // le formule non contano nella ricerca
      expect(MarkdownLiteView.countMatches(r'Una $x$ e una x', 'x'), 1);
    });

    testWidgets('testo semplice con formule (descrizioni, note)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MathText('Programma: limiti e \$\\lim_{x \\to 0}\$.'),
                MathText('Nessuna formula, costa \$5 al mese'),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsOneWidget);
      expect(find.text(r'Nessuna formula, costa $5 al mese'), findsOneWidget);
      expect(mayContainMath('niente'), isFalse);
    });
  });
}
