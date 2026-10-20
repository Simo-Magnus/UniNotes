"""Università degli Studi di Trieste: piani di studio per coorte dal Course Catalogue Cineca (`units.coursecatalogue.cineca.it`).

Parte dei piani di `adapters/units.py` (che resta responsabile di libri, syllabus e appelli). La logica dei gruppi è quella di
`unisa_piani`. Rispetto all'adattatore comune (`cineca_catalogue`) il catalogo di Trieste richiede:

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno),
  con tutti gli anni del corso. I codici dei corsi cambiano da una coorte all'altra («IN01» → «IN01A»): la coorte precedente si
  ritrova per codice (senza la «A»), per nome, sede e tipo, o per nome e tipo. Se la coorte non ha quell'anno nel suo piano si
  legge la più vicina che lo ha (a parità la più recente);
- durata dal piano («3 anni», «6 anni»): l'elenco minimale non ha `durataAnni`;
- gruppi del piano (`cod`): «OO» sono gli insegnamenti obbligatori; «F», «W» e «G» gruppi di scelta (con CFU nell'etichetta o
  senza: una scelta tra), «S» crediti liberi senza elenco («Esami a scelta secondo anno (4 CFU)»). Un'attività è obbligatoria se
  sta in «OO», se il gruppo la richiede per intero (CFU fissi dell'etichetta uguali alla somma delle attività) o se è l'unica del
  gruppo;
- gruppi senza attività elencate: voce a scelta con i CFU dell'etichetta (il massimo se «fra a e b CFU»);
- attività a 0 CFU (OFA, prove di verifica, laboratori senza crediti): non sono insegnamenti del piano;
- sezione «altreAttivita» (attività non legate a un anno): non fanno parte del piano di nessun anno;
- percorsi: «… comune» (campo `comune`) vale per tutti i curricula; un'attività presente in tutti i percorsi dell'anno non ha
  curriculum;
- libri: gli insegnamenti già nel database (per codice) non si rileggono; gli altri dal syllabus (testi liberi, mutuazioni,
  programma dell'a.a. precedente: vedi `units.py`).

Le richieste le fa il client di `units` (2 al secondo, cache su disco con UN_HTTP_CACHE).
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import pathlib
import re
import time
import unicodedata

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .units_testi import libri_units as libri_testo_libero  # noqa: E402

BASE = "https://units.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L2", "LM", "LM5", "LM6", "SP3"}  # lauree, magistrali, cicli unici e le scuole di specializzazione già nel database

# corsi che hanno cambiato nome (e codice) con il riordino: cdsCod di oggi → nome (senza punteggiatura) del corso che prosegue.
# Le coorti precedenti sono sul corso con il vecchio nome (stessa classe, stessa sede)
PREDECESSORI: dict[str, str] = {}

# Correzioni al catalogo dove il piano ufficiale dice altro: (cdsCod, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "cfu=<n>". Fonte nella nota di cfu_verificati/del report dell'agente.
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Insegnamenti del piano ufficiale che il catalogo della coorte non elenca: (cdsCod, anno di corso) → {codice: fonte}.
# L'attività è quella dello stesso codice nelle altre coorti del catalogo (nome, CFU, periodo, docenti, programma).
AGGIUNTE: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (cdsCod, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

_ETICHETTA_CFU = re.compile(r"(?:\(\s*)?(?:(?:fra|tra|between)\s+([\d.,]+)\s+(?:e|and)\s+)?(?<![\w.,-])([\d.,]*\d)\s*(?:CFU|ECTS|crediti)\b(?:\s*\))?", re.I)
_COMUNE = re.compile(r"(?i)\bcomune\b")
_LIBERA = re.compile(r"(?i)scelta\s+libera|libera\s+scelta|^\s*a\s+scelta\s*$")
_DEBITO = re.compile(r"(?i)\bdebito\b|obblig\w*\s+formativ|\bofa\b")
_FREQUENZA = re.compile(r"(?i)\(\s*(?:fr|frequency only|solo frequenza)\s*\)\s*$")
_ALTERNATIVA = re.compile(r"(?i)\bOPZ\s*\d|\boppure\b|\balternativ")  # «Tirocinio OPZ 1 (12 CFU)»: una delle due
_CONDIZIONATO = re.compile(r"(?i)\bper chi\b|\bse non\b|\bnon (?:l'ha|ha)\b|\bchi non\b|\boppure\b|\bscelta\b|\balternativ")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti: le parentesi restano («Tirocinio II (primo semestre)» ≠ «… (secondo semestre)»)."""
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
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _cod_base(cds: str | None) -> str:
    """Codice del corso senza la «A» del riordino («IN01A» e «IN01» sono lo stesso corso)."""
    return re.sub(r"(?<=\d)A$", "", (cds or "").strip())


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


