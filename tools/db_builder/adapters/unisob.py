"""Insegnamenti, docenti, libri e appelli dell'Università Suor Orsola Benincasa da www.unisob.na.it.

Ogni dipartimento ha il servizio LePrE (`/universita/facolta/<dip>/lepre/`, dip = giurisprudenza,
formazione, lettere):

- `programmi.asp` (form: R1 corso, R3 tipologia, R4 anno di corso, R5 a.a., R2 ordinamento) →
  tabella con attività formativa (link a `programma.asp?id=…`), docenti, anno, CFU;
- `programma.asp?id=…` → SSD e "Testi adottati";
- `esami.asp` (stessa form) → calendario degli appelli per insegnamento, con giorno e mese ma senza
  anno ("14 Dicembre ore 09:30 - sessione: straordinaria"): l'anno è quello dell'a.a. (settembre-
  dicembre il primo, gennaio-agosto il secondo).
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unisob.na.it/universita/facolta/{}/lepre/"
DIPARTIMENTI = ("giurisprudenza", "formazione", "lettere")
MESI = {m: i for i, m in enumerate(("gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto",
                                    "settembre", "ottobre", "novembre", "dicembre"), 1)}


def _scarica(c: Client, url: str, data: dict | None = None) -> str:
    """Le pagine del LePrE sono in Windows-1252 o in UTF-8, senza charset nell'intestazione: si
    scaricano e si decodificano qui (il Client le leggerebbe sempre come UTF-8)."""
    for tentativo in range(3):
        with c.lock:
            attesa = c.last + c.min_gap - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            c.last = time.monotonic()
            c.requests += 1
        try:
            r = c.s.post(url, data=data, timeout=90) if data else c.s.get(url, timeout=90)
            if r.ok:
                try:  # alcune pagine sono in UTF-8
                    return r.content.decode("utf-8")
                except UnicodeDecodeError:
                    return r.content.decode("cp1252", "replace")
        except Exception:  # noqa: BLE001
            time.sleep(2 ** tentativo)
    return ""


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_programmi(s: str) -> list[dict]:
    out = []
    for r in re.findall(r"<tr>(.*?)</tr>", s, re.S):
        c = re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)
        p = re.search(r'programma\.asp\?vr=1&amp;id=(\d+)', c[0]) if c else None
        if len(c) < 4 or not p:
            continue
        anno = re.search(r"\d", _testo(c[2]))
        cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[3]))
        v = float(cfu.group(0).replace(",", ".")) if cfu else None
        out.append({"id": p.group(1), "nome": html.unescape(_testo(c[0])),
                    "docenti": [html.unescape(_testo(d)) for d in re.findall(r"<a[^>]*>(.*?)</a>", c[1], re.S)],
                    "anno": int(anno.group(0)) if anno else None,
                    "cfu": int(v) if v is not None and v.is_integer() else v})
    return out


def leggi_programma(s: str) -> dict:
    t = _testo(s)
    ssd = re.search(r"SSD:\s*([A-Z]{2,5}[-/][\w/-]+)", t)
    m = re.search(r"Testi adottati(.*?)(?:Metodo di valutazione|English version|Ultimo aggiornamento)", s, re.S)
    return {"ssd": ssd.group(1) if ssd else None, "libri": estrai_libri(m.group(1)) if m else []}


def leggi_esami(s: str, anno: int, fonte: str) -> dict[str, list[dict]]:
    """Nome normalizzato dell'insegnamento → appelli."""
    oggi = time.strftime("%Y-%m-%d")
    out: dict[str, list[dict]] = {}
    for blocco in re.findall(r'<div class="sfondolepre">(.*?)</div>', s, re.S):
        nome = re.search(r"<a[^>]*>\s*<b>(.*?)</b>", blocco, re.S)
        if not nome:
            continue
        doc = re.search(r"Docent[ei]:\s*<b>(.*?)</b>", blocco, re.S)
        for g, mese, h, mi, nota in re.findall(r"(\d{1,2})\s+([A-Za-z]+)\s+ore\s+(\d{1,2})[:.](\d{2})([^<]*)", blocco):
            mm = MESI.get(mese.lower())
            if not mm:
                continue
            data = f"{anno if mm >= 9 else anno + 1}-{mm:02d}-{int(g):02d}"
            if data < oggi:
                continue
            prova = re.search(r"\(([^)]*)\)", nota)
            sess = re.search(r"sessione:\s*(\w+)", nota)
            out.setdefault(_norm(html.unescape(_testo(nome.group(1)))), []).append({
                "tipo": "prova_in_itinere" if prova and re.search(r"(?i)intercors|parzial|itinere", prova.group(1))
                else "appello", "data": data, "ora": f"{int(h):02d}:{mi}", "luogo": None,
                "modalita": ("scritto" if "scritt" in prova.group(1).lower() else "orale" if "oral" in prova.group(1).lower()
                             else None) if prova else None,
                "iscrizioni_dal": None, "iscrizioni_al": None,
                "docenti": html.unescape(_testo(doc.group(1))) if doc else None,
                "note": f"Sessione {sess.group(1)}" if sess else None, "fonte": fonte})
    return out


