"""Semestre degli insegnamenti dal Course Catalogue Cineca (UniPi, UniFI): piani di studio delle coorti.

Il piano di una coorte (`GET /api/v1/corso/<coorte>/<cod>`) riporta il periodo didattico di ogni attività
o nei campi `periodo_didattico_it` / `data_inizio_periodo_didattico` / `data_fine_periodo_didattico`
oppure, quando l'insegnamento è diviso in frazioni, nell'elenco `frazioni` (uno per frazione, con testo e
date). `cineca_catalogue.fetch_ateneo` legge solo i campi di primo livello: qui si leggono anche le
frazioni, e per gli insegnamenti non ancora erogati nella coorte della scheda (a.a. futuro, «offerta B»
senza periodo) si usa la scheda dello STESSO insegnamento (stesso corso di studio, stesso codice di
attività, stesso percorso) di un'altra coorte/anno accademico, citandola come fonte.
Il periodo non si deduce mai: se nessuna scheda lo riporta, resta vuoto.

L'indice dei piani si può salvare (`cache_indice`) per non rifare le richieste; i piani già scaricati
dagli altri adattatori sono nella cache UN_HTTP_CACHE.
"""
from __future__ import annotations

import json
import pathlib
import re
from collections import defaultdict


import pulizia
from . import periodi
from .cineca_catalogue import _chiave_cds, _walk_cds

_DATA = re.compile(r"\d{2}/\d{2}/\d{4}$")


def _g(s: str) -> tuple:
    d, m, a = s.split("/")
    return int(a), int(m), int(d)


def _voci(parti: list[dict], tipo: str = "f") -> list[tuple]:
    """[(testo, inizio, fine, tipo, crediti, curriculum)]: `tipo` è "a" (l'attività stessa), "m" (un modulo, che
    si frequenta insieme agli altri) o "f" (una frazione: edizione, canale, curriculum alternativi)."""
    out = []
    for x in parti:
        t = (x.get("periodo_didattico_it") or "").strip()
        a, b = (x.get("data_inizio_periodo_didattico") or "").strip(), (x.get("data_fine_periodo_didattico") or "").strip()
        if t.lower() in ("undefined", "non definito", "-", "--"):
            t = ""
        if t or (_DATA.match(a) and _DATA.match(b)):
            try:
                cr = float(str(x.get("crediti")).replace(",", "."))
            except ValueError:
                cr = None
            out.append((t, a if _DATA.match(a) else "", b if _DATA.match(b) else "", tipo, cr,
                        "curriculum" in (x.get("des_it") or "").lower()))
    return out


def _periodi_attivita(att: dict) -> list[tuple]:
    """Le voci del primo livello e delle frazioni dell'attività; solo se mancano, dei moduli del syllabus
    (corso integrato: il periodo sta nei moduli)."""
    out = _voci([att], "a") + _voci(list(att.get("frazioni") or []), "f")
    if not out:
        for mod in att.get("moduli") or []:
            if isinstance(mod, dict):
                # il periodo del modulo vale più delle sue frazioni (edizioni, canali, turni: una può cadere
                # in un altro semestre senza che il modulo cambi); senza periodo proprio contano le frazioni
                proprio = _voci([mod], "m")
                out += proprio or _voci(list(mod.get("frazioni") or []), "f")
    return out


def _sem(t: str, a: str, b: str) -> str | None:
    """Semestre di una frazione ("1" | "2" | "annuale") con le stesse regole del database; None se non si legge."""
    s = pulizia.periodo(t or None, a or None, b or None)
    return s if s in ("1", "2", "annuale") else None


