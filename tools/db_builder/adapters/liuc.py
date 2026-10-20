"""LIUC Università Cattaneo (Castellanza): piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://liuc.coursecatalogue.cineca.it` (API pubblica, coorti 2022-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (tabella `CORSI`): con i riordini i codici del catalogo cambiano per coorte
  (Economia e Management L18A > L18B > L18C, Ingegneria Gestionale L09A > L09B, Economia, Management e Governance
  LM77A > LM77B > LM77C) e il comune creava anche corsi a parte («... - Classe L-9 R», «... - Classe Lm-77 R»,
  «... - Classe Lm-31») accanto a quelli di Universitaly. Per l'anno di corso k nell'a.a. A si legge il piano della coorte
  A-k+1 (gli iscritti oggi al k-esimo anno) col primo codice della catena che ha quell'anno;
- durata dalla tabella (L 3 anni, LM 2): l'elenco minimale non ha la durata;
- insegnamenti integrati: il catalogo li pubblica come contenitori a 0 CFU con i moduli (che hanno i CFU) come righe
  distinte dello stesso piano. Il contenitore non è un insegnamento a CFU: si tolgono le righe a 0 CFU (anche
  «Learning to Learn» e «Information Literacy», consigliati e senza crediti) e i moduli tengono i propri CFU; i libri di un
  modulo senza programma sono quelli del contenitore (nota nel libro);
- percorsi (nomi senza virgole, che separano i percorsi di un insegnamento): ogni coorte ha percorsi con nomi che cambiano («BAM - Doing business with data» > «BAM - Data Management»,
  «Direzione d'Impresa» > «Management e consulenza aziendale»): la tabella `PERCORSI` li riconduce al nome della coorte
  più recente; i percorsi «SUA», «Percorso in Lingua Italiana», «Piano personalizzato» e «comune» (solo «altreAttivita»,
  senza anno) non sono curricula; «X SUA» di Economia, Management e Governance è l'elenco degli insegnamenti a scelta;
- gruppi del piano (`cod`): «OO» obbligatori; «F», «W» e «S» a scelta. Il catalogo chiama «Obbligatori» anche gruppi
  che sono elenchi di alternative (insegnamenti in italiano e in inglese, lingue, stage o insegnamenti sostitutivi): si
  segnano obbligatori solo quelli di `GRUPPI_OBBLIGATORI` (Dual Degree, riscontrati sul piano di studi ufficiale);
- le regole «S» senza elenco («(16) a scelta (fra 1 e 20 CFU)») sono i crediti a scelta dello studente: una voce a scelta
  con i CFU tra parentesi, nell'ultimo anno (la regola è ripetuta nei due anni, i CFU sono quelli del biennio);
- stesso codice obbligatorio in un percorso e a scelta in un altro: due righe (build_db le tiene separate se i curricula
  sono disgiunti), altrimenti una sola, obbligatoria;
- alternative omonime nello stesso anno e curriculum: con CFU diversi il nome porta i CFU, altrimenti il codice;
- lingua dell'attività (`lingua`: «it»/«en», da `lingua_cod`) e gruppi in cui è a scelta (`gruppo_scelta`): con questi
  `pulizia.varianti_lingua_scelta` unisce la versione italiana e quella inglese dello stesso esame offerte nello stesso gruppo;
- libri: quelli già raccolti per lo stesso codice nel database non si rileggono; gli altri dal syllabus (testi, testi liberi,
  Leganto, scheda di un'altra coorte dello stesso insegnamento).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco (`liuc_cc`).
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/liuc.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/liuc.py [--senza-syllabus]
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

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .iulm import _gruppi, _ha_anno, _norm, _titolo, _un, _vale  # noqa: E402
from .uniba import libri_testo_libero  # noqa: E402

BASE = "https://liuc.coursecatalogue.cineca.it"
SITO = "https://www.liuc.it/corsi-di-studio"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio, durata,
# pagina del corso su www.liuc.it).
CORSI: list[tuple[str, tuple[str, ...], int, str]] = [
    ("1635102", ("L18C", "L18B", "L18A"), 3, "laurea-triennale/economia-aziendale"),                      # L-18
    ("1635101", ("L09B", "L09A"), 3, "laurea-triennale/ingegneria-gestionale"),                           # L-9
    ("1635099", ("LM77C", "LM77B", "LM77A"), 2, "laurea-magistrale/economia-aziendale-e-management"),     # LM-77
    ("1635100", ("LM31B",), 2, "laurea-magistrale/ingegneria-gestionale-laurea-magistrale"),              # LM-31
]

SALTA = "__salta__"
POOL = "__pool__"
# Nome del percorso del catalogo (spazi ridotti, senza maiuscole) → curriculum con il nome della coorte più recente.
# SALTA: non è un curriculum; POOL: elenco degli insegnamenti a scelta. Un nome non riconosciuto resta un curriculum a sé.
PERCORSI: dict[str, list[tuple[str, str]]] = {
    "L18C": [(r"^x?\s*sua$", SALTA), (r"^comune$", SALTA),
             (r"^bam\s*-\s*general", "BAM - General"),
             (r"^bam\s*-\s*international", "BAM - International Management"),
             (r"^bam\s*-\s*(data|doing)", "BAM - Data Management"),
             (r"^be\s*-\s*general", "BE - General"),
             (r"^be\s*-\s*international", "BE - International Management"),
             (r"^be\s*-\s*tourism", "BE - Tourism and hospitality management"),
             (r"^be\s*-\s*(data|doing)", "BE - Data management"),
             (r"^(data management|doing business with data)$", "Data Management"),
             (r"^accounting", "Accounting and Finance"),
             (r"^comunicazione", "Comunicazione, marketing e new media"),
             (r"^international management", "International Management"),
             (r"^management (&|and) entrepreneurship", "Management & Entrepreneurship"),
             (r"^management della musica", "Management della musica e entertainment"),
             (r"^management dello sport", "Management dello sport e degli eventi sportivi"),
             (r"^tourism", "Tourism and hospitality management"),
             (r"^ita\s*-\s*management", "ITA - Management")],
    "L09B": [(r"^sua$", SALTA), (r"^comune$", SALTA), (r"^percorso in lingua italiana$", SALTA),
             (r"^business design", "Business Design Era Digitale"),
             (r"^industrial operational", "Industrial Operational Excellence"),
             (r"^operational excellence", "Operational Excellence Industriale")],
    "LM77C": [(r"^x\s*sua$", POOL), (r"^piano personalizzato$", SALTA), (r"^comune$", SALTA),
              (r"^direzione d.impresa", "Management e consulenza aziendale"),
              (r"^international economics", "International Business Management"),
              (r"^dual degree", "Dual Degree in Business and Engineering")],
    "LM31B": [(r"^comune$", SALTA),
              (r"^gestione integrata delle aziende e dei servizi in", "Gestione Integrata delle Aziende e dei Servizi in Sanità")],
}

# Gruppi «W»/«F» del catalogo che sono davvero obbligatori: (codice del corso, etichetta senza maiuscole). Riscontrati sul
# piano di studi ufficiale del Dual Degree (https://www.liuc.it/wp-content/uploads/Piano-studi_Dual-Degree.pdf): Project
# Management e Supply chain design al 1° anno, Management Information Systems, Industrial Design e Sustainability in
# Industrial Systems al 2°.
GRUPPI_OBBLIGATORI = {("LM77C", "i anno obbligatori dual - ing"), ("LM77C", "ii anno obbligatori dual - ing")}

# Attività di gruppi «F» che il piano di studi ufficiale 2026/27 dà obbligatorie (le altre del gruppo sono le versioni in inglese
# degli stessi insegnamenti, le alternative «o» e gli insegnamenti sostitutivi dello stage): (codice del corso, etichetta senza
# maiuscole) → codici delle attività.
#  - L-18, percorso Management, 3° anno: Gestione finanziaria delle imprese, Economia pubblica, Strategia e politica aziendale,
#    Tolerance to Stress (https://www.liuc.it/wp-content/uploads/Piano-studi_LT-ECO_Management.pdf; «Diritto tributario o Diritto
#    dell'UE» è un'alternativa);
#  - L-9, Operational excellence industriale, 3° anno: Gestione e controllo dei processi aziendali, Prova finale, Logistica,
#    Gestione dell'impresa sostenibile, Sistemi di produzione, Lean in produzione, Design e gestione della qualità
#    (https://www.liuc.it/wp-content/uploads/Piano_studi_LT-ING_percorso_ITA.pdf).
CODICI_OBBLIGATORI: dict[tuple[str, str], set[str]] = {
    ("L18C", "iii anno obbligatori ita (26 cfu)"): {"A01040", "A83501", "A88700", "A01010"},
    ("L18B", "iii anno obbligatori ita (26 cfu)"): {"A01040", "A83501", "A88700", "A01010"},
    ("L09B", "obbligatori 3 anno - operational excellence"): {"N90305", "N90392", "N91445", "N91552", "N91488", "N91489", "N91533"},
    ("L09A", "obbligatori 3 anno - operational excellence"): {"N90305", "N90392", "N91445", "N91552", "N91488", "N91489", "N91533"},
}

PERIODI = {"primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale",
           "primo e secondo semestre": "annuale"}
VOCE_SCELTA = "Attività formative a scelta dello studente"


def _nome(des: str | None) -> str:
    t = _titolo(des)
    t = re.sub(r"\bM&a\b", "M&A", t)
    t = re.sub(r"\bAi\b", "AI", t)
    return t


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return PERIODI.get(s.strip().lower()) or cc._periodo(s)


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/liuc_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "liuc_cc" if d else None

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


def _senza_virgole(nome: str) -> str:
    """L'elenco dei percorsi di un insegnamento è separato da virgole (app e build_db): nel nome del curriculum non ce ne sono
    («Amministrazione, Finanza e Controllo» → «Amministrazione Finanza e Controllo»)."""
    return re.sub(r"\s*,\s*", " ", nome).strip()


def _curriculum(cod: str, nome_percorso: str) -> tuple[str | None, bool]:
    """(curriculum, riconosciuto): SALTA/POOL per i percorsi che non lo sono; se il nome non è nella tabella resta un curriculum."""
    n = re.sub(r"\s+", " ", nome_percorso or "").strip()
    for rx, cur in PERCORSI.get(cod, []):
        if re.search(rx, n, re.I):
            return (cur if cur in (SALTA, POOL) else _senza_virgole(cur)), True
    return (_senza_virgole(n[:1].upper() + n[1:]) if n else None), False


def _obbligatorio(cod_corso: str, g: dict, att: dict) -> bool:
    if g.get("cod") == "OO":
        return (att.get("tipo_ins_cod") or "").strip().upper() != "OPZ"
    chiave = (cod_corso, re.sub(r"\s+", " ", (g.get("label_it") or "")).strip().lower())
    return chiave in GRUPPI_OBBLIGATORI or (att.get("adCod") or att.get("cod")) in CODICI_OBBLIGATORI.get(chiave, ())


def _cfu_regola(g: dict) -> float | None:
    """CFU della regola di scelta libera senza elenco: «(16) a scelta (fra 1 e 20 CFU)» → 16."""
    m = re.match(r"\s*\((\d+)\)", g.get("label_it") or "")
    return float(m.group(1)) if m else None


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - 4, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y)}
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

    def build(id_ul: str, catena: tuple[str, ...], durata: int, pagina: str) -> dict | None:
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
        amm = ammissione.da_catalogo(rec_d, f"{base}/corsi/{anno}/{cur['cod']}")
        url_piano = f"{SITO}/{pagina}/"
        cod0 = catena[0]

        def piano(k: int):
            """(coorte, riga dell'elenco, dettaglio) da cui leggere l'anno di corso k: la coorte A-k+1 e, se non ha quell'anno,
            la più vicina che lo ha."""
            y0 = anno - k + 1
            for y in sorted(cohorts, key=lambda y: (abs(y - y0), -y)):
                for x, d in cohorts[y]:
                    if _ha_anno(d, k):
                        return y, x, d
            return None

        # contenitore (a 0 CFU) di ogni modulo e attività dello stesso codice in altre coorti, per codice
        padre_di: dict[str, dict] = {}
        alt_per_ad: dict[str, dict] = {}
        for y, lst in cohorts.items():
            for _x, d in lst:
                for p in d.get("percorsi") or []:
                    for a in p.get("anni") or []:
                        for g in _gruppi(a):
                            for t in g.get("attivita") or []:
                                if not (t.get("crediti") or 0) and t.get("adFiglie"):
                                    for f in t["adFiglie"]:
                                        padre_di.setdefault(f.get("adCod"), t)
                                alt_per_ad.setdefault(t.get("adCod") or t.get("cod"), {})[(str(t.get("aa")), str(t.get("cod")))] = (y, t)

        insegnamenti: dict[str, dict] = {}
        stati: dict[str, dict[str | None, bool]] = {}  # (anno:codice:cfu) → {curriculum o None se comune: obbligatorio}
        gruppi_sc: dict[str, set] = {}  # (anno:codice:cfu) → gruppi del piano in cui è a scelta
        curricula_tutti: set[str] = set()
        piano_anni: dict[str, dict] = {}
        tutti_anno: dict[int, set] = {}
        sconosciuti: set[str] = set()

        def aggiungi(k, y, att, obbl, cur_set, gs=None):
            cfu = att.get("crediti") or 0
            if cfu <= 0:  # contenitore di moduli o attività senza crediti: i CFU sono nei moduli
                return
            ad = att.get("adCod") or att.get("cod")
            key = f"{k}:{ad}:{cfu:g}"
            st = stati.setdefault(key, {})
            for cn in (cur_set or (None,)):
                st[cn] = st.get(cn, False) or obbl
            if gs and not obbl:  # gruppo del piano in cui l'attività è a scelta
                gruppi_sc.setdefault(key, set()).add(gs)
            if key in insegnamenti:
                return
            docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
            item = {
                "codice": ad, "nome": _nome(att.get("des_it") or ad), "anno": k,
                "periodo": _periodo(att.get("periodo_didattico_it")),
                "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                "periodo_fine": att.get("data_fine_periodo_didattico"),
                "cfu": cfu, "ssd": None, "obbligatorio": False, "curriculum": None,
                "docenti": sorted(set(docenti)),
                "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                       f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
            }
            if cc.lingua_attivita(att):  # lingua dell'attività: «it»/«en»
                item["lingua"] = cc.lingua_attivita(att)
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
                    "padre": (padre.get("adCod"), _nome(padre.get("des_it"))) if padre else None,
                    "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                        alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                        if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                })["items"].append(item)

        regole: dict[int, dict[float, set]] = {}  # anno → CFU della scelta libera → curricula
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
                cur_di[id(p)], noto_p = _curriculum(cod0, nome_p)
                if not noto_p:
                    sconosciuti.add(nome_p)
            tutti_anno[k] = {cur_di[id(p)] for p in percorsi_k if cur_di[id(p)] not in (SALTA, POOL)}
            curricula_tutti |= tutti_anno[k]
            for p in percorsi_k:
                cn = cur_di[id(p)]
                if cn == SALTA:
                    continue
                for a in p.get("anni") or []:
                    if not _vale(a, k):
                        continue
                    for g in _gruppi(a):
                        if g.get("cod") == "S" and not g.get("attivita"):
                            cfu_r = _cfu_regola(g)
                            if cfu_r and cn != POOL:
                                regole.setdefault(k, {}).setdefault(cfu_r, set()).add(cn)
                            continue
                        for att in g.get("attivita") or []:
                            obbl = False if cn == POOL else _obbligatorio(cod0, g, att)
                            aggiungi(k, y, att, obbl, None if cn == POOL else {cn}, cc.gruppo_scelta(g, att, p, a.get("anno")))
        # crediti a scelta dello studente (regola «S» senza elenco), nell'ultimo anno del corso
        if durata in regole:
            k = durata
            for cfu_r, cur_set in sorted(regole[k].items()):
                key = f"{k}:SCELTA:{cfu_r:g}"
                st = stati.setdefault(key, {})
                for cn in cur_set:
                    st[cn] = False
                insegnamenti.setdefault(key, {
                    "codice": "SCELTA", "nome": VOCE_SCELTA, "anno": k, "periodo": None, "cfu": cfu_r, "ssd": None,
                    "obbligatorio": False, "curriculum": None, "docenti": [],
                    "url": piano_anni[str(k)]["url"], "libri": [], "esami": [], "stato_libri": "nessun_libro",
                    "fonte": piano_anni[str(k)]["url"], "verificato_il": oggi})
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
                if not v and gruppi_sc.get(key):
                    riga["gruppo_scelta"] = ",".join(sorted(gruppi_sc[key]))
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
            log(f"[{uid}]   {cod0}: percorsi non riconosciuti {sorted(sconosciuti)}")
        return {
            "id_universitaly": id_ul,
            "nome": _nome(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec_d.get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cod0,
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "url_piano": url_piano,
            "curricula": sorted(curricula_tutti) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/liuc.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "liuc.json", ROOT / "database" / "contrib" / "auto" / "liuc_syl_b2.json",
              ROOT / "database" / "contrib" / "auto" / "liuc.json"):
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


def fetch_ateneo(uid: str = "liuc", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "liuc.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[liuc] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
