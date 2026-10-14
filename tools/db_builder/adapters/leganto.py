"""Libri dalle bibliografie Leganto (Ex Libris) pubblicate dagli atenei.

Molti syllabus rimandano alla bibliografia su Leganto con un link pubblico
`https://<ateneo>.alma.exlibrisgroup.com/leganto/public/<ISTITUTO>/lists?courseCode=<codice>`.
Le liste con visibilità pubblica/parziale si leggono senza credenziali: la pagina pubblica crea
una sessione anonima, poi

- `GET /leganto/rl/search/find/lists?course_code=<codice>&scope=all_lists` → liste del corso;
- `GET /leganto/rl/main/lists/<id>` → sezioni e citazioni (`dc`: titolo, autori, editore,
  anno, edizione, ISBN).

Si tengono solo i libri (tipo BK, capitoli BC); siti web e articoli no. Le liste private
(che chiedono il login) restano senza libri.
"""
from __future__ import annotations

import re
import threading
import time
import urllib.parse

import requests

from .testi import _isbn

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
           "Accept": "application/json"}
LINK = re.compile(r"https://[\w.-]+/leganto/public/[\w-]+/lists[^\"'<\s]*", re.I)

_sessioni: dict[str, requests.Session] = {}
_lock = threading.Lock()
_ultimo = {"t": 0.0}


def link(testo: str) -> list[str]:
    return list(dict.fromkeys(m.replace("&amp;", "&") for m in LINK.findall(testo or "")))


def _get(s: requests.Session, url: str, **kw) -> dict | None:
    for tentativo in range(3):
        with _lock:  # al massimo 2 richieste al secondo verso Leganto
            attesa = _ultimo["t"] + 0.5 - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            _ultimo["t"] = time.monotonic()
        try:
            r = s.get(url, timeout=60, **kw)
            if r.status_code in (401, 403, 404):
                return None
            return r.json()
        except (requests.RequestException, ValueError):
            time.sleep(2 ** tentativo)
    return None


def _sessione(pubblico: str) -> tuple[requests.Session, str]:
    """La sessione anonima vale solo per il corso della pagina pubblica con cui è aperta (courseCode):
    una sessione per ateneo e codice."""
    p = urllib.parse.urlparse(pubblico)
    base = f"{p.scheme}://{p.netloc}/leganto"
    codice = dict(urllib.parse.parse_qsl(p.query)).get("courseCode", "")
    chiave = f"{base}|{codice}"
    with _lock:
        s = _sessioni.get(chiave)
        if s is None:
            s = requests.Session()
            s.headers.update(HEADERS)
            time.sleep(0.5)
            try:
                s.get(pubblico, timeout=60, headers={"Accept": "text/html"})
            except requests.RequestException:
                pass
            _sessioni[chiave] = s
    return s, base


def _libro(dc: dict, sezione: str) -> dict | None:
    titolo = (dc.get("title") or "").strip()
    if not titolo:
        return None
    autori = (dc.get("creator") or dc.get("rlterms_author") or "").strip() or None
    anno = re.search(r"\d{4}", dc.get("date") or "")
    isbn = _isbn(str(dc.get("identifier_isbn") or ""))
    tipo = ("obbligatorio" if re.search(r"(?i)obbligator|adottat|required|mandatory|esame", sezione)
            else "consigliato" if re.search(r"(?i)consigliat|facoltativ|approfond|recommended|further|supplement",
                                            sezione) else None)
    cit = ", ".join(x for x in (autori, titolo, dc.get("publisher"), anno.group(0) if anno else None) if x)
    return {"titolo": titolo, "autori": autori, "editore": (dc.get("publisher") or "").strip() or None,
            "anno": int(anno.group(0)) if anno else None, "edizione": (dc.get("rlterms_edition") or "").strip() or None,
            "isbn": isbn, "lingua": None, "tipo": tipo, "note": None, "citazione": cit}


def libri(pubblico: str) -> list[dict]:
    """Libri delle liste Leganto raggiungibili dal link pubblico (`…/lists?courseCode=…`)."""
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(pubblico).query))
    s, base = _sessione(pubblico)
    ids = []
    lista = re.search(r"/lists/(\d+)", pubblico)
    if lista:
        ids.append(lista.group(1))
    elif q.get("courseCode"):
        d = _get(s, f"{base}/rl/search/find/lists", params={"course_code": q["courseCode"], "scope": "all_lists",
                                                             "maxResults": 20, "startPos": 0})
        ids = [x["id"] for x in ((d or {}).get("object") or {}).get("lists") or []
               if x.get("rlStatus") in (None, "PUBLISHED")]
    out, viste = [], set()
    for i in ids:
        d = _get(s, f"{base}/rl/main/lists/{i}")
        for sez in ((d or {}).get("object") or {}).get("sections") or []:
            for c in sez.get("citations") or []:
                if c.get("type") not in ("BK", "BC") or c.get("secondaryType") not in (None, "BK", "BC", "E_BK"):
                    continue
                lb = _libro(c.get("dc") or {}, sez.get("name") or "")
                if lb:
                    k = lb["isbn"] or re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        out.append(lb)
    return out
