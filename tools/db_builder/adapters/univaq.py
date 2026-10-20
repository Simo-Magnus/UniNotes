"""Università degli Studi dell'Aquila: piani di studio per anno di corso, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://univaq.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) il catalogo dell'UnivAQ richiede:

- durata dal piano («3 anni», «5 anni», «6 anni»): l'elenco minimale non ha `durataAnni`;
- coorti: il codice del corso cambia con il riordino del 2025 («B3B» → «B3BR») e alcuni corsi cambiano anche nome
  («Scienze e tecnologie chimiche e dei materiali» → «Chimica», «Ingegneria civile e ambientale» → «Ingegneria
  civile»). Un corso del database è la catena dei corsi del catalogo con lo stesso nome (o in `RINOMINATI`) e lo
  stesso tipo; per l'anno di corso k si legge l'offerta della coorte (anno - k + 1), quella degli iscritti oggi al
  k-esimo anno, e solo se il catalogo non ha quell'anno la coorte più vicina che lo ha (con una nota). Prima il
  piano del 1° anno era quello della coorte 2026 anche per i corsi riordinati, e gli anni successivi quello della
  coorte attuale;
- tipo delle attività: nel gruppo «Obbligatori» valgono «OBB» (obbligatoria) e «OPZ» (una scelta tra le opzioni del
  curriculum); nei gruppi a scelta il catalogo segna «OBB» anche insegnamenti che si scelgono (gruppi «a scelta
  suggeriti»), quindi lì si sostengono per intero solo i gruppi con CFU fissi uguali alla somma delle attività;
- gruppi senza attività elencate ma con i CFU nell'etichetta («INSEGNAMENTO A SCELTA 2° ANNO (fra 9 e 15 CFU)», «AFO
  (3 CFU)», «INSEGNAMENTI A SCELTA (fino a 12 CFU) (fra 1 e 24 CFU)»): sono crediti che il piano richiede senza un
  esame preciso (fissi, oppure liberi: se l'etichetta ha un tetto («fino a», «max.») valgono quello, altrimenti il
  minimo dell'intervallo) e diventano voci a scelta; senza di essi gli anni risultavano di 50-58 CFU;
- sezioni «anno 0»: gruppi a scelta senza anno di corso; vanno all'anno che l'etichetta indica («I ANNO») o, senza
  indicazione, all'ultimo anno;
- attività con 0 CFU: il contenitore di un corso integrato (i CFU sono nei moduli), l'OFA e i test di valutazione
  non sono insegnamenti con crediti e non si riportano; un'attività che in una coorte ha 0 CFU per mancanza del dato
  prende i CFU della stessa attività (stesso codice) in un'altra coorte del corso;
- una sede per corso di Universitaly: «Infermieristica (sede Teramo)» è la sede del corso «… REPLICA TERAMO» e non un
  corso a parte (`ID_CORSI`);
- libri dai syllabus (testi del catalogo); se il syllabus 2026/27 non ha la bibliografia si usa quella dell'insegnamento
  da cui è mutuato o dell'a.a. precedente, indicandolo in nota; i syllabus già letti (stesso url) si riprendono dal
  database (`corsi/univaq.json`).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/univaq.json`, mantenendo gli appelli già presenti):

    python tools/db_builder/adapters/univaq.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import unicodedata

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402

BASE = "https://univaq.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}
FAMIGLIA = {"L2": "L", "LM": "LM", "LM5": "LMCU", "LM6": "LMCU"}  # tipo del catalogo → tipo del database
DURATA_TIPO = {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}

# Codici del catalogo di corsi che hanno cambiato nome con il riordino: vecchio codice → codice della catena
RINOMINATI = {
    "F3D": "F3DR",  # Scienze e tecnologie chimiche e dei materiali → Chimica
    "F3S": "F3SR",  # Scienze e tecnologie per l'ambiente → Scienze ambientali
    "I3A": "I3BR", "I3B": "I3BR",  # Ingegneria civile e ambientale → Ingegneria civile
}

# Corsi del catalogo la cui sede è una sede del corso di Universitaly «… REPLICA …» (non un corso a parte):
# codice del corso → id del corso nel database
ID_CORSI = {
    "D3V": "univaq-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1628614",
}

# Voci dei piani ufficiali (regolamenti didattici dei dipartimenti) che il catalogo non elenca: il catalogo riporta le attività
# erogate nell'a.a. e nei piani delle coorti con il vecchio ordinamento mancano i CFU a scelta dello studente, il tirocinio o
# la prova finale, e gli anni risultavano di 42-54 CFU. Per ogni corso (codice `cdsCod` della catena): documento ufficiale e
# righe (anno di corso, nome, CFU, obbligatoria, codice dell'attività, coorte del piano). Una riga vale solo se l'anno è letto
# dalla coorte indicata e non si aggiunge se l'anno ha già quell'attività.
_REG = "https://www.univaq.it/include/utilities/blob.php?table=off_0809&id={}&item=regolamento"  # regolamento didattico 2024-25
PIANO_EXTRA: dict[str, dict] = {
    # Scienze umane, coorte 2024/25 (vecchio ordinamento): il 3° anno ha «A scelta dello studente» (DQ0147, 1 esame da 12 CFU
    # o 2 da 6) e la prova finale (6 CFU); il catalogo della coorte 2024 elenca solo la prova finale
    "C3DR": {"fonte": _REG.format(1647), "voci": [(3, "A scelta dello studente", 12, True, "DQ0147", 2024)]},  # L-10 Lettere
    "C3MR": {"fonte": _REG.format(1646), "voci": [(3, "A scelta dello studente", 12, True, "DQ0147", 2024)]},  # L-12 Mediazione
    "C3FR": {"fonte": _REG.format(1648), "voci": [(3, "A scelta dello studente", 12, True, "DQ0147", 2024)]},  # L-5 Filosofia e TPC
    # L-27 (Scienze e tecnologie chimiche e dei materiali, coorte 2024/25): Allegato 2, 3° anno: «Insegnamenti a scelta» 12 CFU;
    # il catalogo ha solo un gruppo «Insegnamenti liberi (fra 1 e 18 CFU)»
    "F3DR": {"fonte": _REG.format(1666), "voci": [(3, "Insegnamenti a scelta", 12, False, None, 2024)]},
}

_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_FRA = re.compile(r"\(\s*fra\s+([\d.,]+)\s+e\s+([\d.,]+)\s*CFU\s*\)", re.I)
_TETTO = re.compile(r"\(\s*(?:fino\s+a|max\.?|nax|massimo|min(?:imo|\.)?)\s+([\d.,]+)\s*(?:CFU)?\s*\)", re.I)
_SCELTA = re.compile(r"(?i)scelt|opzional|alternativ|libera|liberi|student choice|a scelta|free[- ]choice|suggerit|consigliat")
_ZERO = re.compile(r"(?i)^\s*(?:ofa\b|test\b|debito\b)")
_ANNO_ETICHETTA = re.compile(r"(?i)\b(I{1,3}|IV|V|VI|[1-6]\s*°?)\s*(?:°\s*)?ANNO\b")
_ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
_PICCOLE = {"e", "di", "del", "della", "dello", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla",
            "il", "la", "lo", "le", "gli", "i", "ed", "nel", "nella", "dell'", "sul", "tra", "o", "of", "the", "and",
            "among", "from"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nome_piano(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", cc._titolo(s or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _chiave_corso(x: dict) -> tuple:
    """Nome (senza vocali e senza «(abilitante …)»), sede e famiglia: la catena delle coorti di un corso."""
    nome = x.get("des_it") or ""
    sede = "teramo" if re.search(r"(?i)\bteramo\b", nome) else ""
    nome = re.sub(r"\(.*?\)", " ", nome)
    n = re.sub(r"\b(?:e|ed|and)\b", " ", _norm(nome))
    return re.sub(r"[aeiou ]", "", n), sede, FAMIGLIA[x["tipo_corso_cod"]]


def _numero(s: str) -> float:
    return float(s.replace(",", "."))


def _int(x: float):
    return int(x) if x == int(x) else x


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/univaq_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "univaq_cc" if d else None

    def get(self, path, params=None):
        if not self.cache:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.cache / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def _titolo_etichetta(s: str) -> str:
    """«ATTIVITA' A SCELTA DELLO STUDENTE» → «Attività a scelta dello studente» (sigle e anni in cifre restano)."""
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    maiuscolo = s.isupper()
    s = re.sub(r"(?i)\battivita'", lambda m: "Attività" if m.group(0)[0].isupper() else "attività", s)
    if not maiuscolo:
        return s[:1].upper() + s[1:]
    out = []
    for i, w in enumerate(s.lower().split()):
        if re.fullmatch(r"[ivx]+", w):
            out.append(w.upper())
        elif i == 0:
            out.append(w[:1].upper() + w[1:])
        else:
            out.append(w)
    return " ".join(out)


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    return int(m.group(1)) if m else DURATA_TIPO.get(tipo or "", 3)


