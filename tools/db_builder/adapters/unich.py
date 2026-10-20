"""Università degli Studi «G. d'Annunzio» di Chieti-Pescara: insegnamenti, libri e appelli.

Piani e syllabus: `https://unich.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Rispetto all'adattatore comune (`cineca_catalogue`) UdA richiede:

- durata: l'elenco minimale non ha `durataAnni`, e l'adattatore comune ripiegava su 3 anni (Architettura,
  Chimica e tecnologia farmaceutiche, Farmacia: 5; Medicina e Odontoiatria: 6, avevano solo 3 anni di
  insegnamenti). Si ricava dal tipo di corso del catalogo (L 3, LM 2, LM5 5, LM6 6);
- coorti: con il riordino i codici dei corsi sono cambiati tra una coorte e l'altra: si cerca il corso
  per nome nelle coorti precedenti (`coorte_per_nome`), altrimenti il 2° e 3° anno sarebbero quelli
  futuri della coorte attuale;
- corsi: solo lauree e lauree magistrali (anche a ciclo unico); i dottorati («D226») non sono corsi di
  studio per il database;
- nomi: «Ingegneria delle costruzioni» (801M) è il corso che Universitaly chiama «Building Engineering»
  (stessa classe LM-24, stesso sito idclm24.unich.it): si scrive l'`id` del corso già presente;
- libri: i testi sono in forma libera (`unich_testi`); se il programma 2026/27 non riporta la
  bibliografia si usa quello dell'a.a. precedente (indicandolo nella nota) o quello dell'insegnamento
  da cui è mutuato.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte restano su disco.
"""
from __future__ import annotations

import hashlib
import html as _h
import json
import os
import pathlib
import re
import time
import unicodedata

from . import cineca_catalogue, unich_piani, unich_testi

BASE = "https://unich.coursecatalogue.cineca.it"
ESSE3 = "https://unich.esse3.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L", "LM", "LM5", "LM6"}
DURATA_TIPO = {"L": 3, "LM": 2, "LM5": 5, "LM6": 6}
# catalogo → corso Universitaly già nel database (stessa classe, altro nome)
ID_CORSO = {"801M": "unich-lm-24-building-engineering"}
# codice del corso nella coorte attuale → codici che aveva nelle coorti precedenti (stesso corso, ordinamento rinnovato)
COD_PRECEDENTI = {"802T": ["801TR", "801T"], "M646": ["M645"]}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = 2.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unich_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def _get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            # lo stesso insegnamento è in più percorsi e il syllabus può stare sotto un altro percorso
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r

    def get(self, path: str, params: dict | None = None):
        r = self._get(path, params)
        if path != "/corsi":
            return r
        elenco: list[dict] = []
        cineca_catalogue._walk_cds(r or [], elenco)
        out = []
        for x in elenco:
            if x.get("tipo_corso_cod") not in TIPI:
                continue
            x = dict(x)
            x["durataAnni"] = x.get("durataAnni") or DURATA_TIPO[x["tipo_corso_cod"]]
            out.append(x)
        # riordino: il corso «610L» delle coorti precedenti è il «610LR» di quella attuale (stesso codice con la «R»,
        # anche quando il nome è cambiato: Economia aziendale → Business Administration)
        anno = (params or {}).get("anno")
        if anno and str(anno) != str(self.anno_attuale):
            attuali = self._codici_attuali()
            for x in out:
                c = x["cdsCod"]
                if c not in attuali and c + "R" in attuali:
                    x["cdsCod"] = c + "R"
                for nuovo, vecchi in COD_PRECEDENTI.items():
                    if c in vecchi and nuovo in attuali:
                        x["cdsCod"] = nuovo
        return out

    anno_attuale = 2026

    def _codici_attuali(self) -> set[str]:
        if not hasattr(self, "_attuali"):
            elenco: list[dict] = []
            cineca_catalogue._walk_cds(self._get("/corsi", {"anno": self.anno_attuale, "minimal": "true"}) or [], elenco)
            self._attuali = {x["cdsCod"] for x in elenco if str(x.get("aa")) == str(self.anno_attuale)}
        return self._attuali


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso del catalogo l'`id` del corso Universitaly già nel database che è lo stesso
    corso con un altro nome; gli altri restano senza `id` (li associa `build_db` per nome e classe)."""
    p = ROOT / "database" / "corsi" / "unich.json"
    esistenti = {c["id"] for c in json.loads(p.read_text(encoding="utf-8"))["corsi"]} if p.exists() else set()
    n = 0
    for cc in corsi:
        i = ID_CORSO.get(cc.get("codice_ateneo"))
        if i and (not esistenti or i in esistenti):
            cc["id"] = i
            n += 1
    return n


def _indice_piani(c: ClientCache, anno: int, durata_max: int = 6) -> dict[str, dict[int, list[dict]]]:
    """adCod → anno di erogazione → parametri del syllabus, da tutti i piani delle coorti (già in cache):
    serve a trovare il programma dell'a.a. precedente dello stesso insegnamento."""
    idx: dict[str, dict[int, list[dict]]] = {}

    def cammina(x):
        if isinstance(x, dict):
            if "adCod" in x and "aa" in x and "cod" in x and "corso_cod" in x:
                par = {"anno": x.get("aa"), "insegnamento": x.get("cod"), "ordinamento_aa": x.get("ordinamento_aa"),
                       "af_percorso": x.get("corso_percorso_id"), "corso_cod": x.get("corso_cod"),
                       "schema_id": x.get("schemaId")}
                v = idx.setdefault(str(x["adCod"]), {}).setdefault(int(x["aa"]), [])
                if par not in v:
                    v.append(par)
            for v in x.values():
                cammina(v)
        elif isinstance(x, list):
            for v in x:
                cammina(v)

    import concurrent.futures as cf
    lavori = [(y, x["cod"]) for y in range(anno - durata_max + 1, anno + 1)
              for x in c.get("/corsi", {"anno": y, "minimal": "true"}) or [] if str(x.get("aa")) == str(y)]
    with cf.ThreadPoolExecutor(6) as ex:  # il ritmo lo fissa il client (2 richieste al secondo)
        for d in ex.map(lambda yc: c.get(f"/corso/{yc[0]}/{yc[1]}"), lavori):
            cammina(d[0] if isinstance(d, list) and d else d)
    return idx


