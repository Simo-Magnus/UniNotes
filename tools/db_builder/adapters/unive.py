"""Insegnamenti, docenti e libri dell'Università Ca' Foscari Venezia da www.unive.it.

Esse3 di Ca' Foscari non pubblica l'offerta; i siti dei corsi sì:

- `unive.it/cdl/<codice>` → home del corso (`/web/it/<pagina>/home`) con i link «Piano di studio»
  (`/web/it/<id>/piano-di-studio`) e «Insegnamenti e orari» (`/web/it/<id>/insegnamenti-e-orari`);
- «Piano di studio» → una pagina per coorte (e per curriculum) «Immatricolati a.a. 2025/2026», con il piano
  completo di tutti gli anni: tipo di attività (A base … F altro), ambito, gruppi con i CFU da acquisire
  («CFU parziale»), codice, settore, anno, nome e CFU di ogni insegnamento (`parse` in `leggi_coorte`);
- `/data/it/<id>/insegnamenti-e-orari/<anno>` → insegnamenti erogati nell'a.a. corrente per anno e
  curriculum: "<NOME> [<codice>]", partizione, periodo, docenti, "x su y CFU" (x è la quota del modulo o della
  partizione, y il totale: i CFU dell'insegnamento sono quelli del piano) e orari;
- `/data/insegnamento/<id>/programma` → "Testi di riferimento".

Il piano dà la struttura (prima l'elenco erogato era l'unica fonte: i CFU erano le quote dei moduli, gli esercizi
a 0 CFU erano insegnamenti, il 3° anno, non ancora erogato, e le attività senza lezioni mancavano):

- ogni anno k si legge dalla coorte che lo frequenta nell'a.a. corrente (anno 1: immatricolati 2026/27, anno 2:
  2025/26, anno 3: 2024/25). Il sito pubblica solo le ultime due coorti: per gli anni senza pagina si usa la
  coorte più vicina (per il 3° anno quella 2025/26), indicata nel campo `fonte` di ogni insegnamento;
- «CFU parziale»: se i CFU degli insegnamenti del gruppo non superano quelli da acquisire sono tutti obbligatori,
  altrimenti sono alternative (`obbligatorio: false`); i gruppi «Percorso …/Indirizzo …» (un solo percorso da
  seguire) sono curricula; i curricula con una pagina di piano propria sono i curricula del corso; gruppi
  uguali di cui se ne sceglie qualcuno (7 lingue da 36 CFU per 72 CFU), «Blocco A/B/C» (tirocinio alternativo),
  tirocini con lo stesso nome e codici diversi (3, 6 o 9 CFU) e il tirocinio «Per stages» sono alternative;
- gli insegnamenti senza anno nel piano (scelte delle lauree magistrali) hanno l'anno in cui sono erogati
  nell'a.a. corrente, altrimenti il 1° (prova finale, tirocinio e lingua: l'ultimo);
- i crediti liberi («A scelta dello studente», con gli insegnamenti suggeriti come alternative) e le attività
  senza insegnamenti (altre conoscenze, lingua) sono righe senza codice all'ultimo anno; tirocinio e prova finale
  sono nel piano;
- insegnamenti a 0 CFU (OFA, esercitazioni, frequenze) non sono nel piano; gli insegnamenti erogati ora che non
  sono nel piano delle coorti lette (a scelta) sono alternative nell'anno in cui sono erogati, con i CFU totali;
- omonimi dello stesso anno con codici diversi: i CFU (o il codice) nel nome.

Docenti, periodo, pagina e libri dell'insegnamento vengono dall'elenco erogato (e dal programma) per lo stesso
codice; i libri già raccolti (`database/contrib/auto/unive.json` e `database/corsi/unive.json`) si riusano senza
rileggere i programmi. Gli insegnamenti del piano non erogati ora hanno pagina e libri dall'a.a. precedente
(ajax `insegnamentipiano` della pagina del piano con `anno` = a.a. di inizio) se esistono; docenti e periodo non
si deducono da un altro anno.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata
import urllib.parse

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unive.it"


def _codice(url: str | None) -> str | None:
    m = re.match(r"https?://(?:www\.)?unive\.it/cdl/(\w+)", (url or "").strip())
    return m.group(1) if m else None


# Ca' Foscari divide l'anno in 4 «periodi» (1° e 2° nel 1° semestre, 3° e 4° nel 2°): le lezioni del 1° periodo vanno
# dal 21/09 a fine ottobre, quelle del 2° da inizio novembre a metà dicembre (file ICS ufficiale di ogni insegnamento),
# il 3° e il 4° da febbraio a maggio (piani delle frequenze pubblicati sul sito). «2° Periodo» NON è il 2° semestre.
PERIODO_A_SEMESTRE = {"1": "1", "2": "1", "3": "2", "4": "2"}


def _periodo(t: str) -> str | None:
    m = re.match(r"\s*(\d|I{1,3}|IV)\s*°?\s*(periodo|semestre|period|semester)", t, re.I)
    if m:
        n = {"I": "1", "II": "2", "III": "3", "IV": "4"}.get(m.group(1).upper(), m.group(1))
        if m.group(2).lower() in ("periodo", "period"):
            return PERIODO_A_SEMESTRE.get(n, n)
        return n
    return "annuale" if re.search(r"(?i)annual", t) else (t.strip() or None)


def leggi_anno(s: str) -> list[dict]:
    out = []
    curricula = re.split(r'<div class="my-2 p-0 titolo-esp">\s*Curriculum\s*<strong>(.*?)</strong>', s, flags=re.S)
    for curr, corpo in zip(curricula[1::2], curricula[2::2]):
        curr = _testo(curr)
        for card in re.split(r'(?=<div class="card border border-black">)', corpo)[1:]:
            testa = re.search(r'<a href="(?:https?:)?//www\.unive\.it/data/insegnamento/(\d+)"[^>]*>(.*?)</a>', card, re.S)
            if not testa:
                continue
            t = _testo(testa.group(2))
            m = re.match(r"(.*?)\s*\[(\w+)\]\s*$", t)
            nome, cod = (m.group(1), m.group(2)) if m else (t, None)
            ps = [_testo(x) for x in re.findall(r'<p class="mt-0 mb-0 pb-0">(.*?)</p>', card, re.S)]
            periodo = next((_periodo(x) for x in ps if re.search(r"(?i)periodo|semestre|annual", x)), None)
            cfu = re.search(r"<strong>\s*([\d.,]+)\s*(?:su\s*([\d.,]+))?\s*</strong>\s*CFU", card)
            v = float(cfu.group(1).replace(",", ".")) if cfu else None
            tot = float(cfu.group(2).replace(",", ".")) if cfu and cfu.group(2) else v
            out.append({
                "id": testa.group(1), "nome": _titolo(nome), "codice": cod, "curriculum": curr, "periodo": periodo,
                "cfu": int(v) if v is not None and v.is_integer() else v,
                "cfu_totale": int(tot) if tot is not None and tot.is_integer() else tot,
                "docenti": [" ".join(w.capitalize() if w.isupper() else w for w in _testo(d).split())
                            for d in re.findall(r'<a href="/data/persone/\d+">(.*?)</a>', card, re.S)],
            })
    return out


def libri_programma(s: str) -> list[dict]:
    m = re.search(r'<h4 class="[^"]*card-title">\s*(?:Testi di riferimento|Referral texts|Textbooks)\s*</h4>.*?'
                  r'<div class="card-body">(.*?)</div>', s, re.S)
    if not m:
        return []
    libri = []
    for lb in estrai_libri(m.group(1)):
        # righe con il solo ISBN ("978-… (print)"): si attaccano al libro precedente
        if lb["isbn"] and not re.search(r"[A-Za-z]{4,}", re.sub(r"(?i)isbn|print|pdf|epub|ebook", "", lb["citazione"])):
            if libri and not libri[-1]["isbn"]:
                libri[-1]["isbn"] = lb["isbn"]
            continue
        libri.append(lb)
    return libri


# ---------------------------------------------------------------------------------------------------------------
# Piano di studio per coorte
# ---------------------------------------------------------------------------------------------------------------

def _num(s) -> float | None:
    try:
        return float(str(s).replace(",", ".").strip())
    except ValueError:
        return None


def _cfu_int(v: float):
    return int(v) if float(v).is_integer() else v


def leggi_coorte(s: str) -> dict:
    """Pagina di una coorte («Immatricolati a.a. 2025/2026», un curriculum) → {aa, cds, pds, blocchi}.
    Un blocco è un ambito del piano (tipo di attività A-F, nome, CFU totali) con i suoi gruppi: ogni gruppo ha il
    «CFU parziale» (numero o etichetta, per esempio «Percorso X - 24 CFU») e i suoi insegnamenti."""
    fine = s.find("</main>")
    s = s[:fine] if fine > 0 else s
    m = re.search(r"Immatricolati a\.a\.\s*(\d{4})/(\d{4})", s)
    aa = int(m.group(1)) if m else None
    cds = re.search(r"'cds':\s*'(\w+)'", s)
    pds = re.search(r"'pds':\s*'(\w+)'", s)
    blocchi = []
    for tipo_blk in re.split(r'(?=<div class="card semplice")', s)[1:]:
        th = re.search(r"Tipo di attività formativa:\s*<strong>(.*?)</strong>", tipo_blk, re.S)
        if not th:
            continue
        tipo = _testo(th.group(1))
        for amb in re.split(r'(?=<div class="card tit-no-border espansione")', tipo_blk)[1:]:
            nm = re.search(r'<div class="col-8">(.*?)</div>\s*<div class="col-3"><small>CFU totali:</small>\s*([\d.,]+)',
                           amb, re.S)
            if not nm:
                continue
            gruppi = []
            tb = re.search(r"<tbody>(.*?)</tbody>", amb, re.S)
            gruppo = None
            for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", tb.group(1), re.S) if tb else []:
                tds = re.findall(r"<td([^>]*)>(.*?)</td>", tr, re.S)
                if len(tds) >= 6 or (tds and "rowspan" in tds[0][0]):
                    pt = _testo(tds[0][1])
                    gruppo = {"parz": _num(pt) if _num(pt) is not None else pt, "righe": []}
                    gruppi.append(gruppo)
                    tds = tds[1:]
                if gruppo is None or len(tds) < 5:
                    continue
                cod, ssd, anno, ins, cfu = [_testo(x[1]) for x in tds[:5]]
                gruppo["righe"].append({"codice": cod, "ssd": ssd, "anno": int(anno) if anno.isdigit() else None,
                                        "nome": ins, "cfu": _num(cfu)})
            blocchi.append({"tipo": tipo, "ambito": _testo(nm.group(1)), "tot": _num(nm.group(2)) or 0.0,
                            "gruppi": gruppi})
    return {"aa": aa, "cds": cds.group(1) if cds else None, "pds": pds.group(1) if pds else None, "blocchi": blocchi}


_TRACCIA = re.compile(r"(?i)^\W*(?:in)?(percorso|path|indirizzo|curriculum|curr\.?\s+origin\w*|profilo)\b\W*")
_BLOCCO = re.compile(r"(?i)^\W*blocco\s*[A-Z]")
_COMUNE = re.compile(r"(?i)\b(comun\w*|common|tutti|tutte|all)\b")


def _n_etichetta(parz) -> float | None:
    """CFU da acquisire dal gruppo: «CFU parziale» o il numero nell'etichetta («Percorso X - 24 CFU», «da 18 a 24 cfu»,
    «Archivistica - 18»)."""
    if isinstance(parz, float):
        return parz
    t = parz or ""
    m = re.search(r"(?i)\bda\s+(\d+)\s+a\s+(\d+)", t)
    if m:
        return float(m.group(2))
    m = re.search(r"(?i)(\d+)\s*(?:cfu|crediti|ects)", t) or re.search(r"(?i)cfu\s*(\d+)", t) or re.search(r"(\d+)\s*$", t)
    return float(m.group(1)) if m else None


def _nome_traccia(etichetta: str) -> str:
    t = _TRACCIA.sub("", etichetta.strip())
    t = re.sub(r"(?i)\s*[-–]?\s*\d+\s*(?:cfu|crediti|ects)?\b.*$", "", t)  # «- 24 CFU obbligatori …»
    t = re.sub(r"(?i)\s*[-–]?\s*cfu\s*\d+.*$", "", t)
    t = t.strip(" \"'“”*-–:")
    return re.sub(r"\s+", " ", t).replace(",", " -")


def _titolo_it(nome: str) -> str:
    """Nome dell'insegnamento in maiuscolo come nel piano → iniziali maiuscole (elisioni, accenti, numeri romani)."""
    s = re.sub(r"\s+", " ", nome.replace("‑", "-")).strip()
    if not s.isupper():
        return s
    s = re.sub(r"(?i)\b(dell|dall|all|nell|sull|coll|quest|quell|un|l|d|c)' +", lambda m: m.group(1) + "'", s)
    s = re.sub(r"([AEIOU])'(?=\W|$)", lambda m: m.group(1).translate(str.maketrans("AEIOU", "ÀÈÌÒÙ")), s)
    small = {"e", "di", "del", "della", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla", "il",
             "la", "lo", "le", "gli", "i", "ed", "nel", "nella", "sul", "tra", "fra", "and", "of", "the", "for", "to",
             "on", "in", "at", "or", "dello", "dell", "all", "ai", "agli", "alle", "nei", "nelle", "su"}
    out = []
    for k, w in enumerate(s.split()):
        low = w.lower()
        if re.fullmatch(r"(?:ii|iii|iv|vi{0,3}|ix|x)[.,:;)]?", low) or (k and low == "i" and k == len(s.split()) - 1):
            out.append(w.upper())
        elif "'" in low and low.split("'")[0] in ("dell", "dall", "all", "nell", "sull", "coll", "quest", "quell", "un", "l", "d", "c"):
            a, b = low.split("'", 1)
            out.append((a if k else a.capitalize()) + "'" + b[:1].upper() + b[1:])
        elif k and low in small:
            out.append(low)
        elif re.fullmatch(r"[a-z]-[a-z]", low):
            out.append(w)
        else:
            out.append(re.sub(r"(^|[-/(])([a-zàèéìòù])", lambda m: m.group(1) + m.group(2).upper(), low))
    return " ".join(out)


