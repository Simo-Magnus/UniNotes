"""Semestre degli insegnamenti UniCal che nel piano della coorte corrente non lo riportano.

Fonte: API pubblica del portale (`storage.portale.unical.it/api/ricerca/cds/<RegDidId>/studyplans-activities/`),
la stessa di `unical.py`. La stessa attività (stesso codice Esse3, stesso corso di studio) compare nei piani
delle altre coorti con `StudyActivitySemester`: si usa la coorte più recente che lo riporta, se concordano.
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import defaultdict

from . import periodi
from .unical import API, _norm, _periodo

try:
    _SP = os.environ.get("SEMESTRI_DIR")
    if _SP:
        sys.path.insert(0, _SP)
    from cachelib import Http  # type: ignore
except Exception:  # noqa: BLE001
    Http = None


def fetch_periodi(uid: str = "unical", anno: int = 2026, log=print) -> dict:
    if Http is not None:
        h = Http(uid)
        get = lambda u: h.text(u)[1]  # noqa: E731
    else:
        from .unibo import Client
        c = Client(rate=1.6)
        get = lambda u: (c.get(u).text if c.get(u) is not None else "")  # noqa: E731

    def lista(a: int) -> list[dict]:
        out, url = [], f"{API}/cds/?lang=it&academicyear={a}&page_size=100"
        while url:
            t = get(url)
            if not t:
                break
            d = json.loads(t)
            out += d.get("results") or []
            url = d.get("next")
        return out

    per_anno = {a: lista(a) for a in range(anno - 5, anno + 1)}
    corsi = periodi.carica(uid)["corsi"]
    manc = periodi.mancanti(uid)
    corso_ids = {m["corso"] for m in manc}

    def trova(corso: dict, cds_list: list[dict]) -> list[dict]:
        cl = {x.strip() for x in re.split(r"/", (corso.get("classe") or "").replace(" R", ""))}
        nome = _norm(corso["nome"])
        cand = [x for x in cds_list if _norm(x.get("CdSName")) == nome]
        both = [x for x in cand if (x.get("CourseClassCod") or "").replace(" R", "").strip() in cl]
        return both or cand

    out: dict[str, dict] = {}
    for corso in corsi:
        if corso["id"] not in corso_ids:
            continue
        sem: dict[str, list] = defaultdict(list)  # codice -> [(coorte, semestre, fonte)]
        for coorte in range(anno, anno - 6, -1):
            for reg in trova(corso, per_anno.get(coorte, [])):
                u = f"{API}/cds/{reg['RegDidId']}/studyplans-activities/?lang=it"
                t = get(u)
                if not t:
                    continue
                for p in json.loads(t).get("results") or []:
                    for tab in p.get("PlanTabs") or []:
                        for acts in (tab.get("StudyActivities") or {}).values():
                            for a in acts:
                                s = _periodo(a.get("StudyActivitySemester"), a.get("AfSubModules"))
                                if s in ("1", "2", "annuale"):
                                    sem[a.get("StudyActivityCod")].append((coorte, s, f"{API}/cds/{reg['RegDidId']}/studyplans-activities/"))
        for m in manc:
            if m["corso"] != corso["id"] or not sem.get(m["codice"]):
                continue
            c0 = max(t[0] for t in sem[m["codice"]])
            s = {t[1] for t in sem[m["codice"]] if t[0] == c0}
            if len(s) == 1:
                out[m["id"]] = {"periodo": s.pop(), "fonte": next(t[2] for t in sem[m["codice"]] if t[0] == c0)}
    log(f"[{uid}] semestre da altre coorti del piano: {len(out)} su {len(manc)}")
    return out
