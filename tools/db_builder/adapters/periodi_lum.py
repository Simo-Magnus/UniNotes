"""Semestre degli insegnamenti LUM dalla «Scheda insegnamento» (PDF) linkata dalla pagina del corso su www.lum.it.

La scheda ha la riga «Anno di corso e semestre di erogazione» («2° anno – 2° semestre», «1° anno, Primo
semestre», «Annuale»…). Si cerca l'insegnamento nel «Piano di studi» dell'a.a. corrente della pagina del
corso e, se lì non c'è la scheda, negli a.a. precedenti ancora presenti sulla stessa pagina (stesso
insegnamento, stesso anno di corso: la pagina del PDF è indicata in `fonte`).
"""
from __future__ import annotations

import hashlib
import io
import os
import re
import time

import requests

from . import periodi
from .lum import leggi_piano
from .unibo import Client

ANNO = 2026
LACUNE: dict[str, str] = {}


def _norm(s: str) -> str:
    s = re.sub(r"(?i)^modulo:\s*", "", s or "")
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def periodo_da_testo(testo: str) -> str | None:
    """Semestre dalla riga «Anno di corso e semestre di erogazione» (it) o «Year of course and semester of provision» (en)."""
    m = (re.search(r"semestre\s+di\s+erogazione(.{0,90})", testo, re.S | re.I)
         or re.search(r"semester\s+of\s+provision(.{0,90})", testo, re.S | re.I))
    if not m:
        return None
    w = re.split(r"Lingua|Language|Teaching language", m.group(1), flags=re.I)[0]
    w = re.sub(r"\s+", " ", w)
    if re.search(r"(?i)annual|full year", w):
        return "annuale"
    if re.search(r"(?i)(?<![\w])(primo|1\s*(?:st)?|I)\W{0,3}(?:semestre|semester)", w):
        return "1"
    if re.search(r"(?i)(?<![\w])(secondo|2\s*(?:nd)?|II)\W{0,3}(?:semestre|semester)", w):
        return "2"
    return None


class Pdf:
    def __init__(self, rate: float = 1.6):
        self.gap, self.last = 1.0 / rate, 0.0
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = os.path.join(d, "lum_pdf") if d else None

    def testo(self, url: str) -> str | None:
        p = os.path.join(self.dir, hashlib.sha1(url.encode()).hexdigest() + ".txt") if self.dir else None
        if p and os.path.exists(p):
            return open(p, encoding="utf-8").read() or None
        t = None
        for att in range(3):
            w = self.last + self.gap - time.monotonic()
            if w > 0:
                time.sleep(w)
            self.last = time.monotonic()
            try:
                r = requests.get(url, timeout=90, headers={"User-Agent": "Mozilla/5.0 (UniversityNotes database builder)"})
            except requests.RequestException:
                time.sleep(2 ** att)
                continue
            if r.status_code == 404:
                break
            if r.status_code == 200:
                if r.content[:5] == b"%PDF-":
                    try:
                        from pypdf import PdfReader
                        t = "\n".join(pg.extract_text() or "" for pg in PdfReader(io.BytesIO(r.content)).pages)
                    except Exception:  # noqa: BLE001 - PDF illeggibile
                        t = None
                break
            time.sleep(1 + att)
        if p:
            os.makedirs(self.dir, exist_ok=True)
            open(p, "w", encoding="utf-8").write(t or "")
        return t


def fetch_periodi(uid: str = "lum", log=print) -> dict:
    mancanti = periodi.mancanti(uid)
    corsi = {c["id"]: c for c in periodi.carica(uid)["corsi"]}
    c, pdf = Client(rate=1.6), Pdf()
    pagine: dict[str, dict] = {}
    out: dict[str, dict] = {}
    for m in mancanti:
        cu = (corsi[m["corso"]].get("url") or "").strip()
        if cu not in pagine:
            r = c.get(cu) if cu else None
            pagine[cu] = {a: leggi_piano(r.text, a) for a in (ANNO, ANNO - 1, ANNO - 2)} if r else {}
        schede = []
        for a in (ANNO, ANNO - 1, ANNO - 2):
            for v in pagine[cu].get(a, []):
                if v["scheda"] and v["anno"] == m["anno"] and _norm(v["nome"]) == _norm(m["nome"]):
                    schede.append(v["scheda"])
        if not schede:
            LACUNE[m["id"]] = "scheda dell'insegnamento non pubblicata nella pagina del corso"
            continue
        for u in dict.fromkeys(schede):
            t = pdf.testo(u)
            p = periodo_da_testo(t) if t else None
            if p:
                out[m["id"]] = {"periodo": p, "fonte": u}
                break
        else:
            LACUNE[m["id"]] = "la scheda non riporta il semestre di erogazione (o PDF non leggibile)"
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}")
    return out
