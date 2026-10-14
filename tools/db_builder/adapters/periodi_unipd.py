"""Semestre degli insegnamenti dell'Università di Padova dal Course Catalogue Cineca (unipd.coursecatalogue.cineca.it).

Il piano di studi di una coorte (`/api/v1/corso/<anno>/<cod>`) e il syllabus dell'insegnamento (`/api/v1/insegnamento`)
riportano `periodo_didattico_it` («Primo Semestre», «Secondo Semestre», «Ciclo Annuale», «… Trimestre») e le date
del periodo. Per gli insegnamenti rimasti senza periodo si cerca, nell'ordine:

1. il piano della stessa coorte della scheda (a volte vuoto) e il syllabus della scheda;
2. lo stesso insegnamento (stesso corso di studio, stesso codice di attività) nel piano di un'altra coorte o di un
   altro anno accademico: si prende quello più vicino all'a.a. 2026/27; se i più vicini si contraddicono, niente.
   Per queste pagine d'altra coorte si passa il solo testo (non le date, che sono di un altro anno) e solo se è
   un semestre o un ciclo annuale: un trimestre senza date l'app non lo sa interpretare.

Il periodo di un insegnamento con lo stesso codice in un altro corso di studio NON si usa: ogni corso fissa il suo.
Con UN_HTTP_CACHE le risposte restano su disco (stessa cache di adapters/unipd.py).
"""
from __future__ import annotations

import re

from . import cineca_catalogue, periodi, unipd

BASE = unipd.BASE
ANNO = 2026
VALIDO_ALTRA_COORTE = re.compile(r"(?i)^(primo|secondo) semestre$|^ciclo annuale$")


def _att(x, acc):
    if isinstance(x, dict):
        if "adCod" in x and "aa" in x and "cod" in x:
            acc.append(x)
        for v in x.values():
            _att(v, acc)
    elif isinstance(x, list):
        for v in x:
            _att(v, acc)


def _url(a: dict, y: int) -> str:
    return f"{BASE}/insegnamenti/{a.get('aa')}/{a.get('cod')}/{a.get('ordinamento_aa')}/{a.get('corso_percorso_id')}?coorte={y}"


def _periodo(o: dict) -> dict | None:
    p = (o.get("periodo_didattico_it") or "").strip()
    ini, fin = o.get("data_inizio_periodo_didattico"), o.get("data_fine_periodo_didattico")
    if not p and not (ini and fin):
        return None
    r = {"periodo": p or None}
    if ini and fin:
        r["periodo_inizio"], r["periodo_fine"] = ini, fin
    return r


def fetch_periodi(uid: str = "unipd", log=print) -> dict[str, dict]:
    c = unipd.ClientCache(BASE, rate=2.0)
    miss = periodi.mancanti(uid)
    cds_di = {x["id"]: x.get("codice_ateneo") for x in periodi.carica(uid)["corsi"]}
    per_cds: dict[str, list[dict]] = {}
    for m in miss:
        if cds_di.get(m["corso"]):
            per_cds.setdefault(cds_di[m["corso"]], []).append(m)
    log(f"[{uid}] {len(miss)} insegnamenti senza semestre in {len(per_cds)} corsi di studio")
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(ANNO - 5, ANNO + 1):
        lst: list[dict] = []
        cineca_catalogue._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], lst)
        coorti[y] = {x["cdsCod"]: x for x in lst if str(x.get("aa")) == str(y)}
    out: dict[str, dict] = {}
    n_syl = n_altra = 0
    for n, (cds, items) in enumerate(per_cds.items(), 1):
        atts: dict[str, list[tuple[int, dict]]] = {}
        for y in range(ANNO, ANNO - 6, -1):
            x = coorti.get(y, {}).get(cds)
            if not x and cds in coorti.get(ANNO, {}):  # codice cambiato con il nuovo ordinamento: per nome, sede e tipo
                chiave = cineca_catalogue._chiave_cds(coorti[ANNO][cds])
                stessi = [v for v in coorti.get(y, {}).values() if cineca_catalogue._chiave_cds(v) == chiave]
                if not stessi:
                    stessi = [v for v in coorti.get(y, {}).values() if cineca_catalogue._chiave_cds(v)[::2] == chiave[::2]]
                x = stessi[0] if len(stessi) == 1 else None
            if not x:
                continue
            d = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(d, list):
                d = d[0] if d else None
            acc: list[dict] = []
            _att((d or {}).get("percorsi"), acc)
            for a in acc:
                atts.setdefault(a.get("adCod"), []).append((y, a))
        for it in items:
            cand = atts.get(it["codice"]) or []
            own = next(((y, a) for y, a in cand if _url(a, y) == it["url"]), None)
            r = None
            if own:
                r = _periodo(own[1])
                if not r:  # il piano non lo dice: syllabus della scheda
                    p = {"anno": own[1].get("aa"), "insegnamento": own[1].get("cod"),
                         "ordinamento_aa": own[1].get("ordinamento_aa"), "af_percorso": own[1].get("corso_percorso_id"),
                         "corso_cod": own[1].get("corso_cod"), "corso_aa": own[0], "schema_id": own[1].get("schemaId")}
                    sy = c.get("/insegnamento", {k: v for k, v in p.items() if v not in (None, "")})
                    r = _periodo(sy) if isinstance(sy, dict) else None
                    n_syl += bool(r)
            if r:
                out[it["id"]] = {**r, "fonte": it["url"]}
                continue
            # stesso insegnamento in un'altra coorte / altro a.a. dello stesso corso di studio
            valide = []
            for y, a in cand:
                p = _periodo(a)
                if p and p.get("periodo") and VALIDO_ALTRA_COORTE.match(p["periodo"]):
                    valide.append((abs(int(a.get("aa")) - ANNO), p["periodo"], _url(a, y)))
            if valide:
                best = min(v[0] for v in valide)
                vicini = [v for v in valide if v[0] == best]
                if len({v[1] for v in vicini}) == 1:
                    out[it["id"]] = {"periodo": vicini[0][1], "fonte": vicini[0][2]}
                    n_altra += 1
        if n % 50 == 0:
            log(f"[{uid}]   corsi {n}/{len(per_cds)}: {len(out)} semestri")
    log(f"[{uid}] semestri trovati: {len(out)} (dal syllabus della scheda: {n_syl}; da un'altra coorte: {n_altra})")
    return out
