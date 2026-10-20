"""Università degli Studi della Basilicata: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unibas.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) il catalogo dell'UniBas richiede:

- durata dal piano («3 anni», «5 anni», «6 anni»): l'elenco minimale non ha `durataAnni` e senza di essa
  tutti i corsi avevano 3 anni (lauree magistrali, cicli unici di Farmacia, Architettura, Medicina e Scienze
  della formazione primaria sbagliati);
- codici del corso che cambiano con il riordino del 2025 («0127» → «1301»): la coorte precedente si ritrova
  per codice, senza il suffisso o per nome, sede e tipo; le righe dell'elenco senza piano nella coorte attuale
  (vecchi ordinamenti ad esaurimento, es. «0121» Scienze e tecnologie informatiche) non si leggono: il piano del
  corso attivo copre già tutti gli anni;
- piano senza anni (`anno` «altreAttivita»: la maggior parte delle coorti 2025 e 2026 e, nelle coorti con gli
  anni, le attività che non stanno in nessun anno): l'anno di ogni attività è l'anno accademico di erogazione
  (`aa`) meno la coorte più uno (verificato sui piani ufficiali dei dipartimenti); le attività «OBB» sono
  obbligatorie, «OPZ» o senza tipo a scelta; nelle coorti con gli anni le attività solo «altreAttivita» a scelta
  (offerta di insegnamenti) non si riportano, quelle obbligatorie (prova finale, lingua) sì;
- anno di corso: per l'anno k si usa il piano della coorte (anno - k + 1), la coorte degli iscritti oggi al
  k-esimo anno; se quella coorte non ha l'anno o ha un piano molto parziale, la coorte più vicina dello stesso
  ordinamento che lo ha; l'url di ogni insegnamento riporta la coorte (`?coorte=`);
- gruppi senza attività elencate: crediti fissi («TIROCINIO (3 CFU)») o liberi («A SCELTA DELLO STUDENTE (fra 0.5 e
  12 CFU)»), come in `unime`; gruppi con CFU fissi uguali alla somma delle attività: si sostengono tutte;
- percorsi: «CORSO GENERICO», «PIANO DI STUDI GENERALE» (codice GEN con altri curricula) valgono per tutti i
  curricula; i piani «da sottoporre ad approvazione» e gli «alternativi» delle coorti con l'approvazione del piano
  non sono curricula e non si leggono; «… AUTOMATICA APPROVAZIONE» è il curriculum «…»;
- `ID_CORSI`: i corsi del catalogo vanno al corso giusto del database.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unibas.json` mantenendo appelli e canali già presenti):

    python tools/db_builder/adapters/unibas.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import copy
import hashlib
import json
import os
import pathlib
import re
import sys
import time

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .uniba import _durata, _norm, libri_testo_libero  # noqa: E402

BASE = "https://unibas.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici

# codice (`cod`) del corso nella coorte 2026 → id dei corsi del database a cui va il piano. Serve dove il
# confronto di build_db per nome e classe sbaglia (nessun caso per ora).
ID_CORSI: dict[str, list[str]] = {}

# Corsi del catalogo che non si riportano: ad esaurimento e senza un corso di Universitaly (build_db li unirebbe per
# classe e nome al corso omonimo più vicino e il suo piano finirebbe nel corso sbagliato). Codice `cdsCod` → motivo.
ESCLUSI: dict[str, str] = {
    "1103": "Scienze forestali e ambientali (L-25, ad esaurimento): confluirebbe nel corso omonimo LM-73, che è un altro corso",
    "1107": "Paesaggio, ambiente e verde urbano (L-21, Matera, ad esaurimento): confluirebbe in «Scienze e tecnologie "
            "per il verde urbano, il paesaggio e le foreste» (L-21/L-25), che è un altro corso",
}

# Voci dei piani ufficiali dei dipartimenti che il catalogo non ha (lingua inglese, tirocinio, prova finale, «altre
# conoscenze», attività a scelta di cui il catalogo non dà i CFU): il catalogo elenca le attività erogate nell'a.a. e gli
# anni risultavano di 50-58 CFU. Per ogni corso (codice `cdsCod` della coorte 2026): documento ufficiale e righe
# (anno di corso, nome, CFU, obbligatoria). Ogni riga è nella tabella dell'anno del documento (Manifesto degli studi
# a.a. 2026/27: I anno coorte 2026/27, II anno coorte 2025/26, III anno coorte 2024/25).
_DISBA = "https://disba.unibas.it/site/home/didattica/offerta-didattica/documento29050230.html"  # Manifesto DISBA 2026/27
PIANO_EXTRA: dict[str, dict] = {
    "1301": {"fonte": _DISBA, "voci": [(1, "Inglese", 4, True), (3, "Tirocinio o internato di laboratorio", 6, True)]},
    "1303": {"fonte": _DISBA, "voci": [
        (1, "Inglese", 4, True),
        (2, "Altre conoscenze utili per l'inserimento nel mondo del lavoro", 1, True)]},
    "1305": {"fonte": _DISBA, "voci": [
        (1, "Inglese", 3, True), (3, "Campo geologico multidisciplinare", 4, True),
        (3, "Insegnamenti a scelta", 12, False), (3, "Tirocinio formativo", 4, True), (3, "Relazione finale", 3, True)]},
    "1307": {"fonte": _DISBA, "voci": [
        (1, "Inglese (livello B1)", 3, True),
        (3, "Altre conoscenze utili per l'inserimento nel mondo del lavoro", 3, True), (3, "Prova finale", 7, True)]},
    "1302": {"fonte": _DISBA, "voci": [(2, "Prova finale", 25, True)], "scelte": {2: 8}},
    "1304": {"fonte": _DISBA, "voci": [(2, "Tirocinio", 6, True)]},
    "1306": {"fonte": _DISBA, "voci": [
        (2, "Tirocinio formativo", 6, True), (2, "Seminari professionalizzanti", 3, True),
        (2, "Tesi magistrale", 24, True)], "scelte": {2: 18}},
    "1308": {"fonte": _DISBA, "voci": [(1, "Insegnamento a scelta", 6, False)]},
    "1201": {"fonte": "https://diss.unibas.it/site/home/didattica/documento27050284.html",  # Manifesto DiSS 2026/27
             "voci": [(1, "Inglese (B2)", 3, True), (2, "Botanica farmaceutica e farmacognosia", 12, True, "FAR0014")]},
    "1001": {"fonte": "https://diing.unibas.it/site/home/didattica/offerta-didattica/documento26051529.html",  # Piano di studi 2026-27
             "voci": [(3, "Materie a scelta", 12, False)]},
    "1106": {"fonte": "https://dafe.unibas.it/site/home/didattica/offerta-didattica/manifesto-degli-studi/documento32050721.html",
             "voci": [(1, "Inglese B2", 3, True)]},  # Manifesto DAFE 2026/27
    "1003": {"fonte": "https://informatica.unibas.it/informatica/laurea/triennale/piani-di-studio/coorte-2025-2026",
             "voci": [(2, "Materia a scelta", 12, False)]},
    "1109": {"fonte": "https://dafe.unibas.it/site/home/didattica/offerta-didattica/documento32050728.html",  # Reg. didattico 2026-27
             "voci": [(3, "Insegnamenti a scelta", 12, False)]},
}
# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto sul catalogo:
# (cdsCod, anno di corso) → coorte. L'anno è comunque quello del corso.
COORTE_ANNO: dict[tuple[str, int], int] = {
    ("1001", 3): 2026,  # Ingegneria civile e ambientale: il 3° anno della coorte 2024 ha la «scelta percorso» senza CFU
    # Scienze e tecnologie informatiche (L-31, ad esaurimento: nel 2026/27 non c'è il 1° anno, sostituito dal corso L-8):
    # il piano della coorte 2025 è completo (54+57+69 CFU, https://informatica.unibas.it/informatica/laurea/triennale/
    # piani-di-studio/coorte-2025-2026); la coorte 2026 del catalogo ha solo gli insegnamenti ancora erogati
    ("1003", 1): 2025, ("1003", 2): 2025, ("1003", 3): 2025,
}
# Correzioni al catalogo dove il piano ufficiale dice altro: (cdsCod, anno) → {codice dell'attività: "scelta" | "escludi"}
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {
    ("1305", 3): {"DIS0162": "scelta", "SMF0347": "scelta"},  # Geologia regionale e Geomorfologia applicata: a scelta (D)
    # Ingegneria informatica (L-8): la «Materia a scelta» vale 12 CFU nel piano 2026-27 del corso
    # (https://informatica.unibas.it/informatica/laurea/triennale/piani-di-studio/coorte-2026-2027), 6 nel catalogo
    ("1008", 2): {"ING0264": "cfu=12"},
    # Biotecnologie: «Proteomica e allergenomica» (mutuato da Scienze chimiche) vale 6 CFU nell'elenco delle attività a scelta
    # del Manifesto DISBA 2026/27; nel catalogo della coorte 2024 ha 0 CFU
    ("1301", 3): {"DIS0248": "cfu=6"},
    # Scienze e tecnologie informatiche (L-31): la scelta di 12 CFU è al 2° anno nel piano ufficiale della coorte 2025
    ("1003", 3): {"Insegnamenti a scelta III anno": "escludi"},
}

_SEDI = ("POTENZA", "MATERA")
_PART_TIME = re.compile(r"(?i)part[\s.-]*time|\bP\.\s?T\.|\b\d+\s*rate\b|\brate\s*\d")
_COMUNE = re.compile(r"(?i)\b(?:comune|statutario|generico)\b|^\s*statutory\b")
_CLASSE = re.compile(r"(?i)\bclasse\b|\bLM?[-\s]?\d{1,2}\b")
_PREFISSO = re.compile(r"(?i)^\s*(?:curriculum|percorso|orientamento|orientation)\s*:?\s+")
_DEBITO = re.compile(r"(?i)^\s*(?:debito\b|ofa\b|debt\b)|\bofa debt\b")
_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_ALTERNATIVA = re.compile(r"(?i)^\s*(?:oppure|or|o)\s+")
_E_ANCHE = re.compile(r"(?i)^\s*(?:e/oppure|e/o|and/or)\s+")
_PICCOLE = {"e", "di", "del", "della", "dello", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla",
            "il", "la", "lo", "le", "gli", "i", "ed", "nel", "nella", "dell'", "sul", "tra", "o", "oppure", "or",
            "of", "the", "and", "from", "by"}


def _cod_base(cds: str | None) -> str:
    """Il codice del corso cambia con il riordino («4035» → «4035R»): senza il suffisso è lo stesso corso."""
    return re.sub(r"(?<=\d)R$", "", (cds or "").strip().upper())


def _numero(s: str) -> float:
    return float(s.replace(",", "."))


def _un(d):
    return d[0] if isinstance(d, list) and d else d


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unibas)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unibas" if d else None

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
    """«A SCELTA DELLO STUDENTE» → «A scelta dello studente» (le sigle restano)."""
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        return s[:1].upper() + s[1:]
    parole = s.lower().split()
    out = []
    for i, w in enumerate(parole):
        if re.fullmatch(r"[ivx]+", w):
            out.append(w.upper())
        elif i == 0:
            out.append(w[:1].upper() + w[1:])
        else:
            out.append(w)
    return " ".join(out)


def _gruppo_senza_attivita(g: dict):
    """Gruppo del piano senza attività elencate ma con i CFU nell'etichetta: crediti fissi («TIROCINIO (3 CFU)»)
    o liberi («A SCELTA DELLO STUDENTE (fra 0.5 e 12 CFU)»). → (nome, cfu, fisso, alternativa) o None."""
    label = g.get("label_it") or ""
    m = _ETICHETTA_CFU.search(label)
    if not m:
        return None
    cfu = _numero(m.group(2))
    cfu = int(cfu) if cfu == int(cfu) else cfu
    resto = _ETICHETTA_CFU.sub(" ", label)
    alt = bool(_ALTERNATIVA.match(resto))
    resto = _E_ANCHE.sub("", _ALTERNATIVA.sub("", resto))
    nome = _titolo_etichetta(resto)
    if len(nome) < 3:
        return None
    return nome, cfu, m.group(1) is None, alt


def _gruppo_per_intero(g: dict) -> bool:
    """Gruppo con CFU richiesti fissi («(12 CFU)») uguali alla somma delle sue attività: si sostengono tutte,
    non è una scelta (es. un blocco con una sola attività)."""
    m = _ETICHETTA_CFU.search(g.get("label_it") or "")
    if not m or m.group(1) is not None:
        return False
    tot = sum(float(a.get("crediti") or 0) for a in g.get("attivita") or [])
    return bool(g.get("attivita")) and tot > 0 and abs(tot - _numero(m.group(2))) < 1e-6


def _sede_corso(cur: dict) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^A-Z ]", "", (cur.get("sede_des_it") or "").upper())).strip()


def _percorso_ok(pnome: str, sede: str) -> bool:
    """Percorsi che sono curricula o piani del corso: non i part-time né i piani di un'altra sede."""
    if _PART_TIME.search(pnome):
        return False
    citate = [s for s in _SEDI if re.search(rf"\b{s}\b", pnome.upper())]
    return not citate or sede in citate


