"""Università degli Studi di Brescia: insegnamenti, libri e appelli.

Piani e syllabus: `https://unibs.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Rispetto all'adattatore comune (`cineca_catalogue`) UniBS richiede:

- coorti: dopo il riordino i codici dei corsi hanno il suffisso «R» (54451R nel 2026, 54451 prima):
  senza toglierlo, gli anni successivi al 1° si leggerebbero dal piano futuro (programmi 2027/28);
- libri: oltre a `testi_it` (testo libero), la bibliografia della biblioteca di ateneo in
  `testi_biblio_it` (`<li>Titolo / Autori. - ed. - Città : Editore, anno.</li>`) e i riferimenti con
  l'editore indicato che il riconoscimento comune scarta; un insegnamento mutuato (`mutuaDa`) usa il
  programma dell'insegnamento da cui è mutuato; un insegnamento integrato senza programma proprio,
  quelli dei suoi moduli; se il programma dell'a.a. non è pubblicato (o il syllabus manca, 404),
  l'ultimo programma pubblicato dello stesso insegnamento (stesso corso, a.a. precedenti) o dello
  stesso codice in un altro corso (repliche di sede); ogni libro così ottenuto lo dice in `note`;
- nomi: le professioni sanitarie hanno nel catalogo «Corso di Laurea in X», in Universitaly
  «X (abilitante alla professione sanitaria di Y)» (più le repliche di sede): si usa il nome di
  Universitaly perché build_db associ il piano al corso già presente;
- appelli (`fetch_appelli`): la bacheca di Esse3 per corso di studio (quella per dipartimento va in
  timeout per medicina), il calendario pubblico UP (unibs-public.prod.up.cineca.it, API senza login)
  e i calendari pubblicati sulle pagine «Studiare» dei corsi (fogli Google e Excel).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import datetime
import hashlib
import html
import json
import os
import pathlib
import re
import threading
import time

import requests

from . import cineca_catalogue as cc
from .esse3_appelli import HEADERS, _parse
from .testi import _libero, estrai_libri

BASE = "https://unibs.coursecatalogue.cineca.it"

# (corso, codice AD) → motivo per cui non si sono trovati libri (per il rapporto sulle lacune)
MOTIVI: dict[str, str] = {}
# codice AD di un insegnamento integrato → codici AD dei suoi moduli (il programma sta nei moduli)
MODULI: dict[str, set[str]] = {}

# nome nel catalogo («Corso di Laurea in …», senza il prefisso) → nome in Universitaly
NOMI_UNIVERSITALY = {
    'assistenza sanitaria':
        'Assistenza sanitaria (abilitante alla professione sanitaria di Assistente sanitario)',
    'dietistica':
        'Dietistica (abilitante alla professione sanitaria di Dietista)',
    'educazione professionale':
        'Educazione professionale (abilitante alla professione sanitaria di Educatore professionale)',
    'fisioterapia':
        'Fisioterapia (abilitante alla professione sanitaria di Fisioterapista)',
    'igiene dentale':
        'Igiene dentale (abilitante alla professione sanitaria di Igienista dentale)',
    'infermieristica':
        'Infermieristica (abilitante alla professione sanitaria di Infermiere)',
    'ortottica ed assistenza oftalmologica':
        'Ortottica ed assistenza oftalmologica (abilitante alla professione sanitaria di Ortottista ed assistente di oftalmologia)',
    'ostetricia':
        'Ostetricia (abilitante alla professione sanitaria di Ostetrica/o)',
    'tecnica della riabilitazione psichiatrica':
        'Tecnica della riabilitazione psichiatrica (abilitante alla professione sanitaria di Tecnico della riabilitazione psichiatrica)',
    "tecniche della prevenzione nell'ambiente e nei luoghi di lavoro":
        "Tecniche della prevenzione nell'ambiente e nei luoghi di lavoro (abilitante alla professione sanitaria di Tecnico della prevenzione nell'ambiente e nei luoghi di lavoro)",
    'tecniche di laboratorio biomedico':
        'Tecniche di laboratorio biomedico (abilitante alla professione sanitaria di Tecnico di laboratorio biomedico)',
    'tecniche di radiologia medica, per immagini e radioterapia':
        'Tecniche di radiologia medica, per immagini e radioterapia (abilitante alla professione sanitaria di Tecnico di radiologia medica)',
}


class ClientConCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE): una raccolta interrotta riparte da dove era."""

    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unibs" if d else None
        self._lk = threading.Lock()
        self.scheletri: dict[tuple[str, str], dict] = {}

    def get(self, path, params=None):
        dati = self._get_cache(path, params)
        if path == "/corsi":
            _senza_r(dati)
        elif path == "/insegnamento" and dati is None and params:
            # attività senza syllabus nel catalogo (404): si restituisce uno scheletro con i dati del piano,
            # così l'estrazione dei libri può cercare il programma negli anni precedenti
            dati = self.scheletri.get((str(params.get("anno")), str(params.get("insegnamento"))))
        return dati

    def _get_cache(self, path, params=None):
        if not self.cache:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.cache / key[:2] / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def _senza_r(x) -> None:
    """Dopo il riordino i codici dei corsi hanno il suffisso «R» (54451R nel 2026, 54451 nelle coorti
    precedenti): senza il suffisso le coorti si ritrovano con lo stesso codice."""
    if isinstance(x, dict):
        if isinstance(x.get("cdsCod"), str):
            x["cdsCod"] = re.sub(r"(?<=\d)R$", "", x["cdsCod"])
        for v in x.values():
            _senza_r(v)
    elif isinstance(x, list):
        for v in x:
            _senza_r(v)


