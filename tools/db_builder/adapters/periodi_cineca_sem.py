"""Periodo didattico (semestre) degli insegnamenti dal Course Catalogue Cineca pubblico dell'ateneo.

Il piano di una coorte (`GET /api/v1/corso/<coorte>/<cod>`) riporta il periodo di ogni attività nei campi
`periodo_didattico_it` e `data_inizio/fine_periodo_didattico`; `cineca_catalogue.fetch_ateneo` legge però
solo il primo livello, mentre per molti insegnamenti il periodo sta nell'elenco `frazioni` (o nei `moduli`)
e, per gli insegnamenti non erogati nella coorte della scheda, solo nelle schede di altre coorti / anni
accademici. Qui si legge tutto e si risale, nell'ordine, a:

 0. la scheda stessa (primo livello, `frazioni`, `moduli`; poi il syllabus dell'insegnamento);
 1. la scheda dello STESSO insegnamento (stesso corso di studio, stesso codice d'attività) di un'altra
    coorte / altro anno accademico, la più recente che lo riporta (anche il suo syllabus);
 2. lo stesso codice d'attività in un altro corso di studio dell'ateneo, solo se tutte le schede dell'a.a.
    più recente che lo riportano concordano.

Il periodo non si deduce mai dall'anno di corso, dal nome o da altri insegnamenti. Un periodo che l'app non
sa interpretare (es. «Ciclo 3» senza date) non si usa. `fonte` è la pagina del catalogo che lo dice.
Le risposte restano su disco in `$UN_HTTP_CACHE/<uid>_cc` (stessa cache e stessa chiave degli adattatori).
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys
from collections import defaultdict

from . import cineca_catalogue as cc, periodi

sys.path.insert(0, str(periodi.ROOT / "tools" / "db_builder"))
import pulizia  # noqa: E402

VUOTI = {"", "undefined", "non definito", "-", "--"}
OK = {"1", "2", "annuale"}
SYLLABUS_MAX = 4  # richieste di syllabus per insegnamento
DATA = re.compile(r"\d{2}/\d{2}/\d{4}$")


class Cache(cc.Client):
    def __init__(self, uid: str, base: str, rate: float = 1.6):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / f"{uid}_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path, params=None):
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json" if self.dir else None
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None and f:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _g(s: str) -> tuple:
    d, m, a = s.split("/")
    return int(a), int(m), int(d)


def _voci(x: dict) -> list[tuple[str, str, str]]:
    """[(testo, inizio, fine)] del primo livello e delle `frazioni` di un'attività (o di un syllabus)."""
    out = []
    for y in [x] + [f for f in (x.get("frazioni") or []) if isinstance(f, dict)]:
        t = (y.get("periodo_didattico_it") or "").strip()
        a, b = (y.get("data_inizio_periodo_didattico") or "").strip(), (y.get("data_fine_periodo_didattico") or "").strip()
        if t.lower() in VUOTI:
            t = ""
        if not (DATA.match(a) and DATA.match(b)):
            a = b = ""
        if t or a:
            out.append((t, a, b))
    return out


def riassumi(voci: list[tuple[str, str, str]]) -> dict | None:
    """Un solo periodo: date (le più ampie, se più frazioni) e testo se è uno solo; None se non interpretabile."""
    date = [(a, b) for _, a, b in voci if a]
    testi = {t for t, _, _ in voci if t}
    r: dict = {}
    if date:
        r["periodo_inizio"] = min((d[0] for d in date), key=_g)
        r["periodo_fine"] = max((d[1] for d in date), key=_g)
    if len(testi) == 1:
        r["periodo"] = next(iter(testi))
    if not r:
        return None
    sem = pulizia.periodo(r.get("periodo"), r.get("periodo_inizio"), r.get("periodo_fine"))
    if sem not in OK:
        return None
    r["sem"] = sem
    return r


def periodo_attivita(a: dict) -> dict | None:
    """Periodo di un'attività del piano: primo livello/frazioni, altrimenti i suoi `moduli` (se concordano)."""
    r = riassumi(_voci(a))
    if r:
        return r
    mod = [m for m in (a.get("moduli") or []) if isinstance(m, dict)]
    rs = [riassumi(_voci(m)) for m in mod]
    if mod and all(rs) and len({x["sem"] for x in rs}) == 1:
        return riassumi([v for m in mod for v in _voci(m)])
    return None


def _attivita(x):
    if isinstance(x, dict):
        if "adCod" in x and "cod" in x and "aa" in x:
            yield x
        for v in x.values():
            yield from _attivita(v)
    elif isinstance(x, list):
        for v in x:
            yield from _attivita(v)


def indice(c: Cache, anni, log=print) -> list[dict]:
    """Tutte le attività dei piani delle coorti `anni`."""
    out = []
    for y in anni:
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        cds = [x for x in cds if str(x.get("aa")) == str(y)]
        if not cds:
            continue
        n = 0
        for x in cds:
            d = c.get(f"/corso/{y}/{x['cod']}")
            if isinstance(d, list):
                d = d[0] if d else None
            for a in _attivita(d or {}):
                out.append({"y": y, "cds": x["cdsCod"], "chiave": cc._chiave_cds(x), "ad": str(a["adCod"]), "att": a})
                n += 1
        log(f"  coorte {y}: {len(cds)} corsi, {n} attività")
    return out


