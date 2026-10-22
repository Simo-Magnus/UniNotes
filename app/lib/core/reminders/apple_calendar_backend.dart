import 'dart:io';

import 'agenda.dart';
import 'native_calendar_backend.dart';
import 'system_calendar.dart';

export 'native_calendar_backend.dart' show EventNotFound;

/// Calendario del dispositivo su iPhone, iPad e Mac con EventKit (codice
/// nativo `UniNotesCalendar` in ios/Runner/AppDelegate.swift e
/// macos/Runner/MainFlutterWindow.swift, protocollo in
/// [NativeCalendarBackend]): gli eventi vanno nel calendario predefinito per
/// i nuovi eventi (iCloud, Google, Exchange… quello che l'utente vede) o in
/// quello scelto in Impostazioni → Calendario; il calendario «UniNotes»
/// delle versioni precedenti si svuota e si toglie. Su iPhone senza iCloud
/// va bene anche «Sul mio iPhone» (le notifiche arrivano lo stesso).
class AppleCalendarBackend extends NativeCalendarBackend {
  AppleCalendarBackend({super.channel});

  static const kChannel = NativeCalendarBackend.kChannel;

  static bool get supported => Platform.isIOS || Platform.isMacOS;

  @override
  String get label => 'calendario del dispositivo';

  @override
  bool get localCalendarsAllowed => true;

  /// Argomenti di `write` (anche per i test): giornata intera dalla
  /// mezzanotte locale del giorno (fine = inizio, come in EventKit),
  /// altrimenti inizio e fine locali; promemoria in minuti prima.
  static Map<String, Object?> eventArgs(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) {
    final day = DateTime(item.date.year, item.date.month, item.date.day);
    return {
      'calendarId': calendarId,
      'eventId': ?eventId,
      'title': item.title,
      'notes': eventDescription(item),
      'location': item.location,
      'allDay': item.allDay,
      'startMs': (item.allDay ? day : item.start).millisecondsSinceEpoch,
      'endMs': (item.allDay ? day : item.end).millisecondsSinceEpoch,
      'alarms': reminderMinutes,
    };
  }

  @override
  Map<String, Object?> args(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) => eventArgs(calendarId, item, reminderMinutes, eventId: eventId);
}
