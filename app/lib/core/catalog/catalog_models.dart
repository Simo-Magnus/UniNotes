/// Modelli del database pubblico degli atenei (formato v1, vedi
/// `docs/database_format.md`): `universita.json`, `indice_corsi.json`,
/// `corsi/<id>.json`, `meta.json`, `corsi_sostituiti.json`.
///
/// Il parsing è tollerante: un campo mancante o di tipo inatteso diventa null
/// (mai inventato), una voce senza id viene saltata.
library;

import '../../utils/parse.dart';

/// Versione del formato supportata dall'app.
const int kCatalogSchema = 1;

class CatalogFormatException implements Exception {
  CatalogFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

List<Map<String, Object?>> _maps(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is Map) e.cast<String, Object?>(),
      ]
    : const [];

List<String> _strings(Object? v) => v is List
    ? [
        for (final e in v)
          if (asString(e) != null) asString(e)!,
      ]
    : const [];

Map<String, Object?> _root(Object? json, String file) {
  if (json is! Map) {
    throw CatalogFormatException('$file non valido: atteso un oggetto JSON.');
  }
  final m = json.cast<String, Object?>();
  final schema = asInt(m['schema']) ?? kCatalogSchema;
  if (schema > kCatalogSchema) {
    throw CatalogFormatException(
      '$file usa il formato $schema: aggiorna l\'app per leggerlo.',
    );
  }
  return m;
}

// ------------------------------------------------------------ universita.json

/// Tipo di ateneo secondo le quattro pagine del MUR.
enum TipoAteneo {
  statale('statale', 'Statale', 'Università statali'),
  nonStatale(
    'non_statale',
    'Non statale riconosciuta',
    'Università non statali riconosciute',
  ),
  ordinamentoSpeciale(
    'ordinamento_speciale',
    'Istituto a ordinamento speciale',
    'Scuole superiori e istituti a ordinamento speciale',
  ),
  telematica('telematica', 'Telematica', 'Università telematiche');

  const TipoAteneo(this.key, this.label, this.description);
  final String key;
  final String label;
  final String description;

  static TipoAteneo? fromKey(String? k) {
    for (final v in values) {
      if (v.key == k) return v;
    }
    return null;
  }
}

class SedeAteneo {
  const SedeAteneo({this.regione, this.citta, this.sito, this.nomeMur});
  final String? regione;
  final String? citta;
  final String? sito;
  final String? nomeMur;

  factory SedeAteneo.fromJson(Map<String, Object?> m) => SedeAteneo(
    regione: asString(m['regione']),
    citta: asString(m['citta']),
    sito: asString(m['sito']),
    nomeMur: asString(m['nome_mur']),
  );
}

class Ateneo {
  const Ateneo({
    required this.id,
    required this.nome,
    required this.tipo,
    this.sigla,
    this.regioni = const [],
    this.sedi = const [],
    this.sito,
  });

  final String id;
  final String nome;
  final String? sigla;
  final TipoAteneo tipo;

  /// Vuoto per le telematiche.
  final List<String> regioni;
  final List<SedeAteneo> sedi;
  final String? sito;

  /// Nome breve da mostrare (sigla, altrimenti il nome).
  String get nomeBreve => sigla ?? nome;

  /// Città delle sedi, senza ripetizioni ("Roma · Taranto · Palermo").
  List<String> get citta => [
    for (final c in {for (final s in sedi) ?s.citta}) c,
  ];

  /// Città delle sedi in [regione] (tutte se null).
  List<String> cittaIn(String? regione) => [
    for (final c in {
      for (final s in sedi)
        if (regione == null || s.regione == regione) ?s.citta,
    })
      c,
  ];

  static Ateneo? fromJson(Map<String, Object?> m) {
    final id = asString(m['id']);
    final nome = asString(m['nome']);
    final tipo = TipoAteneo.fromKey(asString(m['tipo']));
    if (id == null || nome == null || tipo == null) return null;
    return Ateneo(
      id: id,
      nome: nome,
      sigla: asString(m['sigla']),
      tipo: tipo,
      regioni: _strings(m['regioni']),
      sedi: [for (final s in _maps(m['sedi'])) SedeAteneo.fromJson(s)],
      sito: asString(m['sito']),
    );
  }
}

