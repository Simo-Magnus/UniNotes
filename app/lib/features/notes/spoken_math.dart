/// Formule dette a voce in italiano → LaTeX, per l'opzione «Formule
/// (LaTeX)» della trascrizione dal vivo: «due terzi» → `$\frac{2}{3}$`,
/// «integrale da 2 a pi greco» → `$\int_{2}^{\pi}$`, «x al quadrato più y
/// al quadrato uguale r al quadrato» → `$x^{2} + y^{2} = r^{2}$`.
///
/// Funzione pura (test in test/spoken_math_test.dart): il testo che non è
/// una formula resta esattamente com'è, le formule diventano `$…$` (le
/// disegna `widgets/math_text.dart`). Una parte del testo diventa formula
/// solo se contiene almeno un segno o una struttura matematica (operatore,
/// frazione, potenza, radice, integrale, somma, limite, funzione, lettera
/// greca…) e almeno due parole: «tre», «alfa» o «la somma di due numeri»
/// da soli restano testo.
///
/// Cosa si riconosce:
/// - numeri in cifre o in lettere (anche composti: «ventitré», «duemila»),
///   decimali con «virgola»;
/// - frazioni: «due terzi», «un mezzo», «pi greco mezzi», «x fratto 2»,
///   «a su b», «3/4»;
/// - operatori: più, meno, più o meno, per, diviso, fattoriale;
/// - relazioni: uguale (a), fa, diverso da, minore/maggiore (o uguale) di/a,
///   circa uguale, tende a, appartiene a;
/// - potenze: al quadrato, quadro, al cubo, alla terza/n/meno uno, elevato
///   a; pedici: «x con zero», «a pedice n»;
/// - radici (quadrata, cubica, quarta, ennesima), valore assoluto;
/// - integrali «da … a …» o «tra … e …», con «in dx»;
/// - somme e produttorie «per k che va da 1 a n», «da i uguale 1 a n»;
/// - limiti «per x che tende a …» (prima o dopo la funzione);
/// - seno, coseno, tangente, logaritmo (anche «in base»), esponenziale, f di
///   x, f primo;
/// - lettere greche (anche «maiuscola»), pi greco, infinito, e alla x;
/// - parentesi: «aperta parentesi … chiusa parentesi».
library;

/// [text] con le formule dette a voce scritte in LaTeX (`$…$`). Le formule
/// già scritte (`$…$`) non si toccano.
String spokenMathToLatex(String text) {
  if (text.trim().isEmpty) return text;
  final out = StringBuffer();
  var from = 0;
  // le formule già presenti restano come sono
  for (final m in _existingMath.allMatches(text)) {
    out.write(_convertPlain(text.substring(from, m.start)));
    out.write(m.group(0));
    from = m.end;
  }
  out.write(_convertPlain(text.substring(from)));
  return out.toString();
}

final _existingMath = RegExp(r'\$\$[^$]+\$\$|\$[^$\n]+\$');

String _convertPlain(String text) {
  if (text.isEmpty) return text;
  final toks = _tokenize(text);
  if (toks.isEmpty) return text;
  final out = StringBuffer();
  var copied = 0;
  var i = 0;
  while (i < toks.length) {
    if (!toks[i].canStart) {
      i++;
      continue;
    }
    final p = _Parser(toks, i);
    String? tex;
    try {
      tex = p.relation();
    } on _Fail {
      tex = null;
    }
    final used = p.i - i;
    if (tex != null && p.strong > 0 && used >= 2) {
      out
        ..write(text.substring(copied, toks[i].start))
        ..write('\$$tex\$');
      copied = toks[p.i - 1].end;
      i = p.i;
    } else {
      i++;
    }
  }
  out.write(text.substring(copied));
  return out.toString();
}

// ---------------------------------------------------------------- parole

enum _Kind { word, number, symbol, other }

class _Tok {
  _Tok(this.raw, this.start, this.end, this.kind)
    : w = kind == _Kind.word ? _norm(raw) : raw;

  /// Testo originale.
  final String raw;
  final int start;
  final int end;
  final _Kind kind;

  /// Parola normalizzata (minuscole, «piu» → «più»).
  final String w;

  /// Da qui può iniziare una formula.
  bool get canStart => kind != _Kind.other && w != ')' && !w.endsWith("'");
}

