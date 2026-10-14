"""Università degli Studi di Trieste: insegnamenti, libri e appelli.

Piani e syllabus: `https://units.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Rispetto all'adattatore comune (`cineca_catalogue`) UniTS richiede:

- ritmo: al massimo 2 richieste al secondo (il client comune ne fa 8);
- durata: l'elenco minimale non ha `durataAnni` (le magistrali a ciclo unico avevano solo 3 anni e
  le magistrali biennali il solo 2° anno): si legge dal piano della coorte attuale (anno più alto)
  o, se il piano è vuoto, dal tipo di corso;
- coorti: i codici dei corsi cambiano da una coorte all'altra, per cui il piano del 2° anno in poi si
  cerca nella coorte giusta anche per nome (`coorte_per_nome`);
- corsi: solo lauree, magistrali (anche a ciclo unico) e le scuole di specializzazione che il database
  già conosce; dottorati, master, corsi singoli («Semestre aperto») non sono corsi di studio;
- libri: i testi del syllabus sono in forma libera (`units_testi`); se la scheda 2026/27
  non ha la bibliografia si usa quella dell'insegnamento da cui è mutuata o quella dell'a.a. precedente
  dello stesso insegnamento, dicendolo nella nota del libro.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import unicodedata

from . import cineca_catalogue, units_testi
from .testi import YEAR, _isbn
from .unifi_testi import _AUTORE_INIZIO, _PROSA, _editore

BASE = "https://units.coursecatalogue.cineca.it"
ESSE3 = "https://units.esse3.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L2", "LM", "LM5", "LM6", "SP3"}
DURATA_TIPO = {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6, "SP3": 3}
RATE = 2.0  # richieste al secondo
# corsi del catalogo che Universitaly non elenca (nuovo corso, piano ancora senza anni): non sono corsi di studio
# del database, che per ogni ateneo ha gli stessi corsi di Universitaly
ESCLUSI = {"SP56A"}  # «Political Science - Integration and Governance» (LM-62)
# codice del corso nel catalogo → id Universitaly: l'omonimo Igiene dentale ha una replica (Pordenone)
ID_UNIVERSITALY = {"ME15": "1627044", "ME25": "1627103"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "units_cc" if d else None
        self.mancanti: set[tuple[str, str]] = set()  # (a.a., codice) delle schede che il catalogo non ha
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def _get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            # lo stesso insegnamento è in più percorsi e il syllabus può stare sotto un altro percorso
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        elif path == "/insegnamento" and params:
            self.mancanti.add((str(params.get("anno")), str(params.get("insegnamento"))))
        return r

    def get(self, path: str, params: dict | None = None):
        r = self._get(path, params)
        if path != "/corsi":
            return r
        elenco: list[dict] = []
        cineca_catalogue._walk_cds(r or [], elenco)
        out = []
        for x in elenco:
            if x.get("tipo_corso_cod") not in TIPI:
                continue
            x = dict(x)
            if not x.get("durataAnni"):
                x["durataAnni"] = self._durata(x, (params or {}).get("anno"))
            out.append(x)
        return out

    def _durata(self, x: dict, anno) -> int:
        d = self._get(f"/corso/{anno}/{x['cod']}")
        if isinstance(d, list):
            d = d[0] if d else None
        anni = [int(a["anno"]) for p in (d or {}).get("percorsi") or [] for a in p.get("anni") or []
                if str(a.get("anno")).isdigit()]
        return max(anni) if anni else DURATA_TIPO.get(x.get("tipo_corso_cod"), 3)


def _indice_piani(c: ClientCache, anno: int, durata_max: int = 6) -> dict[str, dict[int, list[dict]]]:
    """adCod → anno di erogazione → parametri del syllabus, da tutti i piani delle coorti (già in cache):
    serve a trovare il programma dell'a.a. precedente dello stesso insegnamento."""
    idx: dict[str, dict[int, list[dict]]] = {}

    def cammina(x):
        if isinstance(x, dict):
            if "adCod" in x and "aa" in x and "cod" in x and "corso_cod" in x:
                par = {"anno": x.get("aa"), "insegnamento": x.get("cod"), "ordinamento_aa": x.get("ordinamento_aa"),
                       "af_percorso": x.get("corso_percorso_id"), "corso_cod": x.get("corso_cod"),
                       "schema_id": x.get("schemaId")}
                v = idx.setdefault(str(x["adCod"]), {}).setdefault(int(x["aa"]), [])
                if par not in v:
                    v.append(par)
            for v in x.values():
                cammina(v)
        elif isinstance(x, list):
            for v in x:
                cammina(v)

    for y in range(anno - durata_max + 1, anno + 1):
        for x in c.get("/corsi", {"anno": y, "minimal": "true"}) or []:
            if str(x.get("aa")) != str(y):
                continue
            d = c.get(f"/corso/{y}/{x['cod']}")
            cammina(d[0] if isinstance(d, list) and d else d)
    return idx


