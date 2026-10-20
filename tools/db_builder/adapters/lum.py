"""Insegnamenti, docenti e libri della LUM "Giuseppe Degennaro" da www.lum.it.

La pagina di ogni corso ha la fisarmonica "Piano di studi A.A. 2026/2027" con, per ogni
anno ("1° anno", …), gli insegnamenti: nome, CFU, docenti (link `lum.it/docenti/…`) e
"Scheda insegnamento" (PDF). Più blocchi nello stesso a.a. sono curricula diversi (senza nome:
si uniscono). Dalla scheda (pypdf) si leggono "Anno di corso e semestre di erogazione" e
"Materiale didattico utilizzato e materiale didattico consigliato".

Il piano dell'a.a. corrente si legge con `leggi_piani`: ogni «piano» della pagina (blocco `nome_piano`, «Impresa
Digitale», «Sistemi Produttivi», …) è un curriculum; nelle magistrali il secondo anno ha i percorsi
(«2° anno - Percorso in …»). Le tabelle «Insegnamenti a scelta» / «Elective Courses» sono l'elenco delle opzioni
del gruppo «N insegnamenti a scelta» scritto in un anno del piano: la riga segnaposto (con i CFU del gruppo) è
sostituita dalle opzioni, a scelta, nell'anno in cui compare il segnaposto. Le righe «(*) …» sono alternative.
Le correzioni da regolamenti ufficiali (PDF del corso) sono in `CFU_REGOLAMENTO` e `CORREZIONI`, con la fonte.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import io
import json
import pathlib
import re
import time

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5}


def leggi_piano(s: str, anno: int) -> list[dict]:
    # intestazione «Piano di studi A.A. 2026/2027» oppure, nelle pagine più recenti, «Piano di studi 26/27»
    m = re.search(rf"Piano di studi (?:A\.A\.\s*)?(?:{anno}\s*/\s*{anno + 1}|{anno % 100:02d}\s*/\s*{(anno + 1) % 100:02d})"
                  rf"(.*?)(?=Piano di studi (?:A\.A\.\s*)?\d{{2}}|$)", s, re.S)
    if not m:
        return []
    out, k, cur = [], None, None
    for e in re.finditer(r'<h4[^>]*>\s*(\d)\s*°\s*anno(?:\s*-\s*Percorso in\s*([^<]*?))?\s*</h4>'
                         r'|<h4[^>]*>\s*(Insegnamenti a scelta)[^<]*</h4>'
                         r'|<div class="box clearfix">\s*<p>(.*?)</p>\s*<p class="col2 right">(.*?)</p>(.*?)'
                         r'(?=<div class="box clearfix">|<h4|$)', m.group(1), re.S | re.I):
        if e.group(1):
            k, cur = int(e.group(1)), (_testo(e.group(2)) or None) if e.group(2) else None
        elif e.group(3):
            k, cur = None, None
        else:
            corpo = e.group(6)
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(e.group(5)))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            sch = re.search(r'<a href="([^"]+)"[^>]*class="link_syllabus"', corpo)
            out.append({"anno": k, "curriculum": cur, "nome": _titolo(html.unescape(_testo(e.group(4)))),
                        "cfu": int(v) if v is not None and v.is_integer() else v,
                        "docenti": [_testo(d) for d in re.findall(r'/docenti/[^"]*"[^>]*>(.*?)</a>', corpo, re.S)],
                        "scheda": html.unescape(sch.group(1)) if sch else None})
    return out


def _righe_tabella(layout: str) -> list[tuple[str, list[str]]]:
    """Le schede a.a. 2026/27 sono una tabella a due colonne (etichetta | contenuto): con
    `extract_text()` le parole escono una per riga e le celle si mescolano. Con
    `extraction_mode="layout"` le colonne restano allineate: si separano alla colonna in cui
    inizia il contenuto di «Denominazione» e si raggruppano le righe per etichetta."""
    m = re.search(r"^( *)(Denominazion\w*)( {3,})\S", layout, re.M)
    if not m:
        return []
    c0 = len(m.group(1)) + len(m.group(2)) + len(m.group(3))
    righe: list[tuple[str, list[str]]] = []
    for riga in layout.splitlines():
        if not riga.strip():
            continue
        et, cont = riga[:c0 - 2], riga[c0 - 2:].strip()
        if re.fullmatch(r"A\.A\.\s*\d{4}\s*/\s*\d{4}|\d{1,2}", cont) and not et.strip():
            continue  # intestazione e numero di pagina
        if et.strip() and re.match(r" {0,2}[A-ZÀ-Ý]", et):
            righe.append((et.strip(), [cont] if cont else []))
        elif righe:
            if et.strip():
                righe[-1] = (righe[-1][0] + " " + et.strip(), righe[-1][1])
            if cont:
                righe[-1][1].append(cont)
    return righe


_SEM = {"1": "1", "i": "1", "primo": "1", "2": "2", "ii": "2", "secondo": "2"}


def _periodo(testo: str) -> str | None:
    """«1° anno, 1° semestre», «Anno di corso: II semestre di erogazione: primo», «… annuale»."""
    t = re.sub(r"\s+", " ", testo.lower())
    t = re.sub(r"seme\s+stre", "semestre", t)  # kerning del PDF: «Secondo seme stre»
    s = (re.search(r"\b(1|2|i{1,2}|primo|secondo)\s*[°^º]?\s*semestre\b(?!\s+di\s+erogazione)", t)
         or re.search(r"semestre di erogazione:?\s*(1|2|i{1,2}|primo|secondo)\b", t))
    if s:
        return _SEM[s.group(1)]
    if re.search(r"semestre di erogazione:?\s*(?:\w+\s+anno,\s*)?annual|\b\d°?\s*anno,\s*annual", t):
        return "annuale"
    return None


_PUNTO = r"[^\w\s(\"'“«‘]"  # qualsiasi simbolo di punto elenco (•, ●, ✔,  di Word, -, –)
_NON_LIBRO = re.compile(
    r"(?i)^(?:(?:le |il |la |i |gli |delle |dei )?(?:dispens|material|slide|lucidi|appunti)|elencare|indicare|nb\b|n\.b|"
    r"casi stud|articol|sar[àa] |gli studenti|per i non|per gli studenti|"
    r"testi? (?:consigliat|di riferimento|adottat)|libri? di testo|bibliografia|riferimenti)")


def _libri_materiale(righe: list[str]) -> list[dict]:
    """Voci della cella «Materiale didattico»: una per punto elenco o numero (le righe seguenti la continuano).
    Il tipo (consigliato/obbligatorio) solo se la cella lo dice («Testi consigliati», «facoltativo»)."""
    from .testi import _libero, _strutturato, _tipo
    voci: list[str] = []
    for l in righe:
        if re.match(rf"(?:{_PUNTO}\s*|(?:\d{{1,2}}[.)]|\(?[a-zA-Z][.)])\s+)", l) or _NON_LIBRO.match(l) or not voci:
            voci.append(re.sub(rf"^(?:{_PUNTO}|\d{{1,2}}[.)]|\(?[a-zA-Z][.)])\s*", "", l))
        else:
            voci[-1] += " " + l
    out, viste, tipo_sez = [], set(), None
    for v in voci:
        v = re.sub(r"\s+", " ", v).strip()
        if not v:
            continue
        if re.match(r"(?i)^(?:testi|libri|letture|materiale)\s+(?:consigliat\w+|facoltativ\w+|di approfondimento)\s*:?$", v):
            tipo_sez = "consigliato"
            continue
        if re.match(r"(?i)^(?:testi|libri)\s+(?:obbligatori\w*|adottat\w+|di testo|di riferimento)\s*:?$", v):
            tipo_sez = "obbligatorio" if re.search(r"obbligator|adottat", v, re.I) else None
            continue
        if v.endswith(":") or len(v) < 12 or len(v) > 600 or _NON_LIBRO.match(v):
            continue
        if not re.search(r"[A-Za-zÀ-ÿ]{3}.*[A-Za-zÀ-ÿ]{3}", v) or not (re.search(r"[,.]", v) or _strutturato(v)):
            if len(v.split()) < 3:
                continue
        item = _strutturato(v) or _libero(v)
        item["tipo"] = item.get("tipo") or _tipo(v) or tipo_sez
        key = re.sub(r"\W+", "", item["citazione"].lower())[:120]
        if key not in viste:
            viste.add(key)
            out.append(item)
    return out



def _leggi_scheda_tabella(data: bytes) -> dict | None:
    try:
        from pypdf import PdfReader
        layout = "\n".join(p.extract_text(extraction_mode="layout") or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - PDF illeggibile
        return None
    righe = _righe_tabella(layout)
    if not righe:
        return None
    periodo, materiale, programma = None, [], []
    for et, cont in righe:
        e = et.lower()
        if e.startswith("anno di corso") and "semestre" in e:
            periodo = _periodo(" ".join(cont))
        elif e.startswith("materiale didattico"):
            materiale = cont
        elif e.startswith("programma") or e.startswith("contenuti del corso"):
            programma = cont
    if not periodo:  # schede «per regolamento»: «Anno di corso: II   semestre di erogazione: primo»
        periodo = _periodo(layout)
    libri = _libri_materiale(materiale)
    return {"periodo": periodo, "libri": libri, "programma": programma}


def leggi_scheda(data: bytes) -> dict:
    t = _leggi_scheda_tabella(data)
    if t and (t["periodo"] or t["libri"]):
        return t
    try:
        from pypdf import PdfReader
        testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - PDF illeggibile
        return {"periodo": None, "libri": []}
    per = re.search(r"semestre\s+di\s+erogazione\s*\n?\s*\w+\s+anno,\s*(primo|secondo)\s+semestre", testo, re.I)
    if not per and re.search(r"semestre\s+di\s+erogazione\s*\n?\s*\w+\s+anno,\s*annual", testo, re.I):
        periodo = "annuale"
    else:
        periodo = {"primo": "1", "secondo": "2"}.get(per.group(1).lower()) if per else None
    m = re.search(r"Materiale\s+didattico\s+utilizzato.*?consigliato\s*\n(.*?)(?:\n\s*(?:Altre informazioni|Note|"
                  r"Modalit[àa]|Lingua)\b|\Z)", testo, re.S | re.I)
    righe: list[str] = []
    for r in (m.group(1).splitlines() if m else []):
        r = r.strip(" •-–\t")
        if not r:
            continue
        # le righe che continuano un riferimento (minuscola, cifra, parentesi) si uniscono alla precedente
        if righe and (r[0].islower() or r[0] in "(,;") and not righe[-1].endswith("."):
            righe[-1] += " " + r
        else:
            righe.append(r)
    return {"periodo": periodo, "libri": estrai_libri("<br>".join(righe))}




# ---------------------------------------------------------------------------------------------
# Piano di studi dell'a.a. corrente: tutti i piani (curricula) della pagina del corso
# ---------------------------------------------------------------------------------------------

# Pagina del piano di studi di ogni corso (l'`url` di Universitaly punta spesso alla home o a un indirizzo
# vecchio). Gli id sono quelli di database/corsi/lum.json; la pagina di Medicina vale anche per la «replica».
PAGINE = {
    "lum-l-18-business-economics-and-organization": "https://www.lum.it/laurea-in-business-economics-and-organization/",
    "lum-l-18-economia-e-gestione-aziendale": "https://www.lum.it/laurea-triennale-economia-organizzazione-aziendale/",
    "lum-l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot": "https://www.lum.it/laurea-triennale-fisioterapia/",
    "lum-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf": "https://www.lum.it/laurea-triennale-infermieristica/",
    "lum-l-8-ingegneria-biomedica": "https://www.lum.it/laurea-triennale-ingegneria-biomedica/",
    "lum-l-9-ingegneria-gestionale": "https://www.lum.it/laurea-triennale-ingegneria-gestionale/",
    "lum-lm-77-economia-e-management": "https://www.lum.it/laurea-magistrale-economia-management/",
    "lum-lm-31-ingegneria-gestionale": "https://www.lum.it/laurea-magistrale-ingegneria-gestionale/",
    "lum-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic":
        "https://www.lum.it/laurea-triennale-in-scienze-infermieristiche-ed-ostetriche-profilo-infermieristico/",
    "lum-lmg-01-giurisprudenza": "https://www.lum.it/laurea-magistrale-giurisprudenza-ciclo-unico/",
    "lum-lm-41-medicina-e-chirurgia": "https://www.lum.it/laurea-magistrale-medicina-chirurgia/",
    "lum-lm-41-medicina-e-chirurgia-replica-casamassima": "https://www.lum.it/laurea-magistrale-medicina-chirurgia/",
    "lum-lm-46-odontoiatria-e-protesi-dentaria": "https://www.lum.it/laurea-magistrale-in-odontoiatria-e-protesi-dentaria/",
}

_REG = "https://www.lum.it/wp-content/uploads/"
# CFU che la pagina del piano non scrive (cella vuota) e che il regolamento ufficiale dà:
# (id corso, nome minuscolo) -> (CFU, fonte)
CFU_REGOLAMENTO = {
    ("lum-lm-77-economia-e-management", n): (8, _REG + "2026/04/REG-CDS-LM77-26-27.pdf")
    for n in ("corporate advisory and investment banking", "risk management and derivatives instruments",
              "brand management", "gestione della logistica distributiva")
}
# Valori della pagina che contraddicono il regolamento ufficiale dello stesso a.a. (nel regolamento il
# secondo anno vale 60 CFU con «Direzione dei servizi infermieristici» a 9 e un solo «Laboratorio II anno»):
# (id corso, anno, nome minuscolo) -> (CFU, fonte)
CORREZIONI = {
    ("lum-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic", 2,
     "direzione dei servizi infermieristici"): (9, _REG + "2026/07/Regolamento-didattico-con-allegati-1.pdf"),
}

_ORD_EN = {"1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6}
_PLACEHOLDER = re.compile(r"(?i)\bscelta\b|\belective\b")
_AFASS = re.compile(r"(?i)\bAFASS\b|attivit[àa] formative a scelta dello studente")


def _pannello(s: str, anno: int) -> str | None:
    """Il pannello a fisarmonica dell'a.a. («Piano di studi A.A. 2026/2027», «Piano di studi 26/27»,
    «A.A. 2026/2027 - Recommended study plans/…»)."""
    ts = [(m.start(), _testo(m.group(1))) for m in re.finditer(r'vc_tta-title-text">(.*?)</span>', s, re.S)]
    anni = re.compile(rf"(?<!\d){anno}\s*/\s*{anno + 1}(?!\d)|(?<!\d){anno % 100:02d}\s*/\s*{(anno + 1) % 100:02d}(?!\d)")
    for k, (pos, titolo) in enumerate(ts):
        if anni.search(titolo) and re.search(r"(?i)piano|piani|study plan", titolo):
            fine = ts[k + 1][0] if k + 1 < len(ts) else len(s)
            return s[pos:fine]
    return None


def _num(t: str):
    m = re.search(r"\d+(?:[.,]\d+)?", t or "")
    if not m:
        return None
    v = float(m.group(0).replace(",", "."))
    return int(v) if v.is_integer() else v


def _nome_riga(raw: str) -> tuple[str, bool]:
    """(nome pulito, alternativa): «(*) Nome», «(#) Nome» e «Nome*» sono alternative a scelta; «(**)» in coda è una nota."""
    n = re.sub(r"\s+", " ", html.unescape(_testo(raw))).strip()
    alt = False
    m = re.match(r"^\(\s*(?:\*{1,2}|#)\s*\)\s*", n)
    if m:
        n, alt = n[m.end():], True
    n = re.sub(r"\s*\(\s*\*{1,2}\s*\)\s*$", "", n)
    if re.search(r"\S\*+$", n):
        n, alt = re.sub(r"\s*\*+$", "", n), True
    n = re.sub(r"(?i)storia delle giustizia", "Storia della giustizia", n.strip())  # refuso della pagina (il regolamento ha «della»)
    if not (n.isupper() and len(re.sub(r"\W", "", n)) <= 6):  # le sigle (AFASS, TVPES) restano maiuscole
        n = _titolo(n)
    return n, alt


def _nome_piano(t: str) -> str:
    t = re.sub(r"\s*[–-]?\s*A\.A\.\s*\d{4}\s*/\s*\d{2,4}\s*$", "", html.unescape(_testo(t))).strip(" –-")
    t = re.sub(r"(?i)^corso di laurea(?: triennale| magistrale(?: a ciclo unico)?)? in\s+", "", t)
    return t.replace(",", "").strip()


def leggi_piani(s: str, anno: int) -> list[dict]:
    """Piani del pannello dell'a.a.: [{nome, righe: [{anno, percorso, nome, alt, cfu, docenti, scheda}],
    liste: {titolo: [riga]}}]. Le righe delle tabelle «a scelta» (liste) non hanno anno."""
    seg = _pannello(s, anno)
    if not seg:
        return []
    piani: list[dict] = []
    for e in re.finditer(r'<strong class="nome_piano">(.*?)</strong>|<h4[^>]*>(.*?)</h4>'
                         r'|<div class="box clearfix">\s*<p>(.*?)</p>\s*<p class="col2 right">(.*?)</p>(.*?)'
                         r'(?=<div class="box clearfix">|<h4|<strong class="nome_piano"|$)', seg, re.S):
        if e.group(1) is not None:
            piani.append({"nome": _nome_piano(e.group(1)), "righe": [], "liste": {}, "_a": "ignora", "_p": None})
        elif e.group(2) is not None:
            if not piani:
                continue
            p, t = piani[-1], _testo(e.group(2))
            m = re.match(r"(\d)\s*°\s*anno(?:\s*-\s*Percorso in\s*(.*))?$", t, re.I) or \
                re.match(r"(1st|2nd|3rd|4th|5th|6th)\s+Year$", t, re.I)
            if m:
                a = m.group(1)
                p["_a"] = int(a) if a.isdigit() else _ORD_EN[a.lower()]
                p["_p"] = m.group(2).replace(",", "").strip() if m.lastindex and m.lastindex >= 2 and m.group(2) else None
            elif re.search(r"(?i)scelta|elective", t):
                p["_a"], p["_p"] = ("lista", t), None
                p["liste"].setdefault(t, [])
            else:
                p["_a"], p["_p"] = "ignora", None
        else:
            if not piani or piani[-1]["_a"] == "ignora":
                continue
            p, corpo = piani[-1], e.group(5)
            nome, alt = _nome_riga(e.group(3))
            sch = re.search(r'<a href="([^"]+)"[^>]*class="link_syllabus"', corpo)
            riga = {"nome": nome, "alt": alt, "cfu": _num(_testo(e.group(4))), "percorso": p["_p"],
                    "docenti": [_testo(d) for d in re.findall(r'/docenti/[^"]*"[^>]*>(.*?)</a>', corpo, re.S)],
                    "scheda": html.unescape(sch.group(1)) if sch else None}
            if isinstance(p["_a"], tuple):
                p["liste"][p["_a"][1]].append(riga)
            else:
                riga["anno"] = p["_a"]
                p["righe"].append(riga)
    for p in piani:
        p.pop("_a", None)
        p.pop("_p", None)
    return piani


def _slug40(nome: str) -> str:
    """Come `slug(nome, 40)` di build_db.py (lo slug dell'id di un insegnamento)."""
    import unicodedata
    n = unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", n).strip().replace(" ", "-")[:40].strip("-")


def _chiave(nome: str) -> str:
    return re.sub(r"\W+", " ", nome.lower()).strip()


def righe_piano(uid_corso: str, piano: dict, altri: dict, log=print) -> list[dict]:
    """Righe risolte di un piano: {anno, cs (insieme di curricula), nome, cfu, obbligatorio, docenti, scheda}.
    Le liste «a scelta» sostituiscono i segnaposto; CFU mancanti, righe a 0 CFU e righe doppie sono trattati qui.
    `altri`: {(anno o None per le liste, nome): CFU} delle righe degli altri piani della stessa pagina."""
    percorsi = sorted({r["percorso"] for r in piano["righe"] if r["percorso"]})
    cs_piano = set(percorsi) if percorsi else {piano["nome"]}
    righe: list[dict] = []
    segnaposti: dict[int, set] = {}
    ha_lista = any(piano["liste"].values())
    for r in piano["righe"]:
        cs = {r["percorso"]} if r["percorso"] else set(cs_piano)
        if ha_lista and _PLACEHOLDER.search(r["nome"]) and not _AFASS.search(r["nome"]):
            segnaposti.setdefault(r["anno"], set()).update(cs)
            continue
        a_scelta = r["alt"] or bool(_PLACEHOLDER.search(r["nome"]) or _AFASS.search(r["nome"]))
        righe.append(dict(r, cs=cs, obbligatorio=not a_scelta, lista=False))
    if ha_lista:
        if not segnaposti:
            # la pagina non dice in che anno vanno scelti: si mettono nell'ultimo anno del piano (deduzione)
            ultimo = max(r["anno"] for r in piano["righe"])
            segnaposti = {ultimo: set(cs_piano)}
            log(f"[lum]   {uid_corso} {piano['nome']}: tabella a scelta senza segnaposto, messa nell'anno {ultimo} (deduzione)")
        for lista in piano["liste"].values():
            for a, cs in sorted(segnaposti.items()):
                for r in lista:
                    if re.match(r"(?i)(tirocinio|prova finale)", r["nome"]):
                        continue  # righe in coda alla tabella, già presenti in ogni percorso del secondo anno
                    righe.append(dict(r, anno=a, cs=set(cs), obbligatorio=False, lista=True))
    res, viste = [], set()
    for r in righe:
        k = _chiave(r["nome"])
        corr = CORREZIONI.get((uid_corso, r["anno"], k))
        if corr:
            r["cfu"] = corr[0]
        if r["cfu"] is None and (uid_corso, k) in CFU_REGOLAMENTO:
            r["cfu"] = CFU_REGOLAMENTO[(uid_corso, k)][0]
        if r["cfu"] is None and (None if r["lista"] else r["anno"], k) in altri:
            r["cfu"] = altri[(None if r["lista"] else r["anno"], k)]
            log(f"[lum]   {uid_corso} anno {r['anno']}: «{r['nome']}» senza CFU, {r['cfu']} come nell'altro piano della pagina")
        if r["cfu"] is None or r["cfu"] <= 0:
            log(f"[lum]   {uid_corso} {piano['nome']} anno {r['anno']}: «{r['nome']}» senza CFU ({r['cfu']}), tolta")
            continue
        kk = (r["anno"], k, r["cfu"], tuple(sorted(r["cs"])), r["obbligatorio"])
        if kk in viste:
            log(f"[lum]   {uid_corso} {piano['nome']} anno {r['anno']}: «{r['nome']}» ({r['cfu']} CFU) doppia nella pagina, una sola")
            continue
        viste.add(kk)
        res.append(r)
    return res


def costruisci_corso(uid_corso: str, piani: list[dict], log=print) -> tuple[list[dict], list | None]:
    """Insegnamenti del corso (uniti tra i piani) e i suoi curricula."""
    tutte = []
    for n, p in enumerate(piani):
        altri: dict[tuple, int] = {}
        for q in piani[:n] + piani[n + 1:]:
            for lista in q["liste"].values():
                for r in lista:
                    if r["cfu"] is not None:
                        altri.setdefault((None, _chiave(r["nome"])), r["cfu"])
            for r in q["righe"]:
                if r["cfu"] is not None:
                    altri.setdefault((r["anno"], _chiave(r["nome"])), r["cfu"])
        tutte += righe_piano(uid_corso, p, altri, log)
    tutti_cs = set().union(*(r["cs"] for r in tutte)) if tutte else set()
    righe: dict[tuple, dict] = {}
    for r in tutte:
        k = (r["anno"], _chiave(r["nome"]), r["cfu"], r["obbligatorio"])
        i = righe.get(k)
        if not i:
            i = righe[k] = {"nome": r["nome"], "anno": r["anno"], "cfu": r["cfu"], "obbligatorio": r["obbligatorio"],
                            "docenti": [], "_s": [], "_c": set()}
        i["docenti"] = list(dict.fromkeys(i["docenti"] + r["docenti"]))
        if r["scheda"] and r["scheda"] not in i["_s"]:
            i["_s"].append(r["scheda"])
        i["_c"] |= r["cs"]
    curricula = sorted(tutti_cs) if len(tutti_cs) > 1 and any(i["_c"] != tutti_cs for i in righe.values()) else None
    for i in righe.values():
        cs = i.pop("_c")
        i["curriculum"] = ", ".join(sorted(cs)) if curricula and cs != tutti_cs else None
    ordine = sorted(righe.values(), key=lambda i: (i["anno"], i["nome"].lower()))
    # build_db dà l'id dal nome troncato a 40 caratteri e fonde le righe con lo stesso id, anno e tipo: righe diverse
    # (nome o CFU diversi tra i curricula) con lo stesso inizio di nome tengono un id proprio, fisso nel contributo
    viste_id: dict[tuple, int] = {}
    for i in ordine:
        k = (i["anno"], _slug40(i["nome"]), i["obbligatorio"])
        viste_id[k] = viste_id.get(k, 0) + 1
        if viste_id[k] > 1:
            i["id"] = f"{uid_corso}-{k[1]}-{viste_id[k]}"
            log(f"[lum]   {uid_corso} anno {i['anno']}: «{i['nome']}» ({i['cfu']:g} CFU) ha lo stesso inizio di un'altra riga, id {i['id']}")
    return ordine, curricula


def fetch_ateneo(uid: str = "lum", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]

    def pagina(x: dict) -> str | None:
        if x["id"] in PAGINE:
            return PAGINE[x["id"]]
        for u in (x.get("url_catalogo"), x.get("url")):
            if u and re.search(r"lum\.it/[^/]+", u):
                return u
        return None

    corsi = [x for x in corsi if pagina(x)]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for corso in corsi:
        r = c.get(pagina(corso))
        piani = leggi_piani(r.text, anno) if r else []
        if not piani or not any(p["righe"] for p in piani):
            log(f"[{uid}] {corso['id']}: nessun piano {anno}/{(anno + 1) % 100:02d} su {pagina(corso)}")
            continue
        ins, curricula = costruisci_corso(corso["id"], piani, log)
        for i in ins:
            i.update(codice=None, periodo=None, ssd=None, libri=[], esami=[], fonte=r.url, verificato_il=oggi,
                     stato_libri="da_aggiungere")
            i["url"] = i["_s"][0] if i["_s"] else r.url
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": r.url, "curricula": curricula,
                    "fonte": r.url, "verificato_il": oggi, "insegnamenti": ins})
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {len(items)} insegnamenti")

    def scheda(i: dict) -> int:
        libri, viste = [], set()
        for u in sorted(i.pop("_s")):
            try:
                with c.lock:
                    c.requests += 1
                rp = c.s.get(u, timeout=90)
                d = leggi_scheda(rp.content) if rp.content[:5] == b"%PDF-" else None
            except Exception:  # noqa: BLE001
                d = None
            if not d:
                continue
            i["periodo"] = i["periodo"] or d["periodo"]
            for lb in d["libri"]:
                if lb["citazione"] not in viste:
                    viste.add(lb["citazione"])
                    libri.append(lb)
        i["libri"] = libri
        i["stato_libri"] = "completo" if libri else "da_aggiungere"
        return len(libri)

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            trovati = sum(ex.map(scheda, items))
    else:
        for i in items:
            i.pop("_s", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.lum.it, piani di studio e schede (adapters/lum.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
