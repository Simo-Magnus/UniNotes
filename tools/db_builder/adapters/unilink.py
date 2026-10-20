"""Link Campus University: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unilink.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) il catalogo di Link richiede:

- durata dal piano («3 anni», «6 anni»): l'elenco minimale non ha `durataAnni`;
- piani «per coorte» dentro un solo corso: molti piani hanno un percorso per coorte («Coorte 2024/2025»,
  «SCHEMA DI PIANO COORTE 24», «… COORTE 2025»): non sono curricula ma il piano di ciascuna coorte, tutti
  gli anni. Per l'anno k si legge la coorte di chi lo frequenta oggi (anno - k + 1): il percorso con
  quella coorte (se l'anno ha almeno 30 CFU), altrimenti il piano di una coorte più vicina che ha
  quell'anno, di preferenza con almeno 60 CFU; l'url riporta il catalogo del piano e `piano_anni` la
  coorte usata per ogni anno. Le coorti precedenti si ritrovano per codice, per nome, sede e tipo
  (i codici cambiano con il riordino: «LMGR» → «GIUR», «MEDEC» → «MEDECRM»);
- gruppi del piano: «Obbligatori»; i gruppi `F` portano i CFU richiesti nell'etichetta («ADE 1° Anno
  (2 CFU)», «1° ANNO - ADE, Laboratori, Seminari (5 CFU)»). Se le attività del gruppo sommano i CFU
  richiesti si sostengono tutte (laboratori, seminari, tirocini, altre conoscenze: obbligatorie); se ne
  offrono di più si sceglie (insegnamenti a scelta, lingue a scelta) e il segnaposto «a scelta» /
  «elective» e le ADE restano a scelta;
- insegnamenti integrati: il catalogo elenca il contenitore a 0 CFU («Diritto Romano», «Didattica
  generale … e Laboratorio …», `adFiglie`) accanto ai suoi moduli con i CFU: il contenitore si toglie, i
  moduli restano (`modulo_di`) e ricevono gli appelli del contenitore (`appelli_moduli`);
- stesso nome nello stesso anno con codici e CFU diversi: il nome porta i CFU o il codice;
- sedi: lo stesso corso ha un corso del catalogo per sede, mentre Universitaly elenca i corsi con la sede nel nome
  («… REPLICA <sede>») o senza. `ID_CORSI` lega ogni corso del catalogo al corso di Universitaly della stessa sede:
  il corso senza «REPLICA» è la sede che resta (Roma per Medicina, Città di Castello per Odontoiatria e
  Formazione primaria, sedi indicate da Universitaly). Dove due o tre corsi di Universitaly sono indistinguibili
  (Fisioterapia e Infermieristica di Roma e Città di Castello, Osteopatia di Roma, Città di Castello e Novedrate)
  non si sa quale sia quale sede: ognuno riceve il piano della sede di Roma, senza docenti (`SENZA_SEDE`).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unilink.json` mantenendo appelli e canali già presenti):

    python tools/db_builder/adapters/unilink.py [--senza-syllabus]
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
from .univpm import _gruppo_per_intero, _gruppo_senza_attivita  # noqa: E402

BASE = "https://unilink.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici (D2: dottorati, non sono corsi)
_L = "unilink-"
_F0 = _L + "l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot"
_I0 = _L + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf"

# codice (`cod`) del corso nella coorte 2026 → id dei corsi del database a cui va il piano della sede.
ID_CORSI: dict[str, list[str]] = {
    "10513": [_L + "l-3-dams-produzione-audiovisiva-e-teatrale"],
    "10511": [_L + "l-18-economia-e-management-d-impresa-e-delle-istituzioni"],
    "10739": [_L + "l-snt3-igiene-dentale-abilitante-alla-professione-sanitaria-di-igie"],
    "10552": [_L + "l-8-ingegneria-dell-intelligenza-artificiale"],
    "10500": [_L + "l-19-scienze-dell-educazione-e-della-formazione"],
    "10498": [_L + "l-22-scienze-delle-attivita-motorie-e-sportive"],
    "10517": [_L + "l-20-scienze-delle-comunicazioni-media-e-tecnologie-digitali"],
    "10499": [_L + "l-24-scienze-e-tecniche-psicologiche"],
    "10510": [_L + "l-36-scienze-politiche-diplomatiche-e-governo-delle-amministrazio"],
    "10166": [_L + "l-snt3-tecniche-di-laboratorio-biomedico-abilitante-alla-profession"],
    "10167": [_L + "l-snt3-tecniche-di-radiologia-medica-per-immagini-e-radioterapia-ab"],
    "10551": [_L + "lm-77-corporate-management-and-public-administration"],
    "10550": [_L + "lm-56-scienze-economiche-del-lavoro-e-dei-sistemi-socio-sanitari"],
    "10540": [_L + "lm-62-studi-strategici-e-politiche-della-sicurezza"],
    "10947": [_L + "lm-59-tecnologie-e-linguaggi-della-comunicazione"],
    "10233": [_L + "lm-13-farmacia"],
    "10539": [_L + "lmg-01-giurisprudenza"],
    "10501": [_L + "lm-42-medicina-veterinaria"],
    # Medicina e chirurgia: il corso senza «REPLICA» è la sede che resta (Roma)
    "10512": [_L + "lm-41-medicina-e-chirurgia"],
    "10211": [_L + "lm-41-medicina-e-chirurgia-replica-novedrate"],
    "10453": [_L + "lm-41-medicina-e-chirurgia-replica-ascoli-piceno"],
    "10461": [_L + "lm-41-medicina-e-chirurgia-replica-fano"],
    "10464": [_L + "lm-41-medicina-e-chirurgia-replica-frosinone"],
    "10509": [_L + "lm-41-medicina-e-chirurgia-replica-pietra-ligure"],
    "10612": [_L + "lm-41-medicina-e-chirurgia-replica-citta-di-castello"],
    "10613": [_L + "lm-41-medicina-e-chirurgia-replica-pescara"],
    "10789": [_L + "lm-41-medicina-e-chirurgia-replica-matera"],
    # Odontoiatria: senza «REPLICA» = Città di Castello
    "10232": [_L + "lm-46-odontoiatria"],
    "10465": [_L + "lm-46-odontoiatria-replica-macerata"],
    "10502": [_L + "lm-46-odontoiatria-replica-roma"],
    "10614": [_L + "lm-46-odontoiatria-replica-pescara"],
    # Scienze della formazione primaria: senza «REPLICA» = Città di Castello
    "10112": [_L + "lm-85-bis-scienze-della-formazione-primaria"],
    "10553": [_L + "lm-85-bis-scienze-della-formazione-primaria-replica-roma"],
    "10617": [_L + "lm-85-bis-scienze-della-formazione-primaria-replica-napoli"],
    # Osteopatia: «REPLICA CATANIA» è la sede di Catania
    "10615": [_L + "l-snt4-osteopatia-replica-catania"],
    # Fisioterapia e Infermieristica: le sedi «REPLICA <sede>»
    "10605": [_F0 + "-1631533"], "10606": [_F0 + "-1631512"], "10609": [_F0 + "-1631525"],
    "10704": [_F0 + "-1631524"], "10788": [_F0 + "-1631537"], "10214": [_F0 + "-1631531"],
    "10215": [_F0 + "-1631530"], "10607": [_F0 + "-1631532"],
    "10611": [_I0 + "-1631535"],
    # Scienze della difesa e della sicurezza: «REPLICA ROMA» è la sede di Roma
    "10443": [_L + "l-ds-scienze-della-difesa-e-della-sicurezza-replica-roma"],
}

# Corsi di Universitaly con lo stesso nome e senza sede («Fisioterapia …» nelle sedi di Roma e di Città di Castello,
# senza «REPLICA»): non si sa quale sia quale sede. Il piano usato è quello della sede indicata (codice del catalogo),
# senza docenti, per ciascuno; le altre sedi del gruppo non hanno un corso proprio (`SALTA`).
_F = _L + "l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot"
_I = _L + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf"
SENZA_SEDE: dict[str, list[str]] = {
    "10165": [_F, _F + "-1631502"],  # Fisioterapia: Roma e Città di Castello
    "10164": [_I, _I + "-1631500"],  # Infermieristica: Roma e Città di Castello
    "10304": [_L + "l-snt4-osteopatia", _L + "l-snt4-osteopatia-1631506", _L + "l-snt4-osteopatia-1632244"],  # Roma, Città di Castello, Novedrate
    "10443": [_L + "l-ds-scienze-della-difesa-e-della-sicurezza"],  # senza «REPLICA»: sede non indicata
}
# corsi del catalogo che non hanno un corso proprio (le altre sedi dei gruppi sopra)
SALTA = {"10213", "10218", "10300", "10302"}  # Fisioterapia e Infermieristica di Città di Castello, Osteopatia di CdC e Novedrate

_TAG = re.compile(r"(?i)\bcoorte\s*(20\d{2}|\d{2})\b(?:\s*/\s*(?:20)?\d{2}\b)?")
_ANNI_NOME = re.compile(r"\b20\d{2}\s*/\s*20\d{2}\b")
_PREFISSO = re.compile(r"(?i)^\s*(?:cv|curriculum|indirizzo|percorso|orientamento)\b\s*:?\s*")
_SENZA_NOME = re.compile(r"(?i)^(?:unico|comune|generico|statutario)?$")
_LIBERA = re.compile(r"(?i)\bscelta\b|\belective\b|\bADE\b|attivit[aà] didattiche elettive")


def _un(d):
    return d[0] if isinstance(d, list) and d else d


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unilink)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unilink" if d else None

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


# --- percorsi e coorti ------------------------------------------------------------------------

def _tag(pnome: str) -> int | None:
    """Coorte nel nome del percorso («Coorte 2024/2025», «SCHEMA DI PIANO COORTE 24», «… COORTE 2025»)."""
    m = _TAG.search(pnome or "")
    if not m:
        return None
    v = m.group(1)
    return int(v) if len(v) == 4 else 2000 + int(v)


def _nome_percorso(pnome: str) -> str | None:
    """Nome del curriculum senza coorte, prefisso né anni; None se è solo il piano di una coorte o «unico»."""
    n = _TAG.sub(" ", pnome or "")
    n = _ANNI_NOME.sub(" ", n)
    n = re.sub(r"(?i)\bschemi?\s+di\s+piano\b", " ", n)
    n = re.sub(r"\s+", " ", n).strip(" -–:/\t\n")
    n = _PREFISSO.sub("", n).strip(" -–:/")
    return None if _SENZA_NOME.match(n) else n


def _chiave_percorso(nome: str | None) -> str:
    """Per riconoscere lo stesso curriculum in piani diversi: «(E) Interaction Design» = «(ENG) Interaction Design»."""
    n = re.sub(r"(?i)^\s*\((?:e|en|eng|ita)\)\s*", "", nome or "")
    return _norm(n)


def _voci_percorso(p: dict, durata: int):
    """Voci (anno 1..durata, gruppo, attività o None) di un percorso del piano."""
    out = []
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
                    out.append((k, g, None))
                continue
            for att in atts:
                out.append((k, g, att))
    return out


def _cfu_voci(voci: list, k: int) -> float:
    """CFU dell'anno k (una volta per attività; i contenitori a 0 CFU non contano)."""
    visti, tot = set(), 0.0
    for kk, g, att in voci:
        if kk != k:
            continue
        if att is None:
            info = _gruppo_senza_attivita(g)
            if not info or info[3]:
                continue
            chiave, cfu = ("#", info[0], info[1]), float(info[1])
        else:
            chiave, cfu = att.get("adCod") or att.get("cod"), att.get("crediti")
        if chiave not in visti and isinstance(cfu, (int, float)):
            visti.add(chiave)
            tot += cfu
    return tot


