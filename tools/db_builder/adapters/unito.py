"""Università degli Studi di Torino: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unito.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) UniTO richiede:

- durata dei corsi dal piano: l'elenco minimale dei corsi non ha `durataAnni` e l'adattatore comune
  userebbe 3 anni anche per i corsi a ciclo unico (5-6 anni), lasciando vuoti il 4°, 5° e 6° anno;
- coorti per nome: il codice del corso cambia con ogni nuovo ordinamento (Giurisprudenza: 004501 fino
  alla coorte 2024, 0701U52 nel 2025, 0701T52 nel 2026), quindi per l'anno di corso k si cerca il
  corso con lo stesso nome, sede e tipo nella coorte 2026 - k + 1;
- il catalogo conserva solo le coorti dal 2022: per gli anni che seguono un piano più vecchio
  (5° e 6° anno dei cicli unici) si legge il piano della coorte più vicina;
- sedi: il catalogo ha un corso per sede (Torino, Cuneo, Biella…), Universitaly un corso per sede con
  «REPLICA <sede>» nel nome: il piano di ogni sede va al corso del database della sua sede (`id_corso`),
  non tutti allo stesso;
- blocchi con una sola attività: nei piani a blocchi («PRIMO ANNO - LETTERATURA LATINA (12 CFU)») un
  blocco con una sola attività che vale i CFU richiesti è un insegnamento obbligatorio, anche se il
  catalogo non lo chiama così.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unito_piani.json`, senza toccare i libri di
`unito.json`):

    python tools/db_builder/adapters/unito.py [--senza-syllabus]
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys
import unicodedata

if __package__ in (None, ""):  # esecuzione diretta: python tools/db_builder/adapters/unito.py
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import cineca_catalogue  # noqa: E402

BASE = "https://unito.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unito_cc" if d else None
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
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


# sedi che compaiono nell'indirizzo del sito del corso (corsi senza «REPLICA <sede>» nel nome)
SEDI_URL = {"medtriennalito": "TORINO", "medtriennalias": "ASTI", "medtriennalicn": "CUNEO",
            "medtriennaliao": "AOSTA"}
CITTA = ("BIELLA", "CUNEO", "ASTI", "AOSTA", "SAVIGLIANO", "IVREA", "ORBASSANO", "COLLEGNO")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    s = re.sub(r"\breplica\b.*$", " ", s)
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\b(?:e|ed|di|del|dell|della|delle|dei|degli|il|la|lo|l|d|per)\b", " ", s).strip()


def _classe(c: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", "", (c or "").lower())


def _citta(sede: str | None) -> str:
    return re.sub(r"\s*\(.*$", "", sede or "").strip().upper()


def _sede_url(url: str | None) -> str | None:
    """Sede indicata dall'indirizzo del sito del corso (`formazioneprimaria-biella.…`), se c'è."""
    host = re.sub(r"^https?://", "", (url or "").lower()).split("/")[0]
    if host.split(".")[0] in SEDI_URL:
        return SEDI_URL[host.split(".")[0]]
    return next((c for c in CITTA if c.lower() in host), None)


def _scelta_id_corso(db: list[dict]):
    """`id_corso(corso del catalogo)` → id del corso del database della stessa sede, se si può stabilire."""
    def id_corso(cur: dict) -> str | None:
        nome = _norm(cur.get("des_it"))
        classe = _classe(cineca_catalogue._classe(cur.get("classe_cod")))
        cand = [c for c in db if _norm(c.get("nome")) == nome and (
            not classe or classe in _classe(c.get("classe")) or _classe(c.get("classe")) in classe)]
        if len(cand) < 2:
            return None  # un solo corso: lo trova build_db per nome e classe
        citta = _citta(cur.get("sedeDenominazioneComune") or cur.get("sede_des_it"))
        replica = [c for c in cand if re.search(r"(?i)\breplica\b", c.get("nome") or "")]
        principali = [c for c in cand if c not in replica]
        for c in principali:  # sito del corso con la sede nell'indirizzo
            if citta and _sede_url(c.get("url")) == citta:
                return c["id"]
        for c in replica:  # «… REPLICA Biella», «… REPLICA - CUNEO»
            if citta and re.search(rf"\b{re.escape(citta)}\b", (c.get("nome") or "").upper()):
                return c["id"]
        senza_sede = [c for c in principali if not _sede_url(c.get("url"))]
        return senza_sede[0]["id"] if len(senza_sede) == 1 else None
    return id_corso


def _blocco_obbligatorio(g: dict) -> bool:
    """Gruppo «F» di una sola attività i cui CFU sono quelli richiesti dall'etichetta: «… (12 CFU)»."""
    if g.get("cod") != "F" or len(g.get("attivita") or []) != 1:
        return False
    etichetta = (g.get("label_it") or "").strip()
    m = re.search(r"\((\d+)\s*CFU\)$", etichetta, re.I)
    if not m or re.search(r"(?i)\bfra\b|scelta stesso corso|a la carte|\bda\s+\d+", etichetta):
        return False
    try:
        return float(g["attivita"][0].get("crediti")) == float(m.group(1))
    except (TypeError, ValueError):
        return False


def _corsi_database() -> list[dict]:
    try:
        d = json.loads((ROOT / "database" / "corsi" / "unito.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [{k: c.get(k) for k in ("id", "nome", "classe", "url")} for c in d.get("corsi") or []]


SCUOLE = ("RSS", "SP")  # tipi del catalogo: scuole di specializzazione (Psicologia, Veterinaria, Medicina)


def _solo_scuole_nel_database(corsi: list[dict], db: list[dict], log=print) -> list[dict]:
    """Le scuole di specializzazione (classe SAP-5604, SAV-5101…) non sono corsi di laurea: si tengono solo
    quelle già nel database, con il loro id, perché il piano di una scuola non finisca, per nome uguale,
    nel corso di laurea magistrale omonimo (Psicologia clinica, LM-51)."""
    out = []
    for c in corsi:
        if not str(c.get("tipo_catalogo") or "").upper().startswith(SCUOLE):
            out.append(c)
            continue
        propri = [d for d in db if d.get("classe") and d["classe"] == c.get("classe")]
        if len(propri) == 1:
            out.append({**c, "id": propri[0]["id"]})
        else:
            log(f"[unito] scuola di specializzazione {c.get('classe')} {c.get('nome')} non nel database: saltata")
    return out


def fetch_ateneo(uid: str = "unito", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                        client=ClientCache(), coorte_per_nome=True,
                                        obbligatorio_gruppo=_blocco_obbligatorio,
                                        id_corso=_scelta_id_corso(_corsi_database()))
    doc["corsi"] = _solo_scuole_nel_database(doc["corsi"], _corsi_database(), log)
    doc["descrizione"] = f"Generato da {BASE} (Course Catalogue Cineca, adapters/unito.py)"
    return doc


def main(argv: list[str]) -> int:
    import time
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    doc.setdefault("appelli", {})
    out = ROOT / "database" / "contrib" / "auto" / "unito_piani.json"
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unito] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
