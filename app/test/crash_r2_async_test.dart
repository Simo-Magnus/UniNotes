import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/academic/year_grades_screen.dart';
import 'package:university_notes/features/cloud/drive_picker.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/incoming_files_host.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/links/ai_assistants.dart';
import 'package:university_notes/features/links/links_widgets.dart';
import 'package:university_notes/features/links/whisper_card.dart';
import 'package:university_notes/features/notes/ai_request_dialog.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder_screen.dart';
import 'package:university_notes/features/settings/widgets/async_action_button.dart';
import 'package:university_notes/features/study/focus/focus_plan.dart';
import 'package:university_notes/features/study/focus/focus_service.dart';
import 'package:university_notes/features/study/focus/focus_timer.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/plan_services.dart';

/// Secondo giro della caccia ai crash, categoria «asincronia e ciclo di
/// vita»: doppi tocchi che ripetono un'operazione o chiudono la pagina
/// sotto, dialoghi chiusi a metà attesa, caricamenti che restano sulla
/// rotella, letture all'avvio superate da un'azione dell'utente.

/// Le letture (SQLite, file) avvengono fuori dal tempo finto: si alternano
/// attese reali e ridisegni finché i caricamenti a catena sono finiti.
Future<void> _settle(WidgetTester tester, [int rounds = 60]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _app(AppServices s, Widget home) => Provider<AppServices>.value(
  value: s,
  child: MaterialApp(
    theme: AppTheme.dark(),
    locale: const Locale('it', 'IT'),
    supportedLocales: const [Locale('it', 'IT')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  ),
);

/// Pagina di partenza con un pulsante che apre [open]: dopo la prova la
/// pagina deve esserci ancora (una chiusura di troppo la toglierebbe).
class _Below extends StatelessWidget {
  const _Below(this.open);
  final Future<void> Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => open(context),
        child: const Text('Pagina sotto'),
      ),
    ),
  );
}

/// Google Drive con il selettore «disponibile» e la pagina del selettore
/// che risponde quando lo decide il test.
class _PickerDrive extends GoogleDriveService {
  _PickerDrive(super.settings, super.notes, this.web)
    : super(
        secrets: MemoryCloudSecrets(),
        builtInClientId: 'client.apps.googleusercontent.com',
        builtInClientSecret: '',
        deviceName: 'PC',
      );

  final Completer<String> web;

  @override
  Future<String> accessToken() async => 'token';

