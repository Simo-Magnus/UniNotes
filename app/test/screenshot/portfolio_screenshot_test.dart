// Screenshot dell'app per il sito portfolio dello sviluppatore.
//
// Non fa parte della suite normale: salta se manca UNINOTES_SCREENSHOT=1.
// Costruisce le schermate vere dell'app (stessi widget, tema e servizi con i
// finti della prova a caso) con i dati fittizi di portfolio_dati.dart, carica
// i font veri (IBM Plex, MaterialIcons) e salva i PNG con
// RenderRepaintBoundary.toImage.
//
// Rigenerare (da D:\University_Notes\app, PowerShell):
//   $env:UNINOTES_SCREENSHOT='1'
//   & D:\tools\flutter\bin\flutter.bat test --no-pub test/screenshot/portfolio_screenshot_test.dart
// Cartella di uscita: UNINOTES_SCREENSHOT_DIR, altrimenti
// ..\grafica_play\screenshot_portfolio. Con UNINOTES_SCREENSHOT_SOLO=testo si
// rifanno solo le immagini il cui nome contiene quel testo (per esempio
// «libri_telefono»); con UNINOTES_SCREENSHOT_FORMATO=telefono|tablet|desktop
// solo quel formato (esplora = una pagina intera in un'immagine alta, solo
// per guardare cosa c'è sotto la piega). Le date dei dati sono relative a
// oggi e pensate per un giorno fra settembre e gennaio (primo semestre).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart'
    show appNavigatorKey;
import 'package:university_notes/features/exams/exam_detail.dart';
import 'package:university_notes/features/notes/recorder_screen.dart';
import 'package:university_notes/features/notes/course_notes_screen.dart';
import 'package:university_notes/features/notes/note_viewer_screen.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recording_player_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/core/constants/enums.dart' show ActivityType;
import 'package:university_notes/features/study/focus/focus_plan.dart'
    show FocusSettings;
import 'package:university_notes/features/study/focus/focus_screen.dart'
    show openFocusScreen;
import 'package:university_notes/features/study/focus/focus_service.dart'
    show FocusLink;
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/main.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import '../support/catalog_fixtures.dart' show fakeCatalog;
import '../support/monkey_harness.dart';
import 'portfolio_dati.dart';

final _attivo = Platform.environment['UNINOTES_SCREENSHOT'] == '1';
final _solo = Platform.environment['UNINOTES_SCREENSHOT_SOLO'] ?? '';
final _formato = Platform.environment['UNINOTES_SCREENSHOT_FORMATO'] ?? '';

Directory get _uscita => Directory(
  Platform.environment['UNINOTES_SCREENSHOT_DIR'] ??
      p.normalize(p.join(Directory.current.path, '..', 'grafica_play',
          'screenshot_portfolio')),
);

// ------------------------------------------------------------------ font

Future<void> _caricaFont() async {
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? r'D:\tools\flutter';
  Future<void> famiglia(String nome, List<String> file) async {
    final l = FontLoader(nome);
    for (final f in file) {
      final bytes = File(f).readAsBytesSync();
      l.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await l.load();
  }

  String f(String n) => p.join('assets', 'fonts', n);
  await famiglia('IBMPlexSans', [
    f('IBMPlexSans-Light.ttf'),
    f('IBMPlexSans-Regular.ttf'),
    f('IBMPlexSans-Italic.ttf'),
    f('IBMPlexSans-Medium.ttf'),
    f('IBMPlexSans-SemiBold.ttf'),
    f('IBMPlexSans-Bold.ttf'),
  ]);
  await famiglia('IBMPlexMono', [
    f('IBMPlexMono-Regular.ttf'),
    f('IBMPlexMono-SemiBold.ttf'),
  ]);
  await famiglia('MaterialIcons', [
    p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts',
        'materialicons-regular.otf'),
  ]);
  // formule LaTeX (flutter_math_fork): i caratteri KaTeX del pacchetto
  final config = File(p.join('.dart_tool', 'package_config.json'));
  final pacchetti = jsonDecode(config.readAsStringSync()) as Map;
  final math = (pacchetti['packages'] as List).firstWhere(
    (x) => (x as Map)['name'] == 'flutter_math_fork',
  ) as Map;
  final cartella = Directory(
    p.join(Uri.parse(math['rootUri'] as String).toFilePath(), 'lib',
        'katex_fonts', 'fonts'),
  );
  final perFamiglia = <String, List<String>>{};
  for (final e in cartella.listSync().whereType<File>()) {
    final nome = p.basename(e.path);
    if (!nome.endsWith('.ttf')) continue;
    (perFamiglia[nome.split('-').first] ??= []).add(e.path);
  }
  for (final e in perFamiglia.entries) {
    await famiglia('packages/flutter_math_fork/${e.key}', e.value);
  }
  await famiglia('Roboto', [
    p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts',
        'roboto-regular.ttf'),
    p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts',
        'roboto-bold.ttf'),
  ]);
}

