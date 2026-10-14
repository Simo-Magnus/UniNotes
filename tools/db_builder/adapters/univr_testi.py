"""Libri di UniVR dalle liste Leganto pubbliche, anche quando la lista del 2026/27 non c'è ancora.

Le pagine degli insegnamenti su www.corsi.univr.it rimandano alla bibliografia su Leganto
(`https://univr.alma.exlibrisgroup.com/leganto/public/39UVR_INST/lists?courseCode=<codice>`), ma per
la maggior parte degli insegnamenti la lista del 2026/27 non è ancora pubblicata. Leganto ha però
le liste degli anni precedenti, con nome «<Insegnamento> (AAAA/AAAA) <SEDE> [<modulo>]», e una ricerca
pubblica per parole (`/leganto/rl/search/find/lists?q=…`, sessione anonima) che restituisce al
massimo 100 liste. Per ogni insegnamento si cerca quindi «<nome> <a.a.>» a partire dal 2026/27 e
si risale di anno in anno: si usa la lista del primo anno che ha libri e il libro riporta nella
nota l'a.a. della lista, se non è il corrente.

Per non attribuire a un insegnamento i libri di un altro con lo stesso nome (es. «Algoritmi per
bioinformatica» di un'altra laurea) si accettano solo le liste il cui titolo, tolti a.a. e sede,
è uguale al nome dell'insegnamento (con eventuale «Teoria», «Laboratorio», «Modulo …»).
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import threading
import time
import unicodedata
import urllib.parse

import requests

from . import leganto

BASE = "https://univr.alma.exlibrisgroup.com/leganto"
PUBBLICO = "https://univr.alma.exlibrisgroup.com/leganto/public/39UVR_INST/lists"
ANNI = ["2026/2027", "2025/2026", "2024/2025", "2023/2024"]
SEDI = ("VERONA", "VICENZA", "TRENTO", "BOLZANO", "ROVERETO", "LEGNAGO", "BRESSANONE", "PORDENONE", "MANTOVA")
_lock = threading.Lock()
_ultimo = {"t": 0.0}
_sess: dict[str, requests.Session] = {}


def _cache_dir() -> pathlib.Path | None:
    c = os.environ.get("UN_HTTP_CACHE")
    return pathlib.Path(c) / "univr_leganto" if c else None


def _sessione_codice(codice: str) -> requests.Session:
    """La sessione anonima di Leganto vale solo per il corso della pagina pubblica con cui è aperta:
    una sessione per codice."""
    s = requests.Session()
    s.headers.update(leganto.HEADERS)
    with _lock:
        attesa = _ultimo["t"] + 0.5 - time.monotonic()
        if attesa > 0:
            time.sleep(attesa)
        _ultimo["t"] = time.monotonic()
    try:
        s.get(f"{PUBBLICO}?courseCode={urllib.parse.quote(codice)}", timeout=60, headers={"Accept": "text/html"})
    except requests.RequestException:
        pass
    return s


def _get(url: str, params: dict, sess: requests.Session | None = None, extra: str = "") -> dict | None:
    """GET JSON con cache su disco e al massimo 2 richieste al secondo."""
    chiave = hashlib.sha1((url + json.dumps(sorted(params.items())) + extra).encode()).hexdigest()
    cd = _cache_dir()
    f = cd / chiave[:2] / f"{chiave}.json" if cd else None
    if f and f.exists():
        return json.loads(f.read_text(encoding="utf-8"))
    with _lock:
        s = sess or _sess.get("s")
        if s is None:
            s = requests.Session()
            s.headers.update(leganto.HEADERS)
            try:
                s.get(PUBBLICO + "?courseCode=1", timeout=60, headers={"Accept": "text/html"})
            except requests.RequestException:
                pass
            _sess["s"] = s
    d = None
    for tentativo in range(3):
        with _lock:
            attesa = _ultimo["t"] + 0.5 - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            _ultimo["t"] = time.monotonic()
        try:
            r = s.get(url, params=params, timeout=60)
            if r.status_code in (401, 403, 404):
                d = {}
                break
            d = r.json()
            break
        except (requests.RequestException, ValueError):
            time.sleep(2 ** tentativo)
    if d is None:
        return None
    if f:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(d), encoding="utf-8")
    return d


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def nome_base(nome: str) -> str:
    """'Programmazione I [Matricole dispari]' -> 'Programmazione I'."""
    return re.sub(r"\s*\[[^\]]*\]\s*", " ", nome or "").strip()


def _parti(nome_lista: str) -> tuple[str, str, str, str]:
    """'Algoritmi (2025/2026) VERONA ALGORITMI PER BIOINFORMATICA' -> (nome, aa, sede, resto)."""
    m = re.search(r"\((\d{4}/\d{4})\)", nome_lista or "")
    if not m:
        return norm(nome_lista), "", "", ""
    prima = re.sub(r"\s*-\s*$", "", nome_lista[:m.start()]).strip()
    dopo = nome_lista[m.end():].strip()
    sede = ""
    for s in SEDI:
        if dopo.upper().startswith(s):
            sede, dopo = s, dopo[len(s):].strip()
            break
    return norm(prima), m.group(1), sede, norm(dopo)


_GENERICO = re.compile(r"^(teoria|laboratorio|lezione|lezioni|esercitazioni|modulo [a-z0-9]+( [a-z0-9]+)?|"
                       r"modulo [a-z0-9]+ (teoria|laboratorio)|mod [a-z0-9]+|unico|unita didattica [a-z0-9]+|"
                       r"parte [a-z0-9]+|teoria laboratorio|corso integrato)?$")


def cerca(nome: str, aa: str) -> list[dict]:
    """Liste Leganto dell'a.a. `aa` con lo stesso nome dell'insegnamento (sede e modulo a parte)."""
    base = norm(nome_base(nome))
    if not base:
        return []
    parole = [w for w in re.findall(r"[A-Za-z0-9]+", unicodedata.normalize("NFKD", nome_base(nome))
                                    .encode("ascii", "ignore").decode()) if len(w) > 2 or w.isdigit()]
    q = " ".join(parole[:6] + [aa])
    d = _get(f"{BASE}/rl/search/find/lists", {"q": q, "scope": "all_lists"})
    out = []
    for l in ((d or {}).get("object") or {}).get("lists") or []:
        if l.get("rlStatus") not in (None, "PUBLISHED"):
            continue
        n, a, sede, resto = _parti(l.get("name") or "")
        if a != aa or n != base:
            continue
        if resto and not _GENERICO.match(resto):
            continue
        out.append({"id": l["id"], "nome": l["name"], "sede": sede, "resto": resto, "aa": a,
                    "ccode": str(((l.get("courses") or [{}])[0]).get("code") or "")})
    return out


def libri_lista(lista_id: str, sess: requests.Session | None = None, extra: str = "") -> list[dict]:
    d = _get(f"{BASE}/rl/main/lists/{lista_id}", {}, sess, extra)
    out, viste = [], set()
    for sez in ((d or {}).get("object") or {}).get("sections") or []:
        for c in sez.get("citations") or []:
            if c.get("type") not in ("BK", "BC") or c.get("secondaryType") not in (None, "BK", "BC", "E_BK"):
                continue
            lb = leganto._libro(c.get("dc") or {}, sez.get("name") or "")
            if lb:
                k = lb["isbn"] or re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    out.append(lb)
    return out


def libri_codice(codice_leganto: str) -> tuple[list[dict], list[str]]:
    """Libri e id delle liste pubblicate per il codice del corso Leganto (link della pagina
    dell'insegnamento), con una sessione anonima aperta per quel codice."""
    cd = _cache_dir()
    f = cd / "codici" / (hashlib.sha1(codice_leganto.encode()).hexdigest() + ".json") if cd else None
    if f and f.exists():
        return tuple(json.loads(f.read_text(encoding="utf-8")))  # type: ignore[return-value]
    sess = _sessione_codice(codice_leganto)
    d = _get(f"{BASE}/rl/search/find/lists", {"course_code": codice_leganto, "scope": "all_lists",
                                              "maxResults": 20, "startPos": 0}, sess, "cod" + codice_leganto)
    if d is None:
        return [], []
    ids = [x["id"] for x in ((d or {}).get("object") or {}).get("lists") or []
           if x.get("rlStatus") in (None, "PUBLISHED")]
    libri: list[dict] = []
    for i in ids:
        libri += [x for x in libri_lista(i, sess, "cod" + codice_leganto)
                  if x["citazione"] not in {y["citazione"] for y in libri}]
    if f:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps([libri, ids]), encoding="utf-8")
    return libri, ids


