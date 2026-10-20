"""Semestre degli insegnamenti dell'Università di Torino dalle pagine Campusnet.

Ogni pagina `…/do/corsi.pl/Show?_id=…` di un insegnamento ha il campo «Periodo» («Primo semestre»,
«Secondo semestre», «Annuale», …). Il Course Catalogue Cineca di UniTO lo ha solo per una parte
degli insegnamenti; le pagine si trovano come in `unito_campusnet`: dal campo `url_sito`
dell'insegnamento e, per codice dell'attività didattica, negli elenchi «Corsi e moduli» dei
siti Campusnet. Vale anche la pagina di un altro anno accademico o di un'altra coorte dello stesso
insegnamento (stesso codice): la fonte indicata è sempre la pagina reale letta.

Il periodo non si deduce: se nessuna pagina dello stesso insegnamento lo riporta, resta vuoto.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import os
import pathlib
import re
import time

from . import periodi
from . import cineca_catalogue
from .unibo import Client, _testo
from .unito_campusnet import _assoluto, _host, elenco, HOST_EXTRA


def moduli(s: str, pagina: str) -> list[str]:
    """Pagine dei «Moduli didattici» di un corso integrato (non quelle di «Mutuato da»)."""
    out: list[str] = []
    for m in re.finditer(r'<H2 id="a_moduli_\w+">.*?</H2>(.*?)</dd>', s, re.S | re.I):
        out += re.findall(r'href="([^"]*corsi\.pl/Show\?_id=\w+)"', m.group(1), re.I)
    return list(dict.fromkeys(_assoluto(h, pagina) for h in out))

PERIODO = re.compile(r"<span>(?:Periodo|Period)</span></dt>\s*<dd[^>]*>(.*?)</dd>", re.S | re.I)
ANNO_ACC = re.compile(r"(?:Anno accademico|Academic year)\s*</span></dt>\s*<dd[^>]*>\s*(\d{4}/\d{4})", re.S | re.I)
ORDINALE = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}


def normalizza(t: str) -> str | None:
    """«Primo semestre» -> "1", «Secondo semestre» -> "2", «Annuale»/«Annualità singola»/«Primo e secondo semestre»
    -> "annuale". «Terzo/Quinto semestre» e «Quarto/Sesto semestre» sono i semestri del corso di studio
    (dispari = primo semestre dell'anno, pari = secondo). Tutto il resto («Da definire», «Primo periodo»,
    «Primo quadrimestre», «---Seleziona---»…) non dice un semestre: None."""
    t = re.sub(r"\s+", " ", t.replace("�", "à")).strip().lower()
    if re.match(r"annual", t) or t in ("primo e secondo semestre", "i e ii semestre", "1 e 2 semestre"):
        return "annuale"
    m = re.fullmatch(r"(primo|secondo|terzo|quarto|quinto|sesto) semestre", t)
    if m:
        return "1" if ORDINALE[m.group(1)] % 2 else "2"
    m = re.fullmatch(r"(i|ii|1|2)\s*°?\s*semestre", t)
    if m:
        return "1" if m.group(1) in ("i", "1") else "2"
    m = re.fullmatch(r"(primo|secondo|terzo|quarto|quinto|sesto) periodo", t)
    if m:  # cicli dei corsi a distanza (Giurisprudenza e simili): l'app li mostra come «1° periodo» …
        return f"{ORDINALE[m.group(1)]}° periodo"
    return None


def leggi_periodo(s: str) -> str | None:
    """Semestre dal campo «Periodo» della scheda, o None."""
    m = PERIODO.search(s)
    if not m:
        return None
    return normalizza(_testo(html.unescape(re.sub(r"<[^>]+>", " ", m.group(1)))))


BASE = "https://unito.coursecatalogue.cineca.it"


def _piani(anno: int, log=print, coorti: int = 8) -> dict[str, list[dict]]:
    """Indice {codice attività: [voci]} di tutte le attività dei piani del Course Catalogue (API pubblica,
    2 richieste/s) delle coorti anno-coorti+1…anno, con periodo e date del periodo dove il catalogo li ha.
    Con UN_PIANI_CACHE (cartella) i piani si salvano/leggono da disco (p_<coorte>_<cod>.json)."""
    cache = pathlib.Path(os.environ["UN_PIANI_CACHE"]) if os.environ.get("UN_PIANI_CACHE") else None
    c = cineca_catalogue.Client(BASE, rate=2.0)
    idx: dict[str, list[dict]] = {}

    def leggi(path: str, f: pathlib.Path | None):
        if f and f.exists():
            try:
                return json.loads(f.read_text(encoding="utf-8"))
            except ValueError:
                pass
        d = c.get(path)
        if d is not None and f:
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        return d

    def attivita(o, y, out):
        if isinstance(o, dict):
            if o.get("adCod") and "periodo_didattico_it" in o:
                out.append({"y": y, "ad": o["adCod"], "aa": str(o.get("aa") or ""), "testo": o.get("periodo_didattico_it") or "",
                            "inizio": o.get("data_inizio_periodo_didattico") or "", "fine": o.get("data_fine_periodo_didattico") or "",
                            "url": f"{BASE}/insegnamenti/{o.get('aa')}/{o.get('cod')}/{o.get('ordinamento_aa')}/"
                                   f"{o.get('corso_percorso_id')}?coorte={y}"})
            for v in o.values():
                attivita(v, y, out)
        elif isinstance(o, list):
            for v in o:
                attivita(v, y, out)

    for y in range(anno - coorti + 1, anno + 1):
        lst = c.get("/corsi", {"anno": y, "minimal": "true"}) or []
        cds: list[dict] = []
        cineca_catalogue._walk_cds(lst, cds)
        for x in cds:
            if str(x.get("aa")) != str(y):
                continue
            d = leggi(f"/corso/{y}/{x['cod']}", cache / f"p_{y}_{x['cod']}.json" if cache else None)
            if isinstance(d, list):
                d = d[0] if d else None
            out: list[dict] = []
            attivita(d, y, out)
            for a in out:
                idx.setdefault(a["ad"], []).append(a)
        log(f"[unito] piani coorte {y}: {len(cds)} corsi, {len(idx)} attività indicizzate")
    return idx


def da_piani(mancanti: list[dict], idx: dict[str, list[dict]]) -> dict[str, dict]:
    """Periodo dalle voci dei piani con lo stesso codice di attività (altre coorti/anni dello stesso insegnamento).
    Se le voci non concordano si prendono quelle dell'anno di erogazione più recente; se ancora non concordano, niente."""
    out: dict[str, dict] = {}
    for m in mancanti:
        voci = [v for v in idx.get(m.get("codice") or "", []) if (v["testo"] or v["inizio"])]
        cand = []
        for v in voci:
            p = normalizza(v["testo"]) if v["testo"] else None
            if not p and v["inizio"] and v["fine"]:
                p = periodi._normalizza(None, v["inizio"], v["fine"])
            if p:
                cand.append((v["aa"], p, v))
        if not cand:
            continue
        for livello in (cand, [x for x in cand if x[0] == max(c_[0] for c_ in cand)]):
            if len({p for _, p, _ in livello}) == 1:
                aa, p, v = max(livello, key=lambda t: t[0])
                out[m["id"]] = {"periodo": p, "fonte": v["url"]}
                break
    return out


