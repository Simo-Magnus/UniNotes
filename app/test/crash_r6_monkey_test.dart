// Sesto giro della caccia ai crash (sigla R6-B): la prova a caso del quarto
// giro (crash_r4_monkey_test.dart, impianto in support/monkey_harness.dart)
// estesa alle parti che raggiungeva poco o niente. Ogni scenario parte da un
// luogo preciso dell'app, ci torna da sola quando ne esce, preferisce i suoi
// pulsanti e fa azioni sue con finti che si rompono a comando:
//
// - onboarding: primo avvio completo (aspetto, ateneo, corso, anno, AI, lingua
//   delle lezioni, avvisi, calendario, esclusioni); finito, si azzera il
//   database e si ricomincia;
// - cambio_corso: Impostazioni → «Cambia corso» (i passi del percorso);
// - impostazioni: tutte le sezioni e i dialoghi, calendario, notifiche e
//   server di OneDrive e Google Drive finti, backup da file;
// - collegamenti: OneDrive, Google Drive, Whisper, Parakeet e AI con server
//   finti che vanno e vengono (rete assente, errori 503, file «dal sito»);
// - lettore: file di prova di ogni formato (buoni e rovinati) aperti dalla
//   sezione File e direttamente, con ricerca, pagine, zoom e scorciatoie;
// - registratore: microfono finto (audio, silenzio, dati storti, flusso che
//   finisce, pausa del sistema), testo dal vivo dal riconoscitore finto o da
//   Parakeet finto, correzione del testo mentre arriva, salvataggio, lettore
//   della registrazione, «Trascrivi con…»;
// - studio: Argomenti, cronometro, Focus (avvio, pausa, salta pausa, termina),
//   moduli, allegati;
// - esami: prove (aggiunta, modifica, eliminazione con «Annulla»), Anni
//   precedenti, Voti dell'anno;
// - libri: elenco, schede, apertura nel lettore.
//
// Suite normale: pochi semi e poche azioni per scenario (meno di un minuto in
// tutto). Giri lunghi con le stesse variabili di crash_r4_monkey_test.dart:
//   CRASH_R4_MONKEY=1 flutter test test/crash_r6_monkey_test.dart
// (CRASH_R4_SEEDS, CRASH_R4_ACTIONS, CRASH_R4_SCENARIO, CRASH_R4_SEED,
// CRASH_R4_TRACE, CRASH_R5_COLLECT).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/features/books/books_screen.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/notes/course_notes_screen.dart';
import 'package:university_notes/features/notes/note_viewer_screen.dart';
import 'package:university_notes/features/notes/recorder_screen.dart';
import 'package:university_notes/features/notes/recording_player_screen.dart';
import 'package:university_notes/features/onboarding/onboarding_flow.dart';
import 'package:university_notes/features/reader/files_screen.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/settings/settings_screen.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/links/links_screen.dart';

import 'support/monkey_harness.dart';

// ---------------------------------------------------------------- utilità

/// Frasi che un professore potrebbe dire (e qualche frase ostile) per il
/// riconoscitore finto.
final _phrases = <String>[
  'buongiorno a tutti',
  'oggi parliamo della derivata di una funzione',
  'la derivata della funzione è continua in zero',
  'quindi abbiamo che x al quadrato più uno è sempre positivo',
  'ripeto',
  '',
  ' ',
  'a',
  'Lo spazio vettoriale ha dimensione finita. ' * 20,
  'parola ' * 400,
  kEmoji * 30,
  'مرحبا بالعالم',
  'e${'́' * 40}',
  '\u202Eal contrario',
  'riga uno\nriga due',
  'trenta e lode',
  'integrale da zero a infinito',
  r'$x^2$ \frac{1}{0}',
  '12345678901234567890',
  'virgola, punto. punto e virgola; due punti: punto esclamativo!',
];

String _phrase(Random r) => _phrases[r.nextInt(_phrases.length)];

/// Azzera tutte le tabelle del database: come un primo avvio.
Future<void> _wipeDatabase(Monkey m) async {
  final s = m.setup.services;
  appNavigatorKey.currentState?.popUntil((x) => x.isFirst);
  await m.settle();
  await m.t.runAsync(() async {
    final db = s.database.db;
    await db.execute('PRAGMA foreign_keys = OFF');
    final tables = await db.rawQuery(
      "select name from sqlite_master where type='table' "
      "and name not like 'sqlite_%'",
    );
    for (final t in tables) {
      await db.delete(t['name']! as String);
    }
    await db.execute('PRAGMA foreign_keys = ON');
  });
  s.profile.value = null;
  s.selectedYear.value = null;
  s.revision.bump();
  await m.settle();
}

