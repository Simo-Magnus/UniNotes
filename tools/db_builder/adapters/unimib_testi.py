"""Libri e periodo dai syllabus di UniMiB (elearning.unimib.it, «Course Syllabus»).

Il syllabus ha più modelli di scheda: i testi stanno in «Testi di riferimento» (testiit),
in «Materiale didattico» (materiale_didatticoit) oppure dentro «Programma» (programmait,
dopo l'etichetta «Programma e bibliografia»). Sono testo libero con citazioni, titoli di
paragrafo e prosa («Le slide saranno su Moodle»): si tengono solo i pezzi che hanno la forma
di una citazione (vedi unifi_testi) e il testo resta com'è nella `citazione`.
"""
from __future__ import annotations

import html
import re

from .testi import YEAR, _isbn
from .testi import _EDITORI_CIT, _tipo
from .unifi_testi import _AUTORE_INIZIO, _ETICHETTA, _PROSA, _citazione, _editore, _libro, _solo_nomi

# campi del syllabus in cui possono comparire i testi, in ordine di affidabilità
CAMPI_TESTI = ("testiit", "materiale_didatticoit", "materialiit", "bibliografiait")
CAMPI_PROGRAMMA = ("programmait", "programma_estesoit")  # prosa con, a volte, «Programma e bibliografia»

_SOLO_ANNO = re.compile(r"^[^()]{3,150}\(\s*(?:[a-zà-ÿ]+\s+)?(?:19|20)\d\d[a-z]?\s*\)[.,:;]?$")
_SOLO_EDITORE = re.compile(r"(?i)^(?:societ[àa] editrice|edizioni|editore|editrice|ed\.|casa editrice)\s")
_SEP_RIGA = re.compile(r"\t+| {3,}|\s*[•●▪]\s*")


def _linee(testo: str) -> list[str]:
    """Una voce per riga del syllabus (a capo, elenchi puntati), con i frammenti riuniti:
    «Autori (anno)» seguito dal titolo; nomi o editore soli sulla riga dopo il titolo."""
    s = re.sub(r"(?i)<\s*(?:br|/p|/li|/div|/h\d|/tr|/ul|/ol)\s*/?>", "\n", testo or "")
    s = re.sub(r"(?i)<\s*li[^>]*>", "\n", s)
    s = html.unescape(html.unescape(re.sub(r"<[^>]+>", "", s))).replace("\xa0", " ").replace("​", "")
    s = re.sub(r"(?:https?://|www\.)\S+", "", s)
    righe = []
    for r in s.splitlines():
        for q in _SEP_RIGA.split(r):
            q = re.sub(r"\s+", " ", q).strip(" \t•*·–-;")
            q = re.sub(r"^\s*(?:\d{1,2}[.)]|\[\d{1,2}\]|[a-z]\))\s+", "", q)
            q = _ETICHETTA.sub("", q).strip()
            if q:
                righe.append(q)
    out: list[str] = []
    i = 0
    while i < len(righe):
        r = righe[i]
        if _SOLO_ANNO.match(r) and i + 1 < len(righe) and _AUTORE_INIZIO.match(r):
            r = r + " " + righe[i + 1]  # «Ainslie, T. (2020)» + «Guida alla fisioterapia…»
            i += 1
        if out and (_SOLO_EDITORE.match(r) or (len(r) < 90 and _solo_nomi(r) and not YEAR.search(r))) \
                and not _SOLO_ANNO.match(out[-1]):
            out[-1] += " " + r  # editore o autori su una riga a parte, dopo il titolo
        else:
            out.append(r)
        i += 1
    return out


def _forte(p: str) -> bool:
    """Editore noto o ISBN: basta a distinguere una citazione dalla prosa del programma."""
    return _editore(p.lower()) or _isbn(p) is not None


_FRASI = re.compile(r"(?<=[a-z0-9\)\]])\.\s+(?=[A-ZÈÀÌÒÙ“\"«–\-])|;\s+|\s+[–—]\s+(?=[A-Z])|\s+(?=(?:In alternativa|Libri? di|Testi? (?:di|consigliat|adottat)))")
_LEAD = re.compile(r"(?i)^[^:“\"«]{0,160}?\b(?:è|sono|testi?|libri?|bibliografia|riferimento|consigliat\w+|adottat\w+|obbligatori\w+|suggerit\w+|manuale|manuali)\s*:\s*")
_QUOTE = re.compile(r"[“\"«]")


def _paragrafi(testo: str) -> list[str]:
    """Come `_linee`, ma spezza anche le frasi dei paragrafi in prosa."""
    out = []
    for r in _linee(testo):
        out += [p.strip(" .;,-–") for p in _FRASI.split(r) if p and p.strip(" .;,-–")]
    return out


