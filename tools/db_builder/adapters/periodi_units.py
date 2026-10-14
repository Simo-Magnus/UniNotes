"""Semestre degli insegnamenti di units dal Course Catalogue Cineca (piani delle altre coorti/percorsi): vedi periodi_cineca."""
from . import periodi_cineca

BASE = "https://units.coursecatalogue.cineca.it"


def fetch_periodi(uid, log=print):
    return periodi_cineca.fetch_periodi(uid, BASE, log=log)
