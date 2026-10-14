"""Periodo didattico (semestre) dal syllabus del Course Catalogue Cineca.

Il piano di studi (`/api/v1/corso/<coorte>/<cod>`) spesso non riporta il periodo dell'attivita, ma il suo
syllabus (`/api/v1/insegnamento?anno=…&insegnamento=…&ordinamento_aa=…&af_percorso=…&corso_cod=…`) si:
`periodo_didattico_it` («Primo Semestre», «Annuale»…) e le date `data_inizio_periodo_didattico` /
`data_fine_periodo_didattico`. Si usa solo cio che pubblica l'ateneo (la scheda indicata in `fonte`),
mai l'anno di corso, il codice o altri insegnamenti. Se il syllabus non lo dice, resta una lacuna
(motivo in `LACUNE[uid][id]`).

Uso: `fetch_periodi(uid, host=None, log=print)`; i moduli `periodi_<uid>.py` lo richiamano.
Cache su disco in `$UN_HTTP_CACHE` (se impostata). Al massimo 1,6 richieste al secondo verso l'host.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import threading
import time

import requests

from . import periodi

sys.path.insert(0, str(periodi.ROOT / "tools" / "db_builder"))
import pulizia  # noqa: E402

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
           "Accept": "application/json"}
URL = re.compile(r"https://([^/]+)/insegnamenti/(\d+)/([^/]+)/(\d+)/([^/?]+)\?coorte=(\d+)")
LACUNE: dict[str, dict[str, str]] = {}  # uid -> {id: motivo}, per il rapporto


class Blocked(Exception):
    pass


class Api:
    def __init__(self, host: str, rate: float = 1.6):
        self.base = f"https://{host}/api/v1"
        self.gap = 1.0 / rate
        self.last = 0.0
        self.lock = threading.Lock()
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = os.path.join(d, "cineca_" + host.split(".")[0]) if d else None
        self.richieste = 0

    def get(self, path: str, params: dict | None = None):
        """JSON, None se 404, "ERR" se il server non risponde; Blocked se 403/429."""
        key = hashlib.sha1((self.base + path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        p = f"{self.cache}/{key[:2]}/{key}.json" if self.cache else None
        if p and os.path.exists(p):
            return json.load(open(p, encoding="utf-8"))["j"]
        for att in range(4):
            with self.lock:
                w = self.last + self.gap - time.monotonic()
                if w > 0:
                    time.sleep(w)
                self.last = time.monotonic()
                self.richieste += 1
            try:
                r = requests.get(self.base + path, params=params, headers=HEADERS, timeout=90)
            except requests.RequestException:
                time.sleep(2 ** att)
                continue
            if r.status_code in (403, 429):
                raise Blocked(f"{self.base} {r.status_code}")
            if r.status_code in (200, 404):
                try:
                    j = r.json() if r.status_code == 200 else None
                except ValueError:
                    time.sleep(1 + att)
                    continue
                if p:
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    json.dump({"j": j}, open(p, "w", encoding="utf-8"), ensure_ascii=False)
                return j
            time.sleep(1 + att)
        return "ERR"


def _walk(x, test, out):
    if isinstance(x, dict):
        if test(x):
            out.append(x)
        for v in x.values():
            _walk(v, test, out)
    elif isinstance(x, list):
        for v in x:
            _walk(v, test, out)


def data_gma(s) -> str | None:
    """'15/02/2027 00:00:00' -> '15/02/2027'."""
    m = re.match(r"(\d{2}/\d{2}/\d{4})", s or "")
    return m.group(1) if m else None


def _periodo(sy: dict, con_date: bool = True):
    """(testo del periodo, inizio, fine, motivo): periodo del syllabus se interpretabile come 1/2/annuale, altrimenti il motivo."""
    testo = (sy.get("periodo_didattico_it") or "").strip() or None
    ini, fin = data_gma(sy.get("data_inizio_periodo_didattico")), data_gma(sy.get("data_fine_periodo_didattico"))
    if not (ini and fin) or not con_date:  # le date di un altro a.a. non valgono per quello corrente
        ini = fin = None
    if not testo and not ini:
        # nessun periodo proprio: quello delle attivita figlie / dei moduli elencati nella scheda, solo se concordano tutti
        figli = [x for x in (sy.get("adFiglie") or []) + (sy.get("moduli") or []) if isinstance(x, dict)]
        viste = []
        for x in figli:
            r = _periodo({k: v for k, v in x.items() if k in ("periodo_didattico_it", "data_inizio_periodo_didattico",
                                                              "data_fine_periodo_didattico")}, con_date)
            viste.append(r)
        ok = [r for r in viste if r[0]]
        if ok and len(ok) == len(viste) and len({pulizia.periodo(r[0], r[1], r[2]) for r in ok}) == 1:
            return ok[0]
        return None, None, None, ("moduli/attivita figlie in periodi diversi" if len(ok) > 1 else None)
    p = pulizia.periodo(testo, ini, fin)
    if p in ("1", "2", "annuale"):
        return testo or p, ini, fin, None
    return None, None, None, f"periodo «{testo}» non interpretabile come semestre (senza date)"


def fetch_periodi(uid: str, host: str | None = None, log=print, piani_cache: str | None = None) -> dict:
    mancanti = periodi.mancanti(uid)
    if piani_cache is None and os.environ.get("UN_HTTP_CACHE"):  # piani gia scaricati da altri strumenti di lavoro
        c = os.path.join(os.path.dirname(os.environ["UN_HTTP_CACHE"]), f"prog_{uid}", "plans")
        piani_cache = c if os.path.isdir(c) else None
    host = host or f"{uid}.coursecatalogue.cineca.it"
    api = Api(host)
    base = f"https://{host}"
    lac = LACUNE.setdefault(uid, {})
    jobs: dict[tuple, list[dict]] = {}
    for m in mancanti:
        g = URL.match(m["url"] or "")
        if not g:
            lac[m["id"]] = "scheda senza indirizzo del catalogo"
            continue
        jobs.setdefault(g.groups()[1:], []).append(m)
    log(f"[{uid}] mancanti {len(mancanti)}; schede distinte {len(jobs)}")

    # codice del corso (corso_cod) di ogni attivita, dai piani delle coorti coinvolte
    amap: dict[tuple, str] = {}
    per_ad: dict[str, list] = {}  # adCod -> [(attivita del piano, coorte)]
    cdsmap: dict[tuple, str] = {}  # (coorte, cdsCod) -> cod del corso nel catalogo
    corsi = periodi.carica(uid)["corsi"]
    cod_ateneo = {c["id"]: c.get("codice_ateneo") for c in corsi}
    url_corso = {c["id"]: re.search(r"/corsi/(\d+)/(\w+)", c.get("url_catalogo") or (c.get("ammissione") or {}).get("fonte") or "")
                 for c in corsi}
    ys = {int(k[4]) for k in jobs}
    for y in range(min(ys, default=0), max(ys, default=-1) + 3):  # anche le coorti piu recenti (le attivita ricompaiono con a.a. successivo)
        if y > time.localtime().tm_year:
            break
        pf = f"{piani_cache}/corsi_{y}.json" if piani_cache else None
        lst = json.load(open(pf, encoding="utf-8")) if pf and os.path.exists(pf) else api.get("/corsi", {"anno": y, "minimal": "true"})
        cds: list[dict] = []
        _walk(lst, lambda x: "cdsCod" in x and "aa" in x and "cod" in x and "des_it" in x, cds)
        visti = set()
        for x in cds:
            if str(x["aa"]) != str(y) or x["cod"] in visti:
                continue
            visti.add(x["cod"])
            cdsmap[(str(y), str(x["cdsCod"]))] = str(x["cod"])
            pp = f"{piani_cache}/p_{y}_{x['cod']}.json" if piani_cache else None
            pl = json.load(open(pp, encoding="utf-8")) if pp and os.path.exists(pp) else api.get(f"/corso/{y}/{x['cod']}")
            att: list[dict] = []
            _walk(pl, lambda a: "adCod" in a and "corso_cod" in a and "corso_percorso_id" in a, att)
            for a in att:
                per_ad.setdefault(str(a.get("adCod")), []).append((a, y))
                amap.setdefault((str(a.get("aa")), str(a.get("cod")), str(a.get("ordinamento_aa")),
                                 str(a.get("corso_percorso_id")), str(y)), str(a["corso_cod"]))
        log(f"[{uid}] piani coorte {y}: {len(visti)} corsi")

    out: dict[str, dict] = {}
    for n, (key, items) in enumerate(jobs.items(), 1):
        aa, cod, ordn, perc, co = key
        cc = amap.get(key) or next((v for k, v in amap.items() if k[:4] == key[:4]), None)
        if not cc:  # attivita fuori dai percorsi del piano (af_percorso 9999): corso dal codice del corso di studio
            for m in items:
                cc = cdsmap.get((co, str(cod_ateneo.get(m["corso"]))))
                u = url_corso.get(m["corso"])
                if not cc and u and u.group(1) == co:
                    cc = u.group(2)
                if cc:
                    break
            if not cc:
                u = url_corso.get(items[0]["corso"])
                cc = u.group(2) if u else None
        sy = None
        if cc:
            sy = api.get("/insegnamento", {"anno": aa, "insegnamento": cod, "ordinamento_aa": ordn,
                                           "af_percorso": perc, "corso_cod": cc})
        if sy == "ERR":
            for m in items:
                lac[m["id"]] = "scheda non raggiungibile (errori del server)"
            continue
        p = ini = fin = motivo = None
        url = f"{base}/insegnamenti/{aa}/{cod}/{ordn}/{perc}?coorte={co}"
        if isinstance(sy, dict):
            p, ini, fin, motivo = _periodo(sy)
        # stesso insegnamento (stesso codice AD, stesso corso) in un'altra coorte / a.a. del catalogo
        if not p and cc and items[0].get("codice"):
            visti = {key}
            alt = sorted(((a, y) for a, y in per_ad.get(str(items[0]["codice"]), []) if str(a.get("corso_cod")) == cc),
                         key=lambda t: (-int(t[0]["aa"]), -t[1]))
            for a, y in alt:  # prima i piani, che a volte riportano gia il periodo (nessuna richiesta)
                p, ini, fin, _ = _periodo(a, con_date=False)
                if p:
                    url = (f"{base}/insegnamenti/{a.get('aa')}/{a.get('cod')}/{a.get('ordinamento_aa')}/"
                           f"{a.get('corso_percorso_id')}?coorte={y}")
                    break
            for a, y in ([] if p else alt):
                k2 = (str(a.get("aa")), str(a.get("cod")), str(a.get("ordinamento_aa")), str(a.get("corso_percorso_id")), str(y))
                if k2 in visti or len(visti) > 7:
                    continue
                visti.add(k2)
                sy2 = api.get("/insegnamento", {"anno": a.get("aa"), "insegnamento": a.get("cod"),
                                                "ordinamento_aa": a.get("ordinamento_aa"),
                                                "af_percorso": a.get("corso_percorso_id"), "corso_cod": cc})
                if isinstance(sy2, dict):
                    p, ini, fin, _ = _periodo(sy2, con_date=False)
                    if p:
                        url = f"{base}/insegnamenti/{k2[0]}/{k2[1]}/{k2[2]}/{k2[3]}?coorte={k2[4]}"
                        break
        if p:
            for m in items:
                out[m["id"]] = {"periodo": p, "periodo_inizio": ini, "periodo_fine": fin, "fonte": url}
        else:
            motivo = motivo or ("scheda non pubblicata nel catalogo" if not isinstance(sy, dict)
                                else "la scheda non riporta il periodo didattico")
            for m in items:
                lac[m["id"]] = motivo
        if n % 100 == 0:
            log(f"[{uid}]   schede {n}/{len(jobs)}, trovati {len(out)}")
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}; richieste {api.richieste}")
    return out
