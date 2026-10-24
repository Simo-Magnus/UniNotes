import 'dart:io';

import 'agenda.dart';
import 'native_calendar_backend.dart';
import 'system_calendar.dart';

/// Calendario del telefono su Android (Calendar Provider) con il codice
/// nativo dell'app (android/.../UniNotesCalendar.kt, protocollo in
/// [NativeCalendarBackend]).
///
/// Gli eventi vanno in un calendario VERO e sincronizzato dello studente:
/// scrivibile, con SYNC_EVENTS=1 e di un account reale (Google, Samsung,
/// Exchange…); predefinito il principale dell'account Google, oppure quello
/// scelto in Impostazioni → Calendario. Niente più calendario locale
/// «UniNotes»: quello creato dalle versioni precedenti (con il pacchetto
/// device_calendar, account locale e SYNC_EVENTS=0) l'app Calendario lo
/// mostrava con «Sync error»; i suoi eventi si spostano e il calendario si
/// elimina. Il controllo di salute legge anche la sincronizzazione
/// automatica dell'account (ContentResolver).
class AndroidCalendarBackend extends NativeCalendarBackend {
  AndroidCalendarBackend({super.channel});

  static bool get supported => Platform.isAndroid;

  @override
  String get label => 'calendario del telefono';

  /// Argomenti di `write` (anche per i test). Giornata intera: mezzanotte
  /// UTC del giorno e del giorno dopo (come vuole il Calendar Provider,
  /// fuso «UTC»); altrimenti inizio e fine come istanti dell'ora italiana
  /// (Europe/Rome, come il file .ics): il telefono in un altro fuso mostra
  /// la prova all'ora giusta, non alla stessa ora del suo orologio.
  static Map<String, Object?> eventArgs(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) {
    return {
      'calendarId': calendarId,
      'eventId': ?eventId,
      'title': item.title,
      'notes': eventDescription(item),
      'location': item.location,
      'allDay': item.allDay,
      'startMs': (item.allDay ? item.dayStartUtc : item.startInstant)
          .millisecondsSinceEpoch,
      'endMs': (item.allDay ? item.dayEndUtc : item.endInstant)
          .millisecondsSinceEpoch,
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
