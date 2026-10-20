"""Insubria: piani di studio per coorte dal Course Catalogue Cineca (`uninsubria.coursecatalogue.cineca.it`).

Lo usa `adapters/uninsubria.py` al posto della lettura comune di `cineca_catalogue`, che per l'Insubria dava anni
senza insegnamenti obbligatori, contenitori a 0 CFU, anni mancanti e percorsi «comune» trattati come curricula.

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo
  anno). I codici dei corsi cambiano con il riordino (F011 → F11R, A010 → A10R, U035 → U35R) e le coorti precedenti
  restano sul corso vecchio: la coorte precedente si ritrova per codice, per codice senza zeri e senza «R», per nome,
  sede e tipo o per nome e tipo (Infermieristica: i tre corsi per sede del 2026 hanno alle spalle un solo corso con un
  percorso per sede). Se la coorte non ha pubblicato quell'anno (a volte è pubblicata vuota, come W08R o A16R nel
  2025) si legge la più vicina che lo ha (a parità la più recente);
- gruppi del piano (`cod`): «OO» sono gli insegnamenti obbligatori; «F», «W», «T», «G» gruppi di scelta (CFU
  nell'etichetta «(12 CFU)» o «(fra 6 e 20 CFU)», oppure una scelta tra), «S» crediti liberi. Un'attività è obbligatoria
  se sta in «OO», se il gruppo la richiede per intero (CFU fissi dell'etichetta uguali alla somma delle attività, o
  etichetta «Obbligatori …» senza «a scelta»), o se il gruppo è un solo insegnamento obbligatorio;
- contenitori: l'attività a 0 CFU con `adFiglie` (insegnamento integrato) non è una riga del piano: i CFU stanno nei
  moduli, che sono già attività del piano (se qualche modulo manca si aggiunge dalle `adFiglie`);
- attività a 0 CFU (test di verifica, OFA, scelte libere senza CFU nel catalogo) senza CFU noti da altre coorti: non
  sono insegnamenti del piano e si tolgono; i CFU di un'attività a 0 CFU si prendono dallo stesso codice in un'altra
  coorte dello stesso corso;
- gruppi senza attività elencate: voce a scelta con i CFU dell'etichetta (il massimo se «fra a e b CFU»);
- percorsi: «comune», «generale», «percorso comune» valgono per tutti i curricula; i percorsi part-time (`partTimeDes`)
  hanno una scansione propria degli anni (più anni compressi in un anno del catalogo) e non si importano: sono gli
  stessi insegnamenti del percorso a tempo pieno; un'attività presente in tutti i percorsi dell'anno non ha curriculum;
- `piano_anni`: per ogni anno la coorte da cui viene, l'url del catalogo e i CFU dichiarati del piano (obbligatori,
  scelte con CFU fissi, minimo degli intervalli), per i controlli di `controllo_cfu`.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import re
import time
import unicodedata

from . import ammissione
from . import cineca_catalogue as cc

TIPI = {"L2", "LM", "LM5", "LM6"}

_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_TOTALE_CFU = re.compile(r"(?i)\bper un totale di\s+([\d.,]+)\s*CFU")
_COMUNE = re.compile(r"(?i)\bcomune\b|^\W*(?:(?:percorso|piano|schema)\s+)?(?:generale|common)\W*$")
_ACCENTI = {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}
_PART_TIME = re.compile(r"(?i)\bpart[\s-]*time\b|\bpart$")
_SCELTA = re.compile(r"(?i)\bscelt|\btra\b|of the list|alternativ|opzion|\boppure\b|\bor\b")
_STAGE = re.compile(r"(?i)^\s*(?:stage|internship|tirocinio)\s*$")
_ALT_STAGE = re.compile(r"(?i)alternativ\w*\s+(?:allo|to)\s+(?:stage|internship)")
_NUMERI = {"due": 2, "tre": 3, "quattro": 4, "cinque": 5, "2": 2, "3": 3, "4": 4, "5": 5}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti (le parentesi restano)."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _famiglia(cds: str | None) -> str:
    """Codice del corso senza gli zeri iniziali delle cifre e senza la «R» del riordino: F011, F11R → F11; A010 → A10."""
    c = re.sub(r"R$", "", (cds or "").strip().upper())
    return re.sub(r"(?<=[A-Z])0+(?=\d)", "", c)


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m and 1 <= int(m.group(1)) <= 6:
        return int(m.group(1))
    return {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _titolo_etichetta(s: str) -> str:
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        return s[:1].upper() + s[1:]
    return s[:1].upper() + s[1:].lower()


def _cfu_etichetta(label: str | None):
    """(minimo, massimo) dei CFU nell'etichetta di un gruppo: «(12 CFU)» → (12, 12), «(fra 6 e 18 CFU)» → (6, 18)."""
    m = _ETICHETTA_CFU.search(label or "")
    if m:
        hi = _numero(m.group(2))
        return (_numero(m.group(1)) if m.group(1) else hi), hi
    m = _TOTALE_CFU.search(label or "")
    if m:
        v = _numero(m.group(1))
        return v, v
    return None


