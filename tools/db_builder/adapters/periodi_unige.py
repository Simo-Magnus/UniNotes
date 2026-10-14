"""Semestre degli insegnamenti dell'Università di Genova da corsi.unige.it (scheda `off.f/<a.a.>/ins/<id>`).

La scheda riporta il campo «PERIODO» («1° Semestre», «2° Semestre», «Annuale»…). Gli insegnamenti
«integrati» («Questo insegnamento è composto da: …») non hanno un periodo proprio: la scheda elenca
i moduli, ciascuno con la sua scheda e il suo periodo. Se tutti i moduli hanno lo stesso periodo, vale per
l'insegnamento (fonte: la scheda del primo modulo); se sono in semestri diversi si passa «1,2»
(pulizia.periodo: moduli in semestri diversi = annuale). Se né la scheda né i moduli dicono il periodo,
resta una lacuna (LACUNE). Mai dall'anno di corso, dal codice o da altri insegnamenti.
Al massimo 1,6 richieste al secondo; cache su disco in `$UN_HTTP_CACHE/periodi_unige` (se impostata).
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import threading
import time

import requests

from . import periodi

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
LACUNE: dict[str, str] = {}  # id -> motivo, per il rapporto


class Blocked(Exception):
    pass


class _Http:
    def __init__(self, rate: float = 1.6):
        self.gap, self.last, self.lock = 1.0 / rate, 0.0, threading.Lock()
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = os.path.join(d, "periodi_unige") if d else None
        if self.dir:
            os.makedirs(self.dir, exist_ok=True)
        self.richieste = 0

    def get(self, url: str):
        """Testo della pagina; None se 404; "ERR" se il server non risponde. Blocked se 403/429."""
        f = os.path.join(self.dir, hashlib.sha1(url.encode()).hexdigest() + ".json") if self.dir else None
        if f and os.path.exists(f):
            return json.load(open(f, encoding="utf-8"))["t"]
        for att in range(4):
            with self.lock:
                w = self.last + self.gap - time.monotonic()
                if w > 0:
                    time.sleep(w)
                self.last = time.monotonic()
                self.richieste += 1
            try:
                r = requests.get(url, headers=HEADERS, timeout=60)
            except requests.RequestException:
                time.sleep(2 ** att)
                continue
            if r.status_code in (403, 429):
                raise Blocked(f"corsi.unige.it {r.status_code}")
            if r.status_code in (200, 404):
                t = r.text if r.status_code == 200 else None
                if f:
                    json.dump({"t": t}, open(f, "w", encoding="utf-8"), ensure_ascii=False)
                return t
            time.sleep(1 + att)
        return "ERR"


def _campi(s: str) -> dict[str, str]:
    return {re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", th))).strip().upper(): td
            for th, td in re.findall(r"<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>", s, re.S)}


def _periodo(testo: str) -> str | None:
    """«1° Semestre» -> «1»; «Annuale» -> «annuale»; altro (trimestri, cicli…) -> None."""
    t = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", testo))).strip().lower()
    if not t:
        return None
    if "annual" in t or "year" in t and "semest" not in t:
        return "annuale"
    m = re.match(r"(\d)\W{0,3}\s*(?:semestre|semester)\b", t) or re.match(r"(primo|secondo|first|second)\s+(?:semestre|semester)\b", t)
    if m:
        return {"1": "1", "2": "2", "primo": "1", "first": "1", "secondo": "2", "second": "2"}.get(m.group(1))
    return None


def leggi(s: str) -> tuple[str | None, str, list[str]]:
    """(periodo, testo grezzo del campo, indirizzi delle schede dei moduli)."""
    c = _campi(s)
    grezzo = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", c.get("PERIODO") or c.get("SEMESTER") or ""))).strip()
    mod = c.get("MODULI") or c.get("MODULES") or ""
    figli = []
    if re.search(r"(?i)composto da|composed of|consists of", mod):
        figli = re.findall(r"href=['\"](https://corsi\.unige\.it/off\.f/\d+/ins/\d+)(?:\.html)?['\"]", mod)
    return _periodo(grezzo), grezzo, figli


def fetch_periodi(uid: str, log=print) -> dict:
    mancanti = [m for m in periodi.mancanti(uid) if m.get("url")]
    h = _Http()
    out: dict[str, dict] = {}
    LACUNE.clear()
    cache_s: dict[str, tuple] = {}

    def scheda(url):
        if url not in cache_s:
            t = h.get(url)
            cache_s[url] = ("ERR" if t == "ERR" else None) if not isinstance(t, str) or t == "ERR" else leggi(t)
            if t is None:
                cache_s[url] = "NONE"
        return cache_s[url]

    for n, m in enumerate(mancanti, 1):
        r = scheda(m["url"])
        if r == "ERR":
            LACUNE[m["id"]] = "scheda non raggiungibile (errori del server)"
            continue
        if r == "NONE":
            LACUNE[m["id"]] = "scheda non pubblicata (404)"
            continue
        p, grezzo, figli = r
        if p:
            out[m["id"]] = {"periodo": p, "fonte": m["url"]}
        elif figli:
            ps, fonte = [], None
            for u in figli:
                rf = scheda(u)
                if isinstance(rf, tuple) and rf[0]:
                    ps.append(rf[0])
                    fonte = fonte or u
            if ps and len(ps) == len(figli):
                u = sorted(set(ps))
                out[m["id"]] = {"periodo": u[0] if len(u) == 1 else "1,2" if u == ["1", "2"] else "annuale", "fonte": fonte}
            elif ps:
                LACUNE[m["id"]] = "insegnamento composto da moduli: solo alcuni moduli riportano il periodo"
            else:
                LACUNE[m["id"]] = "insegnamento composto da moduli: né la scheda né i moduli riportano il periodo"
        else:
            LACUNE[m["id"]] = ("la scheda riporta un periodo non interpretabile: " + grezzo) if grezzo else "la scheda non riporta il periodo"
        if n % 100 == 0:
            log(f"[{uid}]   schede {n}/{len(mancanti)}, trovati {len(out)}, richieste {h.richieste}")
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}; richieste {h.richieste}")
    return out