_COMUNE = ("PERCORSO COMUNE", "PERCORSO UNICO", "CURRICULUM UNICO", "COMUNE")
_SCHEMI = {"GDF": "Percorso riservato GdF", "OGI": "generico"}  # percorsi con lo stesso nome (Operatore giuridico d'impresa 2024)


def _nome_percorso(p: dict, doppi: set[str]) -> str:
    """Nome del percorso (uguale in tutte le coorti); due percorsi con lo stesso nome (il percorso riservato alla Guardia di
    Finanza e il generico di Operatore giuridico d'impresa nella coorte 2024) si distinguono come nelle coorti successive."""
    n = re.sub(r"\s+", " ", p.get("des_it") or p.get("pdsDes") or "").strip()
    if n.upper() in doppi and p.get("schemaCod"):
        n = f"{n} - {_SCHEMI.get(p['schemaCod'].rsplit('-', 1)[-1].upper(), p['schemaCod'])}"
    return n


def _comuni(det: dict) -> set[int]:
    """Indici dei percorsi validi per tutti gli studenti: per nome («Percorso comune»), o segnati «comune» dal catalogo se è
    l'unico così (nei corsi in cui tutti i percorsi sono segnati «comune» sono alternative, non un piano comune)."""
    ps = det.get("percorsi") or []
    segnati = sum(1 for p in ps if p.get("comune"))
    out = set()
    for i, p in enumerate(ps):
        nome = (p.get("des_it") or p.get("pdsDes") or "").strip().upper()
        if nome.startswith(_COMUNE) or (p.get("comune") and (segnati == 1 or len(ps) == 1)):
            out.add(i)
    return out


