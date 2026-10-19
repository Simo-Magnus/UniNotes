"""Insegnamenti, docenti, modalità d'esame e libri dal Course Catalogue Cineca.

Molti atenei pubblicano l'offerta didattica su `<ateneo>.coursecatalogue.cineca.it`
con un'API JSON pubblica (la stessa usata dal sito):

- `GET /api/v1/corsi?anno=<coorte>&minimal=true` → corsi di studio della coorte
- `GET /api/v1/corso/<coorte>/<cod>`              → percorsi → anni → insegnamenti
- `GET /api/v1/insegnamento?anno=…&insegnamento=…&corso_cod=…` → syllabus (testi)

Per l'anno di corso k nell'a.a. A si usa il piano della coorte A-k+1 (gli
iscritti al 2° anno nel 2026/27 seguono il piano della coorte 2025).
"""
from __future__ import annotations

import ast
import concurrent.futures as cf
import re
import threading
import time
from typing import Any

import requests

from . import ammissione, leganto
from .testi import estrai_libri

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
           "Accept": "application/json"}
PERIODI = {"primo semestre": "1", "secondo semestre": "2", "annuale": "annuale", "primo periodo": "1",
           "secondo periodo": "2", "terzo periodo": "3", "primo trimestre": "1", "secondo trimestre": "2",
           "terzo trimestre": "3", "1 semestre": "1", "2 semestre": "2"}


class Client:
    def __init__(self, base: str, rate: float = 8.0):
        self.base = base.rstrip("/") + "/api/v1"
        self.s = requests.Session()
        self.lock = threading.Lock()
        self.min_gap = 1.0 / rate
        self.last = 0.0
        self.requests = 0

    def get(self, path: str, params: dict | None = None) -> Any:
        for attempt in range(4):
            with self.lock:
                wait = self.last + self.min_gap - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                self.last = time.monotonic()
                self.requests += 1
            try:
                r = self.s.get(self.base + path, params=params, headers=HEADERS, timeout=90)
                if r.status_code == 404:
                    return None
                r.raise_for_status()
                return r.json()
            except (requests.RequestException, ValueError):
                time.sleep(2 ** attempt)
        return None


def _walk_cds(x, out):
    if isinstance(x, dict):
        if "cdsCod" in x and "aa" in x and "cod" in x and "des_it" in x:
            out.append(x)
        for v in x.values():
            _walk_cds(v, out)
    elif isinstance(x, list):
        for v in x:
            _walk_cds(v, out)


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    k = re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()
    return PERIODI.get(k, s.strip())


def _nome(des: str | None) -> str | None:
    """'VIDOTTO FRANCESCO' -> 'Vidotto Francesco' (ordine Cognome Nome come nel catalogo)."""
    if not des:
        return None
    return " ".join(w.capitalize() if w.isupper() else w for w in des.split())


def _titolo(des: str) -> str:
    """Nomi in maiuscolo -> iniziale maiuscola (le sigle restano)."""
    des = re.sub(r"\s+", " ", des).strip()
    if not des.isupper():
        return des
    words = des.strip().lower().split()
    small = {"e", "di", "del", "della", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla", "il",
             "la", "lo", "le", "gli", "i", "ed", "nel", "nella", "dell'", "sul", "tra"}
    out = []
    for i, w in enumerate(words):
        if re.fullmatch(r"[ivx]+", w):
            out.append(w.upper())
        elif i and w in small:
            out.append(w)
        else:
            out.append(w[:1].upper() + w[1:])
    return " ".join(out)


def _classe(cod: str | None) -> str | None:
    if not cod:
        return None
    return re.sub(r"\s+R$", "", cod.strip())


def _lista(v) -> list[dict]:
    """Alcuni atenei (es. Insubria) pubblicano `altri_testi_ugov` come stringa (repr Python)."""
    if isinstance(v, str):
        try:
            v = ast.literal_eval(v)
        except (ValueError, SyntaxError):
            return []
    return [x for x in v or [] if isinstance(x, dict)]


def _testi_syllabus(sy: dict) -> tuple[list[dict], str | None, list[str]]:
    """Libri del syllabus, modalità d'esame e link alle bibliografie Leganto."""
    testi, modalita, legati = [], None, []
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if isinstance(v, str) and re.search(r"(^|_)testi_it$", k):
                testi.append(v)
        for a in _lista(t.get("altri_testi")) + _lista(t.get("mod_altri_testi")) + _lista(t.get("altri_testi_ugov")):
            lab = a.get("etichetta_it") or a.get("ugov_etichetta_it") or ""
            testo = a.get("altri_testi_it") or a.get("ugov_altri_testi_it") or ""
            if re.search(r"testi|bibliograf|libr|materiale didattico", lab, re.I) and "disponibilit" not in lab.lower():
                testi.append(testo)
            legati += leganto.link(testo)
    if sy.get("tipoEsaDes_it"):
        modalita = sy["tipoEsaDes_it"].lower()
    return estrai_libri(*testi), modalita, list(dict.fromkeys(legati))


def _chiave_cds(x: dict) -> tuple:
    """Nome, sede e tipo di un corso: per ritrovarlo in una coorte in cui ha un altro codice."""
    nome = re.sub(r"[^a-z0-9]+", " ", (x.get("des_it") or "").lower()).strip()
    return nome, x.get("sede_cod") or x.get("sede_des_it"), x.get("tipo_corso_cod")


ALIAS_SEDI = {"VENEZIA": "MESTRE"}


def _percorsi_sede(percorsi: list[dict], cur: dict) -> list[dict]:
    """Percorsi «… SEDE DI <città>»: solo quello della sede del corso, se è uno solo."""
    nomi = [(p.get("des_it") or p.get("pdsDes") or "").upper() for p in percorsi]
    if len(percorsi) < 2 or not all("SEDE" in n for n in nomi):
        return percorsi
    sede = re.sub(r"\s+\d+$", "", (cur.get("sede_des_it") or "").upper()).strip()
    for citta in (sede, ALIAS_SEDI.get(sede)):
        if citta:
            scelti = [p for p, n in zip(percorsi, nomi) if re.search(rf"\b{re.escape(citta)}\b", n)]
            if len(scelti) == 1:
                return scelti
    return percorsi


def fetch_ateneo(uid: str, base: str, anno: int, durata_max: int = 6, max_cds: int | None = None,
                 syllabus: bool = True, log=print, client: Client | None = None,
                 coorte_per_nome: bool = False, libri_extra=None, obbligatorio_gruppo=None,
                 id_corso=None) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py).

    `coorte_per_nome` (UniPD): se il corso non c'è con lo stesso codice in una coorte
    precedente (codici cambiati con il nuovo ordinamento), lo si cerca per nome, sede e tipo,
    poi per nome e tipo (un solo corso per più sedi, con un percorso per sede: si prende il
    percorso della sede); la durata, assente nell'elenco minimale, si legge dal piano.
    Altrimenti per gli anni successivi al 1° si userebbe il piano futuro della coorte attuale.
    `libri_extra(syllabus)`: se l'estrazione comune non trova libri, quella propria dell'ateneo.
    `obbligatorio_gruppo(gruppo)`: se restituisce True le attività del gruppo (non «Obbligatori») sono
    obbligatorie (per esempio un blocco con una sola attività e i CFU richiesti uguali ai suoi).
    `id_corso(corso)`: id del corso del database a cui associare il piano (più sedi con lo stesso nome)."""
    c = client or Client(base)
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - durata_max + 1, anno + 1):
        lst = c.get("/corsi", {"anno": y, "minimal": "true"}) or []
        cds: list[dict] = []
        _walk_cds(lst, cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y)}
    attuali = list(coorti.get(anno, {}).values())
    if max_cds:
        attuali = attuali[:max_cds]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}

    def piano(y: int, cds_cod: str) -> dict | None:
        x = coorti.get(y, {}).get(cds_cod)
        if not x and coorte_per_nome and cds_cod in coorti.get(anno, {}):
            chiave = _chiave_cds(coorti[anno][cds_cod])
            stessi = [v for v in coorti.get(y, {}).values() if _chiave_cds(v) == chiave]
            if not stessi:  # stesso nome e tipo, altra sede principale (sedi come percorsi)
                stessi = [v for v in coorti.get(y, {}).values()
                          if _chiave_cds(v)[::2] == chiave[::2]]
            x = stessi[0] if len(stessi) == 1 else None
        if not x:
            return None
        d = c.get(f"/corso/{y}/{x['cod']}")
        if isinstance(d, list):
            d = d[0] if d else None
        return d

    def build_cds(cur: dict) -> dict | None:
        durata = int(cur.get("durataAnni") or 0)
        if not durata and coorte_per_nome:
            durata = int((piano(anno, cur["cdsCod"]) or {}).get("durataAnni") or 0)
        durata = durata or 3
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi = set()
        classe_dettaglio = None
        amm = None
        for k in range(1, durata + 1):
            y = anno - k + 1
            d = piano(y, cur["cdsCod"]) or (piano(anno, cur["cdsCod"]) if y != anno else None)
            if not d:
                continue
            classe_dettaglio = classe_dettaglio or d.get("classe_cod")
            if amm is None and y == anno:  # requisiti di accesso della coorte che si iscrive ora
                amm = ammissione.da_catalogo(d, f"{base.rstrip('/')}/corsi/{anno}/{cur.get('cod')}")
            percorsi = d.get("percorsi") or []
            if coorte_per_nome:
                percorsi = _percorsi_sede(percorsi, cur)
            n_percorsi = len(d.get("percorsi") or [])
            for p in percorsi:
                pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
                for a in p.get("anni") or []:
                    anno_a = a.get("anno")
                    # "altreAttivita" & simili: attività a scelta non legate a un anno,
                    # si prendono una volta sola (con l'ultimo anno) senza anno.
                    if not str(anno_a).isdigit():
                        if k != durata:
                            continue
                    elif int(anno_a) != k:
                        continue
                    anno_item = int(anno_a) if str(anno_a).isdigit() else None
                    # di solito le attività sono in gruppi ("insegnamenti" → "attivita"); alcuni
                    # atenei (es. Sassari) le mettono direttamente sotto l'anno ("attivita")
                    gruppi = a.get("insegnamenti") or ([{"label_it": "", "attivita": a["attivita"]}]
                                                       if a.get("attivita") else [])
                    for g in gruppi:
                        gruppo = (g.get("label_it") or "").lower()
                        obbl = "obbligator" in gruppo or g.get("cod") == "OO" or bool(
                            obbligatorio_gruppo and obbligatorio_gruppo(g))
                        for att in g.get("attivita") or []:
                            ad = att.get("adCod") or att.get("cod")
                            key = f"{anno_item}:{ad}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [_nome(x.get("des")) for x in att.get("docenti") or [] if x.get("des")]
                                item = {
                                    "codice": ad, "nome": _titolo(att.get("des_it") or ad), "anno": anno_item,
                                    "periodo": _periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": att.get("crediti"), "ssd": None,
                                    "obbligatorio": (obbl or att.get("tipo_ins_cod") == "OBB") and anno_item is not None,
                                    "curriculum": None, "_percorsi": set(),
                                    "docenti": sorted(set(docenti)),
                                    "url": f"{base.rstrip('/')}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                                    "libri": [], "esami": [],
                                    "fonte": base, "verificato_il": time.strftime("%Y-%m-%d"),
                                }
                                insegnamenti[key] = item
                                if syllabus:
                                    syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                                   "af_percorso": att.get("corso_percorso_id"),
                                                   "corso_cod": att.get("corso_cod"), "corso_aa": y,
                                                   "schema_id": att.get("schemaId")},
                                        "items": []})["items"].append(item)
                            if n_percorsi > 1 and pnome:
                                item["_percorsi"].add(pnome)
                                percorsi_nomi.add(pnome)
        ins = list(insegnamenti.values())
        for i in ins:
            ps = i.pop("_percorsi")
            if percorsi_nomi and ps and ps != percorsi_nomi:
                i["curriculum"] = ", ".join(sorted(ps))
        return {
            **({"id": id_corso(cur)} if id_corso and id_corso(cur) else {}),
            "nome": _titolo(cur.get("des_it") or ""),
            "classe": _classe(cur.get("classe_cod") or classe_dettaglio),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base.rstrip('/')}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": base, "verificato_il": time.strftime("%Y-%m-%d"), "insegnamenti": ins,
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
        libri, modalita, legati = _testi_syllabus(sy)
        if not libri and libri_extra:  # estrazione propria dell'ateneo per i testi in forma libera
            libri = libri_extra(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += leganto.libri(u)
        ssd = sy.get("ssd")
        for it in job["items"]:
            it["libri"] = libri
            it["stato_libri"] = "completo" if libri else ("da_aggiungere")
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
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
