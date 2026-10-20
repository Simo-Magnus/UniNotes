"""UNINT (Università degli Studi Internazionali di Roma): piani di studio dalle pagine dei corsi, insegnamenti dal Course Catalogue.

Il Course Catalogue (`https://unint.coursecatalogue.cineca.it`) pubblica l'offerta didattica come un elenco di attività
«altreAttivita» senza anno di corso né gruppi (`/api/v1/corso/<coorte>/<cod>` ha un solo anno non numerico): senza il piano
ogni anno dei corsi risultava vuoto. L'adattatore comune (`cineca_catalogue`) quindi non basta; qui:

- il piano (anni, CFU, insegnamenti obbligatori e a scelta, indirizzi) è letto dalla pagina «Piano di studi» del sito
  ufficiale di ogni corso (`CORSI`, https://www.unint.eu/didattica/...), il piano dell'a.a. 2026/27, il più recente
  pubblicato per tutti gli anni di corso (le pagine dei regolamenti per coorte sono PDF di tabelle: per i corsi che non hanno
  ancora la pagina, L-18, il piano è quello dell'Allegato I del regolamento 2025/26, `PIANO_L18`). Sono scartate le
  varianti nascoste nella pagina (breakpoint e lingua del sito: la pagina in inglese ha un secondo piano, tenuto come
  curriculum «(EN)»);
- ogni riga del piano è abbinata alle attività del Catalogo per nome (codice, SSD, docenti, periodo, libri): una riga con
  «oppure» o «N insegnamenti a scelta tra …» diventa le sue alternative a scelta (`obbligatorio: false`), una riga con
  la lingua come segnaposto («… (prima lingua)») le attività di quel tipo per ogni lingua, a scelta; le righe senza attività
  nel Catalogo (prova finale, crediti liberi, altre attività) restano righe del piano, senza codice;
- attività del Catalogo che non stanno in nessun piano (vecchi ordinamenti, pre-corsi, OFA e test a 0 CFU) non sono
  insegnamenti del piano e non si emettono;
- un corso per ogni corso di Universitaly (id espliciti); la L-18 del Catalogo «Economia internazionale e management digitale»
  (05FDE) ha l'ordinamento cessato nel 2023: il corso attivo è «Green management e sostenibilità» (06FDE/07FDE, ordinamento 2024/25);
- libri, modalità d'esame, SSD già raccolti per lo stesso codice (database e contributi) non si rileggono.

Con la variabile d'ambiente UNINT_HTTP_CACHE (una cartella) le risposte restano su disco. Richieste: 4 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unint.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unint.py [--senza-syllabus]
"""
from __future__ import annotations

import difflib
import hashlib
import json
import os
import pathlib
import re
import sys
import threading
import time
import unicodedata

import requests
from bs4 import BeautifulSoup, Tag

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402

BASE = "https://unint.coursecatalogue.cineca.it"
SITO = "https://www.unint.eu/"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 4.0
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
COORTI = (2026, 2025, 2024, 2023)

