"""Insegnamenti e docenti dell'Università per Stranieri "Dante Alighieri" di Reggio Calabria.

- `www.unidarc.it/corsi/` → pagine dei corsi (`/corsi/<id>_<nome>-<classe>/`), la più recente per classe
  (ordinamento «R» della coorte 2026/27);
- pagina del corso → «Piano di studi curriculum X» (uno per curriculum; «UNICO» = nessun curriculum) con le tabelle
  «Materie Primo Anno», «Materie Secondo Anno», … e le tabelle delle scelte («Materie a scelta», «Lingua a Scelta I»,
  «Lingua a Scelta II»): materia (link alla scheda `/materie/…?anno=<fine a.a.>`), SSD e CFU;
- una riga segnaposto di un anno («Materia a scelta», «Lingua a scelta I») è sostituita dalle opzioni della tabella
  omonima, a scelta, in quell'anno (le stesse opzioni compaiono in ogni anno che ha il segnaposto);
- le righe uguali in tutti i curricula valgono per tutti, le altre hanno i propri curricula (L-39: «Servizio sociale» e
  «Esperto plurilingue»);
- la tabella «Laboratori» non è un insegnamento: sono le attività con cui si assolvono i 6 CFU della riga «Tirocinio –
  Laboratori di servizio sociale» (manifesto degli studi 2026/27) e non si aggiunge;
- controllo: la somma dei CFU di ogni anno (segnaposto compresi) è confrontata con il «Totale CFU» del piano di
  studi ufficiale 2026/27 (manifesto degli studi, `TOTALI_UFFICIALI`). La pagina LM-87R non elenca la «Prova finale»
  (18 CFU, secondo anno) che il manifesto e il regolamento didattico mettono nel piano: si aggiunge solo se la somma
  dell'anno più i 18 CFU dà il totale ufficiale (`INTEGRAZIONI`);
- scheda della materia → docente (il link al syllabus è vuoto: niente libri).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unidarc.it"
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5}
MANIFESTO = "https://www.unidarc.it/wp-content/uploads/2026/07/manifesto-degli-studi-unida-aa-2026-2027.pdf"
# «Totale CFU» di ogni anno nel piano di studi ufficiale 2026/27 (manifesto degli studi, valido per ogni curriculum)
TOTALI_UFFICIALI = {
    "L-24": {1: 63, 2: 54, 3: 63},
    "L-39": {1: 63, 2: 57, 3: 60},
    "LM-87": {1: 57, 2: 63},
}
# righe del piano ufficiale che la pagina del corso non elenca: (classe, anno) -> [(nome, CFU)]
INTEGRAZIONI = {
    ("LM-87", 2): [("Prova finale", 18)],
}
ANOMALIE: list[str] = []


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _slug(s: str, maxlen: int) -> str:
    return _norm(s).replace(" ", "-")[:maxlen].strip("-")


def _chiave_scelta(nome: str) -> str:
    """«Materia a scelta» (riga del piano) e «Materie a scelta» (tabella delle opzioni) sono la stessa scelta."""
    return re.sub(r"\bmaterie\b", "materia", _norm(nome))


def _curriculum(titolo: str) -> str | None:
    t = re.sub(r"\s+", " ", titolo or "").strip()
    if not t or t.upper() == "UNICO":
        return None
    return t[:1].upper() + t[1:].lower()


def leggi_piano(s: str) -> dict[str | None, dict]:
    """{curriculum: {"anni": {anno: [riga]}, "scelte": {chiave: [riga]}}} dalla pagina di un corso.
    Riga: nome, ssd, cfu, url (della scheda della materia o None), segnaposto (True se è una riga «… a scelta»)."""
    marc = [(m.start(), _curriculum(m.group(1))) for m in
            re.finditer(r"Piano di studi curriculum\s+([^<]+?)\s*(?:<|$)", s)]
    if not marc:
        marc = [(0, None)]
    piani: dict[str | None, dict] = {}
    for k, (inizio, cur) in enumerate(marc):
        fine = marc[k + 1][0] if k + 1 < len(marc) else len(s)
        piano = piani.setdefault(cur, {"anni": {}, "scelte": {}})
        for tab in re.findall(r"<table.*?</table>", s[inizio:fine], re.S):
            th = re.search(r"<th[^>]*>(.*?)</th>", tab, re.S)
            titolo = html.unescape(_testo(th.group(1))) if th else ""
            if re.fullmatch(r"(?i)laborator\w*", titolo):
                continue
            a = re.match(r"(?i)Materie\s+(\w+)\s+anno", titolo)
            anno = ANNI.get(a.group(1).lower()) if a else None
            corpo = re.search(r"<tbody>(.*?)</tbody>", tab, re.S)
            righe = []
            for r in re.findall(r"<tr[^>]*>(.*?)</tr>", corpo.group(1) if corpo else "", re.S):
                c = re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)
                if len(c) < 3 or not _testo(c[0]):
                    continue
                link = re.search(r'href="([^"]+/materie/[^"]+)"', c[0])
                nome = html.unescape(_testo(c[0]))
                ssd = re.search(r"([A-Z]{2,5}-\d{2}(?:/[A-Z])?)", _testo(c[1]))
                cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[2]))
                v = float(cfu.group(0).replace(",", ".")) if cfu else None
                url = html.unescape(link.group(1)) if link else None
                righe.append({"nome": nome, "ssd": ssd.group(1) if ssd else None,
                              "cfu": int(v) if v is not None and v.is_integer() else v, "url": url,
                              "segnaposto": bool(re.search(r"(?i)\ba scelta\b", nome))
                              and (not url or "materia-a-scelta" in url or not ssd)})
            if anno:
                piano["anni"].setdefault(anno, []).extend(righe)
            elif titolo:
                piano["scelte"].setdefault(_chiave_scelta(titolo), []).extend(righe)
    return piani


def righe_corso(classe: str, piani: dict[str | None, dict], manifesto: str, log=print) -> list[dict]:
    """Righe (anno, nome, ssd, cfu, url, scelta, curricula) di un corso, con i segnaposto sostituiti dalle opzioni."""
    curricula = list(piani)
    per_riga: dict[tuple, dict] = {}
    totali = TOTALI_UFFICIALI.get(classe) or {}
    for cur, piano in piani.items():
        for anno in sorted(piano["anni"]):
            voci = piano["anni"][anno]
            somma = sum(v["cfu"] or 0 for v in voci)
            extra = [(n, c) for n, c in INTEGRAZIONI.get((classe, anno), [])
                     if not any(_norm(v["nome"]) == _norm(n) for v in voci)]
            tot = totali.get(anno)
            if tot is not None and somma != tot:
                if extra and somma + sum(c for _, c in extra) == tot:
                    voci = voci + [{"nome": n, "ssd": None, "cfu": c, "url": None, "segnaposto": False,
                                    "fonte": manifesto} for n, c in extra]
                    log(f"[unidarc]   {classe} {cur or '-'} anno {anno}: aggiunte da {manifesto.rsplit('/', 1)[-1]} "
                        f"{extra} (somma pagina {somma} + {tot - somma} = totale ufficiale {tot})")
                else:
                    ANOMALIE.append(f"{classe} {cur or '-'} anno {anno}: somma {somma} CFU, totale ufficiale {tot}")
                    log(f"[unidarc]   {ANOMALIE[-1]}")
            for v in voci:
                if v["segnaposto"]:
                    opz = piano["scelte"].get(_chiave_scelta(v["nome"]))
                    if opz:
                        for o in opz:
                            if o["cfu"] != v["cfu"]:
                                log(f"[unidarc]   {classe} {cur or '-'} anno {anno}: «{o['nome']}» {o['cfu']} CFU, "
                                    f"segnaposto «{v['nome']}» {v['cfu']} CFU")
                            _aggiungi(per_riga, cur, anno, o, True)
                        continue
                _aggiungi(per_riga, cur, anno, v, v["segnaposto"])
    out = []
    for r in per_riga.values():
        cs = r.pop("_c")
        r["curricula"] = None if len(curricula) < 2 or cs >= set(curricula) else sorted(c for c in cs if c)
        out.append(r)
    return out


def _aggiungi(per_riga: dict, cur, anno: int, v: dict, scelta: bool) -> None:
    key = (anno, v["nome"].lower(), v["cfu"], scelta)
    r = per_riga.get(key)
    if not r:
        r = per_riga[key] = {"anno": anno, "nome": v["nome"], "ssd": v["ssd"], "cfu": v["cfu"], "url": v["url"],
                             "scelta": scelta, "fonte": v.get("fonte"), "_c": set()}
    r["_c"].add(cur)
    r["ssd"] = r["ssd"] or v["ssd"]
    r["url"] = r["url"] or v["url"]


def _id_espliciti(corso_id: str, items: list[dict]) -> None:
    """build_db tronca lo slug dell'id a 40 caratteri: due insegnamenti diversi con lo stesso inizio di nome nello stesso
    anno si fonderebbero (es. «Sociologia dei processi culturali e comunicativi (Modulo A)» e «… (Modulo B)»): hanno
    un id esplicito."""
    per: dict[tuple, list[dict]] = {}
    for i in items:
        per.setdefault((_slug(i["nome"], 40), i["anno"], i["obbligatorio"] is False), []).append(i)
    usati: set[str] = set()
    for lst in per.values():
        if len({i["nome"].lower() for i in lst}) > 1:
            for i in lst:
                base = f"{corso_id}-{_slug(i['nome'], 90)}"
                nuovo = base
                for suff in (f"-a{i['anno']}", f"-a{i['anno']}-{'scelta' if i['obbligatorio'] is False else 'obbl'}"):
                    if nuovo in usati:
                        nuovo = base + suff
                usati.add(nuovo)
                i["id"] = nuovo


def fetch_ateneo(uid: str = "unidarc", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    ANOMALIE.clear()
    r = c.get(f"{BASE}/corsi/")
    pagine = sorted({h for h in re.findall(r'href="(https://www\.unidarc\.it/corsi/\d+_[\w-]+/)"', r.text if r else "")})
    out = []
    for corso in corsi:
        # la classe è nell'indirizzo della pagina ("…-l-24r-l-24r/")
        cl = _norm(corso.get("classe") or "").replace(" ", "-")
        cand = [u for u in pagine if cl and re.search(rf"-{re.escape(cl)}r?(?:-|/)", u)]
        # vecchi e nuovi ordinamenti ("-l-24-" e "-l-24r-"): la pagina più recente (id più alto)
        cand = sorted(cand, key=lambda u: int(re.search(r"/corsi/(\d+)_", u).group(1)))[-1:]
        if not cand:
            continue
        rc = c.get(cand[0])
        testo = rc.text if rc else ""
        piani = leggi_piano(testo)
        man = re.search(r'href="([^"]+)"[^>]*>(?:(?!</a>).)*?Manifesto degli studi', testo, re.S)
        voci = righe_corso(corso.get("classe") or "", piani, html.unescape(man.group(1)) if man else MANIFESTO, log)
        if not voci:
            continue
        curricula = [k for k in piani if k]
        ins = [{"codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                "ssd": v["ssd"], "obbligatorio": False if v["scelta"] else True,
                "curriculum": ", ".join(v["curricula"]) if v["curricula"] else None,
                "docenti": [], "url": v["url"] or cand[0], "libri": [], "esami": [], "fonte": v["fonte"] or cand[0],
                "verificato_il": oggi, "stato_libri": "da_aggiungere"}
               for v in sorted(voci, key=lambda v: (v["anno"], v["scelta"]))]
        _id_espliciti(corso["id"], ins)
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": cand[0],
                    "curricula": curricula if len(curricula) > 1 else None, "fonte": cand[0],
                    "verificato_il": oggi, "insegnamenti": ins})
    items = [i for x in out for i in x["insegnamenti"] if "/materie/" in i["url"]]
    schede: dict[str, str | None] = {}

    def docente(url: str) -> None:
        rm = c.get(url)
        t = rm.text if rm else ""
        d = re.search(r'<span>Docente</span>\s*<a[^>]*>(.*?)</a>', t, re.S)
        schede[url] = _testo(d.group(1)) if d else None
        k = re.search(r"CFU:\s*(\d+)", _testo(t))
        schede[url + "#cfu"] = k.group(1) if k else None

    if syllabus:
        with cf.ThreadPoolExecutor(3) as ex:
            list(ex.map(docente, sorted({i["url"] for i in items})))
        for i in items:
            if schede.get(i["url"]):
                i["docenti"] = [schede[i["url"]]]
            k = schede.get(i["url"] + "#cfu")
            if k and i["cfu"] is not None and int(k) != i["cfu"]:
                ANOMALIE.append(f"{i['nome']}: scheda {k} CFU, piano {i['cfu']}")
                log(f"[unidarc]   {ANOMALIE[-1]}")
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unidarc.it, piani di studio (adapters/unidarc.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
