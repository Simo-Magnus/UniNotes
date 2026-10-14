import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/features/study/study_stats.dart';
import 'package:university_notes/models/study.dart';

StudySession _s(
  DateTime start,
  int minutes, {
  int? course,
  int? topic,
  ActivityType activity = ActivityType.theory,
}) => StudySession(
  courseId: course,
  topicId: topic,
  start: start,
  end: start.add(Duration(minutes: minutes)),
  durationMinutes: minutes,
  activityType: activity,
);

void main() {
  group('inizio periodi', () {
    test('la settimana inizia di lunedì', () {
      // 1 ottobre 2026 è un giovedì.
      expect(weekStart(DateTime(2026, 10, 1, 15, 30)), DateTime(2026, 9, 28));
      // Lunedì resta se stesso.
      expect(weekStart(DateTime(2026, 9, 28, 0, 1)), DateTime(2026, 9, 28));
      // Domenica appartiene alla settimana iniziata il lunedì precedente.
      expect(weekStart(DateTime(2026, 10, 4, 23, 59)), DateTime(2026, 9, 28));
      // A cavallo di anno.
      expect(weekStart(DateTime(2027, 1, 1)), DateTime(2026, 12, 28));
    });

    test('giorno e mese', () {
      expect(dayStart(DateTime(2026, 3, 29, 23, 59)), DateTime(2026, 3, 29));
      expect(monthStart(DateTime(2026, 2, 28, 10)), DateTime(2026, 2));
    });
  });

  group('totali per materia/argomento/attività', () {
    final sessions = [
      _s(DateTime(2026, 9, 30, 9), 60, course: 1, topic: 10),
      _s(DateTime(2026, 9, 30, 14), 30, course: 1, topic: 11),
      _s(
        DateTime(2026, 10, 1, 9),
        45,
        course: 2,
        topic: 20,
        activity: ActivityType.exercises,
      ),
      _s(DateTime(2026, 10, 1, 11), 15, activity: ActivityType.review),
    ];

    test('totale', () => expect(totalMinutes(sessions), 150));

    test('per materia (null = senza materia)', () {
      expect(minutesByCourse(sessions), {1: 90, 2: 45, null: 15});
    });

    test('per argomento', () {
      expect(minutesByTopic(sessions), {10: 60, 11: 30, 20: 45, null: 15});
    });

    test('per attività', () {
      expect(minutesByActivity(sessions), {
        ActivityType.theory: 90,
        ActivityType.exercises: 45,
        ActivityType.review: 15,
      });
    });

    test('ordinamento per minuti decrescenti', () {
      final sorted = sortedByMinutes(minutesByCourse(sessions));
      expect(sorted.map((e) => e.key), [1, 2, null]);
    });

    test('lista vuota', () {
      expect(totalMinutes(const []), 0);
      expect(minutesByCourse(const []), isEmpty);
    });
  });

  group('serie temporali', () {
    final today = DateTime(2026, 10, 1, 18);

    test('giornaliero: 14 giorni, zeri inclusi, dal più vecchio', () {
      final series = dailyTotals([
        _s(DateTime(2026, 10, 1, 8), 40),
        _s(DateTime(2026, 10, 1, 20), 20),
        _s(DateTime(2026, 9, 18, 10), 30), // primo giorno della finestra
        _s(DateTime(2026, 9, 17, 10), 99), // fuori finestra
        _s(DateTime(2026, 10, 2, 10), 99), // futuro
      ], today: today);
      expect(series, hasLength(14));
      expect(series.first, PeriodTotal(DateTime(2026, 9, 18), 30));
      expect(series.last, PeriodTotal(DateTime(2026, 10, 1), 60));
      expect(series[5].minutes, 0);
    });

    test('settimanale: 8 settimane da lunedì', () {
      final series = weeklyTotals([
        _s(DateTime(2026, 9, 28, 9), 30), // lunedì settimana corrente
        _s(DateTime(2026, 10, 4, 22), 30), // domenica settimana corrente
        _s(DateTime(2026, 9, 27, 22), 50), // domenica settimana precedente
        _s(DateTime(2026, 8, 10, 9), 10), // lunedì della prima settimana
        _s(DateTime(2026, 8, 9, 22), 99), // domenica prima: fuori finestra
      ], today: today);
      expect(series, hasLength(8));
      expect(series.map((p) => p.start.weekday).toSet(), {DateTime.monday});
      expect(series.first, PeriodTotal(DateTime(2026, 8, 10), 10));
      expect(series[6], PeriodTotal(DateTime(2026, 9, 21), 50));
      expect(series.last, PeriodTotal(DateTime(2026, 9, 28), 60));
    });

    test('mensile: 6 mesi, anche a cavallo d\'anno', () {
      final series = monthlyTotals([
        _s(DateTime(2027, 2, 10), 120),
        _s(DateTime(2026, 12, 31, 23), 30),
        _s(DateTime(2026, 9, 1), 15),
        _s(DateTime(2026, 8, 31), 99), // fuori finestra
      ], today: DateTime(2027, 2, 15));
      expect(series.map((p) => p.start), [
        DateTime(2026, 9),
        DateTime(2026, 10),
        DateTime(2026, 11),
        DateTime(2026, 12),
        DateTime(2027, 1),
        DateTime(2027, 2),
      ]);
      expect(series.map((p) => p.minutes), [15, 0, 0, 30, 0, 120]);
    });
  });

  group('raggruppamento e formati', () {
    test('groupByDay: giorni e sessioni dal più recente', () {
      final a = _s(DateTime(2026, 9, 30, 9), 10);
      final b = _s(DateTime(2026, 10, 1, 8), 20);
      final c = _s(DateTime(2026, 10, 1, 15), 30);
      final groups = groupByDay([a, b, c]);
      expect(groups.map((g) => g.key), [
        DateTime(2026, 10, 1),
        DateTime(2026, 9, 30),
      ]);
      expect(groups.first.value, [c, b]);
    });

    test('minutesBetween', () {
      final s = DateTime(2026, 10, 1, 10);
      expect(minutesBetween(s, s.add(const Duration(minutes: 95))), 95);
      expect(minutesBetween(s, s.add(const Duration(seconds: 89))), 1);
      expect(minutesBetween(s, s.subtract(const Duration(minutes: 5))), 0);
    });

    test('formatMinutes', () {
      expect(formatMinutes(0), '0 min');
      expect(formatMinutes(45), '45 min');
      expect(formatMinutes(60), '1 h');
      expect(formatMinutes(125), '2 h 05 min');
    });
  });
}
