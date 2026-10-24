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

  /// Errore dell'ultima sincronizzazione (null se riuscita): con il
  /// calendario che non funziona le notifiche le manda l'app (calendario
  /// interno).
  static const error = 'syscal_error';

  /// Avviso non grave (es. sincronizzazione dell'account spenta): gli eventi
  /// si scrivono lo stesso.
  static const warning = 'syscal_warning';

  /// Eventi scritti: JSON {chiave: {"id": id evento, "sig": impronta}}.
  static const events = 'syscal_events';

  /// Id del calendario in cui sono gli eventi (dispositivo o Outlook).
  static const calendarId = 'syscal_calendar_id';

  /// Nome e account del calendario usato (mostrati in Impostazioni).
  static const calendarName = 'syscal_calendar_name';
  static const calendarAccount = 'syscal_calendar_account';

  /// Calendario scelto dallo studente in Impostazioni → Calendario (null =
  /// il predefinito). Gli id sono di questo dispositivo: non si sincronizza.
  static const chosen = 'syscal_chosen';

  /// Dove sono stati scritti gli eventi (device | outlook): cambiando
  /// piattaforma di scrittura gli id salvati non valgono più.
  static const backend = 'syscal_backend';

  /// Dispositivo che scrive nel calendario di ogni account, sincronizzato
  /// fra i dispositivi con i dati dell'app: JSON {account: {"install": id,
  /// "device": nome, "at": ISO}}. Gli altri dispositivi con lo stesso
  /// account leggono soltanto (niente doppioni).
  static const writers = 'syscal_writers';

  /// Nome del dispositivo che aggiorna il calendario al posto di questo
  /// (null = scrive questo dispositivo).
  static const writtenBy = 'syscal_written_by';
}

/// Nome del calendario dedicato creato dalle versioni precedenti dell'app:
/// ora gli eventi vanno nel calendario vero dello studente e quello
/// «UniNotes» si toglie appena è vuoto.
const String kCalendarName = 'UniNotes';

/// Dopo quanti giorni senza notizie il dispositivo che scriveva nel
/// calendario non conta più (app tolta, dispositivo cambiato).
const Duration kCalendarWriterStale = Duration(days: 21);

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

/// Un calendario in cui l'app può scrivere (scelta in Impostazioni →
/// Calendario).
class CalendarChoice {
  const CalendarChoice({
    required this.id,
    required this.name,
    this.account,
    this.accountType,
    this.color,
    this.primary = false,
    this.synced = true,
    this.writable = true,
    this.legacy = false,
  });

  final String id;
  final String name;

  /// Account del calendario (indirizzo Google/Microsoft, «iCloud»…).
  final String? account;

  /// Tipo di account (Android: com.google, com.samsung…, LOCAL).
  final String? accountType;

  /// Colore ARGB.
  final int? color;

  /// Calendario principale dell'account / predefinito per i nuovi eventi.
  final bool primary;

  /// Sincronizzato con un account vero (non solo sul dispositivo).
  final bool synced;
  final bool writable;

  /// Calendario «UniNotes» creato da una versione precedente dell'app:
  /// non si propone, gli eventi dell'app si spostano e poi si toglie.
  final bool legacy;

  /// Account per la regola dei dispositivi (uno solo scrive).
  String accountKeyFor(String backend) =>
      '$backend:${(account ?? name).trim().toLowerCase()}';

  /// «Calendario · nome@gmail.com».
  String get label =>
      account == null || account!.isEmpty || account == name
      ? name
      : '$name · $account';

  static CalendarChoice? fromMap(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    if (id is! String || id.isEmpty) return null;
    String? s(String k) {
      final x = v[k];
      return x is String && x.trim().isNotEmpty ? x.trim() : null;
    }

    bool b(String k, bool def) => v[k] is bool ? v[k] as bool : def;
    return CalendarChoice(
      id: id,
      name: s('name') ?? 'Calendario',
      account: s('account'),
      accountType: s('accountType'),
      color: (v['color'] as num?)?.toInt(),
      primary: b('primary', false),
      synced: b('synced', true),
      writable: b('writable', true),
      legacy: b('legacy', false),
    );
  }
}

/// Esito del controllo di salute di un calendario.
class CalendarHealth {
  const CalendarHealth({this.problem, this.warning});
  static const fine = CalendarHealth();

  /// Grave (calendario sparito, di sola lettura, non sincronizzato): le
  /// notifiche le manda l'app.
  final String? problem;

