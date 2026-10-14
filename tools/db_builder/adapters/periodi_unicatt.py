"""Semestre degli insegnamenti dell'Università Cattolica dall'API pubblica dei campus.

`secure.unicatt.it/didatticaweb2/v2/elenco-insegnamenti` (la stessa API delle pagine «Programmi dei corsi, orari
delle lezioni ed esami di profitto» di ogni campus) dà, per ogni insegnamento di un corso (codice CDL) e a.a., la
descrizione aggiuntiva «(1 sem.)», «(2 sem.)», «(ann.)», «(1 quad.)», «(2 trim.)» (campo
`descrizioneAggiuntivaInsegnamento`). Si usano solo «1 sem.» → "1", «2 sem.» → "2" e «ann.» → "annuale";
quadrimestri e trimestri senza date non si convertono in semestre (non si deduce) e le descrizioni che indicano più
periodi insieme («(1 sem.) (corso annuale)») sono ambigue: restano senza periodo.

Abbinamento all'insegnamento del database (sempre dentro i corsi di studio che hanno il nome del corso, nella sede
giusta): 1) stesso file di programma (`urlFileProgramma`), 2) stesso codice dell'insegnamento, 3) stesso nome; per il
codice si prova, in ultimo, anche fuori dal corso purché tutte le voci siano d'accordo. Fra più a.a. vale il più
recente che dà un valore unico; se nello stesso a.a. i valori sono diversi l'abbinamento è ambiguo e si passa al
criterio seguente (o si lascia vuoto).
"""
from __future__ import annotations

import os
import pathlib
import re

from . import periodi
from .unicatt import (SEDI, Api, _chiave_ins, _classi, _corsi_uguali, _elenco_cdl, _elenco_ins, _nome_corso, _scheletro,
                      _sedi_corso)

PAGINE = {
    "MI": "https://milano.unicatt.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni",
    "BS": "https://brescia.unicatt.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni",
    "RM": "https://roma.unicatt.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni",
    "PC": "https://piacenza.unicatt.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni-piacenza",
    "CR": "https://piacenza.unicatt.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni-cremona",
}
ANNI = (2026, 2025, 2024)


def token(agg: str | None) -> str | None:
    """"1" | "2" | "annuale" dalla descrizione aggiuntiva, None se assente, ambigua o in quadrimestri/trimestri."""
    t = (agg or "").lower()
    toks = set()
    for m in re.finditer(r"\b([12])\s*(?:°\s*)?sem\b", t):
        toks.add(m.group(1))
    if re.search(r"\bann\.|\bannuale\b", t):
        toks.add("annuale")
    return next(iter(toks)) if len(toks) == 1 else None


def _decidi(gruppo: list[dict]) -> str | None | bool:
    """Valore unico del gruppo (a.a. più recente con un valore); False se i valori dello stesso a.a. sono diversi."""
    for aa in ANNI:
        voci = [r for r in gruppo if r["aa"] == aa]
        if not voci:
            continue
        vals = {token(r["agg"]) for r in voci}
        marca = {r["agg"] for r in voci}
        if len(vals - {None}) > 1:
            return False
        if vals - {None}:
            return next(iter(vals - {None}))
    return None


