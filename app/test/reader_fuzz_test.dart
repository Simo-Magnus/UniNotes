// Fuzz dei parser del lettore: file vuoti, troncati, con byte casuali,
// lunghezze enormi, archivi con voci rovinate, XML annidato all'eccesso.
// Ogni caso gira in un isolate a parte con un tempo massimo: il lettore non
// deve mai restare appeso, finire la memoria o far cadere l'app; un file
// rovinato diventa un messaggio (InfoContent) con «Apri con…».
//
// Giri più lunghi: READER_FUZZ_ROUNDS=20 flutter test test/reader_fuzz_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/features/reader/djvu/djvu_document.dart';
import 'package:university_notes/features/reader/reader_loader.dart';

import 'support/reader_fuzz_corpus.dart';

/// Esito di un caso eseguito in un isolate: descrizione breve.
Future<String> _probe((String, Uint8List, String) job) async {
  final (ext, bytes, tmp) = job;
  readerTempDir = () async => Directory(p.join(tmp, 'temp'));
  final file = File(p.join(tmp, 'file$ext'));
  await file.writeAsBytes(bytes);
  final (_, content) = await loadReaderContent(file.path);
  switch (content) {
    case DjvuContent(:final doc):
      for (var i = 0; i < min(3, doc.pages.length); i++) {
        try {
          renderDjvuPage(doc.pageData(i), reduction: 8);
        } on FormatException {
          // pagina rovinata: la vista la segna come non disegnabile
        } on RangeError {
          // idem
        } on ArgumentError {
          // idem
        } on StateError {
          // idem
        }
      }
    case ArchiveContent(:final entries):
      for (final e in entries.take(6)) {
        try {
          await extractArchiveEntry(file.path, e.name);
        } on Exception {
          // voce illeggibile: messaggio nella vista
        } on Error catch (err) {
          if (err is StackOverflowError) rethrow;
        }
      }
    case InfoContent(:final message):
      // memoria finita, ricorsione troppo profonda o analisi fermata dal
      // tempo massimo: casi da correggere nel parser
      if (message.contains('troppo complesso') ||
          message.contains('troppo tempo') ||
          message.contains('StackOverflow') ||
          message.contains('Out of Memory') ||
          message.contains('OutOfMemory')) {
        return 'ERRORE GRAVE: $message';
      }
    default:
  }
  return content.runtimeType.toString();
}

/// [job] in un isolate con tempo massimo [limit]: (esito, millisecondi).
Future<(String, int)> _isolated(
  (String, Uint8List, String) job,
  Duration limit,
) async {
  final result = RawReceivePort();
  final done = Completer<String>();
  result.handler = (Object? m) {
    if (!done.isCompleted) done.complete(m is String ? m : 'morto: $m');
  };
  final sw = Stopwatch()..start();
  final iso = await Isolate.spawn<(SendPort, (String, Uint8List, String))>(
    (msg) async {
      final (port, j) = msg;
      try {
        port.send(await _probe(j));
      } catch (e, s) {
        port.send('ECCEZIONE NON GESTITA: $e\n$s');
      }
    },
    (result.sendPort, job),
    onExit: result.sendPort,
    onError: result.sendPort,
  );
  final out = await done.future.timeout(
    limit,
    onTimeout: () => 'APPESO oltre ${limit.inSeconds} s',
  );
  sw.stop();
  iso.kill(priority: Isolate.immediate);
  result.close();
  return (out, sw.elapsedMilliseconds);
}

void main() {
  final rounds =
      int.tryParse(Platform.environment['READER_FUZZ_ROUNDS'] ?? '') ?? 1;
  final seed = int.tryParse(Platform.environment['READER_FUZZ_SEED'] ?? '');
  final only = Platform.environment['READER_FUZZ_ONLY'];
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('reader_fuzz'));
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  final corpus = fuzzCorpus();
  for (final entry in corpus.entries) {
    final ext = entry.key;
    if (only != null && !only.split(',').contains(ext)) continue;
    test('fuzz $ext', () async {
      final problems = <String>[];
      var n = 0;
      for (var s = 0; s < entry.value.length; s++) {
        final rnd = Random((seed ?? 7) * 1000 + ext.hashCode + s);
        for (final (what, bytes) in fuzzMutations(entry.value[s], rnd, rounds)) {
          final dir = Directory(p.join(tmp.path, '${ext.substring(1)}_${n++}'))
            ..createSync(recursive: true);
          final (out, ms) = await _isolated(
            (ext, bytes, dir.path),
            const Duration(seconds: 20),
          );
          final bad =
              out.startsWith('APPESO') ||
              out.startsWith('ERRORE') ||
              out.startsWith('ECCEZIONE') ||
              out.startsWith('morto') ||
              ms > 8000;
          if (bad) {
            final f = File(p.join(tmp.path, 'caso_${ext.substring(1)}_$n.bin'))
              ..writeAsBytesSync(bytes);
            problems.add('$ext campione $s, $what (${ms}ms): $out [${f.path}]');
            // copia fuori dalla cartella temporanea per riprodurlo
            try {
              final keep = Platform.environment['READER_FUZZ_KEEP'];
              if (keep != null) {
                f.copySync(p.join(keep, p.basename(f.path)));
              }
            } catch (_) {}
          }
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 30)));
  }
}
