import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/sync_schema.dart';
import 'package:university_notes/core/reminders/agenda.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/reminders/windows_toast_icon.dart';
import 'package:university_notes/features/settings/sections/calendar_section.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_reminders.dart';

/// Calendario vero dello studente (progetto del 21/10/2026): promemoria un
/// giorno e un'ora prima, calendario interno come ripiego, controllo di
/// salute, migrazione dal calendario «UniNotes» e un solo dispositivo che
/// scrive per account.
void main() {
  final now = DateTime(2027, 1, 5, 10);
  late AppDatabase db;
  late SettingsRepository settings;
  late FakeCalendarBackend backend;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    settings = SettingsRepository(db);
    backend = FakeCalendarBackend();
  });
  tearDown(() => db.close());

  SystemCalendarSync syncFor(String install, {String name = 'telefono'}) =>
      SystemCalendarSync(
        settings,
        backend,
        device: CalendarDevice(installId: () async => install, name: name),
      );

  group('promemoria', () {
    test('un giorno e un\'ora prima (predefiniti), l\'ora solo con l\'orario',
        () {
      final timed = examItem(1, DateTime(2027, 2, 10), time: '09:00');
      final allDay = examItem(2, DateTime(2027, 2, 12));
      expect(
        reminderTimes(timed, kDefaultExamOffsets, kDefaultExamHours)
            .map((r) => r.at),
        [DateTime(2027, 2, 9, 9), DateTime(2027, 2, 10, 8)],
      );
      expect(
        calendarReminderMinutes(timed, kDefaultExamOffsets, kDefaultExamHours),
        [1440, 60],
      );
      expect(
        calendarReminderMinutes(allDay, kDefaultExamOffsets, kDefaultExamHours),
        [900],
      );
    });

    test('testi: «Esame domani…» e «Tra 1 ora…» con orario e aula', () {
      final timed = AgendaItem(
        key: examAgendaKey(1),
        kind: AgendaKind.exam,
        title: 'Esame: Analisi I',
        subject: 'Analisi I',
        date: DateTime(2027, 2, 10),
        time: '09:00',
        location: 'Aula 5',
        examId: 1,
      );
      final p = planNotifications(
        now: now,
        prefs: const NotificationPrefs(consent: true, donation: false),
        agenda: [timed],
      );
      expect(p.map((n) => n.title), [
        'Esame domani: Analisi I',
        'Tra 1 ora: Analisi I',
      ]);
      expect(p.first.body, 'mercoledì 10 febbraio alle 09:00 · Aula 5');
      expect(p.last.body, 'Esame alle 09:00 · Aula 5');
      expect(p.last.payload, 'prova:1');
    });

    test('di notte senza suono', () {
      final early = examItem(1, DateTime(2027, 2, 10), time: '07:30');
      final p = planNotifications(
        now: now,
        prefs: const NotificationPrefs(consent: true, donation: false),
        agenda: [early],
      );
      final hour = p.firstWhere((n) => n.title.startsWith('Tra 1 ora'));
      expect(hour.at, DateTime(2027, 2, 10, 6, 30));
      expect(hour.silent, isTrue);
      expect(p.firstWhere((n) => n.title.contains('domani')).silent, isFalse);
    });
  });

  group('calendario vero', () {
    test('eventi nel calendario principale, con promemoria e nome mostrato',
        () async {
      final sync = syncFor('a1');
      await sync.setEnabled(true);
      final st = await sync.sync(
        [examItem(1, DateTime(2027, 2, 10), time: '09:00')],
        kDefaultExamOffsets,
        offsetHours: kDefaultExamHours,
        now: now,
      );
      expect(st.working, isTrue);
      expect(st.calendarName, 'Calendario');
      expect(st.account, 'studente@gmail.com');
      expect(backend.calendarId, 'cal-1');
      expect(backend.events.values.single.reminders, [1440, 60]);
      expect(
        CalendarStatusLine.text(st),
        contains('1 evento nel calendario «Calendario» · studente@gmail.com'),
      );
    });

    test('nessun calendario sincronizzato: calendario interno (avvisa l\'app)',
        () async {
      backend.noCalendars = true;
      final sync = syncFor('a1');
      await sync.setEnabled(true);
      final st = await sync.sync(
        [examItem(1, DateTime(2027, 2, 10))],
        const [1],
        now: now,
      );
      expect(st.working, isFalse);
      expect(st.internal, isTrue);
      expect(st.error, contains('le notifiche delle prove le manda l\'app'));
      expect(backend.events, isEmpty);
      // le notifiche dell'app tornano per tutte le prove
      final plan = planNotifications(
        now: now,
        prefs: const NotificationPrefs(consent: true, donation: false),
        agenda: [examItem(1, DateTime(2027, 2, 10))],
        calendarWorking: st.working,
        calendarWritten: st.written,
      );
      expect(plan, isNotEmpty);
      expect(CalendarStatusLine.text(st), startsWith('Calendario interno'));
    });

    test('controllo di salute grave → interno; sincronizzazione spenta → '
        'avviso, eventi scritti', () async {
      final sync = syncFor('a1');
      await sync.setEnabled(true);
      backend.healthResult = const CalendarHealth(problem: 'sparito');
      var st = await sync.sync([examItem(1, DateTime(2027, 2, 10))], const [1]);
      expect(st.working, isFalse);
      expect(st.error, 'sparito');
      backend.healthResult = const CalendarHealth(warning: 'sync spenta');
      st = await sync.sync([examItem(1, DateTime(2027, 2, 10))], const [1]);
      expect(st.working, isTrue);
      expect(st.warning, 'sync spenta');
      expect(backend.events.length, 1);
    });

    test('calendario scelto: gli eventi si spostano, niente doppioni', () async {
      backend.extra.add(
        const CalendarChoice(
          id: 'cal-2',
          name: 'Università',
          account: 'studente@gmail.com',
          accountType: 'com.google',
        ),
      );
      final sync = syncFor('a1');
      await sync.setEnabled(true);
      final items = [examItem(1, DateTime(2027, 2, 10))];
      await sync.sync(items, const [1], now: now);
      expect(backend.eventCalendar.values.toSet(), {'cal-1'});
      await sync.choose('cal-2');
      final st = await sync.sync(items, const [1], now: now);
      expect(st.calendarName, 'Università');
      expect(backend.events.length, 1);
      expect(backend.eventCalendar[backend.events.keys.single], 'cal-2');
    });

    test('calendario «UniNotes» delle versioni precedenti: svuotato', () async {
      backend.extra.add(
        const CalendarChoice(
          id: 'old',
          name: 'UniNotes',
          accountType: 'LOCAL',
          synced: false,
          legacy: true,
        ),
      );
      final sync = syncFor('a1');
      await sync.setEnabled(true);
      // evento scritto da una versione precedente nel calendario locale
      await backend.write('old', examItem(1, DateTime(2027, 2, 10)), const []);
      await settings.set(CalendarKeys.calendarId, 'old');
      await settings.set(CalendarKeys.backend, 'device');
      await sync.sync([examItem(1, DateTime(2027, 2, 10))], const [1]);
      expect(backend.eventCalendar.values.toSet(), {'cal-1'});
      expect(backend.events.length, 1);
    });
  });

  group('un solo dispositivo scrive per account', () {
    test('il primo scrive; il secondo legge e non manda notifiche doppie',
        () async {
      final items = [examItem(1, DateTime(2027, 2, 10))];
      final phone = syncFor('aa1111');
      await phone.setEnabled(true);
      var st = await phone.sync(items, const [1], now: now);
      expect(st.writtenBy, isNull);
      expect(backend.writes, 1);
      final writers = await settings.get(CalendarKeys.writers);
      expect(writers, contains('aa1111'));

      // secondo telefono con gli stessi dati sincronizzati (stesse
      // impostazioni) e lo stesso account
      final tablet = syncFor('bb2222');
      st = await tablet.sync(items, const [1], now: now);
      expect(st.writtenBy, 'telefono aa1111');
      expect(st.working, isTrue);
      expect(st.written, {items.single.key});
      expect(backend.writes, 1);
      expect(
        CalendarStatusLine.text(st, thisDevice: 'telefono'),
        contains('Calendario aggiornato dall\'altro telefono (aa1111)'),
      );

      // «Aggiorna da questo dispositivo»
      await tablet.takeOver(now: now);
      st = await tablet.sync(items, const [1], now: now);
      expect(st.writtenBy, isNull);
      st = await phone.sync(items, const [1], now: now);
      expect(st.writtenBy, 'telefono bb2222');
    });

    test('dispositivo che non si sente da 3 settimane: si prende il posto',
        () async {
      final items = [examItem(1, DateTime(2027, 2, 10))];
      await syncFor('aa1111').setEnabled(true);
      await syncFor('aa1111').sync(items, const [1], now: now);
      final later = now.add(kCalendarWriterStale + const Duration(days: 1));
      final st = await syncFor('bb2222').sync(items, const [1], now: later);
      expect(st.writtenBy, isNull);
    });

    test('la scelta del dispositivo si sincronizza con i dati', () {
      expect(SyncSchema.isSyncedSetting(CalendarKeys.writers), isTrue);
      expect(SyncSchema.isSyncedSetting(CalendarKeys.chosen), isFalse);
      expect(SyncSchema.isSyncedSetting(CalendarKeys.events), isFalse);
    });

    test('etichette del dispositivo che scrive', () {
      expect(calendarWriterLabel('PC 281078'), 'dal PC');
      expect(
        calendarWriterLabel('telefono ea12a6', thisDevice: 'telefono'),
        'dall\'altro telefono (ea12a6)',
      );
      expect(calendarWriterLabel('Mac 1', thisDevice: 'PC'), 'dal Mac');
    });
  });

  group('icona dei toast di Windows', () {
    test('IconUri letto da «reg query»', () {
      const empty =
          '\r\nHKEY_CURRENT_USER\\Software\\Classes\\AppUserModelId\\x\r\n'
          '    IconUri    REG_SZ    \r\n';
      expect(WindowsToastIcon.iconUriOf(empty), isNull);
      const set =
          '    IconUri    REG_SZ    C:\\App\\data\\uninotes.png\r\n';
      expect(WindowsToastIcon.iconUriOf(set), 'C:\\App\\data\\uninotes.png');
      expect(WindowsToastIcon.iconUriOf(''), isNull);
    });

    test('si riscrive se manca, se il file non c\'è o se è un altro', () {
      const want = 'C:\\App\\data\\uninotes.png';
      expect(WindowsToastIcon.needsUpdate(null, want, false), isTrue);
      expect(WindowsToastIcon.needsUpdate(want, want, false), isTrue);
      expect(WindowsToastIcon.needsUpdate('C:\\Old\\a.png', want, true), isTrue);
      expect(WindowsToastIcon.needsUpdate(want.toLowerCase(), want, true), isFalse);
    });
  });
}