_SIGLE = {"AI", "EF", "EMI", "EMPI", "EII", "IEGB", "CPF", "EPS", "ESI", "IT", "IOT", "UE", "EU", "LM", "II", "III"}


def _pulisci_percorso(nome: str) -> str:
    """Nome di un percorso senza la coorte («… - COORTE 2025», «[COORTE2022]», «IMMATRICOLATI 2024 -»), il prefisso del piano
    («PIANO DI STUDI -», «LM-59 -», «LM 56 CURR.») e le parole di servizio."""
    n = re.sub(r"\s+", " ", nome or "").strip()
    n = re.sub(r"(?i)\[\s*coorte\s*\d{4}\s*\]", " ", n)
    n = re.sub(r"(?i)\b(?:immatricolati|iscritti)\s+(?:nel\s+)?\d{4}(?:/\d{2,4})?\s*-?", " ", n)
    n = re.sub(r"(?i)\bcoorte\s*\d{4}(?:[/-]\d{2,4})?\s*-?", " ", n)
    n = re.sub(r"(?i)\bpiano di studi?o?\b(?:\s+\d+)?\s*-?", " ", n) if not re.search(r"(?i)^\s*(?:EPS|ESI)\b", n) else n
    n = re.sub(r"(?i)^\s*LM[ -]?\d+\s*curr\.?\s*", "", n)
    n = re.sub(r"(?i)^\s*LM[ -]?\d+\s*(?:\([^)]*\))?\s*-?\s*", "", n)
    n = re.sub(r"(?i)^\s*(?:curriculum|percorso)\s+(?:in\s+)?", "", n)
    n = re.sub(r"(?i)\bcurriculum\s+in\b", " ", n)
    n = re.sub(r"Inegneria", "Ingegneria", n)  # refuso del catalogo
    n = re.sub(r"\bRISKFOR\b", "RISK FOR", n)
    n = re.sub(r"\s+", " ", n).strip(" -:,")
    return n or "Piano standard"


def _chiave_percorso(nome: str) -> str:
    n = _pulisci_percorso(nome)
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo)\b", " ", n)
    return _norm(n)


def _nome_percorso(nome: str) -> str:
    n = _pulisci_percorso(nome).replace("_", " ")
    n = re.sub(r"\s*,\s*", " - ", n)  # una virgola nel nome farebbe leggere due percorsi (pulizia.percorsi)
    if n.isupper() or n.islower():
        n = " ".join(w if w in _SIGLE or re.fullmatch(r"\([A-Z]{2,5}\)", w) else w.lower() for w in n.split())
        n = n[:1].upper() + n[1:]
    return n[:1].upper() + n[1:]


_MARCA_COORTE = re.compile(r"(?i)\[\s*coorte\s*(\d{4})\s*\]")


def _coorti_marcate(det: dict, y: int) -> dict[int, dict]:
    """Piani per coorte di un elenco: il catalogo 2025 di Giurisprudenza ha i piani delle coorti 2021-2024 come percorsi
    «[COORTE2022] SCHEMA STANDARD» (con i codici attuali) accanto a quello della coorte 2025 senza marca. Restituisce
    {coorte: piano con i soli percorsi di quella coorte}; vuoto se il catalogo non ha percorsi marcati."""
    ps = det.get("percorsi") or []
    marcati: dict[int, list[dict]] = {}
    for p in ps:
        m = _MARCA_COORTE.search(p.get("des_it") or "")
        if m:
            marcati.setdefault(int(m.group(1)), []).append(p)
    if not marcati:
        return {}
    out = {c_: {**det, "percorsi": v} for c_, v in marcati.items()}
    senza = [p for p in ps if not _MARCA_COORTE.search(p.get("des_it") or "")]
    if senza:
        out.setdefault(y, {**det, "percorsi": senza})
    return out


_ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}


def _percorsi_anno(percorsi: list[dict], k: int) -> list[dict]:
    """«SCHEMA DI PIANO ISCRITTI AL IV° ANNO NEL 2026/27», «… ISCRITTI V ANNO»: un piano per anno di corso, tutti con gli stessi
    anni; per l'anno k si legge quello degli iscritti al k-esimo anno."""
    per_anno = []
    for p in percorsi:
        m = re.search(r"(?i)iscritti\s+(?:al\s+)?(VI|V|IV|III|II|I)\s*°?\s*anno", p.get("des_it") or "")
        if m:
            per_anno.append((_ROMANI[m.group(1).upper()], p))
    scelti = [p for r, p in per_anno if r == k]
    return scelti or percorsi


_SOVRANNUMERARI = re.compile(r"(?i)sovrannumerar|soprannumerar|extra\s*curricular")


def _gruppi_di_anno(a: dict) -> list[dict]:
    """Gruppi del piano di un anno, senza gli esami sovrannumerari (crediti in più, fuori dai 60 CFU dell'anno)."""
    gruppi = a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])
    gruppi = [g for g in gruppi if not _SOVRANNUMERARI.search(g.get("label_it") or "")]
    # «Esami a scelta libera studente CdS LE01 (fra 6 e 18 CFU)» con l'elenco e «Esami a scelta libera studente (fra 6 e 18 CFU)»
    # senza attività: sono gli stessi crediti liberi, il segnaposto non si conta due volte
    def intervallo(g):
        return _cfu_etichetta(g.get("label_it")) if re.search(r"(?i)scelt", g.get("label_it") or "") else None
    con_elenco = {intervallo(g) for g in gruppi if g.get("attivita") and intervallo(g)}
    return [g for g in gruppi if g.get("attivita") or intervallo(g) not in con_elenco]


def _obbligatorio(g: dict, att: dict, atts: list[dict]) -> bool:
    """Un'attività del piano è obbligatoria se sta nel gruppo «OO», se il gruppo la richiede per intero, se il gruppo è di
    insegnamenti obbligatori e l'attività ha il tipo «OBB», o se è l'unica del gruppo (senza una scelta nell'etichetta)."""
    label = (g.get("label_it") or "")
    if g.get("cod") == "OO":
        return True
    if g.get("cod") == "W":  # crediti a scelta libera: l'elenco offre anche insegnamenti obbligatori di altri corsi
        return False
    cfu = _cfu_etichetta(label)
    tot = sum(float(a.get("crediti") or 0) for a in atts)
    if cfu and cfu[0] == cfu[1] and tot > 0 and abs(tot - cfu[0]) < 1e-6 and not _ALTERNATIVA.search(label):
        return True
    if re.search(r"(?i)obbligator", label) and att.get("tipo_ins_cod") == "OBB" and not re.search(r"(?i)\bper chi\b", label):
        return True
    # «Indirizzo biomedico», «Ind. Strutture sanitarie» senza una scelta nell'etichetta: gli insegnamenti dell'indirizzo
    # sono tutti dell'indirizzo (le scelte si chiamano «Indirizzo A - Prima scelta», «… un esame a scelta vincolata tra»)
    if _indirizzo(label) and not re.search(r"(?i)scelt|\btra\b|opzion|alternativ|\boppure\b", label):
        return True
    # gruppo a CFU fissi con attività obbligatorie e scelte («Tirocinio + Prova finale (20 CFU)»: prova finale obbligatoria,
    # tirocinio di 7 o 8 CFU a scelta): le obbligatorie, se stanno nei CFU del gruppo, lo sono
    if cfu and cfu[0] == cfu[1] and att.get("tipo_ins_cod") == "OBB" and len(atts) > 1:
        obb = [a for a in atts if a.get("tipo_ins_cod") == "OBB"]
        if len(obb) < len(atts) and sum(float(a.get("crediti") or 0) for a in obb) <= cfu[0] + 1e-6:
            return True
    return len(atts) == 1 and att.get("tipo_ins_cod") == "OBB" and not _CONDIZIONATO.search(label)


