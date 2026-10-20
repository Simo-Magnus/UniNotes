"""Università degli Studi di Bergamo: piani di studio per coorte dal Course Catalogue Cineca.

`https://unibg.coursecatalogue.cineca.it` (API pubblica, coorti 2021-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) questo modulo:

- legge, per l'anno di corso k nell'a.a. A, il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno). Il codice del corso
  cambia con il riordino («86-270» → «86-R», «19-270-DIN» → «19-R-DIN», «64-270-ENG» → «64-R-ENG»): la coorte precedente si
  ritrova per codice senza «270» e «R», per nome, sede e tipo, o per nome e tipo. Se la coorte non ha quell'anno (o ne ha uno
  molto sotto i 30 CFU dichiarati, come l'anno 3 di Scienze politiche nelle coorti 2022-2024) si usa la più vicina che lo ha;
- durata dal piano («3 anni», «6 anni»);
- gruppi del piano (`cod`): «OO» obbligatori; «F» e «W» scelte («Scelta di un insegnamento tra…», «A scelta dello studente
  (tot. 12 cfu)», «Lingue europee - 18 CFU»); «NO» non obbligatori. Un'attività è obbligatoria se sta in «OO», se il gruppo la
  richiede per intero (CFU fissi dell'etichetta uguali alla somma delle attività) o se è l'unica del gruppo senza una scelta
  nell'etichetta;
- gruppi senza attività elencate: voce a scelta con i CFU dell'etichetta o, se manca, dalle note del gruppo;
- attività a 0 CFU (OFA, test, prove) non sono insegnamenti del piano;
- lingua dell'attività (`lingua`: «it»/«en», da `lingua_cod`) e gruppi di scelta in cui è a scelta (`gruppo_scelta`): con questi
  `pulizia.varianti_lingua_scelta` unisce la versione italiana e quella inglese dello stesso esame offerte nello stesso gruppo
  («Scelta di un insegnamento tra»: «Economia del lavoro» / «Labour Economics»);
- percorsi: il flag `comune` del catalogo non è affidabile (i quattro curricula di Diritto per l'impresa lo hanno tutti): un percorso
  vale per tutti i curricula se «comune» è nel nome o se copre meno anni degli altri; lo stesso percorso nelle coorti si riconosce
  per nome, per codice senza anno e «R», o per gli insegnamenti in comune (almeno il 40%);
- `altre`: per ogni corso, le attività di tutte le coorti con anno e CFU (servono ad abbinare le attività che compaiono solo nella
  bacheca degli appelli).

Con la variabile d'ambiente UN_HTTP_CACHE le risposte restano su disco. I libri già raccolti nel database (`libri_noti`) non si rileggono.
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

BASE = "https://unibg.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici di 5 e 6 anni

ID_UNIVERSITALY: dict[str, str] = {}

# Correzioni al catalogo dove il piano ufficiale dice altro: (cdsCod, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "cfu=<n>". Fonte nella nota di cfu_verificati/del report dell'agente.
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (cdsCod, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

SOGLIA_ANNO = 30  # CFU dichiarati sotto i quali l'anno di una coorte non si considera un piano

_ETICHETTA_CFU = re.compile(r"(?:\(\s*)?(?:(?:fra|tra)\s+([\d.,]+)\s+e\s+)?(?<![\w.,])([\d.,]*\d)\s*(?:CFU|crediti)\b(?:\s*\))?", re.I)
_NOTA_CFU = re.compile(r"(?i)(?<!max )(?<!massimo )(?<!fino a )(?<!\d)(?:CFU\s+(\d+)\b|\b(\d+)\s*(?:CFU|crediti))")
_MINMAX = re.compile(r"(?i)\bmin\.?\s*([\d.,]*\d)\s*(?:CFU|crediti)\s*[-–]?\s*max\.?\s*([\d.,]*\d)\s*(?:CFU|crediti)")
_COMUNE = re.compile(r"(?i)\bcomune\b")
_SCELTA = re.compile(r"(?i)scelt|opzional|alternativ|elective|optional|oppure|\btra\b|\bor\b|among|betwee?n|beetween|\bone\b")
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
    return {"L": 3, "LM": 2, "LM5": 5, "FI": 1}.get(tipo or "", 3)


def _cod_base(cds: str | None) -> str:
    """Il codice del corso cambia con il riordino («86-270» → «86-R», «19-270-DIN» → «19-R-DIN», «96-270R»): senza «270» e «R»
    è lo stesso corso («86», «19-DIN», «96»); «37-270» e «37-270-EN» restano distinti («37», «37-EN»)."""
    c = (cds or "").strip().upper()
    c = re.sub(r"(?<=\d)R(?=$|-)", "", c)
    c = re.sub(r"-R(?=$|-)", "", c)
    c = re.sub(r"-270(?=$|-)", "", c)
    return c


def _titolo_etichetta(s: str) -> str:
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        return s[:1].upper() + s[1:]
    return s[:1].upper() + s[1:].lower()


def _cfu_etichetta(label: str):
    """(minimo, massimo) dei CFU nell'etichetta di un gruppo: «(12 CFU)» → (12, 12), «(fra 6 e 18 CFU)» → (6, 18)."""
    mm = _MINMAX.search(label or "")
    if mm:
        return _numero(mm.group(1)), _numero(mm.group(2))
    m = _ETICHETTA_CFU.search(label or "")
    if not m:
        return None
    try:
        hi = _numero(m.group(2).strip(".,"))
        lo = _numero(m.group(1).strip(".,")) if m.group(1) else hi
    except ValueError:
        return None
    return lo, hi