def codice_dal_link(testo: str) -> str | None:
    for u in leganto.link(testo or ""):
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(u).query))
        if q.get("courseCode"):
            return q["courseCode"]
    return None


def libri_insegnamento(nome: str, sede: str | None, testo_pagina: str, aa_corrente: str = "2026/2027") -> tuple[list[dict], str | None, str | None]:
    """(libri, a.a. della lista usata, id della lista). Prima la lista del corso indicata dalla pagina
    dell'insegnamento, poi quelle con lo stesso nome dal 2026/27 in giù."""
    cod = codice_dal_link(testo_pagina)
    if cod:
        libri: list[dict] = []
        usati = []
        for i in per_corso_codice(cod):
            libri += [x for x in libri_lista(i) if x["citazione"] not in {y["citazione"] for y in libri}]
            usati.append(i)
        if libri:
            return libri, aa_corrente, ",".join(usati)
    for aa in ANNI:
        liste = cerca(nome, aa)
        if not liste:
            continue
        pref = [x for x in liste if x["sede"] == (sede or "VERONA")] or [x for x in liste if x["sede"] == "VERONA"] or liste
        libri = []
        for l in pref:
            libri += [x for x in libri_lista(l["id"]) if x["citazione"] not in {y["citazione"] for y in libri}]
        if libri:
            return libri, aa, ",".join(l["id"] for l in pref)
    return [], None, None


_PROSA = re.compile(r"(?i)\b(saranno|sar[aà’] |disponibil|e-?mail|tel\.|copisteria|moodle|piattaforma|materiale didattico|"
                    r"slide|dispense|sito|docente|studenti)\b")


def libri_testo(pagina: str) -> list[dict]:
    """Libri scritti come testo nella sezione «Bibliografia» (o sotto l'intestazione «Bibliografia»
    del programma) della pagina dell'insegnamento; scarta prosa e rimandi al materiale."""
    from .testi import estrai_libri
    segs = []
    for m in re.finditer(r"Bibliografia", pagina or ""):
        seg = pagina[m.end():]
        j = re.search(r'<h2 class="sezioneTitolo-ins"', seg)
        segs.append(seg[:j.start()] if j else seg[:3000])
    return [b for b in estrai_libri(*segs) if not _PROSA.search(b["citazione"])]
