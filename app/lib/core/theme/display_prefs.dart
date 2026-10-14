import 'package:flutter/painting.dart';

/// Personalizzazione dell'aspetto (Impostazioni → Aspetto): contrasto,
/// grandezza dei caratteri e «Riduci animazioni». Logica pura (test in
/// test/feedback_display_test.dart).

/// Chiavi delle impostazioni.
class DisplayKeys {
  /// 'standard' (predefinito) | 'alto'.
  static const contrast = 'display_contrast';

  /// Indice in [kTextSizeSteps] (predefinito 1 = Standard).
  static const textSize = 'display_text_size';

  /// '1': animazioni ridotte anche se il sistema non lo chiede.
  static const reduceMotion = 'display_reduce_motion';
}

enum ContrastMode {
  standard('standard', 'Standard'),
  high('alto', 'Alto contrasto');

  const ContrastMode(this.key, this.label);
  final String key;
  final String label;

  static ContrastMode fromKey(String? k) =>
      k == high.key ? ContrastMode.high : ContrastMode.standard;
}

/// Cinque grandezze dei caratteri, moltiplicate per quella del sistema.
const List<double> kTextSizeSteps = [0.9, 1.0, 1.15, 1.3, 1.5];
const List<String> kTextSizeLabels = [
  'Piccolo',
  'Standard',
  'Grande',
  'Più grande',
  'Massimo',
];
const int kDefaultTextStep = 1;

/// Limiti della scala finale (sistema × app): oltre il doppio le schermate
/// del telefono non hanno più spazio per il contenuto.
const double kMinTextScale = 0.85;
const double kMaxTextScale = 2.0;

/// Indice salvato → passo valido.
int parseTextStep(String? v) {
  final n = int.tryParse(v ?? '');
  if (n == null || n < 0 || n >= kTextSizeSteps.length) return kDefaultTextStep;
  return n;
}

/// Scala finale per un testo da 14 px: [system] (impostazione del sistema)
/// per il passo scelto nell'app, entro [kMinTextScale]–[kMaxTextScale].
double effectiveTextScale(double system, int step) {
  final f = kTextSizeSteps[step.clamp(0, kTextSizeSteps.length - 1)];
  return (system * f).clamp(kMinTextScale, kMaxTextScale).toDouble();
}

/// Scala dei caratteri dell'app: quella del sistema (anche non lineare,
/// Android 14+) moltiplicata per il passo scelto, entro i limiti.
class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, this.factor);

  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) {
    if (fontSize <= 0) return fontSize;
    final s = system.scale(fontSize) * factor;
    return s.clamp(fontSize * kMinTextScale, fontSize * kMaxTextScale);
  }

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is AppTextScaler &&
      other.system == system &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}

/// Preferenze dell'aspetto lette dalle impostazioni.
class DisplayPrefs {
  const DisplayPrefs({
    this.contrast = ContrastMode.standard,
    this.textStep = kDefaultTextStep,
    this.reduceMotion = false,
  });

  final ContrastMode contrast;
  final int textStep;
  final bool reduceMotion;

  bool get highContrast => contrast == ContrastMode.high;
  double get textFactor => kTextSizeSteps[textStep];

  factory DisplayPrefs.parse({
    String? contrast,
    String? textSize,
    String? reduceMotion,
  }) => DisplayPrefs(
    contrast: ContrastMode.fromKey(contrast),
    textStep: parseTextStep(textSize),
    reduceMotion: reduceMotion == '1',
  );

  DisplayPrefs copyWith({
    ContrastMode? contrast,
    int? textStep,
    bool? reduceMotion,
  }) => DisplayPrefs(
    contrast: contrast ?? this.contrast,
    textStep: textStep ?? this.textStep,
    reduceMotion: reduceMotion ?? this.reduceMotion,
  );

  @override
  bool operator ==(Object other) =>
      other is DisplayPrefs &&
      other.contrast == contrast &&
      other.textStep == textStep &&
      other.reduceMotion == reduceMotion;

  @override
  int get hashCode => Object.hash(contrast, textStep, reduceMotion);
}
