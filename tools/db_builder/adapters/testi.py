"""Riconosce i libri di testo nel testo libero dei syllabus.

I syllabus riportano i testi in forme molto diverse: elenchi strutturati
("Titolo: …, Autori: …, Anno: …, Editore: …" come a Padova), elenchi puntati,
paragrafi. Si tengono solo le righe che sembrano riferimenti bibliografici e si
conserva sempre la citazione originale in `citazione`.
"""
from __future__ import annotations

import html
import re

ISBN = re.compile(r"\b(?:ISBN[-: ]*)?((?:97[89][- ]?)?\d{1,5}[- ]?\d{1,7}[- ]?\d{1,7}[- ]?[\dXx])\b")
YEAR = re.compile(r"\b(19[5-9]\d|20[0-4]\d)\b")
EDITORI = ["zanichelli", "mcgraw", "pearson", "hoepli", "giappichelli", "cedam", "il mulino", "mulino", "carocci",
           "laterza", "utet", "franco angeli", "francoangeli", "edises", "ambrosiana", "apogeo", "springer", "wiley",
           "elsevier", "edra", "piccin", "idelson", "mondadori", "einaudi", "feltrinelli", "giuffr", "esculapio",
           "società editrice", "societa editrice", "edizioni", "editore", "editrice", "press", "cambridge", "oxford",
           "routledge", "sage", "o'reilly", "addison", "prentice", "cengage", "maggioli", "simone", "egea",
           "bompiani", "rizzoli", "garzanti", "le monnier", "loescher", "città studi", "citta studi", "liguori",
           "esselibri", "pàtron", "patron", "clueb", "cleup", "levrotto", "celid", "progetto leonardo", "dispense",
           "jaca book", "raffaello cortina", "cortina", "erickson", "giunti", "ets", "plus", "aracne", "wolters",
           "packt", "manning", "no starch", "mit press", "princeton", "academic press", "crc"]
NON_LIBRO = re.compile(r"^(appunti|slide|slides|lucidi|dispense del docente|materiale (didattico )?(fornito|del docente|"
                       r"disponibile)|articoli|testi consigliati|testi di riferimento|bibliografia|studenti "
                       r"(non )?frequentanti|per il modulo|modulo)\b", re.I)


