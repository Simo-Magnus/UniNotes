"""Università degli Studi di Bari Aldo Moro: insegnamenti e libri dal Course Catalogue Cineca.

`https://uniba.coursecatalogue.cineca.it` pubblica piani di studio e syllabus; il sito
uniba.it è protetto da Radware Bot Manager (CAPTCHA) e non si usa. Rispetto all'adattatore
comune (`cineca_catalogue`) questo adattatore:

- tiene le risposte su disco (variabile d'ambiente UN_HTTP_CACHE, cartella «uniba»): una
  raccolta interrotta riparte da dove era;
- lega ai corsi di Universitaly quelli del catalogo che il confronto per nome e classe non
  associa (stessa laurea in sedi diverse, es. «Economia aziendale - Brindisi» e il corso
  «Economia aziendale» di Brindisi in Universitaly): imposta `id_universitaly`, così
  build_db unisce i piani invece di lasciare un corso senza insegnamenti;
- per i syllabus il cui campo «testi» non ha riferimenti riconoscibili dall'estrazione comune
  (nessun editore o anno) tiene le righe che sono riferimenti, con la citazione com'è;
- legge i piani da sé (`_fetch_piani`), anno per anno: la durata è quella del piano («5 anni»;
  l'elenco minimale non l'ha e prima tutti i corsi avevano 3 anni, senza il 4°-6° anno dei cicli unici);
  il codice del corso cambia con il riordino (7743 → 7743-R) e la coorte precedente si ritrova senza
  il suffisso o per nome, sede e tipo; le coorti con il piano non diviso per anno («altreAttivita»)
  assegnano l'anno dall'anno di erogazione (`aa` - coorte + 1); se il piano della coorte è parziale
  (meno di 60 CFU nell'anno) si prende quello più completo dello stesso ordinamento; i gruppi a scelta
  senza elenco («Insegnamenti a scelta (12 CFU)») diventano una voce a scelta con i CFU dell'etichetta.
"""
from __future__ import annotations

import concurrent.futures as cf
import copy
import hashlib
import html
import json
import os
import pathlib
import re
import time
import unicodedata

from . import ammissione
from . import cineca_catalogue as cc
from .testi import _libero, html_to_lines

BASE = "https://uniba.coursecatalogue.cineca.it"

# codice del corso nel catalogo → id dei corsi del database a cui va il piano. Serve dove il
# confronto di build_db per nome e classe sbaglia: la stessa laurea in sedi diverse ha lo stesso
# nome (Giurisprudenza a Bari e a Taranto, Medicina, Farmacia), e Universitaly elenca anche corsi
# gemelli che il catalogo non distingue («Economia aziendale» a Bari e a Brindisi).
ID_CORSI = {
    "11434": ["uniba-l-18-economia-aziendale"],
    "11435": ["uniba-l-18-economia-aziendale-brindisi", "uniba-l-18-economia-aziendale-1629863"],
    "11466": ["uniba-l-31-informatica-e-tecnologie-dell-informazione-taranto",
              "uniba-l-31-informatica-e-tecnologie-dell-informazione"],
    "11422": ["uniba-lm-13-farmacia"],
    "11468": ["uniba-lm-13-farmacia-taranto"],
    "11423": ["uniba-lm-13-farmacia-1634825"],
    "11459": ["uniba-lmg-01-giurisprudenza"],
    "11460": ["uniba-lmg-01-giurisprudenza-gia-giurisprudenza-d-impresa", "uniba-lmg-01-giurisprudenza-1634842"],
    "11485": ["uniba-lmg-01-giurisprudenza-1635005"],
    "11450": ["uniba-lm-41-medicina-e-chirurgia-1635021"],
    "11658": ["uniba-lm-41-medicina-e-chirurgia-replica-taranto"],
    "11455": ["uniba-lm-41-medicine-and-surgery-medicina-e-chirurgia-in-lingua-inglese",
              "uniba-lm-41-medicina-e-chirurgia"],
}
# corsi di Universitaly senza un corso omonimo nel catalogo
ID_UNIVERSITALY = {
    "11657": "1625605",   # Tecniche di radiologia medica
    "11659": "1625604",   # Scienze e tecniche dello sport (LM-67/LM-68)
}


