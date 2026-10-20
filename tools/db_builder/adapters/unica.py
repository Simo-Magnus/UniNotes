"""Università degli Studi di Cagliari: insegnamenti per anno di corso, libri e appelli.

Piani e syllabus: `https://unica.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Rispetto all'adattatore comune (`cineca_catalogue`) UniCa richiede:

- coorti: il codice del corso cambia con ogni nuovo ordinamento (60/57 → 60/81 per Biologia): un corso del
  database è la catena dei corsi del catalogo con lo stesso nome e tipo (L2/LM/LM5/LM6), e per l'anno di corso k
  si legge l'offerta della coorte 2026 - k + 1 (il piano che il 2° anno segue davvero, non quello futuro della
  coorte attuale);
- anno di corso: le coorti passate hanno gli anni 1…N; le Facoltà di Scienze economiche, giuridiche e politiche
  e alcune offerte 2026 mettono tutto sotto «altreAttivita» o «anno 0» e l'anno si ricava dall'anno accademico
  in cui l'attività è erogata (`aa`): quella con `aa` = 2026 nell'offerta della coorte 2024 è del 3° anno;
- per gli anni senza una coorte nel catalogo (primo anno di un corso nuovo, o coorte mancante) si legge il piano
  della coorte più vicina, indicandolo in nota;
- durata dei corsi dal piano («5 anni»): l'elenco minimale non ha `durataAnni`;
- i libri sono nei testi liberi dei syllabus: estrazione di UniSS (`uniss_testi`) che scarta prosa e frammenti;
  se il syllabus 2026/27 non ha la bibliografia si usa quello dell'a.a. precedente (o dell'insegnamento da cui
  è mutuato), indicandolo nella nota;
- gruppi senza attività elencate ma con i CFU nell'etichetta («ATTIVITA' A SCELTA DELLO STUDENTE (12 CFU)»,
  «ALTRE ATTIVITA' (2 CFU)», «TIROCINIO (4 CFU)», «Discipline a scelta studente 2 anno (7 CFU)»): sono crediti
  che il piano richiede senza un esame preciso e diventano voci del piano (a scelta oppure obbligatorie) con
  quei CFU; senza di esse gli anni risultavano di 50-58 CFU. Le sezioni «anno 0» senza anno vanno all'ultimo anno;
- gruppi con CFU fissi nell'etichetta uguali alla somma delle loro attività («(12 CFU)» con due moduli da 6): si
  sostengono tutte, non sono una scelta;
- attività con 0 CFU: il «Corso integrato» che fa da contenitore ai moduli (elencati a parte con i loro CFU: gli
  appelli e i libri sono dei moduli), le prove pratiche valutative e i test non sono insegnamenti e non si
  registrano;
- opzioni di un gruppo a scelta segnate «obbligatorie» dal catalogo: se i CFU dell'etichetta sono meno della somma
  delle opzioni se ne sceglie una parte, quindi sono a scelta;
- ogni corso porta l'`id` del corso già nel database (stessa denominazione e tipo), così il piano non finisce in
  un doppione.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco; con
UNICA_PRECEDENTE (un file `contrib/auto/unica.json` di una raccolta precedente) i syllabus già letti (stesso url
dell'insegnamento) non si rileggono: restano i loro libri e il loro programma.
Richieste al catalogo: al massimo 2 al secondo.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata

from . import ammissione, cineca_catalogue, unica_testi, uniss_testi

BASE = "https://unica.coursecatalogue.cineca.it"
ESSE3 = "https://unica.esse3.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L2", "LM", "LM5", "LM6"}
RATE = 2.0
FAMIGLIA = {"L2": "L", "LM": "LM", "LM5": "LMCU", "LM6": "LMCU"}  # tipo del catalogo → tipo del database

# corsi del catalogo che il nome non basta ad associare a un corso del database: codice → id del corso
FORZA_ID = {
    "40/50": "unica-l-snt4-assistenza-sanitaria-abilitante-alla-professione-sanitaria-d",
    "40/77": "unica-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf",
    "40/78": "unica-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1627288",
}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nome_piano(s: str | None) -> str:
    """Nome dell'attività per riconoscere lo stesso insegnamento con due codici («INGLESE-LIVELLO B1» e «INGLESE LIVELLO
    B1»): le parentesi restano, perché «Storia medievale 1» e «Storia medievale 1 (mod.A)» sono attività diverse."""
    s = unicodedata.normalize("NFKD", _pulisci_nome(s)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _chiave_corso(nome: str | None) -> str:
    """Nome del corso senza vocali, senza «(abilitante …)» e senza lettere perse: i nomi del catalogo hanno lettere
    accentate perse («Sostenibilit�») e il database a volte l'apostrofo («attivita'») o «&» al posto di «e»."""
    nome = re.sub(r"^\s*\[[^\]]*\]\s*", "", nome or "")  # «[60/57] BIOLOGIA» (etichetta di Esse3)
    nome = re.sub(r"\(.*$", "", re.sub(r"\(.*?\)", " ", nome))  # «(abilitante …)», anche troncato
    n = _norm(re.sub(r"(?i)\s*-?\s*sede (?:di )?\w+\s*$|\s*replica.*$", "", nome))
    n = re.sub(r"\b(?:e|ed|and)\b", " ", n)
    return re.sub(r"[aeiou ]", "", n)


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unica_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    return {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _e_comune(p: dict, nome: str) -> bool:
    """Percorso valido per tutti gli studenti («PERCORSO COMUNE», «PERCORSO UNICO»)."""
    return bool(p.get("comune")) or nome.upper().startswith(("PERCORSO COMUNE", "PERCORSO UNICO"))


def _attivita(det: dict):
    """(nome del percorso, è comune, anno indicato dal piano, attività, gruppo) di tutti i percorsi del corso;
    un gruppo senza attività dà una voce con attività None (i suoi CFU stanno nell'etichetta)."""
    for p in det.get("percorsi") or []:
        nome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        for a in p.get("anni") or []:
            gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                if not g.get("attivita"):
                    yield nome, _e_comune(p, nome), a.get("anno"), None, g
                for att in g.get("attivita") or []:
                    yield nome, _e_comune(p, nome), a.get("anno"), att, g


def _pulisci_nome(s: str | None) -> str:
    """«01/31 DIRITTO COMMERCIALE» → «Diritto Commerciale» (il prefisso è il codice del piano)."""
    s = re.sub(r"^\s*\d{1,3}/\d{1,3}\s+", "", s or "")
    return cineca_catalogue._titolo(s)


_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_SCELTA = re.compile(r"(?i)scelt|opzional|alternativ|libera|liberi|student choice|a scelta")


def _titolo_etichetta(s: str) -> str:
    """«ATTIVITA' A SCELTA DELLO STUDENTE» → «Attività a scelta dello studente» (sigle e SSD restano maiuscoli,
    «AF» iniziale è «Attività formative»)."""
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        s = re.sub(r"(?i)\battivita'", lambda m: "Attività" if m.group(0)[0].isupper() else "attività", s)
        return s[:1].upper() + s[1:]
    out = []
    for i, w in enumerate(s.lower().split()):
        if w == "attivita'":
            w = "attività"
        if i == 0 and w == "af":
            w = "attività formative"
        if re.fullmatch(r"[ivx]+|l-?\d+", w) or re.fullmatch(r"[(]?[a-z]{1,4}-[a-z]{2,4}/\d+[)]?", w):
            out.append(w.upper())
        elif "-" in w:
            out.append("-".join(x[:1].upper() + x[1:] for x in w.split("-")))
        else:
            out.append(w[:1].upper() + w[1:] if i == 0 else w)
    return " ".join(out)


def _voce_etichetta(g: dict):
    """Gruppo del piano senza attività elencate ma con i CFU nell'etichetta: crediti richiesti dal piano senza un
    esame preciso. → (nome, cfu, obbligatorio) oppure None."""
    label = g.get("label_it") or ""
    m = _ETICHETTA_CFU.search(label)
    if not m:
        return None
    try:
        cfu = float(m.group(2).replace(",", "."))
    except ValueError:
        return None
    if cfu <= 0:
        return None
    cfu = int(cfu) if cfu == int(cfu) else cfu
    nome = _titolo_etichetta(_ETICHETTA_CFU.sub(" ", label))
    if len(nome) < 3:
        return None
    return nome, cfu, not _SCELTA.search(label)


def _per_intero(g: dict) -> bool:
    """Gruppo con CFU fissi nell'etichetta uguali alla somma delle sue attività: si sostengono tutte."""
    m = _ETICHETTA_CFU.search(g.get("label_it") or "")
    if not m or m.group(1) is not None:
        return False
    try:
        richiesti = float(m.group(2).replace(",", "."))
    except ValueError:
        return False
    tot = sum(float(a.get("crediti") or 0) for a in g.get("attivita") or [])
    return bool(g.get("attivita")) and tot > 0 and abs(tot - richiesti) < 1e-6


def _a_scelta(g: dict) -> bool:
    """Gruppo che non è «Obbligatori», «in alternativa» o con CFU fissi nell'etichetta minori della somma delle sue
    attività: se ne sceglie una parte, anche se il catalogo segna «obbligatoria» qualcuna delle opzioni."""
    m = _ETICHETTA_CFU.search(g.get("label_it") or "")
    if g.get("cod") != "OO" and len(g.get("attivita") or []) > 1 and re.search(r"(?i)\balternativ", g.get("label_it") or ""):
        return True  # «ATTIVITÀ FORMATIVA OBBLIGATORIA IN ALTERNATIVA»: se ne sostiene una
    if g.get("cod") == "OO" or not m or m.group(1) is not None:
        return False
    try:
        richiesti = float(m.group(2).replace(",", "."))
    except ValueError:
        return False
    tot = sum(float(a.get("crediti") or 0) for a in g.get("attivita") or [])
    return tot > richiesti + 1e-6


def _nomi_etichette(ins: list[dict]) -> None:
    """Le voci ricavate dalle etichette non hanno codice e build_db le distingue per nome: lo stesso nome in anni
    diversi porta l'anno («A scelta dello studente (3° anno)»), nello stesso anno con CFU diversi porta i CFU."""
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
    """Due attività con lo stesso nome nello stesso anno e codici e CFU diversi («Preparazione Tesi» da 24 e da 6 CFU)
    sono attività distinte del piano, non un doppione: il nome porta i CFU."""
    gruppi: dict[tuple, list[dict]] = {}
    for i in ins:
        gruppi.setdefault((i["anno"], _norm(i["nome"]), i.get("curriculum")), []).append(i)
    for g in gruppi.values():
        if len({i["codice"] for i in g}) > 1 and len({i["cfu"] for i in g}) > 1:
            for i in g:
                if i.get("cfu"):
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"


def fetch_ateneo(uid: str = "unica", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache()
    precedente: dict[str, dict] = {}  # url dell'insegnamento -> insegnamento di una raccolta precedente (UNICA_PRECEDENTE)
    if os.environ.get("UNICA_PRECEDENTE") and pathlib.Path(os.environ["UNICA_PRECEDENTE"]).exists():
        for cs_ in json.loads(pathlib.Path(os.environ["UNICA_PRECEDENTE"]).read_text(encoding="utf-8")).get("corsi", []):
            for i_ in cs_.get("insegnamenti") or []:
                if i_.get("url") and i_.get("stato_libri"):
                    precedente[i_["url"]] = i_
        log(f"[{uid}] syllabus già letti nella raccolta precedente: {len(precedente)}")
    fmt = lambda a: f"{a}/{(a + 1) % 100:02d}"  # noqa: E731
    oggi = time.strftime("%Y-%m-%d")

    # --- offerte per coorte -------------------------------------------------------------------------
    offerte: dict[tuple[str, int], dict] = {}  # (cdsCod, coorte) -> dettaglio + dati dell'elenco
    for y in range(anno - 5, anno + 1):
        elenco: list[dict] = []
        cineca_catalogue._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], elenco)
        visti = set()
        for x in elenco:
            if str(x.get("aa")) != str(y) or x.get("tipo_corso_cod") not in TIPI or x["cod"] in visti:
                continue
            visti.add(x["cod"])
            det = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(det, list):
                det = det[0] if det else None
            if not det:
                continue
            offerte[(x["cdsCod"], y)] = {"x": x, "det": det}
    log(f"[{uid}] offerte lette: {len(offerte)}")

    # --- catene di codici = corsi -----------------------------------------------------------------
    gruppi: dict[tuple, list[str]] = {}
    for (cds, y), o in sorted(offerte.items(), key=lambda t: t[0][1]):
        x = o["x"]
        k = (_chiave_corso(x.get("des_it")), FAMIGLIA[x["tipo_corso_cod"]])
        if cds not in gruppi.setdefault(k, []):
            gruppi[k].append(cds)
    log(f"[{uid}] corsi del catalogo: {len({c_ for (c_, _) in offerte})} codici in {len(gruppi)} corsi")

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    indice_ad: dict[str, dict[int, list[dict]]] = {}  # adCod -> aa -> parametri del syllabus

    def parametri(att: dict, y: int) -> dict:
        return {"anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y,
                "schema_id": att.get("schemaId")}

    gruppo_di = {cds: k for k, cods in gruppi.items() for cds in cods}
    indice_nome: dict[tuple, dict[int, list[dict]]] = {}  # (corso, nome) -> aa -> parametri (codice cambiato)
    for (cds, y), o in offerte.items():
        for _, _, _, att, _ in _attivita(o["det"]):
            if att is None:
                continue
            try:
                aa_att = int(att["aa"])
            except (KeyError, TypeError, ValueError):
                continue
            p = parametri(att, y)
            for dest in (indice_ad.setdefault(str(att.get("adCod")), {}).setdefault(aa_att, []),
                         indice_nome.setdefault((gruppo_di.get(cds), _norm(_pulisci_nome(att.get("des_it")))), {})
                         .setdefault(aa_att, [])):
                if p not in dest:
                    dest.append(p)

    for chiave, codici in sorted(gruppi.items(), key=lambda t: t[1]):
        if max_cds and len(corsi_out) >= max_cds:
            break
        coorti = {cds: sorted(y for (cc_, y) in offerte if cc_ == cds) for cds in codici}
        recente = max(((cds, ys[-1]) for cds, ys in coorti.items()), key=lambda t: t[1])
        if recente[1] < anno:  # ordinamento estinto: nessuna iscrizione al 1° anno (né corso nel database)
            continue
        x, det = offerte[recente]["x"], offerte[recente]["det"]
        durata = _durata(det, x.get("tipo_corso_cod"))
        coorti_group = sorted({y for ys in coorti.values() for y in ys})
        insegnamenti: dict[str, dict] = {}
        contenitori: dict[str, set[str]] = {}
        percorsi_nomi: set[str] = set()
        amm = None

        def aggiungi(cds: str, y: int, k: int, nota_anno: str | None):
            nonlocal amm
            o = offerte[(cds, y)]
            if amm is None and y == anno:
                amm = ammissione.da_catalogo(o["det"], f"{BASE}/corsi/{anno}/{o['x'].get('cod')}")
            n_perc = len([p for p in o["det"].get("percorsi") or []
                          if not _e_comune(p, (p.get("des_it") or p.get("pdsDes") or "").strip())])
            # le sezioni «altreAttivita» e «anno 0» elencano le attività di tutti gli anni accademici, anche quelle che il
            # piano ha già in un anno numerato (stesso codice o stesso nome, es. due codici dell'inglese B1) e che
            # ripetono per ogni a.a. in cui sono erogate: valgono solo quelle che il piano numerato non ha, e una
            # volta sola (nel primo a.a. della coorte in cui sono erogate)
            in_piano: set[str] = set()
            primo_aa: dict[str, int] = {}
            for _, _, n_, a_, _ in _attivita(o["det"]):
                if a_ is None:
                    continue
                if str(n_).isdigit() and int(n_) > 0:
                    in_piano.add(str(a_.get("adCod")))
                    in_piano.add(_nome_piano(a_.get("des_it")))
            for _, _, n_, a_, _ in _attivita(o["det"]):
                if a_ is None or (str(n_).isdigit() and int(n_) > 0):
                    continue
                try:
                    aa_ = int(a_.get("aa"))
                except (TypeError, ValueError):
                    continue
                if aa_ >= y:
                    primo_aa[str(a_.get("adCod"))] = min(aa_, primo_aa.get(str(a_.get("adCod")), aa_))
            for pnome, comune, anno_a, att, grp in _attivita(o["det"]):
                if att is None:  # gruppo senza attività: i CFU stanno nell'etichetta
                    voce = _voce_etichetta(grp)
                    if not voce:
                        continue
                    # le sezioni senza anno («anno 0») sono dell'ultimo anno del corso
                    if str(anno_a).isdigit() and int(anno_a) > 0:
                        if int(anno_a) != k:
                            continue
                    elif k != durata:
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
                        pnome = cineca_catalogue._titolo(pnome)
                        item["_percorsi"].add(pnome)
                        percorsi_nomi.add(pnome)
                    continue
                if str(anno_a).isdigit() and int(anno_a) > 0:
                    if int(anno_a) != k:
                        continue
                else:  # «altreAttivita» o anno 0: l'anno di corso è quello in cui l'attività è erogata
                    if str(att.get("adCod")) in in_piano or _nome_piano(att.get("des_it")) in in_piano:
                        continue
                    try:
                        if int(att.get("aa")) != y + k - 1 or int(att.get("aa")) != primo_aa.get(str(att.get("adCod"))):
                            continue
                    except (TypeError, ValueError):
                        continue
                if not (att.get("crediti") or 0):
                    # 0 CFU: il contenitore di un corso integrato (i CFU sono nei moduli, elencati a parte), una prova
                    # pratica valutativa o un test: non sono insegnamenti con crediti
                    moduli = [f.get("adCod") for f in att.get("adFiglie") or []] + [
                        z.get("adCod") for z in grp.get("attivita") or []
                        if (z.get("adPadre") or {}).get("adCod") == att.get("adCod")]
                    if moduli:  # l'appello dell'integrato vale per i suoi moduli
                        contenitori.setdefault(str(att.get("adCod")), set()).update(m for m in moduli if m)
                    continue
                ad = att.get("adCod") or att.get("cod")
                key = f"{k}:{ad}"
                item = insegnamenti.get(key)
                if not item:
                    docenti = [cineca_catalogue._nome(d.get("des")) for d in att.get("docenti") or [] if d.get("des")]
                    item = {
                        "codice": ad, "nome": _pulisci_nome(att.get("des_it") or ad), "anno": k,
                        "periodo": cineca_catalogue._periodo(att.get("periodo_didattico_it")),
                        "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                        "periodo_fine": att.get("data_fine_periodo_didattico"),
                        "cfu": att.get("crediti"), "ssd": None,
                        "obbligatorio": (att.get("tipo_ins_cod") == "OBB" and not _a_scelta(grp)) or _per_intero(grp),
                        "curriculum": None, "_percorsi": set(), "_comune": False,
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
                            "params": parametri(att, y), "items": [], "ad": str(ad),
                            "nome": (gruppo_di.get(cds), _norm(item["nome"]))})["items"].append(item)
                if comune:
                    item["_comune"] = True
                elif n_perc > 1 and pnome:
                    pnome = cineca_catalogue._titolo(pnome)
                    item["_percorsi"].add(pnome)
                    percorsi_nomi.add(pnome)

        voci_sole: dict[int, dict[str, dict]] = {}
        for k in range(1, durata + 1):
            y = anno - k + 1
            # coorte giusta; se il catalogo non la ha, o non vi pubblica le attività di quest'anno di corso,
            # il piano della coorte più vicina che le ha (con una nota)
            ordine = ([y] if any(y in coorti[cds] for cds in codici) else []) +                 [v for v in sorted(coorti_group, key=lambda v: (abs(v - y), -v)) if v != y]
            for yy in ordine:
                nota = None
                if yy != y and y in {v for ys in coorti.values() for v in ys}:
                    nota = (f"Piano della coorte {yy}: il catalogo non pubblica ancora le attività della coorte {y} "
                            f"per questo anno")
                elif yy != y:
                    nota = (f"Piano della coorte {yy}: insegnamento erogato nell'a.a. {fmt(yy + k - 1)}"
                            if yy + k - 1 > anno else
                            f"Piano della coorte {yy}: il catalogo non ha la coorte {y}")
                prima = set(insegnamenti)
                for cds in codici:
                    if yy in coorti[cds]:
                        aggiungi(cds, yy, k, nota)
                nuove = {kk: v for kk, v in insegnamenti.items() if kk not in prima}
                if any(i["anno"] == k and not i.get("_etichetta") for i in insegnamenti.values()):
                    break
                # una coorte con soli gruppi a scelta senza attività non basta: si cerca il piano di un'altra
                # coorte (le voci delle etichette si tengono solo se nessuna ha le attività)
                for kk in nuove:
                    if nuove[kk].get("_etichetta"):
                        voci_sole.setdefault(k, {}).setdefault(kk, insegnamenti.pop(kk))
            else:
                for kk, v in voci_sole.get(k, {}).items():
                    insegnamenti.setdefault(kk, v)
        ins = list(insegnamenti.values())
        _nomi_etichette(ins)
        for i in ins:
            ps = i.pop("_percorsi")
            comune = i.pop("_comune")
            if percorsi_nomi and ps and not comune and ps != percorsi_nomi:
                i["curriculum"] = ", ".join(sorted(ps))
        _omonimi(ins)
        corsi_out.append({
            "nome": cineca_catalogue._titolo(x.get("des_it") or ""),
            "classe": cineca_catalogue._classe(det.get("classe_cod") or x.get("classe_cod")),
            "tipo_catalogo": x.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": x.get("sedeDenominazioneComune") or x.get("sede_des_it"),
            "codice_ateneo": x.get("cdsCod"), "codici_catalogo": sorted(codici),
            "url": f"{BASE}/corsi/{recente[1]}/{x.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "contenitori": {k: sorted(v) for k, v in sorted(contenitori.items())} or None,
            "fonte": BASE, "verificato_il": oggi, "insegnamenti": ins,
        })
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    # --- libri dai syllabus ----------------------------------------------------------------------
    def libri_syllabus(sy) -> list[dict]:
        if not isinstance(sy, dict):
            return []
        sy = uniss_testi._normalizza(sy)  # entità HTML annidate («dell&amp;#39;»)
        libri = cineca_catalogue._testi_syllabus(sy)[0] or uniss_testi.libri_uniss(sy) or unica_testi.libri_unica(sy)
        return [b for b in libri if uniss_testi.e_citazione(b["citazione"])]

    def con_nota(libri: list[dict], nota: str) -> list[dict]:
        return [dict(b, note=f"{nota}; {b['note']}" if b.get("note") else nota) for b in libri]

    def cerca_libri(job: dict) -> tuple[list[dict], dict | None]:
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        libri = libri_syllabus(sy)
        if libri or not isinstance(sy, dict):
            return libri, sy if isinstance(sy, dict) else None
        m = sy.get("mutuaDa")
        if isinstance(m, dict) and m.get("adId"):  # mutuato: il programma è quello dell'insegnamento di origine
            sy2 = c.get("/insegnamento", {"anno": m.get("aaOffId"), "insegnamento": m.get("adId"),
                                          "corso_cod": m.get("cdsId"), "ordinamento_aa": m.get("aaOrdId"),
                                          "af_percorso": m.get("pdsId")})
            libri = libri_syllabus(sy2)
            if libri:
                return con_nota(libri, f"Dal programma di «{(sy2 or {}).get('des_it', '').title()}», da cui questo "
                                       f"insegnamento è mutuato"), sy
        try:
            aa = int(sy.get("aa"))
        except (TypeError, ValueError):
            return [], sy
        for prec in range(aa - 1, aa - 5, -1):  # programma dell'a.a. precedente dello stesso insegnamento
            pari = (indice_ad.get(str(sy.get("adCod")), {}).get(prec) or []) + [
                q for q in indice_nome.get(job["nome"], {}).get(prec) or [] if q["insegnamento"] != sy.get("cod")]
            for par in pari:
                libri = libri_syllabus(c.get("/insegnamento", {k: v for k, v in par.items() if v not in (None, "")}))
                if libri:
                    return con_nota(libri, f"Dal programma dell'a.a. {fmt(prec)}: la scheda {fmt(aa)} non riporta "
                                           f"la bibliografia"), sy
        return [], sy

    def lavora(job: dict):
        try:
            prec = next((precedente[i["url"]] for i in job["items"] if i.get("url") in precedente), None)
            if prec is not None:  # syllabus già letto in una raccolta precedente: stessi libri e stesso programma
                return job, (prec.get("libri") or [], {"tipoEsaDes_it": prec.get("modalita_esame"), "ssd": prec.get("ssd"),
                                                       "urlSitoWeb": prec.get("url_sito")})
            return job, cerca_libri(job)
        except Exception as e:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            log(f"[{uid}]   syllabus {job['ad']} saltato: {e!r}")
            return job, None

    trovati = 0
    # le richieste restano al massimo 2 al secondo (il client le distanzia); più thread coprono la latenza
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
            if n % 200 == 0:
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
    # ordinamenti che il database non ha (nessuna iscrizione 2026/27): non si creano
    doc["corsi"] = [cs for cs in doc["corsi"] if cs.get("id")]
    for cs in doc["corsi"]:
        _id_unici(cs)
    return doc


