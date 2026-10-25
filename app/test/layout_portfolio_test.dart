// Difetti di impaginazione emersi dagli screenshot del portfolio (telefono
// 360×800 dp): testi spezzati o con i puntini e numeri che toccano il bordo.
// Si provano con i caratteri veri (IBM Plex), a 360 e 320 dp, con caratteri
// ×1, ×1,3 e ×2 e con tema chiaro e scuro; nessuna eccezione di layout.
//
//  1. titolo degli appunti («Al…» invece di «Alberi AVL»)
//  2. selettore Aspetto («Sistema» a capo)
//  3. barra in basso («Impostazi…», «Collegam…»)
//  4. Esami, Sostenuti («Non superati», «Annullati» a capo)
//  5. Home, anello dell'obiettivo («100%» tocca il bordo)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' show Intl;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/exams/exams_screen.dart';
import 'package:university_notes/features/study/study_screen.dart';
import 'package:university_notes/features/exams/taken_exams_tab.dart';
import 'package:university_notes/features/notes/note_viewer_screen.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/settings/sections/appearance_section.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/widgets/glass.dart';

const _scales = [1.0, 1.3, 2.0];
const _widths = [360.0, 320.0];

Future<void> _caricaFont() async {
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
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ?? r'D:\tools\flutter';
  final icone = p.join(
    flutterRoot,
    'bin',
    'cache',
    'artifacts',
    'material_fonts',
    'materialicons-regular.otf',
  );
  // nella build automatica (flutter-action) il font delle icone non è nella
  // cache: le icone hanno comunque una misura fissa e le misure non cambiano
  if (File(icone).existsSync()) await famiglia('MaterialIcons', [icone]);
}