/// Contenuto di `universita.json`.
class UniversitaCatalog {
  const UniversitaCatalog({
    required this.universita,
    this.regioni = const [],
    this.conteggi = const {},
    this.generatoIl,
  });

  final List<Ateneo> universita;
  final List<String> regioni;
  final Map<String, int> conteggi;
  final String? generatoIl;

  Ateneo? byId(String id) {
    for (final a in universita) {
      if (a.id == id) return a;
    }
    return null;
  }

  factory UniversitaCatalog.fromJson(Object? json) {
    final m = _root(json, 'universita.json');
    final list = [for (final u in _maps(m['universita'])) ?Ateneo.fromJson(u)];
    final counts = m['conteggi'];
    return UniversitaCatalog(
      universita: list,
      regioni: _strings(m['regioni']),
      conteggi: {
        if (counts is Map)
          for (final e in counts.entries)
            if (asInt(e.value) != null) e.key.toString(): asInt(e.value)!,
      },
      generatoIl: asString(m['generato_il']),
    );
  }
}

// --------------------------------------------------------- indice_corsi.json

/// Tipo di corso di studio.
enum TipoCorso {
  l('L', 'Laurea (triennale)', '3 anni, 180 CFU', 3),
  lp('LP', 'Laurea professionalizzante', '3 anni, 180 CFU', 3),
  lm('LM', 'Laurea magistrale', '2 anni, 120 CFU', 2),
  lmcu(
    'LMCU',
    'Laurea magistrale a ciclo unico',
    '5 o 6 anni (300 o 360 CFU)',
    5,
  ),
  altro(
    'altro',
    'Altro',
    'Dottorato, Master, corsi ordinari delle scuole superiori',
    null,
  );

  const TipoCorso(this.key, this.label, this.description, this.durataTipica);
  final String key;
  final String label;
  final String description;

  /// Durata normale in anni (null = variabile).
  final int? durataTipica;

  static TipoCorso fromKey(String? k) {
    final up = k?.trim().toUpperCase();
    for (final v in values) {
      if (v.key.toUpperCase() == up) return v;
    }
    return TipoCorso.altro;
  }
}

/// Una riga di `indice_corsi.json`:
/// `[id_ateneo, id_corso, nome, tipo, classe, durata_anni, sede, lingua]`.
class CorsoIndice {
  const CorsoIndice({
    required this.ateneoId,
    required this.id,
    required this.nome,
    required this.tipo,
    this.classe,
    this.durataAnni,
    this.sede,
    this.lingua,
  });

  final String ateneoId;
  final String id;
  final String nome;
  final TipoCorso tipo;
  final String? classe;
  final int? durataAnni;
  final String? sede;
  final String? lingua;

  static CorsoIndice? fromRow(Object? row) {
    if (row is List) {
      String? at(int i) => i < row.length ? asString(row[i]) : null;
      final ateneo = at(0), id = at(1), nome = at(2);
      if (ateneo == null || id == null || nome == null) return null;
      return CorsoIndice(
        ateneoId: ateneo,
        id: id,
        nome: nome,
        tipo: TipoCorso.fromKey(at(3)),
        classe: at(4),
        durataAnni: row.length > 5 ? asInt(row[5]) : null,
        sede: at(6),
        lingua: at(7),
      );
    }
    // Tollerato anche come oggetto.
    if (row is Map) {
      final m = row.cast<String, Object?>();
      final ateneo = asString(m['universita_id'] ?? m['ateneo']);
      final id = asString(m['id']);
      final nome = asString(m['nome']);
      if (ateneo == null || id == null || nome == null) return null;
      return CorsoIndice(
        ateneoId: ateneo,
        id: id,
        nome: nome,
        tipo: TipoCorso.fromKey(asString(m['tipo'])),
        classe: asString(m['classe']),
        durataAnni: asInt(m['durata_anni']),
        sede: asString(m['sede']),
        lingua: asString(m['lingua']),
      );
    }
    return null;
  }
}

