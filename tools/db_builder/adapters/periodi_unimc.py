"""Semestre degli insegnamenti unimc dal syllabus del Course Catalogue Cineca (vedi periodi_cineca_syllabus)."""
from . import periodi_cineca_syllabus as _c


def fetch_periodi(uid="unimc", log=print):
    return _c.fetch_periodi(uid, "unimc.coursecatalogue.cineca.it", log=log)