def fetch_periodi(uid: str = "unito", log=print) -> dict[str, dict]:
    db = periodi.carica(uid)
    mancanti = periodi.mancanti(uid)
    corsi = [c for c in db["corsi"] if not c.get("piano_da")]
    c = Client(rate=2.0)
    anno = int(time.strftime("%Y")) if time.strftime("%m") >= "09" else int(time.strftime("%Y")) - 1
    aa_corrente = f"{anno}/{anno + 1}"

    host_corso: dict[str, set[str]] = {}
    for corso in corsi:
        hs = {_host(corso.get("url"))} | {_host(i.get("url_sito")) for i in corso.get("insegnamenti") or []}
        host_corso[corso["id"]] = {h for h in hs if h}
    hosts = sorted(set().union(*host_corso.values()) | set(HOST_EXTRA))
    per_codice: dict[str, list[tuple[str, dict]]] = {}
    with cf.ThreadPoolExecutor(2) as ex:
        for h, voci in zip(hosts, ex.map(lambda h: elenco(c, h), hosts)):
            for v in voci:
                if v["codice"]:
                    per_codice.setdefault(v["codice"], []).append((h, v))
    log(f"[{uid}] {len(hosts)} siti Campusnet, {sum(len(v) for v in per_codice.values())} pagine negli elenchi")

    def candidati(corso_id: str, cod: str) -> list[str]:
        cod = re.sub(r"\s+", "", cod or "").upper()
        if not cod:
            return []
        voci = per_codice.get(cod) or [x for k, v in per_codice.items()
                                        if re.fullmatch(re.escape(cod) + r"/?[A-Z]", k) for x in v]
        # prima l'anno corrente e il sito del corso, poi gli altri anni e siti
        voci = sorted(voci, key=lambda hv: (hv[1]["aa"] != aa_corrente, hv[0] not in host_corso.get(corso_id, ())))
        return list(dict.fromkeys(v["url"] for _, v in voci))[:6]

    corso_di = {i["id"]: c_["id"] for c_ in corsi for i in c_.get("insegnamenti") or []}
    lette: dict[str, tuple[str | None, list[str]]] = {}

    def pagina(u: str) -> tuple[str | None, list[str]]:
        """(semestre, pagine dei moduli se la scheda è di un corso integrato senza il campo «Periodo»)."""
        if u not in lette:
            try:
                r = c.get(u)
                if not r:
                    lette[u] = (None, [])
                else:
                    lette[u] = (leggi_periodo(r.text), [] if PERIODO.search(r.text) else moduli(r.text, u))
            except Exception:  # noqa: BLE001
                lette[u] = (None, [])
        return lette[u]

    def periodo_pagina(u: str) -> str | None:
        return pagina(u)[0]

    def da_moduli(u: str) -> tuple[str, str] | None:
        """Corso integrato: se tutti i moduli (con il campo «Periodo») hanno lo stesso semestre vale per il corso."""
        mods = pagina(u)[1]
        vals = [(periodo_pagina(v), v) for v in mods]
        if mods and all(p for p, _ in vals) and len({p for p, _ in vals}) == 1:
            return vals[0]
        return None

    def risolvi(m: dict) -> tuple[str, dict | None]:
        u = m.get("url_sito") or ""
        pagine = [_assoluto(u, u)] if re.search(r"unito\.it/do/corsi\.pl/Show\?_id=\w+", u) else []
        pagine += [x for x in candidati(corso_di[m["id"]], m.get("codice") or "") if x not in pagine]
        for p in pagine:
            t = periodo_pagina(p)
            if t:
                return m["id"], {"periodo": t, "fonte": p}
        for p in pagine:
            r = da_moduli(p)
            if r:
                return m["id"], {"periodo": r[0], "fonte": r[1]}
        return m["id"], None

    out: dict[str, dict] = {}
    with cf.ThreadPoolExecutor(8) as ex:  # la lettura dalla cache è locale; la rete resta a 2 richieste/s (Client)
        for n, (iid, r) in enumerate(ex.map(risolvi, mancanti), 1):
            if r:
                out[iid] = r
            if n % 500 == 0:
                log(f"[{uid}] {n}/{len(mancanti)} insegnamenti, {len(out)} con periodo (richieste {c.requests})")
    log(f"[{uid}] pagine Campusnet: periodo per {len(out)} insegnamenti su {len(mancanti)}; richieste {c.requests}")
    # insegnamenti senza pagina Campusnet (o senza periodo): stesse attività nei piani del Course Catalogue
    resto = [m for m in mancanti if m["id"] not in out]
    anno = int(time.strftime("%Y")) if time.strftime("%m") >= "09" else int(time.strftime("%Y")) - 1
    n0 = len(out)
    out.update(da_piani(resto, _piani(anno, log)))
    log(f"[{uid}] piani del catalogo: {len(out) - n0} in più; totale {len(out)} su {len(mancanti)}")
    return out


