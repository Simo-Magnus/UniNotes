"""Università Mediterranea di Reggio Calabria (UniRC): piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unirc.coursecatalogue.cineca.it` (API pubblica, coorti 2022-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`): con i riordini 2024 e 2025 i codici del catalogo sono cambiati («87.L»
  <- «86.L», «L7-R» <- «57.L» <- «56.L», «010MR» <- «010M», ...) e le coorti precedenti restano sotto il codice vecchio. Per
  l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno) del codice più recente
  che ha il piano di quell'anno (catena di codici); se la coorte non ha quell'anno si usa la più vicina che lo ha;
- durata dal piano («5 anni»): l'elenco minimale delle coorti non la dà (con l'adattatore comune i cicli unici di cinque anni
  restavano con i soli primi tre anni e le magistrali a 3);
- «86.L» (Ingegneria informatica, elettronica e delle telecomunicazioni, coorti fino al 2024) è il corso padre di due corsi
  attuali: il percorso «Elettronica e Biomedica» va a L-8 Elettronica e biomedica, gli altri a L-8 Informatica e delle
  telecomunicazioni (deduzione dai nomi, `FILTRI_PERCORSI`);
- gruppi del piano (`cod`): «OO» obbligatori; «F», «G», «W» scelte o blocchi fissi (un'attività è obbligatoria se sta in «OO», o
  se è l'unica del gruppo senza una scelta nell'etichetta); «S» regola di scelta libera senza elenco («12 CFU A SCELTA»,
  «SELECT 18 CFU»: la regola diventa una voce a scelta con i CFU dell'etichetta; senza CFU nell'etichetta non c'è niente da
  contare). Un gruppo «W» vuoto («… (Min 12 - Max 12) (12 CFU)») che ha l'elenco in un altro gruppo «W» dello stesso anno è la
  stessa scelta scritta due volte;
- attività a 0 CFU (OFA, prove di lingua senza crediti) non sono insegnamenti del piano;
- percorsi: «comune» (nome «comune», «percorso comune») vale per tutti i curricula; gli altri si riconoscono per nome (con gli
  alias di `ALIAS_PERCORSI` per i refusi del catalogo). Lo stesso codice con CFU diversi in percorsi diversi resta su righe distinte.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/unirc.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unirc.py [--senza-syllabus]
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

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .uniba import libri_testo_libero  # noqa: E402

BASE = "https://unirc.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L", "LM", "LM5"}  # lauree, magistrali e ciclo unico di cinque anni (non le lauree sanitarie senza piano)

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio).
# I codici più vecchi sono il vecchio ordinamento dello stesso corso (le coorti precedenti).
CORSI: list[tuple[str, tuple[str, ...]]] = [
    ("1625443", ("L-2 R-BS",)),                    # Biotecnologie per la sostenibilità (L-2, nuovo 2026)
    ("1628817", ("L4R2025", "L4GEN")),             # Design (L-4)
    ("1628818", ("L7-R", "57.L", "56.L")),         # Ingegneria civile e ambientale per lo sviluppo sostenibile (L-7)
    ("1628819", ("87.L", "86.L")),                 # Ingegneria elettronica e biomedica (L-8), già percorso di «86.L»
    ("1628820", ("L9R-GES", "L9GEST")),            # Ingegneria gestionale (L-9)
    ("1628814", ("87LR", "86.L")),                 # Ingegneria informatica e delle telecomunicazioni (L-8), già «86.L»
    ("1628821", ("L9MEC",)),                       # Ingegneria meccanica (L-9)
    ("1628822", ("L19", "L19GEN")),                # Scienze dell'educazione e della formazione (L-19)
    ("1628825", ("14.LR", "14.L")),                # Scienze e tecnologie agrarie (L-25)
    ("1628826", ("72.LR", "72.L")),                # Scienze e tecnologie alimentari e gastronomiche (L-26)
    ("1628827", ("80.LR", "80.L")),                # Scienze economiche (L-33)
    ("1628824", ("15.LR", "15.L")),                # Scienze forestali e ambientali (L-25)
    ("1628823", ("L22RN", "L22R")),                # Scienze motorie e diritto dello sport (L-22)
    ("1628830", ("LM12R2025", "LM12")),            # Design per le culture mediterranee (LM-12)
    ("1628834", ("3057R", "3057")),                # Economia (LM-56)
    ("1628837", ("15.MR", "15.M")),                # Gestione sostenibile del territorio forestale e montano (LM-73)
    ("1628831", ("LM23R", "5023")),                # Ingegneria civile (LM-23)
    ("1628815", ("LM29R", "LM-29GEN")),            # Ingegneria elettronica e biomedica (LM-29)
    ("1628829", ("86.M", "85.M")),                 # Ingegneria informatica e dei sistemi per le telecomunicazioni (LM-27)
    ("1628832", ("LM30-35R", "LM30GEN", "LM35GEN")),  # Ingegneria per la gestione sostenibile dell'ambiente e dell'energia (LM-30/LM-35)
    ("1628833", ("LM50R", "LM50")),                # Progettazione pedagogica e gestione dei servizi educativi per i minori (LM-50)
    ("1628836", ("72.MR", "72.M")),                # Scienze della qualità e sicurezza dei prodotti alimentari (LM-70)
    ("1628835", ("14.MR", "14.M")),                # Scienze delle produzioni agrarie mediterranee (LM-69)
    ("1628838", ("LM-4R2025", "AR.M")),            # Architettura (LM-4 c.u., 5 anni)
    ("1628828", ("010MR", "010M")),                # Giurisprudenza (LMG/01, 5 anni)
    ("1628816", ("2018",)),                        # Scienze della formazione primaria (LM-85 bis, 5 anni)
]

# «86.L» (coorti 2022-2024) contiene i percorsi di due corsi attuali: (codice del corso di Universitaly, codice del catalogo)
# → codici dei percorsi (`pdsCod`) che gli appartengono. Deduzione dai nomi: «Elettronica e Biomedica» -> L-8 Elettronica e
# biomedica; «Homeland Security», «Internet e Cybersecurity», «Generale» -> L-8 Informatica e delle telecomunicazioni.
FILTRI_PERCORSI: dict[tuple[str, str], set[str]] = {
    ("87.L", "86.L"): {"1"},
    ("87LR", "86.L"): {"2", "3", "4"},
}

# CFU delle regole di scelta libera («Insegnamenti a scelta», «A scelta libera dello studente») che nel piano del catalogo non
# hanno i CFU nell'etichetta: letti dalla tabella del piano di studio del regolamento didattico ufficiale della stessa coorte
# («altre attività a scelta / A scelta dello studente 12»). (codice del corso, anno di corso) → ({curriculum normalizzato o
# «*» per tutti: CFU}, regolamento)
_REG = "https://www.unirc.it/sites/default/files/"
CFU_SCELTA_REGOLAMENTO: dict[tuple[str, int], tuple[dict[str, int], str]] = {
    # L-7, coorte 2024 (regolamento 2024/25, Allegato 1: «altre attività a scelta», 3° anno)
    ("L7-R", 3): ({"civile": 12, "infrastrutture di trasporto": 12, "ambientale": 12, "civil engineering": 18},
                  _REG + "2025-05/Regolamento%20L7.pdf"),
    # L-9 Gestionale, coorte 2024 (regolamento 2024/25, III anno, «A scelta dello studente 12» in tutti i curricula)
    ("L9R-GES", 3): ({"*": 12}, _REG + "2025-05/Regolamento%20L9.pdf"),
    # L-9 Meccanica, coorte 2024 (regolamento 2024/25, III anno, «A scelta dello studente 12»)
    ("L9MEC", 3): ({"*": 12}, _REG + "2025-05/Ingegneria%20Meccanica%20%28L9%29%20Regolamento%20didattico%202024-2025%20con%20schede.pdf"),
    # LM-23, coorte 2026 (regolamento 2026/27, 1° anno: «Attività formative a scelta dello studente» 18 CFU)
    ("LM23R", 1): ({"*": 18}, _REG + "2026-06/Regolamento%20didattico%20LM23R%20A.A.%202026-2027.pdf"),
}

# Percorsi che il catalogo scrive in modo diverso tra le coorti (refusi): chiave normalizzata del nome → nome del curriculum
ALIAS_PERCORSI = {
    "intelligente trasportation systems": "Intelligent Transportation Systems",
    "21 intelligent trasportation systems": "Intelligent Transportation Systems",
    "reti e applicazioni": "Reti ed applicazioni",
    "internet e cybersecurity": "Internet & Cybersecurity",
    "economico": "Economico - aziendale",  # Scienze economiche: «Economico» della coorte 2024 -> «Economico - aziendale» dal 2025
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
_SIGLE = {"ADE", "OPZ", "TPV", "DNA", "RNA", "IT", "AI", "ICT", "IOT", "CAD", "CAM", "PCR", "ECG", "EEG", "TC", "RM", "STEM",
          "MRI", "OFA", "GIS", "BIM", "JAU", "CCNA", "CCNA1", "CCNA2", "CCNA3", "CFU", "UX", "UI", "XML", "HTML", "SQL", "ECTS", "GPS",
          "LCA", "VR", "AR", "DSP"}
_CREDITI_LIBERI = {"a scelta", "a libera scelta", "attivita libera", "attivita a scelta", "attivita a libera scelta"}
_SCELTA = re.compile(r"(?i)scelt|opzion|alternativ|elective|elettiv|optional|oppure|\btra\b|\bfra\b|\bor\b|among|betwee?n|\bone\b")
_CFU_ETICHETTA = re.compile(r"(?:\(\s*)?(?:(?:fra|tra)\s+([\d.,]+)\s+e\s+)?(?<![\w.,])([\d.,]*\d)\s*(?:CFU|crediti)\b(?:\s*\))?", re.I)
_COMUNE = re.compile(r"(?i)\bcomun[ie]\b|\bgeneric[oa]\b")
_ROMANO = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6}
_PERIODI = {"primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale",
            "primo semestre": "1", "secondo semestre": "2", "annuale": "annuale"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _titolo(des: str | None) -> str:
    """Nome dell'attività: maiuscolo del catalogo → iniziali maiuscole (sigle e numeri romani restano)."""
    des = re.sub(r"\s+", " ", des or "").strip()
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
    return re.sub(r"(?i)\bccna(\d)", lambda m: "CCNA" + m.group(1), nome)


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return _PERIODI.get(re.sub(r"\s+", " ", s.lower()).strip(), s.strip())


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unirc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unirc" if d else None

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
    if _a_scelta_studente(att) and re.search(r"(?i)\bscelta\b|\bADE\b", att.get("des_it") or ""):
        return False  # «A libera scelta», crediti liberi del catalogo: a scelta anche dentro «Obbligatori» (non un tirocinio o
        # un corso che ha solo la tipologia «A scelta dello studente»)
    if g.get("cod") == "OO":
        return True
    if g.get("cod") == "W":  # attività a libera scelta «fra 1 e N CFU»
        return False
    # blocchi F/G: un'unica attività senza scelta nell'etichetta («Stage» con una sola attività) è obbligatoria; i blocchi
    # di alternative (stage interno/esterno/estero, «Choose two courses», «Attività formative a scelta») sono a scelta
    return len(atts) == 1 and not _SCELTA.search(g.get("label_it") or "")