String _norm(String w) {
  final l = w.toLowerCase().replaceAll('’', "'");
  return switch (l) {
    'piu' || 'più' => 'più',
    'pigreco' => 'π',
    _ => l,
  };
}

final _tokenRe = RegExp(
  // date (19/10/2026) e orari: mai formule
  r"(\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}:\d{2})"
  // numeri (anche con la virgola decimale)
  r'|(\d+(?:,\d+)?)'
  // parole (l', dell' restano attaccate all'apostrofo)
  r"|([A-Za-zÀ-ÖØ-öø-ÿ]+['’]?)"
  // segni
  r'|([+\-−=<>^/*×÷·()π∞])'
  r'|(\S)',
);

List<_Tok> _tokenize(String text) {
  final out = <_Tok>[];
  for (final m in _tokenRe.allMatches(text)) {
    final kind = m.group(1) != null
        ? _Kind.other
        : m.group(2) != null
        ? _Kind.number
        : m.group(3) != null
        ? _Kind.word
        : m.group(4) != null
        ? _Kind.symbol
        : _Kind.other;
    out.add(_Tok(m.group(0)!, m.start, m.end, kind));
  }
  // «pigreco» vale due parole: si lascia una sola (gestita in _norm)
  return out;
}

// ---------------------------------------------------------------- lessico

const _units = {
  'zero': 0,
  'uno': 1,
  'due': 2,
  'tre': 3,
  'quattro': 4,
  'cinque': 5,
  'sei': 6,
  'sette': 7,
  'otto': 8,
  'nove': 9,
  'dieci': 10,
  'undici': 11,
  'dodici': 12,
  'tredici': 13,
  'quattordici': 14,
  'quindici': 15,
  'sedici': 16,
  'diciassette': 17,
  'diciotto': 18,
  'diciannove': 19,
};

const _tens = {
  'venti': 20,
  'trenta': 30,
  'quaranta': 40,
  'cinquanta': 50,
  'sessanta': 60,
  'settanta': 70,
  'ottanta': 80,
  'novanta': 90,
};

/// Numero scritto in lettere (0–999999), anche composto («ventitré»,
/// «centoventi», «duemilauno»); null se non è un numero.
int? italianNumber(String word) {
  final w = word.toLowerCase().replaceAll('é', 'e').replaceAll('è', 'e');
  if (w.isEmpty) return null;
  return _parseNumber(w);
}

int? _parseNumber(String w) {
  if (w.isEmpty) return 0;
  if (_units.containsKey(w)) return _units[w];
  if (_tens.containsKey(w)) return _tens[w];
  if (w == 'cento') return 100;
  if (w == 'mille') return 1000;
  // migliaia: «duemila», «tremilacinquecento»
  final mila = w.indexOf('mila');
  if (mila > 0) {
    final a = _parseNumber(w.substring(0, mila));
    final b = _parseNumber(w.substring(mila + 4));
    if (a == null || b == null || a < 2) return null;
    return a * 1000 + b;
  }
  if (w.startsWith('mille')) {
    final b = _parseNumber(w.substring(5));
    return b == null ? null : 1000 + b;
  }
  // centinaia: «centoventi», «duecento», «trecentoquattro»
  final cento = w.indexOf('cent');
  if (cento >= 0) {
    final a = cento == 0 ? 1 : _parseNumber(w.substring(0, cento));
    var rest = w.substring(cento + 4);
    if (rest.startsWith('o')) rest = rest.substring(1);
    final b = _parseNumber(rest);
    if (a == null || b == null || a > 9 || a < 1) return null;
    return a * 100 + b;
  }
  // decine con unità: «ventitre», «ventuno», «trentotto»
  for (final e in _tens.entries) {
    final root = e.key.substring(0, e.key.length - 1);
    if (w.startsWith(e.key) || w.startsWith(root)) {
      final rest = w.startsWith(e.key)
          ? w.substring(e.key.length)
          : w.substring(root.length);
      if (rest.isEmpty) return e.value;
      final u = _units[rest];
      if (u == null || u > 9 || u == 0) return null;
      // l'elisione si usa solo davanti a «uno» e «otto»
      if (!w.startsWith(e.key) && rest != 'uno' && rest != 'otto') {
        return null;
      }
      return e.value + u;
    }
  }
  return null;
}