/// Scrive in [tmp]/campioni un backup valido dei dati attuali (e uno con i
/// dati mancanti) per «Importa dati».
Future<void> _writeBackups(AppServices s, Random r, Directory tmp) async {
  final json = await BackupService(s.database).exportJson();
  final dir = Directory(p.join(tmp.path, 'campioni'))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'backup_valido.json')).writeAsStringSync(json);
  final map = jsonDecode(json) as Map<String, Object?>;
  final tables = Map<String, Object?>.of(
    (map['tables'] as Map?)?.cast<String, Object?>() ?? const {},
  );
  if (tables.isNotEmpty) tables.remove(tables.keys.first);
  File(p.join(dir.path, 'backup_parziale.json'))
      .writeAsStringSync(jsonEncode({...map, 'tables': tables}));
  File(p.join(dir.path, 'backup_futuro.json'))
      .writeAsStringSync(jsonEncode({...map, 'version': 99}));
}

Future<void> _plan(AppServices s, Random r, Directory tmp) =>
    fillPlan(s, hostile: false);

Future<void> _planWithBackups(AppServices s, Random r, Directory tmp) async {
  await fillPlan(s, hostile: r.nextBool());
  await _writeBackups(s, r, tmp);
}

Future<void> _noData(AppServices s, Random r, Directory tmp) async {}

RegExp _re(String pattern) => RegExp(pattern);

// ---------------------------------------------------------------- aree

/// Area su una sezione della shell, con pulsanti preferiti e azioni.
class _Section extends MonkeyArea {
  const _Section(
    this.name,
    this.route,
    this.isInside, {
    this.prefer = const [],
    this.preferPerMille = 400,
    this.extra,
    this.actionsPerMille = 150,
  });

  @override
  final String name;
  @override
  final String? route;
  final bool Function(Monkey m) isInside;
  @override
  final List<RegExp> prefer;
  @override
  final int preferPerMille;
  @override
  final int actionsPerMille;
  final List<MonkeyAction> Function(Monkey m)? extra;

  @override
  bool inArea(Monkey m) => isInside(m);

  @override
  List<MonkeyAction> actions(Monkey m) => extra?.call(m) ?? const [];
}

/// Primo avvio: finito l'onboarding si azzerano i dati e si ricomincia.
class _OnboardingArea extends MonkeyArea {
  const _OnboardingArea();
  @override
  String get name => 'onboarding';
  @override
  List<RegExp> get prefer => [
    _re(
      r'continua|decido più tardi|non ora|attiva gli avvisi|collega il '
      r'calendario|vai all|aggiungi corso|standard|alto contrasto',
    ),
  ];
  @override
  bool inArea(Monkey m) => m.shows<OnboardingFlow>();
  @override
  int get actionsPerMille => 450;
  @override
  List<MonkeyAction> actions(Monkey m) => [
    (
      name: 'va avanti nel percorso',
      weight: 10,
      run: (m) async {
        if (!await m.tapAny(exclude: _re(r'indietro'))) await m.settle();
      },
    ),
  ];
  @override
  Future<void> enter(Monkey m) async {
    final s = m.setup.services;
    if (s.profile.value == null) {
      // ancora (o di nuovo) nell'onboarding: si prosegue da dove si è
      await m.settle();
      return;
    }
    m.log('area: onboarding (database azzerato, primo avvio da capo)');
    await _wipeDatabase(m);
  }
}

/// Cambio di corso dalle Impostazioni.
class _ChangePathArea extends MonkeyArea {
  const _ChangePathArea();
  @override
  String get name => 'cambio corso';
  @override
  String? get route => AppRoutes.settings;
  @override
  List<RegExp> get prefer => [
    _re(r'cambia corso'),
    _re(r'continua|vai all|aggiungi corso|non ora'),
  ];
  @override
  int get preferPerMille => 550;
  @override
  bool inArea(Monkey m) =>
      m.shows<SettingsScreen>() || m.shows<OnboardingFlow>();
  @override
  int get actionsPerMille => 300;
  @override
  List<MonkeyAction> actions(Monkey m) => [
    (
      name: 'va avanti nel percorso',
      weight: 10,
      run: (m) async {
        // dalle Impostazioni: «Cambia corso»; dentro: avanti
        if (m.shows<OnboardingFlow>()) {
          if (!await m.tapAny(exclude: _re(r'indietro'))) await m.settle();
        } else if (!await m.tapMatching(_re(r'cambia corso'))) {
          await m.settle();
        }
      },
    ),
  ];
}

bool _inSettings(Monkey m) => m.shows<SettingsScreen>();

// ---------------------------------------------------------------- azioni