def fetch_ateneo(uid: str = "unisob", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    opzioni = []  # (dip, valore, nome)
    for d in DIPARTIMENTI:
        sel = re.search(r'name="R1".*?</select>', _scarica(c, BASE.format(d) + "programmi.asp?vr=1"), re.S)
        opzioni += [(d, v, html.unescape(t).strip()) for v, t in
                    re.findall(r'<option[^>]*value="(\d+)"[^>]*>(.*?)</option>', sel.group(0) if sel else "")
                    if v != "0"]
    abbinati = []
    for corso in corsi:
        n = _norm(corso["nome"])
        punti = sorted(((difflib.SequenceMatcher(None, n, _norm(o[2])).ratio(), o) for o in opzioni), reverse=True)
        if punti and punti[0][0] >= 0.75 and (len(punti) == 1 or punti[0][0] - punti[1][0] > 0.05):
            abbinati.append((corso, punti[0][1]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(opzioni)} corsi nel LePrE, {len(abbinati)} associati (su {len(corsi)})")
    out = []
    for corso, (d, v, nome) in abbinati:
        base = BASE.format(d)
        form = {"R1": v, "R3": "0", "R4": "0", "R5": f"{anno}/{anno + 1}", "R2": "1"}
        voci = leggi_programmi(_scarica(c, base + "programmi.asp?vr=1&mod=el", form))
        if not voci:
            continue
        esami = leggi_esami(_scarica(c, base + "esami.asp?vr=1&mod=el",
                                     {"R1": v, "R3": "0", "R5": "0", "R4": "0", "R2": "1"}), anno, base + "esami.asp")
        righe: dict[str, dict] = {}
        for x in voci:
            key = f"{x['anno']}:{_norm(x['nome'])}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": _titolo(x["nome"]), "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": [],
                    "url": base + f"programma.asp?vr=1&id={x['id']}", "libri": [],
                    "esami": esami.get(_norm(x["nome"]), []), "fonte": base + "programmi.asp",
                    "verificato_il": oggi, "stato_libri": "da_aggiungere", "_p": [],
                }
                if item["esami"]:
                    item["stato_esami"] = "completo"
            item["docenti"] = list(dict.fromkeys(item["docenti"] + x["docenti"]))
            item["_p"].append(base + f"programma.asp?vr=1&id={x['id']}")
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": corso.get("url"), "curricula": None,
                    "fonte": base + "programmi.asp", "verificato_il": oggi, "insegnamenti": list(righe.values())})
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi, {len(items)} insegnamenti, {sum(len(i['esami']) for i in items)} appelli")

    def programma(i: dict) -> int:
        libri, viste = [], set()
        for u in i.pop("_p"):
            try:
                t = _scarica(c, u)
                d = leggi_programma(t) if t else None
            except Exception:  # noqa: BLE001
                d = None
            if not d:
                continue
            i["ssd"] = i["ssd"] or d["ssd"]
            for lb in d["libri"]:
                if lb["citazione"] not in viste:
                    viste.add(lb["citazione"])
                    libri.append(lb)
        i["libri"] = libri
        i["stato_libri"] = "completo" if libri else "da_aggiungere"
        return len(libri)

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(3) as ex:
            trovati = sum(ex.map(programma, items))
    else:
        for i in items:
            i.pop("_p", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dal servizio LePrE di www.unisob.na.it (adapters/unisob.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