_SEDI_RE = "|".join(_SEDI)


def _chiave_nome(pnome: str) -> str:
    """Chiave del nome di un curriculum (senza prefissi, parentesi, «automatica approvazione»), per riconoscerlo tra
    le coorti. Se resta solo la classe («CLASSE LM-02») la classe è il nome."""
    n = _nome_pulito(re.sub(r"\(.*?\)", " ", pnome))
    n = _PREFISSO.sub("", n.strip())
    n = re.sub(r"(?i)\bpiano\b|\bclasse\b", " ", n)
    m = re.search(r"(?i)\b(LM?)[\s-]*(\d{1,2})\b", n)
    senza = re.sub(r"(?i)\bLM?[\s-]*\d{1,2}\b", " ", n)
    testo = re.sub(r"[^a-z0-9]+", " ", senza.lower()).strip()
    if testo or not m:
        return testo
    return f"{m.group(1).lower()} {int(m.group(2))}"


def _nome_percorso(pnome: str) -> str:
    """Nome da mostrare: quello del catalogo senza prefisso né «automatica approvazione»."""
    n = _PREFISSO.sub("", _nome_pulito(pnome))
    return re.sub(r"\s+", " ", n).strip(" :-")


def _e_comune(pnome: str) -> bool:
    """Percorso valido per tutti i curricula («PIANO STATUTARIO», «PERCORSO COMUNE»); non quelli di una classe."""
    return bool(_COMUNE.search(pnome)) and not _CLASSE.search(pnome)


