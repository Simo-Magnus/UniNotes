"""Tor Vergata: testi d'esame dalle schede insegnamento (PDF) pubblicate sui siti dei corsi di studio.

I siti dei corsi (macroaree di Lettere, Scienze, Medicina, Ingegneria, Economia…) pubblicano per
ogni insegnamento la «Scheda insegnamento» in PDF, con gli stessi campi di GOMP (codice, docente,
programma, testi adottati, bibliografia). Dove il docente non ha compilato GOMP, la scheda c'è.

1. `trova_pdf(radice)`: dal sito del corso si seguono (al massimo 2 livelli, solo lo stesso sito) le
   pagine di insegnamenti/programmi e si raccolgono i link ai PDF;
2. `leggi_pdf(url)`: scaricato (cache) e convertito in testo con `pdftotext` (poppler, già presente);
3. `parse_scheda(pdf)`: anno accademico, codice, nome, docente e testo dei libri;
4. l'abbinamento agli insegnamenti (per codice o per nome) è in `uniroma2.py`.

Il tipo (obbligatorio/consigliato) resta `None`: nelle schede «Facsimile» i campi «Testi adottati» e
«Bibliografia di riferimento» escono dal PDF in un ordine che non permette di distinguerli.
"""
from __future__ import annotations

import hashlib
import html
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time
from urllib.parse import urldefrag, urljoin, urlparse

import requests

from .unibo import HEADERS
from .testi import _EDITORI_CIT, YEAR
from .uniroma2 import _blocchi_libero

SEGUI = re.compile(r"insegnament|programm|syllabus|schede|piano|piani|2026[-/ ]?(?:20)?27|a\.a\. ?2026|offerta|didattic|"
                   r"corsi|esami|curricul|manifest", re.I)
NON_SEGUIRE = re.compile(r"wp-json|/feed|/tag/|/category/|/author/|\?replytocom|/news|avvisi|bandi|erasmus|tirocin|"
                         r"\.(jpg|png|gif|zip|docx?|xlsx?|pptx?)$|/wp-login|calendario-lezioni|orario|laurea/|seduta|"
                         r"elezioni|rappresentant|2019|2020|2021|2022|2023|2024[-/_]?2025|2024-25", re.I)
HOST_OK = re.compile(r"(^|\.)uniroma2\.it$|laureesanitarietorvergata\.it$|infermieritorvergata\.net$", re.I)
HOST_NO = re.compile(r"^(web|orientamento|studenti|delphi|directory|didattica|didatticaweb|form|placement|cla|clici)"
                     r"\.uniroma2\.it$|^www-20\d\d\.studenti", re.I)
PDF_NO = re.compile(r"(^|[-_/ ])cv([-_. ]|$)|curricul|regolament|manifest|bando|graduator|avviso|modulo|orario|locandina|"
                    r"decreto|verbal|commission|calendar|sedute|laurea-|tesi|erasmus|tirocini", re.I)
_INTESTAZIONI = re.compile(r"(?im)^(?:Italiano|Inglese|English|Bibliografia di riferimento|Testi adottati)\s*$")
_FINE = re.compile(r"Università degli Studi di Roma|Facsimile Scheda|Modalità di svolgimento|DESCRIZIONE DELLE MODALIT|"
                   r"Macroarea di Scienze|MODALITÀ DI|Scheda di Insegnamento", re.I)
_SIGLA_FINE = re.compile(r"(?:\b[A-Z]|\bpp|\bvol|\bvoll|\bed|\beds|\bcap|\bn|\bnn|\bcfr|\bet al|\bs\.v|\bp)\.$")
_INIZIO_VOCE = re.compile(r"^(?:[-•*·●▪–]|\(?\d{1,2}[.)]|[a-z]\)|\[\d+\])\s*\S")


def _sito(netloc: str) -> str:
    return re.sub(r"^www(?:-20\d\d)?\.", "", netloc)


class Web:
    """HTTP con pausa (2 richieste/s per sito) e cache su disco (UN_HTTP_CACHE, cartella «uniroma2_testi»)."""

    def __init__(self, gap: float = 0.55):
        self.s, self.gap, self.last = requests.Session(), gap, {}
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "uniroma2_testi" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, url: str, binario: bool = False, max_byte: int = 8_000_000):
        f = self.dir / hashlib.sha1(url.encode()).hexdigest() if self.dir else None
        if f and f.exists():
            b = f.read_bytes()
            return b if binario else b.decode("utf-8", "replace")
        host = urlparse(url).netloc
        attesa = self.last.get(host, 0) + self.gap - time.monotonic()
        if attesa > 0:
            time.sleep(attesa)
        self.last[host] = time.monotonic()
        try:
            r = self.s.get(url, headers=HEADERS, timeout=60, stream=True)
            if r.status_code != 200 or int(r.headers.get("content-length") or 0) > max_byte:
                r.close()
                return None
            b = r.content
        except requests.RequestException:
            return None
        if f:
            f.write_bytes(b)
        return b if binario else b.decode("utf-8", "replace")


