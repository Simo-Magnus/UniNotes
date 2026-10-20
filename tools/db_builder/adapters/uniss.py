"""Università degli Studi di Sassari: insegnamenti per anno di corso, libri e appelli.

Piani e syllabus: `https://uniss.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Il catalogo di Sassari non divide il piano per anno: tutte le attività stanno sotto «altreAttivita», ognuna con l'a.a. di
erogazione (`aa`), e l'offerta di una coorte elenca le attività di tutte le coorti in corso dell'ordinamento (per
Fisioterapia l'a.a. 2026 elenca il 2° e il 3° anno insieme). L'anno di corso k di un'attività si ricava dagli a.a. in cui è
erogata: la coorte più recente dell'ordinamento la segue nell'a.a. cL + k - 1, quindi k = ultimo a.a. di erogazione - cL + 1
(per percorso; i percorsi «Sede di …» seguono il percorso comune). Eccezioni: se il nome dice l'anno («Tirocinio III anno») vale
il nome; la «Prova finale» è dell'ultimo anno. Per l'anno k si leggono le attività erogate nell'a.a. corrente della coorte
2026 - k + 1 (l'ordinamento in vigore per quella coorte). Inoltre:

- attività a 0 CFU (precorsi, OFA, corsi zero, integrazioni di livello di lingua) non sono insegnamenti del piano e si tolgono;
- attività omonime dello stesso anno e curriculum con codici diversi: con CFU diversi il nome porta i CFU, con gli stessi CFU
  (e non canali X/Y della stessa disciplina) porta il codice, perché build_db unisce le omonime con stessi anno e CFU;
- libri già raccolti per lo stesso codice nel database non si rileggono (il syllabus si legge solo per i codici nuovi);
- un corso del database è una catena di corsi del catalogo con lo stesso nome e la stessa sede (il codice
  del corso cambia con ogni nuovo ordinamento: 1158 → A187 per Giurisprudenza): per ogni coorte vale solo
  il codice il cui ordinamento era in vigore (`ordinamento_aa` ≤ coorte ≤ `ordinamento_aa_cess`);
  l'offerta delle coorti dopo la cessazione contiene solo gli anni residui di coorti più vecchie;
- per gli anni senza una coorte attiva (primo anno di un corso nuovo: il 2° e il 3° anno sono già nel piano
  della coorte 2026 ma erogati dal 2027/28; ordinamenti chiusi) si legge il piano della coorte con piano più vicina a quella
  degli iscritti, indicando l'anno e la coorte;
  i corsi senza nessuna coorte attiva (ordinamenti estinti) mantengono il piano dell'ultima coorte;
- il catalogo pubblica il programma di molti insegnamenti con libri in forma libera (`uniss_testi`) e,
  quando quello 2026/27 non c'è ancora, si usa il programma dell'a.a. precedente, con una nota;
- durata dei corsi dal piano («2 anni»): l'elenco minimale non ha `durataAnni`.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 2 al secondo.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata

from . import ammissione, cineca_catalogue, uniss_testi

BASE = "https://uniss.coursecatalogue.cineca.it"
ESSE3 = "https://uniss.esse3.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L2", "LM", "LM5", "LM6"}
RATE = 2.0

# gruppi di codici del catalogo che sono lo stesso corso del database pur con un'altra sede
UNISCI = [("A103", "A179")]  # Qualità e sicurezza dei prodotti alimentari: Oristano → Sassari
# corsi del database che il nome non basta a distinguere: codice del catalogo → id del corso
FORZA_ID = {"A232": "uniss-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1634332"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "uniss_cc" if d else None
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


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    return {"L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _e_comune(p: dict, nome: str) -> bool:
    """Percorso valido per tutti gli studenti («PERCORSO COMUNE»; in alcuni ordinamenti senza il flag)."""
    return bool(p.get("comune")) or nome.upper().startswith("PERCORSO COMUNE")


_ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}


def _anno_nel_nome(nome: str) -> int | None:
    """Anno di corso scritto nel nome dell'attività («Tirocinio III Anno», «Attività a scelta II anno - II sem.»)."""
    m = re.search(r"(?i)\b(VI|IV|V|III|II|I)\s*[°^]?\s*anno\b", nome) or re.search(r"(?i)\b([1-6])\s*[°^]\s*anno\b", nome)
    if not m:
        return None
    g = m.group(1).upper()
    return _ROMANI.get(g) or int(g)


