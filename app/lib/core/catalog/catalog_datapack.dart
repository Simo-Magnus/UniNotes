/// Conversione catalogo pubblico → data pack (docs/datapack_format.md), così
/// il piano di studi entra nelle tabelle esistenti (corsi, esami, libri)
/// passando dal [DataPackImporter], che non sovrascrive mai i dati personali.
library;

import '../../utils/parse.dart';
import '../theme/university_colors.dart';
import 'catalog_models.dart';
import 'catalog_search.dart';

/// "Analisi Matematica I" → "analisi-matematica-i" (max [max] caratteri).
String slugify(String s, {int max = 48}) {
  final slug = normalizeText(s).replaceAll(' ', '-');
  return slug.length <= max ? slug : slug.substring(0, max);
}

/// Id esterni stabili degli elementi importati dal catalogo.
abstract final class CatalogIds {
  static String course(String ateneoId, String insegnamentoId) =>
      '$ateneoId:course:$insegnamentoId';

  static String finalExam(String ateneoId, String insegnamentoId) =>
      '$ateneoId:exam:$insegnamentoId';

  static String book(String ateneoId, String insegnamentoId, LibroCatalogo l) {
    final isbn = l.isbn?.replaceAll(RegExp(r'[^0-9Xx]'), '');
    final key = (isbn != null && isbn.length >= 10)
        ? isbn
        : slugify(l.titolo, max: 40);
    return '$ateneoId:book:$insegnamentoId:$key';
  }

  static String midterm(String ateneoId, String insegnamentoId, String key) =>
      '$ateneoId:midterm:$insegnamentoId:$key';

  static String appello(String ateneoId, String insegnamentoId, String key) =>
      '$ateneoId:appello:$insegnamentoId:$key';

  /// Corso di laurea inserito a mano («Aggiungi corso»).
  static String manualDegree(String ateneoId, String nome) =>
      'manuale:$ateneoId:${slugify(nome)}';

  /// Fonte degli eventi (appelli) importati dal catalogo di un ateneo.
  static String source(String ateneoId) => 'catalogo:$ateneoId';
}

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Map<String, Object?> _university(Ateneo a) => {
  'id': a.id,
  'name': a.nome,
  'shortName': a.nomeBreve,
  'color': _hex(UniversityColors.deterministic(a.id).toARGB32()),
  'website': a.sito,
};