def trova_pdf(w: Web, radice: str, max_pagine: int = 60, max_prof: int = 2) -> dict[str, str]:
    """PDF raggiungibili dal sito del corso: {url: testo del link}."""
    base = _sito(urlparse(radice).netloc)
    visti, coda, pdf, n = {urldefrag(radice)[0].rstrip("/")}, [(radice, 0)], {}, 0
    while coda and n < max_pagine:
        u, d = coda.pop(0)
        t = w.get(u)
        if not t:
            continue
        n += 1
        for h, l in re.findall(r'<a [^>]*href="([^"#]+)"[^>]*>(.*?)</a>', t, flags=re.S | re.I):
            l = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", l))).strip()
            h = urljoin(u, html.unescape(h))
            pu = urlparse(h)
            if pu.scheme not in ("http", "https"):
                continue
            k = urldefrag(h)[0].rstrip("/")
            if pu.path.lower().endswith(".pdf"):
                pdf.setdefault(k, l)
                continue
            if k in visti or d >= max_prof or not HOST_OK.search(pu.netloc) or HOST_NO.search(pu.netloc):
                continue
            if _sito(pu.netloc) != base or NON_SEGUIRE.search(pu.path + "?" + pu.query) or not SEGUI.search(l + " " + pu.path):
                continue
            visti.add(k)
            coda.append((h, d + 1))
    return pdf


def anno_ok(url: str, testo_link: str) -> bool:
    """Scarta i PDF che dal nome o dalla cartella di caricamento sono di anni precedenti al 2024/25."""
    s = url + " " + testo_link
    anni = {int(m.group(1)) for m in re.finditer(r"(20\d\d)\s*[-_/]\s*(?:20)?\d\d", s)}
    anni |= {2000 + int(m.group(1)) for m in re.finditer(r"\b(2[2-7])[-_](?:2[3-8])\b", s)}
    up = re.search(r"(?:uploads|files)/(20\d\d)/(\d\d)", url)
    if anni and max(anni) < 2024:
        return False
    if up and (int(up.group(1)), int(up.group(2))) < (2024, 6) and not (anni and max(anni) >= 2024):
        return False
    return not PDF_NO.search(url.rsplit("/", 1)[-1] + " " + testo_link)


def leggi_pdf(w: Web, url: str) -> dict | None:
    """Testo del PDF: `raw` (ordine di lettura, per i testi) e `testata` (prima pagina con `-layout`:
    nelle schede «Facsimile» è l'unico modo di avere etichetta e valore sulla stessa riga)."""
    b = w.get(url, binario=True)
    if not b or not b.startswith(b"%PDF") or not shutil.which("pdftotext"):
        return None
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "s.pdf"
        p.write_bytes(b)
        try:
            raw = subprocess.run(["pdftotext", "-raw", "-enc", "UTF-8", "-l", "150", str(p), "-"], capture_output=True,
                                 timeout=90).stdout.decode("utf-8", "replace")
            testata = subprocess.run(["pdftotext", "-layout", "-enc", "UTF-8", "-l", "1", str(p), "-"],
                                     capture_output=True, timeout=90).stdout.decode("utf-8", "replace")
        except (subprocess.TimeoutExpired, OSError):
            return None
    return {"raw": raw, "testata": testata}


def unisci_righe(brano: str) -> str:
    """Le righe del PDF vanno a capo a metà citazione: si uniscono, salvo che inizi una nuova voce
    (elenco puntato/numerato, o riga maiuscola dopo una riga che finisce con punto e non con una sigla)."""
    voci: list[str] = []
    for r in brano.replace("\xa0", " ").split("\n"):
        r = re.sub(r"\s+", " ", r).strip()
        if not r:
            continue
        if voci and not _INIZIO_VOCE.match(r):
            prec = voci[-1]
            nuova = (prec.endswith((".", ";", ":", "!", "?")) and not _SIGLA_FINE.search(prec)
                     and re.match(r"[A-ZÀ-Ý\"“«]", r)) or bool(
                re.match(r"(?:[A-ZÀ-Ý]\.\s?){1,3}[A-ZÀ-Ý]", r) and (YEAR.search(prec) or _EDITORI_CIT.search(prec) or len(prec.split()) <= 4))
            if not nuova:
                voci[-1] = f"{prec} {r}"
                continue
        voci.append(r)
    return "\n".join(voci)


