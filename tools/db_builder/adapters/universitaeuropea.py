"""Insegnamenti dell'Università Europea di Roma da www.uer.it e dal suo Course Catalogue Cineca.

Pagine del sito (www.uer.it): la pagina del corso e quelle dei suoi indirizzi/curricula (`/<area>/indirizzo/<nome>/`,
`/<area>/bsc-…/<nome>/`, `/<area>/bachelors-degree/<nome>/`, linkate dalla pagina del corso) hanno il piano di studi
della coorte in tabelle: «I anno – 2026/27», «1st YEAR – 2026/27», «First year – 2026/27», «1° anno – 2026/27 –
Comune / Curriculum: …» con insegnamento, SSD e CFU, e la riga «Totale crediti … anno».

- Ogni anno si controlla con il «Totale» scritto nella pagina (la somma delle righe deve tornare); se non torna lo si
  scrive nel log. Un anno non è obbligato a valere 60 CFU: il corso intero sì (Economia 54/61/65, Psicologia 61/63/56…).
- Ogni pagina-indirizzo è un curriculum. Una riga uguale (nome, anno, CFU) in tutti i curricula non ha curriculum; se
  uno stesso nome ha CFU diversi tra curricula (es. «Statistica» 8 e 10 CFU) sono righe distinte per curriculum: la
  variante più diffusa tiene il nome, le altre «Nome (N CFU)». Righe omonime nella stessa pagina e anno (due
  «Insegnamento a scelta dello studente») si numerano.
- Le tabelle «Insegnamenti a scelta» / «Elective courses» e «Laboratori» / «Laboratories» non hanno l'anno: sono le
  opzioni della riga segnaposto dello stesso tipo («Due insegnamenti a scelta dello studente», «Laboratorio») e la
  sostituiscono, a scelta, nell'anno del segnaposto. Senza tabella delle opzioni il segnaposto resta (a scelta).
- build_db dà all'insegnamento l'id «<corso>-<slug del nome, 40 caratteri>» e fonde le righe dello stesso anno con lo
  stesso id: righe diverse con lo stesso inizio di nome tengono un id proprio.
- Fisioterapia e Medicina e Chirurgia non pubblicano il piano sul sito (solo PDF dell'offerta formativa): il piano è
  quello del loro Course Catalogue Cineca (`unier.coursecatalogue.cineca.it`, API pubblica `/api/v1/corso/<coorte>/<cod>`),
  coorte 2026, con codice dell'attività e docenti. I gruppi «a scelta» senza attività valgono i CFU scritti nella loro
  etichetta o, dove manca, quelli del PDF ufficiale dell'offerta formativa (`CFU_PDF`).
Le schede degli insegnamenti sono su Esse3 con accesso: niente libri.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time
import unicodedata
import urllib.parse

from .periodi_cineca_syllabus import Api, _periodo, _walk, pulizia
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
HOST = "unier.coursecatalogue.cineca.it"
ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
PAROLE = {"primo": 1, "first": 1, "secondo": 2, "second": 2, "terzo": 3, "third": 3, "quarto": 4, "fourth": 4,
          "quinto": 5, "fifth": 5, "sesto": 6, "sixth": 6}
_PAR = r"primo|secondo|terzo|quarto|quinto|sesto|first|second|third|fourth|fifth|sixth"
_DATA = r"\s*[–-]\s*\d{4}\s*/\s*\d{2}"
INTESTAZIONE_ROM = re.compile(r"\b(VI|IV|V|III|II|I)\s+anno\b" + _DATA)
INTESTAZIONE_ALTRO = re.compile(rf"(?i)\b(?:([1-6])\s*(?:°|º|st|nd|rd|th)?|({_PAR}))\s+(?:anno|year)\b" + _DATA)
ANNO_ROM = re.compile(r"\b(VI|IV|V|III|II|I)\s+anno\b")
ANNO_ALTRO = re.compile(rf"(?i)\b(?:([1-6])\s*(?:°|º|st|nd|rd|th)?|({_PAR}))\s+(?:anno|year)\b")
TOTALE = re.compile(r"(?i)^(totale|total)\b|\btotal credits\b")
SEGNAPOSTO_SCELTA = re.compile(r"(?i)\ba scelta\b|\belective\b|\bscelta libera\b")
SEGNAPOSTO_LAB = re.compile(r"(?i)^(laboratori[o]?|laborator(?:ies|y))$")
OPZIONI_SCELTA = re.compile(r"(?i)(insegnamenti|corsi|esami)\s+(a scelta|opzionali)|elective")
OPZIONI_LAB = re.compile(r"(?i)\blaboratori|\blaboratories\b")
# nome scritto diversamente in una sola pagina di indirizzo (stesso insegnamento, stessi CFU, negli altri quattro)
CORREZIONI_NOMI = {
    "Osservazione del comportamento nei contexti educativi, formativi e laboratorio":
        "Osservazione del comportamento nei contesti educativi, formativi e laboratorio",
}
# CFU dei gruppi «a scelta» senza attività e senza CFU nell'etichetta del Catalogo, dal PDF dell'offerta formativa
PDF_MEDICINA = ("https://www.uer.it/wp-content/uploads/sites/15/2026/05/"
                "CURRICULUM-MEDICINA-E-CHIRURGIA-LM41-2026-2027-SITO-26-05-26.pdf")
CFU_PDF = {
    ("lm-41-medicina-e-chirurgia", 5, "tirocini a scelta dello studente"): (2, PDF_MEDICINA),
    ("lm-41-medicina-e-chirurgia", 5, "a scelta dello studente"): (5, PDF_MEDICINA),
    ("lm-41-medicina-e-chirurgia", 6, "tirocini a scelta dello studente"): (2, PDF_MEDICINA),
}


# CFU che la pagina del sito non mostra (cella rovinata nel codice della pagina) e che il Course Catalogue dà per lo stesso
# insegnamento dello stesso curriculum: (fine dell'id del corso, nome normalizzato) -> (CFU, fonte)
CFU_MANCANTI = {
    ("l-18-economia-e-gestione-aziendale", "artificial intelligence for decision making"):
        (6, "https://unier.coursecatalogue.cineca.it/corsi/2026/10470"),
}
# CFU del PDF dell'offerta formativa 2026/27 (ufficiale, sul sito dell'ateneo) diversi dal Catalogo per due corsi integrati
# (le righe del PDF tornano con il «Totale crediti» dell'anno: 59 e 69; il Catalogo dà 58 e 70, stesso totale del corso)
CORREZIONI_CFU_PDF = {
    ("lm-41-medicina-e-chirurgia", 2, "biochimica e biologia molecolare"): (15, PDF_MEDICINA),
    ("lm-41-medicina-e-chirurgia", 4, "malattie dell apparato cardiovascolare e respiratorio"): (14, PDF_MEDICINA),
}


def _norm(s: str) -> str:
    n = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", n).strip()


def _slug40(nome: str) -> str:
    """Come `slug(nome, 40)` di build_db.py (lo slug dell'id di un insegnamento)."""
    return _norm(nome).replace(" ", "-")[:40].strip("-")


def _anno(m) -> int | None:
    if not m:
        return None
    if m.re in (INTESTAZIONE_ROM, ANNO_ROM):
        return ROMANI[m.group(1)]
    return int(m.group(1)) if m.group(1) else PAROLE[m.group(2).lower()]


def anno_in(testo: str, intestazione: bool = False) -> tuple[int | None, int]:
    """(anno, fine del testo che lo contiene) dell'ultima menzione «II anno», «2nd YEAR», «1° anno»…;
    con `intestazione` solo se seguita da «– 2026/27»."""
    ms = []
    for rx in ((INTESTAZIONE_ROM, INTESTAZIONE_ALTRO) if intestazione else (ANNO_ROM, ANNO_ALTRO)):
        ms += list(rx.finditer(testo))
    if not ms:
        return None, 0
    m = max(ms, key=lambda x: x.start())
    return _anno(m), m.end()


def _numero(s: str) -> float | None:
    m = re.search(r"\d+(?:[.,]\d+)?", s or "")
    if not m:
        return None
    v = float(m.group(0).replace(",", "."))
    return int(v) if v.is_integer() else v


def leggi_tabelle(s: str) -> list[dict]:
    """Le tabelle della pagina: anno (se è un anno del piano), ambito (None = tutta la pagina, «comune» o il nome
    di un curriculum), righe [{nome, ssd, cfu}], totale dichiarato e tipo di opzioni (`scelta`, `lab`) se senza anno."""
    s = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", "", s)
    s = s.replace("&#8211;", "–").replace("&ndash;", "–")
    out, prev = [], 0
    for m in re.finditer(r"<table.*?</table>", s, re.S):
        label = _testo(s[prev:m.start()])[-260:]
        prev = m.end()
        righe_html = [[_testo(x) for x in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, re.S)]
                      for r in re.findall(r"<tr.*?</tr>", m.group(0), re.S)]
        anno, ambito, totale, voci, titolo = None, "", None, [], None
        for c in righe_html:
            if not any(c):
                continue
            if len(c) == 1 or not any(c[1:]):
                a, fine = anno_in(c[0], intestazione=True)
                if a:
                    anno, ambito = a, c[0][fine:]
                continue
            primo = c[0]
            if re.fullmatch(r"(?i)(insegnamento|titolo)", primo.strip()):
                titolo = primo.lower()
                continue
            if TOTALE.search(primo):
                totale = _numero(c[-1])
                if anno is None:
                    anno = anno_in(primo)[0]
                continue
            ssd = c[1] if len(c) >= 3 and re.match(r"[A-Z]{2,5}[-/]", c[1]) else None
            nome = _titolo(html.unescape(primo)).strip()
            voci.append({"nome": CORREZIONI_NOMI.get(nome, nome), "ssd": ssd, "cfu": _numero(c[-1])})
        if titolo == "titolo":  # tabella dei laboratori con la colonna dell'anno (già nelle righe del piano)
            continue
        if anno is None:
            a, fine = anno_in(label, intestazione=True)
            if a:
                anno, ambito = a, label[fine:]
        tab = {"anno": anno, "ambito": None, "righe": voci, "totale": totale, "opzioni": None, "label": label[-120:]}
        if anno is not None:
            mc = re.search(r"(?i)curriculum\s*:\s*(.+)$", ambito.strip())
            if mc:
                tab["ambito"] = mc.group(1).strip()
            elif re.search(r"(?i)\bcomune\s*$", ambito.strip()):
                tab["ambito"] = "comune"
        else:
            coda = label[-70:]
            tab["opzioni"] = "scelta" if OPZIONI_SCELTA.search(coda) else "lab" if OPZIONI_LAB.search(coda) else None
        if voci:
            out.append(tab)
    return out


