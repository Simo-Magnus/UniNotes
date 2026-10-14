"""Appelli d'esame dell'Università di Genova dai prospetti pubblici del calendario esami.

La pagina "Calendario esami" di ogni corso (`corsi.unige.it/corsi/<id>/studenti-calendario-esami`)
linka uno o più "Prospetti calendario esami" (`servizionline.unige.it/…STAMPAPROSPETTOSALVATO?p_id=…`):
una tabella con codice e nome dell'insegnamento (più docente), corso e, per sessione, le prove
("Orale: 17/12/2026 09:00"). Gli insegnamenti integrati hanno una riga di titolo
("108706 FISICA MATEMATICA E SISTEMI DI TRASPORTO") seguita dai moduli, con il codice del
modulo nella seconda colonna: le date dei moduli valgono anche per l'integrato.
L'intestazione dice l'a.a. ("anno accademico 2026/2027", o "anno solare 2027" per Giurisprudenza e
Farmacia) e se il calendario è già approvato.

I titoli dei link non hanno un formato fisso ("2026/27 …", "2026-27 …", "ECONOMIA 2026/2027
ESAMI", "FAR E CTF AA 2026-2027"): l'a.a. si legge dall'intestazione del prospetto. Del
prospetto dell'a.a. corrente si tengono tutte le date; dei prospetti degli a.a. precedenti
(alcuni corsi non hanno ancora pubblicato quello nuovo) solo le date da oggi in poi.
Alcuni corsi (Medicina e Chirurgia) allegano invece alla stessa pagina dei PDF "APPELLI … ANNO 26_27":
tabelle con anno/semestre, codice dell'insegnamento (o "codice - nome" del modulo) e le date degli
appelli per sessione (`leggi_pdf_appelli`).
Le pagine si scaricano sempre fresche (niente cache su disco): i link cambiano durante l'anno.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import io
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
PAGINE = ("https://corsi.unige.it/corsi/{}/studenti-calendario-esami",
          "https://corsi.unige.it/corsi/{}/students-exams-schedule")
PROVA = re.compile(r"([A-Za-zÀ-ÿ' ]+?):\s*(\d{2})/(\d{2})/(\d{4})(?:\s+(\d{1,2}):(\d{2}))?")
LINK = re.compile(r"href=['\"]([^'\"]*STAMPAPROSPETTOSALVATO[^'\"]*)['\"]")
PDF = re.compile(r"(?i)href=['\"](/sites/corsi\.unige\.it/files/[^'\"]*appell[^'\"]*\.pdf)['\"]")
RIGA_PDF = re.compile(r"(?m)^(?:[IV]+\s*anno\s*/\s*\S+\s*sem\.?\s+)?(?:\d{5,6}\s+(?=\d{5,6}\s*-))?(\d{5,6})(\s*-)?\s+(?=[A-Z])")
DATA_PDF = re.compile(r"\b(\d{1,2})/{1,2}(\d{1,2})/{1,2}(\d{4})\b")


def _modalita(p: str) -> str:
    p = p.lower()
    if "scritt" in p and "oral" in p:
        return "scritto+orale"
    for k, v in (("scritt", "scritto"), ("written", "scritto"), ("oral", "orale"), ("test", "quiz"),
                 ("progett", "progetto"), ("project", "progetto")):
        if k in p:
            return v
    return "altro"


def intestazione(s: str) -> tuple[int | None, str | None]:
    """(primo anno dell'a.a., etichetta): "anno accademico 2026/2027" -> (2026, "calendario a.a. 2026/2027");
    i calendari per anno solare ("anno solare 2027") valgono per l'a.a. che finisce in quell'anno."""
    t = _testo(s)
    m = re.search(r"(?i)anno accademico\s*(\d{4})\s*[/-]\s*\d{2,4}", t)
    if m:
        a = int(m.group(1))
        return a, f"calendario a.a. {a}/{a + 1}"
    m = re.search(r"(?i)anno solare\s*(\d{4})", t)
    if m:
        return int(m.group(1)) - 1, f"calendario anno solare {m.group(1)}"
    return None, None


def anno_prospetto(s: str) -> int | None:
    return intestazione(s)[0]


def leggi_prospetto(s: str, fonte: str, dal: str | None = None) -> dict[str, list[dict]]:
    """{codice: [esame, …]}; con `dal` (AAAA-MM-GG) solo le date da quel giorno in poi."""
    t = _testo(s)
    etichetta = intestazione(s)[1]
    note = ["calendario non approvato"] if re.search(r"(?i)calendario non approvato", t) else []
    if etichetta:
        note.append(etichetta)
    out: dict[str, list[dict]] = {}
    padre = None  # (codice, nome) dell'insegnamento integrato di cui seguono i moduli
    for tr in re.findall(r"<tr.*?</tr>", s, re.S):
        c = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if len(c) == 1:
            m = re.fullmatch(r"(\d{4,})\s+(.+)", _testo(c[0]))
            padre = (m.group(1), _titolo(m.group(2))) if m else None
            continue
        if len(c) < 4:
            continue
        nome_doc = re.split(r"<\s*/?\s*br\s*/?>", c[1], maxsplit=1)
        nome, docente = _testo(nome_doc[0]), _testo(nome_doc[1]) if len(nome_doc) > 1 else ""
        cod, modulo = _testo(c[0]), None
        if re.fullmatch(r"\d+", cod):
            padre = None
        else:
            m = re.fullmatch(r"(\d{4,})\s+(.+)", nome)
            if not m:
                continue
            cod, nome, modulo = m.group(1), m.group(2), padre
        prove = []
        for cella in c[3:]:
            for p, g, mm_, a, hh, mi in PROVA.findall(_testo(re.sub(r"<br\s*/?>", " ", cella))):
                data = f"{a}-{mm_}-{g}"
                if dal and data < dal:
                    continue
                prove.append((data, f"{int(hh):02d}:{mi}" if hh else None, _modalita(p)))
        for data, ora, mod in prove:
            e = {"tipo": "appello", "titolo": _titolo(nome), "data": data, "ora": ora, "luogo": None,
                 "modalita": mod, "iscrizioni_dal": None, "iscrizioni_al": None,
                 "docenti": docente.title() if docente.isupper() else (docente or None),
                 "note": "; ".join(note) or None, "fonte": fonte}
            out.setdefault(cod, []).append(e)
            if modulo:
                out.setdefault(modulo[0], []).append(
                    dict(e, titolo=modulo[1], note="; ".join([f"modulo {_titolo(nome)}"] + note)))
    return out


def leggi_pdf_appelli(testo: str, fonte: str, note: str | None = None, dal: str | None = None) -> dict[str, list[dict]]:
    """Testo di un PDF "APPELLI … ANNO" (Medicina): righe "I anno / 2° sem 58030 BIOCHIMICA" (insegnamento o
    integrato) e "58031- BIOCHIMICA Prova orale 13/01/2027 - …" (modulo, le date valgono anche per l'integrato).
    I periodi delle sessioni nell'intestazione ("(07/01/2027-28/02/2027)") non sono appelli."""
    t = re.sub(r"\(\s*\d{1,2}/\d{1,2}/\d{4}\s*-\s*\d{1,2}/\d{1,2}/\d{4}\s*\)", " ", testo)
    inizio = re.search(r"(?m)^[IV]+\s*anno\s*/", t)
    if not inizio:
        return {}
    t = t[inizio.start():]
    righe = list(RIGA_PDF.finditer(t))
    out: dict[str, list[dict]] = {}
    padre = None
    for k, m in enumerate(righe):
        corpo = t[m.end():righe[k + 1].start() if k + 1 < len(righe) else len(t)]
        cod, modulo = m.group(1), bool(m.group(2))
        if not modulo:
            padre = cod
        nome = re.split(r"\s{2,}|\n(?=[A-Z][a-z])|\s(?=[Pp]rova|L'esame|Esame|\d{1,2}/)", corpo.strip(), maxsplit=1)[0]
        nome = _titolo(re.sub(r"\s+", " ", nome).strip(" -–"))[:120]
        l = corpo.lower()
        mod = "scritto" if "scritt" in l else "orale" if "oral" in l else "altro"
        for g, mm, a in DATA_PDF.findall(corpo):
            data = f"{a}-{int(mm):02d}-{int(g):02d}"
            if dal and data < dal:
                continue
            e = {"tipo": "appello", "titolo": nome, "data": data, "ora": None, "luogo": None, "modalita": mod,
                 "iscrizioni_dal": None, "iscrizioni_al": None, "docenti": None, "note": note, "fonte": fonte}
            out.setdefault(cod, []).append(e)
            if modulo and padre and padre != cod:
                out.setdefault(padre, []).append(dict(e, note="; ".join(x for x in (f"modulo {nome}", note) if x)))
    return out


def fetch_appelli(uid: str = "unige", corsi: list[dict] | None = None, anno: int | None = None,
                  log=print) -> dict[str, list[dict]]:
    """{codice insegnamento: [esame, …]} da tutti i prospetti linkati dai corsi di `corsi`."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    oggi = time.strftime("%Y-%m-%d")
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    ids = sorted({m.group(1) for x in corsi for m in [re.search(r"corsi\.unige\.it/(?:en/)?corsi/(\d+)",
                                                                  (x.get("url") or "") + " " + (x.get("url_catalogo") or ""))] if m})
    c = Client(rate=2.0)
    c.cache = None  # i link ai prospetti cambiano durante l'anno: niente pagine vecchie dalla cache

    def prospetti(i: str) -> set[str]:
        urls: set[str] = set()
        for p in PAGINE:
            r = c.get(p.format(i))
            if r:
                urls |= {html.unescape(h) for h in LINK.findall(r.text)}
                urls |= {"https://corsi.unige.it" + h for h in PDF.findall(r.text)}
        return urls

    with cf.ThreadPoolExecutor(2) as ex:
        urls = sorted(set().union(*ex.map(prospetti, ids))) if ids else []
    out: dict[str, dict[tuple, dict]] = {}
    anni: dict = {}

    sigle = (f"{anno}-{(anno + 1) % 100:02d}", f"{anno}_{(anno + 1) % 100:02d}", f"{anno}/{(anno + 1) % 100:02d}",
             f"{anno}-{anno + 1}", f"{anno}/{anno + 1}")

    def leggi(u: str) -> dict[str, list[dict]]:
        r = c.get(u)
        if not r:
            return {}
        if u.lower().endswith(".pdf"):
            import pypdf
            try:
                testo = "\n".join(p.extract_text() or "" for p in pypdf.PdfReader(io.BytesIO(r.content)).pages)
            except Exception:  # noqa: BLE001 - PDF illeggibile: si salta
                return {}
            corrente = any(x in html.unescape(u).replace("%20", " ") + testo[:3000] for x in sigle)
            anni["pdf " + (str(anno) if corrente else "?")] = anni.get("pdf " + (str(anno) if corrente else "?"), 0) + 1
            return leggi_pdf_appelli(testo, u, f"calendario a.a. {anno}/{anno + 1} (PDF del corso)" if corrente else None,
                                     dal=None if corrente else oggi)
        aa = anno_prospetto(r.text)
        anni[aa] = anni.get(aa, 0) + 1
        return leggi_prospetto(r.text, u, dal=None if aa and aa >= anno else oggi)

    with cf.ThreadPoolExecutor(2) as ex:
        for d in ex.map(leggi, urls):
            for cod, lst in d.items():
                for e in lst:
                    out.setdefault(cod, {}).setdefault((e["data"], e["ora"], e["modalita"]), e)
    res = {k: sorted(v.values(), key=lambda e: (e["data"], e["ora"] or "")) for k, v in out.items()}
    log(f"[{uid}] appelli: {len(ids)} corsi, {len(urls)} prospetti (per a.a.: {anni}), "
        f"{sum(len(v) for v in res.values())} date per {len(res)} insegnamenti; richieste: {c.requests}")
    return res
