import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Scritture sicure dei file di dati delle registrazioni e degli appunti
/// (sessione di registrazione, dati accanto all'audio, cestino).
///
/// - Il testo va in `<file>.part` e poi si rinomina sopra il file (su
///   Windows, macOS e Linux la rinomina sostituisce il file esistente): non
///   c'è mai un momento in cui il file vecchio è cancellato e quello nuovo
///   non c'è ancora (un'interruzione lì faceva perdere i dati).
/// - Le scritture dello stesso file si fanno una alla volta, nell'ordine:
///   due salvataggi insieme (timer, pausa, segnalibro) usavano lo stesso
///   `.part` e il secondo falliva con «file non trovato».
Future<void> writeStringAtomic(File f, String text) =>
    _writeAtomic(f, (tmp) => tmp.writeAsString(text, flush: true));

/// Come [writeStringAtomic] per i byte (PDF esportati, file binari).
Future<void> writeBytesAtomic(File f, List<int> bytes) =>
    _writeAtomic(f, (tmp) => tmp.writeAsBytes(bytes, flush: true));

Future<void> _writeAtomic(File f, Future<void> Function(File tmp) write) {
  final key = f.absolute.path;
  final before = _queues[key] ?? Future<void>.value();
  final next = before.catchError((Object _) {}).then((_) async {
    final tmp = File('${f.path}.part');
    try {
      await write(tmp);
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        // file di arrivo bloccato su qualche sistema: si toglie e si riprova
        if (await f.exists()) await f.delete();
        await tmp.rename(f.path);
      }
    } catch (_) {
      // disco pieno o file in uso: la copia a metà non resta (riempirebbe
      // ancora il disco e nessuno la ripulirebbe); il file vero non si tocca
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  });
  _queues[key] = next;
  return next.whenComplete(() {
    if (identical(_queues[key], next)) _queues.remove(key);
  });
}

final Map<String, Future<void>> _queues = {};

/// Copia [src] in [dest] passando da `<dest>.part`: con il disco pieno o il
/// file di partenza sparito a metà non resta un file troncato al posto buono
/// (l'elenco lo mostrerebbe come un appunto o un documento valido).
Future<File> copyFileSafely(File src, String dest) async {
  final part = File('$dest.part');
  try {
    await src.copy(part.path);
    return await part.rename(dest);
  } catch (_) {
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Al massimo [max] caratteri di [s] senza spezzare una coppia surrogata
/// (un'emoji tagliata a metà diventava un carattere non valido nel nome del
/// file).
String cutText(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  if (end > 0 && _isHigh(s.codeUnitAt(end - 1))) end--;
  return s.substring(0, end);
}

bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;

final _winReserved = RegExp(
  r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
  caseSensitive: false,
);

/// Windows rifiuta questi nomi (CON, PRN, AUX, NUL, COM1-9, LPT1-9) anche
/// con un'estensione («CON.md», «aux.txt») e con spazi prima del punto.
bool isWindowsReservedName(String name) {
  final dot = name.indexOf('.');
  final stem = (dot < 0 ? name : name.substring(0, dot)).trimRight();
  return _winReserved.hasMatch(stem);
}

/// Testo di un appunto o di una trascrizione anche se non è in UTF-8 (file
/// scritti con il Blocco note o con altre app): i byte non validi diventano
/// «�» invece di far fallire la lettura (e la schermata).
Future<String> readTextLenient(File f) async =>
    utf8.decode(await f.readAsBytes(), allowMalformed: true);

/// [v] come lista (dati JSON di un'altra versione dell'app: un campo di tipo
/// diverso vale come vuoto invece di rendere illeggibile tutto il file).
List<Object?> jsonList(Object? v) => v is List ? v : const [];

/// Il file [path] esiste. Per i percorsi esterni scelti dall'utente (un
/// libro o un allegato su una condivisione di rete, un disco USB tolto): se
/// l'unità non risponde, il controllo di Windows può durare decine di
/// secondi e fermare la schermata che lo chiede per ogni file; dopo
/// [timeout] vale «non c'è» (il messaggio «file non trovato» è quello giusto
/// per l'utente).
Future<bool> fileExistsQuick(
  String path, {
  Duration timeout = const Duration(seconds: 5),
}) => File(path)
    .exists()
    .timeout(timeout, onTimeout: () => false)
    .catchError((Object _) => false);