# --- insegnamenti «annuale» nel database ------------------------------------------------------------------
# Il Course Catalogue Cineca di UniTO dà a molti insegnamenti «Annualità Singola» (A1), con le date dell'anno
# intero: un segnaposto, non il semestre. La pagina Campusnet dell'insegnamento (`url_sito`) ha invece il
# campo «Periodo» preciso, e quando c'è vale più del catalogo.
#
# Il risultato va in un file a parte, `unito_semestri_campusnet.json`, e non in `unito_periodi.json`: build_db applica i
# contributi in ordine alfabetico e `unito_piani.json` (che ha il campo `periodo`, anche vuoto, per ogni voce) viene
# dopo `unito_periodi.json` e ne cancella il periodo; questo nome viene dopo tutti i contributi di UniTO.
FILE_SEMESTRI = "unito_semestri_campusnet.json"

CAMPUSNET = re.compile(r"https?://[^/]*unito\.it/do/corsi\.pl/Show\?_id=\w+", re.I)


class _Lettore:
    """Legge le schede Campusnet una volta sola: (semestre, pagine dei moduli se manca il campo «Periodo»)."""

    def __init__(self, client: Client):
        self.c = client
        self.lette: dict[str, tuple[str | None, str | None, list[str]]] = {}

    def pagina(self, u: str) -> tuple[str | None, str | None, list[str]]:
        """(semestre, anno accademico della scheda, moduli se la scheda non ha il campo «Periodo»)."""
        if u not in self.lette:
            try:
                r = self.c.get(u)
                if not r:
                    self.lette[u] = (None, None, [])
                else:
                    aa = ANNO_ACC.search(r.text)
                    self.lette[u] = (leggi_periodo(r.text), aa.group(1) if aa else None,
                                     [] if PERIODO.search(r.text) else moduli(r.text, u))
            except Exception:  # noqa: BLE001
                self.lette[u] = (None, None, [])
        return self.lette[u]

    def risolvi(self, u: str) -> tuple[str, str] | None:
        """(semestre, pagina che lo dice): la scheda, o i moduli del corso integrato se tutti concordano."""
        p = self.pagina(u)[0]
        if p:
            return p, u
        mods = self.pagina(u)[2]
        vals = [(self.pagina(v)[0], v) for v in mods]
        if mods and all(x for x, _ in vals) and len({x for x, _ in vals}) == 1:
            return vals[0]
        return None