def _vale(a: dict, k: int, g: dict | None, coorte: int, durata: int) -> bool:
    """Il gruppo `g` dell'anno `a` del piano vale per l'anno di corso k."""
    if not str(a.get("anno")).isdigit():
        return False
    n = int(a["anno"])
    if n == 0:
        return g is not None and _anno_gruppo0(g, coorte, durata) == k
    return n == k


def _ha_anno(det: dict, k: int, coorte: int, durata: int) -> bool:
    """Il piano ha attività con CFU per l'anno di corso k."""
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            for g in _gruppi(a):
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
    nome = re.sub(r"\(Lm-(\d+)\)", lambda m: f"(LM-{m.group(1)})", nome)
    nome = re.sub(r"\s*,\s*", " - ", nome)
    nome = nome[:1].upper() + nome[1:]
    return ALIAS_PERCORSI.get(_norm(nome), nome)


def _lettera(p: dict) -> str | None:
    m = re.match(r"PDS([A-Z])", (p.get("pdsCod") or "").strip())
    return m.group(1) if m else None


def _comune(p: dict) -> bool:
    """Percorso comune a tutti: dal nome («comune», «percorso generico»). Il flag «comune» del catalogo e il codice «PDS0…»
    non bastano: i curricula di Bioscienze e Biotecnologia hanno tutti lo stesso codice «PDS0-2025» e il flag."""
    return bool(_COMUNE.search(p.get("des_it") or p.get("pdsDes") or ""))


