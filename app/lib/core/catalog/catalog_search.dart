/// Ricerca e filtri sul catalogo pubblico (logica pura, usata
/// dall'onboarding): ricerca "tollerante" degli atenei e dei corsi, regioni
/// per tipo di ateneo, tipi di laurea disponibili.
library;

import 'catalog_models.dart';

const Map<String, String> _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', //
  'ç': 'c', 'ñ': 'n', 'ß': 'ss',
};

/// Minuscolo, senza accenti e punteggiatura, spazi singoli:
/// "Università “Ca’ Foscari”" → "universita ca foscari".
String normalizeText(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final r = _accents[ch] ?? ch;
    final code = r.codeUnitAt(0);
    final alnum =
        (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x7a);
    b.write(alnum || r.length > 1 ? r : ' ');
  }
  return b.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Parole che non servono a distinguere un ateneo.
const Set<String> _stopWords = {
  'di', 'del', 'della', 'degli', 'dei', 'de', 'e', 'la', 'il', 'lo', //
  'per', 'in', 'a', 'da', 'studi', 'l',
};

/// Distanza di Levenshtein limitata (ritorna max+1 se la supera).
int _distance(String a, String b, int max) {
  if ((a.length - b.length).abs() > max) return max + 1;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    var best = cur[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = [
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
      if (cur[j] < best) best = cur[j];
    }
    if (best > max) return max + 1;
    prev = cur;
  }
  return prev[b.length];
}

/// Punteggio di una parola cercata rispetto alle parole di un testo:
/// 0 = assente; più alto = corrispondenza migliore.
int _tokenScore(String token, List<String> words, String joined) {
  var best = 0;
  for (final w in words) {
    if (w == token) return 4;
    if (w.startsWith(token)) best = best < 3 ? 3 : best;
  }
  if (best > 0) return best;
  if (token.length >= 3 && joined.contains(token)) return 2;
  // Errori di battitura: una lettera ogni 5 (es. "bicoca", "pisa" no).
  if (token.length >= 5) {
    final max = token.length >= 9 ? 2 : 1;
    for (final w in words) {
      if (w.length >= 4 && _distance(token, w, max) <= max) return 1;
      if (w.length > token.length &&
          _distance(token, w.substring(0, token.length), max) <= max) {
        return 1;
      }
    }
  }
  return 0;
}

/// Testo indicizzato di un elemento: parole e versione compatta.
class _Indexed {
  _Indexed(Iterable<String?> fields, Iterable<String?> exact)
    : words = [
        for (final f in fields)
          if (f != null) ...normalizeText(f).split(' '),
      ].where((w) => w.isNotEmpty).toList(),
      exact = {
        for (final e in exact)
          if (e != null) normalizeText(e).replaceAll(' ', ''),
      } {
    joined = words.join(' ');
  }
  final List<String> words;
  final Set<String> exact;
  late final String joined;

  /// 0 = non corrisponde. Ogni parola significativa della ricerca deve
  /// trovare corrispondenza.
  int score(String query) {
    final q = normalizeText(query);
    if (q.isEmpty) return 0;
    final compact = q.replaceAll(' ', '');
    if (exact.contains(compact)) return 1000;
    var tokens = q.split(' ').where((t) => !_stopWords.contains(t)).toList();
    if (tokens.isEmpty) tokens = q.split(' ');
    var total = 0;
    for (final t in tokens) {
      final s = _tokenScore(t, words, joined);
      if (s == 0) {
        // "unito" ≈ "uni" + "to": vale anche la sigla/id che inizia così.
        if (exact.any((e) => e.startsWith(compact) && compact.length >= 3)) {
          return 500;
        }
        return 0;
      }
      total += s;
    }
    return total * 10 - words.length ~/ 4;
  }
}

/// Ricerca degli atenei per nome, sigla, id, città e regione, senza accenti
/// e con piccoli errori di battitura ("polito", "bicocca", "Napoli").
List<Ateneo> searchAtenei(
  Iterable<Ateneo> atenei,
  String query, {
  int limit = 30,
}) {
  final scored = <(Ateneo, int)>[];
  for (final a in atenei) {
    final idx = _Indexed(
      [a.nome, a.sigla, a.id, ...a.citta, ...a.regioni, a.tipo.label],
      [a.id, a.sigla],
    );
    final s = idx.score(query);
    if (s > 0) scored.add((a, s));
  }
  scored.sort((x, y) {
    final c = y.$2.compareTo(x.$2);
    return c != 0 ? c : x.$1.nome.compareTo(y.$1.nome);
  });
  return [for (final e in scored.take(limit)) e.$1];
}

/// Atenei di un tipo, ordinati per nome.
List<Ateneo> ateneiDiTipo(Iterable<Ateneo> atenei, TipoAteneo tipo) => [
  for (final a in atenei)
    if (a.tipo == tipo) a,
]..sort((a, b) => normalizeText(a.nome).compareTo(normalizeText(b.nome)));

/// Regioni con almeno un ateneo di [tipo]: un ateneo con sedi in più regioni
/// compare in ciascuna. Ordine alfabetico.
List<String> regioniPerTipo(Iterable<Ateneo> atenei, TipoAteneo tipo) {
  final set = <String>{
    for (final a in atenei)
      if (a.tipo == tipo) ...a.regioni,
  };
  return set.toList()
    ..sort((a, b) => normalizeText(a).compareTo(normalizeText(b)));
}

/// Il tipo di ateneo non ha la scelta della regione (telematiche).
bool tipoSenzaRegione(TipoAteneo t) => t == TipoAteneo.telematica;

/// Atenei di [tipo] presenti in [regione] (null = tutte le regioni).
List<Ateneo> ateneiPer(
  Iterable<Ateneo> atenei,
  TipoAteneo tipo, {
  String? regione,
}) => [
  for (final a in ateneiDiTipo(atenei, tipo))
    if (regione == null || a.regioni.contains(regione)) a,
];

/// Tipi di laurea da proporre per un ateneo: quelli presenti nell'indice,
/// nell'ordine L, LP, LM, LMCU, più sempre "Altro" (anche inserimento a mano).
List<TipoCorso> tipiCorsoDisponibili(IndiceCorsi indice, String ateneoId) {
  final present = {for (final c in indice.ofAteneo(ateneoId)) c.tipo};
  return [
    for (final t in TipoCorso.values)
      if (t == TipoCorso.altro || present.contains(t)) t,
  ];
}

/// Corsi di un ateneo e tipo, filtrati dalla ricerca (nome, classe, sede).
List<CorsoIndice> corsiPer(
  IndiceCorsi indice,
  String ateneoId,
  TipoCorso tipo, {
  String query = '',
}) {
  final list = [
    for (final c in indice.ofAteneo(ateneoId))
      if (c.tipo == tipo) c,
  ];
  if (query.trim().isEmpty) {
    return list
      ..sort((a, b) => normalizeText(a.nome).compareTo(normalizeText(b.nome)));
  }
  final scored = <(CorsoIndice, int)>[];
  for (final c in list) {
    final idx = _Indexed(
      [c.nome, c.classe, c.sede, c.lingua == 'en' ? 'english inglese' : null],
      [c.classe, c.id],
    );
    final s = idx.score(query);
    if (s > 0) scored.add((c, s));
  }
  scored.sort((x, y) {
    final c = y.$2.compareTo(x.$2);
    return c != 0 ? c : x.$1.nome.compareTo(y.$1.nome);
  });
  return [for (final e in scored) e.$1];
}
