"""Appelli d'esame della Sapienza dal catalogo dei corsi (corsidilaurea.uniroma1.it).

Infostud (iscrizioni) richiede il login, ma `/it/course/<id>/attendance/exams` elenca per ogni
attività ("<codice Esse3> | NOME", lo stesso codice degli insegnamenti in
database/corsi/uniroma1.json) le righe Codice corso | Docente | Data inizio prenotazione |
Data fine prenotazione | Data appello. Si tengono le date future; più docenti (canali) con la
stessa data diventano un appello solo.

La pagina degli appelli di un corso elenca anche attività con codici di ordinamenti o coorti
precedenti (es. 10610046 «Human-robot interaction» per il piano 2026/27 con 10627431). Queste
date si associano all'insegnamento dello STESSO corso con lo STESSO nome solo se il docente
dell'appello è tra i docenti dell'insegnamento e il codice dell'insegnamento non ha appelli
propri; la nota indica l'attività d'origine.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
URL = "https://corsidilaurea.uniroma1.it/it/course/{}/attendance/exams"


def _data(s: str) -> str | None:
    m = re.search(r"(\d{2})/(\d{2})/(\d{4})", s or "")
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else None


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return " ".join(re.findall(r"[a-z0-9]+", s))


def _stesso_docente(docente: str | None, docenti: list[str]) -> bool:
    """«IOCCHI LUCA» e «Luca Iocchi»: tutte le parole dell'appello nel nome di un docente."""
    p = set(_norm(docente).split())
    return bool(p) and any(p <= set(_norm(d).split()) for d in docenti or [])


def leggi_pagina(s: str, fonte: str) -> list[tuple[str, dict]]:
    out = []
    for cod, nome, corpo in re.findall(r'data-exam-title="([^"|]+?)\s*\|\s*([^"]*)"(.*?)</fieldset>', s, re.S):
        for tr in re.findall(r"<tr>(.*?)</tr>", corpo, re.S):
            c = [_testo(x) for x in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
            if len(c) < 5 or not _data(c[4]):
                continue
            out.append((cod.strip(), {
                "tipo": "appello", "titolo": html.unescape(nome).strip() or None, "data": _data(c[4]), "ora": None,
                "luogo": None, "modalita": None, "iscrizioni_dal": _data(c[2]), "iscrizioni_al": _data(c[3]),
                "docenti": c[1] or None, "note": None, "fonte": fonte}))
    return out


def fetch_appelli(uid: str = "uniroma1", corsi: list[dict] | None = None, log=print) -> dict[str, list[dict]]:
    """{codice insegnamento: [esame, …]} con le date future."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    ids = sorted({m.group(1) for x in corsi for u in (x.get("url_catalogo"), x.get("url"))
                  for m in [re.search(r"corsidilaurea\.uniroma1\.it/\w+/(?:course|timeview/\d+)/(\d+)", u or "")] if m})
    oggi = time.strftime("%Y-%m-%d")
    c = Client(rate=3.0)

    def pagina(i: str) -> list[tuple[str, dict]]:
        r = c.get(URL.format(i))
        return leggi_pagina(r.text, URL.format(i)) if r else []

    per_corso: dict[str, list[dict]] = {}
    for x in corsi:
        for k in {m.group(1) for u in (x.get("url_catalogo"), x.get("url"))
                  for m in [re.search(r"corsidilaurea\.uniroma1\.it/\w+/(?:course|timeview/\d+)/(\d+)", u or "")] if m}:
            per_corso.setdefault(k, []).extend(x.get("insegnamenti") or [])

    def unisci(dest: dict[str, dict], e: dict) -> None:
        v = dest.setdefault(e["data"], dict(e))
        if e["docenti"] and e["docenti"] not in (v["docenti"] or "").split(", "):
            v["docenti"] = ", ".join(x for x in (v["docenti"], e["docenti"]) if x)

    res: dict[str, dict[str, dict]] = {}
    estranei: dict[tuple[str, str], list[dict]] = {}  # (corso, codice non nel piano del corso) -> esami
    with cf.ThreadPoolExecutor(3) as ex:
        for i, righe in zip(ids, ex.map(pagina, ids)):
            piano = {x.get("codice") for x in per_corso.get(i, [])}
            for cod, e in righe:
                if e["data"] < oggi:
                    continue
                unisci(res.setdefault(cod, {}), e)
                if cod not in piano:
                    estranei.setdefault((i, cod), []).append(e)
    fin = {k: sorted(v.values(), key=lambda e: e["data"]) for k, v in res.items()}
    # attività di ordinamenti/coorti precedenti: insegnamento omonimo dello stesso corso e docente
    omonimi: dict[str, dict[str, dict]] = {}
    for (i, cod), esami in estranei.items():
        nome = _norm(esami[0]["titolo"])
        cand = [x for x in per_corso.get(i, []) if x.get("codice") and _norm(x.get("nome")) == nome]
        if len({x["codice"] for x in cand}) != 1 or cand[0]["codice"] in fin:
            continue
        docenti = [d for x in cand for d in x.get("docenti") or []]
        nota = f"Appello dell'attività {cod} ({esami[0]['titolo']}) dello stesso corso"
        for e in esami:
            if _stesso_docente(e["docenti"], docenti):
                unisci(omonimi.setdefault(cand[0]["codice"], {}), dict(e, note=nota))
    for k, v in omonimi.items():
        fin[k] = sorted(v.values(), key=lambda e: e["data"])
    log(f"[{uid}] insegnamenti con appelli di un'attività omonima dello stesso corso e docente: {len(omonimi)}")
    log(f"[{uid}] appelli: {len(ids)} corsi, {sum(len(v) for v in fin.values())} date future per {len(fin)} "
        f"insegnamenti; richieste: {c.requests}")
    return fin