D = "didattica/"
# Un corso per ogni corso di Universitaly (id) più la L-18 del Catalogo. `cds`: codici del Catalogo dal più recente; `pagine`:
# (percorso della pagina sul sito, nome del curriculum se la pagina ha un solo piano senza titolo).
CORSI = [
    {"id": "unint-l-12-lingue-per-l-interpretariato-e-la-traduzione", "ul": "1628189", "cds": ("05FIT", "04FIT"),
     "pagine": [(D + "corso-di-laurea-triennale-in-lingue-per-linterpretariato-e-la-traduzione/", None)]},
    {"id": "unint-l-18-green-management-e-sostenibilita", "ul": None, "cds": ("07FDE", "06FDE"), "pagine": [],
     "nome": "Green Management e Sostenibilità", "classe": "L-18", "tipo": "L", "durata": 3,
     "url": SITO + "info-per/l-18-green-management-e-sostenibilita/"},
    {"id": "unint-l-36-scienze-politiche-sicurezza-internazionale-e-criminalita", "ul": "1633140", "cds": ("08FSP", "07FSP", "06FSP", "05FSP"),
     "pagine": [(D + "corso-di-laurea-triennale-in-scienze-politiche-sicurezza-internazionale-e-criminalita-indirizzo-cybersecurity/", "Cybersecurity")]},
    {"id": "unint-lm-77-economia-e-management-internazionale", "ul": "1633144", "cds": ("14FDE", "13FDE"),
     "pagine": [(D + "corso-di-laurea-magistrale-in-economia-e-management-internazionale-indirizzo-international-relations-global-management-and-economic-diplomacy/", "International Relations Global Management and Economic Diplomacy"),
                (D + "corso-di-laurea-magistrale-in-economia-e-management-internazionale-indirizzo-marketing-ed-export-digitale/", "Marketing ed export digitale"),
                (D + "corso-di-laurea-magistrale-in-economia-e-management-internazionale-indirizzo-hr-management/", "HR management"),
                (D + "corso-di-laurea-magistrale-in-economia-e-management-internazionale-indirizzo-lusso-made-in-italy-e-sostenibilita/", "Lusso made in Italy e sostenibilità")]},
    {"id": "unint-lm-32-ingegneria-informatica-per-tecnologie-immersive-e-intelligen", "ul": "1625641", "cds": ("18FSP",),
     "pagine": [("info-per/corso-di-laurea-magistrale-in-ingegneria-informatica-per-tecnologie-immersive-e-intelligenza-artificiale-lm-32/", None)]},
    {"id": "unint-lm-94-interpretariato-e-traduzione", "ul": "1633145", "cds": ("19FIT", "13FIT"),
     "pagine": [(D + "corso-di-laurea-magistrale-in-interpretariato-e-traduzione-indirizzo-traduzione/", "Traduzione"),
                (D + "corso-di-laurea-magistrale-in-interpretariato-e-traduzione-indirizzo-interpretazione/", "Interpretazione"),
                (D + "corso-di-laurea-magistrale-in-interpretariato-e-traduzione-indirizzo-misto/", "Misto"),
                (D + "corso-di-laurea-magistrale-in-interpretariato-e-traduzione-indirizzo-tecnologie-avanzate-per-linterpretazione-e-la-traduzione/",
                 "Tecnologie avanzate per l'interpretazione e la traduzione")]},
    {"id": "unint-lm-52-investigazione-criminalita-e-sicurezza-internazionale", "ul": "1633143", "cds": ("16FSP", "14FSP"),
     "pagine": [(D + "corso-di-laurea-magistrale-in-investigazione-criminalita-e-sicurezza-internazionale-indirizzo-generale/", "Generale"),
                (D + "corso-di-laurea-magistrale-in-investigazione-criminalita-e-sicurezza-internazionale-indirizzo-criminologia/", "Criminologia"),
                (D + "corso-di-laurea-magistrale-in-investigazione-criminalita-e-sicurezza-internazionale-indirizzo-international-security-geopolitics-and-global-affairs/",
                 "International Security Geopolitics and Global Affairs"),
                (D + "corso-di-laurea-magistrale-in-investigazione-criminalita-e-sicurezza-internazionale-indirizzo-cybersecurity/", "Cybersecurity")]},
    {"id": "unint-lm-37-lingue-per-la-didattica-innovativa-e-linterculturalita", "ul": "1633141", "cds": ("18FIT", "17FIT"),
     "pagine": [(D + "corso-di-laurea-magistrale-in-lingue-per-la-didattica-innovativa-e-linterculturalita-indirizzo-didattica/", None),
                (D + "corso-di-laurea-magistrale-in-lingue-per-la-didattica-innovativa-e-linterculturalita-indirizzo-turismo/", "Turismo"),
                (D + "corso-di-laurea-magistrale-in-lingue-per-la-didattica-innovativa-e-linterculturalita-indirizzo-editoria-e-giornalismo-digitale/",
                 "Editoria e giornalismo digitale")]},
    {"id": "unint-lm-51-psicologia-dei-processi-di-apprendimento-e-di-inclusione", "ul": "1633142", "cds": ("15FSP",),
     "pagine": [(D + "corso-di-laurea-magistrale-in-psicologia-dei-processi-di-apprendimento-e-di-inclusione-indirizzo-clinica-e-abilitazione-evolutiva/", "Clinica e abilitazione evolutiva"),
                (D + "corso-di-laurea-magistrale-in-psicologia-dei-processi-di-apprendimento-e-di-inclusione-indirizzo-scuola-e-contesti-educativi/", "Scuola e contesti educativi"),
                (D + "corso-di-laurea-magistrale-in-psicologia-dei-processi-di-apprendimento-e-di-inclusione-indirizzo-devianza-minorile/", "Devianza minorile")]},
]

# Allegato I del regolamento didattico L-18 «Green management e sostenibilità» a.a. 2025/26 (www.unint.eu/info-per/l-18-green-management-e-sostenibilita/):
# (anno, titolo, CFU, tipo) con tipo «o» obbligatorio, «s» a scelta (l'insegnamento a scelta tra più alternative è uno solo, «g:<n>» n alternative
# di un gruppo), «l» crediti liberi. Totali dell'Allegato: I anno 58, II anno 58, III anno 42 + 12 liberi + 6 tirocinio + 4 prova finale = 180.
PIANO_L18_URL = "https://unint-site.s3.eu-south-1.amazonaws.com/documents/2025/info%20per/regolamento-didattico-2025-2026-l-18.pdf"
PIANO_L18 = [
    (1, "Economia aziendale e ESG", 12, "o"),
    (1, "Economia politica e modelli di sviluppo sostenibile", 12, "o"),
    (1, "Matematica per l'economia e la finanza", 12, "o"),
    (1, "Diritto privato, impresa e mercato sostenibile", 8, "o"),
    (1, "Green management", 8, "o"),
    (1, "Laboratorio digitale e di intelligenza artificiale", 4, "o"),
    (1, "Soft skills (1 a scelta tra Leadership, Team building, Public speaking, Comunicazione istituzionale)", 2, "g:1"),
    (2, "Bilancio internazionale e rendicontazione di sostenibilità", 12, "o"),
    (2, "English for business and sustainability oppure Lingua francese I (corso base) oppure Lingua francese I (corso intermedio) "
        "oppure Lingua spagnola I (corso base) oppure Lingua spagnola I (corso intermedio) oppure Lingua tedesca I (corso base) "
        "oppure Lingua tedesca I (corso intermedio)", 12, "g:1"),
    (2, "Politica economica, ambiente e sostenibilità", 8, "o"),
    (2, "Diritto dell'UE e fondi europei", 12, "o"),
    (2, "Statistica e indicatori socio-ambientali", 8, "o"),
    (2, "Marketing digitale", 6, "o"),
    (3, "Diritto dell'ambiente e dell'energia", 8, "o"),
    (3, "Finanza etica e sostenibile", 8, "o"),
    (3, "Laboratorio di transizione energetica, cambiamenti climatici e innovazione tecnologica", 6, "o"),
    (3, "Gestione delle risorse umane, inclusione e diversity management", 8, "o"),
    (3, "Social media management oppure Mobilità green, logistica e supply chain oppure Sustainable hospitality and tourism management "
        "oppure Start up, imprenditorialità e modelli di business sostenibili oppure Management delle organizzazioni non profit "
        "oppure Eco-Fashion management", 6, "g:2"),
    (3, "Insegnamenti a libera scelta dello studente", 12, "l"),
    (3, "Tirocinio oppure Laboratorio di realtà virtuale e aumentata", 6, "g:1"),
    (3, "Prova finale", 4, "o"),
]

