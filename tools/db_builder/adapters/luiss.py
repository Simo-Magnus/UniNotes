"""LUISS Guido Carli: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://luiss.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`): con i riordini del 2025 (L-18 R, LM-77 R, ...) e i cambi di nome
  (Corporate Finance → Finance, Economia e Finanza → Economia, Istituzioni e Mercati Finanziari, Governo, Amministrazione e
  Politica → Government and Public Affairs, Management and Computer Science → Management and Artificial Intelligence)
  il codice del catalogo cambia, ma il codice ministeriale del corso (`codicione`) resta lo stesso: le coorti precedenti
  restano sotto il codice vecchio. Per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al
  k-esimo anno) del codice più recente che ha il piano di quell'anno (catena di codici);
- il catalogo pubblica, per ogni coorte, solo gli anni già attivati: il piano della coorte 2024 ha i primi tre anni, quello
  della 2026 solo il primo. I percorsi si chiamano «<N> anno <curriculum>» (N = anni pubblicati della coorte): il prefisso e il
  suffisso «da orientamento INGLESE/ITALIANO» non fanno parte del nome del curriculum;
- gruppi del piano (`cod`): «OO» obbligatori; «F» e «W» blocchi fissi o a scelta. Un'attività è obbligatoria se il catalogo la
  segna «OBB» (tipo di insegnamento); le attività «OPZ» (anche dentro «Obbligatori», come «WID» o «Chinese institutions and
  culture» del ACE Program) sono a scelta. Le etichette «1/2 Core course», «2/2 Core course» sono posti da riempire con una
  sola attività del gruppo;
- attività a 0 CFU (prove, test, livelli) non sono insegnamenti del piano;
- «***CORE ABROAD***», «***ELECTIVE ABROAD***»: crediti da svolgere all'estero, righe distinte per codice;
- percorsi: «comune» (nessun nome dopo il prefisso, «BASE», «orientamento …») valgono per tutti i curricula. Dove due percorsi
  «comuni» hanno contenuti diversi (ACE Program della Business Administration) sono due percorsi alternativi.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/luiss.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/luiss.py [--senza-syllabus]
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

BASE = "https://luiss.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5"}

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio).
# Stesso codice ministeriale («codicione») in ogni coorte; il nome o il codice del catalogo può cambiare.
CORSI: list[tuple[str, tuple[str, ...]]] = [
    ("1633480", ("L25BA", "L21BA")),                # Business Administration (L-18)
    ("1633481", ("L25EE", "L21EE")),                # Economia e management (L-18)
    ("1633483", ("L25BB", "L21BB")),                # Economics and Business (L-33)
    ("1633479", ("L24GLO",)),                       # Global Law (L-14)
    ("1633482", ("L25AIM", "L24AIM", "L21DS")),     # Management and Artificial Intelligence (L-18), già Management and Computer Science
    ("1633485", ("L25PPE", "L22PPE")),              # Politics: Philosophy and Economics (L-36)
    ("1633484", ("L25PS", "L22PS")),                # Scienze politiche (L-36)
    ("1631977", ("LM25A", "LM19A")),                # Amministrazione, finanza e controllo (LM-77)
    ("1625424", ("LM26DSM", "LM25DSM", "LM21DSM")),  # Data Science and Management (LM-Data, già LM-91)
    ("1631973", ("LM26EIM", "LM25F", "LM19F")),     # Economia, istituzioni e mercati finanziari (LM-56), già Economia e finanza
    ("1631979", ("LM26FIN", "LM25W", "LM19W")),     # Finance (LM-77), già Corporate Finance
    ("1631976", ("LM25GMP", "LM19GMP")),            # Global Management and Politics (LM-77)
    ("1631974", ("LM26GPA", "LM25GAP", "LM20GAP")),  # Government and Public Affairs (LM-62), già Governo, amministrazione e politica
    ("1633487", ("LM25IR", "LM20IR")),              # International Relations (LM-52)
    ("1631978", ("LM25M", "LM19M")),                # Management (LM-77)
    ("1631975", ("LM25K", "LM19K")),                # Marketing (LM-77)
    ("1632840", ("LM25SM", "LM24SM", "LM21SM")),    # Strategic Management (LM-77)
    ("1633486", ("LM25GS", "LM3GS")),               # Giurisprudenza (LMG/01)
]

# Nomi di percorso uguali nelle coorti (stessa persona, nome scritto in modo diverso): normalizzato → nome
ALIAS_PERCORSI: dict[str, str] = {}

# Correzioni al catalogo dove il piano ufficiale dice altro: (codice del corso, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "obbligatorio" | "cfu=<n>".
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (codice del corso, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

_SMALL = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al", "alla",
          "alle", "ai", "agli", "il", "la", "lo", "le", "gli", "i", "nel", "nella", "nelle", "nei", "sul", "sulla", "tra",
          "fra", "o", "su", "dal", "dalla", "and", "of", "the", "to", "for", "on", "with", "an", "or", "at", "by", "from",
          "as", "vs", "its", "into", "in"}
_SIGLE = {"ADE", "AI", "ICT", "IT", "EU", "UE", "US", "USA", "UK", "UN", "ESG", "CSR", "HR", "IP", "LUISS", "ACE", "BI", "GAP",
          "GDPR", "SQL", "ERP", "OECD", "NATO", "WTO", "IMF", "PPE", "STEM", "CFU", "ECTS", "IA", "MBA", "KPI", "SMEs", "CEO",
          "NGO", "ROME", "XLAB", "ZLAB", "OFA", "DNA", "IOT", "UX", "UI"}
_SIGLE_MAIUSC = {s.upper() for s in _SIGLE}
_ROMANO = re.compile(r"[ivx]{1,4}")
_SCELTA_PIANO = re.compile(r"^\s*(\d+)/(\d+)\b")
_PERIODI = {"primo semestre": "1", "secondo semestre": "2", "annualità singola": "annuale", "annuale": "annuale",
            "primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale"}
_SENZA_NOME = re.compile(r"(?i)(base|orientamento\s*\w*)?")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _titolo(des: str | None) -> str:
    """Nome dell'attività: maiuscolo del catalogo → iniziali maiuscole (sigle e numeri romani restano); gli asterischi dei
    segnaposto («***CORE ABROAD***») si tolgono."""
    des = re.sub(r"\s+", " ", (des or "").replace("*", " ")).strip()
    if not des.isupper():
        return des
    out = []
    for i, w in enumerate(des.lower().split(" ")):
        core = re.sub(r"[^\w']", "", w)
        if i and _ROMANO.fullmatch(core):
            out.append(w.upper())
        elif core.upper() in _SIGLE_MAIUSC:
            out.append(re.sub(re.escape(core), core.upper(), w, count=1))
        elif i and core in _SMALL:
            out.append(w)
        elif "'" in w:
            a, _, b = w.partition("'")
            out.append(a + "'" + b[:1].upper() + b[1:])
        else:
            m = re.search(r"[a-zà-ÿ]", w)
            out.append(w[:m.start()] + w[m.start()].upper() + w[m.start() + 1:] if m else w)
    return " ".join(out)


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return _PERIODI.get(re.sub(r"\s+", " ", s.lower()).strip(), s.strip())


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/luiss)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "luiss" if d else None

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


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L2": 3, "LM": 2, "LM5": 5}.get(tipo or "", 3)


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _vale(a: dict, k: int) -> bool:
    return str(a.get("anno")).isdigit() and int(a["anno"]) == k


def _ha_anno(det: dict, k: int) -> bool:
    """Il piano ha attività con CFU per l'anno di corso k."""
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            if _vale(a, k):
                for g in _gruppi(a):
                    if any((t.get("crediti") or 0) > 0 for t in g.get("attivita") or []):
                        return True
    return False