# --- bibliografia della biblioteca (testi_biblio_it) --------------------------------------------

def _voce_biblio(li: str) -> dict | None:
    """«Titolo / Autori. - 5. ed. - Torino : Giappichelli, 2025.» → libro (titolo e autori solo
    se la voce ha la forma ISBD «titolo / responsabilità»; altrimenti titolo = citazione)."""
    li = re.sub(r"(?is)<a\b.*?</a>", "", li)
    txt = html.unescape(re.sub(r"<[^>]+>", " ", li)).replace("\xa0", " ")
    txt = re.sub(r"\s+", " ", txt).strip(" .;")
    if len(txt) < 8:
        return None
    titolo, autori, editore, anno, edizione = txt, None, None, None, None
    sep = re.split(r"\s+//?\s+", txt, maxsplit=1)
    if len(sep) == 2:
        titolo, resto = sep[0].strip(" .:"), sep[1]
        parti = [p.strip(" .") for p in re.split(r"\s+-\s+", resto)]
        autori = parti[0] or None
        for p in parti[1:]:
            if re.match(r"(?i)^\d+\.?\s*(?:ed|edizione)(?![a-z])", p):
                edizione = re.match(r"\d+", p).group(0)
            elif " : " in p:
                ed = p.rsplit(" : ", 1)[1]
                m = re.search(r"[\s,.]*(?:c|\[|©|©)?\s*((?:19|20)\d{2})(?!\d).*$", ed)
                if m:
                    anno = int(m.group(1))
                    ed = ed[:m.start()]
                editore = re.sub(r"[\s,.\[\]]+$", "", ed) or None
    if anno is None:
        ys = re.findall(r"(?<!\d)((?:19|20)\d{2})(?!\d)", txt)
        anno = int(ys[-1]) if ys else None
    titolo = titolo.replace("*", "")
    return {"titolo": titolo[:300], "autori": autori, "editore": editore, "anno": anno, "edizione": edizione,
            "isbn": None, "lingua": None, "tipo": None, "note": None, "citazione": txt}


