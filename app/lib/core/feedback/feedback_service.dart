import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import '../../repositories/settings_repository.dart';
import '../services/app_services.dart';
import 'feedback_prefs.dart';

export 'feedback_prefs.dart';

/// Riproduttore dei suoni brevi (nei test: finto o spento).
abstract class SoundPlayer {
  Future<void> play(AppSound sound);
  Future<void> dispose();
}

/// Nessun suono (test, piattaforme senza audio).
class SilentSoundPlayer implements SoundPlayer {
  const SilentSoundPlayer();
  @override
  Future<void> play(AppSound sound) async {}
  @override
  Future<void> dispose() async {}
}

/// Suoni con media_kit (già nell'app per il lettore): due lettori a turno,
/// così un suono che parte subito dopo un altro non lo interrompe. Se il
/// lettore non si apre (sistema senza audio) i suoni si spengono senza
/// errori.
class MediaKitSoundPlayer implements SoundPlayer {
  final List<Player> _players = [];
  var _next = 0;
  var _broken = false;

  @override
  Future<void> play(AppSound sound) async {
    if (_broken) return;
    try {
      if (_players.isEmpty) {
        MediaKit.ensureInitialized();
        for (var i = 0; i < 2; i++) {
          _players.add(Player());
        }
      }
      final p = _players[_next];
      _next = (_next + 1) % _players.length;
      await p.open(Media('asset:///${sound.asset}'), play: true);
    } catch (e) {
      _broken = true;
      debugPrint('Suoni non disponibili: $e');
    }
  }

  @override
  Future<void> dispose() async {
    for (final p in _players) {
      await p.dispose();
    }
    _players.clear();
  }
}

/// Vibrazione del sistema (nei test si registra).
typedef HapticRunner = Future<void> Function(HapticKind kind);

Future<void> _systemHaptic(HapticKind kind) => switch (kind) {
  HapticKind.selection => HapticFeedback.selectionClick(),
  HapticKind.light => HapticFeedback.lightImpact(),
  HapticKind.medium => HapticFeedback.mediumImpact(),
  HapticKind.heavy => HapticFeedback.heavyImpact(),
};

/// Servizio unico di suoni e vibrazioni: le schermate chiamano un evento
/// ([FeedbackEvent]) e il servizio decide suono e vibrazione secondo le
/// preferenze (Impostazioni → Suoni e vibrazioni).
class AppFeedback {
  AppFeedback({SoundPlayer? player, HapticRunner? haptic, bool? phone})
    : phone = phone ?? _isPhone,
      _player = player ?? (_inTest ? const SilentSoundPlayer() : null),
      _haptic = haptic ?? _systemHaptic {
    prefs = ValueNotifier(FeedbackPrefs.defaults(phone: this.phone));
  }

  static bool get _inTest => Platform.environment.containsKey('FLUTTER_TEST');
  static bool get _isPhone => Platform.isAndroid || Platform.isIOS;

  /// Il dispositivo ha la vibrazione (telefono): solo qui l'interruttore.
  final bool phone;
  SoundPlayer? _player;
  final HapticRunner _haptic;

  late final ValueNotifier<FeedbackPrefs> prefs;

  /// Servizio senza Provider (riquadri sopra il Navigator, test).
  static final AppFeedback silent = AppFeedback(
    player: const SilentSoundPlayer(),
    haptic: (_) async {},
    phone: false,
  );

  /// Il servizio dell'app (o uno silenzioso se manca AppServices).
  static AppFeedback of(BuildContext context) {
    try {
      return Provider.of<AppServices>(context, listen: false).feedback;
    } catch (_) {
      return silent;
    }
  }

  SoundPlayer get _sounds => _player ??= MediaKitSoundPlayer();

  Future<void> load(SettingsRepository s) async {
    prefs.value = FeedbackPrefs.parse(
      await s.get(FeedbackKeys.sounds),
      await s.get(FeedbackKeys.haptics),
      phone: phone,
    );
  }

  Future<void> setSounds(SettingsRepository s, bool on) async {
    prefs.value = prefs.value.copyWith(sounds: on);
    await s.set(FeedbackKeys.sounds, on ? '1' : '0');
    if (on) unawaited(play(FeedbackEvent.confirm));
  }

  Future<void> setHaptics(SettingsRepository s, bool on) async {
    prefs.value = prefs.value.copyWith(haptics: on);
    await s.set(FeedbackKeys.haptics, on ? '1' : '0');
    if (on) unawaited(play(FeedbackEvent.toggle));
  }

  /// Suono e vibrazione dell'evento [e] (mai errori verso chi chiama).
  Future<void> play(FeedbackEvent e) async {
    final f = feedbackFor(e);
    final p = prefs.value;
    if (p.haptics && f.haptic != null) {
      try {
        await _haptic(f.haptic!);
      } catch (_) {}
    }
    if (p.sounds && f.sound != null) {
      try {
        await _sounds.play(f.sound!);
      } catch (_) {}
    }
  }

  void tap() => unawaited(play(FeedbackEvent.tap));
  void toggle() => unawaited(play(FeedbackEvent.toggle));
  void confirm() => unawaited(play(FeedbackEvent.confirm));
  void warning() => unawaited(play(FeedbackEvent.warning));
  void complete() => unawaited(play(FeedbackEvent.complete));

  Future<void> dispose() async => _player?.dispose();
}
