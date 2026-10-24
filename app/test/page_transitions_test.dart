import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/feedback/motion.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/widgets/glass.dart';

/// Pagina A con un pulsante che apre la pagina B (Scaffold trasparenti come
/// nell'app: il fondo sta sopra il Navigator). [fullscreen]: B è un modulo
/// «a schermo intero»; [blockPop]: B non si chiude con un gesto (modifiche
/// non salvate).
Widget _app({
  bool reduce = false,
  TargetPlatform? platform,
  bool fullscreen = false,
  bool blockPop = false,
}) {
  final theme = AppTheme.dark().copyWith(platform: platform);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        key: const Key('a'),
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                fullscreenDialog: fullscreen,
                builder: (_) => PopScope(
                  canPop: !blockPop,
                  child: const Scaffold(
                    key: Key('b'),
                    body: Center(child: Text('B')),
                  ),
                ),
              ),
            ),
            child: const Text('A'),
          ),
        ),
      ),
    ),
  );
}

Offset _pos(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(Key(key)));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('A'));
  await tester.pumpAndSettle();
  expect(_pos(tester, 'b'), Offset.zero);
}

/// Messaggio del gesto «Indietro» di Android (canale flutter/backgesture).
Future<void> _back(
  WidgetTester tester,
  String method, {
  double progress = 0,
  bool button = false,
}) async {
  final args = method == 'startBackGesture' ||
          method == 'updateBackGestureProgress'
      ? <String, Object?>{
          'touchOffset': button ? null : <double>[5, 300],
          'progress': progress,
          'swipeEdge': 0,
        }
      : null;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    SystemChannels.backGesture.codec.encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
  await tester.pump();
}