# Alias: titolo del piano (normalizzato, senza parentesi) → prefisso del nome delle attività del Catalogo
ALIAS = {
    "interpretazione dall italiano alla lingua straniera": "interpretazione it",
    "traduzione dall italiano alla lingua straniera": "traduzione it",
    "espressione scritta e orale in arabo o in cinese": "espressione scritta e orale in",
    "lingue per il business": "lingua per il business",
    "lingua per il business": "lingua per il business",
    "laboratorio di traduzione dall italiano alla lingua straniera": "laboratorio di traduzione it",
}
STOP_H = re.compile(r"(?i)guida alla compilazione|comitato di indirizzo|percorso di eccellenza|esperienze di studio|requisiti, modalit")
NUM = re.compile(r"^\d+(?:[.,]\d+)?(?:\s*(?:\+|\s)\s*\d+(?:[.,]\d+)?)*$")
ROMANI = {"i": 1, "ii": 2, "iii": 3}
LINGUE = {"inglese", "francese", "spagnola", "spagnolo", "tedesca", "tedesco", "araba", "arabo", "cinese", "russa", "russo",
          "portoghese", "giapponese"}


def _norm(s: str | None) -> str:
    s = re.sub("[’‘`´ʼ]", "'", s or "")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _n1(s: str | None) -> str:
    """Nome senza «corso» né segni: «Lingua francese I (corso base)» e «Lingua Francese I - Base» coincidono."""
    return re.sub(r"\bcorso\b", " ", _norm(s)).replace("  ", " ").strip()


def _senza_par(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"\([^)]*\)", " ", s or "")).strip()


_cache_lock = threading.Lock()
_last = [0.0]


def _get_text(url: str, params: dict | None = None) -> str | None:
    cache = os.environ.get("UNINT_HTTP_CACHE")
    f = None
    if cache:
        f = pathlib.Path(cache) / (hashlib.sha1((url + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest() + ".html")
        if f.exists():
            return f.read_text(encoding="utf-8")
    for tentativo in range(4):
        with _cache_lock:
            attesa = _last[0] + 1.0 / RATE - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            _last[0] = time.monotonic()
        try:
            r = requests.get(url, params=params, headers=HEADERS, timeout=90)
            if r.status_code == 404:
                return None
            r.raise_for_status()
            if f is not None:
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(r.text, encoding="utf-8")
            return r.text
        except requests.RequestException:
            time.sleep(2 ** tentativo)
    return None


# ----------------------------------------------------------------------------------------------- pagine del sito
def _eventi(html: str) -> list[tuple]:
    """Titoli, paragrafi e fisarmoniche della pagina nell'ordine del documento, con i breakpoint e la lingua in cui sono nascosti."""
    soup = BeautifulSoup(html, "html.parser")
    for s in soup(["script", "style"]):
        s.decompose()
    out: list[tuple] = []

    def walk(n, flags: frozenset) -> None:
        for c in n.children:
            if not isinstance(c, Tag):
                continue
            cl = c.get("class") or []
            f = set(flags)
            if "elementor-hidden-desktop" in cl:
                f.add("hd")
            if "nascondi_da_pagina_in_italiano" in cl:
                f.add("en")
            if "nascondi_da_pagina_in_inglese" in cl:
                f.add("it")
            if c.name == "details":
                t = c.find("div", class_="e-n-accordion-item-title-text")
                reg = c.find("div", attrs={"role": "region"})
                out.append(("ACC", t.get_text(" ", strip=True) if t else "", reg.get_text(" ", strip=True) if reg else "", frozenset(f)))
            elif c.name in ("h1", "h2", "h3", "h4", "h5", "h6"):
                out.append(("H", c.get_text(" ", strip=True), "", frozenset(f)))
            elif c.name in ("p", "li"):
                out.append(("P", c.get_text(" ", strip=True), "", frozenset(f)))
            else:
                walk(c, frozenset(f))

    walk(soup.body or soup, frozenset())
    return out


def _cfu(s: str) -> tuple[float, int] | None:
    """«8» → (8, 1); «6+6» o «6 6» → (6, 2)."""
    if not NUM.match(s.strip()):
        return None
    v = [float(x.replace(",", ".")) for x in re.findall(r"\d+(?:[.,]\d+)?", s)]
    return (int(v[0]) if v[0] == int(v[0]) else v[0]), len(v)


def _pulisci_titolo(t: str) -> str:
    t = re.split(r"\s*(?:•|:\s*•)", t)[0]
    t = re.sub(r"\s*\*+\s*$", "", t)
    t = re.sub(r"^\s*Per i percorsi in [^:]*:\s*", "", t, flags=re.I)
    t = re.sub(r"\s+(?:Per i percorsi in .*|In alternativa a un esame .*)$", "", t, flags=re.I)
    t = re.sub(r"\s*\(in aggiunta altro esame da \d+ CFU\)", "", t, flags=re.I)
    t = re.sub(r"^\s*Oppure\s+", "", t, flags=re.I)
    t = t.replace("specialitisca", "specialistica")
    return re.sub(r"\s+", " ", t).strip()


def _dividi_oppure(t: str) -> list[str]:
    """Divide «A oppure B» fuori dalle parentesi («Lingua e linguistica (prima oppure seconda lingua)» non si divide)."""
    out, prof, ini = [], 0, 0
    for m in re.finditer(r"[()]|\s+(?:oppure|or)\s+", t, flags=re.I):
        g = m.group(0)
        if g == "(":
            prof += 1
        elif g == ")":
            prof = max(0, prof - 1)
        elif prof == 0:
            out.append(t[ini:m.start()])
            ini = m.end()
    out.append(t[ini:])
    return [x.strip() for x in out if x.strip()]


def parse_pagina(html: str, nome_default: str | None) -> list[dict]:
    """I piani della pagina: [{curriculum, lingua, righe: [{anno, titolo, cfu, picks, gruppo, libera, stella, corpo}]}]."""
    ev = [e for e in _eventi(html) if "hd" not in e[3]]
    blocchi: list[dict] = []
    cur: dict | None = None
    anno = None
    gruppo = None  # {"n": picks} | {"tot": cfu}
    libera = False
    dentro = False
    labs: list[str] = []
    nome_blocco: str | None = nome_default
    in_labs = False

    def nuovo(nome, lingua):
        nonlocal cur, anno, gruppo, libera
        cur = {"curriculum": nome, "lingua": lingua, "righe": []}
        blocchi.append(cur)
        anno = None
        gruppo = None
        libera = False

    i = 0
    while i < len(ev):
        k, t, corpo, fl = ev[i]
        lingua = "en" if "en" in fl else "it"
        if k == "H" and re.match(r"(?i)piano di studi", t):
            dentro = True
            if re.fullmatch(r"(?i)piano di studi", t):
                i += 1
                continue
        if not dentro:
            i += 1
            continue
        if k == "H":
            if re.fullmatch(r"(?i)laboratori", t):
                in_labs = True
                cur = None
                i += 1
                continue
            if STOP_H.search(t) and blocchi:
                break
            if re.match(r"(?i)insegnamenti a libera scelta e percorsi", t):
                cur = None
                in_labs = False
                i += 1
                continue
            m = re.match(r"(?i)^(?:indirizzo|percorso)\s+(.+)$", t) or re.match(r"(?i)^piano di studi\s*[|:\-–]?\s*(.+)$", t)
            if m:
                nome_blocco = m.group(1).strip()
                nuovo(nome_blocco, lingua)
            elif in_labs:
                pass
            i += 1
            continue
        if in_labs:
            if k == "ACC":
                nxt = ev[i + 1] if i + 1 < len(ev) else None
                c = _cfu(nxt[1]) if nxt and nxt[0] == "P" else None
                if c:
                    labs.append(_pulisci_titolo(t))
                    i += 1
            i += 1
            continue
        m = re.fullmatch(r"(?i)(I{1,3})\s+anno", t)
        if k == "P" and m:
            nuovo_anno = ROMANI[m.group(1).lower()]
            if cur is None or (anno is not None and nuovo_anno <= anno) or (cur["lingua"] != lingua and cur["righe"]):
                # nuovo piano: stesso titolo di prima (o senza titolo), un'altra lingua del sito o l'anno ricomincia
                nuovo(nome_blocco if cur is None or cur["righe"] else cur["curriculum"], lingua)
                if cur is not None and len(blocchi) > 1 and blocchi[-2]["righe"] and blocchi[-2]["curriculum"] == cur["curriculum"] \
                        and blocchi[-2]["lingua"] == lingua and nome_blocco == blocchi[-2]["curriculum"] and False:
                    pass
            anno = nuovo_anno
            gruppo = None
            libera = False
            i += 1
            continue
        if cur is None:
            i += 1
            continue
        if k == "P":
            if t.startswith("*") or t.lower() in ("cfu", "altre attività", "altre attivita"):
                if t.lower().startswith("altre att"):
                    gruppo = None
                    libera = False
                m = re.match(r"(?i)^(\*+)\s*(?:(\d+)\s*CFU|(\d+|un|uno|due|tre)\s+insegnament)", t)
                if m:  # nota delle righe con l'asterisco: quanti CFU (o insegnamenti) si scelgono tra quelle righe
                    cur.setdefault("stelle", []).append({
                        "liv": len(m.group(1)), "cfu": int(m.group(2)) if m.group(2) else None,
                        "n": ({"un": 1, "uno": 1, "due": 2, "tre": 3}.get(m.group(3).lower()) or int(m.group(3))) if m.group(3) else None})
                i += 1
                continue
            m = re.fullmatch(r"(?i)(?:(I{1,3})\s+anno\s+)?(\d+|un|uno|due|tre|quattro)\s+insegnament[oi]\s+a\s+scelta(?:\s+tra)?:?", t)
            if m:
                if m.group(1):
                    anno = ROMANI[m.group(1).lower()]
                n = {"un": 1, "uno": 1, "due": 2, "tre": 3, "quattro": 4}.get(m.group(2).lower()) or int(m.group(2))
                gruppo = {"n": n}
                libera = False
                i += 1
                continue
            m = re.fullmatch(r"(?i)(?:sezione\s+)?(\d+)\s+CFU", t)
            if m and i + 1 < len(ev) and ev[i + 1][1].startswith("*"):
                i += 1  # intestazione della nota con l'asterisco, non un gruppo
                continue
            if m:
                gruppo = {"tot": int(m.group(1))}
                libera = False
                i += 1
                continue
            if re.search(r"(?i)\bCFU a libera scelta\b", t) or re.fullmatch(r"(?i)cfu a libera scelta", t):
                libera = True
                gruppo = None
                i += 1
                continue
            # riga senza fisarmonica: titolo seguito dal numero dei CFU
            nxt = ev[i + 1] if i + 1 < len(ev) else None
            c = _cfu(nxt[1]) if nxt and nxt[0] == "P" else None
            if c and anno and not NUM.match(t) and len(t) < 160:
                cur["righe"].append({"anno": anno, "titolo": _pulisci_titolo(t), "cfu": c[0], "picks": c[1], "gruppo": gruppo, "libera": libera or bool(re.search(r"(?i)libera scelta", t)),
                                     "stella": len(t) - len(t.rstrip("*")), "corpo": "", "lingua": lingua})
                libera = False
                i += 2
                continue
            i += 1
            continue
        if k == "ACC":
            nxt = ev[i + 1] if i + 1 < len(ev) else None
            c = _cfu(nxt[1]) if nxt and nxt[0] == "P" else None
            if c and anno:
                cur["righe"].append({"anno": anno, "titolo": _pulisci_titolo(t), "cfu": c[0], "picks": c[1], "gruppo": gruppo, "libera": libera,
                                     "stella": len(t) - len(t.rstrip("*")), "corpo": corpo, "lingua": lingua})
                libera = False
                i += 2
                continue
        i += 1
    for b in blocchi:
        b["labs"] = labs
    return [b for b in blocchi if b["righe"]]



# ----------------------------------------------------------------------------------------------- Catalogo
def _json(path: str, params: dict | None = None):
    t = _get_text(f"{BASE}/api/v1{path}", params)
    if not t:
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _attivita(d: dict):
    for p in d.get("percorsi") or []:
        for a in p.get("anni") or []:
            gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                for att in g.get("attivita") or []:
                    yield att


_ELENCO: dict[int, dict[str, dict]] = {}


def _elenco_corsi() -> dict[int, dict[str, dict]]:
    if not _ELENCO:
        for y in COORTI:
            lst = _json("/corsi", {"anno": y, "minimal": "true"}) or []
            cds: list[dict] = []
            cc._walk_cds(lst, cds)
            _ELENCO[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y)}
    return _ELENCO


def catalogo_corso(cds_codici: tuple[str, ...]) -> tuple[dict, dict | None]:
    """(attività per codice, dettaglio del corso della coorte più recente). Le attività sono quelle di tutte le coorti dei codici
    del corso, con il record dell'a.a. più recente."""
    elenco = _elenco_corsi()
    ads: dict[str, dict] = {}
    dett = None
    for cod in cds_codici:
        for y in COORTI:
            x = elenco[y].get(cod)
            if not x:
                continue
            d = _un(_json(f"/corso/{y}/{x['cod']}"))
            if not d:
                continue
            if dett is None:
                dett = {**d, "_coorte": y}
            for att in _attivita(d):
                ad = str(att.get("adCod") or att.get("cod"))
                aa = int(att.get("aa") or 0)
                cur = ads.get(ad)
                if cur and cur["aa"] >= aa:
                    continue
                docenti = sorted({cc._nome(z.get("des")) for z in att.get("docenti") or [] if z.get("des")})
                ads[ad] = {
                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "des": att.get("des_it") or ad,
                    "cfu": att.get("crediti"), "aa": aa, "cds": cod, "docenti": docenti,
                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                    "periodo_inizio": att.get("data_inizio_periodo_didattico"), "periodo_fine": att.get("data_fine_periodo_didattico"),
                    "url": f"{BASE}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                    "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                               "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y,
                               "schema_id": att.get("schemaId")},
                    "n": _norm(att.get("des_it")), "n0": _norm(_senza_par(att.get("des_it"))), "n1": _n1(att.get("des_it")),
                }
    return ads, dett


