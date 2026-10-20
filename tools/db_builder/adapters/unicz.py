"""Università degli Studi «Magna Graecia» di Catanzaro: piani di studio, syllabus e libri dal Course Catalogue Cineca e dai
siti delle strutture didattiche.

Piani e syllabus: `https://unicz.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) il catalogo di UniCZ richiede:

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo
  anno), con tutti gli anni del corso. Il catalogo pubblica i piani per anno solo fino alla coorte 2024 (2025 e 2026 hanno
  solo l'erogato dell'anno, «altreAttivita», senza anni né gruppi): per ogni anno si usa la coorte più vicina che ha almeno
  30 CFU obbligatori in quell'anno (a parità la più recente). L'elenco delle coorti 2025/2026 contiene solo le lauree
  triennali: i corsi magistrali e a ciclo unico si prendono da tutte le coorti dal 2020;
- gruppi del piano (`cod`): «OO» obbligatori, «F»/«W»/«S» gruppi a scelta con i CFU nell'etichetta («(12 CFU)», «fra 1 e 6
  CFU»): stesse regole di UniFE (adapters/unife.py), di cui questo adattatore è una variante;
- l'erogato «altreAttivita» non si legge: sono le attività dell'a.a. di tutti gli anni, senza anno di corso (finivano in
  536 insegnamenti senza anno);
- anni senza piano nel catalogo (Logopedia, Neurofisiopatologia, 6° anno di Medicina e Odontoiatria) e corsi che il catalogo
  non ha (Igiene dentale, Infermieristica interateneo, Scienze delle investigazioni, psicologia, biotecnologie e chimica
  magistrali, professioni sanitarie magistrali, Medicina TD di Crotone, Formazione primaria…): «Elenco Insegnamenti
  Erogati» del sito del corso (Scuola di Medicina e Chirurgia, Scuola di Farmacia e Nutraceutica, Dipartimento di
  Giurisprudenza, Economia e Sociologia), con titolo, docente, CFU, anno e semestre per a.a.: per ogni anno di corso l'a.a.
  più recente la cui lista è completa (≥ 90% dei CFU obbligatori della lista più ricca degli ultimi quattro a.a.);
- Universitaly ha due schede per Dietistica, Infermieristica e Scienze riabilitative: il piano va alla scheda del corso
  ordinario (`ID_UNIVERSITALY`); la seconda è un'edizione interateneo (Infermieristica con Reggio Calabria ha il suo
  sito, le altre due non hanno un piano proprio pubblicato);
- libri, modalità d'esame e SSD già nel database si riusano per codice o per corso e nome (`_libri_database`).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo e dei siti restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unicz.json`):

    python tools/db_builder/adapters/unicz.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import hashlib
import html
import json
import os
import pathlib
import re
import sys
import time
import unicodedata

import requests

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .uniba import libri_testo_libero  # noqa: E402

BASE = "https://unicz.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici (L1 «N.O.» è un vecchio ordinamento senza piano)

# corso del catalogo (cdsCod) → corso di Universitaly: Universitaly ha due schede per Dietistica, Infermieristica e Scienze
# riabilitative (la seconda è un'edizione interateneo con un altro sito): il confronto per nome sceglierebbe la prima, a caso
ID_UNIVERSITALY = {
    "7141": "1629514", "7146": "1629524", "7166": "1629527", "7530": "1633161", "7560": "1629529", "7580": "1633921",
    "7625": "1629522", "7693": "1629519", "7696": "1629513", "7800": "1629517", "7905": "1629518", "7941": "1629535",
    "7951": "1629526", "S203": "1629507", "S674": "1633919", "S740": "1629500", "S771": "1629508", "S820": "1629501",
    "S903": "1629503", "S962": "1629504", "S994": "1633859",
}
# seconda scheda di Universitaly dello stesso corso (interateneo): i libri già raccolti si cercano anche lì
FAMIGLIA = {"1625533": "1633919"}

# Correzioni al catalogo dove il piano ufficiale dice altro: (cdsCod, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "cfu=<n>". Fonte nella nota di cfu_verificati/del report dell'agente.
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (cdsCod, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_COMUNE = re.compile(r"(?i)\bcomune\b")
_DEBITO = re.compile(r"(?i)\bdebito\b|obblig\w*\s+formativ|\bofa\b")
_FREQUENZA = re.compile(r"(?i)\(\s*(?:fr|frequency only|solo frequenza)\s*\)\s*$")
_ALTERNATIVA = re.compile(r"(?i)\bOPZ\b|\bopzion|\boppure\b|\balternativ")  # «Tirocinio OPZ 1 (12 CFU)»: una delle due
_CONDIZIONATO = re.compile(r"(?i)\bper chi\b|\bse non\b|\bnon (?:l'ha|ha)\b|\bchi non\b|\boppure\b|\bscelta\b|\balternativ")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti: le parentesi restano («Tirocinio II (primo semestre)» ≠ «… (secondo semestre)»)."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nk(s: str | None) -> str:
    """Chiave per ritrovare i libri già raccolti di un insegnamento tra coorti e sedi: senza «C.I.», «(a scelta)», «materia a
    scelta» e i CFU nel nome, che cambiano da una scheda all'altra dello stesso insegnamento."""
    n = _nn(s)
    n = re.sub(r"^c i ", "", n)
    n = re.sub(r"\b(?:materia )?a scelta\b|\b\d+ cfu\b", " ", n)
    return re.sub(r"\s+", " ", n).strip()


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _cod_base(cds: str | None) -> str:
    """Il codice del corso cambia con il riordino («1164» → «1164-25»): senza il suffisso è lo stesso corso."""
    return re.sub(r"-\d{2}$", "", (cds or "").strip())


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unicz)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unicz" if d else None

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
    lab = re.sub(r"^\s*\d+°\s*[-–:]?\s*", "", lab)
    return _titolo_etichetta(lab)


def _e_frequenza(att: dict) -> bool:
    return not att.get("crediti") and bool(_FREQUENZA.search((att.get("des_it") or "").strip()))


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", " ", nome)
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo|piano)\b", " ", n)
    return _norm(n)


def _nome_percorso(nome: str) -> str:
    n = re.sub(r"(?i)[\s,-]*\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", "", nome)
    n = re.sub(r"\bInegneria\b", "Ingegneria", n)  # refuso del catalogo
    return re.sub(r"\s+", " ", n).strip(" -:,")