def _nome_gruppo(label: str) -> str:
    """Nome della voce a scelta di un gruppo senza attività: l'etichetta (con l'intervallo dei CFU se non è fisso)."""
    lab = re.sub(r"\s+", " ", label or "").strip()
    cfu = _cfu_etichetta(lab)
    if cfu and cfu[0] == cfu[1]:
        lab = _ETICHETTA_CFU.sub(" ", lab)
    lab = re.sub(r"^\s*\d+°?\s*anno\s*[-–:]?\s*", "", lab, flags=re.I)
    return _titolo_etichetta(lab)


def _molteplicita(label: str | None) -> int:
    """Quante scelte chiede un gruppo senza CFU nell'etichetta: «DUE INSEGNAMENTI A SCELTA» → 2."""
    m = re.search(r"(?i)\b(due|tre|quattro|cinque|[2-5])\s+(?:scelt\w+|esam\w+|insegnament\w+|corsi|attivit\w+|lingu\w+)",
                  label or "")
    return _NUMERI.get(m.group(1).lower(), 1) if m else 1


def _scelte_etichetta(label: str | None) -> int | None:
    """«… - 2 A SCELTA TRA (12 CFU)», «… 1 OF THE LIST (6 CFU)» → quante attività si scelgono."""
    m = re.search(r"(?i)[-–]\s*(\d)\s+(?:a\s+scelt\w+\s+tra|of the list)", label or "")
    return int(m.group(1)) if m else None


def _gruppi_di_anno(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _e_part_time(p: dict) -> bool:
    return bool(p.get("partTimeDes")) or bool(_PART_TIME.search(p.get("des_it") or p.get("pdsDes") or ""))


def _crediti(att: dict, noti: dict[str, float]) -> float:
    v = att.get("crediti")
    if isinstance(v, (int, float)) and v > 0:
        return v
    return noti.get(att.get("adCod") or att.get("cod")) or 0


def _tutti_obbligatori(g: dict, atts: list[dict], noti: dict[str, float]) -> bool:
    """Il gruppo richiede tutte le sue attività (insegnamenti obbligatori scritti in un gruppo «F»/«W»)."""
    label = g.get("label_it") or ""
    if g.get("cod") == "OO":
        return True
    cfu = _cfu_etichetta(label)
    tot = sum(_crediti(a, noti) for a in atts)
    if cfu and cfu[0] == cfu[1] and tot > 0 and abs(tot - cfu[0]) < 1e-6 and not _SCELTA.search(label):
        return True
    if re.match(r"(?i)\s*(?:insegnament\w*\s+)?obbligator\w*", label) and not _SCELTA.search(label) \
            and not re.search(r"(?i)\bper chi\b", label):
        return True
    if re.search(r"(?i)\bobbligator\w*.*laurea magistrale in economia|\bobbligatori[oa] per la laurea", label):
        return True
    return False


_ROMANI = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6}


def _anno_etichetta(label: str | None) -> int | None:
    """Anno di corso scritto nell'etichetta di un gruppo: «… - II anno» → 2, «3° anno» → 3."""
    m = re.search(r"(?i)(?<![a-z])(vi|iv|v|iii|ii|i)\s*(?:\^|°)?\s*anno(?![a-z])|(?<![0-9])([1-6])\s*°\s*anno(?![a-z])",
                  label or "")
    if not m:
        return None
    return _ROMANI.get(m.group(1).lower()) if m.group(1) else int(m.group(2))