class IndiceCorsi {
  const IndiceCorsi({required this.corsi, this.annoAccademico});
  final List<CorsoIndice> corsi;
  final String? annoAccademico;

  static const empty = IndiceCorsi(corsi: []);

  factory IndiceCorsi.fromJson(Object? json) {
    final m = _root(json, 'indice_corsi.json');
    final rows = m['corsi'];
    return IndiceCorsi(
      corsi: [
        if (rows is List)
          for (final r in rows) ?CorsoIndice.fromRow(r),
      ],
      annoAccademico: asString(m['anno_accademico']),
    );
  }

  List<CorsoIndice> ofAteneo(String ateneoId) => [
    for (final c in corsi)
      if (c.ateneoId == ateneoId) c,
  ];
}

// --------------------------------------------------------- corsi/<id>.json

class LibroCatalogo {
  const LibroCatalogo({
    required this.titolo,
    this.autori,
    this.editore,
    this.anno,
    this.edizione,
    this.isbn,
    this.lingua,
    this.obbligatorio,
    this.note,
    this.citazione,
  });

  final String titolo;
  final String? autori;
  final String? editore;
  final int? anno;
  final String? edizione;
  final String? isbn;
  final String? lingua;

  /// true = obbligatorio, false = consigliato, null = non indicato.
  final bool? obbligatorio;
  final String? note;

  /// Riferimento come scritto nel syllabus (libri estratti automaticamente).
  final String? citazione;

  static LibroCatalogo? fromJson(Map<String, Object?> m) {
    final titolo = asString(m['titolo']);
    if (titolo == null) return null;
    final tipo = asString(m['tipo']);
    return LibroCatalogo(
      titolo: titolo,
      autori: asString(m['autori']),
      editore: asString(m['editore']),
      anno: asInt(m['anno']),
      edizione: asString(m['edizione']),
      isbn: asString(m['isbn']),
      lingua: asString(m['lingua']),
      obbligatorio: switch (tipo) {
        'obbligatorio' => true,
        'consigliato' => false,
        _ => null,
      },
      note: asString(m['note']),
      citazione: asString(m['citazione']),
    );
  }
}

class EsameCatalogo {
  const EsameCatalogo({
    required this.provaInItinere,
    this.titolo,
    this.data,
    this.ora,
    this.luogo,
    this.modalita,
    this.note,
    this.fonte,
  });

  /// false = appello, true = prova in itinere.
  final bool provaInItinere;
  final String? titolo;

  /// "2027-01-20"
  final String? data;

  /// "09:00"
  final String? ora;
  final String? luogo;
  final String? modalita;
  final String? note;
  final String? fonte;

  DateTime? get giorno => asDateTime(data);

  factory EsameCatalogo.fromJson(Map<String, Object?> m) => EsameCatalogo(
    provaInItinere: asString(m['tipo']) == 'prova_in_itinere',
    titolo: asString(m['titolo']),
    data: asString(m['data']),
    ora: asString(m['ora']),
    luogo: asString(m['luogo']),
    modalita: asString(m['modalita']),
    note: asString(m['note']),
    fonte: asString(m['fonte']),
  );
}

/// Stati dei dati del catalogo (`stato_libri`, `stato_esami`, `stato`).
abstract final class StatoDati {
  static const completo = 'completo';
  static const parziale = 'parziale';
  static const daAggiungere = 'da_aggiungere';
  static const nessunLibro = 'nessun_libro';
}

class Insegnamento {
  const Insegnamento({
    required this.id,
    required this.nome,
    this.codice,
    this.anno,
    this.periodo,
    this.cfu,
    this.ssd,
    this.obbligatorio,
    this.curriculum,
    this.docenti = const [],
    this.url,
    this.modalitaEsame,
    this.libri = const [],
    this.statoLibri = StatoDati.daAggiungere,
    this.esami = const [],
    this.statoEsami = StatoDati.daAggiungere,
    this.fonte,
    this.varianti = const [],
    this.codiciAlternativi = const [],
  });