class Piano:
    """Piano di una coorte: catalogo `Y`, coorte `e` (quella del percorso, se il nome la indica), percorsi."""

    def __init__(self, y: int, e: int, x: dict, det: dict, percorsi: list[tuple[str, list]]):
        self.y, self.e, self.x, self.det = y, e, x, det
        self.percorsi = percorsi  # (nome del percorso come nel catalogo, voci)

    def ha(self, k: int) -> bool:
        return any(v[0] == k for _, voci in self.percorsi for v in voci)

    def cfu(self, k: int) -> float:
        return max((_cfu_voci(voci, k) for _, voci in self.percorsi), default=0.0)


def _piani(y: int, x: dict, det: dict, durata: int) -> list[Piano]:
    """Piani (uno per coorte) contenuti in un piano del catalogo."""
    percorsi = []
    for p in det.get("percorsi") or []:
        pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        voci = _voci_percorso(p, durata)
        if voci:
            percorsi.append((pnome, voci))
    if not percorsi:
        return []
    tag = {id(p): _tag(p[0]) for p in percorsi}
    tags = sorted({t for t in tag.values() if t})
    senza = [p for p in percorsi if tag[id(p)] is None]
    if not tags:
        return [Piano(y, y, x, det, percorsi)]
    out = []
    for t in tags:
        scelti = [p for p in percorsi if tag[id(p)] == t]
        chiavi = {_chiave_percorso(_nome_percorso(p[0])) for p in scelti if _nome_percorso(p[0])}
        # un percorso senza coorte con lo stesso curriculum di uno della coorte è sostituito da quello
        scelti += [p for p in senza if not (_nome_percorso(p[0]) and _chiave_percorso(_nome_percorso(p[0])) in chiavi)]
        out.append(Piano(y, t, x, det, scelti))
    if senza and y not in tags:  # i percorsi senza coorte sono quelli della coorte del catalogo
        out.append(Piano(y, y, x, det, senza))
    return out


