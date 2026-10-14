"""Libri dai testi in forma libera dei syllabus di UniSA (campo «Testi di riferimento», testi_it).

I testi sono quasi sempre in maiuscolo («BAIRD "CHIMICA DELL'AMBIENTE" ZANICHELLI»), con le righe
spezzate, etichette («TESTI CONSIGLIATI:»), più voci sulla stessa riga separate da «;» e spesso
prosa («MATERIALE FORNITO DAL DOCENTE», «DISPENSE DISPONIBILI SUL SITO»). Il riconoscimento comune
(`testi.estrai_libri`) scarta le voci senza editore, anno o virgole: qui si tengono anche i titoli
con autori o con sole parole del titolo, ma mai prosa, indicazioni sul materiale, rimandi al sito del
docente o frammenti (capitoli, «ultima edizione»). Il testo resta com'è nella `citazione`.
"""
from __future__ import annotations

import html
import re

from .testi import EDITORI, YEAR, _isbn, _tipo

_ETICHETTA = re.compile(
    r"(?i)^\s*(?:[-•*·–]\s*)?(?:(?:i\s+)?(?:testi|testo|libri|libro|bibliografia|letture|manuale|manuali|materiale|"
    r"materiali)(?:\s+(?:di|del|per|d')\s*(?:testo|riferimento|studio|lo studio|consultazione|base|corso|"
    r"approfondimento))?(?:\s+(?:di|per)\s+\w+)?\s*(?:consigliati?|obbligatori[oa]?|adottati?|di riferimento|"
    r"di studio|principale|generale|essenziale|integrativ[oa]|aggiuntiv[oa]|di consultazione|per l'esame|"
    r"di approfondimento|sono i seguenti|sono)?|da studiare|consigliat[oi]|obbligatori[oa]?)\s*(?::|\.|-|–)\s*")
_PROSA = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:sar[aà�]|saranno|verr[aà�]|verranno|viene|vengono|vi sono|non (?:[eèé�]|sono|ci|c|è|previst)|"
    r"nessun[oa]?|fornit[oie]|forniti|indicat[oie]|comunicat[oie]|disponibil[ie]|caricat[oie]|messo|messi|resi|"
    r"durante|lezion[ie]|studenti|studentesse|docente|docenti|piattaforma|moodle|teams|e-?learning|slide|"
    r"diapositive|dispens[ae]|appunti|power-?point|materiale|materiali|biblioteca|sito|pagina|http|www\.|"
    r"da definire|da concordare|concordat[oi]|qualsiasi|qualunque|eventuali?|ulteriori|potr[aà�]|potranno|"
    r"consultare|consultazione|si veda|si rimanda|si consiglia|si suggerisce|frequentanti|bibliografia ragionata|"
    r"ampia bibliografia|riferimenti|riferimento|a scelta|scaricabil[ei]|distribuit[oie]|will|available|"
    r"instructor|provided|lectures?|contents|handouts?|notes|teacher|regolamento|protocollo|linee guida|"
    r"indicazioni nazionali|preparazione dell'esame|testi di studio|obbligo|frequenza|esame|prova|orario|"
    r"ricevimento|consigliat[ao]|normativa|testo vigente|pu[oò] essere|svolto|capacit[aà]|valutazion[ei]|tematiche|affrontate|"
    r"possesso|saper|daranno luogo)(?![a-zà-ÿ])")
# frammenti: capitoli, edizione, pagine, riga con la sola numerazione
_FRAMMENTO = re.compile(r"(?i)^(?:\(?\s*(?:cap|capp|capitol[oi]|pp?|pagg?|parte|parti|sez|vol|volume|ultima|ult|nuova|"
                        r"ed|edizione|anno|ristampa|e|ed anche|oppure|o|and|or)\b[\s.:,]*[\d\w.,\-–() ]{0,25}\)?\.?$)")
_NUOVA_VOCE = r"(?:[-•*·–]|\d{1,2}[.)]|\[\d{1,2}\]|\(\d{1,2}\)|[a-z]\))"
_CHIUSA = re.compile(
    r"(?i)(?:(?:19|20)\d\d[a-z]?|ult(?:ima)?\.?\s?ed(?:izione|\.)?|ed\.?|edizione|edition|isbn[\d\- :xX]*|"
    r"\d[\d\- ]{8,}[\dXx]|" + "|".join(re.escape(e) for e in EDITORI if len(e) > 3) + r")\W*$")