  /// Versioni in altra lingua dello stesso insegnamento (es. inglese).
  final List<VarianteLingua> varianti;

  /// Codici dello stesso insegnamento in altri canali, sedi o percorsi
  /// (uniti in uno solo dal database).
  final List<String> codiciAlternativi;

  final String id;
  final String nome;
  final String? codice;

  /// Anno di corso (1..durata_anni); null se sconosciuto.
  final int? anno;
  final String? periodo;
  final double? cfu;
  final String? ssd;

  /// false = a scelta.
  final bool? obbligatorio;
  final String? curriculum;
  final List<String> docenti;
  final String? url;

  /// Modalità d'esame dal syllabus ("scritto", "orale", …).
  final String? modalitaEsame;
  final List<LibroCatalogo> libri;
  final String statoLibri;
  final List<EsameCatalogo> esami;
  final String statoEsami;
  final String? fonte;

  static Insegnamento? fromJson(Map<String, Object?> m) {
    final id = asString(m['id']);
    final nome = asString(m['nome']);
    if (id == null || nome == null) return null;
    return Insegnamento(
      id: id,
      nome: nome,
      codice: asString(m['codice']),
      anno: asInt(m['anno']),
      periodo: asString(m['periodo']),
      cfu: asDouble(m['cfu']),
      ssd: asString(m['ssd']),
      obbligatorio: asBool(m['obbligatorio']),
      curriculum: asString(m['curriculum']),
      codiciAlternativi: _strings(m['codici_alternativi']),
      docenti: _strings(m['docenti']),
      url: asString(m['url']),
      modalitaEsame: asString(m['modalita_esame']),
      libri: [for (final l in _maps(m['libri'])) ?LibroCatalogo.fromJson(l)],
      statoLibri: asString(m['stato_libri']) ?? StatoDati.daAggiungere,
      esami: [for (final e in _maps(m['esami'])) EsameCatalogo.fromJson(e)],
      statoEsami: asString(m['stato_esami']) ?? StatoDati.daAggiungere,
      fonte: asString(m['fonte']),
      varianti: [
        for (final v in _maps(m['varianti'])) VarianteLingua.fromJson(v),
      ],
    );
  }
}

/// Versione in un'altra lingua di un insegnamento (es. PoliTO: «Mathematical
/// analysis I» per «Analisi matematica I»): codice, docenti, pagina e libri
/// propri; lo studente la sceglie dalla modifica del corso.
class VarianteLingua {
  const VarianteLingua({
    required this.lingua,
    this.codice,
    this.nome,
    this.docenti = const [],
    this.url,
    this.libri = const [],
  });

  final String lingua;
  final String? codice;
  final String? nome;
  final List<String> docenti;
  final String? url;
  final List<LibroCatalogo> libri;

  static VarianteLingua fromJson(Map<String, Object?> m) => VarianteLingua(
    lingua: asString(m['lingua']) ?? 'en',
    codice: asString(m['codice']),
    nome: asString(m['nome']),
    docenti: _strings(m['docenti']),
    url: asString(m['url']),
    libri: [for (final l in _maps(m['libri'])) ?LibroCatalogo.fromJson(l)],
  );
}

/// Requisiti di accesso di un corso di studio (quadro A3 della SUA-CdS): il
/// testo dell'ateneo e ciò che dice esplicitamente su test, OFA e inglese.
class Ammissione {
  const Ammissione({
    this.accesso,
    this.requisiti,
    this.test = const [],
    this.ofa,
    this.livelloInglese,
    this.fonte,
  });

  final String? accesso;
  final String? requisiti;
  final List<String> test;

  /// true: previsti OFA; false: il testo dice che non ce ne sono; null: non ne parla.
  final bool? ofa;
  final String? livelloInglese;
  final String? fonte;

