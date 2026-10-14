"""Semestre degli insegnamenti UniSs: Course Catalogue Cineca (piani delle coorti, frazioni, syllabus): vedi periodi_cineca_sem."""
from __future__ import annotations

import json
import os
import pathlib

from . import uniss, periodi_cineca_sem


def fetch_periodi(uid: str = "uniss", log=print) -> dict:
    ris, lacune = periodi_cineca_sem.fetch(uid, uniss.BASE, 2026, log=log)
    d = os.environ.get("SEMESTRI_LACUNE")
    if d:
        pathlib.Path(d, f"lacune_{uid}.json").write_text(json.dumps(lacune, ensure_ascii=False, indent=0), encoding="utf-8")
    return ris
