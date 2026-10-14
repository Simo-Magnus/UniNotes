import '../../models/exam.dart';
import '../catalog/catalog_models.dart';
import '../constants/enums.dart';

/// Cosa annuncia un elemento dell'agenda (notifiche e calendario).
enum AgendaKind {
  exam('Esame'),
  midterm('Prova in itinere/esonero'),
  session('Inizio sessione');

  const AgendaKind(this.label);
  final String label;
}

/// Una data da ricordare: una prova ancora da sostenere del corso attuale
/// o l'inizio di una sessione d'esame dell'ateneo. È la stessa unità per le
/// notifiche dell'app e per gli eventi del calendario di sistema, con una
/// chiave stabile ([key]) che non cambia se si modifica la prova.
class AgendaItem {
  const AgendaItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.subject,
    required this.date,
    this.time,
    this.location,
    this.notes,
    this.examId,
    this.sessionEnd,
  });

  /// Chiave stabile: `esame-<id>` o `sessione-<data>-<nome>`.
  final String key;
  final AgendaKind kind;

  /// Titolo dell'evento («Esame · Analisi I · Scritto»).
  final String title;

  /// Insegnamento o nome della sessione («Analisi I», «Sessione invernale»).
  final String subject;

  /// Solo la data (00:00 locali).
  final DateTime date;

  /// Ora d'inizio "HH:mm" (null = giornata intera).
  final String? time;
  final String? location;
  final String? notes;
  final int? examId;

  /// Ultimo giorno della sessione (solo per [AgendaKind.session]).
  final DateTime? sessionEnd;

  bool get allDay => time == null;

  /// Inizio locale: data e ora, o mezzanotte se è di un giorno intero.
  DateTime get start {
    final t = time;
    if (t == null) return date;
    final parts = t.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(date.year, date.month, date.day, h, m);
  }

  /// Fine locale: 2 ore dopo l'inizio, o il giorno dopo se è di un giorno
  /// intero (come nel file .ics).
  DateTime get end => time == null
      ? DateTime(date.year, date.month, date.day + 1)
      : start.add(const Duration(hours: 2));

  /// Impronta dei dati scritti nel calendario: se non cambia, l'evento non
  /// si riscrive.
  String signature(List<int> reminderMinutes) => [
    title,
    _ymd(date),
    time ?? '',
    location ?? '',
    notes ?? '',
    reminderMinutes.join(','),
  ].join('|');

  @override
  String toString() => 'AgendaItem($key, ${_ymd(date)} ${time ?? ''})';
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}'
    '${d.day.toString().padLeft(2, '0')}';

/// Chiave stabile di una prova.
String examAgendaKey(int examId) => 'esame-$examId';

/// Chiave stabile dell'inizio di una sessione: data e nome, così due
/// sessioni con lo stesso nome in anni diversi restano distinte.
String sessionAgendaKey(SessioneEsami s) {
  final slug = s.nome
      .toLowerCase()
      .replaceAll(RegExp(r'[àáâä]'), 'a')
      .replaceAll(RegExp(r'[èéêë]'), 'e')
      .replaceAll(RegExp(r'[ìíîï]'), 'i')
      .replaceAll(RegExp(r'[òóôö]'), 'o')
      .replaceAll(RegExp(r'[ùúûü]'), 'u')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'sessione-${_ymd(s.inizio)}-$slug';
}

/// Prove ancora da sostenere con una data, dal giorno [now] in poi, e
/// inizi delle sessioni d'esame futuri del corso dello studente.
///
/// [exams] sono già filtrate sul corso attuale (vedi
/// CalendarExport.pendingWithDate); [courseNames]: id insegnamento → nome.
List<AgendaItem> buildAgenda({
  required Iterable<Exam> exams,
  required Map<int, String> courseNames,
  CalendarioSessioni? sessions,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final out = <AgendaItem>[];
  for (final e in exams) {
    final d = e.date;
    final id = e.id;
    if (d == null || id == null || !e.status.isPending) continue;
    final day = DateTime(d.year, d.month, d.day);
    if (day.isBefore(today)) continue;
    final midterm = e.kind == ExamKind.midterm;
    final course = courseNames[e.courseId] ?? 'Esame';
    final extra = e.title != null && e.title!.trim().isNotEmpty
        ? ' · ${e.title!.trim()}'
        : '';
    final kind = midterm ? AgendaKind.midterm : AgendaKind.exam;
    out.add(
      AgendaItem(
        key: examAgendaKey(id),
        kind: kind,
        title: '${kind.label} · $course$extra',
        subject: course,
        date: day,
        time: _validTime(e.time),
        location: e.location,
        notes: [
          if (e.topics != null && e.topics!.trim().isNotEmpty)
            'Argomenti: ${e.topics!.trim()}',
          if (e.notes != null && e.notes!.trim().isNotEmpty) e.notes!.trim(),
        ].join('\n'),
        examId: id,
      ),
    );
  }
  for (final s in sessions?.sessioni ?? const <SessioneEsami>[]) {
    final day = DateTime(s.inizio.year, s.inizio.month, s.inizio.day);
    if (day.isBefore(today)) continue;
    out.add(
      AgendaItem(
        key: sessionAgendaKey(s),
        kind: AgendaKind.session,
        title: 'Inizio sessione d\'esame · ${s.nome}',
        subject: s.nome,
        date: day,
        notes: [
          'Dal ${_dm(s.inizio)} al ${_dm(s.fine)}.',
          if (s.note != null && s.note!.trim().isNotEmpty) s.note!.trim(),
        ].join('\n'),
        sessionEnd: s.fine,
      ),
    );
  }
  out.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out;
}

String _dm(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}'
    '/${d.year}';

/// "9:30" → "09:30"; orari non validi → null (giornata intera).
String? _validTime(String? t) {
  if (t == null) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(t.trim());
  if (m == null) return null;
  final h = int.parse(m[1]!);
  final min = int.parse(m[2]!);
  if (h > 23 || min > 59) return null;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

/// Istanti (locali) degli avvisi di [item] con gli anticipi [offsetDays]:
/// alle 9:00 del giorno N giorni prima; per il giorno prima di una prova con
/// l'orario, 24 ore prima. Le sessioni hanno un solo avviso, il giorno prima
/// alle 9:00. Ordinati dal più lontano, senza doppioni.
List<({int days, DateTime at})> reminderTimes(
  AgendaItem item,
  List<int> offsetDays,
) {
  final days = item.kind == AgendaKind.session
      ? const [1]
      : ({...offsetDays.where((d) => d > 0)}.toList()..sort((a, b) => b - a));
  final out = <({int days, DateTime at})>[];
  final seen = <DateTime>{};
  for (final d in days) {
    final at = d == 1 && item.time != null
        ? item.start.subtract(const Duration(hours: 24))
        : DateTime(item.date.year, item.date.month, item.date.day - d, 9);
    if (seen.add(at)) out.add((days: d, at: at));
  }
  return out;
}

/// Promemoria dell'evento nel calendario (minuti prima dell'inizio), agli
/// stessi istanti delle notifiche dell'app.
List<int> calendarReminderMinutes(AgendaItem item, List<int> offsetDays) => [
  for (final r in reminderTimes(item, offsetDays))
    item.start.difference(r.at).inMinutes,
];
