// Sesto giro (R6-B): prove mirate dei casi trovati dalla prova a caso estesa
// (crash_r6_monkey_test.dart), rosse sul codice del commit 259699fa e verdi
// dopo la correzione.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/router/app_shell.dart' show kDestinations;
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/main.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_folders.dart';
import 'package:university_notes/features/links/onedrive_card.dart';
import 'package:university_notes/widgets/common.dart' show RevisionBuilder;
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/features/notes/notes_store.dart'
    show NoteFolder;
import 'package:university_notes/features/notes/recorder_screen.dart';
import 'package:university_notes/features/notes/recording_player_screen.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/features/settings/sections/profile_section.dart';
import 'package:university_notes/features/study/course_catalog.dart';
import 'package:university_notes/features/study/module_order_dialog.dart';
import 'package:university_notes/features/study/session_dialog.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/study_widgets.dart'
    show ChoiceBox;
import 'package:university_notes/models/study.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/widgets/find_bar.dart';

import 'reader_fixtures.dart' show buildOneNote;
import 'support/monkey_harness.dart';

/// Come nell'app: la scala del sistema passa dall'AppTextScaler.
Widget _app(Widget home, {AppServices? services}) {
  final app = MaterialApp(
    theme: AppTheme.dark(),
    builder: (context, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(textScaler: AppTextScaler(media.textScaler, 1)),
        child: child!,
      );
    },
    home: home,
  );
  return services == null
      ? app
      : Provider<AppServices>.value(value: services, child: app);
}

/// Registra gli overflow («A RenderFlex overflowed…») invece di fallire
/// subito.
FlutterExceptionHandler? _previousHandler;

/// Rimette il gestore di Flutter (prima delle verifiche: i test non devono
/// finire con un gestore diverso).
void _stopCollecting() => FlutterError.onError = _previousHandler;

