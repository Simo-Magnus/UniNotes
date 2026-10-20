"""Università degli Studi di Messina: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unime.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) il catalogo di Messina richiede:

- durata dal piano («3 anni», «5 anni»): l'elenco minimale non ha `durataAnni` e senza di essa tutti
  i corsi avevano 3 anni (anni 4-6 dei cicli unici e 3° anno delle lauree magistrali sbagliati);
- coorti per codice e nome: il codice del corso cambia con il riordino («4035» → «4035R») e la coorte
  precedente si ritrova senza il suffisso o per nome, sede e tipo;
- anno di corso: per l'anno k si usa il piano della coorte (anno - k + 1), la coorte degli iscritti
  oggi al k-esimo anno; se quella coorte non ha l'anno (piano 2026 non ancora pubblicato: Logopedia,
  Odontoiatria, Consulente del lavoro) o ha un piano molto parziale, la coorte più vicina dello stesso
  ordinamento che lo ha; l'url di ogni insegnamento riporta la coorte (`?coorte=`);
- gruppi senza attività elencate: il catalogo li usa per i crediti che non hanno un esame: «TIROCINIO
  (3 CFU)», «ALTRE ATTIVITA' (2 CFU)», «CONOSCENZE LINGUISTICHE (3 CFU)» (CFU fissi, obbligatori) e
  «A SCELTA DELLO STUDENTE (fra 0.5 e 12 CFU)» (crediti liberi: si prende il massimo del catalogo;
  «oppure …», «e/o …» sono alternative della stessa scelta e non si sommano). Prima venivano scartati e
  gli anni risultavano di 54-58 CFU. Le voci non hanno codice: se lo stesso nome compare in anni
  diversi il nome porta l'anno («Tirocinio (2° anno)»), perché build_db unisce per nome le voci senza codice;
- sezione «anno 0» (crediti non legati a un anno, es. «CREDITI A SCELTA (2 CFU)» di Giurisprudenza):
  nell'ultimo anno del corso;
- percorsi: «PIANO STATUTARIO», «PERCORSO COMUNE», «PIANO COMUNE» valgono per tutti i curricula;
  i percorsi «part-time» (stessa offerta in più rate) non sono curricula; nei piani con una sede nel nome
  («PIANO STATUTARIO (Sede Noto)») si prende quello della sede del corso; i nomi dei curricula
  («CURRICULUM X», «ORIENTAMENTO X», «X») si unificano tra le coorti;
- «Debito OFA», «Debito Chimica»…: attività a 0 CFU che indicano un debito formativo (OFA) e non un
  insegnamento: non sono insegnamenti del piano; compaiono nei requisiti di accesso del corso
  («Debiti formativi previsti dal piano: …»);
- `ID_CORSI`: i corsi del catalogo con sede diversa (Messina/Siracusa/Noto) o con nome diverso da quello di
  Universitaly («Infermieristica (abilitante alla professione sanitaria di Infermiere)») vanno al corso
  giusto del database, altrimenti il piano finisce in un corso omonimo e quello di Universitaly resta vuoto.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unime.json` mantenendo appelli e canali già presenti):

    python tools/db_builder/adapters/unime.py [--senza-syllabus]
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

BASE = "https://unime.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici (le altre righe sono master, dottorati, scuole)

# codice (`cod`) del corso nella coorte 2026 → id dei corsi del database a cui va il piano. Serve dove il
# confronto di build_db per nome e classe sbaglia: sedi diverse con lo stesso nome (Messina/Siracusa/Noto),
# nomi del catalogo diversi da Universitaly, corsi gemelli.
ID_CORSI: dict[str, list[str]] = {
    # Consulente del lavoro: Messina e «replica Siracusa»
    "10764": ["unime-l-14-consulente-del-lavoro-e-scienze-dei-servizi-giuridici"],
    "10763": ["unime-l-14-consulente-del-lavoro-e-scienze-dei-servizi-giuridici-replic"],
    # Scienze dell'amministrazione e dell'organizzazione
    "10901": ["unime-l-16-scienze-dell-amministrazione-e-dell-organizzazione"],
    "10902": ["unime-l-16-scienze-dell-amministrazione-e-dell-organizzazione-replica-s"],
    # Scienze della formazione e della comunicazione
    "10806": ["unime-l-19-l-20-scienze-della-formazione-e-della-comunicazione"],
    "10812": ["unime-l-19-l-20-scienze-della-formazione-e-della-comunicazione-replica-noto"],
    # Scienze e tecniche psicologiche
    "10808": ["unime-l-24-scienze-e-tecniche-psicologiche"],
    "10814": ["unime-l-24-scienze-e-tecniche-psicologiche-replica-noto"],
    # Scienze gastronomiche
    "10838": ["unime-l-26-scienze-gastronomiche"],
    "10839": ["unime-l-26-scienze-gastronomiche-replica-noto"],
    # Giurisprudenza
    "10761": ["unime-lmg-01-giurisprudenza"],
    "10760": ["unime-lmg-01-giurisprudenza-replica-siracusa"],
    # Infermieristica: Messina e replica Siracusa (Universitaly ha il nome «… (abilitante alla professione …)»)
    "10172": ["unime-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf"],
    "10843": ["unime-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1628948"],
    # professioni sanitarie con il nome di Universitaly «… (abilitante alla professione …)»
    "10176": ["unime-l-snt3-tecniche-audioprotesiche-abilitante-alla-professione-sanitar"],
    "10181": ["unime-l-snt3-tecniche-di-laboratorio-biomedico-abilitante-alla-profession"],
    "10178": ["unime-l-snt3-tecniche-di-neurofisiopatologia-abilitante-alla-professione"],
    # Medicina e chirurgia: due corsi omonimi in Universitaly (standard e indirizzo biotecnologico) e quello in inglese
    "10842": ["unime-lm-41-medicina-e-chirurgia"],
    "10845": ["unime-lm-41-medicina-e-chirurgia-1628987"],
    "10844": ["unime-lm-41-medicine-and-surgery"],
    # Digital Transformation: il corso ha un solo id (Universitaly: «… and Innovation Management»)
    "10623": ["unime-lm-77-digital-transformation-and-innovation-management"],
    # Scienze infermieristiche e ostetriche (profilo infermieristico)
    "10903": ["unime-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic"],
}

_SEDI = ("MESSINA", "NOTO", "PRIOLO", "SIRACUSA")
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
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unime)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unime" if d else None

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
    return re.sub(r"[^A-Z]", "", (cur.get("sede_des_it") or "").upper())


def _percorso_ok(pnome: str, sede: str) -> bool:
    """Percorsi che sono curricula o piani del corso: non i part-time né i piani di un'altra sede."""
    if _PART_TIME.search(pnome):
        return False
    citate = [s for s in _SEDI if re.search(rf"\b{s}\b", pnome.upper())]
    return not citate or sede in citate