def _gruppi_di_anno(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _obbligatorio(g: dict, att: dict, atts: list[dict]) -> bool:
    """Un'attività del piano è obbligatoria se sta nel gruppo «OO», se il gruppo la richiede per intero, se il gruppo è di
    insegnamenti obbligatori e l'attività ha il tipo «OBB», o se è l'unica del gruppo (senza una scelta nell'etichetta)."""
    label = (g.get("label_it") or "")
    if g.get("cod") == "OO":
        return True
    cfu = _cfu_etichetta(label)
    tot = sum(float(a.get("crediti") or 0) for a in atts)
    if cfu and cfu[0] == cfu[1] and tot > 0 and abs(tot - cfu[0]) < 1e-6 and not _ALTERNATIVA.search(label):
        return True
    if re.search(r"(?i)obbligator", label) and att.get("tipo_ins_cod") == "OBB" and not re.search(r"(?i)\bper chi\b", label):
        return True
    # gruppo a CFU fissi con attività obbligatorie e scelte («Tirocinio + Prova finale (20 CFU)»: prova finale obbligatoria,
    # tirocinio di 7 o 8 CFU a scelta): le obbligatorie, se stanno nei CFU del gruppo, lo sono
    if cfu and cfu[0] == cfu[1] and att.get("tipo_ins_cod") == "OBB" and len(atts) > 1:
        obb = [a for a in atts if a.get("tipo_ins_cod") == "OBB"]
        if len(obb) < len(atts) and sum(float(a.get("crediti") or 0) for a in obb) <= cfu[0] + 1e-6:
            return True
    return len(atts) == 1 and att.get("tipo_ins_cod") == "OBB" and not _CONDIZIONATO.search(label)


_NUMERI = {"due": 2, "tre": 3, "quattro": 4, "cinque": 5, "2": 2, "3": 3, "4": 4, "5": 5}


def _molteplicita(label: str | None) -> int:
    """Quante scelte chiede un gruppo senza CFU nell'etichetta: «Due scelte tra», «Tre insegnamenti a scelta» → 2, 3."""
    m = re.search(r"(?i)\b(due|tre|quattro|cinque|[2-5])\s+(?:scelt\w+|esam\w+|insegnament\w+|corsi|attivit\w+|lingu\w+)", label or "")
    return _NUMERI.get(m.group(1).lower(), 1) if m else 1


def _sommario_anno(det: dict, k: int) -> dict:
    """CFU «dichiarati» dall'anno k di un piano, percorso per percorso:
    {percorso: {"obb": CFU obbligatori, "fissi": CFU di gruppi a scelta con CFU fissi o con una sola scelta,
                "intervalli": [(min, max)] dei gruppi con intervallo}}."""
    out = {}
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                continue
            obb, fissi, interv, etich, alt, incerte, visti = 0.0, 0.0, [], [], [], [], set()
            for g in _gruppi_di_anno(a):
                atts = [x for x in g.get("attivita") or [] if not _e_frequenza(x)]
                cfu_g = _cfu_etichetta(g.get("label_it"))
                oblig = [x for x in atts if _obbligatorio(g, x, atts)]
                for x in oblig:
                    ad = x.get("adCod") or x.get("cod")
                    if ad not in visti:
                        visti.add(ad)
                        obb += float(x.get("crediti") or 0)
                if len(oblig) == len(atts) and atts:
                    continue
                if not oblig and re.search(r"(?i)\bper chi\b", g.get("label_it") or ""):
                    continue  # «Insegnamento obbligatorio per chi non l'ha sostenuto…»: vale solo per alcuni studenti
                if cfu_g and cfu_g[0] == cfu_g[1] and _ALTERNATIVA.search(g.get("label_it") or ""):
                    alt.append(cfu_g[0])  # «Tirocinio OPZ 1 (12 CFU)» / «OPZ 2»: una delle opzioni
                elif cfu_g and cfu_g[0] == cfu_g[1]:
                    fissi += cfu_g[0] - (0 if not oblig else sum(float(x.get("crediti") or 0) for x in oblig))
                elif cfu_g:
                    interv.append(cfu_g)
                    etich.append(re.sub(r"\s+", " ", g.get("label_it") or ""))
                elif atts:
                    cf = {float(x.get("crediti") or 0) for x in atts if x.get("crediti")}
                    if cf:
                        fissi += max(cf) * min(_molteplicita(g.get("label_it")), len(atts))
                    etichetta = re.sub(r"\d+\s*°", " ", g.get("label_it") or "")  # «1° anno»: l'anno, non il numero di scelte
                    plurale = re.search(r"(?i)\b(?:scelte|insegnamenti|esami|corsi|lingue|letterature|attivit\w+)\b", etichetta)
                    numero = re.search(r"(?i)\b(?:un|una|uno|1|due|tre|quattro|cinque|[2-5])\b", etichetta)
                    if len(atts) > 1 and plurale and not numero:
                        incerte.append(re.sub(r"\s+", " ", g.get("label_it") or ""))  # quante scelte non è scritto
            fissi += max(alt, default=0.0)
            out[p.get("des_it") or p.get("pdsDes") or ""] = {"obb": obb, "fissi": fissi, "intervalli": interv, "etichette": etich, "incerte": incerte}
    return out


MIN_OBBLIGATORI_ANNO = 30


def _obb_anno(det: dict, k: int) -> float:
    """CFU obbligatori dichiarati dall'anno k (percorso più ricco)."""
    return max((v["obb"] for v in _sommario_anno(det, k).values()), default=0.0)


def _cfu_anno(det: dict, k: int) -> float:
    """CFU dichiarati dall'anno k (percorso più ricco: obbligatori e scelte con CFU fissi, più il minimo degli intervalli)."""
    s = _sommario_anno(det, k)
    if not s:
        return -1.0
    return max(v["obb"] + v["fissi"] + sum(lo for lo, _ in v["intervalli"]) for v in s.values())


# --- Siti delle strutture didattiche (Scuola di Medicina e Chirurgia, Scuola di Farmacia e Nutraceutica, Dipartimento di
# Giurisprudenza, Economia e Sociologia): «Elenco Insegnamenti Erogati» di ogni corso, una tabella per a.a. con titolo,
# docente, CFU, anno di corso, semestre (e il curriculum). Servono per i corsi che il catalogo Cineca non ha e per gli
# anni che il catalogo non ha (Logopedia, Neurofisiopatologia, 6° anno di Medicina e Odontoiatria).

HEADERS_SITO = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
_ANNI_TESTO = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
_SEM_TESTO = {"primo": "1", "secondo": "2", "annuale": "annuale", "terzo": "3", "1": "1", "2": "2"}
_ELETTIVO = re.compile(r"(?i)\ba\s+(?:libera\s+)?scelta\b|\blibera\s+scelta\b|\bopzional|\bscelta dello studente")
_SENZA_DOCENTE = re.compile(r"(?i)^\s*(?:non\s+presente|codocenza|da definire|-+)?\s*$")

# corsi con il piano solo sul sito: id Universitaly → dati del corso (la pagina del corso è la fonte)
SOLO_SITO: dict[str, dict] = {
    "1629505": dict(nome="Igiene dentale (abilitante alla professione sanitaria di Igienista dentale)", classe="L/SNT3",
                    durata=3, url="https://medicina.unicz.it/corso_studio/igiene_dentale"),
    "1629502": dict(nome="Infermieristica (abilitante alla professione sanitaria di Infermiere)", classe="L/SNT1", durata=3,
                    sede="Reggio Calabria (RC)", url="https://medicina.unicz.it/corso_studio/interateneo"),
    "1629516": dict(nome="Scienze delle Investigazioni", classe="L-14", durata=3,
                    url="https://www.diges.unicz.it/corso_studio/scienze_investigazioni"),
    "1629520": dict(nome="Scienze e Tecniche di psicologia Cognitiva", classe="L-24", durata=3,
                    url="https://medicina.unicz.it/corso_studio/scienze_tecniche_psicologia_cognitiva"),
    "1629521": dict(nome="SCIENZE E TECNOLOGIE COSMETICHE E DEI PRODOTTI DEL BENESSERE", classe="L-29", durata=3,
                    url="https://www.sfn.unicz.it/corso_studio/scienze_tecnologie_cosmetiche"),
    "1629525": dict(nome="Biotecnologie Innovative per la Salute", classe="LM-9", durata=2,
                    url="https://www.sfn.unicz.it/corso_studio/biotecnologie_innovative_salute"),
    "1625727": dict(nome="Economia, Data Analysis e Settore Pubblico", classe="LM-56 / LM-63", durata=2,
                    url="https://www.diges.unicz.it/corso_studio/economia_data_analysis_e_settore_pubblico"),
    "1625700": dict(nome="Healthcare Management", classe="LM-77", durata=2,
                    url="https://www.diges.unicz.it/corso_studio/healthcare_management"),
    "1629531": dict(nome="Psicologia Cognitiva e Neuroscienze", classe="LM-51", durata=2,
                    url="https://medicina.unicz.it/corso_studio/psicologia_cognitiva_neuroscienze"),
    "1629532": dict(nome="Psicologia forense e Criminologica", classe="LM-51", durata=2,
                    url="https://medicina.unicz.it/corso_studio/psicologia_forense_criminologia"),
    "1629534": dict(nome="Scienze Chimiche e Cosmetiche", classe="LM-71", durata=2,
                    url="https://www.sfn.unicz.it/corso_studio/scienze_chimiche_e_cosmetiche"),
    "1633920": dict(nome="Scienze delle professioni sanitarie tecniche diagnostiche", classe="LM/SNT3", durata=2,
                    url="https://medicina.unicz.it/corso_studio/lm_scienze_prof_sanitarie_tecniche_diagnostiche"),
    "1629533": dict(nome="SCIENZE E TECNICHE DELLE ATTIVITÀ MOTORIE PREVENTIVE E ADATTATE", classe="LM-67", durata=2,
                    url="https://www.medicina.unicz.it/corso_studio/scienze_tecniche_sport"),
    "1635759": dict(nome="Scienze infermieristiche e ostetriche - Profilo infermieristico", classe="LM/SNT1", durata=2,
                    url="https://medicina.unicz.it/corso_studio/scienze_infermieristiche_ostetriche"),
    "1629511": dict(nome="Scienze riabilitative delle professioni sanitarie", classe="LM/SNT2", durata=2,
                    url="https://www.medicina.unicz.it/corso_studio/scienze_riabilitative_prof_sanitarie"),
    "1629528": dict(nome="Medicina e chirurgia - TD", classe="LM-41", durata=6, sede="Crotone (KR)",
                    url="https://medicina.unicz.it/corso_studio/medicina_chirurgia_interateneo"),
    "1626060": dict(nome="Scienze della formazione primaria", classe="LM-85 bis", durata=5,
                    url="https://medicina.unicz.it/corso_studio/scienze_formazione_primaria"),
}

# corsi del catalogo: pagina del corso sul sito, per gli anni che il piano del catalogo non ha
SITO_CORSO = {
    "S962": "https://medicina.unicz.it/corso_studio/logopedia",
    "S994": "https://medicina.unicz.it/corso_studio/tecniche_neurofisiopatologia",
    "7560": "https://medicina.unicz.it/corso_studio/medicina_chirurgia",
    "7580": "https://medicina.unicz.it/corso_studio/odontoiatria_protesi_dentaria",
    "S203": "https://medicina.unicz.it/corso_studio/tecniche_laboratorio_biomedico",
}
# corsi del catalogo i cui insegnamenti a scelta offerti nell'a.a. (non elencati nei gruppi delle coorti) si leggono dal sito
SCELTE_SITO = {
    "7141": "https://medicina.unicz.it/corso_studio/ingegneria_informatica_biomedica",
    "7146": "https://www.diges.unicz.it/corso_studio/giurisprudenza",
    "7166": "https://medicina.unicz.it/corso_studio/ingegneria_biomedica",
    "7530": "https://www.diges.unicz.it/corso_studio/Sociologia_e_Servizio_Sociale",
    "7625": "https://www.sfn.unicz.it/corso_studio/stpa",
    "7693": "https://medicina.unicz.it/corso_studio/scienze_motorie_sportive",
    "7696": "https://www.sfn.unicz.it/corso_studio/biotecnologie",
    "7800": "https://www.diges.unicz.it/corso_studio/oapp",
    "7905": "https://www.diges.unicz.it/corso_studio/economia_aziendale",
    "7941": "https://www.diges.unicz.it/corso_studio/economia_aziendale_management",
    "7951": "https://www.sfn.unicz.it/corso_studio/farmacia",
}
_GENERICO = re.compile(r"(?i)^\s*(?:a\s+scelta|attivit[àa]\s+(?:formativ\w+\s+)?a\s+(?:libera\s+)?scelta|insegnamento\s+a\s+scelta|altre?\s+attivit)")


def _html_sito(url: str, log=print) -> str | None:
    d = os.environ.get("UN_HTTP_CACHE")
    f = pathlib.Path(d) / "unicz_sito" / (hashlib.sha1(url.encode()).hexdigest() + ".html") if d else None
    if f and f.exists():
        return f.read_text(encoding="utf-8")
    for tentativo in range(4):
        try:
            r = requests.get(url, headers=HEADERS_SITO, timeout=60)
            if r.status_code == 200 and "<table" in r.text:
                if f:
                    f.parent.mkdir(parents=True, exist_ok=True)
                    f.write_text(r.text, encoding="utf-8")
                return r.text
            if r.status_code == 404:
                return None
        except requests.RequestException:
            pass
        time.sleep(2 ** tentativo)
    log(f"[unicz] pagina non letta: {url}")
    return None


def _celle(tr: str) -> list[str]:
    return [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", x))).strip()
            for x in re.findall(r"<td[^>]*>(.*?)</td>", tr, flags=re.S)]


def _tabelle_sito(h: str) -> dict[int, list[dict]]:
    """{anno accademico (2026 = 2026/27): righe} dalle schede «Insegnamenti erogati». Due impaginazioni: Scuole
    (titolo, docente, CFU, anno, [numero], semestre, [curriculum]) e Dipartimento (titolo, docente, CFU, anno [numero],
    percorso, semestre [numero e testo])."""
    tabs = re.findall(r'href="#(\d+)_anno">\s*([^<]+?)\s*</a>', h)
    diges = False
    if not tabs:
        tabs = [(m[0], m[1]) for m in re.findall(
            r"data-bs-target=\"#anno_(\d+)_pane\".*?class='d-none d-lg-block'>\s*([^<]+?)\s*</div>", h, flags=re.S)]
        diges = True
    marcatori = {tid: (f"<div id='anno_{tid}_pane'" if diges else f"<div id='{tid}_anno'") for tid, _ in tabs}
    out: dict[int, list[dict]] = {}
    for tid, etichetta in tabs:
        m = re.match(r"(\d{4})/", etichetta)
        i = h.find(marcatori[tid])
        if not m or i < 0:
            continue
        fine = min([h.find(mk, i + 10) for mk in marcatori.values() if h.find(mk, i + 10) > 0] + [len(h)])
        righe = []
        for tr in re.findall(r"<tr>(.*?)</tr>", h[i:fine], flags=re.S):
            t = _celle(tr)
            if len(t) < 5:
                continue
            link = re.search(r'href="([^"]+)"', tr)
            if diges:
                anno, curr, sem = t[3], t[4], (t[6] if len(t) > 6 else t[5])
            elif len(t) >= 7:
                anno, curr, sem = t[3], "", t[5]
            else:
                anno, curr, sem = t[3], (t[5] if len(t) > 5 else ""), t[4]
            a = _ANNI_TESTO.get(anno.lower()) or (int(anno) if anno.isdigit() else None)
            try:
                cfu = float(t[2].replace(",", "."))
            except ValueError:
                continue
            righe.append({"titolo": t[0], "docente": t[1], "cfu": int(cfu) if cfu == int(cfu) else cfu, "anno": a,
                          "sem": _SEM_TESTO.get(sem.lower()), "curr": curr, "url": link.group(1) if link else None})
        out[int(m.group(1))] = righe
    return out


def _voci_anno(righe: list[dict]) -> list[dict]:
    """Righe di un anno di corso senza doppioni (stesso titolo, curriculum, CFU e semestre: sedi diverse dello stesso corso)."""
    voci: dict[tuple, dict] = {}
    for r in righe:
        if not r["cfu"] or r["cfu"] <= 0:
            continue
        elettivo = bool(_ELETTIVO.search(r["curr"] or "") or _ELETTIVO.search(r["titolo"]))
        curr = "" if _ELETTIVO.search(r["curr"] or "") else (r["curr"] or "")
        k = (_nn(r["titolo"]), curr, r["cfu"], r["sem"])
        v = voci.get(k)
        if not v:
            voci[k] = {**r, "curr": curr, "docenti": [], "elettivo": elettivo}
            v = voci[k]
        if not _SENZA_DOCENTE.match(r["docente"] or ""):
            v["docenti"] = sorted(set(v["docenti"]) | {r["docente"].strip()})
    return list(voci.values())


def _somma_obbligatori(voci: list[dict]) -> float:
    """CFU non a scelta dell'anno, con il curriculum più ricco."""
    comuni = sum(v["cfu"] for v in voci if not v["curr"] and not v["elettivo"])
    per_curr: dict[str, float] = {}
    for v in voci:
        if v["curr"] and not v["elettivo"]:
            per_curr[v["curr"]] = per_curr.get(v["curr"], 0) + v["cfu"]
    return comuni + max(per_curr.values(), default=0)


def _scegli_anno_sito(per_aa: dict[int, list[dict]], k: int, anno: int) -> tuple[int, list[dict]] | None:
    """Righe dell'anno di corso k: quelle dell'a.a. più recente la cui lista è completa (almeno il 90% dei CFU
    obbligatori della lista più ricca, fino a 70 CFU, tra gli ultimi quattro a.a.: la Scuola pubblica le liste un anno per
    volta)."""
    cand = []
    for aa in sorted((a for a in per_aa if a <= anno), reverse=True)[:4]:
        voci = _voci_anno([r for r in per_aa[aa] if r["anno"] == k])
        if voci:
            cand.append((aa, voci, _somma_obbligatori(voci)))
    if not cand:
        return None
    # liste «gonfie» (più di 70 CFU obbligatori: due coorti nella stessa tabella) non sono un anno di corso
    ragionevoli = [c for c in cand if c[2] <= 70] or cand
    migliore = max(c[2] for c in ragionevoli)
    for aa, voci, ob in ragionevoli:
        if ob > 0 and ob >= 0.9 * migliore:
            return aa, voci
    return ragionevoli[0][0], ragionevoli[0][1]


def _scelte_sito(url_corso: str, anno: int, durata: int, esistenti: set[str], log, noti=None, famiglia=None) -> list[dict]:
    """Insegnamenti a scelta offerti nell'a.a. `anno` dal sito del corso (righe «a libera scelta» o «(a scelta)»), non già nel
    piano: uno per nome, nel primo anno di corso in cui compaiono."""
    pagina = url_corso.rstrip("/") + "/insegnamenti"
    h = _html_sito(pagina, log)
    if not h:
        return []
    per_aa = _tabelle_sito(h)
    aa = max((a for a in per_aa if a <= anno), default=None)
    if aa is None:
        return []
    oggi = time.strftime("%Y-%m-%d")
    out: dict[str, dict] = {}
    for v in sorted(_voci_anno(per_aa[aa]), key=lambda v: v["anno"] or 99):
        if not v["elettivo"] or not v["anno"] or v["anno"] > durata or _GENERICO.search(v["titolo"]):
            continue
        nome = cc._titolo(re.sub(r"\s*\(\s*a\s+scelta\s*\)\s*$", "", v["titolo"], flags=re.I)).strip()
        k = _nn(nome)
        if k in esistenti or k in out:
            continue
        item = {"codice": None, "nome": nome, "anno": v["anno"], "periodo": v["sem"], "cfu": v["cfu"], "ssd": None,
                "obbligatorio": False, "curriculum": None, "docenti": v["docenti"], "url": v["url"] or pagina, "libri": [],
                "esami": [], "fonte": pagina, "verificato_il": oggi, "_percorsi": set(), "_tutti": set()}
        noto = (noti or {}).get("nome", {}).get((famiglia, _nk(v["titolo"])))
        if noto and noto.get("libri"):
            item["libri"], item["stato_libri"] = noto["libri"], "completo"
            for k_ in ("modalita_esame", "ssd", "url_sito"):
                if noto.get(k_):
                    item[k_] = noto[k_]
        out[k] = item
    return list(out.values())


def _ins_sito(url_corso: str, anni: list[int], anno: int, log, noti=None, famiglia=None) -> tuple[list[dict], dict]:
    """Insegnamenti degli `anni` di corso dal sito e, per ogni anno, da quale a.a. e pagina vengono."""
    pagina = url_corso.rstrip("/") + "/insegnamenti"
    h = _html_sito(pagina, log)
    if not h:
        return [], {}
    per_aa = _tabelle_sito(h)
    oggi = time.strftime("%Y-%m-%d")
    ins: list[dict] = []
    piano: dict[str, dict] = {}
    for k in anni:
        sc = _scegli_anno_sito(per_aa, k, anno)
        if not sc:
            continue
        aa, voci = sc
        piano[str(k)] = {"aa": aa, "url": pagina}
        # stesso titolo con CFU o semestri diversi (tirocini, laboratori): il nome porta il semestre o i CFU
        per_titolo: dict[tuple, list] = {}
        for v in voci:
            per_titolo.setdefault((_nn(v["titolo"]), v["curr"]), []).append(v)
        for gruppo in per_titolo.values():
            if len(gruppo) > 1:
                sem = [v["sem"] for v in gruppo]
                for v in gruppo:
                    if all(sem) and len(set(sem)) == len(sem):
                        v["suffisso"] = f" ({v['sem']}° semestre)" if v["sem"] in ("1", "2") else f" ({v['sem']})"
                    else:
                        v["suffisso"] = f" ({v['cfu']:g} CFU)"
        # stesso titolo con CFU diversi nei curricula (6 CFU in un percorso, 8 nell'altro): il nome porta i CFU
        per_t: dict[str, list] = {}
        for v in voci:
            per_t.setdefault(_nn(v["titolo"]), []).append(v)
        for gruppo in per_t.values():
            if len({v["cfu"] for v in gruppo}) > 1:
                for v in gruppo:
                    v.setdefault("suffisso", f" ({v['cfu']:g} CFU)")
        curricula = {v["curr"] for v in voci if v["curr"]}
        nuovi = []
        for v in voci:
            nome = cc._titolo(v["titolo"]) + v.get("suffisso", "")
            elettivo = v["elettivo"]
            item = {"codice": None, "nome": nome, "anno": k, "periodo": v["sem"], "cfu": v["cfu"], "ssd": None,
                    "obbligatorio": not elettivo, "curriculum": v["curr"] or None, "docenti": v["docenti"],
                    "url": v["url"] or pagina, "libri": [], "esami": [], "fonte": pagina, "verificato_il": oggi}
            noto = (noti or {}).get("nome", {}).get((famiglia, _nk(nome)))
            if noto and noto.get("libri"):
                item["libri"] = noto["libri"]
                item["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        item[k_] = noto[k_]
            nuovi.append(item)
        # voce presente in tutti i curricula con gli stessi CFU: comune a tutti
        if len(curricula) > 1:
            per_voce: dict[tuple, list] = {}
            for it in nuovi:
                if it["curriculum"]:
                    per_voce.setdefault((_nn(it["nome"]), it["cfu"], it["periodo"]), []).append(it)
            for lst in per_voce.values():
                if {i["curriculum"] for i in lst} == curricula:
                    lst[0]["curriculum"] = None
                    for altro in lst[1:]:
                        lst[0]["docenti"] = sorted(set(lst[0]["docenti"]) | set(altro["docenti"]))
                        nuovi.remove(altro)
        ins += nuovi
    return ins, piano



# --- Integrazioni dai «Piani di studio» ufficiali (PDF/DOCX della pagina «Piano di Studio» del corso): l'elenco degli
# insegnamenti erogati non ha seminari, tirocini, prova finale e crediti liberi, e per alcuni corsi un anno non è completo.
# Voci: (nome, CFU, semestre, obbligatorio, SSD). «aggiungi» aggiunge le voci mancanti all'anno del sito (con i CFU del
# piano); «sostituisci» sostituisce l'anno con quello del piano (i docenti, i link e i libri delle voci con lo stesso nome
# si riportano). I totali dell'anno tornano a quelli stampati nel piano («TOTALE CFU»).
_P = "https://medicina.unicz.it/scarica_allegato/"
PIANI_PDF: dict[str, dict] = {
    # Scienze della formazione primaria, piano 2026/27: 58 + 61 + 61 + 60 + 60 = 300 CFU
    "1626060": {"url": _P + "15659", "aa": 2026, "modo": "sostituisci", "anni": {
        1: [("Pedagogia generale", 8, "1", True, "PAED-01/A"),
            ("Psicologia clinica e disturbi dell'apprendimento", 8, "1", True, "MEDS-20/B"),
            ("Elementi di biologia e fisiologia umana con laboratorio", 13, "1", True, "BIOS-06/A"),
            ("Didattica generale", 8, "2", True, "PAED-02/A"), ("Pedagogia speciale con laboratorio", 10, "2", True, "PAED-02/A"),
            ("Metodi e didattiche delle attività motorie con laboratorio", 9, "2", True, "MEDF-01/A"),
            ("Inglese I", 2, "2", True, "ANGL-01/C")],
        2: [("Geografia con laboratorio", 9, "1", True, "GEOG-01/A"), ("Matematica di base con laboratorio", 9, "1", True, "MATH-01/B"),
            ("Tecniche per l'osservazione dello sviluppo tipico e atipico", 8, "1", True, "PSIC-02/A"),
            ("Letteratura italiana con laboratorio", 13, "2", True, "ITAL-01/A"),
            ("Pedagogia sociale e interculturale con laboratorio", 9, "2", True, "PAED-01/A"),
            ("Pedagogia sperimentale con laboratorio", 6, "2", True, "PAED-02/B"), ("Inglese II", 2, "2", True, "ANGL-01/C"),
            ("Tirocinio (T1)", 5, "2", True, None)],
        3: [("Disabilità ed inclusione con laboratorio", 10, "1", True, "PAED-02/A"),
            ("Musicologia e storia della musica con laboratorio", 9, "1", True, "PEMM-01/C"),
            ("Linguistica italiana con laboratorio", 7, "1", True, "LIFI-01/A"),
            ("Fondamenti di geometria con laboratorio", 13, "2", True, "MATH-01/B"),
            ("Teorie e metodi di programmazione e di valutazione", 7, "2", True, "PAED-02/B"),
            ("Insegnamento a scelta dello studente", 8, "2", False, None), ("Inglese III", 2, "2", True, "ANGL-01/C"),
            ("Tirocinio (T2)", 5, "2", True, None)],
        4: [("Sociologia dell'educazione", 8, "1", True, "GSPS-06/A"),
            ("Letteratura per l'infanzia con laboratorio", 9, "1", True, "PAED-01/B"),
            ("Storia e didattica della fisica con laboratorio", 9, "1", True, "PHYS-06/B"),
            ("Laboratorio di tecnologie didattiche", 3, "1", True, "PAED-02/A"),
            ("Storia greco-romana", 8, "2", True, "STAN-01/B"), ("Psicologia dell'educazione con laboratorio", 9, "2", True, "PSIC-02/A"),
            ("Fondamenti di didattica delle tecnologie per l'apprendimento con laboratorio", 6, "2", True, "PAED-02/A"),
            ("Inglese IV", 2, "2", True, "ANGL-01/C"), ("Tirocinio (T3)", 6, "2", True, None)],
        5: [("Didattica della lingua", 6, "1", True, "LIFI-01/A"), ("Elementi di didattica della chimica", 4, "1", True, "CHEM-03/A"),
            ("Storia della scuola e delle istituzioni educative", 8, "1", True, None),
            ("Storia moderna", 8, "2", True, "HIST-02/A"),
            ("Tecniche espressive e di educazione all'immagine con laboratorio", 9, "2", True, "PEMM-01/B"),
            ("Igiene scolastica", 4, "2", True, "MEDS-24/B"), ("Inglese V", 2, "2", True, "ANGL-01/C"),
            ("Prova di lingua inglese livello B2", 2, "2", True, None), ("Tirocinio (T4)", 8, "2", True, None),
            ("Prova finale", 9, "2", True, None)]}},
    # Logopedia, piano 2026/27: 31 + 29, 30 + 30, 30 + 30 CFU (le liste del sito sono di a.a. diversi e senza seminari)
    "1629504": {"url": _P + "15602", "aa": 2026, "modo": "sostituisci", "anni": {
        1: [("Scienze Biomediche I", 8, "1", True, None), ("Scienze Fisiche, Informatiche e Statistiche", 5, "1", True, None),
            ("Prevenzione Ambienti di Lavoro", 7, "1", True, None), ("Scienze della Comunicazione Umana", 6, "1", True, None),
            ("Tirocinio (1° semestre)", 5, "1", True, None),
            ("Scienze Biomediche II", 5, "2", True, None), ("Scienze Umane e Management", 8, "2", True, None),
            ("Scienze Medico-chirurgiche", 5, "2", True, None), ("Seminari (2° semestre)", 2, "2", True, None),
            ("Tirocinio (2° semestre)", 9, "2", True, None)],
        2: [("C.I. di Audiofoniatria I", 7, "1", True, None), ("C.I. di Clinica Otorinolaringoiatrica", 4, "1", True, None),
            ("C.I. di Chirurgia Laringea e Riabilitazione", 6, "1", True, None), ("Seminari (1° semestre)", 1, "1", True, None),
            ("Tirocinio (1° semestre)", 12, "1", True, None),
            ("C.I. di Neuroscienze", 5, "2", True, None), ("C.I. di Audiofoniatria II", 6, "2", True, None),
            ("Seminari (2° semestre)", 1, "2", True, None), ("A Scelta Dello Studente", 3, "2", False, None),
            ("Tirocinio (2° semestre)", 15, "2", True, None)],
        3: [("Disturbi del Linguaggio e della Deglutizione in Eta' Adulta", 6, "1", True, None),
            ("Disturbi del Linguaggio e della Deglutizione in Eta' Evolutiva", 8, "1", True, None),
            ("A Scelta Dello Studente (1° semestre)", 3, "1", False, None), ("Seminario", 2, "1", True, None),
            ("Tirocinio", 11, "1", True, None),
            ("Abilita' Informatico-linguistiche", 7, "2", True, None), ("Primo Soccorso", 7, "2", True, None),
            ("Laboratori Ssd", 3, "2", True, None), ("Prova Finale", 5, "2", True, None),
            ("Tirocinio Formativo e di Orientamento", 8, "2", True, None)]}},
    # Sociologia e servizio sociale (L-39/L-40), piano 2026/27, I anno in comune: 59 CFU (le coorti 2023-2024 del catalogo
    # hanno 56 CFU e altri insegnamenti: gli iscritti al 1° anno nel 2026/27 seguono il piano nuovo)
    "1633161": {"url": "https://www.diges.unicz.it/scarica_allegato/1731", "aa": 2026, "modo": "sostituisci", "anni": {
        1: [("Antropologia sociale", 10, "1", True, "SDEA-01/A"), ("Sociologia", 10, "1", True, "GSPS-05/A"),
            ("Progettazione sociale", 9, "1", True, "GSPS-08/A"), ("Informatica", 5, "1", True, "IINF-05/A"),
            ("Psicologia generale", 8, "1", True, "PSIC-01/A"), ("Statistica sociale", 6, "2", True, "STAT-03/B"),
            ("Diritto pubblico", 6, "2", True, "GIUR-05/A"), ("Inglese", 5, "2", True, "ANGL-01/C")]}},
    # LM-71, piano 2026/27: II anno 62 CFU (la prova finale da 8 CFU non è tra gli insegnamenti erogati)
    "1629534": {"url": "https://www.sfn.unicz.it/scarica_allegato/3656", "aa": 2026, "modo": "aggiungi",
                "anni": {2: [("Prova finale", 8, None, True, None)]}},
    # LM/SNT3, piano 2026/27: II anno 30 + 30 CFU (il tirocinio del 1° semestre e la prova finale/lingua non sono erogati)
    "1633920": {"url": _P + "15704", "aa": 2026, "modo": "aggiungi",
                "anni": {2: [("Tirocinio (1° semestre)", 9, "1", True, None),
                             ("Prova finale e lingua straniera", 6, "2", True, None)]}},
    # Igiene dentale, piano 2026/27: II anno, 2° semestre 30 CFU (manca «Scienze e tecniche dell'igiene dentale II», 5 CFU)
    "1629505": {"url": _P + "15657", "aa": 2026, "modo": "aggiungi",
                "anni": {2: [("Scienze e Tecniche dell'Igiene Dentale II", 5, "2", True, None)]}},
}


def _applica_pdf(idu: str | None, ins: list[dict], piano_anni: dict, noti: dict | None, famiglia: str | None) -> list[dict]:
    cfg = PIANI_PDF.get(idu or "")
    if not cfg:
        return ins
    oggi = time.strftime("%Y-%m-%d")
    for k, righe in cfg["anni"].items():
        vecchi = [i for i in ins if i["anno"] == k]
        if cfg["modo"] == "sostituisci":
            ins = [i for i in ins if i["anno"] != k]
        for nome, cfu, periodo, obbl, ssd in righe:
            base = next((v for v in vecchi if _nn(v["nome"]) == _nn(nome)), None)
            if cfg["modo"] == "aggiungi" and base:
                continue
            item = {"codice": None, "nome": nome, "anno": k, "periodo": periodo or (base or {}).get("periodo"), "cfu": cfu,
                    "ssd": ssd or (base or {}).get("ssd"), "obbligatorio": obbl, "curriculum": None,
                    "docenti": list((base or {}).get("docenti") or []), "url": (base or {}).get("url") or cfg["url"],
                    "libri": [], "esami": [], "fonte": cfg["url"], "verificato_il": oggi}
            noto = (base if base and base.get("libri") else None) or (noti or {}).get("nome", {}).get((famiglia, _nk(nome)))
            if noto and noto.get("libri"):
                item["libri"] = noto["libri"]
                item["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "url_sito"):
                    if noto.get(k_):
                        item[k_] = noto[k_]
            ins.append(item)
        piano_anni[str(k)] = {"coorte": None, "aa": cfg["aa"], "url": cfg["url"]}
    return ins



def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    # corsi di tutte le coorti: il catalogo pubblica l'elenco dell'ultima coorte solo per una parte dei corsi (i corsi
    # magistrali e a ciclo unico ci sono fino alla coorte 2024), ma gli iscritti al 2°-6° anno seguono i piani vecchi
    attuali: list[dict] = []
    for y in range(anno, anno - 7, -1):
        for x in coorti[y]:
            if not any(a["cdsCod"] == x["cdsCod"] or _cod_base(a["cdsCod"]) == _cod_base(x["cdsCod"])
                       or (_norm(a.get("des_it")), a.get("tipo_corso_cod")) == (_norm(x.get("des_it")), x.get("tipo_corso_cod"))
                       for a in attuali):
                attuali.append(x)
    if max_cds:
        attuali = attuali[:max_cds]
    log(f"[{uid}] {len(attuali)} corsi di studio nelle coorti {anno - 6}-{anno}")

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
        for x in elenco:
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]):
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        if len(stessi) == 1:
            return stessi[0]
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("tipo_corso_cod")) == chiave[::2]]
        if len(stessi) == 1:
            return stessi[0]
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
        anno_rec = anno if anno in cohorts else max(cohorts)
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")

        # nome canonico dei percorsi: quello della coorte più recente che li ha. Il confronto è con i percorsi delle
        # coorti già viste (mai con quelli della stessa coorte: «… 1» e «… 2» sono percorsi diversi)
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple[str, str, str]] = []  # (chiave, codice, nome canonico)
        for y in sorted(cohorts, reverse=True):
            det = cohorts[y][1]
            ps = det.get("percorsi") or []
            cods = [p.get("pdsCod") or "" for p in ps]
            visti = list(riferimento)
            nuovi = []
            for p in ps:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                ch = _chiave_percorso(pn)
                cod = (p.get("pdsCod") or "").strip()
                num = re.search(r"\d+", ch)
                trovato = next((r for r in visti if r[0] == ch), None)
                if not trovato and cod and cods.count(cod) == 1:
                    cand = [r for r in visti if r[1] == cod and cod not in ("PDS0", "GEN", "COMUNE")]
                    trovato = cand[0] if len(cand) == 1 else None
                if not trovato:  # nome cambiato di poco («Percorso Rigenerazione urbana» → «Percorso Rigenerazione»)
                    num_r = {r[0]: (re.search(r"\d+", r[0]) or [None])[0] for r in visti}
                    stessi = [r[0] for r in visti if (num_r[r[0]] == (num[0] if num else None))
                              and (len(min(ch, r[0], key=len)) >= 6 and (r[0].startswith(ch) or ch.startswith(r[0])))]
                    simili = difflib.get_close_matches(ch, [r[0] for r in visti if num_r[r[0]] == (num[0] if num else None)],
                                                       n=1, cutoff=0.8)
                    scelto = (stessi or simili or [None])[0]
                    trovato = next((r for r in visti if r[0] == scelto), None) if scelto else None
                if not trovato:
                    trovato = (ch, cod, _nome_percorso(pn))
                    nuovi.append(trovato)
                canon[(y, pn)] = trovato[2]
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            """Coorte del piano per l'anno k: quella degli iscritti (A-k+1) se ha l'anno, altrimenti la più vicina che
            lo ha (a parità la più recente). «Ha l'anno» = almeno 30 CFU obbligatori: un anno con le sole scelte
            (coorte appena inserita) o con l'elenco vuoto non è un piano."""
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((cur.get("cdsCod"), k))
            if forzata in cohorts:
                return forzata
            ha = {y: _obb_anno(d, k) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v >= MIN_OBBLIGATORI_ANNO}
            if not ha:
                return None
            if y0 in ha:
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        # stessa attività offerta in altre coorti/anni accademici: schede alternative per i libri
        alt_per_ad: dict[str, dict] = {}
        for y, (_, d) in cohorts.items():
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            alt_per_ad.setdefault(att.get("adCod") or att.get("cod"), {})[
                                (str(att.get("aa")), str(att.get("cod")))] = (y, att)
        # CFU di un'attività con 0 CFU in un piano e CFU nell'altro
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        debiti: list[str] = []
        piano_anni: dict[str, dict] = {}
        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            sommario = _sommario_anno(d, k)
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}", "sommario": sommario}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(str(a.get("anno")).isdigit() and int(a["anno"]) == k for a in p.get("anni") or [])]
            nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi_k}
            anni_p = {n: max(int(a["anno"]) for a in p.get("anni") or [] if str(a.get("anno")).isdigit())
                      for n, p in nomi_k.items()}
            # percorsi comuni: «… comune» o un piano che copre solo i primi anni quando gli altri percorsi li coprono tutti
            comuni = {n for n in nomi_k if _COMUNE.search(n) or (len(nomi_k) > 1 and anni_p[n] < max(anni_p.values()))}
            specifici = [n for n in nomi_k if n not in comuni]
            curricula = {canon[(scelta, n)] for n in specifici} if len(specifici) >= 2 else set()
            for pnome, p in nomi_k.items():
                comune = pnome in comuni or not curricula
                pcur = None if comune else canon[(scelta, pnome)]
                for a in p.get("anni") or []:
                    if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                        continue
                    for g in _gruppi_di_anno(a):
                        atts = [t for t in g.get("attivita") or [] if not _e_frequenza(t)]
                        label = g.get("label_it") or ""
                        if not atts:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                            cfu_g = _cfu_etichetta(label)
                            nome = _nome_gruppo(label)
                            if not cfu_g or len(nome) < 3:
                                continue
                            key = f"{k}:#{_norm(nome)}:{cfu_g[1]:g}"
                            item = insegnamenti.get(key)
                            if not item:
                                item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu_g[1],
                                        "ssd": None, "obbligatorio": False, "curriculum": None, "_percorsi": set(),
                                        "_tutti": curricula, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                        "libri": [], "esami": [], "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                                insegnamenti[key] = item
                            if comune:
                                item["_comune"] = True
                            elif pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
                            continue
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            if _DEBITO.search(att.get("des_it") or "") and not att.get("crediti"):
                                nome_d = re.sub(r"(?i)^\s*debito\s+", "", cc._titolo(att["des_it"])).strip()
                                debiti.append(nome_d)
                                continue
                            obbl = _obbligatorio(g, att, atts)
                            key = f"{k}:{ad}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": att.get("crediti") or cfu_noti.get(ad) or att.get("crediti"), "ssd": None,
                                    "obbligatorio": bool(obbl), "curriculum": None, "_percorsi": set(), "_tutti": curricula,
                                    "docenti": sorted(set(docenti)),
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
                                        "famiglia": FAMIGLIA.get(ID_UNIVERSITALY.get(cur.get("cdsCod")), ID_UNIVERSITALY.get(cur.get("cdsCod"))),
                                        "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                                            alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                                            if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                                    })["items"].append(item)
                            elif obbl:
                                item["obbligatorio"] = True
                            if comune:
                                item["_comune"] = True
                            elif pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
        # anni che il piano del catalogo non ha: elenco degli insegnamenti erogati dal sito del corso
        sito = SITO_CORSO.get(cur.get("cdsCod"))
        mancanti = [k for k in range(1, durata + 1) if str(k) not in piano_anni]
        if sito and mancanti:
            ins_s, piano_s = _ins_sito(sito, mancanti, anno, log, libri_noti, FAMIGLIA.get(ID_UNIVERSITALY.get(cur.get("cdsCod")),
                                                                                       ID_UNIVERSITALY.get(cur.get("cdsCod"))))
            for n_, it in enumerate(ins_s):
                it["_percorsi"], it["_tutti"] = set(), set()
                insegnamenti[f"{it['anno']}:#sito{n_}"] = it
            for k_, v in piano_s.items():
                piano_anni[k_] = {"coorte": None, "aa": v["aa"], "url": v["url"]}
        scelte_url = SCELTE_SITO.get(cur.get("cdsCod"))
        if scelte_url:
            esistenti = {_nn(i["nome"]) for i in insegnamenti.values()} | {_nn(re.sub(r"\(\s*a\s+scelta\s*\)", "", i["nome"], flags=re.I))
                                                                             for i in insegnamenti.values()}
            for n_, it in enumerate(_scelte_sito(scelte_url, anno, durata, esistenti, log, libri_noti,
                                                 FAMIGLIA.get(ID_UNIVERSITALY.get(cur.get("cdsCod")), ID_UNIVERSITALY.get(cur.get("cdsCod"))))):
                insegnamenti[f"{it['anno']}:#scelta{n_}"] = it
        for (cds_c, anno_c), regole in CORREZIONI.items():
            if cds_c != cur.get("cdsCod"):
                continue
            for key, item in list(insegnamenti.items()):
                regola = regole.get(item.get("codice") or item["nome"]) if item["anno"] == anno_c else None
                if regola == "escludi":
                    del insegnamenti[key]
                elif regola == "scelta":
                    item["obbligatorio"] = False
                elif regola and regola.startswith("cfu="):
                    item["cfu"] = int(regola[4:])
        # attività a 0 CFU nel piano (OFA, sicurezza, prove di verifica): non sono insegnamenti del piano
        for key, item in list(insegnamenti.items()):
            if not item.get("cfu"):
                del insegnamenti[key]
        ins = list(insegnamenti.values())
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        # stesso nome nello stesso anno con codici e CFU diversi (alternative omonime): il nome porta i CFU
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"] if i.get("codice") else None), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    if isinstance(i["cfu"], (int, float)):
                        i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        # stesso nome, anno e curriculum con codici diversi e gli stessi CFU: lo stesso insegnamento a scelta con due codici
        # si unisce; i tirocini e i laboratori in più codici restano distinti e il nome porta il semestre o il codice
        per_nome2: dict[tuple, list] = {}
        for i in ins:
            if i.get("codice"):
                per_nome2.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome2.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if all(not i["obbligatorio"] for i in gruppo_i) and len({i["cfu"] for i in gruppo_i}) == 1:
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
            nomi = [t for t in dict.fromkeys(debiti) if t]
            frase = "Debiti formativi (OFA) previsti dal piano di studi" + (": " + ", ".join(nomi) if nomi else "")
            if frase.lower() not in (amm.get("requisiti") or "").lower():
                amm["requisiti"] = ((amm.get("requisiti") or "").rstrip() + "\n" + frase + ".").strip()
            if amm.get("ofa") is None:
                amm["ofa"] = True
        ins = _applica_pdf(ID_UNIVERSITALY.get(cur.get("cdsCod")), ins, piano_anni, libri_noti,
                           FAMIGLIA.get(ID_UNIVERSITALY.get(cur.get("cdsCod")), ID_UNIVERSITALY.get(cur.get("cdsCod"))))
        out = {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno_rec}/{rec[0]['cod']}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        if cur.get("cdsCod") in ID_UNIVERSITALY:
            out["id_universitaly"] = ID_UNIVERSITALY[cur["cdsCod"]]
        return out

    def build_safe(cur: dict) -> dict | None:
        try:
            return build_cds(cur)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {cur.get('cdsCod')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    # corsi che il catalogo non ha: il piano è l'elenco degli insegnamenti erogati dal sito del corso
    oggi_s = time.strftime("%Y-%m-%d")
    for idu, cfg in SOLO_SITO.items():
        ins_s, piano_s = _ins_sito(cfg["url"], list(range(1, cfg["durata"] + 1)), anno, log, libri_noti, FAMIGLIA.get(idu, idu))
        ins_s = _applica_pdf(idu, ins_s, piano_s, libri_noti, FAMIGLIA.get(idu, idu))
        if not ins_s:
            continue
        curricula = sorted({i["curriculum"] for i in ins_s if i["curriculum"]})
        corsi_out.append({
            "id_universitaly": idu, "nome": cfg["nome"], "classe": cfg["classe"], "durata_anni": cfg["durata"],
            "sede": cfg.get("sede") or "CATANZARO (CZ)", "codice_ateneo": None, "url": cfg["url"],
            "curricula": curricula or None, "ammissione": None,
            "piano_anni": {k: {"coorte": None, "aa": v["aa"], "url": v["url"]} for k, v in piano_s.items()},
            "fonte": cfg["url"].rstrip("/") + "/insegnamenti", "verificato_il": oggi_s, "insegnamenti": ins_s})
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        noto = libri_noti.get("cod", {}).get(job.get("codice")) or libri_noti.get("nome", {}).get(
            (job.get("famiglia"), _nk(job["items"][0]["nome"])))
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
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    _id_espliciti(corsi_out)
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unicz.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _slug(s: str, maxlen: int) -> str:
    """Come build_db.slug: l'id degli insegnamenti è `<corso>-<slug del codice o del nome, 40 caratteri>`."""
    return _nn(s).replace(" ", "-")[:maxlen].strip("-")


def _id_espliciti(corsi: list[dict]) -> None:
    """Due insegnamenti del corso i cui nomi hanno le prime 40 lettere uguali («… dell'igiene dentale I», «… II» e «… III»,
    «… in età adulta» e «… in età evolutiva») avrebbero lo stesso id e build_db ne farebbe uno solo, con i CFU del primo:
    a questi si dà l'id completo (`<id del corso nel database>-<slug del nome>`)."""
    try:
        doc = json.loads((ROOT / "database" / "corsi" / "unicz.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    ids = {c.get("id_universitaly"): c["id"] for c in doc.get("corsi") or [] if c.get("id_universitaly")}
    for corso in corsi:
        cid = ids.get(corso.get("id_universitaly"))
        if not cid:
            continue
        gruppi: dict[tuple, list] = {}
        for i in corso["insegnamenti"]:
            gruppi.setdefault(_slug(i.get("codice") or i["nome"], 40), []).append(i)
        for g in gruppi.values():
            if len(g) > 1 and len({_nn(i["nome"]) for i in g}) > 1 and not any(i.get("codice") for i in g):
                for i in g:
                    i["id"] = f"{cid}-{_slug(i['nome'], 90)}"


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database (nessuna nuova richiesta), per codice dell'insegnamento e per
    corso di Universitaly e nome (gli insegnamenti dei siti non hanno il codice, quelli del catalogo lo cambiano da coorte
    a coorte). Con la variabile d'ambiente UNICZ_LIBRI_DB (un altro `corsi/unicz.json`, per esempio la copia prima di una
    ricostruzione) si leggono anche i libri di quel file."""
    per_cod: dict[str, dict] = {}
    per_nome: dict[tuple, dict] = {}
    percorsi = [ROOT / "database" / "corsi" / "unicz.json"]
    if os.environ.get("UNICZ_LIBRI_DB"):
        percorsi.append(pathlib.Path(os.environ["UNICZ_LIBRI_DB"]))
    for p in percorsi:
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            fam = FAMIGLIA.get(corso.get("id_universitaly"), corso.get("id_universitaly"))
            for i in corso.get("insegnamenti") or []:
                if not i.get("libri") or not i.get("nome"):
                    continue
                info = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
                if i.get("codice"):
                    per_cod.setdefault(i["codice"], info)
                per_nome.setdefault((fam, _nk(i.get("nome"))), info)
    return {"cod": per_cod, "nome": per_nome}


def fetch_ateneo(uid: str = "unicz", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unicz.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unicz] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