// --------------------------------------------------------------- formati

class Formato {
  const Formato(this.nome, this.logico, this.dpr, this.piattaforma);
  final String nome;
  final Size logico;
  final double dpr;
  final String piattaforma;
}

const _telefono = Formato('telefono', Size(360, 800), 3, 'android');
const _tablet = Formato('tablet', Size(1024, 1366), 2, 'ios');
const _desktop = Formato('desktop', Size(1920, 1080), 1, 'windows');

/// Solo per esplorare: una pagina intera in un'immagine alta.
const _esplora = Formato('esplora', Size(360, 3600), 1.2, 'android');

// ------------------------------------------------------------- contesto

class Ctx {
  Ctx(this.t, this.s, this.key, this.formato, this.dir, this.channels,
      this.fakes);
  final MonkeyFakes fakes;
  final WidgetTester t;
  final AppServices s;
  final GlobalKey key;
  final Formato formato;
  final Directory dir;
  final MonkeyChannels channels;
  String tema = 'chiaro';

  /// La scena ha già salvato da sé le sue immagini.
  bool giaScattato = false;
  int numero = 0;

  /// Lascia correre sia il tempo vero (immagini, file) sia quello dei
  /// fotogrammi.
  Future<void> attendi({int giri = 14, int ms = 80}) async {
    for (var i = 0; i < giri; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(Duration(milliseconds: ms));
    }
    // finché qualcosa sta ancora caricando (rotella), si aspetta
    for (var i = 0; i < 150; i++) {
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pump(Duration(milliseconds: ms));
    }
    await t.pump(const Duration(milliseconds: 200));
  }

  Future<void> tocca(Finder f, {int giri = 14}) async {
    expect(f, findsWidgets, reason: 'elemento da toccare non trovato');
    await t.tap(f.first, warnIfMissed: false);
    await attendi(giri: giri);
  }

  /// Porta la pagina a [dy] pixel logici dall'inizio (la lista verticale più
  /// lunga fra quelle visibili).
  Future<void> scorri(double dy) async {
    // la lunghezza di una lista pigra si conosce man mano che si scorre: si
    // riprova finché si arriva a [dy] (o in fondo)
    for (var giro = 0; giro < 12; giro++) {
      ScrollPosition? migliore;
      var massimo = 0.0;
      for (final e in find.byType(Scrollable).evaluate()) {
        final pos = ((e as StatefulElement).state as ScrollableState).position;
        if (pos.axis != Axis.vertical || !pos.hasContentDimensions) continue;
        if (pos.maxScrollExtent > massimo) {
          massimo = pos.maxScrollExtent;
          migliore = pos;
        }
      }
      if (migliore == null) break;
      migliore.jumpTo(dy.clamp(0, massimo));
      // le schede in fondo (Whisper, AI) si riempiono man mano che compaiono
      await attendi(giri: 8);
      if (migliore.pixels >= dy - 1) break;
    }
    await attendi(giri: 6);
  }

