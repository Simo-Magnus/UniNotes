"""Libri dai testi liberi dei syllabus di UniMoRe (campi «testi» e «testi del modulo»).

Il campo è scritto a mano dai docenti: prosa introduttiva («Per approfondimenti si consigliano i
seguenti testi:»), elenchi con trattini o puntini Word (\\uf0a7) senza a capo, più citazioni nello
stesso paragrafo separate solo da un punto, riferimenti senza editore. Rispetto all'estrazione
comune (`testi.estrai_libri`) e a quella di UniFI (`unifi_testi`), che lavorano per riga, si prova
in tre passi, fermandosi al primo che trova qualcosa:
1. estrazione per riga di UniFI;
2. come il passo 1 dopo aver tolto la frase introduttiva fino ai due punti e spezzato dove
   comincia un nuovo autore («… CABI. Patiny, S. (2012). …»);
3. per frasi: ogni frase che ha la forma di una citazione, senza la prosa che la precede.
Si tengono solo pezzi con un autore o un titolo tra virgolette e un anno, un editore o un ISBN, che
non sono prosa («Slide fornite dal docente», «Moodle», «Nessuno») né solo nomi di autori. La
citazione resta quella del syllabus; il tipo (obbligatorio/consigliato) solo se il testo lo dice.
"""
from __future__ import annotations

import re

from . import unifi_testi
from .unifi_testi import _PROSA, _citazione, _libro, _pezzi, _solo_nomi

_INTRO = re.compile(
    r"(?is)^.{0,260}?(?:testi|libri|manuali|bibliografia|letture|riferimento|riferimenti|approfondiment[oi]|"
    r"consultazione|adottat[oi]|edizioni)[^:]{0,160}:\s*(?=\S)")
_NUOVO_AUTORE = (r"(?<=[a-zà-ÿ0-9)\"”»])\.\s+(?=[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+(?:\s[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+)?,\s"
                 r"(?:[A-Z]\.\s?-?){1,3}[,(&.\s])")
_NUOVO_AUTORE2 = (r"(?<=[a-zà-ÿ0-9)\"”»])\.\s+(?=(?:[A-Z]\.\s?-?){1,3}\s?[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+"
                  r"(?:,|\s&|\se\s))")
_ANCORA = re.compile(
    r"(?:(?<!\w)(?:[A-Z]\.\s?-?){1,3}\s?(?:(?:de|di|da|del|van|von|der|la|le|el|dos|du)\s)?[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+"
    r"|(?<!\w)[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+(?:\s[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+)?,\s(?:[A-Z]\.\s?-?){1,3}"
    r"|[“\"«][^”\"»]{4,200}[”\"»])")
_FRASE = re.compile(r"(?<=[a-zà-ÿ0-9)\]”\"])\.\s+(?=[A-ZÀ-Ý“\"«(\[])|;\s+|\s+(?=\[\d{1,2}\]\s)")


def _prepara(t: str) -> str:
    t = re.sub(r"(?i)<\s*(?:br|/p|/li|/div)\s*/?>", "\n", t or "")
    t = re.sub(r"<[^>]+>", " ", t)
    t = t.replace("", "\n").replace("", "\n").replace("•", "\n").replace("●", "\n")
    t = re.sub(r"(?<=\s)[-–—](?=[A-ZÀ-Ý])", "\n", t)             # «-G.Cantore»
    t = re.sub(r"(?<=[.;)\d])\s+[-–—]\s+(?=[A-ZÀ-Ý])", "\n", t)    # «… 2010 - A. Brandt»
    t = re.sub(r"\s+(?=\(?[a-e]\)\s+[A-ZÀ-Ý])", "\n", t)            # «a) … c) …»
    t = re.sub(r"\s+(?=\d{1,2}[.)]\s+[A-ZÀ-Ý])", "\n", t)           # «1) … 2) …»
    return t


def _segmenti(testo: str) -> list[str]:
    t = _prepara(testo)
    if _INTRO.match(re.sub(r"\s+", " ", t).strip()):
        t = _INTRO.sub("", t, count=1)
    t = re.sub(_NUOVO_AUTORE, ".\n", t)
    t = re.sub(_NUOVO_AUTORE2, ".\n", t)
    return _pezzi(t)


def _frasi(testo: str) -> list[str]:
    """Frasi del testo, ciascuna senza la prosa che la precede (fino al primo autore o titolo tra virgolette)."""
    t = re.sub(r"(?i)<\s*(?:br|/p|/li|/div)\s*/?>", "\n", testo or "")
    t = re.sub(r"<a [^>]*>.*?</a>", " ", t, flags=re.S)
    t = re.sub(r"<[^>]+>", " ", t).replace("", "\n")
    t = re.sub(r"(?:https?://|www\.)\S+", " ", t)
    out = []
    for riga in re.split(r"\n+", t):
        for f in _FRASE.split(riga):
            f = re.sub(r"\s+", " ", f).strip(" .;,-–•*")
            if not f:
                continue
            m = _ANCORA.search(f)
            if m and m.start() > 0 and (_PROSA.search(f[:m.start()]) or len(f[:m.start()].split()) >= 3):
                f = f[m.start():]
            out.append(f.strip(" .;,-–"))
    return out


def _valido(b: dict) -> bool:
    """Scarta i frammenti: senza anno, editore, ISBN o virgolette, con le parentesi non chiuse, o in cui
    il titolo non si distingue dagli autori e la citazione è troppo corta per essere un riferimento intero."""
    c = b["citazione"]
    if c.count("(") != c.count(")") or c.count("“") != c.count("”"):
        return False
    segno = bool(unifi_testi.YEAR.search(c) or unifi_testi._isbn(c) or unifi_testi._editore(c.lower())
                 or re.search(r"[“\"«]", c))
    if not segno:
        return False
    titolo_separato = b["titolo"] != c and len(b["titolo"]) >= 8
    return titolo_separato or len(c.split()) >= 8


def _passo2(campi: list[str]) -> list[dict]:
    libri = [_libro(p) for c in campi for p in _segmenti(c) if _citazione(p) and not _solo_nomi(p)]
    return [b for b in libri if _valido(b)]


def _passo3(campi: list[str]) -> list[dict]:
    libri = [_libro(f) for c in campi for f in _frasi(c)
             if 24 <= len(f) <= 420 and not _PROSA.search(f) and not _solo_nomi(f) and _citazione(f)]
    return [b for b in libri if _valido(b)]


def libri_unimore(sy: dict) -> list[dict]:
    campi: list[str] = []
    for t in sy.get("testiTotali") or []:
        campi += [t.get(k) or "" for k in ("testi_it", "mod_testi_it")]
    libri, viste = [], set()
    for passo in (lambda: unifi_testi.libri_unifi(sy), lambda: _passo2(campi), lambda: _passo3(campi)):
        for b in passo():
            k = re.sub(r"\W+", "", b["citazione"].lower())[:120]
            if k not in viste:
                viste.add(k)
                libri.append(b)
        if libri:
            break
    return libri
