// Fuzz delle viste del lettore: i documenti ottenuti da file rovinati (vedi
// support/reader_fuzz_corpus.dart) si mostrano, si cercano, si sfogliano e
// si ingrandiscono senza errori di impaginazione (schermata grigia o rossa).
//
// Giri più lunghi: READER_FUZZ_ROUNDS=4 READER_VIEW_FUZZ_MAX=400
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/reader/reader_controller.dart';
import 'package:university_notes/features/reader/reader_loader.dart';
import 'package:university_notes/features/reader/views/djvu_view.dart';
import 'package:university_notes/features/reader/views/document_view.dart';
import 'package:university_notes/features/reader/views/ink_view.dart';
import 'package:university_notes/features/reader/views/outline_view.dart';

import 'support/reader_fuzz_corpus.dart';

Widget? _viewFor(ReaderContent c, ReaderPaneController pane) => switch (c) {
  DocContent(:final doc) => DocumentView(
    doc: doc,
    controller: pane,
    initialPosition: 3,
    onLink: (_) {},
  ),
  InkContent(:final doc) => InkView(doc: doc, controller: pane, initialPage: 2),
  OutlineContent(:final doc) => OutlineView(
    doc: doc,
    controller: pane,
    initialPosition: 2,
  ),
  DjvuContent(:final doc, :final texts) => DjvuView(
    doc: doc,
    texts: texts,
    controller: pane,
    initialPage: 2,
  ),
  _ => null,
};

void main() {
  final rounds =
      int.tryParse(Platform.environment['READER_FUZZ_ROUNDS'] ?? '') ?? 1;
  final maxPerExt =
      int.tryParse(Platform.environment['READER_VIEW_FUZZ_MAX'] ?? '') ?? 6;
  final only = Platform.environment['READER_FUZZ_ONLY'];
  final verbose = Platform.environment['READER_FUZZ_VERBOSE'] != null;
  final corpus = fuzzCorpus();

  for (final entry in corpus.entries) {
    final ext = entry.key;
    if (only != null && !only.split(',').contains(ext)) continue;
    testWidgets('viste con file rovinati: $ext', (t) async {
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('reader_view_fuzz'),
      ))!;
      readerTempDir = () async => Directory(p.join(tmp.path, 'temp'));
      t.view.physicalSize = const Size(390, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final problems = <String>[];
      final previous = FlutterError.onError;
      var current = '';
      FlutterError.onError = (d) {
        final text = d.exceptionAsString().split('\n').first;
        // immagini finte o troncate: l'errore di decodifica è gestito
        // dall'errorBuilder della vista
        if (d.library == 'image resource service') return;
        problems.add('$current: $text');
      };
      try {
        var shown = 0;
        var n = 0;
        for (var s = 0; s < entry.value.length && shown < maxPerExt; s++) {
          final rnd = Random(11 * 1000 + ext.hashCode + s);
          for (final (what, bytes) in fuzzMutations(entry.value[s], rnd, rounds)) {
            if (shown >= maxPerExt) break;
            final path = p.join(tmp.path, 'f${n++}$ext');
            // ignore: avoid_print
            if (verbose) print('${DateTime.now().toIso8601String()} analisi $ext $s $what');
            final loaded = await t.runAsync(() async {
              await File(path).writeAsBytes(bytes);
              return loadReaderContent(path);
            });
            if (loaded == null) continue;
            final pane = ReaderPaneController();
            final view = _viewFor(loaded.$2, pane);
            if (view == null) continue;
            shown++;
            current = '$ext campione $s, $what';
            // ignore: avoid_print
            if (verbose) print('${DateTime.now().toIso8601String()} $current');
            await t.pumpWidget(
              MaterialApp(
                theme: AppTheme.dark(),
                home: Scaffold(body: view),
              ),
            );
            await t.pump(const Duration(milliseconds: 50));
            // le azioni della cornice: ricerca, risultati, pagine, zoom
            pane.find('a');
            await t.pump();
            pane.step(1);
            pane.step(-1);
            await t.pump();
            if (pane.canGoTo) pane.goToUnit(pane.unitCount);
            pane.goToPosition(1);
            pane.zoom(1);
            await t.pump();
            pane.zoom(-1);
            pane.zoom(0);
            pane.toggleFit();
            await t.pump(const Duration(milliseconds: 50));
            pane.plainText?.call();
            pane.describe?.call(pane.position);
            final e = t.takeException();
            if (e != null) problems.add('$current: $e');
            await t.pumpWidget(const SizedBox());
            pane.dispose();
          }
        }
      } finally {
        FlutterError.onError = previous;
        await t.runAsync(() async {
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        });
      }
      expect(problems, isEmpty, reason: problems.take(30).join('\n'));
    }, timeout: const Timeout(Duration(minutes: 20)));
  }
}