  /// Porta a termine [op] facendo avanzare sia il tempo finto sia quello vero.
  Future<void> pilota(Future<void> Function() op) async {
    var finito = false;
    unawaited(op().whenComplete(() => finito = true));
    for (var i = 0; i < 1500 && !finito; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  void sezione(String nome) {
    s.openRoute.call('sezione:$nome');
  }

  Future<void> riparti() async {
    appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    await attendi(giri: 6);
  }

  Future<void> vai(String nome) async {
    await riparti();
    sezione(nome);
    await attendi();
  }

  Future<void> apri(Widget schermata) async {
    await riparti();
    // ignore: unawaited_futures
    appNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => schermata),
    );
    await attendi(giri: 20);
  }

  Future<void> imposta(String nuovoTema) async {
    tema = nuovoTema;
    s.themeMode.value = nuovoTema == 'scuro' ? ThemeMode.dark : ThemeMode.light;
    await attendi(giri: 10);
  }

  /// Salva lo schermo com'è.
  Future<void> scatta(String scena, int n) async {
    final nome =
        '${n.toString().padLeft(2, '0')}_${scena}_${formato.nome}_$tema.png';
    if (_solo.isNotEmpty && !nome.contains(_solo)) return;
    await attendi(giri: 4);
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: formato.dpr);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      dir.createSync(recursive: true);
      File(p.join(dir.path, nome)).writeAsBytesSync(
        bytes!.buffer.asUint8List(),
      );
      img.dispose();
    });
    // ignore: avoid_print
    print('screenshot: $nome');
  }
}

typedef Scena = ({String id, int n, Future<void> Function(Ctx c) prepara});

// ---------------------------------------------------------------- scene

Future<void> _oggi(Ctx c) => c.vai('Home');

Future<void> _progressi(Ctx c) async {
  await c.vai('Home');
  await c.scorri(c.formato.logico.width < 700 ? 1000 : 0);
}

Future<void> _esami(Ctx c) async {
  await c.vai('Esami');
  // schermo largo: l'elenco a sinistra e la prova scelta a destra
  if (c.formato.logico.width >= 700) {
    await c.tocca(find.text('Algoritmi e strutture dati'));
  }
}

Future<void> _esamiSostenuti(Ctx c) async {
  await c.vai('Esami');
  await c.tocca(find.text('Sostenuti'));
}

/// Impostazioni all'inizio della sezione Aspetto (tema chiaro, scuro, sistema).
Future<void> _impostazioniAspetto(Ctx c) async {
  await c.vai('Impostazioni');
  if (c.formato.logico.width >= 700) return;
  for (var dy = 600.0; dy < 3000 && find.text('Sistema').evaluate().isEmpty; dy += 300) {
    await c.scorri(dy);
  }
  final e = find.text('Sistema').evaluate();
  if (e.isNotEmpty) {
    await Scrollable.ensureVisible(e.first, alignment: 0.15);
    await c.attendi(giri: 6);
  }
}

Future<void> _medie(Ctx c) async {
  await c.vai('Esami');
  await c.tocca(find.text('Medie'));
}

Future<void> _prova(Ctx c) async {
  if (c.formato.logico.width < 700) {
    final id = await c.t.runAsync(() async {
      final corsi = await c.s.courses.all();
      final corso = corsi.firstWhere((x) => x.name == 'Algoritmi e strutture dati');
      return (await c.s.exams.finalOf(corso.id!))!.id!;
    });
    await c.apri(ExamDetailScreen(examId: id!));
  } else {
    await c.vai('Esami');
    await c.tocca(find.text('Algoritmi e strutture dati'));
  }
}

Future<void> _studioArgomenti(Ctx c) async {
  await c.vai('Studio');
  await c.tocca(find.text('Argomenti'));
}

