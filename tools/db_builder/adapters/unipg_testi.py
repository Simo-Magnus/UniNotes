"""Libri dai testi in forma libera delle schede di www.unipg.it («Testi di riferimento»).

I docenti scrivono tutto sulla stessa riga («Autore, Titolo, Editore, anno Altro autore, Altro titolo…»),
con elenchi puntati («¿», «•», «-»), numerati, voci separate da «;» o da doppi spazi, etichette
(«Testi consigliati:»), e spesso prosa («materiale fornito dal docente su Unistudium»). Il riconoscimento
comune (`testi.estrai_libri`) tiene solo le righe con editore e anno e perde il resto. Qui:

- ogni riga si divide in voci (punti elenco, numeri, «;», doppi spazi) e in frasi;
- le frasi di prosa e i frammenti (capitoli, «ultima edizione») si scartano: una frase con segni di
  libro (ISBN, editore, anno) resta anche se contiene parole di prosa «deboli» (esame, normativa…),
  mai se parla di docente, studenti, piattaforme o materiale fornito;
- le frasi consecutive senza prosa si uniscono finché una non chiude la citazione (anno, edizione,
  editore, ISBN);
- il tipo (obbligatorio / consigliato) viene solo dalle etichette del testo («Testi consigliati»,
  «Testo adottato», «per approfondimenti»…).

La `citazione` è sempre il testo come pubblicato.
"""
from __future__ import annotations

import html
import re

from .testi import EDITORI, YEAR, _isbn, _libero, _tipo

_EDIT = re.compile(r"(?i)(?<![a-zà-ÿ])(?:" + "|".join(re.escape(e) for e in EDITORI if len(e) > 3) +
                   r"|edi-?ermes|esi|morlacchi|piccin\w*|ambrosiana|mc\s?graw[- ]?hill|gangemi|"
                   r"edagricole|calderini|bollati|pensiero scientifico|edizioni|editore|editrice)(?![a-zà-ÿ])")
# prosa «forte»: non è mai un libro, nemmeno con editore o anno
_PROSA_FORTE = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:(?-i:sar[aà�]|SAR[AÀ])|saranno|verr[aà�]|verranno|viene|vengono|vi sono|non (?:[eèé�]|sono|ci|c|è|previst)|"
    r"nessun[oa]?|fornit[oie]|forniti|indicat[oie]|comunicat[oie]|disponibil[ie]|caricat[oie]|messo|messi|"
    r"messa|durante|studenti|studentesse|docente|docenti|piattaforma|unistudium|moodle|teams|"
    r"e-?learning|power-?point|biblioteca|sito|"
    r"pagina|http|www\.|da definire|da concordare|concordat[oi]|qualsiasi|qualunque|eventuali|"
    r"consultare|si veda|si rimanda|si consiglia|si suggerisce|si segnala|frequentanti|frequentante|"
    r"scaricabil[ei]|distribuit[oie]|will|available|instructor|provided|handouts?|teacher|"
    r"professor|disabilit[aà]|dsa|accessibil[ie]|strumenti compensativi|linee guida|vedi|vedere|come da|"
    r"in aula|a lezione|in classe|on request|su richiesta|per i testi|per il testo|testi? da|si pu[oò]|"
    r"potr[aà]|potranno|consulta|consultazione|aggiornament[oi]|indicazioni|riferimenti bibliografici|"
    r"the course|this course|the students?|aims|syllabus|programma del corso|oggetto del corso|reperibil[ei]|"
    r"vanno bene|ebook|e-book|formato|in alternativa|a scelta|scelta|ulteriori|ulteriore|altri testi|"
    r"altro materiale|sostituti\w*|stranieri|certificat[ae]|difficolt[aà]|avvalersi)(?![a-zà-ÿ])|@")
# prosa «media»: materiale del docente, salvo che la frase abbia un editore o un ISBN (titolo «… Lezioni e materiali»)
_PROSA_MEDIA = re.compile(r"(?i)(?<![a-zà-ÿ])(?:slides?|diapositive|dispens[ae]|appunti|lucidi|materiale|materiali)(?![a-zà-ÿ])")
# prosa «debole»: ammessa se la frase ha segni di libro
_PROSA_DEBOLE = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:lezion[ie]|lectures?|notes|esame|prova|normativa|regolamento|obbligo|frequenza|tematiche|valutazion[ei]|orario|"
    r"ricevimento|capacit[aà]|possesso|saper|protocollo|testo vigente|riferimento|bibliografia)"
    r"(?![a-zà-ÿ])")
_INGLESE = re.compile(r"\b(?:the|of|and|to|is|are|that|which|with|for|will|be|this|on|in)\b")
_FRAMMENTO = re.compile(
    r"(?i)^\(?\s*(?:cap|capp|capitol[oi]|pp?|pagg?|parte|parti|sez|vol|volume|ultima|ult|nuova|ed|edizione|anno|"
    r"ristampa|e|ed anche|oppure|o|and|or|varie|vari|tutti|tutte|altri|altro|altre|per|inoltre|"
    r"ovvero|preferibilmente)\b[\s.:,]*[\d\w.,\-–() ]{0,40}\)?\.?$")
_ETICHETTA = re.compile(
    r"(?i)^\s*\(?\s*(?:i+\s+)?(?:(?:testi?|testo|libri?|libro|bibliografia|letture|manuale|manuali|materiale|materiali|"
    r"letteratura|riferimenti)(?:\s+(?:di|del|per|d')\s*(?:testo|riferimento|studio|lo studio|consultazione|base|"
    r"corso|approfondimento|esame))?(?:\s+(?:di|per)\s+\w+)?)?\s*(consigliat[oiae]|obbligatori[oae]?|adottat[oiae]|"
    r"di riferimento|di studio|principale|principali|generale|essenziale|integrativ[oae]|aggiuntiv[oae]|"
    r"di consultazione|di approfondimento|complementar[ei]|per approfondimenti|per approfondire|facoltativ[oie])?"
    r"\s*\)?\s*(?::|\.|-|–|—)\s*")
_SOLO_ETICHETTA = re.compile(
    r"(?i)^\s*\(?\s*(?:i+\s+)?(?:testi?|libri?|libro|bibliografia|letture|manuali?|materiale|letteratura|"
    r"riferimenti bibliografici|testo)(?:\s+(?:di|del|per|d')\s*\w+)?(?:\s+\w+)?\s*\)?\s*(?:[:.\-–]|$)")
_CHIUSURE = (r"(?i)(?:(?:19|20)\d\d[a-z]?|ult(?:ima)?\.?\s?ed(?:izione|\.)?|ed(?:izione|\.)?\s*\d*|edition|"
             r"isbn[\d\- :xX]*|\d[\d\- ]{8,}[\dXx]|\(?varie edizioni\)?|" +
             "|".join(re.escape(e) for e in EDITORI if len(e) > 3) +
             r"|editore|editrice|edi-?ermes|esi|morlacchi|piccin|gangemi|ambrosiana|mc\s?graw[- ]?hill)")
_CHIUSA = re.compile(_CHIUSURE + r"[\s.,;:)\]]*$")
_CHIUSURA_QUALSIASI = re.compile(_CHIUSURE + r"[\s.,;:)\]]*")
_INIZIALI = re.compile(
    r"(?:^|[\s,;(])(?:[A-ZÀ-Ý]\.\s?-?){1,3}\s?[A-ZÀ-Ý][a-zà-ÿ']|\b[A-ZÀ-Ý][a-zà-ÿ']+,?\s(?:[A-Z]\.\s?){1,3}")
_INIZIO_AUTORE = re.compile(r"^(?:[A-ZÀ-Ý]\.\s?-?){1,3}\s?[A-ZÀ-Ý][a-zà-ÿ']")
_TESTA = re.compile(r"^([^:]{3,70}):\s+(?=\S)")
_PAROLA_ETICHETTA = re.compile(
    r"(?i)\b(?:testi?|testo|libri?|libro|manuali?|bibliografia|letture|programma|obbligator\w*|consigliat\w*|adottat\w*|"
    r"riferimento|studenti|studentesse|frequentanti|frequentante|parte|modulo|mod|cfu|esame|prima|seconda|"
    r"approfondiment\w*|alternativa|integrativ\w*|complementar\w*)\b")
