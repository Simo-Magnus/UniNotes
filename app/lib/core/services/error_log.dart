import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;

/// Registro locale degli errori dell'app (`errori.log` nella cartella di
/// supporto dell'app): eccezioni non gestite, errori dei widget, avvio non
/// riuscito. Resta sul dispositivo: nessun invio all'esterno. Serve allo
/// studente (o a chi lo aiuta) per capire cosa è successo.
///
/// Non lancia mai: un registro che non si può scrivere (disco pieno,
/// cartella non disponibile) non deve diventare un secondo errore.
abstract final class ErrorLog {
  static const fileName = 'errori.log';

  /// Oltre questa dimensione il registro passa a `errori.log.1` (si tiene
  /// solo la copia precedente).
  static const maxBytes = 512 * 1024;

  /// Voci al massimo per avvio (un errore ripetuto a ogni fotogramma non
  /// riempie il disco).
  static const maxEntriesPerRun = 300;

  /// Lo stesso errore entro questo intervallo si scrive una volta sola.
  static const repeatWindow = Duration(seconds: 10);

  /// Cartella del registro (nei test una cartella temporanea).
  @visibleForTesting
  static Future<Directory> Function() directory = _defaultDirectory;

  static Future<Directory> _defaultDirectory() async =>
      getApplicationSupportDirectory();

  static Future<void> _queue = Future.value();
  static int _written = 0;
  static final Map<String, DateTime> _recent = {};

  /// Annota [error] (con [stack] e il [context], es. «Avvio dell'app»).
  static Future<void> record(
    Object error,
    StackTrace? stack, {
    String? context,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final text = '$error';
    final last = _recent[text];
    if (last != null && at.difference(last) < repeatWindow) {
      return _queue;
    }
    if (_recent.length > 50) _recent.clear();
    _recent[text] = at;
    if (_written >= maxEntriesPerRun) return _queue;
    _written++;
    final entry = StringBuffer()
      ..writeln('[${at.toIso8601String()}] ${context ?? 'Errore'}')
      ..writeln('${error.runtimeType}: $text');
    final st = stack?.toString().trim();
    if (st != null && st.isNotEmpty) {
      // le prime righe bastano per capire dove
      final lines = st.split('\n');
      entry.writeln(lines.take(25).join('\n'));
      if (lines.length > 25) entry.writeln('… (${lines.length - 25} righe)');
    }
    entry.writeln();
    return _queue = _queue.then((_) => _append(entry.toString()));
  }

  static Future<void> _append(String entry) async {
    try {
      final f = await file();
      if (f == null) return;
      await f.parent.create(recursive: true);
      if (await f.exists() && await f.length() > maxBytes) {
        final old = File('${f.path}.1');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
      await f.writeAsString(entry, mode: FileMode.append, flush: true);
    } catch (_) {
      // registro non scrivibile (disco pieno, permessi): si continua senza
    }
  }

  /// File del registro (null se la cartella non è disponibile).
  static Future<File?> file() async {
    try {
      return File(p.join((await directory()).path, fileName));
    } catch (_) {
      return null;
    }
  }

  /// Testo del registro (vuoto se non c'è), le voci più vecchie prima.
  static Future<String> read() async {
    await _queue;
    final out = StringBuffer();
    try {
      final f = await file();
      if (f == null) return '';
      for (final x in [File('${f.path}.1'), f]) {
        // (byte non UTF-8, es. una voce troncata dall'app chiusa a metà
        // scrittura: si legge il resto invece di mostrare il registro vuoto)
        if (await x.exists()) {
          out.write(utf8.decode(await x.readAsBytes(), allowMalformed: true));
        }
      }
    } catch (_) {}
    return out.toString();
  }

  /// Svuota il registro.
  static Future<void> clear() async {
    await _queue;
    try {
      final f = await file();
      if (f == null) return;
      for (final x in [File('${f.path}.1'), f]) {
        if (await x.exists()) await x.delete();
      }
    } catch (_) {}
  }

  /// Azzera i contatori di questo avvio (test).
  @visibleForTesting
  static void resetForTest() {
    _written = 0;
    _recent.clear();
    _queue = Future.value();
  }
}

/// Errori di spazio esaurito sul disco (SQLite o file system).
bool isDiskFullError(Object e) {
  if (e is DatabaseException) {
    final code = e.getResultCode();
    if (code != null && (code & 0xff) == 13) return true; // SQLITE_FULL
    return '$e'.toLowerCase().contains('disk is full');
  }
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    // ENOSPC (Android, Linux, macOS: 28), Windows: ERROR_DISK_FULL (112),
    // ERROR_HANDLE_DISK_FULL (39)
    return code == 28 || code == 112 || code == 39;
  }
  return false;
}
