import '../core/constants/enums.dart';
import '../utils/parse.dart';

class Book {
  const Book({
    this.id,
    this.externalId,
    this.courseId,
    required this.title,
    this.author,
    this.isbn,
    this.edition,
    this.publisher,
    this.year,
    this.format = BookFormat.other,
    this.ownership = BookOwnership.wanted,
    this.physicalLocation,
    this.notes,
    this.filePath,
    this.expectedFileName,
    this.language,
    this.required,
    this.storedFile,
    this.lastPage,
    this.pageCount,
    this.lastOpenedAt,
    this.catalogChoice,
    this.userEdited = false,
  });

  final int? id;
  final String? externalId;
  final int? courseId;
  final String title;
  final String? author;
  final String? isbn;
  final String? edition;
  final String? publisher;
  final int? year;
  final BookFormat format;
  final BookOwnership ownership;
  final String? physicalLocation;
  final String? notes;

  /// Percorso locale del file (o cartella) del libro.
  final String? filePath;
  final String? expectedFileName;
  final String? language;

  /// true = obbligatorio, false = consigliato, null = non indicato.
  final bool? required;

  /// Nome del file copiato nella cartella libri dell'app (vedi BookLibrary).
  final String? storedFile;

  /// Ultima pagina letta (1 = prima) e numero di pagine, salvati dal lettore.
  final int? lastPage;
  final int? pageCount;
  final DateTime? lastOpenedAt;

  /// Scelta su un libro del catalogo: Tieni / Rimuovi / da decidere (null).
  final CatalogChoice? catalogChoice;

  /// Dati modificati dallo studente: gli aggiornamenti non li toccano.
  final bool userEdited;

  /// Libro proposto dal catalogo pubblico (importato con externalId).
  bool get fromCatalog => externalId != null;

  /// Nascosto dallo studente ("Rimuovi"), ripristinabile.
  bool get isRemoved => catalogChoice == CatalogChoice.removed;

  /// Proposto dal catalogo e non ancora tenuto né rimosso.
  bool get awaitingChoice => fromCatalog && catalogChoice == null;

  /// Copia con i campi di lettura/archiviazione modificati.
  Book withFile({
    String? Function()? storedFile,
    int? Function()? lastPage,
    int? Function()? pageCount,
  }) => Book(
    id: id,
    externalId: externalId,
    courseId: courseId,
    title: title,
    author: author,
    isbn: isbn,
    edition: edition,
    publisher: publisher,
    year: year,
    format: format,
    ownership: ownership,
    physicalLocation: physicalLocation,
    notes: notes,
    filePath: filePath,
    expectedFileName: expectedFileName,
    language: language,
    required: required,
    storedFile: storedFile == null ? this.storedFile : storedFile(),
    lastPage: lastPage == null ? this.lastPage : lastPage(),
    pageCount: pageCount == null ? this.pageCount : pageCount(),
    lastOpenedAt: lastOpenedAt,
    catalogChoice: catalogChoice,
    userEdited: userEdited,
  );

  /// Copia con la scelta Tieni/Rimuovi o il segno "modificato" cambiati.
  Book withChoice({
    CatalogChoice? Function()? catalogChoice,
    bool? userEdited,
  }) => Book(
    id: id,
    externalId: externalId,
    courseId: courseId,
    title: title,
    author: author,
    isbn: isbn,
    edition: edition,
    publisher: publisher,
    year: year,
    format: format,
    ownership: ownership,
    physicalLocation: physicalLocation,
    notes: notes,
    filePath: filePath,
    expectedFileName: expectedFileName,
    language: language,
    required: required,
    storedFile: storedFile,
    lastPage: lastPage,
    pageCount: pageCount,
    lastOpenedAt: lastOpenedAt,
    catalogChoice: catalogChoice == null ? this.catalogChoice : catalogChoice(),
    userEdited: userEdited ?? this.userEdited,
  );