def _anni_k(p: dict, k: int) -> list[dict]:
    """Gli anni del percorso `p` che valgono per l'anno di corso k: quello con `anno` k, più i gruppi dell'anno «0» (altre
    attività non legate a un anno) la cui etichetta dice che sono del k-esimo anno."""
    out = []
    for a in p.get("anni") or []:
        if str(a.get("anno")).isdigit() and int(a["anno"]) == k:
            out.append(a)
        elif not (str(a.get("anno")).isdigit() and int(a["anno"]) > 0):
            gruppi = [g for g in _gruppi_di_anno(a) if _anno_etichetta(g.get("label_it")) == k]
            if gruppi:
                out.append({"anno": k, "insegnamenti": gruppi})
    return out


def _comuni_specifici(percorsi: list[dict], k: int) -> tuple[set, list]:
    """Nomi dei percorsi comuni (valgono per tutti i curricula) e dei percorsi specifici che hanno l'anno k."""
    nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi
              if not _e_part_time(p) and _anni_k(p, k)}
    anni_p = {n: max([int(a["anno"]) for a in p.get("anni") or [] if str(a.get("anno")).isdigit()] or [0])
              for n, p in nomi_k.items()}
    comuni = {n for n in nomi_k if _COMUNE.search(n) or (len(nomi_k) > 1 and anni_p[n] < max(anni_p.values()))}
    return comuni, [n for n in nomi_k if n not in comuni]


def _sommario_anno(det: dict, k: int, noti: dict[str, float]) -> dict:
    """CFU «dichiarati» dall'anno k di un piano, percorso per percorso:
    {percorso: {"obb": CFU obbligatori, "fissi": CFU di gruppi a scelta con CFU fissi o con una sola scelta,
                "intervalli": [(min, max)] dei gruppi con intervallo}}."""
    out = {}
    for p in det.get("percorsi") or []:
        if _e_part_time(p):
            continue
        for a in _anni_k(p, k):
            obb = fissi = 0.0
            intervalli: list[tuple] = []
            visti: set = set()
            alt = []
            for g in _gruppi_di_anno(a):
                atts = [x for x in g.get("attivita") or [] if not (x.get("adFiglie") and not x.get("crediti"))]
                cfu_g = _cfu_etichetta(g.get("label_it"))
                tutti = _tutti_obbligatori(g, atts, noti)
                if tutti:
                    for x in atts:
                        ad = x.get("adCod") or x.get("cod")
                        if ad not in visti:
                            visti.add(ad)
                            obb += _crediti(x, noti)
                    continue
                label = g.get("label_it") or ""
                if _STAGE.match(label) or _ALT_STAGE.search(label):
                    alt.append(cfu_g[0] if cfu_g else max([_crediti(x, noti) for x in atts] or [0]))
                elif cfu_g and cfu_g[0] == cfu_g[1]:
                    fissi += cfu_g[0]
                elif cfu_g:
                    intervalli.append(cfu_g)
                elif atts:
                    cf = [_crediti(x, noti) for x in atts]
                    cf = [c for c in cf if c]
                    if cf:
                        n = _scelte_etichetta(label) or _molteplicita(label)
                        fissi += max(cf) * min(n, len(atts))
            fissi += max(alt, default=0.0)
            out[(p.get("des_it") or p.get("pdsDes") or "").strip()] = {"obb": obb, "fissi": fissi, "intervalli": intervalli}
    comuni, specifici = _comuni_specifici(det.get("percorsi") or [], k)
    if len(specifici) >= 2 and comuni:  # ogni curriculum vale quanto il suo piano più quello comune
        base = [out[n] for n in comuni if n in out]
        return {n: {"obb": out[n]["obb"] + sum(x["obb"] for x in base),
                    "fissi": out[n]["fissi"] + sum(x["fissi"] for x in base),
                    "intervalli": out[n]["intervalli"] + [i for x in base for i in x["intervalli"]]}
                for n in specifici if n in out}
    if len(specifici) < 2 and len(out) > 1:  # un solo curriculum (o nessuno): i percorsi valgono per tutti
        return {" + ".join(out): {"obb": sum(x["obb"] for x in out.values()),
                                  "fissi": sum(x["fissi"] for x in out.values()),
                                  "intervalli": [i for x in out.values() for i in x["intervalli"]]}}
    return out