/// Denominatori: «mezzi», «terzi», «quarti»… e «-esimi» («undicesimi»,
/// «ennesimi»).
const _denominators = {
  'mezzo': '2',
  'mezzi': '2',
  'terzo': '3',
  'terzi': '3',
  'quarto': '4',
  'quarti': '4',
  'quinto': '5',
  'quinti': '5',
  'sesto': '6',
  'sesti': '6',
  'settimo': '7',
  'settimi': '7',
  'ottavo': '8',
  'ottavi': '8',
  'nono': '9',
  'noni': '9',
  'decimo': '10',
  'decimi': '10',
  'ennesimo': 'n',
  'ennesimi': 'n',
};

String? _denominator(String w) {
  final d = _denominators[w];
  if (d != null) return d;
  final m = RegExp(r'^(\w+?)esim[oi]$').firstMatch(w);
  if (m == null) return null;
  final root = m.group(1)!;
  for (final end in const ['i', 'e', 'o', 'a', '']) {
    final n = italianNumber('$root$end');
    if (n != null && n > 10) return '$n';
  }
  return null;
}

/// Esponenti detti come ordinali: «alla terza», «alla ennesima».
const _ordinalExp = {
  'seconda': '2',
  'terza': '3',
  'quarta': '4',
  'quinta': '5',
  'sesta': '6',
  'settima': '7',
  'ottava': '8',
  'nona': '9',
  'decima': '10',
  'ennesima': 'n',
  'emmesima': 'm',
};

const _greek = {
  'alfa': 'alpha',
  'alpha': 'alpha',
  'beta': 'beta',
  'gamma': 'gamma',
  'delta': 'delta',
  'epsilon': 'varepsilon',
  'eta': 'eta',
  'theta': 'theta',
  'teta': 'theta',
  'iota': 'iota',
  'lambda': 'lambda',
  'mu': 'mu',
  'nu': 'nu',
  'xi': 'xi',
  'omicron': 'omicron',
  'rho': 'rho',
  'ro': 'rho',
  'sigma': 'sigma',
  'tau': 'tau',
  'upsilon': 'upsilon',
  'fi': 'varphi',
  'phi': 'varphi',
  'psi': 'psi',
  'omega': 'omega',
};

/// Lettere greche che hanno la maiuscola in LaTeX.
const _greekUpper = {
  'gamma',
  'delta',
  'theta',
  'lambda',
  'xi',
  'sigma',
  'upsilon',
  'varphi',
  'psi',
  'omega',
};

/// Lettere dette per nome.
const _letterNames = {
  'ics': 'x',
  'ipsilon': 'y',
  'zeta': 'z',
  'enne': 'n',
  'emme': 'm',
  'effe': 'f',
  'erre': 'r',
  'esse': 's',
  'acca': 'h',
  'kappa': 'k',
};

/// Lettere usate come variabili. Non ci sono a, e, i, o (articoli e
/// congiunzioni), d (il «d» di dx) e l (l').
const _letters = 'bcfghjkmnpqrstuvwxyz';

const _functions = {
  'seno': r'\sin',
  'sen': r'\sin',
  'sin': r'\sin',
  'coseno': r'\cos',
  'cos': r'\cos',
  'tangente': r'\tan',
  'tan': r'\tan',
  'tg': r'\tan',
  'cotangente': r'\cot',
  'arcoseno': r'\arcsin',
  'arcseno': r'\arcsin',
  'arcocoseno': r'\arccos',
  'arcoseno coseno': r'\arccos',
  'arcotangente': r'\arctan',
  'arctangente': r'\arctan',
  'logaritmo': r'\log',
  'log': r'\log',
  'ln': r'\ln',
  'esponenziale': r'\exp',
  'exp': r'\exp',
};

class _Fail implements Exception {}

// ---------------------------------------------------------------- analisi

/// Analisi a discesa ricorsiva del parlato a partire dalla parola [i]: ogni
/// regola restituisce il LaTeX o null (e rimette [i] dov'era).
class _Parser {
  _Parser(this.t, this.i);
  final List<_Tok> t;
  int i;

  /// Segni o strutture matematiche trovate (0 = solo numeri o lettere).
  int strong = 0;

  /// Profondità della ricorsione (testi strani non la fanno esplodere).
  int _depth = 0;

  _Tok? tok([int k = 0]) => i + k < t.length ? t[i + k] : null;
  String? w([int k = 0]) => tok(k)?.w;

  bool isAt(String phrase) {
    final parts = phrase.split(' ');
    for (var k = 0; k < parts.length; k++) {
      if (w(k) != parts[k]) return false;
    }
    return true;
  }