# ----------------------------------------------------------------------------------------------- abbinamento
_OPPURE = re.compile(r"\s+(?:oppure|or)\s+", re.I)
_SCELTA_TRA = re.compile(r"(?i)\ba scelta tra\b:?")


def _toks(s: str) -> list[str]:
    return s.split()


def _sottosequenza(base: list[str], toks: list[str]) -> bool:
    it = iter(toks)
    return all(any(b == t for t in it) for b in base)


class Pool:
    """Attività del Catalogo del corso (`fam`) e di tutti gli altri corsi dell'ateneo (stesse attività condivise tra i corsi)."""

    def __init__(self, famiglia: dict, altre: dict):
        self.ads = []
        for k, a in {**altre, **famiglia}.items():
            self.ads.append({**a, "fam": k in famiglia})
        self.per: dict[str, dict[str, list[dict]]] = {"n": {}, "n1": {}, "n0": {}}
        for a in self.ads:
            for key in ("n", "n1", "n0"):
                self.per[key].setdefault(a[key], []).append(a)

    @staticmethod
    def _migliore(lst: list[dict]) -> dict:
        return sorted(lst, key=lambda a: (not a["fam"], -a["aa"], a["codice"]))[0]

    def esatto(self, piece: str) -> list[dict]:
        pn, p1, p0 = _norm(piece), _n1(piece), _norm(_senza_par(piece))
        if pn == "master thesis":
            pn = "prova finale"
        if pn in ("tirocinio", "tirocini", "tirocinio formativo", "internship"):
            for n in ("tirocini", "tirocini e stage"):
                if n in self.per["n"]:
                    return [self._migliore(self.per["n"][n])]
        for key, v in (("n", pn), ("n1", p1)):
            if v in self.per[key]:
                return [self._migliore(self.per[key][v])]
        if p0 in self.per["n0"] and len({a["n"] for a in self.per["n0"][p0]}) == 1:
            return [self._migliore(self.per["n0"][p0])]
        if len(p1) >= 18:  # stesso titolo con parole diverse («delle attività professionali» / «dell'attività professionale»)
            migliore = None
            for a in self.ads:
                r = difflib.SequenceMatcher(None, p1, a["n1"]).ratio()
                if r >= 0.9 and (migliore is None or (r, a["fam"]) > (migliore[0], migliore[1]["fam"])):
                    migliore = (r, a)
            if migliore:
                return [migliore[1]]
        return []

    def contenuti(self, testo: str) -> list[dict]:
        """Attività i cui nomi compaiono nel testo (nomi più lunghi per primi, senza sovrapposizioni)."""
        tn = f" {_n1(testo)} "
        trovati: list[tuple[int, dict]] = []
        occupato = [False] * len(tn)
        visti_n0: set[str] = set()
        for a in sorted(self.ads, key=lambda a: (-len(a["n1"]), not a["fam"], -a["aa"])):
            for nome in dict.fromkeys((a["n1"], a["n0"])):
                if len(nome) < 6:
                    continue
                if nome == a["n0"] and nome in visti_n0:
                    break
                fatto = False
                for m in re.finditer(r"(?<![a-z0-9])" + re.escape(nome) + r"(?![a-z0-9])", tn):
                    if any(occupato[m.start():m.end()]):
                        continue
                    for j in range(m.start(), m.end()):
                        occupato[j] = True
                    trovati.append((m.start(), a))
                    visti_n0.add(a["n0"])
                    fatto = True
                    break
                if fatto:
                    break
        trovati.sort(key=lambda x: x[0])
        out, visti = [], set()
        for _, a in trovati:
            if a["codice"] not in visti:
                visti.add(a["codice"])
                out.append(a)
        return out

    def slot(self, piece: str) -> list[dict]:
        """Attività «segnaposto per lingua»: «Lingua e linguistica (prima lingua UE)», «Traduzione specialistica I (…)»."""
        p0 = _norm(_senza_par(piece))
        p0 = re.sub(r"\b(della|di) (prima|seconda|terza|quarta)( oppure seconda)? lingua( ue)?\b", "di lingua", p0)
        p0 = re.sub(r"\b(prima|seconda|terza)( oppure seconda)? lingua( ue)?$", "", p0).strip()
        p0 = re.sub(r"\bprima o seconda lingua$", "", p0).strip()
        pref = ALIAS.get(p0)
        base = _toks(pref or p0)
        con_qualifica = bool(re.search(r"(?i)\([^)]*(?:prima|seconda|terza)[^)]*\)", piece))
        if len(base) < 2 and not (con_qualifica and base):
            return []
        for solo_fam in (True, False):
            out = []
            for a in self.ads:
                if solo_fam and not a["fam"]:
                    continue
                t = _toks(a["n0"])
                if pref:
                    ok = a["n0"].startswith(pref)
                else:
                    ok = (t[0] == base[0] and _sottosequenza(base, t) and len(t) <= len(base) + 4
                          and not ({x for x in t if x in ("i", "ii", "iii", "iv")} - set(base)))
                    if ok and len(base) == 1:  # una sola parola («Letteratura (prima o seconda lingua)»): solo se segue la lingua
                        ok = len(t) == 2 and t[1] in LINGUE
                if ok:
                    out.append(a)
            if out:
                by: dict[str, dict] = {}
                for a in out:
                    if a["n"] not in by or a["aa"] > by[a["n"]]["aa"]:
                        by[a["n"]] = a
                return list(by.values())
        return []


