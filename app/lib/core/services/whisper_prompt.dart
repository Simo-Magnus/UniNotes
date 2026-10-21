/// Vocabolario del corso per Whisper (`initial_prompt` di whisper.cpp):
/// nomi dell'insegnamento, dei moduli e degli argomenti scritti come li
/// scrive il corso, così Whisper li riconosce («trasformata di Laplace»,
/// «Cauchy»…). Logica pura (test in test/whisper_prompt_test.dart).
///
/// whisper.cpp usa al più metà del contesto del testo (224 token) per il
/// prompt e, se è più lungo, tiene solo la fine: qui si taglia prima, a
/// elementi interi, tenendo i più pertinenti (sono i primi dell'elenco:
/// nome dell'insegnamento, modulo in corso e i suoi argomenti).
///
/// Solo vocabolario, mai l'ultima frase già trascritta: le finestre del
/// testo dal vivo si sovrappongono e Whisper, con la frase prima nel
/// prompt, tende a ripeterla (per questo è anche `noContext: true`).
library;

/// Token massimi del prompt (sotto i 224 di whisper.cpp, con margine per
/// la stima).
const kWhisperPromptTokens = 200;

final _space = RegExp(r'\s+');
final _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Stima prudente dei token di Whisper (BPE multilingue): una parola
/// italiana di 6 lettere sono ~2 token, la punteggiatura uno a parte.
int estimateWhisperTokens(String s) {
  var n = 0;
  for (final w in s.trim().split(_space)) {
    if (w.isEmpty) continue;
    final letters = w.replaceAll(_notWord, '');
    n += letters.isEmpty ? 0 : (letters.length / 3).ceil();
    n += w.length - letters.length;
  }
  return n;
}

/// «Lezione di Analisi 2: Equazioni differenziali, Cauchy, …» con gli
/// elementi di [terms] in ordine (il primo è il nome dell'insegnamento),
/// senza doppioni, finché si resta entro [maxTokens]. null se non c'è
/// niente.
String? buildWhisperPrompt(
  List<String> terms, {
  int maxTokens = kWhisperPromptTokens,
}) {
  final seen = <String>{};
  final clean = <String>[];
  for (final t in terms) {
    final v = t.replaceAll(_space, ' ').trim();
    if (v.isEmpty || v.length > 120) continue;
    if (seen.add(v.toLowerCase())) clean.add(v);
  }
  if (clean.isEmpty) return null;
  var out = 'Lezione di ${clean.first}';
  if (estimateWhisperTokens(out) > maxTokens) return null;
  var first = true;
  for (final t in clean.skip(1)) {
    final next = '$out${first ? ': ' : ', '}$t';
    if (estimateWhisperTokens('$next.') > maxTokens) break;
    out = next;
    first = false;
  }
  return '$out.';
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(_notWord, ' ').replaceAll(_space, ' ').trim();

/// [text] ripete il prompt (Whisper sui silenzi a volte «legge» il
/// vocabolario): almeno tre parole, tutte di seguito nel prompt.
bool isPromptEcho(String text, String? prompt) {
  if (prompt == null || prompt.isEmpty) return false;
  final t = _norm(text);
  if (t.split(' ').length < 3) return false;
  return ' ${_norm(prompt)} '.contains(' $t ');
}
