"""Normalizzazioni sicure dei dati di un ateneo, applicate da build_db.py prima di scrivere
database/corsi/<ateneo>.json. Non aggiungono dati: uniformano, tolgono il rumore evidente e
scartano ciò che è certamente sbagliato (vedi verifica_db.py per i controlli).

- periodo: "Primo Ciclo Semestrale", "I semestre", "P" (UniBo), … → "1"; "Ciclo Annuale Unico",
  "Annualità singola", … → "annuale"; i codici con le date del periodo si risolvono dalle date;
- testi: entità HTML anche doppie (&amp;#39;), tag rimasti, caratteri rovinati da una doppia
  codifica (Ã¨ → è) e spazi;
- docenti: segnaposto ("Docente Fittizio", "Da Definire", "Docente Non Definito") tolti, titoli
  (Prof., Prof.ssa, Dott.) tolti dal nome;
- libri: ISBN con cifra di controllo errata → null (la citazione resta), anni futuri → null,
  frammenti senza titolo ("Carocci, 2019.") e righe di prosa senza editore né anno tolti,
  ripetizioni nello stesso insegnamento tolte; le citazioni in testo libero con tutta la
  citazione nel titolo si scompongono in autori, titolo, editore e anno quando la forma è
  chiara (`_scomponi`);
- esami: date ripetute nello stesso insegnamento tolte;
- anno di corso oltre la durata (piani part-time del Course Catalogue): l'insegnamento si toglie se
  c'è già lo stesso insegnamento con un anno valido, altrimenti l'anno diventa null.
"""
from __future__ import annotations

import datetime as dt
import html
import json
import re
import unicodedata

SEM1 = re.compile(r"(?i)^(primo|1\s*°?|i)\s*(ciclo\s+)?(semestr|ciclo semestrale)|^(s1|sem\.?\s*1|1st semester|first semester|"
                  r"semestre\s*(1|i|primo))\b|^primo ciclo semestrale$")
SEM2 = re.compile(r"(?i)^(secondo|2\s*°?|ii)\s*(ciclo\s+)?(semestr|ciclo semestrale)|^(s2|sem\.?\s*2|2nd semester|"
                  r"second semester|semestre\s*(2|ii|secondo))\b|^secondo ciclo semestrale$")
ANNUALE = re.compile(r"(?i)^(ciclo annuale( unico)?|annualit[àa]( singola)?( (i|ii|iii|iv|v|vi) anno)?|annuale|annual|"
                     r"attivit[àa] a durata annuale|intero anno|anno intero|year|yearly|full year|i e ii semestre|"
                     r"1 e 2 semestre|primo e secondo semestre)$")
SENZA_PERIODO = re.compile(r"(?i)^(undefined|non definito|--+|-|n\.?d\.?|periodo fittizio.*|periodo non specificat\w*)$")
MOJIBAKE = re.compile(r"Ã.|â€|Â")
PLACEHOLDER = re.compile(r"(?i)(fittizi[oa]|to be defined|codocenza|non definit[oa]|da definire|da nominare|da assegnare|"
                         r"da inserire|non assegnat[oa]|provvisori[oa]|tbd|tba|n\.?\s?d\.?)\b|"
                         r"^docente\b(?!\s+[A-Z][a-z])|^docente\s+(csal|vacante|esterno)$")
CODA_DOCENTE = re.compile(r"\s*(?:Scroll to top\b.*|Class(?:e/i| group/s)\b.*|PAGEREF\b.*|\(\s*codocenza\s*\).*)$",
                          re.I | re.S)
TITOLI = re.compile(r"^(?:prof\.?(?:ssa)?|professor(?:essa)?|dott\.?(?:ssa)?|dr\.?|ing\.?|avv\.?)\s+", re.I)
NON_LIBRO = re.compile(r"(?i)^(il voto|la prova|l'esame|esame|modalit|ricevimento|orario|prerequisit|obiettiv|"
                       r"risultati di apprendimento|lo studente|gli studenti|il corso|le lezioni|frequenza|"
                       r"durante il corso|metodi didattici|valutazione)\b")
EDITORE_O_ANNO = re.compile(r"\b(1[5-9]\d\d|20[0-4]\d)\b|(?i:\b(?:editore|edizioni|press|zanichelli|mulino|carocci|"
                            r"laterza|giappichelli|cedam|giuffr\w*|pearson|mcgraw|springer|wiley|elsevier|hoepli|"
                            r"utet|franco ?angeli|edises|einaudi|mondadori|feltrinelli|egea|isbn)\b)")
# doppie codifiche rimaste dopo che il nome è stato messo in maiuscolo/minuscolo (il passaggio inverso
# cp1252 → UTF-8 non funziona più): le sequenze più comuni
RESTI = [("Ã¨", "è"), ("Ã©", "é"), ("Ã²", "ò"), ("Ã¹", "ù"), ("Ã¬", "ì"), ("Ã€", "À"), ("ã€", "à"),
         ("â€™", "’"), ("Â€™", "’"), ("â€“", "–"), ("Â€“", "–"), ("â€œ", "“"), ("â€\x9d", "”"), ("Ã ", "à "),
         ("â€", "”")]  # (ultima: virgolette chiuse il cui terzo byte è andato perso)


def testo(s: str | None) -> str | None:
    if s is None:
        return None
    t = s
    for _ in range(3):  # entità doppie: &amp;#39; → &#39; → '
        u = html.unescape(t)
        if u == t:
            break
        t = u
    if MOJIBAKE.search(t):
        try:
            t = t.encode("cp1252").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            for a, b in RESTI:
                t = t.replace(a, b)
            t = re.sub(r"(?<=[a-z])Â(?=[\s,.;:)]|$)", "à", t)  # "sensorialitÂ" (-ità)
    t = re.sub(r"<\s*/?\s*(?:br|p|span|div|strong|em|a|li|ul|b|i|u|sup|sub)\b[^>]*>", " ", t, flags=re.I)
    t = re.sub(r"[ \t ]+", " ", t).strip()
    return t


def isbn_valido(s: str) -> bool:
    d = re.sub(r"[^0-9Xx]", "", s or "")
    if len(d) == 13 and d.isdigit():
        return sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(d)) % 10 == 0
    if len(d) == 10 and d[:9].isdigit():
        return sum((10 - i) * (10 if c in "Xx" else int(c)) for i, c in enumerate(d)) % 11 == 0
    return False


def _data(s: str | None, con_ora: bool = False) -> dt.date | None:
    if con_ora:  # «22/02/2027 00:00:00»
        s = re.sub(r"[ T]\d{1,2}:\d{2}(:\d{2})?$", "", s or "")
    m = re.match(r"(\d{2})/(\d{2})/(\d{4})$", s or "") or re.match(r"(\d{4})-(\d{2})-(\d{2})$", s or "")
    if not m:
        return None
    a, b, c = m.groups()
    try:
        return dt.date(int(c), int(b), int(a)) if len(a) == 2 else dt.date(int(a), int(b), int(c))
    except ValueError:
        return None


def _semestre_da_date(inizio, fine, con_ora: bool = False) -> str | None:
    """Semestre dalle date del periodo didattico (vale anche per cicli, trimestri e quadrimestri)."""
    a, b = _data(inizio, con_ora), _data(fine, con_ora)
    if not a or not b or b <= a:
        return None
    if (b - a).days > 180:
        return "annuale"
    meta = a + (b - a) / 2
    return "1" if meta.month in (8, 9, 10, 11, 12, 1) else "2"


def _semestre_dichiarato(p, inizio, fine) -> str | None:
    """Semestre scritto nel periodo quando le date coprono più di un semestre: il testo
    («Primo Semestre», «2 SEMESTRE …») vale sempre; il codice "1"/"2", che in alcuni atenei è un
    ciclo, vale se correggendo di un anno la data di inizio o di fine il periodo torna un
    semestre (si usano quelle date), oppure se le date non dicono altro."""
    if p is None:
        return None
    t = str(p).strip()
    if re.fullmatch(r"[1-6]° periodo", t):  # ciclo dichiarato dalla scheda (UniTo, corsi a distanza)
        return t
    if t in ("1", "2"):
        a, b = _data(inizio), _data(fine)
        if a and b:
            try:
                prove = ((a.replace(year=a.year + 1), b), (a, b.replace(year=b.year - 1)))
            except ValueError:  # 29 febbraio
                prove = ()
            for a2, b2 in prove:
                if a2 < b2 and (b2 - a2).days <= 180:
                    meta = a2 + (b2 - a2) / 2
                    return "1" if meta.month in (8, 9, 10, 11, 12, 1) else "2"
        return t
    if ANNUALE.search(t) or re.search(r"(?i)\b(primo|i|1)\b.{0,4}\be\b.{0,4}\b(secondo|ii|2)\b", t):  # «I e II semestre»
        return None
    if SEM1.search(t) or re.search(r"(?i)\bprimo\s+semestre\b|\bi\s+semestre\b", t):
        return "1"
    if SEM2.search(t) or re.search(r"(?i)\bsecondo\s+semestre\b|\bii\s+semestre\b", t):
        return "2"
    return None


