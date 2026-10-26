/// Nome di un insegnamento del database senza i CFU e senza il codice
/// dell'insegnamento: «Analisi matematica I (10 CFU) (16ACFYO)» → «Analisi
/// matematica I», «Business Plan - 6 Cfu» → «Business Plan», «Storia (cod.
/// 120851)» → «Storia». È la regola del database (`nome_insegnamento_pulito` in
/// `tools/db_builder/pulizia.py`, vedi docs/database_format.md) in forma
/// ridotta: serve per gli insegnamenti importati prima della pulizia del
/// database che «Aggiorna database» non rinomina (versione in inglese scelta
/// dallo studente, insegnamenti modificati a mano). Le parti con un
/// significato restano («(modulo A)», «(A-L)», «(livello B1)», «(c.i.)», «(I)»,
/// «(fra 6 e 12 CFU)»), come i numeri senza unità («(2)»). Il database tiene
/// «(N CFU)» solo per distinguere due omonimi dello stesso anno con CFU
/// diversi: l'importatore confronta i nomi ripuliti e prende quello del
/// database, così «(N CFU)» resta dove serve.
library;

const _num = r'\d+(?:[.,]\d+)?';
const _unita = r'(?:c\.\s?f\.\s?u\.?|cfu|crediti|credits?|ects)';

/// Una parte che è solo un numero di CFU: «6 CFU», «7.5 cfu», «CFU 6».
final _cfuSolo = RegExp(
  r'^\s*(?:' + _num + r'\s*' + _unita + r'|(?:cfu|crediti)\s*[:=]?\s*' + _num + r')\s*$',
  caseSensitive: false,
);

/// CFU in coda senza parentesi («Idoneità 9 Cfu»), non dopo «da», «fra», …
final _cfuCoda = RegExp(
  r'(?<=\S)\s+(?:' + _num + r'\s*' + _unita + r'|cfu\s*' + _num + r')\s*$',
  caseSensitive: false,
);
final _preposizioneFinale = RegExp(
  r'(?:^|\s)(?:da|di|fra|tra|e|ed|a|ai|al|per|con|su|of|from|to|and|or|o)\s*$',
  caseSensitive: false,
);
final _cfuNelTesto = RegExp(
  r'\b' + _num + r'\s*' + _unita + r'(?![a-z])',
  caseSensitive: false,
);

/// «cod. 12345», «codice A000123».
final _codiceEsplicito = RegExp(
  r'^\s*(?:cod(?:ice)?|code)\s*[.:]?\s*([A-Za-z0-9][A-Za-z0-9/._-]{1,24})\s*$',
  caseSensitive: false,
);

/// Sigla prima del nome (Roma Tre: «Am110 - Analisi Matematica 1»).
final _sigla = RegExp(r'^[A-Z][a-z]{0,2}\d{3}$');
final _gruppo = RegExp(r'\s*\(([^()\[\]]*)\)|\s*\[([^()\[\]]*)\]');
final _separatoreParti = RegExp(r'\s*[,;]\s*|\s+[-–—]\s+');
final _prefisso = RegExp(r'^\s*([A-Za-z0-9][A-Za-z0-9/._]{1,24})\s*[-–—]\s*(?=\S)');
final _cifra = RegExp(r'\d');
final _spazi = RegExp(r'\s+');

/// [s] è uno dei [codici] dell'insegnamento (almeno 3 caratteri; un codice
/// senza cifre conta solo scritto in maiuscolo come il codice).
bool _codiceUguale(String s, Iterable<String?> codici) {
  final t = s.replaceAll(_spazi, '');
  if (t.length < 3) return false;
  for (final c0 in codici) {
    final c = (c0 ?? '').replaceAll(_spazi, '');
    if (c.isEmpty) continue;
    if (_cifra.hasMatch(c) && t.toLowerCase() == c.toLowerCase()) return true;
    if (!_cifra.hasMatch(c) && t == c && t == t.toUpperCase()) return true;
  }
  return false;
}

bool _rumore(String parte, Iterable<String?> codici) {
  if (_cfuSolo.hasMatch(parte)) return true;
  if (_codiceUguale(parte, codici)) return true;
  final m = _codiceEsplicito.firstMatch(parte);
  return m != null && _cifra.hasMatch(m.group(1)!);
}

