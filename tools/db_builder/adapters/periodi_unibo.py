"""Periodo didattico degli insegnamenti UniBo che il piano didattico non riporta.

Il piano di corsi.unibo.it (adapters/unibo.py) ha la colonna «periodo» solo per alcuni corsi di
studio; per gli altri il periodo si legge nella scheda ufficiale dell'insegnamento su www.unibo.it,
che riporta le date delle lezioni: «Orario delle lezioni [(Modulo N)] dal GG/MM/AAAA al GG/MM/AAAA»
(in inglese «Course Timetable [(Module N)] from Mon GG, AAAA to Mon GG, AAAA»). Le date passano
così come sono (periodo_inizio/periodo_fine): build_db le converte in semestre con pulizia.periodo.
Con più moduli si prende dal primo inizio all'ultima fine. Se la scheda non pubblica l'orario non
si scrive nulla (il periodo non si deduce da anno di corso, codice o nome).
"""
from __future__ import annotations

import concurrent.futures as cf
import re
from datetime import datetime

from . import periodi
from .unibo import Client, _testo, segui_risultato

IT = re.compile(r"Orario delle lezioni(?: \([^)]*\))? dal (\d\d/\d\d/\d{4}) al (\d\d/\d\d/\d{4})")
EN = re.compile(r"Course Timetable(?: \([^)]*\))? from ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4}) to ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4})")


def _data_en(s: str) -> str | None:
    s = s.replace(".", "")
    for f in ("%b %d, %Y", "%B %d, %Y"):
        try:
            return datetime.strptime(s, f).strftime("%d/%m/%Y")
        except ValueError:
            pass
    return None


def date_lezioni(html_scheda: str) -> tuple[str, str] | None:
    """(inizio, fine) GG/MM/AAAA delle lezioni dalla scheda, o None se non pubblicate."""
    t = re.sub(r"<(script|style).*?</\1>", " ", html_scheda, flags=re.S)
    t = _testo(t)
    coppie = IT.findall(t)
    if not coppie:
        coppie = [(_data_en(a), _data_en(b)) for a, b in EN.findall(t)]
        coppie = [(a, b) for a, b in coppie if a and b]
    if not coppie:
        return None
    k = lambda d: datetime.strptime(d, "%d/%m/%Y")  # noqa: E731
    return min((a for a, _ in coppie), key=k), max((b for _, b in coppie), key=k)


def fetch_periodi(uid: str = "unibo", log=print) -> dict:
    mancanti = periodi.mancanti(uid)
    per_url: dict[str, list[dict]] = {}
    for m in mancanti:
        if m.get("url"):
            per_url.setdefault(m["url"], []).append(m)
    log(f"[{uid}] {len(mancanti)} insegnamenti senza periodo, {len(per_url)} schede da leggere")
    c = Client(rate=1.6)
    ris: dict[str, dict] = {}

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if r and not re.search(r"/(insegnamento|course-unit)/\d{4}/", r.url):
                r = segui_risultato(c, r.text, per_url[url][0].get("codice"))
            if not r:
                return 0
            d = date_lezioni(r.text)
            if not d:
                return 0
            for m in per_url[url]:
                ris[m["id"]] = {"periodo": None, "periodo_inizio": d[0], "periodo_fine": d[1], "fonte": r.url}
            return len(per_url[url])
        except Exception as e:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            log(f"[{uid}]   {url}: {e!r}")
            return 0

    n = 0
    with cf.ThreadPoolExecutor(4) as ex:
        for k, v in enumerate(ex.map(scheda, list(per_url)), 1):
            n += v
            if k % 200 == 0:
                log(f"[{uid}]   schede {k}/{len(per_url)}: periodi trovati {n}")
    log(f"[{uid}] periodi trovati: {len(ris)}; richieste: {c.requests}")
    return ris
