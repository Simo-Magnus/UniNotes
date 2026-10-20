"""Semestre degli insegnamenti di Ca' Foscari da www.unive.it («Insegnamenti e orari», una pagina per anno di corso).

Le pagine dicono il periodo come «I Semestre», «II Semestre» oppure «1° Periodo» ... «4° Periodo» (corsi dell'area
economica e umanistica). I periodi non sono semestri: il 1° e il 2° cadono nel 1° semestre (lezioni dal 21/09 a fine
ottobre e da inizio novembre a metà dicembre, dal file ICS ufficiale di ogni insegnamento), il 3° e il 4° nel 2°
(febbraio-maggio, piani delle frequenze dei corsi). Lo stesso criterio è in `unive.PERIODO_A_SEMESTRE`; prima il
«2° Periodo» finiva nel 2° semestre. La fonte di ogni periodo è la pagina dell'elenco che lo riporta.
Al massimo 1 richiesta al secondo; cache su disco in `$UN_HTTP_CACHE/periodi_unive` (se impostata).
"""
from __future__ import annotations

import hashlib
import os
import re
import time

import requests

from . import periodi, unive

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
LISTA = re.compile(r"https://www\.unive\.it/data/it/\d+/insegnamenti-e-orari/\d+$")


def _get(url: str, cache: str | None, stato: dict) -> str | None:
    f = os.path.join(cache, hashlib.sha1(url.encode()).hexdigest() + ".html") if cache else None
    if f and os.path.exists(f):
        return open(f, encoding="utf-8").read()
    for att in range(3):
        w = stato["ultima"] + 1.1 - time.monotonic()
        if w > 0:
            time.sleep(w)
        stato["ultima"] = time.monotonic()
        try:
            r = requests.get(url, headers=HEADERS, timeout=60)
        except requests.RequestException:
            time.sleep(2 ** att)
            continue
        if r.status_code in (403, 429):
            raise RuntimeError(f"www.unive.it {r.status_code}: raccolta ferma")
        if r.status_code == 200:
            if f:
                open(f, "w", encoding="utf-8").write(r.text)
            return r.text
        return None
    return None


def fetch_periodi(uid: str = "unive", log=print) -> dict[str, dict]:
    d = os.environ.get("UN_HTTP_CACHE")
    cache = os.path.join(d, "periodi_unive") if d else None
    if cache:
        os.makedirs(cache, exist_ok=True)
    stato = {"ultima": 0.0}
    db = periodi.carica(uid)
    per_ins: dict[str, tuple[str, str]] = {}  # id insegnamento -> (afid, pagina elenco)
    for c in db["corsi"]:
        for i in c.get("insegnamenti") or []:
            m = re.search(r"/data/insegnamento/(\d+)", i.get("url") or "")
            # dall'adattatore con il piano di studio per coorte `fonte` è la pagina della coorte e la pagina dell'elenco
            # erogato (dove c'è il periodo) è in `periodo_fonte`
            fonte = i.get("periodo_fonte") or i.get("fonte") or ""
            if m and LISTA.match(fonte):
                per_ins[i["id"]] = (m.group(1), fonte)
    pagine = sorted({p for _, p in per_ins.values()})
    log(f"[{uid}] {len(pagine)} pagine di elenco, {len(per_ins)} insegnamenti")
    mappa: dict[tuple[str, str], str] = {}
    for n, url in enumerate(pagine, 1):
        h = _get(url, cache, stato)
        if not h:
            continue
        for x in unive.leggi_anno(h):
            if x.get("periodo"):
                mappa[(x["id"], url)] = x["periodo"]
        if n % 50 == 0:
            log(f"[{uid}]   pagine {n}/{len(pagine)}")
    out = {}
    for iid, (afid, url) in per_ins.items():
        p = mappa.get((afid, url))
        if p:
            out[iid] = {"periodo": p, "fonte": url}
    log(f"[{uid}] periodi letti: {len(out)}")
    return out


if __name__ == "__main__":
    r = fetch_periodi()
    print(periodi.scrivi("unive", r))
