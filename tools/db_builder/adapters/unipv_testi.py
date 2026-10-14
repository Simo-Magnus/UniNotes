"""Libri dai testi in forma libera dei syllabus di UniPV (Course Catalogue).

Oltre all'estrazione comune (`testi.estrai_libri`, `unipd.libri_liberi`, `unifi_testi.libri_unifi`):

- se il testo italiano è vuoto si legge quello inglese (`testi_en`, `mod_testi_en`): i corsi in
  inglese lo pubblicano solo in inglese;
- secondo livello, solo quando il primo non ha trovato nulla: titoli e riferimenti brevi senza
  anno né editore («S. Ross: Stochastic Processes», «Robbins, Pathological Basis of Diseases»,
  «Harrison - Principi di Medicina Interna»), purché abbiano un segno di libro (autore all'inizio,
  editore, ISBN, «Manuale», «Principles»…) e non siano prosa; anche elenchi di righe brevi.

La citazione resta sempre il testo del syllabus, com'è.
"""
from __future__ import annotations

import re

from . import unifi_testi as ut
from .testi import html_to_lines
from .unipd import libri_liberi

_CAMPI_IT = ("testi_it", "mod_testi_it")
_CAMPI_EN = ("testi_en", "mod_testi_en")
_NO = re.compile(
    r"(?i)\b(?:slides?|dispens\w*|appunti|material\w*|fornit\w*|provided|moodle|kiro|kyro|piattaforma|platform|"
    r"lezion\w*|lectures?|nessun\w*|handouts?|docente|teacher|lecturer|indicat\w*|durante|will be|verr\w*|"
    r"sarann\w*|saranno|articoli|articles?|papers?|e-?learning|disponibil\w*|available|non (?:è|sono|vi|ci|viene)|"
    r"there (?:is|are)|no (?:text|book)|vedi|see|si rimanda|si consiglia|consult\w*|www\.|http|esempi|linee guida|"
    r"guidelines|decreto|codice|norme|legge|n\.a\.?|studenti|students?|frequent\w*|cfr|program\w*|ppt|amazon|"
    r"pubblicato|includ\w*|some|adottat\w*|report|questionario|opere|chapters?|test|essendo|being|further|since|"
    r"please|bibliograf\w*|examples?|vedere|presentazion\w*|power|texts?|testi|contact|required|avaiable|"
    r"photocopy|fotocopi\w*|oppure)\b")
_AUTORE_LASCO = re.compile(
    ut._AUTORE_INIZIO.pattern[:-1] + r"|" + ut._NOME + r"(?:\s" + ut._NOME + r")?\s(?:-|–|et al\.?)\s)")
_TITOLO_CASE = re.compile(r"^[A-ZÀ-Ý0-9\"“«']")
_SEGNALE = re.compile(
    r"(?i)\b(?:manual\w*|atlas|atlante|handbook|textbook|treatise|trattato|principles|principi|isbn)\b")


def _testi(sy: dict, campi: tuple[str, ...]) -> list[str]:
    return [t.get(k) or "" for t in sy.get("testiTotali") or [] for k in campi]


def _livello1(testi: list[str]) -> list[dict]:
    libri, viste = [], set()
    for t in testi:
        for p in ut._pezzi(t):
            if ut._citazione(p):
                k = re.sub(r"\W+", "", p.lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(ut._libro(p))
    return libri


def _segnale(p: str) -> bool:
    """Segno di un libro: autore all'inizio, editore noto, ISBN o parola come «Manuale», «Atlas»."""
    return bool(_AUTORE_LASCO.match(p) or ut._editore(p.lower()) or ut._isbn(p) or _SEGNALE.search(p))


def _campo_ok(p: str, minimo: int = 3) -> bool:
    return (_segnale(p) and 14 <= len(p) <= 350 and len(p.split()) >= minimo and not _NO.search(p)
            and not ut._PROSA.search(p) and not ut._INIZIO_NO.match(p) and bool(_TITOLO_CASE.match(p))
            and not p.endswith((":", "(", ",")) and not re.fullmatch(r"[\W\d_]+", p)
            and len([w for w in re.split(r"[\s,;:]+", p) if len(w) > 3]) >= 2)


def _livello2(testi: list[str]) -> list[dict]:
    """Riferimenti brevi senza anno né editore: ogni riga se tutte lo sono, altrimenti il campo intero
    (se è corto); per i campi lunghi le righe che cominciano con un autore."""
    libri, viste = [], set()

    def aggiungi(p: str) -> None:
        k = re.sub(r"\W+", "", p.lower())[:120]
        if k not in viste:
            viste.add(k)
            libri.append(ut._libro(p))

    for t in testi:
        righe = ut._pezzi(t)
        if not righe:
            continue
        if len(righe) <= 8 and all(_campo_ok(p) for p in righe):
            for p in righe:
                aggiungi(p)
            continue
        intero = "; ".join(html_to_lines(t))
        if _campo_ok(intero):
            aggiungi(intero)
            continue
        for p in righe:
            if _campo_ok(p, 4) and _AUTORE_LASCO.match(p):
                aggiungi(p)
    return libri


def libri_unipv(sy: dict) -> list[dict]:
    libri = libri_liberi(sy)
    if libri:
        return libri
    for campi in (_CAMPI_IT, _CAMPI_EN):
        testi = _testi(sy, campi)
        if not any(t.strip() for t in testi):
            continue
        libri = _livello1(testi) or _livello2(testi)
        if libri:
            return libri
    return []