def periodo(p, inizio=None, fine=None):
    """"1" | "2" | "annuale" (il semestre, come lo usa l'app) o None.

    Le date del periodo, se pubblicate, prevalgono sul codice: in molti atenei "1".."4" sono
    cicli o trimestri (UniBo: "2" = novembre-dicembre, primo semestre). Senza date restano i
    codici numerici e il testo riconosciuto; le sigle senza date (UniBo "T" tirocinio, "O"/"Z"
    prova finale, "CT1" …) diventano None.
    """
    if p is None and not (inizio and fine):
        return None
    da_date = _semestre_da_date(inizio, fine)
    if da_date == "annuale":
        # date di un anno intero accanto a un semestre dichiarato: refuso nell'anno della legenda
        # (UniBo «2: 22/02/2026 - 04/06/2027»), segnaposto del catalogo (Cineca «Annualità singola»
        # 21/09-22/05) o calendario lungo (UniVR «2 SEMESTRE PROFESSIONI SANITARIE dal 07/01 al 30/09»)
        esplicito = _semestre_dichiarato(p, inizio, fine)
        if esplicito:
            return esplicito
    if da_date:
        return da_date
    if p is None or p in ("1", "2", "3", "4", "annuale"):
        return p
    t = str(p).strip()
    if SEM1.search(t):
        return "1"
    if SEM2.search(t):
        return "2"
    if ANNUALE.search(t):
        return "annuale"
    if SENZA_PERIODO.search(t):
        return None
    if re.search(r"(?i)\bprimo\s+semestre\b|\b1\s*°?\s*semestre\b|\bi\s+semestre\b", t):  # «Primo Periodo - Primo Semestre»
        return "1"
    if re.search(r"(?i)\bsecondo\s+semestre\b|\b2\s*°?\s*semestre\b|\bii\s+semestre\b", t):
        return "2"
    if re.search(r"(?i)annual", t):  # «Ciclo Annuale Unico posticipato», «… Breve»
        return "annuale"
    parti = [x.strip() for x in t.split(",") if x.strip()]
    if len(parti) > 1 and set(parti) <= {"1", "2"}:  # moduli in semestri diversi
        return "annuale" if len(set(parti)) == 2 else parti[0]
    if re.fullmatch(r"[A-Z]{1,3}\d?(?:,[A-Z0-9]{1,3}\d?)*", t):  # sigla senza date: periodo non noto
        return None
    # bimestri, trimestri, quadrimestri e «periodi» numerati: con le date (anche «22/02/2027 00:00:00») si dice in quale
    # semestre cadono; senza date il testo resta com'è (l'app lo mostra così)
    if re.search(r"(?i)bimestr|trimestr|quadrimestr|trimester|quadrimester|\bperiodo\b|\bperiodi\b", t) and not re.search(
            r"(?i)intensiv|non specificat", t):
        d = _semestre_da_date(inizio, fine, con_ora=True)
        if d:
            return d
    return t


def docenti(lst):
    out = []
    for d in lst or []:
        d = testo(d) or ""
        d = CODA_DOCENTE.sub("", d)
        d = TITOLI.sub("", d).strip(" ,;")
        if d.isupper():  # "FRANCESCO PERRINI" → "Francesco Perrini"
            d = re.sub(r"(^|[\s'’-])(\w)(\w*)", lambda m: m.group(1) + m.group(2) + m.group(3).lower(), d)
        if not d or PLACEHOLDER.search(d):
            continue
        if d not in out:
            out.append(d)
    return out


# --- rifinitura delle liste di libri (agente F, 17/10/2026) -------------------------------------
# Correzioni trovate confrontando un campione con le schede ufficiali: citazioni spezzate a
# meta' dal ritorno a capo del PDF o della pagina, elenchi puntati incollati in un solo libro,
# righe che non sono libri (segnaposto, indirizzi web, materiali del docente, frasi di obiettivi),
# caratteri invisibili e "non obbligatorio" registrato come obbligatorio.
INVISIBILI = re.compile("[\u200b\u200e\u200f\u202a-\u202e\u2060\ufeff]")
CONTROLLO = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f]")


def testo_spostato(s: str) -> str:
    """Testo copiato da un PDF con il font \u00abspostato\u00bb (spazio = 0x03, \u00abQHOOD\u00bb = \u00abnella\u00bb, \u00ab\u00b6\u00bb =
    apostrofo): ogni carattere torna leggibile aggiungendo 29 al codice. Solo se il testo \u00e8 fatto
    quasi tutto cos\u00ec (almeno tre \u00abspazi\u00bb 0x03 e un decimo di caratteri di controllo)."""
    if s.count("\x03") < 3 or sum(1 for ch in s if ord(ch) < 32) * 10 < len(s):
        return s
    return "".join(chr(ord(ch) + 29) if ord(ch) < 32 or 33 <= ord(ch) <= 93 else ch for ch in s).replace("\u00b6", "\u2019")
PUNTI_ELENCO = re.compile("\\s*[\uf0a7\uf0b7\uf0d8\uf0fc\uf076\uf0a8]\\s*")
ENUMERATORE_P = re.compile(r"(?<=[.;,)\w])\s+(?=\d{1,2}\)\s+[A-ZÀ-Ý“\"'‘«])")
ENUMERATORE_N = re.compile(r"(?<=[.;,)\w])\s+(?=\d{1,2}\.\s+[A-ZÀ-Ý“\"'‘«])")
SEGNAPOSTO = re.compile(r"(?i)^\s*autor[ei]\W+titolo\W+editore\W+anno")
NON_LIBRO_MATERIALI = re.compile(
    r"(?i)^\W*(?:tutti i materiali|i materiali|il materiale|materiale didattico|materiali didattici|"
    r"nel corso delle lezioni|durante le lezioni|dispense?|slides?|appunti|presentazioni|lucidi)\b")
CODA_DI_CITAZIONE = re.compile(r"(?i)^(?:ed|edn|vol|voll|volume|pp|cap|capp)[.,]")
PROSA_OBIETTIVO = re.compile(
    r"(?i)^\W*(?:per le lezioni|per l'esame|per la preparazione|si consiglia|si rimanda|verranno|saranno|sar[àa] |"
    r"il docente|la docente|utilizzare|comprendere|conoscere|saper[ei]?|essere in grado|acquisire|riconoscere|"
    r"capacit[àa] di|lo studente|gli studenti|il corso|l'insegnamento|al termine)\b")
NEGAZIONE_OBBLIGO = re.compile(
    r"(?i)\bnon\s+(?:è\s+|sono\s+|risulta\s+)?obbligator\w*|\bnon\s+obb\b|\bnot\s+(?:mandatory|compulsory|required|obligatory)\b|"
    r"\bfacoltativ\w*|\bnon\s+(?:è\s+)?richiest\w*")
APERTA_IN_FONDO = re.compile(
    r"(?i)(?:[,:;(\-–—/&“\"‘«\[]|\b(?:e|di|del|della|dei|degli|and|of|the|in|per|a cura di|volume|vol\.?|tomo|parte|"
    r"capitolo|cap\.?|capp\.?|pagg?\.?|pp\.?|n\.|con))\s*$")
FRAMMENTO_EDITORIALE = re.compile(r"(?i)^\W*(?:(?:isbn|ean)\W*(?:10|13)?\W*[0-9Xx\- ]{9,17}\W*)+$")
URL = re.compile(r"https?://\S+|www\.\S+")


def _senza_url(t: str) -> str:
    return URL.sub(" ", t or "")


def _bilanciata(t: str) -> bool:
    return (t.count("(") == t.count(")") and t.count("[") == t.count("]") and t.count("“") == t.count("”")
            and t.count("«") == t.count("»") and t.count('"') % 2 == 0)


def _cit(lb: dict) -> str:
    return (lb.get("citazione") or lb.get("titolo") or "").strip()


def _nuovo_libro(base: dict, cit: str) -> dict:
    """Libro non scomposto con la citazione `cit` (titolo = citazione; il resto si ricalcola)."""
    cit = re.sub(r"\s+", " ", cit).strip()
    anni = set(re.findall(r"\b(19[5-9]\d|20[0-4]\d)\b", cit))
    isbn = None
    m = re.search(r"\b(97[89][- ]?\d[-\d ]{8,13}\d|\d{9}[\dXx])\b", cit)
    if m:
        d = re.sub(r"[^\dXx]", "", m.group(1)).upper()
        isbn = d if len(d) in (10, 13) else None
    lb = dict(base)
    lb.update({"titolo": cit, "citazione": cit, "autori": None, "editore": None, "edizione": None,
               "anno": int(anni.pop()) if len(anni) == 1 else None, "isbn": isbn or base.get("isbn")})
    return lb


def _struttura(lb: dict) -> bool:
    """Libro gia' scomposto dall'ateneo (Titolo:/Autori:/...): non si tocca."""
    return bool(lb.get("autori")) and lb.get("titolo") != lb.get("citazione")


def _spezza(cit: str) -> list[str]:
    """Punti elenco (U+F0A7, ...) e numerazione «1) ... 2) ...» (o «1. ... 2. ...») incollati in una sola citazione."""
    parti = [x for x in PUNTI_ELENCO.split(cit) if x.strip()]
    if len(parti) > 1:
        return parti
    for pat, sep, richiede_uno in ((ENUMERATORE_P, r")", False), (ENUMERATORE_N, r".", True)):
        if richiede_uno and not re.match(r"\s*1\.\s", cit):
            continue
        sub = pat.split(cit)
        if len(sub) < 2:
            continue
        nums = []
        for x in sub:
            m = re.match(r"\s*(\d{1,2})" + re.escape(sep) + r"\s", x)
            nums.append(int(m.group(1)) if m else -1)
        if nums[0] == -1 and len(sub[0]) >= 20:  # «Titolo A ... 2) Titolo B»: il «1)» iniziale era già stato tolto
            nums[0] = 1
        if nums == list(range(1, len(sub) + 1)):
            return [re.sub(r"^\s*\d{1,2}" + re.escape(sep) + r"\s+", "", x) for x in sub]
    return [cit]


_INIZIO_EDITORIALE = re.compile(
    r"(?i)^\W*(?:ed\.|editore|edizioni|casa editrice|ristampa|pp?\.|isbn|ean|vol\.|voll\.|\d{1,4}\b|[IVX]{1,5}\b)")


def _ha_editore(t: str) -> bool:
    from adapters.testi import _EDITORI_CIT
    return bool(_EDITORI_CIT.search(t))


def _inizia_come_continuazione(cit: str, forte: bool = True) -> bool:
    """La riga non comincia come un nuovo riferimento (autore) ma come il seguito di uno.
    `forte`: il riferimento precedente non ha ancora un editore (un titolo in minuscolo lo continua)."""
    if not cit:
        return False
    if cit[:1] in "”’»)]–—-,;:.0123456789":
        return True
    if cit[:1].islower():
        return forte
    if _INIZIO_EDITORIALE.match(cit):
        return True
    from adapters.testi import _CITTA, _EDITORI_CIT
    prima = re.split(r"[,.;:]", cit, 1)[0].strip().lower()
    if prima in _CITTA:
        return True
    if not forte:
        return False
    m = _EDITORI_CIT.match(cit)  # editore all'inizio (Einaudi, Torino, 2005.)
    return bool(m) and not re.match(r"^\s*[A-ZÀ-Ý][\w'’\-]+,\s+[A-ZÀ-Ý]\.?\s", cit)


