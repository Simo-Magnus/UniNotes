"""Semestre degli insegnamenti unimol dal syllabus del Course Catalogue Cineca (vedi periodi_cineca_syllabus)."""
from . import periodi_cineca_syllabus as _c


def fetch_periodi(uid="unimol", log=print):
    return _c.fetch_periodi(uid, "unimol.coursecatalogue.cineca.it", log=log)
