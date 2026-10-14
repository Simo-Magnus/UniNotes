"""Insegnamenti di Humanitas University da www.hunimed.eu.

Ogni corso ha la pagina `/course/<corso>/programme-structure/` con lo "Study Plan" in schede per
anno ("First", "Second", …): modulo (insegnamento), crediti e argomenti con il loro SSD. I moduli
rimandano a schede in PDF del 2021: non sono dell'a.a. corrente e non se ne prendono i libri.
Le pagine del sito sono in inglese: l'associazione ai corsi del database è per nome. Si scarta il
piano se ha più anni del corso (la pagina di un corso magistrale mostra quello di un altro).
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.hunimed.eu/course/"
ANNI = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6}
# nome nel database (inizio, minuscolo) -> pagina del corso; i corsi con più voci ambigue
# (Medicina e chirurgia, Scienze infermieristiche specialistiche) restano fuori
PAGINE = {
    "fisioterapia": "physiotherapy",
    "infermieristica": "nursing",
    "osteopatia": "osteopathy",
    # biomedical-laboratory-techniques e medical-imaging-and-radiotherapy-techniques mostrano (10/2026)
    # il piano di Infermieristica: esclusi finché il sito non è corretto
    "biotechnologies for human health": "masters-degree-in-biotechnologies-for-human-health",
}


def leggi_piano(s: str) -> list[dict]:
    out = []
    for titolo, corpo in re.findall(r'data-tab-title="(\w+)"(.*?)(?=data-tab-title="|$)', s, re.S):
        k = ANNI.get(titolo.lower())
        if not k:
            continue
        # due formati: MODULES | CREDITS | TOPICS oppure SEMESTER | COURSE TEACHING | CREDITS | MODULES
        testa = [_testo(x).upper() for x in re.findall(r"<th[^>]*>(.*?)</th>", corpo, re.S)]
        sem = bool(testa) and testa[0].startswith("SEMEST")
        for r in re.findall(r"<tr>(.*?)</tr>", corpo, re.S):
            c = re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)
            if sem:
                periodo = _testo(c[0]).lower() if c else ""
                periodo = "annuale" if periodo.startswith("annual") else (periodo if periodo in ("1", "2") else None)
                c = c[1:]
            else:
                periodo = None
            if len(c) < 2 or not _testo(c[0]) or re.match(r"(?i)total", _testo(c[0])):
                continue
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[1]))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            ssd = re.findall(r"\b([A-Z]{2,5}-\d{2}/[A-Z])\b", c[2] if len(c) > 2 else "")
            out.append({"anno": k, "periodo": periodo, "nome": _titolo(html.unescape(_testo(c[0]))),
                        "cfu": int(v) if v is not None and v.is_integer() else v,
                        "ssd": ssd[0] if len(set(ssd)) == 1 else None})
    return out


def fetch_ateneo(uid: str = "hunimed", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        slug = next((v for k, v in PAGINE.items() if corso["nome"].lower().startswith(k)), None)
        if not slug:
            continue
        url = f"{BASE}{slug}/programme-structure/"
        r = c.get(url)
        voci = leggi_piano(r.text) if r else []
        # piano con più anni del corso: la pagina mostra quello di un altro corso (errore del sito)
        if not voci or max(v["anno"] for v in voci) > (corso.get("durata_anni") or 6):
            continue
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": f"{BASE}{slug}/", "curricula": None,
                    "fonte": url, "verificato_il": oggi,
                    "insegnamenti": [{"codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": v["periodo"],
                                      "cfu": v["cfu"], "ssd": v["ssd"], "obbligatorio": None, "curriculum": None,
                                      "docenti": [], "url": url, "libri": [], "esami": [], "fonte": url,
                                      "verificato_il": oggi, "stato_libri": "da_aggiungere"} for v in voci]})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti")
    return {"universita_id": uid, "descrizione": "Generato da www.hunimed.eu, Study Plan (adapters/hunimed.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