_FREQUENZA = re.compile(r"(?i)\(\s*(?:fr|frequency only|solo frequenza)\s*\)\s*$")


def _e_frequenza(att: dict) -> bool:
    """«Anatomia (FR)», «Biochemistry (frequency only)»: la frequenza a 0 CFU di un insegnamento integrato; i CFU
    sono nell'insegnamento stesso (nello stesso piano o in quello di un'altra coorte)."""
    return not att.get("crediti") and bool(_FREQUENZA.search((att.get("des_it") or "").strip()))


_DA_APPROVARE = re.compile(r"(?i)da\s+(?:sottoporre\s+ad\s+)?approv\w*|\balternativ\w*")
_AUTOMATICA = re.compile(r"(?i)\s*\(?\s*da\s+sottoporre\s+ad\s+approvazione\s*\)?|\s*\b(?:di\s+)?automatica\s+approvazione\b"
                         r"|\s*-?\s*\bapprovato\b")


def _percorsi_validi(det: dict, sede: str) -> list[dict]:
    """Percorsi del piano che sono curricula o piani comuni del corso: non i part-time, né i piani «da sottoporre ad
    approvazione» o «alternativi» quando lo stesso codice di percorso ha anche il piano di automatica approvazione
    (varianti dello stesso piano nelle coorti con l'approvazione del piano); se non c'è altro, il piano «da sottoporre
    ad approvazione» è l'unico del curriculum (es. Ingegneria civile e ambientale 2025) e vale."""
    ok = []
    for p in det.get("percorsi") or []:
        pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        if _percorso_ok(pnome, sede):
            ok.append(p)
    definitivi = {(p.get("pdsCod") or "") for p in ok
                  if not _DA_APPROVARE.search((p.get("des_it") or p.get("pdsDes") or ""))}
    return [p for p in ok if not _DA_APPROVARE.search(p.get("des_it") or p.get("pdsDes") or "")
            or (p.get("pdsCod") or "") not in definitivi]


