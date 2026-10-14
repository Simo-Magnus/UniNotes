import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/academic/electives.dart';
import 'package:university_notes/core/academic/plan_scope.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/curricula.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

void main() {
  test('insegnamento a scelta senza esame: archiviato, poi ripreso', () async {
    final db = await AppDatabase.openInMemory();
    final s = AppServices(db);
    final elective = await s.courses.insert(
      const Course(name: 'Robotica', mandatory: false),
    );
    final required = await s.courses.insert(
      const Course(name: 'Analisi', mandatory: true),
    );
    final e1 = await s.exams.insert(Exam(courseId: elective));
    final e2 = await s.exams.insert(Exam(courseId: required));

    // obbligatorio: eliminare l'esame non lo toglie dal piano
    await s.exams.delete(e2);
    expect(await dropElectiveWithoutExam(s, required), isFalse);

    await s.exams.delete(e1);
    expect(await dropElectiveWithoutExam(s, elective), isTrue);
    final dropped = (await s.courses.byId(elective))!;
    expect(dropped.status, CourseStatus.archived);
    expect(isDroppedElective(dropped), isTrue);
    expect(PlanScope.all.inPath(dropped), isFalse);
    expect(PlanScope.all.inDegree(dropped), isTrue);

    await s.exams.insert(Exam(courseId: elective));
    await restoreElective(s, elective);
    expect((await s.courses.byId(elective))!.status, CourseStatus.active);
    await db.close();
  });

  test('a scelta per ultimi e liste divise per semestre', () {
    const a = Course(id: 1, name: 'Zeta', semester: '1', mandatory: true);
    const b = Course(id: 2, name: 'Alfa', semester: '1', mandatory: false);
    const c = Course(id: 3, name: 'Beta', semester: '2');
    expect(([b, a]..sort(electivesLast)).first.id, 1);

    final courses = {1: a, 2: b, 3: c};
    final exams = [
      Exam(id: 10, courseId: 2, date: DateTime(2027, 1, 10)),
      Exam(id: 11, courseId: 3, date: DateTime(2027, 1, 12)),
      Exam(id: 12, courseId: 1, date: DateTime(2027, 1, 20)),
    ];
    final groups = groupBySemester(exams, (e) => courses[e.courseId]);
    expect(groups.map((g) => g.label), ['1° semestre', '2° semestre']);
    // nel 1° semestre l'insegnamento a scelta va dopo, anche se prima in data
    expect(groups.first.items.map((e) => e.id), [12, 10]);
  });

  test('sessioni d\'esame: calendario del corso di laurea', () {
    final s = SessioniAteneo.fromJson({
      'universita_id': 'x',
      'anno_accademico': '2026/27',
      'calendari': [
        {
          'ambito': 'Scuola di Ingegneria',
          'fonte': 'https://example.org/cal',
          'sessioni': [
            {
              'nome': 'Sessione estiva',
              'inizio': '2027-06-07',
              'fine': '2027-07-17',
            },
            {
              'nome': 'Sessione invernale',
              'inizio': '2027-01-11',
              'fine': '2027-02-20',
            },
            {
              'nome': 'Date errate',
              'inizio': '2027-03-10',
              'fine': '2027-03-01',
            },
          ],
          'corsi': ['x-l-8'],
        },
      ],
    });
    final cal = s.per('x-l-8')!;
    expect(cal.sessioni.map((x) => x.nome), [
      'Sessione invernale',
      'Sessione estiva',
    ]);
    expect(cal.fonte, 'https://example.org/cal');
    expect(s.per('altro'), isNull);
  });

  test('percorsi: solo gli insegnamenti del percorso scelto', () {
    const p = 'Percorso';
    const sh = 'Orientamento "Information technology engineering" - Shanghai';
    final corso = _corso([
      {'id': 'a', 'nome': 'Analisi matematica I', 'curriculum': '$p, $sh'},
      {'id': 'b', 'nome': 'Lingua cinese', 'curriculum': sh},
      {
        'id': 'c',
        'nome': 'Basi di dati',
        'curriculum': '$p, Primo anno sede di Mondovì',
      },
      {'id': 'd', 'nome': 'Prova finale'},
      {
        'id': 'e',
        'nome': 'Fisica I',
        'curriculum': sh,
        'codici_alternativi': ['X'],
      },
      {'id': 'f', 'nome': 'Reti', 'curriculum': p},
      {'id': 'g', 'nome': 'Sistemi operativi', 'curriculum': p},
    ]);
    final ps = PercorsiCorso.di(corso);
    expect(ps.daScegliere, isTrue);
    expect(ps.predefinito, p);
    final nomi = [
      for (final i in soloPercorso(corso, null).insegnamenti) i.nome,
    ];
    expect(nomi, [
      'Analisi matematica I',
      'Basi di dati',
      'Prova finale',
      'Fisica I',
      'Reti',
      'Sistemi operativi',
    ]);
    final shanghai = [
      for (final i in soloPercorso(corso, sh).insegnamenti) i.nome,
    ];
    expect(shanghai, contains('Lingua cinese'));
    expect(shanghai, isNot(contains('Basi di dati')));
    expect(percorsiDi('A (x, y), B'), {'A (x, y)', 'B'});
  });
}

CorsoDettaglio _corso(List<Map<String, Object?>> ins) =>
    CorsoDettaglio.fromJson({
      'id': 'polito-l-8',
      'nome': 'Ingegneria informatica',
      'tipo': 'L',
      'insegnamenti': ins,
    })!;
