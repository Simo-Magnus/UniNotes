"""Libri dai testi in forma libera dei syllabus di UniSS (campi «Testi di riferimento» e «testi del modulo»).

I docenti scrivono a mano: citazioni complete («Mankiw, N. G., Taylor, M. P. (2025), Principi di economia,
9ª edizione, Zanichelli, Bologna. ISBN …»), titoli senza autori («Manuale di Anatomia dei vertebrati EdiSES,
2010»), voci con l'editore a capo, prosa («Appunti e dispense forniti dal docente»), rimandi («Materiale su
Moodle»), articoli e capitoli. Le entità HTML sono annidate più volte («dell&amp;amp;#39;esame»).

Si procede in due passi, fermandosi al primo che trova libri:
1. estrazione di UniMoRe (`unimore_testi`: per riga, per frasi, con la prosa tolta), senza i pezzi che sono
   solo nomi di autori, frammenti o articoli di rivista;
2. riga per riga: la riga deve avere la forma di una citazione (cognome, iniziale o titolo seguito da virgole)
   e un segno bibliografico (editore noto, anno, ISBN, «ult. ed.»); la coda di indicazioni sullo studio
   («, reperibile nel Team …», «: scelta di testi da concordare …») si toglie solo se prima resta una citazione.
Il testo della citazione resta quello del syllabus; il tipo (obbligatorio/consigliato) solo se lo dice.
"""
from __future__ import annotations

import html
import re

from . import unifi_testi, unimore_testi
from .testi import EDITORI

_CAMPI = ("testi_it", "mod_testi_it")
_LIBRO_ETICHETTA = re.compile(r"(?i)\b(?:libro(?: di testo)?|testo(?: di riferimento)?|manuale)\s*:\s*")
_MARCATORI_ELENCO = ("", "", "•", "●")  # punti elenco di Word e simboli


def _unescape(s: str) -> str:
    for _ in range(8):
        n = html.unescape(s)
        if n == s:
            break
        s = n
    return s


def _normalizza(sy: dict) -> dict:
    """Copia del syllabus con i campi dei testi senza entità HTML annidate."""
    tt = []
    for t in sy.get("testiTotali") or []:
        t = dict(t)
        for k in _CAMPI:
            if isinstance(t.get(k), str):
                t[k] = _unescape(t[k])
        tt.append(t)
    return {**sy, "testiTotali": tt}


_TAIL = re.compile(
    r"(?i)(?:\s*[:;,.(]?\s*(?:scelta di testi|reperibil[ei]|da concordare|(?:\(?\s*edizione per il)|\(?\s*con esclusione|"
    r"\(?\s*parti indicate|\(?\s*per gli studenti|\(?\s*esclus[oi]|\(?\s*escluso il|\(?\s*capp?\.|\(?\s*capitol|"
    r"\(?\s*limitatamente|\(?\s*solo (?:le )?parti|\(?\s*ad eccezione|\(?\s*pp\.)"
    r"|:\s+(?:due|tre|un|uno|una|alcuni|alcune|per|da|solo)\b).*$")
_PROSA_INIZIO = re.compile(
    r"(?i)^(?:appunti|slide|slides|materiale|materiali|dispens[ae]|forniti|fornito|le indicazioni|i testi|il testo|"
    r"si ricorda|si veda|qualsiasi|un qualsiasi|files?|copia|contenuti|risorse|nessun|non |per |lo studente|gli studenti|"
    r"data la|saranno|sarà|verr|programma|il programma|la bibliografia|bibliografia (?:specifica|ragionata)|"
    r"testo di riferimento confermato|pubblicazioni di vari|manuali? (?:di|del|dei) software|eventuali|ulteriori|"
    r"inoltre|altri|altre|oltre|vedi|see|note|nb|n\.b)")
_PROSA = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:sar[aà]|saranno|verr[aà]|verranno|viene|vengono|forniti|fornito|fornite|indicat[oie]|comunicat[oie]|"
    r"caricat[oie]|piattaforma|moodle|teams|e-?learning|slide|diapositive|dispens[ae]|appunti|power-?point|"
    r"da concordare|concordat[oi]|si consiglia|si suggerisce|frequentanti|non frequentanti|a lezione|durante le lezioni|"
    r"http|www\.|@)(?![a-zà-ÿ])")
_ETICHETTA = re.compile(
    r"(?i)^\s*(?:[-*·–]\s*)?(?:(?:testi?|libri?|bibliografia|letture|manuali?|materiali?|testo)\s*"
    r"(?:di riferimento|consigliati?|obbligatori[oa]?|adottati?|di studio|principale|aggiuntiv[oa]|per l'esame)?"
    r"|obbligatori[oa]?|consigliat[oi]|autori|titolo|editore|edizione)\s*[:.\-–]\s*")
_SEGNO = re.compile(r"(?i)(?:\b(?:19[5-9]\d|20[0-4]\d)\b|\bult(?:ima|\.)?\s?ed\b|\bed\.|\bedizione\b|\bedition\b|\bed\b)")
_AUTORE = (r"(?:(?:[A-Z]\.\s?-?){1,3}\s?(?:(?:de|di|da|del|van|von|der|la|le|el|dos|du)\s)?[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+"
           r"|[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+(?:\s[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+)?\s?,\s?(?:[A-Z]\.\s?-?){1,3}"
           r"|[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+(?:\s(?:[A-Z]\.\s?){1,3})?\s?,)")
# frammenti (capitoli, pagine), articoli di rivista, film: non sono libri
_NON_LIBRO = re.compile(
    r"(?i)^(?:cap(?:p|itol[oi])?\b|pp?\.|parte\b|piccola biblioteca|gli argomenti|decreto|d\.?lgs|legge\b|regolamento|delibera|linee guida|(?:prima|seconda|terza|quarta|quinta|sesta|settima|ottava|nona|decima)\s+edizione)|,\s+in\s+[«“\"]|\bin\s+[«“]|"
    r"\([A-Z]\.\s[A-Z][a-z]+,\s(?:19|20)\d\d\)$|\bn\.\s?\d+,\s(?:19|20)\d\d\b|\bfasc\.\s?\d")
_INIZIO_AUTORE = re.compile(rf"^{_AUTORE}")

_EXTRA_EDITORI = ["edizioni", "macmillan", "edagricole", "edi.ermes", "edi ermes", "ediermes", "quintessenza", "calzetti",
                  "lippincott", "wolters", "sinauer", "blackwell", "pitagora", "delfino", "idelson", "tecniche nuove",
                  "avenue media", "emsi", "ariesdue", "meltemi", "rosenberg", "il capitello", "difusi", "ophrys",
                  "cátedra", "catedra", "schubert", "alpha test", "butterworth", "masson", "liviana", "cuem", "sole 24",
                  "tecniche nuove", "nuova libraria", "ambrosiana", "compagnia delle foreste", "terra nuova",
                  "felici", "bruno mondadori", "einaudi", "inschibboleth", "mylab", "centro stampa"]
_EDITORI_UNISS = [e for e in EDITORI if e not in ("dispense", "plus", "ets", "sage", "press")] + _EXTRA_EDITORI
_RUMORE_EDIZ = re.compile(r"(?i)\b(?:casa editrice|editrice|editore|edizioni|edizione|edition|ed|ult|ultima|ristampa|"
                          r"volume|vol|i{1,3}|iv|v|vi{0,3}|ix|x)\b\.?")
_CONN = {"e", "and", "&", "et", "al", "de", "di", "da", "del", "della", "van", "von", "der", "la", "le", "dos", "du",
         "aa.vv.", "aavv", "ed.", "eds.", "a", "cura", "-", "–", "—"}


def _editore(l: str) -> bool:
    """Nome di un editore noto come parola (non «ets» in «markets»); «dispense» non è un editore."""
    l = l.lower()
    return any(re.search(rf"(?<![a-zà-ÿ]){re.escape(e)}" + (r"(?![a-zà-ÿ])" if len(e) <= 5 else ""), l)
               for e in _EDITORI_UNISS)