def libri_da_biblio(sy: dict) -> list[dict]:
    out, viste = [], set()
    for t in sy.get("testiTotali") or []:
        b = t.get("testi_biblio_it") or ""
        for li in re.findall(r"(?is)<li\b[^>]*>(.*?)</li>", b):
            v = _voce_biblio(li)
            if v:
                k = re.sub(r"\W+", "", v["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    out.append(v)
    return out


def _testi_it(sy: dict) -> list[dict]:
    return estrai_libri(*[t.get("testi_it") or "" for t in sy.get("testiTotali") or []])


# Riferimenti che il riconoscimento comune scarta perché senza anno o virgole («Titolo - Autori - Ed.
# Martina», «Titolo di Autori. Edito da Piccin.», «Titolo / Autore / Editore: UTET» su più righe):
# si accettano solo con l'indicazione esplicita dell'editore e se non sono materiali del docente.
_EDITORE = re.compile(r"(?i)(?<![\w])(?:ed\.|ed\.\s?[A-Z]|editore|edito da|edizioni|casa editrice|editrice|"
                      r"edises|piccin|zanichelli|mcgraw|pearson|elsevier|edra|idelson|esculapio|martina|utet|"
                      r"giappichelli|cedam|il mulino|hoepli|springer|wiley|masson|ambrosiana|carocci|"
                      r"cortina|minerva|ermes|libreria|soc\. ed|societ[aà] editrice)(?![\w])")
_NON_RIF = re.compile(r"(?i)^\W*(si |ai fini|per i |per le |per gli |gli studenti|il docente|la docente|i docenti|saranno|"
                      r"verranno|sar[aà]|materiale|dispens|slides?\b|lucidi|appunti|diapositive|articoli|testi|"
                      r"documenti|nessun|non |vedere|vedi|moodle|sito|piattaforma|bibliografia|letture)")
_CONT = re.compile(r"(?i)^\W*(editore|casa editrice|anno( di)? edizione|edizione|isbn|ed\.|edito da|autori?\s*:)")
_AUTORI = re.compile(r"(?i)(?<!\w)autori?\s*:")
_ETICHETTA = re.compile(r"(?i)^\W*(bibliografia|testi( di riferimento| consigliati| adottati)?|libri? di testo|libri)\s*:\s*")


def _togli_materiale(r: str) -> str:
    """«Materiale fornito dal docente, Medicina interna di X, McGraw-Hill (2019)» → senza la prima parte."""
    if _NON_RIF.match(r) and (_EDITORE.search(r) or _AUTORI.search(r)):
        parti = re.split(r"(?:,|;|\.)\s+", r)
        while parti and _NON_RIF.match(parti[0]):
            parti.pop(0)
        return ", ".join(parti)
    return r


def libri_liberi(sy: dict) -> list[dict]:
    """Riferimenti con l'editore indicato, nel testo libero dei testi, non riconosciuti da `estrai_libri`."""
    out, viste = [], set()

    def aggiungi(b: str) -> None:
        if 15 <= len(b) <= 400 and re.search(r"[A-Za-zÀ-ÿ]{4}", b):
            k = re.sub(r"\WB+", "", b.lower())[:120]
            if k not in viste:
                viste.add(k)
                out.append(_libero(b))

    for tt in sy.get("testiTotali") or []:
        testo = re.sub(r"(?i)<\s*(br|/p|/li|/div)\s*/?>", "\n", tt.get("testi_it") or "")
        testo = html.unescape(re.sub(r"<[^>]+>", "", testo)).replace("\xa0", " ")
        for par in re.split(r"\n\s*\n", testo):
            righe: list[str] = []
            for riga in par.splitlines():
                riga = re.sub(r"\s+", " ", riga).strip(" -–•*·\t;")
                if not riga:
                    continue
                if righe and _CONT.match(riga):
                    righe[-1] += " " + riga
                else:
                    righe.append(riga)
            righe = [_ETICHETTA.sub("", r) for r in righe]
            righe = [_togli_materiale(r) for r in righe]
            righe = [r for r in righe if r and not _NON_RIF.match(r)]
            con = [r for r in righe if _EDITORE.search(r) or _AUTORI.search(r)]
            if not con:
                continue
            if len(con) == 1 and righe[-1] == con[0] and 2 <= len(righe) <= 3 and all(len(r) < 120 for r in righe[:-1]):
                aggiungi(" ".join(righe))  # titolo, autori ed editore su righe distinte
            else:
                for r in con:
                    aggiungi(r)
    return out


def _libri_sy(sy: dict) -> list[dict]:
    """Libri di un syllabus: testi riconosciuti, poi la bibliografia della biblioteca, poi i riferimenti liberi."""
    return _testi_it(sy) or libri_da_biblio(sy) or libri_liberi(sy)


def _inizio_aa(oggi: datetime.date | None = None) -> datetime.date:
    """1° ottobre dell'anno accademico in corso: gli appelli precedenti sono dell'a.a. passato."""
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def _cds(cod) -> str:
    """Codice del corso senza il suffisso «R» del riordino (54451R nel 2026, 54451 nelle coorti precedenti)."""
    return re.sub(r"(?<=\d)R$", "", str(cod or ""))


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print) -> dict:
    client = ClientConCache(BASE)

    # (anno offerta, codice attività) → parametri del syllabus, per gli insegnamenti mutuati; e
    # (corso, codice AD) → anno offerta → parametri, per ritrovare il syllabus dell'a.a. precedente
    noti: dict[tuple[str, str], dict] = {}
    per_ad: dict[tuple[str, str], dict[str, dict]] = {}
    per_cod: dict[str, dict[str, dict[str, dict]]] = {}  # codice AD → anno offerta → corso → parametri
    if syllabus:
        for y in range(anno - 5, anno + 1):
            lst = client.get("/corsi", {"anno": y, "minimal": "true"}) or []
            cds: list[dict] = []
            cc._walk_cds(lst, cds)
            for x in cds:
                if str(x.get("aa")) != str(y):
                    continue
                d = client.get(f"/corso/{y}/{x['cod']}")
                if isinstance(d, list):
                    d = d[0] if d else None
                for p in (d or {}).get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in a.get("insegnamenti") or ([{"attivita": a.get("attivita") or []}]):
                            for att in g.get("attivita") or []:
                                par = {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                       "ordinamento_aa": att.get("ordinamento_aa"),
                                       "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"),
                                       "corso_aa": y, "schema_id": att.get("schemaId")}
                                noti.setdefault((str(att.get("aa")), str(att.get("cod"))), par)
                                client.scheletri.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                    "aa": str(att.get("aa")), "cod": att.get("cod"), "adCod": att.get("adCod"),
                                    "cdsCod": att.get("cdsCod"), "des_it": att.get("des_it"), "testiTotali": [],
                                    "adFiglie": att.get("adFiglie") or [], "mutuaDa": None})
                                per_ad.setdefault((_cds(att.get("cdsCod")), str(att.get("adCod"))), {}).setdefault(
                                    str(att.get("aa")), par)
                                per_cod.setdefault(str(att.get("adCod")), {}).setdefault(
                                    str(att.get("aa")), {}).setdefault(_cds(att.get("cdsCod")), par)
        log(f"[{uid}] attività note per mutuazioni e anni precedenti: {len(noti)}")

    def leggi(par: dict) -> dict | None:
        s2 = client.get("/insegnamento", {k: v for k, v in par.items() if v not in (None, "")})
        return s2 if isinstance(s2, dict) else None

    def pubblicato(sy: dict) -> bool:
        """Il syllabus ha almeno un testo (anche «nessun libro»): altrimenti non è ancora compilato."""
        return any((t.get("testi_it") or "").strip() or (t.get("testi_biblio_it") or "").strip()
                   for t in sy.get("testiTotali") or [])

    def libri_extra(sy: dict) -> list[dict]:
        for f in sy.get("adFiglie") or []:
            if f.get("adCod"):
                MODULI.setdefault(str(sy.get("adCod")), set()).add(str(f["adCod"]))
        libri = libri_da_biblio(sy) or libri_liberi(sy)
        if libri:
            return libri
        m = sy.get("mutuaDa") or {}
        par = noti.get((str(m.get("aa")), str(m.get("cod")))) if m else None
        s2 = leggi(par) if par else None
        if s2:
            libri = _libri_sy(s2)
            if libri or pubblicato(s2):
                return libri
        chiave = f"{sy.get('cdsCod')}|{sy.get('adCod')}|{sy.get('des_it')}"
        if pubblicato(sy):  # il programma c'è e non indica libri: niente da aggiungere
            MOTIVI[chiave] = "programma pubblicato senza libri"
            return []
        # syllabus dell'a.a. in corso non ancora compilato: l'ultimo programma pubblicato dello stesso
        # insegnamento (stesso corso e codice) negli anni accademici precedenti
        aa = int(sy.get("aa") or anno)
        for prec in (aa - 1, aa - 2, aa - 3):
            par = per_ad.get((_cds(sy.get("cdsCod")), str(sy.get("adCod"))), {}).get(str(prec))
            s2 = leggi(par) if par else None
            if not s2:
                continue
            libri = _libri_sy(s2)
            if libri:
                nota = (f"Dal programma dell'a.a. {prec}/{(prec + 1) % 100:02d}: il programma {aa}/{(aa + 1) % 100:02d} "
                        f"non è ancora pubblicato ({BASE}{s2.get('url') or ''})")
                return [dict(x, note=nota) for x in libri]
            if pubblicato(s2):
                MOTIVI[chiave] = f"programma {prec} pubblicato senza libri"
                return []
        # lo stesso insegnamento (codice AD) in un altro corso di studio, a parità di a.a. e poi negli
        # anni precedenti: le repliche di sede e gli insegnamenti comuni a più corsi hanno il programma
        # pubblicato soltanto in uno dei corsi
        mio = _cds(sy.get("cdsCod"))
        for anno_off in (aa, aa - 1, aa - 2):
            cand = per_cod.get(str(sy.get("adCod")), {}).get(str(anno_off), {})
            ordine = sorted((c for c in cand if c != mio),
                            key=lambda c: (-len(os.path.commonprefix([c, mio])), c))[:6]
            for c in ordine:
                s2 = leggi(cand[c])
                if not s2:
                    continue
                libri = _libri_sy(s2)
                if libri:
                    nota = (f"Dal programma dello stesso insegnamento (codice {sy.get('adCod')}) nel corso "
                            f"«{(s2.get('corso_des_it') or '').strip().title()}», a.a. {anno_off}/{(anno_off + 1) % 100:02d}: "
                            f"questo corso non ha un programma pubblicato ({BASE}{s2.get('url') or ''})")
                    return [dict(x, note=nota) for x in libri]
        MOTIVI[chiave] = "programma non pubblicato (né quest'anno né negli anni precedenti)"
        return []

    doc = cc.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log, client=client,
                          libri_extra=libri_extra)
    for c in doc["corsi"]:
        # insegnamenti integrati senza programma proprio: i libri dei moduli
        per_codice = {i["codice"]: i for i in c["insegnamenti"] if i.get("codice")}
        for i in c["insegnamenti"]:
            if i.get("libri") or str(i.get("codice")) not in MODULI:
                continue
            viste = set()
            for mod in sorted(MODULI[str(i["codice"])]):
                f = per_codice.get(mod)
                for lb in (f or {}).get("libri") or []:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        nota = f"Dal programma del modulo «{f['nome']}» dell'insegnamento integrato"
                        i["libri"].append(dict(lb, note=f"{nota}; {lb['note']}" if lb.get("note") else nota))
            if i["libri"]:
                i["stato_libri"] = "completo"
    for c in doc["corsi"]:
        for i in c["insegnamenti"]:  # frasi generiche («possono fare riferimento ai testi di …, pubblicati da …»)
            giusti = [lb for lb in i.get("libri") or []
                      if not re.search(r"(?i)possono fare riferimento ai testi", lb.get("citazione") or "")]
            if len(giusti) != len(i.get("libri") or []):
                i["libri"] = giusti
                i["stato_libri"] = "completo" if giusti else "da_aggiungere"
    for c in doc["corsi"]:
        base = re.sub(r"(?i)^\s*corso di laurea(?: magistrale)?(?: a ciclo unico)? in\s+", "", c["nome"]).strip().lower()
        if base in NOMI_UNIVERSITALY:
            c["nome"] = NOMI_UNIVERSITALY[base]
    return doc