_NUMERI = {"un": 1, "uno": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, **{str(n): n for n in range(1, 10)}}


def _molteplicita(label: str | None) -> int:
    """Quante scelte chiede un gruppo senza CFU nell'etichetta: «Due esami opzionali tra:», «OPZIONALI 3 SU 4», «2 insegnamenti
    opzionali tra» → 2, 3, 2; «Un esame opzionale tra» → 1."""
    lab = label or ""
    m = re.search(r"(?i)\b([1-9])\s*(?:su|of)\s*[1-9]\b", lab)
    if m:
        return int(m.group(1))
    m = re.search(r"(?i)\b(due|tre|quattro|cinque|un|uno|una|[1-9])\s+(?:scelt\w+|esam\w+|insegnament\w+|corsi|attivit\w+|"
                  r"lingu\w+|laborator\w+|opzional\w+)", lab)
    return _NUMERI.get(m.group(1).lower(), 1) if m else 1


_INDIRIZZO = re.compile(r"(?i)^\s*(?:indirizzo|ind\.)\s+([^:\-–(]+?)\s*(?:[-–:(]|$)")


def _indirizzo(label: str | None) -> str | None:
    """Indirizzo di un gruppo del piano: «Indirizzo A - Prima scelta (12 CFU)» → «Indirizzo A»,
    «Ind. Biomedico» → «Indirizzo Biomedico». Gli indirizzi alternativi stanno nello stesso percorso del catalogo."""
    m = _INDIRIZZO.match(label or "")
    if not m:
        return None
    nome = re.sub(r"\s+", " ", m.group(1)).strip()
    if not nome:
        return None
    return "Indirizzo " + (nome.upper() if len(nome) <= 2 else _titolo_etichetta(nome))


def _indirizzi_anno(a: dict) -> dict[str, str]:
    """Indirizzi di un anno del piano ({chiave: nome}); contano solo se sono almeno due (alternativi)."""
    ind = {}
    for g in _gruppi_di_anno(a):
        n = _indirizzo(g.get("label_it"))
        if n:
            ind[_norm(n)] = n
    return ind if len(ind) >= 2 else {}


def _cfu_sorella(g: dict, gruppi: list[dict]):
    """CFU dell'etichetta di un altro gruppo dell'anno con le stesse attività («Indirizzo B - Prima scelta» senza CFU,
    «Indirizzo A - Prima scelta (12 CFU)» con le stesse attività): sono i CFU della scelta."""
    ads = {x.get("adCod") or x.get("cod") for x in g.get("attivita") or []}
    if not ads:
        return None
    for h in gruppi:
        if h is g or {x.get("adCod") or x.get("cod") for x in h.get("attivita") or []} != ads:
            continue
        cfu = _cfu_etichetta(h.get("label_it"))
        if cfu and cfu[0] == cfu[1]:
            return cfu
    return None