def _numera_omonimi(righe: list[dict]) -> None:
    """Righe con lo stesso nome nello stesso anno (due «Insegnamento a scelta dello studente»): numerate."""
    conta: dict[tuple, int] = {}
    for r in righe:
        conta[(r["anno"], _norm(r["nome"]))] = conta.get((r["anno"], _norm(r["nome"])), 0) + 1
    visti: dict[tuple, int] = {}
    for r in righe:
        k = (r["anno"], _norm(r["nome"]))
        if conta[k] > 1:
            visti[k] = visti.get(k, 0) + 1
            r["nome"] = f"{r['nome']} {visti[k]}"


def piani_da_pagina(tabs: list[dict], nome_pagina: str | None, log=print, rif: str = "") -> dict[str | None, list[dict]]:
    """{curriculum o None: righe del piano} di una pagina. Le tabelle del piano sono quelle con l'anno; quelle con
    «Curriculum: X» sono del curriculum X, «Comune» (o nessun ambito) di tutti quelli della pagina."""
    piano = [t for t in tabs if t["anno"]]
    opzioni = {k: [r for t in tabs if t["opzioni"] == k for r in t["righe"]] for k in ("scelta", "lab")}
    curricula = sorted({t["ambito"] for t in piano if t["ambito"] and t["ambito"] != "comune"})
    out: dict[str | None, list[dict]] = {}
    for cur in curricula or [nome_pagina]:
        righe = []
        for t in piano:
            if curricula and t["ambito"] not in (None, "comune", cur):
                continue
            tot = sum(r["cfu"] or 0 for r in t["righe"])
            if t["totale"] is not None and abs(tot - t["totale"]) > 1e-9:
                log(f"[universitaeuropea]   {rif}{cur or ''} anno {t['anno']} ({t['ambito'] or 'piano'}): righe {tot:g} CFU, "
                    f"totale dichiarato {t['totale']:g}")
            for r in t["righe"]:
                righe.append({"anno": t["anno"], "nome": r["nome"], "ssd": r["ssd"], "cfu": r["cfu"],
                              "obbligatorio": False if SEGNAPOSTO_SCELTA.search(r["nome"]) else None})
        for tipo in ("scelta", "lab"):
            if not opzioni[tipo]:
                continue
            if tipo == "scelta":
                ph = [r for r in righe if r["obbligatorio"] is False]
            else:
                ph = [r for r in righe if SEGNAPOSTO_LAB.match(r["nome"])]
            if len(ph) != 1:
                log(f"[universitaeuropea]   {rif}{cur or ''}: {len(ph)} segnaposto per le opzioni «{tipo}», segnaposto tenuti")
                continue
            pos = righe.index(ph[0])
            righe[pos:pos + 1] = [{"anno": ph[0]["anno"], "nome": o["nome"], "ssd": o["ssd"], "cfu": o["cfu"],
                                   "obbligatorio": False} for o in opzioni[tipo]]
        _numera_omonimi(righe)
        out[cur] = righe
    return out


