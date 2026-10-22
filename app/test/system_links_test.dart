import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/apple_calendar_backend.dart';
import 'package:university_notes/core/reminders/device_calendar_backend.dart';
import 'package:university_notes/core/reminders/native_calendar_backend.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/study/focus/focus_plan.dart';
import 'package:university_notes/features/study/focus/focus_service.dart';
import 'package:university_notes/features/study/focus/focus_system.dart';
import 'package:university_notes/features/study/focus/focus_timer.dart';

import 'support/fake_reminders.dart';

/// Collegamenti e funzioni di sistema: Non disturbare durante Focus
/// (Android, Windows, iOS/macOS) e calendario EventKit (iOS, macOS), con i
/// canali nativi finti.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Canale Focus finto: risponde con [answer] e ricorda le chiamate.
  List<MethodCall> mockFocus(Object? Function(MethodCall c) answer) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(FocusSystem.channel, (c) async {
      calls.add(c);
      return answer(c);
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(FocusSystem.channel, null),
    );
    return calls;
  }

  final until = DateTime(2026, 10, 19, 18, 30);

  group('Non disturbare: Android', () {
    const sys = FocusSystem(forcedKind: FocusSystemKind.androidDnd);

    test('attivo solo se il sistema lo conferma', () async {
      final calls = mockFocus(
        (c) => switch (c.method) {
          'dndAccess' => true,
          'setDnd' => true,
          _ => null,
        },
      );
      final r = await sys.enable(until);
      expect(r.on, isTrue);
      final set = calls.firstWhere((c) => c.method == 'setDnd');
      expect(set.arguments, {
        'on': true,
        'untilMs': until.millisecondsSinceEpoch,
      });
    });

    test('senza accesso non si prova nemmeno', () async {
      final calls = mockFocus((c) => c.method == 'dndAccess' ? false : true);
      final r = await sys.enable(until);
      expect(r.failure, QuietFailure.noAccess);
      expect(calls.where((c) => c.method == 'setDnd'), isEmpty);
    });

    test('il sistema non lo applica: lo si dice', () async {
      mockFocus(
        (c) => switch (c.method) {
          'dndAccess' => true,
          'setDnd' => false,
          _ => null,
        },
      );
      final r = await sys.enable(until);
      expect(r.failure, QuietFailure.notApplied);
      expect(
        focusSystemHint(FocusSystemKind.androidDnd, failure: r.failure),
        contains('UniNotes'),
      );
    });

    test('stato reale letto dal sistema', () async {
      mockFocus((c) => c.method == 'dndActive' ? false : null);
      expect(await sys.isActive(), isFalse);
    });
  });

  group('Non disturbare: Windows', () {
    const sys = FocusSystem(forcedKind: FocusSystemKind.windowsFocus);

    test('sessione rifiutata da Windows (accesso limitato)', () async {
      final calls = mockFocus(
        (c) => c.method == 'winFocusStart' ? 'negato' : null,
      );
      final r = await sys.enable(until);
      expect(r.failure, QuietFailure.windowsDenied);
      expect(
        (calls.single.arguments as Map)['endMs'],
        until.millisecondsSinceEpoch,
      );
      final hint = focusSystemHint(
        FocusSystemKind.windowsFocus,
        failure: r.failure,
      );
      expect(hint, contains('autorizzate da Microsoft'));
      expect(hint, contains('Win+N'));
    });

    test('esiti del codice nativo', () {
      expect(windowsFocusOutcome('ok').on, isTrue);
      expect(windowsFocusOutcome(true).on, isTrue);
      expect(
        windowsFocusOutcome('non_supportato').failure,
        QuietFailure.windowsUnsupported,
      );
      expect(windowsFocusOutcome(null).failure, QuietFailure.other);
    });
  });

  group('Non disturbare: iOS e macOS', () {
    test('comando con x-callback-url verso UniNotes', () {
      final u = appleShortcutUri(until);
      expect(u.scheme, 'shortcuts');
      expect(u.host, 'x-callback-url');
      expect(u.path, '/run-shortcut');
      expect(u.queryParameters['name'], kAppleFocusShortcut);
      expect(u.queryParameters['text'], '2026-10-19 18:30');
      expect(u.queryParameters['x-success'], 'uninotes://focus/ok');
      expect(u.queryParameters['x-cancel'], 'uninotes://focus/annullato');
      expect(u.queryParameters['x-error'], 'uninotes://focus/errore');
      // spazi codificati come %20 (Comandi non legge il «+»)
      expect(u.toString(), isNot(contains('+')));
    });

    test('esito del comando', () {
      expect(appleShortcutOutcome('ok'), isNull);
      expect(appleShortcutOutcome('annullato'), QuietFailure.shortcutCancelled);
      expect(appleShortcutOutcome('errore'), QuietFailure.shortcutFailed);
      expect(
        focusSystemHint(
          FocusSystemKind.appleFocus,
          failure: QuietFailure.shortcutFailed,
          macOS: false,
        ),
        contains(kAppleFocusShortcut),
      );
      expect(
        focusSystemHint(FocusSystemKind.appleFocus, macOS: true),
        contains('barra dei menu'),
      );
    });
  });

  group('Non disturbare nella sessione Focus', () {
    test('stato e motivo nella sessione, spento a mano', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      var active = true;
      mockFocus(
        (c) => switch (c.method) {
          'dndAccess' => true,
          'setDnd' => true,
          'dndActive' => active,
          _ => null,
        },
      );
      final now = DateTime(2026, 10, 19, 9);
      final f = FocusService(
        s,
        timer: FocusTimer(clock: () => now, tick: false),
        system: const FocusSystem(forcedKind: FocusSystemKind.androidDnd),
      );
      addTearDown(f.dispose);
      await f.start(
        const FocusSettings(minutes: 30),
        const FocusLink(),
        systemDnd: true,
      );
      expect(f.systemQuiet, isTrue);
      expect(f.quietFailure, isNull);
      // l'utente lo spegne dalla tendina: al ritorno nell'app lo si vede
      active = false;
      final g = FocusService(
        s,
        timer: FocusTimer(clock: () => now, tick: false),
        system: const FocusSystem(forcedKind: FocusSystemKind.androidDnd),
      );
      addTearDown(g.dispose);
      await g.load();
      for (var i = 0; i < 50 && g.systemQuiet; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(g.systemQuiet, isFalse);
      expect(g.quietFailure, QuietFailure.turnedOff);
      await f.discard();
    });

    test('Windows rifiuta: messaggio e pulsante per le impostazioni', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      mockFocus((c) => c.method == 'winFocusStart' ? 'negato' : null);
      final f = FocusService(
        s,
        timer: FocusTimer(clock: () => DateTime(2026, 10, 19, 9), tick: false),
        system: const FocusSystem(forcedKind: FocusSystemKind.windowsFocus),
      );
      addTearDown(f.dispose);
      await f.start(
        const FocusSettings(minutes: 30),
        const FocusLink(),
        systemDnd: true,
      );
      expect(f.systemQuiet, isFalse);
      expect(f.windowsFailed, isTrue);
      expect(f.quietFailure, QuietFailure.windowsDenied);
      await f.discard();
    });
  });

  group('calendario del telefono (Android)', () {
    test('giornata intera: mezzanotte UTC del giorno e del giorno dopo', () {
      final a = AndroidCalendarBackend.eventArgs(
        '7',
        examItem(1, DateTime(2027, 2, 10)),
        const [1440],
      );
      expect(a['allDay'], isTrue);
      expect(a['startMs'], DateTime.utc(2027, 2, 10).millisecondsSinceEpoch);
      expect(a['endMs'], DateTime.utc(2027, 2, 11).millisecondsSinceEpoch);
      expect(a['alarms'], [1440]);
      final t = AndroidCalendarBackend.eventArgs(
        '7',
        examItem(2, DateTime(2027, 2, 10), time: '09:00'),
        const [60],
      );
      expect(t['startMs'], DateTime(2027, 2, 10, 9).millisecondsSinceEpoch);
      expect(t['endMs'], DateTime(2027, 2, 10, 11).millisecondsSinceEpoch);
    });

    test('controllo di salute: grave → calendario interno, sync spenta → '
        'solo avviso', () {
      const c = CalendarChoice(
        id: '7',
        name: 'Personale',
        account: 'studente@gmail.com',
      );
      expect(
        NativeCalendarBackend.healthOf(const {'exists': false}, c).ok,
        isFalse,
      );
      expect(
        NativeCalendarBackend.healthOf(const {
          'exists': true,
          'writable': true,
          'synced': false,
        }, c).problem,
        contains('non è sincronizzato'),
      );
      final off = NativeCalendarBackend.healthOf(const {
        'exists': true,
        'writable': true,
        'synced': true,
        'autoSync': false,
        'masterSync': true,
      }, c);
      expect(off.ok, isTrue);
      expect(off.warning, contains('studente@gmail.com'));
      expect(
        NativeCalendarBackend.healthOf(const {
          'exists': true,
          'writable': true,
          'synced': true,
          'autoSync': true,
          'masterSync': true,
        }, c).warning,
        isNull,
      );
    });

    test('scelta predefinita: il principale di Google, mai un locale', () {
      const local = CalendarChoice(
        id: '1',
        name: 'UniNotes',
        accountType: 'LOCAL',
        synced: false,
        legacy: true,
      );
      const samsung = CalendarChoice(
        id: '2',
        name: 'Calendario',
        accountType: 'com.samsung',
        primary: true,
      );
      const google = CalendarChoice(
        id: '3',
        name: 'studente@gmail.com',
        accountType: 'com.google',
        primary: true,
      );
      const other = CalendarChoice(
        id: '4',
        name: 'Festività',
        accountType: 'com.google',
        writable: false,
      );
      expect(pickCalendar([local, samsung, google, other], null)?.id, '3');
      expect(pickCalendar([local, samsung, google], '2')?.id, '2');
      // scelto ma non più utilizzabile: il predefinito
      expect(pickCalendar([local, samsung, google, other], '4')?.id, '3');
      expect(pickCalendar([local], null), isNull);
    });
  });

  group('calendario EventKit (iOS, macOS)', () {
    late _FakeEventKit kit;
    late AppleCalendarBackend backend;
    setUp(() {
      kit = _FakeEventKit();
      messenger.setMockMethodCallHandler(
        AppleCalendarBackend.kChannel,
        kit.handle,
      );
      backend = AppleCalendarBackend();
    });
    tearDown(
      () => messenger.setMockMethodCallHandler(
        AppleCalendarBackend.kChannel,
        null,
      ),
    );

    test('giornata intera: mezzanotte locale, fine uguale all\'inizio', () {
      final a = AppleCalendarBackend.eventArgs(
        'c',
        examItem(1, DateTime(2027, 2, 10)),
        const [900],
      );
      expect(a['allDay'], isTrue);
      expect(a['startMs'], DateTime(2027, 2, 10).millisecondsSinceEpoch);
      expect(a['endMs'], a['startMs']);
      expect(a['notes'], endsWith('Rif. UniNotes: esame-1'));
      expect(a.containsKey('eventId'), isFalse);
      final t = AppleCalendarBackend.eventArgs(
        'c',
        examItem(2, DateTime(2027, 2, 10), time: '09:30'),
        const [],
        eventId: 'e1',
      );
      expect(t['startMs'], DateTime(2027, 2, 10, 9, 30).millisecondsSinceEpoch);
      expect(t['endMs'], DateTime(2027, 2, 10, 11, 30).millisecondsSinceEpoch);
      expect(t['eventId'], 'e1');
    });

    test('aggiorna lo stesso evento, lo ricrea se tolto, lo ritrova dopo '
        'una reinstallazione', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      final sync = SystemCalendarSync(s.settings, backend);
      await sync.setEnabled(true);
      final now = DateTime(2027, 1, 10);
      final a = examItem(1, DateTime(2027, 2, 10));

      var st = await sync.sync([a], const [7, 1], now: now);
      expect(st.working, isTrue);
      expect(kit.events.length, 1);
      final id = kit.events.keys.single;

      // modifica nell'app: stesso evento aggiornato, nessun doppione
      st = await sync.sync([withLocation(a, 'Aula 5')], const [7, 1], now: now);
      expect(st.working, isTrue);
      expect(kit.events.keys, [id]);
      expect(kit.events[id]!['location'], 'Aula 5');
      expect(kit.updates, 1);

      // tolto a mano dal calendario: si ricrea
      kit.events.clear();
      st = await sync.sync([withLocation(a, 'Aula 6')], const [7, 1], now: now);
      expect(st.working, isTrue);
      expect(kit.events.length, 1);

      // reinstallazione: impostazioni vuote, il calendario «UniNotes» e i
      // suoi eventi restano; si ritrovano dalla riga «Rif. UniNotes»
      final db2 = await AppDatabase.openInMemory();
      addTearDown(db2.close);
      final s2 = AppServices(db2);
      final sync2 = SystemCalendarSync(s2.settings, backend);
      await sync2.setEnabled(true);
      final before = kit.events.keys.toList();
      st = await sync2.sync(
        [withLocation(a, 'Aula 7')],
        const [7, 1],
        now: now,
      );
      expect(st.working, isTrue);
      expect(kit.events.keys, before);
      expect(kit.events.values.single['location'], 'Aula 7');
      // nel calendario predefinito, nessun calendario creato
      expect(kit.events.values.single['calendarId'], 'def');
      expect(kit.calendarsCreated, 0);
      expect(st.calendarName, 'Calendario');
    });

    test('calendario «UniNotes» delle versioni precedenti: eventi spostati '
        'nel predefinito e calendario tolto', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      kit.calendars['old'] = 'UniNotes';
      kit.events['vecchio'] = {
        'calendarId': 'old',
        'notes': 'Rif. UniNotes: esame-1',
      };
      final sync = SystemCalendarSync(s.settings, backend);
      await sync.setEnabled(true);
      await s.settings.set(CalendarKeys.calendarId, 'old');
      final st = await sync.sync(
        [examItem(1, DateTime(2027, 2, 10))],
        const [1],
        now: DateTime(2027, 1, 10),
      );
      expect(st.working, isTrue);
      expect(kit.calendars.keys, ['def']);
      expect(kit.events.length, 1);
      expect(kit.events.values.single['calendarId'], 'def');
    });

    test('permesso negato: collegamento non funzionante', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      final sync = SystemCalendarSync(s.settings, backend);
      await sync.setEnabled(true);
      kit.access = 'negato';
      await expectLater(
        sync.sync([examItem(1, DateTime(2027, 2, 10))], const [1]),
        throwsA(isA<CalendarAccessException>()),
      );
      expect((await sync.status()).working, isFalse);
    });

    test('calendario vuoto eliminato solo se è «UniNotes»', () async {
      kit.calendars['old'] = 'UniNotes';
      expect(await backend.deleteCalendarIfEmpty('def'), isFalse);
      expect(await backend.deleteCalendarIfEmpty('old'), isTrue);
      expect(kit.calendars.keys, ['def']);
    });
  });
}

