"""Appelli d'esame di UniBG (Università di Bergamo) dalla bacheca pubblica di Esse3.

`https://unibg.esse3.cineca.it/Guide/PaginaListaAppelli.do`: per ogni struttura (dipartimento) la
bacheca elenca gli appelli pubblicati da oggi in poi; con una data elenca quelli di quel giorno.
Per avere anche le date già passate dell'a.a. (dal 1° settembre) si ripercorrono i giorni uno alla
volta, una struttura per volta. Le risposte restano su disco con la variabile UN_HTTP_CACHE (la
pagina senza data vale un giorno).
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import pathlib
import re
import time
from datetime import date, timedelta

import requests

from .esse3_appelli import HEADERS, _parse

BASE = "https://unibg.esse3.cineca.it"
URL = BASE + "/Guide/PaginaListaAppelli.do"


def _opzioni(page: str, name: str) -> list[tuple[str, str]]:
    sel = re.search(rf'<select[^>]*name="{name}".*?</select>', page, re.S)
    if not sel:
        return []
    return [(v, html.unescape(re.sub(r"<[^>]+>", "", t)).replace("\u200b", "").strip())
            for v, t in re.findall(r'<option value="([^"]*)"[^>]*>(.*?)</option>', sel.group(0), re.S)
            if v not in ("X", "-1", "")]


class _Sess:
    def __init__(self, delay: float):
        self.s = requests.Session()
        self.delay = delay
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unibg_esse3" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def post(self, data: dict, log) -> str | None:
        chiave = {**data, "_oggi": date.today().isoformat()} if data.get("DATA_ESA", "") == "" else data
        key = hashlib.sha1(json.dumps(chiave, sort_keys=True).encode()).hexdigest()
        f = self.dir / f"{key}.html" if self.dir else None
        if f and f.exists():
            return f.read_text(encoding="utf-8")
        for attempt in range(3):
            try:
                time.sleep(self.delay)
                r = self.s.post(URL, data=data, headers=HEADERS, timeout=300)
                r.raise_for_status()
                if f:
                    f.write_text(r.text, encoding="utf-8")
                return r.text
            except requests.RequestException as e:
                log(f"[unibg] esse3 {data.get('FAC_ID')} {data.get('DATA_ESA')} (tentativo {attempt + 1}): {e!r}")
                time.sleep(5 * (attempt + 1))
        return None


def _aggiungi(appelli: dict, trovati: dict) -> int:
    n = 0
    for cod, lst in trovati.items():
        viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(cod, [])}
        nuovi = []
        for x in lst:
            k = (x["data"], x["ora"], x["tipo"])
            if k not in viste:
                viste.add(k)
                nuovi.append(x)
        appelli.setdefault(cod, []).extend(nuovi)
        n += len(nuovi)
    return n


def fetch_appelli(uid: str = "unibg", corsi=None, log=print, delay: float = 0.7, dal: str | None = None,
                  con_corsi: bool = False):
    """Appelli per codice dell'attività; con `con_corsi` anche, per ogni corso di studio dell'elenco
    Esse3 (chiave: codice tra parentesi quadre, es. «65-R»), i codici delle attività che vi compaiono
    (con il titolo), per abbinare gli insegnamenti il cui codice nel catalogo è diverso."""
    sess = _Sess(delay)
    r = sess.s.get(URL, headers=HEADERS, timeout=60)
    facs = _opzioni(r.text, "FAC_ID")
    base = {"CDS_ID": "X", "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "", "form_id_form1": "form1"}
    appelli: dict[str, list[dict]] = {}
    per_corso: dict[str, dict[str, str]] = {}
    for fac, nome in facs:
        page = sess.post({**base, "FAC_ID": fac, "actionBar1": "Cerca"}, log)
        n = _aggiungi(appelli, _parse(page or "", URL))
        log(f"[unibg] esse3 {nome}: +{n} date (totale {len(appelli)} attività)")
        if con_corsi:  # corso per corso (il menu dei corsi si aggiorna con refresh=FAC_ID)
            pag = sess.post({**base, "FAC_ID": fac, "refresh": "FAC_ID"}, log)
            for cid, cnome in _opzioni(pag or "", "CDS_ID"):
                page = sess.post({**base, "FAC_ID": fac, "CDS_ID": cid, "actionBar1": "Cerca"}, log)
                mc = re.match(r"^\[([^\]]+)\]", cnome)
                for cod, lst in _parse(page or "", URL).items():
                    per_corso.setdefault(mc.group(1) if mc else cnome, {})[cod] = lst[0].get("titolo") or cod
    if dal is None:
        oggi = date.today()
        dal = f"{oggi.year if oggi.month >= 9 else oggi.year - 1}-09-01"
    giorno, fine, tot = date.fromisoformat(dal), date.today() - timedelta(days=1), 0
    while giorno <= fine:
        for fac, _ in facs:
            page = sess.post({**base, "FAC_ID": fac, "DATA_ESA": giorno.strftime("%d/%m/%Y"),
                              "actionBar1": "Cerca"}, log)
            tot += _aggiungi(appelli, _parse(page or "", URL))
        giorno += timedelta(days=1)
    log(f"[unibg] esse3: appelli già svolti dal {dal}: {tot} date; totale {len(appelli)} attività, "
        f"{sum(len(v) for v in appelli.values())} date")
    return (appelli, per_corso) if con_corsi else appelli
