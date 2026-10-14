"""Insegnamenti e docenti dell'Università per Stranieri "Dante Alighieri" di Reggio Calabria.

- `www.unidarc.it/corsi/` → pagine dei corsi (`/corsi/<id>_<nome>-<classe>/`);
- pagina del corso → "Piano di studi": tabelle "Materie Primo Anno", "Materie Secondo Anno", …,
  "Materie a scelta" con materia (link alla scheda `/materie/…?anno=<fine a.a.>`), SSD e CFU;
- scheda della materia → docente (il link al syllabus è vuoto: niente libri).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unidarc.it"
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_piano(s: str) -> list[dict]:
    out = []
    for testa, corpo in re.findall(r"<th[^>]*>\s*Materie\s+([^<]*?)\s*</th>.*?<tbody>(.*?)</tbody>", s, re.S):
        a = re.match(r"(\w+)\s+anno", testa, re.I)
        k = ANNI.get(a.group(1).lower()) if a else None
        scelta = "scelta" in testa.lower()
        if not k and not scelta:
            continue
        for r in re.findall(r"<tr[^>]*>(.*?)</tr>", corpo, re.S):
            c = re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)
            if len(c) < 3 or not _testo(c[0]):
                continue
            link = re.search(r'href="([^"]+/materie/[^"]+)"', c[0])
            ssd = re.match(r"([A-Z]{2,5}-\d{2}(?:/[A-Z])?)", _testo(c[1]))
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[2]))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            out.append({"anno": k, "nome": html.unescape(_testo(c[0])), "ssd": ssd.group(1) if ssd else None,
                        "cfu": int(v) if v is not None and v.is_integer() else v,
                        "url": html.unescape(link.group(1)) if link else None, "a_scelta": scelta})
    return out


def fetch_ateneo(uid: str = "unidarc", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(f"{BASE}/corsi/")
    pagine = sorted({h for h in re.findall(r'href="(https://www\.unidarc\.it/corsi/\d+_[\w-]+/)"', r.text if r else "")})
    out = []
    for corso in corsi:
        # la classe è nell'indirizzo della pagina ("…-l-24r-l-24r/")
        cl = _norm(corso.get("classe") or "").replace(" ", "-")
        cand = [u for u in pagine if cl and re.search(rf"-{re.escape(cl)}r?(?:-|/)", u)]
        # vecchi e nuovi ordinamenti ("-l-24-" e "-l-24r-"): la pagina più recente (id più alto)
        cand = sorted(cand, key=lambda u: int(re.search(r"/corsi/(\d+)_", u).group(1)))[-1:]
        if not cand:
            continue
        rc = c.get(cand[0])
        voci = leggi_piano(rc.text) if rc else []
        if not voci:
            continue
        ins = [{"codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                "ssd": v["ssd"], "obbligatorio": False if v["a_scelta"] else None, "curriculum": None,
                "docenti": [], "url": v["url"] or cand[0], "libri": [], "esami": [], "fonte": cand[0],
                "verificato_il": oggi, "stato_libri": "da_aggiungere"} for v in voci]
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": cand[0], "curricula": None, "fonte": cand[0],
                    "verificato_il": oggi, "insegnamenti": ins})
    items = [i for x in out for i in x["insegnamenti"] if "/materie/" in i["url"]]

    def docente(i: dict) -> None:
        rm = c.get(i["url"])
        d = re.search(r'<span>Docente</span>\s*<a[^>]*>(.*?)</a>', rm.text if rm else "", re.S)
        i["docenti"] = [_testo(d.group(1))] if d else []

    if syllabus:
        with cf.ThreadPoolExecutor(3) as ex:
            list(ex.map(docente, items))
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unidarc.it, piani di studio (adapters/unidarc.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