def _elenco_altrove(g: dict, gruppi: list[dict]) -> bool:
    """Un altro gruppo dello stesso anno e dello stesso tipo ha l'elenco delle attività (con CFU) di questa scelta: la regola
    senza elenco («… (Min 12 - Max 12) (12 CFU)») è la stessa scelta scritta due volte."""
    return any(h is not g and h.get("cod") == g.get("cod") and any((t.get("crediti") or 0) > 0 for t in h.get("attivita") or [])
               for h in gruppi)


def _nome_regola(label: str) -> str:
    """Nome della voce a scelta di una regola senza elenco: le regole «a scelta» sono attività a scelta dello studente."""
    lab = _CFU_ETICHETTA.sub(" ", label or "")
    if re.search(r"(?i)scel|scle|select", lab):
        return "Attività formative a scelta dello studente"
    nome = re.sub(r"\s+", " ", lab).strip(" -–:/,()")
    return nome[:1].upper() + nome[1:].lower()


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
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
                if d and (catena[0], cod) in FILTRI_PERCORSI:  # percorsi di un altro corso attuale: tolti
                    d = {**d, "percorsi": [p for p in d.get("percorsi") or []
                                           if p.get("pdsCod") in FILTRI_PERCORSI[(catena[0], cod)]]}
                if d:
                    lst.append((x, d))
            if lst:
                cohorts[y] = lst
        if not cohorts:
            return None
        cur = coorti[anno].get(catena[0]) or next(iter(cohorts[max(cohorts)]))[0]
        rec_x, rec_d = (cohorts.get(anno) or cohorts[max(cohorts)])[0]
        durata = _durata(rec_d, rec_x.get("tipo_corso_cod"))
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
                    if _ha_anno(d, k, y, durata):
                        return y, x, d
            return None

        # nome canonico dei percorsi: quello della coorte più recente che li ha, per nome (senza maiuscole e punteggiatura) o,
        # nei corsi in cui la lettera del codice («PDSA», «PDSB») indica sempre lo stesso curriculum, per lettera
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
        for y, lst in cohorts.items():
            for _x, d in lst:
                for p in d.get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in _gruppi(a):
                            for t in g.get("attivita") or []:
                                alt_per_ad.setdefault(t.get("adCod") or t.get("cod"), {})[(str(t.get("aa")), str(t.get("cod")))] = (y, t)

        insegnamenti: dict[str, dict] = {}
        stati: dict[str, dict[str | None, bool]] = {}  # (anno:codice) → {curriculum o None se comune: obbligatorio}
        percorsi_nomi: set[str] = set()
        piano_anni: dict[str, dict] = {}
        tutti_anno: dict[int, set] = {}
        for k in range(1, durata + 1):
            sc = piano(k)
            if not sc:
                continue
            y, x, d = sc
            piano_anni[str(k)] = {"coorte": y, "url": f"{base}/corsi/{y}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(_vale(a, k, g, y, durata) for a in p.get("anni") or [] for g in _gruppi(a))]
            comuni = [p for p in percorsi_k if _comune(p)]
            specifici = [p for p in percorsi_k if not _comune(p)]
            if len(percorsi_k) == 1 or len({nome_percorso(p) for p in specifici}) < 2:
                comuni, specifici = percorsi_k, []  # un solo percorso: vale per tutti
            tutti_anno[k] = {nome_percorso(p) for p in specifici}
            percorsi_nomi |= tutti_anno[k]
            for p in percorsi_k:
                pcur = None if p in comuni else nome_percorso(p)
                for a in p.get("anni") or []:
                    gruppi_a = _gruppi(a)
                    for g in gruppi_a:
                        if not _vale(a, k, g, y, durata):
                            continue
                        atts = [t for t in g.get("attivita") or [] if (t.get("crediti") or 0) > 0]
                        if not atts:
                            # regola di scelta senza elenco («12 CFU A SCELTA», «SELECT 18 CFU»): una voce a scelta con i CFU
                            # dell'etichetta, salvo che l'elenco della stessa scelta sia in un altro gruppo dell'anno
                            cfu_g = _cfu_etichetta(g.get("label_it"))
                            fonte_r = base
                            if not cfu_g and g.get("cod") == "S" and re.search(r"(?i)scelt", g.get("label_it") or ""):
                                reg = CFU_SCELTA_REGOLAMENTO.get((catena[0], k))
                                v = reg and (reg[0].get(_norm(pcur or "")) or reg[0].get("*"))
                                if v:
                                    cfu_g, fonte_r = (v, v), reg[1]
                            if g.get("cod") == "OO" or not cfu_g or _elenco_altrove(g, gruppi_a):
                                continue
                            nome_r = _nome_regola(g.get("label_it") or "")
                            key = f"{k}:#{_norm(nome_r)}:{cfu_g[1]:g}"
                            st = stati.setdefault(key, {})
                            st[pcur] = st.get(pcur, False)
                            if key not in insegnamenti:
                                insegnamenti[key] = {
                                    "codice": None, "nome": nome_r, "anno": k, "periodo": None, "cfu": cfu_g[1], "ssd": None,
                                    "obbligatorio": False, "curriculum": None, "docenti": [],
                                    "url": fonte_r if fonte_r != base else f"{base}/corsi/{y}/{x['cod']}",
                                    "libri": [], "esami": [], "fonte": fonte_r, "verificato_il": oggi}
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
                riga["curriculum"] = None if (not tutti or (cur_set == tutti and len(per_valore) == 1))                     else ", ".join(sorted(cur_set))
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
                periodi = [i["periodo"] for i in gruppo_i]
                for i in gruppo_i:
                    if all(periodi) and len(set(periodi)) == len(periodi):
                        p = str(i["periodo"])
                        i["nome"] = f"{i['nome']} ({p}° semestre)" if p in ("1", "2") else f"{i['nome']} ({p})"
                    else:
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
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
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
            if ssd:
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unirc.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "unirc.json", ROOT / "database" / "contrib" / "auto" / "unirc_syl_b2.json"):
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


def fetch_ateneo(uid: str = "unirc", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unirc.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unirc] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
