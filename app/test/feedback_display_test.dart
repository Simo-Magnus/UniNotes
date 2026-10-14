import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/feedback/feedback_service.dart';
import 'package:university_notes/core/feedback/motion.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/app_tokens.dart';
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/repositories/settings_repository.dart';

class _FakePlayer implements SoundPlayer {
  final List<AppSound> played = [];
  @override
  Future<void> play(AppSound sound) async => played.add(sound);
  @override
  Future<void> dispose() async {}
}

void main() {
  group('preferenze di suoni e vibrazioni', () {
    test('predefiniti: suoni discreti; vibrazioni solo sul telefono', () {
      expect(FeedbackPrefs.defaults(phone: true).haptics, isTrue);
      expect(FeedbackPrefs.defaults(phone: false).haptics, isFalse);
      expect(FeedbackPrefs.defaults(phone: false).sounds, isTrue);
      expect(
        FeedbackPrefs.parse(null, null, phone: true),
        const FeedbackPrefs(sounds: true, haptics: true),
      );
      expect(
        FeedbackPrefs.parse('0', '0', phone: true),
        const FeedbackPrefs(sounds: false, haptics: false),
      );
      // sul PC la vibrazione resta spenta anche se salvata
      expect(FeedbackPrefs.parse('1', '1', phone: false).haptics, isFalse);
      expect(FeedbackPrefs.parse('x', null, phone: false).sounds, isTrue);
    });

    test('suono e vibrazione per evento', () {
      // il tocco dei pulsanti vibra soltanto
      expect(feedbackFor(FeedbackEvent.tap).sound, isNull);
      expect(feedbackFor(FeedbackEvent.toggle).haptic, HapticKind.selection);
      expect(feedbackFor(FeedbackEvent.focusEnd).sound, AppSound.focusEnd);
      expect(
        feedbackFor(FeedbackEvent.recordStart).sound,
        AppSound.recordStart,
      );
      expect(AppSound.breakStart.asset, 'assets/suoni/pausa_inizio.wav');
      for (final e in FeedbackEvent.values) {
        final f = feedbackFor(e);
        expect(f.sound != null || f.haptic != null, isTrue, reason: '$e');
      }
    });

    test('il servizio rispetta gli interruttori', () async {
      final player = _FakePlayer();
      final haptics = <HapticKind>[];
      final fb = AppFeedback(
        player: player,
        haptic: (k) async => haptics.add(k),
        phone: true,
      );
      await fb.play(FeedbackEvent.complete);
      expect(player.played, [AppSound.confirm]);
      expect(haptics, [HapticKind.medium]);

      fb.prefs.value = const FeedbackPrefs(sounds: false, haptics: true);
      await fb.play(FeedbackEvent.focusStart);
      expect(player.played, hasLength(1));
      expect(haptics, hasLength(2));

      fb.prefs.value = const FeedbackPrefs(sounds: true, haptics: false);
      await fb.play(FeedbackEvent.warning);
      expect(player.played.last, AppSound.warning);
      expect(haptics, hasLength(2));
    });

    test('un suono che non parte non blocca nulla', () async {
      final fb = AppFeedback(
        player: _BrokenPlayer(),
        haptic: (_) => throw StateError('nessuna vibrazione'),
        phone: true,
      );
      await fb.play(FeedbackEvent.confirm);
    });

    test('preferenze salvate e rilette', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      final fb = AppFeedback(
        player: _FakePlayer(),
        haptic: (_) async {},
        phone: true,
      );
      await fb.setSounds(settings, false);
      await fb.setHaptics(settings, false);
      final again = AppFeedback(
        player: _FakePlayer(),
        haptic: (_) async {},
        phone: true,
      );
      await again.load(settings);
      expect(
        again.prefs.value,
        const FeedbackPrefs(sounds: false, haptics: false),
      );
    });
  });

  group('grandezza dei caratteri e contrasto', () {
    test('passi e scala finale', () {
      expect(parseTextStep(null), kDefaultTextStep);
      expect(parseTextStep('4'), 4);
      expect(parseTextStep('9'), kDefaultTextStep);
      expect(parseTextStep('-1'), kDefaultTextStep);
      expect(effectiveTextScale(1, 1), 1);
      expect(effectiveTextScale(1, 4), 1.5);
      // sistema già grande × «Massimo»: si ferma al doppio
      expect(effectiveTextScale(1.6, 4), kMaxTextScale);
      expect(effectiveTextScale(0.8, 0), kMinTextScale);
      expect(kTextSizeLabels, hasLength(kTextSizeSteps.length));
    });

    test('scala dell\'app: sistema × passo, entro i limiti', () {
      const a = AppTextScaler(TextScaler.noScaling, 1.3);
      expect(a.scale(10), closeTo(13, 0.001));
      const b = AppTextScaler(TextScaler.linear(1.8), 1.5);
      expect(b.scale(10), 20);
      const c = AppTextScaler(TextScaler.linear(0.5), 1);
      expect(c.scale(10), closeTo(8.5, 0.001));
      expect(a, const AppTextScaler(TextScaler.noScaling, 1.3));
      expect(a.clamp(maxScaleFactor: 1.1).scale(10), closeTo(11, 0.001));
    });

    test('preferenze dell\'aspetto', () {
      final p = DisplayPrefs.parse(
        contrast: 'alto',
        textSize: '3',
        reduceMotion: '1',
      );
      expect(p.highContrast, isTrue);
      expect(p.textFactor, kTextSizeSteps[3]);
      expect(p.reduceMotion, isTrue);
      expect(DisplayPrefs.parse(), const DisplayPrefs());
      expect(ContrastMode.fromKey('boh'), ContrastMode.standard);
    });

    test('alto contrasto: testi e bordi più leggibili', () {
      // fondi di riferimento delle card nei due temi
      const darkCard = Color(0xFF111D31);
      const lightCard = Color(0xFFFFFFFF);
      for (final (b, base, card) in [
        (Brightness.dark, AppTokens.dark, darkCard),
        (Brightness.light, AppTokens.light, lightCard),
      ]) {
        final hc = base.highContrast(b);
        expect(contrastRatio(hc.textPrimary, card), greaterThanOrEqualTo(15));
        expect(contrastRatio(hc.textSecondary, card), greaterThanOrEqualTo(10));
        expect(contrastRatio(hc.textMuted, card), greaterThanOrEqualTo(7));
        expect(
          contrastRatio(hc.textMuted, card),
          greaterThan(contrastRatio(base.textMuted, card)),
        );
        // bordi più marcati, card meno trasparenti
        expect(hc.cardBorder.a, greaterThan(base.cardBorder.a));
        expect(hc.cardGradient.first.a, greaterThanOrEqualTo(0.9));
        // l'arancione dell'azione resta quello di Design 3
        expect(hc.orangeGradient, base.orangeGradient);
      }
      final theme = AppTheme.dark(highContrast: true);
      expect(
        theme.extension<AppTokens>()!.textMuted,
        isNot(AppTokens.dark.textMuted),
      );
    });
  });

  group('microinterazioni', () {
    testWidgets('«Riduci animazioni» toglie le durate', (tester) async {
      late Duration d;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              d = motion(context, const Duration(milliseconds: 300));
              return const SizedBox();
            },
          ),
        ),
      );
      expect(d, Duration.zero);
    });

    testWidgets('contatore animato e pulsante che si abbassa', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const AnimatedCount(value: 40, format: _min),
                Pressable(
                  child: FilledButton(
                    onPressed: () => taps++,
                    child: const Text('Avvia'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('40 min'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Avvia')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.scale, lessThan(1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    });
  });
}

String _min(int v) => '$v min';

class _BrokenPlayer implements SoundPlayer {
  @override
  Future<void> play(AppSound sound) => throw StateError('niente audio');
  @override
  Future<void> dispose() async {}
}
