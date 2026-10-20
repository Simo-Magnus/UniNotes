"""Università di Modena e Reggio Emilia: piani di studio per coorte dal Course Catalogue Cineca.

Piani e syllabus: `https://unimore.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) il catalogo di UniMoRe richiede:

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo
  anno), con tutti gli anni del corso. Con il riordino delle classi del 2025 i corsi hanno cambiato codice (16-215 →
  16-315, 20-262 → 20-362: la cifra delle centinaia passa da 2 a 3) e a volte nome (Lingue, culture, comunicazione →
  Lingue e traduzione per le arti e i media, Scienze giuridiche dell'impresa → Scienze dei servizi giuridici, ...);
  la coorte precedente si ritrova per codice, per codice con la centinaia cambiata, per nome, sede e tipo, o per il
  codice del predecessore. Se una coorte non ha quell'anno nel suo piano si legge la più vicina che lo ha;
- piani «approvato» e «da approvare»/«proposto»/«in valutazione» dello stesso percorso (stesso `pdsCod`): sono due versioni
  del piano per lo studente (elenco degli insegnamenti a scelta preapprovati o scelta libera). Si legge la versione
  approvata; il piano proposto non crea percorsi in più;
- schemi per gli allievi dell'Accademia Militare («SCHEMA CADETTI IEI», «Allievi Carabinieri», «Esercito-Commissariato»):
  piani speciali per una popolazione particolare, non percorsi degli studenti ordinari; non si importano;
- durata dal piano («3 anni», «6 anni»): l'elenco minimale non ha `durataAnni` per tutti i corsi;
- gruppi del piano (`cod`): «OO» sono gli insegnamenti obbligatori; «F», «W» gruppi di scelta (con CFU nell'etichetta o
  senza: «Selezionare un insegnamento tra i due», «fra 1 e 99 CFU»), «S» crediti liberi senza elenco («LIBERA SCELTA
  (fra 12 e 30 CFU)»). Un'attività è obbligatoria se sta in «OO» o se il gruppo la richiede per intero (CFU fissi
  dell'etichetta uguali alla somma delle attività);
- gruppi senza attività elencate: voce a scelta con i CFU dell'etichetta (il minimo se «fra a e b CFU»: sono i crediti
  che lo studente deve acquisire; le attività non legate a un anno vanno all'ultimo anno);
- attività a 0 CFU (OFA, debiti, livelli di lingua, precorsi, prove di verifica): non sono insegnamenti del piano; gli
  obblighi formativi aggiuntivi vanno tra i requisiti di accesso;
- percorsi: il `pdsCod` identifica il curriculum tra coorti e versioni; «Percorso comune» e piani che coprono solo i primi
  anni valgono per tutti i curricula; un'attività presente in tutti i percorsi dell'anno non ha curriculum;
- alternative omonime con CFU diversi (Tirocinio da 9 e da 12 CFU): il nome porta i CFU;
- `ID_UNIVERSITALY`: ogni corso del catalogo (cdsCod) si lega al corso di Universitaly, senza creare corsi doppi o
  mescolare i piani di Laurea e Laurea magistrale con lo stesso nome (Ingegneria gestionale, Ingegneria meccanica, ...).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco (cartella «unimore_cc»).
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.
Gli appelli si legano ai corsi (`unimore_appelli`: bacheca Esse3 per corso di studio, calendario di Economia).
I testi dei syllabus (campo «testi_it») sono in forma libera: `unimore_testi` tiene i riferimenti e scarta il resto.

Esecuzione locale (scrive `database/contrib/auto/unimore.json`, conserva gli appelli già raccolti):

    python tools/db_builder/adapters/unimore.py [--senza-syllabus] [--senza-appelli]
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
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
from . import unimore_appelli, unimore_testi  # noqa: E402

BASE = "https://unimore.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici (dottorati, master e corsi di perfezionamento non hanno un piano per anno)

# codice del corso nel catalogo (cdsCod) → id Universitaly dello stesso corso
ID_UNIVERSITALY = {
    "3-312": "1629967",   # Analisi dei dati per l'impresa e la finanza
    "14-412": "1629924",  # Assistenza sanitaria
    "17-300": "1629938",  # Biotecnologie
    "16-310": "1629959",  # Chimica
    "16-316": "1629960",  # Chimica verde e sostenibile
    "14-400": "1629921",  # Dietistica
    "83-312": "1629955",  # Digital Education
    "3-311": "1629952",   # Digital Marketing
    "50-313": "1629951",  # Economia aziendale e management
    "50-312": "1629964",  # Economia e finanza
    "50-311": "1629950",  # Economia e marketing internazionale
    "16-311": "1629961",  # Fisica
    "14-401": "1629916",  # Fisioterapia
    "14-410": "1629922",  # Igiene dentale
    "14-408": "1631900",  # Infermieristica, Modena
    "14-409": "1631901",  # Infermieristica, Reggio Emilia
    "16-315": "1629962",  # Informatica
    "20-310": "1629939",  # Ingegneria civile e ambientale
    "20-316": "1629946",  # Ingegneria del veicolo
    "20-315": "1629942",  # Ingegneria elettronica
    "1-310": "1629944",   # Ingegneria gestionale
    "20-317": "1629940",  # Ingegneria informatica, Mantova
    "20-312": "1629941",  # Ingegneria informatica, Modena
    "20-313": "1629945",  # Ingegneria meccanica
    "1-311": "1629943",   # Ingegneria meccatronica
    "12-302": "1629947",  # Lingue e culture europee
    "14-402": "1629918",  # Logopedia
    "3-310": "1629953",   # Marketing e organizzazione d'impresa
    "16-314": "1629966",  # Matematica
    "14-403": "1631899",  # Ostetricia
    "17-301": "1629948",  # Scienze biologiche
    "11-310": "1629949",  # Scienze dei servizi giuridici
    "83-313": "1629954",  # Scienze dell'educazione per il nido e le professioni socio-pedagogiche
    "3-305": "1629956",   # Scienze della comunicazione
    "83-311": "1629957",  # Scienze e tecniche psicologiche
    "30-310": "1629958",  # Scienze e tecnologie agrarie e degli alimenti
    "16-313": "1629965",  # Scienze geologiche
    "16-312": "1629963",  # Scienze naturali
    "11-214": "1626804",  # Scienze strategiche
    "12-304": "1629968",  # Storia e culture contemporanee
    "14-404": "1629915",  # Tecnica della riabilitazione psichiatrica
    "14-406": "1629923",  # Tecniche di fisiopatologia cardiocircolatoria e perfusione cardiovascolare
    "14-405": "1629919",  # Tecniche di laboratorio biomedico
    "14-407": "1629920",  # Tecniche di radiologia medica, per immagini e radioterapia
    "14-411": "1629917",  # Terapia occupazionale
    "20-369": "1629933",  # Advanced Automotive Engineering
    "50-367": "1629988",  # Analisi dei dati per l'economia e il management
    "12-359": "1629970",  # Antropologia e storia del mondo contemporaneo
    "20-373": "1629930",  # Artificial Intelligence Engineering
    "14-366": "1629978",  # Bioingegneria per l'innovazione in medicina
    "17-356": "1629971",  # Bioscienze
    "17-355": "1629973",  # Biotecnologie mediche
    "30-361": "1629993",  # Controllo e sicurezza degli alimenti
    "16-369": "1629990",  # Didattica e comunicazione delle scienze
    "1-362": "1629927",   # Digital Automation Engineering
    "50-360": "1629998",  # Direzione e consulenza di impresa
    "3-365": "1629997",   # Economia e diritto per la sostenibilità delle organizzazioni
    "50-368": "1629987",  # Economia, politiche pubbliche e sostenibilità
    "20-371": "1629928",  # Electronics Engineering
    "1-363": "1629980",   # Energy Engineering
    "50-364": "1629976",  # Finanza e management
    "16-370": "1629994",  # Geoscienze, georischi e georisorse
    "16-362": "1629926",  # Informatica (LM)
    "20-370": "1629979",  # Ingegneria civile e ambientale (LM)
    "20-372": "1629937",  # Ingegneria dei materiali
    "20-364": "1626805",  # Ingegneria del veicolo (LM)
    "1-360": "1629929",   # Ingegneria gestionale (LM)
    "20-362": "1629931",  # Ingegneria informatica (LM)
    "20-363": "1629935",  # Ingegneria meccanica (LM)
    "1-361": "1629932",   # Ingegneria meccatronica (LM)
    "50-369": "1629995",  # International Management
    "12-361": "1629981",  # Languages for communication in international enterprises and organizations
    "12-362": "1626806",  # Lingue e traduzione per le arti e i media
    "3-363": "1629996",   # Management e comunicazione d'impresa
    "16-363": "1629982",  # Matematica (LM)
    "83-360": "1629984",  # Media education per le discipline letterarie e l'editoria
    "16-368": "1629977",  # Physics - Fisica
    "3-364": "1629989",   # Pubblicità, comunicazione digitale e creatività d'impresa
    "50-362": "1629999",  # Relazioni di lavoro
    "14-364": "1629991",  # Salute e sport
    "16-364": "1629986",  # Scienze chimiche
    "14-363": "1631903",  # Scienze infermieristiche e ostetriche - Profilo infermieristico
    "14-365": "1635748",  # Scienze infermieristiche specialistiche nelle cure primarie
    "83-351": "1630000",  # Scienze pedagogiche
    "17-352": "1629972",  # Sistemi biotecnologici per lo sviluppo sostenibile
    "30-362": "1629992",  # Sostenibilità integrata dei sistemi agricoli
    "20-374": "1629934",  # Sustainable Industrial Engineering
    "83-353": "1630001",  # Teorie e metodologie del digital learning
    "15-356": "1629975",  # Chimica e tecnologia farmaceutiche
    "15-357": "1629974",  # Farmacia
    "11-355": "1629969",  # Giurisprudenza
    "14-361": "1629983",  # Medicina e chirurgia
    "14-362": "1629985",  # Odontoiatria e protesi dentaria
    "83-252": "1629936",  # Scienze della formazione primaria
    "20-219": "1629914",  # Costruzioni e gestione del territorio
    "1-213": "1629925",   # Tecnologie per l'industria intelligente
}

# corsi del catalogo che nelle coorti precedenti hanno un altro nome e un altro codice: cdsCod attuale → cdsCod delle coorti
# precedenti (stessa sede e stesso tipo; vedi i piani delle coorti sul catalogo)
PREDECESSORI = {
    "11-310": ["11-210"],   # Scienze giuridiche dell'impresa e della PA → Scienze dei servizi giuridici
    "12-362": ["12-260"],   # Lingue, culture, comunicazione → Lingue e traduzione per le arti e i media
    "14-363": ["14-263"],   # Scienze infermieristiche ed ostetriche (RE) → LM/SNT1 sede di Reggio Emilia
    "14-365": ["14-265"],   # Scienze infermieristiche e ostetriche (MO) → Scienze infermieristiche specialistiche nelle cure primarie
}

# l'elenco dei corsi non ha la durata: si ricava dal tipo (L2 triennale, LM biennale, LM5/LM6 a ciclo unico)
DURATE = {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}

_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_PENDENTE = re.compile(r"(?i)da\s+approvare|propost|in\s+valutazione|da\s+sottoporre|libero\s+da|sottoporre\s+ad\s+approvazione|propopst")
_SPECIALE = re.compile(r"(?i)cadett|accademi|allievi|esercito|commissariato|carabinieri")
_DEBITO = re.compile(r"(?i)\bdebito\b|obblig\w*\s+formativ|\bofa\b|precorso|verifica\s+(?:della\s+)?preparazione")
_STESSO_BLOCCO = re.compile(r"(?i)libera\s+scelta|\bregola\b|\bopzione\s+\d|\balternativ|scelta\s+fra")
_NUMERI = {"un": 1, "uno": 1, "due": 2, "tre": 3, "quattro": 4}
_SELEZIONA = re.compile(r"(?i)selezionare\s+(uno|un|due|tre|quattro)\s+insegnament")
_ALTERNATIVA = re.compile(r"(?i)\bOPZ\b|\bopzion\w*\s+\d|\boppure\b|\balternativ")


DICHIARATI = None  # (cdsCod, curriculum, anno) → CFU dichiarati dal piano (solo per i controlli)


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti: le parentesi restano."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    return DURATE.get(tipo or "", 3)


def _chiave_cds(cod: str | None) -> str:
    """«16-215» (coorti precedenti) e «16-315» sono lo stesso corso: la cifra delle centinaia 2 diventa 3."""
    m = re.fullmatch(r"([\w]+)-(\d)(\d\d)", (cod or "").strip())
    if not m:
        return (cod or "").strip()
    return f"{m.group(1)}-{'3' if m.group(2) == '2' else m.group(2)}{m.group(3)}"


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unimore_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unimore_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path, params=None):
        if not self.dir:
            return super().get(path, params)
        k = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.dir / f"{k}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def _titolo_etichetta(s: str) -> str:
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        return s[:1].upper() + s[1:]
    return s[:1].upper() + s[1:].lower()


def _cfu_etichetta(label: str):
    """(minimo, massimo) dei CFU nell'etichetta di un gruppo: «(12 CFU)» → (12, 12), «(fra 6 e 18 CFU)» → (6, 18)."""
    m = _ETICHETTA_CFU.search(label or "")
    if not m:
        return None
    hi = _numero(m.group(2))
    lo = _numero(m.group(1)) if m.group(1) else hi
    return lo, hi


