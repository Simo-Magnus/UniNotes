import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/features/study/session_dialog.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/features/study/topic_logic.dart';
import 'package:university_notes/models/attachment.dart';
import 'package:university_notes/models/study.dart';

void main() {
  group('StudyTimer', () {
    late DateTime now;
    late StudyTimer timer;

    setUp(() {
      now = DateTime(2026, 10, 1, 9);
      timer = StudyTimer(clock: () => now, tick: false);
    });

    test('avvio, pausa, ripresa e stop escludono le pause', () {
      timer
        ..setCourse(3)
        ..setTopic(7)
        ..setActivity(ActivityType.exercises)
        ..notes = ' esercizi cap. 2 ';
      timer.start();
      expect(timer.isRunning, isTrue);
      now = now.add(const Duration(minutes: 25));
      timer.pause();
      expect(timer.isPaused, isTrue);
      now = now.add(const Duration(minutes: 10)); // pausa
      expect(timer.elapsed, const Duration(minutes: 25));
      timer.start();
      now = now.add(const Duration(minutes: 20));
      expect(timer.elapsed, const Duration(minutes: 45));

      final s = timer.stop()!;
      expect(s.courseId, 3);
      expect(s.topicId, 7);
      expect(s.activityType, ActivityType.exercises);
      expect(s.start, DateTime(2026, 10, 1, 9));
      expect(s.end, DateTime(2026, 10, 1, 9, 55));
      expect(s.durationMinutes, 45);
      expect(s.notes, 'esercizi cap. 2');
      // Azzerato, ma la scelta di corso/attività resta.
      expect(timer.isActive, isFalse);
      expect(timer.elapsed, Duration.zero);
      expect(timer.courseId, 3);
    });

    test('sessione sotto il minuto non viene salvata', () {
      timer.start();
      now = now.add(const Duration(seconds: 20));
      expect(timer.stop(), isNull);
      expect(timer.isActive, isFalse);
    });

    test('cambiare corso azzera l\'argomento', () {
      timer
        ..setCourse(1)
        ..setTopic(5)
        ..setCourse(2);
      expect(timer.topicId, isNull);
    });

    test('modulo: cambiandolo si azzera l\'argomento; va nella sessione', () {
      timer
        ..setCourse(2)
        ..setModule(7)
        ..setTopic(9);
      expect((timer.moduleId, timer.topicId), (7, 9));
      timer.setModule(8);
      expect(timer.topicId, isNull);
      timer.setCourse(3);
      expect((timer.moduleId, timer.topicId), (null, null));
      timer.select(courseId: 4, moduleId: 5, topicId: 6);
      timer.start();
      now = now.add(const Duration(minutes: 30));
      final s = timer.stop()!;
      expect((s.courseId, s.moduleId, s.topicId), (4, 5, 6));
    });
  });

  group('argomenti', () {
    const t = Topic(
      id: 3,
      moduleId: 1,
      name: 'Limiti',
      status: TopicStatus.partial,
      notes: 'vecchia',
    );

    test('riordino con trascinamento (indici di onReorderItem)', () {
      expect(reorderList([1, 2, 3], 0, 1), [2, 1, 3]);
      expect(reorderList([1, 2, 3], 0, 2), [2, 3, 1]);
      expect(reorderList([1, 2, 3], 2, 0), [3, 1, 2]);
      expect(reorderList([1, 2, 3], 1, 1), isNull);
      expect(reorderList([1, 2, 3], 5, 0), isNull);
    });

    test('nota: nome e nota cambiati, il resto resta', () {
      final a = withNameNote(t, 'Limiti notevoli', '  rivedere es. 4 ');
      expect(a.name, 'Limiti notevoli');
      expect(a.notes, 'rivedere es. 4');
      expect(a.status, TopicStatus.partial);
      expect(a.id, 3);
      expect(withNameNote(t, 'Limiti', ' ').notes, isNull);
    });

    test('modulo: nota vuota = nessuna nota', () {
      const m = StudyModule(id: 1, courseId: 2, name: 'Analisi', notes: 'x');
      expect(m.copyWith(notes: '').notes, isNull);
      expect(m.copyWith(name: 'Analisi I').notes, 'x');
      expect(StudyModule.fromMap(m.toMap()).notes, 'x');
    });

    test('tipo dei file allegati', () {
      expect(AttachmentKind.parse('ripasso,teoria'), {
        AttachmentKind.review,
        AttachmentKind.theory,
      });
      expect(AttachmentKind.parse(null), isEmpty);
      expect(AttachmentKind.parse('teoria,boh'), {AttachmentKind.theory});
      expect(
        AttachmentKind.encode({AttachmentKind.review, AttachmentKind.theory}),
        'teoria,ripasso',
      );
      expect(AttachmentKind.encode({}), isNull);
      final a = Attachment(
        topicId: 1,
        title: 'Esercizi 1',
        createdAt: DateTime(2026, 10, 1),
        kinds: const {AttachmentKind.exercises},
      );
      expect(Attachment.fromMap(a.toMap()).kinds, {AttachmentKind.exercises});
    });
  });

  test('sessionEnd: fine prima dell\'inizio = giorno dopo', () {
    final day = DateTime(2026, 10, 1);
    expect(
      sessionEnd(
        day,
        const TimeOfDay(hour: 23, minute: 0),
        const TimeOfDay(hour: 0, minute: 30),
      ),
      DateTime(2026, 10, 2, 0, 30),
    );
    expect(
      sessionEnd(
        day,
        const TimeOfDay(hour: 9, minute: 0),
        const TimeOfDay(hour: 10, minute: 15),
      ),
      DateTime(2026, 10, 1, 10, 15),
    );
  });
}