def _attivita(det: dict):
    """(nome del percorso, è comune, anno indicato dal piano, attività, gruppo) di tutti i percorsi del corso;
    un gruppo senza attività dà una voce con attività None (i suoi CFU stanno nell'etichetta)."""
    ps = det.get("percorsi") or []
    comuni = _comuni(det)
    nomi = [re.sub(r"\s+", " ", p.get("des_it") or p.get("pdsDes") or "").strip().upper() for p in ps]
    doppi = {n for n in nomi if nomi.count(n) > 1}
    for idx, p in enumerate(ps):
        nome = _nome_percorso(p, doppi)
        for a in p.get("anni") or []:
            gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                if not g.get("attivita"):
                    yield nome, idx in comuni, a.get("anno"), None, g
                for att in g.get("attivita") or []:
                    yield nome, idx in comuni, a.get("anno"), att, g


def _cfu_att(att: dict) -> float:
    v = att.get("crediti")
    return float(v) if isinstance(v, (int, float)) else 0.0


def _fisso(g: dict) -> float | None:
    """CFU fissi dell'etichetta («(12 CFU)»), senza intervallo."""
    for m in _ETICHETTA_CFU.finditer(g.get("label_it") or ""):
        if m.group(1) is None:
            return _numero(m.group(2))
    return None


def _per_intero(g: dict) -> bool:
    """Gruppo con CFU fissi nell'etichetta uguali alla somma delle sue attività: si sostengono tutte."""
    f = _fisso(g)
    tot = sum(_cfu_att(a) for a in g.get("attivita") or [])
    return f is not None and bool(g.get("attivita")) and tot > 0 and abs(tot - f) < 1e-6


