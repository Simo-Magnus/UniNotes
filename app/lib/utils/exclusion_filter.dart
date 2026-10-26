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
  ExclusionFilter(List<String> patterns) : _regexes = _compileAll(patterns);

  final List<RegExp> _regexes;

  static List<RegExp> _compileAll(List<String> patterns) {
    var regexes = 0;
    final out = <RegExp>[];
    for (final p
        in patterns
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .take(maxPatterns)) {
      // oltre [maxRegexPatterns] espressioni le altre valgono come testo
      // (il costo di ogni testo si somma su tutti i filtri)
      final r = regexes < maxRegexPatterns ? _compile(p) : null;
      if (r != null) regexes++;
      out.add(r ?? RegExp(RegExp.escape(p), caseSensitive: false));
    }
    return out;
  }

  /// Filtri usati come espressioni regolari al massimo (le caselle di
  /// Impostazioni sono 6).
  static const maxRegexPatterns = 12;

  /// Filtri letti al massimo (gli altri si ignorano): con le caselle delle
  /// esclusioni sono meno di dieci.
  static const maxPatterns = 100;

  /// Lunghezza massima di un filtro usato come espressione regolare.
  static const maxRegexLength = 200;

  /// Caratteri di ogni testo confrontati con i filtri (i nomi degli
  /// insegnamenti e dei moduli sono molto più corti). Anche un'espressione
  /// ammessa da [isSafePattern] costa fino al cubo della lunghezza del testo
  /// (`.*a.*b` su 10.000 caratteri: circa un minuto); su 150 caratteri resta
  /// di pochi millisecondi.
  static const maxTextLength = 150;

  /// Prodotto massimo delle alternative dei gruppi in sequenza
  /// (`(a|b)(c|d)` = 4): si moltiplicano i percorsi provati. Con due o più
  /// quantificatori (ogni percorso si riprova per ogni loro combinazione)
  /// al massimo [maxPathsWithQuantifiers].
  static const maxAlternativePaths = 30;
  static const maxPathsWithQuantifiers = 2;

  /// Espressione di [p], o null se va usato come testo semplice.
  static RegExp? _compile(String p) {
    if (!isSafePattern(p)) return null;
    try {
      return RegExp(p, caseSensitive: false);
    } on FormatException {
      // espressione non valida: testo semplice
      return null;
    }
  }

  /// Vero se [p] si può usare come espressione regolare senza rischio di
  /// blocco: corta, senza riferimenti all'indietro, gruppi non annidati (al
  /// massimo 5), al massimo 30 alternative, nessun quantificatore su un
  /// gruppo con alternative o quantificatori dentro (`(a+)+`, `(a|aa)*`) e
  /// al massimo 2 quantificatori (3 se l'espressione parte da `^` senza
  /// alternative fuori dai gruppi, che la provano da una posizione sola),
  /// e i gruppi con alternative in sequenza non oltre
  /// [maxAlternativePaths] percorsi. Con i testi tagliati a [maxTextLength]
  /// anche il caso peggiore resta sotto i 50 ms.
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
    // alternative del gruppo aperto e prodotto di quelle dei gruppi chiusi
    var groupBranches = 1;
    var paths = 1;
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
          groupBranches = 1;
          afterAtom = false;
          afterComplexGroup = false;
          // (?:…), (?=…), (?!…), (?<=…), (?<nome>…): il «?» non è un
          // quantificatore
          if (i + 1 < p.length && p[i + 1] == '?') i++;
        case ')':
          if (depth == 0) return false;
          depth--;
          paths *= groupBranches;
          if (paths > maxAlternativePaths) return false;
          afterAtom = true;
          afterComplexGroup = groupComplex;
        case '|':
          alternatives++;
          if (depth > 0) {
            groupComplex = true;
            groupBranches++;
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
    if (quantifiers >= 2 && paths > maxPathsWithQuantifiers) return false;
    final anchored = p.startsWith('^') && !topLevelAlternation;
    return quantifiers <= (anchored ? 3 : 2);
  }

  static const _digits = '0123456789';

  /// true se uno qualsiasi dei testi corrisponde a un pattern di esclusione.
  bool isExcluded(Iterable<String?> texts) {
    for (final t in texts) {
      if (t == null || t.isEmpty) continue;
      // (testo lunghissimo da un data pack o da un backup: solo l'inizio,
      // vedi [maxTextLength])
      final s = t.length > maxTextLength ? t.substring(0, maxTextLength) : t;
      for (final r in _regexes) {
        if (r.hasMatch(s)) return true;
      }
    }
    return false;
  }
}