  /// Non grave: gli eventi si scrivono, ma lo studente deve saperlo (es.
  /// sincronizzazione automatica dell'account spenta).
  final String? warning;

  bool get ok => problem == null;
}

/// Dove si scrivono gli eventi: calendario del dispositivo (Android, iOS,
/// macOS) o Outlook dell'account Microsoft (Windows, Microsoft Graph).
abstract class CalendarBackend {
  /// device | outlook
  String get id;

  /// «calendario del telefono», «calendario Outlook».
  String get label;

  /// Permesso concesso / accesso all'account valido (senza chiedere nulla).
  Future<bool> hasAccess();

  /// Chiede il permesso del sistema o il consenso all'account (interattivo).
  Future<bool> requestAccess();

  /// Calendari dell'utente (anche quelli che non si possono usare: vedi
  /// [CalendarChoice.writable], [CalendarChoice.synced]).
  Future<List<CalendarChoice>> calendars();

  /// Si possono usare anche i calendari solo sul dispositivo (iPhone senza
  /// iCloud: «Sul mio iPhone»). Su Android no: un calendario locale fa
  /// comparire «Sync error» nell'app Calendario.
  bool get localCalendarsAllowed => false;

  /// Controllo di salute del calendario [c].
  Future<CalendarHealth> health(CalendarChoice c) async => CalendarHealth.fine;

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

/// Backend che sa eliminare il calendario «UniNotes» creato dall'app.
abstract interface class RemovableCalendar {
  /// Elimina il calendario [calendarId] solo se si chiama «UniNotes», non è
  /// il calendario predefinito ed è vuoto (nessun evento, neanche
  /// dell'utente). true se eliminato.
  Future<bool> deleteCalendarIfEmpty(String calendarId);
}

/// Scelta del calendario: [chosen] se utilizzabile, poi il principale di un
/// account Google, il principale di un altro account, un calendario Google,
/// un altro calendario sincronizzato. I calendari solo sul dispositivo
/// valgono solo con [allowLocal] (iPhone senza iCloud: «Sul mio iPhone»).
CalendarChoice? pickCalendar(
  List<CalendarChoice> all,
  String? chosen, {
  bool allowLocal = false,
}) {
  final usable = [
    for (final c in all)
      if (c.writable && !c.legacy && (c.synced || allowLocal)) c,
  ];
  if (usable.isEmpty) return null;
  for (final c in usable) {
    if (c.id == chosen) return c;
  }
  bool google(CalendarChoice c) => c.accountType == 'com.google';
  int rank(CalendarChoice c) {
    if (c.synced && c.primary && google(c)) return 0;
    if (c.synced && c.primary) return 1;
    if (c.synced && google(c)) return 2;
    if (c.synced) return 3;
    if (c.primary) return 4;
    return 5;
  }

  final sorted = [...usable]..sort((a, b) => rank(a).compareTo(rank(b)));
  return sorted.first;
}

/// Stato del collegamento mostrato in Impostazioni → Calendario.
class CalendarStatus {
  const CalendarStatus({
    required this.enabled,
    required this.working,
    this.lastOk,
    this.error,
    this.warning,
    this.written = const {},
    this.calendarName,
    this.account,
    this.writtenBy,
  });

  static const off = CalendarStatus(enabled: false, working: false);

  final bool enabled;

  /// «Funzionante»: attivo, ultima scrittura riuscita, permesso/token validi.
  final bool working;
  final DateTime? lastOk;
  final String? error;
  final String? warning;

  /// Chiavi delle prove e sessioni presenti nel calendario (scritte qui o
  /// dal dispositivo che lo aggiorna): per queste avvisa il calendario.
  final Set<String> written;

  /// Calendario usato e il suo account.
  final String? calendarName;
  final String? account;

  /// Il calendario lo aggiorna un altro dispositivo con lo stesso account
  /// (es. «telefono ea12a6»): questo legge soltanto.
  final String? writtenBy;

  /// Attivo ma non funzionante: le notifiche le manda l'app (calendario
  /// interno, nessun calendario visibile).
  bool get internal => enabled && !working;
}

/// Evento scritto: id nel calendario e impronta dei dati.
typedef WrittenEvent = ({String id, String sig});

/// Questo dispositivo, per la regola «un solo dispositivo scrive».
class CalendarDevice {
  const CalendarDevice({required this.installId, required this.name});

  /// Identificativo stabile dell'installazione.
  final Future<String> Function() installId;