Future<void> _studioStatistiche(Ctx c) async {
  await c.vai('Studio');
  await c.tocca(find.text('Statistiche'));
  // telefono: dalle card dei totali ai grafici
  if (c.formato.logico.width < 700) await c.scorri(1550);
}

Future<void> _libri(Ctx c) => c.vai('Libri');

Future<void> _collegamenti(Ctx c) => c.vai('Collegamenti');

Future<void> _collegamentiAi(Ctx c) async {
  await c.vai('Collegamenti');
  // dalla trascrizione (Whisper, Parakeet) alle AI di riferimento
  await c.scorri(2700);
}

Future<void> _impostazioni(Ctx c) async {
  await c.vai('Impostazioni');
  // telefono: da «Contrasto» in giù (in cima c'è il percorso)
  if (c.formato.logico.width < 700) await c.scorri(1450);
}


/// Registrazione in corso con il testo dal vivo: audio finto a pezzi di
/// 100 ms (come il microfono vero) e frasi del riconoscitore.
Future<void> _registra(Ctx c) async {
  // ignore: avoid_print
  print('registra: inizio');
  final corso = (await c.t.runAsync(() async {
    final corsi = await c.s.courses.all();
    return corsi.firstWhere((x) => x.name == 'Algoritmi e strutture dati');
  }))!;
  await c.riparti();
  await c.apri(RecorderScreen(initialCourse: corso));
  final rec = c.s.recorder;
  unawaited(() async {
    final ext = await rec.extension(corso);
    final path = await c.s.notes.newRecordingPath(corso, DateTime.now(), ext);
    await rec.start(path,
        course: corso.name, courseId: corso.id, language: 'it');
  }());
  // ignore: avoid_print
  print('registra: avviata');
  for (var i = 0; i < 100 && !rec.active; i++) {
    await c.attendi(giri: 1);
  }
  // ignore: avoid_print
  print('registra: attesa finita, attiva=${rec.active}');
  final r = math.Random(5);
  // audio a pezzi di un secondo (pochi gestori da smaltire) e, alla fine,
  // a pezzi di 100 ms per la forma d'onda dal vivo
  void grosso(int secondi, double ampiezza) {
    final b = ByteData(32000 * secondi);
    for (var i = 0; i < 16000 * secondi; i++) {
      b.setInt16(i * 2, ((r.nextDouble() * 2 - 1) * ampiezza * 32767).round(),
          Endian.little);
    }
    c.fakes.mic.pcm.add(b.buffer.asUint8List());
  }

  Future<void> audio(int pezzi, double base) async {
    for (var i = 0; i < pezzi; i += 1) {
      final onda = 0.5 + 0.5 * math.sin(i / 3.0) * math.cos(i / 11.0);
      c.fakes.mic.feed(r, chunks: 1, amplitude: (base * (0.25 + 0.75 * onda)).clamp(0.02, 0.9));
    }
    await c.t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
  }

  final frasi = [for (final sgm in kLezioneAvl.segmenti.take(5)) sgm.$2];
  for (final fr in frasi) {
    // ignore: avoid_print
    print('registra: frase');
    grosso(42, 0.3);
    await c.t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await c.t.runAsync(() => c.channels.speechEvent('result', fr));
    await c.attendi(giri: 2);
  }
  grosso(15, 0.3);
  await c.t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await c.t.runAsync(
    () => c.channels.speechEvent(
      'partial',
      'Il caso sinistra-sinistra si risolve con una rotazione a destra sul nodo',
    ),
  );
  // l'ultimo tratto, pezzo per pezzo, per la forma d'onda sotto il tempo
  for (var i = 0; i < 90; i++) {
    await audio(1, 0.15 + 0.5 * ((i * 7) % 13) / 13);
  }
  c.fakes.mic.feed(r, chunks: 1, amplitude: 0.3);
  await c.attendi(giri: 6);
  await c.scatta('registra', 6);
  // la scheda del testo dal vivo, sotto i comandi
  await c.scorri(c.formato.logico.height < 1200 ? 760 : 0);
  await c.scatta('registra_testo', 7);
  await _registraFine(c);
  c.giaScattato = true;
}