def _chiave_percorso(pnome: str) -> str:
    """Nome del curriculum senza prefisso, sede né sigle della classe/riordino («L-18 R», «110»): per riconoscerlo
    tra le coorti. Se resta solo la classe («CLASSE L-11», «PIANO STATUTARIO LM-55») la classe è il nome."""
    n = re.sub(r"\(.*?\)", " ", pnome)
    n = re.sub(r"(?i)\s*-\s*(?:sede\s+)?(?:" + "|".join(_SEDI) + r")\b.*$", "", n)
    n = _PREFISSO.sub("", n.strip())
    n = re.sub(r"(?i)\bpiano statutario\b|\bclasse\b|\b(?:sede\s+(?:di\s+)?)?(?:" + "|".join(_SEDI) + r")\b", " ", n)
    m = re.search(r"(?i)\b(LM?)\s*-?\s*(\d{1,2})\s*R?\b", n)
    senza = re.sub(r"(?i)\bLM?[-\s]*\d{1,2}\s*R?\b", " ", n)
    senza = re.sub(r"\b\d{3}\b|\bR\b", " ", senza)
    testo = re.sub(r"[^a-z0-9]+", " ", senza.lower()).strip()
    if testo or not m:
        return testo
    return f"{m.group(1).lower()} {int(m.group(2))}"


