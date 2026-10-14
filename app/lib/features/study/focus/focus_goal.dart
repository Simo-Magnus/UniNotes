/// Obiettivo giornaliero di studio e serie di giorni consecutivi (logica
/// pura, test in test/focus_test.dart).
///
/// Contano tutte le sessioni di studio del giorno in cui iniziano: quelle
/// Focus, quelle del cronometro e quelle aggiunte a mano.
library;

import '../../../models/study.dart';
import '../study_stats.dart';

/// Obiettivi proposti (minuti al giorno).
const List<int> kDailyGoalChoices = [30, 45, 60, 90, 120, 180, 240];
const int kDefaultDailyGoal = 60;

/// Minuti di studio per giorno (chiave: mezzanotte locale).
Map<DateTime, int> minutesPerDay(Iterable<StudySession> sessions) {
  final out = <DateTime, int>{};
  for (final s in sessions) {
    final d = dayStart(s.start);
    out[d] = (out[d] ?? 0) + s.durationMinutes;
  }
  return out;
}

/// Giorni consecutivi con l'obiettivo raggiunto, fino a oggi. Se oggi non è
/// ancora raggiunto la serie resta quella che arriva a ieri (si può ancora
/// allungare in giornata); un giorno senza obiettivo la interrompe.
int goalStreak(
  Map<DateTime, int> perDay, {
  required DateTime today,
  required int goal,
}) {
  if (goal <= 0) return 0;
  bool met(DateTime d) => (perDay[d] ?? 0) >= goal;
  final t = dayStart(today);
  var day = met(t) ? t : DateTime(t.year, t.month, t.day - 1);
  var n = 0;
  while (met(day)) {
    n++;
    day = DateTime(day.year, day.month, day.day - 1);
  }
  return n;
}

/// Serie più lunga di sempre.
int bestStreak(Map<DateTime, int> perDay, {required int goal}) {
  if (goal <= 0 || perDay.isEmpty) return 0;
  final days =
      perDay.entries.where((e) => e.value >= goal).map((e) => e.key).toList()
        ..sort();
  var best = 0, run = 0;
  DateTime? prev;
  for (final d in days) {
    final next = prev == null
        ? null
        : DateTime(prev.year, prev.month, prev.day + 1);
    run = (next != null && next == d) ? run + 1 : 1;
    if (run > best) best = run;
    prev = d;
  }
  return best;
}

/// Avanzamento verso l'obiettivo (0–1, pieno se superato).
double goalProgress(int minutes, int goal) =>
    goal <= 0 ? 0 : (minutes / goal).clamp(0.0, 1.0);

/// Obiettivo salvato → valore valido (predefinito 60 minuti).
int parseDailyGoal(String? v) {
  final n = int.tryParse(v ?? '');
  return n == null || n < 10 || n > 600 ? kDefaultDailyGoal : n;
}

/// "Ancora 25 min", "Obiettivo raggiunto".
String goalCaption(int minutes, int goal) {
  if (minutes >= goal) return 'Obiettivo raggiunto';
  return 'Ancora ${formatMinutes(goal - minutes)}';
}

/// "1 giorno", "5 giorni".
String streakLabel(int days) => days == 1 ? '1 giorno' : '$days giorni';

/// Obiettivo, serie e tempo Focus calcolati dalle sessioni.
class FocusStats {
  const FocusStats({
    required this.goal,
    required this.today,
    required this.streak,
    required this.best,
    required this.focusToday,
    required this.focusWeek,
    required this.focusSessionsWeek,
  });

  factory FocusStats.of(
    Iterable<StudySession> sessions, {
    required int goal,
    required DateTime today,
  }) {
    final perDay = minutesPerDay(sessions);
    final d = dayStart(today);
    final week = weekStart(today);
    final focus = sessions.where((s) => s.focus).toList();
    final thisWeek = focus.where((s) => !s.start.isBefore(week)).toList();
    return FocusStats(
      goal: goal,
      today: perDay[d] ?? 0,
      streak: goalStreak(perDay, today: today, goal: goal),
      best: bestStreak(perDay, goal: goal),
      focusToday: totalMinutes(focus.where((s) => dayStart(s.start) == d)),
      focusWeek: totalMinutes(thisWeek),
      focusSessionsWeek: thisWeek.length,
    );
  }

  final int goal;

  /// Minuti di studio di oggi (tutte le sessioni).
  final int today;
  final int streak;
  final int best;

  /// Minuti delle sole sessioni Focus.
  final int focusToday;
  final int focusWeek;
  final int focusSessionsWeek;

  /// Avanzamento verso l'obiettivo di oggi (0–1).
  double get progress => goalProgress(today, goal);
  String get caption => goalCaption(today, goal);
  String get streakText => streakLabel(streak);
  String get bestText => streakLabel(best);
}
