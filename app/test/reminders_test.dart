import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/agenda.dart';
import 'package:university_notes/core/reminders/home_widgets.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/outlook_calendar_backend.dart';
import 'package:university_notes/core/reminders/promo_rules.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/services/nudges.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_reminders.dart';

void main() {
  final now = DateTime(2027, 1, 5, 10);
  const on = NotificationPrefs(consent: true, donation: false);

  group('agenda', () {
    test('solo prove da sostenere future, sessioni del corso, ordinate', () {
      final agenda = buildAgenda(
        exams: [
          Exam(id: 1, courseId: 10, date: DateTime(2027, 1, 20), time: '9:30'),
          Exam(
            id: 2,
            courseId: 11,
            kind: ExamKind.midterm,
            date: DateTime(2027, 1, 12),
            title: 'Esonero 1',
          ),
          // passata, superata, senza data: escluse
          Exam(id: 3, courseId: 10, date: DateTime(2027, 1, 2)),
          Exam(
            id: 4,
            courseId: 10,
            date: DateTime(2027, 2, 2),
            status: ExamStatus.passed,
          ),
          const Exam(id: 5, courseId: 10),
        ],
        courseNames: {10: 'Analisi I', 11: 'Fisica'},
        sessions: CalendarioSessioni(
          ambito: 'Ateneo',
          corsi: const {'x'},
          sessioni: [
            SessioneEsami(
              nome: 'Sessione invernale',
              inizio: DateTime(2027, 1, 11),
              fine: DateTime(2027, 2, 20),
            ),
            SessioneEsami(
              nome: 'Sessione estiva',
              inizio: DateTime(2026, 6, 1),
              fine: DateTime(2026, 7, 20),
            ),
          ],
        ),
        now: now,
      );
      expect(agenda.map((i) => i.key), [
        'sessione-20270111-sessione-invernale',
        'esame-2',
        'esame-1',
      ]);
      expect(agenda[1].title, 'Prova in itinere/esonero: Fisica · Esonero 1');
      expect(agenda[2].time, '09:30');
      expect(agenda[2].allDay, isFalse);
      expect(agenda[0].kind, AgendaKind.session);
    });

    test('avvisi: alle 9 del giorno N prima, 24 ore prima con l\'orario', () {
      final allDay = examItem(1, DateTime(2027, 2, 10));
      final timed = examItem(2, DateTime(2027, 2, 10), time: '09:30');
      expect(reminderTimes(allDay, [7, 1]).map((r) => r.at), [
        DateTime(2027, 2, 3, 9),
        DateTime(2027, 2, 9, 9),
      ]);
      expect(reminderTimes(timed, [1, 7]).map((r) => r.at), [
        DateTime(2027, 2, 3, 9),
        DateTime(2027, 2, 9, 9, 30),
      ]);
      // stessi istanti come promemoria del calendario (minuti prima)
      expect(calendarReminderMinutes(allDay, [7, 1]), [9540, 900]);
      expect(calendarReminderMinutes(timed, [7, 1]), [10110, 1440]);
    });
  });

  group('notifiche', () {
    test('ID stabili e diversi per tipo, prova e anticipo', () {
      final a = notificationId(NotificationType.exam, 'esame-1:7');
      expect(notificationId(NotificationType.exam, 'esame-1:7'), a);
      expect(notificationId(NotificationType.exam, 'esame-1:1'), isNot(a));
      expect(notificationId(NotificationType.outcome, 'esame-1:7'), isNot(a));
      expect(a, greaterThanOrEqualTo(100000));
      expect(a, lessThan(1 << 31));
    });

    test('senza consenso nessuna notifica', () {
      expect(
        planNotifications(
          now: now,
          prefs: const NotificationPrefs(),
          agenda: [examItem(1, DateTime(2027, 2, 10))],
        ),
        isEmpty,
      );
    });

    test('prove in arrivo e regola del calendario', () {
      final a = examItem(1, DateTime(2027, 2, 10));
      final b = examItem(2, DateTime(2027, 1, 7), subject: 'Fisica');
      List<PlannedNotification> plan({bool working = false}) =>
          planNotifications(
            now: now,
            prefs: const NotificationPrefs(
              consent: true,
              donation: false,
              examOffsets: [7, 1],
            ),
            agenda: [a, b],
            calendarWorking: working,
            calendarWritten: {a.key},
          );
      // senza calendario: 2 avvisi per a, per b solo il giorno prima
      // (7 giorni prima è già passato)
      final all = plan();
      expect(all.length, 3);
      expect(all.first.title, 'Esame domani: Fisica');
      expect(all.first.at, DateTime(2027, 1, 6, 9));
      expect(all.first.payload, 'prova:2');
      expect(all[1].title, 'Esame tra 7 giorni: Analisi I');
      // calendario funzionante con a scritta: avvisi di a dal calendario
      final cal = plan(working: true);
      expect(cal.map((n) => n.payload).toSet(), {'prova:2'});
      // collegamento rotto: tornano tutte
      expect(plan(working: false).length, 3);
    });

    test('anticipi configurabili e interruttori per tipo', () {
      final a = examItem(1, DateTime(2027, 2, 10));
      final s = AgendaItem(
        key: 'sessione-20270201-invernale',
        kind: AgendaKind.session,
        title: 'Inizio sessione',
        subject: 'Sessione invernale',
        date: DateTime(2027, 2, 1),
        sessionEnd: DateTime(2027, 2, 28),
      );
      final p = planNotifications(
        now: now,
        prefs: const NotificationPrefs(consent: true, examOffsets: [14, 3]),
        agenda: [a, s],
      );
      expect(ofType(p, NotificationType.exam).map((n) => n.at), [
        DateTime(2027, 1, 27, 9),
        DateTime(2027, 2, 7, 9),
      ]);
      final sess = ofType(p, NotificationType.session).single;
      expect(sess.at, DateTime(2027, 1, 31, 9));
      expect(sess.body, 'Sessione invernale, fino al 28 febbraio');
      final none = planNotifications(
        now: now,
        prefs: const NotificationPrefs(
          consent: true,
          exams: false,
          sessions: false,
        ),
        agenda: [a, s],
      );
      expect(none, isEmpty);
    });

    test('«Com\'è andata?» il giorno dopo, una volta sola', () {
      final c = OutcomeCandidate(
        examId: 7,
        subject: 'Analisi I',
        midterm: false,
        date: DateTime(2027, 1, 5),
      );
      final p = planNotifications(
        now: now,
        prefs: on,
        agenda: const [],
        outcomes: [c],
      );
      final n = p.single;
      expect(n.type, NotificationType.outcome);
      expect(n.at, DateTime(2027, 1, 6, 18));
      expect(n.body, contains('Ieri avevi l\'esame di Analisi I'));
      expect(n.actions.map((a) => a.$1), [
        NotificationActions.recordOutcome,
        NotificationActions.skipExam,
      ]);
      expect(
        planNotifications(
          now: now,
          prefs: on,
          agenda: const [],
          outcomes: [c],
          outcomeDone: {7},
        ),
        isEmpty,
      );
    });

    test('al massimo 60 notifiche, le più vicine', () {
      final agenda = [
        for (var i = 0; i < 50; i++)
          examItem(i + 1, DateTime(2027, 3, 1).add(Duration(days: i))),
      ];
      final p = planNotifications(
        now: now,
        prefs: const NotificationPrefs(consent: true, examOffsets: [7, 1]),
        agenda: agenda,
      );
      expect(p.length, kMaxScheduled);
      expect(p.first.at.isBefore(p.last.at), isTrue);
    });

    test('tocchi e pulsanti, anche nel formato di Windows', () {
      final t = NotificationTap.from('prova:3', 'prova:3')!;
      expect(t.payload, 'prova:3');
      expect(t.action, isNull);
      final w = NotificationTap.from(
        NotificationTap.windowsArguments('mai_piu', 'recensione'),
        null,
      )!;
      expect((w.payload, w.action), ('recensione', 'mai_piu'));
      expect(
        NotificationTap.from('sostegno', 'piu_tardi')!.action,
        'piu_tardi',
      );
      expect(AppRoutes.examId('prova:12'), 12);
      expect(AppRoutes.section('sezione:Esami'), 'Esami');
    });

    test('anticipi letti dalle impostazioni', () {
      expect(NotificationPrefs.parseOffsets(null), kDefaultExamOffsets);
      expect(NotificationPrefs.parseOffsets('1, 14,x,3'), [14, 3, 1]);
      expect(NotificationPrefs.parseOffsets(''), isEmpty);
      expect(NotificationPrefs.formatOffsets([1, 7, 1]), '7,1');
    });
  });

  group('recensione e sostegno', () {
    final install = DateTime(2027, 1, 1);
    PromoState st({
      int useDays = 6,
      DateTime? reviewAt,
      DateTime? reviewShownAt,
      DateTime? donationShownAt,
      DateTime? donationNext,
      bool closed = false,
    }) => PromoState(
      firstOpen: install,
      useDays: useDays,
      reviewClosed: closed,
      reviewAt: reviewAt,
      reviewShownAt: reviewShownAt,
      donationShownAt: donationShownAt,
      donationNext: donationNext,
    );

    test('recensione: 14 giorni, 5 giorni d\'uso, lontano dalle prove', () {
      final t = DateTime(2027, 1, 10, 12);
      DateTime? slot(PromoState s, {List<DateTime> exams = const []}) =>
          reviewSlot(
            now: t,
            state: s,
            examDays: exams,
            recording: false,
            available: true,
          );
      expect(slot(st()), DateTime(2027, 1, 15, 18));
      expect(slot(st(useDays: 4)), isNull);
      expect(slot(st(closed: true)), isNull);
      // prova il 16: niente dal 14 al 18
      expect(
        slot(st(), exams: [DateTime(2027, 1, 16)]),
        DateTime(2027, 1, 19, 18),
      );
      // già pianificata e ancora valida: resta lì
      final kept = DateTime(2027, 1, 20, 18);
      expect(slot(st(reviewAt: kept)), kept);
      // mai durante una registrazione, mai senza destinazione
      expect(
        reviewSlot(
          now: t,
          state: st(),
          examDays: const [],
          recording: true,
          available: true,
        ),
        isNull,
      );
      expect(
        reviewSlot(
          now: t,
          state: st(),
          examDays: const [],
          recording: false,
          available: false,
        ),
        isNull,
      );
    });

    test(
      'sostegno: dopo 30 giorni, ogni 6 mesi, non nel mese della recensione',
      () {
        final t = DateTime(2027, 1, 20, 12);
        DateTime? slot(PromoState s, {DateTime? reviewAt}) => donationSlot(
          now: t,
          state: s,
          examDays: const [],
          recording: false,
          available: true,
          reviewAt: reviewAt,
        );
        expect(slot(st()), DateTime(2027, 1, 31, 18));
        // recensione a gennaio: il sostegno passa a febbraio
        expect(
          slot(st(), reviewAt: DateTime(2027, 1, 25, 18)),
          DateTime(2027, 2, 1, 18),
        );
        // mostrata a febbraio: la prossima dopo 6 mesi
        expect(
          donationSlot(
            now: DateTime(2027, 3, 1),
            state: st(donationShownAt: DateTime(2027, 2, 1, 18)),
            examDays: const [],
            recording: false,
            available: true,
          ),
          DateTime(2027, 8, 2, 18),
        );
        // build senza link alle donazioni: mai
        expect(
          donationSlot(
            now: t,
            state: st(),
            examDays: const [],
            recording: false,
            available: false,
          ),
          isNull,
        );
      },
    );

    test('destinazione della recensione secondo la build', () {
      final play = reviewDestination(platform: 'android', donationLink: false)!;
      expect(play.url, startsWith('market://details?id=io.github.'));
      expect(play.fallbackUrl, startsWith('https://play.google.com/'));
      final apk = reviewDestination(platform: 'android', donationLink: true)!;
      expect(apk.github, isTrue);
      expect(apk.url, 'https://github.com/Simo-Magnus/UniNotes');
      expect(reviewDestination(platform: 'ios', appStoreId: ''), isNull);
      expect(
        reviewDestination(platform: 'ios', appStoreId: '123')!.url,
        'itms-apps://itunes.apple.com/app/id123?action=write-review',
      );
      expect(reviewDestination(platform: 'windows')!.github, isTrue);
      expect(reviewDestination(platform: 'macos')!.github, isTrue);
    });
  });

  group('calendario di sistema', () {
    late AppServices s;
    late FakeCalendarBackend backend;
    late SystemCalendarSync sync;
    setUp(() async {
      s = AppServices(await AppDatabase.openInMemory());
      backend = FakeCalendarBackend();
      sync = SystemCalendarSync(s.settings, backend);
      await sync.setEnabled(true);
    });
    tearDown(() => s.database.close());

    test('scrive, aggiorna e cancella senza doppioni', () async {
      final a = examItem(1, DateTime(2027, 2, 10));
      final b = examItem(2, DateTime(2027, 2, 12), time: '14:00');
      var st = await sync.sync([a, b], [7, 1], now: now);
      expect(st.working, isTrue);
      expect(st.lastOk, now);
      expect(st.written, {a.key, b.key});
      expect(backend.events.length, 2);
      expect(backend.writes, 2);
      // di nuovo uguale: niente scritture
      await sync.sync([a, b], [7, 1], now: now);
      expect(backend.events.length, 2);
      expect(backend.writes, 2);
      // modifica: si aggiorna lo stesso evento
      await sync.sync([withLocation(a, 'Aula 5'), b], [7, 1], now: now);
      expect(backend.events.length, 2);
      expect(backend.writes, 3);
      expect(
        backend.events.values.firstWhere((e) => e.key == a.key).item.location,
        'Aula 5',
      );
      // prova tolta (superata o cancellata): via dal calendario
      st = await sync.sync([b], [7, 1], now: now);
      expect(backend.events.values.map((e) => e.key), [b.key]);
      expect(st.written, {b.key});
    });

    test('doppioni trovati nel calendario: ne resta uno', () async {
      final a = examItem(1, DateTime(2027, 2, 10));
      await sync.sync([a], [1], now: now);
      // un altro evento con la stessa chiave (es. dati dell'app cancellati)
      backend.events['altro'] = (key: a.key, item: a, reminders: const [900]);
      await sync.sync([a], [1], now: now);
      expect(backend.events.length, 1);
    });

    test('evento tolto a mano: si ricrea', () async {
      final a = examItem(1, DateTime(2027, 2, 10));
      await sync.sync([a], [1], now: now);
      backend.events.clear();
      final st = await sync.sync([withLocation(a, 'Aula 2')], [1], now: now);
      expect(st.working, isTrue);
      expect(backend.events.length, 1);
    });

    test('permesso tolto o accesso revocato: non funzionante', () async {
      final a = examItem(1, DateTime(2027, 2, 10));
      await sync.sync([a], [1], now: now);
      backend.access = false;
      await expectLater(
        sync.sync([a], [1], now: now),
        throwsA(isA<CalendarAccessException>()),
      );
      var st = await sync.status();
      expect(st.working, isFalse);
      expect(st.lastOk, now);
      backend.access = true;
      backend.revoked = true;
      await expectLater(
        sync.sync([a], [1], now: now),
        throwsA(
          isA<CalendarAccessException>().having(
            (e) => e.expired,
            'expired',
            true,
          ),
        ),
      );
      backend.revoked = false;
      backend.failWrites = true;
      st = await sync.sync([withLocation(a, 'X')], [1], now: now);
      expect(st.working, isFalse);
      expect(st.error, contains('scrittura non riuscita'));
    });

    test('spento: nessuna scrittura', () async {
      await sync.setEnabled(false);
      final st = await sync.sync([examItem(1, DateTime(2027, 2, 10))], [1]);
      expect(st.enabled, isFalse);
      expect(backend.events, isEmpty);
    });

    test('chiave nella descrizione degli eventi del dispositivo', () {
      final a = examItem(9, DateTime(2027, 2, 10));
      final d = eventDescription(a);
      expect(d, endsWith('Rif. UniNotes: esame-9'));
      expect(markerKey(d), 'esame-9');
      expect(markerKey('Riunione'), isNull);
    });

    test('evento Outlook: giornata intera, orario in UTC, un promemoria', () {
      final allDay = OutlookCalendarBackend.eventJson(
        examItem(1, DateTime(2027, 2, 10)),
        [9540, 900],
      );
      expect(allDay['isAllDay'], isTrue);
      expect(allDay['start'], {
        'dateTime': '2027-02-10T00:00:00',
        'timeZone': 'UTC',
      });
      expect(allDay['end'], {
        'dateTime': '2027-02-11T00:00:00',
        'timeZone': 'UTC',
      });
      expect(allDay['reminderMinutesBeforeStart'], 900);
      expect((allDay['singleValueExtendedProperties'] as List).single, {
        'id': OutlookCalendarBackend.keyProperty,
        'value': 'esame-1',
      });
      final item = examItem(2, DateTime(2027, 2, 10), time: '09:30');
      final timed = OutlookCalendarBackend.eventJson(item, const []);
      final utc = item.start.toUtc();
      expect(
        (timed['start'] as Map)['dateTime'],
        '${utc.year}-02-10T${utc.hour.toString().padLeft(2, '0')}:30:00',
      );
      expect(timed['isReminderOn'], isFalse);
      expect(timed.containsKey('reminderMinutesBeforeStart'), isFalse);
    });

    test('accesso scaduto o revocato riconosciuto', () {
      expect(isExpiredGrant('invalid_grant'), isTrue);
      expect(isExpiredGrant('Token has been expired or revoked.'), isTrue);
      expect(
        isExpiredGrant('AADSTS700082: The refresh token has expired'),
        isTrue,
      );
      expect(isExpiredGrant('Microsoft non raggiungibile'), isFalse);
    });
  });

  test('dati del widget: prossime 3 prove con i giorni mancanti', () {
    final agenda = [
      AgendaItem(
        key: 'sessione-x',
        kind: AgendaKind.session,
        title: 'Inizio sessione',
        subject: 'Sessione',
        date: DateTime(2027, 1, 6),
      ),
      examItem(1, DateTime(2027, 1, 5), time: '14:00'),
      examItem(2, DateTime(2027, 1, 6), subject: 'Fisica'),
      examItem(3, DateTime(2027, 1, 15)),
      examItem(4, DateTime(2027, 1, 20)),
    ];
    final p = widgetPayload(agenda, now);
    final exams = p['exams'] as List;
    expect(exams.length, 3);
    expect(exams.map((e) => (e as Map)['daysLabel']), [
      'Oggi',
      'Domani',
      'Tra 10 giorni',
    ]);
    final first = exams.first as Map;
    expect(first['route'], 'prova:1');
    expect(first['isoDate'], '2027-01-05');
    expect(first['time'], '14:00');
    expect(first['date'], 'martedì 5 gennaio');
    expect(p['route'], AppRoutes.exams);
    expect((widgetPayload(const [], now)['exams'] as List), isEmpty);
  });

  group('servizio dei promemoria', () {
    late AppServices s;
    late FakeNotificationPlatform platform;
    late FakeCalendarBackend backend;
    late RemindersService r;
    late int examId;

    setUp(() async {
      final db = await AppDatabase.openInMemory();
      platform = FakeNotificationPlatform();
      backend = FakeCalendarBackend();
      s = AppServices(
        db,
        reminders: (s) => RemindersService(
          s,
          platform: platform,
          calendarBackend: backend,
          widgets: FakeHomeWidgets(),
          platformName: 'android',
          isRecording: () => false,
        ),
      );
      r = s.reminders;
      final c = await s.courses.insert(const Course(name: 'Analisi I'));
      examId = await s.exams.insert(
        Exam(courseId: c, date: DateTime(2027, 2, 10)),
      );
    });
    tearDown(() => s.database.close());

    Future<List<PlannedNotification>> plan(DateTime t) async {
      final data = await r.loadAgenda(t);
      return r.reschedule(data, await r.calendar.status(), now: t);
    }

    test('consenso, permesso e pianificazione', () async {
      expect(await plan(now), isEmpty);
      expect(await r.enableNotifications(), isTrue);
      expect(platform.askedPermission, isTrue);
      final p = await plan(now);
      expect(ofType(p, NotificationType.exam).length, 1);
      expect(
        ofType(p, NotificationType.outcome).single.payload,
        'prova:$examId',
      );
      expect(platform.scheduled.length, p.length);
      // ripianificando non si duplica nulla
      await plan(now);
      expect(platform.scheduled.length, p.length);
    });

    test(
      'calendario funzionante: le prove scritte non hanno notifiche',
      () async {
        await s.settings.set(NotificationKeys.consent, '1');
        await r.enableCalendar();
        expect(backend.events.length, 1);
        final p = await plan(now);
        expect(ofType(p, NotificationType.exam), isEmpty);
        // collegamento interrotto: tornano le notifiche dell'app
        backend.access = false;
        await r.refresh(now: now);
        expect((await r.calendar.status()).working, isFalse);
        final p2 = await plan(now);
        expect(ofType(p2, NotificationType.exam).length, 1);
      },
    );

    test('«Com\'è andata?» chiesto una volta sola', () async {
      await s.settings.set(NotificationKeys.consent, '1');
      await plan(now);
      // il giorno dopo la prova la notifica è già stata mostrata
      final after = DateTime(2027, 2, 12, 9);
      final p = await plan(after);
      expect(ofType(p, NotificationType.outcome), isEmpty);
      expect(await s.settings.get(NotificationKeys.outcomeDone), '$examId');
    });

    test(
      'recensione: pianificata, poi chiusa dopo essere stata mostrata',
      () async {
        await s.settings.set(NotificationKeys.consent, '1');
        await s.settings.set(
          Nudges.firstOpenKey,
          DateTime(2026, 12, 1).toIso8601String(),
        );
        await s.settings.set(Nudges.useDaysKey, '8');
        final p = await plan(now);
        final review = ofType(p, NotificationType.review).single;
        expect(review.at, DateTime(2027, 1, 5, 18));
        // Android senza link alle donazioni (build di test): Google Play
        expect(review.body, contains('lascia una recensione'));
        // passata l'ora: è stata mostrata, non si ripropone
        final later = await plan(DateTime(2027, 1, 6, 9));
        expect(ofType(later, NotificationType.review), isEmpty);
        expect(await s.settings.get(NotificationKeys.reviewState), 'done');
      },
    );

    test(
      'collegamento interrotto: al massimo una notifica ogni 3 giorni',
      () async {
        await s.settings.set(NotificationKeys.consent, '1');
        await r.linkBroken('OneDrive', now: now);
        await r.linkBroken('OneDrive', now: now.add(const Duration(days: 1)));
        await r.linkBroken('Google Drive', now: now);
        expect(platform.shown.map((n) => n.title), [
          'OneDrive non è più collegato',
          'Google Drive non è più collegato',
        ]);
        await r.linkBroken('OneDrive', now: now.add(const Duration(days: 4)));
        expect(platform.shown.length, 3);
        expect(platform.shown.first.payload, AppRoutes.links);
      },
    );

    test('impostazioni lette con i valori predefiniti', () async {
      final p = await NotificationPrefs.load(SettingsRepository(s.database));
      expect(p.consent, isFalse);
      expect(p.exams && p.sessions && p.outcome && p.links && p.review, isTrue);
      // il giorno prima e un'ora prima
      expect(p.examOffsets, [1]);
      expect(p.examHours, [1]);
      // build di test senza DONATIONS=link: niente invito al sostegno
      expect(p.donation, isFalse);
    });
  });
}
