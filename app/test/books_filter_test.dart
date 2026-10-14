import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/books/book_filters.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/book_repository.dart';
import 'package:university_notes/repositories/course_repository.dart';

const _analisiPdf = Book(
  id: 1,
  courseId: 10,
  title: 'Analisi Matematica 1',
  author: 'Bramanti',
  format: BookFormat.pdf,
  ownership: BookOwnership.owned,
  filePath: r'D:\Libri\analisi.pdf',
  language: 'italiano',
  required: true,
);
const _fisicaWanted = Book(
  id: 2,
  courseId: 20,
  title: 'Fisica 1',
  author: 'Mazzoldi',
  format: BookFormat.paper,
  ownership: BookOwnership.wanted,
  required: false,
);
const _analisiEsercizi = Book(
  id: 3,
  courseId: 10,
  title: 'Esercizi di analisi',
  format: BookFormat.paper,
  ownership: BookOwnership.borrowed,
  physicalLocation: 'Scaffale 2',
);
const _orphan = Book(
  id: 4,
  title: 'Manuale di stile',
  ownership: BookOwnership.unavailable,
);

const _all = [_analisiPdf, _fisicaWanted, _analisiEsercizi, _orphan];

List<int?> _ids(List<Book> l) => l.map((b) => b.id).toList();

void main() {
  test('scaricato / da procurare', () {
    expect(isDownloaded(_analisiPdf), isTrue);
    expect(isDownloaded(const Book(title: 'x', filePath: '  ')), isFalse);
    expect(needsProcurement(_fisicaWanted), isTrue);
    expect(needsProcurement(_orphan), isTrue);
    expect(needsProcurement(_analisiEsercizi), isFalse);
    // Desiderato ma con file già associato: non va procurato.
    expect(
      needsProcurement(
        const Book(title: 'x', ownership: BookOwnership.wanted, filePath: 'a'),
      ),
      isFalse,
    );
  });

  test('facoltativi non da procurare se gli obbligatori del corso ci sono', () {
    const req = Book(
      id: 11,
      courseId: 30,
      title: 'Obbl.',
      required: true,
      filePath: 'a.pdf',
    );
    const opt = Book(id: 12, courseId: 30, title: 'Facolt.', required: false);
    const reqMissing = Book(
      id: 13,
      courseId: 40,
      title: 'Obbl. 2',
      required: true,
    );
    const opt2 = Book(
      id: 14,
      courseId: 40,
      title: 'Facolt. 2',
      required: false,
    );
    const onlyOpt = Book(
      id: 15,
      courseId: 50,
      title: 'Solo facolt.',
      required: false,
    );
    const all = [req, opt, reqMissing, opt2, onlyOpt];
    final covered = coursesWithRequiredCovered(all);
    expect(covered, {30});
    expect(needsProcurement(opt, covered: covered), isFalse);
    expect(needsProcurement(opt2, covered: covered), isTrue);
    expect(needsProcurement(reqMissing, covered: covered), isTrue);
    // Corso con soli libri facoltativi: restano da procurare.
    expect(needsProcurement(onlyOpt, covered: covered), isTrue);
    expect(
      _ids(
        filterBooks(
          all,
          const BookFilter(availability: BookAvailability.toProcure),
        ),
      ),
      // il filtro «Da procurare» riguarda solo i libri obbligatori
      [13],
    );
  });

  test('filtri per corso, stato, formato, disponibilità', () {
    expect(_ids(filterBooks(_all, const BookFilter(courseId: 10))), [1, 3]);
    expect(
      _ids(filterBooks(_all, const BookFilter(courseId: BookFilter.noCourse))),
      [4],
    );
    expect(
      _ids(
        filterBooks(_all, const BookFilter(ownership: BookOwnership.borrowed)),
      ),
      [3],
    );
    expect(
      _ids(filterBooks(_all, const BookFilter(format: BookFormat.paper))),
      [2, 3],
    );
    expect(
      _ids(
        filterBooks(
          _all,
          const BookFilter(availability: BookAvailability.downloaded),
        ),
      ),
      [1],
    );
    expect(
      _ids(
        filterBooks(
          _all,
          const BookFilter(availability: BookAvailability.toProcure),
        ),
      ),
      // nessun obbligatorio senza file
      <int>[],
    );
  });

  test('ricerca su più campi e nome materia, tutte le parole', () {
    String course(int? id) => id == 20 ? 'Fisica generale' : 'Analisi I';
    List<int?> q(String s) =>
        _ids(filterBooks(_all, BookFilter(query: s), courseName: course));
    expect(q('bramanti'), [1]);
    expect(q('ANALISI'), [1, 3, 4]); // id 4: materia null → "Analisi I"
    expect(q('generale'), [2]);
    // la posizione fisica non è più nell'app: non si cerca
    expect(q('scaffale'), isEmpty);
    expect(q('analisi esercizi'), [3]);
    expect(q('  '), [1, 2, 3, 4]);
  });

  test('copyWith permette di azzerare i filtri nullable', () {
    const f = BookFilter(courseId: 10, format: BookFormat.pdf);
    final g = f.copyWith(courseId: () => null);
    expect(g.courseId, isNull);
    expect(g.format, BookFormat.pdf);
    expect(g.isActive, isTrue);
    expect(const BookFilter().isActive, isFalse);
    // «Scaricati» / «Da procurare» si tolgono tornando a nessuna scelta
    final h = const BookFilter(availability: BookAvailability.downloaded)
        .copyWith(availability: () => null);
    expect(h.availability, isNull);
    expect(h.isActive, isFalse);
  });

  test('raggruppa per corso: ordine corsi, obbligatori prima, senza corso in fondo', () {
    final groups = groupBooksByCourse(
      [_orphan, _analisiEsercizi, _fisicaWanted, _analisiPdf],
      [20, 10],
    );
    expect(groups.map((g) => g.key), [20, 10, null]);
    expect(_ids(groups[1].value), [1, 3]);
    // Corso sconosciuto → gruppo "senza materia".
    final g2 = groupBooksByCourse([_fisicaWanted], [10]);
    expect(g2.single.key, isNull);
  });

  test('repository libri su DB in memoria', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final courseId = await CourseRepository(db)
        .insert(const Course(name: 'Analisi I'));
    final repo = BookRepository(db);
    final id = await repo.insert(
      Book(
        courseId: courseId,
        title: 'Analisi',
        format: BookFormat.pdf,
        ownership: BookOwnership.owned,
        filePath: r'C:\Libri\a.pdf',
        required: true,
      ),
    );
    await repo.insert(const Book(title: 'Altro'));
    final mine = await repo.all(courseId: courseId);
    expect(mine.single.id, id);
    expect(mine.single.required, isTrue);
    expect(mine.single.filePath, r'C:\Libri\a.pdf');
    expect(await repo.all(), hasLength(2));
  });
}