def _scegli(piani: list[Piano], k: int, anno: int) -> Piano | None:
    """Piano da cui leggere l'anno k: la coorte degli iscritti oggi al k-esimo anno (anno - k + 1) o la più
    vicina che ha l'anno, di preferenza con un anno intero (almeno 60 CFU)."""
    y0 = anno - k + 1
    ha = [p for p in piani if p.ha(k)]
    if not ha:
        return None
    esatti = [p for p in ha if p.e == y0 and p.cfu(k) >= 30]
    if esatti:
        return max(esatti, key=lambda p: p.y)
    # la coorte non ha l'anno (o un piano molto parziale): la più vicina, di preferenza con un anno intero
    pieni = [p for p in ha if p.cfu(k) >= 60]
    return min(pieni or ha, key=lambda p: (abs(p.e - y0), -p.e, -p.y))


# --- raccolta ---------------------------------------------------------------------------------

def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    attuali = [x for x in attuali if str(x["cod"]) not in SALTA]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`: stesso codice, poi stesso nome,
        sede e tipo (il codice cambia con il riordino: «LMGR» → «GIUR»), se è uno solo."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        return stessi[0] if len(stessi) == 1 else None

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    cont_jobs: dict[str, dict] = {}  # codice di un contenitore a 0 CFU → lavoro per la sua scheda
    oggi = time.strftime("%Y-%m-%d")

    def job_syllabus(att: dict, ad: str, y: int, alt_per_ad: dict) -> dict:
        """Scheda da leggere per l'attività `att` (una volta per anno accademico e codice): più schede dello
        stesso insegnamento in altre coorti servono, se mancano i testi, per riprenderli (con la fonte)."""
        return syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
            "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                       "ordinamento_aa": att.get("ordinamento_aa"),
                       "af_percorso": att.get("corso_percorso_id"),
                       "corso_cod": att.get("corso_cod"), "corso_aa": y,
                       "schema_id": att.get("schemaId")},
            "items": [],
            "alt": [(a, y_) for (_, _), (y_, a) in sorted(
                alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                if (str(a.get("aa")), str(a.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
        })

    def build_cds(cur: dict) -> dict | None:
        det_att = dettaglio(anno, cur)
        if not det_att:
            return None
        durata = _durata(det_att, cur.get("tipo_corso_cod"))
        piani: list[Piano] = []
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                piani += _piani(y, x, d, durata)
        if not piani:
            return None
        rec = max(piani, key=lambda p: (p.y, p.e)).det
        classe_dettaglio = rec.get("classe_cod")
        amm = ammissione.da_catalogo(det_att, f"{base}/corsi/{anno}/{cur.get('cod')}")
        # CFU di un'attività altrove con 0 CFU nello stesso corso (stesso codice in un'altra coorte)
        cfu_noti: dict[str, float] = {}
        for p in piani:
            for _, voci in p.percorsi:
                for _, _, att in voci:
                    if att is not None and isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                        cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]
        # stessa attività offerta in altre coorti: schede alternative per i libri
        alt_per_ad: dict[str, dict] = {}
        for p in piani:
            for _, voci in p.percorsi:
                for _, _, att in voci:
                    if att is not None:
                        alt_per_ad.setdefault(att.get("adCod") or att.get("cod"), {})[
                            (str(att.get("aa")), str(att.get("cod")))] = (p.y, att)
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        piano_anni: dict[str, dict] = {}
        integrati: dict[str, str] = {}  # codice di un modulo → codice del contenitore a 0 CFU
        for k in range(1, durata + 1):
            sc = _scegli(piani, k, anno)
            if sc is None:
                continue
            piano_anni[str(k)] = {"coorte": sc.e, "catalogo": sc.y, "url": f"{base}/corsi/{sc.y}/{sc.x['cod']}"}
            nomi = {pn: _nome_percorso(pn) for pn, _ in sc.percorsi}
            distinti = {_chiave_percorso(n) for n in nomi.values() if n}
            curricula = distinti if len(distinti) >= 2 else set()
            nome_vis = {}  # chiave → nome da mostrare
            for pn, _ in sc.percorsi:
                if nomi[pn]:
                    nome_vis.setdefault(_chiave_percorso(nomi[pn]), nomi[pn])
            contenitori = {(att.get("adCod") or att.get("cod")) for pn, voci in sc.percorsi for kk, g, att in voci
                           if att is not None and not att.get("crediti") and att.get("adFiglie")}
            for pn, voci in sc.percorsi:
                pcur = nome_vis.get(_chiave_percorso(nomi[pn])) if nomi[pn] and curricula else None
                for kk, g, att in voci:
                    if kk != k:
                        continue
                    gruppo = (g.get("label_it") or "").lower()
                    obbl = "obbligator" in gruppo or g.get("cod") in ("O", "OO")
                    per_intero = _gruppo_per_intero(g)
                    if att is None:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                        nome, cfu, fisso, alt = _gruppo_senza_attivita(g)
                        if alt:
                            continue
                        key = f"{k}:#{_norm(nome)}:{cfu}"
                        item = insegnamenti.get(key)
                        if not item:
                            insegnamenti[key] = item = {
                                "codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu, "ssd": None,
                                "obbligatorio": bool(fisso), "curriculum": None, "_percorsi": set(),
                                "_tutti": set(nome_vis.values()) if curricula else set(), "docenti": [],
                                "url": f"{base}/corsi/{sc.y}/{sc.x['cod']}", "libri": [], "esami": [],
                                "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                    else:
                        ad = att.get("adCod") or att.get("cod")
                        if ad in contenitori:  # integrato: i CFU sono nei moduli
                            if syllabus:  # la scheda del contenitore serve ai moduli senza testi propri
                                cont_jobs.setdefault(ad, job_syllabus(att, ad, sc.y, alt_per_ad))
                            continue
                        libera = bool(_LIBERA.search(att.get("des_it") or "") or
                                      "scelta" in (att.get("tafDes_it") or "").lower())
                        voluto = bool(obbl or att.get("tipo_ins_cod") == "OBB" or (per_intero and not libera))
                        key = f"{k}:{ad}"
                        item = insegnamenti.get(key)
                        if not item:
                            docenti = [cc._nome(x_.get("des")) for x_ in att.get("docenti") or [] if x_.get("des")]
                            padre = att.get("adPadre") or {}
                            item = {
                                "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                                "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                "periodo_fine": att.get("data_fine_periodo_didattico"),
                                "cfu": att.get("crediti") or cfu_noti.get(ad), "ssd": None,
                                "obbligatorio": voluto, "curriculum": None, "_percorsi": set(),
                                "docenti": sorted(set(docenti)),
                                "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                       f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={sc.y}",
                                "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                "_tutti": set(nome_vis.values()) if curricula else set(),
                            }
                            if padre.get("adCod"):  # modulo di un insegnamento integrato
                                item["_padre"] = padre["adCod"]
                                item["modulo_di"] = cc._titolo(padre.get("adDes_it") or padre["adCod"])
                                integrati[ad] = padre["adCod"]
                            insegnamenti[key] = item
                            if syllabus:
                                job_syllabus(att, ad, sc.y, alt_per_ad)["items"].append(item)
                        elif voluto:
                            item["obbligatorio"] = True
                    if pcur:
                        item["_percorsi"].add(pcur)
                        percorsi_nomi.add(pcur)
                    elif curricula:
                        item["_percorsi"].add(None)  # percorso comune a tutti i curricula
        ins = list(insegnamenti.values())
        for i in ins:
            raw, tutti = i.pop("_percorsi"), i.pop("_tutti", set())
            ps = {p for p in raw if p}
            if ps and None not in raw and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        # stesso nome nello stesso anno con codici e CFU diversi: il nome porta i CFU
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"] if i.get("codice") else None), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    if isinstance(i["cfu"], (int, float)):
                        i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        # stesso nome, anno e curriculum con codici diversi e gli stessi CFU: a scelta, lo stesso insegnamento;
        # altrimenti (due esami) il nome porta il semestre o il codice
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
        # voci senza codice con lo stesso nome in anni diversi: il nome porta l'anno
        anni_nome: dict[str, set] = {}
        for i in ins:
            if i.pop("_senza_codice", False):
                anni_nome.setdefault(_norm(i["nome"]), set()).add(i["anno"])
                i["_nk"] = _norm(i["nome"])
        for i in ins:
            nk = i.pop("_nk", None)
            if nk and len(anni_nome[nk]) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        return {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or classe_dettaglio),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "integrati": integrati, "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

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
        if not libri:  # scheda di un'altra coorte dello stesso insegnamento (con la fonte)
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
        job["libri"] = libri
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
    # moduli senza testi propri: quelli della scheda dell'insegnamento integrato (contenitore), con la nota
    ereditati = 0
    for corso in corsi_out:
        for i in corso["insegnamenti"]:
            padre = i.pop("_padre", None)
            job = cont_jobs.get(padre) if padre else None
            if syllabus and job and job.get("libri") and not i["libri"]:
                nota = f"Dalla scheda dell'insegnamento integrato «{i.get('modulo_di')}» ({base}/insegnamenti/"                        f"{job['params']['anno']}/{job['params']['insegnamento']})"
                i["libri"] = [{**b, "note": ((b.get("note") + " | ") if b.get("note") else "") + nota} for b in job["libri"]]
                i["stato_libri"] = "completo"
                ereditati += 1
    log(f"[{uid}] libri trovati: {trovati}; moduli con i testi del contenitore: {ereditati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unilink.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _senza_docenti(c: dict) -> dict:
    for i in c["insegnamenti"]:
        i["docenti"] = []
    return c


def fetch_ateneo(uid: str = "unilink", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    doc = _fetch_piani(uid, anno, max_cds, syllabus, log, client)
    corsi = []
    for c in doc["corsi"]:
        cod = str(c.get("url") or "").rsplit("/", 1)[-1]
        if cod in ID_CORSI:  # una copia del piano per ogni corso del database (id esplicito)
            corsi += [{**copy.deepcopy(c), "id": i} for i in ID_CORSI[cod]]
        for i in SENZA_SEDE.get(cod, []):
            corsi.append({**_senza_docenti(copy.deepcopy(c)), "id": i, "sede": None, "url": None,
                          "codice_ateneo": None})
        if cod not in ID_CORSI and cod not in SENZA_SEDE:
            corsi.append(c)
    doc["corsi"] = corsi
    log(f"[{uid}] corsi del database legati per id: {sum(1 for c in corsi if c.get('id'))}")
    return doc


def appelli_moduli(corsi: list[dict], appelli: dict) -> dict:
    """I moduli di un insegnamento integrato (contenitore a 0 CFU tolto dal piano) hanno gli appelli del
    contenitore: la bacheca li elenca con il codice del contenitore."""
    for c in corsi:
        for modulo, contenitore in (c.get("integrati") or {}).items():
            if modulo not in appelli and appelli.get(contenitore):
                appelli[modulo] = appelli[contenitore]
    return appelli


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unilink.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    appelli = vecchio.get("appelli") or {}
    try:  # gli appelli della bacheca Esse3 sono nel file accanto: servono per i moduli degli integrati
        bacheca = json.loads((out.parent / "unilink_appelli.json").read_text(encoding="utf-8")).get("appelli", {})
    except (OSError, ValueError):
        bacheca = {}
    tutti = {**bacheca, **appelli}
    appelli_moduli(doc["corsi"], tutti)
    doc["appelli"] = {**appelli, **{k: v for k, v in tutti.items() if k not in bacheca and k not in appelli}}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unilink] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
