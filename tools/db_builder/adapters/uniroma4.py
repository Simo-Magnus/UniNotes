"""Università degli Studi di Roma «Foro Italico» (Uniroma4): piani di studio, AFS, syllabus e libri.

Piani e syllabus: `https://uniroma4.coursecatalogue.cineca.it` (API pubblica, coorti 2022-2026). AFS (attività formative a
scelta) e internati elettivi: pagine ufficiali `uniroma4.it/…/attivita-formative-a-scelta-afs/`. Rispetto all'adattatore
comune (`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`), con l'id Universitaly esplicito: il catalogo ha un corso per ogni codice
  («L22R», «LM67I-R», …) e con i riordini del 2025 i codici sono cambiati («L22» <- «L22R», «LM67INT» <- «LM67I-R», …); le coorti
  precedenti restano sotto il codice vecchio. Senza l'id i corsi del catalogo restavano accanto a quelli di Universitaly come
  doppioni («Corso di Laurea Magistrale in Management dello Sport» e «Management dello Sport»);
- per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno) del codice più
  recente che ha il piano di quell'anno (catena di codici); se la coorte non ha quell'anno si usa la più vicina che lo ha. Nel
  2026/27 il 3° anno di Scienze motorie e sportive è la coorte 2024 dell'ordinamento 2014 («L22»), il 1° e il 2° anno sono
  dell'ordinamento 2025 («L22R»); le magistrali hanno solo due anni;
- durata dal piano («3 anni», «2 anni»);
- gruppi del piano (`cod`): «OO» obbligatori; «F», «G» scelte o blocchi fissi (un'attività è obbligatoria se sta in «OO», o se è
  l'unica del gruppo senza una scelta nell'etichetta: le due lingue di L-22, gli sport a scelta di LM-68, i gruppi OPZ. di
  Health and Physical Activity sono scelte); la voce «Attività formativa a scelta dello studente» del catalogo (crediti liberi)
  è a scelta;
- AFS e internati elettivi: il catalogo li mette in un gruppo «W» senza anno («Attività a scelta … (4 CFU)», 57-83 attività da
  4 CFU, tutte «anno 0»), che con l'adattatore comune restavano senza anno. L'anno viene dalle pagine ufficiali delle AFS di
  ogni corso («Anno di corso: 1, 2, 3» nella pagina di Scienze motorie; nelle magistrali l'elenco completo
  `…/iscriversi-alle-attivita-formative-a-scelta-afs/afs-elenco-completo/`): una riga a scelta per ogni anno in cui l'AFS si può
  frequentare. Health and Physical Activity non ha AFS nel piano (solo attività sovrannumerarie): il gruppo «W» non conta. Se le
  pagine non rispondono si ripiega sul gruppo «W» del catalogo (anno dalle date di erogazione);
- attività a 0 CFU (OFA, prove di lingua senza crediti, AFS non attive per la coorte) non sono insegnamenti del piano;
- percorsi: «comune» (nome «comune», «percorso comune») vale per tutti i curricula; gli altri si riconoscono per nome (con gli
  alias di `ALIAS_PERCORSI` per i refusi del catalogo: «Gestone»). Lo stesso codice con CFU diversi in percorsi diversi resta su
  righe distinte.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo e delle pagine AFS restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/uniroma4.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/uniroma4.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import unicodedata
import urllib.request
from html.parser import HTMLParser

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .uniba import libri_testo_libero  # noqa: E402

BASE = "https://uniroma4.coursecatalogue.cineca.it"
SITO = "https://www.uniroma4.it/index.php"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L", "L2", "LM", "LM5"}  # lauree (in questo catalogo la laurea è «L2»), magistrali e ciclo unico (non i master)

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio).
# I codici più vecchi sono il vecchio ordinamento dello stesso corso (le coorti precedenti).
CORSI: list[tuple[str, tuple[str, ...]]] = [
    ("1629575", ("L22R", "L22")),                  # Scienze motorie e sportive (L-22): ordinamento 2025 (2025, 2026) < 2014 (fino al 2024)
    ("1629577", ("LM67R", "LM67")),                # Attività motorie preventive e adattate (LM-67)
    ("1629555", ("LM67I-R", "LM67INT")),           # Health and Physical Activity (LM-67 interateneo, in inglese)
    ("1629576", ("LM47R", "LM47")),                # Management dello sport (LM-47)
    ("1629578", ("LM68R", "LM68")),                # Scienza e tecnica dello sport (LM-68)
]

# Pagine ufficiali delle AFS di ogni corso (codice più recente del catalogo → pagina); None: il piano non ha AFS (le attività
# del gruppo «W» sono sovrannumerarie) e il gruppo non si legge.
_AFS = SITO + "/didattica/attivita-formative-a-scelta-afs/"
AFS_PAGINE: dict[str, str | None] = {
    "L22R": _AFS + "afs-laurea-in-scienze-motorie-e-sportive-l22-46/",
    "LM47R": _AFS + "afs-corsi-laurea-magistrale-in-management-dello-sport-lm47/",
    "LM67R": _AFS + "afs-corsi-laurea-magistrale-in-attivita-motorie-preventive-e-adattate-lm67/",
    "LM68R": _AFS + "afs-corsi-laurea-magistrale-in-scienza-e-tecnica-dello-sport-lm68/",
    "LM67I-R": None,
}
# «Ogni AFS/IE permette di acquisire 4 CFU» (pagina dell'elenco completo delle AFS): la colonna CFU delle pagine delle magistrali
# ha numeri diversi (5-12) che non tornano con la scheda di ogni AFS (4 CFU) né con le quote del piano (4+4 CFU)
CFU_AFS = 4
# Anni di corso delle AFS delle magistrali (le loro pagine non hanno la colonna compilata)
AFS_ELENCO_COMPLETO = SITO + "/come-fare-per/iscriversi-alle-attivita-formative-a-scelta-afs/afs-elenco-completo/"

# Percorsi che il catalogo scrive in modo diverso tra le coorti (refusi): chiave normalizzata del nome → nome del curriculum
ALIAS_PERCORSI = {
    "gestone e organizzazione dello sport di alto livello": "Gestione e organizzazione dello sport di alto livello",
    "gestione e organizzazione dello sport di alto livello": "Gestione e organizzazione dello sport di alto livello",
    "scienze motorie e sportive": "Scienze motorie e sportive",
}

# Corsi in cui la lettera del codice dei percorsi è sempre lo stesso curriculum nelle coorti (nessuno: i nomi bastano)
LETTERE_STABILI: set[str] = set()

# Correzioni al catalogo dove il piano ufficiale dice altro: (codice del corso, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "obbligatorio" | "cfu=<n>".
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (codice del corso, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

_SMALL = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al", "alla",
          "alle", "ai", "agli", "il", "la", "lo", "le", "gli", "i", "nel", "nella", "nelle", "nei", "sul", "sulla", "tra",
          "fra", "o", "su", "dal", "dalla", "and", "of", "the", "to", "for", "on", "with", "an", "or", "at", "by", "from"}
_SIGLE = {"ADE", "OPZ", "TPV", "DNA", "RNA", "IT", "AI", "IA", "ICT", "IOT", "CAD", "CAM", "PCR", "ECG", "EEG", "TC", "RM", "STEM",
          "MRI", "OFA", "GIS", "BIM", "CFU", "UX", "UI", "XML", "HTML", "SQL", "ECTS", "GPS", "LCA", "VR", "AR", "DSP",
          "BLSD", "SSN", "FISE", "ONU", "UE", "CONI", "EBM", "AFS", "IE"}
_CREDITI_LIBERI = {"a scelta", "a libera scelta", "attivita libera", "attivita a scelta", "attivita a libera scelta"}
_SCELTA = re.compile(r"(?i)scelt|opzion|alternativ|elective|elettiv|optional|oppure|\btra\b|\bfra\b|\bor\b|among|betwee?n|\bone\b")
_CFU_ETICHETTA = re.compile(r"(?:\(\s*)?(?:(?:fra|tra)\s+([\d.,]+)\s+e\s+)?(?<![\w.,])([\d.,]*\d)\s*(?:CFU|crediti)\b(?:\s*\))?", re.I)
_COMUNE = re.compile(r"(?i)\bcomun[ie]\b|\bgeneric[oa]\b")
_ROMANO = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6}
_PERIODI = {"primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale",
            "primo semestre": "1", "secondo semestre": "2", "annuale": "annuale"}
_HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
            "Accept": "text/html"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _accenti(s: str) -> str:
    """«ATTIVITA'» → «ATTIVITÀ», "attivita'" → «attività» (il catalogo e le pagine scrivono l'accento con l'apostrofo)."""
    s = re.sub(r"(?<=[A-Z]{2})([AU])'(?![\w])", lambda m: {"A": "À", "U": "Ù"}[m.group(1)], s)
    return re.sub(r"(?<=[a-z]{2})([au])'(?![\w])", lambda m: {"a": "à", "u": "ù"}[m.group(1)], s)


