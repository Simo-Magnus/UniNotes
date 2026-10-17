"""Insegnamenti, docenti e libri dell'Università Ca' Foscari Venezia da www.unive.it.

Esse3 di Ca' Foscari non pubblica l'offerta; i siti dei corsi sì:

- `unive.it/cdl/<codice>` → home del corso (`/web/it/<pagina>/home`) con il link
  "Insegnamenti e orari" (`/web/it/<id>/insegnamenti-e-orari`);
- `/data/it/<id>/insegnamenti-e-orari/<anno>` → insegnamenti dell'a.a. corrente per anno e
  curriculum: "<NOME> [<codice>]", partizione, periodo, docenti, "x su y CFU" (e orari);
- `/data/insegnamento/<id>/programma` → "Testi di riferimento".

L'elenco non dice se un insegnamento è obbligatorio: `obbligatorio` resta null.
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
BASE = "https://www.unive.it"


def _codice(url: str | None) -> str | None:
    m = re.match(r"https?://(?:www\.)?unive\.it/cdl/(\w+)", (url or "").strip())
    return m.group(1) if m else None


# Ca' Foscari divide l'anno in 4 «periodi» (1° e 2° nel 1° semestre, 3° e 4° nel 2°): le lezioni del 1° periodo vanno
# dal 21/09 a fine ottobre, quelle del 2° da inizio novembre a metà dicembre (file ICS ufficiale di ogni insegnamento),
# il 3° e il 4° da febbraio a maggio (piani delle frequenze pubblicati sul sito). «2° Periodo» NON è il 2° semestre.
PERIODO_A_SEMESTRE = {"1": "1", "2": "1", "3": "2", "4": "2"}


def _periodo(t: str) -> str | None:
    m = re.match(r"\s*(\d|I{1,3}|IV)\s*°?\s*(periodo|semestre|period|semester)", t, re.I)
    if m:
        n = {"I": "1", "II": "2", "III": "3", "IV": "4"}.get(m.group(1).upper(), m.group(1))
        if m.group(2).lower() in ("periodo", "period"):
            return PERIODO_A_SEMESTRE.get(n, n)
        return n
    return "annuale" if re.search(r"(?i)annual", t) else (t.strip() or None)


def leggi_anno(s: str) -> list[dict]:
    out = []
    curricula = re.split(r'<div class="my-2 p-0 titolo-esp">\s*Curriculum\s*<strong>(.*?)</strong>', s, flags=re.S)
    for curr, corpo in zip(curricula[1::2], curricula[2::2]):
        curr = _testo(curr)
        for card in re.split(r'(?=<div class="card border border-black">)', corpo)[1:]:
            testa = re.search(r'<a href="(?:https?:)?//www\.unive\.it/data/insegnamento/(\d+)"[^>]*>(.*?)</a>', card, re.S)
            if not testa:
                continue
            t = _testo(testa.group(2))
            m = re.match(r"(.*?)\s*\[(\w+)\]\s*$", t)
            nome, cod = (m.group(1), m.group(2)) if m else (t, None)
            ps = [_testo(x) for x in re.findall(r'<p class="mt-0 mb-0 pb-0">(.*?)</p>', card, re.S)]
            periodo = next((_periodo(x) for x in ps if re.search(r"(?i)periodo|semestre|annual", x)), None)
            cfu = re.search(r"<strong>\s*([\d.,]+)\s*(?:su\s*[\d.,]+)?\s*</strong>\s*CFU", card)
            v = float(cfu.group(1).replace(",", ".")) if cfu else None
            out.append({
                "id": testa.group(1), "nome": _titolo(nome), "codice": cod, "curriculum": curr, "periodo": periodo,
                "cfu": int(v) if v is not None and v.is_integer() else v,
                "docenti": [" ".join(w.capitalize() if w.isupper() else w for w in _testo(d).split())
                            for d in re.findall(r'<a href="/data/persone/\d+">(.*?)</a>', card, re.S)],
            })
    return out


def libri_programma(s: str) -> list[dict]:
    m = re.search(r'<h4 class="[^"]*card-title">\s*(?:Testi di riferimento|Referral texts|Textbooks)\s*</h4>.*?'
                  r'<div class="card-body">(.*?)</div>', s, re.S)
    if not m:
        return []
    libri = []
    for lb in estrai_libri(m.group(1)):
        # righe con il solo ISBN ("978-… (print)"): si attaccano al libro precedente
        if lb["isbn"] and not re.search(r"[A-Za-z]{4,}", re.sub(r"(?i)isbn|print|pdf|epub|ebook", "", lb["citazione"])):
            if libri and not libri[-1]["isbn"]:
                libri[-1]["isbn"] = lb["isbn"]
            continue
        libri.append(lb)
    return libri


def fetch_ateneo(uid: str = "unive", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _codice(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con sito unive.it/cdl")
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        r = c.get(f"{BASE}/cdl/{_codice(corso['url'])}")
        if not r:
            return None
        m = re.search(r'href="/web/it/(\d+)/insegnamenti-e-orari"', r.text)
        if not m:
            return None
        pid = m.group(1)
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        for k in range(1, durata + 1):
            url = f"{BASE}/data/it/{pid}/insegnamenti-e-orari/{k}"
            ra = c.get(url)
            if not ra:
                continue
            for x in leggi_anno(ra.text):
                if x["curriculum"] and x["curriculum"].upper() != "PERCORSO COMUNE":
                    curricula.add(x["curriculum"])
                key = f"{k}:{x['codice'] or x['nome']}"
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": x["codice"], "nome": x["nome"], "anno": k, "periodo": x["periodo"], "cfu": x["cfu"],
                        "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": [],
                        "url": f"{BASE}/data/insegnamento/{x['id']}", "libri": [], "esami": [], "fonte": url,
                        "verificato_il": oggi, "_ids": [], "_curr": set(),
                    }
                item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
                item["_ids"].append(x["id"])
                item["_curr"].add(x["curriculum"])
        for i in righe.values():
            cs = {x for x in i.pop("_curr") if x}
            if curricula and "PERCORSO COMUNE" not in {x.upper() for x in cs} and cs and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": f"{BASE}/web/it/{pid}/home", "curricula": sorted(curricula) or None,
                "fonte": f"{BASE}/web/it/{pid}/insegnamenti-e-orari", "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    ids = sorted({i for x in out for it in x["insegnamenti"] for i in it["_ids"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"programmi da leggere: {len(ids) if syllabus else 0}")
    libri: dict[str, list[dict]] = {}

    def leggi(i: str) -> None:
        try:
            r = c.get(f"{BASE}/data/insegnamento/{i}/programma")
            libri[i] = libri_programma(r.text) if r else []
        except Exception:  # noqa: BLE001
            libri[i] = []

    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, _ in enumerate(ex.map(leggi, ids), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   programmi {n}/{len(ids)}")
    trovati = 0
    for x in out:
        for it in x["insegnamenti"]:
            viste = set()
            for i in it.pop("_ids"):
                for lb in libri.get(i, []):
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        it["libri"].append(lb)
            if syllabus:
                it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
            trovati += len(it["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unive.it, Insegnamenti e orari (adapters/unive.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
