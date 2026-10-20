"""Semestre degli insegnamenti dell'Università per Stranieri di Siena.

Ogni guida didattica (`online.unistrasi.it/docenti/Guide/<anno>/<sigla>.pdf`, la stessa da cui
`unistrasi.py` legge il piano) ha una tabella «PERIODO DI SVOLGIMENTO DELLE LEZIONI» con una X nella
colonna del I o del II semestre per ogni disciplina. Le X si riconoscono dalla posizione sulla pagina
(colonna di sinistra = I semestre, di destra = II). Si usa solo l'abbinamento per nome con una riga
della tabella della stessa guida; una disciplina senza X o con X in entrambe le colonne resta senza
semestre (non si deduce nulla).
"""
from __future__ import annotations

import io
import os
import re
import time
import unicodedata

import requests

from . import periodi

SP = os.environ.get("SEMESTRI_SP") or r"C:\Users\simon\AppData\Local\Temp\claude\D--University-Notes\0e1973a7-21aa-4a45-b9ef-77200eb6c84a\scratchpad"
UA = "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"
SSD = re.compile(r"^\s*([A-Z]{3,4}-\d{2}/[A-Z]|[A-Z]+(?:-[A-Z]+)?/\d{2})\s*-?\s*")
SOGLIA_X = 455  # le X del I semestre sono a x~390-420, quelle del II a x~495-505


def _n(t: str) -> str:
    t = re.sub(r"\(\s*\d+\s*cfu\s*\)|\(\s*tace\s*\)|\btraduzione lingua\b|\bcfu totali\b", lambda m: "traduzione" if "traduzione" in m.group(0) else "", t or "", flags=re.I)
    t = unicodedata.normalize("NFKD", t or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", t)


def _frammenti(page) -> list[tuple[float, float, str]]:
    out = []

    def v(text, cm, tm, fd, fs):
        if text.strip():
            x = tm[4] * cm[0] + tm[5] * cm[2] + cm[4]
            y = tm[4] * cm[1] + tm[5] * cm[3] + cm[5]
            out.append((x, y, text))
    page.extract_text(visitor_text=v)
    return out


def leggi_tabella(data: bytes) -> dict[str, set[str]]:
    """{nome normalizzato (o alternativa dopo «/»): {"1", "2"}} dalla tabella del periodo di svolgimento."""
    import pypdf
    r = pypdf.PdfReader(io.BytesIO(data))
    righe_tot: list[tuple[str, set[str]]] = []
    in_tabella = False
    for p in r.pages:
        t = p.extract_text() or ""
        if "PERIODO DI SVOLGIMENTO DELLE LEZIONI" in t and ("Discipline" in t or "Semestre" in t):
            in_tabella = True
        elif in_tabella and "CALENDARIO DEI CORSI" in t:
            break
        elif in_tabella and not re.search(r"^[ \t]*(?:[A-Z]{3,4}-\d{2}/[A-Z]|Laboratorio)", t, re.M):
            in_tabella = False
        if not in_tabella:
            continue
        righe: dict[int, list[tuple[float, str]]] = {}
        for x, y, tx in _frammenti(p):
            k = next((kk for kk in righe if abs(kk - y) <= 2), round(y))
            righe.setdefault(k, []).append((x, tx))
        for y in sorted(righe, reverse=True):
            fr = sorted(righe[y])
            xs = {("1" if x < SOGLIA_X else "2") for x, tx in fr if tx.strip() == "X"}
            nome = re.sub(r"\s+", " ", "".join(tx for x, tx in fr if tx.strip() != "X" and x < 400)).strip()
            if not nome and not xs:
                continue
            if re.fullmatch(r"\d{1,3}|Universit.*Siena|PERIODO DI SVOLGIMENTO DELLE LEZIONI|Semestre|Discipline|I|II|Semestre I|", nome):
                if not (xs and not nome):
                    continue
            righe_tot.append((nome, xs))
    # unione delle righe di continuazione (iniziano in minuscolo, senza codice SSD)
    voci: list[list] = []
    for nome, xs in righe_tot:
        if voci and nome and not SSD.match(nome) and nome[0].islower():
            voci[-1][0] += " " + nome
            voci[-1][1] |= xs
        elif not nome:  # X sole (a capo della voce precedente)
            if voci:
                voci[-1][1] |= xs
        else:
            voci.append([nome, set(xs)])
    out: dict[str, set[str]] = {}
    for nome, xs in voci:
        if not xs:
            continue
        nome = SSD.sub("", nome)
        nome = re.sub(r"\s*\b\d+\s*CFU\b", "", nome)
        for alt in [nome] + [a for a in nome.split("/") if a.strip()]:
            out.setdefault(_n(alt), set()).update(xs)
    return out


def fetch_periodi(uid: str, log=print) -> dict:
    mancanti = periodi.mancanti(uid)
    cache = os.path.join(SP, "semestri", f"cache_{uid}")
    os.makedirs(cache, exist_ok=True)
    tabelle: dict[str, dict[str, set[str]] | None] = {}
    out, senza = {}, {"nome non nella tabella del periodo": 0, "disciplina senza X nella tabella": 0,
                      "X in entrambi i semestri": 0, "guida non leggibile": 0}
    for m in mancanti:
        url = m["url"] or ""
        if not url.lower().endswith(".pdf"):
            senza["guida non leggibile"] += 1
            continue
        if url not in tabelle:
            f = os.path.join(cache, re.sub(r"\W+", "_", url) + ".pdf")
            if not os.path.exists(f):
                time.sleep(1)
                r = requests.get(url, headers={"User-Agent": UA}, timeout=120)
                if r.status_code == 200 and r.content[:4] == b"%PDF":
                    open(f, "wb").write(r.content)
            try:
                tabelle[url] = leggi_tabella(open(f, "rb").read())
            except Exception as e:  # noqa: BLE001
                log(f"[{uid}] guida non leggibile {url}: {e!r}")
                tabelle[url] = None
            log(f"[{uid}] {url}: {len(tabelle[url] or {})} voci nella tabella del periodo")
        tab = tabelle[url]
        if tab is None:
            senza["guida non leggibile"] += 1
            continue
        xs = tab.get(_n(m["nome"]))
        if xs is None:
            senza["nome non nella tabella del periodo"] += 1
        elif len(xs) != 1:
            senza["X in entrambi i semestri"] += 1
        else:
            out[m["id"]] = {"periodo": next(iter(xs)), "fonte": url}
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}; senza: {senza}")
    return out