def _ssd(s: str) -> str | None:
    s = (s or "").replace("‑", "-").strip()
    return s if "/" in s and s.upper() == s else None


def righe_coorte(pagina: dict, curr_pagina: str | None) -> list[dict]:
    """Insegnamenti di una pagina di coorte, con anno (o None), obbligatorietà e percorso del blocco.
    Righe `_segnaposto` (senza codice) per i crediti liberi e le attività senza insegnamenti del piano."""
    out: list[dict] = []
    for bi, b in enumerate(pagina["blocchi"]):
        tipo = b["tipo"]
        inizio = len(out)
        gruppi = [g for g in b["gruppi"] if g["righe"]]
        libero = "scelta" in tipo.lower()
        if b["tot"] > 0 and (libero or not gruppi):
            # crediti liberi (anche con insegnamenti suggeriti) e ambiti senza insegnamenti: una riga con i loro CFU
            out.append({"codice": None, "nome": b["ambito"], "ssd": None, "anno": None, "cfu": b["tot"],
                        "obbligatorio": not libero, "curriculum": curr_pagina, "_segnaposto": True,
                        "_tipo": tipo, "_gid": (bi, -1), "_n": b["tot"]})
        if not gruppi:
            continue
        # percorsi (alternative esclusive): etichette «Percorso …/Indirizzo …», o più etichette con gli stessi CFU
        # che sommate superano quelli dell'ambito
        etichette = [g for g in gruppi if isinstance(g["parz"], str) and g["parz"].strip()]
        n_noti = [(_n_etichetta(g["parz"]) or 0.0) for g in gruppi]
        eccesso = sum(n_noti) > b["tot"] + 0.01
        stesse = len({_n_etichetta(g["parz"]) for g in etichette}) == 1
        tracce = {}
        for g in etichette:
            if _COMUNE.search(g["parz"]):
                continue
            if _TRACCIA.match(g["parz"]) or (len(etichette) > 1 and stesse and eccesso
                                              and not re.match(r"(?i)\W*(blocco|grappolo|\d)", g["parz"])):
                nome = _nome_traccia(g["parz"])
                if nome:
                    tracce[id(g)] = nome
        restante = b["tot"] - sum(n for g, n in zip(gruppi, n_noti) if _n_etichetta(g["parz"]) is not None)
        primo_blocco = True
        # più gruppi che valgono ciascuno tutti i CFU dell'ambito (es. un'altra lingua + un insegnamento comune):
        # alternative; è obbligatorio solo ciò che sta in tutte
        scambiabili: set[float] = set()
        if sum(n_noti) > b["tot"] + 0.01 and not tracce:
            # più gruppi uguali di cui se ne sceglie qualcuno (7 lingue da 36 CFU per un ambito da 72): alternative
            conteggio: dict[float, int] = {}
            for n_g in n_noti:
                conteggio[n_g] = conteggio.get(n_g, 0) + 1
            scambiabili = {n_g for n_g, k in conteggio.items() if k > 1 and n_g * k > b["tot"] + 0.01}
        comuni = None
        if (not tracce and len(gruppi) > 1 and b["tot"] > 0 and not libero
                and all(abs(n - b["tot"]) < 0.01 for n in n_noti)):
            comuni = set.intersection(*({r["codice"] for r in g["righe"]} for g in gruppi))
        for gi, g in enumerate(gruppi):
            visti = {}
            for r in g["righe"]:
                visti.setdefault((r["codice"], r["anno"]), r)
            righe = list(visti.values())
            somma = sum(r["cfu"] or 0 for r in righe)
            n = _n_etichetta(g["parz"])
            if isinstance(g["parz"], str) and _BLOCCO.match(g["parz"]):
                # «Blocco A - Track A», «Blocco B …»: percorsi alternativi che valgono gli stessi CFU dell'ambito;
                # il primo è quello ordinario, gli altri sono per casi particolari (OFA di italiano, microcredenziali)
                n = b["tot"] if primo_blocco else 0.0
                primo_blocco = False
            obbligatorio = (somma <= n + 0.01) if n is not None else (somma <= restante + 0.01)
            if len(gruppi) == 1 and b["tot"] > 0 and not obbligatorio:
                obbligatorio = somma <= b["tot"] + 0.01  # unico gruppo: valgono i CFU dell'ambito (il parziale a volte è sbagliato)
            if "stages" in tipo.lower() or libero:  # [S] alternativa al tirocinio del piano; [D] insegnamenti suggeriti
                obbligatorio = False
            elif tracce and n is None and not (g["parz"] or "").strip():
                obbligatorio = False  # senza percorso: alternativa ai percorsi dell'ambito
            elif comuni is not None:
                obbligatorio = None  # per riga: obbligatorio solo se in tutte le alternative
            elif n in scambiabili:
                obbligatorio = False
            obbligatorio_g = obbligatorio is True
            gid, dich = (bi, gi), None
            if tracce and n is None and not (g["parz"] or "").strip():
                dich = 0.0  # alternativa ai percorsi: i CFU dell'ambito sono già quelli del percorso
            if comuni is not None:
                gid, dich = (bi, 90), max(b["tot"] - sum(r["cfu"] or 0 for r in gruppi[0]["righe"] if r["codice"] in comuni), 0.0)
            elif n in scambiabili:
                gid = (bi, 91)
                dich = max(b["tot"] - sum(m for m in n_noti if m not in scambiabili), 0.0)
            traccia = tracce.get(id(g))
            curr = " - ".join(x for x in (curr_pagina, traccia) if x) or None
            for r in righe:
                if not r["cfu"]:
                    continue
                out.append({"codice": r["codice"] or None, "nome": r["nome"], "ssd": _ssd(r["ssd"]), "anno": r["anno"],
                            "cfu": r["cfu"],
                            "obbligatorio": (r["codice"] in comuni) if obbligatorio is None else obbligatorio,
                            "curriculum": curr, "_tipo": tipo, "_gid": gid, "_n": n,
                            "_dich": dich if dich is not None else (
                                somma if obbligatorio_g else
                                (min(n, somma) if n is not None else min(somma, max(restante, 0.0))))})
        # stesso nome con codici diversi nello stesso ambito (versioni in italiano e in inglese, tirocini da 3, 6 o 9
        # CFU): sono alternative dello stesso insegnamento
        nomi: dict[str, set] = {}
        for x in out[inizio:]:
            nomi.setdefault(_chiave(x["nome"]), set()).add((x["codice"], x["curriculum"]))
        for x in out[inizio:]:
            if len({cod for cod, cur in nomi[_chiave(x["nome"])] if cur == x["curriculum"]}) > 1:
                x["obbligatorio"] = False
    return out