def _titolo(des: str | None) -> str:
    """Nome dell'attività: maiuscolo del catalogo → iniziali maiuscole (sigle e numeri romani restano)."""
    des = _accenti(re.sub(r"\s+", " ", des or "").strip())
    if not des.isupper():
        return des
    out = []
    for i, w in enumerate(des.lower().split(" ")):
        core = re.sub(r"[^\w']", "", w)
        if re.fullmatch(r"[ivx]{1,4}", core):
            out.append(w.upper())
        elif core.upper() in _SIGLE:
            out.append(re.sub(re.escape(core), core.upper(), w, count=1))
        elif i and core in _SMALL:
            out.append(w)
        elif "-" in w and w.split("-")[0].upper() in _SIGLE:  # «opz-tirocinio» → «OPZ-Tirocinio»
            a, _, b = w.partition("-")
            out.append(a.upper() + "-" + b[:1].upper() + b[1:])
        elif "'" in w:
            a, _, b = w.partition("'")
            if i == 0 or not b:  # «L'ENERGIA», «QUALITA'»: la prima lettera maiuscola
                a = a[:1].upper() + a[1:]
            out.append(a + "'" + b[:1].upper() + b[1:])
        else:
            m = re.search(r"[a-zà-ÿ]", w)
            out.append(w[:m.start()] + w[m.start()].upper() + w[m.start() + 1:] if m else w)
    return " ".join(out)


def _nome_attivita(att: dict) -> str:
    """Nome dell'attività; «A SCELTA» (la voce dei crediti liberi, tipologia «A scelta dello studente») prende il nome
    che la stessa voce ha negli altri corsi dell'ateneo."""
    nome = _titolo(att.get("des_it") or att.get("adCod") or "")
    if _norm(nome) in _CREDITI_LIBERI and _a_scelta_studente(att):
        return "Attività formative a scelta dello studente"
    return nome


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return _PERIODI.get(re.sub(r"\s+", " ", s.lower()).strip(), s.strip())


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/uniroma4)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "uniroma4" if d else None

    def get(self, path, params=None):
        if not self.cache:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.cache / key[:2] / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def _cfu_etichetta(label: str | None):
    """(minimo, massimo) dei CFU nell'etichetta di un gruppo: «(3 CFU)» → (3, 3), «(fra 6 e 12 CFU)» → (6, 12)."""
    m = _CFU_ETICHETTA.search(label or "")
    if not m:
        return None
    try:
        hi = _numero(m.group(2).strip(".,"))
        lo = _numero(m.group(1).strip(".,")) if m.group(1) else hi
    except ValueError:
        return None
    return lo, hi


def _sede(cur: dict) -> str | None:
    """Comune della sede («ROMA (RM)» → «Roma»), come lo dà Universitaly; il catalogo ha anche l'indirizzo."""
    comune = re.sub(r"\s*\([A-Z]{2}\)\s*$", "", cur.get("sedeDenominazioneComune") or "").strip()
    return comune.title() if comune else (cur.get("sede_des_it") or None)


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L": 3, "L2": 3, "LM": 2, "LM5": 5}.get(tipo or "", 3)


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _a_scelta_studente(att: dict) -> bool:
    return (att.get("tafDes_it") or "").strip().lower() == "a scelta dello studente" or bool(
        re.search(r"(?i)a scelta dello studente|\bADE\b", att.get("des_it") or ""))


def _anno_gruppo0(g: dict, coorte: int, durata: int) -> int:
    """Anno di corso di un gruppo dell'anno 0: dall'etichetta («ADE III anno», «2 anno») o dall'anno di erogazione."""
    lab = g.get("label_it") or ""
    m = re.search(r"(?i)\b(i{1,3}|iv|v|vi|[1-6])\s*°?\s*anno\b", lab)
    if m:
        t = m.group(1).lower()
        n = _ROMANO.get(t) or int(t)
        if 1 <= n <= durata:
            return n
    anni = []
    for t in g.get("attivita") or []:
        if str(t.get("aa") or "").isdigit():
            anni.append(int(t["aa"]) - coorte + 1)
    if anni:
        return min(max(max(set(anni), key=anni.count), 1), durata)
    return durata


def _obbligatorio(g: dict, att: dict, atts: list[dict]) -> bool:
    if _a_scelta_studente(att) and re.search(r"(?i)scelta|ADE", att.get("des_it") or ""):
        return False  # «A libera scelta», crediti liberi del catalogo: a scelta anche dentro «Obbligatori» (non un tirocinio o
        # un corso che ha solo la tipologia «A scelta dello studente»)
    if g.get("cod") == "OO":
        return True
    if g.get("cod") == "W":  # attività a libera scelta «fra 1 e N CFU»
        return False
    # blocchi F/G: un'unica attività senza scelta nell'etichetta è obbligatoria; i blocchi di alternative (le due lingue,
    # sport a scelta, gruppi di insegnamenti a scelta) sono a scelta
    return len(atts) == 1 and not _SCELTA.search(g.get("label_it") or "")


