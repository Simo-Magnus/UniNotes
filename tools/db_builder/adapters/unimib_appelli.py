"""Appelli d'esame di UniMiB dalla bacheca pubblica di Esse3, un corso di studio alla volta.

`https://unimib.esse3.cineca.it/Guide/PaginaListaAppelli.do`: si sceglie il dipartimento
(FAC_ID) e poi ogni corso di studio del suo elenco (CDS_ID, con il codice del corso tra
parentesi quadre: lo stesso che compare nel titolo delle categorie di e-learning). Per ogni
corso si ottengono gli appelli per codice dell'attività didattica; il nome del corso
serve ad abbinarli ai corsi del database.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import pathlib
import re
import time

import requests

from .esse3_appelli import HEADERS, _parse

BASE = "https://unimib.esse3.cineca.it"
URL = BASE + "/Guide/PaginaListaAppelli.do"


def _opzioni(page: str, name: str) -> list[tuple[str, str]]:
    sel = re.search(rf'<select[^>]*name="{name}".*?</select>', page, re.S)
    if not sel:
        return []
    return [(v, html.unescape(re.sub(r"<[^>]+>", "", t)).replace("​", "").replace("\xa0", " ").strip())
            for v, t in re.findall(r'<option value="([^"]*)"[^>]*>(.*?)</option>', sel.group(0), re.S)
            if v not in ("X", "-1", "")]


class _Sess:
    def __init__(self, delay: float):
        self.s = requests.Session()
        self.delay = delay
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unimib_esse3" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self) -> str | None:
        try:
            r = self.s.get(URL, headers=HEADERS, timeout=60)
            r.raise_for_status()
            return r.text
        except requests.RequestException:
            return None

    def post(self, data: dict, log) -> str | None:
        key = hashlib.sha1(json.dumps({**data, "_giorno": time.strftime("%Y-%m-%d")}, sort_keys=True).encode()).hexdigest()
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
                log(f"[unimib] esse3 {data.get('FAC_ID')}/{data.get('CDS_ID')} (tentativo {attempt + 1}): {e!r}")
                time.sleep(5 * (attempt + 1))
        return None


def fetch_appelli_cds(log=print, delay: float = 1.5) -> list[dict]:
    """[{codice, nome, fac, appelli: {codice_attività: [appello…]}}] per ogni corso di studio dell'elenco Esse3."""
    sess = _Sess(delay)
    sess.get()  # cookie di sessione
    pagina = sess.get() or ""
    facs = _opzioni(pagina, "FAC_ID")
    base = {"CDS_ID": "X", "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "", "form_id_form1": "form1"}
    out: list[dict] = []
    for fac, fnome in facs:
        pag = sess.post({**base, "FAC_ID": fac, "refresh": "FAC_ID"}, log)
        for cid, cnome in _opzioni(pag or "", "CDS_ID"):
            page = sess.post({**base, "FAC_ID": fac, "CDS_ID": cid, "actionBar1": "Cerca"}, log)
            if page is None:
                log(f"[unimib] esse3 corso {cnome}: non raggiunto")
                continue
            m = re.match(r"\[([^\]]+)\]\s*(.*)", cnome)
            out.append({"codice": m.group(1) if m else None, "nome": m.group(2) if m else cnome,
                        "fac": fnome, "appelli": _parse(page, URL)})
        log(f"[unimib] esse3 {fnome[:50]}: totale {len(out)} corsi letti")
    return out
