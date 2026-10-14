"""Semestre degli insegnamenti UniNA (Federico II) che nel piano dell'a.a. corrente non lo riportano.

Fonte: API pubblica del portale dei corsi di studio (www.corsi.unina.it/corsidistudio-be/v1), la stessa di
`unina.py`: nel piano di studio (`…/study-plans/<aa>-<aa+1>/teachings?codPiano=…`, e `child-teachings` per i
gruppi a scelta) ogni insegnamento ha `semestre` (1, 2, A = annuale). Per gli insegnamenti senza semestre
nel piano corrente si cercano i piani degli anni accademici precedenti dello STESSO corso di studio e dello
stesso codice di insegnamento; per quelli integrati (moduli con `codIntegrato`) si usa il semestre dei moduli
se concordano; altrimenti la scheda dell'insegnamento (`schedainsegnamento`, campo «semestre») di un anno
precedente. Mai dedotto da anno di corso o nome.
"""
from __future__ import annotations

import re
from collections import defaultdict

from . import periodi, unina

SEM = {"1": "1", "2": "2", "A": "annuale"}


def fetch_periodi(uid: str = "unina", log=print) -> dict:
    h = unina.Http(rate=1.6)
    API, SITO = unina.API, unina.SITO
    manc = periodi.mancanti(uid)
    corsi = {c["id"]: c for c in periodi.carica(uid)["corsi"]}
    # codici di corso del portale usati dagli insegnamenti di ciascun corso del database
    cds_di: dict[str, set] = defaultdict(set)
    for c in corsi.values():
        for i in c.get("insegnamenti") or []:
            m = re.search(r"unina\.it/([^/]+)/insegnamenti/", i.get("url") or "")
            if m:
                cds_di[c["id"]].add(m.group(1))
    out: dict[str, dict] = {}
    cache_piani: dict = {}

    def piani(cds: str) -> dict[str, list]:
        """codice insegnamento -> [(aa, semestre, fonte)] dai piani degli ultimi anni."""
        if cds in cache_piani:
            return cache_piani[cds]
        ris: dict[str, list] = defaultdict(list)
        anni = h.json(f"{API}/courses/details/{cds}/study-plans-years") or []
        for a in sorted(anni, reverse=True)[:4]:
            aas = f"{a}-{a + 1}"
            fonte = f"{SITO}/{cds}/piani-degli-studi?anno={aas}"
            for pi in h.json(f"{API}/courses/details/{cds}/study-plans/{aas}") or []:
                for t in h.json(f"{API}/courses/details/{cds}/study-plans/{aas}/teachings?codPiano={pi['codPiano']}") or []:
                    if t.get("semestre") in SEM and t.get("codInsegnamento"):
                        ris[t["codInsegnamento"]].append((a, SEM[t["semestre"]], fonte))
                    if t.get("tipo") == "G":
                        for f in h.json(f"{API}/courses/details/{cds}/study-plans/{aas}/child-teachings?codPiano="
                                        f"{pi['codPiano']}&annoCorso={t.get('annoCorso')}&codInsegnamentoPadre="
                                        f"{t.get('codInsegnamento')}") or []:
                            if f.get("semestre") in SEM and f.get("codInsegnamento"):
                                ris[f["codInsegnamento"]].append((a, SEM[f["semestre"]], fonte))
        cache_piani[cds] = ris
        return ris

    cache_erog: dict = {}

    def erogati(cds: str, a: int) -> list[dict]:
        if (cds, a) not in cache_erog:
            items, p = [], 0
            while True:
                d = h.json(f"{API}/courses/details/{cds}/teachings/{a}?page={p}&size=100")
                if not d:
                    break
                items += d.get("items") or []
                p += 1
                if p >= (d.get("totalPages") or 0):
                    break
            cache_erog[(cds, a)] = items
        return cache_erog[(cds, a)]

    def da_schede(cds: str, cod: str) -> tuple | None:
        """(anno, semestre, link) dalle schede dei docenti degli anni precedenti (insegnamento o suoi moduli)."""
        for a in (2025, 2024, 2023):
            unita = [cod] + sorted({t["codInsegnamento"] for t in erogati(cds, a)
                                    if t.get("codIntegrato") == cod and t["codInsegnamento"] != cod})
            sem, link = set(), None
            completo = True
            for u in unita:
                profs = h.json(f"{API}/courses/details/{cds}/teachings/{a}/{u}/professors", 4) or []
                trovato = False
                for p in profs:
                    if not p.get("link"):
                        continue
                    url = h.redirect(p["link"])
                    mm = re.search(r"/sl/(\d+)", url or "")
                    d = h.json(unina.SCHEDA + mm.group(1), 4) if mm else None
                    v = unina.SEM_SCHEDA.get(((d or {}).get("semestre") or "").strip().lower())
                    if v:
                        sem.add(v)
                        link = link or p["link"]
                        trovato = True
                        break
                completo = completo and trovato
            if sem and completo and len(sem) == 1:
                return a, sem.pop(), link
            if len(sem) > 1:
                return None
        return None

    for m in manc:
        cds_url = re.search(r"unina\.it/([^/]+)/insegnamenti/", m.get("url") or "")
        if not cds_url or not m.get("codice"):
            continue
        cand = [cds_url.group(1)] + sorted(cds_di[m["corso"]] - {cds_url.group(1)})
        trov = []
        for cds in cand:
            trov += piani(cds).get(m["codice"], [])
        if not trov:
            r = da_schede(cds_url.group(1), m["codice"])
            if r:
                out[m["id"]] = {"periodo": r[1], "fonte": r[2]}
            continue
        a0 = max(t[0] for t in trov)
        s = {t[1] for t in trov if t[0] == a0}
        if len(s) == 1:
            out[m["id"]] = {"periodo": s.pop(), "fonte": next(t[2] for t in trov if t[0] == a0)}
    log(f"[{uid}] semestre dai piani/schede degli anni precedenti: {len(out)} su {len(manc)}")
    return out
