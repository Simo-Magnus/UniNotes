"""Insegnamenti, docenti e libri dell'Università Telematica San Raffaele Roma da www.uniroma5.it.

Stesso gruppo e stesso sito di Mercatorum e Pegaso (vedi adapters/unimercatorum.py): pagine dei
corsi `/triennale/<corso>` e `/magistrale/<corso>` con i piani in una fisarmonica ("L-22 - … - PIANO
STATUTARIO") e le schede HTML degli insegnamenti (`/insegnamenti/<codice>`: docente, "Testi consigliati").
"""
from __future__ import annotations

from . import unimercatorum


def fetch_ateneo(uid: str = "uniroma5", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    d = unimercatorum.fetch_ateneo(uid, anno, max_cds, syllabus, corsi, log, base="https://www.uniroma5.it",
                                   elenco=r"https://www\.uniroma5\.it/(?:triennale|magistrale)/[\w.-]+",
                                   pagina_elenco="/offerta-formativa")
    d["descrizione"] = "Generato da www.uniroma5.it, piani di studio e schede (adapters/uniroma5.py)"
    return d
