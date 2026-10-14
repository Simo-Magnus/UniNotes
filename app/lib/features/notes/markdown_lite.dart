/// Markdown essenziale per trascrizioni e riassunti, condiviso tra la vista
/// nell'app e l'esportazione in PDF.
///
/// Blocchi: titoli `#`–`####`, elenchi `-`/`*`/`1.`, citazioni `>`, righe
/// `---`, blocchi di codice ```` ``` ````, formule `$$…$$` o `\[…\]` su righe
/// proprie, paragrafi. In linea: `**grassetto**`, `*corsivo*`/`_corsivo_`,
/// `==evidenziato==` (i concetti chiave), `` `codice` ``, formule `$…$` e
/// `\(…\)` (vedi [parseInline] per il `$` usato come valuta).
library;

enum MdBlockType {
  heading,
  paragraph,
  bullet,
  numbered,
  quote,
  rule,
  code,
  math,
}

class MdSpan {
  const MdSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.highlight = false,
    this.code = false,
    this.math = false,
    this.display = false,
  });
  final String text;
  final bool bold;
  final bool italic;
  final bool highlight;
  final bool code;

  /// Formula LaTeX ([text] senza i delimitatori).
  final bool math;

  /// Formula in stile «a sé» (`$$…$$` dentro una riga di testo).
  final bool display;

  /// Testo con i delimitatori della formula (copia, ricerca, PDF).
  String get source => math ? (display ? '\$\$$text\$\$' : '\$$text\$') : text;
}

class MdBlock {
  const MdBlock(this.type, this.spans, {this.level = 0, this.number, this.raw});
  final MdBlockType type;
  final List<MdSpan> spans;

  /// Livello del titolo (1–4) o rientro dell'elenco (0, 1, …).
  final int level;
  final int? number;

  /// Testo grezzo (blocchi di codice, formula LaTeX dei blocchi di formula).
  final String? raw;

  String get plainText => raw ?? spans.map((s) => s.text).join();
}

