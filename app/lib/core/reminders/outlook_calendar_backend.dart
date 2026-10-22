import 'dart:convert';

import '../../features/cloud/graph_client.dart';
import '../../features/cloud/microsoft_admin_consent.dart';
import '../../features/cloud/microsoft_oauth.dart';
import '../../features/cloud/onedrive_service.dart';
import '../services/external_launcher.dart';
import '../services/loopback_oauth.dart';
import 'agenda.dart';
import 'system_calendar.dart';

/// Accesso al calendario Outlook con l'account Microsoft già collegato per
/// OneDrive: stesso ID applicazione e tipo di account, ma un token
/// separato con lo scope `Calendars.ReadWrite` chiesto solo quando lo
/// studente attiva il calendario (consenso dinamico). Il flusso di OneDrive
/// non cambia: scollegando il calendario si toglie solo questo token.
class OutlookCalendarAuth {
  OutlookCalendarAuth(
    this.onedrive, {
    LoopbackOAuth Function(String clientId, String tenant)? oauthFactory,
  }) : _oauthFactory = oauthFactory ?? _defaultOAuth;

  final OneDriveService onedrive;
  final LoopbackOAuth Function(String clientId, String tenant) _oauthFactory;

  static const refreshKey = 'outlook_calendar.refreshToken';

  CloudSecrets get _secrets => onedrive.secrets;
  OAuthTokens? _tokens;

  static LoopbackOAuth _defaultOAuth(String clientId, String tenant) =>
      MicrosoftOAuth(
        clientId: clientId,
        tenant: tenant,
        scope: MicrosoftOAuth.calendarScope,
        openBrowser: (u) async => (await ExternalLauncher.openUrl('$u')).ok,
      );

  /// Account Microsoft collegato (Collegamenti → OneDrive).
  Future<bool> microsoftConnected() => onedrive.connected();