def _pool(a: dict, g: dict) -> bool:
    """Gruppo «W» dell'anno 0: elenco delle AFS e degli internati elettivi del catalogo (senza anno di corso)."""
    return str(a.get("anno")) == "0" and g.get("cod") == "W"


def _gruppi_piano(a: dict, usa_pool: bool) -> list[dict]:
    return [g for g in _gruppi(a) if usa_pool or not _pool(a, g)]


def _vale(a: dict, k: int, g: dict | None, coorte: int, durata: int) -> bool:
    """Il gruppo `g` dell'anno `a` del piano vale per l'anno di corso k."""
    if not str(a.get("anno")).isdigit():
        return False
    n = int(a["anno"])
    if n == 0:
        return g is not None and _anno_gruppo0(g, coorte, durata) == k
    return n == k


def _ha_anno(det: dict, k: int, coorte: int, durata: int, usa_pool: bool) -> bool:
    """Il piano ha attività con CFU per l'anno di corso k."""
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            for g in _gruppi_piano(a, usa_pool):
                if _vale(a, k, g, coorte, durata) and any((t.get("crediti") or 0) > 0 for t in g.get("attivita") or []):
                    return True
    return False


def _nome_percorso_grezzo(p: dict) -> str:
    n = (p.get("des_it") or p.get("pdsDes") or "").strip()
    n = re.sub(r"(?i)\s*-\s*corso di laurea magistrale in .*$", "", n)
    n = re.sub(r"(?i)^\s*schema(?: automatico per il pds)?\s*:?\s*", "", n)
    n = re.sub(r"(?i)^\s*(?:curriculum|percorso|pds)\s+[A-Z]\s*[-–]\s*", "", n)
    n = re.sub(r"(?i)^\s*pds[a-z0-9]?\b\s*", "", n)
    n = re.sub(r"(?i)^\s*(?:percorso|curriculum|indirizzo)\s+", "", n)
    return re.sub(r"\s+", " ", n).strip(" -:")


_SENZA_NOME = re.compile(r"(?i)(?:pds)?[a-z]?\d{0,4}")


def _pulisci_nome_percorso(nome: str) -> str:
    """Nome di un curriculum: maiuscole del catalogo corrette e senza virgole (i curricula di un insegnamento si separano
    con la virgola); refusi tra le coorti corretti (`ALIAS_PERCORSI`)."""
    nome = re.sub(r"\s+", " ", nome).strip()
    nome = _titolo(nome) if nome.isupper() else nome
    nome = re.sub(r"\s*,\s*", " - ", nome)
    nome = nome[:1].upper() + nome[1:]
    return ALIAS_PERCORSI.get(_norm(nome), nome)


def _lettera(p: dict) -> str | None:
    m = re.match(r"PDS([A-Z])", (p.get("pdsCod") or "").strip())
    return m.group(1) if m else None


def _comune(p: dict) -> bool:
    """Percorso comune a tutti: dal nome («comune», «percorso generico»)."""
    return bool(_COMUNE.search(p.get("des_it") or p.get("pdsDes") or ""))


def _elenco_altrove(g: dict, gruppi: list[dict]) -> bool:
    """Un altro gruppo dello stesso anno e dello stesso tipo ha l'elenco delle attività (con CFU) di questa scelta: la regola
    senza elenco è la stessa scelta scritta due volte."""
    return any(h is not g and h.get("cod") == g.get("cod") and any((t.get("crediti") or 0) > 0 for t in h.get("attivita") or [])
               for h in gruppi)


def _nome_regola(label: str) -> str:
    """Nome della voce a scelta di una regola senza elenco: le regole «a scelta» sono attività a scelta dello studente."""
    lab = _CFU_ETICHETTA.sub(" ", label or "")
    if re.search(r"(?i)scel|scle|select", lab):
        return "Attività formative a scelta dello studente"
    nome = re.sub(r"\s+", " ", lab).strip(" -–:/,()")
    return nome[:1].upper() + nome[1:].lower()


# ---------------------------------------------------------------------------------------------------------------------
# AFS dalle pagine ufficiali

