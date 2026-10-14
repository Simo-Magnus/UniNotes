"""Insegnamenti, docenti e libri dell'Università Telematica Internazionale UNINETTUNO.

- `www.uninettunouniversity.net/it/offertaformativa.aspx` → pagine dei corsi e dei loro indirizzi
  (`…aspx?faculty=…&degree=<id>&idIndirizzo=…&mode=cs`);
- pagina dell'indirizzo → "Piano degli Studi (A.A. 2026/2027)", titolo "<corso> (Anno Accademico
  …) - <indirizzo>" e tabelle "Primo anno", "Secondo anno", …: insegnamento (link al programma),
  settore, CFU, lingua, docenti delle videolezioni (spesso di altri atenei) e docente/tutor
  dell'insegnamento (quello che si mette in `docenti`);
- programma (`cyberspaziomateria.aspx?courseid=…`) → sezione "Testi".
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.uninettunouniversity.net"
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_piano(s: str) -> tuple[str | None, str | None, list[dict]]:
    h1 = re.search(r"<h1[^>]*>(.*?)</h1>", s, re.S)
    t = html.unescape(_testo(h1.group(1))) if h1 else ""
    m = re.match(r"(.*?)\s*\(Anno Accademico [^)]*\)\s*(?:-\s*(.*))?$", t)
    corso, indirizzo = (m.group(1), m.group(2)) if m else (t or None, None)
    out = []
    for anno, corpo in re.findall(r"<h3[^>]*>\s*(\w+) anno\s*</h3>(.*?)(?=<h3|$)", s, re.S | re.I):
        k = ANNI.get(anno.lower())
        if not k:
            continue
        for tr in re.findall(r"<tr>(.*?)</tr>", corpo, re.S):
            c = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(c) < 5:
                continue
            nome = re.search(r"<span title='([^']*)'", c[0])
            link = re.search(r"href='([^']*cyberspaziomateria\.aspx[^']*)'", c[0])
            ssd = re.search(r"Settore:\s*([A-Z]{2,5}-\d{2}/[A-Z]|[A-Z-]+/\d{2})", _testo(c[0]))
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[1]))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            tutor = [_testo(x) for x in re.findall(r"cyberspaziopaginamateriatutor\.aspx[^>]*>(.*?)</a>", c[4], re.S)]
            out.append({"anno": k, "nome": html.unescape(nome.group(1)) if nome else _testo(c[0]).split(" - ")[0],
                        "ssd": ssd.group(1) if ssd else None, "cfu": int(v) if v is not None and v.is_integer() else v,
                        "url": html.unescape(link.group(1)) if link else None,
                        "lingua": _testo(c[2]).lower() or None, "docenti": [x for x in tutor if x]})
    return corso, indirizzo, out


def leggi_programma(s: str) -> list[dict]:
    m = re.search(r'id="[^"]*_ctesti"[^>]*>(.*?)</span>\s*</td>', s, re.S)
    return estrai_libri(m.group(1)) if m else []


def fetch_ateneo(uid: str = "uninettuno", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(f"{BASE}/it/offertaformativa.aspx")
    pagine = sorted({html.unescape(h) for h in re.findall(r'href="(/it/[^"]+\.aspx\?[^"]*degree=\d+[^"]*mode=cs[^"]*)"',
                                                          r.text if r else "")})
    piani: dict[str, list[tuple[str, str | None, list[dict]]]] = {}
    for p in pagine:
        rp = c.get(BASE + p)
        corso, indirizzo, voci = leggi_piano(rp.text) if rp else (None, None, [])
        if corso and voci:
            piani.setdefault(_norm(corso), []).append((BASE + p, indirizzo, voci))
    out = []
    for corso in corsi:
        cand = piani.get(_norm(corso["nome"])) or []
        durata = corso.get("durata_anni") or 3
        # stesso nome per triennale e magistrale (Ingegneria gestionale): si tiene il piano con la durata giusta
        cand = [x for x in cand if max(v["anno"] for v in x[2]) <= durata
                and (durata > 2 or max(v["anno"] for v in x[2]) <= 2)]
        if corso.get("tipo") == "L":
            cand = [x for x in cand if max(v["anno"] for v in x[2]) == 3] or cand
        if not cand:
            continue
        indirizzi = sorted({x[1] for x in cand if x[1]})
        righe: dict[str, dict] = {}
        for url, indirizzo, voci in cand:
            for v in voci:
                key = f"{v['anno']}:{_norm(v['nome'])}"
                item = righe.setdefault(key, {
                    "codice": None, "nome": _titolo(v["nome"]), "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": v["ssd"], "obbligatorio": None, "curriculum": None, "docenti": [], "url": v["url"] or url,
                    "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere",
                    "_c": set()})
                item["docenti"] = list(dict.fromkeys(item["docenti"] + v["docenti"]))
                item["_c"].add(indirizzo)
        for i in righe.values():
            cs = i.pop("_c")
            if len(indirizzi) > 1 and None not in cs and cs != set(indirizzi):
                i["curriculum"] = ", ".join(sorted(cs))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": cand[0][0],
                    "curricula": indirizzi if len(indirizzi) > 1 else None, "fonte": cand[0][0],
                    "verificato_il": oggi, "insegnamenti": list(righe.values())})
    items = [i for x in out for i in x["insegnamenti"] if "cyberspaziomateria" in (i["url"] or "")]
    log(f"[{uid}] {len(piani)} corsi sul sito, {len(out)} associati (su {len(corsi)}), "
        f"{sum(len(x['insegnamenti']) for x in out)} insegnamenti")

    def programma(i: dict) -> int:
        rp = c.get(i["url"])
        i["libri"] = leggi_programma(rp.text) if rp else []
        i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
        return len(i["libri"])

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(3) as ex:
            trovati = sum(ex.map(programma, items))
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uninettunouniversity.net, piani di studio e "
                                                 "programmi (adapters/uninettuno.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