class ClientConCache(cc.Client):
    """Course Catalogue con cache su disco."""

    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "uniba" if d else None

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


# Righe che non sono un libro: materiale del docente, indicazioni «durante le lezioni», rimandi
_NON_LIBRO = re.compile(
    r"(?i)durante (le|il) (lezion|corso)|\bverr[àa]\b|\bverranno\b|\bsar[àa]\b|\bsaranno\b|\bslides?\b|\blucidi\b|"
    r"\bdispense\b|\bmateriale\b|\bappunti\b|\bfornit|\bindicat|\bqualsias|\bqualunque\b|\ba scelta\b|"
    r"\bdisponibil|\breperibil|\bconsult|\bnon (è|e'|sono) previst|\bnessun|\bnel corso\b|\bsul sito\b|"
    r"\bmoodle\b|\bpiattaforma\b|\bteams\b|\bda definire\b|\bda concordare\b|\bdel docente\b|"
    r"\b(textbook|book|books|manual)s? (will|is|are)\b|\bsee the\b|\bany manual\b|\b(è|nato|scaricabil\w*|citat[ae]|possono|devono|può)\b|:\s*$")
_CONTINUA = re.compile(r"^(?:(?i:aut\.|autori?\b|casa editrice|editore|a cura di|eds?[.:]|edited by|curato da)|[a-zà-ÿ(])")


def libri_testo_libero(sy: dict) -> list[dict]:
    """Per i syllabus in cui l'estrazione comune non riconosce nulla: ogni riga del campo
    «testi» che sembra un riferimento (non una frase come «materiale fornito dal docente»)
    è un libro, con la citazione così com'è nel syllabus."""
    out, viste = [], set()
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if not (isinstance(v, str) and re.search(r"(^|_)testi_it$", k)):
                continue
            righe: list[str] = []
            for r in html_to_lines(v):
                if righe and _CONTINUA.match(r):
                    righe[-1] += " " + r
                else:
                    righe.append(r)
            for r in righe:
                if _NON_LIBRO.search(r) or not 12 <= len(r) <= 400 or len(r.split()) < 4:
                    continue
                if not re.search(r"[A-ZÀ-Ý]", r):
                    continue
                b = _libero(r)
                key = re.sub(r"\W+", "", b["citazione"].lower())[:120]
                if key not in viste:
                    viste.add(key)
                    out.append(b)
    return out


def _durata(det: dict, tipo: str | None) -> int:
    """Durata legale dal piano («5 anni»): l'elenco minimale del catalogo non ha `durataAnni`."""
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _cod_base(cds: str | None) -> str:
    """Il codice del corso cambia con il riordino («7743» → «7743-R»): senza il suffisso è lo stesso corso."""
    return re.sub(r"-R$", "", (cds or "").strip().upper())


_CFU_ETICHETTA = re.compile(r"\(\s*(\d+)\s*CFU\s*\)", re.I)
# gruppi del piano senza elenco di insegnamenti ma con i CFU nell'etichetta: attività a scelta dello studente,
# altre attività («Insegnamenti a scelta (12 CFU)»); le etichette come «LM 5 CFU 12 (12 CFU)» sono varianti di una
# stessa scelta e non si contano
_GRUPPO_LIBERO = re.compile(r"(?i)\bscelta\b|altre attivit|\bliber[eao]\b|crediti liberi")


