"""Calendario esami pubblico dell'Agenda Web di UniMiB (EasyTest, gestioneorari.didattica.unimib.it).

Il portale «Calendario esami» è pubblico (nessun login): per ogni corso di studio (codice
come in Esse3) e anno di corso restituisce gli appelli pubblicati con data, ora, aula e sede,
tipo di prova e codice dell'attività didattica (`CodiceGenerale`, lo stesso di Esse3). Si
leggono solo gli appelli dell'anno accademico corrente (dal 1° ottobre); gli appelli annullati
si scartano. Dei docenti si tengono cognome e nome (nessun recapito).
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import time

import requests

BASE = "https://gestioneorari.didattica.unimib.it/PortaleStudentiUnimib"
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
PAGINA = BASE + "/index.php?view=easytest&_lang=it&include=et_cdl"


def _iso(d: str) -> str:
    g, m, a = d.split("-")
    return f"{a}-{m}-{g}"


class _Sess:
    def __init__(self, delay: float):
        self.s = requests.Session()
        self.s.headers.update(HEADERS)
        self.delay = delay
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unimib_agenda" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def _cached(self, chiave: str, fn):
        key = hashlib.sha1((chiave + time.strftime("%Y-%m-%d")).encode()).hexdigest()
        f = self.dir / f"{key}.txt" if self.dir else None
        if f and f.exists():
            return f.read_text(encoding="utf-8")
        for attempt in range(3):
            try:
                time.sleep(self.delay)
                t = fn()
                if f:
                    f.write_text(t, encoding="utf-8")
                return t
            except requests.RequestException:
                time.sleep(5 * (attempt + 1))
        return None

    def combo(self) -> dict:
        self.s.get(PAGINA, timeout=60)
        t = self._cached("combo", lambda: self.s.get(BASE + "/combo.php?sw=et_&page=corsi", timeout=60).text)
        return json.loads(t[t.index("{"):t.index("};") + 1]) if t and "};" in t else {}

    def appelli(self, cds: str, info: dict, dal: str, al: str) -> dict | None:
        dati = {"view": "easytest", "form-type": "et_cdl", "include": "et_cdl", "anno2": "", "et_er": "1",
                "scuola": info.get("scuola") or "", "esami_cdl": cds, "datefrom": dal, "dateto": al, "_lang": "it",
                "list": "", "week_grid_type": "-1", "ar_codes_": "", "ar_select_": "", "col_cells": "0",
                "empty_box": "0", "only_grid": "0", "highlighted_date": "0", "all_events": "1"}
        lista = [(k, v) for k, v in dati.items()] + [("anno2[]", a) for a in (info.get("elenco_anni") or {})]
        t = self._cached("cds|" + json.dumps(lista), lambda: self.s.post(BASE + "/test_call.php", data=lista, timeout=120).text)
        try:
            return json.loads(t) if t else None
        except ValueError:
            return None


def fetch_agenda(anno: int, log=print, delay: float = 1.0) -> list[dict]:
    """[{codice, nome, appelli: {codice_attività: [appello…]}}] per ogni corso dell'Agenda Web."""
    sess = _Sess(delay)
    combo = sess.combo()
    inizio = f"{anno}-10-01"
    dal, al = f"01-{9:02d}-{anno}", f"30-09-{anno + 1}"
    out = []
    for cds, info in combo.items():
        d = sess.appelli(cds, info, dal, al)
        if not d:
            log(f"[unimib] agenda {cds}: non raggiunto")
            continue
        appelli: dict[str, list[dict]] = {}
        for ins in (d.get("Insegnamenti") or {}).values():
            cod = (ins.get("DatiInsegnamento") or {}).get("CodiceGenerale")
            for a in ins.get("Appelli") or []:
                if not cod or a.get("Tipo") != "Esame" or a.get("event_Annullato") == "1" or not a.get("Data"):
                    continue
                data = _iso(a["Data"])
                if data < inizio:
                    continue
                docenti = " ".join(f"{x.get('Cognome', '')} {x.get('Nome', '')}".strip()
                                   for x in a.get("event_docenti") or []) or None
                prova = (a.get("TipoEsame") or "").lower().replace("esame ", "").strip() or None
                appelli.setdefault(cod, []).append({
                    "tipo": "appello", "titolo": ins["DatiInsegnamento"].get("Nome"),
                    "data": data, "ora": a.get("OraInizio") or None,
                    "luogo": (a.get("aula_sede") or a.get("Aula") or "").strip() or None,
                    "modalita": prova, "iscrizioni_dal": None, "iscrizioni_al": None, "docenti": docenti,
                    "note": None, "fonte": PAGINA})
        out.append({"codice": cds, "nome": re.sub(r"\s*\([^)]*\)\s*$", "", info.get("label") or ""), "appelli": appelli})
    log(f"[unimib] agenda: {len(out)} corsi, {sum(len(v) for c in out for v in c['appelli'].values())} appelli")
    return out