def _solo_nomi(p: str) -> bool:
    """Solo cognomi e iniziali («A. Jorio, M. Rossi»): manca il titolo."""
    return all(re.fullmatch(r"[A-ZÀ-Ý][A-Za-zà-ÿ'’.\-]*", w) or w.lower() in ("e", "and", "&", "de", "di", "van")
               for w in re.split(r"[\s,;]+", p) if w)


def _chiusa(riga: str) -> bool:
    """La riga termina una citazione (anno, edizione, ISBN, editore, oppure frase lunga con il punto)."""
    return bool(_CHIUSA.search(riga)) or (riga.endswith(".") and len(riga.split()) >= 6)


def _blocchi(testo: str) -> list[str]:
    s = html.unescape(html.unescape(testo or ""))
    s = re.sub(r"(?i)<\s*(?:br|/p|/li|/div)\s*/?>", "\n", s)
    s = re.sub(r"<[^>]+>", "", s).replace("\xa0", " ").replace("​", "")
    s = re.sub(r"(?:https?://|www\.)\S+", "", s, flags=re.I)
    out: list[str] = []
    cur: list[str] = []

    def chiudi():
        if cur:
            out.append(" ".join(cur))
            cur.clear()

    for riga in s.splitlines():
        r = re.sub(r"[ \t]+", " ", riga).strip()
        if not r:
            chiudi()
            continue
        if re.match(rf"^{_NUOVA_VOCE}\s*\S", r):  # elenco puntato o numerato: nuova voce
            chiudi()
            r = re.sub(rf"^{_NUOVA_VOCE}\s*", "", r)
        if r.endswith(":") or _PROSA.search(r):  # introduzione dell'elenco o prosa interrompe la citazione e non ne fa parte
            chiudi()
            continue
        cur.append(r)
        if _chiusa(r):
            chiudi()
    chiudi()
    return out


def _pezzi(blocco: str) -> list[str]:
    b = _ETICHETTA.sub("", blocco).strip()
    parti = [p.strip(" .;,-–*\"'") for p in re.split(r";\s+", b)]
    return [p for p in parti if p]


def _libro(p: str) -> bool:
    if not (14 <= len(p) <= 450) or _PROSA.search(p) or _FRAMMENTO.match(p):
        return False
    if len(p.split()) < 3:
        return False
    if not p.isupper() and _solo_nomi(p) and not YEAR.search(p):
        return False  # solo autori: manca il titolo
    return True


def libri_unisa(sy: dict) -> list[dict]:
    libri, viste = [], set()
    for t in sy.get("testiTotali") or []:
        for blocco in _blocchi(t.get("testi_it") or ""):
            for p in _pezzi(blocco):
                if not _libro(p):
                    continue
                cit = re.sub(r"\s+", " ", p).strip()
                k = re.sub(r"\W+", "", cit.lower())[:120]
                if k in viste:
                    continue
                viste.add(k)
                anni = YEAR.findall(cit)
                libri.append({
                    "titolo": cit[:300], "autori": None, "editore": None,
                    "anno": int(anni[-1]) if anni else None, "edizione": None, "isbn": _isbn(cit), "lingua": None,
                    "tipo": _tipo(cit), "note": None, "citazione": cit,
                })
    return libri


_SEGNO_LIBRO = re.compile(r"(?i)(?:19|20)\d\d|isbn|(?:" + "|".join(re.escape(e) for e in EDITORI if len(e) > 3) + r")")


def e_prosa(cit: str) -> bool:
    """Voce del riconoscimento comune che non è un libro: indicazioni sul materiale («DISPENSE FORNITE DAL
    DOCENTE», «I TESTI SARANNO INDICATI …») senza anno, ISBN o editore, oppure introduzione di un elenco."""
    c = (cit or "").strip()
    if c.endswith(":"):
        return True
    return bool(_PROSA.search(c)) and not _SEGNO_LIBRO.search(c)