# --- appelli d'esame: Bacheca appelli per corso di studio (ListaAppelliOfferta.do) -----------------

ESSE3 = "https://unibs.esse3.cineca.it/ListaAppelliOfferta.do"


def fetch_bacheca(uid: str, log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027") -> tuple[dict[str, list[dict]], dict[str, set[str]]]:
    """La bacheca di Esse3 per dipartimento (PaginaListaAppelli) va in timeout per i dipartimenti con
    molti corsi (medicina): la bacheca dell'offerta si interroga per corso di studio (data da/a).
    Restituisce gli appelli per codice AD e, per ogni codice, i codici dei corsi di studio in cui compare."""
    da = da or _inizio_aa().strftime("%d/%m/%Y")
    s = requests.Session()
    s.headers.update(HEADERS)
    r = s.get(ESSE3, timeout=60)
    form = re.search(r'<form action="([^"]+)" id="formRicercaCds"', r.text)
    if r.status_code != 200 or not form:
        log(f"[{uid}] esse3: bacheca non raggiungibile (HTTP {r.status_code})")
        return {}, {}
    url = "https://unibs.esse3.cineca.it/" + form.group(1).split(";")[0]
    base = {"data_da": da, "data_a": a, "TIPO_FORM": "1", "form_id_formRicercaCds": "formRicercaCds"}
    sel = re.search(r'<select id="selectionFacolta".*?</select>', r.text, re.S)
    facs = [v for v in re.findall(r'<option value="([^"]+)"', sel.group(0))] if sel else []
    appelli: dict[str, list[dict]] = {}
    origine: dict[str, set[str]] = {}
    n_cds = 0

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                x = s.post(url, data=dati, timeout=180)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            time.sleep(3 * (tentativo + 1))
        return None

    for fac in facs:
        t = post({**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "", "_fw_refresh-form": "selectionFacolta"})
        time.sleep(pausa)
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        cds = re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []
        for cod, etichetta in cds:
            t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
            time.sleep(pausa)
            if t is None:
                log(f"[{uid}] esse3: corso {cod} (dipartimento {fac}) non letto")
                continue
            n_cds += 1
            cod_cds = re.match(r"\s*\[(\w+)\]", html.unescape(etichetta))
            # l'intestazione della bacheca dell'offerta è «Date e ora del turno» (il lettore comune cerca «data»)
            for ad, lst in _parse(t.replace("Date e ora del turno", "Data e ora del turno"), ESSE3).items():
                if cod_cds:
                    origine.setdefault(ad, set()).add(cod_cds.group(1))
                viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(ad, [])}
                for x in lst:
                    k = (x["data"], x["ora"], x["tipo"])
                    if k not in viste:
                        viste.add(k)
                        appelli.setdefault(ad, []).append(x)
    log(f"[{uid}] esse3: {n_cds} corsi di studio, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli, origine


def _nome_ad(s: str) -> str:
    s = re.sub(r"[’‘`´]", "'", s or "").lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], corsi: list[dict],
                    log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (codici diversi tra Esse3 e Course
    Catalogue) si attribuiscono all'insegnamento omonimo dello stesso corso di studio (stesso codice
    corso, stesso nome); il resto lo associa build_db per nome e docenti."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[str, dict[str, set[str]]] = {}
    for c in corsi:
        k = _cds(c.get("codice_ateneo"))
        for i in c.get("insegnamenti") or []:
            if i.get("codice"):
                per_corso.setdefault(k, {}).setdefault(_nome_ad(i["nome"]), set()).add(i["codice"])
    out = {k: list(v) for k, v in appelli.items()}
    n = 0
    for ad, lst in appelli.items():
        if ad in codici:
            continue
        nome = _nome_ad(lst[0].get("titolo") or "")
        dest: set[str] = set()
        for cds in origine.get(ad, ()):
            dest |= per_corso.get(_cds(cds), {}).get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[unibs] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