Future<void> _registraFine(Ctx c) async {
  final rec = c.s.recorder;
  // ignore: avoid_print
  print('registra: chiusura, attiva=${rec.active} saving=${rec.saving}');
  if (rec.active) {
    await c.pilota(() async {
      final take = await rec.stop();
      // ignore: avoid_print
      print('registra: fermata');
      if (take != null) {
        unawaited(take.live?.close());
        await take.session.delete();
      }
    });
    await c.attendi(giri: 6);
    // ignore: avoid_print
    print('registra: chiusa, attiva=${rec.active} saving=${rec.saving}');
  }
}

/// File [cartella] del corso [corso] il cui nome contiene [parte].
Future<(Course, NoteFile)> _file(
  Ctx c,
  String corso,
  NoteFolder cartella, {
  String parte = '',
  int numero = 0,
}) async {
  final r = await c.t.runAsync(() async {
    final corsi = await c.s.courses.all();
    final co = corsi.firstWhere((x) => x.name == corso);
    final elenco = (await c.s.notes.list(co))[cartella] ?? const <NoteFile>[];
    final scelti = [
      for (final f in elenco)
        if (f.name.contains(parte)) f,
    ]..sort((a, b) => b.name.compareTo(a.name));
    return (co, scelti[numero]);
  });
  return r!;
}

/// Nasconde il messaggio «Riproduzione non disponibile» del lettore (nei
/// test non c'è il motore audio): il testo si svuota nell'albero di
/// disposizione.
void _nascondiAvviso(Ctx c) {
  void visita(RenderObject o) {
    if (o is RenderParagraph &&
        o.text.toPlainText().contains('non disponibile in questo ambiente')) {
      o.text = const TextSpan(text: '');
    }
    o.visitChildren(visita);
  }

  visita(RendererBinding.instance.renderViews.first);
}

Future<void> _lezione(Ctx c) async {
  final (corso, file) = await _file(
    c,
    'Algoritmi e strutture dati',
    NoteFolder.recordings,
    parte: kLezioneAvl.quando.day.toString().padLeft(2, '0'),
  );
  await c.apri(RecordingPlayerScreen(course: corso, file: file.file));
  for (var i = 0; i < 60; i++) {
    await c.t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await c.t.pump(const Duration(milliseconds: 500));
  }
  _nascondiAvviso(c);
  await c.attendi(giri: 2);
}

Future<void> _appunti(Ctx c) async {
  final (corso, file) = await _file(
    c,
    'Algoritmi e strutture dati',
    NoteFolder.notes,
    parte: 'AVL',
  );
  await c.apri(
    NoteViewerScreen(
      course: corso,
      note: file,
      // telefono: la barra del titolo non ha posto per titolo e ricerca
      query: c.formato.logico.width < 700 ? null : 'rotazion',
    ),
  );
}

Future<void> _corso(Ctx c) async {
  final (corso, _) = await _file(
    c,
    'Algoritmi e strutture dati',
    NoteFolder.notes,
    parte: 'AVL',
  );
  await c.apri(CourseNotesScreen(course: corso));
}

/// Primo avvio: aspetto, ricerca dell'ateneo e scelta del corso (catalogo
/// vero dell'app, nessun profilo).
Future<void> _onboarding(Ctx c) async {
  await c.attendi(giri: 20);
  await c.scatta('onboarding_aspetto', 20);
  await c.tocca(find.text('Continua'));
  await c.t.enterText(find.byKey(const Key('onboarding-search')), 'Milano');
  await c.attendi(giri: 10);
  await c.scatta('onboarding_ateneo', 21);
  await c.t.enterText(find.byKey(const Key('onboarding-search')), 'Torino');
  await c.attendi(giri: 8);
  await c.tocca(find.text('Politecnico di Torino'));
  await c.attendi(giri: 10);
  await c.tocca(find.text('Laurea (triennale)'));
  await c.attendi(giri: 14);
  await c.t.enterText(find.byType(TextField).first, 'Informatica');
  await c.attendi(giri: 10);
  await c.scatta('onboarding_corso', 22);
}