def _voce_etichetta(g: dict):
    """Gruppo del piano senza attività elencate ma con i CFU nell'etichetta. → (nome, cfu, obbligatorio) o None.
    CFU fissi («(3 CFU)»); con un tetto («(fino a 12 CFU)», «(max. 9 CFU)», «(MIN 8)») quello; con il solo intervallo
    «(fra 9 e 15 CFU)» il minimo, se è più di 1 (un minimo di 1 CFU è il segnaposto del catalogo, non un requisito)."""
    label = g.get("label_it") or ""
    fisso = _fisso(g)
    tetto = _TETTO.search(label)
    fra = _FRA.search(label)
    if fisso is not None and not (fra and fisso == _numero(fra.group(2))):
        cfu, obbl = fisso, not _SCELTA.search(label)
    elif tetto:
        cfu, obbl = _numero(tetto.group(1)), False
    elif fra and _numero(fra.group(1)) > 1:
        cfu, obbl = _numero(fra.group(1)), False
    else:
        return None
    if cfu <= 0:
        return None
    resto = _ETICHETTA_CFU.sub(" ", _TETTO.sub(" ", label))
    nome = _titolo_etichetta(resto)
    if len(nome) < 3:
        return None
    return nome, _int(cfu), obbl


def _anno_etichetta(g: dict) -> int | None:
    m = _ANNO_ETICHETTA.search(g.get("label_it") or "")
    if not m:
        return None
    t = m.group(1).upper()
    return _ROMANI.get(t) or int(re.sub(r"\D", "", t))


def _nomi_etichette(ins: list[dict]) -> None:
    """Le voci ricavate dalle etichette non hanno codice e build_db le distingue per nome: lo stesso nome in anni
    diversi porta l'anno, nello stesso anno con CFU diversi porta i CFU."""
    voci = [i for i in ins if i.get("_etichetta")]
    anni: dict[str, set] = {}
    cfu: dict[tuple, set] = {}
    for i in voci:
        anni.setdefault(_norm(i["nome"]), set()).add(i["anno"])
        cfu.setdefault((_norm(i["nome"]), i["anno"]), set()).add(i["cfu"])
    for i in voci:
        i.pop("_etichetta")
        if len(cfu[(_norm(i["nome"]), i["anno"])]) > 1:
            i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        if len(anni[_norm(i["nome"].split(" (")[0])]) > 1:
            i["nome"] = f"{i['nome']} ({i['anno']}° anno)"


def _omonimi(ins: list[dict]) -> None:
    """Due attività con lo stesso nome nello stesso anno, codici e CFU diversi: attività distinte, il nome porta i CFU."""
    gruppi: dict[tuple, list[dict]] = {}
    for i in ins:
        gruppi.setdefault((i["anno"], _norm(i["nome"]), i.get("curriculum")), []).append(i)
    for g in gruppi.values():
        if len({i["codice"] for i in g}) > 1 and len({i["cfu"] for i in g}) > 1:
            for i in g:
                if i.get("cfu"):
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"


def chiave_extra(codici: list[str]) -> str | None:
    """Codice di `PIANO_EXTRA` della catena di un corso, se c'è."""
    return next((c for c in codici if c in PIANO_EXTRA), "")


def _carica_precedente() -> dict[str, dict]:
    """Insegnamenti già nel database per url: i syllabus già letti non si rileggono."""
    out: dict[str, dict] = {}
    p = ROOT / "database" / "corsi" / "univaq.json"
    if p.exists():
        for c in json.loads(p.read_text(encoding="utf-8")).get("corsi", []):
            for i in c.get("insegnamenti") or []:
                if isinstance(i, dict) and i.get("url") and i.get("stato_libri"):
                    out.setdefault(i["url"], i)
    return out