def _voci_anno(det: dict, y: int, durata: int, usa_aa: bool = True):
    """Voci del piano di una coorte: (anno di corso, percorso, gruppo, attività).

    L'anno è quello della sezione del piano; nelle coorti in cui il catalogo non divide il piano per
    anno («altreAttivita», es. 2026) si ricava dall'anno accademico di erogazione (`aa`) meno la coorte, ma solo
    per la coorte che si iscrive ora (`usa_aa`): nelle coorti passate le attività portano l'`aa` dell'offerta
    attuale, non quello della coorte (Fisioterapia 2024: il 1° anno ha `aa` 2025), e l'anno sarebbe sbagliato.
    Un gruppo senza attività elencate («Insegnamenti a scelta (12 CFU)») dà una voce con attività None.
    Le attività di «altreAttivita» già nelle sezioni per anno dello stesso percorso sono doppioni."""
    out = []
    for p in det.get("percorsi") or []:
        pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        con_anno = set()
        for a in p.get("anni") or []:
            if str(a.get("anno")).isdigit():
                for g in a.get("insegnamenti") or [{"attivita": a.get("attivita") or []}]:
                    con_anno |= {att.get("adCod") or att.get("cod") for att in g.get("attivita") or []}
        for a in p.get("anni") or []:
            digit = str(a.get("anno")).isdigit()
            gruppi = a.get("insegnamenti") or ([{"label_it": "", "attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                atts = g.get("attivita") or []
                if digit and not atts and g.get("label_it"):
                    out.append((int(a["anno"]), pnome, g, None))
                visti = set()
                for att in atts:
                    ad = att.get("adCod") or att.get("cod")
                    if digit:
                        out.append((int(a["anno"]), pnome, g, att))
                        continue
                    if ad in con_anno or (ad, att.get("aa")) in visti:
                        continue
                    visti.add((ad, att.get("aa")))
                    try:
                        k = int(att.get("aa")) - y + 1 if usa_aa else None
                    except (TypeError, ValueError):
                        k = None
                    out.append((k if k and 1 <= k <= durata else None, pnome, g, att))
    return out


def _punteggio(voci: list, k: int) -> float:
    """CFU dell'anno k in un piano (una volta per attività; i gruppi a scelta senza elenco con i CFU dell'etichetta)."""
    visti, tot = set(), 0.0
    for kk, _, g, att in voci:
        if kk != k:
            continue
        if att is None:
            m = _CFU_ETICHETTA.search(g.get("label_it") or "")
            libero = bool(m and _GRUPPO_LIBERO.search(g.get("label_it") or ""))
            chiave, cfu = ("#", g.get("label_it")), (float(m.group(1)) if libero else 0.0)
        else:
            chiave, cfu = att.get("adCod") or att.get("cod"), att.get("crediti")
        if chiave not in visti and isinstance(cfu, (int, float)):
            visti.add(chiave)
            tot += cfu
    return tot


def _coorte_anno(cohorts: dict, voci: dict, k: int, anno: int) -> int | None:
    """Coorte da cui leggere l'anno k: quella degli iscritti all'anno k oggi (anno-k+1), se il suo piano ha
    quell'anno e arriva a 60 CFU. Altrimenti, nello stesso ordinamento, la coorte più vicina con un piano più
    completo (il catalogo pubblica alcune coorti solo in parte); se la coorte non ha l'anno, la più vicina
    che lo ha (di preferenza con almeno 60 CFU)."""
    y0 = anno - k + 1
    ha = {y: _punteggio(v, k) for y, v in voci.items() if any(x[0] == k and x[3] is not None for x in v)}
    if not ha:
        return None
    vicine = sorted(ha, key=lambda y: (abs(y - y0), -y))
    if y0 in ha:
        if ha[y0] >= 60:
            return y0
        ord0 = cohorts[y0][1].get("ordinamento_aa")
        # un piano molto parziale (meno di mezzo anno: es. un solo insegnamento dell'ordinamento appena
        # pubblicato) si sostituisce anche con quello di un altro ordinamento
        meglio = [y for y in vicine if y != y0 and ha[y] > ha[y0]
                  and (cohorts[y][1].get("ordinamento_aa") == ord0 or ha[y0] < 30)]
        pieni = [y for y in meglio if ha[y] >= 60]
        if pieni:
            return pieni[0]
        return max(meglio, key=lambda y: (ha[y], -abs(y - y0))) if meglio else y0
    pieni = [y for y in vicine if ha[y] >= 60]
    return (pieni or vicine)[0]


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, solo_syllabus: set | None = None,
                 anni_precedenti: bool = False) -> dict:
    """Piani di studio dal catalogo, un anno di corso alla volta.

    Per l'anno k si usa il piano della coorte anno-k+1; il codice del corso cambia da una coorte
    all'altra (7743 → 7743-R: si riconosce senza il suffisso o per nome, sede e tipo). Se quella coorte
    non ha voci per quell'anno (corso nuovo, offerta non ancora pubblicata, piano senza ripartizione per
    anno) si prende il piano della coorte più vicina che le ha, di solito la più recente. La durata è
    quella del piano (le lauree magistrali a ciclo unico hanno 5-6 anni, non 3).

    `solo_syllabus`: insieme di codici di attività (adCod); se dato, si leggono i syllabus solo di quelle
    (per riempire i libri di insegnamenti nuovi senza rileggere tutto il catalogo).
    `anni_precedenti`: per gli insegnamenti la cui scheda dell'anno corrente non ha libri si legge la scheda
    degli anni accademici precedenti (stesso codice di attività, piano di un'altra coorte); i libri portano in
    `note` l'anno e l'indirizzo della scheda usata."""
    base = BASE
    c = ClientConCache(BASE)
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 5, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y)]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            d = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(d, list):
                d = d[0] if d else None
            dettagli[k] = d
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        for x in elenco:
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]):
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        return stessi[0] if len(stessi) == 1 else None

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    alt_jobs: list[tuple[dict, dict]] = []
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}  # coorte → (riga dell'elenco, dettaglio)
        for y in range(anno - 5, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        voci = {y: _voci_anno(d, y, durata, usa_aa=(y == anno)) for y, (_, d) in cohorts.items()}
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        classe_dettaglio = rec[1].get("classe_cod")
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")
        for k in range(1, durata + 1):
            scelta = _coorte_anno(cohorts, voci, k, anno)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            n_percorsi = len(d.get("percorsi") or [])
            nomi_coorte = {(p.get("des_it") or p.get("pdsDes") or "").strip() for p in d.get("percorsi") or []}
            for kk, pnome, g, att in voci[scelta]:
                if kk != k and not (kk is None and k == durata):
                    continue
                gruppo = (g.get("label_it") or "").lower()
                obbl = "obbligator" in gruppo or g.get("cod") == "OO"
                if att is None:  # gruppo a scelta senza attività elencate: i CFU sono nell'etichetta
                    m = _CFU_ETICHETTA.search(g.get("label_it") or "")
                    if not m or not _GRUPPO_LIBERO.search(g.get("label_it") or ""):
                        continue
                    nome = cc._titolo(_CFU_ETICHETTA.sub(" ", g["label_it"]).strip(" -"))
                    key = f"{k}:#{_norm(nome)}"
                    item = insegnamenti.get(key)
                    if not item:
                        item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": int(m.group(1)),
                                "ssd": None, "obbligatorio": False, "curriculum": None, "_percorsi": set(),
                                "_tutti": nomi_coorte, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                "libri": [], "esami": [], "fonte": base, "verificato_il": oggi}
                        insegnamenti[key] = item
                else:
                    ad = att.get("adCod") or att.get("cod")
                    key = f"{kk}:{ad}"
                    item = insegnamenti.get(key)
                    if not item:
                        docenti = [cc._nome(x_.get("des")) for x_ in att.get("docenti") or [] if x_.get("des")]
                        item = {
                            "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": kk,
                            "periodo": cc._periodo(att.get("periodo_didattico_it")),
                            "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                            "periodo_fine": att.get("data_fine_periodo_didattico"),
                            "cfu": att.get("crediti"), "ssd": None,
                            "obbligatorio": (obbl or att.get("tipo_ins_cod") == "OBB") and kk is not None,
                            "curriculum": None, "_percorsi": set(), "_tutti": nomi_coorte,
                            "docenti": sorted(set(docenti)),
                            "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                   f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                            "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                        }
                        insegnamenti[key] = item
                        if syllabus and (solo_syllabus is None or ad in solo_syllabus):
                            syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                           "ordinamento_aa": att.get("ordinamento_aa"),
                                           "af_percorso": att.get("corso_percorso_id"),
                                           "corso_cod": att.get("corso_cod"), "corso_aa": scelta,
                                           "schema_id": att.get("schemaId")},
                                "items": []})["items"].append(item)
                if n_percorsi > 1 and pnome:
                    item["_percorsi"].add(pnome)
                    percorsi_nomi.add(pnome)
        if anni_precedenti and syllabus:
            for item in insegnamenti.values():
                ad = item.get("codice")
                if not ad or (solo_syllabus is not None and ad not in solo_syllabus):
                    continue
                alts: dict = {}
                for y, vv in voci.items():
                    for _, _, _, att in vv:
                        if att is None or (att.get("adCod") or att.get("cod")) != ad:
                            continue
                        try:
                            aa = int(att.get("aa"))
                        except (TypeError, ValueError):
                            continue
                        if aa >= anno:
                            continue
                        alts.setdefault((aa, str(att.get("cod")), str(att.get("corso_percorso_id"))), {
                            "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                       "ordinamento_aa": att.get("ordinamento_aa"),
                                       "af_percorso": att.get("corso_percorso_id"),
                                       "corso_cod": att.get("corso_cod"), "corso_aa": y,
                                       "schema_id": att.get("schemaId")},
                            "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                   f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}"})
                if alts:
                    alt_jobs.append((item, alts))
        ins = list(insegnamenti.values())
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        return {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or classe_dettaglio),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

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
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, legati = cc._testi_syllabus(sy)
        if not libri:  # testi in forma libera
            libri = libri_testo_libero(sy)
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
            if i % 1000 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")

    def libri_di(sy: dict) -> list[dict]:
        libri = cc._testi_syllabus(sy)[0]
        if not libri:
            libri = libri_testo_libero(sy)
        if not libri:
            for u in cc._testi_syllabus(sy)[2]:
                libri += cc.leganto.libri(u)
        return libri

    def do_alt(entry: tuple[dict, dict]) -> int:
        item, alts = entry
        try:
            for (aa, _, _), a in sorted(alts.items(), key=lambda kv: -kv[0][0]):
                sy = c.get("/insegnamento", {k: v for k, v in a["params"].items() if v not in (None, "")})
                libri = libri_di(sy) if isinstance(sy, dict) else []
                if libri:
                    nota = (f"Dal programma dell'a.a. {aa}/{(aa + 1) % 100:02d}: la scheda {anno}/{(anno + 1) % 100:02d} "
                            f"non riporta la bibliografia. {a['url']}")
                    item["libri"] = [{**b, "note": f"{b['note']} {nota}" if b.get("note") else nota} for b in libri]
                    item["stato_libri"] = "completo"
                    return len(libri)
        except Exception:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            pass
        return 0

    if alt_jobs:
        da_fare = [e for e in alt_jobs if not e[0]["libri"]]
        log(f"[{uid}] schede degli anni precedenti da leggere: {len(da_fare)}")
        trovati = 0
        with cf.ThreadPoolExecutor(8) as ex:
            for i, n in enumerate(ex.map(do_alt, da_fare), 1):
                trovati += n
        log(f"[{uid}] libri dagli anni precedenti: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print,
                 solo_syllabus: set | None = None, anni_precedenti: bool = False) -> dict:
    doc = _fetch_piani(uid, anno, max_cds, syllabus, log, solo_syllabus, anni_precedenti)
    for c in doc["corsi"]:  # alcuni syllabus hanno le entità HTML annidate («&amp;#39;»)
        for ins in c.get("insegnamenti") or []:
            for b in ins.get("libri") or []:
                for k in ("titolo", "autori", "editore", "citazione"):
                    v = b.get(k)
                    while isinstance(v, str) and "&" in v and html.unescape(v) != v:
                        v = html.unescape(v)
                    b[k] = v
    corsi = []
    for c in doc["corsi"]:
        cod = str(c.get("url") or "").rsplit("/", 1)[-1]
        if cod in ID_CORSI:  # una copia del piano per ogni corso del database (id esplicito)
            corsi += [{**copy.deepcopy(c), "id": i} for i in ID_CORSI[cod]]
        else:
            if cod in ID_UNIVERSITALY:
                c["id_universitaly"] = ID_UNIVERSITALY[cod]
            corsi.append(c)
    copie = [c for c in corsi if c.get("id") or c.get("id_universitaly")]
    doc["corsi"] = corsi
    log(f"[{uid}] corsi del database legati per id: {len(copie)}")
    return doc