def _aperte(t: str) -> int:
    """Virgolette e parentesi aperte e non chiuse."""
    return max(0, t.count("“") - t.count("”")) + max(0, t.count("«") - t.count("»")) + max(0, t.count("(") - t.count(")"))


def _chiusura_orfana(cit: str) -> bool:
    """Una virgoletta di chiusura prima di qualunque virgoletta di apertura."""
    for ch in cit:
        if ch in "”»":
            return True
        if ch in "“«":
            return False
    return False


ISBN_RIPETUTO = re.compile(r"((?:\s|^)(?:ISBN|EAN)(?:-1[03])?[\s:]*[\dXx][\dXx -]{8,16}[\dXx])(?:\1)+")


def rifinisci_libri(lst: list[dict]) -> list[dict]:
    """Spezza i libri incollati, unisce le citazioni spezzate, toglie cio' che non e' un libro."""
    pezzi: list[dict] = []
    for lb in lst or []:
        if any(isinstance(lb.get(k), str) and CONTROLLO.search(lb[k]) for k in ("titolo", "citazione", "note")):
            # testo dei PDF con il font spostato o caratteri di controllo rimasti (« Einführungs\x02buch »)
            lb = dict(lb)
            for k in ("titolo", "citazione", "note"):
                if isinstance(lb.get(k), str):
                    lb[k] = CONTROLLO.sub("", testo_spostato(lb[k]))
        if any(isinstance(lb.get(k), str) and ISBN_RIPETUTO.search(lb[k]) for k in ("titolo", "citazione")):
            # «… ISBN: X ISBN: X ISBN: X»: la riga dell'ISBN unita più volte da ricostruzioni precedenti
            lb = dict(lb)
            for k in ("titolo", "citazione"):
                if isinstance(lb.get(k), str):
                    lb[k] = ISBN_RIPETUTO.sub(r"\1", lb[k])
        cit = INVISIBILI.sub("", _cit(lb))
        if not cit:
            continue
        if _struttura(lb):
            pezzi.append(lb)
            continue
        parti = _spezza(cit)
        if len(parti) > 1:
            pezzi.extend(_nuovo_libro(lb, x) for x in parti)
        elif cit != _cit(lb):
            lb = dict(lb)
            for k in ("titolo", "citazione", "note"):
                if isinstance(lb.get(k), str):
                    lb[k] = INVISIBILI.sub("", lb[k])
            pezzi.append(lb)
        else:
            pezzi.append(lb)
    out: list[dict] = []
    for lb in pezzi:
        cit = _cit(lb)
        prec = out[-1] if out else None
        unisci = False
        if prec is not None and FRAMMENTO_EDITORIALE.match(cit) and not FRAMMENTO_EDITORIALE.match(_cit(prec)):
            # riga con il solo codice ISBN/EAN: appartiene al libro che la precede (anche se già scomposto)
            nuovo = dict(prec)
            pc = _cit(prec)
            if cit in pc:  # già unita in una ricostruzione precedente (il contributo la ripropone a ogni giro)
                continue
            nuovo["citazione"] = pc + " " + cit
            if nuovo.get("titolo") == pc:
                nuovo["titolo"] = nuovo["citazione"]
            m = re.search(r"\b(97[89][- ]?\d[-\d ]{8,13}\d|\d{9}[\dXx])\b", cit)
            if m and not nuovo.get("isbn"):
                d = re.sub(r"[^\dXx]", "", m.group(1)).upper()
                if len(d) in (10, 13):
                    nuovo["isbn"] = d
            out[-1] = nuovo
            continue
        if prec is not None and not _struttura(prec) and not _struttura(lb) and len(cit) <= 120:
            pc = _cit(prec)
            completa = bool(re.search(r"\b(?:19|20)\d\d\b|ISBN|EAN", pc, re.I))
            if FRAMMENTO_EDITORIALE.match(cit) and not FRAMMENTO_EDITORIALE.match(pc):
                unisci = True
            elif (not completa and APERTA_IN_FONDO.search(pc)
                  and _inizia_come_continuazione(cit, forte=not _ha_editore(pc))
                  and len(re.findall(r"\b(?:19|20)\d\d\b", cit)) <= 1):
                unisci = True
            elif _chiusura_orfana(cit) and _aperte(pc) > 0:
                unisci = True
        if unisci:
            nuovo = _nuovo_libro(prec, _cit(prec) + " " + cit)
            nuovo["tipo"] = prec.get("tipo") or lb.get("tipo")
            out[-1] = nuovo
        else:
            out.append(lb)
    norm = [re.sub(r"\W+", "", _cit(x).lower()) for x in out]
    risultato = []
    for k, lb in enumerate(out):
        cit = _cit(lb)
        lettere = [ch for ch in _senza_url(cit) if ch.isalpha()]
        ha_isbn = bool(re.search(r"\b(?:97[89][- ]?\d|ISBN|EAN)", cit, re.I))
        if SEGNAPOSTO.match(cit) or CODA_DI_CITAZIONE.match(cit):
            continue
        if len(lettere) < 8 and not ha_isbn and not re.search(r"/dp/|/libro/|/product/|/book|isbn", cit, re.I):
            continue  # solo un indirizzo web generico o simboli
        if (not _struttura(lb) and not ha_isbn and PROSA_OBIETTIVO.match(cit) and not re.search(r"\d{4}", cit)
                and not _ha_editore(cit) and not re.search(r"[“«\"]|\b[A-Z]\.\s?[A-ZÀ-Ý][a-zà-ÿ]+", cit)):
            continue  # frase di obiettivi o istruzioni, senza alcun riferimento bibliografico
        if cit[:1].islower() and len(cit) >= 25:  # frammento gia' contenuto in un'altra citazione dello stesso insegnamento
            corpo = re.sub(r"\W+", "", re.sub(r"\([^)]*\)\W*$", "", cit).lower())[:40]
            if len(corpo) >= 20 and any(corpo in n and len(n) > len(norm[k]) for j, n in enumerate(norm) if j != k):
                continue
        if len(norm[k]) >= 25 and any(len(n) >= len(norm[k]) + 4 and n.endswith(norm[k]) for j, n in enumerate(norm) if j != k):
            continue  # coda ripetuta di un'altra citazione (es. «WG1 (2021), WG2 (2022)» dentro «IPCC - AR6 - WG1 (2021), …»)
        if lb.get("tipo") == "obbligatorio" and NEGAZIONE_OBBLIGO.search(cit + " " + (lb.get("note") or "")):
            lb = dict(lb)
            lb["tipo"] = "consigliato"
        risultato.append(lb)
    return risultato



def libri(lst, anno_max: int):
    out, viste = [], set()
    for lb in rifinisci_libri(lst or []):
        lb = dict(lb)
        for k in ("titolo", "autori", "editore", "citazione", "note", "edizione"):
            if isinstance(lb.get(k), str):
                lb[k] = testo(lb[k])
        if isinstance(lb.get("titolo"), str) and not re.search(r"\w", lb["titolo"]):
            lb["titolo"] = None  # «--», «-»: nessun titolo (resta la citazione, se c'è)
        cit = lb.get("citazione") or lb.get("titolo") or ""
        if not cit:
            continue
        ed = lb.get("editore")
        if isinstance(ed, str):  # «Editore: Giappichelli» → «Giappichelli»; «Il Mulino: parti I» → «Il Mulino»
            ed = re.sub(r"(?i)^(?:editore|publisher|casa editrice)\s*:\s*", "", ed).strip()
            m = re.match(r"^([^:]{3,40}):\s", ed)
            if m:
                from adapters.testi import _EDITORI_RE
                if _EDITORI_RE.search(m.group(1).lower()):
                    ed = m.group(1).strip()
            lb["editore"] = ed or None
        # frammento senza titolo ("Carocci, 2019.") o prosa che non cita un'opera
        if len(cit) < 20 and not re.search(r"[A-Za-zÀ-ÿ]{4,}\s+[A-Za-zÀ-ÿ]{4,}", re.sub(EDITORE_O_ANNO, "", cit)):
            continue
        if NON_LIBRO.search(cit) and not EDITORE_O_ANNO.search(cit):
            continue
        _scomponi(lb)
        if lb.get("isbn") and not isbn_valido(lb["isbn"]):
            lb["isbn"] = None
        if isinstance(lb.get("anno"), int) and not (1450 <= lb["anno"] <= anno_max):
            lb["anno"] = None
        k = re.sub(r"\W+", "", cit.lower())[:120]
        if k in viste:
            continue
        viste.add(k)
        out.append(lb)
    return out


def _scomponi(lb: dict) -> bool:
    """Libro con tutta la citazione nel titolo e senza autori (testo libero non
    scomposto: «C. Canuto, A. Tabacco. Analisi Matematica I. Pearson, 2021.», con
    l'editore spesso un pezzo di citazione): autori, titolo, editore e anno dalla
    citazione stessa, se la forma è chiara (`adapters.testi.scomponi_citazione`).
    La citazione resta com'è. True se il libro è cambiato."""
    from adapters.testi import scomponi_citazione

    cit = lb.get("citazione")
    if lb.get("autori") or not cit or lb.get("titolo") != cit:
        return False
    sc = scomponi_citazione(cit)
    if not sc:
        return False
    lb["autori"], lb["titolo"], lb["editore"] = sc["autori"], sc["titolo"], sc["editore"]
    if sc["anno"]:
        lb["anno"] = sc["anno"]
    return True


def scomponi_citazioni(corsi: list[dict]) -> int:
    """`_scomponi` su tutti i libri (anche quelli delle varianti). Restituisce il numero
    di libri scomposti."""
    n = 0
    for c in corsi:
        for i in c.get("insegnamenti") or []:
            for lb in (i.get("libri") or []) + [x for v in i.get("varianti") or [] for x in v.get("libri") or []]:
                n += _scomponi(lb)
    return n


