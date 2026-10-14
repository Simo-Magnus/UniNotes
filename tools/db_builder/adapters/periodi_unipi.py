"""Semestre degli insegnamenti UniPi (Course Catalogue Cineca, piani delle coorti): vedi periodi_cineca_piani."""
from __future__ import annotations

import os
import pathlib

from . import periodi_cineca_piani, unipi


def fetch_periodi(uid: str = "unipi", log=print) -> dict:
    ci = os.environ.get("PERIODI_INDICE_UNIPI")
    return periodi_cineca_piani.fetch_periodi(uid, unipi.ClientCache(unipi.BASE, rate=1.6), unipi.BASE, 2026, log,
                                        pathlib.Path(ci) if ci else None)
