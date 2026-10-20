"""IULM (Milano): piani di studio, syllabus e libri dal Course Catalogue Cineca, completati dalle pagine dei corsi.

Piani e syllabus: `https://iulm.coursecatalogue.cineca.it` (API pubblica, coorti 2022-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (tabella `CORSI`): con i riordini del 2025 (L-12 R, L-20 R, ...) i codici del
  catalogo sono cambiati (Interpretariato e comunicazione 59 → Mediazione, interpretariato e comunicazione interculturale
  361, Traduzione specialistica 64 → Traduzione, interpretariato e comunicazione digitale 360, ...) e le coorti precedenti
  stanno sotto il codice vecchio. Per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al
  k-esimo anno) col primo codice della catena che ha quell'anno. Il catalogo pubblica per ogni coorte gli anni già attivati
  (la 2026 ha solo il 1° anno): senza l'anno si ripiega sulla coorte più vicina che lo ha (non succede nell'a.a. 2026/27);
- durata dal tipo del catalogo (L 3, LM 2): l'elenco minimale non ha `durataAnni` e il comune la fissava a 3 anni anche per
  le lauree magistrali;
- insegnamenti integrati: il catalogo li pubblica come «raggruppamento esami» a 0 CFU (`adFiglie`) con i moduli, che hanno
  i CFU e il proprio docente, come righe distinte dello stesso piano. Il contenitore non è un insegnamento a CFU: si tolgono
  le righe a 0 CFU (nel catalogo IULM sono tutte contenitori) e i moduli tengono i propri CFU; i libri di un modulo senza
  programma sono quelli del contenitore (nota nel libro);
- percorsi: ogni coorte ha percorsi con nomi diversi («I ANNO CIRP», «CCPR - I ANNO», «III ANNO - CORPORATE …»,
  «II anno Florida»): la tabella `PERCORSI` li riconduce al curriculum (nome come nella pagina del corso) o a nessuno (piano
  comune a tutti i curricula);
- gruppi del piano (`cod`): «OO» obbligatori; «F» e «W» a scelta («attività a scelta consigliate», «IULM for the City»). Una
  attività è obbligatoria se il catalogo la segna «OBB» e il gruppo è «OO»;
- il catalogo non ha le attività che la pagina «Piano di studi» del corso elenca a parte: crediti a scelta dello studente,
  stage, field project, prova finale (le lauree magistrali: 12 CFU). Si aggiungono da `EXTRA` (valori letti dalle pagine
  del corso su www.iulm.it, «Piano degli studi consigliato», con la pagina come fonte) per l'anno, il curriculum e i CFU
  che la pagina indica;
- stesso codice obbligatorio in un percorso e a scelta in un altro: due righe (build_db le tiene separate se i curricula
  sono disgiunti), altrimenti una sola, obbligatoria;
- alternative omonime nello stesso anno e curriculum: con CFU diversi il nome porta i CFU, altrimenti il codice;
- libri: quelli già raccolti per lo stesso codice nel database non si rileggono; gli altri dal syllabus (testi, testi liberi,
  Leganto, scheda di un'altra coorte dello stesso insegnamento).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco (`iulm_cc`).
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/iulm.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/iulm.py [--senza-syllabus]
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

BASE = "https://iulm.coursecatalogue.cineca.it"
SITO = "https://www.iulm.it/it/offerta-formativa"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L", "LM"}
DURATA = {"L": 3, "LM": 2}

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio, pagina del
# piano di studi del corso su www.iulm.it).
CORSI: list[tuple[str, tuple[str, ...], str]] = [
    ("1626872", ("361", "59"), "corsi-di-lauree-triennali/interpretariato-comunicazione"),                     # L-12
    ("1626875", ("362", "232"), "corsi-di-lauree-triennali/comunicazione-impresa-relazioni-pubbliche"),         # L-20
    ("1626870", ("363", "318", "175"), "corsi-di-lauree-triennali/arti-eventi-culturali"),                      # L-3
    ("1626874", ("364", "60"), "corsi-di-lauree-triennali/comunicazione-media-pubblicita"),                     # L-20
    ("1626873", ("365", "250", "176"), "corsi-di-lauree-triennali/turismo-management-cultura"),                 # L-15
    ("1626869", ("366", "251"), "corsi-di-lauree-triennali/moda-e-industrie-creative"),                         # L-3
    ("1626871", ("388", "288"), "corsi-di-lauree-triennali/lingue-cultura-e-comunicazione-digitale"),           # L-11
    ("1626882", ("330",), "corsi-di-lauree-magistrali/fashion-communication-and-luxury-strategies"),          # LM-92
    ("1626883", ("360", "64"), "corsi-di-lauree-magistrali/traduzione-interpretariato-comunicazione-digitale"),  # LM-94
    ("1626879", ("368", "68"), "corsi-di-lauree-magistrali/televisione-cinema-new-media"),                     # LM-65
    ("1626881", ("369", "259"), "corsi-di-lauree-magistrali/intelligenza-artificiale-impresa-societa"),         # LM-91
    ("1626876", ("373", "173"), "corsi-di-lauree-magistrali/hospitality-tourism-management"),                  # LM-49
    ("1626878", ("374", "174"), "corsi-di-lauree-magistrali/strategic-communication"),                         # LM-59
    ("1626877", ("384", "84"), "corsi-di-lauree-magistrali/marketing-consumi-comunicazione"),                   # LM-59
    ("1626880", ("396", "196"), "corsi-di-lauree-magistrali/arte-valorizzazione-mercato"),                      # LM-89
]

# Nome del percorso del catalogo → curriculum (nome come nella pagina del corso). None: piano comune a tutti i curricula;
# una tupla: curricula a cui si applica. Si prova nell'ordine; un nome non riconosciuto resta un curriculum a sé.
_MCC_IT = ("Brand Management", "Digital Marketing Management", "Retail Management")
PERCORSI: dict[str, list[tuple[str, object]]] = {
    "361": [(r"interpretariato e tecniche", "Interpretariato e tecniche della traduzione"),
            (r"mediazione linguistica per il marketing", "Mediazione linguistica per il marketing e le aziende"),
            (r"lingue emergenti", "Lingue emergenti e competenze multiculturali"),
            (r"", None)],
    "362": [(r"CCPR|CORPORATE", "Corporate Communication and Public Relations"),
            (r"", "Comunicazione d'impresa e relazioni pubbliche")],
    "365": [(r"comunicazione del turismo|comunicazione e cultura", "Comunicazione del turismo"),
            (r"management e organizzazione", "Management e organizzazione per il turismo"),
            (r"", None)],
    "366": [(r"industrie creative", "Industrie creative e design"), (r"^moda$", "Moda"), (r"", None)],
    "330": [(r"global", "Global Trends"), (r"luxury", "Luxury Strategies"), (r"", None)],
    "360": [(r"trad", "Traduzione editoriale e multimediale"),
            (r"interpretariato", "Interpretariato di conferenza e nuove tecnologie")],
    "368": [(r"cinema", "Cinema e nuove tecnologie"), (r"new media", "New media - musica e racconti digitali"),
            (r"cross media", "Televisione e cross media"), (r"", None)],
    "373": [(r"florida", "Hospitality and Tourism Management (University of Central Florida)"),
            (r"digital", "Digital technologies and data for tourism and creative industries"),
            (r"sustainable", "Sustainable destination management and communication"), (r"", None)],
    "374": [(r"corporate", "Corporate Communication"), (r"sustainability", "Sustainability Communication"), (r"", None)],
    "384": [(r"brand", "Brand Management"), (r"digital marketing", "Digital Marketing Management"),
            (r"retail", "Retail Management"),
            (r"consumer behaviour", "Marketing - Consumer Behaviour and Communication"),
            (r"consumi", _MCC_IT)],
}
ENG_MCC = "Marketing - Consumer Behaviour and Communication"

# Attività della pagina «Piano di studi» del corso che il catalogo non ha: codice → (nome, obbligatoria).
VOCI = {"SCELTA": ("Attività formative a scelta dello studente", False), "PF": ("Prova finale", True),
        "STAGE": ("Stage", True), "FIELD": ("Field project", True), "FIELDWORK": ("Fieldwork", True),
        "WORKEXP": ("Work experience", True)}

# (codice del corso, anno, curriculum o tupla di curricula o None, codice della voce, CFU). Valori letti dalla pagina
# «Piano di studi» del corso su www.iulm.it («Piano degli studi consigliato»: righe «Attività formative a scelta», «Stage…»,
# «Field project», «Fieldwork», «Prova finale»).
EXTRA: list[tuple[str, int, object, str, int]] = [
    ("361", 2, None, "SCELTA", 6), ("361", 3, None, "SCELTA", 6), ("361", 3, None, "PF", 6),
    ("362", 2, None, "SCELTA", 12), ("362", 3, None, "SCELTA", 6), ("362", 3, None, "PF", 6),
    ("363", 1, None, "SCELTA", 6), ("363", 2, None, "SCELTA", 6), ("363", 3, None, "SCELTA", 6),
    ("363", 3, None, "PF", 6),
    ("364", 2, None, "SCELTA", 12), ("364", 3, None, "SCELTA", 6), ("364", 3, None, "PF", 6),
    ("365", 2, None, "SCELTA", 6), ("365", 3, None, "STAGE", 6),
    ("365", 3, ("Comunicazione del turismo", "Management e organizzazione per il turismo"), "SCELTA", 12),
    ("365", 3, ("Comunicazione del turismo", "Management e organizzazione per il turismo"), "PF", 3),
    ("366", 2, None, "SCELTA", 12), ("366", 3, None, "SCELTA", 6), ("366", 3, None, "PF", 6),
    ("388", 1, None, "SCELTA", 3), ("388", 2, None, "SCELTA", 3), ("388", 3, None, "SCELTA", 6), ("388", 3, None, "PF", 6),
    ("330", 2, None, "FIELD", 6), ("330", 2, None, "SCELTA", 12), ("330", 2, None, "PF", 12),
    ("360", 1, None, "SCELTA", 9), ("360", 2, None, "WORKEXP", 3), ("360", 2, None, "PF", 12),
    ("368", 1, None, "SCELTA", 6), ("368", 2, None, "SCELTA", 6), ("368", 2, None, "STAGE", 3), ("368", 2, None, "PF", 12),
    ("369", 1, None, "SCELTA", 6), ("369", 2, None, "SCELTA", 6), ("369", 2, None, "FIELDWORK", 6),
    ("369", 2, None, "STAGE", 6), ("369", 2, None, "PF", 12),
    ("373", 2, None, "SCELTA", 9), ("373", 2, None, "FIELD", 3), ("373", 2, None, "PF", 12),
    ("374", 1, None, "SCELTA", 6), ("374", 2, None, "SCELTA", 6), ("374", 2, None, "FIELD", 6), ("374", 2, None, "PF", 12),
    ("384", 1, None, "SCELTA", 6),
    ("384", 2, _MCC_IT, "SCELTA", 6), ("384", 2, _MCC_IT, "STAGE", 6), ("384", 2, _MCC_IT, "FIELDWORK", 6),
    ("384", 2, _MCC_IT, "PF", 12),
    ("384", 2, (ENG_MCC,), "STAGE", 6), ("384", 2, (ENG_MCC,), "FIELDWORK", 6), ("384", 2, (ENG_MCC,), "PF", 12),
    ("396", 2, None, "SCELTA", 12), ("396", 2, None, "PF", 12),
]
_SMALL = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al", "alla",
          "alle", "ai", "agli", "il", "la", "lo", "le", "gli", "i", "nel", "nella", "nelle", "nei", "sul", "sulla", "tra",
          "fra", "o", "su", "dal", "dalla", "and", "of", "the", "to", "for", "on", "with", "an", "or", "at", "by", "from",
          "as", "its", "into", "in"}
_SIGLE = {"AI", "IA", "ICT", "IT", "EU", "UE", "US", "UK", "UX", "UI", "HR", "PR", "CSR", "SEO", "IULM", "UCF", "ESG"}
_ROMANO = re.compile(r"[ivx]{1,4}")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


_ACCENTI = {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}
_TOKEN = re.compile(r"[A-Za-zÀ-ÿ]+(?:'[A-Za-zÀ-ÿ]+)?'?")


def _titolo(des: str | None) -> str:
    """Nome dell'attività. Il catalogo scrive in maiuscolo (anche «COMUNICARE L'ARTE - Modulo»), con l'apostrofo al posto
    dell'accento («PUBBLICITA'»): iniziali maiuscole, parole brevi minuscole, sigle e numeri romani maiuscoli, accenti."""
    des = re.sub(r"\s+", " ", (des or "")).strip()
    lettere = [ch for ch in des if ch.isalpha()]
    if not lettere or sum(ch.isupper() for ch in lettere) < 0.6 * len(lettere):
        # nomi già in minuscolo/maiuscolo misto: solo l'accento scritto come apostrofo («Pubblicita'» → «Pubblicità»)
        return re.sub(r"(?<=[A-Za-zÀ-ÿ])([aeiouAEIOU])'(?![A-Za-zÀ-ÿ])",
                      lambda m: _ACCENTI[m.group(1).lower()] if m.group(1).islower() else _ACCENTI[m.group(1).lower()].upper(), des)
    primo = [True]

    def fix(m: re.Match) -> str:
        t = m.group(0)
        era_primo, primo[0] = primo[0], False
        accento = t.endswith("'") and len(t) > 3 and t[-2].lower() in _ACCENTI  # apostrofo finale = accento
        if accento:
            t = t[:-1]
        if "'" in t:
            a, _, b = t.lower().partition("'")
            r = a + "'" + b[:1].upper() + b[1:]
        elif t.upper() in _SIGLE:
            r = t.upper()
        elif not era_primo and _ROMANO.fullmatch(t.lower()):
            r = t.upper()
        elif not era_primo and t.lower() in _SMALL:
            r = t.lower()
        else:
            r = t.lower()[:1].upper() + t.lower()[1:]
        return r[:-1] + _ACCENTI[r[-1].lower()] if accento else r

    return _TOKEN.sub(fix, des)


def _periodo(s: str | None) -> str | None:
    return cc._periodo(s)


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/iulm_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "iulm_cc" if d else None

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


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _vale(a: dict, k: int) -> bool:
    return str(a.get("anno")).isdigit() and int(a["anno"]) == k


def _ha_anno(det: dict, k: int) -> bool:
    """Il piano ha attività con CFU (anche solo nei moduli) per l'anno di corso k."""
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            if _vale(a, k):
                for g in _gruppi(a):
                    if any((t.get("crediti") or 0) > 0 for t in g.get("attivita") or []):
                        return True
    return False


