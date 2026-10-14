"""Università di Firenze: Course Catalogue Cineca con le correzioni che servono a UniFI.

- Molti corsi hanno cambiato codice con il nuovo ordinamento (es. Matematica: B036 nella
  coorte 2024, B327 dalla 2025): il piano del 2° e 3° anno si cerca nella coorte giusta per
  nome, sede e tipo (`coorte_per_nome`), non nel piano futuro della coorte che si iscrive ora
  (i cui insegnamenti avrebbero il syllabus del 2027/28, ancora inesistente).
- I testi dei syllabus sono spesso in forma libera: si usa l'estrazione propria di UniFI
  (`unifi_testi.libri_unifi`) e, in mancanza, quella di UniPD (`unipd.libri_liberi`).

Con la variabile d'ambiente UN_HTTP_CACHE le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import unicodedata

from . import cineca_catalogue, unifi_testi, unipd

BASE = "https://unifi.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso del catalogo l'`id` del corso del database con lo stesso nome (e, se ce ne
    sono più d'uno, la stessa durata: Architettura LM-4 di 2 anni e LM-4 c.u. di 5, che la sola classe
    non distingue). Serve anche perché «Medicine and Surgery» è il nome inglese di «Medicina e
    chirurgia»: senza `id` il suo piano finirebbe nel corso italiano."""
    p = ROOT / "database" / "corsi" / "unifi.json"
    if not p.exists():
        return 0
    db = json.loads(p.read_text(encoding="utf-8"))["corsi"]
    n = 0
    for cc in corsi:
        cand = [c for c in db if c.get("id_universitaly") and _norm(c["nome"]) == _norm(cc["nome"])]
        if len(cand) > 1:
            cand = [c for c in cand if c.get("durata_anni") == cc.get("durata_anni")]
        if len(cand) == 1:
            cc["id"] = cand[0]["id"]
            n += 1
        else:
            log(f"[unifi]   corso del catalogo non associato: {cc['nome']} ({cc.get('classe')})")
    return n


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unifi_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            # lo stesso insegnamento è in più percorsi e il syllabus può stare sotto un altro percorso:
            # senza `af_percorso` il catalogo lo trova comunque
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


# frasi che spiegano come studiare («Gli studenti frequentanti sosterranno l'esame sul testo …»):
# non sono la citazione di un libro; il libro, se c'è, lo estrae libri_extra dal testo spezzato
_PROSA_INIZIO = re.compile(r"(?i)^(?:gli|le)\s+student|^student[ie]\b|^(?:il|la|lo)\s+(?:corso|docente|candidat|materiale)|"
                           r"^(?:l'|l’)esame|^(?:il|lo)\s+student|^per (?:gli|le|i)\s+(?:student|frequentant|non)")
_testi_originale = cineca_catalogue._testi_syllabus


def _testi_syllabus(sy: dict):
    libri, modalita, legati = _testi_originale(sy)
    return [b for b in libri if not _PROSA_INIZIO.match(b.get("citazione") or "")], modalita, legati


def libri_extra(sy: dict) -> list[dict]:
    return unifi_testi.libri_unifi(sy) or unipd.libri_liberi(sy)


def fetch_ateneo(uid: str = "unifi", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    cineca_catalogue._testi_syllabus = _testi_syllabus
    try:
        doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                            client=ClientCache(BASE), coorte_per_nome=True,
                                            libri_extra=libri_extra)
    finally:
        cineca_catalogue._testi_syllabus = _testi_originale
    log(f"[{uid}] corsi con id del database: {associa(doc['corsi'], log)}")
    return doc
