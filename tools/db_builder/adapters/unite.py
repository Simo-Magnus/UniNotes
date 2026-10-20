"""Università degli Studi di Teramo (UniTE): piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unite.coursecatalogue.cineca.it` (API pubblica, coorti 2020-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`): con il riordino del 2025 i codici del catalogo sono cambiati («65» >
  «99», «46» > «108», «86» > «118», ...) e le coorti precedenti restano sotto il codice vecchio; «Politiche internazionali e
  della sostenibilità» ha avuto tre codici («84» > «92» > «113»). Per l'anno di corso k nell'a.a. A si legge il piano della
  coorte A-k+1 (gli iscritti oggi al k-esimo anno) del codice più recente che lo ha; se la coorte non ha quell'anno (corsi
  nuovi: Biotechnology dal 2025, Business Management dal 2026) si usa la più vicina che lo ha;
- durata dal piano («5 anni»): l'elenco minimale delle coorti non la dà (con l'adattatore comune Medicina veterinaria e
  Giurisprudenza avevano solo i primi tre anni);
- «Giurisprudenza (sede Avezzano)» (codici «109» > «502») è il corso «Giurisprudenza REPLICA AVEZZANO» di Universitaly: il
  piano si associa a quel corso (id Universitaly) e non a un corso nuovo; la sede è Avezzano (`altreSedi` del catalogo);
- gruppi del piano (`cod`): «OO» obbligatori; «F» e «W» scelte o blocchi fissi (un'attività è obbligatoria se sta in «OO», o se è
  l'unica del gruppo senza una scelta nell'etichetta, come il «Corso sicurezza» da 2 CFU); «S» sono regole di scelta libera senza
  elenco («ATTIVITA' DIDATTICHE A SCELTA EROGATE DA ALTRI CORSI (6 CFU)»): l'elenco con i CFU è nel gruppo «F»/«W» accanto, quindi
  non diventano voci. Le voci «A scelta dello studente», «Esame a scelta» dentro «OO» sono crediti liberi: a scelta;
- attività a 0 CFU (OFA di matematica, biologia, comprensione del testo, ...) non sono insegnamenti del piano (i requisiti di
  accesso sono in `ammissione`); il «Semestre filtro» di Medicina veterinaria (tipo «SFM», 18 CFU a parte) non è un corso;
- percorsi: nomi ripuliti da «PIANO DI STUDIO COORTE 2024», «AD III ANNO COORTE 2022», ... e riportati allo stesso nome tra le
  coorti (`CURRICULA`); i nomi in codice del 2026 («SG_1», «SC_AMM_2», «BA_GENETICA A») sono riconosciuti dal contenuto (stesse
  attività della coorte precedente: deduzione, vedi `CURRICULA`);
- stessa attività con CFU diversi nello stesso anno in percorsi diversi: due righe con id proprio (`-<cfu>cfu`) e il nome con «(N CFU)».

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/unite.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unite.py [--senza-syllabus]
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

BASE = "https://unite.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5"}  # lauree, magistrali e ciclo unico di cinque anni (non il «Semestre filtro» SFM)

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, id del corso nel database, codici del catalogo dal più recente al
# più vecchio). I codici più vecchi sono il vecchio ordinamento dello stesso corso (le coorti precedenti).
CORSI: list[tuple[str, str, tuple[str, ...]]] = [
    ("1631140", "unite-l-2-biotechnology", ("95",)),                             # Biotechnology (L-2, in inglese, dal 2025)
    ("1631139", "unite-l-2-biotecnologie", ("96", "83")),                        # Biotecnologie (L-2)
    ("1626160", "unite-l-18-business-management", ("120",)),                     # Business Management (L-18, nuovo 2026)
    ("1631142", "unite-l-14-diritto-dell-ambiente-e-dell-energia", ("98", "93")),  # Diritto dell'ambiente e dell'energia (L-14, Lanciano)
    ("1631141", "unite-l-3-discipline-delle-arti-della-musica-e-dello-spettacolo", ("97", "80")),  # DAMS (L-3)
    ("1631144", "unite-l-18-economia", ("101", "69")),                           # Economia (L-18)
    ("1631147", "unite-l-26-scienze-e-tecnologie-alimentari", ("103", "53")),    # Scienze e tecnologie alimentari (L-26)
    ("1631145", "unite-l-20-scienze-e-tecnologie-della-comunicazione", ("102", "75")),  # (L-20, già Scienze della comunicazione)
    ("1631150", "unite-l-gastr-scienze-gastronomiche-per-la-sostenibilita", ("107", "2005")),  # Scienze gastronomiche (L/GASTR)
    ("1631148", "unite-l-36-scienze-politiche", ("105", "55")),                  # Scienze politiche (L-36)
    ("1631143", "unite-l-14-servizi-giuridici", ("99", "65")),                   # Servizi giuridici (L-14)
    ("1630499", "unite-l-15-turismo-sostenibile", ("100", "90")),                # Turismo sostenibile (L-15)
    ("1631149", "unite-l-38-tutela-e-benessere-animale", ("106", "66")),         # Tutela e benessere animale (L-38)
    ("1631146", "unite-l-26-viticoltura-ed-enologia", ("104", "54")),            # Viticoltura ed enologia (L-26)
    ("1631152", "unite-lm-9-biotecnologie-avanzate", ("110", "2006")),           # Biotecnologie avanzate (LM-9)
    ("1631155", "unite-lm-59-comunicazione-marketing-e-innovazione-digitale", ("119", "88")),  # (LM-59, già Comunicazione per la gestione delle organizzazioni)
    ("1631161", "unite-lm-sc-giur-lm-77-diritto-economia-e-strategia-d-impresa", ("118", "86")),  # Diritto, economia e strategia d'impresa
    ("1631159", "unite-lm-70-food-science-and-technology", ("116", "81")),       # Food Science and Technology (LM-70)
    ("1631158", "unite-lm-65-media-arti-culture-e-spettacolo", ("115", "87")),   # Media, arti, culture e spettacolo (LM-65)
    ("1631156", "unite-lm-62-politiche-internazionali-e-della-sostenibilita", ("113", "92", "84")),  # (LM-62, già Scienze politiche internazionali)
    ("1631153", "unite-lm-9-reproductive-biotechnologies", ("111", "82")),       # Reproductive Biotechnologies (LM-9)
    ("1631157", "unite-lm-63-scienze-delle-amministrazioni", ("114", "78")),     # Scienze delle amministrazioni (LM-63)
    ("1631160", "unite-lm-86-scienze-delle-produzioni-animali-sostenibili", ("117", "85")),  # (LM-86)
    ("1631151", "unite-lmg-01-giurisprudenza", ("108", "46")),                   # Giurisprudenza (LMG/01, 5 anni)
    ("1631162", "unite-lmg-01-giurisprudenza-replica-avezzano", ("109", "502")),  # Giurisprudenza, sede Avezzano (5 anni)
    ("1631154", "unite-lm-42-medicina-veterinaria", ("112", "67")),              # Medicina veterinaria (LM-42, 5 anni)
]

_P = "Pubblica amministrazione - lavoratori"
# Nomi dei percorsi: per corso (primo codice della catena), chiave normalizzata del nome ripulito → nome canonico. Il catalogo
# scrive lo stesso percorso in modo diverso tra le coorti («SERVIZI GIURIDICI - CARRIERE AMMINISTRATIVA», «CARRIERE
# AMMINISTRATIVE»). I nomi in codice del 2026 sono riconosciuti dal contenuto: il percorso ha le stesse attività (codici di
# insegnamento) di un percorso della coorte precedente (sovrapposizione massima e maggiore delle altre) e lo stesso numero di
# percorso della coorte 2024: «SG_1» = Consulenti del lavoro, «SG_2» = Carriere amministrative, «SG_3» = Criminologia;
# «SC_AMM_1/2/4» = Politiche pubbliche, Management pubblico, Innovazione in sanità (3 per esclusione = Sicurezza pubblica);
# «BA_GENETICA A» = Genomica applicata, «BA_PROTEOMICA» = Proteomica e metabolomica; «E_GESTORE DEL PATRIMONIO IMM» (IMM è
# l'abbreviazione del catalogo) = Gestore del patrimonio immobiliare. Deduzioni, non lette dalla fonte.
CURRICULA: dict[str, dict[str, str]] = {
    "105": {  # Scienze politiche
        "internazionale ed europeo": "Internazionale ed europeo", "sc pol percorso internazionale": "Internazionale ed europeo",
        "politiche per il terzo settore e il non profit": "Politiche per il terzo settore e il non-profit",
        "sc pol percorso politiche per il terzo sett": "Politiche per il terzo settore e il non-profit",
        "pubblica amministrazione": "Pubblica amministrazione", "sc pol percorso pub amm": "Pubblica amministrazione",
        "pubblica amministrazione lavoratori": _P, "sc pol percorso pubblica amministrazione": _P,
    },
    "99": {  # Servizi giuridici
        "carriere amministrative": "Carriere amministrative", "servizi giuridici carriere amministrativa": "Carriere amministrative",
        "sg 2": "Carriere amministrative",
        "consulenti del lavoro e delle relazioni aziendali": "Consulenti del lavoro e delle relazioni aziendali",
        "servizi giuridici consulenti del lavoro": "Consulenti del lavoro e delle relazioni aziendali",
        "sg 1": "Consulenti del lavoro e delle relazioni aziendali",
        "criminologia e tecniche investigative e della sicurezza": "Criminologia e tecniche investigative e della sicurezza",
        "servizi giuridici criminologia": "Criminologia e tecniche investigative e della sicurezza",
        "sg 3": "Criminologia e tecniche investigative e della sicurezza",
    },
    "101": {  # Economia
        "economia consulenti finanziario": "Consulente finanziario", "percorso consulente finanziario": "Consulente finanziario",
        "consulente finanziario": "Consulente finanziario", "e consulente f": "Consulente finanziario",
        "economia economico gestionale": "Economico gestionale", "percorso economico gestionale": "Economico gestionale",
        "economico gestionale": "Economico gestionale", "e ec gestionale": "Economico gestionale",
        "e gestore del patrimonio imm": "Gestore del patrimonio immobiliare",
    },
    "102": {  # Scienze e tecnologie della comunicazione
        "scom com media e informazione": "Comunicazione, media e informazione",
        "comunicazione media e informazione": "Comunicazione, media e informazione",
        "scom comunicazione d impresa": "Comunicazione d'impresa e marketing",
        "comunicazione d impresa e marketing": "Comunicazione d'impresa e marketing",
        "scom comunicazione e ia": "Comunicazione e intelligenza artificiale",
        "comunicazione e intelligenza artificiale": "Comunicazione e intelligenza artificiale",
        # coorte 2024 (vecchio ordinamento «Scienze della comunicazione»), nomi propri
        "comunicazione per l azienda ed il commercio": "Comunicazione per l'azienda ed il commercio",
        "media e le piattaforme digitali": "Media e le piattaforme digitali",
    },
    "114": {  # Scienze delle amministrazioni
        "politiche pubbliche e governance": "Politiche pubbliche e governance",
        "percorso politiche pubbliche e governance": "Politiche pubbliche e governance",
        "scienze delle amministrazioni politiche pubbliche e governance": "Politiche pubbliche e governance",
        "sc amm 1": "Politiche pubbliche e governance",
        "management pubblico": "Management pubblico", "scienze delle amministrazioni management pubblico": "Management pubblico",
        "sc amm 2": "Management pubblico",
        "sicurezza pubblica e criminalita": "Sicurezza pubblica e criminalità",
        "sicurezza pubblica e criminialita": "Sicurezza pubblica e criminalità",
        "scienze delle amministrazioni sicurezza pubblica e criminalita": "Sicurezza pubblica e criminalità",
        "sc amm 3": "Sicurezza pubblica e criminalità",
        "innovazione e digitalizzazione in sanita": "Innovazione e digitalizzazione in sanità",
        "scienze delle amministrazioni innovazione e dig in sanita": "Innovazione e digitalizzazione in sanità",
        "sc amm 4": "Innovazione e digitalizzazione in sanità",
    },
    "96": {  # Biotecnologie
        "biotecnologie molecolari e cellulari": "Biotecnologie molecolari e cellulari",
        "biotecnologie degli alimenti": "Biotecnologie degli alimenti",
    },
    "118": {  # Diritto, economia e strategia d'impresa
        "lm 77 imprenditorialita e servizi": "LM-77 - Imprenditorialità e servizi", "lm 77 imp e servizi": "LM-77 - Imprenditorialità e servizi",
        "desi lm 77 imp": "LM-77 - Imprenditorialità e servizi",
        "lm 77 innovazione": "LM-77 - Innovazione", "desi lm 77 inn": "LM-77 - Innovazione",
        "lm sc giur imprenditorialita e servizi": "LM-SC/GIUR - Imprenditorialità e servizi",
        "lm sc giur imp e servizi": "LM-SC/GIUR - Imprenditorialità e servizi", "desi lm sc imp": "LM-SC/GIUR - Imprenditorialità e servizi",
        "lm sc giur innovazione": "LM-SC/GIUR - Innovazione", "desi lm sc inn": "LM-SC/GIUR - Innovazione",
    },
    "110": {  # Biotecnologie avanzate
        "percorso genomica applicata": "Genomica applicata", "genomica applicata": "Genomica applicata",
        "ii anno percorso genomica applicata": "Genomica applicata", "ba genetica a": "Genomica applicata",
        "percorso proteomica e metabolomica": "Proteomica e metabolomica", "proteomica e metabolomica": "Proteomica e metabolomica",
        "ii anno percorso proteomica e metabolomica": "Proteomica e metabolomica", "ba proteomica": "Proteomica e metabolomica",
    },
    "106": {  # Tutela e benessere animale
        "tba animali da compagnia": "Animali da compagnia", "animali da compagnia": "Animali da compagnia",
        "tba animali da reddito e equidi": "Animali da reddito e equidi", "animali da reddito e equidi": "Animali da reddito e equidi",
    },
    "116": {  # Food Science and Technology
        "food process innovation digitalisation": "Food process innovation & digitalisation",
        "food process innovation and digitalisation": "Food process innovation & digitalisation",
        "sustainable food systems": "Sustainable food systems",
    },
}

# Correzioni al catalogo dove il piano ufficiale dice altro: (codice del corso, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "obbligatorio" | "cfu=<n>".
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (codice del corso, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

# Righe che il catalogo non ha ma la pagina ufficiale degli insegnamenti sì: (codice del corso, anno di corso) → righe.
# Scienze politiche (L-36): il catalogo non elenca la «Prova finale» (6 CFU) in nessuna coorte (36 CFU obbligatori nel 3° anno, il
# corso arriva a 174 su 180); la pagina del corso su unite.it (Insegnamenti 2026-2027, «III anno … Prova finale 6 CFU», in tutti e
# quattro i curricula) la elenca. Per la coorte 2024 (gli iscritti al 3° anno nel 2026/27) la riga è una deduzione: la pagina
# descrive il piano 2026/27 e con la prova finale il piano 2024 del catalogo fa esattamente 60 + 66 + 54 = 180 CFU.
_L36 = "https://www.unite.it/UniTE/Didattica/Corsi_di_studio/Scienze_politiche_L36/Scienze_Politiche_Insegnamenti"
AGGIUNTE: dict[tuple[str, int], list[dict]] = {
    ("105", 3): [{"nome": "Prova finale", "cfu": 6, "obbligatorio": True, "url": _L36, "fonte": _L36}],
}

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
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unite)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unite" if d else None

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
    """Nome del percorso senza «PIANO DI STUDIO COORTE 2024», «AD III ANNO COORTE 2022», «COURSE STRUCTURE 2026», «PERCORSO»."""
    n = re.sub(r"\s+", " ", p.get("des_it") or p.get("pdsDes") or "").strip()
    n = re.sub(r"(?i)^(?:piano di studio|course structure)\b[\s_]*", "", n)
    n = re.sub(r"(?i)^ad\s+[ivx]+\s+anno\s+coorte\s+\d+[\s_]*", "", n)
    n = re.sub(r"(?i)^(?:coorte[\s_]*)?\d{3,5}(?=[\s_]|$)[\s_]*", "", n)
    n = re.sub(r"(?i)^(?:ii\s+anno\s+)?(?:percorso\s+)+", "", n)
    return re.sub(r"\s+", " ", n).strip(" -:_.")


def _pulisci_nome_percorso(nome: str, catena0: str) -> str:
    """Nome di un curriculum: quello canonico di `CURRICULA` o, se non c'è, le maiuscole del catalogo corrette e senza
    virgole (i curricula di un insegnamento si separano con la virgola)."""
    nome = re.sub(r"\s+", " ", nome).strip()
    alias = CURRICULA.get(catena0, {}).get(_norm(nome))
    if alias:
        return alias
    nome = _titolo(nome) if nome.isupper() else nome
    nome = re.sub(r"\s*,\s*", " - ", nome)
    return nome[:1].upper() + nome[1:]


def _comune(p: dict) -> bool:
    """Percorso comune a tutti: dal nome («comune», «percorso generico»). Il flag «comune» del catalogo non basta: i percorsi di
    Biotecnologie hanno il flag anche quando sono curricula."""
    return bool(_COMUNE.search(p.get("des_it") or p.get("pdsDes") or ""))


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

    def build(id_ul: str, id_corso: str, catena: tuple[str, ...]) -> dict | None:
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
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][0][1], f"{base}/corsi/{anno}/{cohorts[anno][0][0]['cod']}")
            # le prove OFA sono attività a 0 CFU del 1° anno del piano (tolte dagli insegnamenti): il piano della coorte
            # che si iscrive ora le elenca, quindi gli OFA sono previsti
            if amm and amm.get("ofa") is None and any(
                    re.match(r"(?i)\s*ofa\b", t.get("des_it") or "") and not t.get("crediti")
                    for p in cohorts[anno][0][1].get("percorsi") or [] for a in p.get("anni") or []
                    for g in _gruppi(a) for t in g.get("attivita") or []):
                amm["ofa"] = True

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

        # nome del percorso: canonico (`CURRICULA`) o ripulito dal catalogo; senza nome (solo il codice) il codice
        def nome_percorso(p: dict) -> str:
            nome = _nome_percorso_grezzo(p)
            if not nome:
                return p.get("pdsCod") or ""
            return _pulisci_nome_percorso(nome, catena[0])

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
                            # regola di scelta senza elenco («ATTIVITA' DIDATTICHE A SCELTA EROGATE DA ALTRI CORSI (6 CFU)»):
                            # l'elenco con i CFU è nel gruppo accanto, la regola non è un insegnamento
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
        for (cds_c, anno_c), righe_agg in AGGIUNTE.items():
            if cds_c == catena[0] and str(anno_c) in piano_anni:
                for r_ in righe_agg:
                    ins.append({"codice": None, "anno": anno_c, "periodo": None, "ssd": None, "curriculum": None,
                                "docenti": [], "libri": [], "esami": [], "verificato_il": oggi, **r_})
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
        # stessa attività con CFU diversi nello stesso anno (percorsi diversi): build_db unisce le righe con lo stesso codice e
        # anno in una sola e perderebbe uno dei due CFU; ogni riga ha l'id proprio e il nome con i suoi CFU
        per_cod: dict[tuple, list] = {}
        for i in ins:
            if i["codice"]:
                per_cod.setdefault((i["anno"], i["codice"]), []).append(i)
        for gruppo_i in per_cod.values():
            if len({i["cfu"] for i in gruppo_i}) < 2:
                continue
            viste: dict[str, int] = {}
            for i in gruppo_i:
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
                base_id = f"{id_corso}-{_norm(i['codice']).replace(' ', '-')[:40].strip('-')}-{i['cfu']:g}cfu"
                n = viste.get(base_id, 0)
                viste[base_id] = n + 1
                i["id"] = base_id if not n else f"{base_id}-{'obbl' if i['obbligatorio'] else 'scelta'}"
        sede = cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None
        if re.search(r"(?i)\(sede [a-z]+\)", cur.get("des_it") or "") and rec_d.get("altreSedi"):
            sede = rec_d["altreSedi"][0].get("sedeDenominazioneComune") or sede  # «GIURISPRUDENZA (SEDE AVEZZANO)»: si tiene a Avezzano
        out = {
            "id": id_corso, "id_universitaly": id_ul,
            "nome": _titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec_d.get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": sede,
            "codice_ateneo": catena[0],
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        return out

    def build_safe(r: tuple[str, str, tuple[str, ...]]) -> dict | None:
        try:
            return build(*r)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {r[2][0]} saltato: {e!r}")
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unite.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "unite.json", ROOT / "database" / "contrib" / "auto" / "unite_syl_b2.json"):
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


def fetch_ateneo(uid: str = "unite", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unite.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unite] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
