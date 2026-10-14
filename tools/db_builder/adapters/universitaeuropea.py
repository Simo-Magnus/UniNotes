"""Insegnamenti dell'Università Europea di Roma da www.uer.it.

La pagina del corso (o le pagine dei suoi indirizzi, `/<area>/indirizzo/<nome>/`, linkate dalla
pagina del corso) ha il "Piano di studi" della coorte: tabelle "I anno – 2026/27", "II anno –
2027/28", … con insegnamento, SSD e CFU. Le schede degli insegnamenti sono su Esse3 con accesso:
niente docenti né libri.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time
import urllib.parse

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}


def leggi_piano(s: str) -> list[dict]:
    out = []
    s = s.replace("&#8211;", "–").replace("&ndash;", "–")
    parti = re.split(r"\b(I|II|III|IV|V|VI)\s+anno\s*[–-]\s*\d{4}/\d{2}", s)
    for romano, corpo in zip(parti[1::2], parti[2::2]):
        tab = re.search(r"<table.*?</table>", corpo, re.S)
        for r in re.findall(r"<tr.*?</tr>", tab.group(0) if tab else "", re.S):
            c = [_testo(x) for x in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, re.S)]
            if len(c) < 2 or not c[0] or re.match(r"(?i)insegnamento|totale", c[0]):
                continue
            cfu = re.search(r"\d+(?:[.,]\d+)?", c[-1])
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            ssd = c[1] if len(c) >= 3 and re.match(r"[A-Z]{2,5}[-/]", c[1]) else None
            out.append({"anno": ROMANI[romano], "nome": _titolo(html.unescape(c[0])), "ssd": ssd,
                        "cfu": int(v) if v is not None and v.is_integer() else v})
    return out


def fetch_ateneo(uid: str = "universitaeuropea", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if "uer.it/" in (x.get("url") or "")]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        r = c.get(corso["url"])
        if not r:
            continue
        area = "/" + urllib.parse.urlparse(r.url).path.strip("/").split("/")[0] + "/"
        pagine = {r.url: (None, leggi_piano(r.text))}
        for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            p = urllib.parse.urlparse(urllib.parse.urljoin(r.url, html.unescape(h)))
            if p.netloc.endswith("uer.it") and p.path.startswith(area) and "/indirizzo/" in p.path:
                u = f"https://{p.netloc}{p.path}"
                if u not in pagine:
                    rp = c.get(u)
                    h1 = re.search(r"<h1[^>]*>(.*?)</h1>", rp.text if rp else "", re.S)
                    nome = re.sub(r"(?i)^indirizzo\s+", "", _testo(h1.group(1))) if h1 else _testo(t)
                    pagine[u] = (nome or None, leggi_piano(rp.text) if rp else [])
        durata = corso.get("durata_anni") or 6
        piani = {u: (nome, v) for u, (nome, v) in pagine.items() if v and max(x["anno"] for x in v) <= durata}
        if not piani:
            continue
        curricula = sorted({nome for nome, _ in piani.values() if nome}) if len(piani) > 1 else []
        righe: dict[str, dict] = {}
        for u, (nome, voci) in piani.items():
            for v in voci:
                key = f"{v['anno']}:{v['nome'].lower()}"
                item = righe.setdefault(key, {
                    "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": v["ssd"], "obbligatorio": False if re.search(r"(?i)a scelta", v["nome"]) else None,
                    "curriculum": None, "docenti": [], "url": u, "libri": [], "esami": [], "fonte": u,
                    "verificato_il": oggi, "stato_libri": "da_aggiungere", "_c": set()})
                item["_c"].add(nome)
        for i in righe.values():
            cs = i.pop("_c")
            if curricula and None not in cs and cs != set(curricula):
                i["curriculum"] = ", ".join(sorted(cs))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": r.url, "curricula": curricula or None,
                    "fonte": next(iter(piani)), "verificato_il": oggi, "insegnamenti": list(righe.values())})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uer.it, piani di studio (adapters/universitaeuropea.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