  bool get vuota =>
      accesso == null &&
      requisiti == null &&
      test.isEmpty &&
      ofa == null &&
      livelloInglese == null;

  static Ammissione? fromJson(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, Object?>();
    final a = Ammissione(
      accesso: asString(m['accesso']),
      requisiti: asString(m['requisiti']),
      test: _strings(m['test']),
      ofa: asBool(m['ofa']),
      livelloInglese: asString(m['livello_inglese']),
      fonte: asString(m['fonte']),
    );
    return a.vuota ? null : a;
  }
}

/// Percorso classico di un corso con più percorsi (`percorso_classico` nel
/// database): quello che segue la maggior parte degli studenti, già scelto.
/// [criterio]: `nome` (nome da piano ordinario, es. «Percorso», «Generale»,
/// «Statutario»), `unico_ordinario` (l'unico senza percorsi speciali) o
/// `piu_insegnamenti` (percorsi tematici: quello con più insegnamenti).
class PercorsoClassico {
  const PercorsoClassico(this.nome, this.criterio);

  final String nome;
  final String criterio;

  /// È davvero il percorso «normale» (non solo quello con più insegnamenti).
  bool get classico => criterio == 'nome' || criterio == 'unico_ordinario';

  static PercorsoClassico? fromJson(Object? json) {
    if (json is! Map) return null;
    final nome = asString(json['nome']);
    if (nome == null) return null;
    return PercorsoClassico(nome, asString(json['criterio']) ?? '');
  }
}

class CorsoDettaglio {
  const CorsoDettaglio({
    required this.id,
    required this.nome,
    required this.tipo,
    this.classe,
    this.durataAnni,
    this.sede,
    this.lingua,
    this.accesso,
    this.url,
    this.curricula = const [],
    this.ammissione,
    this.stato = StatoDati.daAggiungere,
    this.fonte,
    this.insegnamenti = const [],
    this.percorsoClassico,
  });

  final String id;
  final String nome;
  final TipoCorso tipo;
  final String? classe;
  final int? durataAnni;
  final String? sede;
  final String? lingua;
  final String? accesso;
  final String? url;
  final List<String> curricula;
  final Ammissione? ammissione;
  final String stato;
  final String? fonte;
  final List<Insegnamento> insegnamenti;

  /// Percorso da proporre già scelto (corsi con più percorsi).
  final PercorsoClassico? percorsoClassico;

  static CorsoDettaglio? fromJson(Map<String, Object?> m) {
    final id = asString(m['id']);
    final nome = asString(m['nome']);
    if (id == null || nome == null) return null;
    return CorsoDettaglio(
      id: id,
      nome: nome,
      tipo: TipoCorso.fromKey(asString(m['tipo'])),
      classe: asString(m['classe']),
      durataAnni: asInt(m['durata_anni']),
      sede: asString(m['sede']),
      lingua: asString(m['lingua']),
      accesso: asString(m['accesso']),
      url: asString(m['url']),
      curricula: _strings(m['curricula']),
      ammissione: Ammissione.fromJson(m['ammissione']),
      stato: asString(m['stato']) ?? StatoDati.daAggiungere,
      fonte: asString(m['fonte']),
      insegnamenti: [
        for (final i in _maps(m['insegnamenti'])) ?Insegnamento.fromJson(i),
      ],
      percorsoClassico: PercorsoClassico.fromJson(m['percorso_classico']),
    );
  }
}

/// Contenuto di `per_corso/<ateneo>/<corso>.json` (un solo corso in
/// [corsi]) o di `corsi/<ateneo>.json` (tutti i corsi, file delle versioni
/// precedenti).
class CorsiAteneo {
  const CorsiAteneo({
    required this.universitaId,
    required this.corsi,
    this.annoAccademico,
    this.aggiornatoIl,
    this.fonte,
  });

  final String universitaId;
  final String? annoAccademico;
  final String? aggiornatoIl;
  final String? fonte;
  final List<CorsoDettaglio> corsi;