def _unisci_curricula(piani: dict[str | None, list[dict]]) -> tuple[list[dict], list[str]]:
    """Righe del corso da più piani (uno per curriculum). Righe con lo stesso nome e anno: uguali (CFU) -> una sola riga
    con i suoi curricula (nessuno se vale per tutti); CFU diversi -> una riga per variante."""
    nomi = [n for n in piani if n]
    if len(piani) == 1:
        (_, righe), = piani.items()
        return [dict(r, _cs=set()) for r in righe], []
    per_chiave: dict[tuple, dict] = {}
    ordine: list[tuple] = []
    for cur, righe in piani.items():
        for r in righe:
            k = (r["anno"], _norm(r["nome"]))
            if k not in per_chiave:
                per_chiave[k] = {}
                ordine.append(k)
            v = per_chiave[k].setdefault(r["cfu"], dict(r, _cs=set()))
            v["_cs"].add(cur)
            v["ssd"] = v["ssd"] or r["ssd"]
    out = []
    tutti = set(nomi)
    for k in ordine:
        varianti = sorted(per_chiave[k].values(), key=lambda v: (-len(v["_cs"]), v["cfu"] or 0))
        for n, v in enumerate(varianti):
            if n and v["cfu"] is not None:
                v["nome"] = f"{v['nome']} ({v['cfu']:g} CFU)"
            if v["_cs"] == tutti:
                v["_cs"] = set()
            out.append(v)
    return out, sorted(nomi)