ORA = re.compile(r"^(\d{1,2}):(\d{2})$")


def _ora(o):
    """Ora dell'appello «HH:MM»; None se manca o è impossibile per un esame («00:00»
    usato come «ora non indicata», «23:45» chiusura delle iscrizioni)."""
    m = ORA.match(str(o or "").strip())
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    return f"{h:02d}:{mi:02d}" if 6 <= h <= 21 and mi < 60 else None


def esami(lst, oggi: dt.date | None = None):
    """Appelli senza doppioni (stessa data, ora, tipo e luogo: i docenti si uniscono),
    con l'ora impossibile tolta e senza date non valide o assurde (es. anno 4017)."""
    oggi = oggi or dt.date.today()
    out, viste = [], {}
    for e in lst or []:
        e = dict(e)
        d = _data(e.get("data"))
        if d is None or d.year < 2000 or d > oggi.replace(year=oggi.year + 3):
            continue
        if "ora" in e:
            e["ora"] = _ora(e.get("ora"))
        k = (e.get("data"), e.get("ora"), e.get("tipo"), e.get("luogo"))
        if k in viste:
            prima = viste[k]
            d1, d2 = prima.get("docenti"), e.get("docenti")
            if isinstance(d1, list) and isinstance(d2, list):
                prima["docenti"] = d1 + [x for x in d2 if x not in d1]
            elif d2 and not d1:  # (a volte i docenti sono un testo)
                prima["docenti"] = d2
            continue
        viste[k] = e
        out.append(e)
    return out


def _unisci_doppi(ins: list[dict]) -> list[dict]:
    gruppi: dict[tuple, list[dict]] = {}
    for i in ins:
        gruppi.setdefault((i.get("anno"), (i.get("nome") or "").lower().strip(), i.get("curriculum")), []).append(i)
    via = set()
    for g in gruppi.values():
        completi = [i for i in g if i.get("codice")]
        vuoti = [i for i in g if not i.get("codice") and i.get("cfu") is None]
        if len(completi) != 1 or not vuoti:
            continue
        dest = completi[0]
        for v in vuoti:
            for k in ("docenti", "libri", "esami"):
                if v.get(k):
                    dest[k] = (dest.get(k) or []) + [x for x in v[k] if x not in (dest.get(k) or [])]
            via.add(id(v))
    return [i for i in ins if id(i) not in via]


def pulisci_corsi(corsi: list[dict], oggi: dt.date | None = None) -> None:
    """Modifica i corsi sul posto."""
    anno_max = (oggi or dt.date.today()).year + 1
    for c in corsi:
        durata = c.get("durata_anni")
        ins = c.get("insegnamenti") or []
        validi = {(i.get("nome") or "").lower() for i in ins
                  if isinstance(i.get("anno"), int) and (not durata or i["anno"] <= durata)}
        tenuti = []
        for i in ins:
            for k in ("nome", "curriculum"):
                if isinstance(i.get(k), str):
                    i[k] = testo(i[k])
            if durata and isinstance(i.get("anno"), int) and i["anno"] > durata:
                if (i.get("nome") or "").lower() in validi:
                    continue  # copia del piano part-time
                i["anno"] = None
            i["periodo"] = periodo(i.get("periodo"), i.get("periodo_inizio"), i.get("periodo_fine"))
            if "ssd" in i:
                i["ssd"] = ssd(i["ssd"])
            if "docenti" in i:
                i["docenti"] = docenti(i["docenti"])
            if "libri" in i:
                i["libri"] = libri(i["libri"], anno_max)
                if not i["libri"] and i.get("stato_libri") == "completo":
                    i["stato_libri"] = "da_aggiungere"
            if "esami" in i:
                i["esami"] = esami(i["esami"])
            tenuti.append(i)
        c["insegnamenti"] = _unisci_doppi(tenuti)


def repliche(corsi: list[dict]) -> int:
    """I corsi "… REPLICA <sede>" sono lo stesso corso di studio in un'altra sede, con lo stesso
    ordinamento: se sono vuoti ricevono la struttura del piano del corso principale (stesso nome
    e classe). Docenti, libri ed esami cambiano da sede a sede e restano vuoti."""
    principali = {}
    for c in corsi:
        if c.get("insegnamenti") and not re.search(r"(?i)\breplica\b", c["nome"]):
            principali.setdefault((c["nome"].strip().lower(), c.get("classe")), c)
    n = 0
    for c in corsi:
        m = re.match(r"(?i)(.*?)\s+replica\b", c["nome"])
        if not m or c.get("insegnamenti"):
            continue
        p = principali.get((m.group(1).strip().lower(), c.get("classe")))
        if not p:
            continue
        c["insegnamenti"] = [{
            **{k: i.get(k) for k in ("codice", "nome", "anno", "periodo", "periodo_inizio", "periodo_fine", "cfu", "ssd",
                                     "obbligatorio", "curriculum", "url", "fonte", "verificato_il")},
            "id": c["id"] + i["id"][len(p["id"]):] if i.get("id", "").startswith(p["id"]) else f"{c['id']}-{n}",
            "docenti": [], "libri": [], "stato_libri": "da_aggiungere", "esami": [], "stato_esami": "da_aggiungere",
        } for i in p["insegnamenti"]]
        if p.get("curricula") and not c.get("curricula"):
            c["curricula"] = p["curricula"]
        c["piano_da"] = p["id"]  # struttura copiata: build_db non vi aggancia gli appelli della sede principale
        n += 1
    return n


_INGLESE = re.compile(r"(?i)\b(in lingua inglese|english[- ]taught|taught in english|in english)\b")


def _ssd_base(s: str | None) -> str:
    """«10 cfu - MAT/05 (MATH-03/A)» → «MAT/05 (MATH-03/A)»."""
    return re.sub(r"^\s*\d+(?:[.,]\d+)?\s*cfu\s*-\s*", "", s or "", flags=re.I).strip().lower()


def _solo_inglese(curriculum: str | None, curricula: list[str] | None = None) -> bool:
    """L'insegnamento è soltanto del percorso in lingua inglese («Percorso in lingua inglese»),
    non di un elenco di percorsi tra cui quello inglese («Introductory year taught in English,
    Percorso, Primo anno sede di Mondovì»: è comune a tutti). I nomi dei percorsi del corso
    (`curricula`) servono quando contengono virgole («Political, Economic and Social Studies -
    in lingua inglese»)."""
    s = curriculum or ""
    if not _INGLESE.search(s):
        return False
    resto = s
    for nome in sorted(curricula or [], key=len, reverse=True):
        if nome and _INGLESE.search(nome):
            resto = resto.replace(nome, "")
    if resto != s:
        return not re.sub(r"[\s,;]+", "", resto)
    return all(_INGLESE.search(p) for p in percorsi(s))


# --- versioni italiana e inglese dello stesso insegnamento ------------------------------------

_IT_PAROLE = {"di", "e", "ed", "della", "delle", "del", "dei", "degli", "dello", "dell", "per", "la", "il",
              "lo", "le", "gli", "nel", "nella", "nelle", "nei", "negli", "nello", "nell", "con", "alla", "alle",
              "ai", "al", "allo", "all", "agli", "sul", "sulla", "sulle", "sui", "sull", "dal", "dalla", "dalle",
              "dai", "dall", "tra", "fra", "un", "una", "uno", "ad", "l"}
_EN_PAROLE = {"of", "and", "the", "for", "to", "with", "on", "an", "from", "by", "into", "at", "its"}
# parole inglesi: finale in consonante o -y (le parole italiane finiscono in vocale), alcuni
# suffissi, lettere e gruppi che l'italiano non usa
_EN_PAROLA = re.compile(r"(?:[bcdfghjklmnpqrstvwxyz]|ence|ance|age|ble|ise|ize)$|[kwy]|th|ph|sh")
# parti del nome che non sono il titolo: note tra parentesi («(Grandi Sfide - Digitale)»,
# «(modulo A)»), «Insegnamento a numero chiuso», «d.i. = 1 CFU …» (PoliMi), «- Intraprendenti»
_NOTE_NOME = re.compile(r"(?i)\([^)]*\)|\[[^\]]*\]|\binsegnamento a numero chiuso\b|\s+d\.i\..*$|"
                        r"\s+-\s+(?:intraprendenti|gyt)\s*$")


def _nome_base(nome: str | None) -> str:
    return re.sub(r"\s+", " ", _NOTE_NOME.sub(" ", nome or "")).strip()


def _lingua_nome(nome: str | None) -> str | None:
    """«en» / «it» dal nome dell'insegnamento (parole funzionali, accenti, finali delle
    parole), None se non si capisce («Design Studio 1»)."""
    s = _nome_base(nome).lower()
    parole = re.findall(r"[a-zàèéìòù]+", s)
    if not parole:
        return None
    if any(p in _IT_PAROLE for p in parole) or re.search(r"[àèéìòù]|[a-z][aeiou]'(?:\s|$)", s):
        return "it"
    if any(p in _EN_PAROLE for p in parole):
        return "en"
    lunghe = [p for p in parole if len(p) > 3]
    if not lunghe:
        return None
    quota = sum(bool(_EN_PAROLA.search(p)) for p in lunghe) / len(lunghe)
    if quota >= 0.6:
        return "en"
    if quota <= 0.25:
        return "it"
    return None


