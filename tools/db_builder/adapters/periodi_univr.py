"""Periodo degli insegnamenti UniVR dalla scheda dell'insegnamento su www.corsi.univr.it.

La scheda (`/?ent=cs&id=…&menu=studiare&tab=Insegnamenti&codiceCs=…&codins=…&aa=2026/2027`) riporta
«Periodo Primo semestre LM dal 28 set 2026 al 23 dic 2026.» (uno per modulo se l'insegnamento è diviso).
«Non ancora assegnato» = periodo non pubblicato: l'insegnamento resta senza. Se i moduli sono in periodi
diversi non si sceglie (resta vuoto). Le pagine sono quelle già lette dall'adattatore univr (cache comune).
"""
from __future__ import annotations

import os
import re
import sys

from . import periodi
from .unibo import Client, _testo

MESI = {"gen": "01", "feb": "02", "mar": "03", "apr": "04", "mag": "05", "giu": "06", "lug": "07", "ago": "08",
        "set": "09", "ott": "10", "nov": "11", "dic": "12"}
DATA = r"(\d{1,2}) ([a-z]{3}) (\d{4})"


def _d(g):
    return f"{int(g[0]):02d}/{MESI[g[1]]}/{g[2]}"


def periodo_scheda(testo: str):
    """(testo periodo, inizio, fine) dalla scheda, oppure None se non pubblicato / moduli discordi."""
    i = testo.find("Codice insegnamento")
    x = testo[i:] if i >= 0 else testo
    trovati = []
    for m in re.finditer(r"\bPeriodo (.{0,90}?)(?= Docent| Corsi Singoli| Orario| Seminari| Crediti|\. |$)(?:\. | )?", x):
        t = m.group(1).strip()
        d = re.search(rf"^(.*?)\s+dal {DATA} al {DATA}$", t)
        if d:
            trovati.append((d.group(1).strip(), _d(d.groups()[1:4]), _d(d.groups()[4:7])))
        elif t and not t.lower().startswith("non ancora assegnato"):
            trovati.append((t, None, None))
        elif t:
            trovati.append(None)
    if not trovati or None in trovati:
        return None
    testi = {a for a, _, _ in trovati}
    if len(testi) != 1:
        return None
    a = trovati[0]
    if not re.search(r"semestre|annual", a[0], re.I):
        return None
    inizi = [b for _, b, _ in trovati if b]
    return a[0], (inizi[0] if inizi else None), ([c for _, _, c in trovati if c][0] if inizi else None)


def fetch_periodi(uid: str = "univr", log=print) -> dict:
    c = Client(rate=1.6)
    out, senza = {}, 0
    for m in periodi.mancanti(uid):
        if not m.get("url"):
            continue
        r = c.get(m["url"])
        t = _testo(r.text) if r is not None and getattr(r, "text", None) else ""
        p = periodo_scheda(t) if t else None
        if not p:
            senza += 1
            continue
        v = {"periodo": p[0], "fonte": m["url"]}
        if p[1]:
            v["periodo_inizio"], v["periodo_fine"] = p[1], p[2]
        out[m["id"]] = v
    log(f"[{uid}] periodo nella scheda: {len(out)}; non pubblicato/non univoco: {senza}")
    return out
