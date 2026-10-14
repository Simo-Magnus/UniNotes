"""Insegnamenti, docenti e libri dell'Università Telematica Pegaso da www.unipegaso.it.

Stesso gruppo e stesso sito dell'Universitas Mercatorum (vedi adapters/unimercatorum.py):
pagine dei corsi `/lauree-triennali/<corso>`, `/lauree-magistrali/<corso>`, … con i piani di
studio per indirizzo e i programmi in PDF (`/pdf/programma/<codice>`).
"""
from __future__ import annotations

from . import unimercatorum


def fetch_ateneo(uid: str = "unipegaso", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    d = unimercatorum.fetch_ateneo(uid, anno, max_cds, syllabus, corsi, log, base="https://www.unipegaso.it",
                                   elenco=r"https://www\.unipegaso\.it/(?:lauree|laurea)[\w-]*/[\w-]+")
    d["descrizione"] = "Generato da www.unipegaso.it, piani di studio e programmi (adapters/unipegaso.py)"
    return d
