"""Semestre degli insegnamenti dal Course Catalogue Cineca (UniPi, UniFI): piani di studio delle coorti.

Il piano di una coorte (`GET /api/v1/corso/<coorte>/<cod>`) riporta il periodo didattico di ogni attività
o nei campi `periodo_didattico_it` / `data_inizio_periodo_didattico` / `data_fine_periodo_didattico`
oppure, quando l'insegnamento è diviso in frazioni, nell'elenco `frazioni` (uno per frazione, con testo e
date). `cineca_catalogue.fetch_ateneo` legge solo i campi di primo livello: qui si leggono anche le
frazioni, e per gli insegnamenti non ancora erogati nella coorte della scheda (a.a. futuro, «offerta B»
senza periodo) si usa la scheda dello STESSO insegnamento (stesso corso di studio, stesso codice di
attività, stesso percorso) di un'altra coorte/anno accademico, citandola come fonte.
Il periodo non si deduce mai: se nessuna scheda lo riporta, resta vuoto.

L'indice dei piani si può salvare (`cache_indice`) per non rifare le richieste; i piani già scaricati
dagli altri adattatori sono nella cache UN_HTTP_CACHE.
"""
from __future__ import annotations

import json
import pathlib
import re
from collections import defaultdict


import pulizia
from . import periodi
from .cineca_catalogue import _chiave_cds, _walk_cds

_DATA = re.compile(r"\d{2}/\d{2}/\d{4}$")


def _g(s: str) -> tuple:
    d, m, a = s.split("/")
    return int(a), int(m), int(d)


def _voci(parti: list[dict]) -> list[tuple[str, str, str]]:
    out = []
    for x in parti:
        t = (x.get("periodo_didattico_it") or "").strip()
        a, b = (x.get("data_inizio_periodo_didattico") or "").strip(), (x.get("data_fine_periodo_didattico") or "").strip()
        if t.lower() in ("undefined", "non definito", "-", "--"):
            t = ""
        if t or (_DATA.match(a) and _DATA.match(b)):
            out.append((t, a if _DATA.match(a) else "", b if _DATA.match(b) else ""))
    return out


def _periodi_attivita(att: dict) -> list[tuple[str, str, str]]:
    """[(testo, inizio, fine)] dal primo livello e dalle frazioni dell'attività; solo se mancano, dai moduli
    del syllabus (corso integrato: il periodo sta nei moduli)."""
    out = _voci([att] + list(att.get("frazioni") or []))
    if not out:
        for mod in att.get("moduli") or []:
            if isinstance(mod, dict):
                out += _voci([mod] + list(mod.get("frazioni") or []))
    return out


def riassumi(ps: list[tuple[str, str, str]]) -> dict | None:
    """Un periodo solo: le date (le più ampie, se le frazioni sono più d'una) oppure il testo se è uno solo."""
    date = [(a, b) for _, a, b in ps if a and b]
    if date:
        a = min((x[0] for x in date), key=_g)
        b = max((x[1] for x in date), key=_g)
        testi = {t for t, _, _ in ps if t}
        return {"periodo_inizio": a, "periodo_fine": b, "periodo": testi.pop() if len(testi) == 1 else None}
    testi = {t for t, _, _ in ps if t}
    if len(testi) == 1:
        return {"periodo": testi.pop()}
    return None


