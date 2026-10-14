"""Insegnamenti, docenti e libri dell'Università della Campania "Luigi Vanvitelli".

I siti dei dipartimenti (*.unicampania.it, stesso CMS) pubblicano per ogni corso le pagine
"Insegnamenti - CdS … <a.a.>" (o l'elenco nella pagina del corso) con le intestazioni
"N° anno - … semestre" e i link alle schede degli insegnamenti:

  /dipartimento/docenti?MATRICOLA=…&COD_UNITA=…&COD_ATTIVITA=…&AA_OFFERTA=<anno>&SETTORE=…&CFU=…

La scheda (dati U-GOV) ha docente, "Insegnamento di …", SSD, CFU, "Periodo di Erogazione" e
"Testi di riferimento". I moduli di un insegnamento integrato hanno lo stesso COD_ATTIVITA.
Lo stesso indirizzo con il solo `COD_ATTIVITA=<codice>&AA_OFFERTA=<anno>` (su qualsiasi sito di
dipartimento) è la pagina del corso integrato: nome ("C.I. …"), moduli con CFU, SSD, docenti e il
link alla scheda di ciascun modulo; se l'attività ha una sola unità è la scheda stessa.

Dove si trovano i piani:

- pagine HTML con l'elenco e i link alle schede (la maggior parte dei dipartimenti);
- PDF «Insegnamenti attivi» / «Didattica erogata» / «Programmazione didattica» con i link alle
  schede: i link e il testo sotto ciascun link (nome) si leggono dalle annotazioni del PDF, l'anno
  e il semestre dall'intestazione («N° anno», «ANNO I», «SEMESTRE II») più vicina sopra;
- PDF/HTML senza link (Igiene dentale, Ortottica, Odontoiatria…): si leggono i codici delle
  attività («A8401», «A425690») dal testo, con l'anno dalle intestazioni o dalla colonna «A.S.»
  (I.1 = 1° anno, 1° semestre), e il resto (nome, CFU, moduli, docenti, testi) dalla pagina del
  corso integrato;
- elenchi con un articolo per ogni corso integrato (Tecniche di laboratorio biomedico…).

Se per il 2026/27 esiste solo il piano dell'a.a. precedente, si usa quello (i codici delle
attività restano gli stessi) e la fonte dell'insegnamento è il documento dell'a.a. 2025/26; i
testi presi dal programma dell'anno precedente portano la nota nel libro.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import html
import io
import json
import logging
import os
import pathlib
import re
import time
import urllib.parse

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo
from .unipg_testi import libri_unipg

ROOT = pathlib.Path(__file__).resolve().parents[3]
ROMANI = {"i": "1", "ii": "2", "iii": "3", "primo": "1", "secondo": "2", "terzo": "3", "1": "1", "2": "2", "3": "3"}
PAROLE = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
ROM_ANNO = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
_R = r"VI|IV|III|II|I|V"  # numeri romani da 1 a 6 (i più lunghi prima)
_ORD = r"\s*[°º°�]?\s*"  # «1°», «1º», «1�» (° mal codificato), «1»
EVENTI = re.compile(
    r'<a\s[^>]*href="(?P<href>[^"]*/dipartimento/docenti(?:-csa)?\?[^"]*COD_ATTIVITA=[^"]*)"[^>]*>(?P<testo>.*?)</a>'
    r'(?P<dopo>(?:(?!<a\s)[\s\S]){0,400})'
    rf'|(?<![\w/])(?P<anno>[1-6]){_ORD}anno\b|(?<![\w/])(?P<annor>{_R}){_ORD}(?:anno|year)\b|\banno\s+(?P<annor2>{_R})\b(?!\.)'
    r'|\b(?P<annoparola>primo|secondo|terzo|quarto|quinto|sesto)\s+anno\b'
    rf'|(?P<sem>(?<![\w/])(?:III|II|I|primo|secondo|terzo|[123]){_ORD}semest(?:re|er)\b|\bsemestre\s+(?:III|II|I|[123])\b)'
    r'|(?P<annuale>\bannual[ei]\b)', re.I)
# intestazioni di un PDF: all'inizio della riga («ANNO I - 1° SEMESTRE», «2° Anno (CFU 58)», «I anno II semestre»)
_RIGA_ANNO = re.compile(
    rf"^\W*(?:(?P<n>[1-6]){_ORD}anno\b|(?P<r>{_R}){_ORD}anno\b|anno\s*(?:di corso\s*)?(?P<r2>{_R}|[1-6])\b(?!\.)|"
    r"(?P<w>primo|secondo|terzo|quarto|quinto|sesto)\s+anno\b|(?P<en>[1-6])(?:st|nd|rd|th)?\s+year\b|"
    rf"year\s+(?P<en2>[1-6]|{_R})\b|(?P<r3>{_R})\s+year\b|(?P<wen>first|second|third|fourth|fifth|sixth)\s+year\b)", re.I)
_PAROLE_EN = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6}
_SEM = re.compile(
    rf"(?<![\w/])(?P<s1>III|II|I|[12]){_ORD}sem(?:estre|ester)?\b|\bsem(?:estre|ester)\s*(?P<s2>II|I|[12])\b|"
    r"\b(?P<s3>primo|secondo)\s+semestre\b|\b(?P<s4>annual[ei])\b", re.I)
_AS = re.compile(rf"(?<![\w.])(?P<a>{_R})\s*\.\s*(?P<s>[12])\b")  # colonna «A.S.»: I.1°, II.2°
USER_AGENT_PDF = True


def _pulisci(s: str) -> str:
    return s.replace("&nbsp;", " ").replace("&deg;", "°").replace("&ordm;", "º").replace("\xa0", " ")


def _sem_norm(m: re.Match) -> str | None:
    v = (m.group("s1") or m.group("s2") or m.group("s3") or m.group("s4") or "").lower()
    if v.startswith("annual"):
        return "annuale"
    return ROMANI.get(v)


def _anno_riga(m: re.Match) -> int | None:
    if m.group("n"):
        return int(m.group("n"))
    for g in ("r", "r2"):
        v = m.group(g)
        if v:
            return ROM_ANNO.get(v.upper()) or (int(v) if v.isdigit() else None)
    if m.group("w"):
        return PAROLE[m.group("w").lower()]
    for g in ("en", "en2", "r3"):
        v = m.group(g)
        if v:
            return int(v) if v.isdigit() else ROM_ANNO.get(v.upper())
    if m.group("wen"):
        return _PAROLE_EN[m.group("wen").lower()]
    return None


def intestazione(riga: str, max_anno: int = 6) -> tuple[int | None, str | None]:
    """(anno, semestre) di una riga d'intestazione di un PDF, o (None, None). Un anno oltre `max_anno`
    (la durata del corso) si rilegge senza unire i numeri romani spaziati («II I Anno» di un biennio)."""
    riga = riga.strip()
    for r in (re.sub(r"\b([IV]+) (?=[IV]+\b)", r"\1", riga), riga):  # «ANNO I I I» → «ANNO III»
        m = _RIGA_ANNO.match(r)
        if not m:
            continue
        anno = _anno_riga(m)
        if anno and anno <= max_anno:
            resto = r[m.end():]
            s = _SEM.search(resto)
            if m.group("r2") and resto.strip() and not s:
                continue  # «ANNO I SEMESTRE»: intestazione di colonna, non di sezione
            return anno, (_sem_norm(s) if s else None)
    return None, None


def leggi_elenco(s: str, anno_offerta: int) -> list[dict]:
    """Insegnamenti di una pagina "Insegnamenti - CdS …": un elemento per unità didattica."""
    s = _pulisci(s)
    m = re.search(r'itemprop="articleBody"|class="item-page', s)
    s = s[m.start():] if m else s
    fine = s.find("<aside")
    s = s[:fine] if fine > 0 else s
    out, anno, sem = [], None, None
    for e in EVENTI.finditer(s):
        if e.group("anno") or e.group("annoparola") or e.group("annor") or e.group("annor2"):
            if e.group("anno"):
                anno = int(e.group("anno"))
            elif e.group("annoparola"):
                anno = PAROLE[e.group("annoparola").lower()]
            else:
                anno = ROM_ANNO[(e.group("annor") or e.group("annor2")).upper()]
            sem = None
        elif e.group("sem"):
            sem = ROMANI.get(re.match(r"\w+", re.sub(r"(?i)^semestre\s+", "", e.group("sem"))).group(0).lower())
        elif e.group("annuale"):
            sem = "annuale"
        elif e.group("href"):
            ei = re.search(r"\(\s*Modulo\s+dell[’']\s*e\.?\s*i\.?\s*(?:di\s+)?(.*?)\)", _testo(e.group("dopo")), re.I)
            v = _voce(html.unescape(e.group("href")), anno, sem, _testo(e.group("testo")),
                      ei.group(1).strip() if ei else None, anno_offerta)
            if v:
                out.append(v)
    return out


EVENTI_ART = re.compile(EVENTI.pattern.replace('/dipartimento/docenti(?:-csa)?\\?[^"]*COD_ATTIVITA=[^"]*',
                                               '[^"]*/10-didattica/\\d+-[^"]*'), re.I)


def leggi_articoli(s: str) -> list[dict]:
    """Pagina con le intestazioni «I anno I semestre» e un articolo per ogni corso integrato
    (`…/10-didattica/1697-corso-integrato`): (anno, semestre, nome, indirizzo dell'articolo)."""
    s = _pulisci(s)
    m = re.search(r'itemprop="articleBody"|class="item-page', s)
    s = s[m.start():] if m else s
    fine = s.find("<aside")
    s = s[:fine] if fine > 0 else s
    out, anno, sem = [], None, None
    for e in EVENTI_ART.finditer(s):
        if e.group("anno") or e.group("annoparola") or e.group("annor") or e.group("annor2"):
            if e.group("anno"):
                anno = int(e.group("anno"))
            elif e.group("annoparola"):
                anno = PAROLE[e.group("annoparola").lower()]
            else:
                anno = ROM_ANNO[(e.group("annor") or e.group("annor2")).upper()]
            sem = None
        elif e.group("sem"):
            sem = ROMANI.get(re.match(r"\w+", re.sub(r"(?i)^semestre\s+", "", e.group("sem"))).group(0).lower())
        elif e.group("annuale"):
            sem = "annuale"
        elif e.group("href"):
            out.append({"anno": anno, "periodo": sem, "nome": _testo(e.group("testo")),
                        "href": html.unescape(e.group("href"))})
    return out


def _norm_nome(x: str | None) -> str:
    x = re.sub(r"\([^)]*\)", " ", x or "")  # «(Cognomi A-L)», «(IUS/08)», «(862)»
    return re.sub(r"[^a-z0-9]", "", x.lower().replace("*", ""))


def leggi_piano_tabella(s: str) -> list[dict]:
    """Piano in tabella (siti del Dipartimento di Giurisprudenza): righe «SSD | Insegnamento | CFU | Catt. | Semestre» sotto
    le intestazioni «I ANNO», «IV ANNO - Esami comuni», «Esami caratterizzanti - Indirizzo …». Si legge la sezione degli
    immatricolati più recenti e si fermano alla prima sezione di coorti precedenti o alle propedeuticità."""
    s = _pulisci(s)
    m = re.search(r'itemprop="articleBody"', s)
    b = s[m.start():] if m else s
    fine = b.find("<aside")
    b = b[:fine] if fine > 0 else b
    out, anno, curr, sez = [], None, None, 0
    for e in re.finditer(r"<h\d[^>]*>(?P<h>.*?)</h\d>|<tr[^>]*>(?P<r>.*?)</tr>", b, re.S):
        if e.group("h") is not None:
            h = _testo(e.group("h"))
            if re.search(r"(?i)fino all|ad esaurimento|propedeutic", h):
                break
            if re.search(r"(?i)immatricolati dall", h):
                sez += 1
            elif h:
                curr = re.sub(r"(?i)^esami caratterizzanti\s*-\s*", "", h)
            continue
        celle = re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", e.group("r"), re.S)
        testi = [_testo(c) for c in celle]
        if testi and all(not t for t in testi[1:]):
            a, _ = intestazione(testi[0])
            if a:
                anno = a
                if re.search(r"(?i)esami comuni", testi[0]):
                    curr = None
            elif re.search(r"(?i)curriculum|indirizzo", testi[0]):
                curr = testi[0]
            continue
        if len(testi) < 3 or testi[1].upper() == "INSEGNAMENTO" or not anno:
            continue
        nome = re.sub(r"\s*\*+$", "", testi[1]).strip()
        if not nome or nome.startswith("*") or re.match(r"(?i)insegnamento a scelta|a scelta|tirocinio|prova finale|in alternativa", nome):
            continue
        mcfu = re.match(r"(\d+(?:[.,]\d+)?)", testi[2])
        mat = re.findall(r"MATRICOLA=(\d+)", html.unescape(e.group("r")))
        sem = None
        if len(testi) >= 5:
            t = testi[4].lower()
            sem = "annuale" if t.startswith("ann") else ROMANI.get(re.match(r"\w+", t).group(0)) if t else None
        out.append({"anno": anno, "nome": nome, "ssd": testi[0] or None,
                    "cfu": mcfu.group(1).replace(",", ".") if mcfu else None, "periodo": sem,
                    "matricole": mat, "curriculum": curr})
    return out


def leggi_docente(s: str) -> list[dict]:
    """Pagina del docente: gli insegnamenti dell'a.a. con il corso di laurea (titolo del gruppo) e il link alla scheda."""
    s = _pulisci(s)
    i = s.find("Didattica Anno Accademico")
    s = s[i:] if i >= 0 else s
    out, corso = [], None
    for e in re.finditer(r"(?P<c>Corso di laurea(?:\s+magistrale)?(?:\s+a ciclo unico)?\s+in\s+(?P<nome>[^<]+))|"
                         r"""<a\s[^>]*href=['"](?P<href>[^'"]*COD_ATTIVITA=[^'"]*)['"][^>]*>(?P<t>.*?)</a>""", s, re.S):
        if e.group("c"):
            corso = _testo(e.group("nome"))
        elif corso:
            out.append({"corso": corso, "titolo": _testo(e.group("t")), "href": html.unescape(e.group("href"))})
    return out


def _voce(href: str, anno: int | None, sem: str | None, nome: str | None, integrato: str | None,
          anno_offerta: int) -> dict | None:
    q = dict(urllib.parse.parse_qsl(href.split("?", 1)[1]))
    try:
        aa = int(q.get("AA_OFFERTA") or 0)
    except ValueError:
        aa = 0
    if not q.get("COD_ATTIVITA") and not q.get("COD_UNITA") or (aa and aa < anno_offerta - 1):
        return None
    return {"anno": anno, "periodo": sem, "nome": nome or None, "integrato": integrato,
            "cod_unita": q.get("COD_UNITA"), "cod_attivita": q.get("COD_ATTIVITA") or q.get("COD_UNITA"),
            "ssd": None if (q.get("SETTORE") or "NN") == "NN" else q.get("SETTORE"),
            "cfu": q.get("CFU"), "href": href, "cds": q.get("COD_CORSO_STUDIO"), "aa": aa or None}


# ---------------------------------------------------------------------------------------------
# PDF


def _frammenti(pagina) -> list[tuple[float, float, str]]:
    """(x, y, testo) di ogni frammento di testo della pagina."""
    out = []

    def visita(testo, cm, tm, *_):
        if testo and testo.strip():
            out.append((tm[4] * cm[0] + tm[5] * cm[2] + cm[4], tm[4] * cm[1] + tm[5] * cm[3] + cm[5], testo))

    pagina.extract_text(visitor_text=visita)
    return out


def _righe(frammenti: list[tuple[float, float, str]]) -> list[tuple[float, str]]:
    """Righe (y, testo) raggruppando i frammenti con la stessa ordinata."""
    out: list[list] = []
    for x, y, t in sorted(frammenti, key=lambda q: (-round(q[1] / 3), q[0])):
        if out and abs(out[-1][0] - y) < 3:
            out[-1][1].append(t)
        else:
            out.append([y, [t]])
    return [(y, re.sub(r"\s+", " ", " ".join(ts)).strip()) for y, ts in out]


def _pdf_reader(data: bytes):
    from pypdf import PdfReader
    logging.getLogger("pypdf").setLevel(logging.CRITICAL)
    return PdfReader(io.BytesIO(data))


def leggi_pdf(data: bytes, anno_offerta: int, max_anno: int = 6) -> list[dict]:
    """Elenco in PDF con i link alle schede / ai corsi integrati: i link con COD_ATTIVITA si
    assegnano all'anno e al semestre dell'intestazione più vicina sopra di loro nella pagina (se
    non ce ne sono, a quelli della colonna «Anno»/«Sem.» sulla stessa riga); il nome del corso
    integrato è il testo sotto il suo link (più righe dello stesso link si uniscono)."""
    out, anno, sem = [], None, None
    for pg in _pdf_reader(data).pages:
        fr = _frammenti(pg)
        eventi: list[tuple[float, int, object]] = []
        for y, riga in _righe(fr):
            a, s = intestazione(riga, max_anno)
            if a:
                eventi.append((y, 0, (a, s)))
            else:
                m = re.match(r"(?i)^\W*sem(?:estre|ester)\b", riga) and _SEM.search(riga)
                if m:
                    eventi.append((y, 0, (None, _sem_norm(m))))
        gruppi: dict[str, list[tuple]] = {}
        for a in pg.get("/Annots") or []:
            a = a.get_object()
            uri = str((a.get("/A") or {}).get("/URI") or "")
            if "COD_ATTIVITA=" not in uri or "/dipartimento/docenti" not in uri:
                continue
            x0, y0, x1, y1 = (float(z) for z in a["/Rect"])
            gruppi.setdefault(uri, []).append(
                (y1, {(round(x), round(y), t.strip()) for x, y, t in fr
                      if x0 - 2 <= x <= x1 + 2 and y0 - 1 <= y <= y1 + 1 and t.strip()}, x0, (y0 + y1) / 2))
        for uri, rects in gruppi.items():
            y = max(r[0] for r in rects)
            nome = None
            if "COD_UNITA=" not in uri:  # link al corso integrato: il testo sotto il link è il suo nome
                frs = set().union(*(r[1] for r in rects))  # ogni frammento una volta sola
                nome = re.sub(r"\s+", " ", " ".join(t for _, _, t in sorted(frs, key=lambda q: (-q[1], q[0])))).strip() or None
            # colonne «Anno» (I, II, III) e «Sem.» (1°, 2°) sulla stessa riga del link
            x0, ym = min(r[2] for r in rects), rects[0][3]
            riga_anno = [(abs(yy - ym), x0 - x, t) for x, yy, t in fr
                         if abs(yy - ym) < 16 and x < x0 and re.fullmatch(_R, t.strip())]
            riga_sem = [(abs(yy - ym), t.strip()) for x, yy, t in fr if abs(yy - ym) < 16 and re.fullmatch(
                r"[12]\s*[°º�](?:\s*-\s*[12]\s*[°º�])?", t.strip())]
            s_riga = None
            if riga_sem:
                t = min(riga_sem)[1]
                s_riga = "annuale" if len(re.findall(r"[12]", t)) == 2 else t[0]
            eventi.append((y, 1, (uri, nome, ROM_ANNO[min(riga_anno)[2].strip().upper()] if riga_anno else None,
                                  s_riga)))
        for y, tipo, dati in sorted(eventi, key=lambda e: (-e[0], e[1])):
            if tipo == 0:
                a, s = dati
                if a:
                    anno, sem = a, s
                elif s:
                    sem = s
                continue
            uri, nome, a_riga, s_riga = dati
            v = _voce(uri, anno or a_riga, sem or (s_riga if not anno else None), nome, None, anno_offerta)
            if v:
                out.append(v)
    return out


CODICE_ATT = re.compile(r"\b(A\d{4,6})([A-Z])?\b")


_TOK = re.compile(r"\b(A\d{4,6})([A-Z]?)\b")


def _candidati(riga: str, prefisso: str) -> list[str]:
    """Codici di attività della riga, dall'ultimo al primo (il corso integrato sta dopo l'unità: «A7901A … A424500»),
    senza la lettera dell'unità («A7901A» → «A7901»). Vuoto se nessun codice è del corso (`prefisso`)."""
    toks = [m for m in _TOK.finditer(riga)]
    if not any(re.fullmatch(prefisso, m.group(1)) for m in toks):
        return []
    out: list[str] = []
    for m in reversed(toks):
        if m.group(1) not in out:
            out.append(m.group(1))
    return out


def _records_codici(righe: list[tuple[str, int | None, str | None]], prefisso: str) -> list[dict]:
    """Da righe (testo, anno, semestre) ai codici: per ogni riga con un codice del corso, i codici candidati (della riga,
    poi quelli a sei cifre delle righe vicine: nelle tabelle a più righe il corso integrato sta su un'altra riga)
    e le unità della riga (`A7110A`), con cui si controlla la pagina del corso integrato."""
    out = []
    for k, (riga, anno, sem) in enumerate(righe):
        c = _candidati(riga, prefisso)
        if not c:
            continue
        m_as = _AS.search(riga)
        a2, s2 = (ROM_ANNO[m_as.group("a")], m_as.group("s")) if m_as else (anno, sem)
        unita = [m.group(0) for m in _TOK.finditer(riga) if re.fullmatch(prefisso, m.group(1))]
        ctx: list[str] = []
        for j in sorted(range(max(0, k - 12), min(len(righe), k + 5)), key=lambda j: (abs(j - k), j)):
            if j == k:
                continue
            for m in _TOK.finditer(righe[j][0]):
                if len(m.group(1)) == 7 and not m.group(2) and m.group(1) not in c and m.group(1) not in ctx:
                    ctx.append(m.group(1))
        out.append({"cod": c[0], "cands": c, "ctx": ctx, "unita": unita, "anno": a2, "periodo": s2, "riga": riga})
    return out


def leggi_pdf_codici(data: bytes, prefisso: str = r"A\d{4}") -> list[dict]:
    """PDF/testo senza link: codici delle attività (`Cod. C.I. A8401`, `Cod. Attività A8401A`) con
    anno e semestre dall'intestazione («I ANNO - 1° SEMESTRE») o dalla colonna A.S. (I.1)."""
    righe, anno, sem = [], None, None
    for pg in _pdf_reader(data).pages:
        for y, riga in _righe(_frammenti(pg)):
            a, s = intestazione(riga)
            if a:
                anno, sem = a, s
                continue
            righe.append((riga, anno, sem))
    return _records_codici(righe, prefisso)


def leggi_html_codici(s: str, prefisso: str) -> list[dict]:
    """Pagina HTML (articolo) con i codici delle attività nel testo e le intestazioni «I ANNO – 1° SEMESTRE»."""
    s = _pulisci(s)
    m = re.search(r'itemprop="articleBody"|class="item-page', s)
    s = s[m.start():] if m else s
    fine = s.find("<aside")
    s = s[:fine] if fine > 0 else s
    testo = re.sub(r"(?i)<\s*(br|/p|/li|/div|/h\d|/tr|/td)\s*/?>", "\n", s)
    righe, anno, sem = [], None, None
    for riga in html.unescape(re.sub(r"<[^>]+>", "", testo)).splitlines():
        riga = riga.strip()
        a, sm = intestazione(riga)
        if a:
            anno, sem = a, sm
            continue
        righe.append((riga, anno, sem))
    return _records_codici(righe, prefisso)


# ---------------------------------------------------------------------------------------------
# pagine di corso integrato e schede


def _tabella(s: str, nome: str) -> str | None:
    """Testo della riga «nome | valore» delle tabelle della scheda."""
    m = re.search(rf">\s*{nome}\s*</td>\s*<td[^>]*>(.*?)</td>", s, re.S | re.I)
    return m.group(1) if m else None


_PROSA_CAMP = re.compile(
    r"(?i)\b(?:dispens[ae]|slides?|lucidi|appunti|materiale (?:didattico|fornito|integrativo)|materiali didattici|forniti?|fornite|fornisce|disponibil[ei]|teams|moodle|"
    r"lezion[ei]|docente|durante|verr[aà]|sar[aà]|saranno|non prevede|sito|piattaforma|power ?point|ppt|bibliografia dettagliata|"
    r"consigliat[oi] dal|indicat[ao]|studenti|corso)\b")
_ETICHETTA_CAMP = re.compile(r"(?i)^\s*(?:testi?|testo|libri?|libro)(?:\s+(?:di\s+)?(?:riferimento|consigliat[oi]|adottat[oi]|base|di testo))?\s*[:\-]\s*")


def libri_semplici(raw: str) -> list[dict]:
    """Ultima risorsa per i «Testi di riferimento» brevi che il riconoscimento generale scarta: una voce per riga o per «;»,
    purché abbia un autore (iniziale, «et al.», volume) o un editore o un anno, almeno due parole di titolo e nessuna
    parola da prosa («dispense», «slide», «il docente fornirà»…)."""
    from .testi import YEAR, _libero
    out, viste = [], set()
    righe = html_to_lines_camp(raw)
    for riga in righe if not (2 <= len(righe) <= 4 and not any(r.rstrip().endswith(";") for r in righe[:-1])) \
            else [" ".join(righe)]:  # titolo, autori ed editore su righe separate (<br><br>): una sola citazione
        for voce in re.split(r"\s*;\s*|\s+(?=\d{1,2}[.)]\s+[A-ZÀ-Ý])", riga):
            tipo = "consigliato" if re.match(r"(?i)\s*testi?\s+consigliat", voce) else (
                "obbligatorio" if re.match(r"(?i)\s*(?:testi?|libri?)\s+(?:adottat|obbligator)", voce) else None)
            v = _ETICHETTA_CAMP.sub("", voce).strip(" .;,-–•*")
            if not (12 <= len(v) <= 300) or _PROSA_CAMP.search(v):
                continue
            resto = re.sub(r"\b[A-ZÀ-Ý]\.|\bet al\.?|\b(?:19|20)\d\d\b|\bvol\.?\s*\d+|\bed\.?\s*\d*", " ", v)
            parole = [w for w in re.findall(r"[A-Za-zÀ-ÿ']{3,}", resto)]
            segno = bool(re.search(r"\b[A-ZÀ-Ý]\.\s?[A-ZÀ-Ý]|\bet al\b|\bvol\.?\s*\d", v) or YEAR.search(v)
                         or re.search(r"(?i)\b(?:edizioni|editore|editrice|press|zanichelli|pearson|mcgraw|hoepli|springer|wiley|elsevier|"
                                      r"cedam|giappichelli|carocci|il mulino|laterza|utet|edises|piccin|idelson|ambrosiana|esculapio)\b", v))
            if len(parole) < 3 or not segno:
                continue
            k = re.sub(r"\W+", "", v.lower())[:120]
            if k in viste:
                continue
            viste.add(k)
            item = _libero(v)
            item["tipo"] = tipo or item.get("tipo")
            out.append(item)
    return out


def html_to_lines_camp(raw: str) -> list[str]:
    from .testi import html_to_lines
    return html_to_lines(raw)


def leggi_scheda(s: str) -> dict:
    s = _pulisci(s)
    testo = _testo(s)
    # <h2><a href='/dipartimento/docenti?MATRICOLA=...'>Nome COGNOME</a></h2> <h3>Insegnamento di NOME</h3>
    doc = re.search(r"<h2>\s*<a[^>]*MATRICOLA=[^>]*>(.*?)</a>\s*</h2>", s, re.S)
    ins = re.search(r"<h3>\s*Insegnamento di\s+(.*?)</h3>", s, re.S)
    per = re.search(r"Periodo di Erogazione:\s*(\w+)", testo)
    p = (per.group(1).lower() if per else "")
    periodo = "annuale" if p.startswith("annual") else ROMANI.get(p)
    t = re.search(r"Testi di riferimento(.*?)(?:Obiettivi formativi|Prerequisiti|Metodi didattici|English|$)", s, re.S)
    libri = []
    if t:
        libri = estrai_libri(t.group(1))
        if not libri:  # riconoscimento tollerante: elenchi puntati, prosa, voci senza editore
            libri = libri_unipg([t.group(1)])
        if not libri:
            libri = libri_semplici(t.group(1))
    return {"docente": _testo(doc.group(1)) if doc else None, "periodo": periodo,
            "nome": _testo(ins.group(1)) if ins else None, "libri": libri}


def leggi_ci(s: str) -> dict:
    """Pagina `docenti?COD_ATTIVITA=…`: nome del corso integrato, moduli (link alle schede, CFU, SSD) oppure,
    se l'attività ha una sola unità, la scheda stessa (`scheda`)."""
    s = _pulisci(s)
    m = re.search(r'itemprop="articleBody"', s)
    b = s[m.start():] if m else s
    fine = b.find("<aside")
    b = b[:fine] if fine > 0 else b
    ci = re.search(r"<h3>\s*C\.?\s?I\.?\s+(.*?)(?:\(\s*Corso Integrato\s*\))?\s*</h3>", b, re.S | re.I)
    moduli = []
    for href, nome in re.findall(r"""<h3>\s*<a\s+href=['"]([^'"]*COD_UNITA=[^'"]*)['"][^>]*>(.*?)</a>""", b, re.S):
        href = html.unescape(href)
        q = dict(urllib.parse.parse_qsl(href.split("?", 1)[1])) if "?" in href else {}
        moduli.append({"href": href, "nome": _testo(nome), "cod_unita": q.get("COD_UNITA"), "cfu": q.get("CFU"),
                       "ssd": None if (q.get("SETTORE") or "NN") == "NN" else q.get("SETTORE")})
    scheda = None
    if re.search(r"<h3>\s*Insegnamento di\s", b):
        scheda = leggi_scheda(b)
        sc = re.search(r"CFU:\s*([\d.,]+)", _testo(b))
        ssd = re.search(r"SSD:\s*([\w\-/]+)", _testo(b))
        scheda["cfu"] = sc.group(1).replace(",", ".") if sc else None
        scheda["ssd"] = ssd.group(1) if ssd else None
    corso = re.search(r"Corso di laurea(?:\s+magistrale)?(?:\s+a ciclo unico)?\s+in\s+([^<]+)", b, re.I)
    return {"nome": _testo(ci.group(1)) if ci else None, "moduli": moduli, "scheda": scheda,
            "corso": _testo(corso.group(1)) if corso else None}


def stesso_corso(a: str | None, b: str | None) -> bool:
    """Il nome del corso di una pagina U-GOV («FISIOTERAPIA (ABILITANTE …)») coincide con quello del database."""
    def n(x):
        return re.sub(r"[^a-z0-9]", "", (x or "").lower())[:14]
    na, nb = n(a), n(b)
    return bool(na) and bool(nb) and na == nb


class _Scarica(Client):
    """Client con scarico dei PDF (stesso limite di richieste e stessa cache su disco delle pagine)."""

    def pdf(self, url: str) -> bytes | None:
        f = None
        if self.cache:
            f = self.cache / "pdf" / (hashlib.sha1(url.encode()).hexdigest() + ".pdf")
            if f.exists():
                d = f.read_bytes()
                return d or None
        d = b""
        for tentativo in range(3):
            with self.lock:
                attesa = self.last + self.min_gap - time.monotonic()
                if attesa > 0:
                    time.sleep(attesa)
                self.last = time.monotonic()
                self.requests += 1
            try:
                r = self.s.get(url, timeout=120)
            except Exception:  # noqa: BLE001
                time.sleep(2 ** tentativo)
                continue
            if r.status_code == 200 and r.content.startswith(b"%PDF"):
                d = r.content
            if r.status_code in (200, 404):
                break
            time.sleep(2 ** tentativo)
        if f:
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(d)
        return d or None


# ---------------------------------------------------------------------------------------------
# scoperta delle fonti

# a.a. di una fonte: 2026/27 (corrente), 2025/26 (precedente)
_AA2627 = re.compile(r"2026\s*[-/_–]\s*(?:20)?27|(?<!\d)26\s*[-_/]\s*27(?!\d)")
_AA2526 = re.compile(r"2025\s*[-/_–.]\s*(?:20)?26|(?<!\d)25\s*[-_/]\s*26(?!\d)")
_AA2026 = re.compile(r"(?<![\d/-])2026(?!\d)")
_FONTE_CHIAVE = re.compile(r"insegnament|programmazione|piano.{0,5}(?:di )?stud|didattica erogata|offerta didattica|"
                           r"study plan|teaching plan|courses a|erogat|offerta formativa|planning", re.I)
_FONTE_ESCLUDI = re.compile(r"qualit|sedut|tirocin|/orari|MATRICOLA|regolament|ordinament|manifesto|calendar|"
                            r"propedeutic|orario|esami|prova finale|tesi|erasmus", re.I)


def _assoluto(h: str, base: str) -> str:
    h = html.unescape(h).strip()
    if h.startswith("http"):
        return h
    host = re.match(r"https?://[^/]+", base).group(0)
    return host + (h if h.startswith("/") else "/" + h)


def _link_corpo(t: str) -> list[tuple[str, str]]:
    m = re.search(r'itemprop="articleBody"', t)
    b = t[m.start():] if m else t
    e = b.find("<aside")
    b = b[:e] if e > 0 else b
    return re.findall(r'href="([^"#]+)"[^>]*>(.*?)</a>', b, re.S)


def _aa_fonte(testo: str) -> int | None:
    """2026 se il testo (titolo/indirizzo) indica l'a.a. 2026/27, 2025 se 2025/26, altrimenti None."""
    if _AA2627.search(testo):
        return 2026
    if _AA2526.search(testo):
        return 2025
    return 2026 if _AA2026.search(testo) else None


def fonti_corso(c: Client, url: str, anno: int) -> list[tuple[str, str, int]]:
    """Fonti (url, tipo html|pdf, a.a.) della pagina del corso, solo dell'a.a. più recente trovato
    (2026/27, altrimenti 2025/26). Si guardano la pagina del corso e gli articoli «Insegnamenti»/«Piano di studio»
    che essa collega (un livello)."""
    r = c.get(url)
    if not r:
        return []
    trovate: dict[str, tuple[str, int]] = {}
    senza_anno: list[str] = []

    def esamina(t: str, base: str, profondita: int):
        for h, x in _link_corpo(t):
            tx = _testo(x)
            u = _assoluto(h, base)
            s = u + " " + tx
            if _FONTE_ESCLUDI.search(s.replace(base, "")) or not _FONTE_CHIAVE.search(s):
                continue
            aa = _aa_fonte(s)
            if u.lower().endswith(".pdf"):
                if aa and u not in trovate:
                    trovate[u] = ("pdf", aa)
            elif u.startswith(re.match(r"https?://[^/]+", base).group(0)) and "/dipartimento/docenti" not in u:
                if aa and u not in trovate:
                    trovate[u] = ("html", aa)
                elif not aa and profondita == 0 and re.search(r"view=article|insegnament|/10-didattica/", u) \
                        and not re.search(r"20[12]\d|\b\d\d-\d\d\b", s) and u != base:
                    t2 = c.get(u)  # articolo «Insegnamenti» senza anno: è un elenco esso stesso e ha altri link
                    if t2:
                        senza_anno.append(u)
                        esamina(t2.text, u, 1)

    esamina(r.text, r.url, 0)
    extra = [(u, "html", 0) for u in senza_anno]  # elenchi senza a.a. nel titolo: valgono i link delle schede (AA_OFFERTA)
    if not trovate:
        return extra
    migliore = max(aa for _, aa in trovate.values())
    return [(u, k, aa) for u, (k, aa) in trovate.items() if aa == migliore] + extra


# fonti e parametri espliciti dei corsi che la scoperta automatica non trova (id del corso → impostazioni)
#   url:      pagina del corso (se Universitaly non la dà)
#   fonti:    elenco (url, tipo) da leggere al posto della scoperta
#   prefisso: espressione dei codici delle attività del corso (piani senza link)
#   aa:       a.a. dei codici (AA_OFFERTA) da usare per le pagine dei corsi integrati
CORSI: dict[str, dict] = {
    "unicampania-l-35-matematica": {"tutte": True},  # un PDF per curriculum
    # piani senza link alle schede: i codici delle attività si leggono dal testo
    "unicampania-l-snt1-infermieristica": {"prefisso": r"A50\d\d"},
    "unicampania-l-snt2-ortottica": {"prefisso": r"A76\d\d"},
    "unicampania-l-snt3-igiene-dentale": {"prefisso": r"A84\d\d"},
    "unicampania-lm-46-odontoiatria": {"prefisso": r"A42\d{4}"},
    # pagine dei corsi che Universitaly non collega (o collega alla home del dipartimento)
    "unicampania-lm-snt2-scienze-riabilitative": {"url": "http://www.dipmdsmco.unicampania.it/didattica/corsi-di-studio/"
                                                         "scienze-riabilitative-delle-professioni-sanitarie"},
    # Medicina e chirurgia (Caserta): l'elenco 2025/26 collega schede con AA_OFFERTA anche degli anni precedenti
    "unicampania-lm-41-medicina-e-chirurgia": {"aa_indietro": 3},
    # Nursing usa le stesse attività di Infermieristica (la pagina U-GOV porta il nome del corso in italiano)
    "unicampania-l-snt1-nursing": {"prefisso": r"A42\d{4}", "senza_verifica": True, "url": "http://www.scienzemedichetraslazionali.unicampania.it/didattica/corsi-di-studio/nursing-infermieristica-in-lingua-inglese"},
    "unicampania-l-snt2-logopedia": {"prefisso": r"A71\d\d"},
    "unicampania-l-snt2-terapia-della-neuro": {"prefisso": r"A74\d\d"},
    "unicampania-l-snt2-tecnica-della-riabilitazione": {"prefisso": r"A73\d\d"},
    "unicampania-l-snt1-ostetricia": {"prefisso": r"A\d{4}"},
    # Giurisprudenza: piano in tabella; le schede si trovano dalle pagine dei docenti della riga
    "unicampania-lmg-01-giurisprudenza": {
        "url": "https://www.giurisprudenza.unicampania.it/cds-giurisprudenza-online",
        "fonti": [("https://www.giurisprudenza.unicampania.it/studiare-cds-giurisprudenza-online/insegnamenti", "tabella")]},
    "unicampania-lmg-01-giurisprudenza-1634398": {
        "fonti": [("https://www.giurisprudenza.unicampania.it/studiare-cds-giurisprudenza/insegnamenti", "tabella")]},
    "unicampania-l-14-scienze-dei-servizi-giuridici": {"fonti": [  # un articolo per curriculum (immatricolati dal 2025/26)
        ("https://www.giurisprudenza.unicampania.it/index.php?option=com_content&view=article&id=3575",
         "tabella:Scienze dei servizi giuridici per amministrazioni, imprese ed enti del terzo settore"),
        ("https://www.giurisprudenza.unicampania.it/index.php?option=com_content&view=article&id=3576",
         "tabella:Scienze delle investigazioni e della sicurezza"),
        ("https://www.giurisprudenza.unicampania.it/index.php?option=com_content&view=article&id=3577",
         "tabella:Diritto e management dello sport")]},
    "unicampania-lm-sc-giur-diritto-della-sicurezza": {
        "fonti": [("https://www.giurisprudenza.unicampania.it/studiare-cds-diritto-della-sicurezza/insegnamenti", "tabella")]},
    # Medicina e chirurgia interateneo (Vanvitelli-Parthenope): programmazione 2026/27 in PDF, senza link alle schede
    "unicampania-lm-41-medicina-e-chirurgia-1634408": {
        "url": "http://www.dipmdsmco.unicampania.it/didattica/corsi-di-studio/medicina-e-chirurgia", "prefisso": r"A42\d{4}"},
    # un articolo per ogni corso integrato
    "unicampania-lm-41-medicina-e-chirurgia-1634406": {"fonti": [(
        "https://www.medicinasperimentale.unicampania.it/didattica/corsi-di-studio/corso-di-laurea-magistrale-a-ciclo-unico-in-"
        "medicina-e-chirurgia-sede-di-napoli/10-didattica/1696-insegnamenti-a-a-2026-2027-corso-di-laurea-magistrale-a-ciclo-"
        "unico-in-medicina-e-chirurgia-sede-di-napoli", "articoli")]},
    # il piano 2025/26 (con i codici delle attività) è l'ultimo pubblicato in PDF; le pagine dei corsi integrati sono del 2026/27
    "unicampania-l-snt3-tecniche-di-laboratorio-biomedico": {"prefisso": r"A77\d\d", "fonti": [(
        "http://www.medicinadiprecisione.unicampania.it/images/Piano_di_Studi_TLB_a.a._25-26.pdf", "pdf")]},
    "unicampania-l-snt3-tecniche-di-radiologia-medica": {"prefisso": r"A79\d\d", "fonti": [(
        "http://www.medicinadiprecisione.unicampania.it/images/Piano_di_Studi_a.a_25.26.pdf", "pdf")]},
    "unicampania-lm-41-medicina-e-chirurgia-1634407": {"fonti": [(
        "https://www.medicinadiprecisione.unicampania.it/didattica/corsi-di-studio/corso-di-laurea-magistrale-a-ciclo-unico-in-"
        "medicina-e-chirurgia-in-lingua-inglese-medicine-and-surgery-in-english/10-didattica/1523-teaching-plan-2026-2027",
        "articoli")]},
}


def _cfg(cid: str) -> dict:
    """Impostazioni del corso: la chiave più lunga che è un prefisso dell'id."""
    ks = [k for k in CORSI if cid.startswith(k)]
    return CORSI[max(ks, key=len)] if ks else {}


def _host(url: str) -> str:
    return re.match(r"https?://[^/]+", url).group(0)


def fetch_ateneo(uid: str = "unicampania", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    for x in corsi:
        x["url"] = _cfg(x["id"]).get("url") or x.get("url")
    # solo pagine dedicate al corso (non la home del dipartimento)
    corsi = [x for x in corsi if re.match(r"https?://[\w.-]+\.unicampania\.it/.+", x.get("url") or "")
             and not x.get("piano_da") and not re.search(r"(?i)\breplica\b", x["nome"])]
    if max_cds:
        corsi = corsi[:max_cds]
    c = _Scarica(rate=2.0)  # un sito: al massimo 2 richieste al secondo in tutto
    oggi = time.strftime("%Y-%m-%d")
    prec = anno - 1

    def build(corso: dict) -> dict | None:
        righe: dict[str, dict] = {}
        fonti: list[str] = []
        cfg = _cfg(corso["id"])
        if cfg.get("fonti"):
            sorgenti = [(u, k, None) for u, k in cfg["fonti"]]
        else:  # la pagina del corso stessa (spesso ha l'elenco in una scheda a fisarmonica) e i documenti che collega
            sorgenti = [(corso["url"], "html", None)] + fonti_corso(c, corso["url"], anno)
        # le pagine HTML dell'elenco, se ci sono; il PDF solo se le pagine non hanno l'elenco
        sorgenti.sort(key=lambda s: (s[1] != "html", s[0]))
        host_corso = _host(corso["url"])
        letti_html: list[tuple[str, list[dict]]] = []
        letti_pdf: list[tuple[str, list[dict]]] = []
        for p, tipo, aa_fonte in sorgenti:
            voci: list[dict] = []
            if tipo.startswith("tabella"):
                r = c.get(p)
                righe_t = leggi_piano_tabella(r.text) if r else []
                if ":" in tipo:  # «tabella:<curriculum>»: l'articolo è il piano di un solo curriculum
                    for x in righe_t:
                        x["curriculum"] = tipo.split(":", 1)[1]
                voci = _voci_da_tabella(righe_t, corso)
            elif tipo == "articoli":
                r = c.get(p)
                voci = _voci_da_articoli(leggi_articoli(r.text), cfg, host_corso) if r else []
            elif tipo == "html":
                r = c.get(p)
                if r:
                    voci = leggi_elenco(r.text, anno - cfg.get("aa_indietro", 0))
                    if not voci and cfg.get("prefisso"):
                        voci = _voci_da_codici(leggi_html_codici(r.text, cfg["prefisso"]), host_corso, cfg.get("aa", anno), corso)
            elif not letti_html or cfg.get("tutte"):
                dati = c.pdf(p)
                if dati:
                    try:
                        voci = leggi_pdf(dati, anno, corso.get("durata_anni") or 6)
                        if len([v for v in voci if v["anno"]]) < 3 and cfg.get("prefisso"):
                            voci = _voci_da_codici(leggi_pdf_codici(dati, cfg["prefisso"]), host_corso, cfg.get("aa", anno), corso)
                    except Exception as e:  # noqa: BLE001
                        log(f"[{uid}]   PDF {p} illeggibile: {e!r}")
            if voci:
                (letti_pdf if tipo == "pdf" else letti_html).append((p, voci))
        if letti_html:
            letti = letti_html
        elif cfg.get("tutte"):
            letti = letti_pdf
        else:  # più PDF dello stesso a.a.: quello con più insegnamenti assegnati a un anno
            letti = sorted(letti_pdf, key=lambda q: -len({v["cod_attivita"] for v in q[1] if v["anno"]}))[:1]
        for p, voci in letti:
            # i link ai moduli (anche quelli dei docenti) seguono il corso integrato, che ha il suo anno
            ci_pos = {v["cod_attivita"]: v for v in voci if not v["cod_unita"] and v["anno"]}
            for v in voci:
                if v["cod_unita"] and v["cod_attivita"] in ci_pos:
                    v["anno"], v["periodo"] = ci_pos[v["cod_attivita"]]["anno"], ci_pos[v["cod_attivita"]]["periodo"]
            fonti.append(p)
            host = _host(p)
            for v in voci:
                if not v["anno"]:
                    continue
                key = f"{v['anno']}:{v['cod_attivita'] or _norm_nome(v['nome'])}:{v.get('curriculum') or ''}"
                href = v["href"] if v["href"].startswith("http") else host + v["href"]
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": v["cod_attivita"], "nome": None, "anno": v["anno"],
                        "periodo": v["periodo"], "cfu": None, "ssd": v["ssd"], "obbligatorio": None,
                        "curriculum": v.get("curriculum"), "docenti": [], "url": href, "libri": [], "esami": [], "fonte": p,
                        "verificato_il": oggi, "_unita": {}, "_schede": set(), "_ci": False, "_aa": v.get("aa"),
                        "_host": host, "_cfu_tab": v.get("cfu_tab"),
                    }
                nome = _titolo(v["integrato"] or v["nome"]) if (v["integrato"] or v["nome"]) else None
                if nome and (not item["nome"] or (not v["cod_unita"] and not v["integrato"])):
                    item["nome"] = nome  # il nome del corso integrato (link senza unità) vale più di quello di un modulo
                item["periodo"] = item["periodo"] or v["periodo"]
                if v["cod_unita"]:
                    try:
                        item["_unita"][v["cod_unita"]] = float(v["cfu"] or 0)
                    except ValueError:
                        pass
                    item["_schede"].add(href)
                elif v["cod_attivita"]:
                    item["_ci"] = True
                    item["url"] = href
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": corso["url"], "curricula": None,
                "fonte": fonti[0], "verificato_il": oggi, "insegnamenti": list(righe.values())}

    titoli_appelli: dict[str, list[str]] = {}
    try:  # titoli degli appelli dell'ultima raccolta: danno il codice dell'attività di titoli senza scheda collegata
        ap = json.loads((ROOT / "database" / "contrib" / "auto" / f"{uid}.json").read_text(encoding="utf-8")).get("appelli", {})
        for cod_a, lst in ap.items():
            if lst and lst[0].get("titolo"):
                titoli_appelli.setdefault(_norm_nome(lst[0]["titolo"]), []).append(cod_a)
    except Exception:  # noqa: BLE001
        pass

    def _voci_da_tabella(righe: list[dict], corso: dict) -> list[dict]:
        """Righe del piano → voci: la scheda (codice dell'attività) si trova nella pagina del docente della riga, tra gli
        insegnamenti del corso di laurea con lo stesso titolo."""
        host = _host(corso["url"])
        online = bool(re.search(r"online|a distanza", corso["url"], re.I))
        doc_cache: dict[str, list[dict]] = {}
        out = []
        for r in righe:
            trovate = []
            for mat in r["matricole"]:
                if mat not in doc_cache:
                    pg = c.get(f"{host}/dipartimento/docenti?MATRICOLA={mat}")
                    doc_cache[mat] = leggi_docente(pg.text) if pg else []
                for d in doc_cache[mat]:
                    if f"AA_OFFERTA={anno}" not in d["href"]:
                        continue
                    if bool(re.search(r"(?i)\(online\)", d["corso"])) != online:
                        continue
                    if not stesso_corso(re.sub(r"(?i)\(online\)", "", d["corso"]), corso["nome"]):
                        continue
                    if _norm_nome(d["titolo"]) == _norm_nome(r["nome"]):
                        trovate.append(d["href"])
            if not trovate:  # righe senza docente collegato: i codici con lo stesso titolo nella bacheca appelli di Esse3
                for cod in titoli_appelli.get(_norm_nome(r["nome"]), [])[:12]:
                    pg = ci_page(host, cod, [anno], corso["nome"])
                    if pg and bool(re.search(r"(?i)online", pg.get("corso") or "")) == online:
                        trovate.append(pg["url"])
                        break
            base = {"anno": r["anno"], "periodo": r["periodo"], "nome": r["nome"], "integrato": None, "ssd": r["ssd"],
                    "cds": None, "aa": anno, "cfu_tab": r["cfu"], "curriculum": r["curriculum"]}
            if trovate:
                for href in dict.fromkeys(trovate):
                    v = _voce(href, r["anno"], r["periodo"], r["nome"], None, anno)
                    if v:
                        v.update({"cfu_tab": r["cfu"], "curriculum": r["curriculum"], "ssd": r["ssd"] or v["ssd"]})
                        out.append(v)
            else:
                out.append({**base, "cod_unita": None, "cod_attivita": None, "href": corso["url"]})
        return out

    def _voci_da_articoli(arts: list[dict], cfg: dict, host: str) -> list[dict]:
        """Ogni articolo di corso integrato rimanda alla scheda (COD_ATTIVITA) o riporta i codici nel testo."""
        out = []
        for a in arts:
            if not a["anno"] or re.match(r"(?i)\s*(AFP|ADE|a scelta|tirocinio)", a["nome"] or ""):
                continue
            u = a["href"] if a["href"].startswith("http") else host + a["href"]
            r = c.get(u)
            if not r:
                continue
            m = re.search(r"COD_ATTIVITA=(\w+)", html.unescape(r.text))
            cod = m.group(1) if m else None
            if not cod and cfg.get("prefisso"):
                cs = leggi_html_codici(r.text, cfg["prefisso"])
                cod = cs[0]["cod"] if cs else None
            if not cod:
                continue
            aa = cfg.get("aa", anno)
            out.append({"anno": a["anno"], "periodo": a["periodo"], "nome": a["nome"], "integrato": None, "cod_unita": None,
                        "cod_attivita": cod, "ssd": None, "cfu": None, "cds": None, "aa": aa,
                        "href": f"{host}/dipartimento/docenti?COD_ATTIVITA={cod}&AA_OFFERTA={aa}"})
        return out

    def ci_page(host: str, cod: str, aa_list: list[int], corso_nome: str | None = None) -> dict | None:
        """Pagina U-GOV del corso integrato `cod` (primo a.a. che ha dati); se `corso_nome`, deve essere di quel corso."""
        for aa in aa_list:
            u = f"{host}/dipartimento/docenti?COD_ATTIVITA={cod}&AA_OFFERTA={aa}"
            r = c.get(u)
            if not r:
                continue
            d = leggi_ci(r.text)
            if not (d["moduli"] or d["scheda"]):
                continue
            if corso_nome and d.get("corso") and not stesso_corso(d["corso"], corso_nome):
                continue
            d["aa"] = aa
            d["url"] = u
            return d
        return None

    def _voci_da_codici(cods: list[dict], host: str, aa: int, corso: dict) -> list[dict]:
        """Codici letti dal testo → voci: tra i codici della riga si sceglie il primo che ha la pagina del corso integrato
        e appartiene a questo corso di laurea."""
        out, viste = [], set()
        for d in cods:
            if not d["anno"]:
                continue
            cands = d.get("cands") or [d["cod"]]
            if any(k in viste for k in cands):
                continue
            for cod in cands + d.get("ctx", []):
                pg = ci_page(host, cod, [aa, aa - 1], None if _cfg(corso["id"]).get("senza_verifica") else corso["nome"])
                if pg and cod not in cands:  # codice preso dalle righe vicine: deve contenere un'unità della riga
                    unita = {m["cod_unita"] for m in pg["moduli"]}
                    if not (unita & set(d.get("unita", []))):
                        pg = None
                if pg:
                    viste.update(cands)
                    out.append({"anno": d["anno"], "periodo": d["periodo"], "nome": None, "integrato": None,
                                "cod_unita": None, "cod_attivita": cod, "ssd": None, "cfu": None, "cds": None,
                                "aa": pg["aa"], "href": pg["url"]})
                    break
        return out

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi con elenco degli insegnamenti (su {len(corsi)}), {len(items)} insegnamenti")

    def pagina_ci(i: dict) -> dict | None:
        """Pagina del corso integrato (2026, altrimenti l'anno del link): nome, moduli, scheda."""
        aa_list = [anno] + ([i["_aa"]] if i.get("_aa") and i["_aa"] != anno else [])
        return ci_page(i["_host"], i["codice"], aa_list)

    def scheda(i: dict) -> int:
        libri, viste, docenti = [], set(), set()
        ci = None
        if i["codice"] and (i["_ci"] or not i["_schede"] or not i["nome"]):
            try:
                ci = pagina_ci(i)
            except Exception:  # noqa: BLE001
                ci = None
        if ci:
            if ci["nome"]:
                i["nome"] = _titolo(ci["nome"])
            for m in ci["moduli"]:
                i["_schede"].add(m["href"] if m["href"].startswith("http") else i["_host"] + m["href"])
                if m["cod_unita"]:
                    try:
                        i["_unita"][m["cod_unita"]] = float(m["cfu"] or 0)
                    except ValueError:
                        pass
                if not i["ssd"] and m["ssd"]:
                    i["ssd"] = m["ssd"]
            if ci["scheda"]:
                sc = ci["scheda"]
                if not i["nome"] and sc["nome"]:
                    i["nome"] = _titolo(sc["nome"])
                try:
                    i["_unita"][i["codice"]] = float(sc["cfu"] or 0)
                except (TypeError, ValueError):
                    pass
                i["ssd"] = i["ssd"] or sc["ssd"]
                i["periodo"] = i["periodo"] or sc["periodo"]
                if sc["docente"]:
                    docenti.add(sc["docente"])
                for lb in sc["libri"]:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        libri.append(lb)
            if i["ssd"] and len({m["ssd"] for m in ci["moduli"] if m["ssd"]}) > 1:
                i["ssd"] = ", ".join(sorted({m["ssd"] for m in ci["moduli"] if m["ssd"]}))
        i["url"] = (ci or {}).get("url") or i["url"]
        for u in sorted(i["_schede"]):
            try:
                r = c.get(u)
                if not r:
                    continue
                d = leggi_scheda(r.text)
            except Exception:  # noqa: BLE001
                continue
            if d["docente"]:
                docenti.add(" ".join(w.capitalize() if w.isupper() else w for w in d["docente"].split()))
            i["periodo"] = i["periodo"] or d["periodo"]
            if not i["nome"] and d["nome"]:
                i["nome"] = _titolo(d["nome"])
            m_aa = re.search(r"AA_OFFERTA=(\d{4})", u)
            for lb in d["libri"]:
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    if m_aa and int(m_aa.group(1)) != anno:
                        a0 = int(m_aa.group(1))
                        lb["note"] = (lb.get("note") + " - " if lb.get("note") else "") + \
                            f"dal programma dell'a.a. {a0}/{str(a0 + 1)[2:]} (scheda collegata dal piano dell'ateneo)"
                    libri.append(lb)
        if not libri and i["_schede"]:
            # il programma 2026/27 non indica i testi: si cerca quello dell'anno precedente (stesso docente e unità)
            for u in sorted(i["_schede"]):
                if f"AA_OFFERTA={anno}" not in u:
                    continue
                try:
                    r = c.get(u.replace(f"AA_OFFERTA={anno}", f"AA_OFFERTA={prec}"))
                    d = leggi_scheda(r.text) if r else None
                except Exception:  # noqa: BLE001
                    d = None
                for lb in (d or {}).get("libri", []):
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        lb["note"] = (lb.get("note") + " - " if lb.get("note") else "") + \
                            f"dal programma dell'a.a. {prec}/{str(anno)[2:]} (quello {anno}/{str(anno + 1)[2:]} non indica i testi)"
                        libri.append(lb)
        tot = sum(i["_unita"].values())
        if not tot and i.get("_cfu_tab"):
            tot = float(i["_cfu_tab"])
        i["cfu"] = (int(tot) if float(tot).is_integer() else tot) or None
        i["docenti"] = sorted(docenti)
        i["libri"] = libri
        i["stato_libri"] = "completo" if libri else "da_aggiungere"
        for k in ("_unita", "_schede", "_ci", "_aa", "_host", "_cfu_tab"):
            i.pop(k, None)
        return len(libri)

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, items), 1):
                trovati += k
                if n % 300 == 0:
                    log(f"[{uid}]   schede {n}/{len(items)}")
    else:
        for i in items:
            for k in ("_unita", "_schede", "_ci", "_aa", "_host", "_cfu_tab"):
                i.pop(k, None)
    for x in out:  # voci senza scheda né pagina leggibile: manca il nome
        persi = [f"{i['anno']}:{i['codice']}" for i in x["insegnamenti"] if not i.get("nome")]
        if persi:
            log(f"[{uid}]   {x['nome'][:40]}: {len(persi)} voci senza pagina U-GOV leggibile: {', '.join(persi[:12])}")
        x["insegnamenti"] = [i for i in x["insegnamenti"] if i.get("nome")]
        for i in x["insegnamenti"]:  # «TPV in Psicologia …» = Tirocinio pratico valutativo (sigla scritta per esteso)
            i["nome"] = re.sub(r"^TPV\b", "Tirocinio pratico valutativo (TPV)", i["nome"])
    out = [x for x in out if x["insegnamenti"]]
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dai siti dei dipartimenti *.unicampania.it "
                                                 "(adapters/unicampania.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
