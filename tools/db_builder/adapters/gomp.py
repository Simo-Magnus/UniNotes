"""Insegnamenti, docenti e libri dagli atenei che usano GOMP (es. Roma Tre, Cassino).

GOMP pubblica il catalogo con un'API JSON pubblica (`<ateneo>-public.gomp.it/CourseAPI`),
la stessa delle pagine "PublicData":

- `POST /CourseAPI/getDepartmentsAndCourses` {academicYear} → corsi di studio dell'a.a.
  (uid del regolamento, nome, classi);
- `POST /CourseAPI/getCourse` {uid, academicYear} → curricula → anni → periodi → attività
  (codice, nome, CFU e SSD, moduli, canali con docenti, "books" = testi adottati,
  "bibliography" = testi consigliati). L'API pubblica espone gli anni di corso del
  regolamento della coorte dell'a.a. richiesto (in pratica il 1° anno).
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import pathlib
import re
import threading
import time
import unicodedata

import requests

from .testi import estrai_libri
from .unibo import HEADERS, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
HOSTS = {u: f"https://{u}-public.gomp.it" for u in ("uniroma3", "unicas", "unitus", "unicamillus", "unifortunato", "iul")}
HOSTS["uniroma2"] = "https://uniroma2public.gomp.it"  # Tor Vergata: host senza trattino


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _ita(testi: list | None) -> str:
    for t in testi or []:
        if t.get("iso") == "ita" and (t.get("text") or "").strip():
            return t["text"].strip()
    for t in testi or []:
        if (t.get("text") or "").strip():
            return t["text"].strip()
    return ""


class Api:
    def __init__(self, base: str, rate: float = 3.0):
        self.base, self.s, self.lock, self.gap, self.last, self.requests = base, requests.Session(), threading.Lock(), \
            1.0 / rate, 0.0, 0

    def post(self, metodo: str, dati: dict) -> dict | None:
        for tentativo in range(4):
            with self.lock:
                attesa = self.last + self.gap - time.monotonic()
                if attesa > 0:
                    time.sleep(attesa)
                self.last = time.monotonic()
                self.requests += 1
            try:
                r = self.s.post(f"{self.base}/CourseAPI/{metodo}", json=dati, timeout=180,
                                headers={**HEADERS, "Accept": "application/json", "Content-Type": "application/json"})
                d = r.json()
                return d.get("data") if d.get("success") else None
            except (requests.RequestException, ValueError):
                time.sleep(2 ** tentativo)
        return None

    def corso(self, uid: str, anno: int) -> dict | None:
        return self.post("getCourse", {"mode": "CourseDetail", "uid": uid, "code": "", "academicYear": anno,
                                       "curricula": None, "years": None, "iso": "ita", "showCUINs": "False"})


def _libri(professori: list[dict]) -> list[dict]:
    libri, viste = [], set()
    for p in professori:
        for campo, tipo in (("books", "obbligatorio"), ("bibliography", "consigliato")):
            testo = _ita(p.get(campo)).replace("\n", "<br>")
            for lb in estrai_libri(testo):
                lb["tipo"] = lb["tipo"] or tipo
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(lb)
    return libri


def _attivita(a: dict) -> dict:
    cfu = sum(c.get("credits") or 0 for c in a.get("credits") or []) or None
    ssd = ", ".join(sorted({c.get("sector") for c in a.get("credits") or [] if c.get("sector")})) or None
    prof = [p for part in a.get("partitions") or [] for p in part.get("professors") or []]
    for figlio in a.get("children") or []:
        prof += [p for part in figlio.get("partitions") or [] for p in part.get("professors") or []]
    docenti = sorted({" ".join(w.capitalize() for w in f"{p.get('lastName', '')} {p.get('name', '')}".split())
                      for p in prof if p.get("lastName")})
    return {"codice": a.get("code"), "nome": _titolo(_ita(a.get("name"))), "cfu": int(cfu) if cfu and float(cfu).is_integer()
            else cfu, "ssd": ssd, "docenti": docenti, "libri": _libri(prof),
            "gruppo": bool(a.get("linkedGroup")) or a.get("type") not in (None, "activity")}


def fetch_gomp(uid: str, anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
               corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    base = HOSTS[uid]
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    api = Api(base)
    oggi = time.strftime("%Y-%m-%d")
    elenco = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": anno,
                                                   "courseTypes": ["CorsoDiStudio"]}) or {}
    gomp = [c for s in elenco.get("data") or [] for c in s.get("courses") or []]
    per_nome: dict[str, list[dict]] = {}
    for g in gomp:
        for n in {_norm(_ita(g.get("name"))), _norm(" ".join(t.get("text") or "" for t in g.get("name") or []
                                                             if t.get("iso") == "eng"))}:
            if n:
                per_nome.setdefault(n, []).append(g)
    abbinati = []
    for corso in corsi:
        cand = per_nome.get(_norm(corso["nome"])) or per_nome.get(_norm(corso.get("nome_en") or "")) or []
        cl = {x.strip() for x in (corso.get("classe") or "").split("/")}
        both = [g for g in cand if {re.sub(r"\s+R$", "", x) for x in g.get("classes") or []} & cl] or cand
        if both:
            abbinati.append((corso, both[0]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(gomp)} corsi in GOMP, {len(abbinati)} associati al database (su {len(corsi)})")

    def build(coppia) -> dict | None:
        corso, g = coppia
        attuale = api.corso(g["uid"], anno)
        if not attuale:
            return None
        # Il "CourseDetail" pubblico mostra, per ogni regolamento, solo gli anni già pubblicati
        # (di fatto il 1° anno della coorte): gli anni successivi dell'a.a. corrente non sono
        # nei regolamenti delle coorti precedenti e restano da aggiungere.
        coorti = {anno: attuale}
        durata = corso.get("durata_anni") or g.get("years") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        fonte = f"{base}/PublicData?uid={g['uid']}&mode=CourseDetail&iso=ita&academicYear={anno}"
        for k in range(1, durata + 1):
            dati = coorti.get(anno - k + 1)
            if isinstance(dati, str):
                dati = api.corso(dati, anno - k + 1)
            if not dati:
                continue
            curr_list = dati.get("curricula") or []
            for cu in curr_list:
                nome_c = _ita(cu.get("name"))
                if nome_c and len(curr_list) > 1:
                    curricula.add(nome_c)
                for y in cu.get("years") or []:
                    if y.get("number") != k:
                        continue
                    for u in y.get("units") or []:
                        for a in u.get("activities") or []:
                            x = _attivita(a)
                            if not x["nome"]:
                                continue
                            key = f"{k}:{x['codice'] or x['nome']}"
                            item = righe.get(key)
                            if not item:
                                item = righe[key] = {
                                    "codice": x["codice"], "nome": x["nome"], "anno": k,
                                    "periodo": str(u.get("number")) if u.get("number") else None, "cfu": x["cfu"],
                                    "ssd": x["ssd"], "obbligatorio": not x["gruppo"], "curriculum": None,
                                    "docenti": x["docenti"], "url": fonte, "libri": x["libri"], "esami": [],
                                    "fonte": fonte, "verificato_il": oggi, "_c": set(),
                                }
                                if syllabus:
                                    item["stato_libri"] = "completo" if x["libri"] else "da_aggiungere"
                            item["_c"].add(nome_c if len(curr_list) > 1 else None)
        for i in righe.values():
            cs = i.pop("_c")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": fonte, "curricula": sorted(curricula) or None, "fonte": fonte, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(coppia) -> dict | None:
        try:
            return build(coppia)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {coppia[0].get('id')} saltato: {e!r}")
            return None

    out = []
    with cf.ThreadPoolExecutor(3) as ex:
        for n, r in enumerate(ex.map(build_safe, abbinati), 1):
            if r:
                out.append(r)
            if n % 10 == 0:
                log(f"[{uid}]   corsi {n}/{len(abbinati)}")
    libri = sum(len(i["libri"]) for x in out for i in x["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {libri}; "
        f"richieste: {api.requests}")
    return {"universita_id": uid, "descrizione": f"Generato dall'API pubblica GOMP {base} (adapters/gomp.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def fetch_ateneo(uid: str, anno: int | None = None, **kw) -> dict:
    return fetch_gomp(uid, anno, **kw)


def _data_gomp(s: str | None) -> tuple[str | None, str | None]:
    m = re.match(r"(\d{4}-\d{2}-\d{2})(?:T(\d{2}:\d{2}))?", s or "")
    return (m.group(1), m.group(2) if m and m.group(2) != "00:00" else None) if m else (None, None)


def fetch_appelli(uid: str, corsi: list[dict] | None = None, anno: int | None = None, log=print) -> dict[str, list[dict]]:
    """Appelli dalle schede pubbliche dei docenti (`getProfessor` → `appelliList`), per codice insegnamento.

    Solo alcuni atenei li pubblicano (Cassino sì; Roma Tre, Tor Vergata, Tuscia no). I docenti
    sono quelli dei corsi dell'a.a. nell'API pubblica.
    """
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    base = HOSTS[uid]
    api = Api(base)
    elenco = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": anno,
                                                   "courseTypes": ["CorsoDiStudio"]}) or {}
    profs: set[str] = set()

    def raccogli(o) -> None:
        if isinstance(o, dict):
            profs.update(p["uid"] for p in o.get("professors") or [] if p.get("uid"))
            for v in o.values():
                raccogli(v)
        elif isinstance(o, list):
            for v in o:
                raccogli(v)

    with cf.ThreadPoolExecutor(3) as ex:
        for d in ex.map(lambda g: api.corso(g["uid"], anno),
                        [c for s in elenco.get("data") or [] for c in s.get("courses") or []]):
            raccogli(d)
    fonte = f"{base}/PublicData"

    def appelli(p: str) -> list[dict]:
        for tentativo in range(3):
            try:
                r = api.s.post(f"{base}/CourseAPI/getProfessor", timeout=120,
                               json={"mode": "professorDetail", "uid": p, "code": "", "academicYear": anno, "name": "",
                                     "lastName": "", "iso": "ita"},
                               headers={**HEADERS, "Accept": "application/json", "Content-Type": "application/json"})
                with api.lock:
                    api.requests += 1
                d = r.json()
                return [{**a, "_doc": " ".join(w.capitalize() for w in
                                               f"{(d.get('data') or {}).get('lastName', '')} "
                                               f"{(d.get('data') or {}).get('name', '')}".split()) or None}
                        for a in d.get("appelliList") or []]
            except (requests.RequestException, ValueError):
                time.sleep(2 ** tentativo)
        return []

    out: dict[str, dict[tuple, dict]] = {}
    with cf.ThreadPoolExecutor(3) as ex:
        for lst in ex.map(appelli, sorted(profs)):
            for a in lst:
                data, ora = _data_gomp(a.get("DataAppello"))
                if not data:
                    continue
                prove = [n for k, n in (("valutazioneProvaScritta", "scritto"), ("valutazioneProvaOrale", "orale"),
                                        ("valutazioneTestAttitudinale", "quiz"), ("valutazioneProgetto", "progetto"))
                         if a.get(k)]
                e = {"tipo": "appello", "titolo": None, "data": data, "ora": ora, "luogo": (a.get("Aula") or "").strip() or None,
                     "modalita": "scritto+orale" if prove == ["scritto", "orale"] else (prove[0] if len(prove) == 1 else
                                                                                       ("altro" if prove else None)),
                     "iscrizioni_dal": _data_gomp(a.get("dataInizioPrenotazione"))[0],
                     "iscrizioni_al": _data_gomp(a.get("dataFinePrenotazione"))[0],
                     "docenti": a["_doc"], "note": (a.get("TipoSessione") or "").strip() or None, "fonte": fonte}
                for ins in a.get("Insegnamenti") or []:
                    if ins.get("CodiceInsegnamento"):
                        e2 = dict(e, titolo=_titolo(ins.get("DenominazioneInsegnamento") or "") or None)
                        out.setdefault(str(ins["CodiceInsegnamento"]), {})[(a.get("AppelloID"), data, ora)] = e2
    res = {k: sorted(v.values(), key=lambda e: (e["data"], e["ora"] or "")) for k, v in out.items()}
    log(f"[{uid}] appelli GOMP: {len(profs)} docenti, {sum(len(v) for v in res.values())} date per {len(res)} "
        f"insegnamenti; richieste: {api.requests}")
    return res
