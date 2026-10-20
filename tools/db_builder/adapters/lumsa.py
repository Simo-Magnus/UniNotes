"""LUMSA (Roma e Palermo): piani di studio per coorte, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://lumsa.coursecatalogue.cineca.it` (API pubblica, coorti 2022-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) il catalogo della LUMSA richiede:

- un corso per ogni corso di Universitaly (tabella `CORSI`: id Universitaly → catena dei codici del catalogo, dal più recente
  al più vecchio). Con il riordino del 2025 i codici sono cambiati («R403/02» → «L18», «400/15» → «LMG01R»...) e le coorti
  2022-2024 stanno ancora sotto il codice vecchio: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli
  iscritti oggi al k-esimo anno) col primo codice della catena che ha quella coorte con gli anni. Se la coorte degli iscritti
  non ha l'anno (o non è nel catalogo: Giurisprudenza di Palermo ha solo le coorti 2022-2024) si usa la più vicina che lo ha
  e l'anno è segnalato in `anni_da_altra_coorte`;
- durata dal tipo del catalogo (L2 3, LM 2, LM5 5): l'elenco minimale non ha `durataAnni`;
- sede: i percorsi «Schema piano sede di Roma / Palermo / Taranto», «Schema Piano Roma» / «Taranto-Palermo», «… SEDE ROMA»
  sono piani diversi per sede dello stesso corso: si legge solo quello della sede del corso di Universitaly;
- il flag `comune` dei percorsi del catalogo non dice nulla (è vero anche per cinque piani alternativi di Giurisprudenza):
  è comune a tutti solo il percorso che si chiama «comune» e, se ce ne sono altri con i propri insegnamenti, è uno dei
  percorsi come gli altri («Comune» e «Programma internazionale» di Giurisprudenza Roma);
- gruppi del piano (`cod`): «OO» obbligatori; «F» (insegnamenti «a scelta tra», di solito uno solo: la Prima lingua, la
  Letteratura...; con «(N CFU)» nell'etichetta il gruppo vale N CFU) e «W» (l'elenco delle discipline a scelta dello studente)
  a scelta. Un gruppo «F» con un solo insegnamento (o i cui insegnamenti sommano esattamente i CFU dell'etichetta) è da
  sostenere per intero: obbligatorio;
- anno «altreAttivita» (laboratori, cliniche, tirocini, insegnamenti di altri percorsi: non legati a un anno): ogni attività
  porta l'a.a. in cui è offerta (`aa`), quindi per la coorte c è dell'anno di corso aa - c + 1; quelle con CFU, offerte
  nell'a.a. dell'anno di corso k, che non sono nel piano di nessun percorso della coorte (di nessuna sede) e non sono di tipo
  base, caratterizzante, affine o prova finale (sarebbero insegnamenti del piano con un altro codice o di un altro anno), si
  offrono nell'anno k a scelta (obbligatorie solo se il catalogo le dà obbligatorie), con il curriculum del percorso che le
  elenca (nessuno se il percorso è «comune»); non per gli anni letti da un'altra coorte, né dalla lista «comune» dei corsi che
  hanno un piano per sede (è di tutte le sedi);
- percorsi: lo stesso percorso nelle coorti e nei codici del riordino si riconosce per nome (senza «Piano di studio», «area»,
  «percorso»...), per nome simile o per gli insegnamenti in comune; i percorsi che compaiono solo in un codice vecchio
  restano curricula a sé;
- attività a 0 CFU (OFA, idoneità di lingua inglese, corsi di lingua): non sono insegnamenti del piano e si tolgono; i CFU
  mancanti si leggono, se ci sono, dallo stesso codice in un'altra coorte;
- stesso codice obbligatorio in un percorso e a scelta in un altro: due righe (build_db le tiene separate se i curricula
  sono disgiunti), altrimenti una sola, obbligatoria;
- alternative omonime nello stesso anno e curriculum: con CFU diversi il nome porta i CFU, con gli stessi CFU e lo stesso
  docente (due codici per la stessa scheda) è un insegnamento solo, altrimenti il nome porta il semestre o il codice;
- libri: quelli già raccolti per lo stesso codice nel database non si rileggono; gli altri dal syllabus.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte restano su disco (`lumsa_cc`). Richieste: 4 al secondo.

Esecuzione locale (scrive `database/contrib/auto/lumsa.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/lumsa.py [--senza-syllabus]
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

BASE = "https://lumsa.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 4.0
TIPI = {"L2", "LM", "LM5"}
DURATA_TIPO = {"L2": 3, "LM": 2, "LM5": 5}

# Un corso per ogni corso di Universitaly: id Universitaly → codici del corso nel catalogo (cdsCod), dal più recente al più
# vecchio. Con il riordino del 2025 i corsi hanno un codice nuovo (coorti 2025 e 2026) e le coorti 2022-2024 restano sotto il
# vecchio (stesso corso: stessa sede, stessa classe, stesso sito del corso). Giurisprudenza di Palermo è solo nelle coorti
# 2022-2024 (400/68); Scienze della formazione primaria di Palermo (replica) è il piano «SEDE PALERMO» del corso R100/42.
CORSI = {
    "1630008": ["L18", "R403/02"],            # Economia e gestione aziendale (L-18, Roma)
    "1630007": ["L12", "R400/25"],            # Mediazione linguistica e culturale (L-12, Roma)
    "1630014": ["L39", "R100/43"],            # Scienze del servizio sociale e del non profit (L-39, Roma)
    "1630013": ["L36", "R410/03"],            # Scienze politiche e studi internazionali (L-36, Roma; già «… e internazionali»)
    "1630009": ["L19R", "R110/01"],           # Scienze dell'educazione e della formazione (L-19, Roma; già «… dell'educazione»)
    "1627917": ["L20R", "R110/03"],           # Scienze della comunicazione, Marketing e digital media (L-20, Roma)
    "1630011": ["L24", "R100/41"],            # Scienze e tecniche psicologiche (L-24, Roma)
    "1630010": ["L20P-25", "P700-L20"],       # Comunicazione digitale e marketing (L-20, Palermo)
    "1630012": ["L33", "P700/01"],            # Economia e commercio (L-33, Palermo)
    "1626003": ["LM59ENR"],                   # AI for Marketing and Communication (LM-59, Roma, dal 2026)
    "1630027": ["LM91", "R110/07"],           # Comunicazione, innovazione ed experience design (LM-91)
    "1630021": ["LM59P"],                     # Digital Communication - Society, Business & Culture (LM-59, Palermo)
    "1630023": ["LM77P", "P700/02LM"],        # Economia e management (LM-77, Palermo)
    "1630024": ["LM77R", "R410LM77"],         # Management, Finance and Data Analytics (LM-77, Roma)
    "1630020": ["LM59R", "R110/02"],          # Marketing & Digital Communication (LM-59, Roma)
    "1630025": ["LM85"],                      # Pedagogia e progettazione socio-educativa (LM-85, Roma, dal 2025)
    "1630022": ["LM62", "R410/04"],           # Politiche, amministrazioni e innovazione (LM-62)
    "1630026": ["LM87", "R100/45"],           # Programmazione e gestione delle politiche e dei servizi sociali (LM-87, Roma)
    "1630018": ["LM51PC", "R02-LM51"],        # Psicologia clinica (LM-51)
    "1630017": ["LM51PS", "R01-LM51"],        # Psicologia sociale, forense e delle organizzazioni (LM-51)
    "1630019": ["LM52", "R400/23"],           # Relazioni internazionali (LM-52)
    "1630015": ["LMG01R", "400/15"],          # Giurisprudenza (LMG/01, Roma)
    "1630016": ["400/68"],                    # Giurisprudenza (LMG/01, Palermo): solo coorti 2022-2024 nel catalogo
    "1630006": ["LM85bisR", "R100/42"],       # Scienze della formazione primaria (LM-85 bis, Roma)
    "1630028": ["LM85bisP", "R100/42"],       # Scienze della formazione primaria, replica di Palermo
}
# sede di ogni corso (per scegliere il piano della sede nei corsi che ne hanno più d'uno)
SEDE_CORSO = {"1630010": "palermo", "1630012": "palermo", "1630021": "palermo", "1630023": "palermo",
              "1630016": "palermo", "1630028": "palermo"}  # gli altri sono a Roma
CITTA = ("roma", "palermo", "taranto")
# tipi di attività (TAF) del piano: se «altreAttivita» ne ha di non nel piano sono insegnamenti del piano di altri anni o percorsi
# (o la stessa attività con un altro codice), non attività in più: si tengono solo le «a scelta dello studente», i tirocini...
TAF_DEL_PIANO = {"base", "caratterizzante", "affine/integrativa", "lingua/prova finale"}

_ETICHETTA_CFU = re.compile(
    r"(?:\(\s*)?(?:(?:fra|tra)\s+([\d.,]+)\s+e\s+)?(?<![\w.,])([\d.,]*\d)\s*(?:CFU|crediti)\b(?:\s*\))?", re.I)
_COMUNE = re.compile(r"(?i)\bcomune\b|\bstatutario\b")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti: le parentesi restano."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/lumsa_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "lumsa_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _cfu_etichetta(label: str | None):
    """(minimo, massimo) dei CFU nell'etichetta di un gruppo: «(10 CFU)» → (10, 10), «(fra 1 e 6 CFU)» → (1, 6)."""
    m = _ETICHETTA_CFU.search(label or "")
    if not m:
        return None
    try:
        hi = _numero(m.group(2).strip(".,"))
        lo = _numero(m.group(1).strip(".,")) if m.group(1) else hi
    except ValueError:
        return None
    return lo, hi


