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
  ExclusionFilter(List<String> patterns) {
    _compileAll(patterns);
  }

  /// Filtri con quantificatori (confrontati sui primi [maxTextLength]
  /// caratteri) e filtri senza (testo semplice o espressioni come `\bOFA\b`,
  /// `inglese`: costo lineare, confrontati con tutto il testo, così un nome
  /// lungo con «Inglese» in fondo resta escluso).
  final List<RegExp> _bounded = [];
  final List<RegExp> _linear = [];

  void _compileAll(List<String> patterns) {
    var regexes = 0;
    for (final p
        in patterns
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .take(maxPatterns)) {
      // oltre [maxRegexPatterns] espressioni le altre valgono come testo
      // (il costo di ogni testo si somma su tutti i filtri)
      final q = regexes < maxRegexPatterns ? _quantifiersOf(p) : null;
      final r = q == null ? null : _compile(p);
      if (r != null) {
        regexes++;
        (q! > 0 ? _bounded : _linear).add(r);
      } else {
        _linear.add(RegExp(RegExp.escape(p), caseSensitive: false));
      }
    }
  }

  /// Filtri usati come espressioni regolari al massimo (le caselle di
  /// Impostazioni sono 6).
  static const maxRegexPatterns = 12;

  /// Filtri letti al massimo (gli altri si ignorano): con le caselle delle
  /// esclusioni sono meno di dieci.
  static const maxPatterns = 100;

  /// Lunghezza massima di un filtro usato come espressione regolare.
  static const maxRegexLength = 200;

  /// Caratteri di ogni testo confrontati con i filtri con quantificatori
  /// (`.*`, `+`…, scritti a mano: quelli delle Impostazioni non ne hanno e
  /// guardano tutto il testo). Anche un'espressione ammessa da
  /// [isSafePattern] costa fino al cubo della lunghezza del testo (`.*a.*b`
  /// su 10.000 caratteri: circa un minuto); su 150 caratteri resta di pochi
  /// millisecondi (su 200 già oltre 70 ms). Nel database solo lo 0,07% dei
  /// nomi supera i 150 caratteri (il più lungo circa 190).
  static const maxTextLength = 150;

  /// Caratteri confrontati con i filtri senza quantificatori (costo lineare:
  /// i nomi più lunghi del database sono sotto i 200 caratteri).
  static const maxLinearTextLength = 2000;

  /// Prodotto massimo delle alternative dei gruppi in sequenza
  /// (`(a|b)(c|d)` = 4): si moltiplicano i percorsi provati. Con due o più
  /// quantificatori (ogni percorso si riprova per ogni loro combinazione)
  /// al massimo [maxPathsWithQuantifiers].
  static const maxAlternativePaths = 30;
  static const maxPathsWithQuantifiers = 2;

  /// Espressione di [p] (già ammessa da [isSafePattern]), o null se va usato
  /// come testo semplice.
  static RegExp? _compile(String p) {
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
  static bool isSafePattern(String p) => _quantifiersOf(p) != null;

  /// Quantificatori di [p] se è ammessa da [isSafePattern], altrimenti null.
  static int? _quantifiersOf(String p) {
    if (p.length > maxRegexLength) return null;
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
        if (i + 1 >= p.length) return null;
        final n = p[i + 1];
        // \1…\9 e \k<nome>: riferimenti all'indietro
        if (_digits.contains(n) || n == 'k') return null;
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
          if (depth > 0) return null;
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
          if (depth == 0) return null;
          depth--;
          paths *= groupBranches;
          if (paths > maxAlternativePaths) return null;
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
            if (end < 0) return null;
            i = end;
          }
          // quantificatore pigro (*?, +?, ??): stesso costo
          if (i + 1 < p.length && p[i + 1] == '?') i++;
          if (!afterAtom || afterComplexGroup) return null;
          quantifiers++;
          if (depth > 0) groupComplex = true;
          afterAtom = false;
        default:
          afterAtom = true;
          afterComplexGroup = false;
      }
    }
    if (inClass || depth != 0) return null;
    if (groups > 5 || alternatives > 30) return null;
    if (quantifiers >= 2 && paths > maxPathsWithQuantifiers) return null;
    final anchored = p.startsWith('^') && !topLevelAlternation;
    return quantifiers <= (anchored ? 3 : 2) ? quantifiers : null;
  }

  static const _digits = '0123456789';

  /// true se uno qualsiasi dei testi corrisponde a un pattern di esclusione.
  bool isExcluded(Iterable<String?> texts) {
    for (final t in texts) {
      if (t == null || t.isEmpty) continue;
      // (testo lunghissimo da un data pack o da un backup: solo l'inizio,
      // vedi [maxTextLength] e [maxLinearTextLength])
      final long = t.length > maxLinearTextLength
          ? t.substring(0, maxLinearTextLength)
          : t;
      for (final r in _linear) {
        if (r.hasMatch(long)) return true;
      }
      if (_bounded.isEmpty) continue;
      final s = t.length > maxTextLength ? t.substring(0, maxTextLength) : t;
      for (final r in _bounded) {
        if (r.hasMatch(s)) return true;
      }
    }
    return false;
  }
}
