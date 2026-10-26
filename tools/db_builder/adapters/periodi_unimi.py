"""Semestre degli insegnamenti dell'Università degli Studi di Milano dalla scheda dell'insegnamento su www.unimi.it.

La scheda (`www.unimi.it/it/corsi/insegnamenti-dei-corsi-di-laurea/<a.a.>/…`, in inglese
`www.unimi.it/en/education/degree-programme-courses/<a.a.>/…`) riporta «Periodo: Primo semestre» /
«Lesson period: Second semester» / «annuale» anche quando la tabella del piano didattico del sito del corso
non lo ha. Si prende solo ciò che la scheda dice: «Periodo non definito», «Open sessions» (prove finali,
attività senza lezioni), trimestri e quadrimestri senza date (l'app non li sa interpretare) restano lacune.
Gli insegnamenti senza scheda (il piano didattico del corso non la collega) restano senza periodo.

www.unimi.it è dietro Cloudflare: si leggono prima le pagine già scaricate (cache `SP/prog_unimi/cache`,
`$UN_HTTP_CACHE`); una pagina non in cache si scarica a 1,6 richieste al secondo al massimo e alla prima
risposta che non sia 200 (403, sfida Cloudflare) ci si ferma. Cache su disco anche della cartella `periodi_unimi`.
"""
from __future__ import annotations

import glob
import hashlib
import html
import json
import os
import re
import time

import requests

from . import periodi

SP = periodi.cartella_lavoro()
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
LACUNE: dict[str, str] = {}  # id -> motivo, per il rapporto
CAMPO = re.compile(r"(?:Periodo|Lesson period):?\s*(.{0,40}?)\s*(?:Orari delle lezioni|Lessons timetable|Modalit|Assessment|Syllabus|Programma)")
PERIODI = {"primo semestre": "1", "first semester": "1", "secondo semestre": "2", "second semester": "2",
           "annuale": "annuale", "year": "annuale", "annual": "annuale"}


class _Pagine:
    def __init__(self, rate: float = 1.6):
        self.gap, self.last, self.bloccato, self.richieste = 1.0 / rate, 0.0, False, 0
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = os.path.join(d, "periodi_unimi") if d else None
        self.cache_dirs = [p for p in [os.path.join(SP, "prog_unimi", "cache")] if os.path.isdir(p)]
        if self.dir:
            os.makedirs(self.dir, exist_ok=True)

    def _letta(self, url):
        k = hashlib.sha1(("txt|" + url).encode()).hexdigest()
        for d in self.cache_dirs:
            p = f"{d}/{k[:2]}/{k}.json"
            if os.path.exists(p):
                try:
                    j = json.load(open(p, encoding="utf-8"))
                except ValueError:
                    continue
                if j.get("s", 200) == 200 and j.get("t"):
                    return j["t"]
        if self.dir:
            p = os.path.join(self.dir, hashlib.sha1(url.encode()).hexdigest() + ".json")
            if os.path.exists(p):
                return json.load(open(p, encoding="utf-8"))["t"]
        return None

    def get(self, url: str):
        t = self._letta(url)
        if t is not None or self.bloccato:
            return t
        w = self.last + self.gap - time.monotonic()
        if w > 0:
            time.sleep(w)
        self.last = time.monotonic()
        self.richieste += 1
        try:
            r = requests.get(url, headers=HEADERS, timeout=60)
        except requests.RequestException:
            return None
        if r.status_code != 200 or "cf-chl" in r.text[:5000] or "Just a moment" in r.text[:2000]:
            if r.status_code in (403, 429, 503):
                self.bloccato = True  # Cloudflare: non si insiste
            return None
        if self.dir:
            json.dump({"t": r.text}, open(os.path.join(self.dir, hashlib.sha1(url.encode()).hexdigest() + ".json"), "w",
                                          encoding="utf-8"), ensure_ascii=False)
        return r.text


def periodo_scheda(pagina: str) -> tuple[str | None, str | None]:
    """(semestre, testo grezzo del campo periodo) dalla scheda."""
    txt = re.sub(r"\s+", " ", html.unescape(re.sub(r"<(script|style)[^>]*>.*?</\1>|<[^>]+>", " ", pagina, flags=re.S)))
    m = CAMPO.search(txt)
    if not m:
        return None, None
    grezzo = m.group(1).strip()
    return PERIODI.get(grezzo.lower()), grezzo


def fetch_periodi(uid: str, log=print) -> dict:
    h = _Pagine()
    out: dict[str, dict] = {}
    LACUNE.clear()
    visti: dict[str, tuple] = {}
    mancanti = periodi.mancanti(uid)
    for m in mancanti:
        u = m.get("url")
        if not u or "unimi.it" not in u:
            LACUNE[m["id"]] = "nessuna scheda dell'insegnamento collegata dal piano didattico del corso"
            continue
        if u not in visti:
            t = h.get(u)
            visti[u] = (None, None, False) if t is None else (*periodo_scheda(t), True)
        p, grezzo, letta = visti[u]
        if p:
            out[m["id"]] = {"periodo": p, "fonte": u}
        elif not letta:
            LACUNE[m["id"]] = "scheda non raggiungibile (www.unimi.it protetto da Cloudflare)"
        elif grezzo:
            LACUNE[m["id"]] = f"la scheda riporta «{grezzo}», non interpretabile come semestre"
        else:
            LACUNE[m["id"]] = "la scheda non riporta il periodo"
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}; schede distinte {len(visti)}; richieste {h.richieste}")
    return out
