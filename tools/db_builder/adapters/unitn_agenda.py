"""Calendario esami pubblico dell'Agenda Web di UniTN (EasyTest, easyacademy.unitn.it/AgendaStudentiUnitn).

Alternativa alla bacheca Esse3 (dietro verifica Cloudflare dal 17/10/2026). La pagina «Calendario esami → Per
corso di studio» è pubblica, senza login: `combo.php?sw=et_&page=corsi` elenca a.a. → corso di studio → anno di
corso/percorso → sessioni; `test_call.php` (POST con gli stessi campi del modulo) restituisce per ogni
sessione gli insegnamenti con codice generale (`CodiceGenerale`, il codice Esse3 senza prefisso), nome e
appelli (data, ora, tipo di prova, docente). Si leggono gli a.a. dal precedente al corrente e solo le date
da oggi in poi. Non si salvano email né altri recapiti, solo i nomi dei docenti. Al massimo 1 richiesta al secondo.
"""
from __future__ import annotations

import json
import re
import time
from datetime import date

import requests

BASE = "https://easyacademy.unitn.it/AgendaStudentiUnitn"
PAGINA = BASE + "/index.php?view=easytest&include=et_cdl&_lang=it"
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}


def _combo(s: requests.Session) -> list[dict]:
    t = s.get(BASE + "/combo.php?sw=et_&page=corsi", timeout=60).text
    return json.loads(t[t.index("["):t.index("}];") + 2])


def _appelli(j: dict, oggi: str) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    ins = j.get("Insegnamenti") or []
    for v in (ins.values() if isinstance(ins, dict) else ins):
        di = v.get("DatiInsegnamento") or {}
        cod = (di.get("CodiceGenerale") or "").strip()
        if not cod:
            continue
        dd = v.get("DatiDocente") or {}
        for a in v.get("Appelli") or []:
            m = re.match(r"(\d{2})-(\d{2})-(\d{4})", a.get("Data") or "")
            if not m or str(a.get("Annullato") or "0") != "0" or a.get("Tipo") not in (None, "", "Esame"):
                continue
            data = f"{m.group(3)}-{m.group(2)}-{m.group(1)}"
            if data < oggi:
                continue
            aula = (a.get("Aula") or "").strip()
            mod = "scritto" if "scritt" in aula.lower() else "orale" if "oral" in aula.lower() else None
            docente = (a.get("docente") or " ".join(x for x in (dd.get("Cognome"), dd.get("Nome")) if x)).strip() or None
            ora = (a.get("OraInizio") or "").strip()
            out.setdefault(cod, []).append({
                "tipo": "appello", "titolo": (di.get("Nome") or "").strip() or None, "data": data,
                "ora": ora if re.fullmatch(r"\d{1,2}:\d{2}", ora) else None,
                "luogo": None if not aula or mod else aula, "modalita": mod,
                "iscrizioni_dal": None, "iscrizioni_al": None, "docenti": docente,
                "note": (a.get("Notes") or "").strip() or None, "fonte": PAGINA})
    return out


def fetch_appelli(uid: str = "unitn", corsi=None, log=print, delay: float = 1.0) -> dict[str, list[dict]]:
    """{codice insegnamento: [esame, …]} dall'Agenda Web per l'a.a. corrente e il precedente."""
    oggi = date.today().isoformat()
    aa = date.today().year if date.today().month >= 9 else date.today().year - 1
    s = requests.Session()
    s.headers.update(HEADERS)
    s.get(PAGINA, timeout=60)
    out: dict[str, list[dict]] = {}
    n = 0
    for a in _combo(s):
        if int(a["valore"]) not in (aa, aa - 1):
            continue
        for c in a.get("elenco") or []:
            for an in c.get("elenco_anni") or []:
                for se in an.get("elenco_sessioni") or []:
                    dati = {"view": "easytest", "form-type": "et_cdl", "include": "et_cdl", "anno": a["valore"],
                            "cdl": c["valore"], "annocdl": an["valore"], "sessione": se["valore"], "_lang": "it",
                            "list": "", "week_grid_type": "-1", "ar_codes_": "", "ar_select_": "", "col_cells": "0",
                            "empty_box": "0", "only_grid": "0", "highlighted_date": "0", "all_events": "1"}
                    j = None
                    for tentativo in range(3):
                        time.sleep(delay)
                        n += 1
                        try:
                            r = s.post(BASE + "/test_call.php", data=dati, timeout=90)
                            r.raise_for_status()
                            j = r.json()
                            break
                        except (requests.RequestException, ValueError):
                            time.sleep(5 * (tentativo + 1))
                    if not isinstance(j, dict):
                        continue
                    for cod, lst in _appelli(j, oggi).items():
                        cur = out.setdefault(cod, [])
                        for e in lst:
                            if not any((x["data"], x["ora"]) == (e["data"], e["ora"]) for x in cur):
                                cur.append(e)
                    if n % 100 == 0:
                        log(f"[{uid}] agenda: {n} richieste, {len(out)} insegnamenti con appelli")
    for lst in out.values():
        lst.sort(key=lambda e: (e["data"], e["ora"] or ""))
    log(f"[{uid}] agenda web: {n} richieste, {len(out)} insegnamenti, {sum(len(v) for v in out.values())} date")
    return out
