"""Periodo degli insegnamenti PoliTo che nel piano dell'a.a. corrente hanno la colonna «periodo» vuota.

Lo stesso insegnamento (stesso codice, stesso corso di studio) compare nei piani di altre coorti / altri
a.a. (`sviluppo.offerta_formativa_2019.vis?p_coorte=…&p_sdu=…&p_cds=…`, sezioni «N° anno AAAA/AAAA») con il
periodo didattico (1, 2, 3, «1,2»): si usa il piano più recente che lo riporta, se le righe concordano.
"""
from __future__ import annotations

import re
from collections import defaultdict

from . import periodi, polito
from .unibo import Client

AA = ["2027/2028", "2026/2027", "2025/2026", "2024/2025"]


def fetch_periodi(uid: str = "polito", log=print) -> dict:
    c = Client(rate=1.6)
    corsi = {x["id"]: x for x in periodi.carica(uid)["corsi"]}
    manc = periodi.mancanti(uid)
    out = {}
    cache: dict = {}
    for m in manc:
        sdu_cds = polito._codici(corsi[m["corso"]].get("url"))
        if not sdu_cds:
            continue
        sdu, cds = sdu_cds
        trov = []  # (aa, periodo, url)
        for coorte in (2028, 2027, 2026, 2025):
            u = polito.PIANO.format(c=coorte, sdu=sdu, cds=cds)
            if u not in cache:
                r = c.get(u)
                cache[u] = (r.url if r else u, r.text if r else None)
            url, s = cache[u]
            if not s:
                continue
            for aa in AA:
                for x in polito.leggi_piano(s, aa):
                    if x["codice"] == m["codice"] and x["periodo"] in ("1", "2", "3", "annuale"):
                        trov.append((aa, x["periodo"], u))
        if not trov:
            continue
        aa0 = max(t[0] for t in trov)
        p = {t[1] for t in trov if t[0] == aa0}
        if len(p) != 1:
            continue
        out[m["id"]] = {"periodo": p.pop(), "fonte": next(t[2] for t in trov if t[0] == aa0)}
    log(f"[{uid}] periodo da altre coorti/a.a. del piano: {len(out)} su {len(manc)}")
    return out