_INIZIO_TESTI = re.compile(r"(?im)^(?:Testi adottati(?: e bibliografia di riferimento)?|Testi consigliati|Testi di riferimento|"
                           r"Bibliografia di riferimento|Libri di testo)[ \t]*(?:Italiano[ \t]+English|Italiano)?[ \t]*:?[ \t]*$")
_FINE_TESTI = re.compile(r"(?im)^(?:Modalità(?: di)?\b|MODALIT[ÀA]\b|Prerequisiti|Obiettivi formativi|OBIETTIVI FORMATIVI|"
                         r"Programma\b|PROGRAMMA\b|FACOLT[ÀA] DI MEDICINA|Università degli Studi di Roma|Facsimile Scheda|"
                         r"DESCRIZIONE DELLE|Macroarea di|Scheda di Insegnamento|Metodi didattici|Criteri|Frequenza|"
                         r"Descrizione della modalit)")
_INIZIO_TESTI_ANY = re.compile(r"(?im)^(?:Testi adottati|Testi consigliati|Testi di riferimento|Libri di testo)\b")
_ETICHETTE = re.compile(r"(?im)^(?:Italiano|Inglese|English|ITALIANO|INGLESE|Italiano English|Bibliografia di riferimento|"
                        r"BIBLIOGRAFIA DI RIFERIMENTO|Testi adottati|TESTI ADOTTATI)[ \t]*$")


def brano_testi(raw: str, scienze: bool = False) -> str:
    """Righe sotto «Testi adottati»/«Bibliografia di riferimento»: dal titolo alla sezione successiva (modalità,
    prerequisiti, intestazione di pagina). Le etichette Italiano/Inglese sono tolte."""
    righe = raw.replace("\r", "").replace("\x0c", "\n").split("\n")
    out: list[str] = []
    i = 0
    while i < len(righe):
        if _INIZIO_TESTI.match(righe[i].strip()):
            j = i + 1
            inizio_seg, salta = len(out), False
            while j < len(righe) and not _FINE_TESTI.match(righe[j].strip()):
                r = righe[j].strip()
                if scienze and r == "English" and out:
                    break
                if re.fullmatch(r"(?i)inglese|english", r) and len(out) > inizio_seg:
                    salta = True  # traduzione inglese del campo: si salta fino all'etichetta italiana o al titolo seguente
                elif re.fullmatch(r"(?i)italiano", r) or _INIZIO_TESTI.match(r):
                    salta = False
                    if _INIZIO_TESTI.match(r):
                        inizio_seg = len(out)
                elif not salta and not _ETICHETTE.match(r):
                    out.append(righe[j])
                j += 1
            i = j
        else:
            i += 1
    return "\n".join(out)


