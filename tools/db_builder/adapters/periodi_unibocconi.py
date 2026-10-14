"""Semestre degli insegnamenti dell'Università Bocconi che non sono nell'elenco `tsn_ric_alf` del corso.

La scheda dell'insegnamento (`didattica.unibocconi.eu/ts/tsn_anteprima.php?cod_ins=…&ric_cdl=…`, la stessa che
è già nel database come `url`) ha in testa una riga per ogni corso di studio (sigla) in cui l'insegnamento è
offerto: «WBB (6 credits - II sem. - OP | IUS/12) - BAI (…)». Il semestre è quello della riga della sigla del
corso dell'insegnamento (la sigla si ricava da `ric_cdl` con l'elenco dei corsi di `ts/index.php`).
Se la riga della sigla non c'è o il semestre non è «I sem.»/«II sem.»/«I/II sem.», nessun periodo.
"""
from __future__ import annotations

import html
import re

from . import periodi
from .unibo import Client, _testo
from .unibocconi import SEM, TS


def _siglie(c: Client, fine: int) -> dict[str, str]:
    """codice ric_cdl (es. TR06R) → sigla (WBB)."""
    out = {}
    for o in ("N3", "R2", "R5"):
        r = c.get(f"{TS}index.php?IdPag=8227&ric_ordinamento={o}&anno={fine}")
        sel = re.search(r'<select name="ric_cdl".*?</select>', r.text if r else "", re.S)
        for v, t in re.findall(r'<option value="([^"]+)"[^>]*>(.*?)</option>', sel.group(0) if sel else ""):
            out[v.split("^")[-1]] = html.unescape(t).strip()
    return out


def semestre_scheda(s: str, sigla: str) -> str | None:
    for b in re.split(r'<div style="background-color: #5686CE', s)[1:]:
        intest = _testo(b[:b.find("</div>")])
        m = re.search(rf"(?<![\w-]){re.escape(sigla)}\s*\(([^)]*)\)", intest)
        if m:
            sm = re.search(r"(?:^|\s-\s)\s*(I/II|II|I)\s+sem\.(?=\s*(?:-|\||$))", m.group(1))
            return SEM.get(sm.group(1) + " sem.") if sm else None
    return None


def fetch_periodi(uid: str = "unibocconi", log=print) -> dict:
    mancanti = periodi.mancanti(uid)
    c = Client(rate=1.6)
    sig = _siglie(c, 2027)
    out: dict[str, dict] = {}
    lacune: dict[str, int] = {}
    for n, m in enumerate(mancanti, 1):
        mm = re.search(r"ric_cdl=([^&]+)", m.get("url") or "")
        sigla = sig.get(mm.group(1)) if mm else None
        r = c.get(m["url"]) if m.get("url") else None
        p = semestre_scheda(r.text, sigla) if (r and sigla) else None
        if p:
            out[m["id"]] = {"periodo": p, "fonte": m["url"]}
        else:
            k = "scheda non raggiungibile" if not r else ("corso non riconosciuto" if not sigla else "semestre non indicato")
            lacune[k] = lacune.get(k, 0) + 1
        if n % 100 == 0:
            log(f"[{uid}] {n}/{len(mancanti)}, trovati {len(out)}")
    log(f"[{uid}] trovati {len(out)} su {len(mancanti)}; lacune {lacune}")
    return out
