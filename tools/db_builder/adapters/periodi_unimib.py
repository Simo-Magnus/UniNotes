"""Semestre degli insegnamenti dell'Università di Milano-Bicocca (riga «Periodo» del Course Syllabus).

La pagina pubblica `https://elearning.unimib.it/course/info.php?id=<id>` di ogni insegnamento riporta nella
scheda riassuntiva la riga «Periodo» («Primo Semestre», «Secondo Semestre», «Annuale»…; in inglese «Term»: First semester, Second semester, Annual).
`adapters/unimib.py` legge solo i campi di testo libero del syllabus (periodo_erogazione…): qui si legge la riga
della scheda, che c'è in quasi tutte le pagine. Il testo è normalizzato da pulizia.periodo in build_db.
"""
from __future__ import annotations

import re

from . import periodi
from .unibo import Client, _testo

RIGA = re.compile(r'font-weight-bold">\s*(?:Periodo|Period|Term)\s*</div>\s*<div class="col-6 text-right">\s*(.*?)\s*</div>',
                  re.S | re.I)
NULLI = re.compile(r"(?i)^(-+|n\.?d\.?|non definito|undefined|nessuno|none)?$")


def leggi(s: str) -> dict | None:
    m = RIGA.search(s or "")
    if not m:
        return None
    t = _testo(m.group(1))
    return None if NULLI.match(t) else {"periodo": t}


def fetch_periodi(uid: str = "unimib", log=print) -> dict[str, dict]:
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
    log(f"[{uid}] semestri trovati: {len(out)}; schede senza periodo: {senza}; schede non raggiungibili: {nopag}")
    return out
