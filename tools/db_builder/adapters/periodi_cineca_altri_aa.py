"""Periodo degli insegnamenti di un ateneo con Course Catalogue Cineca: piani delle altre coorti / altri a.a.

Si appoggia a `periodi_cineca_piani` (piani delle coorti, frazioni comprese) e aggiunge:
- una cache su disco per ateneo (le chiavi del catalogo sono uguali per tutti gli atenei);
- le date di un altro anno accademico non si copiano (non valgono per l'a.a. corrente): del periodo
  resta il semestre che ne ricava `pulizia.periodo`;
- se il corso di studio non ha altre schede con periodo, si usa lo stesso codice di insegnamento in altri
  corsi dello stesso ateneo, ma solo se TUTTE le occorrenze con periodo danno lo stesso semestre
  (la fonte è la scheda di quell'altro corso).
Il periodo non si deduce mai: se nessuna scheda lo riporta, l'insegnamento resta senza periodo.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import tempfile
from collections import defaultdict

from . import periodi, periodi_cineca_piani as pc
from .cineca_catalogue import Client, _walk_cds
import pulizia


class ClientCache(Client):
    """Client del catalogo con cache su disco separata per ateneo (UN_HTTP_CACHE/periodi_<uid>)."""

    def __init__(self, uid: str, base: str, rate: float = 1.6, solo_cds=None):
        super().__init__(base, rate)
        self.solo_cds = set(solo_cds) if solo_cds else None  # solo i corsi (cdsCod) con insegnamenti senza periodo
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / f"periodi_{uid}" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path, params=None):
        r = self._get_cache(path, params)
        if self.solo_cds and path == "/corsi" and r is not None:
            lst: list = []
            _walk_cds(r, lst)
            return [x for x in lst if x.get("cdsCod") in self.solo_cds]
        return r

    def _get_cache(self, path, params=None):
        if not self.dir:
            return super().get(path, params)
        f = self.dir / (hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest() + ".json")
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _sem(r: dict):
    s = pulizia.periodo(r.get("periodo"), r.get("periodo_inizio"), r.get("periodo_fine"))
    return s if s in periodi.VALIDI else None


def fetch_periodi(uid: str, base: str, anno: int = 2026, log=print, solo_necessari: bool = False) -> dict:
    solo = None
    if solo_necessari:  # ateneo con centinaia di corsi: si leggono solo i piani dei corsi che servono
        corsi = {c["id"]: c.get("codice_ateneo") for c in periodi.carica(uid)["corsi"]}
        solo = {corsi[m["corso"]] for m in periodi.mancanti(uid) if corsi.get(m["corso"])}
    cl = ClientCache(uid, base, solo_cds=solo)
    ind = pathlib.Path(tempfile.gettempdir()) / f"periodi_indice_{uid}{'_solo' if solo else ''}.json"  # indice dei piani (riusabile)
    ris = pc.fetch_periodi(uid, cl, base, anno, log, ind)
    out: dict[str, dict] = {}
    for iid, r in ris.items():
        s = _sem(r)
        if not s:
            log(f"  {iid}: periodo non interpretabile {r}")
            continue
        corrente = re.search(rf"/insegnamenti/{anno}/", r["fonte"])
        v = {"periodo": s, "fonte": r["fonte"]}
        if corrente and r.get("periodo_inizio") and r.get("periodo_fine"):
            v["periodo_inizio"], v["periodo_fine"] = r["periodo_inizio"], r["periodo_fine"]
        out[iid] = v
    # stesso codice insegnamento in altri corsi dello stesso ateneo (solo se concordano tutti)
    idx = json.loads(ind.read_text(encoding="utf-8"))
    per_ad: dict = defaultdict(list)
    for e in idx:
        if e["periodi"]:
            r = pc.riassumi([tuple(p) for p in e["periodi"]])
            s = _sem(r) if r else None
            if s:
                per_ad[e["ad"]].append((e, s))
    n = 0
    for m in periodi.mancanti(uid):
        if m["id"] in out or not m.get("codice"):
            continue
        occ = per_ad.get(m["codice"]) or []
        if occ and len({s for _, s in occ}) == 1:
            e, s = max(occ, key=lambda x: (x[0]["y"], x[0]["aa"]))
            out[m["id"]] = {"periodo": s, "fonte": pc._url(base, e)}
            n += 1
    log(f"[{uid}] periodi totali {len(out)} (di cui {n} da altri corsi con lo stesso codice insegnamento)")
    return out
