"""Semestre degli insegnamenti UniUrb dalla scheda «Insegnamenti e programmi» (www.uniurb.it).

La tabella della scheda ha la colonna «Periodo» («Primo semestre», «Ciclo Annuale Unico»…). Le schede
degli insegnamenti rimasti senza periodo riportano «Ciclo Annuale Unico»: il testo è quello dell'ateneo.
"""
from __future__ import annotations

import re

from . import periodi
from .unibo import Client, _testo


def _periodo_scheda(s: str) -> str | None:
    r = re.search(r"<th[^>]*>\s*Periodo\s*</th>(.*?)</table>", s, re.S)
    if not r:
        return None
    ths = [_testo(x) for x in re.findall(r"<th[^>]*>(.*?)</th>", s[r.start() - 600:r.end()], re.S)]
    tds = [_testo(x) for x in re.findall(r"<td[^>]*>(.*?)</td>", r.group(1), re.S)]
    if "Periodo" not in ths:
        return None
    i = ths.index("Periodo")
    return tds[i] if i < len(tds) and tds[i] else None


def fetch_periodi(uid: str = "uniurb", log=print) -> dict:
    c = Client(rate=1.6)
    out: dict[str, dict] = {}
    mancanti = periodi.mancanti(uid)
    for n, m in enumerate(mancanti, 1):
        if not m["url"]:
            continue
        r = c.get(m["url"])
        p = _periodo_scheda(r.text) if r else None
        if p:
            out[m["id"]] = {"periodo": p, "fonte": m["url"]}
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}")
    return out
