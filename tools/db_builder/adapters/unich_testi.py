"""Libri dai testi in forma libera dei syllabus di UdA (campo «Testi di riferimento», testi_it / mod_testi_it).

I testi sono scritti a mano in molti modi: elenchi puntati o numerati, un solo paragrafo con più
citazioni di seguito («… Il Mulino 2020; M. Arzarello … 2015. Oltre ai testi verranno messi a
disposizione dispense»), etichette («Testi consigliati:», «Un testo a scelta tra:»), prosa sul
materiale («Dispense a cura del docente», «sulla piattaforma Moodle») e rimandi a capitoli o pagine.
Il riconoscimento comune (`testi.estrai_libri`) scarta tutto ciò che non ha editore, anno o virgole;
qui il testo si divide in voci (a capo, punto e virgola, nuova citazione dopo un anno, frase di prosa),
si scartano le voci che sono prosa o frammenti e si tengono quelle che hanno i segni di un riferimento
bibliografico (anno, ISBN, editore, oppure autore con iniziale e almeno quattro parole).
Il testo resta com'è nella `citazione`. Il tipo (obbligatorio/consigliato) c'è solo se il programma lo dice
(nella voce o nell'etichetta che la precede).
"""
from __future__ import annotations

import html
import re

from .testi import EDITORI, YEAR, _isbn, _tipo

_EDITORI = [e for e in EDITORI if len(e) > 3]
_SEGNO_EDITORE = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:" + "|".join(re.escape(e) + (r"(?![a-zà-ÿ])" if len(e) <= 5 else "") for e in _EDITORI) +
    r"|ed\.|editore|editrice|edizioni|edises|cambridge up|university press|univ\. press|angeli|laterza|zanichelli|"
    r"utet|cedam|giappichelli|mulino|carocci|einaudi|piccin|ambrosiana|esculapio|edra|mcgraw|hoepli|pearson|egea|"
    r"cortina|elsevier|springer|wiley|oxford|apogeo)")
_ISBN_T = re.compile(r"(?i)isbn")
_ETICHETTA = re.compile(
    r"(?i)^\s*(?:[-•*·–]\s*)?(?:(?:i\s+|il\s+|gli\s+)?(?:testi|testo|libri|libro|bibliografia|letture|lettura|manuale|"
    r"manuali|materiale|materiali|volumi|volume)(?:\s+(?:di|del|per|d')\s*(?:testo|riferimento|studio|lo studio|"
    r"consultazione|base|corso|approfondimento|esame))?(?:\s+(?:adottat[oi]|consigliat[oi]|obbligatori[oa]?|"
    r"di riferimento|di studio|principale|generale|essenziale|integrativ[oa]|aggiuntiv[oa]|di consultazione|"
    r"per l'esame|di approfondimento|facoltativ[oi]|suggerit[oi]))?|altri\s+(?:testi|libri|volumi|manuali)|"
    r"altre\s+letture(?:\s+consigliate)?|letture\s+(?:consigliate|di approfondimento)|"
    r"da studiare|consigliat[oi]|obbligatori[oa]?)(?:\s+(?:consigliat[oi]|obbligatori[oa]?|facoltativ[oi]|di "
    r"approfondimento|di riferimento))?\s*(?::|\.|-|–)\s*")
# frasi di prosa e indicazioni sul materiale: una voce che le contiene (e non ha un segno chiaro di riferimento) non è un libro
_PROSA = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:sar[aà�]|saranno|verr[aà�]|verranno|viene|vengono|vi sono|non (?:[eèé�]|sono|ci|c|è|previst)|"
    r"nessun[oa]?|fornit[oie]|forniti|indicat[oie]|comunicat[oie]|disponibil[ie]|caricat[oie]|messo|messi|resi|"
    r"durante|lezion[ie]|studenti|studentesse|docente|docenti|docenza|piattaforma|moodle|teams|e-?learning|slide|"
    r"diapositive|dispens[ae]|appunti|power-?point|ppt|materiale|materiali|biblioteca|sito|pagina|http|www\.|"
    r"da definire|da concordare|concordat[oi]|qualsiasi|qualunque|eventuali?|ulteriori|ulteriore|potr[aà�]|potranno|"
    r"consultare|si veda|si rimanda|si consiglia|si suggerisce|si raccomanda|si segnala|si indica|esemplificativo|segnalazione|frequentanti|bibliografia ragionata|"
    r"ampia bibliografia|a scelta|scaricabil[ei]|distribuit[oie]|will|available|"
    r"instructor|provided|lectures?|handouts?|notes|teacher|regolamento|"
    r"preparazione dell'esame|obbligo|frequenza|orario|ricevimento|"
    r"valutazion[ei]|tematiche|affrontate|possesso|saper|daranno luogo|reperibil[ei]|indicazioni|bibliografia di approfondimento|"
    r"verranno|fornisce|fornir[aà]|consegnat[oie]|segnalat[oie]|segnalar[aà]|illustrat[oie]|spiegat[oie]|"
    r"argomenti|programma del corso|contenuti|oggetto d'esame|esame|prova|gli studenti|lo studente|"
    r"scaricare|scaricabile|dalla rete|online|on-?line)(?![a-zà-ÿ])")
_PROSA_FORTE = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:sar[aà]|saranno|verr[aà]|verranno|vengono|fornit[oie]|forniti|comunicat[oie]|"
    r"disponibil[ie]|caricat[oie]|piattaforma|moodle|e-?learning|slide|diapositive|dispens[ae]|appunti|"
    r"power-?point|biblioteca|http|www\.|da definire|da concordare|potr[aà]|potranno|si veda|si rimanda|"
    r"si consiglia|si suggerisce|si raccomanda|si segnala|frequentanti|a scelta dello studente|"
    r"will|available|provided|durante le lezioni|docente|docenti|studenti|studentesse|regolamento|linee guida|"
    r"direttiva|codice deontologico)(?![a-zà-ÿ])")
# frasi che aprono un periodo di prosa dopo l'ultima citazione
_INIZIO_PROSA = (r"Oltre|Gli studenti|Le studentesse|Lo studente|Si |Per gli|Per le|Per i |Per chi|I testi|Il testo|Il materiale|"
                 r"Le dispense|La dispensa|Materiale|Altri testi|Altre indicazioni|Eventuale|Eventuali|Tutti i|Tutto il|"
                 r"Durante|Verranno|Saranno|Sar[aà]|Potranno|Gli argomenti|Ulteriori|Ulteriore|Nel corso|Gli appunti|"
                 r"I non|NB|N\.B|Attenzione|Avvertenza|Altre letture|Altri materiali|I materiali|Dispens|Slide|Appunti|"
                 r"Inoltre|Infine|Integrazioni|Integrazione|Tutta la|Tutte le|Il docente|La docente|I docenti|Lezioni|"
                 r"Per la preparazione|Per l'esame|Per approfondimenti|Per ulteriori|In caso|Qualora|Ove|Sono|È |E' |"
                 r"Il manuale è|L'eventual|Eventual|Il materiale|Lo studente|Gli studenti")
_RE_INIZIO_PROSA = re.compile(rf"(?<=[.;!?)\d])\s+(?:[–-]\s+)?(?=(?:{_INIZIO_PROSA}))")
# nuova citazione che comincia con l'autore (iniziale + cognome) dopo la fine di quella precedente (anno o punto)
_INIZIALI = r"(?:[A-ZÀ-Ý]\.\s?){1,3}[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+"
_RE_NUOVA_CIT = re.compile(rf"(?:(?<=(?:19|20)\d\d[.,;])|(?<=[a-zà-ÿ)\"”]\.)|(?<=[;]))\s+(?={_INIZIALI})")
_RE_MARCATORE = re.compile(r"(?<=[.;)\d])\s*(?=(?:-\s?[A-ZÀ-Ý“\"«]|•|\d{1,2}\)\s|\(?[a-z]\)\s|\[\d{1,2}\]))|"
                           r"(?<=\S)\s+(?=-[A-ZÀ-Ý“\"«])")
_NUOVA_VOCE = re.compile(r"^\s*(?:[-•*·–▪●]|\d{1,2}[.)]|\[\d{1,2}\]|\(\d{1,2}\)|[a-z][.)])\s*")
_FRAMMENTO = re.compile(r"(?i)^(?:\(?\s*(?:cap|capp|capitol[oi]|pp?|pagg?|parte|parti|sez|vol|volume|ultima|ult|nuova|"
                        r"ed|edizione|anno|ristampa|e|ed anche|oppure|o|and|or|cfu|modulo|per)\b[\s.:,]*[\d\w.,\-–() ]{0,25}\)?\.?$)")