def _dichiarati(s: dict) -> float:
    return max((v["obb"] + v["fissi"] + sum(lo for lo, _ in v["intervalli"]) for v in s.values()), default=-1.0)


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", " ", nome)
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo|piano|schema)\b", " ", n)
    return _norm(n)


def _nome_percorso(nome: str) -> str:
    """Nome del percorso senza «coorte 20xx», senza «Curriculum»/«Percorso» davanti e senza la sede in coda
    («ECONOMICO COMO» → «Economico»); l'apostrofo finale delle maiuscole è un accento («BIODIVERSITA'» → «biodiversità»)."""
    n = re.sub(r"(?i)[\s,-]*coorte\s*\d{4}(?:[/-]\d{2,4})?", "", nome)
    n = re.sub(r"\s+", " ", n).strip(" -:,\t")
    n = re.sub(r"(?i)^(?:curriculum|percorso|indirizzo)\s+(?=\S{4,})", "", n)
    n = re.sub(r"(?i)\s+(?:como|varese|va)$", "", n)
    if n.isupper():
        n = n.capitalize()
    n = re.sub(r"(?i)\b(\w*[a-z])([aeiou])'(?=\s|$)", lambda m: m.group(1) + _ACCENTI[m.group(2).lower()], n)
    return n[:1].upper() + n[1:]


def _percorsi_sede(percorsi: list[dict], cur: dict) -> list[dict]:
    """Percorsi «… Sede di <città>»: solo quello della sede del corso, se è uno solo."""
    nomi = [(p.get("des_it") or p.get("pdsDes") or "").upper() for p in percorsi]
    if len(percorsi) < 2 or not all("SEDE" in n for n in nomi):
        return percorsi
    sede = re.sub(r"\s+\d+$", "", (cur.get("sede_des_it") or "").upper()).strip()
    sede = re.sub(r"\s*-.*$", "", sede)
    for citta in (sede, sede.split(" ")[0]):
        if citta:
            scelti = [p for p, n in zip(percorsi, nomi) if re.search(rf"\b{re.escape(citta)}\b", n)]
            if len(scelti) == 1:
                return scelti
    return percorsi


