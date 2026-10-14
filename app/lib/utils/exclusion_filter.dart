/// Filtro per escludere OFA, lezioni di inglese, corsi facoltativi, ecc.
class ExclusionFilter {
  ExclusionFilter(List<String> patterns)
    : _regexes = [
        for (final p in patterns)
          if (p.trim().isNotEmpty) _compile(p.trim()),
      ];

  final List<RegExp> _regexes;

  static RegExp _compile(String p) {
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