def _titolo_etichetta(s: str) -> str:
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    return s[:1].upper() + s[1:].lower() if s else s


def _nome_regola(label: str) -> str:
    """Nome della voce a scelta di una regola senza elenco: l'etichetta in minuscolo con l'iniziale maiuscola, con
    l'intervallo dei CFU («fra 1 e 6 CFU») se non è fisso."""
    lab = re.sub(r"\s+", " ", label or "").strip()
    lab = re.sub(r"\(\s*[A-Z]{1,5}/\d+\s*\)|\b[A-Z]{1,5}/\d+\b", " ", lab)  # codice del curriculum «(AF/1)»
    cfu = _cfu_etichetta(lab)
    resto = _ETICHETTA_CFU.sub(" ", lab)
    resto = re.sub(r"\(\s*\)", " ", resto)
    resto = re.sub(r"\s+", " ", resto).strip(" -–:/,")
    nome = re.sub(r"(?i)\battivita'", "attività", _titolo_etichetta(resto))
    nome = nome[:1].upper() + nome[1:]
    if cfu and cfu[0] != cfu[1]:
        nome += f" (fra {cfu[0]:g} e {cfu[1]:g} CFU)"
    return nome


_PAROLE_PERCORSO = {"piano", "pianodi", "di", "studio", "studi", "area", "pds", "schema", "percorso", "curriculum",
                    "indirizzo", "sede"}


# Percorsi che cambiano nome tra le coorti e non si riconoscono né per nome simile né per insegnamenti in comune (deduzione dai
# nomi: stessa classe, stesso corso, un solo percorso rimasto con quel significato): chiave del nome vecchio → chiave del nuovo
ALIAS_PERCORSI = {"educatori sociopedagogici e scolastici": "educatore sociopedagogico"}


def _chiave_percorso(nome: str) -> str:
    """Nome di un percorso per riconoscerlo nelle coorti: senza «Piano di studio», «area», «percorso», «PDS1-2026»..."""
    n = re.sub(r"(?i)\bpds\s*\d+(?:-\d{4})?\b", " ", nome)
    toks = [t for t in _norm(n).split() if t not in _PAROLE_PERCORSO and not t.isdigit()]
    k = " ".join(toks)
    return ALIAS_PERCORSI.get(k, k)


def _nome_att(des: str | None) -> str:
    """Nome dell'attività: iniziali maiuscole e numeri romani («TEOLOGIA II: …» → «Teologia II: …»)."""
    n = cc._titolo(des or "")
    if (des or "").strip().isupper():
        n = re.sub(r"\b(Ii|Iii|Iv|Vi|Vii|Viii|Ix)\b(?=[\s:.,)]|$)", lambda m: m.group(1).upper(), n)
    return n