def fetch_piani(uid: str, anno: int, client, base: str, testi_syllabus, libri_noti: dict | None = None,
                max_cds: int | None = None, syllabus: bool = True, log=print, id_universitaly: dict | None = None,
                durata_max: int = 6) -> dict:
    """Contributo (formato di database/contrib) con i piani di tutti i corsi del catalogo.
    `client`: ClientCache di uninsubria.py; `testi_syllabus(sy)`: (libri, modalità, legati)."""
    c = client
    libri_noti = libri_noti or {}
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - durata_max + 1, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c._get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    attuali = []
    visti_cod = set()
    for x in coorti[anno]:
        if x["cod"] not in visti_cod:
            visti_cod.add(x["cod"])
            attuali.append(x)
    if max_cds:
        attuali = attuali[:max_cds]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            d = _un(c._get(f"/corso/{y}/{x['cod']}"))
            if isinstance(d, dict):
                c._note_af(d)
            dettagli[k] = d if isinstance(d, dict) else None
        return dettagli[k]

    def candidati(y: int, cur: dict) -> list[dict]:
        """Corsi della coorte y che sono lo stesso corso di `cur` (codice, famiglia di codici, nome+sede+tipo, nome+tipo)."""
        elenco = coorti.get(y, [])
        for test in (
            lambda x: x["cdsCod"] == cur["cdsCod"],
            lambda x: _famiglia(x["cdsCod"]) == _famiglia(cur["cdsCod"]) and x.get("tipo_corso_cod") == cur.get("tipo_corso_cod"),
            lambda x: (_nn(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod"))
            == (_nn(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod")),
        ):
            r = [x for x in elenco if test(x)]
            if r:
                return r
        r = [x for x in elenco if (_nn(x.get("des_it")), x.get("tipo_corso_cod")) == (_nn(cur.get("des_it")), cur.get("tipo_corso_cod"))]
        return r if len(r) == 1 and _nn(cur.get("des_it")) else []

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, list[tuple[dict, dict]]] = {}
        for y in range(anno - durata_max + 1, anno + 1):
            lst = []
            for x in candidati(y, cur):
                d = dettaglio(y, x)
                if d:
                    lst.append((x, d))
            if lst:
                cohorts[y] = lst
        if not cohorts:
            return None
        rec = (cohorts.get(anno) or cohorts[max(cohorts)])[0]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(rec[1], f"{base}/corsi/{anno}/{cur.get('cod')}")

        # CFU di un'attività noti da una coorte (servono per le attività a 0 CFU di un'altra)
        noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for _, d in cohorts[y]:
                for p in d.get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in _gruppi_di_anno(a):
                            for att in g.get("attivita") or []:
                                if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                    noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        def scegli(y: int, k: int):
            """(x, d) della coorte y per l'anno k: il candidato con più CFU dichiarati."""
            migliori = sorted(cohorts.get(y, []), key=lambda xd: -_dichiarati(_sommario_anno(xd[1], k, noti)))
            return migliori[0] if migliori else None

        def coorte_anno(k: int):
            y0 = anno - k + 1
            ha = {}
            for y in cohorts:
                sc = scegli(y, k)
                v = _dichiarati(_sommario_anno(sc[1], k, noti)) if sc else -1.0
                if v > 0:
                    ha[y] = v
            if not ha:
                return None
            if y0 in ha and ha[y0] >= 30:
                return y0
            buoni = {y: v for y, v in ha.items() if v >= 30} or ha
            return min(buoni, key=lambda y: (abs(y - y0), -y))

        # attività delle altre coorti per i libri: schede alternative dello stesso insegnamento
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        piano_anni: dict[str, dict] = {}
        mancanti_figli: list[str] = []
        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            x, d = scegli(scelta, k)
            sommario = _sommario_anno(d, k, noti)
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                  "dichiarati": _dichiarati(sommario),
                                  "sommario": {n: {"obb": v["obb"], "fissi": v["fissi"], "intervalli": v["intervalli"]}
                                               for n, v in sommario.items()}}
            percorsi = _percorsi_sede(d.get("percorsi") or [], cur)
            percorsi = [p for p in percorsi if not _e_part_time(p)]
            percorsi_k = [p for p in percorsi if _anni_k(p, k)]
            nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi_k}
            comuni, specifici = _comuni_specifici(percorsi_k, k)
            curricula = {_nome_percorso(n) for n in specifici} if len(specifici) >= 2 else set()
            for pnome, p in nomi_k.items():
                comune = pnome in comuni or not curricula
                pcur = None if comune else _nome_percorso(pnome)
                for a in _anni_k(p, k):
                    ads_anno = {t.get("adCod") or t.get("cod") for g in _gruppi_di_anno(a) for t in g.get("attivita") or []}
                    for g in _gruppi_di_anno(a):
                        atts = g.get("attivita") or []
                        label = g.get("label_it") or ""
                        if not any(_crediti(t, noti) > 0 or t.get("adFiglie") for t in atts):
                            atts = []  # nessuna attività con CFU: contano i CFU dell'etichetta
                        if not atts:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                            cfu_g = _cfu_etichetta(label)
                            nome = _nome_gruppo(label)
                            if not cfu_g or len(nome) < 3:
                                continue
                            key = f"{k}:#{_nn(nome)}:{cfu_g[1]:g}"
                            item = insegnamenti.get(key)
                            if not item:
                                item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu_g[1],
                                        "ssd": None, "obbligatorio": False, "curriculum": None, "_percorsi": set(),
                                        "_tutti": curricula, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                        "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                        "_senza_codice": True}
                                insegnamenti[key] = item
                            if pcur is None:
                                item["_comune"] = True
                            else:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
                            continue
                        tutti = _tutti_obbligatori(g, atts, noti)
                        figli_piano = []
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            figli = att.get("adFiglie") or []
                            if figli and not att.get("crediti"):
                                # contenitore (insegnamento integrato): i CFU stanno nei moduli
                                for f in figli:
                                    if f.get("adCod") not in ads_anno and f.get("crediti"):
                                        figli_piano.append((att, f))
                                continue
                            cfu = _crediti(att, noti)
                            if not cfu:
                                continue  # nessun CFU nel catalogo: non è un insegnamento del piano
                            figli_piano.append((att, None))
                        for att, fig in figli_piano:
                            src = fig or att
                            ad = src.get("adCod") or src.get("cod")
                            obbl = tutti or (len(atts) == 1 and att.get("tipo_ins_cod") == "IB" and not _SCELTA.search(label)
                                             and not _STAGE.match(label) and not _cfu_etichetta(label))
                            key = f"{k}:{ad}:{int(bool(obbl))}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in src.get("docenti") or [] if t.get("des")]
                                if fig:
                                    url = f"{base}/corsi/{scelta}/{x['cod']}"
                                else:
                                    url = (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}")
                                item = {
                                    "codice": ad, "nome": cc._titolo(src.get("des_it") or src.get("adDes_it") or ad),
                                    "anno": k, "periodo": cc._periodo(src.get("periodo_didattico_it")),
                                    "periodo_inizio": src.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": src.get("data_fine_periodo_didattico"),
                                    "cfu": _crediti(src, noti), "ssd": None,
                                    "obbligatorio": bool(obbl), "curriculum": None, "_percorsi": set(),
                                    "_tutti": curricula,
                                    "docenti": sorted(set(docenti)), "url": url,
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                }
                                insegnamenti[key] = item
                                if fig:
                                    mancanti_figli.append(ad)
                                if syllabus and not fig:
                                    syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                                   "af_percorso": att.get("corso_percorso_id"),
                                                   "corso_cod": att.get("corso_cod"), "corso_aa": scelta,
                                                   "schema_id": att.get("schemaId")},
                                        "items": [], "codice": ad})["items"].append(item)
                            if pcur is None:
                                item["_comune"] = True
                            else:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
        # stesso insegnamento obbligatorio in alcuni curricula e a scelta in altri (curricula disgiunti): due righe;
        # altrimenti una sola, obbligatoria
        per_cod: dict[tuple, list] = {}
        for key, i in list(insegnamenti.items()):
            if i.get("codice"):
                per_cod.setdefault((i["anno"], i["codice"]), []).append((key, i))
        for righe in per_cod.values():
            if len(righe) < 2:
                continue
            ob = next((i for _, i in righe if i["obbligatorio"]), None)
            sc = next((i for _, i in righe if not i["obbligatorio"]), None)
            if not ob or not sc:
                continue
            if not ob.get("_comune") and not sc.get("_comune") and ob["_percorsi"] and sc["_percorsi"]                     and not (ob["_percorsi"] & sc["_percorsi"]):
                continue
            ob["_comune"] = ob.get("_comune") or sc.get("_comune")
            ob["_percorsi"] |= sc["_percorsi"]
            ob["docenti"] = sorted(set(ob["docenti"]) | set(sc["docenti"]))
            for key, i in righe:
                if i is sc:
                    del insegnamenti[key]
        ins = list(insegnamenti.values())
        usati: set[str] = set()
        for i in ins:
            ps, tutti_c = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti_c:
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
        if id_universitaly and cur.get("cdsCod") in id_universitaly:
            out["id_universitaly"] = id_universitaly[cur["cdsCod"]]
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
        if noto and noto.get("libri") is not None and noto.get("stato_libri"):  # libri già raccolti: non si rileggono
            for it in job["items"]:
                it["libri"] = noto["libri"]
                it["stato_libri"] = noto["stato_libri"]
                it["_noto"] = True
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        it[k_] = noto[k_]
            return len(noto["libri"])
        sy = c._get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, _ = testi_syllabus(sy)
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
    with cf.ThreadPoolExecutor(6) as ex:
        for i, n in enumerate(ex.map(do_syllabus, syllabus_jobs.values()), 1):
            trovati += n
            if i % 500 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    log(f"[{uid}] libri nei syllabus: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/uninsubria_piani.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
