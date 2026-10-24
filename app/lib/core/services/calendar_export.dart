import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/exam.dart';
import '../academic/plan_scope.dart';
import '../../features/notes/notes_store.dart';
import '../constants/enums.dart';
import 'app_services.dart';
import 'external_launcher.dart';

/// Impostazione «Aggiungi esami, prove in itinere ed esoneri al calendario».
const kCalendarExamsKey = 'calendar_exams';

/// Esami, prove in itinere ed esoneri nel calendario del dispositivo con un
/// file iCalendar (.ics): lo apre l'app di calendario del sistema (Outlook,
/// Calendario di Windows/Mac/iPhone, Google Calendar…), che lo importa.
/// Ogni prova ha un UID fisso: reimportandola il calendario la aggiorna
/// invece di duplicarla.
class CalendarExport {
  CalendarExport(this._s);
  final AppServices _s;

  Future<bool> enabled() async =>
      (await _s.settings.get(kCalendarExamsKey)) == '1';
  Future<void> setEnabled(bool v) =>
      _s.settings.set(kCalendarExamsKey, v ? '1' : null);

  /// Prove da sostenere con una data, nel piano dello studente.
  /// Prove ancora da sostenere con una data, dei soli insegnamenti del
  /// corso di laurea attuale (vedi [PlanScope.inPath]).
  Future<List<Exam>> pendingWithDate() async {
    final courses = await _s.courses.mapById();
    final scope = PlanScope(profile: await _s.profiles.load());
    return [
      for (final e in await _s.exams.all())
        if (e.date != null &&
            e.status.isPending &&
            (courses[e.courseId] == null || scope.inPath(courses[e.courseId]!)))
          e,
    ];
  }

  /// Scrive il file .ics con [exams] e lo apre nel calendario del sistema.
  /// Restituisce l'esito dell'apertura.
  Future<LaunchResult> open(List<Exam> exams, {String name = 'esami'}) async {
    if (exams.isEmpty) {
      return const LaunchResult.error(
        'Nessuna prova con una data da aggiungere.',
      );
    }
    final courses = {for (final c in await _s.courses.all()) c.id: c};
    final ics = buildIcs([
      for (final e in exams)
        (exam: e, course: courses[e.courseId]?.name ?? 'Esame'),
    ]);
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'calendario'),
    );
    await dir.create(recursive: true);
    // nome del file valido su ogni sistema e non troppo lungo (es. «Prova
    // 1/2», «Esame: scritto», un titolo arrivato da un'altra versione)
    final safe = NotesStore.safeName(name);
    final f = File(p.join(dir.path, 'UniNotes - $safe.ics'));
    await f.writeAsString(ics);
    return ExternalLauncher.openPath(f.path);
  }
}

