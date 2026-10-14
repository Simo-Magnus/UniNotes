"""Semestre degli insegnamenti unior dal syllabus del Course Catalogue Cineca (vedi periodi_cineca_syllabus)."""
from . import periodi_cineca_syllabus as _c


def fetch_periodi(uid="unior", log=print):
    return _c.fetch_periodi(uid, "coursecatalogue.unior.it", log=log)
