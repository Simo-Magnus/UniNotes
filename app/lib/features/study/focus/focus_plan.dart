/// Sessione Focus (come le sessioni di concentrazione dell'Orologio di
/// Windows 11): durata scelta, pause automatiche, tempo restante. Logica
/// pura, senza orologio né interfaccia (test in test/focus_test.dart).
library;

/// Fase della sessione: concentrazione o pausa.
enum FocusPhase { focus, rest }

/// Un tratto della sessione.
class FocusSegment {
  const FocusSegment(this.phase, this.length);
  final FocusPhase phase;
  final Duration length;

  @override
  bool operator ==(Object other) =>
      other is FocusSegment && other.phase == phase && other.length == length;

  @override
  int get hashCode => Object.hash(phase, length);

  @override
  String toString() =>
      '${phase == FocusPhase.focus ? 'focus' : 'pausa'} ${length.inMinutes}m';
}

/// Impostazioni di una sessione (ricordate per la successiva).
class FocusSettings {
  const FocusSettings({
    this.minutes = 60,
    this.breaks = true,
    this.breakEvery = 30,
    this.breakMinutes = 5,
  });

  static const int minMinutes = 15;
  static const int maxMinutes = 240;
  static const List<int> breakEveryChoices = [20, 25, 30, 45, 60];
  static const List<int> breakLengthChoices = [3, 5, 10, 15];

  /// Durata totale della sessione, pause comprese (come in Windows).
  final int minutes;

  /// Pause automatiche attive.
  final bool breaks;

  /// Minuti di concentrazione tra una pausa e l'altra.
  final int breakEvery;

  /// Durata di ogni pausa.
  final int breakMinutes;

  FocusSettings copyWith({
    int? minutes,
    bool? breaks,
    int? breakEvery,
    int? breakMinutes,
  }) => FocusSettings(
    minutes: minutes ?? this.minutes,
    breaks: breaks ?? this.breaks,
    breakEvery: breakEvery ?? this.breakEvery,
    breakMinutes: breakMinutes ?? this.breakMinutes,
  );

  Map<String, Object?> toJson() => {
    'minuti': minutes,
    'pause': breaks,
    'ogni': breakEvery,
    'pausa': breakMinutes,
  };

