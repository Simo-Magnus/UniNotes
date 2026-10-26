"""Semestre degli insegnamenti dei Course Catalogue Cineca che nel piano della coorte non lo riportano.

Il piano di studi di una coorte (`/api/v1/corso/<anno>/<cod>`) dà il «periodo didattico» di ogni attività, ma in
alcune coorti (di solito le più recenti) il campo è vuoto. L'attività è la stessa (stesso codice AD, stesso corso di
studio) nel piano di un'altra coorte o di un altro percorso: se lì il periodo è pubblicato e non è in contrasto, vale
anche per l'insegnamento mancante, e come fonte si cita la pagina di quella coorte
(`<base>/insegnamenti/<aa>/<cod>/<ordinamento>/<percorso>?coorte=<anno>`).

Mai dall'anno di corso, dal codice o dal nome: solo da ciò che il catalogo pubblica per quell'attività.
I piani già scaricati dagli altri agenti (SP/prog_<uid>/plans) sono letti dalla cache; quelli mancanti si scaricano
a 1,6 richieste al secondo al massimo, nella cache `SP/semestri/plans_<uid>`.
"""
from __future__ import annotations

import glob
import json
import os
import re
import threading
import time
import unicodedata
from collections import Counter, defaultdict

import requests

from . import periodi
import pulizia

SP = periodi.cartella_lavoro()
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
           "Accept": "application/json"}
URL_RE = re.compile(r"/insegnamenti/(\d+)/([^/]+)/(\d+)/(\w+)\?coorte=(\d+)")

# codice del periodo didattico del catalogo -> semestre dell'app (None = non noto: si guardano le date)
COD = {"S1": "1", "S2": "2", "P1bis": "1", "P2bis": "2", "A": "annuale", "A1": "annuale", "P0": "annuale"}
IGNORA = {"ND", "", None}


def _periodo(att: dict) -> str | None:
    cod = att.get("periodo_didattico_cod")
    if cod in IGNORA and not att.get("periodo_didattico_it"):
        return None
    if cod in IGNORA:
        return None
    if cod in COD:
        return COD[cod]
    ini = (att.get("data_inizio_periodo_didattico") or "")[:10]
    fin = (att.get("data_fine_periodo_didattico") or "")[:10]
    return pulizia._semestre_da_date(ini, fin)  # trimestri, quadrimestri, annualità corte