def pagina(base: str, a: dict, y) -> str:
    return (f"{base.rstrip('/')}/insegnamenti/{a.get('aa')}/{a.get('cod')}/{a.get('ordinamento_aa')}/"
            f"{a.get('corso_percorso_id')}?coorte={y}")


def syllabus(c: Cache, e: dict) -> dict | None:
    a = e["att"]
    p = {"anno": a.get("aa"), "insegnamento": a.get("cod"), "ordinamento_aa": a.get("ordinamento_aa"),
         "af_percorso": a.get("corso_percorso_id"), "corso_cod": a.get("corso_cod"), "corso_aa": e["y"],
         "schema_id": a.get("schemaId")}
    sy = c.get("/insegnamento", {k: v for k, v in p.items() if v not in (None, "")})
    return riassumi(_voci(sy)) if isinstance(sy, dict) else None


def fetch(uid: str, base: str, anno: int = 2026, anni=None, log=print, usa_syllabus: bool | None = None,
          rate: float = 1.6) -> tuple[dict, dict]:
    """({id_insegnamento: {periodo…, fonte}}, {id: motivo della lacuna})."""
    if usa_syllabus is None:
        usa_syllabus = os.environ.get("SEMESTRI_SYLLABUS", "1") == "1"
    manc = periodi.mancanti(uid)
    c = Cache(uid, base, rate)
    log(f"[{uid}] {len(manc)} insegnamenti senza periodo; lettura dei piani delle coorti")
    idx = indice(c, anni or range(2016, anno + 1), log)
    per_ad: dict[str, list[dict]] = defaultdict(list)
    per_url: dict[tuple, dict] = {}
    for e in idx:
        per_ad[e["ad"]].append(e)
        per_url[(e["y"], str(e["att"].get("cod")))] = e
    ris: dict[str, dict] = {}
    lacune: dict[str, str] = {}
    via: dict[str, int] = defaultdict(int)

    def cerca(es: list[dict], budget: list[int]):
        """Tra le schede `es` (stesso insegnamento), la più recente che riporta il periodo: (voce, scheda).
        `budget`: richieste di syllabus ancora consentite per questo insegnamento (le schede non erogate si saltano)."""
        for aa in sorted({int(e["att"].get("aa") or 0) for e in es}, reverse=True):
            gruppo = [e for e in es if int(e["att"].get("aa") or 0) == aa]
            trovati = []
            for e in sorted(gruppo, key=lambda e: -e["y"]):
                r = periodo_attivita(e["att"])
                if not r and usa_syllabus and budget[0] > 0 and e["att"].get("statoErogMod") not in ("NE",):
                    budget[0] -= 1
                    r = syllabus(c, e)
                if r:
                    trovati.append((r, e))
            if trovati and len({t[0]["sem"] for t in trovati}) == 1:
                return trovati[0]
            if trovati:
                return "conflitto"
        return None

    for m in manc:
        mm = re.search(r"/insegnamenti/(\d{4})/([^/]+)/(\d+)/([^/?]+)\?coorte=(\d{4})", m.get("url") or "")
        propria = per_url.get((int(mm.group(5)), mm.group(2))) if mm else None
        ad = str(m["codice"])
        stesso = list(per_ad.get(ad, []))
        if propria:
            chiave = propria["chiave"]
            stessi = [e for e in stesso if e["cds"] == propria["cds"] or e["chiave"] == chiave]
            altri = [e for e in stesso if e not in stessi]
        else:
            stessi, altri = [], stesso
        ordine = ([propria] if propria else []) + [e for e in stessi if e is not propria]
        budget = [SYLLABUS_MAX]
        r = cerca(ordine, budget) if ordine else None
        livello = "stesso corso"
        if r is None and altri:
            r = cerca(altri, budget)
            livello = "altro corso"
        if isinstance(r, tuple):
            voce, e = r
            out = {k: v for k, v in voce.items() if k != "sem"}
            if "periodo_inizio" in out and e["att"].get("aa") != (propria["att"].get("aa") if propria else None):
                # le date di un altro anno accademico non valgono per quello corrente: resta il semestre
                out.pop("periodo_inizio"), out.pop("periodo_fine")
                out["periodo"] = voce["sem"]
            out["fonte"] = pagina(base, e["att"], e["y"])
            ris[m["id"]] = out
            via[livello + (" (propria scheda)" if e is propria else "")] += 1
        elif r == "conflitto":
            lacune[m["id"]] = "schede dell'ateneo discordanti sul periodo"
        elif not stesso:
            lacune[m["id"]] = "nessuna attività con questo codice nel catalogo"
        else:
            lacune[m["id"]] = "il catalogo non riporta il periodo in nessuna coorte (piano e syllabus)"
    log(f"[{uid}] trovati {len(ris)} su {len(manc)}; {dict(via)}")
    return ris, lacune
