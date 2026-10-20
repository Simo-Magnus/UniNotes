"""Università della Valle d'Aosta: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://univda.coursecatalogue.cineca.it` (API pubblica, coorti 2022-2026). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (tabella `CORSI`): con il riordino 2025 i codici del catalogo cambiano
  (Economia e management C06 > C07, Lingue E02 > E03, Scienze e tecniche psicologiche D03 > D05, Scienze politiche
  F02 > F03, LM-56 G01 > G02) e il comune creava due corsi per codice, mescolati nello stesso corso di Universitaly.
  Per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno) col primo
  codice della catena che ha quell'anno (le pagine «Piano di studi» di univda.it pubblicano un PDF per coorte con gli
  stessi piani e i totali per anno);
- durata dalla tabella: l'elenco minimale non ha la durata e il comune ripiegava su 3 anni, così Scienze della
  formazione primaria (5 anni) aveva solo i primi tre anni;
- percorsi: «Piano di studi approvato / consigliato / (vuoto)» sono l'unico piano del corso, non curricula; «Piano di
  studi proposto» è la variante senza l'elenco degli opzionali (un gruppo «S» di opzionali liberi, senza attività) del
  piano approvato e si salta; i percorsi veri (Economia e management: «Analisi dei sistemi economici» e «Gestione
  delle imprese»; LM-56: «Mercato e impresa» e «Sviluppo del territorio») prendono il nome della coorte più recente,
  senza il prefisso «Piano di studi … Curriculum»; «comune» ha solo «altreAttivita»;
- «altreAttivita»: elenco di quanto è erogato nell'a.a. (anche i doppi diplomi L12AV/L12CH, vecchi piani SPO_SZ/SPO_CH,
  moduli S_… degli esami da 12 CFU, esercitazioni e precorsi a 0 CFU, un modulo «Quantitative Methods» con 45 CFU), senza
  anno di corso: non fa parte del piano e non si legge (le attività di quel piano sono già negli anni 1-5);
- gruppi del piano (`cod`): «OO» obbligatori, «F» a scelta; le attività «A scelta dello studente» del catalogo (segnaposto
  OPZIONALI, BLOCCO OPZIONALI, INSEGNAMENTI OPZIONALI: i CFU a libera scelta dell'anno) sono voci a scelta anche se nel
  gruppo «Obbligatori»; stesso per «Opzionali 4 anno» di Scienze della formazione primaria;
- stesso codice obbligatorio in un curriculum e a scelta in un altro: due righe (build_db le tiene separate se i curricula
  sono disgiunti), altrimenti una sola, obbligatoria;
- alternative omonime nello stesso anno e curriculum: con CFU diversi il nome porta i CFU, altrimenti il codice;
- libri: quelli già raccolti per lo stesso codice nel database non si rileggono; gli altri dal syllabus (testi, testi
  liberi, Leganto, scheda di un'altra coorte dello stesso insegnamento).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco (`univda_cc`).
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/univda.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/univda.py [--senza-syllabus]
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

BASE = "https://univda.coursecatalogue.cineca.it"
SITO = "https://www.univda.it/didattica"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0

# Corsi di Universitaly dell'a.a. 2026/27: (id Universitaly, codici del catalogo dal più recente al più vecchio, durata,
# pagina «Piano di studi» del corso su www.univda.it).
CORSI: list[tuple[str, tuple[str, ...], int, str]] = [
    ("1627479", ("C07", "C06"), 3,        # L-18 Economia e management
     "dipartimento-di-scienze-economiche-e-politiche/offerta-formativa/corso-di-laurea-in-economia-e-management/piano-di-studi/"),
    ("1627478", ("E03", "E02"), 3,        # L-12 Lingue e comunicazione per l'impresa e il turismo
     "dipartimento-di-scienze-umane-e-sociali/offerta-formativa/corso-di-laurea-in-lingue-e-comunicazione-per-limpresa-e-il-turismo/piano-di-studi-pdf-scaricabili/"),
    ("1627480", ("D05", "D03"), 3,        # L-24 Scienze e tecniche psicologiche
     "dipartimento-di-scienze-umane-e-sociali/offerta-formativa/corso-di-laurea-in-scienze-e-tecniche-psicologiche/piani-di-studio-pdf-scaricabili/"),
    ("1627481", ("F03", "F02"), 3,        # L-36 Scienze politiche e delle relazioni internazionali
     "dipartimento-di-scienze-economiche-e-politiche/offerta-formativa/corso-di-laurea-in-scienze-politiche-e-delle-relazioni-internazionali/piano-di-studi-pdf-scaricabili/"),
    ("1627482", ("G02", "G01"), 2,        # LM-56 Economia e politiche del territorio e dell'impresa
     "dipartimento-di-scienze-economiche-e-politiche/offerta-formativa/corso-di-laurea-magistrale-in-economia-e-politiche-del-terriotorio-e-dellimpresa/piano-di-studi-pdf-scaricabili/"),
    ("1627477", ("A05",), 5,              # LM-85 bis Scienze della formazione primaria
     "dipartimento-di-scienze-umane-e-sociali/offerta-formativa/corso-di-laurea-magistrale-in-scienze-della-formazione-primaria/piano-di-studi-pdf-scaricabili/"),
]

# Anno di corso per cui si legge una coorte diversa da A-k+1: (id Universitaly, anno) → coorte. Il catalogo della coorte 2024
# di Scienze della formazione primaria omette per il 3° anno il «Tirocinio 4 CFU» (SED T14) che hanno le coorti 2022, 2025 e
# 2026 (a 57 CFU invece di 61), mentre il PDF ufficiale del piano 2024/25 (univda.it, «Piano di studi») dà «Totale crediti terzo
# anno: 61» e ha il «Tirocinio III anno»: si usa il piano della coorte 2025, identico a parte quel tirocinio.
PIANO_COORTE: dict[tuple[str, int], int] = {("1627477", 3): 2025}
# Il 4° anno di Scienze della formazione primaria si legge dalla coorte 2024 (la 2023 è incompleta nel catalogo), ma l'insegnamento
# opzionale da 8 CFU della coorte 2023 (quella che lo frequenta ora) è «Educazione ed espressività: gioco e lettura» (SED 171, gruppo
# «Opz consigliato» del catalogo e PDF ufficiale 2023/24), non il segnaposto «Opzionali 4 anno 8 CFU» (SED 9999) delle coorti
# successive: (id Universitaly, anno) → (coorte, codici da aggiungere dalla coorte, codici del piano scelto da non usare).
PIANO_RETTIFICHE: dict[tuple[str, int], tuple[int, tuple[str, ...], tuple[str, ...]]] = {
    ("1627477", 4): (2023, ("SED 171",), ("SED 9999",)),
}

SALTA = "__salta__"
# Nome del percorso del catalogo (senza «Piano di studi [approvato|consigliato|proposto] [-] [Curriculum]») → curriculum con il
# nome della coorte più recente. Un nome vuoto è l'unico piano del corso (nessun curriculum). SALTA: non è un curriculum.
ALIAS_CURRICULA = {
    "gestione imprese": "Gestione delle imprese",
    "economia e gestione delle imprese": "Gestione delle imprese",
    "economia e analisi dei sistemi economici": "Analisi dei sistemi economici",
}

PERIODI = {"primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale",
           "primo e secondo semestre": "annuale"}
VOCE_SCELTA_RX = re.compile(r"^(blocco |insegnamenti? )?opzional[ei]\b", re.I)
PAROLE_STRANIERE = {"de", "en", "y", "et", "el", "los", "las", "durch", "die", "und", "des", "du"}


def _nome(des: str | None) -> str:
    t = _titolo(des)
    t = re.sub(r"\bCfu\b", "CFU", t)
    t = re.sub(r"\bTpv\b", "TPV", t)
    t = re.sub(r"(?<=[a-z])' (?=[A-Z])", "'", t)  # «dell' Unione» → «dell'Unione»
    t = re.sub(r"(?<=\s)(" + "|".join(PAROLE_STRANIERE) + r")\b", lambda m: m.group(1).lower(), t, flags=re.I)
    t = re.sub(r"(?<= - )il\b", "Il", t)
    t = re.sub(r"(?<=: )the\b", "The", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t[:1].upper() + t[1:]


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return PERIODI.get(s.strip().lower()) or cc._periodo(s)


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/univda_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "univda_cc" if d else None

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
    """L'elenco dei percorsi di un insegnamento è separato da virgole (app e build_db): nel nome del curriculum non ce ne sono."""
    return re.sub(r"\s*,\s*", " ", nome).strip()


