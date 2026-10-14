"""Versione italiana, inglese e originale dei libri obbligatori (Open Library).

    python tools/db_builder/versioni_libri.py [--max N]

Legge docs/libri/versioni_libri.csv (generato da libri_obbligatori.py) e per
ogni libro cerca su Open Library l'opera e le sue edizioni:
- libri con ISBN: edizione per ISBN → opera → edizioni dell'opera;
- libri senza ISBN ma con titolo e autori separati: ricerca per titolo e
  autore, accettata solo se il titolo coincide (somiglianza ≥ 0,9) e almeno un
  cognome dell'autore corrisponde;
- libri con la sola citazione: non cercati (non si sa con certezza quale sia
  il titolo).

Per ogni opera trovata: lingua originale (dal campo «translated_from» delle
edizioni, altrimenti la lingua dell'edizione più vecchia), l'edizione italiana
e quella inglese più recenti, e l'edizione più vecchia nella lingua originale
presente su Open Library (non sempre la prima edizione in assoluto). Il
risultato va in docs/libri/versioni_libri.json; poi si rigenerano le tabelle
con libri_obbligatori.py. Le risposte sono in cache (database/contrib/auto/
openlibrary, non nel repository): il comando riprende da dove si era fermato.
Una richiesta al secondo, con User-Agent identificativo, come chiede Open
Library.
"""
from __future__ import annotations

import csv
import difflib
import hashlib
import json
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSV_IN = ROOT / "docs" / "libri" / "versioni_libri.csv"
OUT = ROOT / "docs" / "libri" / "versioni_libri.json"
CACHE = ROOT / "database" / "contrib" / "auto" / "openlibrary"
UA = "UniversityNotes-DB/1.0 (+https://github.com/Simo-Magnus/UniNotes)"
BASE = "https://openlibrary.org"

_last = 0.0


