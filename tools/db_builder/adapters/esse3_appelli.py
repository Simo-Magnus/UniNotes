"""Date d'esame dalla bacheca appelli pubblica di Esse3 (Cineca).

`https://<ateneo>.esse3.cineca.it/Guide/PaginaListaAppelli.do`: si sceglie un
dipartimento/facoltà (obbligatorio) e la pagina elenca tutti gli appelli
pubblicati, con il codice dell'attività didattica ("[ADCOD] NOME"), il periodo
di iscrizione, data e ora dei turni, modalità, tipo di prova e docenti.
"""
from __future__ import annotations

import html
import re
import time

import requests

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
DATA_ORA = re.compile(r"(\d{2})/(\d{2})/(\d{4})(?:\s*-\s*(\d{1,2}):(\d{2}))?")


def _cells(row: str) -> list[str]:
    return [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", c))).strip()
            for c in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", row, re.S)]


def _parse(page: str, fonte: str) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for table in re.findall(r"<table.*?</table>", page, re.S):
        rows = re.findall(r"<tr.*?</tr>", table, re.S)
        if not rows:
            continue
        head = [h.lower() for h in _cells(rows[0])]
        if not any("attivit" in h for h in head) or not any("data" in h for h in head):
            continue
        col = {name: next((i for i, h in enumerate(head) if key in h), None) for name, key in
               [("ad", "attivit"), ("iscr", "iscrizion"), ("data", "data"), ("tipo", "tipo"),
                ("prova", "tipo prova"), ("doc", "docent")]}
        if col["prova"] == col["tipo"]:
            col["tipo"] = next((i for i, h in enumerate(head) if h == "tipo"), col["tipo"])
        for r in rows[1:]:
            c = _cells(r)
            if not c or col["ad"] is None or col["ad"] >= len(c) or not c[col["ad"]]:
                continue
            m = re.match(r"\[([^\]]+)\]\s*(.*)", c[col["ad"]])
            if not m:
                continue
            cod, nome = m.group(1).strip(), m.group(2).strip()
            prova = (c[col["prova"]] if col["prova"] is not None and col["prova"] < len(c) else "").lower()
            tipo = "prova_in_itinere" if re.search(r"parzial|itinere|intermedi|esonero", prova) else "appello"
            iscr = DATA_ORA.findall(c[col["iscr"]]) if col["iscr"] is not None and col["iscr"] < len(c) else []
            for d in DATA_ORA.findall(c[col["data"]] if col["data"] < len(c) else ""):
                out.setdefault(cod, []).append({
                    "tipo": tipo, "titolo": nome or None,
                    "data": f"{d[2]}-{d[1]}-{d[0]}", "ora": f"{int(d[3]):02d}:{d[4]}" if d[3] else None,
                    "luogo": None,
                    "modalita": (c[col["tipo"]].split("/")[0].strip().lower() or None)
                    if col["tipo"] is not None and col["tipo"] < len(c) else None,
                    "iscrizioni_dal": f"{iscr[0][2]}-{iscr[0][1]}-{iscr[0][0]}" if len(iscr) >= 1 else None,
                    "iscrizioni_al": f"{iscr[1][2]}-{iscr[1][1]}-{iscr[1][0]}" if len(iscr) >= 2 else None,
                    "docenti": c[col["doc"]] if col["doc"] is not None and col["doc"] < len(c) else None,
                    "note": None, "fonte": fonte,
                })
    return out


def fetch_appelli(uid: str, base: str, log=print, delay: float = 0.5) -> dict[str, list[dict]]:
    url = base.rstrip("/") + "/Guide/PaginaListaAppelli.do"
    s = requests.Session()
    r = s.get(url, headers=HEADERS, timeout=60)
    if r.status_code != 200:
        log(f"[{uid}] esse3: HTTP {r.status_code}")
        return {}
    sel = re.search(r'<select[^>]*name="FAC_ID".*?</select>', r.text, re.S)
    facs = re.findall(r'<option value="([^"]+)"', sel.group(0)) if sel else []
    facs = [f for f in facs if f and f not in ("X", "-1")]
    campo = "FAC_ID"
    if not facs:
        # atenei senza il menu delle strutture (es. UniVR): si cerca corso per corso
        sel = re.search(r'<select[^>]*name="CDS_ID".*?</select>', r.text, re.S)
        facs = [f for f in (re.findall(r'<option value="([^"]+)"', sel.group(0)) if sel else [])
                if f and f not in ("X", "-1")]
        campo = "CDS_ID"
    appelli: dict[str, list[dict]] = {}
    for fac in facs:
        data = {"FAC_ID": fac, "CDS_ID": "X", "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "",
                "form_id_form1": "form1", "actionBar1": "Cerca"}
        if campo == "CDS_ID":
            data.pop("FAC_ID")
            data["CDS_ID"] = fac
        r2 = None
        for attempt in range(2):  # le strutture grandi possono metterci minuti
            try:
                r2 = s.post(url, data=data, headers=HEADERS, timeout=300)
                break
            except requests.RequestException as e:
                log(f"[{uid}] esse3 {fac} (tentativo {attempt + 1}): {e!r}")
        if r2 is None:
            continue
        for cod, lst in _parse(r2.text, url).items():
            seen = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(cod, [])}
            appelli.setdefault(cod, []).extend(x for x in lst if (x["data"], x["ora"], x["tipo"]) not in seen)
        time.sleep(delay)
    log(f"[{uid}] esse3: {len(facs)} {'strutture' if campo == 'FAC_ID' else 'corsi'}, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli
