"""Università Politecnica delle Marche: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://univpm.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) il catalogo dell'UnivPM richiede:

- codici del corso che cambiano con il riordino («IT02» → «IT22», «MT07» → «MT07A»): la coorte precedente si
  ritrova per codice, senza il suffisso o per nome e tipo (anche se la sede cambia); le righe dell'elenco
  senza piano nella coorte attuale (vecchi ordinamenti ad esaurimento, es. «IT02») non si leggono: il piano
  del corso attivo (IT22) copre già tutti gli anni, altrimenti il vecchio corso sostituirebbe il nuovo;
- piano senza anni (`anno` «altreAttivita»: tutte le coorti 2026 e molte del 2025): l'anno di ogni attività è
  `annoCorso` (anno di erogazione - coorte + 1); le attività «OBB» sono obbligatorie, «OPZ» o senza tipo a scelta;
- anno di corso: per l'anno k si usa il piano della coorte (anno - k + 1), la coorte degli iscritti oggi al
  k-esimo anno; se quella coorte non ha l'anno o ha un piano molto parziale, la coorte più vicina dello stesso
  ordinamento che lo ha; l'url di ogni insegnamento riporta la coorte (`?coorte=`);
- sedi come percorsi: nei piani fino al 2024 le professioni sanitarie (Infermieristica, Fisioterapia, Logopedia,
  Radiologia) hanno un percorso per sede («INFERMIERISTICA - FERMO»): si prende quello della sede del corso;
- gruppi senza attività elencate: crediti fissi («TIROCINIO (3 CFU)») o liberi («A SCELTA DELLO STUDENTE (fra 1 e
  12 CFU)»), come in `unime`; le voci senza codice di anni diversi hanno il nome con l'anno;
- «OFA», «OFA - Matematica»: attività a 0 CFU che indicano un debito formativo: non sono insegnamenti
  (requisiti di accesso); «… (FR)», «… (frequency only)»: frequenze a 0 CFU di un insegnamento integrato (i CFU
  sono nell'insegnamento): non si riportano come insegnamenti;
- percorsi: «PERCORSO COMUNE», «CORSO GENERICO», «STATUTARIO» valgono per tutti i curricula; i piani
  «PS IMMATRICOLATI 2026 X» e «PIANO L-18 642 2026» sono i curricula «X» e «Piano L-18 642», con lo stesso nome
  in tutte le coorti;
- `ID_CORSI`: i corsi del catalogo vanno al corso giusto del database (sedi gemelle, nomi diversi da Universitaly).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/univpm.json` mantenendo appelli e canali già presenti):

    python tools/db_builder/adapters/univpm.py [--senza-syllabus]
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

BASE = "https://univpm.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici (le altre righe: semestre filtro)

# codice (`cod`) del corso nella coorte 2026 → id dei corsi del database a cui va il piano. Serve dove il
# confronto di build_db per nome e classe sbaglia: sedi gemelle (Infermieristica ad Ancona, Ascoli Piceno, Fermo,
# Macerata, Pesaro), nomi del catalogo diversi da Universitaly, corsi professionalizzanti («LP»).
_P = "univpm-"
ID_CORSI: dict[str, list[str]] = {
    "4994": [_P + "l-25-scienze-e-tecnologie-agrarie"],
    "5191": [_P + "l-26-scienze-e-tecnologie-alimentari"],
    "4995": [_P + "l-25-scienze-forestali-e-ambientali"],
    "4993": [_P + "l-25-sistemi-agricoli-innovativi"],
    "5994": [_P + "lm-70-food-and-beverage-innovation-and-management"],
    "5993": [_P + "lm-69-scienze-agrarie-e-del-territorio"],
    "6191": [_P + "lm-73-scienze-e-tecnologie-forestali-e-ambientali"],
    "5197": [_P + "l-33-l-18-digital-economics-and-business"],
    "4991": [_P + "l-18-economia-aziendale"],
    "5193": [_P + "l-33-economia-e-commercio"],
    "4190": [_P + "l-18-management-per-la-valorizzazione-sostenibile-delle-aziende-e"],
    "8201": [_P + "lm-data-data-science-for-economics-business-and-finance"],
    "6194": [_P + "lm-77-economia-e-management"],
    "5799": [_P + "lm-56-international-economics-and-commerce"],
    "6193": [_P + "lm-77-management-pubblico-e-dei-sistemi-socio-sanitari"],
    "5392": [_P + "lm-16-scienze-economiche-e-finanziarie"],
    "6195": [_P + "lm-77-sustainability-management-and-circular-economy"],
    "4597": [_P + "l-8-ingegneria-biomedica"],
    "4594": [_P + "l-7-ingegneria-civile-e-ambientale"],
    "4598": [_P + "l-8-ingegneria-dellinformazione-per-videogame-e-realta-virtuale"],
    "5196": [_P + "l-23-ingegneria-edile"],
    "4595": [_P + "l-8-ingegneria-elettronica-e-delle-tecnologie-digitali"],
    "4792": [_P + "l-9-l-8-ingegneria-gestionale"],
    "4596": [_P + "l-8-ingegneria-informatica-e-dell-automazione"],
    "5195": [_P + "l-9-ingegneria-meccanica"],
    "4591": [_P + "l-9-ingegneria-per-la-sostenibilita-industriale"],
    "774": [_P + "l-p03-sistemi-industriali-e-dell-informazione"],
    "773": [_P + "l-p01-tecniche-della-costruzione-e-gestione-del-territorio"],
    "5393": [_P + "lm-21-biomedical-engineering"],
    "5794": [_P + "lm-35-environmental-engineering"],
    "5595": [_P + "lm-30-green-industrial-engineering"],
    "5591": [_P + "lm-23-ingegneria-civile"],
    "2984": [_P + "lm-33-ingegneria-delle-infrastrutture-energetiche-e-della-logistic"],
    "5592": [_P + "lm-24-ingegneria-edile"],
    "5593": [_P + "lm-29-ingegneria-elettronica"],
    "5791": [_P + "lm-31-ingegneria-gestionale"],
    "5792": [_P + "lm-32-ingegneria-informatica-e-dell-automazione"],
    "5793": [_P + "lm-33-ingegneria-meccanica"],
    "6196": [_P + "lm-4-c-u-ingegneria-edile-architettura"],
    "452": [_P + "l-snt3-dietistica-abilitante-alla-professione-sanitaria-di-dietista"],
    "374": [_P + "l-snt2-educazione-professionale-abilitante-alla-professione-sanitar"],
    "382": [_P + "l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot"],
    "6798": [_P + "l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot-1627918"],
    "371": [_P + "l-snt3-igiene-dentale-abilitante-alla-professione-sanitaria-di-igie"],
    "383": [_P + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf"],
    "7201": [_P + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1628876"],
    "7202": [_P + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1628931"],
    "7200": [_P + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1628918"],
    "7199": [_P + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1628927"],
    "451": [_P + "l-snt2-logopedia-abilitante-alla-professione-sanitaria-di-logopedis"],
    "7598": [_P + "l-snt2-logopedia-abilitante-alla-professione-sanitaria-di-logopedis-1627919"],
    "376": [_P + "l-snt1-ostetricia-abilitante-alla-professione-sanitaria-di-ostetric"],
    "6197": [_P + "l-22-scienze-motorie-per-la-salute-e-l-invecchiamento-attivo-heal"],
    "379": [_P + "l-snt4-tecniche-della-prevenzione-nell-ambiente-e-nei-luoghi-di-lav"],
    "3184": [_P + "l-snt3-tecniche-di-fisiopatologia-cardiocircolatoria-e-perfusione-c"],
    "375": [_P + "l-snt3-tecniche-di-radiologia-medica-per-immagini-e-radioterapia-ab"],
    "7398": [_P + "l-snt3-tecniche-di-radiologia-medica-per-immagini-e-radioterapia-ab-1627920"],
    "733": [_P + "l-snt2-terapia-della-neuro-e-psicomotricita-dell-eta-evolutiva-abil"],
    "372": [_P + "l-snt3-tecniche-di-laboratorio-biomedico-abilitante-alla-profession"],
    "753": [_P + "lm-snt2-scienze-riabilitative-delle-professioni-sanitarie"],
    "8211": [_P + "lm-snt1-scienze-infermieristiche-specialistiche-nelle-cure-primarie"],
    "8208": [_P + "lm-snt1-scienze-infermieristiche-specialistiche-nelle-cure-intensive"],
    "8210": [_P + "lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic"],
    "5795": [_P + "lm-41-medicina-e-chirurgia"],
    "5797": [_P + "lm-41-medicine-and-surgery"],
    "5800": [_P + "lm-46-odontoiatria-e-protesi-dentaria"],
    "5192": [_P + "l-32-environmental-sciences-and-civil-protection"],
    "4593": [_P + "l-13-scienze-biologiche"],
    "5391": [_P + "lm-6-biologia-molecolare-e-applicata"],
    "6192": [_P + "lm-75-environmental-hazard-and-disaster-risk-management"],
    "5198": [_P + "lm-6-marine-biology"],
    "5992": [_P + "lm-61-scienze-della-nutrizione-e-dell-alimentazione"],
}
# codici di corsi di coorti precedenti che hanno cambiato nome oltre al codice: «Scienze infermieristiche e ostetriche»
# di Fermo (MM03F) diventa «… - Profilo infermieristico» (MM12)
PRECEDENTI = {"MM12": ["MM03F"]}

_SEDI = ("ANCONA", "ASCOLI PICENO", "FERMO", "MACERATA", "PESARO")
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
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/univpm)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "univpm" if d else None

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


def _chiave_percorso(pnome: str) -> str:
    """Nome del curriculum senza sede, anno della coorte né prefissi («PS IMMATRICOLATI 2026 X» → «x»,
    «PIANO L-18 642 2026» → «642»), per riconoscerlo tra le coorti. Se resta solo la classe («STATUTARIO L-8»,
    «PIANO L-33 2026») la classe è il nome."""
    n = re.sub(r"\(.*?\)", " ", pnome)
    n = re.sub(r"(?i)\s*-\s*(?:sede\s+)?(?:" + _SEDI_RE + r")\b.*$", "", n)
    n = re.sub(r"(?i)\b(?:" + _SEDI_RE + r")\b", " ", n)
    n = re.sub(r"(?i)\bPS IMMATRICOLATI\b|\b20\d{2}\b", " ", n)
    n = _PREFISSO.sub("", n.strip())
    m = re.search(r"(?i)\bPIANO\b.*?\b(\d{3})\b", n)  # «PIANO L-18 642»: il numero distingue i piani
    if m:
        return m.group(1)
    n = re.sub(r"(?i)\bpiano statutario\b|\bstatutario\b|\bpiano\b|\bclasse\b", " ", n)
    m = re.search(r"(?i)\b(LM?)[\s-]*(\d{1,2}|DATA)\b", n)
    senza = re.sub(r"(?i)\bLM?[\s-]*(?:\d{1,2}|DATA)\b", " ", n)
    testo = re.sub(r"[^a-z0-9]+", " ", senza.lower()).strip()
    if testo or not m:
        return testo
    return f"{m.group(1).lower()} {m.group(2).lower().lstrip('0')}"


def _nome_percorso(pnome: str) -> str:
    """Nome da mostrare: quello del catalogo senza prefisso né anno della coorte."""
    n = re.sub(r"(?i)\bPS IMMATRICOLATI\b|\b20\d{2}\b", " ", pnome)
    n = _PREFISSO.sub("", re.sub(r"\s+", " ", n).strip())
    return n.strip(" :-")


def _e_comune(pnome: str) -> bool:
    """Percorso valido per tutti i curricula («PIANO STATUTARIO», «PERCORSO COMUNE»); non quelli di una classe."""
    return bool(_COMUNE.search(pnome)) and not _CLASSE.search(pnome)


_FREQUENZA = re.compile(r"(?i)\(\s*(?:fr|frequency only|solo frequenza)\s*\)\s*$")


def _e_frequenza(att: dict) -> bool:
    """«Anatomia (FR)», «Biochemistry (frequency only)»: la frequenza a 0 CFU di un insegnamento integrato; i CFU
    sono nell'insegnamento stesso (nello stesso piano o in quello di un'altra coorte)."""
    return not att.get("crediti") and bool(_FREQUENZA.search((att.get("des_it") or "").strip()))


def _voci_anno(det: dict, durata: int, sede: str) -> list:
    """Voci del piano di una coorte: (anno 1..durata, percorso, gruppo, attività o None).

    Le sezioni senza anno (`anno` 0 o non numerico) hanno le attività con `annoCorso` (piano «altreAttivita»):
    ciascuna va nel suo anno, in un gruppo piatto `{"_piatto": True}`; senza `annoCorso` vanno all'ultimo anno.
    Un gruppo senza attività elencate dà una voce con attività None."""
    out = []
    for p in det.get("percorsi") or []:
        pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        if not _percorso_ok(pnome, sede):
            continue
        for a in p.get("anni") or []:
            anno = a.get("anno")
            numerico = str(anno).isdigit() and int(anno) >= 1
            if not numerico and a.get("attivita") and not a.get("insegnamenti"):
                per_anno: dict[int, list] = {}
                for att in a["attivita"]:
                    ac = att.get("annoCorso")
                    k = int(ac) if str(ac).isdigit() and int(ac) >= 1 else durata
                    if k <= durata and not _e_frequenza(att):
                        per_anno.setdefault(k, []).append(att)
                for k, atts in per_anno.items():
                    # attività senza tipo (SNT e Medicina 2026: codici nuovi): sono obbligatorie se non «a scelta dello
                    # studente» e se, con le obbligatorie dell'anno, stanno in 60 CFU; l'anno ha già un piano a gruppi
                    # (altre attività offerte in più): a scelta
                    obb = sum(float(t.get("crediti") or 0) for t in atts if (t.get("tipo_ins_cod") or "").startswith("OBB"))
                    senza = sum(float(t.get("crediti") or 0) for t in atts if not t.get("tipo_ins_cod")
                                and "scelta" not in (t.get("tafDes_it") or "").lower())
                    con_gruppi = any(str(x.get("anno")) == str(k) and x.get("insegnamenti") for x in p.get("anni") or [])
                    piatto = {"label_it": "", "_piatto": True, "_senza_tipo_obbl": not con_gruppi and obb + senza <= 60}
                    out.extend((k, pnome, piatto, att) for att in atts)
                continue
            k = int(anno) if numerico else durata
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
        for cod in PRECEDENTI.get(cur["cdsCod"], []):
            for x in elenco:
                if x["cdsCod"] == cod:
                    return x
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
        voci = {y: _voci_anno(d, durata, sede) for y, (_, d) in cohorts.items()}
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
        # nome dei curricula: quello della coorte più recente che ha lo stesso curriculum
        nomi_percorso: dict[str, str] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                if _percorso_ok(pn, sede) and not _e_comune(pn):
                    nomi_percorso[_chiave_percorso(pn)] = _nome_percorso(pn)
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
            scelta = _coorte_anno(cohorts, voci, k, anno) if coorte_unica is None else (
                coorte_unica if any(v[0] == k for v in voci.get(coorte_unica, [])) else None)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}"}
            validi = [(p.get("des_it") or p.get("pdsDes") or "").strip() for p in d.get("percorsi") or []]
            validi = [p for p in validi if _percorso_ok(p, sede)]
            curricula = {nomi_percorso.get(_chiave_percorso(p), p) for p in validi if not _e_comune(p)}
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/univpm.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def fetch_ateneo(uid: str = "univpm", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None, coorte_unica: int | None = None) -> dict:
    """`coorte_unica`: solo per i controlli, legge tutti gli anni dal piano di una sola coorte."""
    doc = _fetch_piani(uid, anno, max_cds, syllabus, log, client, coorte_unica)
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
    out = ROOT / "database" / "contrib" / "auto" / "univpm.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[univpm] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
