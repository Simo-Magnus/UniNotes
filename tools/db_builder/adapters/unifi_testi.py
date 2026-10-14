"""Libri dai testi in forma libera dei syllabus di UniFI (campo «Testi di riferimento»).

Il campo contiene di tutto: citazioni su una riga, più citazioni sulla stessa riga separate da
spazi doppi o trattini, titolo e editore su righe diverse, etichette («Testi consigliati:»),
e soprattutto prosa («Le slide saranno su Moodle»). Si tengono solo i pezzi che hanno la
forma di una citazione (autore all'inizio o titolo tra virgolette, più un anno, un editore,
un ISBN o almeno due virgole) e non sono prosa; il testo resta com'è nella `citazione`.
"""
from __future__ import annotations

import html
import re

from .testi import _CITTA, EDITORI, YEAR, _isbn, _libero

_ETICHETTA = re.compile(
    r"(?i)^\s*(?:[-•*]\s*)?(?:(?:testi|testo|libri|libro|bibliografia|letture|manuale|manuali|materiale|materiali)"
    r"(?:\s+(?:di|del|per|d')\s*(?:testo|riferimento|studio|lo studio|consultazione|base|corso))?"
    r"(?:\s+(?:di|per)\s+\w+)?\s*(?:consigliati?|obbligatori[oa]?|adottati?|di riferimento|di studio|principale|"
    r"generale|specifica|essenziale|integrativ[oa]|aggiuntiv[oa]|di consultazione|per l'esame)?"
    r"|da studiare(?: obbligatoriamente)?(?: per l'esame)?|consigliat[oi]|obbligatori[oa]?|"
    r"testo di riferimento|testi di riferimento)\s*(?::|\.|-|–)\s*")
_PROSA = re.compile(
    r"(?i)\b(?:sar[aà]|saranno|verr[aà]|verranno|viene|vengono|vi sono|non (?:è|sono|ci)|nessun[oa]?|"
    r"fornit[oie]|indicat[oie]|disponibil[ie]|caricat[oie]|messo|messi|resi?|durante|lezion[ie]|studenti|"
    r"docente|docenti|piattaforma|moodle|e-?learning|slide|diapositive|dispens[ae]|appunti|materiale|materiali|"
    r"onesearch|biblioteca|pubmed|sito|http|www\.|see english|a scelta|da concordare|concordat[oi]|"
    r"qualsiasi|qualunque|eventuali?|ulteriori|verrà|potrà|potranno|consultare|"
    r"si veda|si rimanda|si consiglia|si suggerisce|riferimento al|frequentanti|non frequentanti)\b")
_NOME = r"[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+"
_INIZ = r"(?:[A-Z]\.\s?-?){1,3}"
_AUTORE_INIZIO = re.compile(
    rf"^(?:{_INIZ}\s?(?:(?:de|di|da|del|van|von|der|la|le|el|dos|du|Mc|Mac)\s)?{_NOME}"
    rf"|{_NOME}(?:\s(?:de|di|da|del|van|von|der|la|le|el|dos|du)\s{_NOME}|\s{_NOME})?\s?(?:{_INIZ})?\s?[,:;&(]"
    rf"|{_NOME}\s{_INIZ}"
    rf"|{_NOME}(?:\s{_NOME})?\s(?:e|and|&)\s{_NOME})")
_SEGNO = re.compile(r"\b(1[89]\d\d|20[0-4]\d)\b|[“\"«]|\b(?:ed\.|edizione|edition|editore|editrice|edizioni|press|"
                    r"vol\.|volume|capitol[oi]|chapter|pp?\.)", re.I)


def _pezzi(testo: str) -> list[str]:
    s = re.sub(r"(?i)<\s*(?:br|/p|/li|/div|/h\d|/tr)\s*/?>", "\n", testo or "")
    s = re.sub(r"(?i)<\s*li[^>]*>", "\n", s)
    s = html.unescape(html.unescape(re.sub(r"<[^>]+>", "", s))).replace("\xa0", " ").replace("\u200b", "")
    s = re.sub(r"(?:https?://|www\.)\S+", "", s)  # indirizzi web: non fanno parte della citazione
    # spazi doppi o tabulazioni: separano le voci (nell'originale erano a capo)
    righe = [re.sub(r"[ \t]+", " ", q).strip(" \t•*·–;") for r in s.splitlines() for q in re.split(r" {2,}|\t+", r)]
    righe = [r for r in righe if r]
    # riga che continua la precedente (editore o edizione a capo)
    uniti: list[str] = []
    for r in righe:
        if uniti and (r[0].islower() or re.match(r"(?i)^(?:ed\.|edizione|edition|editore|vol\.)", r)
                      or (len(r) < 30 and not re.search(r"[.:]$", uniti[-1]) and re.match(r"^[A-ZÀ-Ý]", r)
                          and any(e in r.lower() for e in EDITORI) and not _AUTORE_INIZIO.match(r))) \
                and not re.search(r"(?:https?://|www\.)\S*$", uniti[-1]):
            uniti[-1] += " " + r
        else:
            uniti.append(r)
    out: list[str] = []
    for r in uniti:
        r = _ETICHETTA.sub("", r)
        # più voci sulla stessa riga: numerazione 1) 2), trattini fra voci, spazi doppi nell'originale
        parti = re.split(r"\s+(?=\d{1,2}[.)]\s+[A-ZÀ-Ý“\"])|\s+[-–]\s+(?=[A-ZÀ-Ý][^\s,]*[,.]?\s)|\s*[\u2022\u25cf]\s*"
                         r"|\s+(?=\[\d{1,2}\]\s)|\s+\*\s+(?=[A-Z\u00c0-\u00dd])|;\s+", r)
        for p in parti:
            # frasi di prosa dopo la citazione: «…2024. È possibile utilizzare anche …»
            for q in re.split(r"(?<=[a-z0-9)])\.\s+(?=[A-ZÈÀÌÒÙ][a-zà-ÿ]{2,}\s[a-zà-ÿ])|"
                              r"(?<=\w)\.\s+(?=(?:Gli|Le|Il|Lo|La|Per|Nel|Si|Sono|Non|Ulteriori|Materiale|Materiali|"
                              r"Dispense|È|Eventuali|Tutti|Alcuni|Studenti|Inoltre|N\.?B\.?|Oltre|Gli)\b)", p):
                q = re.sub(r"^\s*\d{1,2}[.)]\s+", "", q)  # numerazione «2. », «3) »
                q = _ETICHETTA.sub("", q.strip(" .;,-–*"))
                if q:
                    out.append(q)
    return out


_INIZIO_NO = re.compile(r"(?i)^(?:tra|dalle?|dagli|dai|dal|della|delle|nel|nella|negli|nei|theory|parte|per|con|in|"
                        r"il|lo|la|le|i|gli|un|una|the|this|see|vedi|ed|e|oppure|and|or|cap|capp|capitol[oi]|"
                        r"pp|nb|note|esempio|ad esempio|anche|altri|altre|alcuni|alcune|inoltre|oltre|sez|sezione|"
                        r"regolamento|direttiva|legge|decreto|codice|costituzione|trattato|carta)\b")


def _editore(l: str) -> bool:
    """Nome di un editore noto come parola (non «ets» in «markets», «plus» in «surplus»)."""
    return any(re.search(rf"(?<![a-zà-ÿ]){re.escape(e)}" + (r"(?![a-zà-ÿ])" if len(e) <= 5 else ""), l) for e in EDITORI)


def _citazione(p: str) -> bool:
    if not (18 <= len(p) <= 450) or _PROSA.search(p) or _INIZIO_NO.match(p):
        return False
    if p[0] in "(" or p.endswith((":", "(")):  # frammento di una citazione spezzata
        return False
    if re.split(r"[\s,]+", p.lower())[0] in _CITTA:  # «Roma, Carocci, 2023»: coda di una citazione spezzata
        return False
    l = p.lower()
    pub = _editore(l)
    segno = bool(YEAR.search(p)) or pub or bool(_isbn(p)) or bool(re.search(r"[“\"«]", p)) or p.count(",") >= 2
    autore = bool(_AUTORE_INIZIO.match(p))
    virgolette = bool(re.search(r"[“\"«][^”\"»]{4,}[”\"»]", p))
    parole = len(p.split())
    # titolo + editore noto senza autore («Gestione dei pascoli. Aracne Editrice, 2005»)
    titolo_editore = pub and parole >= 4 and (bool(YEAR.search(p)) or p.count(",") + p.count(". ") >= 1)
    return segno and parole >= 3 and (autore or virgolette or titolo_editore)


_CONNETTIVI = {"e", "and", "&", "et", "al", "de", "di", "da", "del", "della", "van", "von", "der", "la", "le", "dos",
               "du", "aa.vv.", "aavv", "ed.", "eds."}


def _solo_nomi(s: str) -> bool:
    """Solo cognomi, nomi e iniziali: «A. Jorio», «Madigan MT, Martinko JM», «S. Pacchi e S. Ambrosini»."""
    parole = [w for w in re.split(r"[\s,;]+", s) if w]
    return bool(parole) and all(w.lower() in _CONNETTIVI or re.match(r"^[A-ZÀ-Ý][A-Za-zà-ÿ'’.\-]*$", w)
                                for w in parole)


def _libro(p: str) -> dict:
    """Come `_libero`, ma autori e titolo solo se la scomposizione è plausibile: altrimenti
    titolo = citazione intera (mai un titolo indovinato male)."""
    b = _libero(p)
    ok = (b["autori"] and len(b["autori"]) <= 80 and _AUTORE_INIZIO.match(b["autori"])
          and _solo_nomi(b["autori"])
          and len(b["titolo"]) >= 6 and b["titolo"] != b["citazione"])
    if not ok and (b["autori"] or b["titolo"] != b["citazione"]):
        # titolo ricavato da virgolette o da scomposizione: tenuto solo se coincide con la citazione intera
        sc = b["titolo"] != b["citazione"] and b["autori"] is None and b["editore"] and len(b["titolo"]) >= 6
        if not sc:
            b["titolo"], b["autori"] = p[:300], None
    return b


def libri_unifi(sy: dict) -> list[dict]:
    libri, viste = [], set()
    testi = []
    for t in sy.get("testiTotali") or []:
        testi += [t.get(k) or "" for k in ("testi_it", "mod_testi_it")]
    for t in testi:
        for p in _pezzi(t):
            if _citazione(p):
                k = re.sub(r"\W+", "", p.lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(_libro(p))
    return libri