def fetch_ateneo(uid: str = "univaq", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache()
    precedente = _carica_precedente() if syllabus else {}
    if precedente:
        log(f"[{uid}] syllabus già letti nel database: {len(precedente)}")
    fmt = lambda a: f"{a}/{(a + 1) % 100:02d}"  # noqa: E731
    oggi = time.strftime("%Y-%m-%d")

    # --- offerte per coorte -------------------------------------------------------------------------
    offerte: dict[tuple[str, int], dict] = {}  # (cdsCod, coorte) -> dettaglio + dati dell'elenco
    for y in range(anno - 5, anno + 1):
        elenco: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], elenco)
        visti = set()
        for x in elenco:
            if str(x.get("aa")) != str(y) or x.get("tipo_corso_cod") not in TIPI or x["cod"] in visti:
                continue
            visti.add(x["cod"])
            det = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(det, list):
                det = det[0] if det else None
            if det:
                offerte[(x["cdsCod"], y)] = {"x": x, "det": det}
    log(f"[{uid}] offerte lette: {len(offerte)}")

    # --- catene di codici = corsi -----------------------------------------------------------------
    gruppi: dict[tuple, list[str]] = {}
    for (cds, y), o in sorted(offerte.items(), key=lambda t: t[0][1]):
        k = _chiave_corso(o["x"])
        if cds not in gruppi.setdefault(k, []):
            gruppi[k].append(cds)
    for vecchio, nuovo in RINOMINATI.items():  # corsi con un altro nome: stessa catena
        kv = next((k for k, v in gruppi.items() if vecchio in v), None)
        kn = next((k for k, v in gruppi.items() if nuovo in v), None)
        if kv and kn and kv != kn:
            gruppi[kn] += [x for x in gruppi.pop(kv) if x not in gruppi[kn]]
    log(f"[{uid}] corsi del catalogo: {len({c_ for (c_, _) in offerte})} codici in {len(gruppi)} corsi")

    # CFU delle attività per codice nelle altre coorti (attività con 0 CFU per dato mancante)
    cfu_altrove: dict[tuple, dict[str, float]] = {}
    gruppo_di = {cds: k for k, cods in gruppi.items() for cds in cods}
    for (cds, y), o in offerte.items():
        for _, _, _, att, _ in _attivita(o["det"]):
            if att is not None and _cfu_att(att) > 0:
                cfu_altrove.setdefault(gruppo_di[cds], {}).setdefault(str(att.get("adCod")), _cfu_att(att))

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    indice_ad: dict[str, dict[int, list[dict]]] = {}  # adCod -> aa -> parametri del syllabus

    def parametri(att: dict, y: int) -> dict:
        return {"anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y,
                "schema_id": att.get("schemaId")}

    for (cds, y), o in offerte.items():
        for _, _, _, att, _ in _attivita(o["det"]):
            if att is None:
                continue
            try:
                aa_att = int(att["aa"])
            except (KeyError, TypeError, ValueError):
                continue
            p = parametri(att, y)
            dest = indice_ad.setdefault(str(att.get("adCod")), {}).setdefault(aa_att, [])
            if p not in dest:
                dest.append(p)

    for chiave, codici in sorted(gruppi.items(), key=lambda t: t[1]):
        if max_cds and len(corsi_out) >= max_cds:
            break
        coorti = {cds: sorted(y for (cc_, y) in offerte if cc_ == cds) for cds in codici}
        recente = max(((cds, ys[-1]) for cds, ys in coorti.items() if ys), key=lambda t: t[1])
        if recente[1] < anno:  # ordinamento estinto: nessuna iscrizione al 1° anno (né corso nel database)
            continue
        x, det = offerte[recente]["x"], offerte[recente]["det"]
        durata = _durata(det, x.get("tipo_corso_cod"))
        coorti_group = sorted({y for ys in coorti.values() for y in ys})
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        zero_senza_cfu: set[str] = set()
        amm = None
        altrove = cfu_altrove.get(chiave, {})

        def aggiungi(cds: str, y: int, k: int, nota_anno: str | None):
            nonlocal amm
            o = offerte[(cds, y)]
            if amm is None and y == anno:
                amm = ammissione.da_catalogo(o["det"], f"{BASE}/corsi/{anno}/{o['x'].get('cod')}")
            n_perc = len(o["det"].get("percorsi") or []) - len(_comuni(o["det"]))
            for pnome, comune, anno_a, att, grp in _attivita(o["det"]):
                # anno di corso del gruppo: quello del piano; le sezioni «anno 0» (a scelta, senza anno) vanno all'anno
                # dell'etichetta («… I ANNO») o all'ultimo
                if str(anno_a).isdigit() and int(anno_a) > 0:
                    k_att = int(anno_a)
                else:
                    k_att = _anno_etichetta(grp) or durata
                if k_att != k:
                    continue
                if att is None:  # gruppo senza attività: i CFU stanno nell'etichetta
                    voce = _voce_etichetta(grp)
                    if not voce:
                        continue
                    nome_v, cfu_v, obbl_v = voce
                    key = f"{k}:#{_norm(nome_v)}:{cfu_v}"
                    item = insegnamenti.get(key)
                    if not item:
                        item = {
                            "codice": None, "nome": nome_v, "anno": k, "periodo": None, "cfu": cfu_v, "ssd": None,
                            "obbligatorio": obbl_v, "curriculum": None, "_percorsi": set(), "_comune": False,
                            "docenti": [], "libri": [], "esami": [], "_etichetta": True,
                            "url": f"{BASE}/corsi/{y}/{o['x'].get('cod')}",
                            "fonte": BASE, "verificato_il": oggi,
                            "note": "Crediti che il piano richiede senza un esame preciso (etichetta del gruppo nel "
                                    "catalogo)",
                        }
                        if nota_anno:
                            item["_nota_anno"] = nota_anno
                        insegnamenti[key] = item
                    if comune:
                        item["_comune"] = True
                    elif n_perc > 1 and pnome:
                        pnome = cc._titolo(pnome)
                        item["_percorsi"].add(pnome)
                        percorsi_nomi.add(pnome)
                    continue
                cfu = att.get("crediti")
                if not (cfu or 0):
                    ad_ = str(att.get("adCod"))
                    if _ZERO.search(att.get("des_it") or ""):
                        continue  # OFA e test di valutazione: requisiti di accesso, non insegnamenti
                    if att.get("adFiglie") or any((z.get("adPadre") or {}).get("adCod") == att.get("adCod")
                                                  for z in grp.get("attivita") or []):
                        continue  # contenitore di un corso integrato: i CFU sono nei moduli
                    if ad_ in altrove:
                        cfu = _int(altrove[ad_])
                    else:
                        zero_senza_cfu.add(att.get("des_it") or ad_)
                        continue
                ad = att.get("adCod") or att.get("cod")
                key = f"{k}:{ad}"
                item = insegnamenti.get(key)
                if grp.get("cod") == "OO":
                    obbl = True  # il gruppo «Obbligatori» del curriculum: anche le «OPZ» sono parte dei suoi 60 CFU
                else:
                    obbl = _per_intero(grp) or (len(grp.get("attivita") or []) == 1 and att.get("tipo_ins_cod") == "OBB"
                                                and not _SCELTA.search(grp.get("label_it") or ""))
                if not item:
                    docenti = [cc._nome(d.get("des")) for d in att.get("docenti") or [] if d.get("des")]
                    item = {
                        "codice": ad, "nome": cc._titolo(re.sub(r"\s+", " ", att.get("des_it") or ad)), "anno": k,
                        "periodo": cc._periodo(att.get("periodo_didattico_it")),
                        "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                        "periodo_fine": att.get("data_fine_periodo_didattico"),
                        "cfu": cfu, "ssd": None,
                        "obbligatorio": obbl, "curriculum": None, "_percorsi": set(), "_comune": False,
                        "docenti": sorted(set(docenti)),
                        "url": f"{BASE}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                               f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                        "libri": [], "esami": [],
                        "fonte": BASE, "verificato_il": oggi,
                    }
                    if nota_anno:
                        item["_nota_anno"] = nota_anno
                    insegnamenti[key] = item
                    if syllabus:
                        syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                            "params": parametri(att, y), "items": [], "ad": str(ad)})["items"].append(item)
                elif obbl:
                    item["obbligatorio"] = True  # obbligatorio in almeno un percorso
                if comune:
                    item["_comune"] = True
                elif n_perc > 1 and pnome:
                    pnome = cc._titolo(pnome)
                    item["_percorsi"].add(pnome)
                    percorsi_nomi.add(pnome)

        coorte_letta: dict[int, int] = {}
        for k in range(1, durata + 1):
            y = anno - k + 1
            # coorte giusta; se il catalogo non la ha, o non vi pubblica le attività di quest'anno di corso, il piano
            # della coorte più vicina che le ha (con una nota)
            ordine = ([y] if any(y in coorti[cds] for cds in codici) else []) + \
                [v for v in sorted(coorti_group, key=lambda v: (abs(v - y), -v)) if v != y]
            for yy in ordine:
                nota = None
                if yy != y and y in {v for ys in coorti.values() for v in ys}:
                    nota = (f"Piano della coorte {yy}: il catalogo non pubblica ancora le attività della coorte {y} "
                            f"per questo anno")
                elif yy != y:
                    nota = (f"Piano della coorte {yy}: insegnamento erogato nell'a.a. {fmt(yy + k - 1)}"
                            if yy + k - 1 > anno else
                            f"Piano della coorte {yy}: il catalogo non ha la coorte {y}")
                for cds in codici:
                    if yy in coorti[cds]:
                        aggiungi(cds, yy, k, nota)
                if any(i["anno"] == k and not i.get("_etichetta") for i in insegnamenti.values()):
                    coorte_letta[k] = yy
                    break
        for riga in PIANO_EXTRA.get(chiave_extra(codici), {}).get("voci", []):
            k_e, nome_e, cfu_e, obbl_e, cod_e, coorte_e = riga
            if k_e > durata or coorte_letta.get(k_e) != coorte_e or (cod_e and any(i["anno"] == k_e and i["codice"] == cod_e for i in insegnamenti.values())):
                continue
            fonte_e = PIANO_EXTRA[chiave_extra(codici)]["fonte"]
            insegnamenti[f"{k_e}:+{cod_e or _norm(nome_e)}"] = {
                "codice": cod_e, "nome": nome_e, "anno": k_e, "periodo": None, "cfu": cfu_e, "ssd": None,
                "obbligatorio": obbl_e, "curriculum": None, "_percorsi": set(), "_comune": True,
                "docenti": [], "libri": [], "esami": [], "url": fonte_e, "fonte": fonte_e, "verificato_il": oggi,
                "note": "Voce del piano ufficiale (regolamento didattico) che il catalogo non elenca",
            }
        ins = list(insegnamenti.values())
        _nomi_etichette(ins)
        for i in ins:
            ps = i.pop("_percorsi")
            comune = i.pop("_comune")
            if percorsi_nomi and ps and not comune and ps != percorsi_nomi:
                i["curriculum"] = ", ".join(sorted(ps))
        _omonimi(ins)
        if zero_senza_cfu:
            log(f"[{uid}]   {x.get('cdsCod')}: attività a 0 CFU senza CFU altrove, non riportate: "
                f"{', '.join(sorted(zero_senza_cfu))[:200]}")
        corsi_out.append({
            "nome": cc._titolo(x.get("des_it") or ""),
            "classe": cc._classe(det.get("classe_cod") or x.get("classe_cod")),
            "tipo_catalogo": x.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": x.get("sedeDenominazioneComune") or x.get("sede_des_it"),
            "codice_ateneo": x.get("cdsCod"), "codici_catalogo": sorted(codici),
            "url": f"{BASE}/corsi/{recente[1]}/{x.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": BASE, "verificato_il": oggi, "insegnamenti": ins,
        })
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    # --- libri dai syllabus ----------------------------------------------------------------------
    def con_nota(libri: list[dict], nota: str) -> list[dict]:
        return [dict(b, note=f"{nota}; {b['note']}" if b.get("note") else nota) for b in libri]

    def cerca_libri(job: dict) -> tuple[list[dict], dict | None]:
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return [], None
        libri = cc._testi_syllabus(sy)[0]
        if libri:
            return libri, sy
        m = sy.get("mutuaDa")
        if isinstance(m, dict) and m.get("adId"):  # mutuato: il programma è quello dell'insegnamento di origine
            sy2 = c.get("/insegnamento", {"anno": m.get("aaOffId"), "insegnamento": m.get("adId"),
                                          "corso_cod": m.get("cdsId"), "ordinamento_aa": m.get("aaOrdId"),
                                          "af_percorso": m.get("pdsId")})
            libri = cc._testi_syllabus(sy2)[0] if isinstance(sy2, dict) else []
            if libri:
                return con_nota(libri, f"Dal programma di «{(sy2 or {}).get('des_it', '').title()}», da cui questo "
                                       f"insegnamento è mutuato"), sy
        try:
            aa = int(sy.get("aa"))
        except (TypeError, ValueError):
            return [], sy
        for prec in range(aa - 1, aa - 5, -1):  # programma dell'a.a. precedente dello stesso insegnamento
            for par in indice_ad.get(str(sy.get("adCod")), {}).get(prec) or []:
                sy2 = c.get("/insegnamento", {k: v for k, v in par.items() if v not in (None, "")})
                libri = cc._testi_syllabus(sy2)[0] if isinstance(sy2, dict) else []
                if libri:
                    return con_nota(libri, f"Dal programma dell'a.a. {fmt(prec)}: la scheda {fmt(aa)} non riporta "
                                           f"la bibliografia"), sy
        return [], sy

    def lavora(job: dict):
        try:
            prec = next((precedente[i["url"]] for i in job["items"] if i.get("url") in precedente), None)
            if prec is not None:  # syllabus già letto: stessi libri e stessa modalità d'esame
                return job, (prec.get("libri") or [], {"tipoEsaDes_it": prec.get("modalita_esame"),
                                                       "ssd": prec.get("ssd"), "urlSitoWeb": prec.get("url_sito")})
            return job, cerca_libri(job)
        except Exception as e:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            log(f"[{uid}]   syllabus {job['ad']} saltato: {e!r}")
            return job, None

    trovati = 0
    with cf.ThreadPoolExecutor(10) as ex:
        for n, (job, r) in enumerate(ex.map(lavora, list(syllabus_jobs.values())), 1):
            if r is None:
                continue
            libri, sy = r
            trovati += len(libri)
            for it in job["items"]:
                it["libri"] = libri
                it["stato_libri"] = "completo" if libri else "da_aggiungere"
                if sy:
                    if sy.get("tipoEsaDes_it"):
                        it["modalita_esame"] = sy["tipoEsaDes_it"].lower()
                    if sy.get("ssd"):
                        it["ssd"] = sy["ssd"]
                    if sy.get("urlSitoWeb"):
                        it["url_sito"] = sy["urlSitoWeb"].strip()
            if n % 300 == 0:
                log(f"[{uid}]   syllabus {n}/{len(syllabus_jobs)}")
    for cs in corsi_out:
        for i in cs["insegnamenti"]:
            nota = i.pop("_nota_anno", None)
            if nota:
                i["note"] = nota
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    doc = {"universita_id": uid, "descrizione": f"Generato da {BASE} (Course Catalogue Cineca)",
           "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
    log(f"[{uid}] corsi con id del database: {associa(doc['corsi'], log)}/{len(doc['corsi'])}")
    return doc


def _slug(s: str, maxlen: int = 40) -> str:
    return re.sub(r"[^a-z0-9]+", "-", unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
                  ).strip("-")[:maxlen].strip("-")


def _chiave_db(nome: str | None) -> str:
    n = re.sub(r"\(.*?\)", " ", nome or "")
    n = re.sub(r"\b(?:e|ed|and)\b", " ", _norm(n))
    return re.sub(r"[aeiou ]", "", n)


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso del catalogo l'`id` del corso già nel database (stessa denominazione e tipo)."""
    p = ROOT / "database" / "corsi" / "univaq.json"
    if not p.exists():
        return 0
    db = json.loads(p.read_text(encoding="utf-8"))["corsi"]
    forzati = set(ID_CORSI.values())
    per_chiave: dict[tuple[str, str], list[dict]] = {}
    for d in db:
        if d["id"] in forzati or re.search(r"(?i)\breplica\b|\(sede\b", d["nome"]):
            continue
        tipo = "L" if d.get("tipo") in ("L", "LP") else d.get("tipo")
        per_chiave.setdefault((_chiave_db(d["nome"]), tipo), []).append(d)
    n = 0
    for cs in corsi:
        forzato = next((ID_CORSI[k] for k in cs["codici_catalogo"] if k in ID_CORSI), None)
        if forzato:
            cs["id"] = forzato
            n += 1
            continue
        cand = per_chiave.get((_chiave_db(cs["nome"]), FAMIGLIA[cs["tipo_catalogo"]]), [])
        if len(cand) == 1:
            cs["id"] = cand[0]["id"]
            n += 1
        else:
            log(f"[univaq]   corso del catalogo senza corso unico nel database: {cs['nome']} {cs['codici_catalogo']} "
                f"({len(cand)} candidati)")
    return n


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "univaq.json"
    if out.exists():  # appelli e canali già presenti
        vecchio = json.loads(out.read_text(encoding="utf-8"))
        doc["appelli"] = vecchio.get("appelli") or {}
        doc["canali"] = vecchio.get("canali") or []
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"scritto {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
