"""Appelli d'esame dell'Università di Verona dalla bacheca pubblica di Esse3, un corso di studio alla volta.

`univr.esse3.cineca.it/Guide/PaginaListaAppelli.do` non ha il menu dei dipartimenti: si sceglie il
corso di studio (`CDS_ID`, «[S24R] INFORMATICA») e si leggono gli appelli già pubblicati. I codici
dell'attività didattica di Esse3 non sempre coincidono con quelli del portale dei corsi
(www.corsi.univr.it) e il portale divide gli ordinamenti in «R» (nuovo) e senza «R»: per questo
l'appello si assegna all'insegnamento del corso che ha lo stesso codice oppure lo stesso nome
(senza «[Matricole pari/dispari]» né maiuscole/accenti), e si scrive con il codice dell'insegnamento.

La bacheca ha solo gli appelli già aperti dall'ateneo: a ottobre sono pochi (gli altri compaiono
mano a mano). Il calendario degli esami di EasyTest (logistica.univr.it) non ha ancora il 2026/27.
"""
from __future__ import annotations

import html
import re
import time
import unicodedata

import requests

from .esse3_appelli import HEADERS, _parse

URL = "https://univr.esse3.cineca.it/Guide/PaginaListaAppelli.do"


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\[[^\]]*\]|\(abilitante.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _codice_cs(url: str | None) -> str | None:
    m = re.search(r"codiceCs=([^&]+)", url or "")
    return m.group(1) if m else None


def lista_cds(s: requests.Session) -> list[tuple[str, str, str]]:
    """[(CDS_ID, codice 'S24R', nome 'INFORMATICA')]"""
    r = s.get(URL, headers=HEADERS, timeout=60)
    sel = re.search(r'<select[^>]*name="CDS_ID".*?</select>', r.text, re.S)
    out = []
    for v, n in re.findall(r'<option value="([^"]*)"[^>]*>(.*?)</option>', sel.group(0) if sel else "", re.S):
        m = re.match(r"\s*\[([^\]]+)\]\s*(.*)", html.unescape(n))
        if v and v not in ("X", "-1") and m:
            out.append((v, m.group(1).strip(), m.group(2).strip()))
    return out


def raccogli(log=print, delay: float = 0.6) -> dict[str, dict]:
    """{codice corso di studio: {'nome', 'appelli': {codice attività: [esami]}}}"""
    s = requests.Session()
    cds = lista_cds(s)
    out = {}
    for v, cod, nome in cds:
        time.sleep(delay)
        data = {"CDS_ID": v, "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "", "form_id_form1": "form1",
                "actionBar1": "Cerca"}
        r = None
        for tentativo in range(2):
            try:
                r = s.post(URL, data=data, headers=HEADERS, timeout=300)
                break
            except requests.RequestException as e:
                log(f"[univr] esse3 {cod} (tentativo {tentativo + 1}): {e!r}")
        if r is None:
            continue
        out[cod] = {"nome": nome, "appelli": _parse(r.text, URL)}
    log(f"[univr] esse3: {len(cds)} corsi di studio, "
        f"{sum(len(x['appelli']) for x in out.values())} attività con appelli")
    return out


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    raccolti = raccogli(log=log)
    # corsi del contributo per codice di corso di studio (dai link degli insegnamenti) e per nome
    per_cs: dict[str, list[dict]] = {}
    per_nome: dict[str, list[dict]] = {}
    for c in corsi:
        for cs in {_codice_cs(i.get("url")) for i in c.get("insegnamenti") or []} - {None}:
            per_cs.setdefault(cs, []).append(c)
        per_nome.setdefault(_norm(c.get("nome") or ""), []).append(c)
    out: dict[str, list[dict]] = {}
    non_assegnati = 0
    for cs, x in raccolti.items():
        cand = per_cs.get(cs) or per_cs.get(cs + "R") or per_cs.get(cs.rstrip("R")) or per_nome.get(_norm(x["nome"])) or []
        for cod, lst in x["appelli"].items():
            titolo = _norm(lst[0].get("titolo") or "")
            target = {i.get("codice") for c in cand for i in c.get("insegnamenti") or [] if i.get("codice") == cod}
            if not target and titolo:
                target = {i.get("codice") for c in cand for i in c.get("insegnamenti") or []
                          if i.get("codice") and _norm(i.get("nome") or "") == titolo}
            if not target:
                non_assegnati += 1
                target = {cod}
            for t in target:
                cur = out.setdefault(t, [])
                for e in lst:
                    if not any((y["data"], y["ora"], y["tipo"]) == (e["data"], e["ora"], e["tipo"]) for y in cur):
                        cur.append(dict(e))
    for v in out.values():
        v.sort(key=lambda e: (e["data"], e["ora"] or ""))
    log(f"[{uid}] appelli: {len(out)} attività, {sum(len(v) for v in out.values())} date "
        f"({non_assegnati} attività senza corrispondenza nel piano)")
    return out