List<MonkeyAction> _settingsActions(Monkey m) {
  final f = m.setup.fakes;
  return [
    ..._formActions(m),
    (
      name: 'importa un backup (valido, parziale o di una versione futura)',
      weight: 6,
      run: (m) async {
        m.picker.queue.add(
          [
            'backup_valido.json',
            'backup_parziale.json',
            'backup_futuro.json',
            'backup.json',
          ][m.rnd.nextInt(4)],
        );
        await m.tapMatching(_re(r'importa dati'), what: 'importa');
        await m.settle();
        // conferma del ripristino
        await m.tapMatching(
          _re(r'^(ripristina|importa|conferma|sostituisci|sì)'),
          what: 'conferma',
        );
        await m.settle();
      },
    ),
    (
      name: 'esporta i dati',
      weight: 2,
      run: (m) async {
        await m.tapMatching(_re(r'esporta dati'), what: 'esporta');
        await m.settle();
      },
    ),
    (
      name: 'il calendario perde l\'accesso',
      weight: 2,
      run: (m) async {
        f.calendar.revoked = !f.calendar.revoked;
        m.setup.services.revision.bump();
        await m.settle();
      },
    ),
    (
      name: 'il calendario non ha calendari',
      weight: 1,
      run: (m) async {
        f.calendar.noCalendars = !f.calendar.noCalendars;
        await m.settle();
      },
    ),
    (
      name: 'le scritture nel calendario falliscono',
      weight: 1,
      run: (m) async {
        f.calendar.failWrites = !f.calendar.failWrites;
        await m.settle();
      },
    ),
    (
      name: 'il sistema nega le notifiche',
      weight: 1,
      run: (m) async {
        f.notifications.granted = !f.notifications.granted;
        await m.settle();
      },
    ),
    (
      name: 'rete assente per i server finti',
      weight: 1,
      run: (m) async {
        f.offline = !f.offline;
        await m.settle();
      },
    ),
    (
      name: 'cambia il giorno',
      weight: 1,
      run: (m) async {
        m.setup.services.revision.bump();
        await m.settle();
      },
    ),
  ];
}

List<MonkeyAction> _linksActions(Monkey m) {
  final f = m.setup.fakes;
  return [
    (
      name: 'rete assente per i server finti',
      weight: 3,
      run: (m) async {
        f.offline = !f.offline;
        await m.settle();
      },
    ),
    (
      name: 'i server finti rispondono 503',
      weight: 3,
      run: (m) async {
        f.serverErrors = !f.serverErrors;
        await m.settle();
      },
    ),
    (
      name: 'un file nuovo su OneDrive «dal sito»',
      weight: 2,
      run: (m) async {
        f.onedrive.put(
          'UniNotes/Corsi/Analisi/Appunti/dal_sito_${m.rnd.nextInt(5)}.md',
          '# dal sito\n${_phrase(m.rnd)}',
        );
        await m.settle();
      },
    ),
    (
      name: 'un file nuovo su Google Drive «dal sito»',
      weight: 2,
      run: (m) async {
        f.google.add(
          'root',
          'dal_sito_${m.rnd.nextInt(5)}.md',
          'text/markdown',
          utf8.encode('# dal sito\n${_phrase(m.rnd)}'),
        );
        await m.settle();
      },
    ),
    (
      name: 'il download del modello Parakeet finisce o fallisce',
      weight: 2,
      run: (m) async {
        final pk = f.parakeet;
        if (pk == null || !pk.downloadStarted) return;
        m.rnd.nextBool() ? pk.finishDownload() : pk.failDownload();
        await m.settle();
      },
    ),
    (
      name: 'cambia il giorno',
      weight: 1,
      run: (m) async {
        m.setup.services.revision.bump();
        await m.settle();
      },
    ),
  ];
}

