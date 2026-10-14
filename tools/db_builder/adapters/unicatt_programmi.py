"""Lettura dei programmi degli insegnamenti dell'Università Cattolica (`/upl/proguc/….docx` e `.pdf`).

Dal programma si prendono il docente («Prof. …»), la bibliografia e il titolo (per controllare che il
file sia proprio quello dell'insegnamento). La bibliografia è la sezione che segue un titolo come
«BIBLIOGRAFIA», «Testi di riferimento», «Reading list», «3. testi di riferimento/BIBLIOGRAPHY» (i
syllabus in PDF di Medicina) fino al titolo della sezione successiva. Le righe che citano un'opera
(editore, anno, ISBN) si riconoscono con `testi.estrai_libri`; nelle sezioni di bibliografia si
accettano anche le citazioni senza editore («P. Mazzoleni, Finanza matematica, EDUCatt.») purché
abbiano la forma «autori, titolo». Il tipo (obbligatorio/consigliato) si assegna solo se la riga o il
sottotitolo sotto cui sta lo dicono («Testo adottato», «Letture suggerite», «(testo facoltativo)»).
"""
from __future__ import annotations

import html
import io
import pathlib
import re
import shutil
import subprocess
import tempfile
import unicodedata
import zipfile

from .testi import _EDITORI_CIT, _libero, estrai_libri

# titolo di una sezione di bibliografia: «Bibliografia», «Testi di riferimento:», «Required readings», …
TESTATA = re.compile(
    r"(?i)^\s*(?:\d+[.)]?\s*)?(?:programma(?: del corso| d['’]esame)?\s*(?:e|and)\s+)?"
    r"(bibliografia|bibliography|bibliographie|reading\s*list|textbooks?|testi|testo|materials\s+to\s+study|"
    r"required\s+readings?|"
    r"suggested\s+readings?|recommended\s+readings?|references|libri?\s+di\s+testo|letture|literature)\b(.*)$")
# inizio di un'altra sezione del programma
FINE_SEZIONE = re.compile(
    r"(?i)^\s*(?:\d+[.)]?\s*)?(?:didattica\b|metodo e criteri|metodi? didattic|avvertenze|orario e luogo|ricevimento|"
    r"orario di ricevimento|teaching method|assessment method|method and criteria|notices|office hours|"
    r"modalit[àa] (?:di|d['’]) ?(?:esame|verifica|valutazione|accertamento)|programma del corso|programma d['’]esame|"
    r"course (?:content|programme|program|description)|obiettiv|prerequisit|valutazione|criteri di valutazione|"
    r"verifica dell['’]apprendimento|contenuti del corso|risultati di apprendimento|learning (?:outcomes|objectives)|"
    r"intended learning|aims|area (?:informativa|dei contenuti|della valutazione|delle attivit)|argomenti|"
    r"modalit[àa]|frequenza|note\b|avvisi|syllabus|prerequisites|lingua insegnamento|contenuti|"
    r"altre informazioni|other information)")
NUMERATA_MINUSCOLA = re.compile(r"^\d{1,2}[.)]\s+[a-zà-ÿ]")

# sottotitoli che fissano il tipo
OBBLIGATORIO = re.compile(r"(?i)\b(obbligator\w*|adottat\w*|required|mandatory|indispensabil\w*|testo base|basic text)\b")
CONSIGLIATO = re.compile(r"(?i)\b(consigliat\w*|suggerit\w*|facoltativ\w*|recommended|suggested|optional|further|"
                         r"approfondiment\w*|supplementar\w*|integrativ\w*|di approfondimento|additional)\b")
# righe che non sono libri
NEGATIVE = re.compile(
    r"(?i)(blackboard|moodle|verranno|saranno|sar[àa] (?:indicat|comunicat|fornit|messo|reso|dat)|fornit[eoi]|"
    r"indicat[eoi] (?:a|dal|durante|nel)|comunicat[eoi]|will be|provided|available|disponibil\w*|durante|during|"
    r"slide|appunti|lucidi|dispensa|lecture notes|piattaforma|sito web|pagina web|e-?mail|@|https?://|www\.|"
    r"studenti|students|docente|lecturer|professor|esame|exam\b|frequent)")
PAROLE_NOME = {"and", "e", "&", "de", "di", "del", "della", "van", "von", "der", "den", "la", "le", "el", "dos", "da",
               "du", "des", "y", "ed", "eds", "ed.", "by", "a", "cura", "of"}


