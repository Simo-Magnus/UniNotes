import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/widgets/glass.dart';

/// Pagina 1 con un pulsante che apre la pagina 2 (Scaffold trasparente come
/// nell'app: il fondo sta sopra il Navigator).
Widget _app({bool reduce = false, TargetPlatform? platform}) {
  final theme = AppTheme.dark().copyWith(platform: platform);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => const Scaffold(body: Center(child: Text('B'))),
              ),
            ),
            child: const Text('A'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('cambio pagina: fondo opaco solo durante la transizione', (
    tester,
  ) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.android));
    expect(find.byType(AppBackground), findsNothing);

    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // transizione in corso: la pagina nuova ha il suo fondo pieno, salvato
    // come immagine
    expect(find.byType(AppBackground), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(AppBackground),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );

    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    // a regime nessun fondo in più (le card tornano sul fondo dell'app)
    expect(find.byType(AppBackground), findsNothing);
  });

  testWidgets('tornando indietro il fondo pieno c\'è finché la pagina esce', (
    tester,
  ) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.android));
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBackground), findsNothing);

    Navigator.of(tester.element(find.text('B'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AppBackground), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(AppBackground), findsNothing);
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('«Riduci animazioni»: la pagina compare subito, senza fondo', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(reduce: true, platform: TargetPlatform.android),
    );
    await tester.tap(find.text('A'));
    await tester.pump();
    expect(find.byType(AppBackground), findsNothing);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('B'), findsOneWidget);
    expect(find.byType(AppBackground), findsNothing);
  });

  testWidgets('iOS: il fondo pieno scorre con la pagina', (tester) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.iOS));
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AppBackground), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(AppBackground), findsNothing);
  });
}
