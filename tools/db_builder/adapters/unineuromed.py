"""Insegnamenti dell'Università Neuromed da unineuromed.it.

La pagina del corso (`/didattica/<corso>/`) ha il "Piano di studi" in tabelle per anno (didascalia
"… — Primo anno" o "… — 1° anno (a.a. 2026/2027)", "Insegnamenti a scelta"): semestre,
insegnamento (con eventuali moduli), SSD, TAF e CFU. Niente docenti né libri sulle pagine pubbliche.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://unineuromed.it"
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
SEM = {"I": "1", "II": "2"}


def leggi_piano(s: str) -> list[dict]:
    out = []
    for cap, corpo in re.findall(r"<caption[^>]*>(.*?)</caption>(.*?)</table>", s, re.S):
        cap = _testo(cap)
        a = re.search(r"(\d)\s*°\s*anno|\b(primo|secondo|terzo|quarto|quinto|sesto)\s+anno", cap, re.I)
        scelta = "scelta" in cap.lower()
        if not a and not scelta:
            continue
        k = (int(a.group(1)) if a.group(1) else ANNI[a.group(2).lower()]) if a else None
        for r in re.findall(r"<tr[^>]*>(.*?)</tr>", re.sub(r"<thead.*?</thead>", "", corpo, flags=re.S), re.S):
            nome = re.search(r'<th[^>]*class="pds__nome"[^>]*>(.*?)</th>', r, re.S)
            if not nome or not _testo(nome.group(1)):
                continue  # riga di un modulo: si tiene l'insegnamento
            celle = {c: _testo(v) for c, v in re.findall(r'<td[^>]*class="pds__(\w+)"[^>]*>(.*?)</td>', r, re.S)}
            codici = re.findall(r'<td[^>]*class="pds__code"[^>]*>(.*?)</td>', r, re.S)
            ssd = _testo(codici[0]) if codici else ""
            cfu = re.search(r"\d+(?:[.,]\d+)?", celle.get("cfu", ""))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            out.append({"anno": k, "nome": _titolo(html.unescape(_testo(nome.group(1)))),
                        "periodo": SEM.get(celle.get("sem", "").upper()),
                        "ssd": ssd if re.match(r"[A-Z]{2,5}[-/]", ssd) else None,
                        "cfu": int(v) if v is not None and v.is_integer() else v, "a_scelta": scelta})
    return out


def fetch_ateneo(uid: str = "unineuromed", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        u = corso.get("url") or ""
        if "unineuromed.it/didattica/" not in u:
            continue
        r = c.get(u)
        voci = leggi_piano(r.text) if r else []
        if not voci:
            continue
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": u, "curricula": None, "fonte": u,
                    "verificato_il": oggi,
                    "insegnamenti": [{"codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": v["periodo"],
                                      "cfu": v["cfu"], "ssd": v["ssd"],
                                      "obbligatorio": False if v["a_scelta"] else None, "curriculum": None,
                                      "docenti": [], "url": u, "libri": [], "esami": [], "fonte": u,
                                      "verificato_il": oggi, "stato_libri": "da_aggiungere"} for v in voci]})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti")
    return {"universita_id": uid, "descrizione": "Generato da unineuromed.it, piani di studio (adapters/unineuromed.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