def abbina(titolo: str, pool: Pool, labs: list[str] | None = None, libera: bool = False) -> list:
    """Le alternative di una riga del piano: attività del Catalogo o, se non c'è, il nome della riga (str)."""
    t = re.sub(r"\s+", " ", titolo).strip()
    tn = _norm(t)
    if tn.startswith("soft skills"):
        out = []
        for a in pool.ads:
            if a["n"].startswith("soft skills"):
                suff = _norm(re.sub(r"(?i)^soft skills\s*[-:]?\s*", "", a["des"]))
                if suff and suff in tn:
                    out.append(a)
        return list({a["n"]: a for a in out}.values()) or [t]
    if re.search(r"(?i)vedi sezione", t):
        alts: list = list(pool.esatto("tirocini")) or ["Tirocinio"]
        for lab in labs or []:
            alts += pool.esatto(lab) or pool.slot(lab) or [lab]
        return alts
    m = re.search(r"(?i)\b(?:consigliat[oi]|recommended)\s*:?\s*(.*)$", t)
    if m and (libera or re.search(r"(?i)libera scelta|elective", t)):
        elenco = m.group(1)
        trovati = pool.contenuti(elenco)
        if trovati:
            return trovati
        t = re.sub(r"(?i)\s*\b(?:consigliat[oi]|recommended).*$", "", t).strip() or t
    out: list = []
    for p in _dividi_oppure(t):
        p = p.strip()
        if not p:
            continue
        m = re.match(r"(?i)^(.*?)\(\s*a scelta tra\s+(.*)\)\s*$", p)
        if m:
            testa, elenco = m.group(1).strip(), m.group(2)
            out += pool.esatto(testa) or pool.slot(testa) or pool.contenuti(elenco) or [p]
            continue
        m = _SCELTA_TRA.search(p)
        if m:
            testa, elenco = p[:m.start()], p[m.end():]
            testa = re.sub(r"(?i)^\s*(?:\d+|un|uno|due|tre)\s+(?:insegnament[oi]|laborator[io]|esam[ei])\s*$", "", testa).strip()
            r = pool.contenuti(elenco)
            if not r and testa:
                r = pool.esatto(testa) or pool.slot(testa)
            out += r or [p]
            continue
        if re.search(r"(?i)\([^)]*\b(?:prima|seconda|terza)\b[^)]*\)", p):
            r = pool.slot(p) or pool.esatto(p)  # segnaposto per lingua: tutte le lingue, non l'attività che ha lo stesso nome
        else:
            r = pool.esatto(p) or pool.slot(p)
        if not r:
            cand = pool.contenuti(p)
            pn = _norm(_senza_par(p))
            if len(cand) == 1 and len(cand[0]["n0"]) >= 0.8 * len(pn):
                r = cand
        out += r or [p]
    visti, res = set(), []
    for a in out:
        k = a if isinstance(a, str) else a["codice"]
        if k not in visti:
            visti.add(k)
            res.append(a)
    return res


# ----------------------------------------------------------------------------------------------- righe del piano
def _nome_curriculum(nome: str | None, lingua: str, prefisso: str = "") -> str | None:
    if not nome:
        return None
    n = re.sub(r"\s*,\s*", " ", nome).strip()
    n = prefisso + n
    return n + (" (EN)" if lingua == "en" else "")