def piano_per_coorte(pagine: list[dict]) -> dict[int, list[dict]]:
    """Coorte (anno di immatricolazione) → insegnamenti del piano, con i curricula delle pagine: un insegnamento in
    tutte le pagine della coorte vale per tutti i curricula, altrimenti per quelli che lo hanno."""
    per_aa: dict[int, list[dict]] = {}
    for p in pagine:
        if p["aa"]:
            per_aa.setdefault(p["aa"], []).append(p)
    out = {}
    for aa, ps in per_aa.items():
        molti = len(ps) > 1
        nomi = [(p["nome"] if molti else None) for p in ps]
        tutte: dict[tuple, dict] = {}
        for p, nome in zip(ps, nomi):
            for r in righe_coorte(p["piano"], nome):
                k = (r["codice"] or r["nome"], r["anno"], r.get("_segnaposto", False), r["curriculum"])
                x = tutte.get(k)
                if x:
                    x["obbligatorio"] = x["obbligatorio"] or r["obbligatorio"]
                    continue
                r["_url"] = p["url"]
                tutte[k] = r
        # lo stesso insegnamento (codice e anno) in curricula diversi: un solo insegnamento con i suoi curricula
        gruppi: dict[tuple, list[dict]] = {}
        for r in tutte.values():
            gruppi.setdefault((r["codice"] or r["nome"], r["anno"], r.get("_segnaposto", False)), []).append(r)
        righe = []
        for lista in gruppi.values():
            base = lista[0]
            currs: list[str] = []
            for x in lista:
                if x["curriculum"] and x["curriculum"] not in currs:
                    currs.append(x["curriculum"])
            # in tutte le pagine della coorte, senza percorso: vale per tutti i curricula
            tutti = molti and all(n in currs for n in nomi)
            base["curriculum"] = None if (tutti or not currs) else ", ".join(sorted(currs))
            base["obbligatorio"] = any(x["obbligatorio"] for x in lista)
            righe.append(base)
        out[aa] = righe
    return out


