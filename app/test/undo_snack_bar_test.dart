// Avvisi in basso con «Annulla» (lib/widgets/undo_snack_bar.dart): il
// pulsante annulla l'azione, l'avviso si chiude da solo e la parte non
// recuperabile ([onCommit]) si esegue solo se non si annulla.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/widgets/undo_snack_bar.dart';

void main() {
  Future<BuildContext> pump(WidgetTester t) async {
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  testWidgets('«Annulla» ripristina e conferma; niente commit', (t) async {
    final ctx = await pump(t);
    var undone = 0, committed = 0;
    showUndoSnackBar(
      ctx,
      'Libro rimosso.',
      undoneMessage: 'Libro ripristinato.',
      onUndo: () => undone++,
      onCommit: () => committed++,
    );
    await t.pumpAndSettle();
    expect(find.text('Libro rimosso.'), findsOneWidget);
    await t.tap(find.widgetWithText(SnackBarAction, 'Annulla'));
    await t.pumpAndSettle();
    expect(undone, 1);
    expect(find.text('Libro ripristinato.'), findsOneWidget);
    // il secondo avviso si chiude da solo
    await t.pump(const Duration(seconds: 10));
    await t.pumpAndSettle();
    expect(find.text('Libro ripristinato.'), findsNothing);
    expect(committed, 0);
  });

  testWidgets('senza «Annulla»: si chiude da solo e completa l\'azione', (
    t,
  ) async {
    final ctx = await pump(t);
    var undone = 0, committed = 0;
    showUndoSnackBar(
      ctx,
      'Allegato rimosso.',
      onUndo: () => undone++,
      onCommit: () => committed++,
    );
    await t.pumpAndSettle();
    expect(find.text('Allegato rimosso.'), findsOneWidget);
    await t.pump(kUndoSnackDuration + const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.text('Allegato rimosso.'), findsNothing);
    expect(undone, 0);
    expect(committed, 1);
  });

  testWidgets('un nuovo avviso chiude il precedente e lo completa', (t) async {
    final ctx = await pump(t);
    var committed = 0;
    showUndoSnackBar(ctx, 'Primo.', onUndo: () {}, onCommit: () => committed++);
    await t.pumpAndSettle();
    showUndoSnackBar(ctx, 'Secondo.', onUndo: () {});
    await t.pumpAndSettle();
    expect(committed, 1);
    expect(find.text('Secondo.'), findsOneWidget);
  });

  testWidgets('annullamento non riuscito: messaggio', (t) async {
    final ctx = await pump(t);
    showUndoSnackBar(
      ctx,
      'Eliminato.',
      onUndo: () => throw StateError('disco pieno'),
    );
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(SnackBarAction, 'Annulla'));
    await t.pumpAndSettle();
    expect(find.textContaining('Annullamento non riuscito'), findsOneWidget);
  });
}