/// Azioni del lettore: un file di prova aperto direttamente, scorciatoie
/// con Ctrl, ricerca e salto a pagina.
List<MonkeyAction> _readerActions(Monkey m) {
  final s = m.setup.services;
  return [
    (
      name: 'apri un file di prova nel lettore',
      weight: 30,
      run: (m) async {
        final ctx = appNavigatorKey.currentContext;
        if (ctx == null) return;
        final dirs = [
          await m.t.runAsync(() => s.library.directory()),
          await m.t.runAsync(() => s.materialsLibrary.directory()),
          await m.t.runAsync(() => s.attachmentsLibrary.directory()),
        ];
        final files = <File>[];
        await m.t.runAsync(() async {
          for (final d in dirs) {
            if (d == null) continue;
            files.addAll(d.listSync().whereType<File>());
          }
        });
        if (files.isEmpty) return;
        files.sort((a, b) => a.path.compareTo(b.path));
        final f = files[m.rnd.nextInt(files.length)];
        m.log('apre nel lettore ${p.basename(f.path)}');
        // non si aspetta: la pagina si chiude con «Indietro»
        // ignore: use_build_context_synchronously
        openInReader(ctx, f.path, title: p.basename(f.path)).ignore();
        await m.settle();
      },
    ),
    (
      name: 'Ctrl+F',
      weight: 6,
      run: (m) => m.shortcut(LogicalKeyboardKey.keyF, control: true),
    ),
    (
      name: 'Ctrl+D (segnalibro)',
      weight: 6,
      run: (m) => m.shortcut(LogicalKeyboardKey.keyD, control: true),
    ),
    (
      name: 'Ctrl+G (vai a)',
      weight: 4,
      run: (m) => m.shortcut(LogicalKeyboardKey.keyG, control: true),
    ),
    (
      name: 'Ctrl++ (ingrandisci)',
      weight: 5,
      run: (m) => m.shortcut(LogicalKeyboardKey.equal, control: true),
    ),
    (
      name: 'Ctrl+- (rimpicciolisci)',
      weight: 5,
      run: (m) => m.shortcut(LogicalKeyboardKey.minus, control: true),
    ),
    (
      name: 'Ctrl+0 (zoom iniziale)',
      weight: 2,
      run: (m) => m.shortcut(LogicalKeyboardKey.digit0, control: true),
    ),
    (
      name: 'F11 (schermo intero)',
      weight: 2,
      run: (m) => m.shortcut(LogicalKeyboardKey.f11),
    ),
    (
      name: 'Pagina giù/su, Inizio, Fine',
      weight: 10,
      run: (m) async {
        final k = [
          LogicalKeyboardKey.pageDown,
          LogicalKeyboardKey.pageUp,
          LogicalKeyboardKey.home,
          LogicalKeyboardKey.end,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.space,
        ][m.rnd.nextInt(7)];
        m.log('tasto ${k.keyLabel}');
        await m.t.sendKeyEvent(k);
      },
    ),
    (
      name: 'cerca nel testo',
      weight: 8,
      run: (m) async {
        const words = ['a', 'Ciao', 'mondo', 'x', '1', 'e', 'Titolo', ''];
        await m.typeInField(words[m.rnd.nextInt(words.length)]);
        await m.t.testTextInput.receiveAction(TextInputAction.search);
      },
    ),
    (
      name: 'vai a pagina',
      weight: 4,
      run: (m) async {
        const pages = ['1', '0', '-3', '2', '99999', '7', '1e9', ''];
        await m.typeInField(
          pages[m.rnd.nextInt(pages.length)],
          matching: _re(r'pagina|vai|numero'),
        );
        await m.t.testTextInput.receiveAction(TextInputAction.done);
      },
    ),
  ];
}