def libri_testi(sy: dict) -> list[dict]:
    """Libri dai testi liberi dei syllabus (`units_testi`)."""
    if not isinstance(sy, dict):
        return []
    return units_testi.libri_units(sy)


def _prosa(cit: str) -> bool:
    """Frase di prosa e non riferimento: parole come «materiale», «slide», «verranno», nessun anno, editore o
    ISBN, e non comincia con un autore («R. Marconato “Sistemi elettrici di potenza”»)."""
    return bool(_PROSA.search(cit) and not (YEAR.search(cit) or _isbn(cit) or _editore(cit.lower()))
                and not _AUTORE_INIZIO.match(cit) and cit not in units_testi.CITAZIONI_SET)


def _testo_vuoto(sy: dict) -> bool:
    """La scheda non ha alcun testo nel campo «Testi di riferimento» (né nei moduli) né bibliografie altrove."""
    for t in sy.get("testiTotali") or []:
        for k in ("testi_it", "mod_testi_it"):
            v = re.sub(r"<[^>]+>|&nbsp;|\s+", " ", t.get(k) or "").strip(" -.–")
            if len(v) > 3 and v.lower() not in ("nessuno", "nessun testo", "n.a.", "n/a", "da definire", "tbd"):
                return False
    return True


def fetch_ateneo(uid: str = "units", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache()
    idx = _indice_piani(c, anno) if syllabus else {}
    fmt = lambda a: f"{a}/{(a + 1) % 100:02d}"  # noqa: E731

    def libri_std(sy) -> list[dict]:
        if not isinstance(sy, dict):
            return []
        return cineca_catalogue._testi_syllabus(sy)[0] or libri_testi(sy)

    def con_nota(libri: list[dict], nota: str) -> list[dict]:
        return [dict(b, note=f"{nota}; {b['note']}" if b.get("note") else nota) for b in libri]

    def anni_precedenti(ad: str, aa: int, motivo: str) -> list[dict]:
        """Bibliografia dell'a.a. più recente (fino a tre anni prima) in cui lo stesso insegnamento la riporta."""
        for k in (1, 2, 3):
            for par in (idx.get(str(ad), {}).get(aa - k) or []):
                libri = libri_std(c.get("/insegnamento", {p: v for p, v in par.items() if v not in (None, "")}))
                if libri:
                    return con_nota(libri, f"Dal programma dell'a.a. {fmt(aa - k)}: {motivo}")
        return []

    def libri_extra(sy: dict) -> list[dict]:
        libri = libri_testi(sy)
        if libri:
            return libri
        m = sy.get("mutuaDa")
        if isinstance(m, dict) and m.get("adId"):  # mutuato: il programma è quello dell'insegnamento di origine
            sy2 = c.get("/insegnamento", {"anno": m.get("aaOffId"), "insegnamento": m.get("adId"),
                                          "corso_cod": m.get("cdsId"), "ordinamento_aa": m.get("aaOrdId"),
                                          "af_percorso": m.get("pdsId")})
            libri = libri_std(sy2)
            if libri:
                return con_nota(libri, f"Dal programma di «{(sy2 or {}).get('des_it', '').title()}», da cui questo "
                                       f"insegnamento è mutuato")
        try:
            aa = int(sy.get("aa"))
        except (TypeError, ValueError):
            return []
        if not _testo_vuoto(sy):  # la scheda ha un testo (anche solo «materiale del docente»): vale quello
            return []
        return anni_precedenti(sy.get("adCod"), aa, f"la scheda {fmt(aa)} non riporta la bibliografia")

    doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                        client=c, coorte_per_nome=True, libri_extra=libri_extra)
    corsi = []
    for cc in doc["corsi"]:
        if cc.get("codice_ateneo") in ESCLUSI:
            log(f"[{uid}] corso escluso (non è nell'elenco di Universitaly): {cc['nome']}")
            continue
        if cc.get("codice_ateneo") in ID_UNIVERSITALY:
            cc["id_universitaly"] = ID_UNIVERSITALY[cc["codice_ateneo"]]
        corsi.append(cc)
    doc["corsi"] = corsi
    # l'estrazione comune lascia passare qualche frase di prosa («Slide del corso e materiali …»): senza anno,
    # editore o ISBN e senza un autore all'inizio non è un riferimento bibliografico
    scartati = 0
    for cc in corsi:
        for i in cc["insegnamenti"]:
            buoni = [b for b in i.get("libri") or [] if not _prosa(b.get("citazione") or "")]
            scartati += len(i.get("libri") or []) - len(buoni)
            if len(buoni) != len(i.get("libri") or []):
                i["libri"], i["stato_libri"] = buoni, ("completo" if buoni else "da_aggiungere")
    log(f"[{uid}] citazioni di prosa scartate: {scartati}")
    # insegnamenti la cui scheda non esiste nel catalogo (risposta 404): bibliografia dell'a.a. precedente
    n = 0
    for cc in corsi:
        for i in cc["insegnamenti"]:
            m = re.search(r"/insegnamenti/(\d+)/(\d+)/", i.get("url") or "")
            if i.get("libri") or not m or (m.group(1), m.group(2)) not in c.mancanti:
                continue
            libri = anni_precedenti(i.get("codice"), int(m.group(1)), "la scheda non è pubblicata nel catalogo")
            if libri:
                i["libri"], i["stato_libri"] = libri, "completo"
                n += 1
    log(f"[{uid}] insegnamenti senza scheda con la bibliografia dell'a.a. precedente: {n}")
    return doc