def _n(t: str | None) -> str:
    t = unicodedata.normalize("NFKD", t or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", t)


def _walk(x, out):
    if isinstance(x, dict):
        if "adCod" in x and "corso_percorso_id" in x:
            out.append(x)
        for v in x.values():
            _walk(v, out)
    elif isinstance(x, list):
        for v in x:
            _walk(v, out)


class _Api:
    def __init__(self, uid: str, base: str, rate: float = 1.6):
        self.base = base.rstrip("/") + "/api/v1"
        self.gap = 1.0 / rate
        self.last = 0.0
        self.lock = threading.Lock()
        self.s = requests.Session()
        self.own = os.path.join(SP, "semestri", f"plans_{uid}")
        os.makedirs(self.own, exist_ok=True)
        self.cache_dirs = [os.path.join(SP, f"prog_{uid}", "plans"), self.own]
        self.richieste = 0

    def _letto(self, nome):
        for d in self.cache_dirs:
            p = os.path.join(d, nome)
            if os.path.exists(p):
                try:
                    return json.load(open(p, encoding="utf-8"))
                except ValueError:
                    pass
        return None

    def get(self, nome: str, path: str, params=None):
        j = self._letto(nome)
        if j is not None:
            return j
        for att in range(4):
            with self.lock:
                w = self.last + self.gap - time.monotonic()
                if w > 0:
                    time.sleep(w)
                self.last = time.monotonic()
                self.richieste += 1
            try:
                r = self.s.get(self.base + path, params=params, headers=HEADERS, timeout=90)
                if r.status_code in (403, 429):
                    raise SystemExit(f"bloccato {r.status_code} {self.base}")
                if r.status_code == 404:
                    j = []
                else:
                    r.raise_for_status()
                    j = r.json()
                json.dump(j, open(os.path.join(self.own, nome), "w", encoding="utf-8"), ensure_ascii=False)
                return j
            except (requests.RequestException, ValueError):
                time.sleep(2 ** att)
        return None


def _cds(lst) -> list[dict]:
    out = []

    def w(x):
        if isinstance(x, dict):
            if "cdsCod" in x and "aa" in x and "cod" in x and "des_it" in x:
                out.append(x)
            for v in x.values():
                w(v)
        elif isinstance(x, list):
            for v in x:
                w(v)
    w(lst)
    return out


def fetch_periodi(uid: str, base: str, anno: int = 2026, da: int = 2020, log=print, ammessi=None) -> dict:
    """Risultati per `periodi.scrivi`. `ammessi`: insieme di valori ammessi (default: tutti i riconosciuti)."""
    mancanti = periodi.mancanti(uid)
    db = periodi.carica(uid)
    api = _Api(uid, base)
    base = base.rstrip("/")

    # elenco dei corsi di ogni coorte; lo stesso corso ha codici diversi da una coorte all'altra
    # (es. «1164» -> «1164-25»): si riconosce da nome, tipo e sede
    def chiave(x: dict):
        return (re.sub(r"\s+", " ", (x.get("des_it") or "").upper()).strip(), x.get("tipo_corso_cod"), x.get("sede_cod"))

    per_anno: dict[int, dict[str, dict]] = {}
    chiave2cods: dict[int, dict[tuple, list[str]]] = {}
    for y in range(da, anno + 1):
        lst = api.get(f"corsi_{y}.json", "/corsi", {"anno": y, "minimal": "true"})
        v = {str(x["cod"]): x for x in _cds(lst or []) if str(x.get("aa")) == str(y)}
        per_anno[y] = v
        k2 = defaultdict(list)
        for cod, x in v.items():
            k2[chiave(x)].append(cod)
        chiave2cods[y] = k2

    # corso del db -> chiave del corso nel catalogo
    corso_cds: dict[str, tuple] = {}
    for c in db["corsi"]:
        if c.get("piano_da"):
            continue
        for u in (c.get("url_catalogo"), (c.get("ammissione") or {}).get("fonte")):
            m = re.search(r"/corsi/(\d+)/(\w+)", u or "")
            if m and m.group(2) in per_anno.get(int(m.group(1)), {}):
                corso_cds[c["id"]] = chiave(per_anno[int(m.group(1))][m.group(2)])
                break
    log(f"[{uid}] corsi del db: {len(db['corsi'])}, collegati al catalogo: {len(corso_cds)}")

    da_fare = [m for m in mancanti if URL_RE.search(m.get("url") or "") and m["corso"] in corso_cds]
    cds_serve = sorted({corso_cds[m["corso"]] for m in da_fare}, key=str)
    log(f"[{uid}] mancanti {len(mancanti)}, con scheda del catalogo {len(da_fare)}, corsi da leggere {len(cds_serve)}")

    # piani di tutte le coorti disponibili per quei corsi
    indice: dict[tuple, list[dict]] = defaultdict(list)
    for n, cds in enumerate(cds_serve, 1):
        for y in range(da, anno + 1):
            for cod in chiave2cods[y].get(cds, []):
                piano = api.get(f"p_{y}_{cod}.json", f"/corso/{y}/{cod}")
                if not piano:
                    continue
                atts: list[dict] = []
                _walk(piano, atts)
                for a in atts:
                    p = _periodo(a)
                    if p:
                        indice[(cds, str(a["adCod"]))].append({"p": p, "y": y, "a": a})
        if n % 10 == 0:
            log(f"[{uid}]   piani letti per {n}/{len(cds_serve)} corsi (richieste: {api.richieste})")

    # secondo livello: stessa attività (codice AD) in un altro corso di studio dell'ateneo, solo se il nome è lo
    # stesso e tutti i piani di tutte le coorti concordano (l'insegnamento mutuato ha un'unica scheda)
    resto = [m for m in da_fare if not indice.get((corso_cds[m["corso"]], str(m["codice"])))
             or len({c["p"] for c in indice[(corso_cds[m["corso"]], str(m["codice"]))]}) > 1]
    altri: dict[str, list[dict]] = defaultdict(list)
    if resto:
        serve = {str(m["codice"]) for m in resto}
        n = 0
        for y in range(da, anno + 1):
            for cod, x in per_anno[y].items():
                piano = api.get(f"p_{y}_{cod}.json", f"/corso/{y}/{cod}")
                if not piano:
                    continue
                atts: list[dict] = []
                _walk(piano, atts)
                for a in atts:
                    if str(a["adCod"]) in serve:
                        p = _periodo(a)
                        if p:
                            altri[str(a["adCod"])].append({"p": p, "y": y, "a": a, "corso": chiave(x)})
            n += 1
            log(f"[{uid}]   piani di tutti i corsi, coorte {y} (richieste: {api.richieste})")

    out, motivi = {}, Counter()
    for m in da_fare:
        mm = URL_RE.search(m["url"])
        y0 = int(mm.group(5))
        cands = indice.get((corso_cds[m["corso"]], str(m["codice"])), [])
        valori = {c["p"] for c in cands}
        if len(valori) > 1:
            stessa = {c["p"] for c in cands if c["y"] == y0}
            if len(stessa) == 1:
                cands = [c for c in cands if c["y"] == y0]
            else:
                motivi["periodo discordante tra coorti/percorsi dello stesso corso"] += 1
                continue
        if not cands:
            cands = [c for c in altri.get(str(m["codice"]), []) if _n(c["a"].get("des_it")) == _n(m["nome"])]
            if not cands:
                motivi["nessuna coorte/percorso/corso del catalogo pubblica il periodo di questa attività"] += 1
                continue
            if len({c["p"] for c in cands}) > 1:
                motivi["periodo discordante tra i corsi che erogano la stessa attività"] += 1
                continue
            motivi["(stessa attività di un altro corso, periodo concorde)"] += 1
        # fonte: la coorte più vicina a quella dell'insegnamento
        c = min(cands, key=lambda c: (abs(c["y"] - y0), -c["y"]))
        a = c["a"]
        fonte = f"{base}/insegnamenti/{a.get('aa')}/{a.get('cod')}/{a.get('ordinamento_aa')}/{a.get('corso_percorso_id')}?coorte={c['y']}"
        out[m["id"]] = {"periodo": c["p"], "fonte": fonte}
    log(f"[{uid}] semestri trovati: {len(out)}; senza: {dict(motivi)}; non collegabili al catalogo: {len(mancanti) - len(da_fare)}")
    return out