def get(path: str) -> dict | None:
    """GET JSON con cache su disco; None se non trovato."""
    global _last
    CACHE.mkdir(parents=True, exist_ok=True)
    f = CACHE / (hashlib.sha1(path.encode()).hexdigest() + ".json")
    if f.exists():
        d = json.loads(f.read_text(encoding="utf-8"))
        return d.get("v")
    for tentativo in range(4):
        wait = 1.0 - (time.time() - _last)
        if wait > 0:
            time.sleep(wait)
        _last = time.time()
        req = urllib.request.Request(BASE + path, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                v = json.loads(r.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                v = None
                break
            if e.code in (429, 500, 502, 503, 504):
                time.sleep(10 * (tentativo + 1))
                continue
            raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            time.sleep(10 * (tentativo + 1))
    else:
        return None  # non salvato in cache: si riprova al prossimo giro
    f.write_text(json.dumps({"v": v}, ensure_ascii=False), encoding="utf-8")
    return v


def norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def anno(e: dict) -> int | None:
    m = re.search(r"(1[5-9]\d\d|20\d\d)", e.get("publish_date") or "")
    return int(m.group(1)) if m else None


def lingua(e: dict) -> str | None:
    for x in e.get("languages") or []:
        k = (x.get("key") or "").rsplit("/", 1)[-1]
        if k:
            return k
    return None


def descr(e: dict) -> dict:
    isbn = (e.get("isbn_13") or e.get("isbn_10") or [None])[0]
    return {
        "titolo": e.get("title"),
        "editore": ", ".join(e.get("publishers") or []) or None,
        "anno": anno(e),
        "edizione": e.get("edition_name"),
        "isbn": isbn,
        "lingua": lingua(e),
        "openlibrary": BASE + e["key"] if e.get("key") else None,
    }


def edizioni(work: str) -> list[dict]:
    out, off = [], 0
    while True:
        d = get(f"{work}/editions.json?limit=200&offset={off}")
        if not d:
            break
        entries = d.get("entries") or []
        out += entries
        if len(entries) < 200 or len(out) >= 1000:
            break
        off += 200
    return out


def da_opera(work: str, eds: list[dict]) -> dict:
    con_lingua = [e for e in eds if lingua(e)]
    tradotto = Counter(
        (x.get("key") or "").rsplit("/", 1)[-1]
        for e in eds
        for x in e.get("translated_from") or []
    )
    if tradotto:
        orig_lang = tradotto.most_common(1)[0][0]
    else:
        datate = sorted((e for e in con_lingua if anno(e)), key=anno)
        orig_lang = lingua(datate[0]) if datate else None

    def ultima(lang):
        c = [e for e in con_lingua if lingua(e) == lang]
        c.sort(key=lambda e: anno(e) or 0)
        return descr(c[-1]) if c else None

    originale = None
    if orig_lang:
        c = sorted(
            (e for e in con_lingua if lingua(e) == orig_lang and anno(e)),
            key=anno,
        )
        originale = descr(c[0]) if c else None
    return {
        "opera": BASE + work,
        "lingua_originale": orig_lang,
        "italiana": ultima("ita"),
        "inglese": ultima("eng"),
        "originale": originale,
        "edizioni_open_library": len(eds),
    }


def cognomi(autori: str) -> set[str]:
    parti = re.split(r"[,;&]| e | and ", autori or "")
    out = set()
    for p in parti:
        w = [x for x in norm(p).split() if len(x) >= 3]
        if w:
            out.add(max(w, key=len))
    return out


def per_isbn(isbn: str) -> dict | None:
    e = get(f"/isbn/{isbn}.json")
    if not e:
        return None
    works = e.get("works") or []
    if not works:
        return None
    r = da_opera(works[0]["key"], edizioni(works[0]["key"]))
    r["metodo"] = "ISBN"
    return r


def per_titolo(titolo: str, autori: str) -> dict | None:
    q = urllib.parse.urlencode({
        "title": titolo[:200],
        "author": autori[:120],
        "fields": "key,title,author_name",
        "limit": "5",
    })
    d = get(f"/search.json?{q}")
    if not d:
        return None
    cog = cognomi(autori)
    for doc in d.get("docs") or []:
        sim = difflib.SequenceMatcher(None, norm(doc.get("title")), norm(titolo)).ratio()
        nomi = norm(" ".join(doc.get("author_name") or []))
        if sim >= 0.9 and cog and any(c in nomi for c in cog):
            r = da_opera(doc["key"], edizioni(doc["key"]))
            r["metodo"] = "titolo e autore"
            return r
    return None


def salva(out: dict) -> None:
    """Scrittura sicura (file temporaneo + sostituzione), con tentativi se il
    file è bloccato da un altro programma (antivirus, indicizzazione)."""
    tmp = OUT.with_suffix(".tmp")
    for t in range(10):
        try:
            tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
            tmp.replace(OUT)
            return
        except OSError:
            time.sleep(2 * (t + 1))
    print("impossibile salvare", OUT, flush=True)


def main() -> int:
    massimo = None
    if "--max" in sys.argv:
        massimo = int(sys.argv[sys.argv.index("--max") + 1])
    rows = list(csv.reader(CSV_IN.read_text(encoding="utf-8-sig").splitlines(), delimiter=";"))[1:]
    # ISBN prima (più affidabili), poi titolo e autore
    rows.sort(key=lambda r: (0 if r[0].startswith("isbn:") else 1, r[0]))
    out = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else {}
    oggi = date.today().isoformat()
    fatti = 0
    for n, r in enumerate(rows, 1):
        key, titolo, autori = r[0], r[1], r[2]
        if key in out:
            continue
        if massimo is not None and fatti >= massimo:
            break
        try:
            if key.startswith("isbn:"):
                res = per_isbn(key[5:])
            elif key.startswith("ta:") and autori and titolo and len(titolo) < 200:
                res = per_titolo(titolo, autori)
            else:
                res = {"stato": "non cercato (titolo non separato dalla citazione)"}
        except Exception as e:  # rete: si riprova al prossimo giro
            print("errore", key, e, flush=True)
            continue
        if res is None:
            res = {"stato": "non trovato su Open Library"}
        elif "stato" not in res:
            ha = res.get("italiana") or res.get("inglese") or res.get("originale")
            res["stato"] = (
                f"verificato su Open Library ({res['metodo']})" if ha
                else "opera trovata, edizioni senza lingua"
            )
            res["fonte"] = res.get("opera")
        res["verificato_il"] = oggi
        out[key] = res
        fatti += 1
        if fatti % 25 == 0:
            salva(out)
            stati = Counter(v.get("stato", "")[:40] for v in out.values())
            print(f"{n}/{len(rows)}", dict(stati), flush=True)
    salva(out)
    print("FINE", len(out), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
