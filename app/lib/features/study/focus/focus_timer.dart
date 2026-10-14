import 'dart:async';

import 'package:flutter/foundation.dart';

import 'focus_plan.dart';

/// Cosa succede nella sessione (per suoni, notifiche e salvataggio).
enum FocusEventKind {
  started,
  paused,
  resumed,
  breakStarted,
  breakEnded,
  breakSkipped,
  finished,
  stopped,
}

/// Esito di una sessione fermata o finita.
class FocusResult {
  const FocusResult({
    required this.start,
    required this.end,
    required this.focusMinutes,
    required this.plannedMinutes,
    required this.completed,
  });

  final DateTime start;
  final DateTime end;

  /// Minuti di concentrazione (pause escluse), arrotondati.
  final int focusMinutes;

  /// Durata scelta, pause comprese.
  final int plannedMinutes;

  /// La sessione è arrivata alla fine (non fermata prima).
  final bool completed;
}

/// Timer della sessione Focus: tempo a orologio, non a battiti (se l'app
/// resta ferma in background, al ritorno il tempo è giusto). Le pause
/// manuali fermano il tempo; «Salta pausa» lo porta avanti alla fine della
/// pausa. Lo stato si salva in JSON per riprendere la sessione dopo una
/// chiusura dell'app.
class FocusTimer extends ChangeNotifier {
  FocusTimer({DateTime Function()? clock, bool tick = true})
    : _clock = clock ?? DateTime.now,
      _tickEnabled = tick;

  final DateTime Function() _clock;
  final bool _tickEnabled;
  Timer? _ticker;

  FocusSettings? _settings;
  List<FocusSegment>? _plan;
  DateTime? _startedAt;
  DateTime? _runningSince;
  Duration _accumulated = Duration.zero;
  Duration _skipped = Duration.zero;
  int _lastIndex = -1;
  bool _finishedSent = false;

  final _events = StreamController<FocusEventKind>.broadcast();

  /// Eventi della sessione (arrivano subito dopo il cambio, in ordine).
  Stream<FocusEventKind> get events => _events.stream;

  FocusSettings? get settings => _settings;
  List<FocusSegment> get plan => _plan ?? const [];
  DateTime? get startedAt => _startedAt;

  /// C'è una sessione (anche in pausa o appena finita).
  bool get active => _plan != null;
  bool get running => _runningSince != null;
  bool get paused => active && !running && !finished;

  DateTime get now => _clock();

  /// Tempo trascorso senza le pause manuali.
  Duration get activeElapsed {
    final since = _runningSince;
    return since == null ? _accumulated : _accumulated + now.difference(since);
  }

  /// Tempo nel piano: trascorso più le pause saltate.
  Duration get planElapsed => activeElapsed + _skipped;

  FocusPosition get position => positionAt(plan, planElapsed);
  bool get finished => active && position.finished;

  /// Fine prevista (null in pausa o senza sessione).
  DateTime? get endsAt => running ? now.add(position.totalRemaining) : null;

  void start(FocusSettings s) {
    _stopTicker();
    _settings = s;
    _plan = buildFocusPlan(s);
    final t = now;
    _startedAt = t;
    _runningSince = t;
    _accumulated = Duration.zero;
    _skipped = Duration.zero;
    _lastIndex = 0;
    _finishedSent = false;
    _startTicker();
    _emit(FocusEventKind.started);
    notifyListeners();
  }

  void pause() {
    final since = _runningSince;
    if (since == null || finished) return;
    _accumulated += now.difference(since);
    _runningSince = null;
    _stopTicker();
    _emit(FocusEventKind.paused);
    notifyListeners();
  }

  void resume() {
    if (!active || running || finished) return;
    _runningSince = now;
    _startTicker();
    _emit(FocusEventKind.resumed);
    notifyListeners();
  }

  void togglePause() => running ? pause() : resume();