/// Contenuto di un gruppo tra parentesi senza le parti di rumore; null se era
/// solo rumore.
String? _senzaParti(String contenuto, Iterable<String?> codici) {
  final parti = <(String, String)>[]; // (separatore prima, parte)
  var inizio = 0;
  var sep = '';
  for (final m in _separatoreParti.allMatches(contenuto)) {
    parti.add((sep, contenuto.substring(inizio, m.start)));
    sep = m.group(0)!;
    inizio = m.end;
  }
  parti.add((sep, contenuto.substring(inizio)));
  final piene = [
    for (final p in parti)
      if (p.$2.trim().isNotEmpty) p,
  ];
  final tenute = [
    for (final p in piene)
      if (!_rumore(p.$2, codici)) p,
  ];
  if (tenute.isEmpty) return null;
  if (tenute.length == piene.length) return contenuto;
  return tenute.first.$2.trim() +
      [for (final p in tenute.skip(1)) '${p.$1}${p.$2}'].join();
}

/// Parti del nome separate da « - » fuori dalle parentesi.
List<String> _segmenti(String s) {
  final out = <String>[];
  var prof = 0, inizio = 0;
  for (var k = 0; k < s.length; k++) {
    final ch = s[k];
    if (ch == '(' || ch == '[') {
      prof++;
    } else if ((ch == ')' || ch == ']') && prof > 0) {
      prof--;
    } else if (prof == 0 &&
        (ch == '-' || ch == '–' || ch == '—') &&
        k > 0 &&
        s[k - 1] == ' ' &&
        k + 1 < s.length &&
        s[k + 1] == ' ') {
      out.add(s.substring(inizio, k - 1));
      inizio = k + 2;
      k++;
    }
  }
  out.add(s.substring(inizio));
  return out;
}

/// [nome] senza i CFU e senza i [codici] dell'insegnamento (vedi sopra).
String nomeInsegnamentoPulito(
  String nome, {
  Iterable<String?> codici = const [],
}) {
  var s = nome.replaceAllMapped(_gruppo, (m) {
    final contenuto = m.group(1) ?? m.group(2)!;
    final resto = _senzaParti(contenuto, codici);
    if (resto == null) return '';
    if (resto == contenuto) return m.group(0)!;
    final tutto = m.group(0)!;
    final spazio = tutto.substring(0, tutto.length - tutto.trimLeft().length);
    return m.group(1) != null ? '$spazio($resto)' : '$spazio[$resto]';
  });
  final seg = _segmenti(s);
  if (seg.length > 1) {
    final piene = [
      for (final x in seg)
        if (x.trim().isNotEmpty) x,
    ];
    final tenuti = <String>[];
    for (final (k, x) in seg.indexed) {
      if (x.trim().isEmpty || _rumore(x, codici)) continue;
      if (k == 0 && _sigla.hasMatch(x.trim())) continue;
      tenuti.add(x.trim());
    }
    if (tenuti.isNotEmpty && tenuti.length < piene.length) {
      s = tenuti.join(' - ');
    }
  }
  final p = _prefisso.firstMatch(s);
  if (p != null &&
      (_codiceUguale(p.group(1)!, codici) || _sigla.hasMatch(p.group(1)!)) &&
      s.substring(p.end).trim().isNotEmpty) {
    s = s.substring(p.end);
    s = s[0].toUpperCase() + s.substring(1);
  }
  final c = _cfuCoda.firstMatch(s);
  if (c != null) {
    final prima = s.substring(0, c.start);
    if (!_preposizioneFinale.hasMatch(prima) &&
        prima.trim().length >= 3 &&
        !_cfuNelTesto.hasMatch(prima)) {
      s = prima;
    }
  }
  if (s == nome) return nome;
  s = s
      .replaceAll(_spazi, ' ')
      .replaceAllMapped(RegExp(r'\s+([,;:.)\]])'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'^[\s\-–—,;:]+|[\s\-–—,;:]+$'), '');
  if (s.length < 2 || !RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(s)) return nome;
  return s;
}
