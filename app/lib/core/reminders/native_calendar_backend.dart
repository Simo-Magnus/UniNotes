import 'package:flutter/services.dart';

import 'agenda.dart';
import 'system_calendar.dart';

/// Calendario del dispositivo con codice nativo dell'app (canale
/// `io.github.simomagnus.universitynotes/calendario`), uguale per Android
/// (Calendar Provider, `android/.../UniNotesCalendar.kt`) e per iPhone, iPad
/// e Mac (EventKit, `UniNotesCalendar` in ios/Runner/AppDelegate.swift e
/// macos/Runner/MainFlutterWindow.swift):
/// - `access` → concesso | da_chiedere | solo_scrittura | negato;
///   `request` → true se l'utente dà l'accesso completo;
/// - `calendars` → [{id, name, account, accountType, color, primary,
///   synced, writable, legacy}];
/// - `health` {calendarId} → {exists, writable, synced, autoSync?,
///   masterSync?};
/// - `events` {calendarId, startMs, endMs} → [{id, notes}];
/// - `write` {calendarId, eventId?, title, notes, location?, startMs, endMs,
///   allDay, alarms} → id dell'evento (errore `non_trovato` se l'evento da
///   aggiornare non c'è più);
/// - `delete` {calendarId, eventId}; `deleteCalendarIfEmpty` {calendarId,
///   name} → true se il calendario «UniNotes» vuoto è stato eliminato.
/// Gli eventi dell'app si riconoscono dalla riga «Rif. UniNotes: …» della
/// descrizione, anche dopo una reinstallazione.
abstract class NativeCalendarBackend
    implements CalendarBackend, RemovableCalendar {
  NativeCalendarBackend({MethodChannel? channel}) : _ch = channel ?? kChannel;
  final MethodChannel _ch;

  static const kChannel = MethodChannel(
    'io.github.simomagnus.universitynotes/calendario',
  );

  /// Stesso id `device` delle versioni precedenti: gli id salvati restano.
  @override
  String get id => 'device';

  @override
  bool get localCalendarsAllowed => false;

  Future<T?> call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'permesso') {
        throw CalendarAccessException('Permesso del calendario negato.');
      }
      if (e.code == 'non_trovato') throw const EventNotFound();
      throw Exception(e.message ?? e.code);
    } on MissingPluginException {
      throw Exception('Calendario non disponibile in questa versione.');
    }
  }

  @override
  Future<bool> hasAccess() async {
    try {
      return await call<String>('access') == 'concesso';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestAccess() async => await call<bool>('request') ?? false;

  @override
  Future<List<CalendarChoice>> calendars() async => [
    for (final c in await call<List<Object?>>('calendars') ?? const [])
      ?CalendarChoice.fromMap(c),
  ];

  /// Testi del controllo di salute (anche per i test).
  static CalendarHealth healthOf(Map<Object?, Object?> h, CalendarChoice c) {
    if (h['exists'] != true) {
      return CalendarHealth(
        problem:
            'Il calendario «${c.name}» non c\'è più sul dispositivo: scegline '
            'un altro in Impostazioni → Calendario.',
      );
    }
    if (h['writable'] == false) {
      return CalendarHealth(
        problem:
            'Il calendario «${c.name}» è di sola lettura: scegline un altro in '
            'Impostazioni → Calendario.',
      );
    }
    if (h['synced'] == false) {
      return CalendarHealth(
        problem:
            'Il calendario «${c.name}» non è sincronizzato: attiva la sua '
            'sincronizzazione nell\'app Calendario o scegline un altro.',
      );
    }
    if (h['masterSync'] == false || h['autoSync'] == false) {
      return CalendarHealth(
        warning:
            'La sincronizzazione automatica dell\'account ${c.account ?? ''} '
            'è spenta: le prove sono nel calendario di questo telefono, ma '
            'non arrivano sugli altri dispositivi finché non la riattivi '
            '(Impostazioni del telefono → Account).',
      );
    }
    return CalendarHealth.fine;
  }

  @override
  Future<CalendarHealth> health(CalendarChoice c) async {
    final h = await call<Map<Object?, Object?>>('health', {
      'calendarId': c.id,
    });
    return healthOf(h ?? const {}, c);
  }

  @override
  Future<Map<String, List<String>>> existing(String calendarId) async {
    final now = DateTime.now();
    final list =
        await call<List<Object?>>('events', {
          'calendarId': calendarId,
          'startMs': now
              .subtract(const Duration(days: 400))
              .millisecondsSinceEpoch,
          'endMs': now.add(const Duration(days: 1100)).millisecondsSinceEpoch,
        }) ??
        const [];
    final out = <String, List<String>>{};
    for (final e in list) {
      if (e is! Map) continue;
      final key = markerKey(e['notes'] as String?);
      final id = e['id'];
      if (key == null || id is! String) continue;
      (out[key] ??= []).add(id);
    }
    return out;
  }

  /// Argomenti di `write` per questa piattaforma.
  Map<String, Object?> args(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  });

  @override
  Future<String> write(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) async {
    final id = await call<String>(
      'write',
      args(calendarId, item, reminderMinutes, eventId: eventId),
    );
    if (id == null || id.isEmpty) throw Exception('Evento non scritto.');
    return id;
  }

  @override
  Future<void> delete(String calendarId, String eventId) =>
      call<void>('delete', {'calendarId': calendarId, 'eventId': eventId});

  @override
  Future<bool> deleteCalendarIfEmpty(String calendarId) async =>
      await call<bool>('deleteCalendarIfEmpty', {
        'calendarId': calendarId,
        'name': kCalendarName,
      }) ??
      false;
}

/// L'evento da aggiornare non c'è più (tolto a mano): la sincronizzazione
/// lo ricrea.
class EventNotFound implements Exception {
  const EventNotFound();
  @override
  String toString() => 'Evento non trovato nel calendario.';
}
