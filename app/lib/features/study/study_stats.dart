/// Aggregazioni pure sulle sessioni di studio (testabili senza UI).
///
/// Una sessione è attribuita al giorno/settimana/mese in cui **inizia**.
/// Le settimane iniziano di lunedì.
library;

import '../../core/constants/enums.dart';
import '../../models/study.dart';

/// Totale minuti di un periodo che inizia in [start].
class PeriodTotal {
  const PeriodTotal(this.start, this.minutes);
  final DateTime start;
  final int minutes;

  @override
  bool operator ==(Object other) =>
      other is PeriodTotal && other.start == start && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(start, minutes);

  @override
  String toString() => 'PeriodTotal($start, $minutes)';
}

/// Mezzanotte (ora locale) del giorno di [d].
DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// Lunedì della settimana di [d], a mezzanotte.
DateTime weekStart(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - DateTime.monday));

/// Primo giorno del mese di [d].
DateTime monthStart(DateTime d) => DateTime(d.year, d.month);

int totalMinutes(Iterable<StudySession> sessions) =>
    sessions.fold(0, (sum, s) => sum + s.durationMinutes);

Map<K, int> _sumBy<K>(
  Iterable<StudySession> sessions,
  K Function(StudySession) key,
) {
  final out = <K, int>{};
  for (final s in sessions) {
    final k = key(s);
    out[k] = (out[k] ?? 0) + s.durationMinutes;
  }
  return out;
}

/// Minuti per corso (chiave null = senza materia).
Map<int?, int> minutesByCourse(Iterable<StudySession> sessions) =>
    _sumBy(sessions, (s) => s.courseId);

/// Minuti per argomento (chiave null = senza argomento).
Map<int?, int> minutesByTopic(Iterable<StudySession> sessions) =>
    _sumBy(sessions, (s) => s.topicId);

Map<ActivityType, int> minutesByActivity(Iterable<StudySession> sessions) =>
    _sumBy(sessions, (s) => s.activityType);

/// Voci di una mappa ordinate per minuti decrescenti.
List<MapEntry<K, int>> sortedByMinutes<K>(Map<K, int> m) =>
    m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

List<PeriodTotal> _series(
  Iterable<StudySession> sessions,
  List<DateTime> starts,
  DateTime Function(DateTime) bucket,
) {
  final sums = _sumBy(sessions, (s) => bucket(s.start));
  return [for (final d in starts) PeriodTotal(d, sums[d] ?? 0)];
}

/// Ultimi [days] giorni fino a [today] incluso, dal più vecchio.
List<PeriodTotal> dailyTotals(
  Iterable<StudySession> sessions, {
  required DateTime today,
  int days = 14,
}) {
  final last = dayStart(today);
  final starts = [
    for (var i = days - 1; i >= 0; i--)
      DateTime(last.year, last.month, last.day - i),
  ];
  return _series(sessions, starts, dayStart);
}

/// Ultime [weeks] settimane (lunedì-domenica) fino a quella di [today].
List<PeriodTotal> weeklyTotals(
  Iterable<StudySession> sessions, {
  required DateTime today,
  int weeks = 8,
}) {
  final last = weekStart(today);
  final starts = [
    for (var i = weeks - 1; i >= 0; i--)
      DateTime(last.year, last.month, last.day - 7 * i),
  ];
  return _series(sessions, starts, weekStart);
}

/// Ultimi [months] mesi fino a quello di [today].
List<PeriodTotal> monthlyTotals(
  Iterable<StudySession> sessions, {
  required DateTime today,
  int months = 6,
}) {
  final starts = [
    for (var i = months - 1; i >= 0; i--) DateTime(today.year, today.month - i),
  ];
  return _series(sessions, starts, monthStart);
}

/// Sessioni raggruppate per giorno, giorni dal più recente; all'interno
/// del giorno le sessioni sono in ordine di inizio decrescente.
List<MapEntry<DateTime, List<StudySession>>> groupByDay(
  Iterable<StudySession> sessions,
) {
  final map = <DateTime, List<StudySession>>{};
  for (final s in sessions) {
    map.putIfAbsent(dayStart(s.start), () => []).add(s);
  }
  for (final l in map.values) {
    l.sort((a, b) => b.start.compareTo(a.start));
  }
  return map.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
}

/// Durata in minuti tra due istanti (arrotondata, mai negativa).
int minutesBetween(DateTime start, DateTime end) {
  final secs = end.difference(start).inSeconds;
  if (secs <= 0) return 0;
  return (secs / 60).round();
}

/// "1 h 05 min", "45 min", "0 min".
String formatMinutes(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h ${m.toString().padLeft(2, '0')} min';
}