List<String> _collectOverflows() {
  final found = <String>[];
  final previous = _previousHandler = FlutterError.onError;
  FlutterError.onError = (d) {
    final text = d.exceptionAsString();
    if (text.contains('overflowed by')) {
      final loc = RegExp(
        r'file:///[A-Za-z]:/[^\s]*?/app/(lib/[^\s:]+\.dart:\d+)',
      ).firstMatch(d.toString());
      found.add('${text.split('\n').first} (${loc?[1] ?? '?'})');
    } else {
      previous?.call(d);
    }
  };
  addTearDown(() => FlutterError.onError = previous);
  return found;
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  // 1. «Nuova sessione» (Studio → Sessioni): il menu «Attività» non era a
  // tutta larghezza e la sua voce («Simulazione»…) usciva dal riquadro con la
  // finestra stretta (320 px): overflow di 63 px.
  testWidgets('riquadro «Nuova sessione» in una finestra stretta', (t) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final problems = <String>[];
    for (final scale in [1.0, 2.0]) {
      t.platformDispatcher.textScaleFactorTestValue = scale;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSessionDialog(
                  context,
                  catalog: CourseCatalog(const [
                    Course(id: 1, name: 'Fisica'),
                  ], const []),
                ),
                child: const Text('apri'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('apri'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Nuova sessione'), findsOneWidget);
      // la voce scelta è la più lunga delle attività
      await t.pump(const Duration(milliseconds: 100));
      if (found.isNotEmpty) problems.add('caratteri ×$scale: $found');
      found.clear();
      Navigator.of(t.element(find.text('Nuova sessione'))).pop();
      await t.pumpAndSettle();
    }
    _stopCollecting();
    expect(problems, isEmpty);
  });

  // 2. «Trova nel testo» del lettore: l'esito («Nessun risultato») non
  // cedeva spazio e con 360 px e i caratteri ×2 spingeva i pulsanti fuori
  // dalla riga (218 px).
  testWidgets('barra «Trova nel testo» stretta con i caratteri grandi', (
    t,
  ) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = TextEditingController(text: 'zzz');
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final problems = <String>[];
    for (final (total, searching) in const [
      (0, false),
      (12, false),
      (0, true),
    ]) {
      await t.pumpWidget(
        _app(
          Scaffold(
            body: FindBar(
              controller: controller,
              focusNode: focus,
              onChanged: (_) {},
              onNext: () {},
              onPrevious: () {},
              onClose: () {},
              total: total,
              current: total == 0 ? null : 3,
              searching: searching,
            ),
          ),
        ),
      );
      await t.pump();
      if (found.isNotEmpty) {
        problems.add('risultati $total, in ricerca $searching: $found');
      }
      found.clear();
    }
    _stopCollecting();
    expect(problems, isEmpty);
  });

  // 4. Finestra larga con i caratteri grandi (1280×800, ×2): la colonna di
  // navigazione con nove voci usciva dallo schermo (70 px) e la barra di
  // «Registra» di 8 px. Ogni sezione si apre senza overflow in tre finestre
  // larghe e basse con i caratteri ×1,3 e ×2.
  testWidgets('sezioni con la colonna di navigazione e i caratteri grandi', (
    t,
  ) async {
    final found = _collectOverflows();
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_rail_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final s = (await t.runAsync(() async {
      final s = await monkeyServices(db, tmp);
      await fillPlan(s, hostile: false);
      // cartelle con molti file (il conteggio a destra di ogni cartella)
      await writeCorpus(s, Random(3));
      return s;
    }))!;
    final messenger = t.binding.defaultBinaryMessenger;
    final channels = MonkeyChannels(tmp);
    messenger.allMessagesHandler = channels.handle;
    addTearDown(() => messenger.allMessagesHandler = null);
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    for (final size in const [
      Size(1280, 800),
      Size(1024, 600),
      Size(840, 480),
    ]) {
      for (final scale in const [1.3, 2.0]) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = scale;
        await t.pumpWidget(UniversityNotesApp(services: s));
        await settle();
        for (final label in [for (final d in kDestinations) d.label]) {
          final before = found.length;
          s.openRoute.call('sezione:$label');
          await settle();
          for (var i = before; i < found.length; i++) {
            found[i] =
                '${size.width.toInt()}x${size.height.toInt()} ×$scale '
                '$label: ${found[i]}';
          }
        }
      }
    }
    _stopCollecting();
    expect(found, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 5. Lettore con un file OneNote su un telefono (375×812): l'avviso «Per
  // la sezione completa usa OneNote» con i pulsanti «OneNote» e «Apri
  // con…» sulla stessa riga lasciava al testo larghezza zero: una lettera per
  // riga, colonna alta 799 px (overflow). Ora i pulsanti vanno sotto.
  testWidgets('avviso del lettore con due pulsanti su un telefono', (t) async {
    final found = _collectOverflows();
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_avviso_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final path = '${tmp.path}/Esercizi.one';
    await t.runAsync(() => File(path).writeAsBytes(buildOneNote()));
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    const notice =
        'Testo e immagini estratti dalla sezione OneNote, senza impaginazione. '
        'Per le pagine complete usa OneNote.';
    final problems = <String>[];
    // telefono normale; finestra minima con i caratteri al massimo (l'avviso
    // non può occupare tutta l'altezza)
    for (final (size, scale) in const [
      (Size(375, 812), 1.0),
      (Size(320, 568), 2.0),
    ]) {
      t.view.physicalSize = size;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      await t.pumpWidget(
        _app(
          ReaderScreen(
            key: ValueKey(size),
            path: path,
            store: ReaderStore(SettingsRepository(db)),
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(notice), findsOneWidget);
      expect(find.text('OneNote'), findsWidgets);
      // il testo ha una larghezza decente (non una lettera per riga) e
      // l'avviso non supera un terzo dell'altezza
      final h = t.getSize(find.text(notice)).height;
      if (scale == 1.0 && h >= 120) problems.add('testo alto $h px');
      final banner = t.getSize(
        find
            .ancestor(
              of: find.text(notice),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      if (banner.height > size.height / 3 + 1) {
        problems.add('avviso alto ${banner.height} px su ${size.height}');
      }
      if (found.isNotEmpty) {
        problems.add('${size.width}x${size.height}: $found');
      }
      found.clear();
    }
    _stopCollecting();
    expect(problems, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 6. Lettore con una registrazione e la sua trascrizione in una finestra
  // stretta e bassa (320×568, caratteri ×2): i comandi del lettore audio
  // sopra la trascrizione non scorrevano e uscivano dallo schermo (176 px).
  testWidgets('registrazione con trascrizione in una finestra bassa', (
    t,
  ) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_media_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final path = '${tmp.path}/lezione.m4a';
    await t.runAsync(() async {
      await File(path).writeAsBytes(List.filled(64, 1));
      await File('${tmp.path}/lezione.md')
          .writeAsString('# Lezione\n\nTesto della trascrizione.');
    });
    await t.pumpWidget(
      _app(
        ReaderScreen(path: path, store: ReaderStore(SettingsRepository(db))),
      ),
    );
    for (var i = 0; i < 60; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    _stopCollecting();
    expect(find.textContaining('Trascrizione'), findsWidgets);
    expect(found, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 7. Impostazioni → «Il mio percorso» con i caratteri ×2: «Aggiorna
  // database» e «Indirizzo del database» sulla stessa riga uscivano di 11 px
  // dai loro pulsanti (visto una volta dalla prova a caso, finestra di 1280
  // px con la colonna di navigazione larga, dopo un «Cambia corso»; non
  // riprodotto a riposo, quindi questa prova NON era rossa prima della
  // correzione: protegge la nuova disposizione, una riga se c'è posto per
  // tutte e due le scritte, altrimenti una sotto l'altra).
  testWidgets('«Il mio percorso» stretto con i caratteri grandi', (t) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(700, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_percorso_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final s = (await t.runAsync(() async {
      final s = await monkeyServices(db, tmp);
      await fillPlan(s, hostile: false);
      return s;
    }))!;
    final problems = <String>[];
    for (final width in const [700.0, 560.0, 420.0, 320.0]) {
      await t.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: const SingleChildScrollView(child: ProfileSection()),
              ),
            ),
          ),
          services: s,
        ),
      );
      for (var i = 0; i < 6; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      if (found.isNotEmpty) problems.add('larghezza $width: $found');
      found.clear();
    }
    _stopCollecting();
    expect(problems, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 8. Studio → «Ordine dei moduli» con la finestra di 360×640 e i caratteri
  // ×2: il riquadro (titolo, spiegazione, lista alta il 55% dello schermo)
  // era più alto della finestra e non scorreva: overflow di 130 px.
  testWidgets('riquadro «Ordine dei moduli» in una finestra bassa', (t) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_ordine_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final s = (await t.runAsync(() => monkeyServices(db, tmp)))!;
    await t.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModuleOrderDialog(
                context,
                modules: [
                  for (var i = 1; i <= 8; i++)
                    StudyModule(id: i, courseId: 1, name: 'Modulo $i', sort: i),
                ],
                selectedId: 2,
              ),
              child: const Text('apri'),
            ),
          ),
        ),
        services: s,
      ),
    );
    await t.tap(find.text('apri'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Ordine dei moduli'), findsOneWidget);
    _stopCollecting();
    expect(found, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 9. Studio → Sessioni Studio con i caratteri ×2: la riga di una sessione
  // («1 h 25 min» + cestino a destra) occupava tutta la larghezza della
  // casella («Trailing widget consumes the entire tile width», tile di
  // 247 px) e il menu «Tipo del file e altro» degli allegati aveva voci più
  // larghe del menu (19 px). Visti dalla prova a caso dopo molte azioni;
  // questa prova NON è rossa sul codice vecchio (le righe lunghe non sono
  // fra quelle costruite) e protegge solo dalle regressioni.
  testWidgets('sessioni di studio con i caratteri grandi', (t) async {
    final found = _collectOverflows();
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_sessioni_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final s = (await t.runAsync(() async {
      final s = await monkeyServices(db, tmp);
      await fillPlan(s, hostile: false);
      // sessioni con durate lunghe da scrivere («1 h 25 min»)
      final first = (await s.courses.all()).first;
      final day = DateTime.now().subtract(const Duration(hours: 4));
      for (final minutes in [85, 125, 1445, 185]) {
        await s.study.insertSession(
          StudySession(
            courseId: first.id!,
            start: day,
            end: day.add(Duration(minutes: minutes)),
            durationMinutes: minutes,
            activityType: ActivityType.theory,
          ),
        );
      }
      return s;
    }))!;
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.allMessagesHandler = MonkeyChannels(tmp).handle;
    addTearDown(() => messenger.allMessagesHandler = null);
    Future<void> settle([int n = 4]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    final problems = <String>[];
    for (final size in const [Size(320, 568), Size(412, 915)]) {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 2;
      await t.pumpWidget(UniversityNotesApp(services: s));
      await settle(6);
      StudyScreen.initialTab = StudyScreen.focusTab;
      s.openRoute.call('sezione:Studio');
      await settle(30);
      final vertical = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axis == Axis.vertical,
      );
      final list = vertical.evaluate().isEmpty ? null : vertical.last;
      for (var i = 0; i < 12 && list != null; i++) {
        await t.drag(list, const Offset(0, -400), warnIfMissed: false);
        await settle(2);
        final e = t.takeException();
        if (e != null) {
          problems.add('${size.width.toInt()}x${size.height.toInt()}: $e');
          break;
        }
      }
      if (found.isNotEmpty) problems.add('${size.width.toInt()}: $found');
      found.clear();
    }
    _stopCollecting();
    expect(problems, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 10. Lettore di una registrazione con la trascrizione in finestre piccole:
  // 568×320 con i caratteri ×2 (intestazione, scelta del motore e ricerca
  // della trascrizione, e «Nessuna trascrizione» durante il caricamento,
  // occupavano più del riquadro: 158 e 19 px) e 320×568 (i cinque pulsanti
  // di avanti e indietro uscivano di 8 px).
  testWidgets('registrazione con trascrizione in una finestra piccola', (
    t,
  ) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(568, 320);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_lettore_reg_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    const course = Course(id: 1, name: 'Analisi');
    final (s, file) = (await t.runAsync(() async {
      final s = await monkeyServices(db, tmp);
      final path = await s.notes.newRecordingPath(
        course,
        DateTime(2026, 10, 12, 8, 30),
        '.wav',
      );
      File(path).writeAsBytesSync(wavBytes(2));
      final base = p.basenameWithoutExtension(path);
      await s.notes.writeText(
        course,
        NoteFolder.transcripts,
        base,
        '# Trascrizione\n\n${'parola ' * 200}',
      );
      return (s, File(path));
    }))!;
    await t.pumpWidget(
      _app(
        RecordingPlayerScreen(course: course, file: file),
        services: s,
      ),
    );
    for (var i = 0; i < 200; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 100));
      if (i > 8 && find.text('Nessuna trascrizione.').evaluate().isEmpty) break;
    }
    expect(find.textContaining('Trascrizione'), findsWidgets);
    final problems = <String>[];
    if (found.isNotEmpty) problems.add('568x320 ×2: $found');
    found.clear();
    for (final (size, scale) in const [
      (Size(320, 568), 1.0),
      (Size(320, 568), 2.0),
      (Size(360, 640), 1.3),
    ]) {
      t.view.physicalSize = size;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      if (found.isNotEmpty) {
        problems.add(
          '${size.width.toInt()}x${size.height.toInt()} ×$scale: '
          '$found',
        );
      }
      found.clear();
    }
    _stopCollecting();
    expect(problems, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 11. Scelta della cartella di OneDrive/Google Drive senza rete e con un
  // doppio tocco su una cartella: il secondo elenco sostituisce il primo
  // prima che il FutureBuilder lo ascolti e l'errore di rete del primo
  // restava senza ascoltatori («eccezione non gestita», trovata dalla prova a
  // caso con la rete assente).
  testWidgets('scelta della cartella: doppio tocco senza rete', (t) async {
    var calls = 0;
    final browser = OneDriveFolderBrowser(
      GraphClient(
        () async => 'token',
        transport: (m, u, {headers = const {}, body}) async {
          calls++;
          if (calls == 1) {
            return GraphResponse(
              200,
              Uint8List.fromList(
                utf8.encode(
                  '{"value":[{"id":"a1","name":"Cartella A",'
                  '"folder":{"childCount":1}}]}',
                ),
              ),
            );
          }
          throw GraphException(0, 'Rete assente (prova).');
        },
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showOneDriveFolderPicker(context, browser),
              child: const Text('apri'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('apri'));
    await t.pump();
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Cartella A'), findsOneWidget);
    final at = t.getCenter(find.text('Cartella A'));
    // due tocchi nello stesso fotogramma
    for (var k = 0; k < 2; k++) {
      final g = await t.startGesture(at);
      await g.up();
    }
    await t.pump();
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(t.takeException(), isNull);
  });

  // 11b. Lo stesso riquadro in una finestra di 568×320 con i caratteri ×1,3:
  // altezza fissa di 420 px e niente scorrimento (4 px di overflow).
  testWidgets('scelta della cartella in una finestra bassa', (t) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(568, 320);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final browser = OneDriveFolderBrowser(
      GraphClient(
        () async => 'token',
        transport: (m, u, {headers = const {}, body}) async => GraphResponse(
          200,
          Uint8List.fromList(
            utf8.encode(
              '{"value":[{"id":"a1","name":"Cartella A",'
              '"folder":{"childCount":1}}]}',
            ),
          ),
        ),
      ),
    );
    await t.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showOneDriveFolderPicker(
                context,
                browser,
                initialPath: 'UniNotes',
              ),
              child: const Text('apri'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('apri'));
    await t.pump();
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    _stopCollecting();
    expect(find.textContaining('Cartella su OneDrive'), findsOneWidget);
    expect(found, isEmpty);
  });

  // 12. RevisionBuilder (la base di quasi tutte le schermate): due
  // ricaricamenti nello stesso fotogramma (due `revision.bump()` di fila) con
  // un errore di lettura: il futuro del primo veniva sostituito prima di
  // essere ascoltato e il suo errore restava senza ascoltatori.
  testWidgets('RevisionBuilder: due ricaricamenti di fila con un errore', (
    t,
  ) async {
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_revision_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final s = (await t.runAsync(() => monkeyServices(db, tmp)))!;
    var calls = 0;
    await t.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(
          home: RevisionBuilder<int>(
            load: (_) async {
              if (calls++ > 0) throw StateError('lettura non riuscita');
              return 1;
            },
            builder: (context, v) => Text('dato $v'),
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('dato 1'), findsOneWidget);
    s.revision
      ..bump()
      ..bump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    expect(find.textContaining('lettura non riuscita'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  // 13. Studio → Sessioni: la casella dell'intervallo accanto a «Sessioni» in
  // una riga già piena (375 px, caratteri ×2) restava con 39,5 px di
  // larghezza mentre il suo contenuto fisso ne chiede 40 (0,5 px di
  // overflow). Ora in uno spazio stretto resta solo la freccia.
  testWidgets('casella di scelta in uno spazio strettissimo', (t) async {
    final found = _collectOverflows();
    final problems = <String>[];
    for (final width in const [20.0, 39.5, 47.0, 60.0, 120.0]) {
      await t.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ChoiceBox<int>(
                    value: 1,
                    items: const [(1, 'Questa settimana'), (2, 'Tutto')],
                    onChanged: (_) {},
                    tooltip: 'Intervallo',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      if (found.isNotEmpty) problems.add('larghezza $width: $found');
      found.clear();
    }
    _stopCollecting();
    expect(problems, isEmpty);
  });

  // 3. Registratore con il testo dal vivo acceso: la riga «Trascrizione ·
  // dal vivo · sul dispositivo» non cedeva spazio e con i caratteri ×2
  // usciva dalla scheda (120 px).
  testWidgets('scheda della trascrizione dal vivo con i caratteri grandi', (
    t,
  ) async {
    final found = _collectOverflows();
    t.view.physicalSize = const Size(768, 1024);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final tmp = (await t.runAsync(
      () => Directory.systemTemp.createTemp('r6_trascrizione_'),
    ))!;
    final db = (await t.runAsync(AppDatabase.openInMemory))!;
    final fakes = MonkeyFakes();
    final s = (await t.runAsync(
      () => monkeyServices(
        db,
        tmp,
        fakes: fakes,
        options: const MonkeyOptions(liveSpeech: true),
      ),
    ))!;
    final channels = MonkeyChannels(tmp)..speech = true;
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.allMessagesHandler = channels.handle;
    addTearDown(() => messenger.allMessagesHandler = null);
    await t.pumpWidget(
      _app(
        const RecorderScreen(initialCourse: Course(id: 1, name: 'Fisica')),
        services: s,
      ),
    );
    await t.runAsync(
      () => s.recorder.start('${tmp.path}/prova.m4a', course: 'Fisica'),
    );
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    fakes.mic.feed(Random(1), chunks: 5);
    await channels.speechEvent('partial', 'buongiorno a tutti');
    await t.pump(const Duration(milliseconds: 200));
    expect(s.recorder.live?.state.name, 'running');
    _stopCollecting();
    expect(found, isEmpty);
    await t.runAsync(s.recorder.stop);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(() async {
      await db.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });
}
