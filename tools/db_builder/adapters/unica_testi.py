"""Libri dai testi liberi dei syllabus di UniCa quando l'estrazione di UniSS (`uniss_testi`) non trova nulla.

I docenti di Cagliari scrivono spesso un elenco di titoli senza anno né editore («E. Husserl, Filosofia come scienza
rigorosa», «Goldstein, Meccanica classica», «Idraulica (Citrini-Noseda)», «Elettronica di potenza … vol. 1 – Muhammad
H. Rashid»): non c'è un segno bibliografico che permetta di riconoscerli con le regole di UniSS. Questo passo è
l'ultimo e il più prudente:

- la riga deve stare in un campo «testi di riferimento» del syllabus e non essere prosa (verbi di servizio, rimandi
  a materiali del docente, siti, regolamenti, articoli, linee guida);
- deve avere la forma di un titolo con un autore (iniziale + cognome, «Cognome, Titolo», «Titolo (Cognome)»,
  «Titolo – Autore», «Autore: Titolo»), non una sola parola né una frase in minuscolo;
- una riga di soli nomi di persona («Laurence L. Brunton») o di un'etichetta («Testi di riferimento») non è un libro.
Il testo della citazione è quello del syllabus.
"""
from __future__ import annotations

import re

from . import unifi_testi, uniss_testi

_ESCLUDI = re.compile(
    r"(?i)\b(?:sito|siti|rivista|riviste|comitato|rapporto|rapporti|documenti|documento|report|regolamento|regolamenti|"
    r"pubblicazioni|articol[oi]|linee guida|norme|normativa|materiale|materiali|dispense|slides?|appunti|trasparenze|"
    r"manuale software|manuali di utilizzo|esercitazioni|disponibile|download|programma|corso|docente|studenti|"
    r"cataloghi|codici di calcolo|simulatore|software|consultazione|in via di definizione|da valutare|nessuno|"
    r"si prega|insegnamento|modulo di|lezioni|prof\.|strumenti|elettromagnetometri|georesistivimetro|sismografo)\b")
_NOME = r"[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+"
_INIZIALE = r"(?:[A-Z]\.\s?-?){1,3}"
_AUTORE_TITOLO = re.compile(
    rf"^(?:{_INIZIALE}\s?(?:(?:de|di|da|del|van|von|der)\s)?{_NOME}(?:[,;]\s?|\s?[-–:]\s?|\s)"  # E. Husserl, Titolo
    rf"|{_NOME}(?:\s{_NOME})?,\s?)"                                                              # Goldstein, Titolo
    r"[A-ZÀ-Ý“\"«]")
_TITOLO_AUTORE = re.compile(
    rf"[A-Za-zà-ÿ0-9’'\)]\s?(?:\([A-ZÀ-Ý][^()]{{2,60}}\)|[-–—:]\s?(?:{_INIZIALE}\s?)?{_NOME}(?:[ ,\-–]+(?:{_INIZIALE}\s?)?{_NOME}){{0,4}})"
    r"\s*\.?\s*$")


def _righe(sy: dict) -> list[str]:
    out: list[str] = []
    for t in sy.get("testiTotali") or []:
        for k in uniss_testi._CAMPI:
            for r in uniss_testi._righe(t.get(k) or ""):
                for p in re.split(r";\s+|\s+//\s+", r):
                    p = re.sub(r"^(?:\(?(?:richiesto|consigliato|obbligatorio)\)?[:\s]+|\d\.\s?)", "", p.strip(" .;,•-–\t"))
                    if p:
                        out.append(p)
    return out


def _sembra_libro(p: str) -> bool:
    n = len(p.split())
    if not (15 <= len(p) <= 260) or n < 3 or p.endswith(":") or p.count("(") != p.count(")"):
        return False
    if _ESCLUDI.search(p) or uniss_testi._PROSA.search(p) or uniss_testi._PROSA_INIZIO.match(p):
        return False
    if uniss_testi._NON_LIBRO.search(p) or uniss_testi._solo_nomi(p):
        return False
    if not re.match(r"^[A-ZÀ-Ý“\"«0-9]", p):
        return False
    return bool(_AUTORE_TITOLO.match(p) or _TITOLO_AUTORE.search(p) or unifi_testi._isbn(p))


def libri_unica(sy: dict) -> list[dict]:
    sy = uniss_testi._normalizza(sy)
    libri, viste = [], set()
    for p in _righe(sy):
        if not _sembra_libro(p):
            continue
        k = re.sub(r"\W+", "", p.lower())[:120]
        if k in viste:
            continue
        viste.add(k)
        libri.append(uniss_testi._scheda(p))
    return libri