/// Testo iCalendar (RFC 5545) delle prove: evento di 2 ore se c'è l'ora,
/// altrimenti di un giorno intero; promemoria il giorno prima. Orari nel fuso
/// italiano (Europe/Rome, con la definizione VTIMEZONE), righe ripiegate a 75
/// byte, SEQUENCE crescente perché un'esportazione successiva aggiorni
/// l'evento già importato.
String buildIcs(List<({Exam exam, String course})> items, {DateTime? now}) {
  String two(int v) => v.toString().padLeft(2, '0');
  // anno sempre di 4 cifre (RFC 5545), anche per date lontane
  String date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${two(d.month)}${two(d.day)}';
  String dateTime(DateTime d) => '${date(d)}T${two(d.hour)}${two(d.minute)}00';
  String esc(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll(';', r'\;')
      .replaceAll(',', r'\,')
      .replaceAll('\r\n', r'\n')
      .replaceAll('\r', r'\n')
      .replaceAll('\n', r'\n');
  final at = now ?? DateTime.now();
  final stamp = at.toUtc();
  // cresce a ogni esportazione (minuti dal 2026)
  final sequence = at
      .difference(DateTime.utc(2026))
      .inMinutes
      .clamp(0, 1 << 30);
  final b = StringBuffer();
  // Righe lunghe ripiegate a 75 byte (continua con uno spazio), senza
  // spezzare i caratteri UTF-8.
  void line(String text) {
    final bytes = utf8.encode(text);
    if (bytes.length <= 75) {
      b.write('$text\r\n');
      return;
    }
    var start = 0;
    var first = true;
    while (start < bytes.length) {
      final limit = first ? 75 : 74;
      var end = (start + limit).clamp(0, bytes.length);
      // non dentro un carattere multibyte (byte di continuazione 10xxxxxx)
      while (end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      final chunk = utf8.decode(bytes.sublist(start, end));
      b.write(first ? '$chunk\r\n' : ' $chunk\r\n');
      first = false;
      start = end;
    }
  }

  line('BEGIN:VCALENDAR');
  line('VERSION:2.0');
  line('PRODID:-//UniNotes//Esami//IT');
  line('CALSCALE:GREGORIAN');
  for (final l in const [
    'BEGIN:VTIMEZONE',
    'TZID:Europe/Rome',
    'BEGIN:DAYLIGHT',
    'TZOFFSETFROM:+0100',
    'TZOFFSETTO:+0200',
    'TZNAME:CEST',
    'DTSTART:19700329T020000',
    'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU',
    'END:DAYLIGHT',
    'BEGIN:STANDARD',
    'TZOFFSETFROM:+0200',
    'TZOFFSETTO:+0100',
    'TZNAME:CET',
    'DTSTART:19701025T030000',
    'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU',
    'END:STANDARD',
    'END:VTIMEZONE',
  ]) {
    line(l);
  }
  for (final (:exam, :course) in items) {
    final d = exam.date;
    if (d == null) continue;
    final kind = exam.kind == ExamKind.midterm
        ? 'Prova in itinere/esonero'
        : 'Esame';
    final title =
        '$kind · $course'
        '${exam.title != null && exam.title!.isNotEmpty ? ' · ${exam.title}' : ''}';
    line('BEGIN:VEVENT');
    // UID invariato dalle prime versioni: i calendari aggiornano, non
    // duplicano, gli esami già importati
    line(
      'UID:university-notes-exam-${exam.id ?? '${course.hashCode}-${date(d)}'}@universitynotes',
    );
    line('DTSTAMP:${dateTime(stamp)}Z');
    line('LAST-MODIFIED:${dateTime(stamp)}Z');
    line('SEQUENCE:$sequence');
    final start = exam.dateTime;
    if (exam.time != null && start != null) {
      // Ora «a muro» dell'ateneo, scritta con i suoi numeri (mai convertita
      // nel fuso del telefono) e dichiarata Europe/Rome; la fine si calcola
      // sugli stessi numeri, non con l'orologio del dispositivo (che in un
      // altro fuso avrebbe il cambio d'ora in un altro momento).
      DateTime end;
      try {
        end = DateTime.utc(
          start.year,
          start.month,
          start.day,
          start.hour,
          start.minute,
        ).add(const Duration(hours: 2));
      } on ArgumentError {
        end = start;
      }
      line('DTSTART;TZID=Europe/Rome:${dateTime(start)}');
      line('DTEND;TZID=Europe/Rome:${dateTime(end)}');
    } else {
      DateTime next;
      try {
        next = DateTime.utc(d.year, d.month, d.day + 1);
      } on ArgumentError {
        // ultimo giorno rappresentabile: non c'è un giorno dopo
        next = d;
      }
      line('DTSTART;VALUE=DATE:${date(d)}');
      line('DTEND;VALUE=DATE:${date(next)}');
    }
    line('SUMMARY:${esc(title)}');
    if (exam.location != null) line('LOCATION:${esc(exam.location!)}');
    final notes = [
      if (exam.topics != null) 'Argomenti: ${exam.topics}',
      if (exam.notes != null) exam.notes!,
    ].join('\n');
    if (notes.isNotEmpty) line('DESCRIPTION:${esc(notes)}');
    line('BEGIN:VALARM');
    line('TRIGGER:-P1D');
    line('ACTION:DISPLAY');
    line('DESCRIPTION:${esc(title)}');
    line('END:VALARM');
    line('END:VEVENT');
  }
  line('END:VCALENDAR');
  return b.toString();
}