def fetch_annuali(uid: str = "unito", log=print) -> dict[str, dict]:
    """Per gli insegnamenti «annuale» del database con la scheda Campusnet (`url_sito`): il periodo che dice la
    scheda, con la scheda come fonte. «Annuale»/«Annualità singola»/«Da definire»/campo assente: la scheda non
    dice un semestre diverso e l'insegnamento resta com'è (qui non compare). Come `fetch_periodi`, non si
    deduce nulla: solo ciò che la scheda scrive. Ritorna {id: {"periodo": "1"|"2"|"annuale", "fonte": url}}."""
    db = periodi.carica(uid)
    lettore = _Lettore(Client(rate=2.0))
    voci = [i for c in db["corsi"] if not c.get("piano_da") for i in c.get("insegnamenti") or []
            if i.get("periodo") == "annuale" and CAMPUSNET.match(i.get("url_sito") or "")]
    log(f"[{uid}] {len(voci)} insegnamenti annuali con scheda Campusnet")

    def una(i: dict) -> tuple[str, tuple[str, str] | None]:
        return i["id"], lettore.risolvi(_assoluto(i["url_sito"], i["url_sito"]))

    out: dict[str, dict] = {}
    with cf.ThreadPoolExecutor(8) as ex:  # la rete resta a 2 richieste/s (Client)
        for n, (iid, r) in enumerate(ex.map(una, voci), 1):
            if r:
                out[iid] = {"periodo": r[0], "fonte": r[1]}
            if n % 100 == 0:
                log(f"[{uid}] {n}/{len(voci)} schede, {len(out)} con periodo (richieste {lettore.c.requests})")
    log(f"[{uid}] richieste {lettore.c.requests}; periodo letto per {len(out)} insegnamenti su {len(voci)}")
    return out


if __name__ == "__main__":
    ris = fetch_annuali()
    # «annuale» confermato: nessuna modifica; «N° periodo» = ciclo dei corsi a distanza
    semestri = {k: v for k, v in ris.items() if v["periodo"] in ("1", "2") or v["periodo"].endswith("° periodo")}
    print(f"semestre dalla scheda per {len(semestri)} insegnamenti annuali; "
          f"scritti/scartati {periodi.scrivi('unito', semestri, nome_file=FILE_SEMESTRI)}")