def _obbligatorio(g: dict, att: dict) -> bool:
    tipo = (att.get("tipo_ins_cod") or "").strip().upper()
    if g.get("cod") == "OO":
        return tipo != "OPZ"
    return tipo == "OBB"


def _curricula(codice_corso: str, nome_percorso: str) -> tuple[tuple[str, ...] | None, bool]:
    """Curricula a cui vale un percorso del catalogo (None: tutti) e se il nome è riconosciuto dalla tabella."""
    tab = PERCORSI.get(codice_corso)
    if tab is None:
        return None, True
    for rx, cur in tab:
        if re.search(rx, nome_percorso, re.I):
            if cur is None:
                return None, True
            return (cur if isinstance(cur, tuple) else (cur,)), True
    n = nome_percorso.strip()
    return (n[:1].upper() + n[1:],) if n else None, False


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - 4, anno + 1):
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

    def build(id_ul: str, catena: tuple[str, ...], pagina: str) -> dict | None:
        cohorts: dict[int, list[tuple[dict, dict]]] = {}
        for y in range(anno - 4, anno + 1):
            lst = []
            for cod in catena:
                x = coorti.get(y, {}).get(cod)
                d = dettaglio(y, x) if x else None
                if d:
                    lst.append((x, d))
            if lst:
                cohorts[y] = lst
        if not cohorts or anno not in cohorts:
            return None
        cur, rec_d = cohorts[anno][0]
        durata = DURATA[cur.get("tipo_corso_cod")]
        amm = ammissione.da_catalogo(rec_d, f"{base}/corsi/{anno}/{cur['cod']}")
        url_piano = f"{SITO}/{pagina}/piano-di-studi"

        def piano(k: int):
            """(coorte, riga dell'elenco, dettaglio) da cui leggere l'anno di corso k: la coorte A-k+1 e, se non ha quell'anno,
            la più vicina che lo ha."""
            y0 = anno - k + 1
            for y in sorted(cohorts, key=lambda y: (abs(y - y0), -y)):
                for x, d in cohorts[y]:
                    if _ha_anno(d, k):
                        return y, x, d
            return None

        # moduli di ogni contenitore (a 0 CFU) e contenitore di ogni modulo, per codice
        padre_di: dict[str, dict] = {}
        for lst in cohorts.values():
            for _x, d in lst:
                for p in d.get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in _gruppi(a):
                            for t in g.get("attivita") or []:
                                if not (t.get("crediti") or 0) and t.get("adFiglie"):
                                    for f in t["adFiglie"]:
                                        padre_di.setdefault(f.get("adCod"), t)

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
        curricula_tutti: set[str] = set()
        piano_anni: dict[str, dict] = {}
        tutti_anno: dict[int, set] = {}
        sconosciuti: set[str] = set()
        for k in range(1, durata + 1):
            sc = piano(k)
            if not sc:
                continue
            y, x, d = sc
            piano_anni[str(k)] = {"coorte": y, "url": f"{base}/corsi/{y}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or [] if any(_vale(a, k) for a in p.get("anni") or [])]
            cur_di = {}
            for p in percorsi_k:
                nome_p = (p.get("des_it") or p.get("pdsDes") or "").strip()
                cur_di[id(p)], noto_p = _curricula(catena[0], nome_p)
                if not noto_p:
                    sconosciuti.add(nome_p)
            tutti_anno[k] = {n for p in percorsi_k for n in (cur_di[id(p)] or ())}
            curricula_tutti |= tutti_anno[k]
            for p in percorsi_k:
                for a in p.get("anni") or []:
                    if not _vale(a, k):
                        continue
                    for g in _gruppi(a):
                        for att in g.get("attivita") or []:
                            cfu = att.get("crediti") or 0
                            if cfu <= 0:  # contenitore di moduli: i CFU sono nei moduli
                                continue
                            ad = att.get("adCod") or att.get("cod")
                            obbl = _obbligatorio(g, att)
                            key = f"{k}:{ad}:{cfu:g}"
                            st = stati.setdefault(key, {})
                            for cn in (cur_di[id(p)] or (None,)):
                                st[cn] = st.get(cn, False) or obbl
                            if key in insegnamenti:
                                continue
                            docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                            item = {
                                "codice": ad, "nome": _titolo(att.get("des_it") or ad), "anno": k,
                                "periodo": _periodo(att.get("periodo_didattico_it")),
                                "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                "periodo_fine": att.get("data_fine_periodo_didattico"),
                                "cfu": cfu, "ssd": None,
                                "obbligatorio": False, "curriculum": None,
                                "docenti": sorted(set(docenti)),
                                "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                       f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                                "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                            }
                            insegnamenti[key] = item
                            if syllabus:
                                padre = padre_di.get(ad)
                                syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                    "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                               "ordinamento_aa": att.get("ordinamento_aa"),
                                               "af_percorso": att.get("corso_percorso_id"),
                                               "corso_cod": att.get("corso_cod"), "corso_aa": y,
                                               "schema_id": att.get("schemaId")},
                                    "items": [], "codice": ad,
                                    "padre": (padre.get("adCod"), _titolo(padre.get("des_it"))) if padre else None,
                                    "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                                        alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                                        if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                                })["items"].append(item)
        # voci della pagina del corso che il catalogo non ha (crediti a scelta, stage, prova finale)
        for cod_c, k, curs, voce, cfu in EXTRA:
            if cod_c != catena[0] or k > durata:
                continue
            nome_v, obbl = VOCI[voce]
            if curs is not None and not set(curs) <= (tutti_anno.get(k) or set()) | curricula_tutti:
                log(f"[{uid}]   {cod_c}: curricula {curs} della voce {voce} non nel piano")
            key = f"{k}:{voce}:{cfu:g}"
            st = stati.setdefault(key, {})
            for cn in (curs if curs is not None else (None,)):
                st[cn] = st.get(cn, False) or obbl
            insegnamenti.setdefault(key, {
                "codice": voce, "nome": nome_v, "anno": k, "periodo": None, "cfu": cfu, "ssd": None,
                "obbligatorio": False, "curriculum": None, "docenti": [], "url": url_piano,
                "libri": [], "esami": [], "stato_libri": "nessun_libro", "fonte": url_piano, "verificato_il": oggi})
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
                riga["curriculum"] = None if (not tutti or (cur_set == tutti and len(per_valore) == 1)) \
                    else ", ".join(sorted(cur_set))
                riga["_orig"] = item
                ins.append(riga)
        # stesso codice con CFU diversi nello stesso anno (ids di build_db: codice): il codice porta i CFU
        per_cod: dict[tuple, set] = {}
        for i in ins:
            per_cod.setdefault((i["anno"], i["codice"]), set()).add(i["cfu"])
        for i in ins:
            if len(per_cod[(i["anno"], i["codice"])]) > 1:
                i["codice"] = f"{i['codice']}_{i['cfu']:g}cfu"
        # stesso nome nello stesso anno e curriculum con codici diversi (alternative omonime): il nome porta i CFU o il codice
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if len({i["cfu"] for i in gruppo_i}) == len(gruppo_i):
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            else:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['codice']})"
        if sconosciuti:
            log(f"[{uid}]   {catena[0]}: percorsi non riconosciuti {sorted(sconosciuti)}")
        out = {
            "id_universitaly": id_ul,
            "nome": _titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec_d.get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": catena[0],
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "url_piano": url_piano,
            "curricula": sorted(curricula_tutti) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        return out

    def build_safe(r) -> dict | None:
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
        if not libri and job.get("padre"):  # modulo di un insegnamento integrato: il programma è quello del contenitore
            cod_p, nome_p = job["padre"]
            noto_p = libri_noti.get(cod_p)
            if noto_p and noto_p.get("libri"):
                libri = noto_p["libri"]
                modalita = modalita or noto_p.get("modalita_esame")
                nota = f"Programma dell'insegnamento integrato «{nome_p}» (codice {cod_p}), di cui è modulo"
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
            if i % 200 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    for corso_ in corsi_out:
        for riga in corso_["insegnamenti"]:
            orig = riga.pop("_orig", None)
            if orig is not None:
                for k_ in ("libri", "stato_libri", "modalita_esame", "ssd", "url_sito"):
                    if k_ in orig:
                        riga[k_] = orig[k_]
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/iulm.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "iulm.json", ROOT / "database" / "contrib" / "auto" / "iulm_syl_b2.json",
              ROOT / "database" / "contrib" / "auto" / "iulm.json"):
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


def fetch_ateneo(uid: str = "iulm", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "iulm.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[iulm] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