def _id_distinti(corso_id: str, righe: list[dict], log=print) -> None:
    """Righe diverse con lo stesso inizio di nome (40 caratteri dello slug), anno e tipo sarebbero fuse da build_db:
    la prima tiene l'id del nome, le altre un id proprio (il sito non dà il codice)."""
    viste: dict[tuple, int] = {}
    contatori: dict[str, int] = {}
    for r in righe:
        if r.get("codice"):
            continue
        j = (r["anno"], _slug40(r["nome"]), r["obbligatorio"] is False)
        viste[j] = viste.get(j, 0) + 1
        if viste[j] > 1:
            contatori[j[1]] = contatori.get(j[1], 1) + 1
            r["id"] = f"{corso_id}-{j[1]}-{contatori[j[1]]}"
            log(f"[universitaeuropea]   {corso_id} anno {r['anno']}: «{r['nome']}» ha lo stesso inizio di un'altra "
                f"riga, id {r['id']}")


PICCOLE = {"e", "ed", "o", "a", "ai", "agli", "di", "del", "dello", "della", "dei", "delle", "degli", "per", "in", "con", "da",
           "al", "alla", "il", "la", "lo", "le", "gli", "nel", "nella", "sul", "tra", "and", "of", "the"}


def _titolo_cineca(s: str) -> str:
    """Nome del Catalogo (spesso in maiuscolo, con «SANITA'» per «Sanità»): iniziale maiuscola, numeri romani in maiuscolo."""
    s = re.sub(r"\s+", " ", s or "").strip()
    s = re.sub(r"(?<=[A-Za-z])([AEIOU])'(?=\s|$)", lambda m: {"A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù"}[m.group(1)], s)
    if sum(c.isupper() for c in s) <= sum(c.islower() for c in s):
        return s
    out = []
    for k, w in enumerate(s.lower().split()):
        m = re.match(r"(dell|all|nell|sull|dall|l)'(.+)", w)
        if m:
            out.append(f"{m.group(1)}'{m.group(2)}" if k else f"{m.group(1).capitalize()}'{m.group(2)}")
        elif re.fullmatch(r"[ivx]+", w):
            out.append(w.upper())
        elif k and w in PICCOLE:
            out.append(w)
        else:
            out.append(re.sub(r"^(\W*)(\w)", lambda m: m.group(1) + m.group(2).upper(), w))
    return " ".join(out)


def _nome_persona(des: str) -> str:
    return " ".join(w.capitalize() if w.isupper() else w for w in (des or "").split())


