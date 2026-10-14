"""Semestre degli insegnamenti di univaq: Course Catalogue Cineca (piani delle coorti e syllabus): vedi periodi_cineca_corso."""
from __future__ import annotations

import json
import os
import pathlib

from . import periodi_cineca_corso

BASE = "https://univaq.coursecatalogue.cineca.it"


def fetch_periodi(uid: str = "univaq", log=print) -> dict:
    ris, lacune = periodi_cineca_corso.fetch(uid, BASE, 2026, log=log)
    d = os.environ.get("SEMESTRI_LACUNE")
    if d:
        pathlib.Path(d, f"lacune_{uid}.json").write_text(json.dumps(lacune, ensure_ascii=False, indent=0), encoding="utf-8")
    return ris
