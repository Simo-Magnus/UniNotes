"""Università di Modena e Reggio Emilia: Course Catalogue Cineca con le correzioni che servono a UniMoRe.

- Le risposte del catalogo restano su disco (variabile d'ambiente UN_HTTP_CACHE, cartella «unimore»):
  una raccolta interrotta riparte da dove era.
- Otto corsi del catalogo (sedi e curricula di Infermieristica, Ingegneria informatica, ecc.) hanno
  un nome diverso da quello di Universitaly («Infermieristica (mo)»): `ID_UNIVERSITALY` lega il codice
  del catalogo al corso di Universitaly, così build_db unisce i piani invece di lasciare un corso vuoto.
- Gli appelli si legano ai corsi (`unimore_appelli`: bacheca Esse3 per corso di studio, calendario di
  Economia) e si abbinano agli insegnamenti per codice o per nome.
- I testi dei syllabus (campo «testi_it») sono in forma libera: l'estrazione comune scarta le righe
  lunghe o senza editore; `unimore_testi` tiene i riferimenti (anche dentro la prosa) e scarta il resto.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib

from . import cineca_catalogue, unimore_appelli, unimore_testi

BASE = "https://unimore.coursecatalogue.cineca.it"

# codice del corso nel catalogo (cdsCod) → id Universitaly dello stesso corso
ID_UNIVERSITALY = {
    "14-408": "1631900",  # Infermieristica, Modena
    "14-409": "1631901",  # Infermieristica, Reggio Emilia
    "20-317": "1629940",  # Ingegneria informatica, Mantova
    "20-312": "1629941",  # Ingegneria informatica, Modena
    "14-406": "1629923",  # Tecniche di fisiopatologia cardiocircolatoria e perfusione cardiovascolare
    "14-405": "1629919",  # Tecniche di laboratorio biomedico
    "30-361": "1629993",  # Controllo e sicurezza degli alimenti
    "50-360": "1629998",  # Direzione e consulenza di impresa
}


# corsi che hanno cambiato nome e codice: (coorte, codice vecchio) -> codice attuale. Il piano del
# 2° e 3° anno si cerca nella coorte giusta (es. Scienze dei servizi giuridici è l'ex «Scienze giuridiche
# dell'impresa e della pubblica amministrazione», 11-210, nella coorte 2024).
CODICI_PRECEDENTI = {
    (2024, "11-210"): "11-310",  # Scienze giuridiche dell'impresa e della PA -> Scienze dei servizi giuridici
    (2025, "14-263"): "14-363",  # Scienze infermieristiche ed ostetriche (RE) -> LM/SNT1 sede di Reggio Emilia
    (2025, "12-360"): "12-362",  # Lingue, culture, comunicazione -> Lingue e traduzione per le arti e i media
}


# l'elenco dei corsi non ha la durata: si ricava dal tipo (L2 triennale, LM biennale, LM5/LM6 a ciclo unico)
DURATE = {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}


def _rinomina(dati, anno: int) -> None:
    if isinstance(dati, dict):
        nuovo = CODICI_PRECEDENTI.get((anno, dati.get("cdsCod")))
        if nuovo and "des_it" in dati and "cod" in dati:
            dati["cdsCod"] = nuovo
        if "cdsCod" in dati and "des_it" in dati and not dati.get("durataAnni") and dati.get("tipo_corso_cod") in DURATE:
            dati["durataAnni"] = DURATE[dati["tipo_corso_cod"]]
        for v in dati.values():
            _rinomina(v, anno)
    elif isinstance(dati, list):
        for v in dati:
            _rinomina(v, anno)


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unimore_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path, params=None):
        dati = self._get(path, params)
        if path == "/corsi" and params and str(params.get("anno")).isdigit():
            _rinomina(dati, int(params["anno"]))
        return dati

    def _get(self, path, params=None):
        if not self.dir:
            return super().get(path, params)
        k = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.dir / f"{k}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def libri_unimore(sy: dict) -> list[dict]:
    return unimore_testi.libri_unimore(sy)


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print) -> dict:
    d = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                      client=ClientCache(BASE), libri_extra=libri_unimore, coorte_per_nome=True)
    for c in d["corsi"]:
        ul = ID_UNIVERSITALY.get(c.get("codice_ateneo"))
        if ul:
            c["id_universitaly"] = ul
    unimore_appelli.abbina(d["corsi"], log)
    return d
