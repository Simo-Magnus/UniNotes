import '../../models/book.dart';
import '../../models/course.dart';
import '../services/app_services.dart';
import 'catalog_datapack.dart';
import 'catalog_models.dart';

/// Lingua dell'esame di un insegnamento offerto anche in inglese (es.
/// PoliTO: «Analisi matematica I» / «Mathematical analysis I»). Il database
/// importa la versione italiana; lo studente può passare a quella inglese
/// dalla modifica del corso, che cambia nome, codice, docenti, pagina e libri.
class TeachingLanguage {
  const TeachingLanguage(this.ateneoId, this.teaching);

  final String ateneoId;

  /// Insegnamento del catalogo (versione italiana con le sue varianti).
  final Insegnamento teaching;

  VarianteLingua? get english =>
      teaching.varianti.where((v) => v.lingua == 'en').firstOrNull;

  bool get hasEnglish => english != null;

  /// Il corso usa la versione inglese (riconosciuta dal codice).
  bool isEnglish(Course c) =>
      english?.codice != null && c.code == english!.codice;

  /// Insegnamento del catalogo da cui è stato importato [c] (null se inserito
  /// a mano o se il catalogo non è disponibile).
  static Future<TeachingLanguage?> of(AppServices s, Course c) async {
    final ext = c.externalId;
    final degree = c.degreeId;
    if (ext == null || degree == null) return null;
    final m = RegExp(r'^([^:]+):course:(.+)$').firstMatch(ext);
    if (m == null) return null;
    final ateneo = m.group(1)!;
    final insId = m.group(2)!;
    try {
      final r = await s.catalog.corsiAteneo(ateneo, remote: false);
      final corso = r?.data.corso(degree);
      for (final i in corso?.insegnamenti ?? const <Insegnamento>[]) {
        if (i.id == insId) return TeachingLanguage(ateneo, i);
      }
    } catch (_) {}
    return null;
  }

  /// Campi del corso nella lingua scelta.
  Course apply(Course c, {required bool english}) {
    final v = this.english;
    if (english && v != null) {
      return c.copyWith(
        name: v.nome ?? c.name,
        code: v.codice ?? c.code,
        // senza docenti nella versione inglese: campo vuoto, non quelli italiani
        teacher: v.docenti.join(', '),
        syllabusUrl: v.url ?? c.syllabusUrl,
      );
    }
    final t = teaching;
    return c.copyWith(
      name: t.nome,
      code: t.codice,
      teacher: t.docenti.join(', '),
      syllabusUrl: t.url ?? c.syllabusUrl,
    );
  }

  /// Sostituisce i libri del catalogo con quelli della versione scelta. I
  /// libri che lo studente ha già usato (posseduti, con il file, modificati)
  /// restano.
  Future<void> replaceBooks(
    AppServices s,
    Course course, {
    required bool english,
  }) async {
    final id = course.id;
    if (id == null) return;
    final prefix = '$ateneoId:book:${teaching.id}:';
    for (final b in await s.books.all(courseId: id)) {
      final fromCatalog = b.externalId?.startsWith(prefix) ?? false;
      final untouched =
          !b.userEdited &&
          b.storedFile == null &&
          b.filePath == null &&
          b.ownership.key == 'wanted';
      if (fromCatalog && untouched) await s.books.delete(b.id!);
    }
    final libri = english
        ? (this.english?.libri ?? const <LibroCatalogo>[])
        : teaching.libri;
    final presenti = {
      for (final b in await s.books.all(courseId: id)) ?b.externalId,
    };
    for (final l in libri) {
      final ext = CatalogIds.book(ateneoId, teaching.id, l);
      if (presenti.contains(ext)) continue;
      await s.books.insert(
        Book(
          externalId: ext,
          courseId: id,
          title: l.titolo,
          author: l.autori,
          isbn: l.isbn,
          edition: l.edizione,
          publisher: l.editore,
          year: l.anno,
          required: l.obbligatorio,
          language: l.lingua,
          notes: l.note,
        ),
      );
    }
  }
}
