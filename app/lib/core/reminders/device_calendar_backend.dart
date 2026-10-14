import 'dart:io';
import 'dart:ui' show Color;

import 'package:device_calendar/device_calendar.dart' as dc;

import 'agenda.dart';
import 'system_calendar.dart';

/// Calendario del dispositivo (Android: Calendar Provider, iOS: EventKit)
/// con il pacchetto device_calendar: calendario locale «UniNotes» (azzurro
/// dell'app); se il sistema non permette di crearlo (iOS senza un account
/// locale) si usa il calendario predefinito, e gli eventi dell'app si
/// riconoscono dalla riga «Rif. UniNotes: …» (con la chiave) nella descrizione.
class DeviceCalendarBackend implements CalendarBackend, RemovableCalendar {
  DeviceCalendarBackend([this._custom]);
  final dc.DeviceCalendarPlugin? _custom;

  /// Creato al primo uso (carica il database dei fusi orari).
  late final dc.DeviceCalendarPlugin _plugin =
      _custom ?? dc.DeviceCalendarPlugin();

  /// Android, iOS. Su macOS il pacchetto non c'è: resta il file .ics.
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// Azzurro dell'app (AppTokens.dark.cyan).
  static const _color = Color(0xFF38BDF8);

  @override
  String get id => 'device';

  @override
  String get label => 'calendario del dispositivo';

  T _data<T>(dc.Result<T> r, String what) {
    if (r.isSuccess && r.data != null) return r.data as T;
    final msg = r.errors.map((e) => e.errorMessage).join('; ');
    if (r.errors.any((e) => e.errorCode == 401 || e.errorCode == 403)) {
      throw CalendarAccessException('Permesso del calendario negato.');
    }
    throw Exception('$what: ${msg.isEmpty ? 'errore sconosciuto' : msg}');
  }

  @override
  Future<bool> hasAccess() async {
    final r = await _plugin.hasPermissions();
    return r.isSuccess && r.data == true;
  }

  @override
  Future<bool> requestAccess() async {
    final r = await _plugin.requestPermissions();
    return r.isSuccess && r.data == true;
  }

  @override
  Future<String> ensureCalendar(String? knownId) async {
    final cals = _data(
      await _plugin.retrieveCalendars(),
      'Calendari non letti',
    );
    bool writable(dc.Calendar c) => c.isReadOnly != true && c.id != null;
    for (final c in cals) {
      if (c.id == knownId && writable(c)) return c.id!;
    }
    for (final c in cals) {
      if (c.name == kCalendarName && writable(c)) return c.id!;
    }
    final created = await _plugin.createCalendar(
      kCalendarName,
      calendarColor: _color,
      localAccountName: kCalendarName,
    );
    if (created.isSuccess && (created.data ?? '').isNotEmpty) {
      return created.data!;
    }
    // iOS senza sorgente locale (solo iCloud/Exchange): calendario
    // predefinito modificabile
    for (final c in cals) {
      if (c.isDefault == true && writable(c)) return c.id!;
    }
    for (final c in cals) {
      if (writable(c)) return c.id!;
    }
    throw Exception('Nessun calendario modificabile sul dispositivo.');
  }

  @override
  Future<Map<String, List<String>>> existing(String calendarId) async {
    final now = DateTime.now();
    final events = _data(
      await _plugin.retrieveEvents(
        calendarId,
        dc.RetrieveEventsParams(
          startDate: now.subtract(const Duration(days: 400)),
          endDate: now.add(const Duration(days: 1100)),
        ),
      ),
      'Eventi non letti',
    );
    final out = <String, List<String>>{};
    for (final e in events) {
      final key = markerKey(e.description);
      final id = e.eventId;
      if (key == null || id == null) continue;
      (out[key] ??= []).add(id);
    }
    return out;
  }

  @override
  Future<String> write(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) async {
    final dc.TZDateTime start;
    final dc.TZDateTime end;
    if (item.allDay) {
      // giornata intera: data «pura» (device_calendar la porta a
      // mezzanotte UTC su Android e a mezzanotte locale su iOS)
      start = dc.TZDateTime.utc(item.date.year, item.date.month, item.date.day);
      end = start;
    } else {
      start = dc.TZDateTime.from(item.start, dc.UTC);
      end = dc.TZDateTime.from(item.end, dc.UTC);
    }
    final event = dc.Event(
      calendarId,
      eventId: eventId,
      title: item.title,
      description: eventDescription(item),
      start: start,
      end: end,
      allDay: item.allDay,
      location: item.location,
      reminders: [for (final m in reminderMinutes) dc.Reminder(minutes: m)],
    );
    final r = await _plugin.createOrUpdateEvent(event);
    if (r == null) throw Exception('Evento non scritto.');
    return _data(r, 'Evento non scritto');
  }

  @override
  Future<bool> deleteCalendarIfEmpty(String calendarId) async {
    final cals = _data(
      await _plugin.retrieveCalendars(),
      'Calendari non letti',
    );
    final c = cals.where((c) => c.id == calendarId).firstOrNull;
    if (c == null ||
        c.name != kCalendarName ||
        c.isDefault == true ||
        c.isReadOnly == true) {
      return false;
    }
    final now = DateTime.now();
    final events = _data(
      await _plugin.retrieveEvents(
        calendarId,
        dc.RetrieveEventsParams(
          startDate: now.subtract(const Duration(days: 3650)),
          endDate: now.add(const Duration(days: 3650)),
        ),
      ),
      'Eventi non letti',
    );
    if (events.isNotEmpty) return false;
    final r = await _plugin.deleteCalendar(calendarId);
    return r.isSuccess && r.data == true;
  }

  @override
  Future<void> delete(String calendarId, String eventId) async {
    final r = await _plugin.deleteEvent(calendarId, eventId);
    if (!r.isSuccess) {
      throw Exception(r.errors.map((e) => e.errorMessage).join('; '));
    }
  }
}
