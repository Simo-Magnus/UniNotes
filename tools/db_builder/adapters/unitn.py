"""Università di Trento: Course Catalogue Cineca con le correzioni che servono a UniTN.

- cache su disco delle risposte del catalogo (variabile d'ambiente UN_HTTP_CACHE);
- piano del 2° e 3° anno dalla coorte giusta (anche quando il corso ha cambiato codice); se la coorte degli
  iscritti oggi al k-esimo anno è presente ma senza piano pubblicato (a ottobre alcuni corsi della coorte
  2026 sono ancora vuoti) vale il piano della coorte precedente, con la coorte nell'url di ogni insegnamento;
  se è presente ma vuota da sempre (vecchio ordinamento ad esaurimento) l'anno non esiste;
- durata dal piano (percorsi abilitanti FIT da 1 anno, lauree magistrali da 2, cicli unici da 5 e 6);
- obbligatorietà dai gruppi del piano: «Insegnamenti e attività formative obbligatorie», gruppi da sostenere per
  intero («Scegliere due attività fra le seguenti (2 attività didattiche)», CFU richiesti uguali alla somma delle
  attività) sono obbligatori; «Non obbligatori», scelte, attività extracurriculari e in sovrannumero no;
- attività a 0 CFU (test d'ingresso, livelli di lingua, ECDL, prova finale di abilitazione) non sono insegnamenti;
- gruppi senza attività elencate ma con i CFU nell'etichetta («Scegliere 18 crediti liberi … (18 CFU)»,
  «Altre attività - Tirocinio (3 CFU)»): una riga con quei CFU;
- sede dei corsi interateneo: sede principale e sedi dei partner (Management - EMBS);
- libri dai testi in forma libera dei syllabus (estrazione di UniFI e di UniPD);
- se il syllabus dell'a.a. 2026/27 non ha ancora i testi (il catalogo si compila a ottobre), si
  usa il syllabus ufficiale della stessa attività dell'anno precedente.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata

from . import ammissione, cineca_catalogue, unifi_testi, unipd, unitn_testi

BASE = "https://unitn.coursecatalogue.cineca.it"


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unitn_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


_testi_originale = cineca_catalogue._testi_syllabus
_CON_TESTO: set[tuple[str, str]] = set()  # (anno, codice) dei syllabus che hanno un testo nel campo dei testi


def _ha_testo(sy: dict) -> bool:
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if isinstance(v, str) and re.search(r"(^|_)testi_(it|en)$", k) and                     len(re.sub(r"(?i)<[^>]+>|&nbsp;|[^a-z0-9]", "", v)) >= 5:
                return True
    return False


def _testi_syllabus(sy: dict):
    if _ha_testo(sy):
        _CON_TESTO.add((str(sy.get("aa")), str(sy.get("cod"))))
    libri, modalita, legati = _testi_originale(sy)
    return [unitn_testi.ripulisci(b) for b in libri], modalita, legati


def libri_extra(sy: dict) -> list[dict]:
    libri = unifi_testi.libri_unifi(sy) or unipd.libri_liberi(sy) or unitn_testi.libri_unitn(sy)
    return [unitn_testi.ripulisci(b) for b in libri]


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _attivita(piano: dict):
    """Tutte le attività di un piano: (anno di corso, attività)."""
    for p in piano.get("percorsi") or []:
        for a in p.get("anni") or []:
            gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                for att in g.get("attivita") or []:
                    yield a.get("anno"), att


def indice_anni_precedenti(client: ClientCache, anno: int, indietro: int = 5, log=print) -> tuple[dict, dict]:
    """Attività offerte negli anni accademici precedenti, dai piani delle coorti passate:
    per codice dell'attività e per (nome del corso, nome dell'attività)."""
    per_codice: dict[str, list[dict]] = {}
    per_nome: dict[tuple[str, str], list[dict]] = {}
    for y in range(anno - 1, anno - 1 - indietro, -1):
        lst: list[dict] = []
        cineca_catalogue._walk_cds(client.get("/corsi", {"anno": y, "minimal": "true"}) or [], lst)
        cds = [x for x in lst if str(x.get("aa")) == str(y)]
        log(f"[unitn] coorte {y}: {len(cds)} corsi")
        for x in cds:
            piano = client.get(f"/corso/{y}/{x['cod']}")
            if isinstance(piano, list):
                piano = piano[0] if piano else None
            if not piano:
                continue
            for _, att in _attivita(piano):
                try:
                    aa = int(att.get("aa"))
                except (TypeError, ValueError):
                    continue
                if aa >= anno:  # syllabus dell'anno corrente o futuri: non servono
                    continue
                voce = {"aa": aa, "params": {k: v for k, v in {
                    "anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                    "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y,
                    "schema_id": att.get("schemaId")}.items() if v not in (None, "")}}
                per_codice.setdefault(str(att.get("adCod")), []).append(voce)
                per_nome.setdefault((_norm(x.get("des_it")), _norm(att.get("des_it"))), []).append(voce)
    return per_codice, per_nome


def completa_da_anni_precedenti(doc: dict, client: ClientCache, anno: int, log=print) -> int:
    """Insegnamenti 2026/27 senza libri perché il syllabus non ha ancora i testi: si cerca il syllabus
    ufficiale della stessa attività negli anni accademici precedenti (il più recente che li ha)."""
    per_codice, per_nome = indice_anni_precedenti(client, anno, log=log)
    cache: dict[tuple, list[dict]] = {}

    def libri_di(voce: dict) -> list[dict]:
        k = (voce["aa"], json.dumps(voce["params"], sort_keys=True))
        if k not in cache:
            sy = client.get("/insegnamento", voce["params"])
            libri: list[dict] = []
            if isinstance(sy, dict):
                libri = cineca_catalogue._testi_syllabus(sy)[0] or libri_extra(sy)
            cache[k] = libri
        return cache[k]

    trovati = 0
    for cs in doc["corsi"]:
        nome_cds = _norm(cs.get("nome"))
        for it in cs["insegnamenti"]:
            if it.get("libri"):
                continue
            m = re.search(r"/insegnamenti/(\d+)/([^/?]+)", it.get("url") or "")
            if m and (m.group(1), m.group(2)) in _CON_TESTO:
                continue  # il syllabus attuale ha un testo (senza libri: materiali su Moodle, da indicare…)
            cand = list(per_codice.get(str(it.get("codice")), [])) + list(per_nome.get((nome_cds, _norm(it["nome"])), []))
            visti = set()
            for voce in sorted(cand, key=lambda v: -v["aa"]):
                k = (voce["aa"], json.dumps(voce["params"], sort_keys=True))
                if k in visti:
                    continue
                visti.add(k)
                libri = libri_di(voce)
                if libri:
                    aa = voce["aa"]
                    nota = f"Dal syllabus {aa}/{(aa + 1) % 100:02d} (quello {anno}/{(anno + 1) % 100:02d} non ha ancora i testi)"
                    it["libri"] = [dict(b, note=(b.get("note") + "; " if b.get("note") else "") + nota) for b in libri]
                    it["stato_libri"] = "completo"
                    trovati += 1
                    break
    log(f"[unitn] insegnamenti con libri dal syllabus di un anno precedente: {trovati}")
    return trovati


# --- piani di studio: gruppi, coorti, CFU ---

_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_N_ATTIVITA = re.compile(r"\(\s*(\d+)\s+attivit[àa]\s+didattich[ae]\s*\)", re.I)
_NON_OBBLIGATORIO = re.compile(r"(?i)\bnon\s+obbligator|facoltativ|extracurricular|extra\s+course|sovrannumer|opzional|"
                               r"a\s+scelta|scelta\s+libera|elective|optional|libera\b|\bfree\b")
_SCELTA = re.compile(r"(?i)\bscegli|\bscelta\b|\bliber[ie]\b|elective|free choice|to be chosen|\bchoose\b|\bopzional")
_RICHIESTA = re.compile(r"(?i)tirocin|internship|stage\b|prova finale|tesi\b|thesis|laborator|altre attivit|other activit|"
                        r"lingua|language|conoscenz|abilit")


def _numero(s: str) -> float:
    return float(s.replace(",", "."))


def _cfu(v) -> float:
    return float(v) if isinstance(v, (int, float)) else 0.0


def gruppo_obbligatorio(g: dict, attivita: list[dict], n_elencate: int | None = None) -> bool:
    """Le attività del gruppo si sostengono tutte? Gruppo «obbligatorio», oppure da sostenere per intero (le
    attività da scegliere sono quante quelle elencate, i CFU richiesti uguali alla loro somma).
    `attivita`: quelle con CFU; `n_elencate`: tutte quelle del gruppo (anche a 0 CFU, che sono alternative)."""
    label = (g.get("label_it") or "").strip()
    if g.get("cod") == "OO":
        return True
    low = label.lower()
    if re.search(r"non\s+obbligator|facoltativ", low):
        return False
    if "obbligator" in low or (re.search(r"\b(?:compulsory|required)\b", low) and not _SCELTA.search(low)):
        return True
    if not attivita:
        return False
    m = _N_ATTIVITA.search(label)
    if m and int(m.group(1)) >= max(len(attivita), n_elencate or 0) and not _NON_OBBLIGATORIO.search(low):
        return True
    m = _ETICHETTA_CFU.search(label)
    if m and m.group(1) is None and not re.search(r"(?i)extracurricular|extra\s+course|sovrannumer|facoltativ|opzional", low):
        if (n_elencate or 0) <= len(attivita) and abs(sum(_cfu(a.get("crediti")) for a in attivita) - _numero(m.group(2))) < 1e-6:
            return True
    return False


def gruppo_senza_attivita(g: dict):
    """Gruppo senza attività elencate con i CFU nell'etichetta: crediti fissi («Scegliere 18 crediti liberi … (18 CFU)»,
    «Other activities - Internship (3 CFU)»). → (nome, cfu, obbligatorio) o None. I gruppi con un intervallo
    («fra 1 e 48 CFU») sono filtri sui corsi di altri dipartimenti: non hanno CFU propri."""
    label = re.sub(r"\s+", " ", g.get("label_it") or "").strip()
    m = _ETICHETTA_CFU.search(label)
    if not m or m.group(1) is not None:
        return None
    cfu = _numero(m.group(2))
    if cfu <= 0:
        return None
    cfu = int(cfu) if cfu == int(cfu) else cfu
    low = label.lower()
    if _RICHIESTA.search(low) and not _SCELTA.search(low):
        nome = _ETICHETTA_CFU.sub(" ", label).strip(" -–:")
        return re.sub(r"\s+", " ", nome)[:120] or None, cfu, True
    if re.search(r"(?i)elective|free choice|credits", low) and not re.search(r"[àèéìòù]|scegli|liber", low):
        return "Elective courses", cfu, False
    return "Insegnamenti a scelta libera", cfu, False


def _durata_piano(d: dict | None) -> int:
    try:
        return int((d or {}).get("durataAnni") or 0)
    except (TypeError, ValueError):
        return 0


def _anni_del_piano(d: dict | None) -> set[int]:
    out = set()
    for p in (d or {}).get("percorsi") or []:
        for a in p.get("anni") or []:
            if str(a.get("anno")).isdigit() and (a.get("insegnamenti") or a.get("attivita")):
                out.add(int(a["anno"]))
    return out


def _sede(cur: dict) -> str | None:
    """Sede del corso: il comune; per i corsi interateneo anche le sedi dei partner (Management - EMBS)."""
    sede = cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None
    altre = [s.get("sedeDenominazioneComune") or s.get("sede_des_it") for s in cur.get("altreSedi") or []]
    altre = [s for s in dict.fromkeys(altre) if s and s != sede]
    if sede and altre:
        return f"{sede}; {'; '.join(altre)}"
    return sede


def _fetch_piani(uid: str, anno: int, client: ClientCache, max_cds: int | None, syllabus: bool, log=print) -> dict:
    """Come cineca_catalogue.fetch_ateneo, con le regole di UniTN (vedi il docstring del modulo)."""
    cc = cineca_catalogue
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - 5, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(client.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y)}
    attuali = list(coorti[anno].values())
    if max_cds:
        attuali = attuali[:max_cds]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    base = BASE
    oggi = time.strftime("%Y-%m-%d")

    def voce(y: int, cur: dict) -> dict | None:
        """Corso della coorte y: stesso codice, altrimenti (codici cambiati col nuovo ordinamento) stesso nome,
        sede e tipo, poi stesso nome e tipo."""
        x = coorti.get(y, {}).get(cur["cdsCod"])
        if not x:
            chiave = cc._chiave_cds(cur)
            stessi = [v for v in coorti.get(y, {}).values() if cc._chiave_cds(v) == chiave]
            if not stessi:
                stessi = [v for v in coorti.get(y, {}).values() if cc._chiave_cds(v)[::2] == chiave[::2]]
            x = stessi[0] if len(stessi) == 1 else None
        return x

    def dettaglio(y: int, x: dict) -> dict | None:
        d = client.get(f"/corso/{y}/{x['cod']}")
        return (d[0] if d else None) if isinstance(d, list) else d

    def piano(cur: dict, k: int):
        """(coorte, corso, dettaglio) per l'anno di corso k: la coorte degli iscritti oggi al k-esimo anno."""
        y = anno - k + 1
        x = voce(y, cur)
        if x is None:  # corso più recente della coorte: piano della coorte più vicina tra y+1 e quella attuale
            for yy in range(y + 1, anno + 1):
                xx = voce(yy, cur)
                d = dettaglio(yy, xx) if xx else None
                if d and k in _anni_del_piano(d):
                    return yy, xx, d
            return None
        d = dettaglio(y, x)
        if d and k in _anni_del_piano(d):
            return y, x, d
        if y == anno:  # piano della coorte attuale non ancora pubblicato: quello della coorte precedente
            xp = voce(y - 1, cur)
            dp = dettaglio(y - 1, xp) if xp else None
            if dp and k in _anni_del_piano(dp):
                return y - 1, xp, dp
        return None

    def build_cds(cur: dict) -> dict | None:
        durata = int(cur.get("durataAnni") or 0) or _durata_piano(dettaglio(anno, cur))
        if not durata:  # nessun piano nella coorte attuale: l'ultimo piano pubblicato
            for y in range(anno - 1, anno - 6, -1):
                x = voce(y, cur)
                durata = _durata_piano(dettaglio(y, x)) if x else 0
                if durata:
                    break
        durata = durata or 3
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        classe_dettaglio = amm = None
        for k in range(1, durata + 1):
            trovato = piano(cur, k)
            if not trovato:
                continue
            y, x, d = trovato
            classe_dettaglio = classe_dettaglio or d.get("classe_cod")
            if amm is None and y == anno:  # requisiti di accesso della coorte che si iscrive ora
                amm = ammissione.da_catalogo(d, f"{base}/corsi/{anno}/{cur.get('cod')}")
            percorsi = cc._percorsi_sede(d.get("percorsi") or [], cur)
            n_percorsi = len(d.get("percorsi") or [])
            for p in percorsi:
                pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
                for a in p.get("anni") or []:
                    anno_a = a.get("anno")
                    if not str(anno_a).isdigit():  # attività senza anno: una volta sola, nell'ultimo anno, senza anno
                        if k != durata:
                            continue
                    elif int(anno_a) != k:
                        continue
                    anno_item = int(anno_a) if str(anno_a).isdigit() else None
                    gruppi = a.get("insegnamenti") or ([{"label_it": "", "attivita": a["attivita"]}]
                                                       if a.get("attivita") else [])
                    for g in gruppi:
                        # attività a 0 CFU (test d'ingresso, livelli di lingua, ECDL, prova di abilitazione): non
                        # sono insegnamenti
                        elenco = [t for t in g.get("attivita") or [] if _cfu(t.get("crediti")) > 0
                                  or t.get("crediti") is None]
                        obbl = gruppo_obbligatorio(g, elenco, len(g.get("attivita") or []))
                        if not elenco:
                            r = gruppo_senza_attivita(g) if not g.get("attivita") else None
                            if not r:
                                continue
                            nome, cfu, richiesto = r
                            key = f"{anno_item}:#{_norm(nome)}:{cfu}"
                            item = insegnamenti.get(key)
                            if not item:
                                item = {"codice": None, "nome": nome, "anno": anno_item, "periodo": None, "cfu": cfu,
                                        "ssd": None, "obbligatorio": richiesto and anno_item is not None,
                                        "curriculum": None, "_percorsi": set(), "docenti": [],
                                        "url": f"{base}/corsi/{y}/{x['cod']}", "libri": [], "esami": [],
                                        "fonte": base, "verificato_il": oggi}
                                insegnamenti[key] = item
                            if n_percorsi > 1 and pnome:
                                item["_percorsi"].add(pnome)
                                percorsi_nomi.add(pnome)
                            continue
                        for att in elenco:
                            ad = att.get("adCod") or att.get("cod")
                            key = f"{anno_item}:{ad}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": anno_item,
                                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": att.get("crediti"), "ssd": None,
                                    "obbligatorio": (obbl or att.get("tipo_ins_cod") == "OBB") and anno_item is not None,
                                    "curriculum": None, "_percorsi": set(),
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
                                        "items": []})["items"].append(item)
                            elif (obbl or att.get("tipo_ins_cod") == "OBB") and anno_item is not None:
                                item["obbligatorio"] = True  # obbligatorio in almeno un percorso
                            if n_percorsi > 1 and pnome:
                                item["_percorsi"].add(pnome)
                                percorsi_nomi.add(pnome)
        ins = list(insegnamenti.values())
        for i in ins:
            ps = i.pop("_percorsi")
            if percorsi_nomi and ps and ps != percorsi_nomi:
                i["curriculum"] = ", ".join(sorted(ps))
        return {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or classe_dettaglio),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(cur),
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

    corsi_out = []
    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            sy = client.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
            if not isinstance(sy, dict):
                return 0
            libri, modalita, legati = cc._testi_syllabus(sy)
            if not libri:  # estrazione propria dell'ateneo per i testi in forma libera
                libri = libri_extra(sy)
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
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    trovati = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, syllabus_jobs.values()), 1):
            trovati += n
            if i % 1000 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {client.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unitn.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def fetch_ateneo(uid: str = "unitn", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    client = ClientCache(BASE)
    cineca_catalogue._testi_syllabus = _testi_syllabus
    try:
        doc = _fetch_piani(uid, anno, client, max_cds, syllabus, log)
        if syllabus:
            completa_da_anni_precedenti(doc, client, anno, log)
    finally:
        cineca_catalogue._testi_syllabus = _testi_originale
    associa(doc, log)
    return doc


# Universitaly ha due corsi «Management» LM-77: 1627991 (corsi.unitn.it/it/management, Dipartimento di
# Economia e Management) e 1627989 (corsi.unitn.it/en/european-master-business-studies, EMBS). Nel
# catalogo sono 0132H «Management» e 0138H «Management - EMBS». Il nome non li distingue: si indica l'id.
ID_CORSI = {"0132H": "unitn-lm-77-management-1627991",
            "0138H": "unitn-lm-77-management"}  # 1627989: EMBS, lo stesso piano di «Management - EMBS» (0138H)


def associa(doc: dict, log=print) -> None:
    for cs in doc["corsi"]:
        if cs.get("codice_ateneo") in ID_CORSI:
            cs["id"] = ID_CORSI[cs["codice_ateneo"]]
    log(f"[unitn] corsi associati per id: {sum(1 for c in doc['corsi'] if c.get('id'))}")


# --- appelli: bacheca pubblica di Esse3 (tutte le strutture) + codici di attività dei piani precedenti ---

ESSE3 = "https://unitn.esse3.cineca.it"


def _parole(s: str | None) -> set[str]:
    return {w for w in _norm(s).split() if len(w) >= 3}


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli della bacheca di Esse3. La bacheca usa spesso il codice di un piano precedente (o di un
    altro corso di studio) per lo stesso insegnamento: l'appello si assegna anche agli insegnamenti dei
    corsi con lo stesso nome e almeno un docente in comune (stesso esame, codice diverso)."""
    from .esse3_appelli import fetch_appelli as esse3

    app = esse3(uid, ESSE3, log=log)
    try:  # Agenda Web pubblica (EasyTest): date anche per gli appelli non ancora aperti in Esse3
        from .unitn_agenda import fetch_appelli as agenda
        for cod, lst in agenda(uid, corsi, log=log).items():
            viste = {(x["data"], x.get("ora")) for x in app.get(cod, [])}
            app.setdefault(cod, []).extend(x for x in lst if (x["data"], x.get("ora")) not in viste)
    except Exception as e:  # noqa: BLE001 - la bacheca Esse3 basta
        log(f"[{uid}] agenda web non letta: {e!r}")
    codici = {i["codice"] for c in corsi for i in c["insegnamenti"]}
    estesi = 0
    for cod, lst in list(app.items()):
        if cod in codici or not lst:
            continue
        nome = _norm(lst[0].get("titolo"))
        doc_app = set().union(*(_parole(e.get("docenti")) for e in lst))
        if not nome or not doc_app:
            continue
        for c in corsi:
            for i in c["insegnamenti"]:
                if _norm(i["nome"]) != nome or i["codice"] in app and i["codice"] != cod:
                    continue
                if not doc_app & set().union(*(_parole(d) for d in i.get("docenti") or [])):
                    continue
                viste = {(e["data"], e["ora"], e["tipo"]) for e in app.get(i["codice"], [])}
                nuovi = [e for e in lst if (e["data"], e["ora"], e["tipo"]) not in viste]
                if nuovi:
                    app.setdefault(i["codice"], []).extend(nuovi)
                    estesi += 1
    log(f"[unitn] insegnamenti con appelli per nome e docente (codice diverso): {estesi}")
    return app
