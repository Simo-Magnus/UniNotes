"""Insegnamenti dell'Università Telematica Guglielmo Marconi dalle pagine dei piani di studio del sito.

Ogni corso (pagina `https://www.unimarconi.it/<corso>-<classe>/`) linka le pagine dei suoi curricula o orientamenti
(`curriculum-…`, `orientamento-…`, `piano-di-studi-statutario-l-22`): «A.A. 2026/2027», una tabella per anno
(«I anno», «II anno»…) con TAF | SSD e Corso | CFU e la riga «Totale», poi le «Rose» delle scelte (tabelle o
elenchi puntati con titolo «Rosa N – … – M CFU») e l'elenco «Esami a scelta libera (tra quelli non sostenuti)».
I vecchi regolamenti didattici in PDF (usati prima) non hanno la coorte attuale né sempre le stesse regole.

Come si leggono le righe della tabella dell'anno:

- esame con SSD e nome (il docente è nel link): insegnamento obbligatorio; con due righe e due CFU («Tecnica e
  didattica… ¦ con Attività tecnico-pratiche 1» / «6 ¦ 9») sono due insegnamenti con i CFU dati; con un solo CFU
  è un insegnamento solo (nome «… con Attività tecnico-pratiche 2»);
- «Scelta libera» (anche «6+6»): i crediti liberi dello studente, una riga a scelta con la somma dei CFU; gli esami
  dell'elenco «a scelta libera» che non sono già nel piano del curriculum si aggiungono, a scelta, in ogni anno che
  ha la «Scelta libera» (con i CFU dell'elenco);
- «A scelta tra: …», «Uno a scelta nella Rosa N», «Attività affini-integrative ¦ 1 insegnamento scelto nella Rosa 2»:
  gruppo a scelta: ogni alternativa è un insegnamento a scelta di quell'anno, con i CFU dell'alternativa se li dà
  (nella rosa, nell'etichetta «(6 CFU)» o «– 1 CFU») o quelli del gruppo; un gruppo con una sola alternativa è da
  sostenere per intero (obbligatorio); un elenco senza «scelta» nell'intestazione («Laboratori di indirizzo:») è un
  elenco di attività da sostenere tutte;
- «6 o 12» nella rosa (Tirocinio): due alternative «(6 CFU)» e «(12 CFU)».
Stesso nome nello stesso anno con CFU diversi (tra curricula o nell'elenco della scelta libera): il nome porta
«(N CFU)». Le righe uguali dei curricula si uniscono: nessun curriculum se vale per tutti. I nomi dei curricula non
hanno virgole (`pulizia.percorsi` le userebbe per separare i percorsi). Una pagina «piano» unica (L-22, L-36) non è
un curriculum. Il totale dell'anno dichiarato dalla pagina e la somma dei CFU dei gruppi/righe si confrontano nel log.
Particolarità: il docente è l'attributo `data-teacher` del link (i segnaposto «Docente Docente» e «Docente non
impostato» si scartano); una cella dei CFU vuota (carattere invisibile) si legge dallo stesso esame negli elenchi
della pagina; `CFU_REGOLAMENTO` ha i CFU che la pagina non dà e il regolamento didattico sì («Tirocinio pratico»
di Giurisprudenza, 6); build_db dà l'id «<corso>-<slug del nome, 40 caratteri>»: se due righe dello stesso anno
differiscono solo dopo il 40° carattere («… (12 CFU)» / «… (6 CFU)», «(modulo I)» / «(modulo II)») quella con il
codice dell'insegnamento sulla piattaforma (`data-course-id`) lo usa come `codice`. Il sito non pubblica i
programmi: le pagine `externalplatformprogram/<id>` dei link rispondono 404, quindi nessun libro.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le pagine restano su disco.
Esecuzione locale (scrive `database/contrib/auto/unimarconi.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unimarconi.py
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import sys
import time
import unicodedata

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .unibo import Client  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITO = "https://www.unimarconi.it"
# pagina ufficiale di ogni corso (elenco dei suoi piani); le pagine più vecchie (`l-1-corso-di-laurea-…`) reindirizzano
PAGINE = {
    "unimarconi-l-1-beni-culturali-conoscenza-gestione-valorizzazione": "/beni-culturali-conoscenza-gestione-valorizzazione-l-1/",
    "unimarconi-l-18-economia-aziendale-e-management": "/economia-aziendale-e-management-l-18/",
    "unimarconi-l-8-ingegneria-informatica": "/ingegneria-informatica-l-8/",
    "unimarconi-l-7-l-9-ingegneria-per-linnovazione-e-la-sostenibilita": "/ingegneria-per-linnovazione-e-la-sostenibilita-interclasse-l-7-l-9/",
    "unimarconi-l-10-lettere": "/lettere-l-10/",
    "unimarconi-l-19-scienze-dell-educazione-e-della-formazione": "/scienze-delleducazione-e-della-formazione-l-19/",
    "unimarconi-l-20-scienze-della-comunicazione-e-media-digitali": "/scienze-della-comunicazione-e-media-digitali-l-20/",
    "unimarconi-l-24-scienze-e-tecniche-psicologiche": "/scienze-e-tecniche-psicologiche-l24/",
    "unimarconi-l-14-scienze-giuridiche": "/scienze-giuridiche-l-14/",
    "unimarconi-l-22-scienze-motorie-e-sportive": "/scienze-motorie-e-sportive-l-22/",
    "unimarconi-l-36-scienze-politiche-e-delle-relazioni-internazionali": "/scienze-politiche-e-delle-relazioni-internazionali-l-36/",
    "unimarconi-lm-77-economia-internazionale-e-management-per-linnovazione-e-la-s":
        "/economia-internazionale-e-management-per-linnovazione-e-la-sostenibilita-lm-77/",
    "unimarconi-lm-14-filologia-e-letterature-moderne": "/filologia-e-letterature-moderne-lm-14/",
    "unimarconi-lm-23-ingegneria-civile-per-la-progettazione-ecosostenibile": "/ingegneria-civile-per-la-progettazione-ecosostenibile-lm-23/",
    "unimarconi-lm-33-ingegneria-industriale-per-linnovazione-sostenibile": "/ingegneria-industriale-per-linnovazione-sostenibile-lm-33/",
    "unimarconi-lm-32-ingegneria-informatica": "/ingegneria-informatica-lm-32/",
    "unimarconi-lm-38-lingue-moderne-per-la-comunicazione-internazionale": "/lingue-moderne-per-la-comunicazione-internazionale-lm-38/",
    "unimarconi-lm-51-psicologia": "/psicologia-lm-51/",
    "unimarconi-lm-85-scienze-pedagogiche-e-strategie-didattiche": "/scienze-pedagogiche-e-strategie-didattiche-lm-85/",
    "unimarconi-lmg-01-giurisprudenza": "/giurisprudenza-lmg-01/",
}
ROMANI = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6}
SSD_RE = re.compile(r"^([A-Z]{2,5})[-/ ]?(\d{1,2})[-/ ]?([A-Z])?$")
SSD_VECCHIO = re.compile(r"^([A-Z]{1,5}(?:-[A-Z]{1,5})?/\d{2})$")  # «SECS-P/08»: formato di prima del riordino, come sulla pagina
# CFU che la pagina del piano non dà ma il regolamento didattico sì: (nome, corso) → (CFU, fonte)
CFU_REGOLAMENTO = {
    ("tirocinio pratico", "unimarconi-lmg-01-giurisprudenza"):
        (6, "https://www.unimarconi.it/wp-content/uploads/2025/07/Regolamento_Didattico_LMG01.pdf"),
}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _slug40(nome: str) -> str:
    """Come `build_db.slug(nome, 40)`."""
    s = unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip().replace(" ", "-")[:40].strip("-")


def _testo(s: str) -> str:
    s = html.unescape(re.sub(r"<[^>]+>", "", s or ""))
    s = s.replace(" ", " ").replace("﻿", "").replace("​", "")
    return re.sub(r"\s+", " ", s).strip()


def _ssd(tok: str) -> str | None:
    """«ITAL-01/A» (anche «HIST/01-A», «PHIL/04A», «GSPS-4/B») → «ITAL-01/A»."""
    if SSD_VECCHIO.match(tok or ""):
        return tok
    m = SSD_RE.match(tok or "")
    if not m or not m.group(3) or m.group(1) in {"CFU"}:
        return None
    return f"{m.group(1)}-{int(m.group(2)):02d}/{m.group(3)}"


def _numeri(s: str) -> list[int | float]:
    out = []
    for x in re.findall(r"\d+(?:[.,]\d+)?", s or ""):
        v = float(x.replace(",", "."))
        out.append(int(v) if v.is_integer() else v)
    return out


def _riga(parte_html: str) -> dict:
    """Una riga di cella (tra due <br>): testo, SSD iniziale, nome, docente del link."""
    testo = _testo(parte_html)
    doc = re.search(r'data-teacher(?:-1)?="([^"]*)"', parte_html)
    docente = html.unescape(doc.group(1)).strip() if doc and doc.group(1).strip() else None
    if docente and _norm(docente).replace("docente", "").replace("non impostato", "").strip() == "":  # segnaposto
        docente = None
    testo = re.sub(r"\)(?=[A-Z])", ") ", testo)
    pid = re.search(r'data-course-id(?:-1)?="(\d+)"', parte_html)
    return {"testo": testo, "docente": docente, "pid": pid.group(1) if pid else None}


def _linee(cella: str) -> list[dict]:
    return [r for r in (_riga(p) for p in re.split(r"<br[^>]*>", cella)) if r["testo"]]


def _ssd_nome(testo: str) -> tuple[str | None, str]:
    testo = re.sub(r"^[-•–\s]+", "", testo).strip()
    primo, _, resto = testo.partition(" ")
    ssd = _ssd(primo)
    if ssd and resto.strip():
        testo = resto.strip()
    else:
        ssd = None
    # note fuori dal link: «[ove non già sostenuto alla triennale]» resta come nota tra parentesi, mentre
    # «– video lezione introduttiva» descrive il materiale (l'esame è «Matematica I»)
    testo = re.sub(r"\[([^\]]*)\]", r"()", testo)
    testo = re.sub(r"\s*[–-]\s*video lezione introduttiva\s*$", "", testo, flags=re.I)
    return ssd, testo


def _opzione(riga: dict) -> dict:
    """Alternativa di un gruppo: «HELL-01/B Letteratura greca (12 CFU)», «Laboratorio… – 1 CFU», «Tirocinio pratico»."""
    ssd, nome = _ssd_nome(riga["testo"])
    cfu = None
    m = re.search(r"\s*[(–-]\s*(\d+(?:[.,]\d+)?)\s*CFU\)?\s*$", nome)
    if m:
        cfu = _numeri(m.group(1))[0]
        nome = nome[:m.start()].strip()
    nome = nome.strip(" -–*")  # «*» è il rimando a una nota della pagina
    return {"ssd": ssd, "nome": nome, "cfu": cfu, "docente": riga["docente"], "pid": riga.get("pid")}


def _nome_curriculum(titolo: str) -> str:
    t = _testo(titolo)
    t = re.sub(r"\s*\((?:L|LM|LMG)-\d+(?:\s+L-\d+)?\)\s*$", "", t).strip()
    t = re.sub(r"(?i)^(curriculum|orientamento|english program)\s*", "", t)
    t = re.sub(r"(?i)^in lingua inglese\s*", "", t)
    t = t.replace("“", "").replace("”", "").replace('"', "").strip(" –-")
    t = re.sub(r"^[–-]\s*", "", t)
    t = re.sub(r"\s*[–-]\s*", " – ", t) if " – " in t or " - " in t else t
    # pulizia.percorsi separa i percorsi alle virgole: nei nomi non ce ne sono
    t = re.sub(r",\s*(?=(?:del|della|dei|delle|degli)\s)", " ", t)
    t = re.sub(r",\s*", " - ", t)
    return t.strip()


def leggi_piano(testo: str) -> dict:
    """Pagina di un curriculum → {titolo, anni: {n: [slot]}, rose: {n: {...}}, libera: [...], totali: {n: CFU}}."""
    m = re.search(r'<h2 class="mb-3">(.*?)</h2>', testo, re.S)
    titolo = _testo(m.group(1)) if m else ""
    inizio = m.end() if m else 0
    fine = testo.find("Richiedi informazioni", inizio)
    corpo = testo[inizio:fine if fine > 0 else None]
    anni: dict[int, list[dict]] = {}
    rose: dict[int, dict] = {}
    libera: list[dict] = []
    totali: dict[int, float] = {}
    stato, anno, rosa = None, None, None
    for b in re.finditer(r"<h([1-6])[^>]*>(.*?)</h\1>|<table.*?</table>|<ul[^>]*>.*?</ul>", corpo, re.S):
        if b.group(1):
            h = _testo(b.group(2))
            if re.match(r"(?i)^(I{1,3}|IV|V|VI)\s+anno$", h):
                stato, anno = "anno", ROMANI[h.split()[0].lower()]
                anni.setdefault(anno, [])
            elif re.match(r"(?i)^rosa\s*\d+", h):
                n = int(re.search(r"\d+", h).group(0))
                cfu = re.search(r"(\d+)\s*CFU", h)
                rosa = rose.setdefault(n, {"titolo": h, "cfu": int(cfu.group(1)) if cfu else None, "opzioni": []})
                stato = "rosa"
            elif re.search(r"(?i)scelta libera", h):
                stato = "libera"
            else:
                stato = None
            continue
        blocco = b.group(0)
        if blocco.startswith("<ul"):
            if stato == "rosa":
                for li in re.findall(r"<li[^>]*>(.*?)</li>", blocco, re.S):
                    t = _testo(li)
                    if t:
                        rosa["opzioni"].append(_opzione({"testo": t, "docente": None}) | {"cfu": rosa["cfu"]})
            continue
        for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", blocco, re.S):
            celle = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tr, re.S)
            if not celle or "<th" in tr:
                continue
            if stato == "anno" and len(celle) == 3:
                nome_testo = _testo(celle[1])
                if re.match(r"(?i)^totale\b", nome_testo):
                    totali[anno] = (_numeri(_testo(re.sub(r"<br[^>]*>", " ¦ ", celle[2]))) or [None])[0]
                    continue
                cfu_testo = _testo(re.sub(r"<br[^>]*>", " ¦ ", celle[2]))
                anni[anno].append({"taf": _testo(celle[0]) or None, "linee": _linee(celle[1]),
                                   "cfu_testo": cfu_testo, "cfu": _numeri(cfu_testo)})
            elif stato in ("rosa", "libera") and len(celle) == 2:
                for r in _linee(celle[0]):
                    cfu_testo = _testo(re.sub(r"<br[^>]*>", " ¦ ", celle[1]))
                    num = _numeri(cfu_testo)
                    if not num:  # intestazioni interne («Un insegnamento a scelta fra i seguenti:»)
                        continue
                    o = _opzione(r)
                    if re.search(r"\d\s*o\s*\d", cfu_testo):  # «6 o 12»: due alternative
                        for v in num:
                            (rosa["opzioni"] if stato == "rosa" else libera).append(
                                dict(o, nome=f"{o['nome']} ({v} CFU)", cfu=v))
                        continue
                    o["cfu"] = num[0]
                    (rosa["opzioni"] if stato == "rosa" else libera).append(o)
    return {"titolo": titolo, "anni": anni, "rose": rose, "libera": libera, "totali": totali}


def righe_anno(piano: dict, anno: int, log=print) -> tuple[list[dict], float, bool]:
    """Righe del piano di un anno e somma dei CFU dei gruppi (confrontabile con il «Totale» della pagina)."""
    righe: list[dict] = []
    somma = 0.0
    ha_libera = False

    def aggiungi(o, cfu, obbligatorio):
        righe.append({"nome": o["nome"], "ssd": o.get("ssd"), "cfu": cfu, "obbligatorio": obbligatorio,
                      "docente": o.get("docente"), "pid": o.get("pid")})

    for slot in piano["anni"].get(anno, []):
        linee, num = slot["linee"], slot["cfu"]
        somma += sum(num)
        if not linee:
            continue
        intero = " ".join(r["testo"] for r in linee)
        cfu_gruppo = sum(num) if num else None
        if re.match(r"(?i)^scelta libera\b", linee[0]["testo"]) and len(linee) == 1:
            ha_libera = True
            righe.append({"nome": re.sub(r"(?i)^scelta libera", "Scelta libera", linee[0]["testo"]), "ssd": None,
                          "cfu": cfu_gruppo, "obbligatorio": False, "docente": None, "libera": True})
            continue
        rosa_m = re.search(r"(?i)\brosa\s*(\d+)", intero)
        if rosa_m:
            r = piano["rose"].get(int(rosa_m.group(1)))
            if not r or not r["opzioni"]:
                log(f"      rosa {rosa_m.group(1)} non trovata ({intero[:60]})")
                continue
            for o in r["opzioni"]:
                aggiungi(o, o["cfu"] if o["cfu"] is not None else r["cfu"] or cfu_gruppo, len(r["opzioni"]) == 1)
            continue
        # intestazione di un elenco: la prima riga con «scelt…» o che finisce con «:» (anche «Diritto civile, a scelta fra:»)
        k = next((n for n, r in enumerate(linee) if re.search(r"(?i)\bscelt|\bfra:|\btra:|:$", r["testo"])), None)
        if k is not None and len(linee) - k > 1:
            intest = linee[k]["testo"]
            opz = [_opzione(r) for r in linee[k + 1:]]
            a_scelta = bool(re.search(r"(?i)\bscelt", intest))
            if not a_scelta and len(opz) > 1:
                # elenco di attività da sostenere tutte: i CFU sono quelli delle voci (o i CFU del gruppo diviso)
                for o in opz:
                    aggiungi(o, o["cfu"] if o["cfu"] is not None else None, True)
                continue
            for o in opz:
                cfu = o["cfu"] if o["cfu"] is not None else (cfu_gruppo if len(num) <= 1 else None)
                aggiungi(o, cfu, len(opz) == 1)
            continue
        if k is not None and re.search(r"(?i)\bscelt", linee[k]["testo"]) and ":" in linee[k]["testo"] \
                and len(linee) == 1 and re.search(r":\s*\S", linee[k]["testo"]):
            # «A scelta tra: inglese, francese»: alternative separate da virgola
            elenco = [x.strip() for x in linee[k]["testo"].split(":", 1)[1].split(",") if x.strip()]
            for x in elenco:
                aggiungi({"nome": x[:1].upper() + x[1:], "ssd": None}, cfu_gruppo, len(elenco) == 1)
            continue
        # riga fissa (con eventuale «con Attività…» sulla seconda riga e due CFU)
        ssd, nome = _ssd_nome(linee[0]["testo"])
        if len(linee) == 2 and len(num) == 2 and re.match(r"(?i)^con\s", linee[1]["testo"]):
            aggiungi({"ssd": ssd, "nome": nome, "docente": linee[0]["docente"], "pid": linee[0]["pid"]}, num[0], True)
            aggiungi({"ssd": None, "nome": re.sub(r"(?i)^con\s+", "", linee[1]["testo"]), "docente": linee[1]["docente"],
                      "pid": linee[1]["pid"]}, num[1], True)
            continue
        if len(linee) > 1:
            opz = [_opzione(r) for r in linee]
            if all(o["cfu"] is not None for o in opz):
                # più attività, ognuna con i suoi CFU («-Laboratory: … – 6 CFU ¦ -Electrical Engineering Laboratory – 6 CFU»)
                for o in opz:
                    aggiungi(o, o["cfu"], True)
                continue
            nome = nome + " " + " ".join(r["testo"] for r in linee[1:])
        if not num:
            # CFU vuoti sulla pagina (cella con un carattere invisibile): quelli dello stesso esame negli elenchi della pagina
            lista = piano["libera"] + [o for r in piano["rose"].values() for o in r["opzioni"]]
            trovati = {o["cfu"] for o in lista if _norm(o["nome"]) == _norm(nome) and o["cfu"] is not None}
            if len(trovati) == 1:
                cfu_gruppo = trovati.pop()
                somma += cfu_gruppo
                log(f"      CFU vuoti per «{nome}»: {cfu_gruppo:g} dall'elenco della stessa pagina")
        if len(num) > 1:
            log(f"      CFU multipli su una riga: {intero[:70]} → {slot['cfu_testo']}")
        aggiungi({"ssd": ssd, "nome": nome, "docente": linee[0]["docente"], "pid": linee[0]["pid"]}, cfu_gruppo, True)
    return righe, somma, ha_libera


def righe_curriculum(piano: dict, log=print) -> list[dict]:
    """Tutte le righe di un curriculum con l'anno; aggiunge gli esami dell'elenco della scelta libera."""
    out: list[dict] = []
    anni_libera: list[int] = []
    for a in sorted(piano["anni"]):
        righe, somma, libera = righe_anno(piano, a, log)
        tot = piano["totali"].get(a)
        if tot is not None and abs(somma - tot) > 0.01:
            log(f"      anno {a}: somma dei CFU {somma:g} ≠ totale della pagina {tot:g}")
        for r in righe:
            r["anno"] = a
        out.extend(righe)
        if libera:
            anni_libera.append(a)
    presenti = {_norm(r["nome"]) for r in out}
    if piano["libera"] and not anni_libera:
        log("      elenco della scelta libera senza riga «Scelta libera» nel piano: non aggiunto")
    for o in piano["libera"]:
        if _norm(o["nome"]) in presenti:
            continue
        for a in anni_libera:
            out.append({"nome": o["nome"], "ssd": o.get("ssd"), "cfu": o["cfu"], "obbligatorio": False,
                        "docente": o.get("docente"), "pid": o.get("pid"), "anno": a})
    return out


def fetch_ateneo(uid: str = "unimarconi", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if x["id"] in PAGINE]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        r = c.get(SITO + PAGINE[corso["id"]])
        if not r:
            log(f"[{uid}] {corso['id']}: pagina del corso non letta")
            continue
        links = []
        for h in re.findall(r'href="(https://www\.unimarconi\.it/(?:curriculum|orientamento|piano-di-studi)[^"]*)"', r.text):
            if "accoglienza" not in h and h not in links:
                links.append(h)
        piani = []
        for u in links:
            rp = c.get(u)
            if not rp:
                log(f"[{uid}]   {u}: non letta")
                continue
            p = leggi_piano(rp.text)
            if not p["anni"]:
                log(f"[{uid}]   {u}: nessun anno")
                continue
            p["url"], p["curriculum"] = u, _nome_curriculum(p["titolo"])
            piani.append(p)
        if not piani:
            continue
        unico = len(piani) == 1
        nomi = [p["curriculum"] for p in piani]
        if len(set(nomi)) != len(nomi):
            log(f"[{uid}]   {corso['id']}: curricula con lo stesso nome {nomi}")
        # righe per curriculum
        tutte: list[dict] = []
        for p in piani:
            log(f"[{uid}]   {p['url'].rsplit('/', 2)[1]}")
            for rg in righe_curriculum(p, log):
                rg["_c"], rg["_url"] = p["curriculum"], p["url"]
                tutte.append(rg)
        for rg in tutte:
            if rg["cfu"] is None and (_norm(rg["nome"]), corso["id"]) in CFU_REGOLAMENTO:
                rg["cfu"], fonte_cfu = CFU_REGOLAMENTO[(_norm(rg["nome"]), corso["id"])]
                log(f"      CFU di «{rg['nome']}» dal regolamento didattico: {rg['cfu']} ({fonte_cfu})")
        # stesso nome e anno con CFU diversi (tra curricula o nell'elenco): il nome porta i CFU
        per_nome: dict[tuple, set] = {}
        for rg in tutte:
            per_nome.setdefault((rg["anno"], _norm(rg["nome"]), rg["obbligatorio"]), set()).add(rg["cfu"])
        for rg in tutte:
            if len(per_nome[(rg["anno"], _norm(rg["nome"]), rg["obbligatorio"])]) > 1 and rg["cfu"] is not None:
                rg["nome"] = f"{rg['nome']} ({rg['cfu']:g} CFU)"
        righe: dict[tuple, dict] = {}
        for rg in tutte:
            key = (rg["anno"], _norm(rg["nome"]), rg["cfu"], rg["obbligatorio"])
            it = righe.get(key)
            if not it:
                it = righe[key] = {
                    "codice": None, "nome": rg["nome"], "anno": rg["anno"], "periodo": None, "cfu": rg["cfu"],
                    "ssd": rg.get("ssd"), "obbligatorio": rg["obbligatorio"], "curriculum": None,
                    "docenti": [], "url": rg["_url"], "libri": [], "esami": [], "fonte": rg["_url"],
                    "verificato_il": oggi, "stato_libri": "da_aggiungere", "_c": set(), "_pid": rg.get("pid")}
            it["_c"].add(rg["_c"])
            it["_pid"] = it["_pid"] or rg.get("pid")
            if rg.get("docente") and rg["docente"] not in it["docenti"]:
                it["docenti"].append(rg["docente"])
            it["ssd"] = it["ssd"] or rg.get("ssd")
        # build_db dà all'insegnamento l'id «<corso>-<slug del nome, 40 caratteri>»: due righe dello stesso anno che
        # differiscono solo dopo il 40° carattere («… (12 CFU)» / «… (6 CFU)», «(modulo I)» / «(modulo II)») sarebbero
        # fuse. Una sola riga tiene l'id del nome, le altre il codice dell'insegnamento sulla piattaforma (data-course-id)
        gruppi: dict[tuple, list[dict]] = {}
        for i in righe.values():
            gruppi.setdefault((i["anno"], _slug40(i["nome"]), i["obbligatorio"] is False), []).append(i)
        for g in gruppi.values():
            if len(g) > 1:
                g.sort(key=lambda i: (i["_pid"] is not None, i["nome"]))
                for i in g[1:] if g[0]["_pid"] is None else g:
                    if i["_pid"]:
                        i["codice"] = i["_pid"]
                    else:
                        log(f"[{uid}]   {corso['id']}: id in conflitto per «{i['nome']}»")
        for i in righe.values():
            i.pop("_pid", None)
            cs = i.pop("_c")
            if not unico and cs != set(nomi):
                i["curriculum"] = ", ".join(sorted(cs))
            elif not unico:
                i["url"] = i["fonte"] = SITO + PAGINE[corso["id"]]
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": max(max(p["anni"]) for p in piani), "url": SITO + PAGINE[corso["id"]],
                    "curricula": None if unico else sorted(nomi), "fonte": SITO + PAGINE[corso["id"]],
                    "verificato_il": oggi,
                    "insegnamenti": sorted(righe.values(), key=lambda i: (i["anno"], i["nome"]))})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dalle pagine dei piani di studio di www.unimarconi.it "
                                                 "(adapters/unimarconi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


if __name__ == "__main__":
    dest = ROOT / "database" / "contrib" / "auto" / "unimarconi.json"
    esistente = json.loads(dest.read_text(encoding="utf-8")) if dest.exists() else {}
    dati = fetch_ateneo()
    for k in ("appelli", "canali"):
        if esistente.get(k) and not dati.get(k):
            dati[k] = esistente[k]
    dest.write_text(json.dumps(dati, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"scritto {dest}")
