// Quarto giro della caccia ai crash (sigla R4-A): prova a caso automatica
// («monkey test») di tutta l'interfaccia. Si apre l'app vera
// (UniversityNotesApp → onboarding o AppShell) con servizi di prova e
// database preparati, poi un generatore a seme fisso esegue azioni casuali:
// tocchi e pressioni lunghe sugli elementi toccabili, tocchi in punti a caso,
// scorrimenti, testo casuale nei campi (emoji, testo lunghissimo, numeri
// strani), «Indietro», Esc, Tab e frecce, ridimensionamenti della finestra
// (da 320×568 a 1920×1080), caratteri ×1/×1,3/×2, tema chiaro/scuro e attese.
// Dopo ogni azione si raccolgono gli errori di Flutter e le eccezioni non
// gestite; al primo errore la prova si ferma con seme, passo e ultime azioni.
//
// Niente risorse vere: selettore dei file, link, «Condividi», «Apri con»,
// microfono, percorsi di sistema, notifiche e calendario sono finti; i
// pulsanti che uscirebbero dall'app o toccherebbero dati veri (accesso a
// OneDrive/Google/Outlook, «Elimina tutti i dati», Esplora file) si saltano
// (vedi `kDenied` in support/monkey_harness.dart).
//
// Suite normale: pochi semi, qualche centinaio di azioni. Giro lungo:
//   CRASH_R4_MONKEY=1 flutter test test/crash_r4_monkey_test.dart
// con CRASH_R4_SEEDS (semi per scenario, predefinito 12), CRASH_R4_ACTIONS
// (azioni per seme, predefinito 1200) e CRASH_R4_SEED (un solo seme, per
// riprodurre un errore riportato).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/main.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/notes/recording_player_screen.dart';
import 'package:university_notes/features/study/topics_tab.dart';
import 'package:university_notes/features/exams/averages_tab.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/course_rename.dart';
import 'package:university_notes/features/books/book_tile.dart';
import 'package:university_notes/features/settings/sections/calendar_section.dart';
import 'package:university_notes/features/settings/sections/notifications_section.dart';

import 'support/monkey_harness.dart';