def _solo_nomi(p: str) -> bool:
    """Solo autori e dati editoriali, senza titolo («Naldini, Monica e Saraceno, Chiara», «Gasco - Gualtieri,
    Casa Editrice Ambrosiana - Ed. II 2020», «Goldberg et al., McGraw-Hill»)."""
    if unifi_testi._isbn(p):
        return False
    q = p
    for e in sorted(EDITORI, key=len, reverse=True):
        if len(e) > 3 and e != "dispense":
            q = re.sub(rf"(?i)(?<![a-zà-ÿ]){re.escape(e)}(?![a-zà-ÿ])", " ", q)
    q = _RUMORE_EDIZ.sub(" ", q)
    parole = [w.strip("-–—.") or w for w in re.split(r"[\s,;()/]+", q) if w.strip("-–—.") or w in ("-", "–", "—")]
    nomi = bool(parole) and all(
        w.lower() in _CONN or re.fullmatch(r"(?:19|20)\d\d[a-z]?", w) or re.fullmatch(r"[A-ZÀ-Ý][A-Za-zà-ÿ'’.\-]*", w)
        for w in parole)
    if not nomi:
        return False
    # tutte parole con l'iniziale maiuscola: sono solo nomi se non c'è nessun dato editoriale (editore, ISBN,
    # edizione) o se ne restano meno di 3 oltre a iniziali, connettivi e anni («Goldberg et al., McGraw-Hill»);
    # un titolo di una sola parola («Chimica») si riconosce solo con autore, editore e luogo
    contenuto = [w for w in parole if w.lower() not in _CONN and not re.fullmatch(r"(?:19|20)\d\d[a-z]?|[A-Z]\.?", w)]
    editoriale = _editore(p) or bool(re.search(r"(?i)\bed\b|\bedizione\b", p))
    return not editoriale or len(contenuto) < 3


def _passo1(sy: dict) -> list[dict]:
    out = []
    for b in unimore_testi.libri_unimore(sy):
        c = b["citazione"]
        if (len(c) < 20 or _solo_nomi(c) or _NON_LIBRO.search(c)
                or re.search(r"(?:&|&amp;?|\bed|\bet al\.?)\s*$", c) and len(c.split()) < 8
                or re.match(r"^[a-zà-ÿ]{1,3}\s", c) and not unifi_testi._isbn(c)
                or re.search(r"[“\"«][^”\"»]{4,}[”\"»],?\s+(?:in|su|on)\b", c)  # capitolo/articolo di una raccolta
                or re.search(r"(?i)\bpp?\.\s*\d", c) and not unifi_testi._isbn(c) and not _editore(c)):
            continue
        out.append(b)
    return out


def _righe(testo: str) -> list[str]:
    t = re.sub(r"(?i)<\s*(?:br|/p|/li|/div)\s*/?>", "\n", testo or "")
    t = re.sub(r"<[^>]+>", " ", t).replace("\xa0", " ").replace("​", "")
    t = re.sub(r"(?:https?://|www\.)\S+", " ", t)
    for marcatore in _MARCATORI_ELENCO:
        t = t.replace(marcatore, "\n")
    righe: list[str] = []
    for r in t.splitlines():
        r = re.sub(r"[ \t]+", " ", r).strip(" \t-–*·;")
        r = re.sub(r"^\d{1,2}[.)]\s+", "", r)
        r = _ETICHETTA.sub("", r).strip()
        if r:
            righe.append(r)
    # riga che continua la precedente (editore o anno a capo)
    uniti: list[str] = []
    for r in righe:
        if uniti and not _PROSA.search(r) and (
                re.match(r"^(?:ed\.|edizione|editore|\d{4}\b|isbn|casa editrice|ed\b)", r, re.I)
                or (len(r) < 40 and _editore(r) and not _INIZIO_AUTORE.match(r))):
            uniti[-1] += ", " + r
        else:
            uniti.append(r)
    return uniti


def _valida(p: str) -> bool:
    n = len(p.split())
    if not (20 <= len(p) <= 450) or n < 4 or _PROSA.search(p) or _solo_nomi(p):
        return False
    if p.count("(") != p.count(")") or _NON_LIBRO.search(p):
        return False
    segno = bool(_SEGNO.search(p)) or _editore(p) or bool(unifi_testi._isbn(p))
    if not segno:
        return False
    struttura = p.count(",") >= 1 or p.count(". ") >= 1 or bool(re.search(r"[“\"«]", p))
    if not struttura:
        return False
    # autore all'inizio (cognome, iniziale) o titolo + editore noto
    return bool(_INIZIO_AUTORE.match(p)) or _editore(p) or bool(re.match(r"^[A-ZÀ-Ý][^,]{3,80},\s", p) and _SEGNO.search(p))