def righe_blocco(blocco: dict, pool: Pool, curriculum: str | None, fonte: str) -> tuple[list[dict], dict]:
    """Le righe del piano di un curriculum (una per attività abbinata) e, per anno, i CFU che il piano dichiara
    (obbligatori più una scelta per ogni gruppo: «N insegnamenti a scelta tra», «Sezione N CFU», crediti liberi)."""
    out: list[dict] = []
    dich: dict[int, float] = {}
    fissi: dict[int, float] = {}
    visti_gruppi: set[int] = set()
    for r in blocco["righe"]:
        anno, cfu, picks, g = r["anno"], r["cfu"], r["picks"], r["gruppo"]
        alts = abbina(r["titolo"], pool, blocco.get("labs"), r["libera"])
        stella = r["stella"] if any(n["liv"] == r["stella"] for n in blocco.get("stelle") or []) else 0
        scelta = bool(g) or r["libera"] or bool(stella) or len(alts) > 1
        if stella:
            pass  # i CFU delle righe con l'asterisco sono quelli della nota (aggiunti sotto)
        elif g and "tot" in g:
            if id(g) not in visti_gruppi:
                visti_gruppi.add(id(g))
                dich[anno] = dich.get(anno, 0) + g["tot"]
        elif g and "n" in g:
            if id(g) not in visti_gruppi:
                visti_gruppi.add(id(g))
                dich[anno] = dich.get(anno, 0) + g["n"] * cfu
        else:
            dich[anno] = dich.get(anno, 0) + cfu * picks
            if not scelta:
                fissi[anno] = fissi.get(anno, 0) + cfu
        for a in alts:
            if isinstance(a, str):
                nome = re.sub(r"\s+", " ", a).strip().rstrip(".")
                if re.match(r"(?i)^(?:\d+|un|uno|due)\s+(?:insegnament[oi]|elective course)\s+a libera scelta", nome):
                    nome = "Insegnamenti a libera scelta dello studente"
                nome = nome[:1].upper() + nome[1:]
                ad = None
                cfu_riga = cfu * picks if len(alts) == 1 and picks > 1 else cfu
            else:
                nome, ad = a["nome"], a
                cfu_riga = cfu
                if r["libera"] and a.get("cfu"):
                    cfu_riga = a["cfu"]
            out.append({"anno": anno, "ad": ad, "nome": nome, "cfu": cfu_riga, "obbligatorio": not scelta,
                        "curriculum": curriculum, "fonte": fonte})
    for nota in blocco.get("stelle") or []:
        righe_stella = [r for r in blocco["righe"] if r["stella"] == nota["liv"]]
        if righe_stella:
            anno_n = max(r["anno"] for r in righe_stella)
            dich[anno_n] = dich.get(anno_n, 0) + (nota["cfu"] if nota["cfu"] else nota["n"] * righe_stella[0]["cfu"])
    # nessuna attività due volte nello stesso anno e curriculum
    visti, res = set(), []
    for x in out:
        k = (x["anno"], x["ad"]["codice"] if x["ad"] else _norm(x["nome"]))
        if k in visti:
            continue
        visti.add(k)
        res.append(x)
    return res, {"dichiarati": dich, "fissi": fissi}


def piano_l18() -> dict:
    righe = []
    for anno, titolo, cfu, tipo in PIANO_L18:
        picks = int(tipo.split(":")[1]) if tipo.startswith("g:") else 1
        righe.append({"anno": anno, "titolo": titolo, "cfu": cfu, "picks": picks, "gruppo": None, "libera": tipo == "l",
                      "stella": False, "corpo": "", "lingua": "it"})
    return {"curriculum": None, "lingua": "it", "righe": righe, "labs": []}


# ----------------------------------------------------------------------------------------------- libri già raccolti
def _noti() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database o nei contributi, per codice dell'insegnamento (nessuna richiesta)."""
    out: dict[str, dict] = {}
    percorsi = [ROOT / "database" / "corsi" / "unint.json", ROOT / "database" / "contrib" / "auto" / "unint.json",
                ROOT / "database" / "contrib" / "auto" / "unint_syl_b2.json"]
    percorsi += [pathlib.Path(x) for x in os.environ.get("UNINT_NOTI", "").split(os.pathsep) if x]
    for p in percorsi:
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            for i in corso.get("insegnamenti") or []:
                cod = i.get("codice")
                if not cod:
                    continue
                cur = out.setdefault(cod, {})
                if i.get("libri") and not cur.get("libri"):
                    cur["libri"] = i["libri"]
                for k in ("modalita_esame", "ssd", "url_sito"):
                    if i.get(k) and not cur.get(k):
                        cur[k] = i[k]
                if "visto" not in cur:
                    cur["visto"] = True
    return out


