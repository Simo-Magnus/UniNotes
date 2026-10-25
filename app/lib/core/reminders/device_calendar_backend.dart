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
class AndroidCalendarBackend extends NativeCalendarBackend
    implements AccountConfirmation {
  AndroidCalendarBackend({super.channel});

  static bool get supported => Platform.isAndroid;

  @override
  String get label => 'calendario del telefono';

  /// Account e tipo del calendario [c] per `accountAccess` e
  /// `confirmAccount`; null per i calendari solo sul telefono (nessun
  /// server, nessun account da confermare).
  static Map<String, Object?>? accountArgs(CalendarChoice c) {
    final account = c.account?.trim() ?? '';
    final type = c.accountType?.trim() ?? '';
    if (!c.synced || account.isEmpty || type.isEmpty || type == 'LOCAL') {
      return null;
    }
    return {'account': account, 'accountType': type};
  }

  /// Testo della finestra del sistema per la conferma dell'account.
  static String accountDescription(CalendarChoice c) =>
      c.accountType == 'com.google'
      ? 'Conferma l\'account del calendario: così UniNotes carica subito su '
            'Google Calendar le prove che aggiungi.'
      : 'Conferma l\'account del calendario: così UniNotes carica subito '
            'sul tuo account le prove che aggiungi.';

  @override
  Future<bool> accountAccessNeeded(CalendarChoice c) async {
    final args = accountArgs(c);
    if (args == null) return false;
    try {
      final r = await call<Map<Object?, Object?>>('accountAccess', args);
      return r?['needed'] == true;
    } catch (_) {
      // versione senza il metodo o errore del sistema: niente conferma
      return false;
    }
  }

  @override
  Future<bool?> confirmAccount(CalendarChoice c) async {
    final args = accountArgs(c);
    if (args == null) return true;
    try {
      return await call<bool>('confirmAccount', {
        ...args,
        'calendarId': c.id,
        'description': accountDescription(c),
      });
    } catch (_) {
      return null;
    }
  }

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