def _e_comune(pnome: str) -> bool:
    """Percorso valido per tutti i curricula («PIANO STATUTARIO», «PERCORSO COMUNE»); non quelli di una classe."""
    return bool(_COMUNE.search(pnome)) and not _CLASSE.search(pnome)


LINGUE_PERCORSO = {"ita": "Percorso in lingua italiana", "eng": "Percorso in lingua inglese"}


def _lingua_percorso(p: dict) -> str | None:
    """Lingua di un percorso dalle attività (`lingua_cod`): quella, tra italiano e inglese, con più attività
    (le lingue straniere insegnate in un percorso italiano non contano); None se pari o senza indicazioni."""
    n = {"ita": 0, "eng": 0}
    for a in p.get("anni") or []:
        gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
        for g in gruppi:
            for att in g.get("attivita") or []:
                if att.get("lingua_cod") in n:
                    n[att["lingua_cod"]] += 1
    if n["ita"] == n["eng"]:
        return None
    return "ita" if n["ita"] > n["eng"] else "eng"


def _percorsi_nomi(det: dict, sede: str) -> list[tuple[dict, str]]:
    """(percorso, nome) dei percorsi validi del piano di una coorte. Due o più percorsi «comuni» con `pdsCod` diversi
    che hanno lingua diversa (Scienze politiche e delle relazioni internazionali: «PIANO STATUTARIO COMUNE» 100 in
    italiano e 200 in inglese) non sono comuni a tutti: sono il percorso in italiano e quello in inglese, due
    curricula (altrimenti i due piani si fondono e ogni insegnamento compare nelle due lingue)."""
    ok = [(p, (p.get("des_it") or p.get("pdsDes") or "").strip()) for p in det.get("percorsi") or []]
    ok = [(p, n) for p, n in ok if _percorso_ok(n, sede)]
    comuni = [p for p, n in ok if _e_comune(n)]
    if len(comuni) >= 2 and len({str(p.get("pdsCod")) for p in comuni}) == len(comuni):
        lingue = [_lingua_percorso(p) for p in comuni]
        if None not in lingue and len(set(lingue)) == len(lingue):
            etichette = {id(p): LINGUE_PERCORSO[lg] for p, lg in zip(comuni, lingue)}
            return [(p, etichette.get(id(p), n)) for p, n in ok]
    return ok


def _voci_anno(det: dict, durata: int, sede: str) -> list:
    """Voci del piano di una coorte: (anno 1..durata, percorso, gruppo, attività o None).

    Le sezioni senza anno (`anno` 0 o non numerico: crediti non legati a un anno) vanno all'ultimo anno.
    Un gruppo senza attività elencate dà una voce con attività None."""
    out = []
    for p, pnome in _percorsi_nomi(det, sede):
        for a in p.get("anni") or []:
            anno = a.get("anno")
            k = int(anno) if str(anno).isdigit() and int(anno) >= 1 else durata
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
                    out.append((k, pnome, g, att))
    return out


def _cfu_voci(voci: list, k: int) -> float:
    """CFU dell'anno k in un piano (una volta per attività; i gruppi senza elenco con i CFU dell'etichetta,
    le alternative «oppure …» non si sommano)."""
    visti, tot = set(), 0.0
    for kk, _, g, att in voci:
        if kk != k:
            continue
        if att is None:
            info = _gruppo_senza_attivita(g)
            if not info or info[3]:
                continue
            chiave, cfu = ("#", info[0], info[1]), float(info[1])
        else:
            chiave, cfu = att.get("adCod") or att.get("cod"), att.get("crediti")
            if _DEBITO.search(att.get("des_it") or ""):
                continue
        if chiave not in visti and isinstance(cfu, (int, float)):
            visti.add(chiave)
            tot += cfu
    return tot


