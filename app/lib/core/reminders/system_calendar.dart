import 'dart:convert';

import '../../repositories/settings_repository.dart';
import 'agenda.dart';

/// Chiavi dello stato del calendario di sistema nelle impostazioni.
class CalendarKeys {
  /// L'utente ha acconsentito a scrivere le prove nel calendario.
  static const enabled = 'syscal_enabled';

  /// '1' se l'ultima sincronizzazione è riuscita con permesso/token validi.
  static const ok = 'syscal_ok';

  /// Fine dell'ultima sincronizzazione riuscita (ISO).
  static const lastOk = 'syscal_last_ok';

  /// Errore dell'ultima sincronizzazione (null se riuscita).
  static const error = 'syscal_error';

  /// Eventi scritti: JSON {chiave: {"id": id evento, "sig": impronta}}.
  static const events = 'syscal_events';

  /// Id del calendario «UniNotes» usato (dispositivo o Outlook).
  static const calendarId = 'syscal_calendar_id';

  /// Dove sono stati scritti gli eventi (device | outlook): cambiando
  /// piattaforma di scrittura gli id salvati non valgono più.
  static const backend = 'syscal_backend';
}

/// Nome del calendario dedicato.
const String kCalendarName = 'UniNotes';

/// Permesso del calendario negato o accesso all'account scaduto/revocato:
/// il collegamento non funziona finché l'utente non lo ripristina.
class CalendarAccessException implements Exception {
  CalendarAccessException(this.message, {this.expired = false});
  final String message;

  /// Accesso scaduto o revocato (token): merita l'avviso «Collegamento
  /// interrotto».
  final bool expired;
  @override
  String toString() => message;
}

/// Dove si scrivono gli eventi: calendario del dispositivo (Android, iOS)
/// o Outlook dell'account Microsoft (Windows, Microsoft Graph).
abstract class CalendarBackend {
  /// device | outlook
  String get id;

  /// «calendario del dispositivo», «calendario Outlook».
  String get label;

  /// Permesso concesso / accesso all'account valido (senza chiedere nulla).
  Future<bool> hasAccess();

  /// Chiede il permesso del sistema o il consenso all'account (interattivo).
  Future<bool> requestAccess();

  /// Id del calendario «UniNotes» (lo crea se manca; se la piattaforma non
  /// lo permette usa il calendario predefinito). [knownId]: quello salvato.
  Future<String> ensureCalendar(String? knownId);

  /// Eventi dell'app già presenti nel calendario: chiave → id (più di uno
  /// = doppioni da togliere).
  Future<Map<String, List<String>>> existing(String calendarId);

  /// Crea l'evento (o lo aggiorna se [eventId] è dato) e ne restituisce
  /// l'id. [reminderMinutes]: promemoria in minuti prima dell'inizio.
  Future<String> write(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  });

  Future<void> delete(String calendarId, String eventId);
}

/// Stato del collegamento mostrato in Impostazioni → Calendario.
class CalendarStatus {
  const CalendarStatus({
    required this.enabled,
    required this.working,
    this.lastOk,
    this.error,
    this.written = const {},
  });

  static const off = CalendarStatus(enabled: false, working: false);

  final bool enabled;

  /// «Funzionante»: attivo, ultima scrittura riuscita, permesso/token validi.
  final bool working;
  final DateTime? lastOk;
  final String? error;

  /// Chiavi delle prove e sessioni scritte con successo.
  final Set<String> written;
}

/// Evento scritto: id nel calendario e impronta dei dati.
typedef WrittenEvent = ({String id, String sig});

/// Sincronizzazione delle prove con il calendario di sistema: crea,
/// aggiorna e cancella gli eventi dell'app così che il calendario rispecchi
/// sempre l'elenco attuale, senza doppioni (chiave stabile per evento).
class SystemCalendarSync {
  SystemCalendarSync(this._settings, this.backend);
  final SettingsRepository _settings;
  final CalendarBackend? backend;

  bool get supported => backend != null;

  Future<bool> enabled() async =>
      supported && await _settings.get(CalendarKeys.enabled) == '1';

  Future<void> setEnabled(bool v) async {
    await _settings.set(CalendarKeys.enabled, v ? '1' : null);
    if (!v) await _settings.set(CalendarKeys.ok, null);
  }

  Future<CalendarStatus> status() async {
    if (!await enabled()) return CalendarStatus.off;
    return CalendarStatus(
      enabled: true,
      working: await _settings.get(CalendarKeys.ok) == '1',
      lastOk: DateTime.tryParse(await _settings.get(CalendarKeys.lastOk) ?? ''),
      error: await _settings.get(CalendarKeys.error),
      written: (await _stored()).keys.toSet(),
    );
  }