def _slug(s: str, maxlen: int = 40) -> str:
    return re.sub(r"[^a-z0-9]+", "-", unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
                  ).strip("-")[:maxlen].strip("-")


def _id_unici(cs: dict) -> None:
    """Lo stesso codice può essere erogato a più anni di corso (coorti diverse): il primo anno tiene l'id
    solito (corso + codice), gli altri anni «-aN»."""
    viste: set[str] = set()
    for i in sorted(cs["insegnamenti"], key=lambda i: (i.get("anno") or 99)):
        cod = i.get("codice") or i["nome"]
        if cod in viste:
            i["id"] = f"{cs['id']}-{_slug(str(cod))}-a{i.get('anno')}"
        viste.add(cod)


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso del catalogo l'`id` del corso già nel database (stessa denominazione e tipo)."""
    p = ROOT / "database" / "corsi" / "unica.json"
    if not p.exists():
        return 0
    db = json.loads(p.read_text(encoding="utf-8"))["corsi"]
    forzati = set(FORZA_ID.values())
    per_chiave: dict[tuple[str, str], list[dict]] = {}
    for d in db:
        if d["id"] in forzati:
            continue
        tipo = "L" if d.get("tipo") in ("L", "LP") else d.get("tipo")
        per_chiave.setdefault((_chiave_corso(d["nome"]), tipo), []).append(d)
    n = 0
    for cc in corsi:
        forzato = next((FORZA_ID[k] for k in cc["codici_catalogo"] if k in FORZA_ID), None)
        if forzato:
            cc["id"] = forzato
            n += 1
            continue
        cand = per_chiave.get((_chiave_corso(cc["nome"]), FAMIGLIA[cc["tipo_catalogo"]]), [])
        if len(cand) == 1:
            cc["id"] = cand[0]["id"]
            n += 1
        else:
            log(f"[unica]   corso del catalogo senza corso unico nel database: {cc['nome']} {cc['codici_catalogo']} "
                f"({len(cand)} candidati)")
    return n


