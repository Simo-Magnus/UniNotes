import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/feedback/app_modals.dart';
import 'package:university_notes/core/feedback/motion.dart';
import 'package:university_notes/core/theme/app_theme.dart';

/// Pagina con due pulsanti: una finestra e un foglio dal basso.
Widget _app({bool reduce = false}) => MaterialApp(
  theme: AppTheme.dark(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => showAppDialog<void>(
              context: context,
              builder: (c) => const AlertDialog(content: Text('finestra')),
            ),
            child: const Text('apri finestra'),
          ),
          TextButton(
            onPressed: () => showAppSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (c) => const SizedBox(
                height: 200,
                child: Center(child: Text('foglio')),
              ),
            ),
            child: const Text('apri foglio'),
          ),
        ],
      ),
    ),
  ),
);

double _scale(WidgetTester tester) => tester
    .widget<ScaleTransition>(
      find.ancestor(
        of: find.byType(AlertDialog),
        matching: find.byType(ScaleTransition),
      ),
    )
    .scale
    .value;

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(AlertDialog),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  testWidgets('finestra: entra con la molla di iOS (da 1,15 a 1), esce '
      'solo con la dissolvenza', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('apri finestra'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_scale(tester), inExclusiveRange(1, 1.15));
    expect(_opacity(tester), inExclusiveRange(0, 1));
    final route = ModalRoute.of(tester.element(find.text('finestra')))!;
    expect(route.transitionDuration, const Duration(milliseconds: 404));
    await tester.pumpAndSettle();
    expect(_scale(tester), 1);
    expect(_opacity(tester), 1);

    Navigator.of(tester.element(find.text('finestra'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_scale(tester), 1);
    expect(_opacity(tester), lessThan(1));
    // a metà del tempo la finestra è già sparita
    await tester.pump(const Duration(milliseconds: 150));
    expect(_opacity(tester), 0);
    await tester.pumpAndSettle();
    expect(find.text('finestra'), findsNothing);
  });

  testWidgets('foglio dal basso: molla di iOS', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('apri foglio'));
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.text('foglio')))!;
    expect(route.transitionDuration, kIosSheetAnimation.duration);
    expect(route.reverseTransitionDuration, kIosSheetAnimation.reverseDuration);
    await tester.pumpAndSettle();
    expect(find.text('foglio'), findsOneWidget);
  });

  testWidgets('«Riduci animazioni»: finestre e fogli compaiono subito', (
    tester,
  ) async {
    await tester.pumpWidget(_app(reduce: true));
    await tester.tap(find.text('apri finestra'));
    await tester.pump();
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byType(AlertDialog),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
    expect(_opacity(tester), 1);
    final dialog = ModalRoute.of(tester.element(find.text('finestra')))!;
    expect(dialog.transitionDuration, Duration.zero);
    Navigator.of(tester.element(find.text('finestra'))).pop();
    await tester.pump();
    await tester.pump();
    expect(find.text('finestra'), findsNothing);

    await tester.tap(find.text('apri foglio'));
    await tester.pump();
    final sheet = ModalRoute.of(tester.element(find.text('foglio')))!;
    expect(sheet.transitionDuration, Duration.zero);
    expect(sheet.reverseTransitionDuration, Duration.zero);
  });

  test('ExpansionTile con la molla nel tema', () {
    expect(
      AppTheme.dark().expansionTileTheme.expansionAnimationStyle,
      kIosExpansionAnimation,
    );
  });

  test('tutta l\'app usa le transizioni e le finestre comuni', () {
    // finestre e fogli: solo da app_modals.dart (curve di iOS e «Riduci
    // animazioni»); pagine: solo route del tema (niente transizioni proprie
    // con dissolvenze o pagine trasparenti)
    final banned = <String, RegExp>{
      'showDialog → usa showAppDialog (core/feedback/app_modals.dart)': RegExp(
        r'\bshowDialog\s*[<(]',
      ),
      'showModalBottomSheet → usa showAppSheet (core/feedback/app_modals.dart)':
          RegExp(r'\bshowModalBottomSheet\s*[<(]'),
      'showGeneralDialog → usa showAppDialog': RegExp(
        r'\bshowGeneralDialog\s*[<(]',
      ),
      'showAdaptiveDialog/showCupertino* → usa showAppDialog/showAppSheet':
          RegExp(r'\b(showAdaptiveDialog|showCupertinoDialog|showCupertinoModalPopup)\s*[<(]'),
      'PageRouteBuilder → usa MaterialPageRoute (transizione di iOS del tema)':
          RegExp(r'\bPageRouteBuilder\s*[<(]'),
      'route trasparente (opaque: false)': RegExp(r'\bopaque:\s*false'),
    };
    final problems = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll(r'\', '/');
      if (path.endsWith('core/feedback/app_modals.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        for (final e in banned.entries) {
          if (e.value.hasMatch(line)) problems.add('$path:${i + 1}: ${e.key}');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