  /// «PC», «telefono», «Mac».
  final String name;
}

/// Dispositivo che scrive nel calendario di un account.
typedef CalendarWriter = ({String install, String device, DateTime at});

/// Sincronizzazione delle prove con il calendario di sistema: crea,
/// aggiorna e cancella gli eventi dell'app così che il calendario rispecchi
/// sempre l'elenco attuale, senza doppioni (chiave stabile per evento).
///
/// Gli eventi vanno nel calendario vero dello studente (Google, Samsung,
/// iCloud, Outlook…), scelto in Impostazioni o il predefinito; quelli
/// scritti dalle versioni precedenti nel calendario «UniNotes» si spostano
/// e quel calendario si toglie. Con i dati sincronizzati fra dispositivi
/// scrive un solo dispositivo per account ([CalendarKeys.writers]); gli
/// altri leggono gli eventi e non mandano notifiche doppie.
class SystemCalendarSync {
  SystemCalendarSync(this._settings, this.backend, {this.device});
  final SettingsRepository _settings;
  final CalendarBackend? backend;

  /// Null (test) = nessuna regola dei dispositivi: scrive sempre.
  final CalendarDevice? device;

  bool get supported => backend != null;

  Future<bool> enabled() async =>
      supported && await _settings.get(CalendarKeys.enabled) == '1';

  Future<void> setEnabled(bool v) async {
    await _settings.set(CalendarKeys.enabled, v ? '1' : null);
    if (!v) {
      await _settings.set(CalendarKeys.ok, null);
      await _settings.set(CalendarKeys.writtenBy, null);
      await _settings.set(CalendarKeys.warning, null);
    }
  }

  /// Calendario scelto in Impostazioni (null = predefinito).
  Future<String?> chosen() => _settings.get(CalendarKeys.chosen);

  Future<void> choose(String? id) => _settings.set(CalendarKeys.chosen, id);