# --- appelli ---------------------------------------------------------------------------------
def _inizio_aa(oggi=None):
    import datetime
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def fetch_bacheca(uid: str = "units", log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027") -> tuple[dict[str, list[dict]], dict[str, set[str]], dict[str, str]]:
    """Bacheca degli appelli dell'offerta di Esse3 (ListaAppelliOfferta), un corso di studio per volta
    (la bacheca per dipartimento ha solo gli appelli dell'attività, senza il corso). Restituisce gli
    appelli per codice AD, i nomi dei corsi di studio in cui compare ogni codice e il titolo di ogni codice."""
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
    facs = [v for v in re.findall(r'<option value="([^"]*)"', sel.group(0)) if v] if sel else []
    appelli: dict[str, list[dict]] = {}
    origine: dict[str, set[str]] = {}
    titoli: dict[str, str] = {}
    n_cds = 0

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                x = s.post(url, data=dati, timeout=180)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            _t.sleep(3 * (tentativo + 1))
        return None

    for fac in facs:
        t = post({**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "",
                  "_fw_refresh-form": "selectionFacolta"})
        _t.sleep(pausa)
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        cds = re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []
        for cod, etichetta in cds:
            t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
            _t.sleep(pausa)
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


def _chiave_nome(nome: str | None) -> str:
    """Nome del corso o dell'attività senza le parentesi («(abilitante alla professione …)», «(SEM.)»)."""
    return _norm(re.sub(r"\(.*?\)", " ", nome or ""))


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], titoli: dict[str, str],
                    corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (altro codice in un'altra coorte o ordinamento)
    si attribuiscono all'insegnamento omonimo del corso di studio che li ospita in Esse3."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[str, dict[str, set[str]]] = {}
    for c in corsi:
        for i in c.get("insegnamenti") or []:
            if i.get("codice"):
                per_corso.setdefault(_chiave_nome(c["nome"]), {}).setdefault(_chiave_nome(i["nome"]), set()).add(i["codice"])
    out = {k: list(v) for k, v in appelli.items()}
    n = 0
    for ad, lst in appelli.items():
        if ad in codici:
            continue
        nome = _chiave_nome(titoli.get(ad) or lst[0].get("titolo"))
        dest: set[str] = set()
        for nome_cds in origine.get(ad, ()):
            dest |= per_corso.get(_chiave_nome(nome_cds), {}).get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[units] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli dell'a.a. in corso: bacheca dell'offerta per corso di studio (con riassegnazione per nome dei
    codici che il catalogo non ha), più quella per dipartimento (attività fuori dall'offerta dei corsi)."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    off, origine, titoli = fetch_bacheca(uid, log=log)
    out = associa_appelli(off, origine, titoli, corsi, log=log) if corsi else off
    try:
        dip = per_dipartimento(uid, ESSE3, log=log, delay=0.6)
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
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti")
    return out
