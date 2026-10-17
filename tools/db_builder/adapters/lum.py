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


def _righe_tabella(layout: str) -> list[tuple[str, list[str]]]:
    """Le schede a.a. 2026/27 sono una tabella a due colonne (etichetta | contenuto): con
    `extract_text()` le parole escono una per riga e le celle si mescolano. Con
    `extraction_mode="layout"` le colonne restano allineate: si separano alla colonna in cui
    inizia il contenuto di «Denominazione» e si raggruppano le righe per etichetta."""
    m = re.search(r"^( *)(Denominazion\w*)( {3,})\S", layout, re.M)
    if not m:
        return []
    c0 = len(m.group(1)) + len(m.group(2)) + len(m.group(3))
    righe: list[tuple[str, list[str]]] = []
    for riga in layout.splitlines():
        if not riga.strip():
            continue
        et, cont = riga[:c0 - 2], riga[c0 - 2:].strip()
        if re.fullmatch(r"A\.A\.\s*\d{4}\s*/\s*\d{4}|\d{1,2}", cont) and not et.strip():
            continue  # intestazione e numero di pagina
        if et.strip() and re.match(r" {0,2}[A-ZÀ-Ý]", et):
            righe.append((et.strip(), [cont] if cont else []))
        elif righe:
            if et.strip():
                righe[-1] = (righe[-1][0] + " " + et.strip(), righe[-1][1])
            if cont:
                righe[-1][1].append(cont)
    return righe


_SEM = {"1": "1", "i": "1", "primo": "1", "2": "2", "ii": "2", "secondo": "2"}


def _periodo(testo: str) -> str | None:
    """«1° anno, 1° semestre», «Anno di corso: II semestre di erogazione: primo», «… annuale»."""
    t = re.sub(r"\s+", " ", testo.lower())
    s = (re.search(r"\b(1|2|i{1,2}|primo|secondo)\s*[°^º]?\s*semestre\b(?!\s+di\s+erogazione)", t)
         or re.search(r"semestre di erogazione:?\s*(1|2|i{1,2}|primo|secondo)\b", t))
    if s:
        return _SEM[s.group(1)]
    if re.search(r"semestre di erogazione:?\s*(?:\w+\s+anno,\s*)?annual|\b\d°?\s*anno,\s*annual", t):
        return "annuale"
    return None


_PUNTO = r"[•●▪◦\uf0b7\-–]"
_NON_LIBRO = re.compile(
    r"(?i)^(?:(?:le |il |la |i |gli |delle |dei )?(?:dispens|material|slide|lucidi|appunti)|elencare|indicare|nb\b|n\.b|"
    r"casi stud|articol|sar[àa] |gli studenti|per i non|per gli studenti|"
    r"testi? (?:consigliat|di riferimento|adottat)|libri? di testo|bibliografia|riferimenti)")


def _libri_materiale(righe: list[str]) -> list[dict]:
    """Voci della cella «Materiale didattico»: una per punto elenco o numero (le righe seguenti la continuano).
    Il tipo (consigliato/obbligatorio) solo se la cella lo dice («Testi consigliati», «facoltativo»)."""
    from .testi import _libero, _strutturato, _tipo
    voci: list[str] = []
    for l in righe:
        if re.match(rf"(?:{_PUNTO}\s*|(?:\d{{1,2}}[.)]|\(?[a-zA-Z][.)])\s+)", l) or _NON_LIBRO.match(l) or not voci:
            voci.append(re.sub(rf"^(?:{_PUNTO}|\d{{1,2}}[.)]|\(?[a-zA-Z][.)])\s*", "", l))
        else:
            voci[-1] += " " + l
    out, viste, tipo_sez = [], set(), None
    for v in voci:
        v = re.sub(r"\s+", " ", v).strip()
        if not v:
            continue
        if re.match(r"(?i)^(?:testi|libri|letture|materiale)\s+(?:consigliat\w+|facoltativ\w+|di approfondimento)\s*:?$", v):
            tipo_sez = "consigliato"
            continue
        if re.match(r"(?i)^(?:testi|libri)\s+(?:obbligatori\w*|adottat\w+|di testo|di riferimento)\s*:?$", v):
            tipo_sez = "obbligatorio" if re.search(r"obbligator|adottat", v, re.I) else None
            continue
        if v.endswith(":") or len(v) < 12 or len(v) > 600 or _NON_LIBRO.match(v):
            continue
        if not re.search(r"[A-Za-zÀ-ÿ]{3}.*[A-Za-zÀ-ÿ]{3}", v) or not (re.search(r"[,.]", v) or _strutturato(v)):
            if len(v.split()) < 3:
                continue
        item = _strutturato(v) or _libero(v)
        item["tipo"] = item.get("tipo") or _tipo(v) or tipo_sez
        key = re.sub(r"\W+", "", item["citazione"].lower())[:120]
        if key not in viste:
            viste.add(key)
            out.append(item)
    return out



def _leggi_scheda_tabella(data: bytes) -> dict | None:
    try:
        from pypdf import PdfReader
        layout = "\n".join(p.extract_text(extraction_mode="layout") or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - PDF illeggibile
        return None
    righe = _righe_tabella(layout)
    if not righe:
        return None
    periodo, materiale, programma = None, [], []
    for et, cont in righe:
        e = et.lower()
        if e.startswith("anno di corso") and "semestre" in e:
            periodo = _periodo(" ".join(cont))
        elif e.startswith("materiale didattico"):
            materiale = cont
        elif e.startswith("programma") or e.startswith("contenuti del corso"):
            programma = cont
    if not periodo:  # schede «per regolamento»: «Anno di corso: II   semestre di erogazione: primo»
        periodo = _periodo(layout)
    libri = _libri_materiale(materiale)
    return {"periodo": periodo, "libri": libri, "programma": programma}


def leggi_scheda(data: bytes) -> dict:
    t = _leggi_scheda_tabella(data)
    if t and (t["periodo"] or t["libri"]):
        return t
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