  Future<CalendarStatus> status() async {
    if (!await enabled()) return CalendarStatus.off;
    return CalendarStatus(
      enabled: true,
      working: await _settings.get(CalendarKeys.ok) == '1',
      lastOk: DateTime.tryParse(await _settings.get(CalendarKeys.lastOk) ?? ''),
      error: await _settings.get(CalendarKeys.error),
      warning: await _settings.get(CalendarKeys.warning),
      written: (await _stored()).keys.toSet(),
      calendarName: await _settings.get(CalendarKeys.calendarName),
      account: await _settings.get(CalendarKeys.calendarAccount),
      writtenBy: await _settings.get(CalendarKeys.writtenBy),
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

  // ------------------------------------------------- regola dei dispositivi

  Future<Map<String, CalendarWriter>> writers() async {
    final raw = await _settings.get(CalendarKeys.writers);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map;
      return {
        for (final e in m.entries)
          if (e.value is Map &&
              (e.value as Map)['install'] is String &&
              DateTime.tryParse('${(e.value as Map)['at']}') != null)
            '${e.key}': (
              install: (e.value as Map)['install'] as String,
              device: '${(e.value as Map)['device'] ?? 'altro dispositivo'}',
              at: DateTime.parse('${(e.value as Map)['at']}'),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveWriters(Map<String, CalendarWriter> m) => _settings.set(
    CalendarKeys.writers,
    m.isEmpty
        ? null
        : jsonEncode({
            for (final e in m.entries)
              e.key: {
                'install': e.value.install,
                'device': e.value.device,
                'at': e.value.at.toUtc().toIso8601String(),
              },
          }),
  );

  /// Chi scrive nel calendario dell'account [key]: null = questo
  /// dispositivo (se nessuno lo fa, o chi lo faceva non si sente da
  /// [kCalendarWriterStale], questo diventa lo scrittore). Il segno si
  /// rinnova una volta al giorno.
  Future<CalendarWriter?> _otherWriter(String key, DateTime now) async {
    final d = device;
    if (d == null) return null;
    final me = await d.installId();
    final all = await writers();
    var w = all[key];
    // segno con l'orario nel futuro (orologio avanti sul dispositivo che
    // l'ha scritto): vale come scritto adesso e da qui invecchia con questo
    // orologio, come «Orologi diversi» della sincronizzazione. Prima un
    // segno di un anno avanti impediva per un anno agli altri di subentrare
    // e al dispositivo stesso, con l'orologio rimesso a posto, di rinnovarlo.
    if (w != null && w.at.isAfter(now)) {
      w = (install: w.install, device: w.device, at: now);
      all[key] = w;
      await _saveWriters(all);
    }
    if (w != null && w.install != me && now.difference(w.at) < kCalendarWriterStale) {
      return w;
    }
    if (w == null || w.install != me || now.difference(w.at).inHours >= 24) {
      all[key] = (install: me, device: '${d.name} $me', at: now);
      await _saveWriters(all);
    }
    return null;
  }

  /// «Aggiorna da questo dispositivo»: da ora scrive questo dispositivo.
  Future<void> takeOver({DateTime? now}) async {
    final d = device;
    final b = backend;
    if (d == null || b == null) return;
    final me = await d.installId();
    final all = await writers();
    final account = await _settings.get(CalendarKeys.calendarAccount);
    final name = await _settings.get(CalendarKeys.calendarName);
    final key = CalendarChoice(
      id: '',
      name: name ?? '',
      account: account,
    ).accountKeyFor(b.id);
    all[key] = (install: me, device: '${d.name} $me', at: now ?? DateTime.now());
    await _saveWriters(all);
    await _settings.set(CalendarKeys.writtenBy, null);
  }

  /// Toglie il segno di questo dispositivo (calendario spento qui): un
  /// altro dispositivo con lo stesso account può prendere il suo posto.
  Future<void> _releaseWriter() async {
    final d = device;
    if (d == null) return;
    final me = await d.installId();
    final all = await writers();
    final before = all.length;
    all.removeWhere((_, w) => w.install == me);
    if (all.length != before) await _saveWriters(all);
  }

  // ------------------------------------------------------- sincronizzazione

  /// Toglie gli eventi dell'app dal calendario [calendarId] (calendario
  /// precedente o «UniNotes» delle versioni passate) e, se è quello
  /// dell'app ed è rimasto vuoto, il calendario stesso.
  Future<void> _moveOut(CalendarBackend b, String calendarId) async {
    try {
      final old = await b.existing(calendarId);
      for (final ids in old.values) {
        for (final id in ids) {
          await b.delete(calendarId, id);
        }
      }
      if (b is RemovableCalendar) {
        await (b as RemovableCalendar).deleteCalendarIfEmpty(calendarId);
      }
    } on CalendarAccessException {
      rethrow;
    } catch (_) {
      // calendario già sparito: niente da spostare
    }
  }

  /// Scrive [agenda] nel calendario con i promemoria agli anticipi
  /// [offsetDays] (giorni prima) e [offsetHours] (ore prima, solo per le
  /// prove con l'orario) e toglie gli eventi che non ci sono più. Rilancia
  /// [CalendarAccessException] (dopo aver salvato lo stato) se il permesso
  /// o l'accesso all'account non valgono più.
  Future<CalendarStatus> sync(
    List<AgendaItem> agenda,
    List<int> offsetDays, {
    List<int> offsetHours = const [],
    DateTime? now,
  }) async {
    final b = backend;
    if (b == null || !await enabled()) return CalendarStatus.off;
    final t = now ?? DateTime.now();
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
      final all = await b.calendars();
      final target = pickCalendar(
        all,
        await chosen(),
        allowLocal: b.localCalendarsAllowed,
      );
      if (target == null) {
        return await _fail(
          b.id == 'outlook'
              ? 'Nessun calendario modificabile nell\'account Microsoft.'
              : 'Nessun calendario sincronizzato con un account sul '
                    'dispositivo (es. Google): le notifiche delle prove le '
                    'manda l\'app.',
        );
      }
      await _settings.set(CalendarKeys.calendarName, target.name);
      await _settings.set(CalendarKeys.calendarAccount, target.account);
      final health = await b.health(target);
      await _settings.set(CalendarKeys.warning, health.warning);
      if (!health.ok) return await _fail(health.problem!);

      // calendari delle versioni precedenti («UniNotes») e calendario
      // usato prima della scelta attuale: gli eventi dell'app si spostano
      final prevId = await _settings.get(CalendarKeys.calendarId);
      var stored = await _stored();
      for (final old in {
        if (prevId != null && prevId != target.id) prevId,
        for (final c in all)
          if (c.legacy && c.id != target.id) c.id,
      }) {
        await _moveOut(b, old);
        if (old == prevId) stored = {};
      }
      await _settings.set(CalendarKeys.calendarId, target.id);
      await _settings.set(CalendarKeys.backend, b.id);

      final existing = await b.existing(target.id);
      final wanted = {for (final i in agenda) i.key: i};

      // un altro dispositivo con lo stesso account aggiorna il calendario:
      // qui si legge soltanto (le notifiche le dà il calendario)
      final writer = await _otherWriter(target.accountKeyFor(b.id), t);
      if (writer != null) {
        for (final e in existing.entries) {
          if (wanted.containsKey(e.key) && e.value.isNotEmpty) {
            next[e.key] = (id: e.value.first, sig: '');
          }
        }
        await _store(next);
        await _settings.set(CalendarKeys.writtenBy, writer.device);
        await _settings.set(CalendarKeys.ok, '1');
        await _settings.set(CalendarKeys.error, null);
        await _settings.set(CalendarKeys.lastOk, t.toIso8601String());
        return await status();
      }
      await _settings.set(CalendarKeys.writtenBy, null);

      for (final item in agenda) {
        final reminders = item.kind == AgendaKind.session
            ? calendarReminderMinutes(item, const [1])
            : calendarReminderMinutes(item, offsetDays, offsetHours);
        final sig = item.signature(reminders);
        final ids = [...?existing[item.key]];
        final prev = stored[item.key];
        // l'id salvato se c'è ancora, altrimenti il primo trovato
        final keep = prev != null && ids.contains(prev.id)
            ? prev.id
            : (ids.isEmpty ? null : ids.first);
        try {
          for (final dup in ids.where((x) => x != keep)) {
            await b.delete(target.id, dup);
          }
          if (keep != null && prev?.id == keep && prev?.sig == sig) {
            next[item.key] = (id: keep, sig: sig);
            continue;
          }
          String id;
          try {
            id = await b.write(target.id, item, reminders, eventId: keep);
          } on CalendarAccessException {
            rethrow;
          } catch (_) {
            if (keep == null) rethrow;
            // evento tolto a mano nel frattempo: si ricrea
            id = await b.write(target.id, item, reminders);
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
            await b.delete(target.id, id);
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
    await _settings.set(CalendarKeys.lastOk, t.toIso8601String());
    return status();
  }

  /// Toglie dal calendario tutti gli eventi dell'app (interruttore spento):
  /// solo quelli con il riferimento dell'app, mai gli altri, e solo se li
  /// scrive questo dispositivo (se li aggiorna un altro dispositivo restano:
  /// li gestisce lui). Con [dropCalendar] («Elimina tutti i dati») elimina
  /// poi anche il calendario «UniNotes» delle versioni precedenti se è
  /// rimasto vuoto; senza permesso o accesso rilancia
  /// [CalendarAccessException] (gli eventi restano).
  Future<void> removeAll({bool dropCalendar = false}) async {
    final b = backend;
    final calId = await _settings.get(CalendarKeys.calendarId);
    final readOnly = await _settings.get(CalendarKeys.writtenBy) != null;
    if (b != null && calId != null && !readOnly) {
      if (await b.hasAccess()) {
        final existing = await b.existing(calId);
        for (final ids in existing.values) {
          for (final id in ids) {
            await b.delete(calId, id);
          }
        }
        final removable = b is RemovableCalendar
            ? b as RemovableCalendar
            : null;
        if (dropCalendar &&
            removable != null &&
            await removable.deleteCalendarIfEmpty(calId)) {
          await _settings.set(CalendarKeys.calendarId, null);
        }
      } else if (dropCalendar) {
        throw CalendarAccessException(
          'Permesso del calendario non disponibile: gli eventi aggiunti '
          "dall'app restano nel ${b.label}.",
        );
      }
    }
    await _releaseWriter();
    await _settings.set(CalendarKeys.events, null);
    await _settings.set(CalendarKeys.ok, null);
    await _settings.set(CalendarKeys.error, null);
    await _settings.set(CalendarKeys.warning, null);
    await _settings.set(CalendarKeys.writtenBy, null);
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

/// «dal telefono», «dal PC», «dal Mac» (con il codice se questo
/// dispositivo è dello stesso tipo: «dall'altro telefono (ea12a6)»).
String calendarWriterLabel(String writer, {String? thisDevice}) {
  final parts = writer.trim().split(' ');
  final kind = parts.first;
  final code = parts.length > 1 ? parts.sublist(1).join(' ') : '';
  final same = thisDevice != null && thisDevice == kind;
  final base = switch (kind) {
    'telefono' => same ? 'dall\'altro telefono' : 'dal telefono',
    'PC' => same ? 'dall\'altro PC' : 'dal PC',
    'Mac' => same ? 'dall\'altro Mac' : 'dal Mac',
    _ => 'da $kind',
  };
  return same && code.isNotEmpty ? '$base ($code)' : base;
}