  /// Valori salvati; quelli mancanti o fuori misura tornano ai predefiniti.
  static FocusSettings fromJson(Object? j) {
    if (j is! Map) return const FocusSettings();
    int pick(Object? v, int def, int lo, int hi) =>
        v is int && v >= lo && v <= hi ? v : def;
    return FocusSettings(
      minutes: pick(j['minuti'], 60, minMinutes, maxMinutes),
      breaks: j['pause'] is bool ? j['pause'] as bool : true,
      breakEvery: pick(j['ogni'], 30, 10, 120),
      breakMinutes: pick(j['pausa'], 5, 1, 30),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FocusSettings &&
      other.minutes == minutes &&
      other.breaks == breaks &&
      other.breakEvery == breakEvery &&
      other.breakMinutes == breakMinutes;

  @override
  int get hashCode => Object.hash(minutes, breaks, breakEvery, breakMinutes);
}

/// Ultimo tratto di concentrazione minimo: una pausa non si mette se dopo
/// resterebbero meno di 5 minuti di lavoro.
const int kMinLastFocusMinutes = 5;

/// Tratti della sessione: concentrazione di [FocusSettings.breakEvery]
/// minuti, pausa, concentrazione… fino alla durata totale. L'ultimo tratto
/// è sempre di concentrazione. Esempi: 60 min con pause di 5 ogni 30 →
/// 30 + 5 + 25; 45 min → 30 + 5 + 10; 30 min → 30.
List<FocusSegment> buildFocusPlan(FocusSettings s) {
  final total = s.minutes.clamp(1, FocusSettings.maxMinutes);
  final every = s.breakEvery;
  final rest = s.breakMinutes;
  if (!s.breaks || every <= 0 || rest <= 0) {
    return [FocusSegment(FocusPhase.focus, Duration(minutes: total))];
  }
  final out = <FocusSegment>[];
  var used = 0;
  while (true) {
    final left = total - used;
    if (left < every + rest + kMinLastFocusMinutes) {
      out.add(FocusSegment(FocusPhase.focus, Duration(minutes: left)));
      break;
    }
    out
      ..add(FocusSegment(FocusPhase.focus, Duration(minutes: every)))
      ..add(FocusSegment(FocusPhase.rest, Duration(minutes: rest)));
    used += every + rest;
  }
  return out;
}

/// Durata totale dei tratti.
Duration planLength(List<FocusSegment> plan) =>
    plan.fold(Duration.zero, (a, s) => a + s.length);

/// Minuti di concentrazione (pause escluse) del piano.
int planFocusMinutes(List<FocusSegment> plan) => plan
    .where((s) => s.phase == FocusPhase.focus)
    .fold(0, (a, s) => a + s.length.inMinutes);

/// Numero di pause del piano.
int planBreaks(List<FocusSegment> plan) =>
    plan.where((s) => s.phase == FocusPhase.rest).length;

/// Dove si trova la sessione dopo [t] di tempo trascorso (pause manuali
/// escluse, pause saltate incluse).
class FocusPosition {
  const FocusPosition({
    required this.index,
    required this.phase,
    required this.segmentLength,
    required this.segmentRemaining,
    required this.totalRemaining,
    required this.focusDone,
    required this.breaksLeft,
  });

  /// Indice del tratto in corso (= numero di tratti a sessione finita).
  final int index;
  final FocusPhase phase;
  final Duration segmentLength;
  final Duration segmentRemaining;

  /// Fino alla fine della sessione.
  final Duration totalRemaining;

  /// Concentrazione già fatta (pause escluse).
  final Duration focusDone;

  /// Pause ancora da fare (esclusa quella in corso).
  final int breaksLeft;

  bool get finished => totalRemaining <= Duration.zero;

  /// Avanzamento del tratto in corso (0–1).
  double get segmentProgress => segmentLength.inMilliseconds <= 0
      ? 1
      : 1 - segmentRemaining.inMilliseconds / segmentLength.inMilliseconds;
}

FocusPosition positionAt(List<FocusSegment> plan, Duration t) {
  final elapsed = t < Duration.zero ? Duration.zero : t;
  var start = Duration.zero;
  var focus = Duration.zero;
  for (var i = 0; i < plan.length; i++) {
    final s = plan[i];
    final end = start + s.length;
    if (elapsed < end) {
      final inside = elapsed - start;
      if (s.phase == FocusPhase.focus) focus += inside;
      return FocusPosition(
        index: i,
        phase: s.phase,
        segmentLength: s.length,
        segmentRemaining: end - elapsed,
        totalRemaining: planLength(plan) - elapsed,
        focusDone: focus,
        breaksLeft: plan
            .skip(i + 1)
            .where((x) => x.phase == FocusPhase.rest)
            .length,
      );
    }
    if (s.phase == FocusPhase.focus) focus += s.length;
    start = end;
  }
  return FocusPosition(
    index: plan.length,
    phase: FocusPhase.focus,
    segmentLength: Duration.zero,
    segmentRemaining: Duration.zero,
    totalRemaining: Duration.zero,
    focusDone: focus,
    breaksLeft: 0,
  );
}

/// Istante di fine di ogni tratto da [t] in poi (per pianificare gli avvisi
/// di fine pausa e fine sessione): (indice del tratto, tempo dall'inizio).
List<(int, Duration)> boundariesAfter(List<FocusSegment> plan, Duration t) {
  final out = <(int, Duration)>[];
  var end = Duration.zero;
  for (var i = 0; i < plan.length; i++) {
    end += plan[i].length;
    if (end > t) out.add((i, end));
  }
  return out;
}

/// "25:00", "1:05:09": tempo restante del timer grande.
String formatCountdown(Duration d) {
  final s = d.inSeconds < 0 ? 0 : (d.inMilliseconds / 1000).ceil();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// "1 h 30 min", "45 min" per la durata scelta.
String formatFocusLength(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// Riepilogo del piano: "2 pause da 5 min", "Nessuna pausa".
String describePlan(List<FocusSegment> plan) {
  final n = planBreaks(plan);
  if (n == 0) return 'Nessuna pausa';
  final len = plan.firstWhere((s) => s.phase == FocusPhase.rest).length;
  return '${n == 1 ? '1 pausa' : '$n pause'} da ${len.inMinutes} min';
}
