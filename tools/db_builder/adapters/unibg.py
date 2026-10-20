"""Università di Bergamo: Course Catalogue Cineca + bibliografie Leganto per codice d'insegnamento.

- I piani di studio si leggono con `unibg_piani` (piano della coorte di ogni anno di corso, codici del
  riordino, gruppi OO/F/W con i CFU dalle etichette e dalle note, attività a 0 CFU tolte, durata dal piano);
  il catalogo non indica la durata nell'elenco dei corsi.
- I syllabus non contengono i testi: rimandano alla bibliografia su Leganto
  (`readings.unibg.it`, liste pubbliche), il cui `courseCode` è il codice dell'insegnamento
  (per i moduli «93212-MOD1» il codice senza il suffisso). Ogni codice ha una lista per a.a.
  («LINGUA TEDESCA 2026-2027»): si usa quella del 2026/27 e, se il docente non l'ha ancora
  pubblicata, quella dell'a.a. più recente, scrivendolo nella nota di ogni libro.

Con la variabile d'ambiente UN_HTTP_CACHE le risposte restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata
import urllib.parse

import requests

from . import cineca_catalogue, leganto, unibg_appelli, unibg_piani, unifi, unifi_testi
from .testi import YEAR, _isbn

BASE = "https://unibg.coursecatalogue.cineca.it"
PUBBLICO = "https://readings.unibg.it/leganto/public/39BRG_INST/lists?courseCode={}"
ROOT = pathlib.Path(__file__).resolve().parents[3]
ANNO_MIN = 2022  # liste più vecchie non si usano
# codice del corso nel catalogo -> id Universitaly dello stesso corso (altrimenti ne nascerebbe un doppione)
STESSO_CORSO_UNIVERSITALY = {"65GDF-R": "1632620", "103-R": "1626925",  # GdF; Management per l'innovazione di business (apostrofo tipografico)
                             "37-270-EN": "1632083"}  # Management Engineering: senza id build_db lo scambia per Ingegneria gestionale (stessa classe LM-31)


class ClientCache(unifi.ClientCache):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unibg_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)


def _cache_leganto() -> pathlib.Path | None:
    d = os.environ.get("UN_HTTP_CACHE")
    if not d:
        return None
    p = pathlib.Path(d) / "unibg_leganto"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _anno_lista(l: dict) -> int | None:
    m = re.search(r"(20\d\d)\s*[-/–]\s*(?:20)?\d\d\b", l.get("name") or "")
    if m:
        return int(m.group(1))
    for c in l.get("courses") or []:
        m = re.search(r"_(20\d\d)$", c.get("code") or "")
        if m:
            return int(m.group(1))
    return None


def liste_corso(codice: str, log=print) -> list[dict]:
    """Liste pubblicate di un codice: [{id, anno, nome, libri:[…]}], con la cache su disco."""
    cd = _cache_leganto()
    f = cd / f"{hashlib.sha1(codice.encode()).hexdigest()}.json" if cd else None
    if f and f.exists():
        return json.loads(f.read_text(encoding="utf-8"))
    pub = PUBBLICO.format(urllib.parse.quote(codice))
    # la sessione anonima vale per il corso della pagina con cui è stata aperta: una per codice
    p = urllib.parse.urlparse(pub)
    base = f"{p.scheme}://{p.netloc}/leganto"
    s = requests.Session()
    s.headers.update(leganto.HEADERS)
    for tentativo in range(3):
        try:
            time.sleep(0.25)
            s.get(pub, timeout=60, headers={"Accept": "text/html"})
            break
        except requests.RequestException:
            time.sleep(2 ** tentativo)
    d = leganto._get(s, f"{base}/rl/search/find/lists", params={"course_code": codice, "scope": "all_lists",
                                                                  "maxResults": 50, "startPos": 0})
    if d is None:
        return []  # non raggiungibile adesso: niente cache, si riprova alla prossima raccolta
    out = []
    for l in ((d.get("object") or {}).get("lists") or []):
        if l.get("rlStatus") not in (None, "PUBLISHED"):
            continue
        x = leganto._get(s, f"{base}/rl/main/lists/{l['id']}")
        if x is None:
            return []
        libri, viste = [], set()
        for sez in ((x.get("object") or {}).get("sections") or []):
            for c in sez.get("citations") or []:
                if c.get("type") not in ("BK", "BC") or c.get("secondaryType") not in (None, "BK", "BC", "E_BK"):
                    continue
                lb = leganto._libro(c.get("dc") or {}, sez.get("name") or "")
                if lb:
                    k = lb["isbn"] or re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        libri.append(lb)
        out.append({"id": l["id"], "anno": _anno_lista(l), "nome": l.get("name"), "libri": libri})
    if f:
        f.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    return out


def libri_codice(codice: str, anno: int, fonte: str, log=print) -> list[dict]:
    """Libri della lista più recente (a.a. `anno` se c'è) del codice; la nota dice l'a.a. se è precedente."""
    liste = [l for l in liste_corso(codice, log) if l["anno"] and ANNO_MIN <= l["anno"] <= anno and l["libri"]]
    if not liste:
        return []
    a = max(l["anno"] for l in liste)
    out, viste = [], set()
    for l in liste:
        if l["anno"] != a:
            continue
        for b in l["libri"]:
            k = b["isbn"] or re.sub(r"\W+", "", b["citazione"].lower())[:120]
            if k not in viste:
                viste.add(k)
                b = dict(b)
                if a < anno:
                    b["note"] = (f"Dalla bibliografia Leganto dell'a.a. {a}/{(a + 1) % 100:02d} dello stesso "
                                 f"insegnamento: quella del {anno}/{(anno + 1) % 100:02d} non è ancora pubblicata")
                out.append(b)
    return out


def _codici(ins: dict) -> list[str]:
    cod = str(ins.get("codice") or "").strip()
    if not cod:
        return []
    base = re.sub(r"-(?:MOD|M|U|UD|P)?\d*[A-Z]?\d*$", "", cod) if "-" in cod else cod
    return list(dict.fromkeys(x for x in (cod, base) if x))


def libri_extra(sy: dict) -> list[dict]:
    """Testi scritti a mano nel campo «Altre informazioni» del syllabus («Testi: …»), quando ci sono:
    solo le voci che hanno la forma di una citazione (anno, ISBN o editore) e non sono prosa."""
    testi = [{"testi_it": t.get("altro_it") or "", "mod_testi_it": t.get("mod_altro_it") or ""}
             for t in sy.get("testiTotali") or []]
    out = []
    # codici delle liste Leganto indicati nel syllabus (di solito uguali al codice dell'insegnamento)
    for t in sy.get("testiTotali") or []:
        for a in list(cineca_catalogue._lista(t.get("altri_testi"))) + list(cineca_catalogue._lista(t.get("mod_altri_testi"))):
            for m in re.finditer(r"courseCode=([\w.-]+)", (a.get("altri_testi_it") or "") + (a.get("altri_testi_en") or "")):
                if {"_leganto": m.group(1)} not in out:
                    out.append({"_leganto": m.group(1)})
    for b in unifi_testi.libri_unifi({"testiTotali": testi}):
        c = b.get("citazione") or ""
        if len(c) >= 25 and c[0].isupper() and (YEAR.search(c) or _isbn(c) or unifi_testi._editore(c.lower())):
            out.append(dict(b, _testo=True))
    return out


_testi_originale = cineca_catalogue._testi_syllabus


def _testi_syllabus(sy: dict):
    """Senza i link a Leganto: le liste si leggono dopo, per codice e a.a. (non tutte le liste insieme)."""
    libri, modalita, _ = _testi_originale(sy)
    return libri, modalita, []


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _alias_corsi(anno: int, log=print) -> dict[str, str]:
    """Codice di un corso di studio in una qualsiasi coorte (2021…) -> codice del corso della coorte
    attuale (stesso nome, sede e tipo): la bacheca Esse3 elenca i corsi con i codici dei vecchi ordinamenti."""
    c = ClientCache(BASE)
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - 5, anno + 1):
        lst, cds = c.get("/corsi", {"anno": y, "minimal": "true"}) or [], []
        cineca_catalogue._walk_cds(lst, cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y)}
    out = {}
    for cod, x in coorti[anno].items():
        k = cineca_catalogue._chiave_cds(x)
        out[cod] = cod
        for m in coorti.values():
            for cod2, x2 in m.items():
                if cineca_catalogue._chiave_cds(x2) == k:
                    out.setdefault(cod2, cod)
    # codici cambiati con il riordino («86-270» → «86-R») o corso passato da una sede all'altra (Scienze politiche): per
    # codice senza «270» e «R» (stesso tipo), poi per nome e tipo se univoci
    base = {unibg_piani._cod_base(cod) + "|" + (x.get("tipo_corso_cod") or ""): cod for cod, x in coorti[anno].items()}
    nomi: dict[tuple, list[str]] = {}
    for cod, x in coorti[anno].items():
        nomi.setdefault((_norm(x.get("des_it")), x.get("tipo_corso_cod")), []).append(cod)
    for m in coorti.values():
        for cod2, x2 in m.items():
            if cod2 in out:
                continue
            cod = base.get(unibg_piani._cod_base(cod2) + "|" + (x2.get("tipo_corso_cod") or ""))
            if not cod:
                cand = nomi.get((_norm(x2.get("des_it")), x2.get("tipo_corso_cod")), [])
                cod = cand[0] if len(cand) == 1 else None
            if cod:
                out[cod2] = cod
    return out


def integra_appelli(doc: dict, anno: int, log=print) -> dict[str, list[dict]]:
    """Appelli della bacheca Esse3 per corso di studio. Le attività che compaiono in un corso e che
    non sono tra i suoi insegnamenti per codice: se hanno lo stesso nome di un insegnamento del corso
    (codice diverso tra catalogo e Esse3) gli appelli vanno a quello, altrimenti sono insegnamenti
    in più del corso (a scelta, vecchi ordinamenti ancora attivi) con i loro appelli. Restituisce
    gli appelli per codice (come per gli altri atenei)."""
    appelli, per = unibg_appelli.fetch_appelli("unibg", None, log, con_corsi=True)
    alias = _alias_corsi(anno, log)
    corsi = {c.get("codice_ateneo"): c for c in doc["corsi"]}
    oggi = time.strftime("%Y-%m-%d")
    n_nome = n_nuovi = n_senza = 0
    for cn, attivita in per.items():
        cur = corsi.get(alias.get(cn))
        if not cur:
            continue
        ins = cur["insegnamenti"]
        altre = cur.get("_altre") or {}
        altre_nome = {_norm(v["nome"]): v for v in altre.values()}
        per_codice = {i["codice"]: i for i in ins}
        per_nome: dict[str, list[dict]] = {}
        for i in ins:
            per_nome.setdefault(_norm(i["nome"]), []).append(i)
        for cod, titolo in attivita.items():
            if cod in per_codice:
                continue
            esami = [{k: v for k, v in e.items() if k != "titolo"} for e in appelli.get(cod, [])]
            if not esami:
                continue
            simili = per_nome.get(_norm(titolo))
            if simili:
                for i in simili:
                    viste = {(e.get("data"), e.get("ora"), e.get("tipo")) for e in i["esami"]}
                    i["esami"] += [e for e in esami if (e.get("data"), e.get("ora"), e.get("tipo")) not in viste]
                n_nome += 1
                continue
            # un'attività che non è nel piano della coorte degli iscritti ma sta nel piano di un'altra coorte del corso
            # (scelta di coorti precedenti, corsi ancora attivi per i fuori corso): anno e CFU di quel piano; altrimenti non
            # si può collocare (senza anno e CFU) e non è un insegnamento del piano
            info = altre.get(cod) or altre_nome.get(_norm(titolo))
            if not info:
                n_senza += 1
                continue
            nuovo = {"codice": cod, "nome": info["nome"] or cineca_catalogue._titolo(titolo), "anno": info["anno"],
                     "periodo": None, "periodo_inizio": "", "periodo_fine": "", "cfu": info["cfu"], "ssd": None,
                     "obbligatorio": False,
                     "curriculum": None, "docenti": [], "url": unibg_appelli.URL, "libri": [], "esami": esami,
                     "stato_libri": "da_aggiungere", "fonte": unibg_appelli.URL, "verificato_il": oggi}
            ins.append(nuovo)
            per_codice[cod] = nuovo
            per_nome.setdefault(_norm(titolo), []).append(nuovo)
            n_nuovi += 1
    log(f"[unibg] appelli: {n_nome} attività abbinate per nome, {n_nuovi} insegnamenti aggiunti dalla bacheca "
        f"(anno e CFU da un'altra coorte del corso), {n_senza} non nel piano di nessuna coorte (non aggiunte)")
    return appelli


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    try:
        doc = json.loads((ROOT / "database" / "corsi" / "unibg.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("libri") and cod not in out:
                out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def fetch_ateneo(uid: str = "unibg", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    doc = unibg_piani.fetch_piani(uid, anno, max_cds, syllabus, log, ClientCache(BASE), _libri_database(),
                                  testi_syllabus=_testi_syllabus, libri_extra=libri_extra)
    for c in doc["corsi"]:  # lo stesso corso: «riservato agli Allievi della Guardia di Finanza» (lm-giugdf.unibg.it)
        if c.get("codice_ateneo") in STESSO_CORSO_UNIVERSITALY:
            c["id_universitaly"] = STESSO_CORSO_UNIVERSITALY[c["codice_ateneo"]]
        if c.get("codice_ateneo") == "65GDF-R":
            # Universitaly ha due corsi «GIURISPRUDENZA» con la stessa classe e senza sede (1632105 e 1632620): la sede, che build_db
            # copia dal contributo, li distingue come nel titolo del catalogo
            c["sede"] = f'{c.get("sede") or "BERGAMO"} - riservato agli Allievi della Guardia di Finanza'
    appelli = integra_appelli(doc, anno, log)  # prima dei libri: anche gli insegnamenti aggiunti cercano la lista Leganto
    for c in doc["corsi"]:
        c.pop("_altre", None)
    doc["appelli"] = appelli
    if syllabus:
        n_ins = n_lib = 0
        cache: dict[str, list[dict]] = {}
        t0 = time.time()
        tutti = [i for c in doc["corsi"] for i in c["insegnamenti"]]
        for k, i in enumerate(tutti, 1):
            if i.pop("_noto", False):  # libri già nel database per questo codice
                n_ins += 1
                n_lib += len(i.get("libri") or [])
                continue
            testo = [b for b in i.get("libri") or [] if b.get("_testo")]
            link = [b["_leganto"] for b in i.get("libri") or [] if b.get("_leganto")]
            leg: list[dict] = []
            for cod in list(dict.fromkeys(_codici(i) + link)):
                if cod not in cache:
                    cache[cod] = libri_codice(cod, anno, PUBBLICO.format(urllib.parse.quote(cod)), log)
                if cache[cod]:
                    fonte = PUBBLICO.format(urllib.parse.quote(cod))
                    leg = [dict(b, fonte=fonte) for b in cache[cod]]
                    break
            if leg and not leg[0].get("note"):  # lista Leganto dell'a.a. corrente: vale più di tutto
                scelti = leg
            elif testo:  # testi del syllabus corrente, meglio di una lista di un a.a. precedente
                scelti = [dict({k2: v for k2, v in b.items() if k2 != "_testo"}, fonte=i.get("url")) for b in testo]
            else:
                scelti = leg
            i["libri"] = scelti
            i["stato_libri"] = "completo" if scelti else "da_aggiungere"
            if scelti:
                n_ins += 1
                n_lib += len(scelti)
            if k % 500 == 0:
                log(f"[{uid}] Leganto {k}/{len(tutti)} insegnamenti ({time.time() - t0:.0f}s): {n_ins} con libri")
        log(f"[{uid}] Leganto: {n_ins} insegnamenti con libri ({n_lib} libri)")
    for c in doc["corsi"]:
        for i in c["insegnamenti"]:
            i.pop("_noto", None)
            i["libri"] = [{k: v for k, v in b.items() if not k.startswith("_")} for b in i.get("libri") or []
                          if not b.get("_leganto")]
    return doc