def fetch_periodi(uid: str = "unicatt", log=print) -> dict[str, dict]:
    cache_dir = os.environ.get("UN_HTTP_CACHE")
    api = Api((pathlib.Path(cache_dir) / "unicatt_api") if cache_dir else None, gap=0.7, log=log)
    db = periodi.carica(uid)
    corsi = {c["id"]: c for c in db["corsi"]}
    elenchi = {(s, a): _elenco_cdl(api, s, a) for s in SEDI for a in ANNI}
    log(f"[{uid}] corsi CDL: " + ", ".join(f"{s}{a}={len(v)}" for (s, a), v in elenchi.items()))
    # tutte le voci dell'API: sede, a.a., CDL, codice, nome, descrizione aggiuntiva, programma
    voci: list[dict] = []
    for (s, a), lst in elenchi.items():
        for e in lst:
            for x in _elenco_ins(api, s, a, e):
                ci = x.get("corsoIntegrato") or {}
                voci.append({"sede": s, "aa": a, "cdl": e["codiceCDL"], "cod": x.get("codiceInsegnamento"),
                             "nome": _chiave_ins(x.get("descrizioneInsegnamento")), "agg": x.get("descrizioneAggiuntivaInsegnamento"),
                             "urls": {u for u in (x.get("urlFileProgramma"), ci.get("urlFileProgramma")) if u}})
    log(f"[{uid}] voci dell'API: {len(voci)}; richieste {api.requests}")
    per_url: dict[str, list[dict]] = {}
    per_cod: dict[str, list[dict]] = {}
    per_cdl_cod: dict[tuple, list[dict]] = {}
    per_cdl_nome: dict[tuple, list[dict]] = {}
    for v in voci:
        for u in v["urls"]:
            per_url.setdefault(u, []).append(v)
        if v["cod"]:
            per_cod.setdefault(v["cod"], []).append(v)
            per_cdl_cod.setdefault((v["sede"], v["cdl"], v["cod"]), []).append(v)
        per_cdl_nome.setdefault((v["sede"], v["cdl"], v["nome"]), []).append(v)

    # CDL (sede, codice) che corrispondono a ogni corso del database
    cdl_di: dict[str, set[tuple[str, str]]] = {}
    for cid, corso in corsi.items():
        sedi = _sedi_corso(corso, [])
        if sedi == []:
            sedi = None
        trovati = set()
        for s in sedi or SEDI:
            cand = [(a, e) for a in ANNI for e in elenchi[(s, a)]]
            for a, e in _corsi_uguali(corso, cand):
                trovati.add((s, e["codiceCDL"]))
        cdl_di[cid] = trovati

    out: dict[str, dict] = {}
    stat = {"url": 0, "codice": 0, "nome": 0, "codice_globale": 0, "ambigui": 0, "senza_voce": 0, "voce_senza_semestre": 0}
    for m in periodi.mancanti(uid):
        cdls = cdl_di.get(m["corso"], set())
        livelli = []
        if m["url"]:
            livelli.append(("url", [v for v in per_url.get(m["url"], []) if not cdls or (v["sede"], v["cdl"]) in cdls]))
        if m["codice"]:
            livelli.append(("codice", [v for c in cdls for v in per_cdl_cod.get((c[0], c[1], m["codice"]), [])]))
        livelli.append(("nome", [v for c in cdls for v in per_cdl_nome.get((c[0], c[1], _chiave_ins(m["nome"])), [])]))
        scelto, sede, ambiguo, vista = None, None, False, False
        for nome_liv, gruppo in livelli:
            if not gruppo:
                continue
            vista = True
            d = _decidi(gruppo)
            if d is False:
                ambiguo = True
                continue
            if d:
                scelto, sede = (nome_liv, d), next(v for v in gruppo if token(v["agg"]) == d)["sede"]
                break
        if not scelto and m["codice"] and per_cod.get(m["codice"]):
            vista = True
            vals = {token(v["agg"]) for v in per_cod[m["codice"]]} - {None}
            if len(vals) == 1:
                d = next(iter(vals))
                scelto, sede = ("codice_globale", d), next(v for v in per_cod[m["codice"]] if token(v["agg"]) == d)["sede"]
        if not scelto:
            stat["ambigui" if ambiguo else ("voce_senza_semestre" if vista else "senza_voce")] += 1
            continue
        stat[scelto[0]] += 1
        out[m["id"]] = {"periodo": scelto[1], "fonte": PAGINE[sede]}
    log(f"[{uid}] semestri trovati: {len(out)} su {len(periodi.mancanti(uid))}; {stat}")
    return out