def _cfu_gruppo(g: dict):
    """CFU di un gruppo senza attività elencate: dall'etichetta («12 CFU a scelta libera», «(6CFU)») o, se manca, dalle
    note del gruppo («deve acquisire 3 CFU», «almeno 9 CFU», «ha a disposizione 8 crediti»)."""
    c = _cfu_etichetta(g.get("label_it"))
    if c:
        return c
    for n in (g.get("nota1_it"), g.get("nota2_it")):
        m = _NOTA_CFU.search(n or "")
        if m:
            v = int(m.group(1) or m.group(2))
            if 0 < v <= 30:
                return v, v
    return None


_MINMAX_NOTA = re.compile(r"(?i)(?:^|[\s(])min\.?\s*(\d+(?:[.,]\d+)?)\s*[-–]\s*max\.?\s*(\d+(?:[.,]\d+)?)")
_NUMERO_CFU = re.compile(r"(?i)(?<![\w.,])(\d+(?:[.,]\d+)?)\s*(?:cfu|crediti)\b")


def _cfu_nota(g: dict):
    """(minimo, massimo) dei CFU del gruppo dalle note («(Min 8 - Max 8)», «Min 12 - Max 18», «AD a scelta da 12,0 cfu»): solo se la
    nota dice un intervallo o un solo valore."""
    note = " ".join(g.get(k) or "" for k in ("nota1_it", "nota2_it"))
    m = _MINMAX_NOTA.search(note)
    if m:
        try:
            return _numero(m.group(1)), _numero(m.group(2))
        except ValueError:
            return None
    valori = {_numero(x) for x in _NUMERO_CFU.findall(note)}
    return (min(valori), min(valori)) if len(valori) == 1 and 0 < min(valori) <= 30 else None


def _cfu_g(g: dict):
    """CFU richiesti dal gruppo: l'etichetta o, se manca, le note."""
    return _cfu_etichetta(g.get("label_it")) or _cfu_nota(g)


def _nome_gruppo(label: str) -> str:
    """Nome della voce a scelta di un gruppo senza attività: l'etichetta con l'intervallo dei CFU se non è fisso."""
    lab = re.sub(r"\s+", " ", label or "").strip()
    cfu = _cfu_etichetta(lab)
    if cfu and cfu[0] == cfu[1]:
        lab = _ETICHETTA_CFU.sub(" ", lab)
    lab = re.sub(r"^\s*\d+°?\s*anno\s*[-–:]?\s*", "", lab, flags=re.I)
    lab = re.sub(r"^\s*\d+°\s*[-–:]?\s*", "", lab)
    lab = re.sub(r"^\s*\d+\s*[-–.)]\s*", "", lab)  # «3- a scelta libera»
    lab = re.sub(r"(?i)^\s*(?:i{1,3}|iv|v)\s+anno\s*(?:[a-z]{2,4}\s*)?:\s*", "", lab)  # «III anno ESI: a scelta dello studente»
    lab = re.sub(r"(?i)\s*,?\s*tipo regola\b.*$", "", lab)  # suffisso tecnico del catalogo
    lab = re.sub(r"\s+", " ", lab).strip(" -–:/,")
    return _titolo_etichetta(lab)


