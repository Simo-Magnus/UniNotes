"""Insegnamenti, docenti e libri della LUM "Giuseppe Degennaro" da www.lum.it.

La pagina di ogni corso ha la fisarmonica "Piano di studi A.A. 2026/2027" con, per ogni
anno ("1° anno", …), gli insegnamenti: nome, CFU, docenti (link `lum.it/docenti/…`) e
"Scheda insegnamento" (PDF). Più blocchi nello stesso a.a. sono curricula diversi (senza nome:
si uniscono). Dalla scheda (pypdf) si leggono "Anno di corso e semestre di erogazione" e
"Materiale didattico utilizzato e materiale didattico consigliato".
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import io
import json
import pathlib
import re
import time

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5}


def leggi_piano(s: str, anno: int) -> list[dict]:
    # intestazione «Piano di studi A.A. 2026/2027» oppure, nelle pagine più recenti, «Piano di studi 26/27»
    m = re.search(rf"Piano di studi (?:A\.A\.\s*)?(?:{anno}\s*/\s*{anno + 1}|{anno % 100:02d}\s*/\s*{(anno + 1) % 100:02d})"
                  rf"(.*?)(?=Piano di studi (?:A\.A\.\s*)?\d{{2}}|$)", s, re.S)
    if not m:
        return []
    out, k, cur = [], None, None
    for e in re.finditer(r'<h4[^>]*>\s*(\d)\s*°\s*anno(?:\s*-\s*Percorso in\s*([^<]*?))?\s*</h4>'
                         r'|<h4[^>]*>\s*(Insegnamenti a scelta)[^<]*</h4>'
                         r'|<div class="box clearfix">\s*<p>(.*?)</p>\s*<p class="col2 right">(.*?)</p>(.*?)'
                         r'(?=<div class="box clearfix">|<h4|$)', m.group(1), re.S | re.I):
        if e.group(1):
            k, cur = int(e.group(1)), (_testo(e.group(2)) or None) if e.group(2) else None
        elif e.group(3):
            k, cur = None, None
        else:
            corpo = e.group(6)
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(e.group(5)))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            sch = re.search(r'<a href="([^"]+)"[^>]*class="link_syllabus"', corpo)
            out.append({"anno": k, "curriculum": cur, "nome": _titolo(html.unescape(_testo(e.group(4)))),
                        "cfu": int(v) if v is not None and v.is_integer() else v,
                        "docenti": [_testo(d) for d in re.findall(r'/docenti/[^"]*"[^>]*>(.*?)</a>', corpo, re.S)],
                        "scheda": html.unescape(sch.group(1)) if sch else None})
    return out


def leggi_scheda(data: bytes) -> dict:
    try:
        from pypdf import PdfReader
        testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - PDF illeggibile
        return {"periodo": None, "libri": []}
    per = re.search(r"semestre\s+di\s+erogazione\s*\n?\s*\w+\s+anno,\s*(primo|secondo)\s+semestre", testo, re.I)
    if not per and re.search(r"semestre\s+di\s+erogazione\s*\n?\s*\w+\s+anno,\s*annual", testo, re.I):
        periodo = "annuale"
    else:
        periodo = {"primo": "1", "secondo": "2"}.get(per.group(1).lower()) if per else None
    m = re.search(r"Materiale\s+didattico\s+utilizzato.*?consigliato\s*\n(.*?)(?:\n\s*(?:Altre informazioni|Note|"
                  r"Modalit[àa]|Lingua)\b|\Z)", testo, re.S | re.I)
    righe: list[str] = []
    for r in (m.group(1).splitlines() if m else []):
        r = r.strip(" •-–\t")
        if not r:
            continue
        # le righe che continuano un riferimento (minuscola, cifra, parentesi) si uniscono alla precedente
        if righe and (r[0].islower() or r[0] in "(,;") and not righe[-1].endswith("."):
            righe[-1] += " " + r
        else:
            righe.append(r)
    return {"periodo": periodo, "libri": estrai_libri("<br>".join(righe))}


def fetch_ateneo(uid: str = "lum", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if "lum.it/" in (x.get("url") or "")]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        r = c.get(corso["url"])
        voci = leggi_piano(r.text, anno) if r else []
        if not voci:
            continue
        righe: dict[str, dict] = {}
        for v in voci:
            key = f"{v['anno']}:{v['nome'].lower()}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": None, "obbligatorio": False if v["anno"] is None else None, "curriculum": None,
                    "docenti": [], "url": v["scheda"] or r.url, "libri": [], "esami": [], "fonte": r.url,
                    "verificato_il": oggi, "stato_libri": "da_aggiungere", "_s": set(), "_c": set(),
                }
            item["docenti"] = list(dict.fromkeys(item["docenti"] + v["docenti"]))
            item["_c"].add(v["curriculum"])
            if v["scheda"]:
                item["_s"].add(v["scheda"])
        curricula = sorted({v["curriculum"] for v in voci if v["curriculum"]})
        for i in righe.values():
            cs = i.pop("_c")
            if curricula and None not in cs:
                i["curriculum"] = ", ".join(sorted(cs))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": r.url, "curricula": curricula or None,
                    "fonte": r.url,
                    "verificato_il": oggi, "insegnamenti": list(righe.values())})
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {len(items)} insegnamenti")

    def scheda(i: dict) -> int:
        libri, viste = [], set()
        for u in sorted(i.pop("_s")):
            try:
                with c.lock:
                    c.requests += 1
                rp = c.s.get(u, timeout=90)
                d = leggi_scheda(rp.content) if rp.content[:5] == b"%PDF-" else None
            except Exception:  # noqa: BLE001
                d = None
            if not d:
                continue
            i["periodo"] = i["periodo"] or d["periodo"]
            for lb in d["libri"]:
                if lb["citazione"] not in viste:
                    viste.add(lb["citazione"])
                    libri.append(lb)
        i["libri"] = libri
        i["stato_libri"] = "completo" if libri else "da_aggiungere"
        return len(libri)

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            trovati = sum(ex.map(scheda, items))
    else:
        for i in items:
            i.pop("_s", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.lum.it, piani di studio e schede (adapters/lum.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
