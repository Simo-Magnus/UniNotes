import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/nudges.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

void main() {
  late AppServices s;
  late Nudges n;
  final t0 = DateTime(2026, 10, 1);

  setUp(() async {
    s = AppServices(await AppDatabase.openInMemory());
    n = Nudges(s);
  });
  tearDown(() => s.database.close());

  Future<void> opens(int k, DateTime at) async {
    for (var i = 0; i < k; i++) {
      await n.registerOpen(now: at);
    }
  }

  test('recensione: non subito, poi in un momento positivo', () async {
    await opens(12, t0);
    expect(await n.current(now: t0.add(const Duration(days: 3))), isNull);
    // 15 giorni: serve un esame superato da poco (o 30 giorni d'uso)
    final day15 = t0.add(const Duration(days: 15));
    expect(await n.current(now: day15), isNull);
    final c = await s.courses.insert(const Course(name: 'Analisi'));
    await s.exams.insert(
      Exam(courseId: c, status: ExamStatus.passed, grade: 28, date: day15),
    );
    expect(await n.current(now: day15), NudgeKind.review);
    // «Più tardi»: 60 giorni
    await n.later(NudgeKind.review, now: day15);
    expect(await n.current(now: day15.add(const Duration(days: 10))), isNull);
    // «No, grazie»: mai più
    await n.never(NudgeKind.review);
    expect(await n.current(now: day15.add(const Duration(days: 90))), isNull);
  });

  test('niente inviti con un esame nei prossimi 7 giorni', () async {
    await opens(20, t0);
    final day40 = t0.add(const Duration(days: 40));
    final c = await s.courses.insert(const Course(name: 'Fisica'));
    await s.exams.insert(
      Exam(courseId: c, date: day40.add(const Duration(days: 3))),
    );
    expect(await n.current(now: day40), isNull);
  });

  test('link della recensione: GitHub nelle build predefinite', () {
    expect(Nudges.reviewTarget().url, contains('github.com'));
  });
}
