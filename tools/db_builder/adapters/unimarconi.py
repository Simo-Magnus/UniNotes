"""Insegnamenti dell'Università Telematica Guglielmo Marconi dai regolamenti didattici.

Il sito non ha l'elenco degli insegnamenti in HTML: la pagina del corso linka il "Regolamento
Didattico" (PDF), il cui Allegato 2 ha per ogni curriculum ("Curriculum N / Nome: …") la tabella
Anno | Nome | Tip. | Ambito | SSD | CFU (l'anno è nella prima riga di ogni blocco) e le "Rose" di
insegnamenti a scelta ("Marketing - 6 CFU, ECON-07/A (ex SECS-P/08)"). La tabella si legge con
pdfplumber, che rispetta le celle. I regolamenti non hanno testi né docenti.
"""
from __future__ import annotations

import html
import io
import json
import pathlib
import re
import time
import unicodedata

from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
TESTA = ["anno", "nome", "tip.", "ambito", "ssd", "cfu"]


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _ssd(s: str) -> str | None:
    m = re.search(r"\b([A-Z]{2,5}-\d{2}(?:/[A-Z])?)\b", s or "")
    return m.group(1) if m else None


def _cfu(s: str):
    m = re.search(r"\d+(?:[.,]\d+)?", s or "")
    if not m:
        return None
    v = float(m.group(0).replace(",", "."))
    return int(v) if v.is_integer() else v


def leggi_regolamento(data: bytes) -> list[dict]:
    import pdfplumber
    out, curriculum, anno, in_tabella, rosa = [], None, None, False, None
    with pdfplumber.open(io.BytesIO(data)) as pdf:
        for pagina in pdf.pages:
            testo = pagina.extract_text() or ""
            for m in re.finditer(r"Curriculum\s+\d+\s*\n\s*Nome:\s*(.+)", testo):
                curriculum, anno, in_tabella = m.group(1).strip(), None, False
            for tab in pagina.extract_tables():
                for riga in tab:
                    c = [re.sub(r"\s+", " ", x or "").strip() for x in riga]
                    if [x.lower() for x in c] == TESTA:
                        in_tabella, anno = True, None
                        continue
                    if not in_tabella or len(c) != 6:
                        if len(c) != 6:
                            in_tabella = False
                        continue
                    if c[0]:
                        anno = ANNI.get(c[0].lower(), anno)
                    if not c[1] or not anno:
                        continue
                    out.append({"anno": anno, "nome": re.sub(r"\s*\(\d+\s*CFU\)\s*$", "", c[1]), "taf": c[2] or None,
                                "ssd": _ssd(c[4]), "cfu": _cfu(c[5]), "curriculum": curriculum,
                                "a_scelta": bool(re.search(r"(?i)\ba scelta\b|scelta libera|rosa", c[1]))})
            # rose degli insegnamenti a scelta: "Nome - 6 CFU, SSD"
            for riga in testo.splitlines():
                r = re.match(r"\s*Rosa\s+(\d+)\s*$", riga)
                if r:
                    rosa = r.group(1)
                    continue
                m = re.match(r"\s*(.+?)\s+-\s+(\d+)\s*CFU\b(?:,\s*(.*))?$", riga)
                if rosa and m:
                    out.append({"anno": None, "nome": m.group(1).strip(), "taf": None, "ssd": _ssd(m.group(3) or ""),
                                "cfu": int(m.group(2)), "curriculum": curriculum, "a_scelta": True})
                elif rosa and riga.strip() and not m and not re.match(r"\s*\d+\s", riga):
                    rosa = None if re.match(r"\s*(Curriculum|ALLEGATO|Tabella|Art\.)", riga) else rosa
    return out


def fetch_ateneo(uid: str = "unimarconi", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if "unimarconi.it/" in (x.get("url") or "")]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=2.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        r = c.get(corso["url"])
        if not r:
            continue
        regolamenti = [html.unescape(h) for h, t in re.findall(r'href="([^"]+\.pdf)"[^>]*>(.*?)</a>', r.text, re.S)
                       if re.search(r"(?i)regolamento[_ -]?didattico", h + " " + _testo(t))]
        if not regolamenti:
            continue
        # il più recente: la cartella di caricamento (…/uploads/AAAA/MM/) più alta
        fonte = sorted(regolamenti, key=lambda h: re.search(r"uploads/(\d{4}/\d{2})", h).group(1)
                       if re.search(r"uploads/(\d{4}/\d{2})", h) else "")[-1]
        try:
            with c.lock:
                c.requests += 1
            rp = c.s.get(fonte, timeout=120)
            voci = leggi_regolamento(rp.content) if rp.content[:5] == b"%PDF-" else []
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}]   {corso['id']}: {e!r}")
            voci = []
        if not voci:
            continue
        curricula = sorted({v["curriculum"] for v in voci if v["curriculum"]})
        righe: dict[str, dict] = {}
        for v in voci:
            key = f"{v['anno']}:{_norm(v['nome'])}"
            item = righe.setdefault(key, {
                "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                "ssd": v["ssd"], "obbligatorio": False if v["a_scelta"] else None, "curriculum": None, "docenti": [],
                "url": fonte, "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi,
                "stato_libri": "da_aggiungere", "_c": set()})
            item["_c"].add(v["curriculum"])
        for i in righe.values():
            cs = i.pop("_c")
            if len(curricula) > 1 and None not in cs and cs != set(curricula):
                i["curriculum"] = ", ".join(sorted(cs))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": corso["url"],
                    "curricula": curricula if len(curricula) > 1 else None, "fonte": fonte, "verificato_il": oggi,
                    "insegnamenti": list(righe.values())})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dai regolamenti didattici di www.unimarconi.it "
                                                 "(adapters/unimarconi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
