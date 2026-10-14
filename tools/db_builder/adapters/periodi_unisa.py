"""Periodo degli insegnamenti unisa dal Course Catalogue Cineca (altri a.a./coorti dello stesso insegnamento)."""
from . import periodi_cineca_altri_aa


def fetch_periodi(uid, log=print):
    return periodi_cineca_altri_aa.fetch_periodi(uid, "https://unisa.coursecatalogue.cineca.it", 2026, log=log)
