"""Insegnamenti e docenti dell'Università Telematica "Leonardo da Vinci" da www.unidav.it.

La pagina del corso ha i piani degli studi per indirizzo ("4A – PIANO DEGLI STUDI – Indirizzo: …")
con le tabelle "ANNO I", "ANNO II", …: SSD, syllabus (PDF, colonna SY), materia, docente e CFU;
"… a scelta tra i seguenti" introduce gli insegnamenti opzionali. I syllabus in PDF sono del 2023
e il testo estratto non separa i riferimenti in modo affidabile: i libri non si prendono.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5}


def leggi_piano(s: str) -> list[dict]:
    out = []
    for blocco in re.split(r"PIANO DEGLI STUDI", s)[1:]:
        ind = re.search(r"Indirizzo:\s*([^<]+)", blocco)
        curriculum = html.unescape(ind.group(1)).strip() if ind else None
        k, scelta = None, False
        for e in re.finditer(r"(a scelta tra)|<tr[^>]*>(.*?)</tr>", blocco, re.S):
            if e.group(1):
                scelta = True
                continue
            intest = re.fullmatch(r"\s*ANNO\s+(I{1,3}|IV|V)\s*", _testo(e.group(2)))
            if intest:  # riga d'intestazione "ANNO I"
                k, scelta = ROMANI[intest.group(1)], False
                continue
            c = re.findall(r"<td[^>]*>(.*?)</td>", e.group(2), re.S)
            if not k or len(c) < 6 or _testo(c[0]).upper() == "SSD" or not _testo(c[2]):
                continue
            sy = re.search(r'href="([^"]+\.pdf)"', c[1])
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[5]))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            docenti = [re.sub(r"^Prof(?:\.ssa|\.)?\s+", "", _testo(x)) for x in re.split(r"<br\s*/?>|,", c[4])]
            out.append({"anno": k, "nome": _titolo(html.unescape(_testo(c[2]))), "curriculum": curriculum,
                        "ssd": _testo(c[0]) or None, "docenti": [d for d in docenti if d],
                        "cfu": int(v) if v is not None and v.is_integer() else v,
                        "syllabus": html.unescape(sy.group(1)) if sy else None, "a_scelta": scelta})
    return out


def fetch_ateneo(uid: str = "unidav", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        u = corso.get("url") or ""
        if "unidav.it/index.php/" not in u:
            continue
        r = c.get(u)
        voci = leggi_piano(r.text) if r else []
        if not voci:
            continue
        curricula = sorted({v["curriculum"] for v in voci if v["curriculum"]})
        righe: dict[str, dict] = {}
        for v in voci:
            key = f"{v['anno']}:{v['nome'].lower()}"
            item = righe.setdefault(key, {
                "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                "ssd": v["ssd"], "obbligatorio": False if v["a_scelta"] else None, "curriculum": None,
                "docenti": [], "url": v["syllabus"] or u, "libri": [], "esami": [], "fonte": u, "verificato_il": oggi,
                "stato_libri": "da_aggiungere", "_c": set()})
            item["docenti"] = list(dict.fromkeys(item["docenti"] + v["docenti"]))
            item["_c"].add(v["curriculum"])
        for i in righe.values():
            cs = i.pop("_c")
            if len(curricula) > 1 and cs != set(curricula):
                i["curriculum"] = ", ".join(sorted(x for x in cs if x))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": u,
                    "curricula": curricula if len(curricula) > 1 else None, "fonte": u, "verificato_il": oggi,
                    "insegnamenti": list(righe.values())})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unidav.it, piani degli studi (adapters/unidav.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
