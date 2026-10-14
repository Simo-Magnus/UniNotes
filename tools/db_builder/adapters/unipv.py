"""Università di Pavia: Course Catalogue Cineca con le correzioni che servono a UniPV.

- Con il nuovo ordinamento molti corsi hanno cambiato codice (es. Lettere: 05413 nella coorte
  2024, 05434 dalla 2025): il piano del 2° e 3° anno si cerca nella coorte giusta per nome, sede
  e tipo (`coorte_per_nome`), invece di prendere il piano futuro della coorte che si iscrive ora
  (per il quale i syllabus non esistono ancora).
- Il catalogo elenca anche corsi interateneo con sede in altri atenei (Bicocca, Statale di Milano,
  Cagliari, Bergamo): non si associano a nessun corso del database e si scartano.
- Le sedi (Infermieristica a Pavia, Città di Pavia, Maugeri e Vigevano; Scienze motorie a Pavia e
  Voghera) sono corsi a sé nel catalogo e «REPLICA …» di Universitaly: si associano con l'`id`.
- Testi in forma libera dei syllabus: estrazione tollerante di UniPD (`unipd.libri_liberi`).

Con la variabile d'ambiente UN_HTTP_CACHE le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re

from . import cineca_catalogue
from .unipd import TIPI as _TIPI, _norm
from .unipv_testi import libri_unipv

TIPI = {**_TIPI, "L2": "L", "L1": "L"}

BASE = "https://unipv.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
# suffisso del codice del corso nel catalogo -> parola della «REPLICA …» di Universitaly
# durata legale dal tipo di corso del catalogo (L2 = laurea, LM = magistrale, LM5/LM6 = ciclo unico)
ANNO_BASE = 2026
# codice del corso nelle coorti precedenti -> codice attuale, per i corsi che con il nuovo ordinamento hanno
# cambiato nome e codice (stessa classe, stesso dipartimento: verificati sui piani del catalogo)
ALIAS_CDS = {"08403": "08436",  # Scienze e tecnologie per la natura -> Scienze naturali e ambientali (L-32)
             "02410": "02421", "02416": "02421",  # Economics, development and innovation -> Economics and data analysis (LM-56)
             "02409": "02418",  # International business and entrepreneurship - Management internazionale (LM-77)
             "06417": "06433",  # Industrial automation engineering - Ingegneria dell'automazione industriale (LM-25)
             "04418": "04433",  # Scienze infermieristiche e ostetriche -> … - Profilo infermieristico (LM/SNT1)
             "03404": "03414",  # Governo e politiche pubbliche -> Governo, amministrazione e territorio (LM-63)
             "03405": "03415",  # World politics and international relations (Politica nel mondo…) (LM-62)
             "04401": "04431",  # Medicina e chirurgia (in lingua inglese) -> Medicine and surgery (LM-41)
             "02400": "02413"}  # Amministrazione, controllo e finanza aziendale -> Amministrazione e governance (L-18)
NOMI_ALIAS = {"08436": "scienze naturali e ambientali", "02421": "economics and data analysis for industry and policy",
              "02418": "international business and entrepreneurship", "06433": "industrial automation engineering",
              "04433": "scienze infermieristiche e ostetriche profilo infermieristico",
              "03414": "governo amministrazione e territorio", "03415": "world politics and international relations",
              "04431": "medicine and surgery", "02413": "amministrazione e governance"}
DURATE = {"L2": 3, "L": 3, "LM": 2, "LM5": 5, "LM6": 6}
REPLICHE = {"04403C": "CITTA", "04403V": "VIGEVANO", "04403M": "MAUGERI", "04427V": "VOGHERA"}


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unipv_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        r = self._get(path, params)
        if path == "/corsi" and r is not None:
            elenco: list[dict] = []
            cineca_catalogue._walk_cds(r, elenco)
            for x in elenco:
                # l'elenco minimale non ha la durata: senza, il piano è letto su 3 anni anche per le magistrali
                if not x.get("durataAnni"):
                    x["durataAnni"] = DURATE.get(x.get("tipo_corso_cod") or "")
            if params and str(params.get("anno")) < str(ANNO_BASE):
                self._alias(elenco)
        return r

    @staticmethod
    def _alias(elenco: list[dict]) -> None:
        """Corsi che con il nuovo ordinamento hanno cambiato nome e codice: nelle coorti precedenti prendono il
        codice del corso attuale, così il piano si trova per codice (v. ALIAS_CDS)."""
        presenti = {x["cdsCod"] for x in elenco}
        for x in elenco:
            x.setdefault("cdsCodOrig", x["cdsCod"])
            nuovo = ALIAS_CDS.get(x["cdsCod"])
            if nuovo and nuovo not in presenti:
                x["cdsCodAlias"] = (NOMI_ALIAS[nuovo], x.get("tipo_corso_cod"))
                x["cdsCod"] = nuovo

    def _get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _corsi_db() -> list[dict]:
    p = ROOT / "database" / "corsi" / "unipv.json"
    return json.loads(p.read_text(encoding="utf-8"))["corsi"] if p.exists() else []


def associa(corsi: list[dict], db: list[dict], log=print) -> list[dict]:
    """Scrive in ogni corso del contributo l'`id` del corso del database; scarta quelli senza corrispondenza."""
    gruppi: dict[tuple[str, str], list[dict]] = {}
    for c in db:
        base = re.sub(r"(?i)\s+replica\b.*", "", c["nome"])
        gruppi.setdefault((_norm(base), c.get("tipo")), []).append(c)
    usati, out = set(), []
    for cc in sorted(corsi, key=lambda x: x.get("codice_ateneo") or ""):
        nome = _norm(cc["nome"])
        tipo = TIPI.get(cc.get("tipo_catalogo") or "", "")
        if not tipo and (cc.get("classe") or "").upper().startswith("LM"):
            tipo = "LM"
        cand = [c for t in ([tipo, "LP"] if tipo == "L" else [tipo, "L", "LM"] if not tipo else [tipo])
                for c in gruppi.get((nome, t), []) if c["id"] not in usati]
        rep = REPLICHE.get(cc.get("codice_ateneo") or "")
        if len(cand) > 1:
            if rep:
                cand = [c for c in cand if rep in re.sub(r"[^A-Z]", "", c["nome"].upper().split("REPLICA", 1)[-1])
                        and "REPLICA" in c["nome"].upper()]
            else:
                cand = [c for c in cand if not re.search(r"(?i)\breplica\b", c["nome"])]
        if len(cand) == 1:
            cc["id"] = cand[0]["id"]
            usati.add(cand[0]["id"])
            out.append(cc)
        else:
            log(f"[unipv]   corso del catalogo non associato (scartato): {cc['nome']} ({cc.get('codice_ateneo')}, "
                f"{cc.get('sede')}, candidati {len(cand)})")
    return out