  /// Salta la pausa in corso: si riparte subito con la concentrazione.
  bool skipBreak() {
    if (!active) return false;
    final p = position;
    if (p.finished || p.phase != FocusPhase.rest) return false;
    _skipped += p.segmentRemaining;
    _lastIndex = p.index + 1;
    _emit(FocusEventKind.breakSkipped);
    notifyListeners();
    return true;
  }

  /// Controlla i cambi di tratto (chiamato ogni secondo e al ritorno
  /// nell'app): inizio e fine delle pause, fine della sessione.
  void check() {
    if (!active) return;
    final p = position;
    if (p.finished) {
      if (!_finishedSent) {
        _finishedSent = true;
        _lastIndex = p.index;
        _stopTicker();
        _emit(FocusEventKind.finished);
      }
      notifyListeners();
      return;
    }
    if (p.index != _lastIndex) {
      final from = _lastIndex;
      _lastIndex = p.index;
      // più tratti passati insieme (app ferma): conta dove si è arrivati
      if (from >= 0 && from < plan.length) {
        _emit(
          p.phase == FocusPhase.rest
              ? FocusEventKind.breakStarted
              : FocusEventKind.breakEnded,
        );
      }
    }
    notifyListeners();
  }

  /// Ferma la sessione (finita o interrotta) e restituisce l'esito.
  FocusResult? stop() {
    final start = _startedAt;
    final plan = _plan;
    if (start == null || plan == null) return null;
    final total = planLength(plan);
    final elapsed = planElapsed;
    final over = elapsed > total ? elapsed - total : Duration.zero;
    final p = positionAt(plan, elapsed > total ? total : elapsed);
    final result = FocusResult(
      start: start,
      // a sessione finita da un po' (app chiusa) la fine è quella prevista
      end: now.subtract(over),
      focusMinutes: (p.focusDone.inSeconds / 60).round(),
      plannedMinutes: _settings?.minutes ?? total.inMinutes,
      completed: elapsed >= total,
    );
    _reset();
    _emit(FocusEventKind.stopped);
    notifyListeners();
    return result;
  }

  /// Scarta la sessione senza esito.
  void discard() {
    if (!active) return;
    _reset();
    _emit(FocusEventKind.stopped);
    notifyListeners();
  }

  void _reset() {
    _stopTicker();
    _settings = null;
    _plan = null;
    _startedAt = null;
    _runningSince = null;
    _accumulated = Duration.zero;
    _skipped = Duration.zero;
    _lastIndex = -1;
    _finishedSent = false;
  }

  void _emit(FocusEventKind k) {
    if (!_events.isClosed) _events.add(k);
  }

  void _startTicker() {
    if (!_tickEnabled) return;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => check());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  // ------------------------------------------------------------ stato

  Map<String, Object?>? toJson() {
    final s = _settings, start = _startedAt;
    if (s == null || start == null) return null;
    return {
      'impostazioni': s.toJson(),
      'inizio': start.toIso8601String(),
      'accumulatoMs': _accumulated.inMilliseconds,
      'daQuando': _runningSince?.toIso8601String(),
      'saltatoMs': _skipped.inMilliseconds,
    };
  }

  /// Riprende una sessione salvata (false se i dati non sono validi). Il
  /// tempo passato ad app chiusa conta, se la sessione non era in pausa.
  bool restore(Object? j) {
    if (j is! Map) return false;
    final start = DateTime.tryParse('${j['inizio'] ?? ''}');
    if (start == null) return false;
    final s = FocusSettings.fromJson(j['impostazioni']);
    _settings = s;
    _plan = buildFocusPlan(s);
    _startedAt = start;
    _accumulated = Duration(
      milliseconds: (j['accumulatoMs'] as num?)?.toInt() ?? 0,
    );
    _skipped = Duration(milliseconds: (j['saltatoMs'] as num?)?.toInt() ?? 0);
    _runningSince = DateTime.tryParse('${j['daQuando'] ?? ''}');
    _lastIndex = position.index;
    _finishedSent = false;
    if (_runningSince != null && !position.finished) _startTicker();
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _stopTicker();
    _events.close();
    super.dispose();
  }
}
