import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/calendar_entry.dart';

/// Intervallo semiaperto [start, end).
class DateRange {
  const DateRange(this.start, this.end);
  final DateTime start;
  final DateTime end;

  List<DateTime> get days => [
    for (var d = start; d.isBefore(end); d = addDays(d, 1)) d,
  ];
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Somma giorni di calendario (indipendente dall'ora legale).
DateTime addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days, d.hour, d.minute, d.second);

DateTime startOfWeek(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - DateTime.monday));

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Giorni di calendario tra due date (b - a), ignorando l'ora.
int daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String formatTime(DateTime d) => DateFormat('HH:mm').format(d);

String _two(int n) => n.toString().padLeft(2, '0');

const _weekdayNames = [
  'Lunedì',
  'Martedì',
  'Mercoledì',
  'Giovedì',
  'Venerdì',
  'Sabato',
  'Domenica',
];
const _weekdayShort = ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'];

/// "05/10/2026": il formato unico delle date nell'app (DD/MM/YYYY).
String formatDmy(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';

/// "05/10/2026 08:30".
String formatDmyHm(DateTime d) => '${formatDmy(d)} ${formatTime(d)}';

/// "Lunedì 05/10/2026".
String formatWeekdayDmy(DateTime d) =>
    '${_weekdayNames[d.weekday - 1]} ${formatDmy(d)}';

/// "lun 05/10/2026".
String formatShortWeekdayDmy(DateTime d) =>
    '${_weekdayShort[d.weekday - 1]} ${formatDmy(d)}';

/// "05/10/2026" da una data "YYYY-MM-DD" o "YYYY.MM.DD" (es. la versione del
/// database); la stringa originale se non è una data.
String formatDmyString(String s) {
  final m = RegExp(r'^(\d{4})[-.](\d{2})[-.](\d{2})').firstMatch(s);
  return m == null ? s : '${m[3]}/${m[2]}/${m[1]}';
}

/// "08:30–10:00", oppure "Tutto il giorno".
String formatEntryTime(CalendarEntry e) {
  if (e.allDay) return 'Tutto il giorno';
  return '${formatTime(e.start)}–${formatTime(e.end)}';
}

/// "Lunedì 5 ottobre 2026 · 08:30–10:00" (gestisce più giorni).
String formatEntryWhen(CalendarEntry e) {
  if (e.allDay) {
    final lastDay = addDays(dateOnly(e.end), -1);
    if (!lastDay.isAfter(dateOnly(e.start))) {
      return '${formatWeekdayDmy(e.start)} · tutto il giorno';
    }
    return '${capitalize(formatShortWeekdayDmy(e.start))} – '
        '${formatShortWeekdayDmy(lastDay)} · tutto il giorno';
  }
  if (isSameDay(e.start, e.end) ||
      (e.end.hour == 0 &&
          e.end.minute == 0 &&
          daysBetween(e.start, e.end) == 1)) {
    return '${formatWeekdayDmy(e.start)} · ${formatEntryTime(e)}';
  }
  return '${capitalize(formatShortWeekdayDmy(e.start))} ${formatTime(e.start)} – '
      '${formatShortWeekdayDmy(e.end)} ${formatTime(e.end)}';
}

/// true se l'elemento cade (anche in parte) nel giorno [day].
bool entryTouchesDay(CalendarEntry e, DateTime day) {
  final s = dateOnly(day);
  final next = addDays(s, 1);
  if (e.end.isAtSameMomentAs(e.start)) {
    return !e.start.isBefore(s) && e.start.isBefore(next);
  }
  return e.start.isBefore(next) && e.end.isAfter(s);
}

/// Elementi da mostrare nella fascia "tutto il giorno" (giornate intere o
/// eventi lunghi 24 ore o più).
bool isAllDayLike(CalendarEntry e) =>
    e.allDay || e.end.difference(e.start) >= const Duration(hours: 24);

/// "oggi", "domani", "tra 5 giorni", "ieri".
String countdownLabel(DateTime target, {DateTime? now}) {
  final n = daysBetween(now ?? DateTime.now(), target);
  if (n == 0) return 'oggi';
  if (n == 1) return 'domani';
  if (n == -1) return 'ieri';
  if (n < 0) return '${-n} giorni fa';
  return 'tra $n giorni';
}

/// Sfondo tenue di un elemento colorato, leggibile in tema chiaro e scuro.
Color entryTint(BuildContext context, Color c) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Color.alphaBlend(
    c.withValues(alpha: dark ? 0.35 : 0.16),
    Theme.of(context).colorScheme.surface,
  );
}