def _e_frequenza(att: dict) -> bool:
    return not att.get("crediti") and bool(_FREQUENZA.search((att.get("des_it") or "").strip()))


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", " ", nome)
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo|piano)\b", " ", n)
    return _norm(n)


def _nome_percorso(nome: str) -> str:
    n = re.sub(r"(?i)[\s,-]*\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", "", nome)
    m = re.match(r"(?i)\s*schema automatico per il pds\s*:\s*(\S+?)(?:/\d{2,4})?\s*$", n)
    if m:  # percorsi senza nome nelle coorti vecchie: resta il codice («L19-AG»)
        n = m.group(1)
    n = re.sub(r"\s*,\s*", " - ", n)  # una virgola nel nome lo farebbe leggere come due percorsi (pulizia.percorsi)
    n = re.sub(r"\s+", " ", n).strip(" -:,")
    m = re.match(r"(?i)percorso da (\d+) cfu\s*-\s*allegato (\d+)$", n)
    if m:  # percorsi FI: «PERCORSO DA 30 CFU - ALLEGATO 4», «Percorso da 30 cfu - allegato 4»
        return f"Percorso da {m.group(1)} CFU - Allegato {m.group(2)}"
    if n.isupper() and len(n) > 6:
        n = " ".join(w if re.search(r"\d", w) else w.lower() for w in n.split())
        n = n[:1].upper() + n[1:]
    return n


def _stem_percorso(cod: str | None) -> str:
    """Codice del percorso senza l'anno e la «R» del riordino: «L28-BF/24», «L28-BF/26» → «L28-BF»; «L11-24-ESI», «L11R-26ESI» → «L11-ESI»."""
    c = re.sub(r"(?<=\d)R(?=-)", "", (cod or "").strip())
    c = re.sub(r"[-_/]?(?<!\d)2[0-7](?!\d)", "-", c)
    return re.sub(r"-+", "-", c).strip("-_/")


def _adcod_percorso(p: dict) -> set:
    return {t.get("adCod") for a in p.get("anni") or [] if str(a.get("anno")).isdigit()
            for g in a.get("insegnamenti") or [] for t in g.get("attivita") or [] if t.get("adCod")}


def _gruppi_di_anno(a: dict) -> list[dict]:
    gruppi = a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])
    # la regola «S» (scelta libera, senza elenco) con gli stessi CFU di un gruppo «W»/«F» con l'elenco delle attività offerte
    # è la stessa scelta scritta due volte («Elective courses (15 CFU)»): una volta sola
    con_elenco = {_cfu_etichetta(g.get("label_it")) for g in gruppi if g.get("attivita") and _cfu_etichetta(g.get("label_it"))}
    return [g for g in gruppi if g.get("attivita") or _cfu_gruppo(g) not in con_elenco]


def _obbligatorio(g: dict, att: dict, atts: list[dict]) -> bool:
    """Un'attività del piano è obbligatoria se sta nel gruppo «OO», se il gruppo la richiede per intero, se il gruppo è di
    insegnamenti obbligatori e l'attività ha il tipo «OBB», o se è l'unica del gruppo (senza una scelta nell'etichetta)."""
    label = (g.get("label_it") or "")
    if g.get("cod") == "OO":
        return True
    if g.get("cod") == "W":  # scelta libera dello studente: l'elenco è solo una proposta
        return False
    cfu = _cfu_g(g)
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
    if len(atts) == 1 and not _SCELTA.search(label) and not _CONDIZIONATO.search(label):
        return True  # unica attività del gruppo e nessuna scelta nell'etichetta (UniMC non valorizza il tipo «OBB»)
    return len(atts) == 1 and att.get("tipo_ins_cod") == "OBB" and not _CONDIZIONATO.search(label)


_NUMERI = {"due": 2, "tre": 3, "quattro": 4, "cinque": 5, "2": 2, "3": 3, "4": 4, "5": 5}


