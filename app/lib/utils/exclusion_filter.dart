/// Filtro per escludere OFA, lezioni di inglese, corsi facoltativi, ecc.
class ExclusionFilter {
  ExclusionFilter(List<String> patterns)
    : _regexes = [
        for (final p in patterns)
          if (p.trim().isNotEmpty) _compile(p.trim()),
      ];

  final List<RegExp> _regexes;

  /// Gruppo con un quantificatore dentro e un altro fuori, come `(a+)+` o
  /// `(.*)*`: le espressioni regolari di Dart tornano indietro provando ogni
  /// combinazione e su un titolo di 30 caratteri l'app si blocca per ore. Un
  /// filtro così (scritto a mano nelle versioni con i filtri avanzati,
  /// sincronizzato o ripristinato da un backup) si usa come testo semplice.
  static final _nestedQuantifier = RegExp(
    r'\((?:[^()\\]|\\.)*[+*](?:[^()\\]|\\.)*\)(?:[+*]|\{\d+,\d*\})',
  );

  /// Gruppo con alternative e un quantificatore fuori, come `(a|aa)+` o
  /// `(x|x?)*`: stesso problema (le alternative si sovrappongono). Un filtro
  /// normale come `(ofa|inglese)` non ha il quantificatore e resta valido.
  static final _quantifiedAlternation = RegExp(
    r'\((?:[^()\\]|\\.)*\|(?:[^()\\]|\\.)*\)(?:[+*]|\{\d+,\d*\})',
  );

  static RegExp _compile(String p) {
    if (_nestedQuantifier.hasMatch(p) || _quantifiedAlternation.hasMatch(p)) {
      return RegExp(RegExp.escape(p), caseSensitive: false);
    }
    try {
      return RegExp(p, caseSensitive: false);
    } on FormatException {
      return RegExp(RegExp.escape(p), caseSensitive: false);
    }
  }

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