_INTRO = re.compile(r"(?i)^(?:il|i|lo|gli)\s+(?:principale\s+|unico\s+)?(?:testi?|libri?|manuali?)"
                    r"(?:\s+(?:di|per)\s+(?:riferimento|studio|base|consultazione))?\s+(?:[eèé]|sono|consiste in)\s+")
_NO_ETICHETTA =re.compile(r"(?i)^(?:titolo|autori?|editore|anno|edizione|isbn|note|luogo)$")
_BULLET = "¿•●▪◦·■□►➢✓✔"
_NUOVA_VOCE = r"(?:[-–—*]|\d{1,2}[.)]|\[\d{1,2}\]|\(\d{1,2}\)|[a-zA-Z]\)|[ivx]{2,4}\))"
_PAROLA_NOME = re.compile(r"[A-ZÀ-Ý][A-Za-zà-ÿ'’.\-]*")


def _pulisci(testo: str) -> str:
    s = html.unescape(html.unescape(testo or ""))
    s = re.sub(r"(?i)<\s*(?:br|/p|/li|/div|/tr)\s*/?>|<\s*li[^>]*>", "\n", s)
    s = re.sub(r"<[^>]+>", " ", s).replace("\xa0", " ").replace("​", "")
    s = re.sub("[" + re.escape(_BULLET) + "]", "\n", s)
    return re.sub(r"(?:https?://|www\.)[^\s)]+", " ", s, flags=re.I)


def _tipo_etichetta(m: re.Match | None, prec: str | None) -> str | None:
    if not m or not m.group(1):
        return prec
    e = m.group(1).lower()
    if e.startswith(("consigliat", "per approfond", "di approfond", "facoltativ", "complementar", "integrativ",
                     "aggiuntiv")):
        return "consigliato"
    if e.startswith(("obbligator", "adottat")):
        return "obbligatorio"
    return prec


def _spezza(riga: str) -> list[str]:
    """Divide una riga in voci: «;», doppi spazi, « - » prima di una maiuscola e numeri d'elenco in mezzo
    alla riga; mai dentro parentesi o virgolette."""
    out, ini, prof, virg = [], 0, 0, False
    molli: set[int] = set()  # indici dei pezzi che seguono un doppio spazio (separazione incerta)
    i = 0
    while i < len(riga):
        ch = riga[i]
        if ch in "([":
            prof += 1
        elif ch in ")]":
            prof = max(0, prof - 1)
        elif ch == '"':
            virg = not virg
        elif ch == "“":
            virg = True
        elif ch == "”":
            virg = False
        elif prof == 0 and not virg:
            if ch == ";" and riga[i + 1:i + 2] in (" ", ""):
                out.append(riga[ini:i])
                ini = i + 1
            elif ch == " " and riga[i + 1:i + 2] == " ":
                out.append(riga[ini:i])
                molli.add(len(out))
                while i + 1 < len(riga) and riga[i + 1] == " ":
                    i += 1
                ini = i + 1
            elif (ch == " " and re.match(r"[-–—]\s{1,2}[A-ZÀ-Ý]", riga[i + 1:i + 5])
                  and not re.search(r"\w[-–—]$", riga[:i]) and _chiusa(riga[ini:i])):
                out.append(riga[ini:i])
                ini = i + 2
            elif ch == " " and re.match(r"(?:\d{1,2}[.)]|[a-z]\)|[ivx]{2,4}\))\s?[A-ZÀ-Ý]", riga[i + 1:i + 7]) and (
                    re.search(r"[.)\d]$", riga[:i]) or _chiusa(riga[ini:i])):
                out.append(riga[ini:i])
                ini = i + 1
        i += 1
    out.append(riga[ini:])
    return [(x, k in molli) for k, x in enumerate(out) if x.strip()]