def _syllabus(ad: dict, noto: dict | None) -> dict:
    """libri, modalità d'esame, SSD e sito dell'attività: da quelli già raccolti o dalla scheda del Catalogo."""
    if noto and (noto.get("libri") or noto.get("visto")):
        return {k: noto.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito") if noto.get(k)}
    sy = _json("/insegnamento", {k: v for k, v in ad["params"].items() if v not in (None, "")})
    if not isinstance(sy, dict):
        return {}
    libri, modalita, legati = cc._testi_syllabus(sy)
    if not libri:
        from .uniba import libri_testo_libero
        libri = libri_testo_libero(sy)
    if not libri:
        for u in legati:
            libri += cc.leganto.libri(u)
    out: dict = {}
    if libri:
        out["libri"] = libri
    if modalita:
        out["modalita_esame"] = modalita
    if sy.get("ssd"):
        out["ssd"] = sy["ssd"]
    if sy.get("urlSitoWeb"):
        out["url_sito"] = sy["urlSitoWeb"].strip()
    return out


# ----------------------------------------------------------------------------------------------- corsi
DICHIARATI: dict[str, dict] = {}  # id corso → {curriculum: {anno: CFU dichiarati dal piano}} (per i controlli)
NON_ABBINATE: dict[str, list] = {}


def fetch_ateneo(uid: str = "unint", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    oggi = time.strftime("%Y-%m-%d")
    noti = _noti()
    tutte: dict[str, dict] = {}
    famiglie = {}
    for cfg in CORSI:
        ads, dett = catalogo_corso(cfg["cds"])
        famiglie[cfg["id"]] = (ads, dett)
        for k, v in ads.items():
            if k not in tutte or v["aa"] > tutte[k]["aa"]:
                tutte[k] = v
    for extra in ("05FDE", "04FDE", "16FIT"):
        for k, v in catalogo_corso((extra,))[0].items():
            tutte.setdefault(k, v)
    corsi_out = []
    for cfg in (CORSI[:max_cds] if max_cds else CORSI):
        ads, dett = famiglie[cfg["id"]]
        if not dett:
            log(f"[{uid}] {cfg['id']}: corso non trovato nel Catalogo")
            continue
        pool = Pool(ads, {k: v for k, v in tutte.items() if k not in ads})
        blocchi: list[tuple[dict, str, str | None]] = []  # (blocco, url della pagina, nome curriculum)
        if cfg["pagine"]:
            for path, nome_pagina in cfg["pagine"]:
                url = SITO + path
                html = _get_text(url)
                if not html:
                    log(f"[{uid}] pagina non letta: {url}")
                    continue
                prefisso = "Didattica: " if "indirizzo-didattica" in path else ""
                for b in parse_pagina(html, nome_pagina):
                    blocchi.append((b, url, _nome_curriculum(b["curriculum"] or nome_pagina, b["lingua"], prefisso)))
        else:
            blocchi.append((piano_l18(), PIANO_L18_URL, None))
        nomi = list(dict.fromkeys(n for _, _, n in blocchi if n))
        multi = len(nomi) > 1
        righe: list[dict] = []
        dich: dict = {}
        for b, url, nome_c in blocchi:
            rr, info = righe_blocco(b, pool, nome_c if multi else None, url)
            righe += rr
            dich[nome_c or "-"] = info
        DICHIARATI[cfg["id"]] = dich
        # righe uguali in più curricula: una sola, con l'elenco dei curricula (nessuno se valgono per tutti)
        fuse: dict[tuple, dict] = {}
        for x in righe:
            k = (x["anno"], x["ad"]["codice"] if x["ad"] else _norm(x["nome"]), x["obbligatorio"], x["cfu"])
            if k not in fuse:
                fuse[k] = {**x, "curricula": []}
            if x["curriculum"] and x["curriculum"] not in fuse[k]["curricula"]:
                fuse[k]["curricula"].append(x["curriculum"])
        insegnamenti = []
        for x in fuse.values():
            cur = x["curricula"]
            curriculum = None if (not cur or len(cur) == len(nomi)) else ", ".join(cur)
            ad = x["ad"]
            item = {
                "codice": ad["codice"] if ad else None, "nome": x["nome"], "anno": x["anno"],
                "periodo": ad["periodo"] if ad else None,
                "periodo_inizio": ad["periodo_inizio"] if ad else None, "periodo_fine": ad["periodo_fine"] if ad else None,
                "cfu": x["cfu"], "ssd": None, "obbligatorio": x["obbligatorio"], "curriculum": curriculum,
                "docenti": ad["docenti"] if ad else [], "url": ad["url"] if ad else x["fonte"],
                "libri": [], "esami": [], "fonte": x["fonte"], "verificato_il": oggi,
            }
            if ad:
                sy = _syllabus(ad, noti.get(ad["codice"])) if syllabus or noti.get(ad["codice"]) else {}
                item["libri"] = sy.get("libri") or []
                item["stato_libri"] = "completo" if item["libri"] else "da_aggiungere"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if sy.get(k_):
                        item[k_] = sy[k_]
            else:
                item["stato_libri"] = "da_aggiungere"
            insegnamenti.append(item)
        NON_ABBINATE[cfg["id"]] = sorted({i["nome"] for i in insegnamenti if not i["codice"]})
        corso = {
            "id": cfg["id"], "nome": cfg.get("nome") or cc._titolo(dett.get("des_it") or ""),
            "classe": cfg.get("classe") or cc._classe(dett.get("classe_cod")), "tipo_catalogo": cfg.get("tipo") or dett.get("tipo_corso_cod"),
            "durata_anni": cfg.get("durata") or (2 if str(dett.get("tipo_corso_cod")) == "LM" else 3),
            "sede": "Roma (RM)", "codice_ateneo": dett.get("cdsCod"),
            "url": cfg.get("url") or f"{BASE}/corsi/{dett['_coorte']}/{dett.get('cod')}",
            "curricula": nomi if multi else None,
            "ammissione": ammissione.da_catalogo(dett, f"{BASE}/corsi/{dett['_coorte']}/{dett.get('cod')}"),
            "fonte": SITO + "didattica/" if cfg["pagine"] else PIANO_L18_URL, "verificato_il": oggi,
            "insegnamenti": sorted(insegnamenti, key=lambda i: (i["anno"], not i["obbligatorio"], i["nome"])),
        }
        if cfg.get("ul"):
            corso["id_universitaly"] = cfg["ul"]
        corsi_out.append(corso)
        log(f"[{uid}] {cfg['id']}: {len(insegnamenti)} righe, {len(nomi)} curricula")
    return {"universita_id": uid, "descrizione": f"Generato da {SITO} (piani di studio) e {BASE} (Course Catalogue Cineca, adapters/unint.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unint.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unint] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
