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
Future<void> writeStringAtomic(File f, String text) {
  final key = f.absolute.path;
  final before = _queues[key] ?? Future<void>.value();
  final next = before.catchError((Object _) {}).then((_) async {
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(text, flush: true);
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      // file di arrivo bloccato su qualche sistema: si toglie e si riprova
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  });
  _queues[key] = next;
  return next.whenComplete(() {
    if (identical(_queues[key], next)) _queues.remove(key);
  });
}

final Map<String, Future<void>> _queues = {};

/// Testo di un appunto o di una trascrizione anche se non è in UTF-8 (file
/// scritti con il Blocco note o con altre app): i byte non validi diventano
/// «�» invece di far fallire la lettura (e la schermata).
Future<String> readTextLenient(File f) async =>
    utf8.decode(await f.readAsBytes(), allowMalformed: true);

/// [v] come lista (dati JSON di un'altra versione dell'app: un campo di tipo
/// diverso vale come vuoto invece di rendere illeggibile tutto il file).
List<Object?> jsonList(Object? v) => v is List ? v : const [];