final _heading = RegExp(r'^(#{1,4})\s+(.*)$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

/// Delimitatori dei blocchi di formula: (apertura, chiusura).
const _mathFences = [(r'$$', r'$$'), (r'\[', r'\]')];

List<MdBlock> parseMarkdown(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final out = <MdBlock>[];
  final para = <String>[];

  void flush() {
    if (para.isEmpty) return;
    out.add(MdBlock(MdBlockType.paragraph, parseInline(para.join(' '))));
    para.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final t = line.trim();
    if (t.startsWith('```')) {
      flush();
      final code = <String>[];
      for (i++; i < lines.length && !lines[i].trim().startsWith('```'); i++) {
        code.add(lines[i]);
      }
      out.add(MdBlock(MdBlockType.code, const [], raw: code.join('\n')));
      continue;
    }
    if (t.isEmpty) {
      flush();
      continue;
    }
    final math = _mathBlock(lines, i);
    if (math != null) {
      flush();
      out.add(MdBlock(MdBlockType.math, const [], raw: math.$1));
      i = math.$2;
      continue;
    }
    if (_rule.hasMatch(t) && !_bullet.hasMatch('$t x')) {
      flush();
      out.add(const MdBlock(MdBlockType.rule, []));
      continue;
    }
    if (_rule.hasMatch(t)) {
      flush();
      out.add(const MdBlock(MdBlockType.rule, []));
      continue;
    }
    final h = _heading.firstMatch(t);
    if (h != null) {
      flush();
      out.add(
        MdBlock(
          MdBlockType.heading,
          parseInline(h.group(2)!),
          level: h.group(1)!.length,
        ),
      );
      continue;
    }
    final b = _bullet.firstMatch(line);
    if (b != null) {
      flush();
      out.add(
        MdBlock(
          MdBlockType.bullet,
          parseInline(b.group(2)!),
          level: b.group(1)!.length ~/ 2,
        ),
      );
      continue;
    }
    final n = _numbered.firstMatch(line);
    if (n != null) {
      flush();
      out.add(
        MdBlock(
          MdBlockType.numbered,
          parseInline(n.group(3)!),
          level: n.group(1)!.length ~/ 2,
          number: int.tryParse(n.group(2)!),
        ),
      );
      continue;
    }
    if (t.startsWith('>')) {
      flush();
      out.add(
        MdBlock(
          MdBlockType.quote,
          parseInline(t.replaceFirst(RegExp(r'^>\s?'), '')),
        ),
      );
      continue;
    }
    para.add(t);
  }
  flush();
  return out;
}

/// Formula su righe proprie che inizia alla riga [i]: `$$…$$` o `\[…\]`,
/// su una riga sola o su più righe. Restituisce (LaTeX, ultima riga) o null
/// se la riga non apre una formula o la formula non si chiude (allora resta
/// testo normale).
(String, int)? _mathBlock(List<String> lines, int i) {
  final t = lines[i].trim();
  for (final (open, close) in _mathFences) {
    if (!t.startsWith(open)) continue;
    final rest = t.substring(open.length);
    // tutto su una riga: $$ x $$
    final end = rest.indexOf(close);
    if (end >= 0) {
      final after = rest.substring(end + close.length).trim();
      final tex = rest.substring(0, end).trim();
      if (after.isNotEmpty || tex.isEmpty) return null;
      return (tex, i);
    }
    // su più righe, fino alla riga che contiene la chiusura
    final body = <String>[if (rest.trim().isNotEmpty) rest];
    for (var j = i + 1; j < lines.length; j++) {
      final l = lines[j];
      final k = l.indexOf(close);
      if (k >= 0) {
        if (l.substring(k + close.length).trim().isNotEmpty) return null;
        final head = l.substring(0, k);
        if (head.trim().isNotEmpty) body.add(head);
        final tex = body.join('\n').trim();
        return tex.isEmpty ? null : (tex, j);
      }
      // una riga vuota interrompe: era un $$ isolato, non una formula
      if (l.trim().isEmpty) return null;
      body.add(l);
    }
    return null;
  }
  return null;
}

bool _isSpace(String c) => c.trim().isEmpty;
bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

/// Il `$` in [i] apre una formula in linea? Regole (come pandoc):
/// - dopo il `$` non c'è uno spazio (`$ 5`, `5 $` restano testo);
/// - `$` seguito da un numero e poi da uno spazio, dalla punteggiatura o
///   dalla fine è una valuta (`$5 al mese`, `costa $10,50.`): non apre;
/// - serve un `$` di chiusura non preceduto da uno spazio e non seguito da
///   una cifra (`$5 e $6` non è una formula).
/// Restituisce l'indice del `$` di chiusura o -1.
int _inlineDollarEnd(String text, int i) {
  final n = text.length;
  if (i + 1 >= n) return -1;
  final next = text[i + 1];
  if (_isSpace(next) || next == r'$') return -1;
  if (_isDigit(next)) {
    var j = i + 1;
    while (j < n && (_isDigit(text[j]) || text[j] == '.' || text[j] == ',')) {
      j++;
    }
    if (j >= n || _isSpace(text[j]) || '!?;:)'.contains(text[j])) return -1;
  }
  for (var j = i + 2; j < n; j++) {
    if (text[j] == '\\') {
      j++; // \$ dentro la formula
      continue;
    }
    if (text[j] != r'$') continue;
    if (_isSpace(text[j - 1])) continue;
    if (j + 1 < n && _isDigit(text[j + 1])) continue;
    return j;
  }
  return -1;
}

/// Solo le formule, il resto è testo semplice (descrizioni e note brevi,
/// dove `*` e `_` restano come sono scritti).
List<MdSpan> parseMathOnly(String text) => parseInline(text, formatting: false);

/// Spezza il testo in tratti con lo stile in linea. Con [formatting] falso
/// riconosce solo le formule.
List<MdSpan> parseInline(String text, {bool formatting = true}) {
  final out = <MdSpan>[];
  var bold = false, italic = false, highlight = false;
  final buf = StringBuffer();

  void emit() {
    if (buf.isEmpty) return;
    out.add(
      MdSpan(buf.toString(), bold: bold, italic: italic, highlight: highlight),
    );
    buf.clear();
  }

  void formula(String tex, {bool display = false}) {
    emit();
    out.add(
      MdSpan(
        tex,
        math: true,
        display: display,
        bold: bold,
        highlight: highlight,
      ),
    );
  }

  var i = 0;
  while (i < text.length) {
    final rest = text.substring(i);
    if (formatting && rest.startsWith('`')) {
      final end = text.indexOf('`', i + 1);
      if (end > i) {
        emit();
        out.add(
          MdSpan(
            text.substring(i + 1, end),
            code: true,
            bold: bold,
            highlight: highlight,
          ),
        );
        i = end + 1;
        continue;
      }
    }
    // \$ = dollaro scritto (mai una formula)
    if (rest.startsWith(r'\$')) {
      buf.write(r'$');
      i += 2;
      continue;
    }
    // \( … \) formula in linea, \[ … \] formula «a sé» nella riga
    if (rest.startsWith(r'\(') || rest.startsWith(r'\[')) {
      final display = rest.startsWith(r'\[');
      final end = text.indexOf(display ? r'\]' : r'\)', i + 2);
      if (end > i + 2 && text.substring(i + 2, end).trim().isNotEmpty) {
        formula(text.substring(i + 2, end).trim(), display: display);
        i = end + 2;
        continue;
      }
    }
    // $$ … $$ dentro una riga di testo: formula in stile «a sé»
    if (rest.startsWith(r'$$')) {
      final end = text.indexOf(r'$$', i + 2);
      if (end > i + 2 && text.substring(i + 2, end).trim().isNotEmpty) {
        formula(text.substring(i + 2, end).trim(), display: true);
        i = end + 2;
        continue;
      }
      // $$ senza chiusura: testo
      buf.write(r'$$');
      i += 2;
      continue;
    }
    if (rest.startsWith(r'$')) {
      final end = _inlineDollarEnd(text, i);
      if (end > i) {
        formula(text.substring(i + 1, end));
        i = end + 1;
        continue;
      }
    }
    if (!formatting) {
      buf.write(text[i]);
      i++;
      continue;
    }
    if (rest.startsWith('**') || rest.startsWith('__')) {
      final marker = rest.substring(0, 2);
      if (bold || text.indexOf(marker, i + 2) > i) {
        emit();
        bold = !bold;
        i += 2;
        continue;
      }
    }
    if (rest.startsWith('==')) {
      if (highlight || text.indexOf('==', i + 2) > i) {
        emit();
        highlight = !highlight;
        i += 2;
        continue;
      }
    }
    final ch = text[i];
    final doubled = i + 1 < text.length && text[i + 1] == ch;
    final afterDouble = i > 0 && text[i - 1] == ch;
    if ((ch == '*' || ch == '_') && !doubled && !afterDouble) {
      final prev = i > 0 ? text[i - 1] : ' ';
      final next = i + 1 < text.length ? text[i + 1] : ' ';
      // "_" dentro una parola (nome_file) non è corsivo.
      final opening =
          !italic &&
          next.trim().isNotEmpty &&
          (ch == '*' || prev.trim().isEmpty || '([{"\''.contains(prev));
      final closing = italic && prev.trim().isNotEmpty;
      if ((opening && text.indexOf(ch, i + 1) > i) || closing) {
        emit();
        italic = !italic;
        i++;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  emit();
  return out;
}

/// Il testo contiene almeno una formula (in linea o a blocco)?
bool hasMath(String text) =>
    parseMarkdown(text)
        .any((b) => b.type == MdBlockType.math || b.spans.any((s) => s.math));