def _pulisci(t: str) -> str:
    t = re.sub(r'HYPERLINK\s+"[^"]*"', " ", t)
    t = re.sub(r"(?i)\s*Acquista da VP\b", "", t)
    t = re.sub(r"(?i)\s*(?:disponibile|acquista|vai) (?:su|alla scheda|da)\s+(?:libreria|librerie)[\w. ]*$", "", t)
    return re.sub(r"\s+", " ", t.replace("\xa0", " ")).strip()


def righe_docx(data: bytes) -> list[str] | None:
    try:
        x = zipfile.ZipFile(io.BytesIO(data)).read("word/document.xml").decode("utf-8", "replace")
    except (zipfile.BadZipFile, KeyError):
        return None
    righe = []
    for p in re.findall(r"<w:p[ >].*?</w:p>", x, re.S):
        p = re.sub(r"<w:(?:br|cr)\s*/?>|<w:tab\s*/?>", " ", p)
        t = _pulisci(html.unescape(re.sub(r"<[^>]+>", "", p)))
        if t:
            righe.append(t)
    return righe


def righe_pdf(data: bytes) -> list[str] | None:
    exe = shutil.which("pdftotext")
    testo = None
    if exe:
        with tempfile.TemporaryDirectory() as tmp:
            f = pathlib.Path(tmp) / "p.pdf"
            f.write_bytes(data)
            try:
                r = subprocess.run([exe, "-enc", "UTF-8", "-nopgbrk", "-layout", str(f), "-"], capture_output=True,
                                   timeout=120)
                if r.returncode == 0:
                    testo = r.stdout.decode("utf-8", "replace")
            except (OSError, subprocess.SubprocessError):
                testo = None
    if testo is None:
        try:
            from pypdf import PdfReader
            testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages)
        except Exception:  # noqa: BLE001
            return None
    righe: list[str] = []
    for r in testo.splitlines():
        r = _pulisci(r)
        if not r:
            continue
        # riga a capo nel mezzo di una frase: «… Springer Italia» / «2007 (fornito in formato digitale)»
        if righe and re.match(r"[a-zà-ÿ(]", r) and not re.match(r"^\d{1,2}[.)]\s+\S", righe[-1]):
            righe[-1] += " " + r
        else:
            righe.append(r)
    return righe


def testata_biblio(r: str) -> tuple[bool, str]:
    """(è il titolo di una sezione di bibliografia, testo che segue il titolo sulla stessa riga)."""
    m = TESTATA.match(r)
    if not m:
        return False, ""
    resto = m.group(2).strip()
    if ":" in resto[:45]:
        titolo, _, contenuto = resto.partition(":")
        if len(titolo) <= 40 and "." not in titolo:
            return True, contenuto.strip()
    if len(resto) <= 40 and "." not in resto and "," not in resto:
        return True, ""
    return False, ""


def fine_sezione(r: str) -> bool:
    if len(r) > 100:
        return False
    if FINE_SEZIONE.match(r) and not TESTATA.match(r):
        return True
    return bool(NUMERATA_MINUSCOLA.match(r)) and not TESTATA.match(re.sub(r"^\d{1,2}[.)]\s*", "", r))


EDIZIONE = re.compile(r"(?i)\b(?:\d+(?:st|nd|rd|th|a|ª|°)?\s*(?:edition|edizione|ed\.)|(?:edition|edizione)\s*\d+)")


def _forma_citazione(r: str) -> bool:
    """«Autori, titolo, …» senza editore: nome (o iniziali) prima della prima virgola, poi altro testo.
    Vale anche un titolo con l'edizione («Head First Java, 3rd Edition»)."""
    if NEGATIVE.search(r) or r.endswith(":") or not 8 <= len(r) <= 400:
        return False
    if EDIZIONE.search(r) and re.match(r"[A-ZÀ-Ý“\"']", r) and 2 <= len(r.split()) <= 16:
        return True
    if len(r) < 20 or "," not in r:
        return False
    prima = re.sub(r"\([^)]*\)", " ", r.split(",", 1)[0]).strip()
    parole = prima.split()
    if not (1 <= len(parole) <= 7) or not re.match(r"[A-ZÀ-Ý“\"']", prima):
        return False
    if not all(re.match(r"[A-ZÀ-Ý][\w'’.\-]*$", w) or w.lower() in PAROLE_NOME for w in parole):
        return False
    return len(r.split()) >= 4