# titoli che non si traducono parola per parola: (italiano, traduzioni inglesi in uso)
_FRASI = [
    ("istituzioni di matematiche", ("calculus", "mathematics")),
    ("analisi matematica", ("mathematical analysis", "calculus")),
    ("fisica tecnica ambientale", ("building physics", "environmental technical physics")),
    ("fisica tecnica", ("engineering thermodynamics", "applied thermodynamics", "technical physics")),
    ("termodinamica applicata", ("engineering thermodynamics", "applied thermodynamics")),
    ("trasmissione del calore", ("heat transfer",)),
    ("basi di dati", ("databases", "database")),
    ("calcolatori elettronici", ("computer architecture", "computer architectures")),
    ("reti di calcolatori", ("computer networks",)),
    ("scienza delle costruzioni", ("structural mechanics", "strength of materials", "mechanics of structures")),
    ("meccanica strutturale", ("strength of materials", "structural mechanics")),
    ("tecnica delle costruzioni", ("structural engineering", "structural analysis and design", "structural design")),
    ("disegno tecnico industriale", ("engineering drawing", "technical drawing")),
    ("disegno tecnico", ("technical drawing", "engineering drawing")),
    ("meccanica applicata alle macchine", ("applied mechanics", "mechanics of machines")),
    ("costruzione di macchine", ("machine design",)),
    ("macchine a fluido", ("fluid machinery", "fluid machines")),
    ("scienza delle finanze", ("public economics", "public finance")),
    ("economia aziendale", ("business administration", "business economics")),
    ("economia politica", ("political economy", "economics")),
    ("politica economica", ("economic policy",)),
    ("diritto commerciale", ("business law", "commercial law")),
    ("lingua inglese", ("english language", "english")),
    ("medio oriente", ("middle east",)),
    ("calcolo delle strutture", ("structural analysis", "structural calculation")),
    ("programmazione di sistema", ("system and device programming", "system programming")),
    ("informatica", ("computer science", "computer sciences", "informatics", "computing")),
    ("urbanistica", ("urban planning", "town planning")),
    ("corso avanzato", ("advanced",)),
    ("corso base", ("",)),
]
# parole che non sono affini all'inglese (le affini, come sistemi/systems o
# elettronica/electronics, si riconoscono da sole)
_TRADUZIONI = {
    "reti": ("networks", "network"), "rete": ("network",), "calcolatori": ("computers", "computer"),
    "calcolatore": ("computer",), "progettazione": ("design", "planning"), "progetto": ("design", "project"),
    "progetti": ("projects", "project"), "fondamenti": ("fundamentals", "foundations"),
    "macchine": ("machines", "machinery"), "macchina": ("machine",), "lingua": ("language",),
    "inglese": ("english",), "livello": ("level",), "economia": ("economics", "economy", "business"),
    "aziendale": ("business", "corporate", "company"), "aziendali": ("business", "corporate", "company"),
    "diritto": ("law",), "costruzioni": ("construction", "structural", "structures", "buildings"),
    "costruzione": ("construction", "building"), "edifici": ("buildings", "building"),
    "calcolo": ("calculus", "computation", "computing"), "dati": ("data",), "elaborazione": ("processing",),
    "laboratorio": ("laboratory", "lab", "studio"), "laboratori": ("laboratories", "labs"), "atelier": ("studio",),
    "tirocinio": ("internship", "traineeship"), "storia": ("history",), "politica": ("policy", "politics"),
    "politiche": ("policies", "policy", "politics"), "gestione": ("management",),
    "impresa": ("business", "firm", "enterprise", "company", "corporate"),
    "imprese": ("business", "firms", "enterprises", "companies", "corporate"),
    "chimica": ("chemistry", "chemical"), "chimici": ("chemical",), "chimico": ("chemical",),
    "biochimica": ("biochemistry", "biochemical"), "disegno": ("drawing", "design"),
    "tecnica": ("technique", "practice", "technical", "engineering"),
    "tecnico": ("technical", "engineering"), "trasmissione": ("transmission", "transfer"), "calore": ("heat",),
    "ingegneria": ("engineering",), "produzione": ("production", "manufacturing"), "rilievo": ("survey",),
    "concezione": ("concept", "conception"), "sviluppo": ("development",), "lavoro": ("labour", "labor", "work"),
    "popolazione": ("population",), "umana": ("human",), "umano": ("human",), "cellule": ("cells",),
    "staminali": ("stem",), "regolazione": ("regulation",), "genica": ("gene", "genes"),
    "struttura": ("structure",), "strutture": ("structures",), "microonde": ("microwaves",),
    "componenti": ("components", "devices"), "elettrici": ("electrical", "electric", "power"),
    "elettriche": ("electrical", "electric", "power"), "sicurezza": ("safety", "security"),
    "restauro": ("conservation", "restoration"), "edilizia": ("building",), "storici": ("historical",),
    "storica": ("historical",), "storico": ("historical",), "impianti": ("plants", "plant", "systems"),
    "ricerca": ("research",), "strumenti": ("tools", "instruments"), "antiche": ("ancient",),
    "antico": ("ancient",), "riqualificazione": ("requalification", "regeneration", "retrofitting"),
    "valutazione": ("evaluation", "assessment", "valuation"), "esercizio": ("practice",),
    "tesi": ("thesis",), "volo": ("flight",), "bordo": ("onboard", "board"),
    "ragioneria": ("accounting",), "consumatori": ("consumers", "consumer"), "consumatore": ("consumer",),
    "comportamento": ("behavior", "behaviour"), "rischi": ("risks", "risk"), "rischio": ("risk",),
    "approccio": ("approach",), "sperimentale": ("experimental",), "religione": ("religion",),
    "misure": ("measurements", "measures"), "comportamentale": ("behavioral", "behavioural"),
    "sostenibile": ("sustainable",), "sostenibili": ("sustainable",), "sostenibilità": ("sustainability",),
    "giuridici": ("legal",), "giuridico": ("legal",), "giuridica": ("legal",), "giuridiche": ("legal",),
    "filosofia": ("philosophy",), "unione": ("union",), "pubblica": ("public",), "pubblico": ("public",),
    "mercati": ("markets",), "mercato": ("market",), "ispezione": ("inspection",), "metallici": ("metallic",),
    "contratti": ("contracts", "contract"), "stato": ("state",), "solido": ("solid",),
    "medicina": ("medicine",), "nucleare": ("nuclear",), "acque": ("water", "waters"), "terre": ("soil",),
    "modellazione": ("modeling", "modelling"), "modelli": ("models", "modelling", "modeling"),
    "avanzato": ("advanced",), "avanzata": ("advanced",), "avanzati": ("advanced",), "avanzate": ("advanced",),
}
# parole che possono mancare nella traduzione senza cambiare l'insegnamento
_OPZ_IT = {"fondamenti", "elementi", "introduzione", "principi", "istituzioni", "corso", "generale", "avanzato",
           "avanzata", "avanzati", "avanzate", "ingegneria"}  # «… per l'ingegneria» ↔ «…»
_OPZ_EN = {"introduction", "introductory", "fundamentals", "elements", "basics", "principles", "advanced",
           "early", "general"}
_STOP_TRAD = _IT_PAROLE | _EN_PAROLE | {"a", "i", "in", "&"}
_PREFISSI = ("micro", "macro", "inter", "intra", "intro", "multi", "trans", "super", "tele", "bio", "geo",
             "nano", "neuro", "psic", "socio", "idro", "termo", "elet")


def _norm_parola(p: str) -> str:
    p = p.translate(str.maketrans("àèéìòù", "aeeiou"))
    p = re.sub(r"(.)\1", r"\1", p)  # doppie
    for a, b in (("ph", "f"), ("th", "t"), ("ch", "c"), ("ck", "c"), ("ct", "t"), ("qu", "cu"),
                 ("k", "c"), ("y", "i"), ("x", "s"), ("zi", "ti")):
        p = p.replace(a, b)
    return p


_TRADUZIONI_N = {_norm_parola(k): v for k, v in _TRADUZIONI.items()}  # «sostenibilita'» = «sostenibilità»