def _nome_gruppo(label: str) -> str:
    """Nome della voce a scelta di un gruppo senza attività: l'etichetta con l'intervallo dei CFU se non è fisso."""
    lab = re.sub(r"\s+", " ", label or "").strip()
    cfu = _cfu_etichetta(lab)
    if cfu and cfu[0] == cfu[1]:
        lab = _ETICHETTA_CFU.sub(" ", lab)
    lab = re.sub(r"^\s*\d+°?\s*anno\s*[-–:]?\s*", "", lab, flags=re.I)
    lab = re.sub(r"(?i)^\s*(?:i|ii|iii|iv|v)\s+anno\s*[-–:]?\s*", "", lab)
    lab = re.sub(r"\s+", " ", lab).strip()
    return _titolo_etichetta(lab)


def _gruppi_di_anno(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _ad(att: dict) -> str:
    return att.get("adCod") or att.get("cod")


def _pds(p: dict) -> str:
    return (p.get("pdsCod") or "").strip()


def _nome_p(p: dict) -> str:
    return (p.get("des_it") or p.get("pdsDes") or "").strip()


def _anni_percorso(p: dict) -> set[int]:
    return {int(a["anno"]) for a in p.get("anni") or [] if str(a.get("anno")).isdigit() and int(a["anno"]) > 0}


def _n_att(p: dict) -> int:
    return sum(len(g.get("attivita") or []) for a in p.get("anni") or [] for g in _gruppi_di_anno(a))


def _percorsi_validi(det: dict) -> list[dict]:
    """Percorsi del piano di una coorte: senza gli schemi speciali (Accademia Militare) e con una sola versione per `pdsCod`
    (l'approvata: «da approvare»/«proposto»/«in valutazione» sono la versione proposta dallo studente dello stesso piano)."""
    ps = [p for p in det.get("percorsi") or [] if not _SPECIALE.search(_nome_p(p))]
    out: dict[str, dict] = {}
    for p in ps:
        k = _pds(p) or _nome_p(p)
        cur = out.get(k)
        if cur is None:
            out[k] = p
            continue
        pend_new, pend_cur = bool(_PENDENTE.search(_nome_p(p))), bool(_PENDENTE.search(_nome_p(cur)))
        if pend_cur and not pend_new:
            out[k] = p
        elif pend_cur == pend_new and _n_att(p) > _n_att(cur):
            out[k] = p
    # percorsi senza pdsCod comune ma stesso nome ripetuto (versione approvata e proposta): resta uno solo per nome
    res: dict[str, dict] = {}
    for p in out.values():
        nome = re.sub(r"(?i)\b(?:approvat\w*|automaticamente|pre-?approvat\w*)\b", "", _nome_p(p))
        k = (_pds(p) + "|" + _norm(nome)) if not _pds(p) else _pds(p)
        res.setdefault(k, p)
    return list(res.values())


def _tutti_percorsi(det: dict) -> list[dict]:
    """Come `_percorsi_validi` ma senza togliere le versioni del piano: serve per sapere quali attività esistono."""
    return [p for p in det.get("percorsi") or [] if not _SPECIALE.search(_nome_p(p))]


def _e_pdscomune(p: dict) -> bool:
    cod = _pds(p).upper()
    return cod.startswith("PDS0") or cod in ("COMUNE", "GEN")


# nomi dei curricula scritti in modo diverso da una coorte all'altra (chiave: nome senza maiuscole né punteggiatura, vedi _norm)
ALIAS_PERCORSI = {
    "edss": "EDSS - Educatore digitale nei contesti socio-sanitari",
    "eps": "EPS - Educatore psico-sociale nei contesti digitali",
    "id": "ID - Instructional Designer nei contesti digitali",
    "t agrarie": "Tecnologie agrarie", "t alimentari": "Tecnologie alimentari",
    "consulenti del lavoro": "Consulente del lavoro e di relazioni industriali",
    "operatori giuridici d impresa": "Operatore giuridico d'impresa e del terzo settore",
    "giustizia sicurezza pubblica e amministrazione": "Funzionario delle pubbliche amministrazioni e delle istituzioni europee ed internazionali",
    "sistema veicolo": "Chassis & Body", "lm ingegneria del veicolo chassis body": "Chassis & Body",
    "chassis body": "Chassis & Body",
    "processo": "Progettazione di Processo", "prodotto": "Progettazione di Prodotto",
}


def _nome_percorso(nome: str) -> str:
    n = re.sub(r"(?i)[\s,\-–]*coorte\s*\d{4}(?:[/-]\d{2,4})?", "", nome)
    n = re.sub(r"\s+", " ", n).strip()
    # «Piano LT Ingegneria Meccanica - Generale», «Piano LM Ingegneria Informatica - Cloud and Cybersecurity»,
    # «Corso di Laurea in Scienze e tecnologie agrarie e degli alimenti - Tecnologie agrarie»: resta dopo il trattino
    n = re.sub(r"(?i)^\s*piano\s+(?:automaticamente\s+approvato|in\s+valutazione)\s*[-–]?\s*", "", n)
    for _ in range(2):
        m = re.match(r"(?i)^(?:piano\s+)?(?:lt|lm|lp|corso di laurea|scienze e tecnologie)\b.*?(?:\s-\s|\bcurr(?:iculum)?\.?\s+)(.+)$", n)
        if m:
            n = m.group(1)
    n = re.sub(r"(?i)\bapprovat[oa]\b", " ", n)
    n = re.sub(r"(?i)\b(?:piano|schema)\s+(?:automaticamente\s+)?approvat\w*|\bpre-?approvat\w*|\bda approvare\b|\bproposto\b", " ", n)
    n = re.sub(r"(?i)^\s*piano\s+del\s+", "", n)
    n = re.sub(r"(?i)^\s*(?:piano|schema)\s+", "", n)
    n = re.sub(r"(?i)^\s*(?:curriculum|curriculm|currilum|percorso|pecorso|curr\.?)\s+", "", n)
    n = re.sub(r"(?i)^\s*(?:del\s+)?curriculum\s+", "", n)
    n = re.sub(r"^\s*\d+(?:-\d+)+\s+", "", n)  # «1-310-1 Produzione - Beni e servizi»
    n = re.sub(r"\s+", " ", n).strip(" -:,")
    if (n.isupper() and len(n) > 4) or n.islower():
        n = n.capitalize()
    n = ALIAS_PERCORSI.get(_norm(n), n)
    n = re.sub(r"\s*,\s*", " - ", n)  # le virgole separano i percorsi di un insegnamento (pulizia.percorsi)
    return n[:1].upper() + n[1:]


def _cfu_att(att: dict, noti: dict) -> float:
    c = att.get("crediti")
    if isinstance(c, (int, float)) and c > 0:
        return c
    return noti.get(_ad(att)) or 0


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None,
                 codici_db=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    codici_db = codici_db or set()
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    elenco_attuale, visti_cod = [], set()
    for x in coorti[anno]:
        if x["cod"] not in visti_cod:
            visti_cod.add(x["cod"])
            elenco_attuale.append(x)
    attuali = elenco_attuale[:max_cds] if max_cds else elenco_attuale
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        k = _chiave_cds(cur["cdsCod"])
        for x in elenco:
            if _chiave_cds(x["cdsCod"]) == k and x.get("tipo_corso_cod") == cur.get("tipo_corso_cod"):
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        if len(stessi) == 1:
            return stessi[0]
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("tipo_corso_cod")) == chiave[::2]]
        if len(stessi) == 1:
            return stessi[0]
        for prec in PREDECESSORI.get(cur["cdsCod"], []):
            for x in elenco:
                if x["cdsCod"] == prec:
                    return x
        return None

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")

        # nome canonico dei percorsi: quello della coorte più recente che li ha, riconosciuto tra coorti per nome, per
        # numero del curriculum o per somiglianza. Il confronto è con i percorsi delle coorti già viste
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple[str, str, str]] = []  # (chiave nome, suffisso pdsCod, nome canonico)
        for y in sorted(cohorts, reverse=True):
            ps = [p for p in _percorsi_validi(cohorts[y][1]) if not _e_pdscomune(p)]
            visti = list(riferimento)
            nuovi = []
            for p in ps:
                pn = _nome_p(p)
                nome_c = _nome_percorso(pn)
                ch = _norm(nome_c)
                suf = (re.search(r"-(\d+)\s*$", _pds(p)) or [None, ""])[1]
                trovato = next((r for r in visti if r[0] == ch), None)
                if not trovato:
                    simili = difflib.get_close_matches(ch, [r[0] for r in visti], n=1, cutoff=0.72)
                    if not simili:  # prefisso: «Percorso Rigenerazione urbana» → «Percorso Rigenerazione»
                        simili = [r[0] for r in visti if len(min(ch, r[0], key=len)) >= 8
                                  and (r[0].startswith(ch) or ch.startswith(r[0]))][:1]
                    trovato = next((r for r in visti if r[0] == simili[0]), None) if simili else None
                if not trovato:
                    trovato = (ch, suf, nome_c)
                    nuovi.append(trovato)
                canon[(y, _pds(p) or pn)] = trovato[2]
            riferimento.extend(nuovi)

        def sommario(det: dict, k: int) -> float:
            """CFU «dichiarati» dall'anno k di un piano (obbligatori, scelte con CFU fissi o con una sola scelta)."""
            tot = 0.0
            for p in _percorsi_validi(det):
                if k not in _anni_percorso(p):
                    continue
                for a in p.get("anni") or []:
                    if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                        continue
                    for g in _gruppi_di_anno(a):
                        tot += sum(float(t.get("crediti") or 0) for t in g.get("attivita") or [])
            return tot

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            ha = {y: sommario(d, k) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v > 0}
            if not ha:
                return None
            if y0 in ha:
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        # stessa attività offerta in altre coorti/anni accademici: schede alternative per i libri; CFU noti di un'attività
        # con 0 CFU in un piano e CFU nell'altro
        alt_per_ad: dict[str, dict] = {}
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for p in _tutti_percorsi(cohorts[y][1]):
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            alt_per_ad.setdefault(_ad(att), {})[(str(att.get("aa")), str(att.get("cod")))] = (y, att)
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[_ad(att)] = att["crediti"]

        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        debiti: list[str] = []
        blocchi: set = set()
        regole: list[dict] = []  # CFU richiesti da ogni gruppo del piano, per il calcolo dei crediti liberi
        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            percorsi_k = [p for p in _percorsi_validi(d) if k in _anni_percorso(p)
                          or (k == durata and any(not str(a.get("anno")).isdigit() or int(a["anno"]) == 0
                                                  for a in p.get("anni") or []))]
            anni_p = {_pds(p) or _nome_p(p): max(_anni_percorso(p) or {0}) for p in percorsi_k}
            # percorsi comuni: «PDS0-…»/«… comune» o un piano che copre solo i primi anni quando gli altri li coprono tutti
            comuni = {kk for kk, p in zip(anni_p, percorsi_k)
                      if _e_pdscomune(p) or (len(percorsi_k) > 1 and anni_p[kk] < max(anni_p.values()))}
            specifici = [p for kk, p in zip(anni_p, percorsi_k) if kk not in comuni]
            if len(percorsi_k) > 1 and len(comuni) == len(percorsi_k):
                comuni = set()  # nessun percorso specifico: non sono curricula
                specifici = list(percorsi_k)
            curricula = {canon[(scelta, _pds(p) or _nome_p(p))] for p in specifici} if len(specifici) >= 2 else set()
            for kk, p in zip(anni_p, percorsi_k):
                comune = kk in comuni or not curricula
                pcur = None if comune else canon[(scelta, _pds(p) or _nome_p(p))]
                for a in p.get("anni") or []:
                    anno_a = str(a.get("anno"))
                    if anno_a.isdigit() and int(anno_a) > 0:
                        if int(anno_a) != k:
                            continue
                    elif k != durata:  # attività non legate a un anno: ultimo anno
                        continue
                    for g in _gruppi_di_anno(a):
                        atts = [t for t in g.get("attivita") or []]
                        label = g.get("label_it") or ""
                        cfu_g = _cfu_etichetta(label)
                        positive = [t for t in atts if _cfu_att(t, cfu_noti) > 0]
                        if not atts:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                            nome = _nome_gruppo(label)
                            if not cfu_g or len(nome) < 3 or _DEBITO.search(label) or cfu_g[0] <= 0:
                                continue
                            cfu_v = cfu_g[0]
                            key = f"{k}:#{_norm(nome)}:{cfu_v:g}"
                            item = insegnamenti.get(key)
                            if not item:
                                item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu_v,
                                        "ssd": None, "obbligatorio": False, "curriculum": None, "_percorsi": set(),
                                        "_tutti": set(curricula), "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                        "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                        "_senza_codice": True}
                                insegnamenti[key] = item
                            regole.append({"k": k, "p": None if comune else pcur, "tipo": "libera", "lo": cfu_g[0],
                                           "hi": cfu_g[1], "item": item})
                            if comune:
                                item["_comune"] = True
                            elif pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
                            continue
                        tot_g = sum(_cfu_att(t, cfu_noti) for t in positive)
                        tutte = (g.get("cod") == "OO") or bool(
                            cfu_g and cfu_g[0] == cfu_g[1] and positive and abs(tot_g - cfu_g[0]) < 1e-6
                            and not _ALTERNATIVA.search(label))
                        if positive:
                            sel = _SELEZIONA.search(label)
                            if tutte:
                                reg = {"tipo": "fisso", "val": tot_g}
                            elif cfu_g and cfu_g[0] == cfu_g[1]:
                                reg = {"tipo": "fisso", "val": cfu_g[0]}
                                if _STESSO_BLOCCO.search(label):  # «libera scelta (12 CFU) - I regola/II regola», «Opzione 1/2/3»: un blocco solo
                                    if (k, cfu_g[0]) in blocchi:
                                        reg = {"tipo": "ripetuto"}
                                    blocchi.add((k, cfu_g[0]))
                            elif sel:
                                reg = {"tipo": "fisso", "val": _NUMERI[sel.group(1).lower()] * max(_cfu_att(t, cfu_noti) for t in positive)}
                            elif cfu_g:
                                reg = {"tipo": "aperto", "lo": cfu_g[0], "hi": cfu_g[1]}
                            else:
                                reg = {"tipo": "ignoto"}
                            regole.append({"k": k, "p": None if comune else pcur, **reg})
                        for att in atts:
                            ad = _ad(att)
                            cfu_v = _cfu_att(att, cfu_noti)
                            if not cfu_v:
                                if _DEBITO.search(att.get("des_it") or "") or _DEBITO.search(label):
                                    nome_d = re.sub(r"(?i)^\s*debito\s+(?:in\s+)?", "", cc._titolo(att.get("des_it") or "")).strip()
                                    debiti.append(nome_d)
                                continue
                            key = f"{k}:{ad}:{int(bool(tutte))}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": cfu_v, "ssd": None,
                                    "obbligatorio": bool(tutte), "curriculum": None, "_percorsi": set(),
                                    "_tutti": set(curricula), "docenti": sorted(set(docenti)),
                                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                }
                                insegnamenti[key] = item
                                if syllabus:
                                    syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                                   "af_percorso": att.get("corso_percorso_id"),
                                                   "corso_cod": att.get("corso_cod"), "corso_aa": scelta,
                                                   "schema_id": att.get("schemaId")},
                                        "items": [], "codice": ad,
                                        "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                                            alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                                            if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                                    })["items"].append(item)
                            if comune:
                                item["_comune"] = True
                            elif pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
        # crediti liberi («LIBERA SCELTA (fra 12 e 30 CFU)»): il catalogo dà solo l'intervallo; se in un percorso tutti gli altri
        # gruppi hanno CFU noti e i gruppi aperti sono tutti in un anno con lo stesso intervallo, i crediti liberi sono quelli che
        # portano il percorso al totale del corso di studio (se stanno nell'intervallo); altrimenti il minimo dell'intervallo
        crediti = rec[1].get("crediti")
        if not isinstance(crediti, (int, float)) or crediti <= 0:
            crediti = 60 * durata
        valori: dict[int, set] = {}
        for pth in (sorted(curricula) or [None]):
            # i percorsi dei curricula ripetono le attività del percorso comune: per ogni anno vale il percorso più specifico
            ent = []
            for kk in range(1, durata + 1):
                propri = [r for r in regole if r["k"] == kk and r["p"] == pth and pth is not None]
                ent += propri or [r for r in regole if r["k"] == kk and r["p"] is None]
            if not ent or any(r["tipo"] == "ignoto" for r in ent):
                continue
            aperti = [r for r in ent if r["tipo"] in ("libera", "aperto")]
            liberi = [r for r in ent if r["tipo"] == "libera"]
            if not liberi:
                continue
            resto = crediti - sum(r["val"] for r in ent if r["tipo"] == "fisso")
            ranges = {(r["lo"], r["hi"]) for r in aperti}
            if len({r["k"] for r in aperti}) == 1 and len(ranges) == 1:
                lo, hi = next(iter(ranges))
                if lo <= resto <= hi:
                    for r in liberi:
                        valori.setdefault(id(r["item"]), set()).add(resto)
                    continue
            for r in liberi:
                valori.setdefault(id(r["item"]), set()).add(None)
        for r in regole:
            if r["tipo"] == "libera":
                v = valori.get(id(r["item"]), set())
                if len(v) == 1 and None not in v:
                    r["item"]["cfu"] = next(iter(v))
        if DICHIARATI is not None:  # solo per i controlli: CFU dichiarati dal piano per percorso e anno
            for pth in (sorted(curricula) or [None]):
                for kk in range(1, durata + 1):
                    propri = [r for r in regole if r["k"] == kk and r["p"] == pth and pth is not None]
                    ent = propri or [r for r in regole if r["k"] == kk and r["p"] is None]
                    DICHIARATI[(cur["cdsCod"], pth, kk)] = {
                        "fisso": sum(r["val"] for r in ent if r["tipo"] == "fisso"),
                        "min": max([r["lo"] for r in ent if r["tipo"] == "aperto"], default=0),
                        "libera": sum((r["item"]["cfu"] if r["tipo"] == "libera" else 0) for r in ent),
                        "libera_lo": max([r["lo"] for r in ent if r["tipo"] == "libera"], default=0),
                        "ignoto": sum(1 for r in ent if r["tipo"] == "ignoto"),
                        "crediti": crediti}
        ins = list(insegnamenti.values())
        usati: set[str] = set()
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
                usati |= ps
        # stesso nome nello stesso anno e curriculum con codici diversi: alternative omonime
        per_nome: dict[tuple, list] = {}
        for i in ins:
            if i.get("codice"):
                per_nome.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if len({i["cfu"] for i in gruppo_i}) > 1:  # CFU diversi: il nome porta i CFU
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
                continue
            if all(not i["obbligatorio"] for i in gruppo_i):  # lo stesso insegnamento a scelta con due codici: uno solo
                tieni = min(gruppo_i, key=lambda i: str(i["codice"]))
                for altro in gruppo_i:
                    if altro is tieni:
                        continue
                    tieni["docenti"] = sorted(set(tieni["docenti"]) | set(altro["docenti"]))
                    tieni["periodo"] = tieni["periodo"] or altro["periodo"]
                    ins.remove(altro)
                continue
            periodi = [i["periodo"] for i in gruppo_i]
            for i in gruppo_i:
                if all(periodi) and len(set(periodi)) == len(periodi):
                    p = str(i["periodo"])
                    i["nome"] = f"{i['nome']} ({p}° semestre)" if p in ("1", "2") else f"{i['nome']} ({p})"
                else:
                    i["nome"] = f"{i['nome']} ({i['codice']})"
        # voci senza codice con lo stesso nome in anni diversi: il nome porta l'anno (build_db unisce per nome)
        anni_nome: dict[str, set] = {}
        for i in ins:
            if i.pop("_senza_codice", False):
                anni_nome.setdefault(_nn(i["nome"]), set()).add(i["anno"])
                i["_nk"] = _nn(i["nome"])
        for i in ins:
            nk = i.pop("_nk", None)
            if nk and len(anni_nome[nk]) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        if amm is not None and debiti:
            nomi = [t for t in dict.fromkeys(debiti) if t and t.lower() not in ("obblighi formativi aggiuntivi",)]
            frase = "Debiti formativi (OFA) previsti dal piano di studi" + (": " + ", ".join(nomi) if nomi else "")
            if frase.lower() not in (amm.get("requisiti") or "").lower():
                amm["requisiti"] = ((amm.get("requisiti") or "").rstrip() + "\n" + frase + ".").strip()
            if amm.get("ofa") is None:
                amm["ofa"] = True
        out = {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(rec[1].get("classe_cod") or cur.get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(usati) or None, "ammissione": amm,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        if cur.get("cdsCod") in ID_UNIVERSITALY:
            out["id_universitaly"] = ID_UNIVERSITALY[cur["cdsCod"]]
        return out

    def build_safe(cur: dict) -> dict | None:
        try:
            return build_cds(cur)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            import traceback
            log(f"[{uid}]   corso {cur.get('cdsCod')} saltato: {e!r}\n{traceback.format_exc()}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
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
        if job.get("codice") in codici_db:  # già nel database senza libri: la scheda è stata letta
            return 0
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            sy = {}
        libri, modalita, legati = cc._testi_syllabus(sy) if sy else ([], None, [])
        if not libri and sy:  # testi in forma libera
            libri = unimore_testi.libri_unimore(sy)
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
                l2 = l2 or unimore_testi.libri_unimore(sy2)
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
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unimore.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _dati_database() -> tuple[dict[str, dict], set[str]]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta), e i
    codici già presenti (anche senza libri)."""
    out: dict[str, dict] = {}
    codici: set[str] = set()
    for p in (ROOT / "database" / "corsi" / "unimore.json", ROOT / "database" / "contrib" / "auto" / "unimore.json"):
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            for i in corso.get("insegnamenti") or []:
                cod = i.get("codice")
                if not cod:
                    continue
                codici.add(cod)
                if i.get("libri") and cod not in out:
                    out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    for p in (ROOT / "database" / "contrib" / "auto" / "unimore_syl_b2.json",):
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            for i in corso.get("insegnamenti") or []:
                cod = i.get("codice")
                if cod and i.get("libri") and cod not in out:
                    out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out, codici


def libri_unimore(sy: dict) -> list[dict]:
    return unimore_testi.libri_unimore(sy)


def fetch_ateneo(uid: str = "unimore", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None, appelli: bool = True) -> dict:
    noti, codici = _dati_database()
    d = _fetch_piani(uid, anno, max_cds, syllabus, log, client, noti, codici)
    if appelli:
        unimore_appelli.abbina(d["corsi"], log)
    return d


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv, appelli="--senza-appelli" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unimore.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unimore] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
