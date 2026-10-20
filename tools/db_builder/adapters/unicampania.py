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

from . import unicampania_piani as piani
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


_NOME_VERO = re.compile(r"[A-Za-zÀ-ÿ]{4}")
_NON_NOME = re.compile(r"(?i)\(?\s*(?:[A-Z]\s*-\s*[A-Z]|pomeridian\w*|serale|cognomi.*|canale.*|cfu.*|a\d{3,7})\s*\)?")


def _nome_riga(s: str, pos: int) -> str | None:
    """Nome dell'insegnamento nella prima cella della riga di tabella che contiene la posizione `pos`
    («Diritto Privato<a>…</a><a>(A-D)</a>…»): il testo della cella senza i link."""
    a = s.rfind("<tr", 0, pos)
    if a < 0:
        return None
    c = s.find("<td", a)
    f = s.find("</td>", c) if c >= 0 else -1
    if c < 0 or f < 0 or c > pos:
        return None
    cella = re.sub(r"<a\b.*?</a>", " ", s[c:f], flags=re.S | re.I)
    t = re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", _testo(cella))
    t = re.sub(r"\s+", " ", t).strip(" -–−:")
    return t if _NOME_VERO.search(t) else None


def leggi_elenco(s: str, anno_offerta: int) -> list[dict]:
    """Insegnamenti di una pagina "Insegnamenti - CdS …": un elemento per unità didattica."""
    s = _pulisci(s)
    m = re.search(r'itemprop="articleBody"|class="item-page', s)
    s = s[m.start():] if m else s
    fine = s.find("<aside")
    s = s[:fine] if fine > 0 else s
    out, anno, sem = [], None, None
    senza = _righe_senza_link(s)  # righe di tabella senza scheda (insegnamenti «da assegnare», lingua, laboratori…)

    def senza_fino_a(pos: int):
        while senza and senza[0][0] < pos:
            _, nome, cfu = senza.pop(0)
            if anno:
                out.append({"anno": anno, "periodo": sem, "nome": nome, "integrato": None, "cod_unita": None,
                            "cod_attivita": None, "ssd": None, "cfu": None, "cfu_tab": cfu, "href": None,
                            "cds": None, "aa": None})

    for e in EVENTI.finditer(s):
        senza_fino_a(e.start())
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
            nome_link = _testo(e.group("testo"))
            if not _NOME_VERO.search(nome_link) or _NON_NOME.fullmatch(nome_link):
                nome_link = _nome_riga(s, e.start()) or nome_link  # il nome sta nella cella, prima dei link «(A-D)», «(E-O)»
            ei = re.search(r"\(\s*Modulo\s+dell[’']\s*e\.?\s*i\.?\s*(?:di\s+)?(.*?)\)", _testo(e.group("dopo")), re.I)
            v = _voce(html.unescape(e.group("href")), anno, sem, nome_link,
                      ei.group(1).strip() if ei else None, anno_offerta)
            if v:
                # «(esame a scelta)» subito dopo il nome: insegnamento tra quelli a scelta dello studente
                v["scelta"] = bool(re.match(r"\s*[-–]?\s*\(\s*(?:esame|insegnamento|corso)?\s*a\s+scelta\s*\)",
                                            _testo(e.group("dopo"))[:60], re.I))
                out.append(v)
    senza_fino_a(len(s) + 1)
    return out


_INTESTAZIONE_COL = re.compile(r"(?i)(?:insegnamenti?|docenti?|cfu|codice(?: aula virtuale)?|semestre|anno|ssd|settore|"
                               r"course|teacher|credits?|subjects?|class|attivit[àa]|name)")


