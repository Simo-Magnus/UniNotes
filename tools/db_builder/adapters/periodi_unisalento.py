"""Semestre degli insegnamenti dell'Università del Salento (campo «Semestre» della scheda dell'insegnamento).

La scheda dell'insegnamento sui portali dei dipartimenti (www.bbcc.unisalento.it,
medicinasperimentale.unisalento.it: `…/offerta-formativa/percorsi-di-studio/-/dettaglio/insegnamento/<id>/<nome>`)
riporta, nella colonna a destra, «Semestre» (in inglese «Semester»): «Primo Semestre (dal 21/09/2026 al
15/01/2027)», «Annualità Singola (dal 21/09/2026 al 04/06/2027)». Si passano testo e date; le date prevalgono
(pulizia.periodo). La scheda è quella già nel campo `url` dell'insegnamento (l'a.a. è quello della scheda).
"""
from __future__ import annotations

import re

from . import periodi
from .unibo import Client, _testo

RIGA = re.compile(r"(?:Semestre|Semester)\s*<br\s*/?>\s*<strong>\s*(.*?)\s*</strong>", re.S | re.I)
DATE = re.compile(r"(?:dal|from)\s+(\d{2}/\d{2}/\d{4})\s+(?:al|to)\s+(\d{2}/\d{2}/\d{4})", re.I)


def leggi(s: str) -> dict | None:
    m = RIGA.search(s or "")
    if not m:
        return None
    t = _testo(m.group(1))
    d = DATE.search(t)
    testo = re.sub(r"\s*\(.*$", "", t).strip()
    if not testo and not d:
        return None
    out = {"periodo": testo or None}
    if d:
        out["periodo_inizio"], out["periodo_fine"] = d.group(1), d.group(2)
    return out


def fetch_periodi(uid: str = "unisalento", log=print) -> dict[str, dict]:
    c = Client(rate=2.0)
    per_url: dict[str, list[str]] = {}
    for x in periodi.mancanti(uid):
        if x.get("url"):
            per_url.setdefault(x["url"], []).append(x["id"])
    log(f"[{uid}] schede da leggere: {len(per_url)}")
    out, senza, nopag = {}, 0, 0
    for n, (url, ids) in enumerate(per_url.items(), 1):
        r = c.get(url)
        if not r:
            nopag += 1
            continue
        d = leggi(r.text)
        if not d:
            senza += 1
            continue
        for i in ids:
            out[i] = {**d, "fonte": url}
        if n % 200 == 0:
            log(f"[{uid}]   {n}/{len(per_url)}")
    log(f"[{uid}] semestri trovati: {len(out)}; schede senza semestre: {senza}; schede non raggiungibili: {nopag}")
    return out