def _scheda(cit: str) -> dict:
    b = unifi_testi._libro(cit)
    b["citazione"] = re.sub(r"\s+", " ", cit).strip()
    return b


def _passo2(sy: dict) -> list[dict]:
    libri, viste = [], set()
    for t in sy.get("testiTotali") or []:
        for k in _CAMPI:
            for riga in _righe(t.get(k) or ""):
                for p in re.split(r";\s+", riga):
                    p = re.sub(r"^[a-z]\)\s+", "", p.strip(" .;,"))
                    if not p:
                        continue
                    if _LIBRO_ETICHETTA.search(p) and not _INIZIO_AUTORE.match(p):
                        p = _LIBRO_ETICHETTA.split(p)[-1].strip(" .;,")  # «Dispense. Slides. Libro: G. Rossi, Titolo»
                    dopo = p.split(": ", 1)[1].strip() if ": " in p and _PROSA_INIZIO.match(p) else None
                    if _PROSA_INIZIO.match(p) and not dopo:
                        continue
                    p = dopo or p  # «Il programma è nel cap. 15 del seguente manuale: Rossi A., Titolo, Hoepli …»
                    testa = _TAIL.sub("", p).strip(" .;,:(") if _TAIL.search(p) else p
                    for cand in dict.fromkeys([testa, p]):
                        if _valida(cand):
                            kk = re.sub(r"\W+", "", cand.lower())[:120]
                            if kk not in viste:
                                viste.add(kk)
                                libri.append(_scheda(cand))
                            break
    return libri


def _passo3(sy: dict) -> list[dict]:
    """Titolo (con o senza autore) seguito da un anno o da un'edizione, senza editore: «Manuale di
    Elettroencefalografia di Mecarelli, 2009», «Il Bergamini di Neurologia (2020)»."""
    libri, viste = [], set()
    for t in sy.get("testiTotali") or []:
        for k in _CAMPI:
            for riga in _righe(t.get(k) or ""):
                for p in re.split(r";\s+|(?<=\))\s+(?=[A-ZÀ-Ý])|\s+•\s+", riga):
                    p = _LIBRO_ETICHETTA.split(p)[-1].strip(" .;,")
                    p = re.split(r"(?<=[.)\d])\s+(?=(?:Materiale|Materiali|Slide|Slides|Dispens|Appunti|Il materiale|Le slide|"
                                 r"Altro materiale|Altri materiali)\b)", p)[0].strip(" .;,")  # prosa dopo il riferimento
                    if (not p or _PROSA_INIZIO.match(p) or _PROSA.search(p) or _NON_LIBRO.search(p)
                            or _solo_nomi(p) or not (15 <= len(p) <= 250) or len(p.split()) < 3):
                        continue
                    if not re.search(r"\b(?:19[5-9]\d|20[0-4]\d)\b|\b\d+\s?(?:a|°|ª|st|nd|rd|th)?\s?(?:ed\.?|edizione)\b", p, re.I):
                        continue
                    if not re.match(r"^(?:[A-ZÀ-Ý“\"«]|(?:il|la|lo|i|le|gli)\s+[A-ZÀ-Ý])", p) or p.count("(") != p.count(")"):
                        continue
                    kk = re.sub(r"\W+", "", p.lower())[:120]
                    if kk not in viste:
                        viste.add(kk)
                        libri.append(_scheda(p))
    return libri


_PROSA_VERBI = re.compile(
    r"(?i)^(?:il voto|la prova|l'esame|esame|modalit|ricevimento|orario|prerequisit|obiettiv|risultati di apprendimento|"
    r"lo studente|gli studenti|le studentesse|il corso|le lezioni|frequenza|durante il corso|metodi didattici|valutazione|"
    r"si ricorda|per gli studenti|per le studentesse|gli studenti)\b|"
    r"\b(?:dovranno|dovr[aà]|potranno|possono|documentino|esonerat[oi]|si consiglia|riguarda capitoli)\b")


def e_citazione(c: str) -> bool:
    """La citazione non è una frase di prosa sul modo di studiare («Gli studenti non frequentanti dovranno …»)."""
    return not _PROSA_VERBI.search(c or "")


def libri_uniss(sy: dict) -> list[dict]:
    sy = _normalizza(sy)
    return _passo1(sy) or _passo2(sy) or _passo3(sy)
