/// Suoni, vibrazioni e microinterazioni: preferenze ed eventi (logica pura,
/// test in test/feedback_display_test.dart).
library;

/// Chiavi delle impostazioni (Impostazioni → Suoni e vibrazioni).
class FeedbackKeys {
  /// '1' suoni discreti attivi (predefinito), '0' spenti.
  static const sounds = 'feedback_sounds';

  /// '1' vibrazioni attive (predefinito sul telefono), '0' spente.
  static const haptics = 'feedback_haptics';
}

/// Suoni dell'app (assets/suoni/, generati da tool/genera_suoni.py).
enum AppSound {
  tap('tocco'),
  confirm('conferma'),
  warning('avviso'),
  focusStart('focus_inizio'),
  focusEnd('focus_fine'),
  breakStart('pausa_inizio'),
  breakEnd('pausa_fine'),
  recordStart('registrazione_inizio'),
  recordStop('registrazione_fine');

  const AppSound(this.file);
  final String file;

  /// Percorso dell'asset.
  String get asset => 'assets/suoni/$file.wav';
}

/// Intensità della vibrazione (HapticFeedback del sistema).
enum HapticKind { selection, light, medium, heavy }

/// Momenti dell'app con un riscontro.
enum FeedbackEvent {
  /// Pulsante principale premuto.
  tap,

  /// Interruttore, scelta o casella.
  toggle,

  /// Salvataggio riuscito.
  confirm,

  /// Errore o azione da controllare.
  warning,

  /// Traguardo: esame superato, argomento completato, obiettivo raggiunto.
  complete,
  focusStart,
  focusEnd,
  breakStart,
  breakEnd,
  recordStart,
  recordStop,
}

/// Suono e vibrazione di un evento. Il tocco dei pulsanti e gli
/// interruttori vibrano soltanto: un suono a ogni tocco sarebbe invadente.
({AppSound? sound, HapticKind? haptic}) feedbackFor(
  FeedbackEvent e,
) => switch (e) {
  FeedbackEvent.tap => (sound: null, haptic: HapticKind.light),
  FeedbackEvent.toggle => (sound: null, haptic: HapticKind.selection),
  FeedbackEvent.confirm => (sound: AppSound.confirm, haptic: HapticKind.light),
  FeedbackEvent.warning => (sound: AppSound.warning, haptic: HapticKind.medium),
  FeedbackEvent.complete => (
    sound: AppSound.confirm,
    haptic: HapticKind.medium,
  ),
  FeedbackEvent.focusStart => (
    sound: AppSound.focusStart,
    haptic: HapticKind.medium,
  ),
  FeedbackEvent.focusEnd => (
    sound: AppSound.focusEnd,
    haptic: HapticKind.heavy,
  ),
  FeedbackEvent.breakStart => (
    sound: AppSound.breakStart,
    haptic: HapticKind.light,
  ),
  FeedbackEvent.breakEnd => (
    sound: AppSound.breakEnd,
    haptic: HapticKind.light,
  ),
  FeedbackEvent.recordStart => (
    sound: AppSound.recordStart,
    haptic: HapticKind.medium,
  ),
  FeedbackEvent.recordStop => (
    sound: AppSound.recordStop,
    haptic: HapticKind.medium,
  ),
};

/// Preferenze lette dalle impostazioni.
class FeedbackPrefs {
  const FeedbackPrefs({required this.sounds, required this.haptics});

  final bool sounds;
  final bool haptics;

  /// Predefiniti: suoni discreti attivi; vibrazioni attive dove il sistema
  /// le ha (telefono), spente altrove.
  factory FeedbackPrefs.defaults({required bool phone}) =>
      FeedbackPrefs(sounds: true, haptics: phone);

  /// Valori salvati ('1' / '0'); mancanti o non validi → predefiniti.
  factory FeedbackPrefs.parse(
    String? sounds,
    String? haptics, {
    required bool phone,
  }) {
    bool flag(String? v, bool def) => switch (v) {
      '1' => true,
      '0' => false,
      _ => def,
    };
    return FeedbackPrefs(
      sounds: flag(sounds, true),
      // senza vibrazione nel dispositivo l'interruttore non c'è
      haptics: phone && flag(haptics, true),
    );
  }

  FeedbackPrefs copyWith({bool? sounds, bool? haptics}) => FeedbackPrefs(
    sounds: sounds ?? this.sounds,
    haptics: haptics ?? this.haptics,
  );

  @override
  bool operator ==(Object other) =>
      other is FeedbackPrefs &&
      other.sounds == sounds &&
      other.haptics == haptics;

  @override
  int get hashCode => Object.hash(sounds, haptics);
}