def _molteplicita(label: str | None) -> int:
    """Quante scelte chiede un gruppo senza CFU nell'etichetta: «Due scelte tra», «Tre insegnamenti a scelta» → 2, 3."""
    m = re.search(r"(?i)\b(due|tre|quattro|cinque|[2-5])\s+(?:scelt\w+|esam\w+|insegname\w+|corsi|attivit\w+|lingue|discipline|materie)", label or "")
    return _NUMERI.get(m.group(1).lower(), 1) if m else 1


def _vale(a: dict, k: int, durata: int | None) -> bool:
    """L'anno `a` del piano vale per l'anno di corso k; le attività senza anno (anno 0: scelte libere, altre attività) si
    collocano nell'ultimo anno, come le «altreAttivita» del catalogo comune."""
    if not str(a.get("anno")).isdigit():
        return False
    n = int(a["anno"])
    return n == k or (n == 0 and durata is not None and k == durata)


def _sommario_anno(det: dict, k: int, durata: int | None = None) -> dict:
    """CFU «dichiarati» dall'anno k di un piano, percorso per percorso:
    {percorso: {"obb": CFU obbligatori, "fissi": CFU di gruppi a scelta con CFU fissi o con una sola scelta,
                "intervalli": [(min, max)] dei gruppi con intervallo}}."""
    out = {}
    for p in det.get("percorsi") or []:
        obb, fissi, interv, etich, alt, incerte, visti = 0.0, 0.0, [], [], [], [], set()
        trovato = False
        for a in p.get("anni") or []:
            if not _vale(a, k, durata):
                continue
            trovato = True
            for g in _gruppi_di_anno(a):
                atts = [x for x in g.get("attivita") or [] if not _e_frequenza(x)]
                cfu_g = _cfu_g(g) or (None if atts else _cfu_gruppo(g))
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
        if trovato:
            fissi += max(alt, default=0.0)
            out[p.get("des_it") or p.get("pdsDes") or ""] = {"obb": obb, "fissi": fissi, "intervalli": interv, "etichette": etich, "incerte": incerte}
    return out


def _cfu_anno(det: dict, k: int, durata: int | None = None) -> float:
    """CFU dichiarati dall'anno k (percorso più ricco: obbligatori e scelte con CFU fissi, più il minimo degli intervalli)."""
    s = _sommario_anno(det, k, durata)
    if not s:
        return -1.0
    return max(v["obb"] + v["fissi"] + sum(lo for lo, _ in v["intervalli"]) for v in s.values())


def _segna(item: dict, percorso: str | None, obbligatorio: bool) -> None:
    """Registra se l'attività è obbligatoria nel percorso («*» = percorso comune a tutti, senza percorso = comune)."""
    pc = percorso or "*"
    item["_flag"][pc] = item["_flag"].get(pc, False) or obbligatorio


def _espandi(i: dict) -> list[dict]:
    """Una riga per l'attività; due righe, con i curricula disgiunti, se è obbligatoria in alcuni curricula e a scelta in altri
    (la stessa attività è nel gruppo «Obbligatori» di un curriculum e tra le scelte libere degli altri)."""
    flags, tutti = i.pop("_flag"), i.pop("_tutti")
    risolto: dict[str, bool] = {}
    for pc, o in flags.items():
        for t in (tutti if pc == "*" else {pc}) or {"*"}:
            risolto[t] = risolto.get(t, False) or o
    righe = []
    for val in (True, False):
        pset = {t for t, o in risolto.items() if o == val}
        if not pset:
            continue
        r = dict(i)
        r["obbligatorio"] = val
        r["curriculum"] = None if "*" in pset or pset == tutti else ", ".join(sorted(pset))
        righe.append(r)
    job = i.get("_job")
    if job is not None:  # il lavoro dei libri riempie le righe, non l'originale
        job["items"][:] = [x for x in job["items"] if x is not i] + righe
    return righe


def fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client, libri_noti=None,
                testi_syllabus=None, libri_extra=None) -> dict:
    base = BASE
    c = client
    testi_syllabus = testi_syllabus or cc._testi_syllabus
    libri_noti = libri_noti or {}
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
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        for x in elenco:
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]) and x.get("tipo_corso_cod") == cur.get("tipo_corso_cod"):
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
        d = dettaglio(anno, x)
        return bool(d) and any(a.get("attivita") or any(g.get("attivita") or g.get("label_it") for g in a.get("insegnamenti") or [])
                               for p in d.get("percorsi") or [] for a in p.get("anni") or [])

    attuali = [x for x in attuali if con_piano(x)]
    log(f"[{uid}] di cui con un piano: {len(attuali)}")

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

        # nome canonico dei percorsi: quello della coorte più recente che li ha. Il confronto è con i percorsi delle
        # coorti già viste (mai con quelli della stessa coorte: «… 1» e «… 2» sono percorsi diversi)
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple[str, str, str, set]] = []  # (chiave, codice, nome canonico, codici delle attività)
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
                st = _stem_percorso(cod)
                if not trovato and st and not st.startswith("PDS0") and [_stem_percorso(c_) for c_ in cods].count(st) == 1:
                    cand = [r for r in visti if _stem_percorso(r[1]) == st]
                    trovato = cand[0] if len(cand) == 1 else None
                if not trovato:  # nome cambiato di poco («Percorso Rigenerazione urbana» → «Percorso Rigenerazione»)
                    num_r = {r[0]: (re.search(r"\d+", r[0]) or [None])[0] for r in visti}
                    stessi = [r[0] for r in visti if (num_r[r[0]] == (num[0] if num else None))
                              and (len(min(ch, r[0], key=len)) >= 6 and (r[0].startswith(ch) or ch.startswith(r[0])))]
                    simili = difflib.get_close_matches(ch, [r[0] for r in visti if num_r[r[0]] == (num[0] if num else None)],
                                                       n=1, cutoff=0.8)
                    scelto = (stessi or simili or [None])[0]
                    trovato = next((r for r in visti if r[0] == scelto), None) if scelto else None
                if not trovato and not _COMUNE.search(pn):
                    # percorso con un altro nome/codice (riordino): il più simile per insegnamenti in comune
                    mio = _adcod_percorso(p)
                    usati = {canon[(y, q)] for (yy, q) in list(canon) if yy == y}
                    migliori = sorted(((len(mio & r[3]) / max(1, len(mio | r[3])), r) for r in visti
                                       if r[3] and r[2] not in usati), key=lambda t: -t[0])
                    if mio and migliori and migliori[0][0] >= 0.4 and (len(migliori) == 1 or migliori[0][0] - migliori[1][0] >= 0.1):
                        trovato = migliori[0][1]
                if not trovato:
                    trovato = (ch, cod, _nome_percorso(pn), _adcod_percorso(p))
                    nuovi.append(trovato)
                canon[(y, pn)] = trovato[2]
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((cur.get("cdsCod"), k))
            if forzata in cohorts:
                return forzata
            ha = {y: _cfu_anno(d, k, durata) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v > 0}
            if not ha:
                return None
            # la coorte degli iscritti, se il suo anno ha un piano (almeno 30 CFU dichiarati); altrimenti la più vicina che lo ha
            # (coorti con il solo primo anno, o con una sola attività nell'anno); in mancanza, la più ricca
            buone = {y: v for y, v in ha.items() if v >= SOGLIA_ANNO}
            if y0 in buone:
                return y0
            if buone:
                return min(buone, key=lambda y: (abs(y - y0), -y))
            return y0 if y0 in ha else max(ha, key=lambda y: (ha[y], -abs(y - y0)))

        # stessa attività offerta in altre coorti/anni accademici: schede alternative per i libri
        alt_per_ad: dict[str, dict] = {}
        for y, (_, d) in cohorts.items():
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            alt_per_ad.setdefault(att.get("adCod") or att.get("cod"), {})[
                                (str(att.get("aa")), str(att.get("cod")))] = (y, att)
        # attività di tutte le coorti con anno di corso e CFU (per abbinare quelle che compaiono solo nella bacheca degli appelli)
        altre: dict[str, dict] = {}
        for y in sorted(cohorts, reverse=True):
            for p in cohorts[y][1].get("percorsi") or []:
                for a in p.get("anni") or []:
                    if not str(a.get("anno")).isdigit():
                        continue
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                altre.setdefault(att.get("adCod") or att.get("cod"), {
                                    "anno": int(a["anno"]), "cfu": att["crediti"], "coorte": y,
                                    "nome": cc._titolo(att.get("des_it") or ""), "ssd": None})
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
            sommario = _sommario_anno(d, k, durata)
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}", "sommario": sommario}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(_vale(a, k, durata) for a in p.get("anni") or [])]
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
                    if not _vale(a, k, durata):
                        continue
                    for g in _gruppi_di_anno(a):
                        atts = [t for t in g.get("attivita") or [] if not _e_frequenza(t)]
                        label = g.get("label_it") or ""
                        if not atts:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                            cfu_g = _cfu_gruppo(g)
                            nome = _nome_gruppo(label)
                            if not cfu_g or len(nome) < 3:
                                continue
                            key = f"{k}:#{_norm(nome)}:{cfu_g[1]:g}"
                            item = insegnamenti.get(key)
                            if not item:
                                item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu_g[1],
                                        "ssd": None, "obbligatorio": False, "curriculum": None, "_flag": {},
                                        "_tutti": curricula, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                        "libri": [], "esami": [], "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                                insegnamenti[key] = item
                            _segna(item, "*" if comune else pcur, False)
                            if not comune and pcur:
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
                                    "obbligatorio": bool(obbl), "curriculum": None, "_flag": {}, "_tutti": curricula,
                                    "docenti": sorted(set(docenti)),
                                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                }
                                if cc.lingua_attivita(att):  # lingua dell'attività: «it»/«en»
                                    item["lingua"] = cc.lingua_attivita(att)
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
                                    item["_job"] = syllabus_jobs[(str(att.get("aa")), str(att.get("cod")))]
                            _segna(item, "*" if comune else pcur, bool(obbl))
                            if not obbl:  # gruppo di scelta del piano («Scelta di un insegnamento tra»)
                                gs = cc.gruppo_scelta(g, att, p, a.get("anno"))
                                if gs:
                                    item.setdefault("_gruppi_scelta", set()).add(gs)
                            if not comune and pcur:
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
        # attività a 0 CFU nel piano (OFA, sicurezza, prove di verifica): non sono insegnamenti del piano
        for key, item in list(insegnamenti.items()):
            if not item.get("cfu"):
                del insegnamenti[key]
        ins = []
        for i in insegnamenti.values():
            cc.chiudi_gruppi(i)
            ins += _espandi(i)
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
        # stesso nome, anno e CFU con codici diversi, obbligatorio in alcuni percorsi e a scelta (altro codice, di solito dall'elenco
        # della scelta libera) in tutti: build_db/pulizia li unirebbero in un solo insegnamento obbligatorio per tutti. La riga a
        # scelta vale per i percorsi in cui l'altra non è obbligatoria; se l'altra è obbligatoria ovunque il nome porta il codice
        per_obbl: dict[tuple, list] = {}
        for i in ins:
            if i.get("codice"):
                per_obbl.setdefault((i["anno"], _nn(i["nome"]), i["cfu"]), []).append(i)
        for gruppo_i in per_obbl.values():
            obb = [i for i in gruppo_i if i["obbligatorio"]]
            sce = [i for i in gruppo_i if not i["obbligatorio"] and all(i["codice"] != o["codice"] for o in obb)]
            if not obb or not sce:
                continue
            ps_obb = set() if any(not o["curriculum"] for o in obb) else {p for o in obb for p in o["curriculum"].split(", ")}
            for sc in sce:
                propri = set(sc["curriculum"].split(", ")) if sc["curriculum"] else set(percorsi_nomi)
                if ps_obb and propri - ps_obb:
                    sc["curriculum"] = ", ".join(sorted(propri - ps_obb))
                else:
                    sc["nome"] = f"{sc['nome']} ({sc['codice']})"
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
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "_altre": altre, "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
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
                it["_noto"] = True  # i libri del database valgono: non si rileggono da Leganto
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        it[k_] = noto[k_]
            return len(noto["libri"])
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            sy = {}
        libri, modalita, legati = testi_syllabus(sy) if sy else ([], None, [])
        if not libri and sy and libri_extra:  # testi in forma libera e codici delle liste Leganto indicati nel syllabus
            libri = libri_extra(sy)
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
                l2 = l2 or (libri_extra(sy2) if libri_extra else [])
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
    for r in corsi_out:
        for i in r["insegnamenti"]:
            i.pop("_job", None)
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unibg_piani.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
