"""Semestre degli insegnamenti UniFI (Course Catalogue Cineca, piani delle coorti): vedi periodi_cineca_piani."""
from __future__ import annotations

import os
import pathlib

from . import periodi_cineca_piani, unifi


def fetch_periodi(uid: str = "unifi", log=print) -> dict:
    ci = os.environ.get("PERIODI_INDICE_UNIFI")
    return periodi_cineca_piani.fetch_periodi(uid, unifi.ClientCache(unifi.BASE, rate=1.6), unifi.BASE, 2026, log,
                                        pathlib.Path(ci) if ci else None)