def _simile(a: str, b: str) -> bool:
    """Stesso percorso con il nome cambiato di poco (uno è l'inizio dell'altro, o quasi uguali)."""
    if not a or not b:
        return False
    corto, lungo = sorted((a, b), key=len)
    if len(corto) >= 8 and lungo.startswith(corto):
        return True
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def _nome_percorso(nome: str) -> str:
    """Nome del curriculum: senza «Piano di studio», «PDS1-2026 -», tabulazioni e punto finale."""
    n = re.sub(r"\s+", " ", nome or "").strip(" -:,.")
    n = re.sub(r"(?i)^pianodi\b", "Piano di", n)
    n = re.sub(r"(?i)^piano di studi?o?\s+(?:area\s+)?", "", n)
    n = re.sub(r"(?i)^pds\s*\d+(?:-\d{4})?\s*[-–:]?\s*", "", n)
    n = re.sub(r"(?i)^pds\s+\d+\s+", "", n)
    n = n.strip(" -:,.")
    if n.isupper() and len(n) > 3:
        n = cc._titolo(n)
    return n[:1].upper() + n[1:]


def _percorsi_sede(percorsi: list[dict], sede: str) -> list[dict]:
    """Piani diversi per sede dello stesso corso («Schema piano sede di Roma», «… SEDE PALERMO», «Taranto-Palermo»): solo
    quelli che nominano la sede del corso e quelli che non nominano nessuna sede."""
    citta = [{c for c in CITTA if c in _norm(p.get("des_it") or p.get("pdsDes") or "").split()} for p in percorsi]
    if not any(citta):
        return percorsi
    scelti = [p for p, cs in zip(percorsi, citta) if not cs or sede in cs]
    return scelti or percorsi


def _adcod_percorso(p: dict) -> set:
    return {t.get("adCod") for a in p.get("anni") or [] if str(a.get("anno")).isdigit()
            for g in a.get("insegnamenti") or [] for t in g.get("attivita") or [] if t.get("adCod")}


def _vale(a: dict, k: int, durata: int | None = None) -> bool:
    """L'anno `a` del piano vale per l'anno di corso k; l'anno 0 (attività senza anno) si colloca nell'ultimo anno."""
    if not str(a.get("anno")).isdigit():
        return False
    n = int(a["anno"])
    return n == k or (n == 0 and durata is not None and k == durata)


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _cfu_anno(det: dict, k: int, durata: int | None = None) -> float:
    """CFU di tutte le attività dell'anno k nel percorso più ricco (0 se l'anno non c'è)."""
    best = 0.0
    for p in det.get("percorsi") or []:
        tot = 0.0
        for a in p.get("anni") or []:
            if _vale(a, k, durata):
                for g in _gruppi(a):
                    tot += sum(float(t.get("crediti") or 0) for t in g.get("attivita") or [])
        best = max(best, tot)
    return best


def _periodo(att: dict) -> str | None:
    p = cc._periodo(att.get("periodo_didattico_it"))
    if p:
        return p
    ps = {cc._periodo(x.get("periodo_didattico_it")) for x in (att.get("frazioni") or []) + (att.get("moduli") or [])}
    ps.discard(None)
    return ps.pop() if len(ps) == 1 else None