/// Sessione Focus a 23 minuti da una sessione di 60.
Future<void> _focus(Ctx c) async {
  final corso = (await c.t.runAsync(() async {
    final corsi = await c.s.courses.all();
    return corsi.firstWhere((x) => x.name == 'Algoritmi e strutture dati');
  }))!;
  await c.riparti();
  unawaited(
    c.s.focus.start(
      const FocusSettings(minutes: 60, breakEvery: 25, breakMinutes: 5),
      FocusLink(
        courseId: corso.id,
        label: 'Algoritmi e strutture dati · Alberi AVL',
        activity: ActivityType.theory,
      ),
    ),
  );
  await c.attendi(giri: 10);
  c.fakes.clockOffset = const Duration(minutes: 23, seconds: 12);
  unawaited(openFocusScreen(appNavigatorKey.currentContext!));
  await c.attendi(giri: 10);
  await c.t.pump(const Duration(seconds: 2));
  await c.scatta('focus', 12);
  c.giaScattato = true;
  await c.pilota(() => c.s.focus.discard());
  c.fakes.clockOffset = Duration.zero;
  await c.riparti();
}

List<Scena> _scene(Formato f) {
  final tutte = <Scena>[
    (id: 'oggi', n: 1, prepara: _oggi),
    (id: 'progressi', n: 2, prepara: _progressi),
    (id: 'esami', n: 3, prepara: _esami),
    (id: 'medie', n: 4, prepara: _medie),
    (id: 'esami_sostenuti', n: 18, prepara: _esamiSostenuti),
    (id: 'impostazioni_aspetto', n: 19, prepara: _impostazioniAspetto),
    (id: 'prova', n: 5, prepara: _prova),
    (id: 'lezione', n: 8, prepara: _lezione),
    (id: 'appunti', n: 9, prepara: _appunti),
    (id: 'studio_argomenti', n: 10, prepara: _studioArgomenti),
    (id: 'studio_statistiche', n: 11, prepara: _studioStatistiche),
    (id: 'focus', n: 12, prepara: _focus),
    (id: 'libri', n: 13, prepara: _libri),
    (id: 'collegamenti', n: 14, prepara: _collegamenti),
    (id: 'collegamenti_ai', n: 15, prepara: _collegamentiAi),
    (id: 'impostazioni', n: 16, prepara: _impostazioni),
    (id: 'corso', n: 17, prepara: _corso),
    // 'registra' (6 e 7) per ultima: la registrazione in corso si scarta
    (id: 'registra', n: 6, prepara: _registra),
  ];
  const perFormato = <String, Set<String>>{
    'tablet': {'oggi', 'esami', 'studio_argomenti', 'libri'},
    'desktop': {
      'oggi',
      'esami',
      'lezione',
      'appunti',
      'studio_statistiche',
    },
  };
  final scelte = perFormato[f.nome];
  return [
    for (final sc in tutte)
      if (scelte == null || scelte.contains(sc.id)) sc,
  ];
}