  bool take(String phrase) {
    if (!isAt(phrase)) return false;
    i += phrase.split(' ').length;
    return true;
  }

  /// Chiavi di ogni tabella di frasi, dalle più lunghe.
  static final _keys = Expando<List<String>>();

  String? takeAny(Map<String, String> options) {
    final keys = _keys[options] ??= options.keys.toList()
      ..sort((a, b) => b.split(' ').length.compareTo(a.split(' ').length));
    for (final k in keys) {
      if (take(k)) return options[k];
    }
    return null;
  }

  T? attempt<T>(T? Function() rule) {
    final si = i, ss = strong;
    if (++_depth > 60) {
      _depth--;
      throw _Fail();
    }
    try {
      final r = rule();
      if (r == null) {
        i = si;
        strong = ss;
      }
      return r;
    } finally {
      _depth--;
    }
  }

  // ---------------------------------------------------------- relazioni

  static const _relations = {
    'è minore o uguale a': r'\leq',
    'minore o uguale a': r'\leq',
    'minore o uguale di': r'\leq',
    'minore uguale a': r'\leq',
    'minore o uguale': r'\leq',
    'è maggiore o uguale a': r'\geq',
    'maggiore o uguale a': r'\geq',
    'maggiore o uguale di': r'\geq',
    'maggiore uguale a': r'\geq',
    'maggiore o uguale': r'\geq',
    'è uguale a': '=',
    'uguale a': '=',
    'uguale': '=',
    'fa': '=',
    '=': '=',
    'è diverso da': r'\neq',
    'diverso da': r'\neq',
    'è minore di': '<',
    'minore di': '<',
    'minore': '<',
    '<': '<',
    'è maggiore di': '>',
    'maggiore di': '>',
    'maggiore': '>',
    '>': '>',
    'è circa uguale a': r'\approx',
    'circa uguale a': r'\approx',
    'circa uguale': r'\approx',
    'tende a': r'\to',
    'appartiene a': r'\in',
  };

  String? relation() => attempt(() {
    var left = sum();
    if (left == null) return null;
    while (true) {
      final si = i, ss = strong;
      final op = takeAny(_relations);
      if (op == null) break;
      final right = sum();
      if (right == null) {
        i = si;
        strong = ss;
        break;
      }
      left = '$left $op $right';
      strong++;
    }
    return left;
  });

  // ------------------------------------------------------------- somme

  static const _additive = {
    'più o meno': r'\pm',
    'più': '+',
    '+': '+',
    'meno': '-',
    '-': '-',
    '−': '-',
  };

  String? sum() => attempt(() {
    var left = product();
    if (left == null) return null;
    while (true) {
      final si = i, ss = strong;
      final op = takeAny(_additive);
      if (op == null) break;
      final right = product();
      if (right == null) {
        i = si;
        strong = ss;
        break;
      }
      left = '$left $op $right';
      strong++;
    }
    return left;
  });

  // ---------------------------------------------------------- prodotti

  static const _multiplicative = {
    'diviso per': r'\div',
    'diviso': r'\div',
    '÷': r'\div',
    'per': r'\cdot',
    '*': r'\cdot',
    '×': r'\cdot',
    '·': r'\cdot',
    'fratto': 'frac',
    '/': 'frac',
    'su': 'su',
  };

  /// «per x che tende a» / «per k che va da»: non è una moltiplicazione.
  bool get _perIntroducesVariable =>
      w() == 'per' &&
      _variable(1) != null &&
      const {'che', 'da', 'tendente', 'uguale'}.contains(w(2));

  String? product() => attempt(() {
    var left = power();
    if (left == null) return null;
    while (true) {
      if (_perIntroducesVariable) break;
      final si = i, ss = strong;
      final op = takeAny(_multiplicative);
      if (op != null) {
        final simpleLeft = _isSimple(left!);
        final right = op == 'frac' || op == 'su' ? signed() : power();
        if (right == null ||
            (op == 'su' && !(simpleLeft && _isSimple(right)))) {
          i = si;
          strong = ss;
          break;
        }
        left = op == 'frac' || op == 'su'
            ? '\\frac{$left}{$right}'
            : '$left $op $right';
        strong++;
        continue;
      }
      // moltiplicazione implicita: «due x», «3 pi greco», «2 seno di x»
      if (_endsWithNumber(left!) || left.endsWith(r'\right)')) {
        final right = attempt(() {
          final r = power();
          return r != null && !_startsWithDigit(r) ? r : null;
        });
        if (right != null) {
          left = '$left$right';
          continue;
        }
      }
      break;
    }
    return left;
  });