def _affini(a: str, b: str) -> bool:
    """Parole affini (sistemi/systems, elettronica/electronics): stessa radice."""
    if a == b:
        return True
    n = 0
    while n < min(len(a), len(b)) and a[n] == b[n]:
        n += 1
    if n < 4 or n < -(-11 * min(len(a), len(b)) // 20):  # almeno il 55% della parola più corta
        return False
    return not any(a.startswith(p) and n <= len(p) + 1 for p in _PREFISSI)


_ROMANO = r"(?:i{1,3}|iv)"


def _segni(s: str) -> tuple:
    """Numeri e lettere di modulo del nome («I», «2», «1st», «… B»): devono coincidere."""
    out = re.findall(r"\b(\d+)(?:st|nd|rd|th|°)?\b", s)
    for r in re.findall(rf"\b({_ROMANO})\b(?=\s*(?:$|[-–/:,]|livello\b|level\b|modulo\b|module\b))", s):
        out.append(str({"i": 1, "ii": 2, "iii": 3, "iv": 4}[r]))
    m = re.search(r"(?:^|\s)([a-d])\s*$", s)  # «Tecnologia meccanica B»
    if m and len(s.split()) > 1:
        out.append("#" + m.group(1))
    return tuple(sorted(set(out)))


def _parole_trad(s: str) -> list[str]:
    s = re.sub(rf"\b\d+(?:st|nd|rd|th|°)?\b|\b{_ROMANO}\b(?=\s*(?:$|[-–/:,]|livello\b|level\b|modulo\b|module\b))",
               " ", s)
    s = re.sub(r"(?:^|\s)[a-d]\s*$", " ", s)
    return [p for p in re.findall(r"[a-zàèéìòù]+", s) if p not in _STOP_TRAD]


def _con_frasi(it: str, en: str) -> str:
    en_n = " ".join(_norm_parola(p) for p in re.findall(r"[a-z]+", en))
    for frase, trad in _FRASI:
        if re.search(rf"\b{frase}\b", it):
            scelta = next((t for t in trad if t and " ".join(_norm_parola(p) for p in t.split()) in en_n), trad[0])
            it = re.sub(rf"\b{frase}\b", f" {scelta} ", it)
    return it


def _corrispondenze(pi: list[str], pe: list[str]) -> tuple[set[int], set[int]]:
    """(parole italiane abbinate, parole inglesi abbinate), per posizione."""
    usate, presi = set(), set()
    for k, p in enumerate(pi):
        forme = [_norm_parola(f) for f in (p, *_TRADUZIONI_N.get(_norm_parola(p), ()))]
        for j, q in enumerate(pe):
            if j not in usate and any(_affini(f, _norm_parola(q)) for f in forme):
                usate.add(j)
                presi.add(k)
                break
    return presi, usate


def _inglese_coperto(it_nome: str | None, en_nome: str | None) -> bool:
    """Ogni parola del nome inglese (salvo «Introduction», «Advanced»…) corrisponde a una del nome
    italiano: la versione inglese non aggiunge un argomento («International Institutional Law» non è
    «Diritto internazionale umanitario», «Latin American Studies» non è «Antropologia dell'America
    latina»)."""
    it, en = _nome_base(it_nome).lower(), _nome_base(en_nome).lower()
    pe = _parole_trad(en)
    if not pe:
        return False
    _, usate = _corrispondenze(_parole_trad(_con_frasi(it, en)), pe)
    return all(j in usate or q in _OPZ_EN for j, q in enumerate(pe))


def _punteggio(pi: list[str], pe: list[str]) -> float:
    presi, usate = _corrispondenze(pi, pe)
    n_it = sum(1 for k, p in enumerate(pi) if k in presi or p not in _OPZ_IT)
    n_en = sum(1 for j, q in enumerate(pe) if j in usate or q not in _OPZ_EN)
    if not n_it or not n_en:
        return 0.0
    return len(presi) / max(n_it, n_en)


def _somiglianza_traduzione(it_nome: str | None, en_nome: str | None) -> float:
    """Quanto il nome inglese è la traduzione di quello italiano (0…1): parole affini
    (sistemi/systems), tradotte con il dizionario (reti/networks) o titoli in uso
    (basi di dati/databases). Numeri e lettere di modulo devono coincidere."""
    it, en = _nome_base(it_nome).lower(), _nome_base(en_nome).lower()
    if not it or not en:
        return 0.0
    if "/" in it and any(_norm_nome(p) == _norm_nome(en) for p in it.split("/")):
        return 1.0  # «Seminari per Tesi I/Thesis Seminar I» ← «Thesis Seminar I»
    if _segni(it) != _segni(en):
        return 0.0
    s = _punteggio(_parole_trad(_con_frasi(it, en)), _parole_trad(en))
    # note tra parentesi in tutti e due i nomi: devono corrispondere anche loro
    # («Lingua inglese B2 (abilità ricettive)» non è «English Language B2 (productive skills)»)
    pi = " ".join(re.findall(r"\(([^)]*)\)", (it_nome or "").lower()))
    pe = " ".join(re.findall(r"\(([^)]*)\)", (en_nome or "").lower()))
    if _parole_trad(pi) and _parole_trad(pe):
        s = min(s, _punteggio(_parole_trad(_con_frasi(pi, pe)), _parole_trad(pe)))
    return s


def _abbinamento(it: dict, en: dict, minimo: float = 0.6) -> tuple[float, str]:
    """(punteggio, motivo): punteggio > 0 se `en` è la versione inglese di `it`.

    Servono un nome inglese per `en`, un nome italiano per `it` e due nomi che sono
    la traduzione l'uno dell'altro (somiglianza almeno `minimo`); docenti in comune e
    lo stesso semestre sono prove in più, un semestre diverso chiede una traduzione
    quasi letterale. Tra gli insegnamenti a scelta la traduzione deve essere evidente."""
    ni, ne = it.get("nome") or "", en.get("nome") or ""
    # lingua dell'attività dalla fonte (`lingua`, UniTO/UniBG/LIUC: «Private Law» è in inglese anche se
    # il nome sembra italiano): vale al posto della lingua dedotta dal nome. Le varianti hanno sempre
    # «lingua: en», quindi conta la versione italiana: senza il campo (gli altri atenei) nulla cambia.
    esplicita = it.get("lingua") == "it" and en.get("lingua") == "en"
    if _norm_nome(_nome_base(ni)) == _norm_nome(_nome_base(ne)):
        if not esplicita:
            return 0.0, "stesso nome (non è una traduzione)"
        # stesso titolo in italiano e in inglese secondo la fonte (LIUC: «Asset Management» e
        # «Asset Management [Eng.]»): lo stesso insegnamento nelle due lingue
        docenti = bool(set(it.get("docenti") or []) & set(en.get("docenti") or []))
        stesso_periodo = it.get("periodo") is not None and it.get("periodo") == en.get("periodo")
        return 1.0 + 0.05 * docenti + 0.02 * stesso_periodo, "ok"
    if not esplicita and _lingua_nome(ne) == "it":
        return 0.0, "il nome della versione inglese è italiano"
    if not esplicita and _lingua_nome(ni) == "en" and "/" not in ni:
        return 0.0, "il nome della versione italiana è inglese"
    s = _somiglianza_traduzione(ni, ne)
    docenti = bool(set(it.get("docenti") or []) & set(en.get("docenti") or []))
    p1, p2 = it.get("periodo"), en.get("periodo")
    conflitto = p1 in ("1", "2") and p2 in ("1", "2") and p1 != p2
    scelta = it.get("obbligatorio") is False or en.get("obbligatorio") is False
    soglia = max(0.75, minimo) if scelta else minimo
    if docenti:
        soglia -= 0.1
    if conflitto:
        soglia = max(soglia, 0.75 if docenti else 0.9)
    if s < soglia - 1e-9:
        return 0.0, f"i nomi non sono una traduzione (somiglianza {s:.2f} < {soglia:.2f})"
    return s + 0.05 * docenti + 0.02 * (p1 == p2 and p1 is not None), "ok"


def _variante_da(en: dict) -> dict:
    return {"lingua": "en", **{k: en.get(k) for k in (
        "codice", "nome", "docenti", "url", "periodo", "libri", "esami", "modalita_esame")
        if en.get(k) not in (None, [], "")}}


def _aggiungi_variante(it: dict, en: dict) -> None:
    variante = _variante_da(en)
    # la stessa variante già nel database (build precedente): la riga inglese torna dal contributo
    # senza i libri e gli appelli raccolti prima, che restano (come `merge_insegnamenti` per le righe)
    for v in it.get("varianti") or []:
        if v.get("codice") == variante.get("codice") and v.get("lingua") == "en":
            for k in ("libri", "esami"):
                viste = {json.dumps(x, sort_keys=True) for x in variante.get(k) or []}
                altri = [x for x in v.get(k) or [] if json.dumps(x, sort_keys=True) not in viste]
                if altri:
                    variante[k] = (variante.get(k) or []) + altri
            for k, x in v.items():
                if variante.get(k) in (None, [], "") and x not in (None, [], ""):
                    variante[k] = x
    vv = [v for v in it.get("varianti") or [] if v.get("codice") != variante.get("codice")]
    it["varianti"] = vv + [variante]
    if "l-lin/12" in _ssd_base(en.get("ssd")):
        # esame di lingua inglese: i libri in inglese servono comunque
        chiavi = {(l.get("titolo"), l.get("autori")) for l in it.get("libri") or []}
        for l in en.get("libri") or []:
            if (l.get("titolo"), l.get("autori")) not in chiavi:
                it.setdefault("libri", []).append(l)


def _altro_en(it: dict, codice: str | None) -> bool:
    """`it` ha già una versione inglese con un altro codice."""
    return any(v.get("lingua") == "en" and v.get("codice") != codice for v in it.get("varianti") or [])


def _scegli(coppie: list[tuple]) -> list[tuple]:
    """Abbinamenti uno a uno, dal punteggio più alto; una versione inglese con due
    candidati italiani diversi a pari punteggio resta da sola (ambigua)."""
    migliori: dict[int, list] = {}
    for s, it, en, *_ in coppie:
        migliori.setdefault(id(en), []).append((s, _norm_nome(it.get("nome"))))
    ambigue = set()
    for k, lst in migliori.items():
        top = max(x[0] for x in lst)
        if len({n for s, n in lst if abs(s - top) < 1e-9}) > 1:
            ambigue.add(k)
    scelte, usati = [], set()
    for x in sorted(coppie, key=lambda x: -x[0]):
        s, it, en = x[:3]
        if id(en) in ambigue or id(en) in usati or id(it) in usati:
            continue
        usati.update((id(en), id(it)))
        scelte.append(x)
    return scelte


def varianti_lingua(corsi: list[dict], esiti: list | None = None) -> int:
    """Insegnamenti del percorso in lingua inglese che sono la versione inglese di un
    insegnamento italiano dello stesso corso (es. PoliTO: «Mathematical analysis I» nel
    «Percorso in lingua inglese» accanto ad «Analisi matematica I»): nel piano resta la
    versione italiana, quella inglese diventa una sua variante (`varianti: [{lingua: "en", …}]`)
    che lo studente può scegliere nell'app.

    Abbinamento solo con lo stesso anno, gli stessi CFU e lo stesso settore (SSD) e se i due
    nomi sono la traduzione l'uno dell'altro (`_abbinamento`); uno a uno. Altrimenti
    l'insegnamento inglese resta com'è. Restituisce il numero di varianti create."""
    n = 0
    for c in corsi:
        ins = c.get("insegnamenti") or []
        cur = c.get("curricula") or []
        # versione inglese: di un percorso in lingua inglese (anche se in comune con altri
        # percorsi) e con un nome inglese; versione italiana: non solo del percorso inglese
        # (con la lingua dell'attività dalla fonte, `lingua`, un'attività in italiano non è la
        # versione inglese e viceversa; senza il campo vale solo il nome)
        inglesi = [i for i in ins if i.get("ssd") and _INGLESE.search(i.get("curriculum") or "")
                   and _lingua_nome(i.get("nome")) != "it" and i.get("lingua") != "it"]
        italiani = [i for i in ins if not _solo_inglese(i.get("curriculum"), cur) and i.get("lingua") != "en"]
        coppie = []
        for en in inglesi:
            for it in italiani:
                if (it.get("anno") != en.get("anno") or it.get("cfu") != en.get("cfu")
                        or _ssd_base(it.get("ssd")) != _ssd_base(en.get("ssd"))
                        or it.get("codice") == en.get("codice") or _altro_en(it, en.get("codice"))):
                    continue
                s, _ = _abbinamento(it, en)
                if s:
                    coppie.append((s, it, en))
        togli = set()
        for s, it, en in _scegli(coppie):
            _aggiungi_variante(it, en)
            togli.add(id(en))
            n += 1
            if esiti is not None:
                esiti.append(("nuova", c.get("id"), it, _variante_da(en), s, "percorso in lingua inglese"))
        if togli:
            c["insegnamenti"] = [i for i in ins if id(i) not in togli]
    return n


def varianti_lingua_gemelli(corsi: list[dict], esiti: list | None = None) -> int:
    """Stesso insegnamento offerto in italiano e in inglese nello stesso piano
    senza un «percorso in lingua inglese» separato (es. PoliTO, 3° anno:
    «Reti di calcolatori» e «Computer networks», stesso anno, periodo, CFU e
    settore, percorsi in comune): la versione inglese diventa una variante di
    quella italiana, come in `varianti_lingua`. Solo insegnamenti obbligatori
    (tra quelli a scelta due esami nello stesso gruppo sono alternative diverse),
    un nome italiano e uno inglese che sono la traduzione l'uno dell'altro.
    Restituisce le varianti create."""
    n = 0
    for c in corsi:
        ins = c.get("insegnamenti") or []
        gruppi: dict[tuple, list[dict]] = {}
        for i in ins:
            if not i.get("ssd") or i.get("obbligatorio") is not True:
                continue
            k = (i.get("anno"), i.get("periodo"), i.get("cfu"), _ssd_base(i.get("ssd")))
            gruppi.setdefault(k, []).append(i)
        coppie = []
        for g in gruppi.values():
            for a in g:
                # lingua dal nome e, se la fonte la dà (`lingua`), anche dall'attività
                if _lingua_nome(a.get("nome")) != "it" or a.get("lingua") == "en":
                    continue
                for b in g:
                    if (b is a or _lingua_nome(b.get("nome")) != "en" or b.get("lingua") == "it"
                            or _altro_en(a, b.get("codice"))):
                        continue
                    pa, pb = set(percorsi(a.get("curriculum"))), set(percorsi(b.get("curriculum")))
                    if pa and pb and not (pa & pb):
                        continue
                    # nello stesso piano senza percorsi separati serve una traduzione più stretta
                    s, _ = _abbinamento(a, b, minimo=0.75)
                    if s:
                        coppie.append((s, a, b))
        togli = set()
        for s, a, b in _scegli(coppie):
            _aggiungi_variante(a, b)
            a["curriculum"] = _unisci_percorsi(a.get("curriculum"), b.get("curriculum"))
            togli.add(id(b))
            n += 1
            if esiti is not None:
                esiti.append(("nuova", c.get("id"), a, _variante_da(b), s, "stesso piano (gemelli)"))
        if togli:
            c["insegnamenti"] = [i for i in ins if id(i) not in togli]
    return n


def _gruppi_scelta(i: dict) -> set[str]:
    """Gruppi di scelta del piano dichiarati dalla fonte (`gruppo_scelta`, separati da virgola)."""
    return {g.strip() for g in str(i.get("gruppo_scelta") or "").split(",") if g.strip()}


def varianti_lingua_scelta(corsi: list[dict], esiti: list | None = None) -> int:
    """Versione italiana e inglese dello stesso esame offerte come alternative nello stesso
    gruppo di scelta del piano (UniTO, Economia: «I ANNO - UN ESAME A SCELTA FRA (12 CFU)» con
    «Microeconomia» ECO0002 e «Microeconomics» SEM0158): lo studente ne sostiene una, quindi la
    versione inglese diventa una variante di quella italiana (come in `varianti_lingua_gemelli`),
    che resta a scelta nel suo gruppo.

    Solo con i segnali espliciti della fonte, riportati dagli adattatori che li hanno (UniTO,
    UniBG, LIUC): lingua dell'attività (`lingua`: «it» e «en») e gruppo di scelta (`gruppo_scelta`,
    almeno un gruppo in comune). Inoltre: tutte e due a scelta, stesso anno e stessi CFU, stesso
    settore se lo hanno entrambe, nomi che sono la traduzione l'uno dell'altro con la soglia
    degli insegnamenti a scelta di `_abbinamento` (la stessa con cui `rivedi_varianti` ricontrolla
    le varianti alla build successiva) e nessuna parola del nome inglese senza corrispondente
    italiano (`_inglese_coperto`). Le righe senza questi campi (gli altri atenei) non cambiano.
    Restituisce le varianti create."""
    n = 0
    for c in corsi:
        ins = c.get("insegnamenti") or []
        cand = [i for i in ins if i.get("obbligatorio") is False and i.get("lingua") in ("it", "en")
                and _gruppi_scelta(i)]
        if not cand:
            continue
        coppie = []
        for a in cand:
            if a["lingua"] != "it":
                continue
            ga = _gruppi_scelta(a)
            for b in cand:
                if (b["lingua"] != "en" or a.get("anno") != b.get("anno") or a.get("cfu") != b.get("cfu")
                        or not (ga & _gruppi_scelta(b)) or a.get("codice") == b.get("codice")
                        or _altro_en(a, b.get("codice"))):
                    continue
                if a.get("ssd") and b.get("ssd") and _ssd_base(a["ssd"]) != _ssd_base(b["ssd"]):
                    continue
                s, _ = _abbinamento(a, b)
                if s and _inglese_coperto(a.get("nome"), b.get("nome")):
                    coppie.append((s, a, b))
        togli = set()
        for s, a, b in _scegli(coppie):
            _aggiungi_variante(a, b)
            a["curriculum"] = _unisci_percorsi(a.get("curriculum"), b.get("curriculum"))
            togli.add(id(b))
            n += 1
            if esiti is not None:
                esiti.append(("nuova", c.get("id"), a, _variante_da(b), s, "stesso gruppo di scelta (lingua dalla fonte)"))
        if togli:
            c["insegnamenti"] = [i for i in ins if id(i) not in togli]
    return n


def _slug(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")[:40].strip("-")


def _insegnamento_da_variante(c: dict, it: dict, v: dict, orig: dict | None) -> tuple[dict, str]:
    """La variante torna un insegnamento a sé: i campi della variante, anno/CFU/SSD/
    obbligatorio del genitore (erano uguali per costruzione), il percorso dal dato
    originale dell'adapter se c'è, altrimenti il percorso inglese del corso."""
    orig = orig or {}
    nota = ""
    cur = testo(orig.get("curriculum")) if orig.get("curriculum") else None
    if cur:
        nota = "ricreato come insegnamento, percorso dal dato originale"
    else:
        inglesi = [x for x in c.get("curricula") or [] if _INGLESE.search(x)]
        if len(inglesi) == 1:
            cur, nota = inglesi[0], "ricreato come insegnamento, percorso inglese del corso"
        else:
            cur = it.get("curriculum")
            nota = "ricreato come insegnamento, percorso del genitore (percorso inglese non identificabile)"
    obb = orig.get("obbligatorio") if isinstance(orig.get("obbligatorio"), bool) else it.get("obbligatorio")
    nuovo = {
        "codice": v.get("codice"), "nome": v.get("nome"), "anno": it.get("anno"), "periodo": v.get("periodo"),
        "cfu": it.get("cfu"), "ssd": it.get("ssd"), "obbligatorio": obb, "curriculum": cur,
        "docenti": v.get("docenti") or [], "url": v.get("url"),
        "fonte": orig.get("fonte") or it.get("fonte"), "verificato_il": orig.get("verificato_il") or it.get("verificato_il"),
        "stato_libri": "completo" if v.get("libri") else (
            orig.get("stato_libri") if orig.get("stato_libri") not in (None, "completo") else "da_aggiungere"),
        "id": f"{c['id']}-{_slug(v.get('codice') or v.get('nome') or '')}",
        "stato_esami": "completo" if v.get("esami") else "da_aggiungere",
        "libri": v.get("libri") or [], "esami": v.get("esami") or [],
    }
    if v.get("modalita_esame"):
        nuovo["modalita_esame"] = v["modalita_esame"]
    return nuovo, nota


def rivedi_varianti(corsi: list[dict], originali: dict | None = None, esiti: list | None = None) -> int:
    """Ricontrolla le varianti inglesi già nel database con la regola di `_abbinamento`
    (le prime erano abbinate solo per anno, CFU e SSD: «Basi di dati» ← «Computer
    architecture»). Ogni versione inglese resta al più su un insegnamento (il migliore) e
    ogni insegnamento tiene al più una versione inglese; quelle sbagliate tornano
    insegnamenti a sé (`_insegnamento_da_variante`), se il corso non lo ha già.
    `originali`: {id corso: {codice: insegnamento dell'adapter}} per il percorso e
    l'obbligatorietà originali. Restituisce il numero di varianti tolte."""
    tolte = 0
    for c in corsi:
        ins = c.get("insegnamenti") or []
        cur = c.get("curricula") or []
        orig = (originali or {}).get(c.get("id")) or {}
        valut = []
        for it in ins:
            for v in it.get("varianti") or []:
                if v.get("lingua") != "en":
                    continue
                o = orig.get(v.get("codice")) or {}
                en = {**v, "obbligatorio": o.get("obbligatorio", it.get("obbligatorio"))}
                s, motivo = _abbinamento(it, en)
                valut.append((s, it, v, motivo))
        if not valut:
            continue
        tenute = {(id(it), id(v)) for s, it, v, _ in _scegli([x for x in valut if x[0]])}
        presenti = {i.get("codice") for i in ins} | {x for i in ins for x in i.get("codici_alternativi") or []}
        dopo: dict[int, list[dict]] = {}
        gia = set()
        for s, it, v, motivo in valut:
            if (id(it), id(v)) in tenute:
                if esiti is not None:
                    esiti.append(("tenuta", c.get("id"), it, v, s, ""))
                continue
            if motivo == "ok":
                motivo = "abbinata meglio a un altro insegnamento o ambigua"
            it["varianti"] = [x for x in it.get("varianti") or [] if x is not v]
            if not it["varianti"]:
                del it["varianti"]
            if "l-lin/12" in _ssd_base(it.get("ssd")) and v.get("libri"):
                copiati = {(l.get("titolo"), l.get("autori")) for l in v["libri"]}
                it["libri"] = [l for l in it.get("libri") or [] if (l.get("titolo"), l.get("autori")) not in copiati]
            tolte += 1
            cod = v.get("codice")
            ancora = any((id(i), id(x)) in tenute for i in ins for x in i.get("varianti") or []
                         if x.get("codice") == cod)
            nota = ""
            if not ancora and cod not in presenti and cod not in gia:
                nuovo, nota = _insegnamento_da_variante(c, it, v, orig.get(cod))
                dopo.setdefault(id(it), []).append(nuovo)
                gia.add(cod)
            if esiti is not None:
                esiti.append(("annullata", c.get("id"), it, v, s, motivo + (f"; {nota}" if nota else "")))
        if dopo:
            out = []
            for i in ins:
                out.append(i)
                out.extend(dopo.get(id(i), []))
            c["insegnamenti"] = out
    return tolte


def _norm_nome(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def _sede_secondaria(i: dict) -> bool:
    return bool(re.search(r"(?i)\bsede di\b|mondov|\bcanale\b|\bcanali\b", i.get("curriculum") or ""))


def percorsi(curriculum: str | None) -> list[str]:
    """«Percorso, Percorso INTRAPRENDENTI» -> due percorsi (virgole fuori dalle parentesi)."""
    s = (curriculum or "").strip()
    out: list[str] = []
    depth = start = 0
    for k, ch in enumerate(s):
        if ch == "(":
            depth += 1
        elif ch == ")" and depth:
            depth -= 1
        elif ch == "," and depth == 0:
            if s[start:k].strip():
                out.append(s[start:k].strip())
            start = k + 1
    if s[start:].strip():
        out.append(s[start:].strip())
    return out


def _unisci_percorsi(a: str | None, b: str | None) -> str | None:
    """Unendo due copie dello stesso insegnamento: senza percorso una delle due
    vale per tutti; altrimenti l'unione dei percorsi."""
    if not a or not b:
        return None
    pa = percorsi(a)
    return ", ".join(pa + [p for p in percorsi(b) if p not in pa])


_SEGNAPOSTO = re.compile(
    r"(?i)^\s*(insegnament[oi] a scelta|esam[ei] a scelta|attivit[aà] (formative )?a scelta|"
    r"a scelta dello studente|crediti (liberi|a scelta)|corso a scelta|insegnament[oi] opzional[ei]|"
    r"gruppo (di )?insegnamenti a scelta|crediti liberi)"
)


def segna_a_scelta(corsi: list[dict]) -> int:
    """Voci che non sono un esame preciso ma uno spazio da riempire a scelta
    («Insegnamenti a scelta dal Gruppo TABCOM», «Esame a scelta 1»): lo
    studente lo riempie con un esame a scelta, quindi è un insegnamento a
    scelta (obbligatorio = false).
    Restituisce il numero di insegnamenti cambiati."""
    n = 0
    for c in corsi:
        ins = c.get("insegnamenti") or []
        for i in ins:
            if _SEGNAPOSTO.search(i.get("nome") or "") and i.get("obbligatorio") is not False:
                i["obbligatorio"] = False
                n += 1
    return n


def unisci_omonimi(corsi: list[dict], esistenti: set[str] | None = None) -> int:
    """Stesso insegnamento ripetuto nel piano dello stesso corso (un codice per
    canale, sede o curriculum: es. PoliTO «Analisi matematica I» a Torino e a
    Mondovì): diventa un solo insegnamento con tutti i docenti, i libri (senza
    doppioni) e gli appelli; gli altri codici restano in `codici_alternativi`.
    Si uniscono solo insegnamenti con lo stesso nome, anno e CFU, e non quelli
    obbligatori in un percorso e a scelta in un altro (`_per_obbligo`).
    `esistenti`: id già nel database; tra gli uniti tiene l'id uno di questi, così una riga
    nuova (es. la stessa scelta in un altro anno, `-a<anno>`) non toglie l'id a una che c'era.
    Restituisce il numero di insegnamenti uniti."""
    n = 0
    for c in corsi:
        gruppi: dict[tuple, list[dict]] = {}
        for i in c.get("insegnamenti") or []:
            gruppi.setdefault((_norm_nome(i.get("nome")), i.get("anno"), i.get("cfu")), []).append(i)
        nuovi = []
        visti = set()
        for i in c.get("insegnamenti") or []:
            k = (_norm_nome(i.get("nome")), i.get("anno"), i.get("cfu"))
            if k in visti:
                continue
            visti.add(k)
            for g in _per_obbligo(gruppi[k]):
                n += _unisci_gruppo(g, nuovi, esistenti)
        c["insegnamenti"] = nuovi
    return n


def _per_obbligo(g: list[dict]) -> list[list[dict]]:
    """Obbligatorio in alcuni percorsi e a scelta in altri (percorsi tutti indicati e
    disgiunti): due insegnamenti, uno per obbligatorietà (vedi build_db._stessa_riga)."""
    obb = [i for i in g if i.get("obbligatorio") is not False]
    sce = [i for i in g if i.get("obbligatorio") is False]
    if obb and sce and all(i.get("curriculum") for i in g):
        if not {p for i in obb for p in percorsi(i["curriculum"])} & {p for i in sce for p in percorsi(i["curriculum"])}:
            return [obb, sce]
    return [g]


def _unisci_gruppo(g: list[dict], nuovi: list[dict], esistenti: set[str] | None = None) -> int:
    """Un gruppo di `unisci_omonimi`: il primo tiene l'id e prende docenti, libri, appelli,
    percorsi e codici degli altri; finisce in `nuovi`. Restituisce gli insegnamenti uniti."""
    if len(g) == 1:
        nuovi.append(g[0])
        return 0
    n = 0
    g = sorted(g, key=lambda x: (esistenti is not None and x.get("id") not in esistenti, _sede_secondaria(x),
                                 -len(x.get("docenti") or []), x.get("codice") or ""))
    base = g[0]
    for altro in g[1:]:
        n += 1
        for d in altro.get("docenti") or []:
            if d not in (base.get("docenti") or []):
                base.setdefault("docenti", []).append(d)
        chiavi = {(_norm_nome(l.get("titolo")), _norm_nome(l.get("autori"))) for l in base.get("libri") or []}
        for l in altro.get("libri") or []:
            kk = (_norm_nome(l.get("titolo")), _norm_nome(l.get("autori")))
            if kk not in chiavi:
                chiavi.add(kk)
                base.setdefault("libri", []).append(l)
        viste = {(e.get("data"), e.get("ora"), e.get("tipo")) for e in base.get("esami") or []}
        for e in altro.get("esami") or []:
            ke = (e.get("data"), e.get("ora"), e.get("tipo"))
            if ke not in viste:
                viste.add(ke)
                base.setdefault("esami", []).append(e)
        base["curriculum"] = _unisci_percorsi(base.get("curriculum"), altro.get("curriculum"))
        if altro.get("codice") and altro.get("codice") != base.get("codice"):
            alt = base.setdefault("codici_alternativi", [])
            if altro["codice"] not in alt:
                alt.append(altro["codice"])
        for v in altro.get("varianti") or []:
            vv = base.setdefault("varianti", [])
            if all(x.get("codice") != v.get("codice") for x in vv):
                vv.append(v)
    if base.get("libri"):
        base["stato_libri"] = "completo"
    if base.get("esami"):
        base["esami"].sort(key=lambda e: e.get("data") or "")
    nuovi.append(base)
    return n

# Durata legale per tipo di corso (DM 270/2004): magistrale 2 anni, ciclo unico 5 anni,
# 6 per Medicina e chirurgia (LM-41) e Odontoiatria (LM-46).
_CU_SEI = {"LM-41", "LM-46"}


def durata_per_tipo(corsi: list[dict]) -> int:
    """Corregge `durata_anni` incoerente con il tipo (es. una magistrale da 3 anni o un
    ciclo unico da 3, lasciati dall'elenco del catalogo). Restituisce i corsi corretti."""
    n = 0
    for c in corsi:
        tipo, d = c.get("tipo"), c.get("durata_anni")
        classi = {x.strip().upper() for x in re.split(r"[&,]| e ", c.get("classe") or "") if x.strip()}
        if tipo == "LM" and d != 2:
            giusta = 2
        elif tipo == "LMCU" and d not in (5, 6):
            giusta = 6 if classi & _CU_SEI else 5
        elif tipo == "LMCU" and d == 5 and classi & _CU_SEI:
            giusta = 6
        else:
            continue
        c["durata_anni"] = giusta
        n += 1
    return n

# Settori scientifico-disciplinari: vecchia sigla (MAT/05, ING-INF/05, L-FIL-LET/11) e nuova
# (MATH-03/A, DM 639/2024). Le fonti li scrivono in molti modi («IINF-05/A ING-INF/05»,
# «7 cfu - ING-INF/05 (IINF-05/A)», «-- --»): una forma sola, «VECCHIA (NUOVA)», separati da «; ».
SSD_VECCHIO = re.compile(r"\b[A-Z]{1,4}(?:-[A-Z]{1,5}){0,2}/\d{2}\b")
SSD_NUOVO = re.compile(r"\b[A-Z]{3,5}-\d{2}/[A-Z]\b")


def ssd(s: str | None) -> str | None:
    if not s or not isinstance(s, str):
        return s or None
    t = s.strip()
    if t.upper() == "NN":
        return "NN"
    parti = []
    for pezzo in re.split(r"\s*;\s*", t):
        pezzo = re.sub(r"(?i)^\s*\d+(?:[.,]\d+)?\s*cfu\s*-\s*", "", pezzo)
        nuovi = SSD_NUOVO.findall(pezzo)
        vecchi = [v for v in SSD_VECCHIO.findall(pezzo) if v not in nuovi and not any(v in n for n in nuovi)]
        if not vecchi and not nuovi:
            continue
        if vecchi and nuovi:
            parti.append(f"{vecchi[0]} ({nuovi[0]})")
        else:
            parti.append((vecchi or nuovi)[0])
    out = []
    for x in parti:
        if x not in out:
            out.append(x)
    if not out:
        return "NN" if re.search(r"\bNN\b", t) else None
    return "; ".join(out)
