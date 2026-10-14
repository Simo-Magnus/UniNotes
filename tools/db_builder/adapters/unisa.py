"""Università degli Studi di Salerno: insegnamenti, libri e appelli.

Piani e syllabus: `https://unisa.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Rispetto all'adattatore comune (`cineca_catalogue`) UniSA richiede:

- coorti: con il riordino del 2025 i codici dei corsi sono cambiati (02121 → SE121): senza cercare il
  corso per nome nelle coorti precedenti (`coorte_per_nome`) il piano del 2° e 3° anno sarebbe quello
  futuro della coorte attuale (insegnamenti del 2027/28, senza syllabus);
- durata: l'elenco minimale non ha `durataAnni` (medicina, farmacia, giurisprudenza… avevano solo 3
  anni): si legge dal piano della coorte attuale (anno più alto);
- corsi: solo lauree, lauree magistrali (anche a ciclo unico) e la scuola di specializzazione che il
  database già conosce; master, dottorati e corsi di perfezionamento non sono corsi di studio;
- nomi: il catalogo chiama «Infermieristica (abilitante alla Prof. Sanit. …)» i corsi che Universitaly
  chiama «… alla professione sanitaria di …» (e «Ingegneria alimentare» il «Food Engineering»): si
  scrive l'`id` del corso già presente, perché il piano finisca lì e non in un doppione.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata

from . import cineca_catalogue, unisa_testi

BASE = "https://unisa.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L2", "LM", "LM5", "LM6", "SP2"}
DURATA_TIPO = {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6, "SP2": 2}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unisa_cc" if d else None
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


ALIAS = {"ingegneria alimentare": "food engineering",
         "ingegneria per l ambiente ed il territorio": "ingegneria per l ambiente e il territorio"}


def _chiave(nome: str | None) -> tuple[str, bool]:
    """Nome senza «(abilitante alla …)» e senza «REPLICA …», e se è una replica di sede."""
    n = _norm(re.sub(r"\(.*?\)", "", nome or ""))
    replica = "replica" in _norm(nome)
    n = re.sub(r"\s*replica.*$", "", n).strip()
    return ALIAS.get(n, n), replica


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso del catalogo l'`id` del corso Universitaly che è lo stesso corso con un altro
    nome (stessa classe, replica di sede o no); i corsi che il database non conosce restano senza `id`."""
    p = ROOT / "database" / "corsi" / "unisa.json"
    if not p.exists():
        return 0
    db = json.loads(p.read_text(encoding="utf-8"))["corsi"]
    ul = [c for c in db if c.get("id_universitaly")]
    n = 0
    for cc in corsi:
        k = _chiave(cc["nome"])
        cand = [c for c in ul if _chiave(c["nome"]) == k or (_chiave(c.get("nome_en"))[0], k[1]) == k]
        cand = [c for c in cand if (c.get("classe") or "").replace(" ", "") == (cc.get("classe") or "").replace(" ", "")]
        if len(cand) == 1:
            cc["id"] = cand[0]["id"]
            n += 1
        elif len(cand) > 1:
            log(f"[unisa]   corso del catalogo ambiguo: {cc['nome']} ({len(cand)} corsi del database)")
    return n


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


_testi_originale = cineca_catalogue._testi_syllabus


def _testi_syllabus(sy: dict):
    """Riconoscimento comune dei libri, senza le voci che sono prosa («DISPENSE FORNITE DAL DOCENTE»)."""
    libri, modalita, legati = _testi_originale(sy)
    return [b for b in libri if not unisa_testi.e_prosa(b.get("citazione"))], modalita, legati


def fetch_ateneo(uid: str = "unisa", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache()
    idx = _indice_piani(c, anno) if syllabus else {}
    fmt = lambda a: f"{a}/{(a + 1) % 100:02d}"  # noqa: E731

    def libri_std(sy) -> list[dict]:
        return (cineca_catalogue._testi_syllabus(sy)[0] if isinstance(sy, dict) else []) or             (unisa_testi.libri_unisa(sy) if isinstance(sy, dict) else [])

    def con_nota(libri: list[dict], nota: str) -> list[dict]:
        return [dict(b, note=f"{nota}; {b['note']}" if b.get("note") else nota) for b in libri]

    def libri_extra(sy: dict) -> list[dict]:
        libri = unisa_testi.libri_unisa(sy)
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
        for prima in (1, 2, 3):  # l'ultimo programma pubblicato dello stesso insegnamento
            for par in (idx.get(str(sy.get("adCod")), {}).get(aa - prima) or []):
                libri = libri_std(c.get("/insegnamento", {k: v for k, v in par.items() if v not in (None, "")}))
                if libri:
                    return con_nota(libri, f"Dal programma dell'a.a. {fmt(aa - prima)}: la scheda {fmt(aa)} non "
                                           f"riporta la bibliografia")
        return []

    cineca_catalogue._testi_syllabus = _testi_syllabus
    try:
        doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                            client=c, coorte_per_nome=True, libri_extra=libri_extra)
    finally:
        cineca_catalogue._testi_syllabus = _testi_originale
    log(f"[{uid}] corsi con id del database: {associa(doc['corsi'], log)}/{len(doc['corsi'])}")
    return doc


# --- appelli ---------------------------------------------------------------------------------
ESSE3 = "https://unisa.esse3.cineca.it"


def _inizio_aa(oggi=None):
    import datetime
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def fetch_bacheca(uid: str = "unisa", log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027") -> tuple[dict[str, list[dict]], dict[str, set[str]], dict[str, str]]:
    """Bacheca degli appelli dell'offerta di Esse3 (ListaAppelliOfferta), un corso di studio per volta
    (la bacheca per dipartimento ha solo gli appelli dell'attività, senza il corso). Restituisce gli
    appelli per codice AD, i nomi dei corsi di studio in cui compare ogni codice e il titolo di ogni codice."""
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
                x = s.post(url, data=dati, timeout=180)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            _t.sleep(3 * (tentativo + 1))
        return None

    import html as _h
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


def _nome_ad(s: str | None) -> str:
    return _norm(re.sub(r"\(.*?\)", " ", s or ""))


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], corsi: list[dict],
                    log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (altro codice nell'altra coorte o in un altro
    corso) si attribuiscono all'insegnamento omonimo del corso di studio che li ospita in Esse3."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[str, dict[str, set[str]]] = {}
    for c in corsi:
        k = _chiave(c["nome"])[0]
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
            dest |= per_corso.get(_chiave(nome_cds)[0], {}).get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[unisa] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


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
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti")
    return out