def combina_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], corsi: list[dict],
                    altre: list[dict[str, list[dict]]], log=print) -> dict[str, list[dict]]:
    """Esse3 (con codici riallineati al catalogo), poi le altre fonti: una data già presente per lo stesso
    insegnamento e tipo (anche con un altro orario) non si ripete."""
    out = associa_appelli(appelli, origine, corsi, log=log) if corsi else {k: list(v) for k, v in appelli.items()}
    for fonte in altre:
        for cod, lst in fonte.items():
            v = out.setdefault(cod, [])
            viste = {(e["data"], e["tipo"]) for e in v}
            for e in lst:
                if (e["data"], e["tipo"]) not in viste:
                    viste.add((e["data"], e["tipo"]))
                    v.append(e)
    return out


def fetch_appelli(uid: str, corsi: list | None = None, log=print, **kw) -> dict[str, list[dict]]:
    """Appelli: bacheca di Esse3, calendario pubblico UP e calendari pubblicati dai corsi di studio."""
    appelli, origine = fetch_bacheca(uid, log=log, **kw)
    altre = [fetch_up(uid, log=log)]
    if corsi:
        altre.append(fetch_fogli(uid, corsi, log=log))
    return combina_appelli(appelli, origine, corsi or [], altre, log=log)


# --- appelli dal calendario pubblico di ateneo (UP Public, Cineca) --------------------------------

UP = "https://unibs-public.prod.up.cineca.it"
_MODALITA_UP = {"O": "orale", "S": "scritto", "SOC": "scritto+orale", "UD": None}


def _ora_roma(iso: str) -> tuple[str, str]:
    """«2027-01-21T08:00:00.000Z» (UTC) → ("2027-01-21", "09:00") ora di Roma (CET/CEST senza tzdata)."""
    d = datetime.datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S")

    def ultima_domenica(anno: int, mese: int) -> datetime.datetime:
        g = datetime.datetime(anno, mese, 31 if mese in (3, 10) else 30, 1)
        while g.weekday() != 6:
            g -= datetime.timedelta(days=1)
        return g
    estate = ultima_domenica(d.year, 3) <= d < ultima_domenica(d.year, 10)
    d += datetime.timedelta(hours=2 if estate else 1)
    return d.strftime("%Y-%m-%d"), d.strftime("%H:%M")