  factory Book.fromMap(Map<String, Object?> m) => Book(
    id: asInt(m['id']),
    externalId: asString(m['external_id']),
    courseId: asInt(m['course_id']),
    title: m['title'] as String,
    author: asString(m['author']),
    isbn: asString(m['isbn']),
    edition: asString(m['edition']),
    publisher: asString(m['publisher']),
    year: asInt(m['year']),
    format: BookFormat.fromKey(m['format'] as String?),
    ownership: BookOwnership.fromKey(m['ownership_status'] as String?),
    physicalLocation: asString(m['physical_location']),
    notes: asString(m['notes']),
    filePath: asString(m['file_path']),
    expectedFileName: asString(m['expected_file_name']),
    language: asString(m['language']),
    required: asBool(m['required']),
    storedFile: asString(m['stored_file']),
    lastPage: asInt(m['last_page']),
    pageCount: asInt(m['page_count']),
    lastOpenedAt: DateTime.tryParse(asString(m['last_opened_at']) ?? ''),
    catalogChoice: CatalogChoice.fromKey(asString(m['catalog_choice'])),
    userEdited: asBool(m['user_edited']) ?? false,
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'external_id': externalId,
    'course_id': courseId,
    'title': title,
    'author': author,
    'isbn': isbn,
    'edition': edition,
    'publisher': publisher,
    'year': year,
    'format': format.key,
    'ownership_status': ownership.key,
    'physical_location': physicalLocation,
    'notes': notes,
    'file_path': filePath,
    'expected_file_name': expectedFileName,
    'language': language,
    'required': required == null ? null : (required! ? 1 : 0),
    'stored_file': storedFile,
    'last_page': lastPage,
    'page_count': pageCount,
    'last_opened_at': lastOpenedAt?.toIso8601String(),
    'catalog_choice': catalogChoice?.key,
    'user_edited': userEdited ? 1 : 0,
  };
}

/// Scelta dello studente su un libro proposto dal catalogo.
enum CatalogChoice {
  kept('kept', 'Tenuto'),
  removed('removed', 'Rimosso');

  const CatalogChoice(this.key, this.label);
  final String key;
  final String label;

  static CatalogChoice? fromKey(String? k) {
    for (final v in values) {
      if (v.key == k) return v;
    }
    return null;
  }
}

class StudyMaterial {
  const StudyMaterial({
    this.id,
    this.externalId,
    this.courseId,
    required this.title,
    this.localPath,
    this.kind = MaterialKind.other,
    this.academicYear,
    this.author,
    this.source,
    this.notes,
    this.storedFile,
    this.lastPage,
    this.pageCount,
  });

  final int? id;
  final String? externalId;
  final int? courseId;
  final String title;
  final String? localPath;

  /// File copiato nella cartella materiali dell'app e posizione di lettura.
  final String? storedFile;
  final int? lastPage;
  final int? pageCount;
  final MaterialKind kind;
  final String? academicYear;
  final String? author;
  final String? source;
  final String? notes;

  factory StudyMaterial.fromMap(Map<String, Object?> m) => StudyMaterial(
    id: asInt(m['id']),
    externalId: asString(m['external_id']),
    courseId: asInt(m['course_id']),
    title: m['title'] as String,
    localPath: asString(m['local_path']),
    kind: MaterialKind.fromKey(m['kind'] as String?),
    academicYear: asString(m['academic_year']),
    author: asString(m['author']),
    source: asString(m['source']),
    notes: asString(m['notes']),
    storedFile: asString(m['stored_file']),
    lastPage: asInt(m['last_page']),
    pageCount: asInt(m['page_count']),
  );

  StudyMaterial withFile({String? Function()? storedFile}) => StudyMaterial(
    id: id,
    externalId: externalId,
    courseId: courseId,
    title: title,
    localPath: localPath,
    kind: kind,
    academicYear: academicYear,
    author: author,
    source: source,
    notes: notes,
    storedFile: storedFile == null ? this.storedFile : storedFile(),
    lastPage: lastPage,
    pageCount: pageCount,
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'external_id': externalId,
    'course_id': courseId,
    'title': title,
    'local_path': localPath,
    'stored_file': storedFile,
    'last_page': lastPage,
    'page_count': pageCount,
    'kind': kind.key,
    'academic_year': academicYear,
    'author': author,
    'source': source,
    'notes': notes,
  };
}