/// Data pack con l'ateneo, il corso di laurea e **tutti** gli insegnamenti
/// del piano (tutti gli anni), con libri, esame finale, prove in itinere e
/// appelli noti. Gli insegnamenti senza dati restano presenti con
/// `booksStatus`/`examsStatus` = "da_aggiungere".
Map<String, Object?> catalogToDataPack({
  required Ateneo ateneo,
  required CorsoDettaglio corso,
  String? aggiornatoIl,
  DateTime? now,
}) {
  final a = ateneo.id;
  final source = CatalogIds.source(a);
  final courses = <Map<String, Object?>>[];
  final exams = <Map<String, Object?>>[];
  final books = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];

  for (final ins in corso.insegnamenti) {
    final courseExt = CatalogIds.course(a, ins.id);
    final appelli = [
      for (final e in ins.esami)
        if (!e.provaInItinere) e,
    ];
    courses.add({
      'externalId': courseExt,
      'universityId': a,
      'degreeId': corso.id,
      'name': ins.nome,
      'code': ins.codice,
      'teacher': ins.docenti.isEmpty ? null : ins.docenti.join(', '),
      'year': ins.anno,
      'semester': ins.periodo,
      'cfu': ins.cfu,
      'examMode':
          ins.modalitaEsame ??
          appelli.map((e) => e.modalita).nonNulls.firstOrNull,
      'source': ins.fonte ?? ins.url ?? corso.fonte,
      'updatedAt': aggiornatoIl,
      'booksStatus': ins.statoLibri,
      'examsStatus': ins.statoEsami,
      'syllabusUrl': ins.url,
      'ssd': ins.ssd,
      'mandatory': ins.obbligatorio,
      'curriculum': ins.curriculum,
    });

    // Un esame finale per insegnamento: la data la sceglie lo studente
    // (prenotando un appello), i CFU arrivano dal corso.
    exams.add({
      'externalId': CatalogIds.finalExam(a, ins.id),
      'courseExternalId': courseExt,
      'kind': 'final',
      'examType':
          ins.modalitaEsame ??
          appelli.map((e) => e.modalita).nonNulls.firstOrNull,
      'source': source,
    });

    var m = 0;
    final midtermKeys = <String>{};
    for (final e in ins.esami) {
      if (e.provaInItinere) {
        m++;
        // data e ora: due prove lo stesso giorno (es. 08:30 e 11:00) restano
        // distinte
        var key = e.data == null
            ? '$m'
            : (e.ora == null ? e.data! : '${e.data}T${e.ora}');
        if (!midtermKeys.add(key)) key = '$key-$m';
        exams.add({
          'externalId': CatalogIds.midterm(a, ins.id, key),
          'courseExternalId': courseExt,
          'kind': 'midterm',
          'title': e.titolo ?? 'Prova in itinere',
          'date': e.data,
          'time': e.ora,
          'location': e.luogo,
          'examType': e.modalita,
          'notes': e.note,
          'source': e.fonte ?? source,
        });
        continue;
      }
      final day = e.giorno;
      if (day == null) continue;
      final time = e.ora;
      final start = time == null
          ? '${isoDate(day)}T00:00:00'
          : '${isoDate(day)}T$time:00';
      events.add({
        'externalId': CatalogIds.appello(
          a,
          ins.id,
          '${isoDate(day)}${time == null ? '' : '-${time.replaceAll(':', '')}'}',
        ),
        'type': 'exam_window',
        'courseExternalId': courseExt,
        'universityId': a,
        'title': '${e.titolo ?? 'Appello'} · ${ins.nome}',
        'start': start,
        'end': time == null
            ? '${isoDate(DateTime(day.year, day.month, day.day + 1))}T00:00:00'
            : null,
        'allDay': time == null,
        'room': e.luogo,
        'notes': e.note,
        'source': source,
      });
    }

    for (final l in ins.libri) {
      books.add({
        'externalId': CatalogIds.book(a, ins.id, l),
        'courseExternalId': courseExt,
        'title': l.titolo,
        'author': l.autori,
        'isbn': l.isbn,
        'edition': l.edizione,
        'publisher': l.editore,
        'year': l.anno,
        'required': l.obbligatorio,
        'language': l.lingua,
        // Il titolo dei libri estratti dai syllabus può essere l'intera
        // citazione: se è diverso, la citazione originale va nelle note.
        'notes':
            l.note ??
            (l.citazione != null && l.citazione != l.titolo
                ? 'Dal syllabus: ${l.citazione}'
                : null),
      });
    }
  }

  return {
    'format': 'university-manager-datapack',
    'version': 1,
    'generatedAt': isoLocal(now ?? DateTime.now()),
    'source': source,
    'replaceEventsOfSameSource': true,
    'universities': [_university(ateneo)],
    'degrees': [
      {
        'id': corso.id,
        'universityId': a,
        'name': corso.nome,
        'classCode': corso.classe,
        'source': corso.url ?? corso.fonte,
        'updatedAt': aggiornatoIl,
      },
    ],
    'courses': courses,
    'exams': exams,
    'books': books,
    'events': events,
  };
}

/// Data pack minimo per un corso senza insegnamenti nel catalogo (inserito
/// a mano o file dell'ateneo non ancora disponibile): ateneo e corso di
/// laurea, gli insegnamenti li aggiunge lo studente.
Map<String, Object?> manualDegreeDataPack({
  required Ateneo ateneo,
  required String degreeId,
  required String nome,
  String? classe,
  DateTime? now,
}) => {
  'format': 'university-manager-datapack',
  'version': 1,
  'generatedAt': isoLocal(now ?? DateTime.now()),
  'source': 'manuale',
  'universities': [_university(ateneo)],
  'degrees': [
    {
      'id': degreeId,
      'universityId': ateneo.id,
      'name': nome,
      'classCode': classe,
    },
  ],
};