def fetch_up(uid: str, log=print, da: str | None = None, a: str = "2027-12-31",
             pausa: float = 0.4) -> dict[str, list[dict]]:
    """Esami del calendario pubblico (UP Public): per codice dell'attività formativa (`codiceAF`, lo stesso
    del Course Catalogue). Un corso per volta (senza il corso l'API non restituisce l'elenco)."""
    da = da or _inizio_aa().isoformat()
    s = requests.Session()
    s.headers.update({**HEADERS, "Accept": "application/json"})
    corsi: dict[str, dict] = {}
    for q in list("abcdefghijklmnopqrstuvwxyz0123456789"):
        for campo in ("descrizione", "codice"):
            try:
                r = s.get(UP + "/api/Corsi/getPerAutoCompletePublic", timeout=60,
                          params={"valore": q, "lookupFields": campo, "ricerca": "esami"})
                for c in r.json():
                    corsi[c["id"]] = c
            except (requests.RequestException, ValueError):
                pass
            time.sleep(pausa / 2)
    log(f"[{uid}] UP Public: {len(corsi)} corsi nel calendario esami")
    out: dict[str, list[dict]] = {}
    n = 0
    for c in sorted(corsi.values(), key=lambda c: c["codice"]):
        dati = None
        for tentativo in range(3):
            try:
                r = s.get(UP + "/api/Impegni/getImpegniPublic", timeout=180,
                          params={"ricerca": "esami", "corso": c["id"], "dataInizio": da + "T00:00:00.000Z",
                                  "dataFine": a + "T23:00:00.000Z"})
                if r.status_code == 200:
                    dati = r.json()
                    break
            except (requests.RequestException, ValueError):
                pass
            time.sleep(3 * (tentativo + 1))
        time.sleep(pausa)
        if not isinstance(dati, list):
            log(f"[{uid}] UP Public: corso {c['codice']} non letto")
            continue
        for x in dati:
            if x.get("stato") != "P" or x.get("indisponibilita"):
                continue
            ev = x.get("evento") or {}
            dd = (ev.get("dettagliDidattici") or [{}])[0]
            ad = dd.get("codiceAF") or dd.get("codice")
            if not ad:
                continue
            data, ora = _ora_roma(x["dataInizio"])
            if data < da:
                continue
            ta = (ev.get("tipoAttivita") or {}).get("codice")
            nome = dd.get("nome") or ""
            tipo = "prova_in_itinere" if ta == "UD" or re.search(r"(?i)parzial|itinere|esonero", nome) else "appello"
            aule = [", ".join(p for p in ((au.get("descrizione") or "").strip(),
                                          ((au.get("edificio") or {}).get("descrizione") or "").strip()) if p)
                    for au in x.get("aule") or []]
            docenti = "; ".join(f"{(d.get('cognome') or '').strip()} {(d.get('nome') or '').strip()}".strip()
                                for d in x.get("docenti") or [])
            e = {"tipo": tipo, "titolo": None, "data": data, "ora": ora,
                 "luogo": "; ".join(dict.fromkeys(a for a in aule if a)) or None,
                 "modalita": _MODALITA_UP.get(ta), "iscrizioni_dal": None, "iscrizioni_al": None,
                 "docenti": docenti or None, "note": None, "fonte": UP + "/"}
            vecchi = out.setdefault(str(ad), [])
            if not any((v["data"], v["ora"], v["tipo"]) == (data, ora, tipo) for v in vecchi):
                vecchi.append(e)
                n += 1
    log(f"[{uid}] UP Public: {n} date per {len(out)} attività")
    return out


# --- calendari degli appelli pubblicati sui siti dei corsi (fogli Google e Excel) ------------------

SITO_CORSI = "https://corsi.unibs.it"
# sito del corso (corsi.unibs.it/it/<sito>/studiare) → codice del corso di studio (senza «R»)
SITI_CDS = {
    "assistenzasanitaria": "08691", "dietistica": "08692", "educazioneprofessionale": "08693",
    "fisioterapia": "08694", "igienedentale": "08695", "infermieristica": "08696", "ostetricia": "08697",
    "scienzeinfermieristicheostetriche": "08698", "ortottica": "08699", "prevenzionelavoro": "08714",
    "riabilitazionepsichiatrica": "08715", "laboratoriobiomedico": "08716", "radiologiamedica": "08717",
    "ambienteeterritoriomagistrale": "05851", "civilandenvironmentalengineering": "05853",
    "civilemagistrale": "05841", "edilearchitettura": "05781", "ingegneriaambienteeterritorio": "05721",
    "ingegneriacivile": "05731", "sistemiagricolisostenibili": "05722", "tecnichedelledilizia": "05724",
    "transizioneecologicaagricoltura": "05854", "automazione": "05751", "automazionemagistrale": "05881",
    "gestionale": "05771", "gestionalemagistrale": "05891", "innovazionematerialieprodottomagistrale": "05872",
    "meccanicaemateriali": "05742", "meccanicamagistrale": "05861", "tecnichediprodottoeprocesso": "05743",
}
_MESI = {"gennaio": 1, "febbraio": 2, "marzo": 3, "aprile": 4, "maggio": 5, "giugno": 6, "luglio": 7,
         "agosto": 8, "settembre": 9, "ottobre": 10, "novembre": 11, "dicembre": 12}
