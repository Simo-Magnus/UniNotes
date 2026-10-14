"""Semestre degli insegnamenti di Uniba dal Course Catalogue Cineca (uniba.coursecatalogue.cineca.it).

1. syllabus dell'insegnamento (la scheda stessa: `periodo_didattico_it` e le date), vedi periodi_cineca_syllabus;
2. per gli altri, la scheda dello STESSO insegnamento (stesso corso di studio e stesso codice d'attività) in
   un'altra coorte / percorso, vedi periodi_cineca.
La fonte è la pagina del catalogo che dice il periodo. Mai dall'anno di corso, dal codice o dal nome.
"""
from . import periodi_cineca, periodi_cineca_syllabus

BASE = "https://uniba.coursecatalogue.cineca.it"


def fetch_periodi(uid, log=print):
    out = periodi_cineca_syllabus.fetch_periodi(uid, host="uniba.coursecatalogue.cineca.it", log=log)
    altri = periodi_cineca.fetch_periodi(uid, BASE, log=log)
    for iid, v in altri.items():
        out.setdefault(iid, v)
    log(f"[{uid}] totale semestri trovati: {len(out)}")
    return out