void main() {
  test('transizioni di iOS su tutte le piattaforme', () {
    for (final theme in [AppTheme.dark(), AppTheme.light()]) {
      for (final p in TargetPlatform.values) {
        expect(
          theme.pageTransitionsTheme.builders[p],
          isA<IosPageTransitionsBuilder>(),
          reason: '$p',
        );
      }
    }
  });

  test('molla di iOS: parte veloce, senza rimbalzo, chiude su 1', () {
    expect(kIosSpring.transform(0), 0);
    expect(kIosSpring.transform(1), 1);
    var last = 0.0;
    for (var i = 1; i < 100; i++) {
      final v = kIosSpring.transform(i / 100);
      expect(v, greaterThanOrEqualTo(last));
      expect(v, lessThanOrEqualTo(1));
      last = v;
    }
    // decelerazione: a un quarto del tempo ha già fatto più di metà strada
    expect(kIosSpring.transform(0.25), greaterThan(0.6));
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform: entra da destra con la parallasse, opaca', (
      tester,
    ) async {
      await tester.pumpWidget(_app(platform: platform));
      expect(find.byType(AppBackground), findsNothing);
      final width = tester.getSize(find.byKey(const Key('a'))).width;

      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // a metà strada: B arriva da destra, A scorre a sinistra (meno di B)
      final b = _pos(tester, 'b');
      final a = _pos(tester, 'a');
      expect(b.dx, inExclusiveRange(0, width));
      expect(b.dy, 0);
      expect(a.dx, lessThan(0));
      expect(a.dx, greaterThan(-width / 3 - 1));
      // B ha il suo fondo pieno, salvato come immagine: A non traspare
      expect(find.byType(AppBackground), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(AppBackground),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
      // ... e il fondo scorre con B
      expect(tester.getTopLeft(find.byType(AppBackground)), b);

      await tester.pumpAndSettle();
      expect(_pos(tester, 'b'), Offset.zero);
      // a regime nessun fondo in più (le card tornano sul fondo dell'app)
      expect(find.byType(AppBackground), findsNothing);

      // indietro: B esce a destra, sempre opaca
      Navigator.of(tester.element(find.text('B'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(_pos(tester, 'b').dx, inExclusiveRange(0, width));
      expect(find.byType(AppBackground), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing);
      expect(_pos(tester, 'a'), Offset.zero);
    });
  }

  testWidgets('modulo a schermo intero: sale dal basso, la pagina sotto '
      'resta ferma, opaco', (tester) async {
    await tester.pumpWidget(
      _app(platform: TargetPlatform.android, fullscreen: true),
    );
    final height = tester.getSize(find.byKey(const Key('a'))).height;
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final b = _pos(tester, 'b');
    expect(b.dx, 0);
    expect(b.dy, inExclusiveRange(0, height));
    expect(_pos(tester, 'a'), Offset.zero);
    expect(find.byType(AppBackground), findsOneWidget);
    // nessuna dissolvenza: il modulo non è mai semitrasparente
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.byKey(const Key('b')),
        matching: find.byType(FadeTransition),
      ),
    );
    for (final f in fades) {
      expect(f.opacity.value, 1);
    }
    await tester.pumpAndSettle();
    expect(_pos(tester, 'b'), Offset.zero);
    expect(find.byType(AppBackground), findsNothing);
  });

  testWidgets('«Riduci animazioni»: la pagina compare e scompare subito, '
      'opaca', (tester) async {
    await tester.pumpWidget(
      _app(reduce: true, platform: TargetPlatform.android),
    );
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_pos(tester, 'b'), Offset.zero);
    // finché la route è in movimento la pagina sotto non traspare
    expect(find.byType(AppBackground), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(AppBackground), findsNothing);

    final width = tester.getSize(find.byKey(const Key('b'))).width;
    Navigator.of(tester.element(find.text('B'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // B è già fuori e A al suo posto, senza scorrimento
    expect(_pos(tester, 'b').dx, greaterThanOrEqualTo(width));
    expect(_pos(tester, 'a'), Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing);
  });

  testWidgets('trascinando dal bordo sinistro la pagina segue il dito e si '
      'chiude', (tester) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.android));
    await _open(tester);
    final g = await tester.startGesture(const Offset(5, 300));
    await g.moveBy(const Offset(20, 0));
    await g.moveBy(const Offset(400, 0));
    await tester.pump();
    expect(_pos(tester, 'b').dx, closeTo(420, 30));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing);
  });

  group('Android: gesto «Indietro» predittivo', () {
    testWidgets('la pagina segue il gesto e si chiude', (tester) async {
      await tester.pumpWidget(_app(platform: TargetPlatform.android));
      await _open(tester);
      await _back(tester, 'startBackGesture');
      await _back(tester, 'updateBackGestureProgress', progress: 0.4);
      final width = tester.getSize(find.byKey(const Key('b'))).width;
      // movimento lineare, come il dito
      expect(_pos(tester, 'b').dx, closeTo(0.4 * width, 1));
      expect(_pos(tester, 'a').dx, lessThan(0));
      await _back(tester, 'commitBackGesture');
      // continua da dove era, senza tornare indietro
      expect(_pos(tester, 'b').dx, greaterThanOrEqualTo(0.4 * width - 1));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing);
      expect(_pos(tester, 'a'), Offset.zero);
    });

    testWidgets('annullato, la pagina torna al suo posto', (tester) async {
      await tester.pumpWidget(_app(platform: TargetPlatform.android));
      await _open(tester);
      await _back(tester, 'startBackGesture');
      await _back(tester, 'updateBackGestureProgress', progress: 0.3);
      expect(_pos(tester, 'b').dx, greaterThan(0));
      await _back(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(_pos(tester, 'b'), Offset.zero);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('modulo con modifiche non salvate: nessun gesto, Indietro '
        'passa al modulo', (tester) async {
      await tester.pumpWidget(
        _app(platform: TargetPlatform.android, blockPop: true),
      );
      await _open(tester);
      await _back(tester, 'startBackGesture');
      await _back(tester, 'updateBackGestureProgress', progress: 0.5);
      expect(_pos(tester, 'b'), Offset.zero);
      await _back(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
    });
  });

  testWidgets('PC: due dita verso destra sul touchpad chiudono la pagina', (
    tester,
  ) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.windows));
    await _open(tester);
    final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await g.panZoomStart(const Offset(400, 300));
    await g.panZoomUpdate(const Offset(400, 300), pan: const Offset(30, 0));
    await g.panZoomUpdate(const Offset(400, 300), pan: const Offset(500, 0));
    await tester.pump();
    expect(_pos(tester, 'b').dx, greaterThan(300));
    await g.panZoomEnd();
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing);
  });

  testWidgets('PC: due dita verso sinistra non fanno nulla', (tester) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.windows));
    await _open(tester);
    final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await g.panZoomStart(const Offset(400, 300));
    await g.panZoomUpdate(const Offset(400, 300), pan: const Offset(-300, 0));
    await tester.pump();
    expect(_pos(tester, 'b'), Offset.zero);
    await g.panZoomEnd();
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('PC: il tasto «Indietro» del mouse chiude la pagina', (
    tester,
  ) async {
    await tester.pumpWidget(_app(platform: TargetPlatform.windows));
    await _open(tester);
    final g = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await g.down(const Offset(400, 300));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing);
  });
}