Future<void> _vista(
  WidgetTester t,
  double w,
  double scale, {
  double h = 800,
}) async {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _pump(
  WidgetTester t,
  Widget home, {
  required bool scuro,
  AppServices? services,
}) async {
  Widget app = MaterialApp(
    theme: scuro ? AppTheme.dark() : AppTheme.light(),
    locale: const Locale('it', 'IT'),
    supportedLocales: const [Locale('it', 'IT')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
  if (services != null) {
    app = Provider<AppServices>.value(value: services, child: app);
  }
  await t.pumpWidget(app);
  for (var i = 0; i < 6; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

void _noErrors(WidgetTester t, String why) {
  final e = t.takeException();
  if (e is FlutterError) debugPrint('ERRORE ($why): ${e.toStringDeep()}');
  expect(e, isNull, reason: why);
}

/// Il testo [f] si legge intero: una riga sola, senza puntini, con una scala
/// visiva (FittedBox) non inferiore a [minScale].
void _intero(WidgetTester t, Finder f, String why, {double minScale = 1.0}) {
  expect(f, findsOneWidget, reason: '$why: testo non trovato');
  final ro = t.renderObject(f);
  expect(ro, isA<RenderParagraph>(), reason: why);
  final par = ro as RenderParagraph;
  final tp = TextPainter(
    text: par.text,
    textDirection: TextDirection.ltr,
    textScaler: par.textScaler,
    maxLines: 1,
  )..layout();
  expect(
    par.size.width + 0.5,
    greaterThanOrEqualTo(tp.width),
    reason: '$why: testo tagliato (puntini): ${par.text.toPlainText()}',
  );
  expect(
    par.size.height,
    lessThanOrEqualTo(tp.height + 1),
    reason: '$why: testo a capo: ${par.text.toPlainText()}',
  );
  tp.dispose();
  final w = t.getBottomRight(f).dx - t.getTopLeft(f).dx;
  final scale = w / par.size.width;
  expect(
    scale,
    greaterThanOrEqualTo(minScale - 0.005),
    reason: '$why: testo rimpicciolito a $scale: ${par.text.toPlainText()}',
  );
}

void main() {
  setUpAll(() async {
    await _caricaFont();
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  // ----------------------------------------------------------------- 1
  group('titolo degli appunti', () {
    for (final w in _widths) {
      for (final scale in _scales) {
        for (final scuro in [false, true]) {
          testWidgets(
            'larghezza $w, caratteri ×$scale, ${scuro ? 'scuro' : 'chiaro'}',
            (t) async {
              await _vista(t, w, scale);
              final tmp = await t.runAsync(
                () => Directory.systemTemp.createTemp('layout_note_'),
              );
              addTearDown(() => tmp!.deleteSync(recursive: true));
              final file = File(p.join(tmp!.path, 'Alberi AVL.md'));
              file.writeAsStringSync('# Alberi AVL\n\nTesto di prova.\n');
              final note = NoteFile(
                file,
                NoteFolder.notes,
                DateTime(2026, 10, 25),
                10,
              );
              await _pump(
                t,
                NoteViewerScreen(
                  course: const Course(name: 'Algoritmi', universityId: 'x'),
                  note: note,
                ),
                scuro: scuro,
                // il lettore non usa i servizi finché non si tocca un'azione
                services: null,
              );
              final titolo = find.descendant(
                of: find.byType(AppBar),
                matching: find.text('Alberi AVL'),
              );
              // con ×1 e ×1,3 il titolo resta sempre intero a vista; con ×2
              // idem (le azioni passano nel menu «⋯» finché serve)
              _intero(t, titolo, 'titolo $w ×$scale');
              _noErrors(t, 'appunti $w ×$scale');
            },
          );
        }
      }
    }

    for (final w in [768.0, 1920.0]) {
      testWidgets('tablet e desktop ($w): tutte le azioni a vista', (t) async {
        await _vista(t, w, 1, h: 1000);
        final tmp = await t.runAsync(
          () => Directory.systemTemp.createTemp('layout_note_'),
        );
        addTearDown(() => tmp!.deleteSync(recursive: true));
        final file = File(p.join(tmp!.path, 'Alberi AVL.md'))
          ..writeAsStringSync('Testo.');
        await _pump(
          t,
          NoteViewerScreen(
            course: const Course(name: 'Algoritmi', universityId: 'x'),
            note: NoteFile(file, NoteFolder.notes, DateTime(2026, 10, 25), 6),
          ),
          scuro: false,
        );
        expect(find.byKey(const Key('note-more')), findsNothing);
        expect(find.byTooltip('Esporta PDF'), findsOneWidget);
        expect(find.byTooltip('Condividi'), findsOneWidget);
        _intero(
          t,
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Alberi AVL'),
          ),
          'titolo $w',
        );
        _noErrors(t, 'appunti $w');
      });
    }

    testWidgets('le azioni tolte dalla barra stanno nel menu «⋯»', (t) async {
      await _vista(t, 360, 1.3);
      final tmp = await t.runAsync(
        () => Directory.systemTemp.createTemp('layout_note_'),
      );
      addTearDown(() => tmp!.deleteSync(recursive: true));
      final file = File(p.join(tmp!.path, 'Alberi AVL.md'))
        ..writeAsStringSync('Testo.\n');
      await _pump(
        t,
        NoteViewerScreen(
          course: const Course(name: 'Algoritmi', universityId: 'x'),
          note: NoteFile(file, NoteFolder.notes, DateTime(2026, 10, 25), 6),
        ),
        scuro: false,
      );
      expect(find.byKey(const Key('note-more')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-more')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Esporta PDF'), findsOneWidget);
      expect(find.text('Condividi'), findsOneWidget);
      // cerca e modifica restano a vista
      expect(find.byTooltip('Modifica'), findsOneWidget);
      _noErrors(t, 'menu appunti');
    });
  });

  // ----------------------------------------------------------------- 2
  group('selettore Aspetto', () {
    for (final w in _widths) {
      for (final scale in _scales) {
        for (final scuro in [false, true]) {
          testWidgets(
            'larghezza $w, caratteri ×$scale, ${scuro ? 'scuro' : 'chiaro'}',
            (t) async {
              await _vista(t, w, scale, h: 1400);
              final s = (await t.runAsync(
                () async => AppServices(await AppDatabase.openInMemory()),
              ))!;
              addTearDown(() => t.runAsync(s.database.close));
              await _pump(
                t,
                Scaffold(body: ListView(children: const [AppearanceSection()])),
                scuro: scuro,
                services: s,
              );
              // con ×1 le parole restano al 94% o più (le icone cadono prima); con
              // ×2 si rimpiccioliscono al più a tre quarti, mai a capo
              final minimo = scale >= 2 ? 0.6 : (scale > 1 ? 0.85 : 0.94);
              for (final testo in [
                'Scuro',
                'Chiaro',
                'Sistema',
                'Standard',
                'Alto contrasto',
              ]) {
                _intero(
                  t,
                  find.text(testo),
                  '$testo $w ×$scale',
                  minScale: minimo,
                );
              }
              _noErrors(t, 'aspetto $w ×$scale');
            },
          );
        }
      }
    }
  });

  // ----------------------------------------------------------------- 3
  group('barra di navigazione in basso', () {
    final ultime = [for (final d in kDestinations.skip(4)) d.label, 'Altro'];
    for (final w in _widths) {
      for (final scale in _scales) {
        for (final scuro in [false, true]) {
          testWidgets(
            'larghezza $w, caratteri ×$scale, ${scuro ? 'scuro' : 'chiaro'}',
            (t) async {
              await _vista(t, w, scale);
              for (final ultima in ultime) {
                await _pump(
                  t,
                  Scaffold(
                    body: const SizedBox(),
                    bottomNavigationBar: GlassNavBar(
                      selectedIndex: 4,
                      onSelected: (_) {},
                      items: [
                        for (final d in kDestinations.take(4))
                          (
                            icon: d.icon,
                            selectedIcon: d.selectedIcon,
                            label: d.label,
                          ),
                        (
                          icon: Icons.more_horiz,
                          selectedIcon: Icons.more_horiz,
                          label: ultima,
                        ),
                      ],
                    ),
                  ),
                  scuro: scuro,
                );
                // a 360 con caratteri ×1 tutte le etichette sono intere e
                // alla grandezza vera; oltre, al più un piccolo ritocco
                final minimo = scale >= 2 || w < 360
                    ? 0.7
                    : (scale > 1 ? 0.9 : 1.0);
                final finder = [
                  for (final d in kDestinations.take(4)) d.label,
                  ultima,
                ];
                for (final testo in finder) {
                  _intero(
                    t,
                    find.text(testo),
                    '$testo (ultima: $ultima) $w ×$scale',
                    minScale: minimo,
                  );
                }
                // le etichette non si sovrappongono
                final rects = [
                  for (final testo in finder)
                    t.getTopLeft(find.text(testo)) &
                        Size(
                          t.getBottomRight(find.text(testo)).dx -
                              t.getTopLeft(find.text(testo)).dx,
                          10,
                        ),
                ];
                for (var i = 1; i < rects.length; i++) {
                  expect(
                    rects[i - 1].right,
                    lessThanOrEqualTo(rects[i].left + 0.5),
                    reason: 'etichette sovrapposte ($ultima, $w ×$scale)',
                  );
                }
                _noErrors(t, 'barra $ultima $w ×$scale');
              }
            },
          );
        }
      }
    }
  });

  // ----------------------------------------------------------------- 4
  group('Esami, Sostenuti: contatori', () {
    const dati = ExamsData(
      exams: [],
      courses: {},
      universities: {},
      degrees: [],
    );
    for (final w in _widths) {
      for (final scale in _scales) {
        for (final scuro in [false, true]) {
          testWidgets(
            'larghezza $w, caratteri ×$scale, ${scuro ? 'scuro' : 'chiaro'}',
            (t) async {
              await _vista(t, w, scale);
              await _pump(
                t,
                Scaffold(
                  body: TakenExamsTab(
                    data: dati,
                    selectedId: null,
                    onSelect: (_) {},
                  ),
                ),
                scuro: scuro,
              );
              final minimo = scale >= 2 ? 0.7 : 1.0;
              for (final testo in [
                'Superati',
                'Non superati',
                'In attesa',
                'Annullati',
              ]) {
                _intero(
                  t,
                  find.text(testo),
                  '$testo $w ×$scale',
                  minScale: minimo,
                );
              }
              _noErrors(t, 'sostenuti $w ×$scale');
            },
          );
        }
      }
    }
  });

  // ----------------------------------------------------------------- 5
  group('anello dell\'obiettivo', () {
    // la Home dà all'anello 56 dp (fino a 96 con i caratteri grandi) e
    // limita il testo dentro a ×1,3
    for (final w in _widths) {
      for (final scale in _scales) {
        for (final scuro in [false, true]) {
          for (final label in ['0%', '37%', '100%', '150%', '1000%']) {
            testWidgets('«$label» larghezza $w, caratteri ×$scale, '
                '${scuro ? 'scuro' : 'chiaro'}', (t) async {
              await _vista(t, w, scale);
              final chiave = GlobalKey();
              await _pump(
                t,
                Scaffold(
                  body: Builder(
                    builder: (context) => Center(
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.3,
                        child: ProgressRing(
                          key: chiave,
                          size: MediaQuery.textScalerOf(context)
                              .scale(56)
                              .clamp(56.0, 96.0),
                          value: 1,
                          label: label,
                        ),
                      ),
                    ),
                  ),
                ),
                scuro: scuro,
              );
              final anello = t.getRect(find.byKey(chiave));
              final testo = find.descendant(
                of: find.byKey(chiave),
                matching: find.text(label),
              );
              final r =
                  t.getTopLeft(testo) &
                  Size(
                    t.getBottomRight(testo).dx - t.getTopLeft(testo).dx,
                    t.getBottomRight(testo).dy - t.getTopLeft(testo).dy,
                  );
              // bordo interno della traccia: raggio (44 - 4,5)/104 della
              // misura; gli angoli del riquadro del testo devono stare
              // dentro con un po' di margine
              final interno = (44 - 4.5) / 104 * anello.width;
              final centro = anello.center;
              for (final angolo in [
                r.topLeft,
                r.topRight,
                r.bottomLeft,
                r.bottomRight,
              ]) {
                expect(
                  (angolo - centro).distance,
                  lessThanOrEqualTo(interno - 1),
                  reason:
                      '«$label» tocca l\'anello (misura ${anello.width}, '
                      'testo $r)',
                );
              }
              // e resta leggibile (non meno della metà della grandezza)
              final par = t.renderObject<RenderParagraph>(testo);
              expect(
                r.width / par.size.width,
                greaterThanOrEqualTo(label.length > 4 ? 0.5 : 0.65),
                reason: '«$label» troppo piccolo',
              );
              _noErrors(t, 'anello $label $w ×$scale');
            });
          }
        }
      }
    }
  });

  // ------------------------------------------------- schede (Studio, Esami)
  group('schede in alto', () {
    for (final w in _widths) {
      for (final scale in _scales) {
        testWidgets('larghezza $w, caratteri ×$scale', (t) async {
          await _vista(t, w, scale);
          final s = (await t.runAsync(
            () async => AppServices(await AppDatabase.openInMemory()),
          ))!;
          addTearDown(() => t.runAsync(s.database.close));
          for (final entry in {
            'Studio': (
              const StudyScreen(),
              ['Argomenti', 'Sessioni Studio', 'Statistiche'],
            ),
            'Esami': (
              const ExamsScreen(),
              ['Da sostenere', 'Sostenuti', 'Medie'],
            ),
          }.entries) {
            await _pump(t, entry.value.$1, scuro: false, services: s);
            for (final testo in entry.value.$2) {
              _intero(
                t,
                find.descendant(
                  of: find.byType(TabBar),
                  matching: find.text(testo),
                ),
                '$testo (${entry.key}) $w ×$scale',
              );
            }
            _noErrors(t, 'schede ${entry.key} $w ×$scale');
          }
        });
      }
    }
  });
}