  @override
  DrivePicker picker() => DrivePicker(
    openBrowser: (_) async => true,
    apiKey: 'chiave',
    projectNumber: '1',
    mobileClientId: 'client.apps.googleusercontent.com',
    webAuth: (_, _) => web.future,
  );
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  group('doppio tocco', () {
    testWidgets('AsyncActionButton: un solo avvio con due tocchi', (
      tester,
    ) async {
      var runs = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AsyncActionButton(
              label: 'Esporta',
              icon: Icons.upload,
              onPressed: () {
                runs++;
                return gate.future;
              },
            ),
          ),
        ),
      );
      // due tocchi prima del fotogramma che spegne il pulsante
      await tester.tap(find.text('Esporta'));
      await tester.tap(find.text('Esporta'));
      await tester.pump();
      expect(runs, 1);
      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('LinkButton: un solo accesso con due tocchi', (tester) async {
      var runs = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkButton(
              label: 'Accedi',
              icon: Icons.login,
              onPressed: () {
                runs++;
                return gate.future;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Accedi'));
      await tester.tap(find.text('Accedi'));
      await tester.pump();
      expect(runs, 1);
      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('nuovo insegnamento: «Salva» due volte, un corso solo', (
      tester,
    ) async {
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      final before = (await tester.runAsync(s.courses.all))!.length;
      await tester.pumpWidget(_app(s, _Below((c) => openCourseForm(c))));
      await tester.tap(find.text('Pagina sotto'));
      await _settle(tester, 20);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome dell\'insegnamento *'),
        'Laboratorio di prova',
      );
      final save = find.widgetWithText(TextButton, 'Salva');
      await tester.tap(save);
      await tester.tap(save);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final after = (await tester.runAsync(s.courses.all))!;
      expect(
        after.where((c) => c.name == 'Laboratorio di prova'),
        hasLength(1),
      );
      expect(after.length, before + 1);
      // la seconda chiusura avrebbe tolto anche la pagina sotto
      expect(find.text('Pagina sotto'), findsOneWidget);
    });

    testWidgets('voti dell\'anno: «Salva» due volte, la pagina sotto resta', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(planServices))!;
      addTearDown(() => tester.runAsync(s.database.close));
      await tester.pumpWidget(
        _app(
          s,
          _Below(
            (c) => Navigator.of(c).push(
              MaterialPageRoute<void>(
                builder: (_) => const YearGradesScreen(year: 1, markYear: false),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pagina sotto'));
      await _settle(tester, 20);
      final save = find.byKey(const Key('grades-save'));
      expect(save, findsOneWidget);
      await tester.tap(save);
      await tester.tap(save);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Pagina sotto'), findsOneWidget);
      expect(find.byType(YearGradesScreen), findsNothing);
    });

    testWidgets('Whisper: «Scarica» due volte, un solo download', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2400, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tmp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('r2_whisper_'),
      ))!;
      final s = (await tester.runAsync(
        () async => AppServices(
          await AppDatabase.openInMemory(),
          whisper: WhisperService(
            baseDir: () async => tmp,
            host: WhisperHost.windows,
            processRunner: (exe, _) async =>
                throw ProcessException(exe, const []),
            freeSpace: (_) async => 200 * 1000 * 1000 * 1000,
            deviceProbe: () async => const DeviceProfile(
              platform: WhisperPlatform.pc,
              ramBytes: 16 * 1000 * 1000 * 1000,
              cores: 8,
            ),
          ),
        ),
      ))!;
      addTearDown(
        () => tester.runAsync(() async {
          await s.database.close();
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        }),
      );
      await tester.pumpWidget(
        _app(s, const Scaffold(body: SingleChildScrollView(child: WhisperCard()))),
      );
      // lo stato si legge con un centinaio di operazioni sui file in fila
      // (16 modelli: cartella, file, «.part»…), ognuna finita solo durante
      // un'attesa reale: ne servono circa 92 a PC scarico, quindi con il PC
      // carico i 120 giri fissi non bastavano e la sezione dei modelli non
      // c'era ancora. Si aspetta la sezione.
      final models = find.byKey(const Key('whisper-models'));
      for (var i = 0; i < 2000 && models.evaluate().isEmpty; i++) {
        await _settle(tester, 1);
      }
      await tester.tap(models);
      final model = whisperModelById('large-v3-turbo-q5_0')!;
      for (var i = 0; i < 200 && find.text(model.id).evaluate().isEmpty; i++) {
        await _settle(tester, 1);
      }
      await _settle(tester, 5);
      expect(model.italianOk, isTrue);
      // il pulsante «Scarica» sulla riga del modello
      final y = tester.getCenter(find.text(model.id).first).dy;
      final buttons = find.text('Scarica').evaluate().toList();
      expect(buttons, isNotEmpty);
      buttons.sort(
        (a, b) => (tester.getCenter(find.byWidget(a.widget)).dy - y)
            .abs()
            .compareTo((tester.getCenter(find.byWidget(b.widget)).dy - y).abs()),
      );
      final button = find.byWidget(buttons.first.widget);
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      final title = whisperDownloadTitle(model);
      expect(s.jobs.all.where((j) => j.title == title), hasLength(1));
      // il download (senza rete nei test) si ferma
      for (final j in s.jobs.all) {
        s.jobs.cancel(j);
      }
      for (var i = 0; i < 40 && s.jobs.runningTitled(title) != null; i++) {
        await _settle(tester, 1);
      }
      await tester.pumpWidget(const SizedBox());
      await _settle(tester, 5);
    });
  });

  testWidgets(
    'Importa da Drive: Indietro chiude l\'attesa, la pagina sotto resta',
    (tester) async {
      final db = (await tester.runAsync(AppDatabase.openInMemory))!;
      addTearDown(() => tester.runAsync(db.close));
      final settings = SettingsRepository(db);
      final s = AppServices(db);
      final web = Completer<String>();
      final gd = _PickerDrive(
        settings,
        NotesStore(settings, root: () async => Directory.systemTemp),
        web,
      );
      var finished = false;
      Object? error;
      await tester.pumpWidget(
        _app(
          s,
          _Below(
            (c) => Navigator.of(c).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Builder(
                    builder: (c) => Center(
                      child: TextButton(
                        onPressed: () async {
                          try {
                            await importFromDrive(c, gd);
                          } catch (e) {
                            error = e;
                          }
                          finished = true;
                        },
                        child: const Text('Importa da Drive'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pagina sotto'));
      await tester.pumpAndSettle();
      // la rotella del dialogo gira sempre: fotogrammi per un secondo (con
      // pumpAndSettle scadrebbe il tempo massimo del selettore)
      Future<void> frames() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.text('Importa da Drive'));
      await frames();
      expect(error, isNull, reason: '$error');
      expect(finished, isFalse);
      expect(find.text('Scegli i file su Google Drive'), findsOneWidget);
      // Indietro di Android (o Esc): il dialogo si chiude
      await tester.binding.handlePopRoute();
      await frames();
      expect(find.text('Scegli i file su Google Drive'), findsNothing);
      // l'attesa si ferma con il dialogo (prima restava aperta fino al
      // tempo massimo, 5 minuti)
      expect(finished, isTrue);
      expect(error, isNull);
      // la pagina del selettore risponde dopo: niente chiusure di troppo
      web.completeError(Exception('CANCELED'));
      await tester.pumpAndSettle();
      expect(find.text('Importa da Drive'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Registra: database non leggibile, niente rotella infinita', (
    tester,
  ) async {
    final s = (await tester.runAsync(
      () async => AppServices(await AppDatabase.openInMemory()),
    ))!;
    // database chiuso: ogni lettura e scrittura fallisce
    await tester.runAsync(s.database.close);
    await tester.pumpWidget(
      _app(
        s,
        const RecorderScreen(
          initialCourse: Course(id: 1, name: 'Fisica'),
        ),
      ),
    );
    await _settle(tester, 20);
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Insegnamenti non letti'), findsOneWidget);
    // «Registra»: la cartella del corso non si raggiunge, lo si dice
    await tester.tap(find.byIcon(Icons.mic).first);
    await _settle(tester, 20);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Registrazione non avviata'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _settle(tester, 2);
  });

  testWidgets('richiesta all\'AI: risposta copiata mentre il riquadro si '
      'chiude, la pagina sotto resta', (tester) async {
    var clip = 'testo di prima';
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clip};
      if (call.method == 'Clipboard.setData') {
        clip = '${(call.arguments as Map)['text']}';
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    // il browser non si apre (senza risposta l'attesa del canale non
    // finirebbe nei test)
    const launch =
        'dev.flutter.pigeon.url_launcher_windows.UrlLauncherApi.launchUrl';
    messenger.setMockMessageHandler(
      launch,
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[false]),
    );
    addTearDown(() => messenger.setMockMessageHandler(launch, null));
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    messenger.setMockMethodCallHandler(launcher, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));
    String? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: _Below(
          (c) => showAiRequestDialog(
            c,
            title: 'Riassunto',
            ai: ReferenceAi.chatgpt,
            prompt: 'Riassumi la lezione',
            onCapture: (t) async => captured = t,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pagina sotto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apri ChatGPT'));
    // da qui il controllo degli appunti ogni 2 secondi (PC)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1950));
    // la risposta dell'AI arriva negli appunti proprio mentre si chiude
    clip = 'Risposta. ' * 40;
    await tester.tap(find.text('Chiudi'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('Pagina sotto'), findsOneWidget);
    expect(captured, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dettaglio della prova: modifica non salvata, lo si dice', (
    tester,
  ) async {
    final s = (await tester.runAsync(
      () async => AppServices(await AppDatabase.openInMemory()),
    ))!;
    addTearDown(() => tester.runAsync(s.database.close));
    final id = (await tester.runAsync(() async {
      final c = await s.courses.insert(const Course(name: 'Fisica'));
      final e = await s.exams.insert(
        Exam(courseId: c, status: ExamStatus.planned),
      );
      // le letture funzionano, le scritture no (come con il disco pieno)
      await s.database.db.execute(
        'CREATE TRIGGER r2_full BEFORE UPDATE ON exams '
        "BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END",
      );
      return e;
    }))!;
    await tester.pumpWidget(_app(s, ExamDetailScreen(examId: id)));
    await _settle(tester, 20);
    await tester.tap(find.byTooltip('Cambia luogo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Aula 7');
    await tester.tap(find.widgetWithText(FilledButton, 'Salva'));
    await _settle(tester, 20);
    // prima l'errore restava nel registro e il luogo spariva senza avviso
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Modifica non salvata'), findsOneWidget);
  });

  group('Focus', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('sessione avviata prima della lettura all\'avvio: resta quella '
        'rimasta aperta', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      final now = DateTime(2026, 10, 22, 9);
      // sessione di 45 minuti in corso quando l'app si è chiusa
      final before = FocusService(
        s,
        timer: FocusTimer(clock: () => now, tick: false),
      );
      await before.start(const FocusSettings(minutes: 45), const FocusLink());
      final saved = await s.settings.get(FocusKeys.running);
      expect(saved, isNotNull);

      // riavvio: la lettura della sessione (dopo i promemoria) non è
      // ancora arrivata e lo studente avvia una sessione nuova
      final later = now.add(const Duration(minutes: 10));
      final f = FocusService(
        s,
        timer: FocusTimer(clock: () => later, tick: false),
      );
      await f.start(const FocusSettings(minutes: 25), const FocusLink());
      // la sessione rimasta aperta continua, non si perde
      expect(f.active, isTrue);
      expect(f.timer.toJson()?['inizio'], now.toIso8601String());
      // e la lettura arrivata dopo non cambia nulla
      await f.load();
      expect(f.timer.toJson()?['inizio'], now.toIso8601String());
      before.dispose();
      f.dispose();
    });
  });
}