def _coorte_anno(cohorts: dict, voci: dict, k: int, anno: int) -> int | None:
    """Coorte da cui leggere l'anno k: quella degli iscritti all'anno k oggi (anno - k + 1), se il suo piano ha
    quell'anno e non è molto parziale. Altrimenti, nello stesso ordinamento, la coorte più vicina con un piano più
    completo; se la coorte non ha l'anno, la più vicina che lo ha (di preferenza con almeno 60 CFU)."""
    y0 = anno - k + 1
    ha = {y: _cfu_voci(v, k) for y, v in voci.items() if any(x[0] == k for x in v)}
    if not ha:
        return None
    vicine = sorted(ha, key=lambda y: (abs(y - y0), -y))
    if y0 in ha:
        if ha[y0] >= 60:
            return y0
        ord0 = cohorts[y0][1].get("ordinamento_aa")
        # un piano molto parziale (meno di mezzo anno) si sostituisce con quello della coorte più vicina
        meglio = [y for y in vicine if y != y0 and ha[y] > ha[y0] and ha[y0] < 30
                  and cohorts[y][1].get("ordinamento_aa") == ord0]
        return max(meglio, key=lambda y: (ha[y], -abs(y - y0))) if meglio else y0
    pieni = [y for y in vicine if ha[y] >= 60]
    return (pieni or vicine)[0]


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None,
                 coorte_unica: int | None = None, solo: set[str] | None = None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    if solo:  # solo questi corsi (campo `cod` del catalogo), per rieseguire un correttivo senza rileggere tutto
        attuali = [x for x in coorti[anno] if x["cod"] in solo]
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
        for x in elenco:
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]):
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        return stessi[0] if len(stessi) == 1 else None

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
        voci = {y: _voci_anno(d, durata, sede) for y, (_, d) in cohorts.items()}
        classe_dettaglio = rec[1].get("classe_cod")
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")
        # nome dei curricula: quello della coorte più recente che ha lo stesso curriculum
        nomi_percorso: dict[str, str] = {}
        for y in sorted(cohorts):
            for _, pn in _percorsi_nomi(cohorts[y][1], sede):
                if not _e_comune(pn):
                    nomi_percorso[_chiave_percorso(pn)] = pn if pn in LINGUE_PERCORSO.values() else                         re.sub(r"\s+", " ", _PREFISSO.sub("", pn)).strip(": ")
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
        for k in range(1, durata + 1):
            scelta = _coorte_anno(cohorts, voci, k, anno) if coorte_unica is None else (
                coorte_unica if any(v[0] == k for v in voci.get(coorte_unica, [])) else None)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            validi = [n for _, n in _percorsi_nomi(d, sede)]
            curricula = {nomi_percorso.get(_chiave_percorso(p), p) for p in validi if not _e_comune(p)}
            if len(curricula) < 2:  # un solo percorso oltre al comune: non è un curriculum
                curricula = set()
            for kk, pnome, g, att in voci[scelta]:
                if kk != k:
                    continue
                gruppo = (g.get("label_it") or "").lower()
                obbl = "obbligator" in gruppo or g.get("cod") == "OO"
                tutti_obbl = _gruppo_per_intero(g)
                comune = _e_comune(pnome) or not curricula
                pcur = None if comune else nomi_percorso.get(_chiave_percorso(pnome), pnome)
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
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unime.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def fetch_ateneo(uid: str = "unime", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None, coorte_unica: int | None = None, solo: set[str] | None = None) -> dict:
    """`coorte_unica`: solo per i controlli, legge tutti gli anni dal piano di una sola coorte.
    `solo`: codici (`cod`) dei soli corsi del catalogo da leggere."""
    doc = _fetch_piani(uid, anno, max_cds, syllabus, log, client, coorte_unica, solo)
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
    out = ROOT / "database" / "contrib" / "auto" / "unime.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unime] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