def parse_scheda(pdf: dict, url: str = "") -> dict | None:
    """Scheda insegnamento (Facsimile GOMP, Macroarea di Scienze, Scheda Didattica di Medicina): campi e libri."""
    raw, testata = pdf["raw"].replace("\r", ""), pdf["testata"].replace("\r", "")
    if "Scheda Didattica" in raw[:600]:
        mod = "medicina"
    elif "Scheda di Insegnamento / Attività Formativa" in raw:
        mod = "scienze"
    elif re.match(r"(?is)\s*SCHEDA DI INSEGNAMENTO\b", raw[:200]) and re.search(r"(?m)^Insegnamento:", raw):
        mod = "scheda2"
    elif re.search(r"(?i)Scheda insegnamento", raw[:1500]):
        mod = "facsimile"
    elif _INIZIO_TESTI_ANY.search(raw) and re.search(r"(?i)obiettivi formativi|programma", raw) and len(raw) < 70000:
        mod = "generico"
    else:
        return None
    nome = modulo = docente = cds = cod = aa = codice = None
    if mod == "facsimile":
        aa = re.search(r"A\.A\.\s*(20\d\d)\s*[/-]\s*(?:20)?(\d\d)", testata) or re.search(
            r"A\.A\.\s*(20\d\d)\s*[/-]\s*(?:20)?(\d\d)", raw[:3000])
        cod = re.search(r"\bCodice\s+(\d{5,})", testata) or re.search(r"\bCodice\s+(\d{5,})", raw[:3000])
        it = re.findall(r"(?m)^[ \t]*Italiano[ \t]+(\S[^\n]*?)[ \t]*$", testata)
        nome = it[0] if it else None
        modulo = it[1] if len(it) > 1 else None
        cog = re.findall(r"(?m)^[ \t]*Cognome[ \t]+(\S[^\n]*?)[ \t]*$", testata)
        docente = cog[0] if cog else None
        m = re.search(r"(?m)\bCdS[ \t]+(\S[^\n]*?)[ \t]*$", testata)
        cds = m.group(1) if m else None
        if not nome:  # modello senza etichetta e valore sulla stessa riga: si legge l'ordine di lettura
            m = re.search(r"Denominazione insegnamento/attivit\S+ formativa\s*\n(?:\s*(?:ITALIANO|INGLESE|Italiano|Inglese|"
                          r"English)(?: (?:INGLESE|English|Inglese))?\s*\n)*([^\n]+)", raw)
            nome = m.group(1).strip() if m else None
        if not docente:
            m = re.search(r"Cognome\s+(\S[^\n]*)", raw[:3000]) or re.search(
                r"Docente responsabile[^\n]*\n\s*([A-ZÀ-Ý][^\n]{2,60})\n", raw[:3000])
            docente = m.group(1).strip() if m else None
        if not cod:
            cod = re.search(r"\b(8\d{6,8})\b", raw[:3000])
    elif mod == "scheda2":  # «SCHEDA DI INSEGNAMENTO / Corso di Studi: … / Docente: … / Insegnamento: …» (Scienze motorie)
        nomi = re.findall(r"(?m)^Insegnamento:\s*(.+)$", raw[:3000])
        nome, modulo = nomi[0].strip(), (nomi[1].strip() if len(nomi) > 1 else None)
        docente = " ".join(re.findall(r"(?m)^Docente:\s*(.+)$", raw[:3000])) or None
        m = re.search(r"(?m)^Corso di Studi:\s*(.+)$", raw[:600])
        cds = m.group(1).strip() if m else None
        aa = re.search(r"(?i)a\.?a\.?\s*(20\d\d)\s*[/-]\s*(?:20)?(\d\d)", raw[:3000])
    elif mod == "generico":
        aa = re.search(r"(20\d\d)\s*[/-]\s*(?:20)?(\d\d)", raw[:1500])
        cod = re.search(r"\b(8\d{6,8})\b", raw[:3000])
    elif mod == "scienze":
        aa = re.search(r"A\.A\.\s*(20\d\d)\s*[/-]\s*(?:20)?(\d\d)", raw)
        cod = re.search(r"\bCodice\s+(\d{5,})", raw)
        m = re.search(r"DENOMINAZIONE INSEGNAMENTO / ATTIVIT\S+ FORMATIVA\s*\n([^\n]+)", raw)
        nome = m.group(1).strip() if m else None
        m = re.search(r"CdS\s+([^\n]+)", raw)
        cds = m.group(1).strip() if m else None
        m = re.search(r"DOCENTE RESPONSABILE[^\n]*\n([^\n]+)", raw)
        docente = m.group(1).strip() if m else None
    else:  # Scheda Didattica di Medicina e Chirurgia (corsi di laurea sanitari, Medicina e chirurgia)
        m = re.search(r"Scheda Didattica[^\n]*\n\s*(\d{5,})\s*[-–]?\s*([^\n(]+)", raw)
        if m:
            codice, nome = m.group(1), m.group(2).strip()
        else:
            m = re.search(r"Corso [Ii]ntegrato(?: di)?\s*\n?\s*([^\n]+?)\s*(?:[-–]\s*(8\d{6,8}))?\s*(?:\(\d+ CFU\))?\s*\n", raw[:1500])
            if m:
                nome, codice = m.group(1).strip(), m.group(2)
            else:
                m = re.search(r"Scheda Didattica[^\n]*\n([^\n]+?)\s*(?:\d+\s+\d+\s+CFU|\(\d+ CFU\)|\d+ CFU)\s*\n", raw[:1500])
                nome = m.group(1).strip() if m else None
        m = re.search(r"CDL\s+([^\n]+)", raw) or re.search(r"CORSO DI LAUREA(?: MAGISTRALE)?(?: IN|:)\s*([^\n]+)", raw[:600])
        cds = m.group(1).strip() if m else None
    brano = brano_testi(raw, scienze=(mod == "scienze"))
    if cod is not None:
        codice = cod.group(1)
    if not codice:  # il codice è spesso all'inizio del nome del file (8059235-ADO-2.pdf, 804004090_Sabatini.pdf)
        m = re.search(r"(?<!\d)(8\d{6,8})(?!\d)", url.rsplit("/", 1)[-1])
        codice = m.group(1) if m else None
    if aa:
        anno_ini = int(aa.group(1))
    else:  # anno dal titolo («Scheda Didattica 2025-2026») o dalla cartella di caricamento
        m = re.search(r"(20\d\d)\s*[-/]\s*(?:20)?(\d\d)", raw[:300]) or re.search(r"(?<!\d)(20\d\d)[-_](\d\d)(?!\d)", url)
        up = re.search(r"(?:uploads|files)/(20\d\d)/(\d\d)/", url)
        anno_ini = int(m.group(1)) if m else (
            (2026 if (int(up.group(1)), int(up.group(2))) >= (2026, 6) else 2025 if (int(up.group(1)), int(up.group(2))) >= (2025, 6) else None)
            if up else None)
    return {"modello": mod, "aa_inizio": anno_ini, "codice": codice,
            "nome": nome, "modulo": modulo, "cds": cds, "docente": docente, "testi": unisci_righe(brano)}