def _da_frase(p: str) -> str | None:
    """Citazione dentro una frase di prosa («Il libro di testo adottato è: F.J. Holler, … EdiSES, 2015»):
    solo se ha un editore noto o un ISBN, o titolo tra virgolette con autore; si toglie l'introduzione."""
    orig = p
    p = _ETICHETTA.sub("", _LEAD.sub("", p)).strip(" .;,-–")
    q = _QUOTE.search(p)
    if q and q.start() > 0 and _PROSA.search(p[:q.start()].lower()):
        p = p[q.start():]
    if not (15 <= len(p) <= 700):
        return None
    if re.match(r"^(?:[A-ZÀ-Ý][a-zà-ÿ]+:\s|Vol\.|\(|\d)", p) or p.count("(") > p.count(")") + 1:
        return None  # coda di una citazione spezzata («Milano: Casa Editrice …», «Vol.1, Plenum Press»)
    m = _EDITORI_CIT.search(p)
    gen = re.search(r"(?i)\b(?:editoriale|publishers?|publishing|books?|verlag)\b", p)
    titolo_di_autore = re.fullmatch(r"[A-ZÀ-Ý][^,;:]{5,100}\s+(?:di|by)\s+(?:[A-Z]\.\s?){1,3}[A-Z][\w'’-]+"
                                    r"(?:\s+(?:e|and|&)\s+(?:[A-Z]\.\s?){0,3}[A-Z][\w'’-]+)*", p)
    forte = (gen is not None and gen.start() >= 12) or bool(titolo_di_autore) or (m is not None and m.start() >= 12) or (_isbn(p) is not None and len(p.split()) >= 4)
    virg = bool(re.search(r"[“\"«][^”\"»]{6,}[”\"»]", p)) and bool(re.search(r"\b[A-Z]\.|\bdi\s+[A-Z]|\bby\s+[A-Z]", p))
    if not (forte or virg) or len(p.split()) < 4:
        return None
    if re.match(r"(?i)^(?:le |il |i |gli |la |lo |sarà|verr|non |tutt|inoltre|per |durante|slide|materiale|dispens|appunti|"
                r"articol|i docenti|casa editrice)", p) and not _isbn(p):
        return None
    # frasi in inglese sul materiale che nominano «book» senza citarne uno («Other resources from books…»)
    if re.match(r"(?i)^(?:the |other |all |on the |information |in addition|reading |class |it will |online |"
                r"scientific |specialized |teacher|non-attending|different |notebooks |disponibile |pur non )", p) \
            and not (_isbn(p) or m is not None or titolo_di_autore or virg):
        return None
    if re.search(r"(?i)\b(?:bando|docente per l'anno)\b", p):
        return None
    return p


def libri_unimib(campi: dict[str, str]) -> list[dict]:
    libri, viste = [], set()

    def aggiungi(p: str, orig: str | None = None) -> None:
        k = re.sub(r"\W+", "", p.lower())[:120]
        if k not in viste:
            viste.add(k)
            b = _libro(p)
            if orig and b["tipo"] is None:
                b["tipo"] = _tipo(orig)
            libri.append(b)

    # la scheda ha due versioni (it/en): l'inglese solo se l'italiano non dà nessun testo
    for lingua in ("it", "en"):
        if libri:
            break
        for nome in CAMPI_TESTI + CAMPI_PROGRAMMA:
            for p in _linee(campi.get(nome[:-2] + lingua) or ""):
                if _citazione(p) and not (nome in CAMPI_PROGRAMMA and not _forte(p)):
                    aggiungi(p)
        if not libri:  # nessuna citazione ben formata: si cercano nelle frasi dei campi dei testi
            for nome in CAMPI_TESTI:
                for p in _paragrafi(campi.get(nome[:-2] + lingua) or ""):
                    c = _da_frase(p)
                    if c:
                        aggiungi(c, p)
    return libri


def periodo(testo: str) -> str | None:
    """«Secondo semestre», «2° anno, 1° semestre», «I e II semestre», «annuale» -> "1" | "2" | "annuale"."""
    t = re.sub(r"\s+", " ", (testo or "").lower())
    if not t:
        return None
    if re.search(r"annual|year-long|tutto l'? ?anno|first and second|both semesters|i e ii semestre|primo e secondo semestre|1\W{0,3}e\W{0,3}2\W{0,3}sem", t):
        return "annuale"
    if re.search(r"(?:^|[^a-z])(?:secondo|second|ii|2|2nd)\W*(?:semestre|semester|semeste)", t) or \
            re.search(r"semestre\W+(?:ii|2)\b", t):
        return "2"
    if re.search(r"(?:^|[^a-z])(?:primo|first|i|1|1st)\W*(?:semestre|semester|semeste)", t) or \
            re.search(r"semestre\W+(?:i|1)\b", t):
        return "1"
    return None
