"""Insegnamenti, docenti e libri dell'Università di Urbino Carlo Bo da www.uniurb.it.

Esse3 di Uniurb non pubblica l'offerta; il portale sì:

- `/corsi/<id>/insegnamenti-e-programmi` → insegnamenti dell'a.a. corrente: nome (link a
  `/insegnamenti-e-programmi/<id>`), docente, curriculum, SSD, anno, CFU;
- scheda dell'insegnamento → periodo e "Testi di studio".
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.uniurb.it"


def _id(url: str | None) -> str | None:
    m = re.search(r"uniurb\.it/corsi/(\d+)", url or "")
    return m.group(1) if m else None


def leggi_elenco(s: str) -> list[dict]:
    out = []
    for tr in re.findall(r'<tr valign="middle">(.*?)</tr>', s, re.S):
        td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if len(td) < 6:
            continue
        link = re.search(r'href="(/insegnamenti-e-programmi/(\d+))"[^>]*>\s*<strong>(.*?)</strong>', td[0], re.S)
        if not link:
            continue
        anno = re.match(r"\s*(\d)", _testo(td[4]))
        v = _testo(td[5]).replace(",", ".")
        cfu = float(v) if re.fullmatch(r"\d+(\.\d+)?", v) else None
        curr = _testo(td[2])
        out.append({
            "id": link.group(2), "url": BASE + link.group(1), "nome": _titolo(_testo(link.group(3))),
            "docenti": [_testo(x) for x in re.findall(r"<a [^>]*>(.*?)</a>", td[1], re.S) if _testo(x)],
            "curriculum": None if re.match(r"(?i)percorso comune", curr) else (curr.title() or None),
            "ssd": _testo(td[3]) or None, "anno": int(anno.group(1)) if anno else None,
            "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
        })
    return out


def leggi_scheda(s: str) -> dict:
    testi = re.search(r"<dt>\s*Testi di studio\s*</dt>\s*<dd>(.*?)</dd>", s, re.S)
    per = re.search(r'<td class="text-uppercase hidden-xs hidden-sm">\s*((?:Primo|Secondo|Terzo)\s+\w+|Annual\w*)\s*</td>',
                    s, re.I)
    p = per.group(1).lower() if per else ""
    periodo = "annuale" if p.startswith("annual") else {"primo": "1", "secondo": "2", "terzo": "3"}.get(
        p.split(" ")[0]) if p else None
    return {"libri": estrai_libri(testi.group(1)) if testi else [], "periodo": periodo}


def fetch_ateneo(uid: str = "uniurb", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi su www.uniurb.it")
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        url = f"{BASE}/corsi/{_id(corso['url'])}/insegnamenti-e-programmi"
        r = c.get(url)
        if not r:
            return None
        righe: dict[str, dict] = {}
        curricula = set()
        for x in leggi_elenco(r.text):
            if not x["anno"]:
                continue
            if x["curriculum"]:
                curricula.add(x["curriculum"])
            key = f"{x['anno']}:{x['nome'].lower()}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": x["ssd"], "obbligatorio": None, "curriculum": None, "docenti": [], "url": x["url"],
                    "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "_ids": [], "_curr": set(),
                }
            item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
            item["_ids"].append(x["url"])
            item["_curr"].add(x["curriculum"])
        for i in righe.values():
            cs = i.pop("_curr")
            if None not in cs and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": url.rsplit("/", 1)[0],
                "curricula": sorted(curricula) or None, "fonte": url, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    urls = sorted({u for x in out for i in x["insegnamenti"] for u in i["_ids"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(urls) if syllabus else 0}")
    dati: dict[str, dict] = {}

    def leggi(u: str) -> None:
        try:
            r = c.get(u)
            dati[u] = leggi_scheda(r.text) if r else {"libri": [], "periodo": None}
        except Exception:  # noqa: BLE001
            dati[u] = {"libri": [], "periodo": None}

    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, _ in enumerate(ex.map(leggi, urls), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(urls)}")
    trovati = 0
    for x in out:
        for it in x["insegnamenti"]:
            viste = set()
            for u in it.pop("_ids"):
                d = dati.get(u) or {}
                it["periodo"] = it["periodo"] or d.get("periodo")
                for lb in d.get("libri") or []:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        it["libri"].append(lb)
            if syllabus:
                it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
            trovati += len(it["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uniurb.it, Insegnamenti e programmi (adapters/uniurb.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