_TESTA_RACCOLTA = re.compile(r"^(?P<n>[^()\n]{4,90}?)\s*\((?P<d>(?:con )?[A-ZÀ-Ý][A-Za-zÀ-ÿ'’. ,-]{3,70})\)\s*$")
_VOCE_LIBRO = re.compile(r"^(?:(?:[A-ZÀ-Ý]\.\s?){1,3}[A-ZÀ-Ý]|[A-ZÀ-Ý][\w'’-]+,\s(?:[A-ZÀ-Ý]\.\s?)+)")


def parse_raccolta(pdf: dict) -> list[dict]:
    """Un solo PDF con i programmi di tutti gli insegnamenti di un corso («Nome insegnamento (Docente)» seguito dal
    programma e dai testi, come quello di Filosofia): una scheda per insegnamento. Dei testi si tengono solo le
    righe che iniziano come un riferimento bibliografico (iniziale e cognome dell'autore)."""
    raw = pdf["raw"].replace("\r", "").replace("\x0c", "\n")
    righe = raw.split("\n")
    teste = [(k, m) for k, r in enumerate(righe) if (m := _TESTA_RACCOLTA.match(r.strip()))]
    if len(teste) < 8 or not re.search(r"(?i)programmi", raw[:600]):
        return []
    aa = re.search(r"(?i)anno accademico\s+(20\d\d)\s*[-/]", raw[:600])
    out = []
    for n, (k, m) in enumerate(teste):
        fine = teste[n + 1][0] if n + 1 < len(teste) else len(righe)
        voci = [v for v in unisci_righe("\n".join(righe[k + 1:fine])).split("\n")
                if 20 <= len(v) <= 300 and _VOCE_LIBRO.match(v)]
        out.append({"modello": "raccolta", "aa_inizio": int(aa.group(1)) if aa else None, "codice": None,
                    "nome": m.group("n").strip(), "modulo": None, "cds": None,
                    "docente": re.sub(r"^con ", "", m.group("d")).strip(), "testi": "\n".join(voci)})
    return out


def parse_guida(pdf: dict) -> list[dict]:
    """Guida didattica di un corso di studio con una sezione per insegnamento («NOME / 1° anno – 2° semestre / N CFU –
    settore… / Docente: … / Programma: … / Testi consigliati: … / Modalità di esame: …», come Matematica)."""
    raw = pdf["raw"].replace("\r", "").replace("\x0c", "\n")
    aa = re.search(r"(?i)guida didattica\s+(20\d\d)\s*/", raw[:800])
    righe = raw.split("\n")
    teste = [k for k, r in enumerate(righe) if re.match(r"^\d.{0,3}\s*anno\s*[–-]\s*\d", r.strip())]
    if len(teste) < 5 or not aa:
        return []
    out = []
    for n, k in enumerate(teste):
        fine = teste[n + 1] - 1 if n + 1 < len(teste) else len(righe)
        sez = righe[k + 1:fine]
        doc = next((re.sub(r"^Docente:\s*", "", r).strip() for r in sez[:6] if r.startswith("Docente:")), None)
        testi, dentro = [], False
        for r in sez:
            if re.match(r"(?i)^Testi consigliati\s*:?\s*$", r.strip()):
                dentro = True
                continue
            if dentro and re.match(r"(?i)^(Modalità di esame|Program\s*:|Obiettivi|Prerequisiti|Learning|Recommended|Examination)", r.strip()):
                break
            if dentro:
                testi.append(r)
        out.append({"modello": "guida", "aa_inizio": int(aa.group(1)), "codice": None, "nome": righe[k - 1].strip().title(),
                    "modulo": None, "cds": None, "docente": doc, "testi": unisci_righe("\n".join(testi))})
    return out


