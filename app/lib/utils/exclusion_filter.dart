/// Filtro per escludere OFA, lezioni di inglese, corsi facoltativi, ecc.
///
/// I filtri arrivano dalle caselle di Impostazioni → Esclusioni, ma anche
/// dalla sincronizzazione con gli altri dispositivi, da un backup ripristinato
/// o dalle versioni con i filtri avanzati scritti a mano: un'espressione
/// regolare qualsiasi può tenere occupata l'app per ore (le espressioni di
/// Dart tornano indietro provando ogni combinazione). Si usano come
/// espressioni solo quelle dal costo limitato ([isSafePattern]); le altre come
/// testo semplice.
class ExclusionFilter {
  ExclusionFilter(List<String> patterns)
    : _regexes = [
        for (final p in patterns
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .take(maxPatterns))
          _compile(p),
      ];

  final List<RegExp> _regexes;

  /// Filtri letti al massimo (gli altri si ignorano): con le caselle delle
  /// esclusioni sono meno di dieci.
  static const maxPatterns = 100;

  /// Lunghezza massima di un filtro usato come espressione regolare.
  static const maxRegexLength = 200;

  static RegExp _compile(String p) {
    if (isSafePattern(p)) {
      try {
        return RegExp(p, caseSensitive: false);
      } on FormatException {
        // espressione non valida: testo semplice
      }
    }
    return RegExp(RegExp.escape(p), caseSensitive: false);
  }

  /// Vero se [p] si può usare come espressione regolare senza rischio di
  /// blocco: corta, senza riferimenti all'indietro, gruppi non annidati (al
  /// massimo 5), al massimo 30 alternative, nessun quantificatore su un
  /// gruppo con alternative o quantificatori dentro (`(a+)+`, `(a|aa)*`) e
  /// al massimo 2 quantificatori (3 se l'espressione parte da `^` senza
  /// alternative fuori dai gruppi, che la provano da una posizione sola).
  /// Così anche il caso peggiore su un titolo resta di poche migliaia di
  /// passi per carattere.
  static bool isSafePattern(String p) {
    if (p.length > maxRegexLength) return false;
    var quantifiers = 0;
    var groups = 0;
    var alternatives = 0;
    var topLevelAlternation = false;
    var depth = 0;
    var inClass = false;
    // gruppo aperto: contiene alternative o quantificatori
    var groupComplex = false;
    // l'ultimo elemento chiuso è un gruppo complesso / semplice
    var afterComplexGroup = false;
    var afterAtom = false;
    for (var i = 0; i < p.length; i++) {
      final c = p[i];
      if (c == r'\') {
        if (i + 1 >= p.length) return false;
        final n = p[i + 1];
        // \1…\9 e \k<nome>: riferimenti all'indietro
        if (_digits.contains(n) || n == 'k') return false;
        i++;
        afterAtom = true;
        afterComplexGroup = false;
        continue;
      }
      if (inClass) {
        if (c == ']') {
          inClass = false;
          afterAtom = true;
          afterComplexGroup = false;
        }
        continue;
      }
      switch (c) {
        case '[':
          inClass = true;
        case '(':
          if (depth > 0) return false;
          depth++;
          groups++;
          groupComplex = false;
          afterAtom = false;
          afterComplexGroup = false;
          // (?:…), (?=…), (?!…), (?<=…), (?<nome>…): il «?» non è un
          // quantificatore
          if (i + 1 < p.length && p[i + 1] == '?') i++;
        case ')':
          if (depth == 0) return false;
          depth--;
          afterAtom = true;
          afterComplexGroup = groupComplex;
        case '|':
          alternatives++;
          if (depth > 0) {
            groupComplex = true;
          } else {
            topLevelAlternation = true;
          }
          afterAtom = false;
          afterComplexGroup = false;
        case '*' || '+' || '?' || '{':
          if (c == '{') {
            final end = p.indexOf('}', i);
            if (end < 0) return false;
            i = end;
          }
          // quantificatore pigro (*?, +?, ??): stesso costo
          if (i + 1 < p.length && p[i + 1] == '?') i++;
          if (!afterAtom || afterComplexGroup) return false;
          quantifiers++;
          if (depth > 0) groupComplex = true;
          afterAtom = false;
        default:
          afterAtom = true;
          afterComplexGroup = false;
      }
    }
    if (inClass || depth != 0) return false;
    if (groups > 5 || alternatives > 30) return false;
    final anchored = p.startsWith('^') && !topLevelAlternation;
    return quantifiers <= (anchored ? 3 : 2);
  }

  static const _digits = '0123456789';

  /// true se uno qualsiasi dei testi corrisponde a un pattern di esclusione.
  bool isExcluded(Iterable<String?> texts) {
    for (final t in texts) {
      if (t == null || t.isEmpty) continue;
      for (final r in _regexes) {
        if (r.hasMatch(t)) return true;
      }
    }
    return false;
  }
}