def _obbligatorio(g: dict, att: dict) -> bool:
    """Obbligatoria se il catalogo la segna «OBB» (tipo di insegnamento); in «Obbligatori» lo sono tutte, salvo quelle
    segnate «OPZ» (opzioni di un'alternativa, es. la scelta tra WID e Chinese institutions and culture)."""
    tipo = (att.get("tipo_ins_cod") or "").strip().upper()
    if g.get("cod") == "OO":
        return tipo != "OPZ"
    return tipo == "OBB"


def _nome_percorso_grezzo(p: dict) -> str:
    """«2 anno ACE program» → «ACE program»; «1 anno COMUNICAZIONE E PUBLIC AFFAIRS - da orientamento INGLESE» →
    «COMUNICAZIONE E PUBLIC AFFAIRS»; i percorsi senza nome («1 anno», «BASE», «Orientamento INGLESE») → «»."""
    n = (p.get("des_it") or p.get("pdsDes") or "").strip()
    n = re.sub(r"(?i)^\s*\d+\s*anno\b\s*[-–:]?\s*", "", n)
    n = re.sub(r"(?i)^\s*AFC\s*[-–]\s*", "", n)
    n = re.sub(r"\s+", " ", n).strip(" -:")
    n = re.sub(r"(?i)(?<=\w) (ENG|ITA)\)", lambda m: " (" + m.group(1) + ")", n)  # nel catalogo manca la parentesi aperta
    # «… - da orientamento INGLESE»: lo stesso curriculum seguito da chi ha scelto l'orientamento (piani diversi, codici
    # diversi): resta nel nome, i due piani non si fondono
    m = re.search(r"(?i)\s*[-–]?\s*\(?da orientamento\s+(\w+)\)?\s*$", n)
    ori = m.group(1).lower() if m else ""
    if m:
        n = n[:m.start()].strip(" -:")
    if _SENZA_NOME.fullmatch(n):
        return ""
    return f"{n} (da orientamento {ori})" if ori else n


