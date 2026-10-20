"""Università di Camerino (UniCam): piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unicam.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`): con i riordini il codice del catalogo cambia («L-CHI» → «L-CHIR»,
  «LM-FAR» → «LM-FARA» → «LM-FARAR») e le coorti precedenti restano sotto il codice vecchio. Per l'anno di corso k nell'a.a. A
  si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno) del codice più recente che ha il piano di quell'anno
  (catena di codici); se la coorte non ha quell'anno (corsi nati nel 2026) si usa la più vicina che lo ha;
- durata dal piano («3 anni», «5 anni»): l'elenco minimale delle coorti non la dà e i cicli unici di cinque anni
  restavano con i soli primi tre anni;
- gruppi del piano (`cod`): «OO» obbligatori; «F», «G», «W» scelte o blocchi fissi. Un'attività è obbligatoria se sta in «OO»
  (salvo quelle «a scelta dello studente» del catalogo, come «A libera scelta»), se è l'unica del gruppo senza una scelta
  nell'etichetta («Stage» con una sola attività); i blocchi di alternative («Stage interno / esterno / estero», «Choose two
  courses from this list», «Attività formative a scelta», le attività a libera scelta «fra 1 e N CFU») sono a scelta;
- attività a 0 CFU (OFA, obblighi formativi aggiuntivi, prove di lingua senza crediti) non sono insegnamenti del piano;
- percorsi: «comune» (nome «comune» o «percorso generico») valgono per tutti i curricula; i curricula si riconoscono per nome
  (alcuni corsi hanno più percorsi con il flag «comune» e nomi diversi: sono curricula veri). Lo stesso codice con CFU diversi
  in percorsi diversi resta su righe distinte.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/unicam.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unicam.py [--senza-syllabus]
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

BASE = "https://unicam.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5"}  # lauree, magistrali e ciclo unico di cinque anni (non scuole di specializzazione, corsi di perfezionamento e master)

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio).
# I codici più vecchi sono il vecchio ordinamento o il vecchio nome dello stesso corso (le coorti precedenti).
CORSI: list[tuple[str, tuple[str, ...]]] = [
    ("1628636", ("L-AGRNR", "L-AGRN")),            # Ambiente e gestione sostenibile delle risorse naturali (L-32)
    ("1628635", ("L-BNR", "L-BN")),                # Biologia della nutrizione (L-13, San Benedetto del Tronto)
    ("1628634", ("L-BBR", "L-BB")),                # Bioscienze e biotecnologia (L-2/L-13)
    ("1628763", ("L-CHIR", "L-CHI")),              # Chimica (L-27)
    ("1628620", ("L-DIR", "L-DI")),                # Design (L-4), già Disegno industriale e ambientale (Ascoli Piceno)
    ("1628764", ("L-FISR", "L-FI")),               # Fisica (L-30)
    ("1628766", ("L-INFR", "L-INF")),              # Informatica (L-31)
    ("1628765", ("L-ICDR", "L-ICD")),              # Informatica per la comunicazione digitale (L-31)
    ("1628627", ("L-ISF", "L-FFSR", "L-FFS")),     # Informazione scientifica sul farmaco (L-29), già con il curriculum del fitness
    ("1628768", ("L-MAR", "L-MA")),                # Matematica e applicazioni (L-35)
    ("1628621", ("L-SAR", "L-SA")),                # Scienze dell'architettura (L-17, Ascoli Piceno)
    ("1625582", ("L-SAMS",)),                      # Scienze delle attività motorie e sportive (L-22, nuovo 2026)
    ("1628628", ("L-GASTRR", "L-GASTR")),          # Scienze gastronomiche (L/GASTR)
    ("1628767", ("L-SGTAR", "L-SGTA")),            # Scienze geologiche e tecnologie per l'ambiente (L-34)
    ("1628625", ("L-SGT",)),                       # Scienze giuridiche per il governo dei territori (L-14, nuovo 2026: altro piano di L-GICR)
    ("1628637", ("L-TBAR",)),                      # Tecnico del benessere animale e delle produzioni (L-38, Matelica)
    ("1628769", ("L-TEDR", "L-TED")),              # Tecnologie e diagnostica per i beni culturali (L-43)
    ("1628623", ("LM-AR", "LM-A")),                # Architettura (LM-4, Ascoli Piceno)
    ("1628638", ("LM-BSR", "LM-BS")),              # Biological Sciences (LM-6)
    ("1625583", ("LM-BTMV",)),                     # Biotecnologie per le scienze mediche e veterinarie (LM-9, nuovo 2026)
    ("1628772", ("LM-CHR", "LM-CAC")),             # Chemistry (LM-54)
    ("1628624", ("LM-DIDR", "LM-DID")),            # Design per l'innovazione e la cultura digitale (LM-12, Ascoli Piceno)
    ("1628770", ("LM-FIR", "LM-FI")),              # Fisica - Physics (LM-17)
    ("1634270", ("LM-GRRR", "LM-GRR")),            # Geoenvironmental Resources and Risks (LM-74)
    ("1628626", ("LM-GFMR", "LM-GFM")),            # Gestione dei fenomeni migratori e politiche di integrazione (LM-90)
    ("1628762", ("LM-CS",)),                       # Informatica - Computer Science (LM-18)
    ("1628771", ("LM-MATR", "LM-MAT")),            # Matematica e applicazioni - Mathematics and Applications (LM-40)
    ("1628622", ("LM-PAIS",)),                     # Paesaggio, innovazione e sostenibilità (LM-3, Ascoli Piceno)
    ("1628631", ("LM-ScIC",)),                     # Scienza e innovazione del cibo (LM/GASTR)
    ("1628629", ("LM-CTFAR", "LM-CTFA", "LM-CTF")),  # Chimica e tecnologia farmaceutiche (LM-13, 5 anni)
    ("1628630", ("LM-FARAR", "LM-FARA", "LM-FAR")),  # Farmacia (LM-13, 5 anni)
    ("1629585", ("LMG01R", "LMG01")),              # Giurisprudenza (LMG/01, 5 anni)
    ("1634269", ("LM-MVR", "LM-MV")),              # Medicina veterinaria (LM-42, Matelica, 5 anni)
]

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
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unicam)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unicam" if d else None

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
    return {"L2": 3, "LM": 2, "LM5": 5}.get(tipo or "", 3)


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
    if _a_scelta_studente(att):  # «A libera scelta», crediti liberi del catalogo: a scelta anche dentro «Obbligatori»
        return False
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
    con la virgola)."""
    nome = _titolo(nome) if nome.isupper() else nome
    nome = re.sub(r"\s*,\s*", " - ", nome)
    return nome[:1].upper() + nome[1:]


def _lettera(p: dict) -> str | None:
    m = re.match(r"PDS([A-Z])", (p.get("pdsCod") or "").strip())
    return m.group(1) if m else None


def _comune(p: dict) -> bool:
    """Percorso comune a tutti: dal nome («comune», «percorso generico»). Il flag «comune» del catalogo e il codice «PDS0…»
    non bastano: i curricula di Bioscienze e Biotecnologia hanno tutti lo stesso codice «PDS0-2025» e il flag."""
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
                    for g in _gruppi(a):
                        if not _vale(a, k, g, y, durata):
                            continue
                        atts = [t for t in g.get("attivita") or [] if (t.get("crediti") or 0) > 0]
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unicam.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "unicam.json", ROOT / "database" / "contrib" / "auto" / "unicam_syl_b2.json"):
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


def fetch_ateneo(uid: str = "unicam", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unicam.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unicam] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
