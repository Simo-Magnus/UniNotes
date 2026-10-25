import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/apple_calendar_backend.dart';
import 'package:university_notes/core/reminders/device_calendar_backend.dart';
import 'package:university_notes/core/reminders/native_calendar_backend.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/settings/sections/calendar_section.dart';
import 'package:university_notes/features/settings/sections/questions_reset.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';

import 'support/fake_reminders.dart';

/// Calendario finto con l'account da confermare (Android 13+): [needed]
/// finché la finestra del sistema non risponde true.
class _ConfirmableBackend extends FakeCalendarBackend
    implements AccountConfirmation {
  bool needed = true;

  /// Risposta della finestra: true confermato, false annullato, null non
  /// aperta.
  bool? answer = true;
  int windows = 0;
  CalendarChoice? lastAsked;

  @override
  Future<bool> accountAccessNeeded(CalendarChoice c) async => needed;

  @override
  Future<bool?> confirmAccount(CalendarChoice c) async {
    windows++;
    lastAsked = c;
    // la finestra risponde dopo (l'utente sceglie)
    await Future<void>.microtask(() {});
    if (answer == true) needed = false;
    return answer;
  }
}

/// Conferma dell'account del calendario su Android (sesto giro, R6): la
/// richiesta di sincronizzazione dell'app arriva al sistema solo se l'app
/// vede l'account del calendario (vedi UniNotesCalendar.kt, accountNeeded).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('canale nativo (AndroidCalendarBackend)', () {
    const channel = NativeCalendarBackend.kChannel;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const google = CalendarChoice(
      id: '7',
      name: 'Calendario',
      account: 'studente@gmail.com',
      accountType: 'com.google',
      primary: true,
    );

    test('solo i calendari di un account vero hanno un account da '
        'confermare', () {
      expect(AndroidCalendarBackend.accountArgs(google), {
        'account': 'studente@gmail.com',
        'accountType': 'com.google',
      });
      for (final c in const [
        CalendarChoice(id: '1', name: 'Locale', accountType: 'LOCAL'),
        CalendarChoice(
          id: '2',
          name: 'Non sincronizzato',
          account: 'a@b.it',
          accountType: 'com.google',
          synced: false,
        ),
        CalendarChoice(id: '3', name: 'Senza account'),
      ]) {
        expect(AndroidCalendarBackend.accountArgs(c), isNull, reason: c.name);
      }
      expect(
        AndroidCalendarBackend.accountDescription(google),
        contains('Google Calendar'),
      );
      expect(
        AndroidCalendarBackend.accountDescription(
          const CalendarChoice(
            id: '4',
            name: 'Samsung',
            account: 'a@b.it',
            accountType: 'com.osp.app.signin',
          ),
        ),
        isNot(contains('Google')),
      );
    });

    test('accountAccess e confirmAccount: argomenti e risposte', () async {
      final calls = <MethodCall>[];
      Object? confirmReply = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'accountAccess' => {'needed': true},
          'confirmAccount' => confirmReply,
          _ => null,
        };
      });
      final b = AndroidCalendarBackend();
      expect(await b.accountAccessNeeded(google), isTrue);
      expect(await b.confirmAccount(google), isTrue);
      final args = calls.last.arguments as Map;
      expect(args['account'], 'studente@gmail.com');
      expect(args['accountType'], 'com.google');
      expect(args['calendarId'], '7');
      expect(args['description'], isNotEmpty);
      confirmReply = false;
      expect(await b.confirmAccount(google), isFalse);
      // finestra non aperta
      confirmReply = null;
      expect(await b.confirmAccount(google), isNull);
      // calendario locale: nessuna chiamata
      calls.clear();
      const local = CalendarChoice(id: '1', name: 'L', accountType: 'LOCAL');
      expect(await b.accountAccessNeeded(local), isFalse);
      expect(await b.confirmAccount(local), isTrue);
      expect(calls, isEmpty);
    });

    test('versione nativa senza i metodi o errore: niente conferma, nessuna '
        'eccezione', () async {
      final b = AndroidCalendarBackend();
      // nessun gestore: MissingPluginException
      expect(await b.accountAccessNeeded(google), isFalse);
      expect(await b.confirmAccount(google), isNull);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'errore');
      });
      expect(await b.accountAccessNeeded(google), isFalse);
      expect(await b.confirmAccount(google), isNull);
    });

    test('iPhone, Mac e Windows: nessuna conferma dell\'account', () {
      expect(AppleCalendarBackend(), isNot(isA<AccountConfirmation>()));
      expect(FakeCalendarBackend(), isNot(isA<AccountConfirmation>()));
      expect(AndroidCalendarBackend(), isA<AccountConfirmation>());
    });
  });

  group('servizio dei promemoria', () {
    late AppServices s;
    late _ConfirmableBackend backend;
    late RemindersService r;
    late int courseId;
    var foreground = true;

    setUp(() async {
      foreground = true;
      final db = await AppDatabase.openInMemory();
      backend = _ConfirmableBackend();
      s = AppServices(
        db,
        reminders: (s) => RemindersService(
          s,
          platform: FakeNotificationPlatform(),
          calendarBackend: backend,
          widgets: FakeHomeWidgets(),
          platformName: 'android',
          isRecording: () => false,
          isForeground: () => foreground,
        ),
      );
      r = s.reminders;
      courseId = await s.courses.insert(const Course(name: 'Analisi I'));
      await s.exams.insert(
        Exam(courseId: courseId, date: DateTime(2099, 2, 10)),
      );
    });
    tearDown(() async {
      await r.accountConfirmation;
      await s.database.close();
    });

    Future<void> addExam(int day) async {
      await s.exams.insert(
        Exam(courseId: courseId, date: DateTime(2099, 3, day)),
      );
      await r.refresh();
      await r.accountConfirmation;
    }

    test('attivando il calendario si chiede la conferma una volta: '
        'confermato, non si chiede più', () async {
      await r.enableCalendar();
      expect(backend.windows, 1);
      expect(backend.lastAsked?.account, 'studente@gmail.com');
      expect(backend.needed, isFalse);
      expect(await r.calendarAccountNeeded(), isFalse);
      expect(await s.settings.get(CalendarKeys.accountDeclined), isNull);
      await addExam(1);
      expect(backend.windows, 1);
    });

    test('annullata: l\'app non insiste, il pulsante delle Impostazioni la '
        'ripropone e «Ripristina le domande» la riattiva', () async {
      backend.answer = false;
      await r.enableCalendar();
      expect(backend.windows, 1);
      expect(
        await s.settings.get(CalendarKeys.accountDeclined),
        contains('com.google:studente@gmail.com'),
      );
      // nuove prove scritte, scelta del calendario: nessuna nuova finestra
      await addExam(2);
      await r.chooseCalendar('cal-1');
      expect(backend.windows, 1);
      expect(await r.calendarAccountNeeded(), isTrue);
      // pulsante «Conferma account per il caricamento immediato»
      backend.answer = true;
      expect(await r.confirmCalendarAccount(force: true), isTrue);
      expect(backend.windows, 2);
      expect(await s.settings.get(CalendarKeys.accountDeclined), isNull);

      // di nuovo annullata, poi «Ripristina le domande»
      backend
        ..needed = true
        ..answer = false;
      expect(await r.confirmCalendarAccount(force: true), isFalse);
      expect(await resetDontAskQuestions(s.settings), greaterThan(0));
      expect(await s.settings.get(CalendarKeys.accountDeclined), isNull);
      await addExam(3);
      expect(backend.windows, 4);
    });

    test('account già confermato: nessuna finestra', () async {
      backend.needed = false;
      await r.enableCalendar();
      await addExam(4);
      expect(backend.windows, 0);
      expect(await r.calendarAccountNeeded(), isFalse);
    });

    test('calendario scelto prima di questa versione: si chiede alla prima '
        'scrittura con l\'app davanti, una volta sola', () async {
      // calendario già attivo: nessun enableCalendar
      await s.settings.set(CalendarKeys.enabled, '1');
      foreground = false;
      await r.refresh();
      await r.accountConfirmation;
      expect(backend.events, isNotEmpty);
      expect(backend.windows, 0, reason: 'app non in primo piano');
      // nessuna modifica: nessuna scrittura, nessuna finestra
      foreground = true;
      await r.refresh();
      await r.accountConfirmation;
      expect(backend.windows, 0);
      backend.answer = false;
      await addExam(5);
      expect(backend.windows, 1);
      await addExam(6);
      expect(backend.windows, 1);
    });

    test('finestra non aperta: non conta come annullata', () async {
      backend.answer = null;
      // dopo la scrittura e dopo l'attivazione: mai segnata come annullata
      await r.enableCalendar();
      expect(backend.windows, 2);
      expect(await s.settings.get(CalendarKeys.accountDeclined), isNull);
      backend.answer = true;
      await addExam(7);
      expect(backend.windows, 3);
      expect(backend.needed, isFalse);
    });

    test('due richieste insieme: una sola finestra', () async {
      await s.settings.set(CalendarKeys.enabled, '1');
      foreground = false;
      await r.refresh();
      final a = r.confirmCalendarAccount();
      final b = r.confirmCalendarAccount(force: true);
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(backend.windows, 1);
    });

    test(
      'calendario aggiornato da un altro dispositivo: niente conferma',
      () async {
        await s.settings.set(CalendarKeys.enabled, '1');
        await r.refresh();
        await r.accountConfirmation;
        backend.needed = true;
        final before = backend.windows;
        await s.settings.set(CalendarKeys.writtenBy, 'telefono ab12');
        expect(await r.calendarAccountNeeded(), isFalse);
        expect(await r.confirmCalendarAccount(force: true), isTrue);
        expect(backend.windows, before);
      },
    );
  });

  testWidgets('Impostazioni → Calendario: riga «Conferma account per il '
      'caricamento immediato»', (t) async {
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final backend = _ConfirmableBackend()..answer = false;
    final s = AppServices(
      db,
      reminders: (s) => RemindersService(
        s,
        platform: FakeNotificationPlatform(),
        calendarBackend: backend,
        widgets: FakeHomeWidgets(),
        platformName: 'android',
        isRecording: () => false,
        isForeground: () => false,
      ),
    );
    await t.runAsync(() async {
      await s.settings.set(CalendarKeys.enabled, '1');
      await s.reminders.refresh();
    });
    final button = find.byKey(const Key('calendar-confirm-account'));

    /// Attese vere (database) finché [done] o al massimo 3 secondi.
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 150 && !done(); i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
      }
    }

    await t.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: CalendarSection())),
        ),
      ),
    );
    await settle(() => button.evaluate().isNotEmpty);
    expect(button, findsOneWidget);
    expect(
      find.text('Conferma account per il caricamento immediato'),
      findsOneWidget,
    );
    backend.answer = true;
    await t.tap(button);
    await settle(() => button.evaluate().isEmpty);
    expect(backend.windows, 1);
    expect(find.textContaining('Account confermato'), findsOneWidget);
    expect(button, findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(db.close);
  });
}