class _Tabella(HTMLParser):
    """Righe (liste di celle di testo) di tutte le tabelle di una pagina; `<br>` separa le righe di una cella."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.righe: list[list[str]] = []
        self._riga: list[str] | None = None
        self._cella: list[str] | None = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self._riga = []
        elif tag in ("td", "th") and self._riga is not None:
            self._cella = []
        elif tag == "br" and self._cella is not None:
            self._cella.append("\n")

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._cella is not None and self._riga is not None:
            testo = "".join(self._cella)
            self._riga.append("\n".join(re.sub(r"[ \t\r\f\v\xa0]+", " ", r).strip() for r in testo.split("\n")
                                        if r.strip()))
            self._cella = None
        elif tag == "tr" and self._riga is not None:
            self.righe.append(self._riga)
            self._riga = None

    def handle_data(self, d):
        if self._cella is not None:
            self._cella.append(d.replace(chr(10), " "))


def _scarica(url: str, cache: pathlib.Path | None) -> str | None:
    f = None
    if cache:
        f = cache / (hashlib.sha1(url.encode()).hexdigest() + ".html")
        if f.exists():
            return f.read_text(encoding="utf-8")
    for tentativo in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=_HEADERS), timeout=60) as r:
                testo = r.read().decode("utf-8", "replace")
            if f:
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(testo, encoding="utf-8")
            return testo
        except (OSError, ValueError):
            time.sleep(2 ** tentativo)
    return None


def _tabella(url: str, cache: pathlib.Path | None) -> list[dict] | None:
    """Righe della prima tabella AFS della pagina (l'offerta dell'a.a. corrente: le altre sono gli anni accademici
    precedenti) come dizionari {intestazione: testo}; None se la pagina non si legge."""
    testo = _scarica(url, cache)
    if not testo:
        return None
    p = _Tabella()
    p.feed(testo)
    intest = None
    out = []
    for r in p.righe:
        if r and r[0].strip().upper().startswith("AFS/IE"):
            if intest:  # seconda tabella: a.a. precedente
                break
            intest = [c.strip() for c in r]
        elif intest and len(r) >= len(intest) - 1 and r[0].strip().upper() in ("AFS", "IE"):
            out.append(dict(zip(intest, r)))
    return out


def _anni(s: str | None, durata: int) -> list[int]:
    return sorted({int(x) for x in re.findall(r"\d+", s or "") if 1 <= int(x) <= durata})


def _afs_semestre(s: str | None) -> str | None:
    s = _norm(s)
    if s in ("1", "2"):
        return s
    if s.startswith("ann"):
        return "annuale"
    return None


def _leggi_afs(codice_corso: str, durata: int, cache: pathlib.Path | None, log) -> list[dict] | None:
    """AFS e internati elettivi del corso dalle pagine ufficiali: [{codice, titolo, tipo, ssd, cfu, anni, periodo, docenti,
    fonte}]. None se le pagine non si leggono (si ripiega sul catalogo); [] se il corso non ha AFS."""
    url = AFS_PAGINE.get(codice_corso)
    if not url:
        return []
    righe = _tabella(url, cache)
    if righe is None:
        log(f"[uniroma4] pagina AFS non letta: {url}")
        return None
    completo = _tabella(AFS_ELENCO_COMPLETO, cache) or []
    anni_completo: dict[str, set[int]] = {}
    for r in completo:
        anni_completo.setdefault((r.get("Codice") or "").strip(), set()).update(_anni(r.get("Anno di corso"), durata))
    out = []
    viste: set[str] = set()
    for r in righe:
        cod = (r.get("Codice") or "").strip()
        titolo = re.sub(r"\s+", " ", r.get("Titolo insegnamento") or "").strip()
        if not cod or not titolo or cod in viste:
            continue
        viste.add(cod)
        # anno di corso: dalla pagina del corso, altrimenti dall'elenco completo; se nessuna delle due lo dice (AFS solo
        # nell'elenco del corso, senza limite di anno) l'AFS vale per tutti gli anni del corso
        anni = _anni(r.get("Anno di corso"), durata) or sorted(anni_completo.get(cod) or []) or list(range(1, durata + 1))
        docenti = [d.strip() for d in (r.get("Docente") or r.get("Docenti") or "").split("\n")
                   if d.strip() and not d.strip().lower().startswith(("http", "contattare"))]
        out.append({"codice": cod, "titolo": titolo, "tipo": r.get("AFS/IE", "AFS").strip().upper(),
                    "ssd": re.sub(r"\s+", " ", r.get("SSD") or "").strip() or None, "cfu": CFU_AFS,
                    "anni": anni, "periodo": _afs_semestre(r.get("Semestre")), "docenti": docenti, "fonte": url})
    return out


def _nome_afs(a: dict, att: dict | None) -> str:
    """Nome di un'AFS: quello del catalogo se la stessa attività c'è (con «Internato elettivo: …»), altrimenti il titolo della
    pagina nello stile del resto del piano."""
    if att and att.get("des_it"):
        return _titolo(att["des_it"])
    nome = _titolo(a["titolo"].upper())
    if a["tipo"] == "IE" and not nome.lower().startswith("internato elettivo"):
        nome = "Internato Elettivo: " + nome
    return nome


# ---------------------------------------------------------------------------------------------------------------------

def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    d_cache = os.environ.get("UN_HTTP_CACHE")
    cache_afs = pathlib.Path(d_cache) / "uniroma4_afs" if d_cache else None
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI}
    log(f"[{uid}] {len(coorti.get(anno, {}))} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build(id_ul: str, catena: tuple[str, ...]) -> dict | None:
        # piani di ogni coorte, nell'ordine della catena di codici
        cohorts: dict[int, list[tuple[dict, dict]]] = {}
        for y in range(anno - 6, anno + 1):
            lst = []
            for cod in catena:
                x = coorti.get(y, {}).get(cod)
                d = dettaglio(y, x) if x else None
                if d:
                    lst.append((x, d))
            if lst:
                cohorts[y] = lst
        if not cohorts:
            return None
        cur = coorti[anno].get(catena[0]) or next(iter(cohorts[max(cohorts)]))[0]
        rec_x, rec_d = (cohorts.get(anno) or cohorts[max(cohorts)])[0]
        durata = _durata(rec_d, rec_x.get("tipo_corso_cod"))
        afs = _leggi_afs(catena[0], durata, cache_afs, log)
        usa_pool = afs is None  # pagine AFS illeggibili: si ripiega sul gruppo «W» del catalogo
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][0][1], f"{base}/corsi/{anno}/{cohorts[anno][0][0]['cod']}")

        def piano(k: int):
            """(coorte, riga dell'elenco, dettaglio) da cui leggere l'anno di corso k."""
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((catena[0], k))
            ordine = [forzata] if forzata in cohorts else []
            ordine += sorted(cohorts, key=lambda y: (abs(y - y0), -y))
            for y in ordine:
                for x, d in cohorts[y]:
                    if _ha_anno(d, k, y, durata, usa_pool):
                        return y, x, d
            return None

        # nome canonico dei percorsi: quello della coorte più recente che li ha, per nome (senza maiuscole e punteggiatura)
        stabili = catena[0] in LETTERE_STABILI
        per_lettera: dict[str, str] = {}
        per_chiave: dict[str, str] = {}
        for y in sorted(cohorts, reverse=True):
            for _x, d in cohorts[y]:
                for p in d.get("percorsi") or []:
                    nome = _nome_percorso_grezzo(p)
                    if not nome or _SENZA_NOME.fullmatch(nome) or _comune(p):
                        continue
                    nome = _pulisci_nome_percorso(nome)
                    per_chiave.setdefault(_norm(nome), nome)
                    if stabili and _lettera(p):
                        per_lettera.setdefault(_lettera(p), nome)

        def nome_percorso(p: dict) -> str:
            nome = _nome_percorso_grezzo(p)
            if stabili and _lettera(p) in per_lettera:
                return per_lettera[_lettera(p)]
            if not nome or _SENZA_NOME.fullmatch(nome):
                return per_lettera.get(_lettera(p) or "", nome or (p.get("pdsCod") or ""))
            nome = _pulisci_nome_percorso(nome)
            return per_chiave.get(_norm(nome), nome)

        alt_per_ad: dict[str, dict] = {}
        pool_att: dict[str, tuple[int, dict]] = {}  # AFS del catalogo per codice: (coorte, attività) più recente
        for y, lst in sorted(cohorts.items(), reverse=True):
            for _x, d in lst:
                for p in d.get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in _gruppi(a):
                            for t in g.get("attivita") or []:
                                alt_per_ad.setdefault(t.get("adCod") or t.get("cod"), {})[(str(t.get("aa")), str(t.get("cod")))] = (y, t)
                                if _pool(a, g):
                                    pool_att.setdefault(t.get("adCod") or t.get("cod"), (y, t))

        insegnamenti: dict[str, dict] = {}
        stati: dict[str, dict[str | None, bool]] = {}  # (anno:codice) → {curriculum o None se comune: obbligatorio}
        percorsi_nomi: set[str] = set()
        piano_anni: dict[str, dict] = {}
        tutti_anno: dict[int, set] = {}

        def registra_syllabus(att: dict, y: int, ad: str, item: dict) -> None:
            syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                           "ordinamento_aa": att.get("ordinamento_aa"),
                           "af_percorso": att.get("corso_percorso_id"),
                           "corso_cod": att.get("corso_cod"), "corso_aa": y,
                           "schema_id": att.get("schemaId")},
                "items": [], "codice": ad,
                "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                    alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                    if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
            })["items"].append(item)

        for k in range(1, durata + 1):
            sc = piano(k)
            if not sc:
                continue
            y, x, d = sc
            piano_anni[str(k)] = {"coorte": y, "url": f"{base}/corsi/{y}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(_vale(a, k, g, y, durata) for a in p.get("anni") or [] for g in _gruppi_piano(a, usa_pool))]
            comuni = [p for p in percorsi_k if _comune(p)]
            specifici = [p for p in percorsi_k if not _comune(p)]
            if len(percorsi_k) == 1 or len({nome_percorso(p) for p in specifici}) < 2:
                comuni, specifici = percorsi_k, []  # un solo percorso: vale per tutti
            tutti_anno[k] = {nome_percorso(p) for p in specifici}
            percorsi_nomi |= tutti_anno[k]
            for p in percorsi_k:
                pcur = None if p in comuni else nome_percorso(p)
                for a in p.get("anni") or []:
                    gruppi_a = _gruppi_piano(a, usa_pool)
                    for g in gruppi_a:
                        if not _vale(a, k, g, y, durata):
                            continue
                        atts = [t for t in g.get("attivita") or [] if (t.get("crediti") or 0) > 0]
                        if not atts:
                            # regola di scelta senza elenco («12 CFU A SCELTA»): una voce a scelta con i CFU dell'etichetta,
                            # salvo che l'elenco della stessa scelta sia in un altro gruppo dell'anno
                            cfu_g = _cfu_etichetta(g.get("label_it"))
                            if g.get("cod") == "OO" or not cfu_g or _elenco_altrove(g, gruppi_a):
                                continue
                            if not re.search(r"(?i)scel|select", g.get("label_it") or ""):
                                continue
                            nome_r = _nome_regola(g.get("label_it") or "")
                            key = f"{k}:#{_norm(nome_r)}:{cfu_g[1]:g}"
                            st = stati.setdefault(key, {})
                            st[pcur] = st.get(pcur, False)
                            if key not in insegnamenti:
                                insegnamenti[key] = {
                                    "codice": None, "nome": nome_r, "anno": k, "periodo": None, "cfu": cfu_g[1], "ssd": None,
                                    "obbligatorio": False, "curriculum": None, "docenti": [],
                                    "url": f"{base}/corsi/{y}/{x['cod']}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi}
                            continue
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            obbl = _obbligatorio(g, att, atts)
                            key = f"{k}:{ad}:{att.get('crediti'):g}"  # stesso codice con CFU diversi nei percorsi: righe distinte
                            st = stati.setdefault(key, {})
                            st[pcur] = st.get(pcur, False) or obbl
                            if key in insegnamenti:
                                continue
                            docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                            item = {
                                "codice": ad, "nome": _nome_attivita(att), "anno": k,
                                "periodo": _periodo(att.get("periodo_didattico_it")),
                                "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                "periodo_fine": att.get("data_fine_periodo_didattico"),
                                "cfu": att.get("crediti"), "ssd": None,
                                "obbligatorio": False, "curriculum": None,
                                "docenti": sorted(set(docenti)),
                                "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                       f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                                "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                            }
                            insegnamenti[key] = item
                            if syllabus:
                                registra_syllabus(att, y, ad, item)
        # AFS e internati elettivi dalle pagine ufficiali: una riga a scelta per ogni anno in cui si possono frequentare
        for a in afs or []:
            ey, att = pool_att.get(a["codice"], (None, None))
            for k in a["anni"]:
                if str(k) not in piano_anni:  # anno senza piano
                    continue
                key = f"{k}:{a['codice']}:{a['cfu']:g}"
                st = stati.setdefault(key, {})
                st[None] = False
                if key in insegnamenti:
                    continue
                item = {
                    "codice": a["codice"], "nome": _nome_afs(a, att), "anno": k, "periodo": a["periodo"],
                    "cfu": a["cfu"], "ssd": a["ssd"], "obbligatorio": False, "curriculum": None,
                    "docenti": sorted(set(a["docenti"])),
                    "url": (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}"
                            f"/{att.get('corso_percorso_id')}?coorte={ey}") if att else a["fonte"],
                    "libri": [], "esami": [], "fonte": a["fonte"], "verificato_il": oggi,
                }
                insegnamenti[key] = item
                if syllabus and att:
                    registra_syllabus(att, ey, a["codice"], item)
        for (cds_c, anno_c), regole in CORREZIONI.items():
            if cds_c != catena[0]:
                continue
            for key, item in list(insegnamenti.items()):
                regola = regole.get(item.get("codice") or item["nome"]) if item["anno"] == anno_c else None
                if regola == "escludi":
                    del insegnamenti[key]
                elif regola in ("scelta", "obbligatorio"):
                    for c_ in stati[key]:
                        stati[key][c_] = regola == "obbligatorio"
                elif regola and regola.startswith("cfu="):
                    item["cfu"] = int(regola[4:])
        ins = []
        for key, item in insegnamenti.items():
            tutti = tutti_anno.get(item["anno"]) or set()
            st = stati[key]
            if not tutti:  # nessun curriculum: un'unica riga, obbligatoria se lo è in un gruppo
                valore = {None: any(st.values())}
            else:  # il percorso comune vale per tutti i curricula, gli specifici solo per sé
                valore = {c_: st.get(None, False) or st.get(c_, False) for c_ in tutti if None in st or c_ in st}
            per_valore: dict[bool, set] = {}
            for c_, v in valore.items():
                per_valore.setdefault(bool(v), set()).add(c_)
            for v, cur_set in sorted(per_valore.items(), reverse=True):
                riga = dict(item)
                riga["obbligatorio"] = v
                # senza curriculum se vale per tutti (con una sola riga); con due righe ognuna porta i suoi curricula
                riga["curriculum"] = None if (not tutti or (cur_set == tutti and len(per_valore) == 1)) \
                    else ", ".join(sorted(cur_set))
                riga["_orig"] = item
                ins.append(riga)
        # stesso nome nello stesso anno con codici e CFU diversi (alternative omonime): il nome porta i CFU
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if len({i["cfu"] for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            else:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['codice']})"
        # voci senza codice (regole di scelta) con CFU diversi nello stesso anno (curricula diversi): build_db le unirebbe per
        # nome, quindi il nome porta i CFU
        regole: dict[tuple, list] = {}
        for i in ins:
            if not i["codice"]:
                regole.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
        for gruppo_i in regole.values():
            if len({i["cfu"] for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        out = {
            "id_universitaly": id_ul,
            "nome": _titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec_d.get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(cur),
            "codice_ateneo": catena[0],
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        return out

    def build_safe(r: tuple[str, tuple[str, ...]]) -> dict | None:
        try:
            return build(*r)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {r[1][0]} saltato: {e!r}")
            return None

    elenco = CORSI[:max_cds] if max_cds else CORSI
    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, elenco):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        noto = libri_noti.get(job.get("codice"))
        if noto and noto.get("libri"):  # libri già raccolti per questo codice: non si rileggono
            for it in job["items"]:
                it["libri"] = noto["libri"]
                it["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        it[k_] = noto[k_]
            return len(noto["libri"])
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            sy = {}
        libri, modalita, legati = cc._testi_syllabus(sy) if sy else ([], None, [])
        if not libri and sy:  # testi in forma libera
            libri = libri_testo_libero(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cc.leganto.libri(u)
        nota = None
        if not libri:  # scheda di un'altra coorte o di un altro a.a. dello stesso insegnamento (con la fonte)
            for att, y_ in job.get("alt") or []:
                sy2 = c.get("/insegnamento", {k: v for k, v in {
                    "anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                    "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y_,
                    "schema_id": att.get("schemaId")}.items() if v not in (None, "")})
                if not isinstance(sy2, dict):
                    continue
                l2, m2, g2 = cc._testi_syllabus(sy2)
                l2 = l2 or libri_testo_libero(sy2)
                if not l2:
                    for u in g2:
                        l2 += cc.leganto.libri(u)
                if l2:
                    aa = int(att.get("aa"))
                    url = (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}"
                           f"/{att.get('corso_percorso_id')}?coorte={y_}")
                    nota = f"Dal programma dell'a.a. {aa}/{(aa + 1) % 100:02d} dello stesso insegnamento ({url})"
                    libri, modalita, sy = l2, modalita or m2, {**sy2, **{k: v for k, v in sy.items() if v}}
                    break
        if nota:
            libri = [{**b, "note": ((b.get("note") + " | ") if b.get("note") else "") + nota} for b in libri]
        ssd = sy.get("ssd")
        for it in job["items"]:
            it["libri"] = libri
            it["stato_libri"] = "completo" if libri else "da_aggiungere"
            if modalita:
                it["modalita_esame"] = modalita
            if ssd and not it.get("ssd"):
                it["ssd"] = ssd
            if sy.get("urlSitoWeb"):
                it["url_sito"] = sy["urlSitoWeb"].strip()
        return len(libri)

    trovati = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, syllabus_jobs.values()), 1):
            trovati += n
            if i % 500 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    for corso_ in corsi_out:
        for riga in corso_["insegnamenti"]:
            orig = riga.pop("_orig", None)
            if orig is not None:
                for k_ in ("libri", "stato_libri", "modalita_esame", "ssd", "url_sito"):
                    if k_ in orig:
                        riga[k_] = orig[k_]
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca) e dalle pagine AFS di uniroma4.it"
                                                  " (adapters/uniroma4.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "uniroma4.json", ROOT / "database" / "contrib" / "auto" / "uniroma4_syl_b2.json"):
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            for i in corso.get("insegnamenti") or []:
                cod = i.get("codice")
                if cod and i.get("libri") and cod not in out:
                    out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def fetch_ateneo(uid: str = "uniroma4", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "uniroma4.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[uniroma4] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