def _indice_anni_precedenti(c, anno: int, log=print) -> tuple[dict, dict]:
    """Tutte le attività dei piani delle coorti precedenti: per codice del catalogo e per (corso, nome).
    Ogni voce porta i parametri per leggere il syllabus di quell'anno accademico."""
    per_cod: dict[str, list[dict]] = {}
    per_nome: dict[tuple[str, str], list[dict]] = {}
    for y in range(anno - 5, anno):
        cds: list[dict] = []
        cineca_catalogue._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        for x in [x for x in cds if str(x.get("aa")) == str(y)]:
            d = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(d, list):
                d = d[0] if d else None
            if not d:
                continue
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in a.get("insegnamenti") or ([{"attivita": a.get("attivita")}] if a.get("attivita") else []):
                        for att in g.get("attivita") or []:
                            if not att.get("cod") or str(att.get("aa")) >= str(anno):
                                continue
                            e = {"aa": str(att.get("aa")), "cod": str(att["cod"]),
                                 "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                            "ordinamento_aa": att.get("ordinamento_aa"),
                                            "af_percorso": att.get("corso_percorso_id"),
                                            "corso_cod": att.get("corso_cod"), "corso_aa": y,
                                            "schema_id": att.get("schemaId")}}
                            per_cod.setdefault(e["cod"], []).append(e)
                            per_nome.setdefault((_norm(x["des_it"]), _norm(att.get("des_it"))), []).append(e)
    log(f"[unipv] attività dei piani {anno - 5}-{anno - 1}: {len(per_cod)} codici")
    return per_cod, per_nome


