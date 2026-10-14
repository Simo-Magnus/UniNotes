"""Insegnamenti, docenti e libri dell'Università del Salento da www.unisalento.it.

Esse3 di UniSalento non pubblica l'offerta; il portale sì:

- elenchi `…/cosa-studiare/corsi-di-laurea`, `…-magistrale`, `…-magistrale-a-ciclo-unico`
  → schede dei corsi (`…/dettaglio/corso/<codice>/<nome>`);
- scheda del corso → "N° anno - Per gli immatricolati nel AAAA / AAAA" (cioè gli
  insegnamenti erogati nell'a.a. corrente per ogni anno di corso), per percorso:
  nome (SSD), crediti, tipo di attività, "Obbligatorio/Non obbligatorio", codice Esse3;
- scheda dell'insegnamento → docente responsabile, "Testi di riferimento".

I corsi del database (da Universitaly) si associano per codice nell'URL o per nome.
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
BASE = "https://www.unisalento.it"
DIP = "https://www.bbcc.unisalento.it"
ELENCHI = ["corsi-di-laurea", "corsi-di-laurea-magistrale", "corsi-di-laurea-magistrale-a-ciclo-unico"]


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_corso(s: str, anno: int) -> list[dict]:
    out = []
    aa = f"{anno}"
    blocchi = re.split(r'<button class="header[^"]*"[^>]*>\s*<span>\s*(\d)\s*°\s*anno\s*-\s*Per gli immatricolati nel\s*'
                       r'(\d{4})\s*/\s*\d{4}\s*</span>\s*</button>', s)
    for k, coorte, corpo in zip(blocchi[1::3], blocchi[2::3], blocchi[3::3]):
        k = int(k)
        if int(coorte) + k - 1 != int(aa):
            continue  # anno di corso non erogato nell'a.a. corrente
        for st in re.findall(r'<div class="study">(.*?)</div>', corpo, re.S):
            a = re.search(r'<a href="([^"]+)"[^>]*aria-label="([^"]*)"[^>]*>(.*?)</a>', st, re.S)
            p = re.search(r"<p>\s*(.*?)\s*</p>", st, re.S)
            if not a:
                continue
            t = _testo(a.group(3))
            ssd = re.search(r"\(([A-Z][\w/\- ]*)\)\s*$", t)
            label = html.unescape(a.group(2))
            percorso = label.split(" - ", 1)[0].strip() if " - " in label else None
            info = _testo(p.group(1)) if p else ""
            cfu = re.match(r"([\d.,]+)\s*crediti", info)
            cod = re.search(r"\[Cod\.:\s*(\w+)\]", info)
            v = float(cfu.group(1).replace(",", ".")) if cfu else None
            out.append({
                "anno": k, "nome": _titolo(re.sub(r"\s*\([A-Z][\w/\- ]*\)\s*$", "", t)),
                "ssd": ssd.group(1) if ssd and ssd.group(1) != "NN" else None,
                "cfu": int(v) if v is not None and v.is_integer() else v,
                "obbligatorio": False if "non obbligatorio" in info.lower() else ("obbligatorio" in info.lower() or None),
                "codice": cod.group(1) if cod else None, "url": html.unescape(a.group(1)), "percorso": percorso,
            })
    return out


def leggi_insegnamento(s: str) -> dict:
    campi = {_testo(a): b for a, b in re.findall(r"<dt>(.*?)</dt>\s*<dd>(.*?)</dd>", s, re.S)}
    doc = [_testo(x) for x in re.findall(r"<a [^>]*>(.*?)</a>", campi.get("Docente responsabile dell'erogazione", ""))]
    testi = re.search(r'title="Testi di riferimento".*?<div class="content[^"]*"[^>]*>(.*?)</div>', s, re.S)
    per = _testo(campi.get("Periodo", "") or campi.get("Semestre", "")).lower()
    m = re.search(r"(primo|secondo|terzo|\d)", per)
    return {
        "docenti": sorted({" ".join(w.capitalize() for w in d.split()) for d in doc if d}),
        "periodo": ("annuale" if "annual" in per else {"primo": "1", "secondo": "2", "terzo": "3"}.get(m.group(1),
                                                                                                        m.group(1)))
        if m else None,
        "libri": estrai_libri(testi.group(1)) if testi else [],
    }


def fetch_ateneo(uid: str = "unisalento", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    schede: dict[str, str] = {}  # codice corso -> url scheda
    nomi: dict[str, list[str]] = {}
    for e in ELENCHI:
        r = c.get(f"{BASE}/didattica/cosa-studiare/{e}")
        for url, cod, slug in re.findall(r'href="([^"]*dettaglio/corso/(\w+)/([\w-]+))"', r.text if r else ""):
            schede.setdefault(cod, html.unescape(url))
            nomi.setdefault(_norm(slug.replace("-", " ")), []).append(cod)
    abbinati = []
    for corso in corsi:
        m = re.search(r"dettaglio/corso/(\w+)", corso.get("url") or "")
        cod = m.group(1) if m and m.group(1) in schede else None
        if not cod:
            cand = nomi.get(_norm(corso["nome"])) or []
            cod = cand[0] if len(set(cand)) == 1 else None
        if cod:
            abbinati.append((corso, cod))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(schede)} schede corso, {len(abbinati)} corsi del database associati (su {len(corsi)})")

    def build(coppia) -> dict | None:
        corso, cod = coppia
        # la scheda con il piano è quella dei siti di dipartimento (qualsiasi dipartimento la mostra);
        # la scheda del portale centrale non ha il piano
        m = re.match(r"https?://[\w.]+\.unisalento\.it/offerta-formativa/percorsi-di-studio/-/dettaglio/corso/\w+/[\w-]+",
                     corso.get("url") or "")
        url = m.group(0) if m else f"{DIP}/offerta-formativa/percorsi-di-studio/-/dettaglio/corso/{cod}/{cod.lower()}"
        r = c.get(url)
        if not r:
            return None
        righe: dict[str, dict] = {}
        percorsi = set()
        for x in leggi_corso(r.text, anno):
            percorsi.add(x["percorso"])
            key = f"{x['anno']}:{x['codice'] or x['nome']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None, "docenti": [],
                    "url": x["url"], "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "_p": set(),
                }
            item["_p"].add(x["percorso"])
        for i in righe.values():
            ps = i.pop("_p")
            if len(percorsi) > 1 and ps != percorsi:
                i["curriculum"] = ", ".join(sorted(p for p in ps if p))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": url,
                "curricula": sorted(p for p in percorsi if p) if len(percorsi) > 1 else None,
                "fonte": url, "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(coppia) -> dict | None:
        try:
            return build(coppia)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {coppia[0].get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, abbinati) if r]
    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(jobs) if syllabus else 0}")

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if not r:
                return 0
            d = leggi_insegnamento(r.text)
            for it in jobs[url]:
                it["docenti"] = d["docenti"]
                it["periodo"] = d["periodo"]
                it["libri"] = d["libri"]
                it["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
            return len(d["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, list(jobs)), 1):
                trovati += k
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unisalento.it, schede corso (adapters/unisalento.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