def schede_da_pdf(pdf: dict, url: str) -> list[dict]:
    s = parse_scheda(pdf, url)
    return [s] if s else (parse_raccolta(pdf) or parse_guida(pdf))


def libri_da_brano(brano: str) -> list[dict]:
    libri, viste = [], set()
    for lb in _blocchi_libero(brano, ""):
        lb["tipo"] = lb["tipo"] or None
        k = re.sub(r"\W+", "", lb["citazione"].lower())[:60]
        if k not in viste:
            viste.add(k)
            libri.append(lb)
    return libri


def _norm(s: str) -> str:
    import unicodedata
    s = unicodedata.normalize("NFKD", html.unescape(s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def chiavi_nome(nome: str | None) -> set[str]:
    """Nome normalizzato e senza l'indicazione di modulo/canale (A, B, AL, MZ, LM)."""
    n = _norm(nome or "")
    if not n or n in ("inglese", "italiano"):
        return set()
    out = {n}
    m = re.sub(r"\b(?:mod|modulo|canale)\s+[a-z]\b", " ", n)
    while True:
        m2 = re.sub(r"\s+(?:[a-d]|al|mz|lm|unico)$", "", m).strip()
        if m2 == m:
            break
        m = m2
    out.add(re.sub(r"\s+", " ", m).strip())
    return {k for k in out if len(k) >= 4}


_GENERICHE = {"laurea", "lauree", "magistrale", "triennale", "corso", "corsi", "studi", "cdl", "classe", "ciclo", "unico"}
_PAROLE_VUOTE = {"di", "del", "della", "dei", "delle", "degli", "per", "con", "the", "and", "for", "of", "nel", "nella",
                 "sul", "sulla", "alla", "allo", "ed", "una", "uno"}


def _parole(nome: str | None) -> set[str]:
    return {w for w in _norm(nome or "").split() if len(w) >= 3 and w not in _PAROLE_VUOTE}


def _cognomi(testo: str | None) -> set[str]:
    return {t for t in _norm(testo or "").split() if len(t) >= 3}


def _pagina_corsi_economia(w: Web, radice: str) -> tuple[str, str] | None:
    """Pagina «Corsi erogati» / «Courses» di un corso di studio della Facoltà di Economia (stesso gestionale dei siti):
    elenco con codice, nome e docenti, e un link /corso/<id>/ per insegnamento. Si cerca fino a 2 livelli dalla radice."""
    base = _sito(urlparse(radice).netloc)
    visti, coda = {radice.rstrip("/")}, [(radice, 0)]
    while coda:
        u, d = coda.pop(0)
        t = w.get(u)
        if not t:
            continue
        if t.count('class="td"') >= 3 and re.search(r"/(?:corso|course)/\d+/?", t):
            return u, t
        if d >= 2:
            continue
        for h, l in re.findall(r'<a [^>]*href=["\']([^"\'#]+)["\'][^>]*>(.*?)</a>', t, flags=re.S | re.I):
            l = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", l))).strip()
            h = urljoin(u, html.unescape(h))
            pu = urlparse(h)
            if h.rstrip("/") in visti or _sito(pu.netloc) not in (base, "economia.uniroma2.it"):
                continue
            if re.search(r"(?i)corsi erogati|^courses$|elenco corsi|guida didattica|didattica$", l) and \
                    not re.search(r"(?i)non attiv|orario|erasmus|archivio", l + pu.path):
                visti.add(h.rstrip("/"))
                coda.append((h, d + 1))
    return None


def _libri_sezioni(blocco: str, titoli: dict[str, str]) -> list[dict]:
    """Libri nelle sezioni (titolo h3 + contenuto) di una scheda del gestionale di Economia; il tipo viene dal titolo."""
    libri: list[dict] = []
    for titolo_sez, corpo in re.findall(r'<h3 class="spoilerbox">(.*?)</h3>\s*<div class="spoilerbox-content[^"]*">(.*?)</div>',
                                         blocco, flags=re.S):
        ts = html.unescape(re.sub(r"<[^>]+>", "", titolo_sez)).strip().lower()
        tipo = next((v for k, v in titoli.items() if ts.startswith(k)), None)
        if not tipo:
            continue
        testo = html.unescape(re.sub(r"<[^>]+>", "\n", re.sub(r"(?i)<br\s*/?>", "\n", corpo)))
        for lb in libri_da_brano(unisci_righe(testo)):
            lb["tipo"] = lb["tipo"] or tipo
            libri.append(lb)
    return libri


def schede_economia(w: Web, corsi_db: list[dict], anno: int, log=print) -> list[dict]:
    """Syllabus (testi adottati e bibliografia) dalle pagine degli insegnamenti dei corsi di Economia."""
    radici = sorted({c["url"] for c in corsi_db if re.search(r"economia\.uniroma2\.it|globalgovernance\.it", c.get("url") or "")})
    schede: list[dict] = []
    for radice in radici:
        try:
            trovata = _pagina_corsi_economia(w, radice)
        except Exception as e:  # noqa: BLE001
            log(f"[uniroma2-testi] economia {radice}: {e!r}")
            continue
        if not trovata:
            continue
        pagina, t = trovata
        siti = {_sito(urlparse(radice).netloc)}
        for blocco in t.split('class="td"')[1:]:
            det = re.search(r'<span class="detail">\s*(\d{6,9})\s*-', blocco)
            docenti = " ".join(html.unescape(re.sub(r"<[^>]+>", " ", d)) for d in re.findall(r'class="nome-doc"[^>]*>(.*?)</a>', blocco, flags=re.S))
            for h, titolo in re.findall(r"href=['\"]([^'\"]*/(?:corso|course)/\d+/?)['\"][^>]*>\s*<h3[^>]*>(.*?)</h3>", blocco, flags=re.S):
                url = urljoin(pagina, h)
                nome = html.unescape(re.sub(r"<[^>]+>", "", titolo)).strip()
                pag = w.get(url)
                if not pag:
                    continue
                aa = re.search(r'<option value="0">\s*(20\d\d)\s*-', pag)
                blk = pag.split('progbox progbox_0', 1)[1].split('progbox progbox_1', 1)[0] if 'progbox progbox_0' in pag else ""
                it, _, en = blk.partition('class="prog_en"')
                libri = (_libri_sezioni(it, {"testi adottati": "obbligatorio", "bibliografia": "consigliato"})
                         or _libri_sezioni(en, {"books": "obbligatorio", "bibliography": "consigliato"}))
                nome_aa = int(aa.group(1)) if aa else None
                schede.append({"modello": "economia", "aa_inizio": nome_aa, "codice": det.group(1) if det else None,
                               "nome": nome, "modulo": None, "cds": None, "docente": docenti, "testi": "",
                               "libri": libri, "url": url, "siti": siti})
    log(f"[uniroma2-testi] Economia: {len(schede)} schede dai siti dei corsi")
    return schede


def _sito_corso(url: str | None) -> str:
    return _sito(urlparse(url or "").netloc)


def aggiungi_testi(corsi_out: list[dict], corsi_db: list[dict], log=print, anno: int = 2026) -> int:
    """Libri dalle schede PDF dei siti dei corsi, agli insegnamenti ancora senza libri.

    Si usano le schede dell'a.a. `anno`/(anno+1); dove mancano (programmi 2026/27 non ancora pubblicati)
    quelle dei due a.a. precedenti, con l'anno dichiarato nella nota di ogni libro.
    Una scheda va agli insegnamenti con lo stesso codice (in qualunque corso) oppure, in mancanza, con lo stesso nome
    e lo stesso docente ma solo nei corsi il cui sito è quello da cui la scheda è stata raggiunta (lo stesso docente
    può avere programmi diversi per lo stesso nome di insegnamento in corsi di studio diversi).
    """
    w = Web()
    url_corso = {c["id"]: c.get("url") for c in corsi_db}
    radici = sorted({c["url"] for c in corsi_db if (c.get("url") or "").startswith("http") and "gomp.it" not in c["url"]})
    pdf_siti: dict[str, tuple[str, set[str]]] = {}  # url PDF -> (testo link, siti dei corsi da cui è raggiungibile)
    for radice in radici:
        try:
            pdf = trova_pdf(w, radice)
        except Exception as e:  # noqa: BLE001 - un sito che non risponde non ferma gli altri
            log(f"[uniroma2-testi] {radice}: {e!r}")
            continue
        for url, l in pdf.items():
            if anno_ok(url, l):
                pdf_siti.setdefault(url, (l, set()))[1].add(_sito_corso(radice))
    schede: list[dict] = []
    for url, (l, siti) in pdf_siti.items():
        doc = leggi_pdf(w, url)
        for s in (schede_da_pdf(doc, url) if doc else []):
            if (s["aa_inizio"] and anno - 2 <= s["aa_inizio"] <= anno) or (s["aa_inizio"] is None and s["modello"] == "medicina"):
                s["url"], s["siti"] = url, siti
                schede.append(s)
    schede += [s for s in schede_economia(w, corsi_db, anno, log) if s["aa_inizio"] and anno - 2 <= s["aa_inizio"] <= anno]
    log(f"[uniroma2-testi] {len(radici)} siti, {len(pdf_siti)} PDF letti, {len(schede)} schede insegnamento")
    per_codice: dict[str, list[dict]] = {}
    per_nome: dict[str, list[dict]] = {}
    per_cognome: dict[str, list[dict]] = {}
    sito_item: dict[int, str] = {}
    corso_di: dict[int, str] = {}
    nome_corso = {c["id"]: c["nome"] for c in corsi_db}
    for c in corsi_out:
        for i in c["insegnamenti"]:
            sito_item[id(i)] = _sito_corso(url_corso.get(c["id"]))
            corso_di[id(i)] = c["id"]
            if i.get("codice"):
                per_codice.setdefault(i["codice"], []).append(i)
            for k in chiavi_nome(i["nome"]):
                per_nome.setdefault(k, []).append(i)
            for tk in _cognomi(" ".join(i.get("docenti") or [])):
                per_cognome.setdefault(tk, []).append(i)
    raccolta: dict[int, dict] = {}  # id(insegnamento) -> {"i": insegnamento, "v": {anno: [libri]}}
    for s in schede:
        libri = s.get("libri") or libri_da_brano(s["testi"])
        if not libri:
            continue
        bersagli = list(per_codice.get(s["codice"] or "", []))
        if not bersagli:
            doc = _cognomi(s["docente"])
            for k in chiavi_nome(s["nome"]) | chiavi_nome(s["modulo"]):
                for i in per_nome.get(k, []):
                    dbc = _cognomi(" ".join(i.get("docenti") or []))
                    if i not in bersagli and ((doc & dbc) or not doc):
                        bersagli.append(i)
            if not bersagli and doc:  # terzo tentativo: stesso docente e nomi molto simili (parole in comune)
                ts = _parole(s["nome"]) | _parole(s["modulo"])
                migliori, punteggio = [], 0.0
                for t in doc:
                    for i in per_cognome.get(t, []):
                        ti = _parole(i["nome"])
                        if not ts or not ti:
                            continue
                        p = len(ts & ti) / len(ts | ti)
                        if p >= 0.6 and p >= punteggio and i not in migliori:
                            if p > punteggio:
                                migliori, punteggio = [], p
                            migliori.append(i)
                bersagli = migliori
            bersagli = [i for i in bersagli if sito_item.get(id(i)) in s["siti"]]
            if s.get("cds"):  # se il corso di studi della scheda è riconoscibile, solo gli insegnamenti di quel corso
                toks = _parole(s["cds"]) - _GENERICHE
                ok_corsi = {cid for cid, nm in nome_corso.items() if toks & _parole(nm)} if toks else set()
                if ok_corsi:
                    bersagli = [i for i in bersagli if corso_di.get(id(i)) in ok_corsi]
        for i in bersagli:
            r = raccolta.setdefault(id(i), {"i": i, "v": {}})
            lista = r["v"].setdefault(s["aa_inizio"] or 0, [])
            vecchie = {re.sub(r"\W+", "", x["citazione"].lower())[:60] for x in lista}
            nota = ("Scheda insegnamento a.a. %d/%02d: %s" % (s["aa_inizio"], (s["aa_inizio"] + 1) % 100, s["url"])
                    if s["aa_inizio"] else f"Scheda didattica (a.a. non indicato): {s['url']}")
            for lb in libri:
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:60]
                if k not in vecchie:
                    vecchie.add(k)
                    lista.append(dict(lb, note=nota))
    coperti = 0
    for r in raccolta.values():
        i = r["i"]
        if i["libri"]:
            continue
        for a in (anno, anno - 1, anno - 2, 0):
            if r["v"].get(a):
                i["libri"] = r["v"][a]
                i["stato_libri"] = "completo"
                coperti += 1
                break
    log(f"[uniroma2-testi] insegnamenti con libri aggiunti dalle schede PDF: {coperti}")
    return coperti