def libri_anno_precedente(doc: dict, c, anno: int, log=print) -> int:
    """Insegnamenti senza libri nel syllabus corrente: si cerca lo stesso insegnamento (stesso codice del
    catalogo, o stesso nome nello stesso corso) nel syllabus dell'a.a. precedente più recente che riporti
    dei testi. I libri hanno una nota che lo dice."""
    per_cod, per_nome = _indice_anni_precedenti(c, anno, log)
    cache: dict[str, list[dict]] = {}

    def libri_di(e: dict) -> list[dict]:
        k = json.dumps(e["params"], sort_keys=True, default=str)
        if k not in cache:
            sy = c.get("/insegnamento", {k2: v for k2, v in e["params"].items() if v not in (None, "")})
            cache[k] = (cineca_catalogue._testi_syllabus(sy)[0] or libri_unipv(sy)) if isinstance(sy, dict) else []
        return cache[k]

    n = 0
    for cc in doc["corsi"]:
        for it in cc["insegnamenti"]:
            if it.get("libri"):
                continue
            m = re.search(r"/insegnamenti/\d+/(\d+)/", it.get("url") or "")
            cand = list(per_cod.get(m.group(1), [])) if m else []
            cand += per_nome.get((_norm(cc["nome"]), _norm(it["nome"])), [])
            visti = set()
            for e in sorted(cand, key=lambda e: e["aa"], reverse=True):
                kk = json.dumps(e["params"], sort_keys=True, default=str)
                if kk in visti:
                    continue
                visti.add(kk)
                libri = libri_di(e)
                if libri:
                    aa = int(e["aa"])
                    nota = f"Testi indicati nel programma dell'a.a. {aa}/{(aa + 1) % 100:02d}: quello {anno}/{(anno + 1) % 100:02d} non li riporta"
                    it["libri"] = [{**lb, "note": lb.get("note") or nota} for lb in libri]
                    it["stato_libri"] = "completo"
                    n += 1
                    break
    log(f"[unipv] insegnamenti con libri dal programma di un a.a. precedente: {n}")
    return n


def fetch_ateneo(uid: str = "unipv", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                        client=ClientCache(BASE), coorte_per_nome=True, libri_extra=libri_unipv)
    libri_anno_precedente(doc, ClientCache(BASE), anno, log)
    doc["corsi"] = associa(doc["corsi"], _corsi_db(), log)
    log(f"[{uid}] corsi associati al database: {len(doc['corsi'])}")
    return doc


def _cds_per_corso(c, anno: int, nomi_tipi: set[tuple[str, str]]) -> dict[tuple[str, str], set[str]]:
    """Codici del corso (cdsCod) di ogni corso del database nelle coorti recenti, per nome e tipo:
    Esse3 elenca i corsi con il codice della coorte (es. [08411] e [08426] per Biologia sperimentale)."""
    out: dict[tuple[str, str], set[str]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cineca_catalogue._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        for x in cds:
            if str(x.get("aa")) != str(y):
                continue
            nome, tipo = x.get("cdsCodAlias") or (_norm(x["des_it"]), x.get("tipo_corso_cod"))
            out.setdefault((nome, TIPI.get(tipo or "", "")), set()).add(x.get("cdsCodOrig") or x["cdsCod"])
    return out


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli dalla bacheca Esse3, un corso di studio alla volta. Oltre che per codice dell'attività
    di Esse3, le date sono assegnate anche al codice dell'insegnamento del catalogo quando i due
    differiscono (stesso nome nello stesso corso di studio)."""
    from datetime import date

    from . import unipv_appelli

    oggi = date.today()

    appelli, per_cds = unipv_appelli.fetch_appelli(uid, corsi, log=log, con_corsi=True, dal=f"{oggi.year if oggi.month >= 9 else oggi.year - 1}-09-01")
    cds_corso = _cds_per_corso(ClientCache(BASE), 2026, set())
    tit: dict[str, str] = {}
    for cod, lst in appelli.items():
        tit[cod] = _norm(next((e["titolo"] for e in lst if e.get("titolo")), ""))
    extra = 0
    for cc in corsi:
        tipo = TIPI.get(cc.get("tipo_catalogo") or "", "")
        cds = cds_corso.get((_norm(cc["nome"]), tipo)) or set()
        cod_esse3 = set().union(*(per_cds.get(x, set()) for x in cds)) if cds else set()
        per_nome = {}
        for ce in cod_esse3:
            per_nome.setdefault(tit.get(ce), []).append(ce)
        for it in cc.get("insegnamenti") or []:
            cod = it.get("codice")
            if not cod or cod in appelli:
                continue
            cand = per_nome.get(_norm(it["nome"])) or []
            if len(cand) >= 1:
                merged = []
                visti = set()
                for ce in cand:
                    for e in appelli[ce]:
                        k = (e["data"], e["ora"], e["tipo"])
                        if k not in visti:
                            visti.add(k)
                            merged.append(e)
                appelli[cod] = merged
                extra += 1
    log(f"[{uid}] appelli: {sum(len(v) for v in appelli.values())} date; {extra} insegnamenti abbinati per nome")
    return appelli
