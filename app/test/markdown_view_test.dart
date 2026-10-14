import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/markdown_view.dart';

void main() {
  searchTests();
  testWidgets('vista Markdown: titoli, evidenziato, elenchi', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownLiteView(
            '# Limiti\n\nIl **teorema** di ==Rolle==.\n\n- uno\n1. due',
          ),
        ),
      ),
    );
    expect(find.text('Limiti', findRichText: true), findsOneWidget);
    expect(find.textContaining('Rolle', findRichText: true), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
  });

  testWidgets('PDF con caratteri accentati e simboli', (t) async {
    final bytes = (await t.runAsync(
      () => markdownToPdf(
        '# Riassunto\n\n**Perché** è ==importante==: x ≥ 0 → ∫ f(x) dx.\n\n- città\n',
        title: 'Lezione 1',
        subtitle: 'Analisi I',
      ),
    ))!;
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(5000));
  });
}

void searchTests() {
  test('ricerca: occorrenze senza maiuscole, in tutti i blocchi', () {
    expect(findOccurrences('Limite e LIMITE', 'limite'), [0, 9]);
    expect(
      MarkdownLiteView.countMatches(
        '# Limiti\n\nIl **limite** notevole.\n\n- limite destro\n',
        'limit',
      ),
      3,
    );
    expect(MarkdownLiteView.countMatches('abc', ''), 0);
  });

  testWidgets('Ctrl+F apre la ricerca, Invio passa al risultato successivo', (
    t,
  ) async {
    final text = [
      for (var i = 0; i < 60; i++) 'Paragrafo $i.\n',
      'Qui c\'è la parola chiave.\n',
      'E di nuovo chiave.\n',
    ].join('\n');
    await t.pumpWidget(
      MaterialApp(home: Scaffold(body: SearchableMarkdownView(text))),
    );
    await t.pump();
    expect(find.byType(TextField), findsNothing);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await t.enterText(find.byType(TextField), 'chiave');
    await t.pumpAndSettle();
    expect(find.text('1 di 2'), findsOneWidget);
    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pumpAndSettle();
    expect(find.text('2 di 2'), findsOneWidget);
    await t.tap(find.byTooltip('Successivo (Invio)'));
    await t.pumpAndSettle();
    expect(find.text('1 di 2'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });
}