def _sede(cur: dict, cohorts: dict) -> str | None:
    """«ROMA (RM)» → «Roma (RM)»."""
    s = cur.get("sedeDenominazioneComune") or cur.get("sede_des_it")
    for y in sorted(cohorts, reverse=True):
        if s:
            break
        d = cohorts[y][1]
        s = d.get("sedeDenominazioneComune") or d.get("sede_des_it")
    if not s:
        return None
    m = re.fullmatch(r"(.+?)\s*\((\w+)\)", s.strip())
    return f"{m.group(1).title()} ({m.group(2).upper()})" if m else s.strip().title()


def _richiesto(g: dict, atts: list[dict], cfu_noti: dict) -> bool:
    """Gruppo «F» da sostenere per intero: un solo insegnamento, o insegnamenti che sommano esattamente i CFU dell'etichetta
    (non c'è niente da scegliere)."""
    if g.get("cod") != "F" or not atts:
        return False
    cfu = [float(t.get("crediti") or cfu_noti.get(t.get("adCod") or t.get("cod")) or 0) for t in atts]
    et = _cfu_etichetta(g.get("label_it"))
    if len({t.get("adCod") or t.get("cod") for t in atts}) == 1:
        return not et or et[1] >= cfu[0]
    return bool(et) and et[0] == et[1] and abs(sum(cfu) - et[1]) < 1e-9


def _regola_gia_elencata(g: dict, gruppi: list[dict]) -> bool:
    """La regola «S» (senza elenco) ha la stessa etichetta, o lo stesso intervallo «fra A e B CFU», di un gruppo «F»/«W» con
    attività che hanno CFU: è la stessa scelta scritta due volte («Attività a scelta dello studente (fra 1 e 6 CFU)»)."""
    et, cfu = _norm(g.get("label_it")), _cfu_etichetta(g.get("label_it"))
    return any(h is not g and h.get("attivita") and any(float(t.get("crediti") or 0) > 0 for t in h["attivita"])
               and (_norm(h.get("label_it")) == et
                    or (cfu and cfu[0] != cfu[1] and _cfu_etichetta(h.get("label_it")) == cfu))
               for h in gruppi)


def fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI}
    attuali = list(CORSI.items())[:max_cds] if max_cds else list(CORSI.items())
    log(f"[{uid}] {len(attuali)} corsi da leggere (coorti {anno - 6}-{anno})")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    corsi_out: list[dict] = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(voce: tuple[str, list[str]]) -> dict | None:
        id_ul, catena = voce
        sede_corso = SEDE_CORSO.get(id_ul, "roma")
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            for cod in catena:  # il primo codice della catena che in quella coorte ha il piano con gli anni
                x = coorti[y].get(cod)
                d = dettaglio(y, x) if x else None
                if d and any(str(a.get("anno")).isdigit() for p in d.get("percorsi") or [] for a in p.get("anni") or []):
                    d = dict(d)
                    d["percorsi_tutti"] = d.get("percorsi") or []  # (di tutte le sedi: per le attività «altreAttivita»)
                    d["percorsi"] = _percorsi_sede(d.get("percorsi") or [], sede_corso)
                    cohorts[y] = (x, d)
                    break
        if not cohorts:
            return None
        ultima = max(cohorts)
        cur = cohorts[ultima][0]
        durata = DURATA_TIPO.get(cur.get("tipo_corso_cod"), 3)
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cohorts[anno][0].get('cod')}")

        # nome canonico dei percorsi: quello della coorte più recente che li ha (confronto con le coorti già viste)
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple[str, str, set]] = []  # (chiave, nome canonico, codici delle attività)
        for y in sorted(cohorts, reverse=True):
            ps = cohorts[y][1].get("percorsi") or []
            visti = list(riferimento)
            nuovi: list = []
            in_attesa = []
            for p in ps:  # prima i percorsi che si ritrovano per nome
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                ch = _chiave_percorso(pn)
                trovato = next((r for r in visti if r[0] == ch), None)
                if trovato:
                    canon[(y, pn)] = trovato[1]
                else:
                    in_attesa.append((p, pn, ch))
            for p, pn, ch in in_attesa:  # poi gli altri: nome simile o insegnamenti in comune
                trovato = next((r for r in nuovi if r[0] == ch), None)  # copia dello stesso percorso nella stessa coorte
                if not trovato:
                    usati = {canon[(yy, q)] for (yy, q) in list(canon) if yy == y}
                    liberi = [r for r in visti if r[1] not in usati]
                    simili = [r for r in liberi if _simile(ch, r[0])]
                    if len(simili) == 1:
                        trovato = simili[0]
                    elif not simili:
                        mio = _adcod_percorso(p)
                        migliori = sorted(((len(mio & r[2]) / max(1, len(mio | r[2])), r) for r in liberi if r[2]),
                                          key=lambda t: -t[0])
                        if mio and migliori and migliori[0][0] >= 0.5 and (
                                len(migliori) == 1 or migliori[0][0] - migliori[1][0] >= 0.15):
                            trovato = migliori[0][1]
                if not trovato:
                    trovato = (ch, _nome_percorso(pn), _adcod_percorso(p))
                    nuovi.append(trovato)
                canon[(y, pn)] = trovato[1]
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            ha = {y: _cfu_anno(d, k, durata) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v > 0}
            if not ha:
                return None
            if y0 in ha:
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        # CFU di un'attività con 0 CFU in un piano e CFU nell'altro
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        insegnamenti: dict[tuple, dict] = {}
        percorsi_nomi: set[str] = set()
        coorti_anno: dict[int, int] = {}
        piano_anni: dict[str, dict] = {}

        def aggiungi(k, att, obbl, comune, pcur, curricula, scelta):
            ad = att.get("adCod") or att.get("cod")
            cfu = att.get("crediti") or cfu_noti.get(ad)
            key = (k, ad, bool(obbl))
            item = insegnamenti.get(key)
            if not item:
                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                item = {
                    "codice": ad, "nome": _nome_att(att.get("des_it") or ad), "anno": k,
                    "periodo": _periodo(att),
                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                    "cfu": cfu, "ssd": None, "obbligatorio": bool(obbl), "curriculum": None,
                    "_percorsi": set(), "_tutti": curricula, "docenti": sorted(set(docenti)),
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
                        "items": [], "codice": ad})["items"].append(item)
            else:
                item["_tutti"] = item["_tutti"] | curricula
                if not item["docenti"]:
                    item["docenti"] = sorted({cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")})
            if comune:
                item["_comune"] = True
            elif pcur:
                item["_percorsi"].add(pcur)
                percorsi_nomi.add(pcur)

        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            coorti_anno[k] = scelta
            x, d = cohorts[scelta]
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or [] if any(_vale(a, k, durata) for a in p.get("anni") or [])]
            nomi_k: dict[str, list[dict]] = {}
            for p in percorsi_k:  # i percorsi doppi con lo stesso nome sono due copie dello stesso piano
                nomi_k.setdefault((p.get("des_it") or p.get("pdsDes") or "").strip(), []).append(p)
            # più piani con gli anni: curricula (anche quello chiamato «comune»); un piano solo: vale per tutti
            curricula = {canon[(scelta, n)] for n in nomi_k} if len(nomi_k) >= 2 else set()
            for pnome, ps_ in nomi_k.items():
                comune = not curricula
                pcur = None if comune else canon[(scelta, pnome)]
                for p in ps_:
                    for a in p.get("anni") or []:
                        if not _vale(a, k, durata):
                            continue
                        gruppi = _gruppi(a)
                        for g in gruppi:
                            atts = [t for t in g.get("attivita") or [] if (t.get("crediti") or cfu_noti.get(t.get("adCod") or t.get("cod")))]
                            obbl = g.get("cod") == "OO"
                            if not g.get("attivita") or not atts:
                                # regola di scelta libera senza elenco (o con tutte le attività a 0 CFU): una voce a scelta con
                                # i CFU dell'etichetta, salvo che la stessa scelta sia già elencata in un altro gruppo
                                cfu_g = _cfu_etichetta(g.get("label_it"))
                                nome = _nome_regola(g.get("label_it") or "")
                                if g.get("cod") == "OO" or not cfu_g or len(nome) < 3 or _regola_gia_elencata(g, gruppi):
                                    continue
                                key = (k, "#" + _norm(nome), cfu_g[1])
                                item = insegnamenti.get(key)
                                if not item:
                                    item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu_g[1], "ssd": None,
                                            "obbligatorio": False, "curriculum": None, "_percorsi": set(), "_tutti": curricula,
                                            "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}", "libri": [], "esami": [],
                                            "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                                    insegnamenti[key] = item
                                if comune:
                                    item["_comune"] = True
                                elif pcur:
                                    item["_percorsi"].add(pcur)
                                    percorsi_nomi.add(pcur)
                                continue
                            richiesto = obbl or _richiesto(g, atts, cfu_noti)
                            for att in atts:
                                aggiungi(k, att, richiesto, comune, pcur, curricula, scelta)
            # attività «altreAttivita» (laboratori, cliniche, tirocini, insegnamenti di altri percorsi) della coorte, offerte
            # nell'a.a. di questo anno di corso (aa = coorte + k - 1) e non già nel piano: a scelta, nel loro anno
            for p in (d.get("percorsi") or []) if scelta == anno - k + 1 else []:  # (non per gli anni letti da un'altra coorte)
                nome_p = (p.get("des_it") or p.get("pdsDes") or "").strip()
                extra = [t for a in p.get("anni") or [] if not str(a.get("anno")).isdigit() for t in a.get("attivita") or []
                         if str(t.get("aa")).isdigit() and int(t["aa"]) == scelta + k - 1
                         and (t.get("tafDes_it") or "").strip().lower() not in TAF_DEL_PIANO]
                if not extra:
                    continue
                p_comune = bool(_COMUNE.search(nome_p)) or not curricula
                if p_comune and len(d["percorsi_tutti"]) != len(d["percorsi"]) and _COMUNE.search(nome_p):
                    continue  # corso con un piano per sede: la lista «comune» è di tutte le sedi, non si sa quali sono di questa
                if not p_comune and nome_p not in nomi_k:
                    continue
                # codici già nel piano della coorte (di qualunque percorso, in qualunque anno): sono insegnamenti del piano
                # offerti anche in questo anno o ad altri percorsi, non attività in più
                nel_piano = set()
                for q in d.get("percorsi_tutti") or []:
                    nel_piano |= _adcod_percorso(q)
                pc = None if p_comune else canon[(scelta, nome_p)]
                for att in extra:
                    ad = att.get("adCod") or att.get("cod")
                    if ad in nel_piano or not (att.get("crediti") or 0) > 0:
                        continue
                    obb = str(att.get("tipo_ins_cod") or "").startswith("OBB")
                    aggiungi(k, att, obb, pc is None, pc, curricula, scelta)
        ins = _rifinisci(list(insegnamenti.values()))
        out = {
            "id_universitaly": id_ul,
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or next(
                (d.get("classe_cod") for _, d in cohorts.values() if d.get("classe_cod")), None)),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(cur, cohorts),
            "codice_ateneo": catena[0],
            "url": f"{base}/corsi/{ultima}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        coorte_diversa = {k: y for k, y in coorti_anno.items() if y != anno - k + 1}
        if coorte_diversa:  # anni letti da un'altra coorte (piano della coorte più vicina)
            out["anni_da_altra_coorte"] = {str(k): y for k, y in sorted(coorte_diversa.items())}
        return out

    def build_safe(voce: tuple[str, list[str]]) -> dict | None:
        try:
            return build_cds(voce)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {voce[0]} saltato: {e!r}")
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
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, legati = cc._testi_syllabus(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cc.leganto.libri(u)
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/lumsa.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _rifinisci(items: list[dict]) -> list[dict]:
    """Curricula, alternative omonime e doppioni dello stesso insegnamento con due codici."""
    ins = items
    # stesso codice obbligatorio in un percorso e a scelta nello stesso percorso (l'elenco dell'esame a scelta libera comprende
    # gli insegnamenti del piano): la voce a scelta si tiene solo per i percorsi in cui non è obbligatorio
    per_cod: dict[tuple, list] = {}
    for i in ins:
        if i.get("codice"):
            per_cod.setdefault((i["anno"], i["codice"]), []).append(i)
    for righe in per_cod.values():
        obbl = [r for r in righe if r["obbligatorio"]]
        scelte = [r for r in righe if not r["obbligatorio"]]
        if not obbl or not scelte:
            continue

        def ambito(r):
            tutti = r["_tutti"] or {None}
            return set(tutti) if r.get("_comune") or not r["_percorsi"] else set(r["_percorsi"])
        coperti = set().union(*(ambito(r) for r in obbl))
        for r in scelte:
            resto = ambito(r) - coperti
            if not resto:
                ins.remove(r)
            elif resto != ambito(r):
                r["_percorsi"], r["_comune"] = set(resto) - {None}, False
    for i in ins:
        ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
        if i.pop("_comune", False):
            ps = set()
        if ps and ps != tutti:
            i["curriculum"] = ", ".join(sorted(ps))
    # voci senza codice (regole di scelta libera) con lo stesso nome in anni diversi: build_db le unirebbe per nome
    anni_nome: dict[str, set] = {}
    for i in ins:
        if i.pop("_senza_codice", False):
            anni_nome.setdefault(_nn(i["nome"]), set()).add(i["anno"])
            i["_nk"] = _nn(i["nome"])
    for i in ins:
        nk = i.pop("_nk", None)
        if nk and len(anni_nome[nk]) > 1:
            i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
    # stesso nome nello stesso anno e curriculum con codici e CFU diversi (alternative omonime): il nome porta i CFU
    per_nome: dict[tuple, list] = {}
    for i in ins:
        per_nome.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"] if i.get("codice") else None), []).append(i)
    for gruppo in per_nome.values():
        if len({i["cfu"] for i in gruppo}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo}) > 1:
            for i in gruppo:
                if isinstance(i["cfu"], (int, float)):
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
    # stesso nome, anno e curriculum, codici diversi
    per_nome2: dict[tuple, list] = {}
    for i in ins:
        if i.get("codice"):
            per_nome2.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
    for gruppo in per_nome2.values():
        if len({i["codice"] for i in gruppo}) < 2:
            continue
        per_cod: dict[str, list] = {}
        for i in gruppo:
            per_cod.setdefault(i["codice"], []).append(i)
        if len(per_cod) < 2:
            continue
        stessi_cfu = len({i["cfu"] for i in gruppo}) == 1
        docenti = [set(i["docenti"]) for i in gruppo]
        stesso_docente = all(not d for d in docenti) or (all(d for d in docenti) and all(d == docenti[0] for d in docenti))
        if stessi_cfu and stesso_docente and len({bool(i["obbligatorio"]) for i in gruppo}) == 1:
            # due codici per la stessa scheda (stesso nome, CFU e docenti): un insegnamento solo
            tieni = min(gruppo, key=lambda i: str(i["codice"]))
            for altro in gruppo:
                if altro is tieni:
                    continue
                tieni["docenti"] = sorted(set(tieni["docenti"]) | set(altro["docenti"]))
                tieni["periodo"] = tieni["periodo"] or altro["periodo"]
                ins.remove(altro)
            continue
        periodi = [i["periodo"] for i in gruppo]
        for i in gruppo:
            if all(periodi) and len(set(periodi)) == len(periodi):
                p = str(i["periodo"])
                i["nome"] = f"{i['nome']} ({p}° semestre)" if p in ("1", "2") else f"{i['nome']} ({p})"
            else:
                i["nome"] = f"{i['nome']} ({i['codice']})"
    return ins


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    p = ROOT / "database" / "corsi" / "lumsa.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("libri") and cod not in out:
                out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def fetch_ateneo(uid: str = "lumsa", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "lumsa.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[lumsa] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
