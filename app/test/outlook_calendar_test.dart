import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/outlook_calendar_backend.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_reminders.dart';

/// Accesso finto: [refreshFails] simula il token scaduto o revocato, [silent]
/// il consenso al calendario già dato (rinnovo senza pagina di Microsoft).
class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth(this.log)
    : super(
        providerName: 'Microsoft',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('https://login.example/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );
  final List<String> log;
  static bool silent = false;
  static bool refreshFails = false;

  OAuthTokens _t(String r) => OAuthTokens(
    accessToken: 'a',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshToken: r,
  );

  @override
  Future<OAuthTokens> signIn({
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    log.add('signIn $loginHint');
    return _t('cal-refresh');
  }

  @override
  Future<OAuthTokens> refresh(String refreshToken) async {
    log.add('refresh $refreshToken');
    if (refreshFails) {
      throw OAuthException(
        'Microsoft ha rifiutato l\'accesso: AADSTS700082: expired',
      );
    }
    if (refreshToken == 'od-refresh' && !silent) {
      throw OAuthException('AADSTS65001: consent_required');
    }
    return _t(refreshToken);
  }
}

/// Outlook finto: calendari ed eventi in memoria (`def` = «Calendario»,
/// il principale dell'account).
class _FakeOutlook {
  final calendars = <String, String>{'def': 'Calendario'}; // id → nome
  final events = <String, Map<String, Object?>>{}; // id → corpo
  final eventCalendar = <String, String>{}; // id evento → calendario
  bool rejectFilter = false;
  var _n = 0;
  final requests = <String>[];

  GraphResponse _json(int status, Object body) =>
      GraphResponse(status, Uint8List.fromList(utf8.encode(jsonEncode(body))));

  Future<GraphResponse> call(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final path = url.path.replaceFirst('/v1.0/', '');
    requests.add('$method $path');
    final json = body == null
        ? null
        : (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
    if (path == 'me/calendars' && method == 'GET') {
      return _json(200, {
        'value': [
          for (final e in calendars.entries)
            {
              'id': e.key,
              'name': e.value,
              'isDefaultCalendar': e.key == 'def',
              'canEdit': true,
              'owner': {'address': 'studente@outlook.it'},
            },
        ],
      });
    }
    final del = RegExp(r'^me/calendars/([^/]+)$').firstMatch(path);
    if (del != null && method == 'DELETE') {
      calendars.remove(del[1]);
      return GraphResponse(204, Uint8List(0));
    }
    if (path == 'me/calendars' && method == 'POST') {
      final id = 'c${_n++}';
      calendars[id] = json!['name'] as String;
      return _json(201, {'id': id});
    }
    final cal = RegExp(r'^me/calendars/([^/]+)$').firstMatch(path);
    if (cal != null) {
      return calendars.containsKey(cal[1])
          ? _json(200, {
              'id': cal[1],
              'name': calendars[cal[1]],
              'isDefaultCalendar': cal[1] == 'def',
              'canEdit': true,
            })
          : _json(404, {
              'error': {'code': 'ErrorItemNotFound'},
            });
    }
    final evs = RegExp(
      r'^me/calendars/([^/]+)/(events|calendarView)$',
    ).firstMatch(path);
    if (evs != null && method == 'GET') {
      if (url.queryParameters.containsKey(r'$filter') && rejectFilter) {
        return _json(400, {
          'error': {'message': 'filtro non supportato'},
        });
      }
      final pageCal = evs[1]!;
      final calEvents = [
        for (final e in events.entries)
          if ((eventCalendar[e.key] ?? 'def') == pageCal) e,
      ];
      // senza $top=1 (controllo «vuoto») solo gli eventi dell'app
      return _json(200, {
        'value': [
          for (final e in calEvents)
            {'id': e.key, 'singleValueExtendedProperties': e.value['ext']},
        ],
      });
    }
    if (evs != null && method == 'POST') {
      final id = 'e${_n++}';
      events[id] = {...json!, 'ext': json['singleValueExtendedProperties']};
      eventCalendar[id] = evs[1]!;
      return _json(201, {'id': id});
    }
    final ev = RegExp(r'^me/events/([^/]+)$').firstMatch(path);
    if (ev != null) {
      final id = ev[1]!;
      if (!events.containsKey(id)) {
        return _json(404, {
          'error': {'code': 'ErrorItemNotFound'},
        });
      }
      if (method == 'DELETE') {
        events.remove(id);
        eventCalendar.remove(id);
        return GraphResponse(204, Uint8List(0));
      }
      events[id] = {...events[id]!, ...json!};
      return _json(200, {'id': id});
    }
    return _json(400, {
      'error': {'message': 'non previsto: $method $path'},
    });
  }
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late MemoryCloudSecrets secrets;
  late OneDriveService onedrive;
  late List<String> log;
  late OutlookCalendarAuth auth;
  late _FakeOutlook outlook;
  late SystemCalendarSync sync;
  final now = DateTime(2027, 1, 5, 10);

  setUp(() async {
    db = await AppDatabase.openInMemory();
    settings = SettingsRepository(db);
    secrets = MemoryCloudSecrets();
    log = [];
    _FakeOAuth.silent = false;
    _FakeOAuth.refreshFails = false;
    onedrive = OneDriveService(
      settings,
      NotesStore(settings),
      secrets: secrets,
      builtInClientId: '24f57293-12b8-4d3d-b33f-f55effdaa44f',
    );
    auth = OutlookCalendarAuth(
      onedrive,
      oauthFactory: (_, _) => _FakeOAuth(log),
    );
    outlook = _FakeOutlook();
    sync = SystemCalendarSync(
      settings,
      OutlookCalendarBackend(auth, transport: outlook.call),
    );
  });
  tearDown(() => db.close());

  test('senza account Microsoft: si chiede di collegarlo', () async {
    expect(await auth.microsoftConnected(), isFalse);
    await expectLater(auth.connect(), throwsA(isA<CalendarAccessException>()));
  });

  test(
    'consenso dinamico: pagina di Microsoft sull\'account collegato',
    () async {
      await secrets.write(onedrive.refreshKey, 'od-refresh');
      await onedrive.setAccount('Studente · studente@outlook.it');
      await auth.connect();
      expect(log, ['refresh od-refresh', 'signIn studente@outlook.it']);
      expect(await secrets.read(OutlookCalendarAuth.refreshKey), 'cal-refresh');
      // il token di OneDrive non cambia
      expect(await secrets.read(onedrive.refreshKey), 'od-refresh');
    },
  );

  test(
    'ateneo che blocca: account personale scelto sulla pagina di Microsoft',
    () async {
      _FakeOAuth.silent = true;
      await secrets.write(onedrive.refreshKey, 'od-refresh');
      await onedrive.setAccount('Studente · studente@ateneo.it');
      await auth.connect(chooseAccount: true);
      // niente rinnovo silenzioso né account suggerito
      expect(log, ['signIn null']);
      expect(await secrets.read(OutlookCalendarAuth.refreshKey), 'cal-refresh');
      expect(await secrets.read(onedrive.refreshKey), 'od-refresh');
    },
  );

  test('consenso già dato: nessuna pagina di accesso', () async {
    _FakeOAuth.silent = true;
    await secrets.write(onedrive.refreshKey, 'od-refresh');
    await auth.connect();
    expect(log, ['refresh od-refresh']);
  });

  test(
    'eventi nel calendario principale dell\'account (nessun calendario a '
    'parte), senza doppioni',
    () async {
      await secrets.write(OutlookCalendarAuth.refreshKey, 'cal-refresh');
      await sync.setEnabled(true);
      final a = examItem(1, DateTime(2027, 2, 10));
      final b = examItem(2, DateTime(2027, 2, 12), time: '14:00');
      var st = await sync.sync([a, b], [7, 1], now: now);
      expect(st.working, isTrue);
      expect(outlook.calendars.values, ['Calendario']);
      expect(outlook.events.length, 2);
      expect(outlook.eventCalendar.values.toSet(), {'def'});
      expect(st.calendarName, 'Calendario');
      expect(st.account, 'studente@outlook.it');
      final ev = outlook.events.values.firstWhere(
        (e) => (e['ext'] as List).first['value'] == 'esame-1',
      );
      expect(ev['isAllDay'], isTrue);
      expect(ev['reminderMinutesBeforeStart'], 900);
      // di nuovo: nessuna scrittura
      outlook.requests.clear();
      await sync.sync([a, b], [7, 1], now: now);
      expect(outlook.requests.where((r) => !r.startsWith('GET')), isEmpty);
      // modifica e cancellazione
      st = await sync.sync([withLocation(b, 'Aula 3')], [7, 1], now: now);
      expect(outlook.events.length, 1);
      expect(
        (outlook.events.values.single['location'] as Map)['displayName'],
        'Aula 3',
      );
      expect(outlook.calendars.length, 1);
      expect(st.written, {b.key});
    },
  );

  test('versioni precedenti: eventi dal calendario «UniNotes» (che Outlook '
      'non mostrava) spostati nel principale, «UniNotes» eliminato', () async {
    await secrets.write(OutlookCalendarAuth.refreshKey, 'cal-refresh');
    await sync.setEnabled(true);
    outlook.calendars['old'] = 'UniNotes';
    outlook.events['vecchio'] = {
      'subject': 'Esame · Analisi I',
      'ext': [
        {'id': OutlookCalendarBackend.keyProperty, 'value': 'esame-1'},
      ],
    };
    outlook.eventCalendar['vecchio'] = 'old';
    await settings.set(CalendarKeys.calendarId, 'old');
    await settings.set(CalendarKeys.backend, 'outlook');
    final st = await sync.sync(
      [examItem(1, DateTime(2027, 2, 10))],
      [1],
      now: now,
    );
    expect(st.working, isTrue);
    expect(outlook.calendars.keys, ['def']);
    expect(outlook.events.keys, isNot(contains('vecchio')));
    expect(outlook.eventCalendar.values.toSet(), {'def'});
  });

  test('Graph non accetta il filtro: si leggono gli eventi del periodo', () async {
    await secrets.write(OutlookCalendarAuth.refreshKey, 'cal-refresh');
    await sync.setEnabled(true);
    outlook.rejectFilter = true;
    final a = examItem(1, DateTime(2027, 2, 10));
    var st = await sync.sync([a], [1], now: now);
    expect(st.working, isTrue);
    st = await sync.sync([a], [1], now: now);
    expect(outlook.events.length, 1);
    expect(outlook.requests.any((r) => r.endsWith('/calendarView')), isTrue);
  });

  test('token scaduto: collegamento interrotto', () async {
    await secrets.write(OutlookCalendarAuth.refreshKey, 'cal-refresh');
    await sync.setEnabled(true);
    _FakeOAuth.refreshFails = true;
    await expectLater(
      sync.sync([examItem(1, DateTime(2027, 2, 10))], [1], now: now),
      throwsA(
        isA<CalendarAccessException>().having(
          (e) => e.expired,
          'scaduto',
          true,
        ),
      ),
    );
    expect((await sync.status()).working, isFalse);
  });
}
