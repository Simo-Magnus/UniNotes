"""Periodo degli insegnamenti UniCampania dalla scheda dell'insegnamento (dati U-GOV, «Periodo di Erogazione»).

Il link dell'insegnamento nel database (`…/dipartimento/docenti?MATRICOLA=…&COD_ATTIVITA=…&AA_OFFERTA=<a.a.>`)
punta spesso a un a.a. in cui la scheda non è ancora compilata: si prova la stessa scheda (stessa attività e
stesso docente) negli altri anni di offerta, dal 2026 al 2023, e si usa il primo che riporta il periodo.
"""
from __future__ import annotations

import os
import re
import sys

from . import periodi, unicampania

try:
    _SP = os.environ.get("SEMESTRI_DIR")
    if _SP:
        sys.path.insert(0, _SP)
    from cachelib import Http  # type: ignore
except Exception:  # noqa: BLE001
    Http = None


def _get(uid):
    if Http is not None:
        h = Http(uid)
        return lambda u: h.text(u)[1]
    from .unibo import Client
    c = Client(rate=1.6)
    return lambda u: (c.get(u).text if c.get(u) is not None else "")


def fetch_periodi(uid: str = "unicampania", log=print) -> dict:
    get = _get(uid)
    out = {}
    manc = periodi.mancanti(uid)
    for m in manc:
        u0 = m.get("url") or ""
        mm = re.search(r"AA_OFFERTA=(\d+)", u0)
        if not mm:
            continue
        anni = []
        for a in [2026, int(mm.group(1)), 2025, 2024, 2023]:
            if a not in anni:
                anni.append(a)
        for a in anni:
            u = re.sub(r"AA_OFFERTA=\d+", f"AA_OFFERTA={a}", u0)
            t = get(u)
            if not t:
                continue
            p = unicampania.leggi_scheda(t)["periodo"]
            if p:
                out[m["id"]] = {"periodo": p, "fonte": u}
                break
    log(f"[{uid}] periodo dalla scheda (altri anni di offerta): {len(out)} su {len(manc)}")
    return out
