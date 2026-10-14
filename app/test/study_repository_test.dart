import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/models/attachment.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/study.dart';
import 'package:university_notes/repositories/course_repository.dart';
import 'package:university_notes/repositories/study_repository.dart';
import 'package:university_notes/utils/grade_math.dart';

void main() {
  late AppDatabase db;
  late StudyRepository repo;
  late int analisi;
  late int fisica;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    repo = StudyRepository(db);
    final courses = CourseRepository(db);
    analisi = await courses.insert(const Course(name: 'Analisi I'));
    fisica = await courses.insert(const Course(name: 'Fisica I'));
  });
  tearDown(() => db.close());

  test('argomenti di un corso nell\'ordine moduli → argomenti', () async {
    final m2 = await repo.insertModule(
      StudyModule(courseId: analisi, name: 'Derivate', sort: 1),
    );
    final m1 = await repo.insertModule(
      StudyModule(courseId: analisi, name: 'Limiti', sort: 0),
    );
    final mf = await repo.insertModule(
      StudyModule(courseId: fisica, name: 'Cinematica'),
    );
    await repo.insertTopic(Topic(moduleId: m2, name: 'Regole', sort: 0));
    await repo.insertTopic(
      Topic(
        moduleId: m1,
        name: 'Notevoli',
        sort: 1,
        status: TopicStatus.completed,
      ),
    );
    await repo.insertTopic(Topic(moduleId: m1, name: 'Definizione', sort: 0));
    await repo.insertTopic(Topic(moduleId: mf, name: 'Moto rettilineo'));

    final topics = await repo.topicsOfCourse(analisi);
    expect(topics.map((t) => t.name), ['Definizione', 'Notevoli', 'Regole']);
    expect(courseProgress(topics.map((t) => t.status)), closeTo(1 / 3, 1e-9));
    expect((await repo.topicsOfCourse(fisica)).single.name, 'Moto rettilineo');
    expect(await repo.allTopics(), hasLength(4));
  });

  test('sort successivo e riordino', () async {
    expect(await repo.nextModuleSort(analisi), 0);
    final a = await repo.insertModule(
      StudyModule(
        courseId: analisi,
        name: 'A',
        sort: await repo.nextModuleSort(analisi),
      ),
    );
    final b = await repo.insertModule(
      StudyModule(
        courseId: analisi,
        name: 'B',
        sort: await repo.nextModuleSort(analisi),
      ),
    );
    expect(await repo.nextModuleSort(analisi), 2);
    await repo.reorderModules([b, a]);
    expect((await repo.modules(analisi)).map((m) => m.name), ['B', 'A']);

    final t1 = await repo.insertTopic(Topic(moduleId: a, name: 'x', sort: 0));
    final t2 = await repo.insertTopic(
      Topic(moduleId: a, name: 'y', sort: await repo.nextTopicSort(a)),
    );
    expect(await repo.nextTopicSort(a), 2);
    await repo.reorderTopics([t2, t1]);
    expect((await repo.topics(a)).map((t) => t.name), ['y', 'x']);
  });

  test('eliminare un modulo elimina i suoi argomenti', () async {
    final m = await repo.insertModule(
      StudyModule(courseId: analisi, name: 'M'),
    );
    await repo.insertTopic(Topic(moduleId: m, name: 'T'));
    await repo.deleteModule(m);
    expect(await repo.topicsOfCourse(analisi), isEmpty);
  });

  test('sessioni: intervallo [from, to) e filtro corso', () async {
    Future<void> add(DateTime start, int min, int? course) => repo
        .insertSession(
          StudySession(
            courseId: course,
            start: start,
            end: start.add(Duration(minutes: min)),
            durationMinutes: min,
            activityType: ActivityType.exercises,
            notes: 'n',
          ),
        )
        .then((_) {});

    await add(DateTime(2026, 9, 30, 23, 59), 10, analisi);
    await add(DateTime(2026, 10, 1, 0, 0), 20, analisi);
    await add(DateTime(2026, 10, 1, 12, 0), 30, fisica);
    await add(DateTime(2026, 10, 2, 0, 0), 40, analisi);

    final day = await repo.sessions(
      from: DateTime(2026, 10, 1),
      to: DateTime(2026, 10, 2),
    );
    // Ordinate per inizio decrescente, estremo superiore escluso.
    expect(day.map((s) => s.durationMinutes), [30, 20]);
    expect(day.last.activityType, ActivityType.exercises);
    expect(day.last.end, DateTime(2026, 10, 1, 0, 20));

    final onlyAnalisi = await repo.sessions(courseId: analisi);
    expect(onlyAnalisi.map((s) => s.durationMinutes), [40, 20, 10]);

    final since = await repo.sessions(from: DateTime(2026, 10, 1, 12));
    expect(since, hasLength(2));
  });

  test('aggiorna ed elimina sessione', () async {
    final id = await repo.insertSession(
      StudySession(start: DateTime(2026, 10, 1, 9), durationMinutes: 30),
    );
    final s = (await repo.sessions()).single;
    await repo.updateSession(
      StudySession(
        id: s.id,
        courseId: fisica,
        start: s.start,
        end: DateTime(2026, 10, 1, 10),
        durationMinutes: 60,
        activityType: ActivityType.review,
      ),
    );
    final u = (await repo.sessions()).single;
    expect(u.courseId, fisica);
    expect(u.durationMinutes, 60);
    expect(u.activityType, ActivityType.review);
    await repo.deleteSession(id);
    expect(await repo.sessions(), isEmpty);
  });

  test(
    'allegati di moduli e argomenti: per corso e file da eliminare',
    () async {
      final m = await repo.insertModule(
        StudyModule(courseId: analisi, name: 'A'),
      );
      final t = await repo.insertTopic(Topic(moduleId: m, name: 'A1'));
      final other = await repo.insertModule(
        StudyModule(courseId: fisica, name: 'B'),
      );
      final now = DateTime(2026, 10, 5);
      await repo.insertAttachment(
        Attachment(
          moduleId: m,
          title: 'slide',
          storedFile: 'slide.pdf',
          createdAt: now,
        ),
      );
      await repo.insertAttachment(
        Attachment(
          topicId: t,
          title: 'nota',
          path: '/x/nota.md',
          createdAt: now,
        ),
      );
      await repo.insertAttachment(
        Attachment(
          topicId: t,
          title: 'foto',
          storedFile: 'foto.jpg',
          createdAt: now,
        ),
      );
      await repo.insertAttachment(
        Attachment(
          moduleId: other,
          title: 'altro',
          storedFile: 'b.pdf',
          createdAt: now,
        ),
      );
      expect((await repo.attachmentsOfCourse(analisi)).map((a) => a.title), [
        'slide',
        'nota',
        'foto',
      ]);
      expect(await repo.storedAttachmentFiles(topicId: t), ['foto.jpg']);
      expect((await repo.storedAttachmentFiles(moduleId: m))..sort(), [
        'foto.jpg',
        'slide.pdf',
      ]);
      // Eliminando il modulo spariscono anche gli allegati (anche degli argomenti).
      await repo.deleteModule(m);
      expect(await repo.attachmentsOfCourse(analisi), isEmpty);
      expect((await repo.allAttachments()).single.title, 'altro');
    },
  );
}