  /// Un segno davanti è ammesso (denominatori, esponenti).
  String? signed() => attempt(() {
    if (take('meno') || take('-') || take('−')) {
      final r = power();
      if (r == null) return null;
      strong++;
      return '-$r';
    }
    return power();
  });

  static bool _isSimple(String tex) =>
      RegExp(r'^(?:[A-Za-z]|\d+(?:\{,\}\d+)?|\\[a-zA-Z]+)$').hasMatch(tex);
  static bool _endsWithNumber(String tex) => RegExp(r'\d$').hasMatch(tex);
  static bool _startsWithDigit(String tex) => RegExp(r'^\d').hasMatch(tex);

  // ----------------------------------------------------------- potenze

  String _sup(String base, String exp) {
    final b = base.contains('^') || base.contains(' ') ? '{$base}' : base;
    return '$b^{$exp}';
  }

  String? exponent() => attempt(() {
    final ord = _ordinalExp[w()];
    if (ord != null) {
      i++;
      return ord;
    }
    if (take('meno') || take('-')) {
      final e = exponent();
      return e == null ? null : '-$e';
    }
    return atom();
  });

  String? power() => attempt(() {
    if (take('meno') || take('-') || take('−')) {
      // meno davanti: «meno tre», «meno infinito»
      final r = power();
      if (r == null) return null;
      strong++;
      return '-$r';
    }
    var base = atom();
    if (base == null) return null;
    while (true) {
      if (take('elevato al quadrato') ||
          take('al quadrato') ||
          take('quadro')) {
        base = _sup(base!, '2');
        strong++;
        continue;
      }
      if (take('elevato al cubo') || take('al cubo') || take('cubo')) {
        base = _sup(base!, '3');
        strong++;
        continue;
      }
      final si = i, ss = strong;
      if (take('elevato alla') ||
          take('elevato a') ||
          take('alla') ||
          take('^')) {
        final e = exponent();
        if (e == null) {
          i = si;
          strong = ss;
          break;
        }
        base = _sup(base!, e);
        strong++;
        continue;
      }
      if (take('fattoriale')) {
        base = '$base!';
        strong++;
        continue;
      }
      if (_isLetter(base!) && (isAt('con') || isAt('pedice'))) {
        final sj = i;
        i++;
        final sub = _numberOrLetter();
        if (sub == null) {
          i = sj;
          break;
        }
        base = '${base}_{$sub}';
        strong++;
        continue;
      }
      if (RegExp(r'^[fghy]$').hasMatch(base) && take('primo')) {
        base = "$base'";
        strong++;
        continue;
      }
      break;
    }
    return base;
  });

  static bool _isLetter(String tex) =>
      RegExp(r'^(?:[A-Za-z]|\\[a-zA-Z]+)$').hasMatch(tex);

  String? _numberOrLetter() {
    final n = _number();
    if (n != null) return n;
    final v = _variable(0, anyLetter: true);
    if (v != null) {
      i++;
      return v;
    }
    return null;
  }

  // ------------------------------------------------------------- atomi

  /// Variabile alla posizione [k]: lettera singola o detta per nome. Con
  /// [anyLetter] anche a, e, i, o (indici di somme e limiti).
  String? _variable(int k, {bool anyLetter = false}) {
    final tk = tok(k);
    if (tk == null || tk.kind != _Kind.word) return null;
    final named = _letterNames[tk.w];
    if (named != null) return named;
    if (tk.raw.length != 1) return null;
    final c = tk.raw;
    final lower = c.toLowerCase();
    if (anyLetter) return c;
    if (_letters.contains(lower)) return c;
    // maiuscole (A, B, C…) tranne le vocali, che sono parole
    if (c != lower && !'AEIO'.contains(c)) return c;
    return null;
  }