def _segmenti(testo: str):
    """(voce, tipo dall'etichetta, inizia_una_nuova_voce) per ogni elemento dell'elenco."""
    tipo = None
    precedente_aperta = False
    for riga in _pulisci(testo).splitlines():
        r = riga.replace("\t", " ").strip()
        if not r:
            precedente_aperta = False
            continue
        for k, (pezzo, molle) in enumerate(_spezza(r)):
            pezzo = re.sub(r"\s+", " ", pezzo).strip()
            nuova = (k > 0 and not molle) or not precedente_aperta or bool(re.match(rf"\s*{_NUOVA_VOCE}\s*\S", pezzo))
            if molle and (_INIZIO_AUTORE.match(pezzo) or re.match(r"[A-ZÀ-Ý][a-zà-ÿ'’\-]+,?\s+[A-ZÀ-Ý]\.", pezzo)
                          or re.match(r'["“«]', pezzo)):
                nuova = True  # dopo un doppio spazio comincia un altro autore o un titolo tra virgolette
            p = re.sub(rf"^\s*{_NUOVA_VOCE}\s*(?=\S)", "", pezzo).strip(" \t.;,")
            while True:
                m = _ETICHETTA.match(p)
                if m and (m.group(0).strip() or m.group(1)):
                    tipo = _tipo_etichetta(m, tipo)
                    nuovo = p[m.end():].strip()
                    nuova = True
                    if nuovo == p:
                        break
                    p = nuovo
                else:
                    break
            p = _INTRO.sub("", p)  # «Il testo di riferimento è …»
            m = re.match(r"(?i)^(.{3,100}?\b(?:ad esempio|per esempio|ad es\.|ovvero|tipo))\s*:\s*(?=\S)", p) or _TESTA.match(p)
            if (m and _PAROLA_ETICHETTA.search(m.group(1)) and (not re.search(r"[,;]|\d{4}", m.group(1)) or re.search(r"(?i)esempio|\bad es\.|ovvero|\btipo$", m.group(1)))
                    and not _NO_ETICHETTA.match(m.group(1).strip())):
                tipo = _tipo(m.group(1)) or tipo
                p = p[m.end():].strip()
                nuova = True
            if not nuova and _INIZIO_AUTORE.match(p):
                nuova = True  # la riga comincia con un altro autore
            if p:
                yield p, tipo, nuova
        precedente_aperta = not riga.rstrip().endswith((".", ";")) or riga.rstrip().endswith(",")


def _segni(p: str) -> bool:
    return bool(_isbn(p) or _EDIT.search(p) or YEAR.search(p))


def _prosa(frase: str) -> bool:
    senza_parentesi = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", frase)  # «(vanno bene anche le altre edizioni)»
    if frase.rstrip().endswith(":") or _PROSA_FORTE.search(senza_parentesi):
        return True
    if _PROSA_MEDIA.search(senza_parentesi) and not (_EDIT.search(frase) or _isbn(frase)):
        return True
    if _PROSA_DEBOLE.search(frase) and not _segni(frase):
        return True
    return len(_INGLESE.findall(frase)) >= 4 and not _segni(frase) and len(frase.split()) > 12


_SEP_FRASE = re.compile(r"[.!?]\s+(?![A-ZÀ-Ý]\.)(?=[A-ZÀ-Ý\"“«‘'0-9])")
_NO_TAGLIO = re.compile(r"(?:\b[A-ZÀ-Ý]|\b[A-Z][a-z]|\b[a-zà-ÿ]{1,3}|\bAA\.VV|\bVV|\bUniv|\bVol|\bEd|\bpp|\bcap|"
                        r"\bet al|\bJr|\bInc|\bCo|\bSoc|\bSt|\bDr|\bProf)$")


def _frasi(p: str) -> list[str]:
    """Frasi della voce: punto seguito da maiuscola, tranne dopo un'iniziale o un'abbreviazione."""
    out, pos = [], 0
    for m in _SEP_FRASE.finditer(p):
        if _NO_TAGLIO.search(p[pos:m.start()]):
            continue
        out.append(p[pos:m.end()].strip())
        pos = m.end()
    if p[pos:].strip():
        out.append(p[pos:].strip())
    return out


_APA = re.compile(r"(?:\b[A-ZÀ-Ý]\.|\bet al\.?|\([^)]*\))[,\s&]*\(?(?:19|20)\d\d[a-z]?(?:,[^)]*)?\)?\.?$")


def _chiusa(s: str) -> bool:
    s = s.strip()
    if _APA.search(s):  # «Rossi, M. (2020).»: gli autori e l'anno aprono la citazione, non la chiudono
        return False
    return bool(_CHIUSA.search(s))