  CorsoDettaglio? corso(String id) {
    for (final c in corsi) {
      if (c.id == id) return c;
    }
    return null;
  }

  factory CorsiAteneo.fromJson(Object? json) {
    final m = _root(json, 'corsi/<ateneo>.json');
    final uni = asString(m['universita_id']);
    if (uni == null) {
      throw CatalogFormatException('File dei corsi senza universita_id.');
    }
    return CorsiAteneo(
      universitaId: uni,
      annoAccademico: asString(m['anno_accademico']),
      aggiornatoIl: asString(m['aggiornato_il']),
      fonte: asString(m['fonte']),
      corsi: [for (final c in _maps(m['corsi'])) ?CorsoDettaglio.fromJson(c)],
    );
  }
}

// ------------------------------------------------------------- meta.json

class MetaAteneo {
  const MetaAteneo({
    this.corsi,
    this.insegnamenti,
    this.libri,
    this.esami,
    this.file,
    this.sha256,
    this.perCorso,
    this.sha256PerCorso,
  });
  final int? corsi;
  final int? insegnamenti;
  final int? libri;
  final int? esami;
  final String? file;
  final String? sha256;

  /// Indice dei file per corso (`per_corso/<ateneo>/indice.json`) e sua
  /// impronta: se non cambia, nessun corso dell'ateneo è cambiato.
  final String? perCorso;
  final String? sha256PerCorso;

  factory MetaAteneo.fromJson(Map<String, Object?> m) => MetaAteneo(
    corsi: asInt(m['corsi']),
    insegnamenti: asInt(m['insegnamenti']),
    libri: asInt(m['libri']),
    esami: asInt(m['esami']),
    file: asString(m['file']),
    sha256: asString(m['sha256']),
    perCorso: asString(m['per_corso']),
    sha256PerCorso: asString(m['sha256_per_corso']),
  );
}

class DatabaseMeta {
  const DatabaseMeta({
    this.versione,
    this.annoAccademico,
    this.generatoIl,
    this.atenei = const {},
  });

  /// "AAAA.MM.GG" della generazione.
  final String? versione;
  final String? annoAccademico;
  final String? generatoIl;
  final Map<String, MetaAteneo> atenei;

  factory DatabaseMeta.fromJson(Object? json) {
    final m = _root(json, 'meta.json');
    final atenei = m['atenei'];
    return DatabaseMeta(
      versione: asString(m['versione']),
      annoAccademico: asString(m['anno_accademico']),
      generatoIl: asString(m['generato_il']),
      atenei: {
        if (atenei is Map)
          for (final e in atenei.entries)
            if (e.value is Map)
              e.key.toString(): MetaAteneo.fromJson(
                (e.value as Map).cast<String, Object?>(),
              ),
      },
    );
  }
}

// ------------------------------------------------ corsi_sostituiti.json

/// Un corso di laurea eliminato dal catalogo perché doppione di un altro.
class CorsoSostituito {
  const CorsoSostituito({
    required this.nuovo,
    this.universitaId,
    this.motivo,
    this.dal,
  });

  /// Id del corso che lo sostituisce (può a sua volta essere sostituito).
  final String nuovo;
  final String? universitaId;
  final String? motivo;

  /// "AAAA-MM-GG" della sostituzione.
  final String? dal;
}

/// Contenuto di `corsi_sostituiti.json`: {id vecchio → corso che lo
/// sostituisce}. Le catene (A→B, B→C) si seguono fino in fondo; i cicli e
/// le voci senza `nuovo` (o che puntano a sé stesse) si ignorano.
class CorsiSostituiti {
  const CorsiSostituiti(this.corsi);

  static const empty = CorsiSostituiti({});

  final Map<String, CorsoSostituito> corsi;

  bool get isEmpty => corsi.isEmpty;

