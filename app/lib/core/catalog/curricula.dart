import 'catalog_models.dart';

/// Percorsi di un corso di laurea (curricula, orientamenti, percorsi
/// speciali, sedi del primo anno). Nel catalogo ogni insegnamento indica in
/// `curriculum` l'elenco, separato da virgole, dei percorsi a cui
/// appartiene (es. «Percorso, Percorso INTRAPRENDENTI»); senza indicazione
/// vale per tutti. Lo studente segue un solo percorso: gli insegnamenti
/// degli altri (es. «Lingua cinese» del solo orientamento Shanghai) non
/// entrano nel suo piano.

/// Nomi dei percorsi comuni a tutti (insegnamenti sempre nel piano).
final _comune = RegExp(
  r'\b(comune|non diversificato|generico|unico|common)\b',
  caseSensitive: false,
);

/// Separa l'elenco dei percorsi sulle virgole fuori dalle parentesi.
Set<String> percorsiDi(String? curriculum) {
  final s = curriculum?.trim();
  if (s == null || s.isEmpty) return const {};
  final out = <String>{};
  var depth = 0;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '(') depth++;
    if (ch == ')' && depth > 0) depth--;
    if (ch == ',' && depth == 0) {
      final part = s.substring(start, i).trim();
      if (part.isNotEmpty) out.add(part);
      start = i + 1;
    }
  }
  final last = s.substring(start).trim();
  if (last.isNotEmpty) out.add(last);
  return out;
}

bool _comuneATutti(String percorso) => _comune.hasMatch(percorso);

/// Percorsi tra cui scegliere in un corso di laurea, dal più seguito
/// (quello con più insegnamenti, il predefinito) al meno seguito.
class PercorsiCorso {
  const PercorsiCorso(this.scelte);

  /// Vuoto o con un solo elemento: non c'è nulla da scegliere.
  final List<String> scelte;

  bool get daScegliere => scelte.length > 1;

  String? get predefinito => scelte.firstOrNull;

  /// [scelto] valido per questo corso, altrimenti il predefinito.
  String? valido(String? scelto) =>
      scelto != null && scelte.contains(scelto) ? scelto : predefinito;

  /// L'insegnamento fa parte del piano di chi segue [scelto].
  bool include(Insegnamento i, String? scelto) {
    final p = percorsiDi(i.curriculum);
    if (p.isEmpty || p.any(_comuneATutti)) return true;
    // unito da più canali, sedi o percorsi: il database conserva i percorsi
    // di uno solo, quindi vale per tutti
    if (i.codiciAlternativi.isNotEmpty) return true;
    final s = valido(scelto);
    return s == null || p.contains(s);
  }

  factory PercorsiCorso.di(CorsoDettaglio corso) {
    final n = <String, int>{};
    for (final i in corso.insegnamenti) {
      for (final p in percorsiDi(i.curriculum)) {
        if (_comuneATutti(p)) continue;
        n[p] = (n[p] ?? 0) + 1;
      }
    }
    final list = n.keys.toList()
      ..sort((a, b) {
        final c = n[b]!.compareTo(n[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return PercorsiCorso(list);
  }
}

/// Lo stesso corso con i soli insegnamenti del percorso [scelto].
CorsoDettaglio soloPercorso(CorsoDettaglio corso, String? scelto) {
  final p = PercorsiCorso.di(corso);
  if (!p.daScegliere) return corso;
  return CorsoDettaglio(
    id: corso.id,
    nome: corso.nome,
    tipo: corso.tipo,
    classe: corso.classe,
    durataAnni: corso.durataAnni,
    sede: corso.sede,
    lingua: corso.lingua,
    accesso: corso.accesso,
    url: corso.url,
    curricula: corso.curricula,
    ammissione: corso.ammissione,
    stato: corso.stato,
    fonte: corso.fonte,
    insegnamenti: [
      for (final i in corso.insegnamenti)
        if (p.include(i, scelto)) i,
    ],
  );
}