  /// Numero in cifre o in lettere, con «virgola» per i decimali.
  String? _number() {
    final tk = tok();
    if (tk == null) return null;
    String? n;
    if (tk.kind == _Kind.number) {
      n = tk.raw.replaceAll(',', '{,}');
    } else if (tk.kind == _Kind.word) {
      // «un» e «una» sono articoli: valgono 1 solo davanti a un
      // denominatore («un terzo»)
      if (tk.w == 'un' || tk.w == 'una') {
        if (_denominator(w(1) ?? '') == null) return null;
        n = '1';
      } else {
        final v = italianNumber(tk.w);
        if (v == null) return null;
        n = '$v';
      }
    }
    if (n == null) return null;
    i++;
    if (isAt('virgola')) {
      final next = tok(1);
      final digits = next == null
          ? null
          : (next.kind == _Kind.number
                ? next.raw
                : (italianNumber(next.w)?.toString()));
      if (digits != null) {
        i += 2;
        n = '$n{,}$digits';
      }
    }
    return n;
  }

  String? atom() => attempt(() {
    final a = _atom();
    if (a == null) return null;
    // frazione detta: «due terzi», «pi greco mezzi», «x mezzi»
    final den = _denominator(w() ?? '');
    if (den != null && _isSimple(a)) {
      i++;
      strong++;
      return '\\frac{$a}{$den}';
    }
    return a;
  });

  String? _atom() {
    final tk = tok();
    if (tk == null) return null;
    final word = tk.w;

    // parentesi
    if (take('(') ||
        take('aperta parentesi') ||
        take('apri parentesi') ||
        take('parentesi aperta') ||
        take('si apre parentesi') ||
        take('si apre la parentesi')) {
      final inner = relation();
      if (inner == null) return null;
      if (!(take(')') ||
          take('chiusa parentesi') ||
          take('chiudi parentesi') ||
          take('parentesi chiusa') ||
          take('si chiude parentesi') ||
          take('si chiude la parentesi'))) {
        return null;
      }
      strong++;
      return '\\left($inner\\right)';
    }

    if (take('più infinito')) {
      strong++;
      return r'+\infty';
    }
    if (word == 'infinito' || word == '∞') {
      i++;
      strong++;
      return r'\infty';
    }
    if (take('pi greco') || take('π')) {
      strong++;
      return r'\pi';
    }

    if (word == 'radice') return _root();
    if (take('valore assoluto di') || take('valore assoluto')) {
      final arg = power();
      if (arg == null) return null;
      strong++;
      return '\\left|$arg\\right|';
    }
    if (word == 'integrale') return _integral();
    if (word == 'sommatoria' || word == 'somma' || word == 'produttoria') {
      return _bigOperator();
    }
    if (word == 'limite') return _limit();
    if (word == 'derivata') return _derivative();

    final fn = _function();
    if (fn != null) return fn;

    // e alla x
    if (word == 'e' && (w(1) == 'alla' || w(1) == 'elevato' || w(1) == '^')) {
      i++;
      return 'e';
    }

    // lettere greche (anche maiuscole)
    final g = _greek[word];
    if (g != null) {
      i++;
      if (take('maiuscolo') || take('maiuscola') || take('grande')) {
        if (_greekUpper.contains(g)) {
          strong++;
          final cap = g.startsWith('var') ? g.substring(3) : g;
          return '\\${cap[0].toUpperCase()}${cap.substring(1)}';
        }
      }
      strong++;
      return '\\$g';
    }

    // f di x, g di t
    final v = _variable(0);
    if (v != null) {
      if (RegExp(r'^[fgh]$').hasMatch(v) && w(1) == 'di') {
        final si = i;
        i += 2;
        final arg = power();
        if (arg != null) {
          strong++;
          return '$v($arg)';
        }
        i = si;
      }
      i++;
      return v;
    }
    return _number();
  }

  String? _function() {
    if (take('logaritmo naturale')) return _applied(r'\ln');
    if (take('seno iperbolico')) return _applied(r'\sinh');
    if (take('coseno iperbolico')) return _applied(r'\cosh');
    final name = _functions[w()];
    if (name == null) return null;
    i++;
    if (name == r'\log' && take('in base')) {
      final b = _numberOrLetter();
      if (b == null) return null;
      return _applied('\\log_{$b}');
    }
    if (name == r'\exp') {
      take('di');
      final arg = power();
      if (arg == null) return null;
      strong++;
      return 'e^{$arg}';
    }
    return _applied(name);
  }

  String? _applied(String name) {
    take('di');
    final arg = power();
    if (arg == null) return null;
    strong++;
    return '$name $arg';
  }

