/// Logica pura di filtro/raggruppamento del catalogo libri.
library;

import '../../core/constants/enums.dart';
import '../../models/book.dart';

/// Il libro ha un file: copiato nell'app o collegato a un percorso locale.
bool isDownloaded(Book b) => isInApp(b) || (b.filePath ?? '').trim().isNotEmpty;

/// Il file del libro è stato copiato dentro l'app.
bool isInApp(Book b) => (b.storedFile ?? '').isNotEmpty;

/// Avanzamento di lettura ("p. 45/300"), se il libro è stato aperto.
String? readingProgress(Book b) {
  final page = b.lastPage;
  if (page == null) return null;
  final count = b.pageCount;
  return count == null ? 'p. $page' : 'p. $page/$count';
}

/// Il libro va ancora procurato: desiderato o non disponibile e senza file.
///
/// [covered] sono i corsi che hanno già tutti i libri obbligatori (vedi
/// [coursesWithRequiredCovered]): lì i libri facoltativi non vanno più
/// procurati. Un corso con soli libri facoltativi non è mai "coperto".
bool needsProcurement(Book b, {Set<int>? covered}) {
  if (b.isRemoved || !_missing(b)) return false;
  final course = b.courseId;
  if (b.required != true &&
      course != null &&
      (covered?.contains(course) ?? false)) {
    return false;
  }
  return true;
}

bool _missing(Book b) =>
    !isDownloaded(b) &&
    (b.ownership == BookOwnership.wanted ||
        b.ownership == BookOwnership.unavailable);

/// Corsi con almeno un libro obbligatorio e tutti gli obbligatori già
/// procurati (scaricati o posseduti).
Set<int> coursesWithRequiredCovered(Iterable<Book> books) {
  final hasRequired = <int>{};
  final missingRequired = <int>{};
  for (final b in books) {
    final c = b.courseId;
    if (c == null || b.required != true || b.isRemoved) continue;
    hasRequired.add(c);
    if (_missing(b)) missingRequired.add(c);
  }
  return hasRequired.difference(missingRequired);
}

/// «Scaricati» / «Da procurare»; nessuna scelta = tutti i libri (non c'è
/// l'opzione «Tutti»).
enum BookAvailability {
  downloaded('Scaricati'),
  toProcure('Da procurare');

  const BookAvailability(this.label);
  final String label;

  bool matches(Book b, {Set<int>? covered}) => switch (this) {
    BookAvailability.downloaded => isDownloaded(b),
    BookAvailability.toProcure =>
      b.required == true && needsProcurement(b, covered: covered),
  };
}

/// Filtri del catalogo. `courseId == noCourse` = libri senza materia.
class BookFilter {
  const BookFilter({
    this.query = '',
    this.courseId,
    this.ownership,
    this.format,
    this.availability,
    this.removed = false,
  });

  static const int noCourse = -1;

  /// true = solo i libri rimossi ("Libri rimossi"), false = solo gli altri.
  final bool removed;

  final String query;
  final int? courseId;
  final BookOwnership? ownership;
  final BookFormat? format;
  final BookAvailability? availability;

  bool get isActive =>
      query.trim().isNotEmpty ||
      courseId != null ||
      ownership != null ||
      format != null ||
      availability != null ||
      removed;

  BookFilter copyWith({
    String? query,
    int? Function()? courseId,
    BookOwnership? Function()? ownership,
    BookFormat? Function()? format,
    BookAvailability? Function()? availability,
    bool? removed,
  }) => BookFilter(
    query: query ?? this.query,
    courseId: courseId == null ? this.courseId : courseId(),
    ownership: ownership == null ? this.ownership : ownership(),
    format: format == null ? this.format : format(),
    availability: availability == null ? this.availability : availability(),
    removed: removed ?? this.removed,
  );

  /// [courseName] serve a cercare anche per nome della materia.
  bool matches(
    Book b, {
    String Function(int? courseId)? courseName,
    Set<int>? covered,
  }) {
    if (b.isRemoved != removed) return false;
    if (courseId == noCourse && b.courseId != null) return false;
    if (courseId != null && courseId != noCourse && b.courseId != courseId) {
      return false;
    }
    if (ownership != null && b.ownership != ownership) return false;
    if (format != null && b.format != format) return false;
    if (availability case final a? when !a.matches(b, covered: covered)) {
      return false;
    }
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = [
      b.title,
      b.author,
      b.isbn,
      b.publisher,
      b.edition,
      b.notes,
      b.language,
      courseName?.call(b.courseId),
    ].whereType<String>().join('\n').toLowerCase();
    return q.split(RegExp(r'\s+')).every(haystack.contains);
  }
}

List<Book> filterBooks(
  Iterable<Book> books,
  BookFilter filter, {
  String Function(int? courseId)? courseName,
}) {
  final list = books.toList();
  final covered = coursesWithRequiredCovered(list);
  return list
      .where((b) => filter.matches(b, courseName: courseName, covered: covered))
      .toList();
}

/// Raggruppa per corso seguendo [courseOrder]; i libri senza corso (o di
/// corsi sconosciuti) vanno in un gruppo finale con chiave null.
/// All'interno di ogni gruppo: prima gli obbligatori, poi per titolo.
List<MapEntry<int?, List<Book>>> groupBooksByCourse(
  Iterable<Book> books,
  List<int> courseOrder,
) {
  final known = courseOrder.toSet();
  final map = <int?, List<Book>>{};
  for (final b in books) {
    final key = known.contains(b.courseId) ? b.courseId : null;
    map.putIfAbsent(key, () => []).add(b);
  }
  int reqRank(Book b) => b.required == true ? 0 : (b.required == false ? 1 : 2);
  for (final l in map.values) {
    l.sort((a, b) {
      final r = reqRank(a).compareTo(reqRank(b));
      if (r != 0) return r;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }
  return [
    for (final id in courseOrder)
      if (map.containsKey(id)) MapEntry(id, map[id]!),
    if (map.containsKey(null)) MapEntry(null, map[null]!),
  ];
}