def piano_cineca(api: Api, cds_cod: str, coorte: int, corso_id: str, base: str, oggi: str, log=print) -> list[dict]:
    """Righe del piano della coorte dal Course Catalogue: un solo percorso con gli anni numerici."""
    j = api.get(f"/corso/{coorte}/{cds_cod}")
    j = j[0] if isinstance(j, list) and j else j
    if not isinstance(j, dict):
        return []
    percorsi = [p for p in j.get("percorsi") or [] if any(str(a.get("anno")).isdigit() for a in p.get("anni") or [])]
    if len(percorsi) != 1:
        log(f"[universitaeuropea]   {corso_id}: {len(percorsi)} percorsi nel Catalogo, non letto")
        return []
    coda = corso_id.split("universitaeuropea-", 1)[-1]
    pagina_corso = f"{base}/corsi/{coorte}/{cds_cod}"
    righe = []
    for a in percorsi[0]["anni"]:
        if not str(a.get("anno")).isdigit():
            continue
        k = int(a["anno"])
        for g in a.get("insegnamenti") or []:
            etichetta = _testo(g.get("label_it") or "")
            scelta = bool(re.search(r"(?i)\ba scelta\b", etichetta)) and g.get("cod") != "OO"
            for att in g.get("attivita") or []:
                ad = att.get("adCod") or att.get("cod")
                docenti = sorted({_nome_persona(x.get("des")) for x in att.get("docenti") or [] if x.get("des")})
                url = (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}/"
                       f"{att.get('corso_percorso_id')}?coorte={coorte}")
                riga = {
                    "codice": str(ad), "nome": _titolo_cineca(att.get("des_it") or str(ad)), "anno": k, "periodo": None,
                    "cfu": att.get("crediti"), "ssd": None, "obbligatorio": False if scelta else None,
                    "curriculum": None, "docenti": docenti, "url": url,
                    "libri": [], "esami": [], "fonte": pagina_corso, "verificato_il": oggi,
                    "stato_libri": "da_aggiungere"}
                corr = CORREZIONI_CFU_PDF.get((coda, k, _norm(riga["nome"])))
                if corr:
                    riga["cfu"], riga["fonte"] = corr
                p, ini, fin, _ = _periodo(att)  # «Primo/Secondo Ciclo Semestrale» con le date del ciclo, se interpretabile
                p = pulizia.periodo(p, ini, fin) if p else None
                if p in ("1", "2", "annuale"):
                    riga.update(periodo=p, periodo_inizio=ini, periodo_fine=fin, periodo_fonte=url)
                righe.append(riga)
            if not g.get("attivita"):  # gruppo di scelta senza attività: i CFU sono nell'etichetta («… (6 CFU)»)
                nome = re.sub(r"(?i)^\s*(primo|secondo|terzo|quarto|quinto|sesto)\s+anno\s*[-–]\s*", "", etichetta)
                nome = re.sub(r"\s*\(\s*\d+\s*CFU\s*\)\s*$", "", nome).strip()
                mc = re.search(r"\(\s*(\d+)\s*CFU\s*\)", etichetta)
                cfu, url = (int(mc.group(1)), pagina_corso) if mc else CFU_PDF.get((coda, k, _norm(nome)), (None, None))
                if cfu is None:
                    log(f"[universitaeuropea]   {corso_id} anno {k}: «{etichetta}» senza CFU, non riportato")
                    continue
                righe.append({
                    "codice": None, "nome": _titolo_cineca(nome), "anno": k, "periodo": None, "cfu": cfu, "ssd": None,
                    "obbligatorio": False if scelta else None, "curriculum": None, "docenti": [], "url": url,
                    "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere"})
    return righe


def pagine_piano(c: Client, corso: dict) -> tuple[str | None, dict[str, tuple]]:
    """(url finale della pagina del corso, {url: (nome del curriculum o None, tabelle)}) della pagina del corso e
    delle pagine-indirizzo che linka."""
    r = c.get(corso["url"])
    if not r:
        return None, {}
    area = "/" + urllib.parse.urlparse(r.url).path.strip("/").split("/")[0] + "/"
    pagine = {r.url: (None, leggi_tabelle(r.text))}
    for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
        p = urllib.parse.urlparse(urllib.parse.urljoin(r.url, html.unescape(h)))
        if not (p.netloc.endswith("uer.it") and p.path.startswith(area)):
            continue
        if not re.search(r"/(indirizzo|bachelors-degree|masters-degree|bsc-[^/]+|msc-[^/]+)/[^/]+/?$", p.path):
            continue
        u = f"https://{p.netloc}{p.path.rstrip('/')}/"
        if u in pagine:
            continue
        rp = c.get(u)
        h1 = re.search(r"<h1[^>]*>(.*?)</h1>", rp.text if rp else "", re.S)
        nome = _testo(h1.group(1)) if h1 else _testo(t)
        nome = re.sub(r"(?i)^(indirizzo|profilo)\s+", "", nome)
        if re.match(r"(?i)^(BA|MA|BSc|MSc) in ", nome):
            nome = re.split(r"\s+[–-]\s+", nome)[-1]
        pagine[u] = (nome or None, leggi_tabelle(rp.text) if rp else [])
    return r.url, pagine


