"""Appelli d'esame di UniPV (Università di Pavia) dalla bacheca pubblica di Esse3, un corso di studio alla volta.

La ricerca per struttura (Scuola) restituisce pagine enormi che il server non riesce più a
servire (timeout dopo i primi appelli pubblicati): si sceglie la struttura, poi ogni corso di
studio del suo elenco (il menu si aggiorna con `refresh=FAC_ID`). Oltre agli appelli per
codice dell'attività, `per_corso` dice quali codici compaiono in quale corso (nome del corso
dell'elenco Esse3), per abbinare gli insegnamenti il cui codice nel catalogo è diverso.
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

BASE = "https://unipv.esse3.cineca.it"
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
        self.dir = pathlib.Path(d) / "unipv_esse3" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def post(self, data: dict, log) -> str | None:
        # senza data la bacheca elenca gli appelli da oggi in poi: la cache vale per un giorno
        chiave = {**data, "_oggi": date.today().isoformat()} if data.get("DATA_ESA", "") == "" else data
        key = hashlib.sha1(json.dumps(chiave, sort_keys=True).encode()).hexdigest()
        f = self.dir / f"{key}.html" if self.dir else None
        if f and f.exists():
            return f.read_text(encoding="utf-8")
        for attempt in range(3):
            try:
                time.sleep(self.delay)
                r = self.s.post(URL, data=data, headers=HEADERS, timeout=180)
                r.raise_for_status()
                if f:
                    f.write_text(r.text, encoding="utf-8")
                return r.text
            except requests.RequestException as e:
                log(f"[unipv] esse3 {data.get('FAC_ID')}/{data.get('CDS_ID')} (tentativo {attempt + 1}): {e!r}")
                time.sleep(5 * (attempt + 1))
        return None


def fetch_appelli(uid: str = "unipv", corsi=None, log=print, delay: float = 1.0, con_corsi: bool = False,
                  dal: str | None = None):
    sess = _Sess(delay)
    r = sess.s.get(URL, headers=HEADERS, timeout=60)
    facs = _opzioni(r.text, "FAC_ID")
    appelli: dict[str, list[dict]] = {}
    per_corso: dict[str, set[str]] = {}
    base = {"CDS_ID": "X", "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "", "form_id_form1": "form1"}
    for fac, fnome in facs:
        pag = sess.post({**base, "FAC_ID": fac, "refresh": "FAC_ID"}, log)
        cds = _opzioni(pag or "", "CDS_ID")
        n0 = len(appelli)
        for cid, cnome in cds:
            page = sess.post({**base, "FAC_ID": fac, "CDS_ID": cid, "actionBar1": "Cerca"}, log)
            if page is None:
                log(f"[unipv] esse3 corso {cnome}: non raggiunto")
                continue
            trovati = _parse(page, URL)
            mc = re.match(r"^\[([^\]]+)\]", cnome)
            per_corso.setdefault(mc.group(1) if mc else cnome, set()).update(trovati)
            for cod, lst in trovati.items():
                viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(cod, [])}
                appelli.setdefault(cod, []).extend(x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste)
        log(f"[unipv] esse3 {fnome}: {len(cds)} corsi, totale {len(appelli)} attività con appelli (+{len(appelli) - n0})")
    if dal:
        # la bacheca elenca solo gli appelli da oggi in poi; con una data cerca quelli di quel giorno:
        # si ripercorrono i giorni dall'inizio dell'a.a. (1° settembre) a ieri, una struttura alla volta
        giorno, fine, n0 = date.fromisoformat(dal), date.today() - timedelta(days=1), len(appelli)
        n_date = 0
        while giorno <= fine:
            for fac, fnome in facs:
                page = sess.post({**base, "FAC_ID": fac, "DATA_ESA": giorno.strftime("%d/%m/%Y"),
                                  "actionBar1": "Cerca"}, log)
                for cod, lst in _parse(page or "", URL).items():
                    viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(cod, [])}
                    nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
                    appelli.setdefault(cod, []).extend(nuovi)
                    n_date += len(nuovi)
            giorno += timedelta(days=1)
        log(f"[unipv] esse3: appelli già svolti dal {dal}: {n_date} date, {len(appelli) - n0} attività in più")
    return (appelli, per_corso) if con_corsi else appelli
