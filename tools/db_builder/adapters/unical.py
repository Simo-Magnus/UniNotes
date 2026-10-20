"""Insegnamenti, docenti e libri dell'Università della Calabria dall'API pubblica "ricerca".

Il portale dei corsi (corsi.unical.it) legge i dati da un'API JSON pubblica
(`storage.portale.unical.it/api/ricerca`):

- `/cds/?academicyear=<A>` → corsi di studio dell'a.a. (RegDidId = regolamento della coorte A);
- `/cds/<RegDidId>/studyplans-activities/` → piani per curriculum, attività per anno con
  codice Esse3 (lo stesso degli appelli), CFU, obbligatorietà, SSD, semestre, moduli;
  per l'anno di corso k nell'a.a. A si usa il regolamento della coorte A-k+1;
- `/activities/<id>/` → docente e contenuti del syllabus (testi di riferimento).

I corsi si associano a quelli di database/corsi/unical.json per classe e nome.
"""
from __future__ import annotations

import concurrent.futures as cf
from collections import Counter
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
API = "https://storage.portale.unical.it/api/ricerca"
SITO = "https://corsi.unical.it"


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _periodo_singolo(t: str | None) -> str | None:
    t = (t or "").strip().lower()
    if not t:
        return None
    if "annual" in t:
        return "annuale"
    for k, v in (("primo", "1"), ("secondo", "2"), ("terzo", "3")):
        if t.startswith(k):
            return v
    return t


def _periodo(sem: list | str | None, moduli: list[dict] | None = None) -> str | None:
    """Periodo di un'attività del piano. `StudyActivitySemester` è una lista con i semestri dei moduli
    (`AfSubModules`): con un solo valore vale quello; con più valori, se i moduli sono distinti (codice o nome
    diversi) e ciascuno ha un solo semestre, i moduli sono in semestri diversi: annuale; se lo stesso
    modulo compare in due semestri (due edizioni a scelta, «Primo» e «Secondo Semestre» per lo stesso codice)
    il semestre non è determinato: None (non si sceglie il primo della lista)."""
    voci = [str(x) for x in sem if x] if isinstance(sem, list) else ([str(sem)] if sem else [])
    valori = {_periodo_singolo(x) for x in voci}
    if len(valori) <= 1:
        return next(iter(valori), None)
    per_modulo: dict[tuple, set] = {}
    for m in moduli or []:
        s = m.get("StudyActivitySemester")
        for x in (s if isinstance(s, list) else [s]):
            if x:
                per_modulo.setdefault((m.get("StudyActivityCod"), _norm(m.get("StudyActivityName") or "")), set()).add(
                    _periodo_singolo(x))
    if not per_modulo or any(len(v) > 1 for v in per_modulo.values()):
        return None
    return "annuale" if len(set().union(*per_modulo.values())) > 1 else None


def _cfu_attivita(a: dict):
    """CFU di un'attività del piano. Gli insegnamenti integrati (e quelli a canali) arrivano senza
    `StudyActivityECTS`: i CFU stanno nei moduli (`AfSubModules`). Gli stessi codice e nome con
    partizioni diverse (A-L / M-Z, canali) sono lo stesso insegnamento in più copie: si conta una volta;
    i moduli distinti si sommano."""
    cfu = a.get("StudyActivityECTS")
    if isinstance(cfu, (int, float)):
        return int(cfu) if float(cfu).is_integer() else cfu
    gruppi: dict[tuple, float] = {}
    for m in a.get("AfSubModules") or []:
        v = m.get("StudyActivityCreditValue")
        if isinstance(v, (int, float)):
            k = (m.get("StudyActivityCod"), _norm(m.get("StudyActivityName")))
            gruppi[k] = max(gruppi.get(k, 0), v)
    if not gruppi:
        return None
    tot = sum(gruppi.values())
    return int(tot) if float(tot).is_integer() else tot