def _tipo_sottotitolo(r: str) -> tuple[bool, str | None]:
    """(è un sottotitolo, tipo che fissa). Sottotitolo = riga breve senza punto finale che non cita un'opera."""
    if len(r) > 80 or r.endswith(".") or re.search(r"\b(19|20)\d\d\b", r) or r.count(",") > 1:
        return False, None
    if OBBLIGATORIO.search(r) and not CONSIGLIATO.search(r):
        return True, "obbligatorio"
    if CONSIGLIATO.search(r):
        return True, "consigliato"
    return (r.endswith(":") or r.isupper() or len(r) <= 40), None


def _libri_sezione(testi: list[str]) -> list[dict]:
    libri, viste = [], set()
    tipo_corrente = None
    for r in testi:
        sott, tipo = _tipo_sottotitolo(r)
        if sott and not estrai_libri("<br>" + html.escape(r)):
            tipo_corrente = tipo
            continue
        parti = [r]
        if r.count(";") >= 1 and all(len(p.strip()) >= 15 for p in r.split(";")):
            parti = [p.strip() for p in r.split(";")]
        elif len(re.findall(r"(?:^|\s)\(?\d{1,2}\)\s+[A-ZÀ-Ý]", r)) >= 2:
            parti = [p.strip() for p in re.split(r"(?:^|\s)\(?\d{1,2}\)\s+(?=[A-ZÀ-Ý])", r) if p.strip()]
        for p in parti:
            trovati = estrai_libri("<br>" + html.escape(p))
            if not trovati and _forma_citazione(p):
                trovati = [_libero(p)]
            for lb in trovati:
                cit = lb["citazione"]
                if (not lb.get("isbn") and not re.search(r"\b(?:19|20)\d\d\b", cit) and not _EDITORI_CIT.search(cit)
                        and NEGATIVE.search(cit)):
                    continue  # prosa («… verranno indicati su Blackboard»), non una citazione
                if lb.get("tipo") is None and tipo_corrente:
                    lb["tipo"] = tipo_corrente
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(lb)
    return libri


def leggi_programma(data: bytes, formato: str = "docx") -> dict:
    """Docente, bibliografia e intestazione (prime righe) di un programma .docx o .pdf."""
    righe = righe_docx(data) if formato == "docx" else righe_pdf(data)
    if not righe:
        return {"docenti": [], "libri": [], "righe": 0, "intestazione": [], "bibliografia": False}
    docenti = []
    for r in righe[:6]:
        m = re.match(r"(?i)prof(?:\.|ssa\.?|essor)?\s+(.*)", r)
        if m:
            docenti += [d.strip(" .;") for d in re.split(r";|,|\s+e\s+|\s+and\s+", m.group(1)) if d.strip(" .;")]
    testi, dentro, trovata = [], False, False
    for r in righe:
        testata, contenuto = testata_biblio(r)
        if testata:
            dentro = trovata = True
            if contenuto:
                testi.append(contenuto)
            continue
        if dentro and fine_sezione(r):
            dentro = False
            continue
        if dentro:
            testi.append(r)
    return {"docenti": sorted(set(docenti)), "libri": _libri_sezione(testi), "righe": len(righe),
            "intestazione": righe[:4], "bibliografia": trovata}


# --- il programma è proprio quello dell'insegnamento? ---------------------------------------------

GENERICHE = {"lingua", "language", "corso", "course", "laboratorio", "laboratory", "modulo", "module", "with", "dell",
             "della"}


def _ascii(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", " ", unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()).strip()


def _parole(s: str) -> set[str]:
    return {w for w in _ascii(re.sub(r"\([^)]*\)", " ", s or "")).split() if len(w) >= 4 and w not in GENERICHE}


def coerente(intestazione: list[str], url: str, nome: str, codice: str | None) -> bool:
    """Il programma è proprio quello dell'insegnamento? (alcuni link dell'ateneo puntano a un altro file)"""
    testo = " ".join(intestazione)
    if codice and re.search(rf"(?i)\b{re.escape(codice)}\b", testo + " " + url):
        return True
    voluto = _parole(nome)
    if not voluto:
        return True
    base = pathlib.PurePosixPath(url.split("?")[0]).name
    return bool(voluto & (_parole(testo) | _parole(re.sub(r"[_\-.]+", " ", base))))
