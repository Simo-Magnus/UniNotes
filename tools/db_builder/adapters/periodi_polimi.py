"""Periodo degli insegnamenti PoliMi dalla pagina del manifesto (onlineservices.polimi.it/manifesti).

`polimi.leggi_manifesto` assume che dopo la cella del nome vengano lingua, sede, tipo, periodo, CFU: le righe
con più sezioni (es. gli Studio di Architettura: cella del nome con colspan=2 e una cella in più) spostano le
colonne e il periodo non viene letto. Qui la riga si identifica dal suo `idRiga` (lo stesso del link
dell'insegnamento) e il periodo è la cella «1° sem» / «2° sem» / «Annuale» della riga, come la mostra il manifesto.
"""
from __future__ import annotations

import html
import re

from . import periodi
from .unibo import Client, _testo


def periodo_riga(tr: str) -> str | None:
    celle = [_testo(x) for x in re.findall(r"<TD[^>]*>(.*?)</TD>", tr, re.S | re.I)]
    for t in celle:
        m = re.fullmatch(r"(\d)\s*°?\s*sem\.?", t.lower())
        if m:
            return m.group(1)
        if t.lower() in ("annuale", "ann.", "ann"):
            return "annuale"
    return None


def fetch_periodi(uid: str = "polimi", log=print) -> dict:
    cl = Client(rate=1.6)
    corsi = {c["id"]: c for c in periodi.carica(uid)["corsi"]}
    out, pagine = {}, {}
    manc = periodi.mancanti(uid)
    for m in manc:
        ins = next(i for i in corsi[m["corso"]]["insegnamenti"] if i["id"] == m["id"])
        fonte = ins.get("fonte")
        riga = re.search(r"idRiga=(\d+)", m.get("url") or "")
        if not fonte or not riga:
            continue
        if fonte not in pagine:
            r = cl.get(fonte)
            pagine[fonte] = r.text if r is not None else ""
        for tr in re.findall(r"<tr>(.*?)</tr>", pagine[fonte], re.S | re.I):
            if f"idRiga={riga.group(1)}" in html.unescape(tr):
                p = periodo_riga(tr)
                if p:
                    out[m["id"]] = {"periodo": p, "fonte": fonte}
                break
    log(f"[{uid}] periodo dalla riga del manifesto: {len(out)} su {len(manc)}")
    return out
