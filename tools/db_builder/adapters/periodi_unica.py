"""Semestre degli insegnamenti UniCa: Course Catalogue Cineca (piani delle coorti, frazioni, syllabus): vedi periodi_cineca_sem."""
from __future__ import annotations

import json
import os
import pathlib

from . import unica, periodi_cineca_sem


def fetch_periodi(uid: str = "unica", log=print) -> dict:
    ris, lacune = periodi_cineca_sem.fetch(uid, unica.BASE, 2026, log=log)
    d = os.environ.get("SEMESTRI_LACUNE")
    if d:
        pathlib.Path(d, f"lacune_{uid}.json").write_text(json.dumps(lacune, ensure_ascii=False, indent=0), encoding="utf-8")
    return ris
