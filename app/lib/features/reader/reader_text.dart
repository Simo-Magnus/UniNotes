/// Ricerca nel testo del lettore: senza maiuscole e senza accenti
/// ("perche" trova "perché"), con posizioni che restano quelle del testo
/// originale (la piegatura è carattere per carattere, stessa lunghezza).
library;

/// Lettere accentate → lettera base (una unità UTF-16 per una).
const _accented = {
  'a': 'àáâãäåāăąǎ',
  'c': 'çćĉċč',
  'd': 'ďđ',
  'e': 'èéêëēĕėęě',
  'g': 'ĝğġģ',
  'h': 'ĥħ',
  'i': 'ìíîïĩīĭįıǐ',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľŀł',
  'n': 'ñńņňŉ',
  'o': 'òóôõöøōŏőǒ',
  'r': 'ŕŗř',
  's': 'śŝşšș',
  't': 'ţťŧț',
  'u': 'ùúûüũūŭůűųǔ',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
};

final Map<int, int> _fold = () {
  final m = <int, int>{};
  for (final e in _accented.entries) {
    final base = e.key.codeUnitAt(0);
    for (final c in e.value.codeUnits) {
      m[c] = base;
      final upper = String.fromCharCode(c).toUpperCase();
      if (upper.length == 1) m[upper.codeUnitAt(0)] = base;
    }
  }
  // Apostrofi e virgolette tipografiche come quelle della tastiera.
  for (final c in '’‘ʼ'.codeUnits) {
    m[c] = 0x27;
  }
  for (final c in '“”«»'.codeUnits) {
    m[c] = 0x22;
  }
  m[0xA0] = 0x20; // spazio indivisibile
  return m;
}();

/// Testo piegato per la ricerca: stessa lunghezza dell'originale.
String foldText(String s) {
  final out = List<int>.filled(s.length, 0);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final f = _fold[c];
    if (f != null) {
      out[i] = f;
    } else if (c < 0x80) {
      out[i] = (c >= 0x41 && c <= 0x5A) ? c + 32 : c;
    } else {
      final l = String.fromCharCode(c).toLowerCase();
      out[i] = l.length == 1 ? l.codeUnitAt(0) : c;
    }
  }
  return String.fromCharCodes(out);
}

/// Posizioni (inizio) di [query] in [text], senza maiuscole né accenti.
/// [foldedText] evita di ripiegare lo stesso testo a ogni ricerca.
List<int> findFolded(String text, String query, {String? foldedText}) {
  final q = foldText(query);
  if (q.isEmpty) return const [];
  final t = foldedText ?? foldText(text);
  final out = <int>[];
  for (var i = t.indexOf(q); i >= 0; i = t.indexOf(q, i + q.length)) {
    out.add(i);
  }
  return out;
}

/// Espressione regolare equivalente a [findFolded], per i motori che
/// accettano un `Pattern` (la ricerca nel PDF di pdfrx).
RegExp accentInsensitivePattern(String query) {
  final b = StringBuffer();
  for (final ch in foldText(query).split('')) {
    final variants = _accented[ch];
    if (variants != null) {
      b.write('[$ch$variants]');
    } else if (ch == "'") {
      b.write("['’‘ʼ]");
    } else if (ch == ' ') {
      b.write(r'[  ]');
    } else {
      b.write(RegExp.escape(ch));
    }
  }
  return RegExp(b.toString(), caseSensitive: false);
}