/// Azioni del registratore: audio, riconoscitore, microfono e permessi.
List<MonkeyAction> _recorderActions(Monkey m) {
  final f = m.setup.fakes;
  final ch = m.setup.channels;
  Future<void> advance(Monkey m, int seconds, {bool audio = true}) async {
    // il tempo scorre a passi da 1 s con l'audio che arriva
    for (var i = 0; i < seconds; i++) {
      if (audio) f.mic.feed(m.rnd, amplitude: 0.1 + m.rnd.nextDouble() * 0.4);
      await m.t.pump(const Duration(seconds: 1));
      await m.t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }

  /// Apre la schermata del registratore se non è quella sullo schermo.
  Future<void> openRecorderScreen(Monkey m) async {
    if (m.shows<RecorderScreen>()) return;
    appNavigatorKey.currentState?.popUntil((x) => x.isFirst);
    await m.settle();
    m.setup.services.openRoute.call(AppRoutes.record);
    await m.settle();
    await m.settle();
  }

  Future<void> tap(String what, String pattern) async {
    if (what == 'avvia' || what == 'pausa') {
      await openRecorderScreen(m);
      // il pulsante grande non ha testo nel suo albero: lo si trova dall'icona
      for (final icon in [
        Icons.mic,
        Icons.pause_rounded,
        Icons.play_arrow_rounded,
      ]) {
        final rec = m.setup.services.recorder;
        final want = what == 'avvia' ? !rec.active : rec.active;
        if (!want) break;
        if (await m.tapIcon(icon)) return m.settle();
      }
    }
    if (!await m.tapMatching(_re(pattern), what: what)) await m.settle();
  }

  /// Aspetta (tempo finto e vero insieme) che [done] sia vero.
  Future<void> waitFor(Monkey m, bool Function() done, {int max = 60}) async {
    for (var i = 0; i < max && !done(); i++) {
      await m.t.pump(const Duration(milliseconds: 100));
      await m.t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
  }

  return [
    (
      name: 'registrazione completa (avvio, audio, testo, segnalibri, fine)',
      weight: 14,
      run: (m) async {
        final rec = m.setup.services.recorder;
        await openRecorderScreen(m);
        if (!rec.active) {
          await tap('avvia', r'avvia registrazione');
          await waitFor(m, () => rec.active, max: 30);
        }
        if (!rec.active) return;
        final n = 3 + m.rnd.nextInt(14);
        for (var i = 0; i < n && rec.active; i++) {
          switch (m.rnd.nextInt(10)) {
            case 0 || 1:
              f.mic.feed(m.rnd, chunks: 1 + m.rnd.nextInt(30));
            case 2:
              f.mic.feed(m.rnd, chunks: 3);
              await ch.speechEvent('partial', _phrase(m.rnd));
            case 3:
              f.mic.feed(m.rnd, chunks: 5);
              await ch.speechEvent('result', _phrase(m.rnd));
            case 4:
              await m.tapKey('recorder-mark');
            case 5:
              await tap('pausa', r'metti in pausa|riprendi la registrazione');
            case 6:
              await advance(m, 1 + m.rnd.nextInt(20));
            case 7:
              await m.typeInField(_phrase(m.rnd));
            case 8:
              await m.tapMatching(_re(r'aggiungi nota'), what: 'nota');
            default:
              await m.t.pump(Duration(milliseconds: 100 + m.rnd.nextInt(900)));
          }
          await m.settle();
        }
        if (!rec.active) return;
        final end = m.rnd.nextInt(10);
        if (end < 7) {
          await m.tapKey('recorder-save');
          await waitFor(m, () => !rec.active && !rec.saving, max: 80);
        } else if (end < 9) {
          await m.tapKey('recorder-delete');
          await m.settle();
          await m.tapMatching(_re(r'^elimina$|\| elimina$|^elimina \|'));
          await waitFor(m, () => !rec.active, max: 40);
        }
        await m.settle();
      },
    ),
    (
      name: 'avvia la registrazione',
      weight: 18,
      run: (m) => tap('avvia', r'avvia registrazione'),
    ),
    (
      name: 'pausa o ripresa',
      weight: 12,
      run: (m) => tap('pausa', r'metti in pausa|riprendi la registrazione'),
    ),
    (
      name: 'segnalibro',
      weight: 8,
      run: (m) => tap('segna', r'^segna|\| segna'),
    ),
    (
      name: 'salva la registrazione',
      weight: 5,
      run: (m) => tap('salva', r'^salva$|\| salva$|^salva \|'),
    ),
    (
      name: 'elimina la registrazione',
      weight: 1,
      run: (m) => tap('elimina', r'^elimina'),
    ),
    (
      name: 'apre le registrazioni salvate e una lezione',
      weight: 5,
      run: (m) async {
        appNavigatorKey.currentState?.popUntil((x) => x.isFirst);
        await m.settle();
        m.setup.services.openRoute.call('sezione:Registra');
        await m.settle();
        await m.tapMatching(_re(r'\d+ file'), what: 'insegnamento');
        await m.settle();
        await m.tapMatching(
          _re(r'registrazion|lezione|\.m4a|\.wav|trascri'),
          what: 'lezione',
        );
        await m.settle();
      },
    ),
    (
      name: 'arriva audio',
      weight: 40,
      run: (m) async {
        const amps = [0.0, 0.01, 0.2, 0.6, 1.0];
        f.mic.feed(
          m.rnd,
          chunks: 1 + m.rnd.nextInt(m.rnd.nextInt(8) == 0 ? 120 : 12),
          amplitude: amps[m.rnd.nextInt(amps.length)],
        );
        await m.settle();
      },
    ),
    (
      name: 'arrivano dati storti dal microfono',
      weight: 3,
      run: (m) async {
        f.mic.feedOdd(m.rnd);
        await m.settle();
      },
    ),
    (
      name: 'passa del tempo registrando',
      weight: 12,
      run: (m) =>
          advance(m, 2 + m.rnd.nextInt(m.rnd.nextInt(5) == 0 ? 90 : 12)),
    ),
    (
      name: 'passa del tempo in silenzio',
      weight: 4,
      run: (m) => advance(m, 5 + m.rnd.nextInt(60), audio: false),
    ),
    (
      name: 'testo provvisorio dal riconoscitore',
      weight: 25,
      run: (m) async {
        f.mic.feed(m.rnd, chunks: 3);
        await ch.speechEvent('partial', _phrase(m.rnd));
        await m.settle();
      },
    ),
    (
      name: 'testo definitivo dal riconoscitore',
      weight: 15,
      run: (m) async {
        f.mic.feed(m.rnd, chunks: 5);
        await ch.speechEvent('result', _phrase(m.rnd));
        await m.settle();
      },
    ),
    (
      name: 'testo che si allunga e si corregge',
      weight: 10,
      run: (m) async {
        var text = '';
        for (var i = 0; i < 2 + m.rnd.nextInt(5); i++) {
          text = '$text ${_phrase(m.rnd)}'.trim();
          f.mic.feed(m.rnd, chunks: 2);
          await ch.speechEvent('partial', text);
          await m.t.pump(const Duration(milliseconds: 50));
        }
        await ch.speechEvent('result', text);
        await m.settle();
      },
    ),
    (
      name: 'evento di una sessione vecchia',
      weight: 2,
      run: (m) async {
        await ch.speechEvent('partial', _phrase(m.rnd), session: 0);
        await ch.speechEvent('result', _phrase(m.rnd), session: -5);
        await m.settle();
      },
    ),
    (
      name: 'errore del riconoscitore',
      weight: 2,
      run: (m) async {
        await ch.speechEvent('error', _phrase(m.rnd));
        await m.settle();
      },
    ),
    (
      name: 'il riconoscitore si ferma',
      weight: 1,
      run: (m) async {
        await ch.speechEvent('ended', '');
        await m.settle();
      },
    ),
    (
      name: 'il riconoscitore non parte alla prossima registrazione',
      weight: 1,
      run: (m) async {
        ch.speechStarts = false;
      },
    ),
    (
      name: 'il microfono viene preso da un\'altra app',
      weight: 2,
      run: (m) async {
        f.mic.endStream();
        await m.settle();
      },
    ),
    (
      name: 'il sistema mette in pausa (telefonata)',
      weight: 2,
      run: (m) async {
        f.mic.systemPause();
        await m.settle();
      },
    ),
    (
      name: 'permesso del microfono negato alla prossima registrazione',
      weight: 2,
      run: (m) async {
        f.mic.denyPermission = true;
      },
    ),
    (
      name: 'microfono occupato alla prossima registrazione',
      weight: 2,
      run: (m) async {
        f.mic.failStart = true;
      },
    ),
    (
      name: 'la prossima pausa o ripresa non riesce',
      weight: 1,
      run: (m) async {
        f.mic.failResume = true;
      },
    ),
    (
      name: 'scrive nel testo dal vivo',
      weight: 10,
      run: (m) async {
        await m.typeInField(_phrase(m.rnd));
        f.mic.feed(m.rnd, chunks: 4);
        await ch.speechEvent('partial', _phrase(m.rnd));
        await m.settle();
      },
    ),
  ];
}

/// Compila a caso i campi della schermata o del riquadro aperto e conferma.
Future<void> _fillAndConfirm(Monkey m) async {
  for (var i = 0, n = 1 + m.rnd.nextInt(5); i < n; i++) {
    if (!await m.typeInField(randomText(m.rnd))) break;
    await m.t.pump(const Duration(milliseconds: 30));
  }
  await m.tapMatching(
    _re(r'^(salva|aggiungi|conferma|fatto|ok|crea|continua|applica|imposta)$'),
    what: 'conferma',
  );
  await m.settle();
}

/// «Elimina», poi «Annulla» dall'avviso in basso (o conferma del riquadro).
Future<void> _deleteAndUndo(Monkey m) async {
  if (!await m.tapMatching(_re(r'^elimina|\| elimina'), what: 'elimina')) {
    return;
  }
  await m.settle();
  await m.tapMatching(_re(r'^elimina$|^elimina \|'), what: 'conferma');
  await m.settle();
  if (m.rnd.nextBool()) {
    await m.tapMatching(_re(r'^annulla'), what: 'annulla');
    await m.settle();
  }
}

/// Azioni comuni a tutte le schermate con moduli ed elenchi modificabili.
List<MonkeyAction> _formActions(Monkey m) => [
  (name: 'compila i campi e conferma', weight: 10, run: _fillAndConfirm),
  (name: 'elimina e poi annulla', weight: 5, run: _deleteAndUndo),
  (
    name: 'cambia il giorno',
    weight: 1,
    run: (m) async {
      m.setup.services.revision.bump();
      await m.settle();
    },
  ),
];

/// Azioni di Studio: sessione Focus completa e tempo che passa.
List<MonkeyAction> _studyActions(Monkey m) {
  final f = m.setup.fakes;
  Future<void> minutes(Monkey m, int n) async {
    m.log('passano $n minuti');
    f.clockOffset += Duration(minutes: n);
    for (var i = 0; i < n; i++) {
      await m.t.pump(const Duration(minutes: 1));
      await m.t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }

  return [
    (
      name: 'sessione Focus completa (avvio, pause, tempo, fine)',
      weight: 14,
      run: (m) async {
        final focus = m.setup.services.focus;
        if (!focus.active) {
          if (!m.shows<StudyScreen>()) return;
          await m.tapMatching(_re(r'sessioni studio'), what: 'scheda');
          await m.settle();
          await m.tapMatching(_re(r'^timer$'), what: 'timer');
          await m.settle();
          if (!await m.tapMatching(_re(r'avvia il timer'), what: 'avvia')) {
            return;
          }
          await m.settle();
          // «Silenziare il telefono?»
          await m.tapMatching(_re(r'avvia senza|concedi'), what: 'silenzio');
          await m.settle();
          await m.settle();
        }
        for (var i = 0, n = 2 + m.rnd.nextInt(8); i < n && focus.active; i++) {
          switch (m.rnd.nextInt(6)) {
            case 0:
              await minutes(m, [1, 5, 24, 25, 26, 50, 100][m.rnd.nextInt(7)]);
            case 1:
              await m.tapMatching(_re(r'^pausa|\| pausa'), what: 'pausa');
            case 2:
              await m.tapMatching(
                _re(r'^riprendi|\| riprendi'),
                what: 'riprendi',
              );
            case 3:
              await m.tapMatching(_re(r'salta pausa'), what: 'salta pausa');
            case 4:
              await m.tapMatching(_re(r'^fatto|cambia'), what: 'altro');
            default:
              await m.t.pump(Duration(seconds: 1 + m.rnd.nextInt(30)));
          }
          await m.settle();
        }
        if (focus.active && m.rnd.nextInt(10) < 8) {
          await m.tapMatching(_re(r'^termina|\| termina'), what: 'termina');
          await m.settle();
          await m.tapMatching(
            _re(m.rnd.nextInt(4) == 0 ? r'^scarta' : r'termina e salva'),
            what: 'fine',
          );
          await m.settle();
          await m.settle();
        }
      },
    ),
    (
      name: 'passano alcuni minuti',
      weight: 8,
      run: (m) => minutes(m, [1, 5, 25, 26, 50, 90][m.rnd.nextInt(6)]),
    ),
    (
      name: 'si torna alla scheda Sessioni Studio',
      weight: 6,
      run: (m) async {
        await m.tapMatching(_re(r'sessioni studio'), what: 'scheda');
      },
    ),
    ..._formActions(m),
  ];
}

// ---------------------------------------------------------------- scenari

final _scenarios = <MonkeyScenario>[
  const MonkeyScenario(
    'onboarding',
    _noData,
    area: _OnboardingArea(),
    // «Collega il calendario» (calendario finto) si può toccare
    options: MonkeyOptions(platform: 'auto', allowLogin: true),
  ),
  const MonkeyScenario(
    'cambio_corso',
    _plan,
    area: _ChangePathArea(),
    options: MonkeyOptions(platform: 'auto'),
  ),
  MonkeyScenario(
    'impostazioni',
    _planWithBackups,
    area: _Section(
      'impostazioni',
      AppRoutes.settings,
      _inSettings,
      prefer: [
        _re(
          r'calendario|notifiche|avvisi|esclusi|focus|non disturbare|aspetto|'
          r'contrasto|caratteri|animazioni|suoni|vibrazioni|esporta|importa|'
          r'privacy|licenze|domande|ripristina|aggiorna database|collega|'
          r'accedi|scollega|salva|annulla|modifica|aggiungi',
        ),
      ],
      extra: _settingsActions,
    ),
    options: const MonkeyOptions(
      fakeClouds: true,
      allowLogin: true,
      platform: 'auto',
    ),
  ),
  MonkeyScenario(
    'collegamenti',
    _plan,
    area: _Section(
      'collegamenti',
      AppRoutes.links,
      (m) => m.shows<LinksScreen>(),
      prefer: [
        _re(
          r'accedi|collega|scollega|sincronizza|onedrive|google|whisper|'
          r'parakeet|scarica|elimina|modello|interrompi|annulla|riprova|'
          r'microsoft|assistente|chatgpt|gemini|copilot|claude|scegli|cartella',
        ),
      ],
      extra: _linksActions,
    ),
    options: const MonkeyOptions(
      fakeClouds: true,
      allowLogin: true,
      liveEngine: true,
    ),
  ),
  MonkeyScenario(
    'lettore',
    _plan,
    area: _Section(
      'lettore',
      'sezione:File',
      (m) => m.shows<FilesScreen>() || m.shows<ReaderScreen>(),
      prefer: [
        _re(
          r'corpus_|rovinato_|libri|materiali|allegati|appunti|recenti|'
          r'altro|indice|segnalibr|trova|vai|apri con|condividi|ingrandisci|'
          r'rimpicciolisci|adatta|pagina',
        ),
      ],
      preferPerMille: 500,
      extra: _readerActions,
      actionsPerMille: 250,
    ),
    options: const MonkeyOptions(corpus: true),
  ),
  MonkeyScenario(
    'registratore',
    _plan,
    area: _Section(
      'registratore',
      AppRoutes.record,
      (m) =>
          m.shows<RecorderScreen>() ||
          m.shows<CourseNotesScreen>() ||
          m.shows<RecordingPlayerScreen>() ||
          m.shows<NoteViewerScreen>(),
      prefer: [
        _re(
          r'registra|inizia|avvia|pausa|riprendi|segna|segnalibro|salva|'
          r'scarta|elimina|lingua|italiano|inglese|insegnamento|testo|'
          r'trascriv|riproduci|ascolta|condividi|annulla|ferma|chiudi|'
          r'taglia|salta silenzi|velocità|indietro di|avanti di|riassumi|'
          r'apri il riassunto|cerca|copia|togli il tratto|tieni solo|vai a|'
          r'allega|rinomina|salva una copia|esporta pdf|vedi trascrizione|'
          r'apri in|nota|formule',
        ),
      ],
      preferPerMille: 500,
      extra: _recorderActions,
      actionsPerMille: 400,
    ),
    options: const MonkeyOptions(liveSpeech: true, liveEngine: true),
  ),
  MonkeyScenario(
    'studio',
    _plan,
    area: _Section(
      'studio',
      'sezione:Studio',
      (m) => m.shows<StudyScreen>(),
      prefer: [
        _re(
          r'avvia|pausa|riprendi|salta|termina|salva|elimina|cronometro|'
          r'timer|focus|modulo|argomento|allega|sessioni|statistiche|'
          r'obiettivo|scarta|fatto|annulla|aggiungi|modifica|sposta',
        ),
      ],
      extra: _studyActions,
    ),
  ),
  MonkeyScenario(
    'esami',
    _plan,
    area: _Section(
      'esami',
      'sezione:Esami',
      (m) => m.shows<ExamsScreen>(),
      prefer: [
        _re(
          r'nuova prova|aggiungi|modifica|elimina|annulla|anni precedenti|'
          r'voti|salva|segna|prenota|superato|sostenut|esame|prova|esonero|'
          r'voto|lode|data|ora|aula|medie|statistiche',
        ),
      ],
      extra: _formActions,
    ),
  ),
  MonkeyScenario(
    'libri',
    _plan,
    area: _Section(
      'libri',
      'sezione:Libri',
      (m) => m.shows<BooksScreen>(),
      prefer: [
        _re(
          r'aggiungi|libro|apri|scarica|elimina|annulla|modifica|filtr|'
          r'ordina|possiedo|biblioteca|salva|cerca|file|cartella',
        ),
      ],
      extra: _formActions,
    ),
  ),
];

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  final total = <String, int>{};
  tearDownAll(() {
    // ignore: avoid_print
    print('scimmia R6: ${total['azioni'] ?? 0} azioni casuali senza errori');
  });

  if (!monkeyLong) {
    group('scimmia R6 (giro breve)', () {
      for (final sc in _scenarios) {
        const seed = 7;
        const steps = 35;
        testWidgets(
          '${sc.name}, seme $seed, $steps azioni',
          (t) => runMonkey(
            t,
            sc,
            seed,
            steps,
            semantics: sc.name == 'registratore',
            total: total,
          ),
          timeout: const Timeout(Duration(minutes: 3)),
        );
      }
    });
    return;
  }

  final only = Platform.environment['CRASH_R4_SEED'];
  final seeds = only != null
      ? [int.parse(only)]
      : [for (var i = 0; i < monkeyEnv('CRASH_R4_SEEDS', 12); i++) 2000 + i];
  final steps = monkeyEnv('CRASH_R4_ACTIONS', 1200);
  final wanted = Platform.environment['CRASH_R4_SCENARIO'];
  group('scimmia R6 (giro lungo)', () {
    for (final sc in _scenarios) {
      if (wanted != null && sc.name != wanted) continue;
      for (final seed in seeds) {
        testWidgets(
          '${sc.name}, seme $seed, $steps azioni',
          (t) => runMonkey(
            t,
            sc,
            seed,
            steps,
            semantics: seed.isOdd,
            total: total,
          ),
          timeout: const Timeout(Duration(minutes: 30)),
        );
      }
    }
  });
}
