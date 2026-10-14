"""Libri dai testi in forma libera dei syllabus di UniTN (campo «Testi di riferimento»).

Oltre all'estrazione comune (testi.estrai_libri) e a quelle di UniFI e UniPD:
- molti syllabus in italiano rimandano alla versione inglese («Vedi versione in inglese»): i
  libri sono nel campo inglese, che si legge solo se quello italiano non ne ha;
- citazioni dentro una frase («Per i non frequentanti l'esame si prepara su Malfatti, Giustizia
  costituzionale, Giappichelli.»): si prende la parte dopo il richiamo («si prepara su», «libro di
  testo:», «textbook:») se ha la forma di una citazione; il testo resta com'è;
- «il libro "Titolo" di Autore», «Titolo (Autore, Seventh Edition)», «Titolo By Autore».
Prosa e frammenti si scartano con gli stessi criteri di UniFI (`unifi_testi._citazione`).
"""
from __future__ import annotations

import re

from . import testi, unifi_testi, unipd

# etichette che precedono la citazione («Testo di riferimento:», «Main textbook:», «Per consultazione:»)
_ETICHETTA = re.compile(
    r"(?i)^\s*(?:[-•*]\s*)?(?:(?:main|required|recommended|suggested|optional|reference|core|basic|primary|"
    r"principal)\s+)?(?:text\s?books?|books?|readings?|references?|bibliography|reading list|libro(?: di testo)?|"
    r"libri(?: di testo)?|testi?(?: di riferimento| consigliati?)?|manuale|bibliografia|lettura|letture|"
    r"per consultazione|per approfondire|per approfondimento|consigliato|consigliati|obbligatorio|obbligatori)"
    r"(?:\s+(?:is|are|è|sono))?\s*(?::|-|–|—)\s+")
# richiami dentro una frase, dopo i quali c'è la citazione
_RICHIAMO = re.compile(
    r"(?i)(?:\bsi prepara(?:no)? su|\bpu[òo] essere preparato su|\bpreparare l['’]esame (?:su|sul|sui)|"
    r"\bsul (?:volume|testo|manuale)|\bsul libro|\bil libro di testo (?:è|adottato è)|"
    r"\bil testo (?:principale )?(?:di riferimento )?(?:è|adottato è)|"
    r"\bil manuale (?:è|adottato è)|\bdel testo\s*:|\bsi consiglia inoltre la lettura di\s*:|\bi seguenti testi\s*:|"
    r"\bun libro consigliato è|\bsi consiglia(?: il| il testo| il volume)?|"
    r"\bsi consiglia di consultare|\bpuò essere utile|\bshould consult|\brecommended (?:textbook|book|text) is|"
    r"\bthe (?:main )?(?:textbook|book|text) is|\bis recommended|"
    r"\bcome riferimento[^:]{0,60}si consiglia(?: il seguente libro di testo)?|"
    r"\b(?:per consultazione|per approfondire|per approfondimento|per consolidare)[^:]{0,40}:|"
    r"\bis (?:the )?(?:required|main|recommended) (?:textbook|book|reading)[^:]{0,20}:?)\s*:?\s*")
_LIBRO_TITOLO = re.compile(
    r"(?i)\b(?:libro|book|testo|textbook|manuale|volume)\b[^“\"«]{0,40}[“\"«]([^”\"»]{4,150})[”\"»]\s*(?:,\s*)?"
    r"(?:di|by)\s+((?:[A-Z][\w.'’-]*)(?:\s(?:[A-Z][\w.'’-]*|de|di|van|von|and|e|&)){0,5})")
# «Principles of Biochemistry (Lehninger, Seventh Edition)»
_TITOLO_AUTORE_ED = re.compile(
    r"(?<![\w(])([A-ZÀ-Ý][^()\n]{8,100}?)\s*\(([A-ZÀ-Ý][\w'’-]+(?:\s(?:and|&|e)\s[A-ZÀ-Ý][\w'’-]+)?),\s*"
    r"([\w ]{3,20}(?:Edition|Edizione|ed\.))\)")
# «Modern Cryptography with Proof Techniques and Implementations By Seong Oun Hwang, Intae Kim»
_TITOLO_BY = re.compile(
    r"^([A-Z][^.;:]{10,140}?)\s+[Bb]y\s+((?:[A-Z][\w.'’-]*)(?:\s[A-Z][\w.'’-]*)+"
    r"(?:,\s*(?:and\s)?(?:[A-Z][\w.'’-]*)(?:\s[A-Z][\w.'’-]*)+)*)\s*$")
_AAVV = re.compile(r"(?i)^AA\.?\s?VV\.?[,:]?\s+\S")
_EDITORI_AAVV = ("mcgraw", "zanichelli", "mulino", "giappichelli", "cedam", "pearson", "hoepli", "carocci", "egea",
                 "laterza", "utet", "francoangeli")