def riassumi(ps: list[tuple], dal: tuple[int, int, int] | None = None) -> dict | None:
    """Un periodo solo per l'attività, dalle sue voci (testo, inizio, fine[, tipo, crediti, curriculum]).

    - tutte le voci dicono lo stesso semestre: quel semestre, con le date più ampie;
    - un componente a 0 crediti (il «lettorato» annuale di una lingua) non decide il periodo: si ignora se
      accanto ce ne sono con crediti;
    - una frazione semestrale accanto a frazioni «annuali» (edizioni alternative: «Università di Pisa» in un
      semestre, «Accademia Navale» in ciclo annuale unico): il semestre; non vale se le frazioni sono
      curricula alternativi (resta l'insieme) né se a essere annuale è un modulo con crediti;
    - voci in semestri diversi (S1 + S2) o tutte annuali: l'insieme, con le date più ampie (annuale);
    - `dal` (anno, mese, giorno): se tutte le date finiscono prima di quel giorno sono di un anno accademico
      passato e non si copiano: resta il semestre che se ne ricava."""
    ps = [tuple(p) + ("f", None, False)[len(p) - 3:] if len(p) < 6 else tuple(p) for p in ps]
    sems = [_sem(*p[:3]) for p in ps]
    if any(p[4] for p in ps):  # componenti a 0 crediti: contano solo se non c'è altro
        tieni = [k for k, p in enumerate(ps) if p[4] is None or p[4] > 0]
        ps, sems = [ps[k] for k in tieni], [sems[k] for k in tieni]
    valori = {s for s in sems if s}
    semestrali = valori - {"annuale"}
    if len(semestrali) == 1 and "annuale" in valori:
        annuali = [p for p, x in zip(ps, sems) if x == "annuale"]
        edizioni = all(p[3] == "f" for p in annuali) and not any(p[5] for p in ps)
        if edizioni:  # le frazioni annuali accanto alla semestrale sono edizioni alternative: si tiene il semestre
            s = next(iter(semestrali))
            ps = [p for p, x in zip(ps, sems) if x == s]
            sems = [s] * len(ps)
            valori = {s}
    date = [(p[1], p[2]) for p in ps if p[1] and p[2]]
    unico = next(iter(valori)) if len(valori) == 1 and next(iter(valori)) in ("1", "2") else None
    if date and dal and valori and _g(max((x[1] for x in date), key=_g)) < dal:
        # tutte le date sono di un anno accademico passato: non si copiano, resta il semestre (o l'annuale)
        return {"periodo": unico or "annuale"}
    if date:
        a = min((x[0] for x in date), key=_g)
        b = max((x[1] for x in date), key=_g)
        testi = {p[0] for p in ps if p[0]}
        # il semestre dichiarato si scrive esplicito: le date unite possono essere più lunghe (calendari
        # lunghi delle professioni sanitarie) e pulizia.periodo non deve perderlo
        return {"periodo_inizio": a, "periodo_fine": b,
                "periodo": unico or (testi.pop() if len(testi) == 1 else None)}
    if unico:
        return {"periodo": unico}
    testi = {p[0] for p in ps if p[0]}
    if len(testi) == 1:
        return {"periodo": testi.pop()}
    return None


def _syllabus(client, e: dict):
    """Il syllabus (stessa scheda) di una voce dell'indice; None se non ha il codice del corso."""
    if not e.get("corso_cod"):
        return None
    return client.get("/insegnamento", {k: v for k, v in {
        "anno": e["aa"], "insegnamento": e["cod"], "ordinamento_aa": e["ord"], "af_percorso": e["perc"],
        "corso_cod": e.get("corso_cod"), "corso_aa": e["y"], "schema_id": e.get("schema")}.items() if v not in (None, "")})


def _con_dettagli(client, voce: dict) -> list[tuple]:
    """Voci semestrali e «annuali» insieme nello stesso piano: il piano non dice i crediti dei moduli né il nome
    delle frazioni, il syllabus sì. Un modulo annuale a 0 crediti (il «lettorato» di una lingua) non decide il
    periodo dell'insegnamento, uno con crediti sì; frazioni di curricula diversi sono alternative. Si rileggono
    le voci dal syllabus (stesse voci, con crediti e nome) se sono tante quante quelle del piano."""
    sy = _syllabus(client, voce)
    if not isinstance(sy, dict):
        return voce["periodi"]
    nuove = []
    for mod in sy.get("moduli") or []:
        if isinstance(mod, dict):
            nuove += _voci([mod], "m") or _voci(list(mod.get("frazioni") or []), "f")
    if not nuove:
        nuove = _voci(list(sy.get("frazioni") or []), "f")
    piano = [p for p in voce["periodi"] if p[3] != "a"]
    return [p for p in voce["periodi"] if p[3] == "a"] + nuove if nuove and len(nuove) == len(piano) else voce["periodi"]


def _misto(ps: list[tuple]) -> bool:
    sems = {_sem(*p[:3]) for p in ps}
    return "annuale" in sems and bool(sems - {"annuale", None})