  factory CorsiSostituiti.fromJson(Object? json) {
    final m = _root(json, 'corsi_sostituiti.json');
    final rows = m['corsi'];
    final out = <String, CorsoSostituito>{};
    if (rows is Map) {
      for (final e in rows.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final id = e.key.toString().trim();
        final nuovo = asString(v['nuovo']);
        if (id.isEmpty || nuovo == null || nuovo == id) continue;
        out[id] = CorsoSostituito(
          nuovo: nuovo,
          universitaId: asString(v['universita_id']),
          motivo: asString(v['motivo']),
          dal: asString(v['dal']),
        );
      }
    }
    return CorsiSostituiti(out);
  }

  /// Id attuale del corso [id] seguendo le catene; null se [id] non è stato
  /// sostituito, se la catena è un ciclo o se [universitaId] non coincide
  /// con quello indicato nella voce.
  String? risolvi(String id, {String? universitaId}) {
    final seen = <String>{id};
    var corrente = id;
    var passi = 0;
    while (true) {
      final r = corsi[corrente];
      if (r == null) return passi == 0 ? null : corrente;
      final uni = r.universitaId;
      if (universitaId != null && uni != null && uni != universitaId) {
        return passi == 0 ? null : corrente;
      }
      if (!seen.add(r.nuovo)) return null; // ciclo: voce ignorata
      corrente = r.nuovo;
      passi++;
    }
  }
}

// ------------------------------------------------- sessioni/<ateneo>.json

/// Periodo di una sessione d'esame pubblicato dall'ateneo (es. «Sessione
/// invernale» 11/01–20/02/2027).
class SessioneEsami {
  const SessioneEsami({
    required this.nome,
    required this.inizio,
    required this.fine,
    this.note,
  });
  final String nome;
  final DateTime inizio;

  /// Ultimo giorno compreso.
  final DateTime fine;
  final String? note;

  /// null se mancano il nome o date valide.
  static SessioneEsami? fromJson(Map<String, Object?> m) {
    final nome = asString(m['nome']);
    final a = DateTime.tryParse(asString(m['inizio']) ?? '');
    final b = DateTime.tryParse(asString(m['fine']) ?? '');
    if (nome == null || a == null || b == null || b.isBefore(a)) return null;
    return SessioneEsami(
      nome: nome,
      inizio: a,
      fine: b,
      note: asString(m['note']),
    );
  }
}

/// Calendario delle sessioni valido per alcuni corsi di laurea (di ateneo,
/// di Scuola, di Dipartimento o del singolo corso).
class CalendarioSessioni {
  const CalendarioSessioni({
    required this.ambito,
    required this.sessioni,
    required this.corsi,
    this.fonte,
  });
  final String ambito;
  final String? fonte;
  final List<SessioneEsami> sessioni;

  /// Id dei corsi di laurea del database a cui si applica.
  final Set<String> corsi;

  factory CalendarioSessioni.fromJson(Map<String, Object?> m) {
    final list = [
      for (final x in _maps(m['sessioni'])) ?SessioneEsami.fromJson(x),
    ]..sort((a, b) => a.inizio.compareTo(b.inizio));
    return CalendarioSessioni(
      ambito: asString(m['ambito']) ?? 'Ateneo',
      fonte: asString(m['fonte']),
      sessioni: list,
      corsi: {..._strings(m['corsi'])},
    );
  }
}

/// Sessioni d'esame di un ateneo per l'anno accademico, dai calendari
/// ufficiali.
class SessioniAteneo {
  const SessioniAteneo({
    required this.universitaId,
    required this.calendari,
    this.annoAccademico,
    this.verificatoIl,
  });
  final String universitaId;
  final String? annoAccademico;
  final String? verificatoIl;
  final List<CalendarioSessioni> calendari;

  factory SessioniAteneo.fromJson(Object? json) {
    final m = _root(json, 'sessioni/<ateneo>.json');
    return SessioniAteneo(
      universitaId: asString(m['universita_id']) ?? '',
      annoAccademico: asString(m['anno_accademico']),
      verificatoIl: asString(m['verificato_il']),
      calendari: [
        for (final c in _maps(m['calendari'])) CalendarioSessioni.fromJson(c),
      ],
    );
  }