def _solo_nomi(c: str) -> bool:
    """Solo cognomi e iniziali («Drake, Vogl and Mitchell»): manca il titolo."""
    return all(_PAROLA_NOME.fullmatch(w) or w.lower() in ("e", "and", "&", "de", "di", "van", "von", "et", "al.")
               for w in re.split(r"[\s,;]+", c) if w)


def _libro(c: str) -> bool:
    c = c.strip(" .;,-–")
    if not (12 <= len(c) <= 450) or len(c.split()) < 3 or _FRAMMENTO.match(c) or _SOLO_ETICHETTA.match(c + ":"):
        return False
    if not re.search(r"[A-Za-zÀ-ÿ]{3}", c) or not re.match(r"[A-ZÀ-Ý0-9\"“«'‘(]", c):
        return False
    if not _segni(c) and _solo_nomi(c):
        return False
    if _PROSA_MEDIA.search(c) and not (_EDIT.search(c) or _isbn(c)):
        return False
    resto = _EDIT.sub(" ", YEAR.sub(" ", c))
    resto = re.sub(r"(?i)\b(?:ed|editore|edizione|edition|casa|editrice|ristampa|st|nd|rd|th|a|ª|isbn)\b", " ", resto)
    if len(re.findall(r"[A-Za-zÀ-ÿ]{3,}", resto)) < 2:
        return False  # solo editore e anno, o solo l'edizione: manca il titolo
    if _segni(c) or _INIZIALI.search(c) or re.search(r"[\"“«].{3,}[\"”»]", c):
        return True
    # senza segni: un titolo con autore («Fisica generale, Mazzoldi»), non una frase discorsiva
    if re.match(r"[A-ZÀ-Ý][\w'’\-]+(?:\s[A-Z]\.){0,2}:\s+[A-ZÀ-Ý]", c) and len(c.split()) >= 4:
        return True  # «Schenk: Algebraic Foundations for Applied Topology»
    return len(c.split()) <= 14 and ("," in c or c.isupper())


def _recupera(fr: str) -> list[str]:
    """Da una frase di prosa, la parte che può essere un libro: quella dopo i due punti
    («… si consiglia: Autore, Titolo, Editore, 2018») o quella prima della prosa, fino all'ultima
    chiusura di citazione («Autore, Titolo, Zanichelli, Bologna Materiale fornito dal docente»)."""
    for m in re.finditer(r":\s+", fr):
        coda = fr[m.end():]
        if len(coda.split()) >= 3 and not _prosa(coda):
            return [coda]
    primo = next((m for m in _PROSA_FORTE.finditer(fr) if fr[:m.start()].count("(") <= fr[:m.start()].count(")")), None)
    if primo:
        testa = fr[:primo.start()]
        fine = None
        for m in _CHIUSURA_QUALSIASI.finditer(testa):
            fine = m.end()
        if fine and fine >= 25:
            testa = testa[:fine].strip()
            if _segni(testa) and not _prosa(testa):
                return [testa]
    return []


def libri_unipg(testi: list[str]) -> list[dict]:
    """Libri dai campi «Testi di riferimento» (uno per modulo). Vuoto se non ne trova."""
    libri, viste = [], set()
    for t in testi:
        cur: list[str] = []
        tipo_cur: list[str | None] = [None]

        def chiudi():
            cit = re.sub(r"\s+", " ", " ".join(cur)).strip(" .;,-–")
            cur.clear()
            if cit and _libro(cit):
                k = re.sub(r"\W+", "", cit.lower())[:120]
                if k not in viste:
                    viste.add(k)
                    item = _libero(cit)
                    item["tipo"] = tipo_cur[0] or item["tipo"]
                    libri.append(item)

        for voce, tipo, nuova in _segmenti(t):
            if nuova:
                chiudi()
            tipo_cur[0] = tipo
            for fr in _frasi(voce):
                if _prosa(fr):
                    chiudi()
                    for pezzo in _recupera(fr):
                        cur.append(pezzo)
                        chiudi()
                    continue
                cur.append(fr)
                if _chiusa(fr):
                    chiudi()
        chiudi()
    return libri