# --- appelli ---------------------------------------------------------------------------------
def _inizio_aa(oggi=None):
    import datetime
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def fetch_bacheca(uid: str = "unica", log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027", solo_dip: set[str] | None = None):
    """Bacheca degli appelli dell'offerta di Esse3 (ListaAppelliOfferta), un corso di studio per volta
    (la bacheca per dipartimento ha solo gli appelli dell'attività, senza il corso). Restituisce gli
    appelli per codice AD, i nomi dei corsi di studio in cui compare ogni codice e il titolo di ogni codice.
    Una richiesta ogni `pausa` secondi (0,6 s: meno di 2 al secondo)."""
    import html as _h
    import time as _t

    import requests

    from .esse3_appelli import HEADERS, _parse
    da = da or _inizio_aa().strftime("%d/%m/%Y")
    s = requests.Session()
    s.headers.update(HEADERS)
    r = s.get(ESSE3 + "/ListaAppelliOfferta.do", timeout=60)
    form = re.search(r'<form action="([^"]+)" id="formRicercaCds"', r.text)
    if r.status_code != 200 or not form:
        log(f"[{uid}] esse3: bacheca non raggiungibile (HTTP {r.status_code})")
        return {}, {}, {}
    url = ESSE3 + "/" + form.group(1).split(";")[0]
    base = {"data_da": da, "data_a": a, "TIPO_FORM": "1", "form_id_formRicercaCds": "formRicercaCds"}
    sel = re.search(r'<select id="selectionFacolta".*?</select>', r.text, re.S)
    facs = [v for v in re.findall(r'<option value="([^"]+)"', sel.group(0))] if sel else []
    appelli: dict[str, list[dict]] = {}
    origine: dict[str, set[str]] = {}
    titoli: dict[str, str] = {}
    n_cds = 0

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                _t.sleep(pausa)
                x = s.post(url, data=dati, timeout=180)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            _t.sleep(3 * (tentativo + 1))
        return None

    for fac in facs:
        if solo_dip and fac not in solo_dip:
            continue
        t = post({**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "",
                  "_fw_refresh-form": "selectionFacolta"})
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        cds = re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []
        for cod, etichetta in cds:
            t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
            if t is None:
                log(f"[{uid}] esse3: corso {cod} (dipartimento {fac}) non letto")
                continue
            n_cds += 1
            nome_cds = re.sub(r"^\s*\[\w+\]\s*", "", _h.unescape(etichetta)).strip()
            for ad, lst in _parse(t.replace("Date e ora del turno", "Data e ora del turno"),
                                  ESSE3 + "/ListaAppelliOfferta.do").items():
                origine.setdefault(ad, set()).add(nome_cds)
                titoli.setdefault(ad, lst[0].get("titolo") or "")
                viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(ad, [])}
                for x in lst:
                    k = (x["data"], x["ora"], x["tipo"])
                    if k not in viste:
                        viste.add(k)
                        appelli.setdefault(ad, []).append(x)
    log(f"[{uid}] esse3: {n_cds} corsi di studio, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli, origine, titoli


def _nome_ad(s: str | None) -> str:
    return _norm(re.sub(r"\(.*?\)", " ", s or ""))


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], corsi: list[dict],
                    log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (altro codice in un'altra coorte o in un altro
    corso) si attribuiscono all'insegnamento omonimo del corso di studio che li ospita in Esse3."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[str, dict[str, set[str]]] = {}
    for c in corsi:
        k = _chiave_corso(c["nome"])
        for i in c.get("insegnamenti") or []:
            if i.get("codice"):
                per_corso.setdefault(k, {}).setdefault(_nome_ad(i["nome"]), set()).add(i["codice"])
    out = {k: list(v) for k, v in appelli.items()}
    n = 0
    for ad, lst in appelli.items():
        if ad in codici:
            continue
        nome = _nome_ad(lst[0].get("titolo"))
        dest: set[str] = set()
        for nome_cds in origine.get(ad, ()):
            dest |= per_corso.get(_chiave_corso(nome_cds), {}).get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[unica] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