/// EventKit finto: calendari ed eventi in memoria, come UniNotesCalendar
/// (`def` è il calendario predefinito per i nuovi eventi).
class _FakeEventKit {
  String access = 'concesso';
  final calendars = <String, String>{'def': 'Calendario'};
  final events = <String, Map<Object?, Object?>>{};
  int calendarsCreated = 0;
  int updates = 0;
  int _next = 0;

  Future<Object?> handle(MethodCall c) async {
    final a = (c.arguments as Map?) ?? const {};
    if (c.method == 'access') return access;
    if (c.method == 'request') return access == 'concesso';
    if (access != 'concesso') {
      throw PlatformException(code: 'permesso');
    }
    switch (c.method) {
      case 'calendars':
        return [
          for (final e in calendars.entries)
            {
              'id': e.key,
              'name': e.value,
              'account': 'iCloud',
              'primary': e.key == 'def',
              'synced': true,
              'writable': true,
              'legacy': e.value == 'UniNotes' && e.key != 'def',
            },
        ];
      case 'health':
        return {
          'exists': calendars.containsKey(a['calendarId']),
          'writable': true,
          'synced': true,
        };
      case 'ensureCalendar':
        final known = a['knownId'];
        if (calendars.containsKey(known)) return known;
        for (final e in calendars.entries) {
          if (e.value == a['name']) return e.key;
        }
        calendarsCreated++;
        final id = 'cal${_next++}';
        calendars[id] = a['name'] as String;
        return id;
      case 'events':
        return [
          for (final e in events.entries)
            if (e.value['calendarId'] == a['calendarId'])
              {'id': e.key, 'notes': e.value['notes']},
        ];
      case 'write':
        final id = a['eventId'] as String?;
        if (id != null && !events.containsKey(id)) {
          throw PlatformException(code: 'non_trovato');
        }
        if (id != null) updates++;
        final key = id ?? 'ev${_next++}';
        events[key] = Map.of(a);
        return key;
      case 'delete':
        events.remove(a['eventId']);
        return null;
      case 'deleteCalendarIfEmpty':
        final id = a['calendarId'];
        if (calendars[id] != a['name']) return false;
        if (events.values.any((e) => e['calendarId'] == id)) return false;
        calendars.remove(id);
        return true;
    }
    return null;
  }
}