  /// Consenso al calendario già dato.
  Future<bool> connected() async {
    try {
      return (await _secrets.read(refreshKey))?.isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  Future<LoopbackOAuth> _oauth() async =>
      _oauthFactory(await onedrive.clientId(), await onedrive.tenant());

  /// Chiede l'accesso al calendario: prima in silenzio con l'accesso di
  /// OneDrive (se il consenso c'è già), poi con la pagina di Microsoft
  /// sull'account collegato. Con [chooseAccount] (l'ateneo blocca l'account
  /// universitario: «Usa un account Microsoft personale») si va subito alla
  /// pagina di Microsoft, con la scelta dell'account e senza suggerirlo.
  Future<void> connect({bool chooseAccount = false}) async {
    if (!await microsoftConnected()) {
      throw CalendarAccessException(
        'Collega prima il tuo account Microsoft in Collegamenti → OneDrive.',
      );
    }
    final oauth = chooseAccount
        ? _oauthFactory(
            await onedrive.clientId(),
            MicrosoftAdminConsent.tenantForPersonal(await onedrive.tenant()),
          )
        : await _oauth();
    if (chooseAccount) {
      await _store(await oauth.signIn());
      return;
    }
    final odRefresh = await _secrets.read(onedrive.refreshKey);
    OAuthTokens? t;
    if (odRefresh != null) {
      try {
        t = await oauth.refresh(odRefresh);
      } on OAuthException {
        t = null; // serve il consenso: pagina di Microsoft
      }
    }
    if (t == null) {
      final who = await onedrive.account() ?? '';
      final hint = who
          .split(' · ')
          .firstWhere((x) => x.contains('@'), orElse: () => '');
      t = await oauth.signIn(loginHint: hint.isEmpty ? null : hint);
    }
    await _store(t);
  }

  Future<void> _store(OAuthTokens t) async {
    final refresh = t.refreshToken;
    if (refresh == null) {
      throw OAuthException('Microsoft non ha restituito un token permanente.');
    }
    await _secrets.write(refreshKey, refresh);
    _tokens = t;
  }

  Future<void> disconnect() async {
    _tokens = null;
    try {
      await _secrets.delete(refreshKey);
    } catch (_) {}
  }

  Future<String> accessToken() async {
    final t = _tokens;
    if (t != null && t.valid) return t.accessToken;
    final refresh = await _secrets.read(refreshKey);
    if (refresh == null) {
      throw CalendarAccessException(
        'Calendario Outlook non collegato.',
        expired: true,
      );
    }
    try {
      final n = await (await _oauth()).refresh(refresh);
      _tokens = n;
      if (n.refreshToken != null && n.refreshToken != refresh) {
        await _secrets.write(refreshKey, n.refreshToken!);
      }
      return n.accessToken;
    } on OAuthException catch (e) {
      if (isExpiredGrant(e.message)) {
        throw CalendarAccessException(
          'L\'accesso al calendario Outlook è scaduto o è stato revocato: '
          'ricollegalo.',
          expired: true,
        );
      }
      rethrow;
    }
  }
}

/// Calendario Outlook dell'account Microsoft (Windows), con Microsoft Graph.
///
/// Gli eventi vanno nel calendario principale dell'account («Calendario»,
/// quello che Outlook mostra a colpo d'occhio su PC, web e telefono) o in
/// quello scelto in Impostazioni → Calendario. Le versioni precedenti li
/// scrivevano in un calendario a parte «UniNotes» che Outlook elenca sotto
/// «I miei calendari» ma spesso non mostra (casella non spuntata, app
/// Calendario di Windows, Outlook sul telefono): lo studente non vedeva
/// nulla. Ora quegli eventi si spostano e il calendario «UniNotes» vuoto si
/// elimina. Eventi legati alla prova da una proprietà estesa invisibile
/// (chiave stabile) e dall'id salvato, promemoria con
/// `reminderMinutesBeforeStart` (Outlook ne permette uno solo per evento:
/// si usa il più vicino alla prova).
class OutlookCalendarBackend implements CalendarBackend, RemovableCalendar {
  OutlookCalendarBackend(this.auth, {this.transport});

  final OutlookCalendarAuth auth;

  /// Trasporto HTTP di Graph (nei test: server finto).
  final GraphTransport? transport;

  /// Proprietà estesa con la chiave dell'evento (GUID fisso dell'app).
  static const keyProperty =
      'String {6f1d3c2a-8b4e-4f7a-9c35-2e8d1b7a4c60} Name UniNotesKey';

  @override
  String get id => 'outlook';

  @override
  String get label => 'calendario Outlook';

  GraphClient get _graph => GraphClient(auth.accessToken, transport: transport);

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on GraphException catch (e) {
      if (e.status == 401 || e.status == 403) {
        throw CalendarAccessException(
          'Outlook ha rifiutato l\'accesso al calendario: ricollegalo.',
          expired: true,
        );
      }
      rethrow;
    }
  }

  @override
  Future<bool> hasAccess() => auth.connected();

  @override
  Future<bool> requestAccess() async {
    await auth.connect();
    return true;
  }

  @override
  bool get localCalendarsAllowed => false;

  static int? _hex(Object? v) {
    if (v is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v)) return null;
    return 0xFF000000 | int.parse(v.substring(1), radix: 16);
  }

  /// Calendari dell'account (anche per i test): il principale è
  /// `isDefaultCalendar`, quelli condivisi in sola lettura hanno `canEdit`
  /// false, «UniNotes» (non principale) è quello delle versioni precedenti.
  static CalendarChoice? choiceOf(Map<String, Object?> c, String? me) {
    final id = c['id'];
    if (id is! String) return null;
    final name = '${c['name'] ?? 'Calendario'}';
    final owner = c['owner'] is Map ? (c['owner'] as Map)['address'] : null;
    final primary = c['isDefaultCalendar'] == true;
    return CalendarChoice(
      id: id,
      name: name,
      account: owner is String && owner.isNotEmpty ? owner : me,
      accountType: 'outlook',
      color: _hex(c['hexColor']),
      primary: primary,
      writable: c['canEdit'] != false,
      legacy: name == kCalendarName && !primary,
    );
  }

  @override
  Future<List<CalendarChoice>> calendars() => _call(() async {
    final list = await _graph.list('me/calendars', {
      r'$select': 'id,name,hexColor,isDefaultCalendar,canEdit,owner',
    });
    return [
      for (final c in list) ?choiceOf(c, null),
    ];
  });

  @override
  Future<CalendarHealth> health(CalendarChoice c) => _call(() async {
    final got = await _graph.getJson('me/calendars/${c.id}', {
      r'$select': 'id,canEdit',
    });
    if (got == null) {
      return CalendarHealth(
        problem:
            'Il calendario «${c.name}» non c\'è più nell\'account Microsoft: '
            'scegline un altro in Impostazioni → Calendario.',
      );
    }
    if (got['canEdit'] == false) {
      return CalendarHealth(
        problem:
            'Il calendario «${c.name}» è di sola lettura: scegline un altro.',
      );
    }
    return CalendarHealth.fine;
  });