def html_to_lines(s: str) -> list[str]:
    s = re.sub(r"(?i)<\s*(br|/p|/li|/div|/h\d|/tr)\s*/?>", "\n", s or "")
    s = re.sub(r"(?i)<\s*li[^>]*>", "\n- ", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(html.unescape(s)).replace("\xa0", " ")
    out = []
    for line in s.splitlines():
        line = re.sub(r"\s+", " ", line).strip(" -–•*·\t;")
        if line:
            out.append(line)
    return out


def _tipo(line: str) -> str | None:
    l = line.lower()
    if "consigliat" in l or "facoltativ" in l or "approfondiment" in l or "supplementar" in l:
        return "consigliato"
    if "obbligator" in l or "adottat" in l:
        return "obbligatorio"
    return None


def _strutturato(line: str) -> dict | None:
    """Formato 'Titolo: X, Autori: Y, Luogo: Z, Anno: N, Editore: E, Note: …'."""
    if "titolo:" not in line.lower():
        return None
    campi = dict(re.findall(r"(Titolo|Autori|Luogo|Anno|Editore|Note|ISBN|Edizione):\s*(.*?)(?=,\s*(?:Titolo|Autori|"
                            r"Luogo|Anno|Editore|Note|ISBN|Edizione):|\.?\s*$)", line, re.I))
    campi = {k.lower(): v.strip(" .,") for k, v in campi.items()}
    if not campi.get("titolo"):
        return None
    anno = campi.get("anno")
    return {
        "titolo": campi["titolo"], "autori": campi.get("autori") or None, "editore": campi.get("editore") or None,
        "anno": int(anno) if anno and anno.isdigit() and int(anno) > 1800 else None,
        "edizione": campi.get("edizione") or None, "isbn": _isbn(line), "lingua": None,
        "tipo": _tipo(campi.get("note") or ""), "note": (campi.get("note") or None) if campi.get("note") not in
        ("--", "-") else None, "citazione": line,
    }


def _isbn(line: str) -> str | None:
    for m in ISBN.finditer(line):
        digits = re.sub(r"[^\dXx]", "", m.group(1))
        if len(digits) in (10, 13):
            return digits.upper()
    return None


def _sembra_libro(line: str) -> bool:
    if len(line) < 12 or len(line) > 400 or NON_LIBRO.match(line):
        return False
    l = line.lower()
    has_year = bool(YEAR.search(line))
    has_pub = any(e in l for e in EDITORI)
    has_isbn = _isbn(line) is not None
    commas = line.count(",") + line.count(" - ") + line.count(" – ")
    return has_isbn or (has_pub and (has_year or commas >= 1)) or (has_year and commas >= 2)


# --- citazioni in testo libero: «C. Canuto, A. Tabacco. Analisi Matematica I. Pearson, 2021.» ---
# Si scompongono solo le forme riconoscibili senza dubbi: autori con le iniziali all'inizio,
# poi il titolo, poi un editore noto. Altrimenti titolo = citazione intera.
_EDITORI_CIT = re.compile(
    r"(?i)(?<![\w'’])(?:zanichelli|mcgraw|pearson|hoepli|giappichelli|cedam|il mulino|carocci|laterza|utet|"
    r"franco ?angeli|edises|ambrosiana|apogeo|springer|wiley|elsevier|edra|piccin|idelson|mondadori|einaudi|"
    r"feltrinelli|giuffr\w*|esculapio|societ[àa] editrice|edizioni|editore|editrice|editori|press|"
    r"routledge|sage|o'reilly|addison|prentice|cengage|maggioli|egea|bompiani|rizzoli|garzanti|le monnier|"
    r"loescher|citt[àa] studi|liguori|esselibri|p[àa]tron|clueb|cleup|levrotto|celid|jaca book|cortina|"
    r"erickson|giunti|aracne|wolters|packt|manning|no starch|academic press|crc|etas|marsilio|birkh[äa]user|"
    r"butterworth|taylor (?:&|and) francis|dover|pitagora|palgrave|macmillan|norton|penguin|harper|kluwer|"
    r"de gruyter|thieme|masson|world scientific|bollati|donzelli|quodlibet|electa|skira|gangemi|alinea|"
    r"vita e pensiero|jackson|verlag|cambridge university|oxford university|princeton university|"
    r"springer-verlag|spon|earthscan|guerini|mimesis|il sole 24 ore|maggioli|ipsoa|zanichelli)(?![\w])")
_CITTA = {"torino", "milano", "roma", "bologna", "napoli", "firenze", "padova", "venezia", "genova", "bari",
          "pisa", "trento", "verona", "palermo", "catania", "rimini", "santarcangelo di romagna", "london",
          "new york", "berlin", "paris", "cambridge", "oxford", "boston", "amsterdam", "heidelberg", "basel",
          "hoboken", "upper saddle river", "berlino", "londra", "parigi", "new jersey", "chichester", "singapore",
          "dordrecht", "philadelphia", "san francisco", "princeton", "lugano", "bruxelles", "brussels", "madrid",
          "barcelona", "barcellona", "wien", "vienna", "zurich", "zurigo", "usa", "uk", "ny", "ma", "nj", "ca",
          "novara", "macerata", "perugia", "cagliari", "sassari", "lecce", "salerno", "messina", "modena", "parma",
          "brescia", "bergamo", "como", "pavia", "trieste", "udine", "ancona", "pescara", "siena", "arezzo",
          "lucca", "livorno", "cosenza", "potenza", "foggia", "taranto", "vicenza", "treviso", "bolzano", "aosta",
          "alessandria", "cuneo", "varese", "monza", "cremona", "mantova", "ferrara", "ravenna", "pesaro",
          "urbino", "viterbo", "caserta", "benevento", "avellino", "matera", "catanzaro", "reggio emilia",
          "reggio calabria", "rovereto", "assisi", "fiesole", "bari", "edinburgh", "glasgow", "manchester",
          "los angeles", "chicago", "toronto", "montreal", "sydney", "melbourne", "tokyo", "munich", "münchen",
          "frankfurt", "stuttgart", "leipzig", "hamburg", "göttingen", "tübingen", "bern", "genève", "geneva",
          "lausanne", "lyon", "leiden", "lisboa", "lisbona", "mexico", "buenos aires", "new haven", "thousand oaks",
          "englewood cliffs", "reading", "abingdon", "milton park", "basingstoke", "malden", "hove", "harlow"}
_PART = r"(?:(?:de|De|di|Di|da|Da|del|Del|della|Della|van|Van|von|Von|der|Der|den|La|Le|El|dos|Dos|du|Du)\s){0,2}"
_COG1 = r"(?:[dD]['’])?[A-ZÀ-Ý][a-zà-ÿ]+(?:['’][A-ZÀ-Ý]?[a-zà-ÿ]+)?(?:-[A-ZÀ-Ý][a-zà-ÿ]+)?"
_COG = rf"{_PART}{_COG1}(?:\s{_PART}{_COG1})?"  # «Perez Montenegro», «Calvo del Olmo», «van den Toorn»
_INIZ = r"(?:[A-Z]\.\s?-?){1,3}"
# «C. Canuto», «G.C. Calafiore», «L. El Ghaoui» | «Carrera E.», «Viola, E.» (non «Fisica I.»)
_AUTORE = (rf"(?:{_INIZ}\s?{_COG}"
           rf"|{_COG},?\s(?!I\.(?!\s?[A-Z]\.))(?:[A-Z]\.\s?-?){{1,3}})")
# «John C. Hull» non è riconoscibile da «Capasso F. Botanica, …» (cognome, iniziale, titolo): non si scompone
_SEP = r"(?:,\s(?:&\s|and\s|e\s)?|\s(?:e|and|&)\s|;\s)"
_BLOCCO = re.compile(
    rf"^(?P<autori>{_AUTORE}(?:{_SEP}{_AUTORE})*(?:,?\set\.?\sal\.?)?)"
    r"(?:\s?\((?i:eds?\.?|a cura di|edited by|ed\.|cur\.)\)\.?|,\s(?i:eds?\.|a cura di))?"
    r"(?:\s?\((?P<anno1>\d{4})[a-z]?\)[.,:]?\s+|,\s(?P<anno2>\d{4})[,.:]\s+|[,:;]\s+|(?<!\.)\.\s+)")
_TAGLIO = re.compile(r"(?<!\b[A-HJ-UWYZ])(?<!\b[A-Z][a-z])(?<!\bUniv)(?<!\bVol)(?<!\bvol)(?<!\bVoll)(?<!\bed)"
                     r"(?<!\bEd)(?<!\bpp)(?<!\bcap)(?<!\bnn)(?<!\bJr)(?<!\bInc)(?<!\bCo)(?<!\bSoc)\.\s+|,\s+|;\s+|(?<=[?!])\s+")
_EDIZIONE = re.compile(r"(?i)^(?:\d+\s?(?:a|°|st|nd|rd|th)?\s?(?:ed\.?|edizione|edition)|(?:prima|seconda|terza|"
                       r"quarta|quinta|first|second|third|fourth|fifth)\s(?:ed\.?|edizione|edition)|ed\.\s?\d+|"
                       r"\d{4}|isbn.*|ean.*)$")


def _citta(p: str) -> bool:
    """«Torino», «London & New York», «Roma-Bari»: solo nomi di città."""
    parti = [x for x in re.split(r"\s*(?:&|/|-|\band\b|\be\b)\s*", p.lower()) if x]
    return bool(parti) and all(x in _CITTA for x in parti)


def _editoriale(p: str) -> bool:
    return len(p) <= 60 and len(p.split()) <= 8 and bool(
        _EDITORI_CIT.search(p) or re.match(r"^(?:[Ee]d\.|[Ee]ditore:?|[Ee]dizioni)\s+[A-ZÀ-Ý]", p))


def scomponi_citazione(cit: str) -> dict | None:
    """Autori, titolo, editore e anno da una citazione in testo libero, solo quando la
    forma è chiara: autori con le iniziali all'inizio («C. Canuto, A. Tabacco» o
    «Carrera E.»), poi il titolo, poi un editore conosciuto («Pearson», «Levrotto &
    Bella», «… University Press»). None se la citazione è ambigua."""
    s = re.sub(r"^[\s●•▪◦*·\-–]+", "", cit or "").strip()
    m = _BLOCCO.match(s)
    if not m or " / " in s:  # « / »: due opere (originale e traduzione) o titolo/autori invertiti
        return None
    autori = m.group("autori").strip(" ,;")
    resto = s[m.end():]
    pezzi, pos = [], 0
    for t in list(_TAGLIO.finditer(resto)) + [None]:
        fine = t.start() if t else len(resto)
        pezzo = resto[pos:fine].strip(" .")
        if pezzo:
            pezzi.append((pos, pezzo))
        if t:
            pos = t.end()
    ed_i = next((k for k, (_, p) in enumerate(pezzi) if k >= 1 and _editoriale(p)), None)
    if ed_i is None or any(_editoriale(p) for _, p in pezzi[ed_i + 1:]):
        return None  # nessun editore, o più di uno (capitolo «anche in …», due edizioni): ambigua
    titoli = pezzi[:ed_i]
    # dopo il titolo: edizione («2a ed.», «5th ed. New York»), curatore, traduzione, città, anno
    taglio = next((k for k, (_, p) in enumerate(titoli) if k >= 1 and (re.match(
        r"(?i)(?:\d+\s?(?:a|ª|°|st|nd|rd|th)?\.?\s?(?:ed\b|edizione|edition)|(?:[ivx]+|ultima|nuova|prima|seconda|"
        r"terza|quarta|quinta|first|second|third|fourth|fifth)\s(?:ed\b|edizione|edition)|a cura di|edited by|"
        r"trad\b|traduzione|ed\.?\s?it\b)", p) or re.match(rf"(?:{_AUTORE})\s*\((?i:eds?\.?|a cura di)\)", p))), None)
    if taglio is not None:
        titoli = titoli[:taglio]
    while titoli and (_EDIZIONE.match(titoli[-1][1]) or _citta(titoli[-1][1])):
        titoli.pop()
    if not titoli:
        return None
    titolo = resto[:titoli[-1][0] + len(titoli[-1][1])].replace("''", "").replace("``", "")
    titolo = re.sub(r"^\(?(?:19|20)\d\d[a-z]?\)?[.,:]?\s+", "", titolo.strip())  # «2010: Mesoscale …»
    titolo = re.sub(r"(?i)\s*\((?:capp?\.|chapters?|capitoli|pp\.|parte|parti)[^)]*\)\s*$", "", titolo)  # «(capp. 1-4)»
    titolo = re.sub(r"(?i)[\s,]+\d+\s?(?:a|ª|°|st|nd|rd|th)?\s?(?:ed\.?|edizione|edition)\s*$", "", titolo)
    fondo = re.search(r"[.,]\s+([^.,]+)$", titolo)  # «… with R. New York», «… sociale. Roma 2024»
    if fondo and _citta(re.sub(r"\s*\d{4}$", "", fondo.group(1))):
        titolo = titolo[:fondo.start()]
    titolo = titolo.strip(" .,;:'\"“”«»‘’`")
    editore = pezzi[ed_i][1]
    editore = re.sub(r"\s*Acquista da VP.*$", "", editore)  # UniCatt: link alla libreria
    editore = re.sub(r"\s*\[.*$", "", re.sub(r"(?i)^published by\s+", "", editore))
    editore = re.sub(r"(?i)^(?:ed\.\s?|editore:\s?|casa editrice:\s?)", "", editore)
    editore = re.sub(r"(?i)^(?:[IVX]+|\d+\s?(?:a|ª|°|st|nd|rd|th)?)\s?ed(?:\.|izione)?\s+", "", editore)  # «V ed. …»
    m2 = re.match(r"^([^:]+):\s+(\S.*)$", editore)  # «Cambridge: Cambridge University Press»
    if m2:
        editore = m2.group(1) if _EDITORI_CIT.search(m2.group(1)) else m2.group(2)  # «Carocci: Roma»
    editore = re.sub(r"(?i)\s*isbn.*$", "", editore)
    editore = re.sub(r"\s*\([^)]*$", "", editore)  # parentesi tagliata: «Piccin Editore (capitoli 6»
    # note tra parentesi in fondo: «(capp. 1-3)», «(ISBN …)», «(Terza edizione)»; resta «(Elsevier)»
    editore = re.sub(r"(?i)\s*\((?:[^)]*\d[^)]*|cap[^)]*|parti[^)]*|[^)]*edizion[^)]*|[^)]*edition[^)]*|[^)]*chapter[^)]*)\)\s*$",
                     "", editore)
    editore = re.sub(r"\s*\([a-zà-ÿ][^)]*\)\s*$", "", editore)
    editore = re.sub(r"(?i)\.?\s*\d+\s?(?:st|nd|rd|th|a|°)\.?\s*(?:eds?|edition|edizione)\b.*$", "", editore)
    editore = re.sub(r"\s*\(?\b(?:19|20)\d\d\)?\s*$", "", editore).strip(" .,;:-–")
    if (not re.search(r"[A-Za-zÀ-ÿ]{3}", titolo) or len(titolo) > 250 or len(autori) > 200 or not editore
            or len(editore) < 2 or YEAR.fullmatch(titolo) or not re.match(r"[\w'‘“«\"]", titolo)
            or re.match(rf"(?:{_AUTORE})[\s,.;]", titolo)  # altri autori rimasti nel titolo
            or re.search(r"\b[A-Z][a-zà-ÿ]+,\s(?:[A-Z]\.\s?){1,3},\s", titolo)  # «…, Rossi, F., …»
            or re.match(r"[A-Z]\.", titolo) or re.search(r"\b[A-Z]\.,\s", titolo[:80])  # iniziali nel titolo
            or titolo.count("(") != titolo.count(")")
            or re.match(r"(?:and|e|con|with|&)\s", titolo)  # «and Christopher M. Cain. …»: altri autori
            or not (_EDITORI_CIT.search(re.sub(r"\([^)]*\)", "", editore))  # «applicazioni (Maggioli Editore)»
                    or re.match(r"^(?:[Ee]d\.|[Ee]ditore:?|[Ee]dizioni)\s", pezzi[ed_i][1]))
            or re.search(r",\s[A-Z]\.\s?[A-Z][a-zà-ÿ]+,\s", titolo[:80])  # «I Giannelli, A. Soldaini, …»
            # un'altra citazione nel titolo: «… Casa Editrice Zanichelli - Whalen K (2024) …»
            or re.search(r"\((?:19|20)\d\d\)|(?i:\b(?:casa editrice|editore|editrice)\b)", titolo)
            # capitolo di un altro libro: «…, in: …», «… In A. P. Brief (Ed.)», «. In Psychology …», «(chapter 4)»
            or re.search(r"(?:^|[\s,.])[Ii]n:\s|[,'’\"”]\s*in\s|\b[Ii]n\s[A-Z]\.\s?|\.\s[Ii]n\s[A-Z]|"
                         r"(?i:\b(?:chapter|capitolo)\b)", titolo)):
        return None
    anni = set(YEAR.findall(s))
    return {"autori": autori, "titolo": titolo, "editore": editore,
            "anno": int(anni.pop()) if len(anni) == 1 else None}


def _libero(line: str) -> dict:
    """Riferimento in testo libero: il titolo si separa se è tra virgolette o se la
    citazione ha una forma chiara (`scomponi_citazione`), altrimenti titolo =
    citazione intera (mai un titolo indovinato male)."""
    line = re.sub(r"^\s*(\[?[A-Z]?\d{1,2}[a-z]?[\])\.]|[a-z]\))\s*", "", line).strip()
    anno = YEAR.findall(line)
    autori, titolo = None, line
    q = re.search(r"[“\"«]([^”\"»]{4,200})[”\"»]", line)
    if q:
        titolo = q.group(1).strip()
        before = line[:q.start()].strip(" ,:;.-–")
        if 2 <= len(before) <= 120:
            autori = before
    parts = [p.strip(" .") for p in re.split(r",\s*|;\s*", line)]
    editore = next((p for p in parts if any(e in p.lower() for e in EDITORI)), None)
    if editore and len(editore) > 60:
        editore = None
    sc = None if q else scomponi_citazione(line)
    if sc:
        autori, titolo, editore = sc["autori"], sc["titolo"], sc["editore"]
        anno = [str(sc["anno"])] if sc["anno"] else anno
    return {
        "titolo": titolo[:300], "autori": autori, "editore": editore,
        "anno": int(anno[-1]) if anno else None, "edizione": None, "isbn": _isbn(line), "lingua": None,
        "tipo": _tipo(line), "note": None, "citazione": line,
    }


def estrai_libri(*testi: str) -> list[dict]:
    libri, viste = [], set()
    for t in testi:
        for line in html_to_lines(t):
            item = _strutturato(line)
            if not item and _sembra_libro(line):
                item = _libero(line)
            if item:
                key = re.sub(r"\W+", "", item["citazione"].lower())[:120]
                if key not in viste:
                    viste.add(key)
                    libri.append(item)
    return libri
