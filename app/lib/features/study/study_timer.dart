import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/constants/enums.dart';
import '../../models/study.dart';

/// Cronometro di studio e scelta di che cosa si studia (insegnamento,
/// modulo, argomento) in Sessioni Studio: la stessa scelta vale anche per il
/// timer Focus. Vive per tutta l'app ([instance]) così continua a contare
/// anche cambiando scheda o sezione.
class StudyTimer extends ChangeNotifier {
  StudyTimer({DateTime Function()? clock, bool tick = true})
    : _clock = clock ?? DateTime.now,
      _tickEnabled = tick;

  static final StudyTimer instance = StudyTimer();

  final DateTime Function() _clock;
  final bool _tickEnabled;
  Timer? _ticker;

  int? courseId;

  /// Modulo scelto (null = tutto l'insegnamento).
  int? moduleId;

  /// Argomento scelto (null = tutto il modulo).
  int? topicId;
  ActivityType activity = ActivityType.theory;
  String notes = '';

  DateTime? _startedAt;
  DateTime? _runningSince;
  Duration _accumulated = Duration.zero;

  /// Istante del primo avvio della sessione corrente.
  DateTime? get startedAt => _startedAt;

  /// true se c'è una sessione in corso (anche in pausa).
  bool get isActive => _startedAt != null;
  bool get isRunning => _runningSince != null;
  bool get isPaused => isActive && !isRunning;

  Duration get elapsed {
    final since = _runningSince;
    if (since == null) return _accumulated;
    return _accumulated + _span(since);
  }

  /// Tempo dal riavvio [since]: mai negativo (orologio del sistema spostato
  /// indietro mentre si studia), così il tempo già accumulato non si perde.
  Duration _span(DateTime since) {
    final d = _clock().difference(since);
    return d.isNegative ? Duration.zero : d;
  }

  void setCourse(int? id) {
    if (id == courseId) return;
    courseId = id;
    moduleId = null;
    topicId = null;
    notifyListeners();
  }

  void setModule(int? id) {
    if (id == moduleId) return;
    moduleId = id;
    topicId = null;
    notifyListeners();
  }

  void setTopic(int? id) {
    topicId = id;
    notifyListeners();
  }

  /// Scelta completa (es. «Sessione focus» da Argomenti).
  void select({int? courseId, int? moduleId, int? topicId}) {
    this.courseId = courseId;
    this.moduleId = courseId == null ? null : moduleId;
    this.topicId = courseId == null ? null : topicId;
    notifyListeners();
  }

  void setActivity(ActivityType a) {
    activity = a;
    notifyListeners();
  }

  /// Avvia o riprende.
  void start() {
    if (isRunning) return;
    final now = _clock();
    _startedAt ??= now;
    _runningSince = now;
    _startTicker();
    notifyListeners();
  }

  void pause() {
    final since = _runningSince;
    if (since == null) return;
    _accumulated += _span(since);
    _runningSince = null;
    _stopTicker();
    notifyListeners();
  }

  /// Ferma il timer e restituisce la sessione da salvare (null se durata
  /// inferiore a un minuto). Il timer viene azzerato; corso, modulo,
  /// argomento e attività restano selezionati per la sessione successiva.
  StudySession? stop() {
    final start = _startedAt;
    if (start == null) return null;
    final minutes = (elapsed.inSeconds / 60).round();
    final now = _clock();
    // orologio spostato indietro: la fine non viene prima dell'inizio
    final end = now.isBefore(start) ? start.add(elapsed) : now;
    final session = minutes < 1
        ? null
        : StudySession(
            courseId: courseId,
            moduleId: moduleId,
            topicId: topicId,
            start: start,
            end: end,
            durationMinutes: minutes,
            activityType: activity,
            notes: notes.trim().isEmpty ? null : notes.trim(),
          );
    reset();
    return session;
  }

  /// Rimette nel cronometro (in pausa) una sessione che [stop] aveva tolto
  /// ma che non si è potuta salvare: il tempo non va perso e «Salva» si
  /// può riprovare.
  void putBack(StudySession session) {
    _startedAt = session.start;
    _runningSince = null;
    _accumulated = Duration(minutes: session.durationMinutes);
    notes = session.notes ?? '';
    _stopTicker();
    notifyListeners();
  }

  /// Scarta la sessione in corso.
  void reset() {
    _startedAt = null;
    _runningSince = null;
    _accumulated = Duration.zero;
    notes = '';
    _stopTicker();
    notifyListeners();
  }

  void _startTicker() {
    if (!_tickEnabled) return;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}

/// "01:05:09".
String formatElapsed(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