# finestre ((mese, giorno) di inizio e di fine) in cui cadono le sessioni dei fogli dei corsi sanitari
_FINESTRE = {"FEB": ((1, 7), (3, 20)), "PAS": ((3, 10), (5, 5)), "EST": ((5, 25), (7, 31)),
             "AUT": ((8, 20), (10, 15)), "NAT": ((12, 1), (12, 31))}


def _xlsx_celle(dati: bytes) -> list[list[dict]]:
    """Fogli di un .xlsx come righe {colonna: testo | numero}, con la sola libreria standard."""
    import io
    import xml.etree.ElementTree as ET
    import zipfile
    ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    z = zipfile.ZipFile(io.BytesIO(dati))
    cond = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall(ns + "si"):
            cond.append("".join(t.text or "" for t in si.iter(ns + "t")))
    fogli = []
    for nome in sorted(n for n in z.namelist() if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n)):
        righe = []
        for riga in ET.fromstring(z.read(nome)).iter(ns + "row"):
            celle: dict = {}
            for c in riga.findall(ns + "c"):
                col = re.match(r"[A-Z]+", c.get("r") or "")
                v = c.find(ns + "v")
                if not col or v is None or v.text in (None, ""):
                    continue
                celle[col.group(0)] = cond[int(v.text)] if c.get("t") == "s" else float(v.text)
            if celle:
                righe.append(celle)
        fogli.append(righe)
    return fogli


def _pezzi_cella(cella: str) -> list[tuple[str, str | None, str | None]]:
    """«9:00 Elementi di analisi;  Macchine a fluido - scritto 1» → [(nome, modalità, ora)]."""
    out = []
    for p in re.split(r"[;\n]+", cella or ""):
        p = re.sub(r"\s+", " ", p).strip()
        if not p:
            continue
        ora = re.search(r"(?<!\d)(\d{1,2})[:.](\d{2})(?!\d)", p)
        mod = None
        if re.search(r"(?i)scritt", p) and re.search(r"(?i)oral", p):
            mod = "scritto+orale"
        elif re.search(r"(?i)scritt", p):
            mod = "scritto"
        elif re.search(r"(?i)oral", p):
            mod = "orale"
        p = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", p)
        p = re.sub(r"(?i)\b(?:ore|h\.?)\s*\d{1,2}(?:[:.]\d{2})?(?:\s*[-–]\s*\d{1,2}(?:[:.]\d{2})?)?", " ", p)
        p = re.sub(r"(?<!\d)\d{1,2}[:.]\d{2}(?:\s*[-–]\s*\d{1,2}[:.]\d{2})?", " ", p)
        p = re.sub(r"(?i)\s*[-–]?\s*\b(?:prova\s+)?(?:scritto|scritta|orale)\b\s*\d*", " ", p)
        p = re.sub(r"\s+", " ", p).strip(" -–,.")
        if len(p) >= 4:
            out.append((p, mod, f"{int(ora.group(1)):02d}:{ora.group(2)}" if ora else None))
    return out


def _data_it(testo: str) -> datetime.date | None:
    m = re.search(r"(\d{1,2})\s+([a-zì]+)\s+(\d{4})", (testo or "").lower())
    if not m or m.group(2) not in _MESI:
        return None
    try:
        return datetime.date(int(m.group(3)), _MESI[m.group(2)], int(m.group(1)))
    except ValueError:
        return None


def _date_sessione(cella: str, sessione: str, da: datetime.date) -> list[tuple[datetime.date, str | None]]:
    """Date di una cella dei fogli sanitari. I formati sono misti (g/m/aaaa digitato, m/g/aaaa dei fogli
    Google): una data si accetta solo se UNA sola lettura cade nella finestra della sessione."""
    if "?" in cella:
        return []
    (m0, g0), (m1, g1) = _FINESTRE[sessione]
    out = []
    for m in re.finditer(r"(?<![\d/])(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})(?![\d/])", cella.replace("\n", " ")):
        a, b, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        y += 2000 if y < 100 else 0
        ok = set()
        for mese, giorno in ((b, a), (a, b)):
            try:
                d = datetime.date(y, mese, giorno)
            except ValueError:
                continue
            if (m0, g0) <= (d.month, d.day) <= (m1, g1) and d >= da and d.year <= da.year + 1:
                ok.add(d)
        if len(ok) == 1:
            resto = cella[m.end():m.end() + 25]
            ora = re.search(r"(?:ore|h\.?)\s*(\d{1,2})(?:[:.,](\d{2}))?", resto, re.I)
            out.append((next(iter(ok)), f"{int(ora.group(1)):02d}:{ora.group(2) or '00'}" if ora else None))
    return out