// ------------------------------------------------------------------ test

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = _attivo ? null : 'serve UNINOTES_SCREENSHOT=1';

  setUpAll(() async {
    if (!_attivo) return;
    await _caricaFont();
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  for (final formato in [_telefono, _tablet, _desktop, _esplora]) {
    if (formato == _esplora && _formato != 'esplora') continue;
    if (_formato.isNotEmpty && !formato.nome.contains(_formato)) continue;
    testWidgets(
      'screenshot ${formato.nome}',
      (t) async {
        t.view.physicalSize = Size(
          formato.logico.width * formato.dpr,
          formato.logico.height * formato.dpr,
        );
        t.view.devicePixelRatio = formato.dpr;
        addTearDown(t.view.reset);
        final tmp = await t.runAsync(
          () => Directory.systemTemp.createTemp('portfolio_'),
        );
        final fakes = MonkeyFakes();
        final db = await t.runAsync(AppDatabase.openInMemory);
        final s = (await t.runAsync(
          () => monkeyServices(
            db!,
            tmp!,
            fakes: fakes,
            options: MonkeyOptions(
              platform: formato.piattaforma,
              liveSpeech: true,
            ),
          ),
        ))!;
        await t.runAsync(() => riempiPortfolio(s));
        final channels = MonkeyChannels(tmp!)..speech = true;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.allMessagesHandler = channels.handle;
        addTearDown(() => messenger.allMessagesHandler = null);
        StudyScreen.initialTab = 0;

        final key = GlobalKey();
        await t.pumpWidget(
          RepaintBoundary(key: key, child: UniversityNotesApp(services: s)),
        );
        final c = Ctx(t, s, key, formato, _uscita, channels, fakes);
        await c.attendi(giri: 20);

        for (final tema in const ['chiaro', 'scuro']) {
          await c.imposta(tema);
          for (final sc in _scene(formato)) {
            final nome = '${sc.n}_${sc.id}_${formato.nome}_$tema';
            if (_solo.isNotEmpty && !nome.contains(_solo)) continue;
            c.giaScattato = false;
            await sc.prepara(c);
            if (!c.giaScattato) await c.scatta(sc.id, sc.n);
            c.s.selectYear(2);
          }
        }

        // chiusura: nessun timer o servizio vivo
        await _registraFine(c);
        StudyTimer.instance.reset();
        for (final cl in s.clouds) {
          cl.stopAutoSync();
        }
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 1));
        await t.runAsync(s.database.close);
        await t.runAsync(() async {
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        });
      },
      skip: skip != null,
      timeout: const Timeout(Duration(minutes: 20)),
    );
    if (formato == _esplora) continue;
    testWidgets(
      'onboarding ${formato.nome}',
      (t) async {
        t.view.physicalSize = Size(
          formato.logico.width * formato.dpr,
          formato.logico.height * formato.dpr,
        );
        t.view.devicePixelRatio = formato.dpr;
        addTearDown(t.view.reset);
        final tmp = await t.runAsync(
          () => Directory.systemTemp.createTemp('portfolio_onb_'),
        );
        final db = await t.runAsync(AppDatabase.openInMemory);
        final settings = SettingsRepository(db!);
        final assets = <String, String>{
          'assets/database/universita.json': File(
            'assets/database/universita.json',
          ).readAsStringSync(),
          'assets/database/indice_corsi.json': File(
            'assets/database/indice_corsi.json',
          ).readAsStringSync(),
        };
        final s = AppServices(
          db,
          catalog: fakeCatalog(settings, assets: assets, cacheDir: tmp),
        );
        final channels = MonkeyChannels(tmp!);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.allMessagesHandler = channels.handle;
        addTearDown(() => messenger.allMessagesHandler = null);
        final fakes = MonkeyFakes();
        for (final tema in const ['chiaro', 'scuro']) {
          s.themeMode.value = tema == 'scuro' ? ThemeMode.dark : ThemeMode.light;
          final key = GlobalKey();
          await t.pumpWidget(
            RepaintBoundary(key: key, child: UniversityNotesApp(services: s)),
          );
          final c = Ctx(t, s, key, formato, _uscita, channels, fakes)
            ..tema = tema;
          await _onboarding(c);
          await t.pumpWidget(const SizedBox());
        }
        await t.pump(const Duration(seconds: 1));
        await t.runAsync(s.database.close);
        await t.runAsync(() async {
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        });
      },
      skip: skip != null,
      timeout: const Timeout(Duration(minutes: 20)),
    );
  }
}