def fetch_ateneo(uid: str = "unical", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=5.0)
    oggi = time.strftime("%Y-%m-%d")

    def lista(a: int) -> list[dict]:
        out, url = [], f"{API}/cds/?lang=it&academicyear={a}&page_size=100"
        while url:
            r = c.get(url)
            if not r:
                break
            d = json.loads(r.text)
            out += d.get("results") or []
            url = d.get("next")
            if url and url.startswith("//"):  # l'API restituisce URL senza schema
                url = "https:" + url
        return out

    per_anno = {a: lista(a) for a in range(anno - 5, anno + 1)}

    def trova(corso: dict, cds_list: list[dict]) -> dict | None:
        cl = {x.strip() for x in re.split(r"/", (corso.get("classe") or "").replace(" R", ""))}
        nome = _norm(corso["nome"])
        cand = [x for x in cds_list if _norm(x.get("CdSName")) == nome]
        both = [x for x in cand if (x.get("CourseClassCod") or "").replace(" R", "").strip() in cl]
        return (both or cand or [None])[0]

    classi_db = Counter((x.get("classe") or "").replace(" R", "").strip() for x in corsi)
    abbinati = []
    for corso in corsi:
        x = trova(corso, per_anno[anno])
        if x:
            abbinati.append((corso, x))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(abbinati)} corsi del database associati all'API (su {len(corsi)})")

    def build(coppia) -> dict | None:
        corso, attuale = coppia
        durata = corso.get("durata_anni") or attuale.get("CdSDuration") or 3
        classe_att = (attuale.get("CourseClassCod") or "").replace(" R", "").strip()
        righe: dict[str, dict] = {}
        curricula = set()
        def piani_di(reg: dict) -> list[dict]:
            piani, url = [], f"{API}/cds/{reg['RegDidId']}/studyplans-activities/?lang=it"
            while url:  # i piani sono paginati: la seconda pagina ha altri piani/curricula
                r = c.get(url)
                if not r:
                    break
                d = json.loads(r.text)
                piani += d.get("results") or []
                url = d.get("next")
                if url and url.startswith("//"):
                    url = "https:" + url
            return piani

        def regolamento(coorte: int) -> dict | None:
            lista_c = per_anno.get(coorte, [])
            # stesso codice; se l'ordinamento è cambiato, stesso nome e classe; se il corso è stato
            # rinominato, l'unico corso di quella classe (e unico anche tra quelli del database)
            reg = next((x for x in lista_c if x.get("CdSCod") == attuale["CdSCod"]), None) or trova(corso, lista_c)
            if reg or classi_db.get(classe_att, 0) != 1:
                return reg
            cand = [x for x in lista_c if (x.get("CourseClassCod") or "").replace(" R", "").strip() == classe_att]
            return cand[0] if len(cand) == 1 else None

        for k in range(1, durata + 1):
            # regolamento della coorte A-k+1; se non c'è (corso nuovo o non in elenco), quello
            # della coorte più vecchia successiva che ha attività nell'anno k (la fonte resta quella usata)
            piani = reg = None
            for coorte in range(anno - k + 1, anno + 1):
                reg = regolamento(coorte)
                if not reg:
                    continue
                piani = piani_di(reg)
                if any((t.get("StudyActivities") or {}).get(str(k)) for p in piani for t in p.get("PlanTabs") or []):
                    break
                piani = None
            if not piani:
                continue
            tabs = [t for p in piani for t in p.get("PlanTabs") or []]
            for tab in tabs:
                nome_piano = (tab.get("StudyPlanName") or "").strip()
                if len(tabs) > 1 and nome_piano:
                    curricula.add(nome_piano)
                for a in (tab.get("StudyActivities") or {}).get(str(k), []):
                    key = f"{k}:{a.get('StudyActivityCod')}"
                    item = righe.get(key)
                    if not item:
                        cfu = _cfu_attivita(a)
                        item = righe[key] = {
                            "codice": a.get("StudyActivityCod"), "nome": _titolo(a.get("StudyActivityName") or ""),
                            "anno": k, "periodo": _periodo(a.get("StudyActivitySemester"), a.get("AfSubModules")),
                            "cfu": cfu,
                            "ssd": ", ".join(a.get("StudyActivitySSD") or []) or None,
                            "obbligatorio": a.get("StudyActivityCompulsory"), "curriculum": None, "docenti": [],
                            "url": f"{SITO}/activities/{a['StudyActivityID']}/" if a.get("StudyActivityID") else None,
                            "libri": [], "esami": [], "fonte": f"{API}/cds/{reg['RegDidId']}/studyplans-activities/",
                            "verificato_il": oggi, "_ids": [a.get("StudyActivityID")] +
                            [m.get("StudyActivityID") for m in a.get("AfSubModules") or []], "_curr": set(),
                        }
                    item["_curr"].add(nome_piano if len(tabs) > 1 else None)
        for i in righe.values():
            cs = i.pop("_curr")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": corso.get("url"), "curricula": sorted(curricula) or None,
                "fonte": f"{API}/cds/{attuale['RegDidId']}/", "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(coppia) -> dict | None:
        try:
            return build(coppia)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {coppia[0].get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, abbinati) if r]
    ids = sorted({i for x in out for it in x["insegnamenti"] for i in it["_ids"] if i})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"attività da leggere: {len(ids) if syllabus else 0}")
    dati: dict[int, dict] = {}

    def leggi(aid: int) -> None:
        try:
            r = c.get(f"{API}/activities/{aid}/?lang=it")
            d = json.loads(r.text).get("results") or {} if r else {}
            testi = [x.get("StudyActivityContentDes") or "" for x in d.get("StudyActivityContents") or []
                     if re.search(r"(?i)testi|bibliograf|textbook", (x.get("StudyActivityContentCod") or "") + " " +
                                  (x.get("StudyActivityContentTitle") or ""))]
            doc = d.get("StudyActivityTeacherName")
            dati[aid] = {"docenti": [" ".join(w.capitalize() for w in doc.split())] if doc else [],
                         "libri": estrai_libri("<br>".join(t.replace("\n", "<br>") for t in testi))}
        except Exception:  # noqa: BLE001
            dati[aid] = {"docenti": [], "libri": []}

    if syllabus:
        with cf.ThreadPoolExecutor(5) as ex:
            for n, _ in enumerate(ex.map(leggi, ids), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   attività {n}/{len(ids)}")
    trovati = 0
    for x in out:
        for it in x["insegnamenti"]:
            docenti, viste = set(), set()
            for i in it.pop("_ids"):
                d = dati.get(i) or {}
                docenti |= set(d.get("docenti") or [])
                for lb in d.get("libri") or []:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        it["libri"].append(lb)
            it["docenti"] = sorted(docenti)
            if syllabus:
                it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
            trovati += len(it["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dall'API pubblica storage.portale.unical.it (adapters/unical.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