  String? _root() {
    if (!take('radice')) return null;
    String? index;
    if (take('quadrata')) {
      index = null;
    } else if (take('cubica')) {
      index = '3';
    } else if (take('ennesima')) {
      index = 'n';
    } else {
      final o = _ordinalExp[w()];
      if (o != null) {
        i++;
        index = o;
      }
    }
    take('di');
    final arg = power();
    if (arg == null) return null;
    strong++;
    return index == null ? '\\sqrt{$arg}' : '\\sqrt[$index]{$arg}';
  }

  /// «integrale (definito) da A a B (di) F (in) dx».
  String? _integral() {
    if (!take('integrale')) return null;
    take('definito') || take('indefinito');
    String bounds = '';
    if (take('da')) {
      final lo = sum();
      if (lo == null || !(take('fino a') || take('a'))) return null;
      final hi = sum();
      if (hi == null) return null;
      bounds = '_{$lo}^{$hi}';
    } else if (take('tra') || take('fra')) {
      final lo = sum();
      if (lo == null || !take('e')) return null;
      final hi = sum();
      if (hi == null) return null;
      bounds = '_{$lo}^{$hi}';
    }
    var body = '';
    final hadOf = take('di');
    final f = attempt(sum);
    if (f != null) {
      body = ' $f';
    } else if (hadOf) {
      i--;
    }
    // differenziale: «in dx», «in d x», «dx», «d x»
    var diff = '';
    final si = i;
    take('in');
    final dw = w();
    if (dw != null && RegExp(r'^d[a-z]$').hasMatch(dw)) {
      i++;
      diff = ' \\, d${dw.substring(1)}';
    } else if (dw == 'd' && _variable(1, anyLetter: true) != null) {
      diff = ' \\, d${_variable(1, anyLetter: true)}';
      i += 2;
    } else {
      i = si;
    }
    strong++;
    return '\\int$bounds$body$diff';
  }

  /// «sommatoria (per k che va) da 1 a n (di) F», «somma da i uguale 1 a n».
  String? _bigOperator() {
    final word = w();
    final op = word == 'produttoria' ? r'\prod' : r'\sum';
    i++;
    String? index, lo, hi;
    if (take('per')) {
      index = _variable(0, anyLetter: true);
      if (index == null) return null;
      i++;
      take('che va') || take('che varia');
      if (!take('da')) return null;
      lo = sum();
      if (lo == null || !take('a')) return null;
      hi = sum();
    } else if (isAt('da') &&
        _variable(1, anyLetter: true) != null &&
        (w(2) == 'uguale' || w(2) == '=')) {
      i++;
      index = _variable(0, anyLetter: true);
      i++;
      take('uguale a') || take('uguale') || take('=');
      lo = sum();
      if (lo == null || !take('a')) return null;
      hi = sum();
    }
    // «la somma di due numeri»: senza estremi resta testo
    if (hi == null && word == 'somma') return null;
    take('di');
    final body = attempt(product);
    if (body == null && hi == null) return null;
    strong++;
    final b = hi == null ? '' : '_{${index ?? ''}=$lo}^{$hi}';
    return '$op$b${body == null ? '' : ' $body'}';
  }

  /// «limite per x che tende a T (di) F» o «limite di F per x che tende a
  /// T».
  String? _limit() {
    if (!take('limite')) return null;
    String? sub() {
      if (!take('per')) return null;
      final v = _variable(0, anyLetter: true);
      if (v == null) return null;
      i++;
      if (!(take('che tende a') ||
          take('tendente a') ||
          take('tende a') ||
          take('→'))) {
        return null;
      }
      final target = sum();
      if (target == null) return null;
      return '$v \\to $target';
    }

    var under = attempt(sub);
    String? body;
    if (under != null) {
      take('di');
      body = attempt(product);
    } else {
      if (!take('di')) return null;
      body = product();
      if (body == null) return null;
      under = attempt(sub);
      if (under == null) return null;
    }
    strong++;
    return '\\lim_{$under}${body == null ? '' : ' $body'}';
  }

  /// «derivata di F rispetto a x».
  String? _derivative() {
    if (!take('derivata')) return null;
    take('prima');
    if (!take('di')) return null;
    final f = power();
    if (f == null || !take('rispetto a')) return null;
    final v = _variable(0, anyLetter: true);
    if (v == null) return null;
    i++;
    strong++;
    return '\\frac{d}{d$v} $f';
  }
}
