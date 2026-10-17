"""CFU degli insegnamenti dell'Università di Catania dall'API pubblica GOMP (`public.smartedu.unict.it`).

Il piano di studi del database (siti dei dipartimenti) non riporta i crediti: la maggior parte degli insegnamenti ha
`cfu` null. L'API pubblica del regolamento («PublicData», la stessa di `periodi_unict`) dà per ogni attività i
`credits` (CFU per settore) e le ore: si sommano i CFU dei settori dell'attività. L'abbinamento è lo stesso di
`periodi_unict` (corso GOMP con lo stesso nome e classe negli a.a. 2026, 2025 e 2024; insegnamento per codice, poi
per nome); vale il valore se è uno solo in tutte le corrispondenze, altrimenti l'insegnamento resta senza CFU.
Al massimo 1 richiesta al secondo; cache su disco in `$UN_HTTP_CACHE/unict_gomp` (se impostata).
Uscita: `database/contrib/auto/unict_cfu.json` (id, nome, cfu, cfu_fonte).
"""
from __future__ import annotations

import datetime
import json
import os
import pathlib
import re

from . import periodi
from .gomp import Api, _ita, _norm

BASE = "https://public.smartedu.unict.it"
ANNI = (2026, 2025, 2024)


def _attivita(g, out: list) -> None:
    if isinstance(g, dict):
        if g.get("type") == "activity" and g.get("code"):
            cfu = sum(float(c.get("credits") or 0) for c in g.get("credits") or [])
            voce = {"code": g["code"], "name": _ita(g.get("name")), "cfu": cfu or None,
                    "years": sorted({t.get("year") for t in g.get("temporalUnits") or [] if t.get("year")})}
            if voce not in out:
                out.append(voce)
        for v in g.values():
            if isinstance(v, (dict, list)):
                _attivita(v, out)
    elif isinstance(g, list):
        for v in g:
            _attivita(v, out)


def fetch_cfu(uid: str = "unict", log=print) -> dict[str, dict]:
    d = os.environ.get("UN_HTTP_CACHE")
    cache = (pathlib.Path(d) / "unict_gomp") if d else None
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
    mancanti = [(c["id"], i) for c in corsi.values() for i in c.get("insegnamenti") or [] if i.get("cfu") is None]
    usati = {cid for cid, _ in mancanti}
    gomp: dict[int, list[dict]] = {}
    for aa in ANNI:
        def lista(aa=aa):
            r = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": aa, "courseTypes": ["CorsoDiStudio"]})
            return [{"uid": c["uid"], "code": c.get("code"), "ita": _ita(c.get("name")), "classes": c.get("classes") or [],
                     "eng": " ".join(t.get("text") or "" for t in c.get("name") or [] if t.get("iso") == "eng")}
                    for s in (r or {}).get("data") or [] for c in s.get("courses") or []] if r else None
        gomp[aa] = cached(f"corsi_{aa}.json", lista) or []

    def abbina(c: dict, aa: int) -> list[dict]:
        n, ne = _norm(c["nome"]), _norm(c.get("nome_en") or c["nome"])
        cand = [g for g in gomp[aa] if _norm(g["ita"]) == n or _norm(g["eng"]) == ne]
        cl = {x.strip() for x in (c.get("classe") or "").split("/")}
        return [g for g in cand if {re.sub(r"\s+R$", "", x) for x in g["classes"]} & cl] or cand

    attivita: dict[tuple[str, int], list[dict]] = {}
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
                for a in cached(f"cfu_corso_{g['uid']}_{aa}.json", scarica) or []:
                    lst.append({**a, "fonte": f"{BASE}/PublicData?uid={g['uid']}&mode=CourseDetail&iso=ita&academicYear={aa}"})
            attivita[(cid, aa)] = lst
        log(f"[{uid}] {cid}: " + ", ".join(f"{aa}={len(attivita[(cid, aa)])}" for aa in ANNI) + f"; richieste {api.requests}")

    out: dict[str, dict] = {}
    for cid, m in mancanti:
        esito = None
        for criterio in ("codice", "nome"):
            voci = []
            for aa in ANNI:
                if criterio == "codice":
                    voci += [a for a in attivita[(cid, aa)] if m.get("codice") and a["code"] == m["codice"] and a["cfu"]]
                else:
                    voci += [a for a in attivita[(cid, aa)] if _norm(a["name"]) == _norm(m["nome"]) and a["cfu"]]
            valori = {a["cfu"] for a in voci}
            if len(valori) == 1:
                esito = (next(iter(valori)), voci[0]["fonte"])
                break
            if len(valori) > 1:
                break  # ambiguo: nessun CFU
        if esito:
            v = esito[0]
            out[m["id"]] = {"cfu": int(v) if float(v).is_integer() else v, "fonte": esito[1], "nome": m["nome"], "corso": cid}
    log(f"[{uid}] CFU trovati: {len(out)} su {len(mancanti)}")
    return out


def scrivi(uid: str, risultati: dict[str, dict]) -> int:
    per_corso: dict[str, list] = {}
    for iid, r in risultati.items():
        per_corso.setdefault(r["corso"], []).append({"id": iid, "nome": r["nome"], "cfu": r["cfu"], "cfu_fonte": r["fonte"]})
    doc = {"universita_id": uid, "verificato_il": datetime.date.today().isoformat(),
           "corsi": [{"id": cid, "insegnamenti": sorted(l, key=lambda x: x["id"])} for cid, l in sorted(per_corso.items())]}
    p = periodi.DB / "contrib" / "auto" / f"{uid}_cfu.json"
    p.write_text(json.dumps(doc, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    return sum(len(c["insegnamenti"]) for c in doc["corsi"])


if __name__ == "__main__":
    r = fetch_cfu()
    print(scrivi("unict", r))
