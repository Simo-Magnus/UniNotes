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

  /// Titolo dell'evento («Esame: Analisi I · Scritto»).
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
  /// Una data al limite di `DateTime` (anno 275760) con un'ora non si può
  /// scrivere: vale la mezzanotte, senza lanciare.
  DateTime get start {
    final t = time;
    if (t == null) return date;
    final parts = t.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    try {
      return DateTime(date.year, date.month, date.day, h, m);
    } on ArgumentError {
      return date;
    }
  }

  /// Fine locale: 2 ore dopo l'inizio, o il giorno dopo se è di un giorno
  /// intero (come nel file .ics). Al limite di `DateTime` non c'è un dopo:
  /// la fine coincide con l'inizio.
  DateTime get end {
    try {
      return time == null
          ? DateTime(date.year, date.month, date.day + 1)
          : start.add(const Duration(hours: 2));
    } on ArgumentError {
      return start;
    }
  }

  /// Inizio come istante (UTC) di una prova con l'ora: l'ora della prova è
  /// quella dell'ateneo (Europe/Rome), uguale per chi ha il telefono in un
  /// altro fuso. È l'istante che il .ics dichiara con `TZID=Europe/Rome`.
  DateTime get startInstant => romeWallToUtc(start) ?? start.toUtc();

  /// Fine come istante (UTC): 2 ore dopo [startInstant].
  DateTime get endInstant {
    try {
      return startInstant.add(const Duration(hours: 2));
    } on ArgumentError {
      return startInstant;
    }
  }

  /// Giornata intera: mezzanotte UTC del giorno (come vuole il Calendar
  /// Provider di Android e Outlook).
  DateTime get dayStartUtc => DateTime.utc(date.year, date.month, date.day);

  /// Giornata intera: mezzanotte UTC del giorno dopo (al limite di
  /// `DateTime`, il giorno stesso).
  DateTime get dayEndUtc {
    try {
      return DateTime.utc(date.year, date.month, date.day + 1);
    } on ArgumentError {
      return dayStartUtc;
    }
  }

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

/// Istante (UTC) dell'ora «a muro» italiana [wall] (anno, mese, giorno, ore e
/// minuti; il fuso di [wall] non conta): Europe/Rome è UTC+1, e UTC+2 dalle
/// 01:00 UTC dell'ultima domenica di marzo alle 01:00 UTC dell'ultima di
/// ottobre (regola dell'Unione Europea). Un'ora che non esiste (le 02:30 del
/// passaggio all'ora legale) vale un'ora dopo, una ripetuta (le 02:30 del
/// ritorno all'ora solare) la prima volta. null se la data è fuori
/// dall'intervallo di `DateTime`.
DateTime? romeWallToUtc(DateTime wall) {
  try {
    final w = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    int lastSunday(int month) =>
        31 - (DateTime.utc(w.year, month, 31).weekday % 7);
    final summerAsWall = w.subtract(const Duration(hours: 2));
    final summer =
        !summerAsWall.isBefore(DateTime.utc(w.year, 3, lastSunday(3), 1)) &&
        summerAsWall.isBefore(DateTime.utc(w.year, 10, lastSunday(10), 1));
    return w.subtract(Duration(hours: summer ? 2 : 1));
  } on ArgumentError {
    return null;
  }
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
        title: '${kind.label}: $course$extra',
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
        title: 'Inizio sessione d\'esame: ${s.nome}',
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
/// l'orario, 24 ore prima. Con [offsetHours] anche N ore prima (solo per le
/// prove con l'orario: `days` 0, `hours` N). Le sessioni hanno un solo
/// avviso, il giorno prima alle 9:00. Ordinati dal più lontano, senza
/// doppioni.
List<({int days, int hours, DateTime at})> reminderTimes(
  AgendaItem item,
  List<int> offsetDays, [
  List<int> offsetHours = const [],
]) {
  final session = item.kind == AgendaKind.session;
  final days = session
      ? const [1]
      : ({...offsetDays.where((d) => d > 0)}.toList()..sort((a, b) => b - a));
  final hours = session || item.time == null
      ? const <int>[]
      : ({...offsetHours.where((h) => h > 0 && h < 24)}.toList()
          ..sort((a, b) => b - a));
  final out = <({int days, int hours, DateTime at})>[];
  final seen = <DateTime>{};
  for (final d in days) {
    final at = d == 1 && item.time != null
        ? item.start.subtract(const Duration(hours: 24))
        : DateTime(item.date.year, item.date.month, item.date.day - d, 9);
    if (seen.add(at)) out.add((days: d, hours: 0, at: at));
  }
  for (final h in hours) {
    final at = item.start.subtract(Duration(hours: h));
    if (seen.add(at)) out.add((days: 0, hours: h, at: at));
  }
  return out;
}

/// Promemoria dell'evento nel calendario (minuti prima dell'inizio), agli
/// stessi istanti delle notifiche dell'app.
List<int> calendarReminderMinutes(
  AgendaItem item,
  List<int> offsetDays, [
  List<int> offsetHours = const [],
]) => [
  for (final r in reminderTimes(item, offsetDays, offsetHours))
    item.start.difference(r.at).inMinutes,
];