def fetch_ateneo(uid: str = "universitaeuropea", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if "uer.it/" in (x.get("url") or "")]
    if max_cds:
        corsi = corsi[:max_cds]
    coorte = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    c = Client(rate=3.0)
    api = Api(HOST)
    base = f"https://{HOST}"
    oggi = time.strftime("%Y-%m-%d")
    cds_list: list[dict] = []
    _walk(api.get("/corsi", {"anno": coorte, "minimal": "true"}) or [],
          lambda x: "cdsCod" in x and "aa" in x and "cod" in x and "des_it" in x, cds_list)
    catalogo = {_norm(x["des_it"]): x for x in cds_list if str(x["aa"]) == str(coorte)}
    out = []
    for corso in corsi:
        url_corso, pagine = pagine_piano(c, corso)
        if not url_corso:
            continue
        durata = corso.get("durata_anni") or 6
        piani_pagina: dict[str | None, list[dict]] = {}
        fonti: dict[str | None, str] = {}
        for u, (nome, tabs) in pagine.items():
            anni = [t["anno"] for t in tabs if t["anno"]]
            if not anni:
                continue
            if max(anni) > durata:
                log(f"[{uid}]   {corso['id']}: la pagina {u} ha anni oltre la durata ({durata}), saltata")
                continue
            rif = corso["id"].split("universitaeuropea-")[-1][:30] + " "
            for cur, righe in piani_da_pagina(tabs, nome, log, rif=rif).items():
                for r in righe:
                    if r["cfu"] is None:
                        r["cfu"] = CFU_MANCANTI.get((corso["id"].split("universitaeuropea-")[-1], _norm(r["nome"])),
                                                    (None,))[0]
                        if r["cfu"] is None:
                            log(f"[{uid}]   {corso['id']}: «{r['nome']}» senza CFU nella pagina {u}")
                piani_pagina[cur] = righe
                fonti[cur] = u
        cds = next((v for k, v in catalogo.items() if _norm(corso["nome"]).startswith(k)), None)
        d = api.get(f"/corso/{coorte}/{cds['cod']}") if cds else None
        d = d[0] if isinstance(d, list) and d else d
        sede = (d or {}).get("sedeDenominazioneComune")
        sede = re.sub(r"^(\S+)", lambda m: m.group(1).capitalize(), sede) if sede else None
        if piani_pagina:
            righe, curricula = _unisci_curricula(piani_pagina)
            primo_url = next(iter(fonti.values()))
            items = []
            for r in righe:
                cs = r.pop("_cs", set())
                u = fonti[sorted(cs)[0]] if cs else primo_url
                items.append({"codice": None, "nome": r["nome"], "anno": r["anno"], "periodo": None, "cfu": r["cfu"],
                              "ssd": r["ssd"], "obbligatorio": r["obbligatorio"],
                              "curriculum": ", ".join(sorted(cs)) if cs else None, "docenti": [], "url": u,
                              "libri": [], "esami": [], "fonte": u, "verificato_il": oggi, "stato_libri": "da_aggiungere"})
            fonte_corso = url_corso
        else:
            if not cds:
                log(f"[{uid}]   {corso['id']}: nessun piano né sul sito né nel Catalogo")
                continue
            items = piano_cineca(api, cds["cod"], coorte, corso["id"], base, oggi, log)
            curricula = []
            fonte_corso = f"{base}/corsi/{coorte}/{cds['cod']}"
        if not items:
            continue
        _id_distinti(corso["id"], items, log)
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": url_corso, "curricula": curricula or None,
                    **({"sede": sede} if sede else {}), "fonte": fonte_corso, "verificato_il": oggi,
                    "insegnamenti": items})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uer.it e dal Course Catalogue (adapters/universitaeuropea.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