def _nome_pulito(pnome: str) -> str:
    """«IISI AUTOMATICA APPROVAZIONE» → «IISI», «Tecnologie Agrarie - APPROVATO» → «Tecnologie Agrarie»."""
    return re.sub(r"\s+", " ", _AUTOMATICA.sub(" ", pnome)).strip(" -:")


def _percorsi_comuni(det: dict, sede: str) -> set[str]:
    """Nomi dei percorsi validi per tutti i curricula: «CORSO GENERICO», «PIANO STATUTARIO», quello con codice GEN
    quando gli altri percorsi hanno un loro codice («Piano di Studi Generale» di Economia aziendale), un solo
    percorso dopo aver tolto le varianti «da approvare». I percorsi di classe («CLASSE LM-1») sono curricula."""
    validi = _percorsi_validi(det, sede)
    nomi = {(p.get("des_it") or p.get("pdsDes") or "").strip(): (p.get("pdsCod") or "") for p in validi}
    altri = any(c not in ("GEN", "") for c in nomi.values())
    out = set()
    for n, c in nomi.items():
        if _e_comune(n) or (c == "GEN" and altri and not _CLASSE.search(n)):
            out.add(n)
    if len(nomi) == 1:
        out |= set(nomi)
    return out


def _voci_anno(det: dict, y: int, durata: int, sede: str, aa_affidabile: bool = True) -> list:
    """Voci del piano di una coorte `y`: (anno 1..durata, percorso, gruppo, attività o None).

    Le sezioni per anno (`anno` 1..durata) hanno i gruppi del catalogo. Le sezioni senza anno («altreAttivita»)
    hanno le attività con l'anno accademico di erogazione `aa`: l'anno di corso è `aa` - coorte + 1; ciascuna va nel
    suo anno, in un gruppo piatto `{"_piatto": True}`. Nelle coorti passate (`aa_affidabile` falso) le attività portano
    più `aa` (un'offerta per ogni a.a.) e l'anno non si ricava: un piano solo «altreAttivita» non dà voci e le
    attività obbligatorie fuori dalle sezioni per anno vanno all'ultimo anno. Se la coorte ha anche le sezioni per anno, le attività di
    «altreAttivita» già presenti nelle sezioni sono doppioni e quelle a scelta sono l'offerta di insegnamenti (non
    parte del piano): si tengono solo le obbligatorie che mancano (prova finale, lingua). Un gruppo senza attività
    elencate dà una voce con attività None."""
    out = []
    percorsi = _percorsi_validi(det, sede)
    con_anno = set()
    for p in percorsi:
        for a in p.get("anni") or []:
            if str(a.get("anno")).isdigit() and int(a["anno"]) >= 1:
                for g in a.get("insegnamenti") or [{"attivita": a.get("attivita") or []}]:
                    con_anno |= {att.get("adCod") or att.get("cod") for att in g.get("attivita") or []}
    struttura = bool(con_anno) or any(
        str(a.get("anno")).isdigit() and int(a["anno"]) >= 1 for p in percorsi for a in p.get("anni") or [])
    for p in percorsi:
        pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        visti = set()
        for a in p.get("anni") or []:
            anno = a.get("anno")
            numerico = str(anno).isdigit() and int(anno) >= 1
            if not numerico:
                for att in a.get("attivita") or []:
                    ad = att.get("adCod") or att.get("cod")
                    if _e_frequenza(att) or (ad, att.get("aa")) in visti:
                        continue
                    visti.add((ad, att.get("aa")))
                    obb = (att.get("tipo_ins_cod") or "").startswith("OBB")
                    if struttura and (ad in con_anno or not obb):
                        continue
                    if struttura and not aa_affidabile and not att.get("crediti"):
                        continue  # «altreAttivita» di una coorte passata: offerta di altri corsi a 0 CFU (es. ECN0009)
                    try:
                        k = int(att.get("aa")) - y + 1
                    except (TypeError, ValueError):
                        k = durata
                    if not aa_affidabile:  # coorti passate: `aa` è l'a.a. dell'offerta (anche più di uno per attività)
                        if not struttura:
                            continue
                        k = durata
                    if not 1 <= k <= durata:
                        if not obb:
                            continue
                        k = durata
                    out.append((k, pnome, {"label_it": "", "_piatto": True, "_senza_tipo_obbl": True}, att))
                continue
            k = int(anno)
            if k > durata:
                continue
            gruppi = a.get("insegnamenti") or ([{"label_it": "", "attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                atts = g.get("attivita") or []
                if not atts:
                    if _gruppo_senza_attivita(g):
                        out.append((k, pnome, g, None))
                    continue
                for att in atts:
                    if not _e_frequenza(att):
                        out.append((k, pnome, g, att))
    return out


def _cfu_dichiarati(voci: list, k: int, comuni: set[str]) -> float:
    """CFU «dichiarati» dall'anno k in un piano: le attività obbligatorie (gruppo «Obbligatori», piani piatti con tipo
    «OBB») per intero; ogni gruppo a scelta con i CFU nell'etichetta («I SCELTA GUIDATA (12 CFU)», «fra 1 e 12 CFU»)
    una volta sola, col valore dell'etichetta, non con la somma delle alternative; i gruppi a scelta senza CFU
    nell'etichetta non contano. Con più curricula si somma il piano comune al curriculum più ricco."""
    per_perc: dict[str, float] = {}
    visti: set = set()
    for kk, pnome, g, att in voci:
        if kk != k:
            continue
        etic = _ETICHETTA_CFU.search(g.get("label_it") or "")
        if att is None:
            info = _gruppo_senza_attivita(g)
            if not info or info[3]:
                continue
            chiave, cfu = (pnome, "G", _norm(g.get("label_it"))), float(info[1])
            if _ETICHETTA_CFU.search(g.get("label_it") or "") and _ETICHETTA_CFU.search(g["label_it"]).group(1) is not None:
                chiave = (pnome, "libera")  # «Scelta libera … (fra 1 e 12 CFU)»: più gruppi dello stesso anno sono una scelta
        elif g.get("_piatto"):
            if _DEBITO.search(att.get("des_it") or ""):
                continue
            tipo = att.get("tipo_ins_cod") or ""
            scelta = "scelta" in (att.get("tafDes_it") or "").lower() or "scelta" in (att.get("des_it") or "").lower()
            if tipo.startswith("OBB") or (not tipo and not scelta) or (not tipo and scelta and not etic):
                chiave, cfu = (pnome, att.get("adCod") or att.get("cod")), att.get("crediti")
            else:
                continue
        elif g.get("cod") in ("OO", "O") or "obbligator" in (g.get("label_it") or "").lower() or _gruppo_per_intero(g):
            chiave, cfu = (pnome, att.get("adCod") or att.get("cod")), att.get("crediti")
        elif etic:
            chiave, cfu = (pnome, "G", _norm(g.get("label_it"))), _numero(etic.group(2))
            if etic.group(1) is not None:
                chiave = (pnome, "libera")
        else:
            continue
        if chiave not in visti and isinstance(cfu, (int, float)):
            visti.add(chiave)
            per_perc[pnome] = per_perc.get(pnome, 0.0) + cfu
    comune = sum(v for p, v in per_perc.items() if p in comuni)
    altri = [v for p, v in per_perc.items() if p not in comuni]
    return comune + (max(altri) if altri else 0.0)


SOGLIA_ANNO = 48  # CFU dichiarati con cui il piano di un anno si considera completo
SOGLIA_QUASI = 54  # sotto questa soglia il piano di una coorte si confronta con quelli delle coorti accanto
SOGLIA_PARZIALE = 40  # sotto questa soglia il piano della coorte per quell'anno è molto parziale


def _coorte_anno(voci: dict, comuni: dict, k: int, anno: int, extra: float = 0.0) -> int | None:
    """Coorte da cui leggere l'anno k: quella degli iscritti all'anno k oggi (anno - k + 1), se il suo piano ha
    quell'anno e non è molto parziale (`_cfu_dichiarati` più i CFU delle voci di `PIANO_EXTRA` di quell'anno almeno
    `SOGLIA_PARZIALE`: il catalogo pubblica alcune coorti solo in parte, con le sole attività «a scelta» o con i
    curricula «da approvare»). Altrimenti la coorte più vicina con un piano di almeno `SOGLIA_ANNO` CFU (a parità la più
    recente); se nessuna lo è, quella con più CFU dichiarati."""
    y0 = anno - k + 1
    ha = {y: _cfu_dichiarati(v, k, comuni[y]) + extra for y, v in voci.items() if any(x[0] == k for x in v)}
    if not ha:
        return None
    vicine = sorted(ha, key=lambda y: (abs(y - y0), -y))
    if y0 in ha and ha[y0] >= SOGLIA_PARZIALE:
        # piano un po' incompleto (es. manca un insegnamento da 12 CFU): quello di una coorte accanto, se arriva a 60
        meglio = [y for y in vicine if y != y0 and abs(y - y0) == 1 and ha[y] >= 60 and ha[y] > ha[y0]]
        if ha[y0] < SOGLIA_QUASI and meglio:
            return meglio[0]
        return y0
    adeguate = [y for y in vicine if ha[y] >= SOGLIA_ANNO]
    if adeguate:
        return adeguate[0]
    return max(vicine, key=lambda y: (ha[y], -abs(y - y0)))


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None,
                 coorte_unica: int | None = None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`: stesso codice, codice senza il suffisso del
        riordino («R»), nome-sede-tipo, nome e tipo se è l'unico con quel nome (la sede può cambiare da una coorte
        all'altra: il codice «IT02» della sede 1 passa a «IT22»), poi un codice precedente noto."""
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

    def con_piano(x: dict) -> bool:
        """La riga ha un piano con attività (i vecchi ordinamenti ad esaurimento hanno il piano vuoto)."""
        d = dettaglio(anno, x)
        return bool(d) and any(a.get("attivita") or any(g.get("attivita") or g.get("label_it") for g in a.get("insegnamenti") or [])
                               for p in d.get("percorsi") or [] for a in p.get("anni") or [])

    attuali = [x for x in attuali if con_piano(x)]
    log(f"[{uid}] di cui con un piano: {len(attuali)}")

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}  # coorte → (riga dell'elenco, dettaglio)
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        sede = _sede_corso(cur)
        voci = {y: _voci_anno(d, y, durata, sede, y >= anno - 1) for y, (_, d) in cohorts.items()}
        # insegnamenti che un piano a gruppi (coorti con gli anni) dà come obbligatori (gruppo «O») o no: la coorte più recente
        tipo_gruppi: dict[str, bool] = {}
        for y in sorted(voci):
            for _, _, g, att in voci[y]:
                if att is not None and not g.get("_piatto"):
                    tipo_gruppi[att.get("adCod") or att.get("cod")] = bool(
                        g.get("cod") in ("O", "OO") or "obbligator" in (g.get("label_it") or "").lower())
        classe_dettaglio = rec[1].get("classe_cod")
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")
        comuni: dict[int, set[str]] = {y: _percorsi_comuni(d, sede) for y, (_, d) in cohorts.items()}
        # curricula: identificati dal codice del percorso (diverso da GEN) o dal nome; il nome è quello della coorte
        # più recente che lo ha. `chiave_p[(coorte, nome del percorso)]` → chiave
        nomi_percorso: dict[str, str] = {}
        chiave_p: dict[tuple[int, str], str] = {}
        for y in sorted(cohorts):
            for p in _percorsi_validi(cohorts[y][1], sede):
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                cod = (p.get("pdsCod") or "").strip()
                ch = f"c:{cod}" if cod and cod != "GEN" else f"n:{_chiave_nome(pn)}"
                chiave_p[(y, pn)] = ch
                if pn not in comuni[y]:
                    nomi_percorso[ch] = _nome_percorso(pn)
        # CFU di un'attività a scelta che in un piano ha 0 CFU («fra 0.5 e 12 CFU»): quelli della stessa attività
        # in un'altra coorte o un altro anno del corso
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for _, _, _, att in voci[y]:
                if att is not None and isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                    cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]
        # stessa attività offerta in altre coorti/anni accademici: schede alternative per i libri
        alt_per_ad: dict[str, dict] = {}
        for y, v in voci.items():
            for _, _, _, att in v:
                if att is not None:
                    alt_per_ad.setdefault(att.get("adCod") or att.get("cod"), {})[
                        (str(att.get("aa")), str(att.get("cod")))] = (y, att)
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        debiti: list[str] = []
        piano_anni: dict[str, dict] = {}  # anno di corso → coorte e pagina del catalogo da cui viene
        for k in range(1, durata + 1):
            bonus = (sum(float(c_) for k_, _n, c_, o_, *_r in PIANO_EXTRA.get(cur.get("cdsCod"), {}).get("voci", []) if k_ == k and o_)
                     + PIANO_EXTRA.get(cur.get("cdsCod"), {}).get("scelte", {}).get(k, 0))
            scelta = COORTE_ANNO.get((cur.get("cdsCod"), k)) or _coorte_anno(voci, comuni, k, anno, bonus) if coorte_unica is None else (
                coorte_unica if any(v[0] == k for v in voci.get(coorte_unica, [])) else None)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                  "cfu_dichiarati": _cfu_dichiarati(voci[scelta], k, comuni[scelta]) + bonus}
            validi = [(p.get("des_it") or p.get("pdsDes") or "").strip() for p in _percorsi_validi(d, sede)]
            curricula = {nomi_percorso[chiave_p[(scelta, p)]] for p in validi if p not in comuni[scelta]}
            if len(curricula) < 2:  # un solo percorso oltre al comune: non è un curriculum
                curricula = set()
            for kk, pnome, g, att in voci[scelta]:
                if kk != k:
                    continue
                gruppo = (g.get("label_it") or "").lower()
                obbl = "obbligator" in gruppo or g.get("cod") in ("O", "OO")  # gruppo «O»: attività obbligatorie
                if att is not None and g.get("_piatto") and not att.get("tipo_ins_cod"):
                    ad_ = att.get("adCod") or att.get("cod")
                    if ad_ in tipo_gruppi:  # lo stesso insegnamento in un piano a gruppi di un'altra coorte
                        obbl = tipo_gruppi[ad_]
                    elif "scelta" not in (att.get("tafDes_it") or "").lower():
                        obbl = g["_senza_tipo_obbl"]
                tutti_obbl = _gruppo_per_intero(g)
                comune = pnome in comuni[scelta] or not curricula
                pcur = None if comune else nomi_percorso[chiave_p[(scelta, pnome)]]
                if att is None:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                    nome, cfu, fisso, alt = _gruppo_senza_attivita(g)
                    if alt:
                        continue  # alternativa della scelta già contata
                    key = f"{k}:#{_norm(nome)}:{cfu}"
                    item = insegnamenti.get(key)
                    if not item:
                        item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu,
                                "ssd": None, "obbligatorio": bool(fisso), "curriculum": None, "_percorsi": set(),
                                "_tutti": curricula, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                "libri": [], "esami": [], "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                        insegnamenti[key] = item
                else:
                    if _DEBITO.search(att.get("des_it") or ""):
                        nome_d = re.sub(r"(?i)^\s*debito\s+", "", cc._titolo(att["des_it"])).strip()
                        if not re.search(r"(?i)\bofa\b", nome_d) and nome_d not in debiti:
                            debiti.append(nome_d)
                        else:
                            debiti.append("")
                        continue
                    ad = att.get("adCod") or att.get("cod")
                    key = f"{k}:{ad}"
                    item = insegnamenti.get(key)
                    if not item:
                        docenti = [cc._nome(x_.get("des")) for x_ in att.get("docenti") or [] if x_.get("des")]
                        item = {
                            "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                            "periodo": cc._periodo(att.get("periodo_didattico_it")),
                            "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                            "periodo_fine": att.get("data_fine_periodo_didattico"),
                            "cfu": att.get("crediti") or cfu_noti.get(ad) or att.get("crediti"), "ssd": None,
                            "obbligatorio": bool(obbl or att.get("tipo_ins_cod") == "OBB" or tutti_obbl),
                            "curriculum": None, "_percorsi": set(), "_tutti": curricula,
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
                                "items": [],
                                "alt": [(a, y_) for (a, _), (y_, a) in sorted(
                                    alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                                    if (str(a.get("aa")), str(a.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                            })["items"].append(item)
                    elif obbl or att.get("tipo_ins_cod") == "OBB" or tutti_obbl:
                        item["obbligatorio"] = True
                if comune:
                    item["_comune"] = True
                elif pcur:
                    item["_percorsi"].add(pcur)
                    percorsi_nomi.add(pcur)
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
        # attività a 0 CFU nel piano (offerta di altri corsi, scelte senza CFU): non sono insegnamenti del piano
        for key, item in list(insegnamenti.items()):
            if not item.get("cfu"):
                del insegnamenti[key]
        extra = PIANO_EXTRA.get(cur.get("cdsCod"))
        for voce_e in (extra or {}).get("voci", []):
            k_e, nome_e, cfu_e, obbl_e = voce_e[:4]
            cod_e = voce_e[4] if len(voce_e) > 4 else None
            if k_e > durata:
                continue
            insegnamenti[f"{k_e}:#extra:{_norm(nome_e)}"] = {
                "codice": cod_e, "nome": nome_e, "anno": k_e, "periodo": None, "cfu": cfu_e, "ssd": None,
                "obbligatorio": obbl_e, "curriculum": None, "_percorsi": set(), "_tutti": set(), "docenti": [],
                "url": extra["fonte"], "libri": [], "esami": [], "fonte": extra["fonte"], "verificato_il": oggi,
                "_senza_codice": not cod_e, "_comune": True}
        ins = list(insegnamenti.values())
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        # stesso nome nello stesso anno con codici e CFU diversi (es. Psicopatologia e filosofia della mente, 12 CFU per
        # la classe L-19 e 16 per la L-20, nello stesso piano): il nome porta i CFU, altrimenti sembrano un doppione
        per_nome: dict[tuple, list] = {}
        for i in ins:
            # voci con codice: stesso curriculum; voci senza codice (tirocinio di curricula diversi con CFU diversi):
            # build_db le unirebbe per nome e resterebbero i CFU di una sola
            per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"] if i.get("codice") else None), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    if isinstance(i["cfu"], (int, float)):
                        i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        # stesso nome, anno e curriculum con codici diversi e gli stessi CFU: lo stesso insegnamento con due codici
        # (a scelta, es. «Corso monografico …» offerto a due corsi) si unisce; i tirocini e i laboratori in due semestri
        # (due codici, un esame per semestre) restano due e il nome porta il semestre o, se manca, il codice
        per_nome2: dict[tuple, list] = {}
        for i in ins:
            if i.get("codice"):
                per_nome2.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"]), []).append(i)
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
                anni_nome.setdefault(_norm(i["nome"]), set()).add(i["anno"])
                i["_nk"] = _norm(i["nome"])
        for i in ins:
            nk = i.pop("_nk", None)
            if nk and len(anni_nome[nk]) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        if amm is not None and debiti:
            nomi = [t for t in dict.fromkeys(debiti) if t]
            frase = "Debiti formativi (OFA) previsti dal piano di studi" + (": " + ", ".join(nomi) if nomi else "")
            amm["requisiti"] = ((amm.get("requisiti") or "").rstrip() + "\n" + frase + ".").strip()
            if amm.get("ofa") is None:
                amm["ofa"] = True
        return {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or classe_dettaglio),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

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
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, legati = cc._testi_syllabus(sy)
        if not libri:  # testi in forma libera
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unibas.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def fetch_ateneo(uid: str = "unibas", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None, coorte_unica: int | None = None) -> dict:
    """`coorte_unica`: solo per i controlli, legge tutti gli anni dal piano di una sola coorte."""
    doc = _fetch_piani(uid, anno, max_cds, syllabus, log, client, coorte_unica)
    doc["corsi"] = [c for c in doc["corsi"] if c.get("codice_ateneo") not in ESCLUSI]
    corsi = []
    for c in doc["corsi"]:
        cod = str(c.get("url") or "").rsplit("/", 1)[-1]
        if cod in ID_CORSI:  # una copia del piano per ogni corso del database (id esplicito)
            corsi += [{**copy.deepcopy(c), "id": i} for i in ID_CORSI[cod]]
        else:
            corsi.append(c)
    doc["corsi"] = corsi
    log(f"[{uid}] corsi del database legati per id: {sum(1 for c in corsi if c.get('id'))}")
    return doc


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unibas.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unibas] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