  /// Calendario del corso di laurea [corsoId] (null se non coperto).
  CalendarioSessioni? per(String corsoId) {
    for (final c in calendari) {
      if (c.corsi.contains(corsoId) && c.sessioni.isNotEmpty) return c;
    }
    return null;
  }
}

// --------------------------------------------------- moduli/<ateneo>.json

/// Modulo di studio proposto per un insegnamento (per esempio un capitolo
/// del libro di riferimento) con i suoi argomenti.
class ModuloCatalogo {
  const ModuloCatalogo({required this.nome, this.argomenti = const []});
  final String nome;
  final List<String> argomenti;

  static ModuloCatalogo? fromJson(Map<String, Object?> m) {
    final nome = asString(m['nome']);
    if (nome == null) return null;
    return ModuloCatalogo(nome: nome, argomenti: _strings(m['argomenti']));
  }
}

/// Valori di `origine` in `moduli/<ateneo>.json`.
abstract final class OrigineModuli {
  /// Indice di un libro di riferimento consultato (anche se il campo manca).
  static const libreria = 'libreria';

  /// Indice di un libro del programma.
  static const indice = 'indice';

  /// Programma ufficiale pubblicato dall'ateneo.
  static const programma = 'programma';
}

/// Moduli proposti per un insegnamento e da dove vengono.
class ModuliInsegnamento {
  const ModuliInsegnamento({
    required this.moduli,
    this.fonte,
    this.origine = OrigineModuli.libreria,
    this.programma = const [],
    this.fonteProgramma,
  });

  /// Moduli di Studio (indice di un libro o programma, vedi [origine]).
  final List<ModuloCatalogo> moduli;

  /// Per esempio l'indice del libro di riferimento.
  final String? fonte;

  /// Da dove vengono i [moduli] (vedi [OrigineModuli]).
  final String origine;

  /// Programma ufficiale dell'insegnamento, presente quando i [moduli]
  /// vengono dall'indice di un libro e l'ateneo pubblica anche il programma.
  final List<ModuloCatalogo> programma;

  /// URL della scheda con il [programma].
  final String? fonteProgramma;

  /// Argomenti d'esame ufficiali: il [programma] se c'è, altrimenti i
  /// [moduli] se vengono dal programma; mai l'indice di un libro (vuoto).
  List<ModuloCatalogo> get argomentiEsame => programma.isNotEmpty
      ? programma
      : (origine == OrigineModuli.programma ? moduli : const []);
}

/// Moduli di studio proposti per gli insegnamenti di un ateneo
/// (`moduli/<ateneo>.json`), chiave: id dell'insegnamento.
class ModuliAteneo {
  const ModuliAteneo({required this.universitaId, required this.insegnamenti});
  final String universitaId;
  final Map<String, ModuliInsegnamento> insegnamenti;

  factory ModuliAteneo.fromJson(Object? json) {
    final m = _root(json, 'moduli/<ateneo>.json');
    final ins = m['insegnamenti'];
    final out = <String, ModuliInsegnamento>{};
    if (ins is Map) {
      for (final e in ins.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final vm = v.cast<String, Object?>();
        final moduli = [
          for (final x in _maps(vm['moduli'])) ?ModuloCatalogo.fromJson(x),
        ];
        // `programma` e `fonte_programma` sono facoltativi (file precedenti)
        final programma = [
          for (final x in _maps(vm['programma'])) ?ModuloCatalogo.fromJson(x),
        ];
        if (moduli.isEmpty && programma.isEmpty) continue;
        out[e.key.toString()] = ModuliInsegnamento(
          moduli: moduli,
          fonte: asString(vm['fonte']),
          origine: asString(vm['origine']) ?? OrigineModuli.libreria,
          programma: programma,
          fonteProgramma: asString(vm['fonte_programma']),
        );
      }
    }
    return ModuliAteneo(
      universitaId: asString(m['universita_id']) ?? '',
      insegnamenti: out,
    );
  }
}