def _curriculum(nome_percorso: str) -> tuple[str | None, bool]:
    """(curriculum, riconosciuto). None: unico piano del corso; SALTA: non è un piano; il nome ripulito del curriculum."""
    n = re.sub(r"\s+", " ", nome_percorso or "").strip()
    if re.fullmatch(r"(?i)comune", n) or re.search(r"(?i)\bproposto\b", n):
        return SALTA, True
    n = re.sub(r"(?i)^piano di studi\b\s*(approvato|consigliato)?\s*[-–]?\s*", "", n)
    n = re.sub(r"(?i)^curri\w+\s+", "", n).strip()  # (anche «Curridulum Internazionale», refuso del catalogo 2025)
    if not n:
        return None, True
    alias = ALIAS_CURRICULA.get(n.lower())
    return _senza_virgole(alias or (n[:1].upper() + n[1:])), True


def _obbligatorio(g: dict, att: dict) -> bool:
    if g.get("cod") != "OO":
        return False
    if (att.get("tipo_ins_cod") or "").strip().upper() == "OPZ":
        return False
    if (att.get("tafDes_it") or "").strip().lower() == "a scelta dello studente":
        return False  # CFU a libera scelta (segnaposto OPZIONALI, stage)
    return not VOCE_SCELTA_RX.match(re.sub(r"\s+", " ", att.get("des_it") or "").strip())


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
        url_piano = f"{SITO}/{pagina}"
        cod0 = catena[0]

        def cfu_anno(d: dict, k: int) -> float:
            """CFU dell'anno k del piano (il percorso più ricco, senza i piani «proposto»)."""
            best = 0.0
            for p in d.get("percorsi") or []:
                if _curriculum((p.get("des_it") or p.get("pdsDes") or "").strip())[0] == SALTA:
                    continue
                for a in p.get("anni") or []:
                    if _vale(a, k):
                        best = max(best, sum((t.get("crediti") or 0) for g in _gruppi(a) for t in g.get("attivita") or []))
            return best

        def piano(k: int):
            """(coorte, riga dell'elenco, dettaglio) da cui leggere l'anno di corso k: la coorte A-k+1 e, se non ha quell'anno
            o ne ha solo una parte (il catalogo ha, per esempio, il 4° anno di Scienze della formazione primaria della coorte
            2023 con 3 attività e 23 CFU su 62), la più vicina che lo ha completo (almeno 3/4 dei CFU della coorte più ricca)."""
            y0 = PIANO_COORTE.get((id_ul, k), anno - k + 1)
            cand = [(y, x, d, cfu_anno(d, k)) for y in cohorts for x, d in cohorts[y] if _ha_anno(d, k)]
            if not cand:
                return None
            massimo = max(c_[3] for c_ in cand)
            cand = [c_ for c_ in cand if c_[3] >= 0.75 * massimo]
            y, x, d, _ = min(cand, key=lambda c_: (abs(c_[0] - y0), -c_[0]))
            return y, x, d

        # attività dello stesso codice in altre coorti, per codice (per i libri)
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

        def aggiungi(k, y, att, obbl, cur_set):
            cfu = att.get("crediti") or 0
            if cfu <= 0:  # attività senza crediti (precorsi, esercitazioni): non fanno parte del piano
                return
            ad = att.get("adCod") or att.get("cod")
            key = f"{k}:{ad}:{cfu:g}"
            st = stati.setdefault(key, {})
            for cn in (cur_set or (None,)):
                st[cn] = st.get(cn, False) or obbl
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

        for k in range(1, durata + 1):
            sc = piano(k)
            if not sc:
                continue
            y, x, d = sc
            rettifica = PIANO_RETTIFICHE.get((id_ul, k), (None, (), ()))
            piano_anni[str(k)] = {"coorte": y, "url": f"{base}/corsi/{y}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or [] if any(_vale(a, k) for a in p.get("anni") or [])]
            cur_di = {id(p): _curriculum((p.get("des_it") or p.get("pdsDes") or "").strip())[0] for p in percorsi_k}
            tutti_anno[k] = {cur_di[id(p)] for p in percorsi_k if cur_di[id(p)] not in (SALTA, None)}
            curricula_tutti |= tutti_anno[k]
            for p in percorsi_k:
                cn = cur_di[id(p)]
                if cn == SALTA:
                    continue
                for a in p.get("anni") or []:
                    if not _vale(a, k):
                        continue
                    for g in _gruppi(a):
                        for att in g.get("attivita") or []:  # i gruppi «S» (opzionali liberi) non hanno attività
                            if (att.get("adCod") or att.get("cod")) in rettifica[2]:
                                continue
                            aggiungi(k, y, att, _obbligatorio(g, att), {cn} if cn else None)
            if rettifica[1]:  # attività della coorte indicata, a scelta
                for _x2, d2 in cohorts.get(rettifica[0], []):
                    for p2 in d2.get("percorsi") or []:
                        for a2 in p2.get("anni") or []:
                            if _vale(a2, k):
                                for g2 in _gruppi(a2):
                                    for att in g2.get("attivita") or []:
                                        if (att.get("adCod") or att.get("cod")) in rettifica[1]:
                                            aggiungi(k, rettifica[0], att, False, None)
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
        return {
            "id_universitaly": id_ul,
            "nome": _nome(cur.get("des_it") or ""),
            "classe": re.sub(r"[\s,]+$", "", cc._classe(cur.get("classe_cod") or rec_d.get("classe_cod")) or "")
            .replace(" BIS", " bis"),
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
            if i % 100 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    for corso_ in corsi_out:
        for riga in corso_["insegnamenti"]:
            orig = riga.pop("_orig", None)
            if orig is not None:
                for k_ in ("libri", "stato_libri", "modalita_esame", "ssd", "url_sito"):
                    if k_ in orig:
                        riga[k_] = orig[k_]
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/univda.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "univda.json", ROOT / "database" / "contrib" / "auto" / "univda_syl_b2.json",
              ROOT / "database" / "contrib" / "auto" / "univda.json"):
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


def fetch_ateneo(uid: str = "univda", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "univda.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[univda] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