_ETICHETTA_SOLA = re.compile(
    r"(?i)^(?:modulo[\w\s]*|parte\s+\w+|cfu\b.*|\d+\s*cfu.*|per i? ?(?:non )?frequentanti|studenti\b.*|"
    r"(?:testi?|libri?|bibliografia|letture)\b[\w\s']*|un testo a scelta.*|due (?:testi|volumi).*|"
    r"un (?:testo|volume) a scelta.*|a scelta.*|in alternativa|oppure|alternativamente)\s*[:\-–]*$")


def _testo(s: str) -> str:
    s = html.unescape(html.unescape(s or ""))
    s = re.sub(r"(?i)<\s*(?:br|/p|/li|/div|/h\d|/tr)\s*/?>", "\n", s)
    s = re.sub(r"(?i)<\s*li[^>]*>", "\n- ", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = s.replace("\xa0", " ").replace("​", "").replace(" ", " ")
    return s


def _solo_nomi(p: str) -> bool:
    return all(re.fullmatch(r"[A-ZÀ-Ý][A-Za-zà-ÿ'’.\-]*", w) or w.lower() in ("e", "and", "&", "de", "di", "van")
               for w in re.split(r"[\s,;]+", p) if w)


def _senza_parentesi(p: str) -> str:
    return re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", p)


def _segni(p: str) -> bool:
    """La voce ha i segni di un riferimento bibliografico."""
    if YEAR.search(p) or _ISBN_T.search(p) or _SEGNO_EDITORE.search(p):
        return True
    return bool(re.match(rf"^\W*{_INIZIALI}", p) or re.match(r"^\W*[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+,\s*[A-ZÀ-Ý]\.", p)
                or re.match(r"^\W*[A-ZÀ-Ý][A-Za-zà-ÿ'’\-]+\s+[A-ZÀ-Ý]\.(?:,|\s)", p)) \
        and len(p.split()) >= 4


def e_prosa(cit: str) -> bool:
    """Voce del riconoscimento comune che non è un libro: indicazioni sul materiale senza anno, ISBN o editore."""
    c = (cit or "").strip()
    if c.endswith(":"):
        return True
    return bool(_PROSA.search(_senza_parentesi(c))) and not (YEAR.search(c) or _ISBN_T.search(c) or _SEGNO_EDITORE.search(c))


def _libro(p: str) -> bool:
    if not (14 <= len(p) <= 450) or _FRAMMENTO.match(p) or _ETICHETTA_SOLA.match(p):
        return False
    if re.match(r"(?i)^isbn", p) or p.count(")") > p.count("("):
        return False  # frammento di una citazione spezzata
    if len(re.sub(r"\([^)]*\)?", " ", p).split()) < 4 and not re.match(rf"^\W*{_INIZIALI}", p):
        return False
    if len(re.sub(r"\([^)]*\)?", " ", p).split()) < 3:
        return False
    if re.match(r"^[a-zà-ÿ]", p) and not re.match(r"(?i)^(?:de|di|del|della|van|von|le|la|el|al|da|dos)\b", p):
        return False  # frammento che continua una citazione
    senza = _senza_parentesi(p)
    # con un segno deciso di riferimento (ISBN, editore, anno) bastano le parole di prosa «forti»: nei titoli
    # compaiono «prova», «esame», «materiali», «contenuti»…
    deciso = bool(YEAR.search(p) or _ISBN_T.search(p) or _SEGNO_EDITORE.search(p))
    if (_PROSA_FORTE if deciso else _PROSA).search(senza):
        return False
    if not _segni(p):
        return False
    if not p.isupper() and _solo_nomi(p) and not YEAR.search(p):
        return False  # solo autori: manca il titolo
    return True


_RE_ALTERNATIVA = re.compile(r"(?i)[,;]?\s+(?:-\s*)?(?:oppure|in alternativa|ovvero)(?:\s*-)?\s+")
_RE_CONTINUA = re.compile(r"^(?:(?:19|20)\d\d\b|pp?\.\s?\d|[a-zà-ÿ(]|[0-9]+\b)")
_RE_PREFISSO_PROSA = re.compile(r"^([^:]{3,160}):\s+(\S.{12,})$")


def _righe_logiche(t: str) -> list[tuple[str, bool]]:
    """Righe del testo; una riga che continua la precedente (parentesi aperta, comincia con l'anno,
    con «pp.» o con una minuscola) è unita ad essa. (riga, è_nuova_voce_puntata)"""
    out: list[list] = []
    for riga in t.splitlines():
        r = re.sub(r"[ 	]+", " ", riga).strip()
        if not r:
            out.append(["", False])
            continue
        puntata = bool(_NUOVA_VOCE.match(r))
        prec = out[-1][0] if out else ""
        if prec and not puntata and (prec.count("(") > prec.count(")") or _RE_CONTINUA.match(r))                 and not prec.endswith(":"):
            out[-1][0] = prec + " " + r
        else:
            out.append([r, puntata])
    return [(r, p) for r, p in out if r]


_CODA = re.compile(r"(?i)[,;]?\s+(?:o altro|o altri|o un altro|ovvero altro)\b.*$|\s+(?:È|E')\s+indispensabile.*$")
_RE_TRATTINO = re.compile(r"\s[-–]\s+(?=[A-ZÀ-Ý“\"«])")


def _pezzi(p: str) -> list[str]:
    """Una voce con più citazioni unite da « - » (ciascuna con editore o anno) si divide; si toglie la coda
    «o altro manuale a scelta»."""
    p = _CODA.sub("", p).strip(" .;,-–")
    parti = _RE_TRATTINO.split(p)
    if len(parti) > 1 and (all(_SEGNO_EDITORE.search(x) or YEAR.search(x) for x in parti)
                           or any(_PROSA_FORTE.search(x) for x in parti[:-1] + parti[-1:])
                           and any(_SEGNO_EDITORE.search(x) or YEAR.search(x) for x in parti)):
        return [x.strip(" .;,-–") for x in parti]
    return [p]


def _voci(testo: str) -> list[tuple[str, str | None]]:
    """[(voce, tipo dichiarato dall'etichetta che la precede)]"""
    t = _testo(testo)
    t = _RE_MARCATORE.sub("\n", t)
    out: list[tuple[str, str | None]] = []
    tipo_ctx: str | None = None
    for r, _ in _righe_logiche(t):
        r = _NUOVA_VOCE.sub("", r)
        et = _ETICHETTA.match(r)
        if et:
            tipo_ctx = _tipo(et.group(0)) or tipo_ctx
            r = r[et.end():].strip()
        elif r.endswith(":") and len(r.split()) <= 10:  # intestazione di un elenco
            tipo_ctx = _tipo(r)
            continue
        elif re.match(r"(?i)^(?:per|nel caso|ai fini|gli studenti|studenti)\b.*:$", r):
            tipo_ctx = None
            continue
        else:
            m = _RE_PREFISSO_PROSA.match(r)
            if m and (_PROSA.search(m.group(1)) or (len(m.group(1).split()) <= 10 and re.match(
                    r"(?i)(?:per|nel|ai|gli|le|lo|i|il|studenti)\b", m.group(1)))):
                # «Si segnala, a titolo esemplificativo: Raymond Murphy, …», «Per tutti indistintamente: L. del …»
                tipo_ctx = _tipo(m.group(1)) or tipo_ctx
                r = m.group(2)
        if not r:
            continue
        for blocco in _RE_INIZIO_PROSA.split(r):
            for alt in _RE_ALTERNATIVA.split(blocco):
                for sp in _RE_NUOVA_CIT.split(alt):
                    for p in re.split(r";\s+", sp):
                        p = p.strip(" .;,-–*\"'•")
                        if not p:
                            continue
                        # «…; EdiSES Edizione»: l'editore staccato dal punto e virgola torna alla voce precedente
                        if out and len(p.split()) <= 3 and _SEGNO_EDITORE.search(p) and not YEAR.search(p)                                 and not _segni(out[-1][0]):
                            out[-1] = (out[-1][0] + "; " + p, out[-1][1])
                        else:
                            out.extend((x, tipo_ctx) for x in _pezzi(p) if x)
    return out


def libri_unich(sy: dict) -> list[dict]:
    libri, viste = [], set()
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if not (isinstance(v, str) and re.search(r"(^|_)testi_it$", k)):
                continue
            for p, tipo_ctx in _voci(v):
                if not _libro(p):
                    continue
                cit = re.sub(r"\s+", " ", p).strip()
                chiave = re.sub(r"\W+", "", cit.lower())[:120]
                if chiave in viste:
                    continue
                viste.add(chiave)
                anni = YEAR.findall(cit)
                libri.append({
                    "titolo": cit[:300], "autori": None, "editore": None,
                    "anno": int(anni[-1]) if anni else None, "edizione": None, "isbn": _isbn(cit), "lingua": None,
                    "tipo": _tipo(cit) or tipo_ctx, "note": None, "citazione": cit,
                })
    return libri