def indice_piani(client, anni: range, log=print, cache_indice: pathlib.Path | None = None) -> list[dict]:
    """Tutte le attività dei piani delle coorti `anni`, con i periodi trovati."""
    if cache_indice and cache_indice.exists():
        return json.loads(cache_indice.read_text(encoding="utf-8"))
    out: list[dict] = []
    for y in anni:
        cds: list[dict] = []
        _walk_cds(client.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        cds = [x for x in cds if str(x.get("aa")) == str(y)]
        log(f"[periodi] coorte {y}: {len(cds)} corsi")
        for x in cds:
            d = client.get(f"/corso/{y}/{x['cod']}")
            if isinstance(d, list):
                d = d[0] if d else None
            if not d:
                continue
            chiave = list(_chiave_cds(x))
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
                    for g in gruppi:
                        for att in g.get("attivita") or []:
                            out.append({"y": y, "cds": x["cdsCod"], "chiave": chiave, "ad": att.get("adCod") or att.get("cod"),
                                        "cod": att.get("cod"), "aa": str(att.get("aa")), "ord": att.get("ordinamento_aa"),
                                        "perc": att.get("corso_percorso_id"), "perc_cod": att.get("corso_percorso_cod"),
                                        "corso_cod": att.get("corso_cod"), "schema": att.get("schemaId"),
                                        "periodi": _periodi_attivita(att)})
    if cache_indice:
        cache_indice.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    return out


def _url(base: str, e: dict) -> str:
    return f"{base.rstrip('/')}/insegnamenti/{e['aa']}/{e['cod']}/{e['ord']}/{e['perc']}?coorte={e['y']}"


def fetch_periodi(uid: str, client, base: str, anno: int = 2026, log=print, cache_indice=None) -> dict[str, dict]:
    """Periodo degli insegnamenti senza semestre di database/corsi/<uid>.json."""
    idx = indice_piani(client, range(anno - 5, anno + 1), log, cache_indice)
    per_cod = {(e["y"], e["cod"]): e for e in idx}
    per_cds_ad: dict = defaultdict(list)
    per_corso_ad: dict = defaultdict(list)
    per_cod_aa = {(e["cod"], e["aa"]): e for e in idx}  # scheda ereditata dal piano di un'altra coorte (nuovo ordinamento)
    per_ad: dict = defaultdict(list)
    for e in idx:
        if e["periodi"]:
            per_cds_ad[(e["cds"], e["ad"])].append(e)
            per_ad[e["ad"]].append(e)
            per_corso_ad[(e["chiave"][0], e["chiave"][2], e["ad"])].append(e)
    ris: dict[str, dict] = {}
    stat = defaultdict(int)
    manc = periodi.mancanti(uid)
    for m in manc:
        mm = re.search(r"/insegnamenti/(\d{4})/([^/]+)/(\d+)/(\d+)\?coorte=(\d{4})", m.get("url") or "")
        if not mm:
            stat["senza_url"] += 1
            continue
        y, cod = int(mm.group(5)), mm.group(2)
        proprio = per_cod.get((y, cod)) or per_cod_aa.get((cod, mm.group(1)))
        scelto, via = None, None
        if not proprio:
            stat["scheda_non_nel_piano"] += 1
            continue
        if proprio["periodi"]:
            scelto, via = proprio, "propria scheda"
        else:
            # il syllabus (stessa scheda) a volte riporta il periodo anche quando il piano no
            sy = client.get("/insegnamento", {k: v for k, v in {
                "anno": proprio["aa"], "insegnamento": proprio["cod"], "ordinamento_aa": proprio["ord"],
                "af_percorso": proprio["perc"], "corso_cod": proprio.get("corso_cod"), "corso_aa": proprio["y"],
                "schema_id": proprio.get("schema")}.items() if v not in (None, "")}) if proprio.get("corso_cod") else None
            ps = _periodi_attivita(sy) if isinstance(sy, dict) else []
            if ps:
                scelto, via = {**proprio, "periodi": ps}, "syllabus"
        if not scelto:
            cand = [e for e in per_cds_ad.get((proprio["cds"], proprio["ad"]), []) if e["perc_cod"] == proprio["perc_cod"]]
            via = "altra coorte"
            if not cand:  # stesso corso con un altro codice di corso di studio (nuovo ordinamento)
                cand = [e for e in per_corso_ad.get((proprio["chiave"][0], proprio["chiave"][2], proprio["ad"]), [])
                        if e["perc_cod"] == proprio["perc_cod"]]
                via = "altra coorte (altro codice corso)"
            if cand:
                cand.sort(key=lambda e: (e["y"], e["aa"]), reverse=True)
                scelto = cand[0]
        if not scelto and per_ad.get(proprio["ad"]):
            # lo stesso codice di attività in altri corsi di studio, solo se tutte le schede dell'ultimo
            # a.a. che lo riporta dicono lo stesso periodo
            es = per_ad[proprio["ad"]]
            ultimo = max(e["aa"] for e in es)
            es = [e for e in es if e["aa"] == ultimo]
            rs = {json.dumps(riassumi([tuple(p) for p in e["periodi"]]), sort_keys=True) for e in es}
            sems = {pulizia.periodo(r.get("periodo"), r.get("periodo_inizio"), r.get("periodo_fine"))
                    for r in (json.loads(x) for x in rs if x != "null")}
            if len(sems) == 1 and None not in sems:
                scelto, via = es[0], "stesso codice attività in altri corsi"
        if not scelto:
            stat["nessun_periodo"] += 1
            continue
        r = riassumi([tuple(p) for p in scelto["periodi"]])
        if not r:
            stat["periodo_non_interpretabile"] += 1
            continue
        r["fonte"] = _url(base, scelto)
        ris[m["id"]] = r
        stat[via] += 1
    log(f"[{uid}] periodi: {len(ris)} su {len(manc)}; {dict(stat)}")
    return ris