def indice_piani(client, anni: range, log=print, cache_indice: pathlib.Path | None = None) -> list[dict]:
    """Tutte le attività dei piani delle coorti `anni`, con i periodi trovati."""
    if cache_indice and cache_indice.exists():
        return json.loads(cache_indice.read_text(encoding="utf-8"))
    out: list[dict] = []
    for y in anni:
        cds: list[dict] = []
        _walk_cds(client.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        cds = [x for x in cds if str(x.get("aa")) == str(y)]
        log(f"[periodi] coorte {y}: {len(cds)} corsi")
        for x in cds:
            d = client.get(f"/corso/{y}/{x['cod']}")
            if isinstance(d, list):
                d = d[0] if d else None
            if not d:
                continue
            chiave = list(_chiave_cds(x))
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
                    for g in gruppi:
                        for att in g.get("attivita") or []:
                            voce = {"y": y, "cds": x["cdsCod"], "chiave": chiave, "ad": att.get("adCod") or att.get("cod"),
                                    "cod": att.get("cod"), "aa": str(att.get("aa")), "ord": att.get("ordinamento_aa"),
                                    "perc": att.get("corso_percorso_id"), "perc_cod": att.get("corso_percorso_cod"),
                                    "corso_cod": att.get("corso_cod"), "schema": att.get("schemaId"),
                                    "periodi": _periodi_attivita(att)}
                            if _misto(voce["periodi"]):
                                voce["periodi"] = _con_dettagli(client, voce)
                            out.append(voce)
    if cache_indice:
        cache_indice.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    return out


def _url(base: str, e: dict) -> str:
    return f"{base.rstrip('/')}/insegnamenti/{e['aa']}/{e['cod']}/{e['ord']}/{e['perc']}?coorte={e['y']}"


def fetch_periodi(uid: str, client, base: str, anno: int = 2026, log=print, cache_indice=None) -> dict[str, dict]:
    """Periodo degli insegnamenti senza semestre di database/corsi/<uid>.json."""
    idx = indice_piani(client, range(anno - 5, anno + 1), log, cache_indice)
    per_cod = {(e["y"], e["cod"]): e for e in idx}
    per_cds_ad: dict = defaultdict(list)
    per_corso_ad: dict = defaultdict(list)
    per_cod_aa = {(e["cod"], e["aa"]): e for e in idx}  # scheda ereditata dal piano di un'altra coorte (nuovo ordinamento)
    per_ad: dict = defaultdict(list)
    for e in idx:
        if e["periodi"]:
            per_cds_ad[(e["cds"], e["ad"])].append(e)
            per_ad[e["ad"]].append(e)
            per_corso_ad[(e["chiave"][0], e["chiave"][2], e["ad"])].append(e)
    ris: dict[str, dict] = {}
    stat = defaultdict(int)
    manc = periodi.mancanti(uid)
    for m in manc:
        mm = re.search(r"/insegnamenti/(\d{4})/([^/]+)/(\d+)/(\d+)\?coorte=(\d{4})", m.get("url") or "")
        if not mm:
            stat["senza_url"] += 1
            continue
        y, cod = int(mm.group(5)), mm.group(2)
        proprio = per_cod.get((y, cod)) or per_cod_aa.get((cod, mm.group(1)))
        scelto, via = None, None
        if not proprio:
            stat["scheda_non_nel_piano"] += 1
            continue
        if proprio["periodi"]:
            scelto, via = proprio, "propria scheda"
        else:
            # il syllabus (stessa scheda) a volte riporta il periodo anche quando il piano no
            sy = _syllabus(client, proprio)
            ps = _periodi_attivita(sy) if isinstance(sy, dict) else []
            if ps:
                scelto, via = {**proprio, "periodi": ps}, "syllabus"
        if not scelto:
            cand = [e for e in per_cds_ad.get((proprio["cds"], proprio["ad"]), []) if e["perc_cod"] == proprio["perc_cod"]]
            via = "altra coorte"
            if not cand:  # stesso corso con un altro codice di corso di studio (nuovo ordinamento)
                cand = [e for e in per_corso_ad.get((proprio["chiave"][0], proprio["chiave"][2], proprio["ad"]), [])
                        if e["perc_cod"] == proprio["perc_cod"]]
                via = "altra coorte (altro codice corso)"
            if cand:
                cand.sort(key=lambda e: (e["y"], e["aa"]), reverse=True)
                scelto = cand[0]
        if not scelto and per_ad.get(proprio["ad"]):
            # lo stesso codice di attività in altri corsi di studio, solo se tutte le schede dell'ultimo
            # a.a. che lo riporta dicono lo stesso periodo
            es = per_ad[proprio["ad"]]
            ultimo = max(e["aa"] for e in es)
            es = [e for e in es if e["aa"] == ultimo]
            rs = {json.dumps(riassumi([tuple(p) for p in e["periodi"]]), sort_keys=True) for e in es}
            sems = {pulizia.periodo(r.get("periodo"), r.get("periodo_inizio"), r.get("periodo_fine"))
                    for r in (json.loads(x) for x in rs if x != "null")}
            if len(sems) == 1 and None not in sems:
                scelto, via = es[0], "stesso codice attività in altri corsi"
        if not scelto:
            stat["nessun_periodo"] += 1
            continue
        r = riassumi([tuple(p) for p in scelto["periodi"]], dal=(anno - 1, 8, 1))  # date di a.a. più vecchi del precedente: no
        if not r:
            stat["periodo_non_interpretabile"] += 1
            continue
        r["fonte"] = _url(base, scelto)
        ris[m["id"]] = r
        stat[via] += 1
    log(f"[{uid}] periodi: {len(ris)} su {len(manc)}; {dict(stat)}")
    return ris