def _sommario_anno(det: dict, k: int) -> dict:
    """CFU «dichiarati» dall'anno k di un piano, percorso per percorso (e indirizzo per indirizzo):
    {percorso: {"obb": CFU obbligatori, "fissi": CFU di gruppi a scelta con CFU fissi o con una sola scelta,
                "intervalli": [(min, max)] dei gruppi con intervallo}}."""
    out = {}
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                continue
            indirizzi = _indirizzi_anno(a)
            gruppi = _gruppi_di_anno(a)
            parti: dict[str | None, dict] = {}
            visti: dict[str | None, set] = {}
            for g in gruppi:
                ind = _indirizzo(g.get("label_it")) if indirizzi else None
                q = parti.setdefault(ind, {"obb": 0.0, "fissi": 0.0, "intervalli": [], "etichette": [], "alt": []})
                visti_q = visti.setdefault(ind, set())
                atts = [x for x in g.get("attivita") or [] if not _e_frequenza(x)]
                cfu_g = _cfu_etichetta(g.get("label_it")) or _cfu_sorella(g, gruppi)
                oblig = [x for x in atts if _obbligatorio(g, x, atts)]
                for x in oblig:
                    ad = x.get("adCod") or x.get("cod")
                    if ad not in visti_q:
                        visti_q.add(ad)
                        q["obb"] += float(x.get("crediti") or 0)
                if len(oblig) == len(atts) and atts:
                    continue
                if cfu_g and cfu_g[0] == cfu_g[1] and _ALTERNATIVA.search(g.get("label_it") or ""):
                    q["alt"].append(cfu_g[0])  # «Tirocinio OPZ 1 (12 CFU)» / «OPZ 2»: una delle opzioni
                elif cfu_g and cfu_g[0] == cfu_g[1]:
                    q["fissi"] += cfu_g[0] - (0 if not oblig else sum(float(x.get("crediti") or 0) for x in oblig))
                elif cfu_g:
                    q["intervalli"].append(cfu_g)
                    q["etichette"].append(re.sub(r"\s+", " ", g.get("label_it") or ""))
                elif atts and _LIBERA.search(g.get("label_it") or "") and _molteplicita(g.get("label_it")) == 1:
                    q["incerti"] = q.get("incerti", 0) + 1  # crediti liberi senza i CFU nell'etichetta: quanti non lo dice la fonte
                elif atts:
                    cf = {float(x.get("crediti") or 0) for x in atts if x.get("crediti")}
                    if cf:
                        q["fissi"] += max(cf) * min(_molteplicita(g.get("label_it")), len(atts))
            comune = parti.pop(None, {"obb": 0.0, "fissi": 0.0, "intervalli": [], "etichette": [], "alt": []})
            nome_p = p.get("des_it") or p.get("pdsDes") or ""
            for ind, q in (parti or {None: comune}).items():
                if ind is not None:
                    q = {"obb": q["obb"] + comune["obb"], "fissi": q["fissi"] + comune["fissi"],
                         "intervalli": q["intervalli"] + comune["intervalli"], "etichette": q["etichette"] + comune["etichette"],
                         "alt": q["alt"] + comune["alt"]}
                fissi = q["fissi"] + max(q["alt"], default=0.0)
                out[f"{nome_p} / {ind}" if ind else nome_p] = {"obb": q["obb"], "fissi": fissi, "intervalli": q["intervalli"],
                                                                "etichette": q["etichette"], "incerti": q.get("incerti", 0)}
    return out


def _cfu_anno(det: dict, k: int) -> float:
    """CFU dichiarati dall'anno k (percorso più ricco: obbligatori e scelte con CFU fissi, più il minimo degli intervalli)."""
    s = _sommario_anno(det, k)
    if not s:
        return -1.0
    return max(v["obb"] + v["fissi"] + sum(lo for lo, _ in v["intervalli"]) for v in s.values())


def fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client, libri_noti=None,
                testi_syllabus=None, libri_extra=None, testo_libero=None) -> dict:
    """Contributo (formato di database/contrib) con i piani per coorte. `libri_noti`: libri già nel database per codice;
    `testi_syllabus(sy)`: libri, modalità e link Leganto del syllabus; `libri_extra(sy)`: libri dal syllabus con le regole
    proprie dell'ateneo (testi liberi, mutuazioni, programma dell'a.a. precedente); `testo_libero(sy)`: solo i testi liberi."""
    base = BASE
    c = client
    libri_noti = libri_noti or {}
    testi_syllabus = testi_syllabus or cc._testi_syllabus
    testo_libero = testo_libero or libri_testo_libero
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    elenco_attuale = []
    for x in coorti[anno]:  # l'elenco ripete alcuni corsi
        if x["cod"] in {e["cod"] for e in elenco_attuale}:
            continue
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
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur` (stesso codice, o stesso nome, sede e tipo)."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        for x in elenco:  # riordino: «IN01» → «IN01A»
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]):
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        if len(stessi) == 1:
            return stessi[0]
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("tipo_corso_cod")) == chiave[::2]]
        if len(stessi) == 1:
            return stessi[0]
        prec = PREDECESSORI.get(cur["cdsCod"])
        if prec:
            stessi = [x for x in elenco if _norm(x.get("des_it")) == prec and x.get("tipo_corso_cod") == cur.get("tipo_corso_cod")]
            if len(stessi) > 1:
                stessi = [x for x in stessi if x.get("sede_cod") == cur.get("sede_cod")] or stessi
            if len(stessi) == 1:
                return stessi[0]
        return None

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    # CFU di un insegnamento offerto a scelta libera senza crediti nel piano di un corso (gruppi «fra a e b CFU»): quelli che ha
    # nel suo corso, nel catalogo di un altro anno o di un altro corso (la coorte più recente vale)
    cfu_globali: dict[str, float] = {}
    for y in sorted(coorti):
        for x in coorti[y]:
            d_ = dettaglio(y, x)
            for p in (d_ or {}).get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_globali[att.get("adCod") or att.get("cod")] = att["crediti"]

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        # piani di più coorti nello stesso elenco («[COORTE2022] SCHEMA STANDARD»): ognuno diventa la sua coorte
        marcate: dict[int, tuple[dict, dict]] = {}
        for y, (x, d) in list(cohorts.items()):
            for yc, dc in _coorti_marcate(d, y).items():
                marcate[yc] = ({**x, "_aa": y}, dc)
        cohorts.update(marcate)
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
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
                nome_c = trovato[2]
                if _COMUNE.search(nome_c) and not _COMUNE.search(pn):  # stesso codice del percorso «comune» di un'altra coorte
                    nome_c = _nome_percorso(pn)
                canon[(y, pn)] = nome_c
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((cur.get("cdsCod"), k))
            if forzata in cohorts:
                return forzata
            ha = {y: _cfu_anno({**d, "percorsi": _percorsi_anno(d.get("percorsi") or [], k)}, k) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v > 0}
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
            d = {**d, "percorsi": _percorsi_anno(d.get("percorsi") or [], k)}
            sommario = _sommario_anno(d, k)
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{x.get('_aa', scelta)}/{x['cod']}",
                                  "sommario": sommario}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(str(a.get("anno")).isdigit() and int(a["anno"]) == k for a in p.get("anni") or [])]
            nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi_k}
            anni_p = {n: max(int(a["anno"]) for a in p.get("anni") or [] if str(a.get("anno")).isdigit())
                      for n, p in nomi_k.items()}
            # percorsi comuni: «… comune» o un piano che copre solo i primi anni quando gli altri percorsi li coprono tutti
            comuni = {n for n in nomi_k if _COMUNE.search(n) or nomi_k[n].get("comune") in (True, "True") or (len(nomi_k) > 1 and anni_p[n] < max(anni_p.values()))}
            specifici = [n for n in nomi_k if n not in comuni]
            curricula = {canon[(scelta, n)] for n in specifici} if len(specifici) >= 2 else set()
            for pnome, p in nomi_k.items():
                comune = pnome in comuni or not curricula
                pcur = None if comune else canon[(scelta, pnome)]
                for a in p.get("anni") or []:
                    if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                        continue
                    ind_k = _indirizzi_anno(a)  # indirizzi alternativi nello stesso percorso: curricula del solo gruppo
                    tutti = curricula | set(ind_k.values())
                    for g in _gruppi_di_anno(a):
                        atts = [t for t in g.get("attivita") or [] if not _e_frequenza(t)]
                        label = g.get("label_it") or ""
                        gind = _indirizzo(label) if ind_k else None
                        comune_g = comune and not gind
                        pcur_g = gind or pcur
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
                                        "_tutti": tutti, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                        "libri": [], "esami": [], "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                                insegnamenti[key] = item
                            if comune_g:
                                item["_comune"] = True
                            elif pcur_g:
                                item["_percorsi"].add(pcur_g)
                                percorsi_nomi.add(pcur_g)
                            continue
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            if _DEBITO.search(att.get("des_it") or "") and not att.get("crediti"):
                                nome_d = re.sub(r"(?i)^\s*debito\s+", "", cc._titolo(att["des_it"])).strip()
                                debiti.append(nome_d)
                                continue
                            obbl = _obbligatorio(g, att, atts)
                            key = f"{k}:{ad}:{'o' if obbl else 's'}"  # obbligatoria in un percorso e a scelta in un altro: due righe
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": att.get("crediti") or cfu_noti.get(ad) or cfu_globali.get(ad) or att.get("crediti"),
                                    "ssd": None,
                                    "obbligatorio": bool(obbl), "curriculum": None, "_percorsi": set(), "_tutti": tutti,
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
                                        "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                                            alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                                            if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                                    })["items"].append(item)
                            if comune_g:
                                item["_comune"] = True
                            elif pcur_g:
                                item["_percorsi"].add(pcur_g)
                                percorsi_nomi.add(pcur_g)
        for (cds_c, anno_c), voci in AGGIUNTE.items():
            if cds_c != cur.get("cdsCod") or anno_c > durata:
                continue
            for ad, fonte_ad in voci.items():
                key = f"{anno_c}:{ad}"
                origini = alt_per_ad.get(ad) or {}
                if key in insegnamenti or not origini:
                    continue
                y_o, att = max(origini.values(), key=lambda t: t[0])
                if not att.get("crediti"):
                    continue
                item = {
                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": anno_c,
                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                    "cfu": att["crediti"], "ssd": None, "obbligatorio": True, "curriculum": None,
                    "_percorsi": set(), "_tutti": set(),
                    "docenti": sorted({cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")}),
                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y_o}",
                    "libri": [], "esami": [], "fonte": fonte_ad, "verificato_il": oggi,
                }
                insegnamenti[key] = item
                if syllabus:
                    syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                   "af_percorso": att.get("corso_percorso_id"),
                                   "corso_cod": att.get("corso_cod"), "corso_aa": y_o,
                                   "schema_id": att.get("schemaId")},
                        "items": [], "codice": ad, "alt": [],
                    })["items"].append(item)
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
        # stessa attività obbligatoria in un percorso e a scelta in un altro dello stesso anno: due righe se i percorsi sono
        # disgiunti (build_db le tiene distinte), altrimenti una sola obbligatoria
        per_ad: dict[tuple, dict[str, dict]] = {}
        for key, item in list(insegnamenti.items()):
            if item.get("codice") and not item.get("_senza_codice"):
                per_ad.setdefault((item["anno"], item["codice"]), {})["o" if item["obbligatorio"] else "s"] = item
        for coppia in per_ad.values():
            if len(coppia) < 2:
                continue
            o, s = coppia["o"], coppia["s"]
            po = set() if o.get("_comune") else set(o["_percorsi"])
            ps_ = set() if s.get("_comune") else set(s["_percorsi"])
            if po and ps_ and not (po & ps_):
                continue
            o["_percorsi"] |= s["_percorsi"]
            o["_comune"] = o.get("_comune") or s.get("_comune") or not (po and ps_)
            o["docenti"] = sorted(set(o["docenti"]) | set(s["docenti"]))
            o["periodo"] = o["periodo"] or s["periodo"]
            for key_, item in list(insegnamenti.items()):
                if item is s:
                    del insegnamenti[key_]
        ins = list(insegnamenti.values())
        usati: set[str] = set()  # i percorsi che distinguono davvero qualche insegnamento
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
                usati |= ps
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
        out = {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(usati) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
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
        libri, modalita, legati = testi_syllabus(sy) if sy else ([], None, [])
        if not libri and sy:  # testi in forma libera
            libri = (libri_extra or testo_libero)(sy)
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
                l2, m2, g2 = testi_syllabus(sy2)
                l2 = l2 or testo_libero(sy2)
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/units_piani.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