_PRIVATI = ("_ids", "_cds", "_pds", "_aa", "_gid", "_n", "_dich")  # campi di lavoro, non vanno nel contributo


def _sicuro(f, *a) -> None:
    try:
        f(*a)
    except Exception:  # noqa: BLE001 - un insegnamento che non si legge resta com'è
        pass


def _chiave(s: str) -> str:
    s = unicodedata.normalize("NFKD", html.unescape(s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", s)


def fetch_ateneo(uid: str = "unive", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _codice(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    log(f"[{uid}] {len(corsi)} corsi con sito unive.it/cdl")
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    # libri e docenti già raccolti, per codice: i programmi si rileggono solo per gli insegnamenti nuovi
    riuso: dict[str, dict] = {}
    for p in (ROOT / "database" / "contrib" / "auto" / f"{uid}.json", ROOT / "database" / "corsi" / f"{uid}.json"):
        if not p.exists():
            continue
        for co in json.loads(p.read_text(encoding="utf-8")).get("corsi", []):
            for i in co.get("insegnamenti") or []:
                if not i.get("codice"):
                    continue
                r = riuso.setdefault(i["codice"], {"libri": [], "docenti": set(), "letto": False, "url": None,
                                                    "periodo": None, "periodo_fonte": None})
                r["letto"] = True
                r["url"] = r["url"] or i.get("url")
                if i.get("periodo") and not r["periodo"]:
                    r["periodo"], r["periodo_fonte"] = i["periodo"], i.get("periodo_fonte")
                chiavi = {re.sub(r"\W+", "", lb["citazione"].lower())[:120] for lb in r["libri"]}
                for lb in i.get("libri") or []:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in chiavi:
                        chiavi.add(k)
                        r["libri"].append(lb)
                r["docenti"] |= set(i.get("docenti") or [])

    def build(corso: dict) -> dict | None:
        r = c.get(f"{BASE}/cdl/{_codice(corso['url'])}")
        if not r:
            return None
        m = re.search(r'href="/web/it/(\d+)/insegnamenti-e-orari"', r.text)
        mp = re.search(r'href="/web/it/(\d+)/piano-di-studio"', r.text)
        if not m and not mp:
            return None
        durata = corso.get("durata_anni") or 3
        # --- elenco erogato: docenti, periodo, pagine degli insegnamenti, anno in cui sono erogati
        erogato: dict[str, dict] = {}
        pid = m.group(1) if m else None
        for k in range(1, durata + 1) if pid else []:
            url = f"{BASE}/data/it/{pid}/insegnamenti-e-orari/{k}"
            ra = c.get(url)
            if not ra:
                continue
            for x in leggi_anno(ra.text):
                if not x["codice"]:
                    continue
                e = erogato.setdefault(x["codice"], {"ids": [], "docenti": set(), "periodo": None, "anni": set(),
                                                     "nomi": set(), "fonte": url, "cfu": 0})
                e["cfu"] = max(e["cfu"], x["cfu_totale"] or 0)
                if x["id"] not in e["ids"]:
                    e["ids"].append(x["id"])
                e["docenti"] |= set(x["docenti"])
                e["periodo"] = e["periodo"] or x["periodo"]
                e["anni"].add(k)
                e["nomi"].add(x["nome"])
        # --- piano di studio per coorte
        pagine = []
        if mp:
            rp = c.get(f"{BASE}/web/it/{mp.group(1)}/piano-di-studio")
            if rp:
                for href, testo in re.findall(r'<a [^>]*href="(/web/it/\d+/[^"#]*)"[^>]*>(.*?)</a>', rp.text, re.S):
                    t = _testo(testo)
                    mm = re.match(r"(.*?)\s*\[[A-Za-z0-9]+-\d{4}\]\s*$", t)
                    if not mm or t.lower().startswith(("piano", "regolamento")):
                        continue
                    rc = c.get(BASE + href)
                    if not rc:
                        log(f"[{uid}]   pagina del piano non letta: {BASE + href}")
                        continue
                    piano = leggi_coorte(rc.text)
                    if piano["aa"] and piano["blocchi"]:
                        pagine.append({"aa": piano["aa"], "nome": mm.group(1).strip(), "url": rc.url, "piano": piano,
                                       "cds": piano["cds"], "pds": piano["pds"]})
        coorti = piano_per_coorte(pagine)
        if not coorti:
            return None
        aa_disponibili = sorted(coorti)
        righe: dict[tuple, dict] = {}
        # curricula: le pagine di piano dell'ultima coorte (una per curriculum) o, con una sola pagina, i percorsi
        # dei gruppi «Percorso …/Indirizzo …»
        ultime = [p["nome"] for p in pagine if p["aa"] == max(aa_disponibili)]
        curricula = sorted(set(ultime)) if len(ultime) > 1 else sorted(
            {c_ for x in coorti[max(aa_disponibili)] for c_ in (x["curriculum"] or "").split(", ") if c_})
        for k in range(1, durata + 1):
            obiettivo = anno - (k - 1)
            aa = min(aa_disponibili, key=lambda a: (abs(a - obiettivo), -a))
            for x in coorti[aa]:
                cod = x["codice"]
                e = erogato.get(cod or "", {})
                if x.get("_segnaposto"):
                    anno_x = durata
                elif x["anno"]:
                    anno_x = x["anno"]
                elif e.get("anni") and x["obbligatorio"] is False:
                    anno_x = min(e["anni"])
                elif x["obbligatorio"] or not re.match(r"(?i)(base|caratterizzante|affine|a scelta)", x["_tipo"]):
                    anno_x = durata  # prova finale, tirocinio, lingua, attività obbligatorie senza anno: ultimo anno
                else:
                    anno_x = 1  # scelta senza anno né erogazione: si può seguire dal primo anno
                if anno_x != k or anno_x > durata:
                    continue
                chiave = (cod or x["nome"], anno_x)
                if chiave in righe:
                    continue
                nome = _titolo_it(x["nome"])
                for n in sorted(e.get("nomi") or []):
                    # la grafia dell'elenco erogato (sigle, maiuscole) se è lo stesso nome senza il suffisso del modulo
                    base = re.sub(r"\s*-\s*\d+\s*$", "", n)
                    if _chiave(base) == _chiave(x["nome"]) and not x.get("_segnaposto"):
                        nome = base
                        break
                nome = re.sub(r"(?<=[a-z]{3})([aeiou])'(?=\s|$)",
                              lambda m: m.group(1).translate(str.maketrans("aeiou", "àèìòù")), nome)  # «Societa'» → «Società»
                nome = re.sub(r"(?<=[àèéìòù])'(?=\s|$)", "", nome)
                righe[chiave] = {
                    "codice": cod, "nome": nome, "anno": anno_x, "periodo": e.get("periodo"), "cfu": _cfu_int(x["cfu"]),
                    "ssd": x["ssd"], "obbligatorio": bool(x["obbligatorio"]), "curriculum": x["curriculum"],
                    "docenti": sorted(e["docenti"] if e else (riuso.get(cod or "") or {}).get("docenti") or []),
                    "url": f"{BASE}/data/insegnamento/{e['ids'][0]}" if e.get("ids") else (riuso.get(cod or "") or {}).get("url"),
                    "libri": [],
                    "esami": [], "fonte": x["_url"], "verificato_il": oggi, "_ids": list(e.get("ids") or []),
                    "_cds": next((p["cds"] for p in pagine if p["url"] == x["_url"]), None),
                    "_pds": next((p["pds"] for p in pagine if p["url"] == x["_url"]), None),
                    "_aa": aa, "_gid": x.get("_gid"), "_n": x.get("_n"), "_dich": x.get("_dich"),
                }
                if e.get("periodo"):
                    righe[chiave]["periodo_fonte"] = e["fonte"]
                elif not e and (riuso.get(cod or "") or {}).get("periodo"):
                    righe[chiave]["periodo"] = riuso[cod]["periodo"]
                    if riuso[cod]["periodo_fonte"]:
                        righe[chiave]["periodo_fonte"] = riuso[cod]["periodo_fonte"]
        if not righe:
            return None
        # insegnamenti erogati nell'a.a. corrente che non sono nel piano delle coorti lette (a scelta, o di coorti più
        # vecchie ancora attive): righe facoltative nell'anno in cui sono erogati, con i CFU dell'insegnamento
        in_piano = {r["codice"] for r in righe.values() if r["codice"]}
        for cod, e in erogato.items():
            k = min(e["anni"])
            if cod in in_piano or not e["cfu"] or k > durata:
                continue
            nome = sorted(e["nomi"], key=lambda n: (len(n), n))[0]
            righe[(cod, k)] = {
                "codice": cod, "nome": nome, "anno": k, "periodo": e["periodo"], "cfu": e["cfu"], "ssd": None,
                "obbligatorio": False, "curriculum": None, "docenti": sorted(e["docenti"]),
                "url": f"{BASE}/data/insegnamento/{e['ids'][0]}", "libri": [], "esami": [], "fonte": e["fonte"],
                "verificato_il": oggi, "_ids": list(e["ids"]), "_cds": None, "_pds": None, "_aa": None,
                "_gid": None, "_n": None, "_dich": None,
            }
            if e["periodo"]:
                righe[(cod, k)]["periodo_fonte"] = e["fonte"]
        # insegnamenti omonimi dello stesso anno con codici diversi (es. «Laboratori» da 9 e da 12 CFU, tirocini da 6 e 9
        # CFU): alternative diverse, si distinguono dai CFU (o dal codice)
        omonimi: dict[tuple, list[dict]] = {}
        for riga in righe.values():
            omonimi.setdefault((riga["anno"], _chiave(riga["nome"])), []).append(riga)
        for lista in omonimi.values():
            if len(lista) > 1 and len({riga["codice"] for riga in lista}) > 1:
                per_cfu = len({riga["cfu"] for riga in lista}) == len(lista)
                for riga in lista:
                    riga["nome"] += f" ({riga['cfu']} CFU)" if per_cfu else f" ({riga['codice']})"
        ultima = max(aa_disponibili)
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": r.url if "/web/it/" in r.url else f"{BASE}/cdl/{_codice(corso['url'])}",
                "curricula": curricula or None,
                "fonte": f"{BASE}/web/it/{mp.group(1)}/piano-di-studio" if mp else f"{BASE}/web/it/{pid}/insegnamenti-e-orari",
                "verificato_il": oggi, "insegnamenti": list(righe.values()), "_ultima": ultima}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    for x in out:
        x.pop("_ultima", None)
    # --- insegnamenti del piano non erogati nell'a.a. corrente e senza dati già raccolti: la pagina dell'insegnamento
    # dei due a.a. precedenti (ajax «insegnamentipiano» della pagina del piano), per i libri e il collegamento
    def precedente(it: dict) -> None:
        for aa in (anno - 1, anno - 2):
            q = urllib.parse.urlencode({"afgencod": it["codice"], "cds": it["_cds"], "pds": it["_pds"], "anno": aa,
                                        "lang": "it"})
            r = c.get(f"{BASE}/data/ajax/Didattica/insegnamentipiano?{q}")
            trovati = list(dict.fromkeys(re.findall(r"/data/insegnamento/(\d+)", r.text))) if r else []
            if trovati:
                it["_ids"] = trovati
                it["url"] = f"{BASE}/data/insegnamento/{trovati[0]}"
                return

    if syllabus:
        da_cercare = [it for x in out for it in x["insegnamenti"]
                      if it["codice"] and not it["_ids"] and it["codice"] not in riuso and it["_cds"]]
        log(f"[{uid}] insegnamenti non erogati ora, da cercare negli a.a. precedenti: {len(da_cercare)}")
        with cf.ThreadPoolExecutor(4) as ex:
            list(ex.map(lambda it: _sicuro(precedente, it), da_cercare))
    # --- libri: già raccolti per codice, altrimenti dal programma dell'insegnamento
    ids = sorted({i for x in out for it in x["insegnamenti"] for i in it["_ids"]
                  if it["codice"] not in riuso})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"programmi da leggere: {len(ids) if syllabus else 0}")
    libri: dict[str, list[dict]] = {}

    def leggi(i: str) -> None:
        try:
            r = c.get(f"{BASE}/data/insegnamento/{i}/programma")
            libri[i] = libri_programma(r.text) if r else []
        except Exception:  # noqa: BLE001
            libri[i] = []

    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, _ in enumerate(ex.map(leggi, ids), 1):
                if n % 500 == 0:
                    log(f"[{uid}]   programmi {n}/{len(ids)}")
    trovati = 0
    for x in out:
        for it in x["insegnamenti"]:
            viste = set()
            cod = it["codice"]
            sorgenti = list((riuso.get(cod or "") or {}).get("libri") or [])
            for i in it["_ids"]:
                sorgenti += libri.get(i, [])
            for lb in sorgenti:
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    it["libri"].append(lb)
            if syllabus and (it["libri"] or it["_ids"] or cod in riuso):
                it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
            for k in _PRIVATI:
                it.pop(k, None)
            trovati += len(it["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unive.it, Piano di studio per coorte e Insegnamenti e orari "
            "(adapters/unive.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