def _pulisci_nome_percorso(nome: str) -> str:
    """Nome di un curriculum: maiuscole del catalogo corrette e senza virgole (i curricula di un insegnamento si separano con
    la virgola)."""
    nome = re.sub(r"\s*,\s*", " - ", nome)
    m = re.match(r"^(.*?)( \(da orientamento \w+\))?$", nome)
    nome = (_titolo(m.group(1)) if m.group(1).isupper() else m.group(1)) + (m.group(2) or "")
    return nome[:1].upper() + nome[1:]


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
            """(coorte, riga dell'elenco, dettaglio) da cui leggere l'anno di corso k: la coorte A-k+1 e, se non ha quell'anno,
            la più vicina che lo ha."""
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((catena[0], k))
            ordine = [forzata] if forzata in cohorts else []
            ordine += sorted(cohorts, key=lambda y: (abs(y - y0), -y))
            for y in ordine:
                for x, d in cohorts[y]:
                    if _ha_anno(d, k):
                        return y, x, d
            return None

        # nome canonico dei curricula: quello della coorte più recente che li ha, per nome senza maiuscole e punteggiatura
        per_chiave: dict[str, str] = {}
        for y in sorted(cohorts, reverse=True):
            for _x, d in cohorts[y]:
                for p in d.get("percorsi") or []:
                    nome = _nome_percorso_grezzo(p)
                    if nome:
                        nome = _pulisci_nome_percorso(nome)
                        per_chiave.setdefault(_norm(nome), nome)

        def nome_percorso(p: dict) -> str:
            nome = _nome_percorso_grezzo(p)
            if not nome:
                return ""
            nome = _pulisci_nome_percorso(nome)
            chiave = ALIAS_PERCORSI.get(_norm(nome)) or _norm(nome)
            return per_chiave.get(chiave, nome)

        alt_per_ad: dict[str, dict] = {}
        for y, lst in cohorts.items():
            for _x, d in lst:
                for p in d.get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in _gruppi(a):
                            for t in g.get("attivita") or []:
                                alt_per_ad.setdefault(t.get("adCod") or t.get("cod"), {})[(str(t.get("aa")), str(t.get("cod")))] = (y, t)

        insegnamenti: dict[str, dict] = {}
        stati: dict[str, dict[str | None, bool]] = {}  # (anno:codice:cfu) → {curriculum o None se comune: obbligatorio}
        percorsi_nomi: set[str] = set()
        piano_anni: dict[str, dict] = {}
        tutti_anno: dict[int, set] = {}
        for k in range(1, durata + 1):
            sc = piano(k)
            if not sc:
                continue
            y, x, d = sc
            piano_anni[str(k)] = {"coorte": y, "url": f"{base}/corsi/{y}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or [] if any(_vale(a, k) for a in p.get("anni") or [])]
            nomi = {id(p): nome_percorso(p) for p in percorsi_k}
            senza_nome = [p for p in percorsi_k if not nomi[id(p)]]
            con_nome = [p for p in percorsi_k if nomi[id(p)]]
            alt = False
            if senza_nome and con_nome and all(p.get("comune") for p in con_nome):
                # due percorsi «comuni» con contenuti diversi (ACE Program): percorsi alternativi, non un comune con aggiunte
                alt = True
            if alt:
                for p in senza_nome:
                    nomi[id(p)] = ALT_BASE.get(catena[0], "Percorso base")
                comuni, specifici = [], percorsi_k
            else:
                comuni, specifici = senza_nome, con_nome
            if not comuni and len({nomi[id(p)] for p in specifici}) < 2:
                comuni, specifici = percorsi_k, []  # un solo percorso: vale per tutti
            tutti_anno[k] = {nomi[id(p)] for p in specifici}
            percorsi_nomi |= tutti_anno[k]
            for p in percorsi_k:
                pcur = None if p in comuni else nomi[id(p)]
                for a in p.get("anni") or []:
                    if not _vale(a, k):
                        continue
                    for g in _gruppi(a):
                        atts = [t for t in g.get("attivita") or [] if (t.get("crediti") or 0) > 0]
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            obbl = _obbligatorio(g, att)
                            key = f"{k}:{ad}:{att.get('crediti'):g}"
                            st = stati.setdefault(key, {})
                            st[pcur] = st.get(pcur, False) or obbl
                            if key in insegnamenti:
                                continue
                            docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                            item = {
                                "codice": ad, "nome": _titolo(att.get("des_it") or ad), "anno": k,
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
                riga["curriculum"] = None if (not tutti or (cur_set == tutti and len(per_valore) == 1)) \
                    else ", ".join(sorted(cur_set))
                riga["_orig"] = item
                ins.append(riga)
        # stesso nome nello stesso anno con codici e CFU diversi (alternative omonime, segnaposto dei crediti all'estero):
        # il nome porta i CFU o il codice
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if len({i["cfu"] for i in gruppo_i}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo_i}) == len(gruppo_i) \
                    and len({i["cfu"] for i in gruppo_i}) == len(gruppo_i):
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            else:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['codice']})"
        # il nome di un segnaposto all'estero non ripete gli asterischi e li distingue per codice anche da solo
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/luiss.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


# Nome del percorso senza nome quando due percorsi «comuni» sono alternativi: (codice del corso) → nome
ALT_BASE: dict[str, str] = {"L25BA": "Senza ACE Program", "L21BA": "Senza ACE Program"}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "luiss.json", ROOT / "database" / "contrib" / "auto" / "luiss_syl_b2.json"):
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


def fetch_ateneo(uid: str = "luiss", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "luiss.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[luiss] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