/// Prove mirate dei casi trovati dalla scimmia (rosse sul codice del commit
/// 4672237b, verdi dopo la correzione).
void _foundCases() {
  group('casi trovati dalla scimmia', () {
    // 1. Impostazioni → Calendario/Notifiche: un dato cambiato altrove
    // (es. Esclusioni) ricaricava la sezione con `setState(() => _future =
    // _load())`, una freccia che restituisce il Future a setState: errore
    // «setState() callback argument returned a Future» e sezione non
    // ridisegnata.
    for (final (name, section) in [
      ('Calendario', const CalendarSection()),
      ('Notifiche', const NotificationsSection()),
    ]) {
      testWidgets('$name: ricarica dopo una modifica dei dati', (t) async {
        final tmp = (await t.runAsync(
          () => Directory.systemTemp.createTemp('r4_sezione_'),
        ))!;
        final db = (await t.runAsync(AppDatabase.openInMemory))!;
        final s = (await t.runAsync(() => monkeyServices(db, tmp)))!;
        await t.pumpWidget(
          Provider<AppServices>.value(
            value: s,
            child: MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: section)),
            ),
          ),
        );
        for (var i = 0; i < 3; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        // la sezione Calendario rilegge dopo una modifica dei dati, quella
        // delle Notifiche quando cambiano i promemoria
        s.revision.bump();
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        s.reminders.notifyListeners();
        await t.pump();
        expect(t.takeException(), isNull);
        for (var i = 0; i < 3; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async {
          await db.close();
          await tmp.delete(recursive: true);
        });
      });
    }

    // 2. Grandezza del testo del sistema cambiata con l'app aperta: la scala
    // dell'app (AppTextScaler) dava a Flutter un textScaleFactor che seguiva
    // subito il sistema, il MediaQuery vecchio e il nuovo risultavano
    // uguali e i testi restavano impaginati con la grandezza di prima; al
    // primo cambio di colore (tema, pulsante premuto) «debugSize == size».
    testWidgets('grandezza del testo del sistema cambiata: testi '
        'reimpaginati', (t) async {
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final color = ValueNotifier<Color>(Colors.red);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            final m = MediaQuery.of(context);
            return MediaQuery(
              data: m.copyWith(textScaler: AppTextScaler(m.textScaler, 1)),
              child: child!,
            );
          },
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: color,
              builder: (_, c, _) =>
                  Text('Testo', style: TextStyle(color: c, fontSize: 14)),
            ),
          ),
        ),
      );
      final before = t.getSize(find.text('Testo')).height;
      for (final v in [2.0, 1.0, 1.5]) {
        t.platformDispatcher.textScaleFactorTestValue = v;
        await t.pump();
        await t.pump();
        color.value = color.value == Colors.red ? Colors.blue : Colors.red;
        await t.pump();
        expect(t.takeException(), isNull);
        expect(
          t.getSize(find.text('Testo')).height,
          moreOrLessEquals(before * v, epsilon: 2),
        );
      }
    });

    // 3. Tastiera collegata al telefono o al tablet: Pagina giù con il fuoco
    // fuori dalle liste e due liste verticali nella pagina (si agganciano da
    // sole al PrimaryScrollController) → «more than one ScrollPosition is
    // attached» (in release «Too many elements») a ogni tasto.
    testWidgets('Pagina giù con due liste nella pagina', (t) async {
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_pagina_'),
      ))!;
      final s = (await t.runAsync(() => monkeyServices(db, tmp)))!;
      await t.pumpWidget(UniversityNotesApp(services: s));
      await t.pump();
      appNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Column(
              children: [
                for (var l = 0; l < 2; l++)
                  Expanded(
                    child: ListView(
                      children: [
                        for (var i = 0; i < 50; i++) Text('riga $l.$i'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      for (final k in [
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await t.sendKeyEvent(k);
        await t.pump();
        expect(t.takeException(), isNull, reason: k.keyLabel);
      }
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(seconds: 1));
      }
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 4. Lettore di schermo attivo nella pagina di una registrazione: la
    // barra della posizione aveva «value» senza «increasedValue» e
    // «decreasedValue» (asserzione dell'albero semantico a ogni disegno).
    testWidgets('registrazione con il lettore di schermo attivo', (t) async {
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final handle = t.ensureSemantics();
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_lettore_'),
      ))!;
      final (s, course, file) = (await t.runAsync(() async {
        final s = await monkeyServices(db, tmp);
        const c = Course(id: 1, name: 'Analisi');
        final path = await s.notes.newRecordingPath(
          c,
          DateTime(2026, 10, 12, 8, 30),
          '.wav',
        );
        File(path).writeAsBytesSync(wavBytes(2));
        return (s, c, File(path));
      }))!;
      await t.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(
            home: RecordingPlayerScreen(course: course, file: file),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(t.takeException(), isNull);
      expect(
        find.bySemanticsLabel('Posizione nella registrazione'),
        findsOneWidget,
      );
      handle.dispose();
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 3; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(seconds: 1));
      }
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 5. Studio → «Cambia insegnamento» aperto, poi la finestra passa da
    // stretta a larga (o il tablet ruota): la shell cambia disposizione e
    // ricrea Studio; scegliendo un insegnamento nel foglio rimasto aperto
    // si chiamava setState sullo Studio di prima, già eliminato.
    testWidgets('scelta dell\'insegnamento dopo il cambio di disposizione', (
      t,
    ) async {
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_studio_'),
      ))!;
      final s = (await t.runAsync(() async {
        final s = await monkeyServices(db, tmp);
        await fillPlan(s, hostile: false);
        // altri insegnamenti dell'anno frequentato, da scegliere nel foglio
        final first = (await s.courses.all()).first;
        for (final name in ['Fisica tecnica', 'Geometria']) {
          await s.courses.insert(
            Course(
              name: name,
              universityId: first.universityId,
              degreeId: first.degreeId,
              year: s.profile.value?.currentYear ?? 2,
              semester: '1',
              cfu: 6,
            ),
          );
        }
        return s;
      }))!;
      Future<void> settle([int n = 8]) async {
        for (var i = 0; i < n; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await t.pumpWidget(UniversityNotesApp(services: s));
      await settle(20);
      await t.tap(find.text('Studio').last);
      await settle();
      await t.tap(find.byKey(const Key('course-name')));
      await settle();
      expect(
        find.descendant(
          of: find.byType(CoursePickerList),
          matching: find.text('Geometria'),
        ),
        findsOneWidget,
      );
      // finestra larga: colonna di navigazione al posto della barra
      t.view.physicalSize = const Size(1366, 915);
      await settle();
      await t.tap(
        find.descendant(
          of: find.byType(CoursePickerList),
          matching: find.text('Geometria'),
        ),
        warnIfMissed: false,
      );
      await settle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle(3);
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 6. Esami → Medie in una colonna stretta (finestra larga: due colonne,
    // lista accanto al dettaglio) con i caratteri ×2: «30 e lode» a destra
    // della riga occupava tutta la riga («Trailing widget consumes the
    // entire tile width»), il nome restava senza spazio.
    testWidgets('Medie in una colonna stretta con i caratteri grandi', (
      t,
    ) async {
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_medie_'),
      ))!;
      final data = (await t.runAsync(() async {
        final s = await monkeyServices(db, tmp);
        await fillPlan(s, hostile: false);
        for (final c in await s.courses.all()) {
          await s.exams.save(
            Exam(
              courseId: c.id!,
              date: DateTime(2026, 2, 10),
              status: ExamStatus.passed,
              grade: 30,
              laude: true,
            ),
          );
        }
        return loadExamsData(s);
      }))!;
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exceptionAsString();
        if (text.contains('consumes the entire tile width')) errors.add(text);
      };
      // la colonna più stretta possibile: finestra a 840 px (dove parte la
      // disposizione larga) meno la colonna di navigazione, 3/5 accanto al
      // dettaglio
      for (final width in [453.0, 520.0, 640.0]) {
        final before = errors.length;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: AveragesTab(data: data, onSelect: (_) {}),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        if (errors.length > before) {
          errors.add('colonna di ${width.toInt()} px');
        }
      }
      FlutterError.onError = previous;
      expect(errors, isEmpty);
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 7. Modulo dell'insegnamento: nome cancellato, modulo scorso in basso
    // (il campo del nome esce dalla lista e validate() non lo controlla),
    // «Salva» → «Null check operator used on a null value» in _save.
    testWidgets('insegnamento salvato con il nome vuoto fuori schermo', (
      t,
    ) async {
      t.view.physicalSize = const Size(400, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_modulo_'),
      ))!;
      final (s, course) = (await t.runAsync(() async {
        final s = await monkeyServices(db, tmp);
        await fillPlan(s, hostile: false);
        return (s, (await s.courses.all()).first);
      }))!;
      Future<void> settle([int n = 6]) async {
        for (var i = 0; i < n; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await t.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(home: CourseFormPage(course: course)),
        ),
      );
      await settle();
      for (
        var i = 0;
        i < 100 && find.byType(CourseNameField).evaluate().isEmpty;
        i++
      ) {
        await settle(1);
      }
      expect(find.byType(CourseNameField), findsOneWidget);
      await t.enterText(
        find.descendant(
          of: find.byType(CourseNameField),
          matching: find.byType(EditableText),
        ),
        '   ',
      );
      await t.pump();
      // fuoco altrove: un campo con il fuoco resterebbe vivo fuori schermo
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      // in fondo al modulo: il campo del nome non è più nella lista
      for (var i = 0; i < 12; i++) {
        await t.drag(find.byType(ListView).first, const Offset(0, -600));
        await t.pump();
      }
      await settle(2);
      expect(find.byType(CourseNameField), findsNothing);
      // «Salva» nella barra in alto
      await t.tap(find.text('Salva').last);
      await settle();
      expect(t.takeException(), isNull);
      expect(
        find.text('Inserisci il nome dell\'insegnamento.'),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      await settle(3);
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 8. Libri: scheda di un libro senza file in uno spazio stretto con la
    // finestra larga e i caratteri ×2: «Aggiungi» e il menu a destra
    // occupavano tutta la riga («Trailing widget consumes the entire tile
    // width»).
    testWidgets('scheda di un libro stretta con i caratteri grandi', (t) async {
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exceptionAsString();
        if (text.contains('consumes the entire tile width')) errors.add(text);
      };
      for (final width in [240.0, 320.0, 420.0, 560.0]) {
        final before = errors.length;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: BookTile(
                    book: const Book(id: 1, title: 'Analisi matematica'),
                    onOpen: () {},
                    onAction: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        if (errors.length > before) {
          errors.add('scheda di ${width.toInt()} px');
        }
      }
      FlutterError.onError = previous;
      expect(errors, isEmpty);
    });

    test('nessun setState con una freccia che assegna un Future', () {
      // stessa causa del caso 1 nelle altre schermate (OneNote, Google
      // Drive, Whisper, Eliminati di recente)
      final bad = <String>[];
      final assign = RegExp(r'setState\(\(\) => (_?\w+) = ');
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final m in assign.allMatches(src)) {
          final v = RegExp.escape(m[1]!);
          // dichiarazione del campo: «Future<…> _x;» o «Future<…> _x = …»
          if (RegExp('Future<[^;(){}=]*>\\??\\s+$v\\s*[;=]').hasMatch(src)) {
            bad.add('${f.path}: ${m[0]}');
          }
        }
      }
      expect(bad, isEmpty);
    });
  });
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  final total = <String, int>{};
  tearDownAll(() {
    // ignore: avoid_print
    print('scimmia: ${total['azioni'] ?? 0} azioni casuali senza errori');
  });

  _foundCases();

  if (!monkeyLong) {
    group('scimmia (giro breve)', () {
      for (final (sc, seed, steps, sem) in [
        (kScenarioVuoto, 1, 90, false),
        (kScenarioPiano, 2, 160, true),
        (kScenarioLimiti, 3, 110, false),
      ]) {
        testWidgets(
          '${sc.name}, seme $seed, $steps azioni',
          (t) => runMonkey(t, sc, seed, steps, semantics: sem, total: total),
          timeout: const Timeout(Duration(minutes: 2)),
        );
      }
    });
    return;
  }

  final only = Platform.environment['CRASH_R4_SEED'];
  final seeds = only != null
      ? [int.parse(only)]
      : [for (var i = 0; i < monkeyEnv('CRASH_R4_SEEDS', 12); i++) 1000 + i];
  final steps = monkeyEnv('CRASH_R4_ACTIONS', 1200);
  // CRASH_R4_SCENARIO accetta anche i nomi degli scenari del sesto giro
  // (crash_r6_monkey_test.dart): qui non fanno nulla
  final scenarios = switch (Platform.environment['CRASH_R4_SCENARIO']) {
    final String n => [
      for (final sc in kBaseScenarios)
        if (sc.name == n) sc,
    ],
    null => kBaseScenarios,
  };
  group('scimmia (giro lungo)', () {
    for (final sc in scenarios) {
      for (final seed in seeds) {
        testWidgets(
          '${sc.name}, seme $seed, $steps azioni',
          (t) => runMonkey(t, sc, seed, steps, semantics: seed.isOdd, total: total),
          timeout: const Timeout(Duration(minutes: 8)),
        );
      }
    }
  });
}