def _righe_senza_link(s: str) -> list[tuple[int, str, str]]:
    """(posizione, nome, CFU) delle righe di tabella «Insegnamento | … | CFU | Docente» senza link alla scheda: sono
    insegnamenti del piano a cui non è ancora collegata la scheda (docente «da assegnare»). Si escludono le righe di
    intestazione, i moduli di un integrato (nome tra parentesi) e le righe di soli docenti (prima cella numerica)."""
    out = []
    for m in re.finditer(r"<tr[^>]*>(.*?)</tr>", s, re.S | re.I):
        riga = m.group(1)
        if "COD_ATTIVITA=" in riga or "COD_UNITA=" in riga:
            continue
        celle = [_testo(c) for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", riga, re.S | re.I)]
        if len(celle) < 3 or not celle[0] or _INTESTAZIONE_COL.fullmatch(celle[0]):
            continue
        nome = celle[0].strip(" -–−")
        nome = re.sub(r"(?i)^(.{4,}?)\s*\1\s*\(.*?\)$", r"\1", nome)  # «Microeconomia Microeconomia(Pomeridiano)»
        if re.search(r"(?i)\(\s*(?:modul[eo]|mod\.)|\bmodul[eo] of\b", nome):  # modulo di un integrato: il CFU è già nel corso integrato
            continue
        if not re.search(r"[A-Za-zÀ-ÿ]{3}", nome) or re.fullmatch(r"[\d.,\s]+", nome) or nome.startswith("("):
            continue
        cfu = [c for c in celle[1:] if re.fullmatch(r"\d{1,2}(?:[.,]\d)?", c)]
        if not cfu or float(cfu[0].replace(",", ".")) > 30:
            continue
        out.append((m.start(), nome, cfu[0].replace(",", ".")))
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
        if not nome or nome.startswith("*") or re.match(r"(?i)in alternativa", nome):
            continue
        mcfu = re.match(r"(\d+(?:[.,]\d+)?)", testi[2])
        if not mcfu and re.match(r"(?i)(?:insegnamenti a scelta|altre attivit)", nome):
            continue  # riga di intestazione di un gruppo («INSEGNAMENTI A SCELTA», «ALTRE ATTIVITA'»), senza CFU
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


# CFU complessivi degli insegnamenti nei PDF «Insegnamenti attivi» di Ingegneria: «Bioelettromagnetismo  I  9  72» (corso
# integrato: i moduli seguono sulle righe dopo, con l'SSD) oppure «Modelli di sistemi biologici  II  IBIO-01/A  B  9  72  Docente»
_RIGA_CFU_DOC = re.compile(
    r"^(?P<nome>[^|]+?)\s+(?P<sem>I{1,2}|Annuale|annuale)\s+(?:(?P<ssd>[A-Z]{2,5}-\d{2}/[A-Z])\s+(?P<taf>[A-Z](?:\s*,\s*[A-Z])?)\s+)?"
    r"(?P<cfu>\d{1,2})\s+(?P<ore>\d{2,3})(?:\s|$)")


def leggi_cfu_pdf(data: bytes, max_anno: int = 6) -> dict[tuple[int, str], tuple]:
    """{(anno, nome normalizzato): (CFU, semestre, nome)} delle righe con i CFU complessivi di un insegnamento nel PDF."""
    out: dict[tuple[int, str], tuple] = {}
    anno = None
    for pg in _pdf_reader(data).pages:
        for riga in (pg.extract_text() or "").split("\n"):
            riga = re.sub(r"\s+", " ", riga).strip()
            a, _ = intestazione(riga, max_anno)
            if a:
                anno = a
                continue
            m = _RIGA_CFU_DOC.match(riga)
            if m and anno and not re.search(r"(?i)^(?:insegnamento|modulo)", m.group("nome")):
                out[(anno, _norm_nome(m.group("nome")))] = (float(m.group("cfu")), m.group("sem"), m.group("nome").strip())
    return out


# ---------------------------------------------------------------------------------------------
# attività senza scheda (a scelta, tirocinio, prova finale…): dal manifesto / piano di studio ufficiale

_ATT_SCELTA = (r"(?:a\s+scelta\s+(?:dello|dallo)\s+studente|attivit[àa]\s+(?:formative\s+)?(?:a\s+(?:libera\s+)?scelta|autonomamente\s+scelte)(?:\s+(?:dallo|dello)\s+studente)?|"
               r"(?:esami?|insegnamenti?|crediti|cfu)\s+a\s+scelta(?:\s+(?:dallo|dello)\s+studente)?|"
               r"(?:free|student'?s?)\s+choice(?:\s+(?:courses?|credits|activit\w+))?|elective\s+(?:courses?|activit\w+)|"
               r"attivit[àa]\s+didattiche\s+a\s+scelta(?:\s+dello\s+studente)?)")
_ATT_FINALE = r"(?:prova\s+finale|preparazione\s+(?:della\s+)?tesi(?:\s+di\s+laurea)?|tesi(?:\s+di\s+laurea)?|elaborato\s+finale|final\s+(?:exam|thesis|test|examination)|thesis|dissertation)"
_ATT_TIROCINIO = r"(?:tirocini?o?\w*(?:\s+(?:formativo|pratico|professionalizzante|curriculare)\w*)?|stage|internship)"
_ATT_ALTRE = (r"(?:competenze\s+linguistiche|altre\s+attivit[àa](?:\s+formative)?|ulteriori\s+conoscenze\s+linguistiche|abilit[àa]\s+informatiche(?:\s+e\s+telematiche)?|"
              r"ulteriori\s+attivit[àa]\s+formative|attivit[àa]['’]?\s+seminariali|laboratori(?:o)?\s+(?:professionalizzant\w+|didattic\w+)|laboratori\s+ssd|"
              r"other\s+(?:learning\s+)?activit\w+)")
ATTIVITA_SENZA_SCHEDA = re.compile(
    rf"^\W*(?P<nome>{_ATT_SCELTA}|{_ATT_FINALE}|{_ATT_TIROCINIO}|{_ATT_ALTRE})\W*(?P<resto>.*)$", re.I)
_FINE_PIANO = re.compile(r"(?i)^\W*(?:docenti\b|carichi didattici|propedeutic|calendario|insegnamenti a scelta (?:attivati|mutuati)|"
                         r"esami a scelta (?:per|mutuati)|attivit[àa] a scelta(?:\s*$|\s+(?:proposte|attivate))|elenco degli insegnamenti)")
_NUM = re.compile(r"(?<![\w.,/])(\d{1,2}(?:[.,]\d)?)(?![\w.,/])")


def leggi_attivita_manifesto(testo: str, max_anno: int = 6) -> list[dict]:
    """Righe «Attività a scelta 6», «Tirocinio 1», «Tesi di laurea 5» del manifesto/piano di studio in testo, con
    l'anno dell'intestazione («SECONDO ANNO», «III anno») più vicina sopra. Il CFU è il primo numero della riga
    dopo il nome (o, se la riga è solo il nome, della riga seguente)."""
    righe = [re.sub(r"\s+", " ", r).strip() for r in testo.split("\n")]
    righe = [r for r in righe if r]
    out, anno = [], None
    for k, r in enumerate(righe):
        a, _ = intestazione(r, max_anno)
        if a:
            anno = a
            continue
        if not anno:
            continue
        if _FINE_PIANO.match(r):  # dopo i carichi didattici/le tabelle delle scelte si ripetono gli stessi nomi
            break
        m = ATTIVITA_SENZA_SCHEDA.match(r)
        if not m:
            continue
        resto = m.group("resto")
        n = _NUM.search(resto)
        if not n and not resto.strip(" *()-–:") and k + 1 < len(righe):
            n = _NUM.match(righe[k + 1])  # tabella a celle separate: il CFU è sulla riga dopo
        if not n:
            continue
        cfu = float(n.group(1).replace(",", "."))
        if not 0 < cfu <= 30 or len(r) > 140:
            continue
        nome = re.sub(r"\s+", " ", m.group("nome")).strip().rstrip("*")
        if nome.isupper():
            nome = nome.lower()
        out.append({"anno": anno, "nome": nome[:1].upper() + nome[1:], "cfu": cfu})
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


_CHIUSURA_TITOLO = r"(?:”|&rdquo;|&quot;|&#8221;|»|&raquo;)"
_INIZIO_AUTORE = r"(?=(?:[A-ZÀ-Ý]\.\s?){1,3}[A-ZÀ-Ý][a-zà-ÿ]+)"


def _dividi_riferimenti(raw: str) -> str:
    """«D.C. Giancoli “Physics. Principles with Applications.” D.Halliday, … "Fundamentals of Physics" J.W. Kane, …»:
    riferimenti scritti di seguito, senza a capo, con l'autore prima del titolo tra virgolette. Vanno separati prima del
    riconoscimento: il punto dentro il titolo non è la fine del riferimento. Il testo finale sul materiale del docente
    («Appunti forniti a lezione…») non fa parte dell'ultimo riferimento."""
    testo = re.sub(r"<[^>]+>", "", raw)
    chiusure = len(re.findall(_CHIUSURA_TITOLO, testo))
    if chiusure < 2 or not re.match(r"\s*(?:[A-ZÀ-Ý]\.\s?){1,3}[A-ZÀ-Ý]", testo.strip()):
        return raw
    raw = re.sub(r"(" + _CHIUSURA_TITOLO + r"[.,;]?)\s+" + _INIZIO_AUTORE, r"\1<br>", raw)
    return re.sub(r"(?i)\s+(?:Appunti|Dispense|Slide|Materiale didattico)\b[^<]*", "", raw)


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
        testi_raw = _dividi_riferimenti(t.group(1))
        libri = estrai_libri(testi_raw)
        if not libri:  # riconoscimento tollerante: elenchi puntati, prosa, voci senza editore
            libri = libri_unipg([testi_raw])
        if not libri:
            libri = libri_semplici(testi_raw)
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
#   manifesto: manifesto / piano di studio ufficiale (url o (url, curriculum)) da cui si leggono le attività senza scheda
#              (a scelta, tirocinio, prova finale…), `tail_unici`: righe uguali ripetute (curricula) contano una volta
_DISTABIF = "https://www.distabif.unicampania.it/avvisi/Manifesto_degli_studi/AA_2026_2027/"
CORSI: dict[str, dict] = {
    "unicampania-l-2-biotecnologie": {"manifesto": _DISTABIF + "L-2_Manifesto_degli_studi_a.a_2026_2027.pdf"},
    "unicampania-l-25-scienze-agrarie": {"manifesto": _DISTABIF + "LM-25_Manifesto_degli_studi_2026_2027.pdf"},
    "unicampania-l-32-scienze-ambientali": {"manifesto": _DISTABIF + "L-32_Manifesto_degli_studi_2026-2027.pdf"},
    "unicampania-l-13-scienze-biologiche": {"manifesto": _DISTABIF + "L-13_Manifesto_degli_studi_2026_2027.pdf"},
    "unicampania-lm-6-biologia": {"manifesto": _DISTABIF + "LM-6_Manifesto_degli_studi_2026_2027.pdf", "tail_unici": True},
    # Molecular biotechnology: 2° anno del catalogo 2026/27 (coorte 2025/26, 64 CFU): un corso senza scheda, tirocinio e tesi
    "unicampania-lm-9-molecular": {"manifesto": _DISTABIF + "LM-9_Course_Catalogue_a.a_2026-2027.pdf", "piani": [{
        "tipo": "tabella", "url": _DISTABIF + "LM-9_Course_Catalogue_a.a_2026-2027.pdf",
        "righe": [(2, None, "Design and synthesis of bioactive compounds", 8), (2, None, "Internship/Stage", 2),
                  (2, None, "Master thesis", 20)]}]},
    "unicampania-lm-61-scienze-degli-alimenti": {"manifesto": _DISTABIF + "LM-61_Manifesto_degli_studi_2026-2027.pdf"},
    "unicampania-lm-75-scienze-e-tecnologie": {"manifesto": _DISTABIF + "LM-75_Manifesto_degli_studi_2026-2027.pdf"},
    # Farmacia: Biologia è un esame annuale (6 CFU al 1° semestre + 8 al 2°) e Lingua inglese vale 6 CFU (manifesto 2026/27: 1° anno 56 CFU)
    "unicampania-lm-13-farmacia": {"manifesto": _DISTABIF + "LM-13_Manifesto_2026_2027.pdf", "piani": [{
        "tipo": "tabella", "url": _DISTABIF + "LM-13_Manifesto_2026_2027.pdf",
        "righe": [(1, "A422709", "Biologia", 14), (1, "A4808", "Lingua inglese", 6)]}]},
    # Fisica: manifesto 2026/27 (2° anno 58 CFU, 3° anno 66 CFU): lingua inglese, attività a scelta, tesi e tirocinio senza scheda
    "unicampania-l-30-fisica": {
        "extra_fonte": "https://www.matfis.unicampania.it/images/id1439_Manifesto_degli_studi_2026-2027_Fisica_100626.pdf",
        "extra": [(2, "Lingua inglese", 6, False), (2, "Attività a scelta", 6, True), (3, "Attività a scelta libera", 6, True),
                  (3, "Tesi di laurea", 6, False), (3, "Tirocinio", 3, False)]},
    # Ingegneria biomedica magistrale: piano di studio 2026/27 (1° anno 54 CFU, 2° anno 66 CFU)
    "unicampania-lm-21-ingegneria-biomedica": {
        "righe_da_pdf": True,
        "extra_fonte": "https://www.ingegneria.unicampania.it/images/Didattica_2026_2027/Piani_studio/22.09.2026/Manifesto_LM21_26_27.pdf",
        "extra": [(1, "Applicazione di Medicina e Chirurgia di Precisione", 8, False), (2, "Attività a scelta dello studente", 8, True),
                  (2, "Tirocinio formativo e di orientamento", 3, False), (2, "Tirocinio aziendale", 3, False),
                  (2, "Prova finale", 6, False)]},
    # professioni sanitarie: piano di studio con tirocinio, attività a scelta (ADE), laboratori e prova finale, che non hanno scheda
    # (i piani senza codici danno il CFU di ogni corso integrato nella programmazione didattica 2026/27: `piani` tipo «nomi»)
    "unicampania-l-snt4-assistenza-sanitaria": {
        "manifesto": "https://www.medicinasperimentale.unicampania.it/images/AS_Piano_di_Studio_2026_2027.pdf",
        "piani": [{"tipo": "nomi", "url": "https://www.medicinasperimentale.unicampania.it/images/AS__programmazione_Didattica_2026-2027.pdf",
                   # il nome è spezzato dal CFU in una riga del PDF; il piano di studio dà 6 CFU
                   "cfu_nomi": {"Prevenzione delle Malattie Cronico - Degenerative": 6}}]},
    "unicampania-l-snt4-tecniche-della-prevenzione": {
        "manifesto": "https://www.medicinasperimentale.unicampania.it/images/TPS_Piano_di_Studio_2026_2027.pdf",
        "manifesto_salta": ["Laboratori professionalizzanti"],  # i laboratori del piano sono «Laboratorio 1» (2° anno) e «Laboratorio 2» (3°)
        "piani": [
            {"tipo": "nomi", "url": "https://www.medicinasperimentale.unicampania.it/images/TPALL_Programmazione_Didattica_2026-2027.pdf"},
            # «Inglese scientifico» (2 CFU nel 1° e 2° semestre del 1° anno) è nel piano degli studi e non ha scheda
            {"tipo": "tabella", "url": "https://www.medicinasperimentale.unicampania.it/images/TPS_Piano_di_Studio_2026_2027.pdf",
             "righe": [(1, None, "Inglese scientifico - 1° semestre", 2), (1, None, "Inglese scientifico - 2° semestre", 2)]}]},
    # Fisioterapia: programmazione 2025/26 (sede di Napoli, le stesse attività delle altre sedi)
    "unicampania-l-snt2-fisioterapia": {"piani": [{
        "tipo": "codici", "url": "http://www.dipmdsmco.unicampania.it/images/Programmazione_Fisioterapia_2025_26.pdf",
        "prefisso": r"A65\d\d", "fine": "Sede esterna di formazione", "nomi": {"A6503": "Psicologia e Sociologia", "A6507": "Lingua Inglese", "A6531": "Preparazione Esame Finale"}}]},
    "unicampania-lm-32-ingegneria-informatica": {"righe_da_pdf": True},
    # Matematica L-35: "Didattica programmata" 2026/27 (modello di piano): 1° anno 52, 2° 65, 3° 54 + 9 CFU a scelta; gli elenchi in PDF
    # non collegano alcuni insegnamenti (Algebra 2, Meccanica razionale, Geometria 3, che nel U-GOV 2026 hanno la scheda) e mettono
    # «Basi di dati» al 1° anno mentre è un insegnamento del 3° anno
    "unicampania-l-35-matematica": {"tutte": True, "piani": [{
        "tipo": "tabella", "url": "https://www.matfis.unicampania.it/images/Piano_di_studi_Matematica_triennale.pdf",
        "righe": [(1, "A3414", "Ulteriori conoscenze linguistiche", 2), (1, None, "Lingua inglese", 3),
                  (1, None, "Attività autonomamente scelte dallo studente", 3, True),
                  (2, "A3413", "Algebra 2", 8), (2, "A3411", "Meccanica razionale", 12),
                  (3, "A3417", "Geometria 3", 8), (3, "A3425", "Basi di dati e sistemi informativi", 8), (3, None, "Prova finale", 4)]}]},
    # piani senza link alle schede: i codici delle attività si leggono dal testo
    # Infermieristica: stampa U-GOV «Offerta didattica - Dettaglio» (tutte le attività con i CFU, senza l'anno)
    "unicampania-l-snt1-infermieristica": {"prefisso": r"A50\d\d", "piani": [{
        "tipo": "ugov", "url": "https://www.scienzemedichetraslazionali.unicampania.it/avvisi/Piano_di_Studio_Inf_2026pdf.pdf"}]},
    "unicampania-l-snt2-ortottica": {"prefisso": r"A76\d\d", "piani": [{
        "tipo": "codici", "url": "https://www.dipmdsmco.unicampania.it/images/Programmazione_Didattica_Corso_di_Studi_in_ORTOTTICA_a.a._2025.26_FT_1_1.pdf",
        "prefisso": r"A76\d\d|A42\d{4}",
        # le unità di Strabismo e di Chirurgia oculare sono scritte sotto un altro integrato o senza il codice dell'integrato
        "unita_di": {"A424092": "A7617", "A424142": "A7617", "A7629B": "A7629", "A7629C": "A7629"}, "anni": {"A7632": 3},
        "nomi": {"A7603": "La dimensione psicologica e sociale della persona", "A7617": "Strabismo e trattamento ortottico",
                 "A421504": "Ipovisione e riabilitazione visiva", "A7632": "Preparazione tesi", "A421323": "A scelta dello studente",
                 "A421324": "A scelta dello studente", "A421326": "A scelta dello studente"}}]},
    "unicampania-l-snt3-igiene-dentale": {"prefisso": r"A84\d\d", "piani": [{
        "tipo": "codici", "url": "https://www.dipmdsmco.unicampania.it/images/ORDINAMENTO_-_Piano_di_Studi_Corso_di_Studi_in_IGIENE_DENTALE_-_Cod._Reg._A84-19-25_-_a.a._2025-26.pdf",
        "prefisso": r"A84\d\d|A4\d{5}", "unita_di": {"A423739": "A8412", "A425515": "A8404"},
        "cfu_unita": {"A8418A": 3}}]},  # A8418A: 1 CFU caratterizzante + 2 CFU affini (seconda riga della stessa unità, senza codice)
    # Odontoiatria: programmazione 2026/27 (ogni anno è quello della coorte che lo frequenta). Totali dei corsi integrati («(N CFU tot)»):
    # 3°, 4°, 5° e 6° anno sommano 60 CFU; il 1° anno (52 CFU) e il 2° non sono completi nel documento
    "unicampania-lm-46-odontoiatria": {"prefisso": r"A42\d{4}", "piani": [{
        "tipo": "tabella",
        "url": "https://www.dipmdsmco.unicampania.it/images/1.all.2_Programmazione_Didattica_Corso_di_Studi_in_ODONTO_a.a._2026.27_26.03.26_08.05.26_-_MOD15.06.e.9.7_1.pdf",
        "righe": [(1, "A425693", "Scienze comportamentali e metodologia scientifica", 8, None, True), (1, "A425700", "ADE 1° anno", 2, True),
                  (3, "A2214", "Scienze mediche I", 13), (3, "A2215", "Anatomia patologica", 5), (3, "A2216", "Farmacologia", 6),
                  (3, "A2217", "Diagnostica per immagini e radioterapia", 6), (3, "A424793", "ADE 3° anno", 2, True),
                  (4, "A2219", "Gnatologia", 4), (4, "A2220", "Scienze mediche II", 15), (4, "A2221", "Neurologia e psichiatria", 4),
                  (4, "A2222", "Medicina legale", 4), (4, "A2223", "Discipline odontostomatologiche I", 28),
                  (5, "A2224", "Odontoiatria restaurativa", 10), (5, "A2225", "Parodontologia", 6),
                  (5, "A2226", "Patologia e terapia oro-maxillo-facciale", 10), (5, "A2227", "Protesi dentaria", 6),
                  (5, "A2228", "Ortodonzia", 8), (5, "A2229", "Odontoiatria pediatrica", 6), (5, "A2230", "Implantologia", 12),
                  (5, "ADO5", "ADO 5° anno", 2, True),
                  (6, "A2231", "Discipline odontostomatologiche II", 23), (6, "A2232", "Discipline odontostomatologiche III", 22),
                  (6, "A421313", "ADE 6° anno", 2, True), (6, None, "Tesi", 10)]}]},
    # pagine dei corsi che Universitaly non collega (o collega alla home del dipartimento)
    "unicampania-lm-snt2-scienze-riabilitative": {"url": "http://www.dipmdsmco.unicampania.it/didattica/corsi-di-studio/"
                                                         "scienze-riabilitative-delle-professioni-sanitarie", "piani": [{
        # programmazione 2025/26: ogni integrato ha il codice nell'intestazione e le sue unità sulle righe sotto (CFU = somma delle unità)
        "tipo": "tabella", "url": "http://www.dipmdsmco.unicampania.it/images/Prog_25_B85.pdf",
        "righe": [(1, "A425160", "Informatica e Lingua Inglese", 6), (1, "A425189", "Metodologia della Ricerca I", 7),
                  (1, "A425193", "ADE - Attività Didattica Elettiva", 5), (1, "A425194", "Laboratorio Professionale", 3),
                  (1, "A425204", "Tirocinio I anno", 18),
                  (2, "A425207", "Scienze Umane", 5), (2, "A425212", "Metodologie Innovative in ambito riabilitativo", 8),
                  (2, "A425218", "Metodologie del lavoro in team", 7), (2, "A425221", "Scienze della prevenzione e servizi sanitari", 8),
                  (2, "A425227", "Metodologia della Ricerca II", 2), (2, "A425234", "Ricerca Clinica in Riabilitazione II", 5),
                  (2, "A425237", "Scienze Tecniche Mediche Applicate", 1), (2, "A425239", "ADE a scelta dello studente", 1, True),
                  (2, "A425240", "Tirocinio II anno", 18), (2, "A425243", "Prova finale", 5)]}]},
    # Psicologia clinico-dinamica: piano di studio della coorte 2025 (2° anno nel 2026/27): antropologia, prova finale (14) e tirocinio
    # pratico valutativo (14) sono nel piano e non hanno scheda; 8 CFU a scelta tra tre attività (non obbligatorie)
    "unicampania-lm-51-psicologia-clinico-dinamica": {"piani": [{
        "tipo": "tabella", "url": "https://www.psicologia.unicampania.it/images/didattica/piano_di_studio/A30/PIANO_DI_STUDI_V30.pdf",
        "righe": [(2, "A424435", "Antropologia della complessità", 6), (2, "A424437", "Prova finale", 14),
                  (2, "A424689", "Tirocinio pratico valutativo in Psicologia clinico-dinamica", 14),
                  (2, "A425068", "Laboratorio modelli di misura", 2, True), (2, "A425067", "Laboratorio modelli di psicoterapia", 2, True),
                  (2, "A425069", "Sociologia della devianza e del crimine", 6, True)]}]},
    # Medicina e chirurgia (Caserta): l'elenco 2025/26 collega schede con AA_OFFERTA anche degli anni precedenti
    # il piano di studio di ogni anno è quello della coorte che lo frequenta nel 2026/27 (immatricolati 2026 → 1° anno … 2021 → 6°)
    "unicampania-lm-41-medicina-e-chirurgia": {"aa_indietro": 3, "piani": [{"tipo": "coorti", "specs": [
        (1, "https://www.damss.unicampania.it/images/didattica/manifesto/PIANO_DI_STUDIO_2026_con_semestre_filtro.pdf", "2026/2027"),
        (2, "https://www.damss.unicampania.it/images/didattica/manifesto/PIANO_DI_STUDIO_2025_con_semestre_filtro.pdf", "2026/2027"),
        (3, "https://www.damss.unicampania.it/images/didattica/manifesto/PIANO_DI_STUDIO_2024_-_LAUREA_ABILITANTE.pdf", "2026/2027"),
        (4, "https://www.damss.unicampania.it/images/didattica/manifesto/PIANO_DI_STUDIO_2023_-_LAUREA_ABILITANTE.pdf", "2026/2027"),
        (5, "https://www.damss.unicampania.it/images/didattica/manifesto/PIANO_DI_STUDIO_2022_-_LAUREA_ABILITANTE.pdf", "2026/2027"),
        (6, "https://www.damss.unicampania.it/images/didattica/manifesto/PIANO_DI_STUDIO_CdLMMC-CE_2021.pdf", "2026/2027")]}]},
    # Nursing usa le stesse attività di Infermieristica (la pagina U-GOV porta il nome del corso in italiano)
    # Nursing: la programmazione 2026/27 elenca le sole attività con lezioni (senza tirocinio, tesi e attività a scelta): i CFU
    # sono la somma delle righe di ogni integrato (codice «COD AF») e il nome è quello dell'integrato, non di un solo modulo
    "unicampania-l-snt1-nursing": {"prefisso": r"A42\d{4}", "senza_verifica": True, "url": "http://www.scienzemedichetraslazionali.unicampania.it/didattica/corsi-di-studio/nursing-infermieristica-in-lingua-inglese", "piani": [{
        "tipo": "tabella", "url": "https://www.scienzemedichetraslazionali.unicampania.it/avvisi/planning_26-27.pdf",
        "righe": [(1, "A422395", "Biomedical sciences", 5, None, True), (1, "A422396", "Anatomy-physiology", 7, None, True),
                  (1, "A422397", "Nursing 1", 6, None, True), (1, "A422398", "Human sciences", 7, None, True),
                  (1, "A422399", "Italian 1", 2, None, True), (1, "A422400", "Physiopathology sciences", 6, None, True),
                  (2, "A422402", "Preventive care", 5, None, True), (2, "A422403", "Pharmacology and pathology 1", 4, None, True),
                  (2, "A422406", "General and specialistic surgery", 4, None, True), (2, "A422407", "Nursing 2", 6, None, True),
                  (2, "A422409", "Italian 2", 2, None, True), (2, "A422410", "Internistic medicine", 6, None, True),
                  (2, "A422412", "Oncologic diseases", 5, None, True),
                  (3, "A422411", "Nursing 3", 6, None, True), (3, "A422417", "Disability disorders", 4, None, True),
                  (3, "A422418", "Emergency", 6, None, True), (3, "A422422", "Gynaecology and pediatrics", 4, None, True),
                  (3, "A422423", "Epidemiologics", 9, None, True)]}]},
    "unicampania-l-snt2-logopedia": {"prefisso": r"A71\d\d", "piani": [{
        "tipo": "codici", "prefisso": r"A71\d\d|A42\d{4}",
        "url": "https://www.salutementaleefisica.unicampania.it/avvisi/A.A._20262027/Corsi_di_Laurea/Logopedia/Insegnamento_/Insegnamento_LOGO_NAPOLI_26_27.pdf",
        "nomi": {"A422036": "Chirurgia generale, otorinolaringoiatria, audiologia I e radioterapia",
                 "A423979": "Malattie dell'apparato respiratorio, gastroenterologia, medicina interna e anatomia patologica"}}]},
    "unicampania-l-snt2-terapia-della-neuro": {"prefisso": r"A74\d\d", "piani": [{
        "tipo": "codici", "prefisso": r"A74\d\d|A42\d{4}",
        "url": "https://www.salutementaleefisica.unicampania.it/avvisi/A.A._20262027/Corsi_di_Laurea/TNPEE/Insegnamento/Insegnamenti_TNPEE_26_27.pdf",
        "nomi": {"A421635": "Psicologia e sviluppo neuropsicomotorio"}}]},
    "unicampania-l-snt2-tecnica-della-riabilitazione": {"prefisso": r"A73\d\d", "piani": [{
        "tipo": "codici", "prefisso": r"A73\d\d|A42\d{4}", "head": "parole",
        "url": "https://www.salutementaleefisica.unicampania.it/avvisi/Insegnamento_TRP_2025_2026_1_2.pdf"}]},
    "unicampania-l-snt1-ostetricia": {"prefisso": r"A\d{4}", "piani": [{
        "tipo": "codici", "prefisso": r"A61\d\d", "alias": {"A61121": "A6121"},  # il piano scrive «A61121» il laboratorio A6121
        "url": "https://www.dipdbc.unicampania.it/images/piani_studio/Piano_Ostetricia.pdf"},
        # due laboratori professionali nello stesso anno (A6121 2 CFU, A6125 1 CFU): nomi distinti
        {"tipo": "tabella", "url": "https://www.dipdbc.unicampania.it/images/piani_studio/Piano_Ostetricia.pdf",
         "righe": [(3, "A6121", "Laboratorio professionale - parte 1", 2, None, True), (3, "A6125", "Laboratorio professionale - parte 2", 1, None, True)]}]},
    # Scienze infermieristiche e ostetriche: programmazione didattica 2026/27 (CFU dei corsi integrati A.1…D.2; i codici delle righe già
    # lette sono quelli degli integrati, il cui nome nel database è quello di un solo modulo)
    # Matematica LM-40: 2° anno del manifesto 2026/27 (coorte 2025-26): un insegnamento di Tabella 1 (TAF B) e due di Tabella 3 o 4 (TAF C),
    # ulteriori conoscenze linguistiche 2, abilità informatiche e telematiche 2, attività a scelta 8, prova finale 24 (= 60 CFU). Gli
    # insegnamenti opzionali sono quelli già letti per il 1° anno («Coorti 2025-2026, 2026-2027»)
    "unicampania-lm-40-matematica": {"piani": [{
        "tipo": "tabella", "url": "https://www.matfis.unicampania.it/images/All2_Manifesto_A37_MAT_LM_26-27_corr_1.pdf",
        "righe": [(2, None, "Ulteriori conoscenze linguistiche", 2), (2, None, "Abilità informatiche e telematiche", 2),
                  (2, None, "Attività autonomamente scelte dallo studente", 8, True), (2, None, "Prova finale", 24),
                  # Tabella 1 (TAF B, formazione teorica avanzata)
                  (2, "A3426", "Teoria degli Insiemi", 8, True, False, "copia"), (2, "A422255", "Algebra Commutativa", 8, True, False, "copia"),
                  (2, "A3729", "Teoria di Galois", 8, True, False, "copia"), (2, "A422253", "Teoria dei Gruppi", 8, True, False, "copia"),
                  (2, "A423386", "Geometria Combinatoria e Applicazioni", 8, True, False, "copia"),
                  (2, "A423033", "Analisi Matematica Avanzata", 8, True, False, "copia"),
                  # Tabelle 3 e 4 (TAF C)
                  (2, "A3717", "Laboratorio di Fisica Moderna", 8, True, False, "copia"),
                  (2, "A423385", "Elementi di Relativita' e Fisica Quantistica", 8, True, False, "copia"),
                  (2, "A423586", "Analisi dei Dati Multidimensionali", 8, True, False, "copia"), (2, "A425083", "Finanza Matematica", 8, True, False, "copia"),
                  (2, "A425082", "Elaborazione dei Segnali e Applicazioni Biomediche", 8, True, False, "copia"),
                  (2, "A425081", "Sviluppo e Verifica del Software", 8, True, False, "copia"),
                  (2, "A424450", "Theory of quantum computation", 8, True, False, "copia"),
                  (2, "A422260", "Didattica della Matematica", 8, True, False, "copia"), (2, "A425093", "Numerical Optimization", 8, True, False, "copia"),
                  (2, None, "Machine Learning & Artificial Intelligence (mutuato dal CdL in Data Science)", 8, True),
                  (2, None, "Applicazioni della Meccanica dei Fluidi", 8, True),
                  # Tabella 2 (TAF B, formazione modellistico applicativa): anche questi valgono per il TAF C della Tabella 4
                  (2, "A425561", "Processi Stocastici", 8, True, False, "copia"), (2, "A422276", "Equazioni di Navier-stokes", 8, True, False, "copia"),
                  (2, "A3722", "Equazioni Differenziali della Fisica Matematica", 8, True, False, "copia"),
                  (2, "A422755", "Meccanica Superiore", 8, True, False, "copia"),
                  (2, "A426009", "Metodi Numerici per il Machine Learning", 8, True, False, "copia")]}]},
    "unicampania-lm-snt1-scienze-infermieristiche-e-ostetriche": {"piani": [{
        "tipo": "tabella", "url": "https://www.medicinasperimentale.unicampania.it/images/CDLM_SIO_Programmazione_Didattica_2026-2027.pdf",
        "righe": [(1, "A426014", "Management sanitario e programmazione dei servizi", 7),
                  (1, "A426025", "Responsabilità etiche e giuridiche", 5, None, True),
                  (1, "A426031", "Direzione e sviluppo dei team infermieristici ai diversi livelli di complessità organizzativa", 7, None, True),
                  (1, None, "Inglese", 2),
                  (1, "A426037", "Gestione dei flussi informativi in ambito sanitario", 4, None, True),
                  (1, "A426042", "Prevenzione ed educazione sanitaria", 5, None, True),
                  (1, "A426048", "Management oncologico", 6, None, True),
                  (1, None, "ADE 1° anno", 2, True), (1, None, "Attività di laboratorio 1° anno", 2), (1, None, "Esame di tirocinio 1° anno", 20),
                  (2, "A8511", "Sviluppo e ricerca delle scienze infermieristiche e ostetriche", 6, None, True),
                  (2, "A8512", "Sviluppo e formazione delle scienze infermieristiche e ostetriche", 7, None, True),
                  (2, "A8513", "Management e ricerca in area medica", 7, None, True),
                  (2, "A8514", "Management e ricerca in area chirurgica", 6, None, True),
                  (2, None, "ADE 2° anno", 4, True), (2, None, "Attività di laboratorio 2° anno", 3), (2, None, "Esame di tirocinio 2° anno", 20),
                  (2, None, "Elaborazione tesi", 7)]}]},
    # Scienze della formazione primaria: piano degli studi 2026/27 (lo stesso piano vale per tutte le coorti: il documento
    # 2025/26 riporta gli stessi codici); gli anni 4° e 5° non hanno ancora le schede, gli integrati hanno nel database il
    # codice U-GOV dell'integrato (prima unità - 1) e il CFU complessivo di insegnamento + laboratorio
    "unicampania-lm-85-bis-scienze-della-formazione-primaria": {"piani": [{
        "tipo": "tabella", "url": "https://www.letterebeniculturali.unicampania.it/images/didattica/pianidistudio/2026-2027/SFP_Piano_Studi_2026-2027.pdf",
        "righe": [
            (1, "A424922", "Pedagogia generale e laboratorio", 9), (1, "A424937", "Didattica generale e tecnologie didattiche e laboratorio", 12),
            (1, "A424929", "Psicologia dello sviluppo e laboratorio", 9), (1, "A424938", "Storia antica", 4),
            (1, "A424912", "Antropologia culturale", 8), (1, "A424932", "Metodologia della ricerca educativa e didattica e laboratorio", 13),
            (1, "A424933", "Laboratorio di lingua inglese I", 2),
            (2, "A424913", "Pedagogia interculturale", 8), (2, "A424955", "Fondamenti di matematica", 8),
            (2, "A424946", "Pedagogia speciale e laboratorio", 12), (2, "A424949", "Letteratura italiana e laboratorio", 7, None, True),
            (2, "A424914", "Storia moderna", 6), (2, "A424952", "Geografia politico-economica e laboratorio", 9),
            (2, "A424958", "Laboratorio di lingua inglese II", 2), (2, "A424959", "Tirocinio I", 6),
            (3, "A424960", "Linguistica italiana e laboratorio", 13, None, True), (3, "A424966", "Didattica della matematica e laboratorio", 14),
            (3, "A424915", "Letteratura italiana contemporanea", 6), (3, "A424963", "Educazione musicale e laboratorio", 9),
            (3, "A424916", "Storia della scuola", 8), (3, "A424969", "Legislazione scolastica", 4),
            (3, "A424970", "Laboratorio di lingua inglese III", 2), (3, "A424971", "Lingua inglese (prova di idoneità B2)", 2),
            (3, "A424972", "Tirocinio II", 6),
            (4, "A424917", "Storia contemporanea", 6), (4, "A424979", "Elementi e didattica di fisica e laboratorio", 9),
            (4, "A424977", "Pedagogia e didattica speciale e laboratorio", 10), (4, "A424974", "Metodi e didattica dell'attività motoria e laboratorio", 9),
            (4, "A424918", "Psicologia dell'educazione", 8), (4, "A424919", "Fondamenti di chimica", 4),
            (4, None, "Laboratorio di didattica della lingua inglese I", 2), (4, "A424984", "Tirocinio III", 6),
            # attività a scelta libera (8 CFU) al 4° anno: gli insegnamenti attivati nel 2026/27
            (4, "A424999", "Matematica e linguaggi", 8, True), (4, "A425000", "Metodologia e didattica della storia", 8, True),
            (4, "A425001", "Geografia storica e umana", 8, True), (4, "A425985", "Educazione al patrimonio", 8, True),
            (5, "A424986", "Letteratura per l'infanzia e laboratorio", 9), (5, "A424942", "Elementi di biologia e laboratorio", 13),
            (5, None, "Psicologia clinica", 8), (5, "A424990", "Laboratorio di tecnologie didattiche", 3),
            (5, "A424989", "Laboratorio di didattica della lingua inglese II", 2), (5, "A424991", "Tirocinio IV", 6),
            (5, "A424992", "Prova finale", 9),
            # un insegnamento opzionale (9 CFU con il laboratorio) a scelta tra due al 5° anno
            (5, "A424994", "Educazione all'immagine e laboratorio (opzionale)", 9, True), (5, "A424997", "Storia dell'arte contemporanea e laboratorio (opzionale)", 9, True)]}]},
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
    # (corso iniziato nel 2025/26: nel 2026/27 sono attivi il 1° anno, coorte 2026, e il 2°, coorte 2025; dal 3° anno la
    #  programmazione ha «Anno Offerta 2027-28» e seguenti, quindi gli anni 3°-6° non hanno ancora attività erogate)
    "unicampania-lm-41-medicina-e-chirurgia-1634408": {
        "url": "http://www.dipmdsmco.unicampania.it/didattica/corsi-di-studio/medicina-e-chirurgia", "prefisso": r"A42\d{4}", "piani": [{
        "tipo": "tabella", "url": "https://www.dipmdsmco.unicampania.it/images/2._all.2_PROGRAMMAZIONE_DIDATTICA_Corso_di_Studi_in_MEDICINA_a.a._2026-27__31.03.26_04.05.26_-_modifiche_10.06.26.pdf",
        "righe": [(1, "A425834", "Fisica", 6, None, True), (1, "A425266", "Chimica e propedeutica biochimica", 6, None, True),
                  (1, "A425835", "Biologia", 6, None, True), (1, "A425840", "Anatomia umana", 8, None, True),
                  (1, "A425273", "Istologia ed embriologia medica", 8, None, True),
                  (1, "A425277", "Basi metodologiche in medicina e bioetica", 17, None, True),
                  (2, "A425841", "Anatomia umana", 7, None, True), (2, "A425294", "Biochimica e biologia molecolare", 13, None, True),
                  (2, "A425297", "Fisiologia medica - 1° semestre", 7, None, True), (2, "A425298", "Fisiologia medica - 2° semestre", 7, None, True),
                  (2, "A425839", "Microbiologia, immunologia e immunopatologia", 11, None, True),
                  (2, "A425302", "Patologia generale, fisiopatologia e genetica medica", 7, None, True),
                  (2, "A425306", "ADE 2° anno", 2, True)]}]},
    # un articolo per ogni corso integrato
    "unicampania-lm-41-medicina-e-chirurgia-1634406": {"fonti": [(
        "https://www.medicinasperimentale.unicampania.it/didattica/corsi-di-studio/corso-di-laurea-magistrale-a-ciclo-unico-in-"
        "medicina-e-chirurgia-sede-di-napoli/10-didattica/1696-insegnamenti-a-a-2026-2027-corso-di-laurea-magistrale-a-ciclo-"
        "unico-in-medicina-e-chirurgia-sede-di-napoli", "articoli")]},
    # il piano 2025/26 (con i codici delle attività) è l'ultimo pubblicato in PDF; le pagine dei corsi integrati sono del 2026/27
    # (CFU e attività senza scheda trascritti dal piano didattico 2025/26: integrati con unità senza codice dell'integrato
    #  e righe su più celle; ogni anno somma 60 CFU)
    "unicampania-l-snt3-tecniche-di-laboratorio-biomedico": {"prefisso": r"A77\d\d", "fonti": [(
        "http://www.medicinadiprecisione.unicampania.it/images/Piano_di_Studi_TLB_a.a._25-26.pdf", "pdf")], "piani": [{
        "tipo": "tabella", "url": "http://www.medicinadiprecisione.unicampania.it/images/Piano_di_Studi_TLB_a.a._25-26.pdf",
        "righe": [(1, "A422815", "Fondamenti preliminari alla pratica professionale", 4),  # Sicurezza in laboratorio 2 + Organizzazione 2
                  (1, "A422832", "Attività formative professionalizzanti - Tirocinio", 23),
                  (2, "A7711", "Anatomia patologica e metodologie diagnostiche", 6),  # 2 + 1 (affine) + 3
                  (2, "A422821", "Attività formative professionalizzanti - Tirocinio", 26),
                  (3, "A7712", "Metodologie per la pratica professionale e bioetica", 6),  # 2 + 2 + 2
                  (3, "A7716", "Immunoematologia e medicina trasfusionale", 10),  # 3 + 2 + 1 + 4
                  (3, "A421481", "Attività a scelta dello studente", 6, True),
                  (3, "A422829", "Attività formative professionalizzanti - Stage", 3),
                  (3, "A422830", "Attività formative professionalizzanti - Tirocinio", 15),
                  (3, "A7721", "Prova finale (tesi di laurea)", 6)]}]},
    "unicampania-l-snt3-tecniche-di-radiologia-medica": {"prefisso": r"A79\d\d", "fonti": [(
        "http://www.medicinadiprecisione.unicampania.it/images/Piano_di_Studi_a.a_25.26.pdf", "pdf")], "piani": [{
        "tipo": "tabella", "url": "http://www.medicinadiprecisione.unicampania.it/images/Piano_di_Studi_a.a_25.26.pdf",
        # CFU di ogni integrato = somma delle sue unità (colonna «CORSO INTEGRATO»); attività senza scheda dal piano
        "righe": [(1, "A424502", "Fondamenti di Radiologia Tradizionale", 8), (1, "A7907", "Fondamenti di Anatomia e Anatomia Radiologica", 6),
                  (1, "A7901B", "Lingua inglese", 3), (1, "A7904", "Attività a scelta I", 2, True),
                  (1, "A424506", "Laboratorio professionalizzante I", 1), (1, "A7910", "Tirocinio teorico-pratico I", 19),
                  (2, "A7917", "Apparecchiature e Tecniche TC", 8), (2, "A7918", "Apparecchiature e Tecniche RM", 8),
                  (2, "A7913", "Trattamento e Trasmissione delle Immagini Digitalizzate", 8),
                  (2, "A7912", "Apparecchiature e Tecniche di Neuroradiologia e Nozioni di Ultrasonologia", 4),
                  (2, "A424512", "Laboratorio professionalizzante II", 1), (2, "A7908", "Attività a scelta II", 2, True),
                  (2, "A7922", "Tirocinio teorico-pratico II", 25),
                  (3, "A7923", "Apparecchiature e Tecniche Angiografiche", 3), (3, "A7924", "Apparecchiature e Tecniche di Medicina Nucleare", 7),
                  (3, "A7925", "Apparecchiature e Tecniche di Radioterapia", 4), (3, "A424515", "Management nei servizi sanitari", 5),
                  (3, "A7914", "Attività a scelta III", 2, True), (3, "A424517", "Laboratorio professionalizzante III", 1),
                  (3, "A7933", "Tirocinio teorico-pratico III", 28), (3, "A7934", "Esame finale", 6)]}]},
    "unicampania-lm-41-medicina-e-chirurgia-1634407": {"fonti": [(
        "https://www.medicinadiprecisione.unicampania.it/didattica/corsi-di-studio/corso-di-laurea-magistrale-a-ciclo-unico-in-"
        "medicina-e-chirurgia-in-lingua-inglese-medicine-and-surgery-in-english/10-didattica/1523-teaching-plan-2026-2027",
        "articoli")]},
}


def _testo_documento(c: "_Scarica", url: str) -> str | None:
    """Testo di un PDF o di una pagina (articolo) con il piano di studio/manifesto."""
    if url.lower().split("?")[0].endswith(".pdf"):
        dati = c.pdf(url)
        return "\n".join((p.extract_text() or "") for p in _pdf_reader(dati).pages) if dati else None
    r = c.get(url)
    if not r:
        return None
    s = _pulisci(r.text)
    m = re.search(r'itemprop="articleBody"', s)
    s = s[m.start():] if m else s
    fine = s.find("<aside")
    s = s[:fine] if fine > 0 else s
    s = re.sub(r"(?i)</(?:tr|p|div|li|h\d)>|<br\s*/?>", "\n", s)
    s = re.sub(r"(?i)</t[dh]>", " ", s)
    return html.unescape(re.sub(r"<[^>]+>", " ", s))


def _applica_cfu_pdf(x: dict, ci_doc: dict, oggi: str, aggiungi: bool = False) -> None:
    """CFU complessivi letti dal PDF dell'elenco: correggono i CFU presi dalla scheda di un solo modulo; gli
    insegnamenti dell'elenco senza scheda collegata («Da definire») si aggiungono con il CFU del PDF se il corso ha
    `righe_da_pdf` in CORSI (provato sui piani di Ingegneria biomedica e informatica magistrale)."""
    import difflib
    usate = set()
    for i in x["insegnamenti"]:
        n = _norm_nome(i["nome"])
        k = (i["anno"], n)
        if k not in ci_doc:  # nome scritto in modo un po' diverso («Metodi … per l'analisi» / «Metodi … di analisi»)
            simili = [(difflib.SequenceMatcher(None, n, kk[1]).ratio(), kk) for kk in ci_doc if kk[0] == i["anno"]]
            k = max(simili)[1] if simili and max(simili)[0] >= 0.85 else None
        if k is None:
            continue
        usate.add(k)
        v = ci_doc[k][0]
        if not i.get("cfu") or v > i["cfu"]:
            i["cfu"] = int(v) if float(v).is_integer() else v
    for k, (v, sem, nome) in ci_doc.items():
        if not aggiungi or k in usate or len(nome) < 6 or re.match(r"(?i)totale|insegnamento|modulo", nome):
            continue
        if any(i["anno"] == k[0] and difflib.SequenceMatcher(None, _norm_nome(i["nome"]), k[1]).ratio() >= 0.85
               for i in x["insegnamenti"]):
            continue
        x["insegnamenti"].append({
            "codice": None, "nome": _titolo(nome), "anno": k[0], "periodo": {"I": "1", "II": "2"}.get(sem, "annuale"),
            "cfu": int(v) if float(v).is_integer() else v, "ssd": None, "obbligatorio": None, "curriculum": None,
            "docenti": [], "url": x["fonte"], "libri": [], "esami": [], "fonte": x["fonte"], "verificato_il": oggi,
            "stato_libri": "da_aggiungere"})


def _aggiungi_attivita(x: dict, cfg: dict, c: "_Scarica", oggi: str, log=print) -> None:
    """Aggiunge a un corso le attività senza scheda (a scelta, tirocinio, prova finale…) del manifesto / piano di studio
    ufficiale indicato in `CORSI[...]["manifesto"]` (elenco di url, o (url, curriculum)); un'attività già presente
    nello stesso anno con lo stesso nome (collegata a una scheda) non si ripete. Le attività con lo stesso nome e anno
    si distinguono con un numero («Attività a scelta - parte 2»), perché build_db unisce per nome le voci senza codice."""
    fonti = cfg.get("manifesto") or []
    if isinstance(fonti, (str, tuple)):
        fonti = [fonti]
    durata = x.get("durata_anni") or 6
    # attività elencate nel documento ufficiale ma non leggibili dal testo (celle senza il nome sulla stessa riga):
    # (anno, nome, CFU, a scelta?) lette dal documento `extra_fonte`
    for anno_e, nome_e, cfu_e, scelta_e in cfg.get("extra") or []:
        if any(i["anno"] == anno_e and _norm_nome(i["nome"]) == _norm_nome(nome_e) for i in x["insegnamenti"]):
            continue
        fonte_e = cfg["extra_fonte"]
        x["insegnamenti"].append({
            "codice": None, "nome": nome_e, "anno": anno_e, "periodo": None, "cfu": cfu_e, "ssd": None,
            "obbligatorio": False if scelta_e else True, "curriculum": None, "docenti": [], "url": fonte_e, "libri": [],
            "esami": [], "fonte": fonte_e, "verificato_il": oggi, "stato_libri": "da_aggiungere"})
    for f in fonti:
        url, curr = (f, None) if isinstance(f, str) else f
        testo = _testo_documento(c, url)
        if not testo:
            log(f"[unicampania]   {x['id'][:50]}: documento {url} non letto")
            continue
        note = {_norm_nome(i["nome"]) + f":{i['anno']}:{i.get('curriculum') or ''}" for i in x["insegnamenti"]}
        viste: dict[tuple, int] = {}
        gia: set = set()
        for a in leggi_attivita_manifesto(testo, durata):
            if _norm_nome(a["nome"]) in {_norm_nome(n) for n in cfg.get("manifesto_salta") or []}:
                continue  # attività già nel piano per anno (un laboratorio per anno invece del totale del corso)
            chiave = (a["anno"], _norm_nome(a["nome"]))
            if cfg.get("tail_unici") and (chiave, a["cfu"]) in gia:
                continue
            gia.add((chiave, a["cfu"]))
            viste[chiave] = viste.get(chiave, 0) + 1
            n = viste[chiave]
            nome = a["nome"] if n == 1 else f"{a['nome']} - parte {n}"
            if _norm_nome(nome) + f":{a['anno']}:{curr or ''}" in note:
                continue
            scelta = bool(re.match(rf"(?i){_ATT_SCELTA}", a["nome"]))
            x["insegnamenti"].append({
                "codice": None, "nome": nome, "anno": a["anno"], "periodo": None,
                "cfu": int(a["cfu"]) if float(a["cfu"]).is_integer() else a["cfu"], "ssd": None,
                "obbligatorio": False if scelta else True, "curriculum": curr, "docenti": [], "url": url, "libri": [],
                "esami": [], "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere"})


# corsi il cui piano ufficiale è fisso (tutti gli esami obbligatori, con le attività a scelta indicate): obbligatorio esplicito
_PIANO_OBBLIGATORIO = ("unicampania-l-snt", "unicampania-lm-snt", "unicampania-lm-85-bis", "unicampania-lm-46",
                       "unicampania-lm-41-medicina-e-chirurgia")


def _applica_piani(x: dict, cfg: dict, c: "_Scarica", oggi: str, log=print) -> None:
    """Piani di studio ufficiali delle professioni sanitarie (`CORSI[...]["piani"]`, vedi `unicampania_piani`): i CFU degli
    integrati e le attività senza scheda (tirocinio, attività a scelta, laboratori, seminari, prova finale). Alla fine si
    scrive nel log la somma dei CFU di ogni anno, per controllare il piano con i 60 CFU annuali."""
    for p in cfg.get("piani") or []:
        tipo, url = p["tipo"], p.get("url") or p.get("fonte")
        if tipo == "tabella":
            res = piani.applica_tabella(x, p["righe"], url, oggi, log)
        elif tipo == "coorti":  # un documento per coorte: (anno, url, a.a. erogato)
            specs = [(a, u, _testo_documento(c, u), er) for a, u, er in p["specs"]]
            res = piani.applica_coorti(x, [q for q in specs if q[2]], oggi, log)
            url = p["specs"][0][1]
        else:
            testo = _testo_documento(c, url)
            if not testo:
                log(f"[unicampania]   {x['id'][:50]}: piano {url} non letto")
                continue
            if tipo == "codici":
                recs = piani.leggi_codici(testo, p["prefisso"], p.get("alias"), p.get("head", "caps"), p.get("fine"))
                for k, v in (p.get("cfu_unita") or {}).items():
                    if k in recs:
                        recs[k]["cfu"] = v
                res = piani.applica_codici(x, recs, p, url, oggi, log)
            elif tipo == "ugov":
                res = piani.applica_ugov(x, piani.leggi_ugov(testo), p, url, oggi, log)
            elif tipo == "nomi":
                res = piani.applica_nomi(x, testo, url, p, log)
            else:
                continue
        somme: dict = {}
        for i in x["insegnamenti"]:
            if isinstance(i.get("cfu"), (int, float)):
                somme[i["anno"]] = somme.get(i["anno"], 0) + i["cfu"]
        log(f"[unicampania]   {x['id'][11:60]}: piano {tipo} {res}; CFU per anno {dict(sorted(somme.items(), key=lambda q: str(q[0])))}")
    if cfg.get("piani") and x["id"].startswith(_PIANO_OBBLIGATORIO):
        for i in x["insegnamenti"]:  # il piano ufficiale elenca gli esami obbligatori; le attività a scelta sono già `False`
            if i.get("obbligatorio") is None:
                i["obbligatorio"] = True


def _distingui_omonimi(x: dict) -> None:
    """Due attività con lo stesso nome nello stesso anno e codici diversi (la «Lingua francese» da 9 CFU e quella da 6 CFU
    dei due ordinamenti del corso) sono insegnamenti distinti della fonte: il nome dice quale (CFU, o il codice se i CFU
    sono uguali). build_db le unirebbe per nome."""
    gruppi: dict[tuple, list[dict]] = {}
    for i in x["insegnamenti"]:
        gruppi.setdefault((i.get("anno"), _norm_nome(i["nome"]), i.get("curriculum")), []).append(i)
    for righe in gruppi.values():
        codici = {r.get("codice") for r in righe if r.get("codice")}
        if len(righe) < 2 or len(codici) < 2:
            continue
        cfu = [r.get("cfu") for r in righe]
        for r in righe:
            if r.get("codice"):
                r["nome"] += f" ({r['cfu']:g} CFU)" if len(set(cfu)) == len(cfu) and isinstance(r.get("cfu"), (int, float)) else f" ({r['codice']})"


def _cfg(cid: str) -> dict:
    """Impostazioni del corso: la chiave più lunga che è un prefisso dell'id."""
    ks = [k for k in CORSI if cid.startswith(k)]
    return CORSI[max(ks, key=len)] if ks else {}


def _slug_corso(url: str | None) -> str | None:
    """Ultimo segmento di `…/corsi-di-studio/<corso>` (la pagina del corso, o un elenco sotto di essa)."""
    m = re.search(r"/corsi-di-studio/([^/?#]+)", url or "")
    return m.group(1) if m else None


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
    altri_slug = {_slug_corso(x["url"]) for x in corsi} - {None}
    oggi = time.strftime("%Y-%m-%d")
    prec = anno - 1

    def build(corso: dict) -> dict | None:
        righe: dict[str, dict] = {}
        fonti: list[str] = []
        ci_doc: dict[tuple[int, str], float] = {}
        cfg = _cfg(corso["id"])
        if cfg.get("fonti"):
            sorgenti = [(u, k, None) for u, k in cfg["fonti"]]
        else:  # la pagina del corso stessa (spesso ha l'elenco in una scheda a fisarmonica) e i documenti che collega
            sorgenti = [(corso["url"], "html", None)] + fonti_corso(c, corso["url"], anno)
            # il menu delle pagine di alcuni dipartimenti (Architettura) collega gli elenchi degli altri corsi: non sono di questo
            propria = _slug_corso(corso["url"])
            sorgenti = [q for q in sorgenti if _slug_corso(q[0]) in (None, propria) or _slug_corso(q[0]) not in altri_slug]
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
                        ci_doc.update(leggi_cfu_pdf(dati, corso.get("durata_anni") or 6))
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
                href = p if not v["href"] else v["href"] if v["href"].startswith("http") else host + v["href"]
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": v["cod_attivita"], "nome": None, "anno": v["anno"],
                        "periodo": v["periodo"], "cfu": None, "ssd": v["ssd"], "obbligatorio": None,
                        "curriculum": v.get("curriculum"), "docenti": [], "url": href, "libri": [], "esami": [], "fonte": p,
                        "verificato_il": oggi, "_unita": {}, "_schede": set(), "_ci": False, "_aa": v.get("aa"),
                        "_host": host, "_cfu_tab": v.get("cfu_tab"),
                    }
                nome_v = v["integrato"] or v["nome"]
                if nome_v and not _NOME_VERO.search(nome_v):  # «5», «6»: il testo del link è il CFU; il nome lo dà la scheda
                    nome_v = None
                nome = _titolo(nome_v) if nome_v else None
                if nome and (not item["nome"] or (not v["cod_unita"] and not v["integrato"])):
                    item["nome"] = nome  # il nome del corso integrato (link senza unità) vale più di quello di un modulo
                item["periodo"] = item["periodo"] or v["periodo"]
                if v.get("scelta"):
                    item["obbligatorio"] = False
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
                "fonte": fonti[0], "verificato_il": oggi, "insegnamenti": list(righe.values()), "_ci_doc": ci_doc}

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
        if i.get("_cfu_tab") and float(i["_cfu_tab"]) > tot:  # la scheda collegata è di un solo modulo: vale il CFU del piano
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
            if re.search(r"(?i)\ba scelta\b", i["nome"]):  # «Fondamenti di sostenibilità - esame a scelta», «2 Insegnamenti a Scelta»
                i["obbligatorio"] = False
    for x in out:  # CFU complessivi dei PDF (l'insegnamento integrato vale più della scheda del singolo modulo)
        _applica_cfu_pdf(x, x.pop("_ci_doc", None) or {}, oggi, bool(_cfg(x["id"]).get("righe_da_pdf")))
    for x in out:
        try:
            _aggiungi_attivita(x, _cfg(x["id"]), c, oggi, log)
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}]   attività senza scheda di {x['id']} non lette: {e!r}")
        try:
            _applica_piani(x, _cfg(x["id"]), c, oggi, log)
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}]   piano di studio di {x['id']} non letto: {e!r}")
        _distingui_omonimi(x)
    out = [x for x in out if x["insegnamenti"]]
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dai siti dei dipartimenti *.unicampania.it "
                                                 "(adapters/unicampania.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
