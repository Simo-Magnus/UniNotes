import 'dart:io';

import 'package:flutter/services.dart';

import 'agenda.dart';
import 'system_calendar.dart';

/// Calendario del dispositivo su iPhone, iPad e Mac con EventKit (codice
/// nativo `UniNotesCalendar` in ios/Runner/AppDelegate.swift e
/// macos/Runner/MainFlutterWindow.swift). Sostituisce il pacchetto
/// device_calendar su iOS (che creava il calendario «UniNotes» sul
/// dispositivo anche con iCloud attivo, dove l'app Calendario non lo
/// mostra) e il file .ics su macOS (che a ogni modifica andava reimportato):
/// - calendario «UniNotes» nell'account dove l'utente vede i suoi
///   calendari (iCloud se attivo), o il predefinito se non si può creare;
/// - eventi aggiornati sul posto (stesso id) e ritrovati dalla riga
///   «Rif. UniNotes: …» della descrizione, anche dopo una reinstallazione.
/// Stesso [id] `device` di prima: gli id salvati restano validi.
class AppleCalendarBackend implements CalendarBackend, RemovableCalendar {
  AppleCalendarBackend({MethodChannel? channel}) : _ch = channel ?? kChannel;
  final MethodChannel _ch;

  static const kChannel = MethodChannel(
    'io.github.simomagnus.universitynotes/calendario',
  );

  static bool get supported => Platform.isIOS || Platform.isMacOS;

  /// Azzurro dell'app (AppTokens.dark.cyan).
  static const _color = 0xFF38BDF8;

  @override
  String get id => 'device';

  @override
  String get label => 'calendario del dispositivo';

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
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
      return await _call<String>('access') == 'concesso';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestAccess() async => await _call<bool>('request') ?? false;

  @override
  Future<String> ensureCalendar(String? knownId) async {
    final id = await _call<String>('ensureCalendar', {
      'knownId': knownId,
      'name': kCalendarName,
      'color': _color,
    });
    if (id == null || id.isEmpty) throw Exception('Calendario non creato.');
    return id;
  }

  @override
  Future<Map<String, List<String>>> existing(String calendarId) async {
    final now = DateTime.now();
    final list =
        await _call<List<Object?>>('events', {
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
  Future<String> write(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) async {
    final id = await _call<String>(
      'write',
      eventArgs(calendarId, item, reminderMinutes, eventId: eventId),
    );
    if (id == null || id.isEmpty) throw Exception('Evento non scritto.');
    return id;
  }

  @override
  Future<void> delete(String calendarId, String eventId) =>
      _call<void>('delete', {'eventId': eventId});

  @override
  Future<bool> deleteCalendarIfEmpty(String calendarId) async =>
      await _call<bool>('deleteCalendarIfEmpty', {
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