_URL = re.compile(r"^(?:https?://|www\.)\S+$", re.I)
# prosa inglese che non è un riferimento («There is not a required textbook», «Slides provided during lessons»)
_PROSA_EN = re.compile(
    r"(?i)\b(?:there (?:is|are)|no (?:required |mandatory )?(?:text ?book|book)|not a required|will be (?:used|provided|"
    r"shared|made|distributed|available|given|announced|indicated|communicated)|(?:is|are) (?:provided|shared|"
    r"available|distributed)|slides?|lecture notes|handouts?|moodle|during the (?:course|lessons?|lectures?)|"
    r"provided during|shared during)\b")


def _campi(sy: dict, lingua: str) -> list[str]:
    out = []
    for t in sy.get("testiTotali") or []:
        for k in (f"testi_{lingua}", f"mod_testi_{lingua}"):
            if isinstance(t.get(k), str) and t[k].strip():
                out.append(t[k])
    return out


def _come_syllabus(sy: dict, lingua: str) -> dict:
    """Copia del syllabus in cui i testi della lingua scelta stanno nei campi italiani."""
    tt = []
    for t in sy.get("testiTotali") or []:
        t2 = dict(t)
        t2["testi_it"] = t.get(f"testi_{lingua}") or ""
        t2["mod_testi_it"] = t.get(f"mod_testi_{lingua}") or ""
        tt.append(t2)
    return {"testiTotali": tt}


def _libro(cit: str, contesto: str) -> dict:
    b = unifi_testi._libro(cit)
    b["tipo"] = testi._tipo(contesto) or b.get("tipo")
    return b


def libri_frasi(sy: dict, lingua: str = "it") -> list[dict]:
    libri, viste = [], set()

    def aggiungi(cit: str, contesto: str) -> None:
        cit = cit.strip(" .;,-–*")
        k = re.sub(r"\W+", "", cit.lower())[:120]
        if k and k not in viste and not _URL.match(cit) and not _PROSA_EN.search(cit):
            viste.add(k)
            libri.append(_libro(cit, contesto))

    for campo in _campi(sy, lingua):
        for p in unifi_testi._pezzi(campo):
            p = p.strip()
            m = _LIBRO_TITOLO.search(p)
            if m:
                aggiungi(m.group(0), p)
                continue
            q = _ETICHETTA.sub("", p)
            if unifi_testi._citazione(q):
                aggiungi(q, p)
                continue
            if _AAVV.match(q) and len(q) <= 300 and (
                    testi.YEAR.search(q) or any(e in re.sub(r"[\s.]", "", q.lower()) for e in _EDITORI_AAVV)):
                aggiungi(q, p)
                continue
            te = _TITOLO_AUTORE_ED.findall(p) and list(_TITOLO_AUTORE_ED.finditer(p))
            if te and len(p) <= 400:
                for m in te:
                    aggiungi(m.group(0), p)
                continue
            if _TITOLO_BY.match(q):
                aggiungi(q, p)
                continue
            for r in _RICHIAMO.finditer(p):
                coda = p[r.end():].strip(" .;,")
                if unifi_testi._citazione(coda):
                    aggiungi(coda, p)
                    break
    return libri


def libri_unitn(sy: dict) -> list[dict]:
    """Italiano; se non c'è nulla, il testo inglese (che nei syllabus «Vedi versione in inglese» è
    quello vero). Per l'inglese si tengono solo le citazioni con la forma di un riferimento."""
    libri = libri_frasi(sy, "it")
    if libri:
        return libri
    en = _come_syllabus(sy, "en")
    cand = (testi.estrai_libri(*_campi(sy, "en")) + unifi_testi.libri_unifi(en) + unipd.libri_liberi(en)
            + libri_frasi(sy, "en"))
    out, viste = [], set()
    for b in cand:
        cit = _ETICHETTA.sub("", b["citazione"])
        k = re.sub(r"\W+", "", cit.lower())[:120]
        if k in viste or _URL.match(cit) or _PROSA_EN.search(cit) or not (
                unifi_testi._citazione(cit) or _TITOLO_BY.match(cit) or _TITOLO_AUTORE_ED.search(cit)):
            continue
        viste.add(k)
        out.append(b)
    return out


_PROSA_INIZIO = re.compile(r"(?i)^(?:gli|le)\s+student|^student[ie]\b|^il corso\b|^durante\b")
_TAGLI = re.compile(r"(?:[:;]\s+|\s(?:con|su|di|volume di|testo di|lettura di)\s+)")


def ripulisci(b: dict) -> dict:
    """Citazione che comincia con una frase («Gli studenti non frequentanti dovranno aggiungere la
    lettura di: G. Ieranò, …»): si tiene la parte che ha la forma di una citazione, se c'è."""
    cit = b.get("citazione") or ""
    if not _PROSA_INIZIO.match(cit):
        return b
    for m in _TAGLI.finditer(cit):
        coda = cit[m.end():].strip()
        if unifi_testi._AUTORE_INIZIO.match(coda) and unifi_testi._citazione(coda):
            nuovo = unifi_testi._libro(coda)
            nuovo["tipo"] = b.get("tipo") or testi._tipo(cit[:m.end()])
            return nuovo
    return b