def fetch_fogli(uid: str, corsi: list[dict], log=print, da: datetime.date | None = None,
                pausa: float = 0.5) -> dict[str, list[dict]]:
    """Appelli dai calendari pubblicati sulle pagine «Studiare» dei corsi (corsi.unibs.it): fogli Google
    (sanitari: per codice; ingegneria e agraria: per nome) e fogli Excel dei corsi di ingegneria
    industriale. Restituisce gli esami per codice dell'insegnamento del catalogo."""
    import csv
    import io
    import zipfile
    da = da or _inizio_aa()
    s = requests.Session()
    s.headers.update(HEADERS)
    per_corso: dict[str, list[dict]] = {}
    for c in corsi:
        per_corso.setdefault(_cds(c.get("codice_ateneo"))[:5], []).append(c)
    out: dict[str, list[dict]] = {}
    totale = [0]

    def aggiungi(cod: str, e: dict) -> None:
        v = out.setdefault(cod, [])
        if not any((x["data"], x["tipo"]) == (e["data"], e["tipo"]) for x in v):
            v.append(e)
            totale[0] += 1

    def esame(d: datetime.date, ora, mod, fonte: str) -> dict:
        return {"tipo": "appello", "titolo": None, "data": d.isoformat(), "ora": ora, "luogo": None,
                "modalita": mod, "iscrizioni_dal": None, "iscrizioni_al": None, "docenti": None,
                "note": "Dal calendario degli appelli pubblicato dal corso di studio", "fonte": fonte}

    def per_nome(cds: str, nome: str) -> set[str]:
        k = _nome_ad(nome)
        return {i["codice"] for c in per_corso.get(cds, []) for i in c.get("insegnamenti") or []
                if i.get("codice") and _nome_ad(re.sub(r"\([^)]*\)", " ", i["nome"])) == k}

    for sito, cds in SITI_CDS.items():
        if cds not in per_corso:
            continue
        try:
            r = s.get(f"{SITO_CORSI}/it/{sito}/studiare", timeout=60)
        except requests.RequestException:
            continue
        time.sleep(pausa)
        if r.status_code != 200:
            continue
        for m in re.finditer(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            url = html.unescape(m.group(1))
            testo = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))).strip()
            if re.search(r"2025[/-]2026|2025[/-]26|AA ?2025", testo):
                continue
            try:
                if "docs.google.com/spreadsheets" in url and re.search(r"(?i)calendario appelli|date appelli", testo):
                    x = s.get(url.replace("output=pdf", "output=csv"), timeout=60)
                    time.sleep(pausa)
                    if x.status_code == 200:
                        righe = list(csv.reader(io.StringIO(x.content.decode("utf-8", "replace"))))
                        _leggi_csv(righe, cds, da, url, aggiungi, esame, per_nome, per_corso)
                elif url.lower().split("?")[0].endswith(".xlsx") and re.search(r"(?i)appelli", testo):
                    url = url if url.startswith("http") else SITO_CORSI + url
                    x = s.get(url, timeout=60)
                    time.sleep(pausa)
                    if x.status_code == 200:
                        _leggi_xlsx(x.content, cds, da, url, aggiungi, esame, per_nome)
            except (requests.RequestException, ValueError, KeyError, zipfile.BadZipFile) as e:
                log(f"[{uid}] calendario {testo!r} ({sito}): {e!r}")
    log(f"[{uid}] calendari dei corsi: {totale[0]} date per {len(out)} insegnamenti")
    return out


def _leggi_csv(righe, cds, da, fonte, aggiungi, esame, per_nome, per_corso) -> None:
    testa = next((i for i, r in enumerate(righe) if any("SESSIONE DI FEBBRAIO" in c.upper() for c in r)), None)
    if testa is not None:  # foglio sanitario: una riga per insegnamento o modulo, colonne per sessione
        sess, cur = {}, None
        for k, c in enumerate(righe[testa]):
            for chiave, sigla in (("FEBBRAIO", "FEB"), ("PASQUALE", "PAS"), ("ESTIVA", "EST"),
                                  ("AUTUNNALE", "AUT"), ("NATALIZIA", "NAT")):
                if chiave in c.upper():
                    cur = sigla
            if k >= 5 and cur:
                sess[k] = cur
        codici = {i["codice"] for c in per_corso.get(cds, []) for i in c.get("insegnamenti") or [] if i.get("codice")}
        for r in righe[testa + 2:]:
            if len(r) < 5:
                continue
            codice = r[2].strip() or r[1].strip()
            if codice not in codici:
                continue
            for k, sg in sess.items():
                if k < len(r) and r[k].strip():
                    for d, ora in _date_sessione(r[k], sg, da):
                        aggiungi(codice, esame(d, ora, None, fonte))
        return
    for r in righe:  # foglio di ingegneria o agraria: data in lettere, una colonna per anno di corso
        d = _data_it(r[1]) if len(r) > 1 else None
        if not d or d < da:
            continue
        for cella in r[2:]:
            for nome, mod, ora in _pezzi_cella(cella):
                for cod in per_nome(cds, nome):
                    aggiungi(cod, esame(d, ora, mod, fonte))


def _leggi_xlsx(dati, cds, da, fonte, aggiungi, esame, per_nome) -> None:
    for righe in _xlsx_celle(dati):
        for celle in righe:
            serie = celle.get("A")
            if not isinstance(serie, float) or not 40000 < serie < 60000:
                continue
            d = datetime.date(1899, 12, 30) + datetime.timedelta(days=int(serie))
            if d < da:
                continue
            for col, cella in celle.items():
                if col == "A" or not isinstance(cella, str):
                    continue
                for nome, mod, ora in _pezzi_cella(cella):
                    for cod in per_nome(cds, nome):
                        aggiungi(cod, esame(d, ora, mod, fonte))