def _cfu_zero(att: dict) -> bool:
    """Attività a 0 CFU (precorsi, OFA, corsi zero, integrazioni di livello di lingua): non sono insegnamenti del piano."""
    c = att.get("crediti")
    return isinstance(c, (int, float)) and c == 0


def _attivita(det: dict):
    """(nome del percorso, è comune, attività) di tutti i percorsi del corso."""
    for p in det.get("percorsi") or []:
        nome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        for a in p.get("anni") or []:
            gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                for att in g.get("attivita") or []:
                    yield nome, _e_comune(p, nome), att


def fetch_ateneo(uid: str = "uniss", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache()
    fmt = lambda a: f"{a}/{(a + 1) % 100:02d}"  # noqa: E731
    oggi = time.strftime("%Y-%m-%d")

    # --- offerte per coorte -------------------------------------------------------------------------
    offerte: dict[tuple[str, int], dict] = {}  # (cdsCod, coorte) -> dettaglio + dati dell'elenco
    for y in range(anno - 5, anno + 1):
        elenco: list[dict] = []
        cineca_catalogue._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], elenco)
        visti = set()
        for x in elenco:
            if str(x.get("aa")) != str(y) or x.get("tipo_corso_cod") not in TIPI or x["cod"] in visti:
                continue
            visti.add(x["cod"])
            det = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(det, list):
                det = det[0] if det else None
            if not det:
                continue
            offerte[(x["cdsCod"], y)] = {"x": x, "det": det}
    log(f"[{uid}] offerte lette: {len(offerte)}")

    def valida(cds: str, y: int) -> bool:
        o = offerte.get((cds, y))
        if not o:
            return False
        d = o["det"]
        if not int(d.get("ordinamento_aa") or 0) <= y <= int(d.get("ordinamento_aa_cess") or 9999):
            return False
        # la coorte c'è solo se l'offerta ha attività erogate nell'a.a. di immatricolazione (A232, Infermieristica di Nuoro,
        # ha un'offerta dal 2025 anche nell'elenco delle coorti 2022-2024)
        return any(str(att.get("aa")) == str(y) for _, _, att in _attivita(d))

    # --- catene di codici = corsi -----------------------------------------------------------------
    corsi_cat: dict[str, dict] = {}  # cdsCod -> riga dell'offerta più recente
    for (cds, y), o in sorted(offerte.items(), key=lambda t: t[0][1]):
        corsi_cat[cds] = o["x"]
    chiavi: dict[str, tuple] = {cds: (_norm(x.get("des_it")), x.get("sede_cod") or x.get("sede_des_it"))
                                for cds, x in corsi_cat.items()}
    gruppi: dict[tuple, list[str]] = {}
    for cds, k in chiavi.items():
        gruppi.setdefault(k, []).append(cds)
    for a, b in UNISCI:
        ka, kb = chiavi.get(a), chiavi.get(b)
        if ka and kb and ka != kb:
            gruppi[ka] += gruppi.pop(kb)
    log(f"[{uid}] corsi del catalogo: {len(corsi_cat)} codici in {len(gruppi)} corsi")

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    indice_ad: dict[str, dict[int, list[dict]]] = {}  # adCod -> aa -> parametri del syllabus

    def parametri(att: dict, y: int) -> dict:
        return {"anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y,
                "schema_id": att.get("schemaId")}

    for (cds, y), o in offerte.items():
        for _, _, att in _attivita(o["det"]):
            try:
                v = indice_ad.setdefault(str(att.get("adCod")), {}).setdefault(int(att["aa"]), [])
            except (KeyError, TypeError, ValueError):
                continue
            p = parametri(att, y)
            if p not in v:
                v.append(p)

    # --- anno di corso di ogni attività, per ordinamento --------------------------------------------
    # Le offerte del catalogo non sono piani di una coorte: l'offerta di una coorte elenca tutte le attività dell'ordinamento
    # erogate in ogni a.a. da quella coorte in poi, di tutte le coorti in corso (per l'ordinamento 2019-2025 di Fisioterapia
    # l'a.a. 2026 elenca il 2° e il 3° anno insieme). L'anno di corso di un'attività si ricava dagli a.a. in cui è erogata:
    # la coorte più recente dell'ordinamento (cL) la segue nell'a.a. cL + k - 1, quindi l'ultimo a.a. di erogazione è
    # cL + k - 1 e k = ultimo a.a. - cL + 1.
    ord_att: dict[tuple, dict] = {}  # (cdsCod, ordinamento_aa) -> {(percorso, adCod): {"aa": {aa: (att, y)}, ...}}
    ord_ult: dict[tuple, int] = {}  # (cdsCod, ordinamento_aa) -> coorte più recente dell'ordinamento
    perc_ult: dict[tuple, int] = {}  # (cdsCod, ordinamento_aa, percorso) -> coorte più recente in cui il percorso c'è
    for (cds, y), o in sorted(offerte.items(), key=lambda t: t[0][1]):
        d = o["det"]
        ok = (cds, int(d.get("ordinamento_aa") or 0))
        ord_ult[ok] = max(ord_ult.get(ok, 0), min(y, int(d.get("ordinamento_aa_cess") or 9999)))
        reg = ord_att.setdefault(ok, {})
        ult_y = min(y, int(d.get("ordinamento_aa_cess") or 9999))
        for p_ in d.get("percorsi") or []:
            pk = ok + ((p_.get("des_it") or p_.get("pdsDes") or "").strip(),)
            perc_ult[pk] = max(perc_ult.get(pk, 0), ult_y)
        for pnome, comune, att in _attivita(d):
            try:
                aa_ = int(att["aa"])
            except (KeyError, TypeError, ValueError):
                continue
            r = reg.setdefault((pnome, str(att.get("adCod") or att.get("cod"))), {"aa": {}, "comune": comune})
            r["aa"][aa_] = (att, y)  # (la vista più recente che la contiene)

    def anno_di_corso(ok: tuple, r: dict, durata: int, pnome: str = "") -> int | None:
        nome_ = next(iter(r["aa"].values()))[0].get("des_it") or ""
        k = _anno_nel_nome(nome_)  # «Tirocinio III anno»: l'anno lo dice il nome (l'a.a. può mancare per qualche coorte)
        if not k and _norm(nome_) == "prova finale":  # la prova finale è dell'ultimo anno (il catalogo la elenca solo in un a.a.)
            k = durata
        if k:
            return k if k <= durata else None
        k = max(r["aa"]) - perc_ult.get(ok + (pnome,), ord_ult[ok]) + 1
        return k if 1 <= k <= durata else None

    for chiave, codici in sorted(gruppi.items(), key=lambda t: t[1]):
        if max_cds and len(corsi_out) >= max_cds:
            break
        # durata e dati del corso: dall'offerta più recente
        recente = max(((cds, y) for cds in codici for (cc_, y) in offerte if cc_ == cds), key=lambda t: t[1])
        x, det = offerte[recente]["x"], offerte[recente]["det"]
        durata = _durata(det, x.get("tipo_corso_cod"))
        coorti_valide = sorted(y for cds in codici for y in range(anno - 5, anno + 1) if valida(cds, y))
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        amm = None

        def aggiungi(cds: str, y: int, k: int, aa_cercato: int, nota_anno: str | None):
            """Attività dell'ordinamento della coorte y che sono del k-esimo anno e erogate nell'a.a. aa_cercato."""
            nonlocal amm
            o = offerte[(cds, y)]
            ok = (cds, int(o["det"].get("ordinamento_aa") or 0))
            if amm is None and y == anno:
                amm = ammissione.da_catalogo(o["det"], f"{BASE}/corsi/{anno}/{o['x'].get('cod')}")
            n_perc = len([p for p in o["det"].get("percorsi") or []
                          if not _e_comune(p, (p.get("des_it") or p.get("pdsDes") or "").strip())])
            for (pnome, ad), r in ord_att[ok].items():
                if aa_cercato not in r["aa"]:
                    continue
                rk, pk = r, pnome
                if "sede" in pnome.lower():  # i percorsi «Sede di Olbia / Sassari» finiscono prima del comune: vale l'anno del comune
                    rc = next(((p2, r2) for (p2, a2), r2 in ord_att[ok].items() if a2 == ad and r2["comune"]), None)
                    if rc:
                        pk, rk = rc
                if anno_di_corso(ok, rk, durata, pk) != k:
                    continue
                att, y_vista = r["aa"][aa_cercato]
                comune = r["comune"]
                if _cfu_zero(att):
                    continue
                key = f"{k}:{ad}"
                item = insegnamenti.get(key)
                if not item:
                    docenti = [cineca_catalogue._nome(d.get("des")) for d in att.get("docenti") or [] if d.get("des")]
                    item = {
                        "codice": ad, "nome": cineca_catalogue._titolo(att.get("des_it") or ad), "anno": k,
                        "periodo": cineca_catalogue._periodo(att.get("periodo_didattico_it")),
                        "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                        "periodo_fine": att.get("data_fine_periodo_didattico"),
                        "cfu": att.get("crediti"), "ssd": None,
                        "obbligatorio": att.get("tipo_ins_cod") == "OBB",
                        "curriculum": None, "_percorsi": set(), "_comune": False,
                        "docenti": sorted(set(docenti)),
                        "url": f"{BASE}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                               f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y_vista}",
                        "libri": [], "esami": [],
                        "fonte": BASE, "verificato_il": oggi,
                    }
                    if nota_anno:
                        item["_nota_anno"] = nota_anno
                    insegnamenti[key] = item
                    if syllabus:
                        syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                            "params": parametri(att, y_vista), "items": [], "ad": str(ad)})["items"].append(item)
                if comune:
                    item["_comune"] = True
                elif n_perc > 1 and pnome:
                    pnome = cineca_catalogue._titolo(pnome)
                    item["_percorsi"].add(pnome)
                    percorsi_nomi.add(pnome)

        for k in range(1, durata + 1):
            y = anno - k + 1
            attive = [cds for cds in codici if valida(cds, y)]
            if attive:
                for cds in attive:
                    aggiungi(cds, y, k, anno, None)
                continue
            if not coorti_valide:
                continue
            # nessuna coorte attiva per quest'anno: piano della coorte più recente (anno futuro o ultimo erogato)
            yf = min(coorti_valide, key=lambda c_: (abs(c_ - y), -c_))  # la coorte con piano più vicina a quella degli iscritti
            cds_f = [cds for cds in codici if valida(cds, yf)]
            aa_f = yf + k - 1
            if yf == anno or aa_f > anno:  # coorte nuova: il suo anno k sarà erogato nel futuro
                nota = f"Piano della coorte {yf}: insegnamento erogato dal {fmt(aa_f)}"
            else:
                nota = (f"Piano dell'ultima coorte attiva ({yf}): ordinamento senza iscritti al {k}° anno" if yf == max(coorti_valide)
                        else f"Piano della coorte {yf}, la più vicina agli iscritti al {k}° anno (nel catalogo non c'è la coorte {y})")
            for cds in cds_f:
                aggiungi(cds, yf, k, aa_f, nota)
        if not insegnamenti:  # ordinamento estinto senza coorti: piano dell'ultima offerta nota
            yl = max((y for cds in codici for (cc_, y) in offerte if cc_ == cds and
                      any(True for _ in _attivita(offerte[(cc_, y)]["det"]))), default=None)
            cds_l = [cds for cds in codici if (cds, yl) in offerte] if yl else []
            for k in range(1, durata + 1):
                for cds in cds_l:
                    ok_ = (cds, int(offerte[(cds, yl)]["det"].get("ordinamento_aa") or 0))
                    aggiungi(cds, yl, k, ord_ult[ok_] + k - 1, f"Piano della coorte {ord_ult[ok_]}: ordinamento senza iscritti")
        ins = list(insegnamenti.values())
        for i in ins:
            ps = i.pop("_percorsi")
            comune = i.pop("_comune")
            if percorsi_nomi and ps and not comune and ps != percorsi_nomi:
                i["curriculum"] = ", ".join(sorted(ps))
        _distingui(ins)
        corsi_out.append({
            "nome": cineca_catalogue._titolo(x.get("des_it") or ""),
            "classe": cineca_catalogue._classe(det.get("classe_cod") or x.get("classe_cod")),
            "tipo_catalogo": x.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": x.get("sedeDenominazioneComune") or x.get("sede_des_it"),
            "codice_ateneo": x.get("cdsCod"), "codici_catalogo": sorted(codici),
            "url": f"{BASE}/corsi/{recente[1]}/{x.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": BASE, "verificato_il": oggi, "insegnamenti": ins,
        })
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    # --- libri dai syllabus ----------------------------------------------------------------------
    def libri_syllabus(sy) -> list[dict]:
        if not isinstance(sy, dict):
            return []
        sy = uniss_testi._normalizza(sy)  # entità HTML annidate («dell&amp;#39;»)
        libri = cineca_catalogue._testi_syllabus(sy)[0] or uniss_testi.libri_uniss(sy)
        return [b for b in libri if uniss_testi.e_citazione(b["citazione"])]

    def con_nota(libri: list[dict], nota: str) -> list[dict]:
        return [dict(b, note=f"{nota}; {b['note']}" if b.get("note") else nota) for b in libri]

    def cerca_libri(job: dict) -> tuple[list[dict], dict | None]:
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        libri = libri_syllabus(sy)
        if libri or not isinstance(sy, dict):
            return libri, sy if isinstance(sy, dict) else None
        m = sy.get("mutuaDa")
        if isinstance(m, dict) and m.get("adId"):  # mutuato: il programma è quello dell'insegnamento di origine
            sy2 = c.get("/insegnamento", {"anno": m.get("aaOffId"), "insegnamento": m.get("adId"),
                                          "corso_cod": m.get("cdsId"), "ordinamento_aa": m.get("aaOrdId"),
                                          "af_percorso": m.get("pdsId")})
            libri = libri_syllabus(sy2)
            if libri:
                return con_nota(libri, f"Dal programma di «{(sy2 or {}).get('des_it', '').title()}», da cui questo "
                                       f"insegnamento è mutuato"), sy
        try:
            aa = int(sy.get("aa"))
        except (TypeError, ValueError):
            return [], sy
        for prec in range(aa - 1, aa - 5, -1):  # programma dell'a.a. precedente dello stesso insegnamento
            for par in indice_ad.get(str(sy.get("adCod")), {}).get(prec) or []:
                libri = libri_syllabus(c.get("/insegnamento", {k: v for k, v in par.items() if v not in (None, "")}))
                if libri:
                    return con_nota(libri, f"Dal programma dell'a.a. {fmt(prec)}: la scheda {fmt(aa)} non riporta "
                                           f"la bibliografia"), sy
        return [], sy

    trovati = 0
    noti = _libri_database()
    riusati = 0
    for n, job in enumerate(syllabus_jobs.values(), 1):
        noto = noti.get(job["ad"])
        if noto:  # libri già raccolti per questo codice nel database: non si rileggono
            riusati += 1
            trovati += len(noto["libri"])
            for it in job["items"]:
                it["libri"] = json.loads(json.dumps(noto["libri"]))
                it["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        it[k_] = noto[k_]
            continue
        try:
            libri, sy = cerca_libri(job)
        except Exception as e:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            log(f"[{uid}]   syllabus {job['ad']} saltato: {e!r}")
            continue
        trovati += len(libri)
        for it in job["items"]:
            it["libri"] = libri
            it["stato_libri"] = "completo" if libri else "da_aggiungere"
            if sy:
                if sy.get("tipoEsaDes_it"):
                    it["modalita_esame"] = sy["tipoEsaDes_it"].lower()
                if sy.get("ssd"):
                    it["ssd"] = sy["ssd"]
                if sy.get("urlSitoWeb"):
                    it["url_sito"] = sy["urlSitoWeb"].strip()
        if n % 200 == 0:
            log(f"[{uid}]   syllabus {n}/{len(syllabus_jobs)}")
    for cs in corsi_out:
        for i in cs["insegnamenti"]:
            nota = i.pop("_nota_anno", None)
            if nota:
                i["note"] = nota
    log(f"[{uid}] libri trovati: {trovati} (già nel database per {riusati} insegnamenti); richieste: {c.requests}")
    doc = {"universita_id": uid, "descrizione": f"Generato da {BASE} (Course Catalogue Cineca)",
           "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
    log(f"[{uid}] corsi con id del database: {associa(doc['corsi'], log)}/{len(doc['corsi'])}")
    # ordinamenti estinti che il database non ha (nessuna iscrizione 2026/27 in un corso dell'offerta): non si creano
    doc["corsi"] = [cs for cs in doc["corsi"] if cs.get("id")]
    for cs in doc["corsi"]:
        _id_unici(cs)
    return doc


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    p = ROOT / "database" / "corsi" / "uniss.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("libri") and cod not in out:
                out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def _canali(codici: list[str]) -> bool:
    """Codici che differiscono per una sola lettera (40X04002 / 40Y04002): canali della stessa disciplina."""
    def una_lettera(c: str) -> bool:
        diff = [(a, b) for a, b in zip(c, codici[0]) if a != b]
        return len(c) == len(codici[0]) and len(diff) <= 1 and all(a.isalpha() and b.isalpha() for a, b in diff)
    return all(una_lettera(c) for c in codici)


def _distingui(ins: list[dict]) -> None:
    """Attività omonime dello stesso anno e curriculum con codici diversi: sono insegnamenti diversi del catalogo (build_db
    unisce quelli con lo stesso nome, anno e CFU). Con CFU diversi il nome porta i CFU; con gli stessi CFU i canali della
    stessa disciplina (codici che differiscono per una lettera, 40X04002 / 40Y04002: lasciati, si uniscono) o le attività distinte (il nome porta
    il codice)."""
    gruppi: dict[tuple, list[dict]] = {}
    for i in ins:
        gruppi.setdefault((_norm(i["nome"]), i.get("anno"), i.get("curriculum")), []).append(i)
    for g in gruppi.values():
        if len({i["codice"] for i in g}) < 2:
            continue
        cfu = {i.get("cfu") for i in g}
        if len(cfu) > 1:
            for i in g:
                if i.get("cfu") is not None:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            continue
        if _canali(sorted(i["codice"] for i in g)):
            continue
        for i in g:
            i["nome"] = f"{i['nome']} ({i['codice']})"


def _slug(s: str, maxlen: int = 40) -> str:
    return re.sub(r"[^a-z0-9]+", "-", unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
                  ).strip("-")[:maxlen].strip("-")


def _id_unici(cs: dict) -> None:
    """Lo stesso codice può essere erogato a più anni di corso (coorti diverse): il primo anno tiene l'id
    solito (corso + codice), gli altri anni «-aN»."""
    viste: set[str] = set()
    for i in sorted(cs["insegnamenti"], key=lambda i: (i.get("anno") or 99)):
        cod = i.get("codice") or i["nome"]
        if cod in viste:
            i["id"] = f"{cs['id']}-{_slug(str(cod))}-a{i.get('anno')}"
        viste.add(cod)


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso l'`id` del corso già nel database (stesso codice del catalogo o stessa denominazione)."""
    p = ROOT / "database" / "corsi" / "uniss.json"
    if not p.exists():
        return 0
    db = json.loads(p.read_text(encoding="utf-8"))["corsi"]
    per_cod: dict[str, list[dict]] = {}
    for d in db:
        if d.get("codice_ateneo"):
            per_cod.setdefault(d["codice_ateneo"], []).append(d)
    n = 0
    for cc in corsi:
        forzato = next((FORZA_ID[k] for k in cc["codici_catalogo"] if k in FORZA_ID), None)
        if forzato:
            cc["id"] = forzato
            n += 1
            continue
        cand = [d for k in cc["codici_catalogo"] for d in per_cod.get(k, []) if d["id"] not in FORZA_ID.values()]
        cand = list({d["id"]: d for d in cand}.values())
        if len(cand) == 1:
            cc["id"] = cand[0]["id"]
            n += 1
        else:
            log(f"[uniss]   corso del catalogo senza corso unico nel database: {cc['nome']} {cc['codici_catalogo']} "
                f"({len(cand)} candidati)")
    return n


def main(argv: list[str]) -> int:
    """Esecuzione locale: scrive `database/contrib/auto/uniss.json` tenendo gli appelli già presenti.

        (da tools/db_builder) python -m adapters.uniss [--senza-syllabus]
    """
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "uniss.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[uniss] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


# --- appelli ---------------------------------------------------------------------------------
def _inizio_aa(oggi=None):
    import datetime
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def fetch_bacheca(uid: str = "uniss", log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027", solo_dip: set[str] | None = None):
    """Bacheca degli appelli dell'offerta di Esse3 (ListaAppelliOfferta), un corso di studio per volta
    (la bacheca per dipartimento ha solo gli appelli dell'attività, senza il corso). Restituisce gli
    appelli per codice AD, i nomi dei corsi di studio in cui compare ogni codice e il titolo di ogni codice.
    Una richiesta ogni `pausa` secondi (0,6 s: meno di 2 al secondo)."""
    import html as _h
    import time as _t

    import requests

    from .esse3_appelli import HEADERS, _parse
    da = da or _inizio_aa().strftime("%d/%m/%Y")
    s = requests.Session()
    s.headers.update(HEADERS)
    r = s.get(ESSE3 + "/ListaAppelliOfferta.do", timeout=60)
    form = re.search(r'<form action="([^"]+)" id="formRicercaCds"', r.text)
    if r.status_code != 200 or not form:
        log(f"[{uid}] esse3: bacheca non raggiungibile (HTTP {r.status_code})")
        return {}, {}, {}
    url = ESSE3 + "/" + form.group(1).split(";")[0]
    base = {"data_da": da, "data_a": a, "TIPO_FORM": "1", "form_id_formRicercaCds": "formRicercaCds"}
    sel = re.search(r'<select id="selectionFacolta".*?</select>', r.text, re.S)
    facs = [v for v in re.findall(r'<option value="([^"]+)"', sel.group(0))] if sel else []
    appelli: dict[str, list[dict]] = {}
    origine: dict[str, set[str]] = {}
    titoli: dict[str, str] = {}
    n_cds = 0

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                _t.sleep(pausa)
                x = s.post(url, data=dati, timeout=180)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            _t.sleep(3 * (tentativo + 1))
        return None

    for fac in facs:
        if solo_dip and fac not in solo_dip:
            continue
        t = post({**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "",
                  "_fw_refresh-form": "selectionFacolta"})
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        cds = re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []
        for cod, etichetta in cds:
            t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
            if t is None:
                log(f"[{uid}] esse3: corso {cod} (dipartimento {fac}) non letto")
                continue
            n_cds += 1
            nome_cds = re.sub(r"^\s*\[\w+\]\s*", "", _h.unescape(etichetta)).strip()
            for ad, lst in _parse(t.replace("Date e ora del turno", "Data e ora del turno"),
                                  ESSE3 + "/ListaAppelliOfferta.do").items():
                origine.setdefault(ad, set()).add(nome_cds)
                titoli.setdefault(ad, lst[0].get("titolo") or "")
                viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(ad, [])}
                for x in lst:
                    k = (x["data"], x["ora"], x["tipo"])
                    if k not in viste:
                        viste.add(k)
                        appelli.setdefault(ad, []).append(x)
    log(f"[{uid}] esse3: {n_cds} corsi di studio, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli, origine, titoli


def _chiave_corso(nome: str | None) -> str:
    """Nome del corso senza vocali e senza «(abilitante …)»: i nomi del catalogo hanno lettere accentate perse
    («Sostenibilit�») e quelli di Esse3 no."""
    return re.sub(r"[aeiou ]", "", _norm(nome))


def _nome_ad(s: str | None) -> str:
    return _norm(re.sub(r"\(.*?\)", " ", s or ""))


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], corsi: list[dict],
                    log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (altro codice in un'altra coorte o in un altro
    corso) si attribuiscono all'insegnamento omonimo del corso di studio che li ospita in Esse3."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[str, dict[str, set[str]]] = {}
    for c in corsi:
        k = _chiave_corso(c["nome"])
        for i in c.get("insegnamenti") or []:
            if i.get("codice"):
                per_corso.setdefault(k, {}).setdefault(_nome_ad(i["nome"]), set()).add(i["codice"])
    out = {k: list(v) for k, v in appelli.items()}
    n = 0
    for ad, lst in appelli.items():
        if ad in codici:
            continue
        nome = _nome_ad(lst[0].get("titolo"))
        dest: set[str] = set()
        for nome_cds in origine.get(ad, ()):
            dest |= per_corso.get(_chiave_corso(nome_cds), {}).get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[uniss] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli dell'a.a. in corso: bacheca dell'offerta per corso di studio, più quella per dipartimento
    (attività che non stanno in nessun corso di studio dell'offerta)."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    off, origine, _ = fetch_bacheca(uid, log=log)
    out = associa_appelli(off, origine, corsi, log=log) if corsi else off
    try:
        dip = per_dipartimento(uid, ESSE3, log=log)
    except Exception as e:  # noqa: BLE001
        log(f"[{uid}] esse3 per dipartimento: {e!r}")
        dip = {}
    for cod, lst in dip.items():
        v = out.setdefault(cod, [])
        viste = {(e["data"], e["ora"], e["tipo"]) for e in v}
        for e in lst:
            if (e["data"], e["ora"], e["tipo"]) not in viste:
                viste.add((e["data"], e["ora"], e["tipo"]))
                v.append(e)
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti")
    return out


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