def appelli_contenitori(out: dict[str, list[dict]], corsi: list[dict], log=print) -> int:
    """Gli appelli di un corso integrato (codice del contenitore, senza CFU) sono quelli dei suoi moduli: si
    aggiungono ai moduli che non li hanno già. Restituisce il numero di moduli che li ricevono."""
    n = 0
    for c in corsi:
        for cont, moduli in (c.get("contenitori") or {}).items():
            for m in moduli:
                viste = {(e["data"], e["ora"], e["tipo"]) for e in out.get(m, [])}
                nuovi = [e for e in out.get(cont, []) if (e["data"], e["ora"], e["tipo"]) not in viste]
                if nuovi:
                    out.setdefault(m, []).extend(nuovi)
                    n += 1
    log(f"[unica] appelli degli integrati attribuiti ai moduli: {n}")
    return n


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli dell'a.a. in corso: bacheca dell'offerta per corso di studio, più quella per dipartimento
    (attività che non stanno in nessun corso di studio dell'offerta)."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    off, origine, _ = fetch_bacheca(uid, log=log)
    out = associa_appelli(off, origine, corsi, log=log) if corsi else off
    try:
        dip = per_dipartimento(uid, ESSE3, log=log)
    except Exception as e:  # noqa: BLE001
        log(f"[{uid}] esse3 per dipartimento: {e!r}")
        dip = {}
    for cod, lst in dip.items():
        v = out.setdefault(cod, [])
        viste = {(e["data"], e["ora"], e["tipo"]) for e in v}
        for e in lst:
            if (e["data"], e["ora"], e["tipo"]) not in viste:
                viste.add((e["data"], e["ora"], e["tipo"]))
                v.append(e)
    appelli_contenitori(out, corsi, log=log)
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti")
    return out
