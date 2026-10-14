"""Semestre degli insegnamenti dell'Università di Catania dall'API pubblica GOMP (`public.smartedu.unict.it`).

Il catalogo pubblico («PublicData», la stessa API che usa l'orario delle lezioni dei siti dei dipartimenti) dà per ogni
attività del regolamento le «unità temporali» (`temporalUnits`: anno di corso, unità `utActivity` e durata
`periodLength` in mesi). Con durata di 6 mesi l'unità 1 è il primo semestre e la 2 il secondo; con 12 mesi è annuale.
Si usano questi valori e basta (nessuna deduzione dall'anno di corso o dal nome).

Per ogni corso del database si cercano i corsi GOMP con lo stesso nome (e classe) negli a.a. 2026, 2025 e 2024 e si
abbina l'insegnamento per codice (poi per nome); vale l'a.a. più recente; se i valori sono diversi (per anno di corso,
curriculum o a.a.) l'abbinamento è ambiguo e l'insegnamento resta senza periodo.
"""
from __future__ import annotations

import json
import os
import pathlib
import re

from . import periodi
from .gomp import Api, _ita, _norm

BASE = "https://public.smartedu.unict.it"
ANNI = (2026, 2025, 2024)


def _attivita(g, out: list) -> None:
    """Tutte le attività (anche annidate nei gruppi dei curricula) con le loro unità temporali, senza ripetizioni."""
    if isinstance(g, dict):
        if g.get("type") == "activity" and g.get("code"):
            voce = {"code": g["code"], "name": _ita(g.get("name")),
                    "tu": [{"year": t.get("year"), "utActivity": t.get("utActivity"), "periodLength": t.get("periodLength")}
                           for t in g.get("temporalUnits") or []]}
            if voce not in out:
                out.append(voce)
        for v in g.values():
            if isinstance(v, (dict, list)):
                _attivita(v, out)
    elif isinstance(g, list):
        for v in g:
            _attivita(v, out)


def valore(tu: dict) -> str | None:
    if tu.get("periodLength") == 6 and tu.get("utActivity") in (1, 2):
        return str(tu["utActivity"])
    if tu.get("periodLength") == 12:
        return "annuale"
    return None


def fetch_periodi(uid: str = "unict", log=print) -> dict[str, dict]:
    cache_dir = os.environ.get("UN_HTTP_CACHE")
    cache = (pathlib.Path(cache_dir) / "unict_gomp") if cache_dir else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)
    api = Api(BASE, rate=1.0)

    def cached(nome: str, produci):
        f = cache / nome if cache else None
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = produci()
        if f and r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r

    db = periodi.carica(uid)
    corsi = {c["id"]: c for c in db["corsi"] if not c.get("piano_da")}
    mancanti = periodi.mancanti(uid)
    usati = {m["corso"] for m in mancanti}
    # corsi GOMP per a.a.
    gomp: dict[int, list[dict]] = {}
    for aa in ANNI:
        def lista(aa=aa):
            r = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": aa, "courseTypes": ["CorsoDiStudio"]})
            return [{"uid": c["uid"], "code": c.get("code"), "ita": _ita(c.get("name")), "classes": c.get("classes") or [],
                     "eng": " ".join(t.get("text") or "" for t in c.get("name") or [] if t.get("iso") == "eng")}
                    for s in (r or {}).get("data") or [] for c in s.get("courses") or []] if r else None
        gomp[aa] = cached(f"corsi_{aa}.json", lista) or []
    log(f"[{uid}] corsi GOMP: " + ", ".join(f"{a}={len(g)}" for a, g in gomp.items()))

    def abbina(c: dict, aa: int) -> list[dict]:
        n, ne = _norm(c["nome"]), _norm(c.get("nome_en") or c["nome"])
        cand = [g for g in gomp[aa] if _norm(g["ita"]) == n or _norm(g["eng"]) == ne]
        cl = {x.strip() for x in (c.get("classe") or "").split("/")}
        return [g for g in cand if {re.sub(r"\s+R$", "", x) for x in g["classes"]} & cl] or cand

    attivita: dict[tuple[str, int], list[dict]] = {}  # (id corso database, a.a.) → attività con la fonte
    for cid in sorted(usati):
        for aa in ANNI:
            lst = []
            for g in abbina(corsi[cid], aa):
                def scarica(g=g, aa=aa):
                    r = api.corso(g["uid"], aa)
                    if not r:
                        return None
                    a: list = []
                    _attivita(r, a)
                    return a
                for a in cached(f"corso_{g['uid']}_{aa}.json", scarica) or []:
                    lst.append({**a, "fonte": f"{BASE}/PublicData?uid={g['uid']}&mode=CourseDetail&iso=ita&academicYear={aa}"})
            attivita[(cid, aa)] = lst
        log(f"[{uid}] {cid}: " + ", ".join(f"{aa}={len(attivita[(cid, aa)])}" for aa in ANNI) + f"; richieste {api.requests}")

    out: dict[str, dict] = {}
    stat = {"codice": 0, "nome": 0, "ambigui": 0, "senza_attivita": 0, "senza_semestre": 0}
    for m in mancanti:
        esito, visto, ambiguo = None, False, False
        for criterio in ("codice", "nome"):
            for aa in ANNI:
                if criterio == "codice":
                    voci = [a for a in attivita[(m["corso"], aa)] if m["codice"] and a["code"] == m["codice"]]
                else:
                    voci = [a for a in attivita[(m["corso"], aa)] if _norm(a["name"]) == _norm(m["nome"])]
                if not voci:
                    continue
                visto = True
                coppie = [(valore(t), t.get("year"), a["fonte"]) for a in voci for t in a["tu"]]
                if m["anno"] and any(y == m["anno"] for _, y, _ in coppie):
                    coppie = [x for x in coppie if x[1] == m["anno"]]
                vals = {v for v, _, _ in coppie}
                if len(vals) > 1:
                    ambiguo = True
                    continue
                if vals and None not in vals:
                    esito = (criterio, next(iter(vals)), coppie[0][2])
                    break
            if esito:
                break
        if not esito:
            stat["ambigui" if ambiguo else ("senza_semestre" if visto else "senza_attivita")] += 1
            continue
        stat[esito[0]] += 1
        out[m["id"]] = {"periodo": esito[1], "fonte": esito[2]}
    log(f"[{uid}] semestri trovati: {len(out)} su {len(mancanti)}; {stat}")
    return out