_testi_originale = cineca_catalogue._testi_syllabus


def _testi_syllabus(sy: dict):
    """Libri del syllabus: prima il riconoscimento di UdA (`unich_testi`), altrimenti quello comune senza le voci
    che sono prosa («DISPENSE FORNITE DAL DOCENTE»)."""
    libri, modalita, legati = _testi_originale(sy)
    mio = unich_testi.libri_unich(sy)  # riconoscimento tollerante di UdA; se non trova nulla, quello comune
    return mio or [b for b in libri if not unich_testi.e_prosa(b.get("citazione"))], modalita, legati


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    p = ROOT / "database" / "corsi" / "unich.json"
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


def fetch_ateneo(uid: str = "unich", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache()
    c.anno_attuale = anno
    idx = _indice_piani(c, anno) if syllabus else {}
    fmt = lambda a: f"{a}/{(a + 1) % 100:02d}"  # noqa: E731

    def libri_std(sy) -> list[dict]:
        return (cineca_catalogue._testi_syllabus(sy)[0] if isinstance(sy, dict) else []) or \
            (unich_testi.libri_unich(sy) if isinstance(sy, dict) else [])

    def con_nota(libri: list[dict], nota: str) -> list[dict]:
        return [dict(b, note=f"{nota}; {b['note']}" if b.get("note") else nota) for b in libri]

    def libri_extra(sy: dict) -> list[dict]:
        libri = unich_testi.libri_unich(sy)
        if libri:
            return libri
        m = sy.get("mutuaDa")
        if isinstance(m, dict) and m.get("adId"):  # mutuato: il programma è quello dell'insegnamento di origine
            sy2 = c.get("/insegnamento", {"anno": m.get("aaOffId"), "insegnamento": m.get("adId"),
                                          "corso_cod": m.get("cdsId"), "ordinamento_aa": m.get("aaOrdId"),
                                          "af_percorso": m.get("pdsId")})
            libri = libri_std(sy2)
            if libri:
                return con_nota(libri, f"Dal programma di «{(sy2 or {}).get('des_it', '').title()}», da cui questo "
                                       f"insegnamento è mutuato")
        try:
            aa = int(sy.get("aa"))
        except (TypeError, ValueError):
            return []
        for prima in (0, 1, 2, 3):  # stesso insegnamento (stesso codice) in un altro corso, poi l'ultimo programma pubblicato
            for par in (idx.get(str(sy.get("adCod")), {}).get(aa - prima) or []):
                if prima == 0 and str(par.get("insegnamento")) == str(sy.get("cod")):
                    continue
                libri = libri_std(c.get("/insegnamento", {k: v for k, v in par.items() if v not in (None, "")}))
                if libri:
                    if prima == 0:
                        return con_nota(libri, f"Dal programma dello stesso insegnamento (codice {sy.get('adCod')}) in un altro "
                                               f"corso di studio dell'a.a. {fmt(aa)}: la scheda di questo corso non riporta "
                                               f"la bibliografia")
                    return con_nota(libri, f"Dal programma dell'a.a. {fmt(aa - prima)}: la scheda {fmt(aa)} non "
                                           f"riporta la bibliografia")
        return []

    libri_noti = _libri_database()
    corsi, jobs = unich_piani.fetch_piani(uid, anno, c, BASE, TIPI, log=log, max_cds=max_cds, con_syllabus=syllabus)

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
            return 0
        libri, modalita, legati = _testi_syllabus(sy)
        if not libri:  # estrazione propria dell'ateneo per i testi in forma libera
            libri = libri_extra(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cineca_catalogue.leganto.libri(u)
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
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, jobs.values()), 1):
            trovati += n
            if i % 500 == 0:
                log(f"[{uid}]   syllabus {i}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    doc = {"universita_id": uid, "descrizione": f"Generato da {BASE} (Course Catalogue Cineca, adapters/unich_piani.py)",
           "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi, "canali": []}
    log(f"[{uid}] corsi con id del database: {associa(doc['corsi'], log)}/{len(doc['corsi'])}")
    return doc


# --- appelli ---------------------------------------------------------------------------------
def _inizio_aa(oggi=None):
    import datetime
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def fetch_bacheca(uid: str = "unich", log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027") -> tuple[dict[str, list[dict]], dict[str, set[str]], dict[str, str]]:
    """Bacheca degli appelli dell'offerta di Esse3 (ListaAppelliOfferta), un corso di studio per volta
    (la bacheca per dipartimento ha solo gli appelli dell'attività, senza il corso). Restituisce gli
    appelli per codice AD, le etichette «[codice] NOME» dei corsi di studio in cui compare ogni codice e
    il titolo di ogni codice."""
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
    letti: set[str] = set()

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                x = s.post(url, data=dati, timeout=180)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            _t.sleep(3 * (tentativo + 1))
        return None

    for fac in facs:
        t = post({**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "",
                  "_fw_refresh-form": "selectionFacolta"})
        _t.sleep(pausa)
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        cds = re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []
        for cod, etichetta in cds:
            if cod in letti:
                continue
            t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
            _t.sleep(pausa)
            if t is None:
                log(f"[{uid}] esse3: corso {cod} (dipartimento {fac}) non letto")
                continue
            letti.add(cod)
            nome_cds = _h.unescape(etichetta).strip()
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
    log(f"[{uid}] esse3: {len(letti)} corsi di studio, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli, origine, titoli


def _nome_ad(s: str | None) -> str:
    return _norm(re.sub(r"\(.*?\)", " ", s or ""))


def _cds_etichetta(e: str) -> tuple[str, str]:
    """«[L603] INFERMIERISTICA (ABILITANTE…» → («l603», nome senza parentesi)."""
    m = re.match(r"\s*\[([^\]]+)\]\s*(.*)", e)
    cod, nome = (m.group(1), m.group(2)) if m else ("", e)
    return _norm(cod), _norm(re.sub(r"\(.*", "", nome))


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], titoli: dict[str, str],
                    corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (altro codice in un'altra coorte o ordinamento)
    si attribuiscono all'insegnamento omonimo del corso di studio che li ospita in Esse3 (stesso codice
    corso, oppure stesso nome)."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[tuple[str, str], dict[str, set[str]]] = {}
    for c in corsi:
        k = (_norm(c.get("codice_ateneo")), _norm(re.sub(r"\(.*", "", c["nome"])))
        for i in c.get("insegnamenti") or []:
            if i.get("codice"):
                per_corso.setdefault(k, {}).setdefault(_nome_ad(i["nome"]), set()).add(i["codice"])
    out = {k: list(v) for k, v in appelli.items()}
    n = 0
    for ad, lst in appelli.items():
        if ad in codici:
            continue
        nome = _nome_ad(titoli.get(ad) or lst[0].get("titolo"))
        dest: set[str] = set()
        for etichetta in origine.get(ad, ()):
            cod_e, nome_e = _cds_etichetta(etichetta)
            for (cod_c, nome_c), ins in per_corso.items():
                if cod_c == cod_e or nome_c == nome_e or nome_e.startswith(nome_c) or nome_c.startswith(nome_e):
                    dest |= ins.get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[unich] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli dell'a.a. in corso: bacheca dell'offerta per corso di studio, più quella per dipartimento
    (attività che non stanno in nessun corso di studio dell'offerta)."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    off, origine, titoli = fetch_bacheca(uid, log=log)
    out = associa_appelli(off, origine, titoli, corsi, log=log) if corsi else off
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


def main(argv: list[str]) -> int:
    """Esecuzione locale: scrive `database/contrib/auto/unich.json` (o il file di `--out`) tenendo gli appelli già presenti.

        python tools/db_builder/adapters/unich.py [--senza-syllabus] [--out file.json]
    """
    import sys as _s
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else ROOT / "database" / "contrib" / "auto" / "unich.json"
    vecchio_p = ROOT / "database" / "contrib" / "auto" / "unich.json"
    try:
        vecchio = json.loads(vecchio_p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unich] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    import sys as _sys
    if __package__ in (None, ""):
        _sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    _sys.exit(main(_sys.argv[1:]))
