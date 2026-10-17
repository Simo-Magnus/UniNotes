"""Insegnamenti, docenti e libri dell'Università del Piemonte Orientale da of.uniupo.it.

Il sito dell'offerta formativa pubblica la "Didattica erogata" di ogni corso:

- `/syllabus/<a.a.>` → dipartimenti; `/syllabus/<a.a.>/<dip>` → corsi (nome, tipo, link);
- `/syllabus/<a.a.>/<dip>/<corso>` → "N° Anno" con anno, codice, insegnamento, docenti, SSD,
  sede, curriculum, CFU; le righe con sfondo grigio sono attività opzionali;
- scheda dell'insegnamento (`…/C<id>`) → "Testi di riferimento" e periodo.
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
BASE = "https://of.uniupo.it"


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _tipo(t: str) -> str | None:
    t = t.lower()
    if "ciclo unico" in t:
        return "LMCU"
    if "magistrale" in t:
        return "LM"
    if "laurea" in t:
        return "L"
    return None


def leggi_corso(s: str) -> list[dict]:
    out = []
    for attr, corpo in re.findall(r'<div\s+class="corso-row([^"]*)"([^>]*>.*?)(?=<div\s+class="corso-row|</main>|$)', s, re.S):
        # valore singolo (<span class="corso-value">) o più valori (<div|span class="corso-values …">)
        campi = {}
        for k, v1, v2 in re.findall(
                r'<span class="corso-label">([^<]*)</span>\s*(?:<span class="corso-values?[^"]*">(.*?)</span>\s*(?=<|$)|'
                r'<div\s+class="corso-values[^"]*">(.*?)</div>|<div\s+class="docenti-value">.*?</div>)', corpo, re.S):
            v = v1 or ", ".join(_testo(x) for x in re.findall(r'<span class="corso-value">(.*?)</span>', v2, re.S))
            campi.setdefault(_testo(k), v)
        doc = re.search(r'<div\s+class="docenti-value">(.*?)</div>', corpo, re.S)
        url = re.search(r'data-url="([^"]+)"', corpo)
        nome = _testo(campi.get("Insegnamento", ""))
        if not nome:
            continue
        anno = re.match(r"\s*(\d)", _testo(campi.get("Anno corso", "")))
        v = _testo(campi.get("CFU", "")).replace(",", ".")
        cfu = float(v) if re.fullmatch(r"\d+(\.\d+)?", v) else None
        curr = _testo(campi.get("Curriculum", ""))
        out.append({
            "anno": int(anno.group(1)) if anno else None, "codice": _testo(campi.get("Codice", "")) or None,
            "nome": _titolo(nome), "ssd": (_testo(campi.get("SSD", "")) or None) if _testo(campi.get("SSD", "")) != "NN"
            else None,
            "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
            "curriculum": None if re.match(r"(?i)corso generico|percorso comune|tutti$", curr) else (curr or None),
            "docenti": sorted({" ".join(w.capitalize() if w.isupper() else w for w in _testo(d).split())
                               for d in re.findall(r"<a\s[^>]*>(.*?)</a>", doc.group(1) if doc else "", re.S)
                               if _testo(d)}),
            "url": BASE + html.unescape(url.group(1)) if url else None,
            "opzionale": bool(attr.strip()),
        })
    return out


def leggi_scheda(s: str) -> dict:
    campi = {_testo(k): v for k, v in re.findall(
        r'<span class="attivita-label">(.*?)</span>\s*<div class="attivita-value">(.*?)</div>', s, re.S)}
    per = _testo(campi.get("Periodo", "") or campi.get("Periodo didattico", "")).lower()
    m = re.search(r"(primo|secondo|terzo|\d)\W*(?:°\s*)?(semestre|periodo|trimestre)", per)
    periodo = "annuale" if "annual" in per else ({"primo": "1", "secondo": "2", "terzo": "3"}.get(m.group(1), m.group(1))
                                                if m else None)
    return {"libri": estrai_libri(campi.get("Testi di riferimento", "")), "periodo": periodo}


def fetch_ateneo(uid: str = "uniupo", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(f"{BASE}/syllabus/{anno}")
    dips = sorted(set(re.findall(rf'href="/syllabus/{anno}/(\d+)"', r.text if r else "")))
    pagine: dict[tuple[str, str], list[str]] = {}
    for d in dips:
        rd = c.get(f"{BASE}/syllabus/{anno}/{d}")
        for tipo, nome, url in re.findall(r'<div\s+class="cds-card"\s+data-tipo="([^"]*)"[^>]*>\s*<div class="corso-titolo">'
                                          r'\s*(.*?)\s*</div>.*?href="([^"]+)"', rd.text if rd else "", re.S):
            pagine.setdefault((_norm(re.sub(r"(?i)\s*\(abilitante.*?\)", "", _testo(nome))), _tipo(tipo) or ""), []).append(BASE + url)
    abbinati = []
    for corso in corsi:
        nome = _norm(re.sub(r"(?i)\s*\(abilitante.*?\)", "", corso["nome"]))
        cand = pagine.get((nome, corso["tipo"])) or pagine.get((nome, "L" if corso["tipo"] == "LMCU" else "")) or []
        if len(cand) == 1:
            abbinati.append((corso, cand[0]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {sum(len(v) for v in pagine.values())} corsi sul sito, {len(abbinati)} associati (su {len(corsi)})")

    def build(coppia) -> dict | None:
        corso, url = coppia
        r = c.get(url)
        if not r:
            return None
        righe: dict[str, dict] = {}
        curricula = set()
        for x in leggi_corso(r.text):
            if not x["anno"]:
                continue
            if x["curriculum"]:
                curricula.add(x["curriculum"])
            key = f"{x['anno']}:{x['codice'] or x['nome']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": x["ssd"], "obbligatorio": not x["opzionale"], "curriculum": None,
                    "docenti": x["docenti"], "url": x["url"], "libri": [], "esami": [], "fonte": url,
                    "verificato_il": oggi, "_c": set(),
                }
            item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
            item["_c"].add(x["curriculum"])
        for i in righe.values():
            cs = i.pop("_c")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": url, "curricula": sorted(curricula) or None,
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
    for x in out:
        for i in x["insegnamenti"]:
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(jobs) if syllabus else 0}")

    def scheda(u: str) -> int:
        try:
            r = c.get(u)
            if not r:
                return 0
            d = leggi_scheda(r.text)
            for it in jobs[u]:
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
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da of.uniupo.it, Didattica erogata (adapters/uniupo.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