  Future<Map<String, WrittenEvent>> _stored() async {
    final raw = await _settings.get(CalendarKeys.events);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map;
      return {
        for (final e in m.entries)
          if (e.value is Map)
            '${e.key}': (
              id: '${(e.value as Map)['id']}',
              sig: '${(e.value as Map)['sig']}',
            ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _store(Map<String, WrittenEvent> m) => _settings.set(
    CalendarKeys.events,
    jsonEncode({
      for (final e in m.entries) e.key: {'id': e.value.id, 'sig': e.value.sig},
    }),
  );

  Future<CalendarStatus> _fail(String msg) async {
    await _settings.set(CalendarKeys.ok, '0');
    await _settings.set(CalendarKeys.error, msg);
    return status();
  }

  /// Scrive [agenda] nel calendario con i promemoria agli anticipi
  /// [offsetDays] e toglie gli eventi che non ci sono più. Rilancia
  /// [CalendarAccessException] (dopo aver salvato lo stato) se il permesso
  /// o l'accesso all'account non valgono più.
  Future<CalendarStatus> sync(
    List<AgendaItem> agenda,
    List<int> offsetDays, {
    DateTime? now,
  }) async {
    final b = backend;
    if (b == null || !await enabled()) return CalendarStatus.off;
    final failures = <String>[];
    final next = <String, WrittenEvent>{};
    try {
      if (!await b.hasAccess()) {
        throw CalendarAccessException(
          'Permesso del calendario non concesso: riattivalo da Impostazioni '
          '→ Calendario.',
        );
      }
      // cambiando piattaforma (es. backup ripristinato) gli id non valgono
      if (await _settings.get(CalendarKeys.backend) != b.id) {
        await _settings.set(CalendarKeys.events, null);
        await _settings.set(CalendarKeys.calendarId, null);
      }
      final calId = await b.ensureCalendar(
        await _settings.get(CalendarKeys.calendarId),
      );
      await _settings.set(CalendarKeys.calendarId, calId);
      await _settings.set(CalendarKeys.backend, b.id);
      final stored = await _stored();
      final existing = await b.existing(calId);
      final wanted = {for (final i in agenda) i.key: i};

      for (final item in agenda) {
        final reminders = calendarReminderMinutes(
          item,
          item.kind == AgendaKind.session ? const [1] : offsetDays,
        );
        final sig = item.signature(reminders);
        final ids = [...?existing[item.key]];
        final prev = stored[item.key];
        // l'id salvato se c'è ancora, altrimenti il primo trovato
        final keep = prev != null && ids.contains(prev.id)
            ? prev.id
            : (ids.isEmpty ? null : ids.first);
        try {
          for (final dup in ids.where((x) => x != keep)) {
            await b.delete(calId, dup);
          }
          if (keep != null && prev?.id == keep && prev?.sig == sig) {
            next[item.key] = (id: keep, sig: sig);
            continue;
          }
          String id;
          try {
            id = await b.write(calId, item, reminders, eventId: keep);
          } on CalendarAccessException {
            rethrow;
          } catch (_) {
            if (keep == null) rethrow;
            // evento tolto a mano nel frattempo: si ricrea
            id = await b.write(calId, item, reminders);
          }
          next[item.key] = (id: id, sig: sig);
        } on CalendarAccessException {
          rethrow;
        } catch (e) {
          failures.add('${item.title}: $e');
        }
      }
      for (final e in existing.entries) {
        if (wanted.containsKey(e.key)) continue;
        for (final id in e.value) {
          try {
            await b.delete(calId, id);
          } on CalendarAccessException {
            rethrow;
          } catch (err) {
            failures.add('Eliminazione non riuscita: $err');
          }
        }
      }
      await _store(next);
    } on CalendarAccessException catch (e) {
      // gli eventi scritti finora restano validi
      if (next.isNotEmpty) await _store(next);
      await _fail(e.message);
      rethrow;
    } catch (e) {
      if (next.isNotEmpty) await _store(next);
      return _fail('$e');
    }
    if (failures.isNotEmpty) {
      return _fail(
        failures.length == 1
            ? failures.first
            : '${failures.first} (e altri ${failures.length - 1} errori)',
      );
    }
    await _settings.set(CalendarKeys.ok, '1');
    await _settings.set(CalendarKeys.error, null);
    await _settings.set(
      CalendarKeys.lastOk,
      (now ?? DateTime.now()).toIso8601String(),
    );
    return status();
  }

  /// Toglie dal calendario tutti gli eventi dell'app (interruttore spento).
  Future<void> removeAll() async {
    final b = backend;
    final calId = await _settings.get(CalendarKeys.calendarId);
    if (b != null && calId != null && await b.hasAccess()) {
      final existing = await b.existing(calId);
      for (final ids in existing.values) {
        for (final id in ids) {
          await b.delete(calId, id);
        }
      }
    }
    await _settings.set(CalendarKeys.events, null);
    await _settings.set(CalendarKeys.ok, null);
    await _settings.set(CalendarKeys.error, null);
  }
}

/// Riga nella descrizione degli eventi del calendario del dispositivo che
/// lega l'evento alla prova (chiave stabile).
const String kCalendarMarker = 'Rif. UniNotes: ';

/// Chiave scritta nella descrizione di un evento (null se non è dell'app).
String? markerKey(String? description) {
  if (description == null) return null;
  final m = RegExp('${RegExp.escape(kCalendarMarker)}([a-z0-9-]+)')
      .firstMatch(description);
  return m?.group(1);
}

/// Descrizione dell'evento: note della prova e riga con la chiave.
String eventDescription(AgendaItem item) => [
  if (item.notes != null && item.notes!.isNotEmpty) item.notes!,
  '$kCalendarMarker${item.key}',
].join('\n\n');