  /// Eventi dell'app: solo quelli con la proprietà estesa (filtro di Graph),
  /// così nel calendario principale non si scorrono tutti gli eventi dello
  /// studente. Se Graph non accetta il filtro si leggono gli eventi da 400
  /// giorni fa a 3 anni da oggi.
  @override
  Future<Map<String, List<String>>> existing(String calendarId) =>
      _call(() async {
        final out = <String, List<String>>{};
        final expand =
            "singleValueExtendedProperties(\$filter=id eq '$keyProperty')";
        List<Map<String, Object?>> events;
        try {
          events = await _graph.list('me/calendars/$calendarId/events', {
            r'$select': 'id',
            r'$top': '200',
            r'$filter':
                "singleValueExtendedProperties/Any(ep: ep/id eq "
                "'$keyProperty' and ep/value ne null)",
            r'$expand': expand,
          });
        } on GraphException catch (e) {
          if (e.status != 400) rethrow;
          final now = DateTime.now().toUtc();
          events = await _graph.list('me/calendars/$calendarId/calendarView', {
            'startDateTime': now
                .subtract(const Duration(days: 400))
                .toIso8601String(),
            'endDateTime': now.add(const Duration(days: 1100)).toIso8601String(),
            r'$select': 'id',
            r'$top': '200',
            r'$expand': expand,
          });
        }
        for (final e in events) {
          final props = e['singleValueExtendedProperties'];
          final id = e['id'];
          if (props is! List || props.isEmpty || id is! String) continue;
          final key = (props.first as Map)['value'];
          if (key is String) (out[key] ??= []).add(id);
        }
        return out;
      });

  /// Corpo JSON dell'evento (anche per i test).
  static Map<String, Object?> eventJson(
    AgendaItem item,
    List<int> reminderMinutes,
  ) {
    String two(int v) => v.toString().padLeft(2, '0');
    String iso(DateTime d) =>
        '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:'
        '${two(d.minute)}:00';
    final DateTime start;
    final DateTime end;
    if (item.allDay) {
      start = DateTime.utc(item.date.year, item.date.month, item.date.day);
      end = DateTime.utc(item.date.year, item.date.month, item.date.day + 1);
    } else {
      start = item.start.toUtc();
      end = item.end.toUtc();
    }
    final reminder = reminderMinutes.isEmpty
        ? null
        : reminderMinutes.reduce((a, b) => a < b ? a : b);
    return {
      'subject': item.title,
      'body': {'contentType': 'text', 'content': item.notes ?? ''},
      'start': {'dateTime': iso(start), 'timeZone': 'UTC'},
      'end': {'dateTime': iso(end), 'timeZone': 'UTC'},
      'isAllDay': item.allDay,
      'showAs': item.kind == AgendaKind.session ? 'free' : 'busy',
      'location': {'displayName': item.location ?? ''},
      'isReminderOn': reminder != null,
      'reminderMinutesBeforeStart': ?reminder,
      'singleValueExtendedProperties': [
        {'id': keyProperty, 'value': item.key},
      ],
    };
  }

  @override
  Future<String> write(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) => _call(() async {
    final body = utf8.encode(jsonEncode(eventJson(item, reminderMinutes)));
    final r = await _graph.request(
      eventId == null ? 'POST' : 'PATCH',
      eventId == null
          ? 'me/calendars/$calendarId/events'
          : 'me/events/$eventId',
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    final id = r.status == 404 ? null : r.json['id'];
    if (id is! String) throw Exception('Evento Outlook non scritto.');
    return id;
  });

  @override
  Future<bool> deleteCalendarIfEmpty(String calendarId) => _call(() async {
    final c = await _graph.getJson('me/calendars/$calendarId', {
      r'$select': 'id,name,isDefaultCalendar',
    });
    if (c == null ||
        c['name'] != kCalendarName ||
        c['isDefaultCalendar'] == true) {
      return false;
    }
    final page = await _graph.getJson('me/calendars/$calendarId/events', {
      r'$select': 'id',
      r'$top': '1',
    });
    if ((page?['value'] as List? ?? const []).isNotEmpty) return false;
    await _graph.request('DELETE', 'me/calendars/$calendarId');
    return true;
  });

  @override
  Future<void> delete(String calendarId, String eventId) =>
      _call(() => _graph.request('DELETE', 'me/events/$eventId'));
}
