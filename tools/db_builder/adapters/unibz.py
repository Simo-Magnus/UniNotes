"""Insegnamenti, docenti e libri della Libera Università di Bolzano da www.unibz.it.

Per ogni corso di studio (pagine in inglese `/en/faculties/<facoltà>/<corso>/`):

- `…/study-plan` (o una pagina `…/study-plan-major-<percorso>` per ogni percorso, «major»): il piano di studio
  completo dell'ultimo a.a. pubblicato (pannello `data-academicyear`, di norma l'a.a. in corso), con anno di corso,
  CFU di ogni insegnamento e dei suoi moduli, i gruppi «uno/due/tre dei seguenti», i crediti liberi, il tirocinio e la
  prova finale. Prima si leggeva solo l'erogato di quest'anno: i corsi del 3° anno (non ancora erogati) mancavano, gli
  insegnamenti a scelta non avevano l'anno e i CFU dei corsi senza pagina del piano erano zero;
- `…/course-offering?academicYear=<a.a.>` («Course Offering - enrolled from …» e «… before …», nei corsi magistrali
  interateneo `…/courses-offered`) → insegnamenti erogati nell'a.a.: semestre, codice, SSD, lingua, docenti e link alla
  scheda `…/study-course-offering/<a.a.>/<id>`; si abbinano alle righe del piano per nome (e per CFU);
- scheda → «Required readings» (obbligatori) e «Supplementary readings» (consigliati) di ogni modulo (nelle schede in
  italiano «Bibliografia obbligatoria/facoltativa»).

Regole del piano:

- i CFU di un insegnamento con moduli sono quelli del contenitore (non la somma di contenitore e moduli, né i soli
  moduli); un modulo «M2: …» finito fuori dal blocco del suo contenitore si riunisce a questo (Informatica, «Databases»);
- i gruppi «one of the following», «two of the following», «1 Mandatory Course to be chosen among the following»… sono
  alternative (`obbligatorio: false`, ciascuna con i propri CFU) se le alternative sono più di quelle da scegliere,
  altrimenti obbligatorie; gli insegnamenti di un blocco con un solo contenitore e moduli non sono alternative;
- «Free Choice», «Optional courses» e simili sono crediti liberi (`obbligatorio: false`, senza codice); più righe
  uguali nello stesso anno e percorso (tre «Free choice course» da 5 CFU) sono una riga con i CFU sommati;
- le pagine per percorso (`study-plan-major-…`) danno i `curricula` del corso; una riga uguale (anno, nome, CFU,
  obbligatorietà) in tutte le pagine vale per tutti i percorsi, altrimenti ha i percorsi in cui compare. Le intestazioni
  «Path “…”» (Scienze degli alimenti, secondo anno) sono percorsi della stessa pagina;
- un titolo di sezione senza anno dopo gli anni (Informatica: «Applied Computer Science Areas», le aree sono i corsi
  tra cui si scelgono i 12 + 12 CFU di «Applied Computer Science 1/2»; Informatica per la data science: «Curriculum-
  specific courses») elenca alternative: l'anno è quello del primo segnaposto che le richiama. Le sezioni di un piano
  senza anni (Design e Arti, Eco-social Design) non hanno anno: il sito non lo pubblica;
- Formazione primaria (LM-85 bis, sezione italiana) ha pagine con «CFU» e «° anno» invece di «CP» e «year»;
- l'intestazione «1st Year - 2nd Semester (at the University of Trento)» dà anno e semestre del corso (il semestre
  2 è il 2° semestre dell'anno), gli atenei partner non cambiano la sede del corso.

Dati dall'erogato (stesso nome e stessi CFU del piano; più voci con lo stesso nome = gruppi paralleli o un codice per
percorso: il primo codice, gli altri in `codici_alternativi`): codice, docenti, semestre (`Semester 1-2` = annuale), pagina
della scheda e libri. Gli insegnamenti erogati delle coorti attuali («enrolled from <anno più recente>») che non sono nel
piano sono corsi della Facoltà per i crediti liberi: righe a scelta (una per nome e CFU) nell'anno dei primi crediti liberi
del piano; quelli delle coorti precedenti («before …», regolamenti vecchi) non si tengono. Il campus («Campus: …») è la
`sede`. I libri già raccolti (`database/contrib/auto/unibz.json` e `database/corsi/unibz.json`) restano accanto a quelli
riletti dalle schede.

Limiti della fonte: Design e Arti (L-4) ed Eco-social Design (LM-12) pubblicano il piano senza ripartizione per anno (anno
vuoto); il 3° anno dei piani nuovi non è ancora erogato (niente codice, docenti né libri); in Scienze degli alimenti la tesi
vale 33 CFU (valore del piano).
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import html
import json
import pathlib
import re
import time
import unicodedata
import urllib.parse

from .testi import estrai_libri, html_to_lines
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unibz.it"
UNITA = r"(?:CP|CFU|KP|ECTS)"
SEDI = {"bozen-bolzano": "Bolzano", "bolzano": "Bolzano", "bozen": "Bolzano", "brixen-bressanone": "Bressanone",
        "bressanone": "Bressanone", "brixen": "Bressanone", "bruneck-brunico": "Brunico", "brunico": "Brunico",
        "bruneck": "Brunico"}
LIBERI = re.compile(r"(?i)^(free\s*choice|optional|student'?s?\s*choice|insegnament\w*\s+(?:a\s+scelta|opzional)|opzional|"
                    r"wahlf|curriculum-specific optional)")
GRUPPO = re.compile(r"(?i)of the following|chosen among|to be chosen|dei seguenti|tra i seguenti|folgendem")
NUMERI = {"one": 1, "two": 2, "three": 3, "four": 4, "1": 1, "2": 2, "3": 3, "4": 4, "uno": 1, "un": 1, "due": 2,
          "tre": 3, "ein": 1, "zwei": 2, "drei": 3}
SEGNAPOSTO = re.compile(r"(?i)^applied computer science\s+(\d)$|^curriculum-specific optional course")


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _pulisci(nome: str) -> str:
    """Nome senza le note a piè di pagina (`**`, `(*)`, `*/****`) e con gli spazi in ordine."""
    n = re.sub(r"\s+", " ", html.unescape(nome or "")).strip()
    n = re.sub(r"(?:\s*\(\**\))+(?=\s|$|:)", "", n)
    n = re.sub(r"(?<=\S)\**(?:/\**)*(?=\s*(?:\(|:|$))", "", n)
    n = re.sub(r"\s*\*+\s*$", "", n).strip(" :")
    return n


def _cfu(s: str | None) -> float | None:
    m = re.match(rf"\s*([\d]+(?:[.,]\d+)?)\s*{UNITA}", _testo(s or ""), re.I)
    return float(m.group(1).replace(",", ".")) if m else None


def _intero(v: float | None):
    return int(v) if v is not None and float(v).is_integer() else v


# ---------------------------------------------------------------------------------------------------------------
# erogato


def leggi_offerta(s: str) -> list[dict]:
    m = re.search(r"<main", s)
    s = s[m.start():] if m else s
    out = []
    blocchi = re.split(r'<div class="g g-6@md[^"]*">', s)[1:]
    for b in blocchi:
        a = re.search(r'<h2[^>]*>\s*(?:<a href="([^"#]+)"[^>]*>)?(.*?)(?:</a>\s*)?</h2>', b, re.S)
        if not a:
            continue
        sem = re.search(r"Semest\w*\s*(\d)(?:\s*[-–]\s*(\d))?|(Annual|Yearly|Annuale|Jährlich)", _testo(b[:a.start()]), re.I)
        info = re.search(r'<p class="u-tt-caps u-fw-bold[^"]*"[^>]*>(.*?)</p>', b, re.S)
        campi = [x.strip() for x in _testo(info.group(1)).split("·")] if info else []
        v = _cfu(campi[0]) if campi else None
        # docenti dell'insegnamento (non dei moduli, elencati sotto i loro titoli h3)
        testa = re.split(r'<div class="u-padd-lft', b)[0]
        docenti = [_testo(d) for d in re.findall(r'/person/[^"]*"[^>]*>\s*<span>(.*?)</span>', testa, re.S)]
        moduli = re.findall(r'/person/[^"]*"[^>]*>\s*<span>(.*?)</span>', b[len(testa):], re.S)
        periodo = None
        if sem:
            if sem.group(3) or sem.group(2):
                periodo = "annuale"
            else:
                periodo = sem.group(1)
        out.append({
            "url": html.unescape(a.group(1)) if a.group(1) else None, "nome": _pulisci(_testo(a.group(2))),
            "periodo": periodo, "cfu": _intero(v),
            "codice": campi[1] if len(campi) > 1 else None,
            "ssd": campi[2] if len(campi) > 2 and campi[2] != "NN" else None,
            "lingua": campi[3].lower() if len(campi) > 3 else None,
            "docenti": list(dict.fromkeys(docenti + [_testo(d) for d in moduli])),
        })
    return out


# ---------------------------------------------------------------------------------------------------------------
# piano di studio


def _titolo_pagina(s: str) -> str:
    k = re.search(r"<main", s)
    m = re.search(r"<h1[^>]*>(.*?)</h1>", s[k.start():] if k else s, re.S)
    return _testo(m.group(1)) if m else ""


def _anno_da_titolo(t: str) -> tuple[int | None, int | None, str | None]:
    """(anno di corso, semestre del corso, percorso) da un'intestazione di sezione."""
    anno = sem = None
    m = re.search(r"(?i)\b(\d)\s*(?:st|nd|rd|th|°|º|\.)?\s*(?:year|anno|jahr)\b", t) or \
        re.search(r"(?i)\b(?:year|anno|jahr)\s*(\d)\b", t)
    if m:
        anno = int(m.group(1))
    m = re.search(r"(?i)\b(\d)\s*(?:st|nd|rd|th|°|º)?\s*(?:semester|semestre)\b", t)
    if m:
        sem = int(m.group(1))
    p = re.search(r"(?i)\b(?:path|percorso|pfad)\s*[“\"']([^”\"']+)[”\"']", t)
    return anno, sem, (p.group(1).strip() if p else None)


def leggi_piano(s: str) -> dict:
    """Piano di una pagina: {aa, titolo, sezioni: [(titolo, [blocchi])]}, dal pannello con l'a.a. più recente.
    Un blocco è {nome, cfu (contenitore o None), moduli: [(nome, cfu)]}."""
    pannelli = []
    for pn in re.split(r'<div\s+id="Organism-', s)[1:]:
        ay = re.search(r'data-academicyear="([^"]*)"', pn)
        aa = re.match(r"\s*(\d{4})", ay.group(1)) if ay else None
        secs = []
        for sec in re.split(r'<section class="l-sectionSmall">', pn)[1:]:
            h = re.search(r"<h3[^>]*>(.*?)</h3>", sec, re.S)
            blocchi = []
            for b in re.split(r'<div class="g g-6@md g-4@lg g-6@print[^"]*">', sec)[1:]:
                nm = re.search(r"<h4[^>]*>(.*?)</h4>", b, re.S)
                if not nm:
                    continue
                nome = _pulisci(_testo(nm.group(1)))
                if not nome:
                    continue
                top = re.search(r'<p class="u-tt-caps[^"]*"[^>]*>(.*?)</p>', b, re.S)
                mods = []
                for mm in re.finditer(r'<p class="u-cf[^"]*">(.*?)</p>', b, re.S):
                    x = re.search(r"<span[^>]*>(.*?)</span>\s*<b[^>]*>(.*?)</b>", mm.group(1), re.S)
                    if x:
                        mods.append((_pulisci(_testo(x.group(2))), _cfu(x.group(1))))
                blocchi.append({"nome": nome, "cfu": _cfu(top.group(1)) if top else None,
                                "moduli": [m for m in mods if m[0]]})
            secs.append((_testo(h.group(1)) if h else None, blocchi))
        pannelli.append((int(aa.group(1)) if aa else 0, ay.group(1) if ay else None, secs))
    if not pannelli:
        return {}
    _, aa, secs = max(pannelli, key=lambda p: p[0])
    # un modulo «M2: …» fuori dal blocco del contenitore si riunisce al blocco precedente
    for _, blocchi in secs:
        riuniti: list[dict] = []
        for b in blocchi:
            mm = re.match(r"^M-?\s*(\d)\s*[:\-–.]", b["nome"])
            if mm and int(mm.group(1)) >= 2 and riuniti and riuniti[-1]["moduli"] and not b["moduli"]:
                riuniti[-1]["moduli"].append((b["nome"], b["cfu"]))
                continue
            riuniti.append(b)
        blocchi[:] = riuniti
    return {"aa": aa, "titolo": _titolo_pagina(s), "sezioni": secs}


def _quanti(nome: str) -> int:
    m = re.search(r"(?i)\b(?:up to\s+)?(one|two|three|four|[1-4]|uno|un|due|tre|ein|zwei|drei)\s+"
                  r"(?:mandatory\s+courses?|of the following|dei seguenti|insegnament\w+|wahlpflicht\w+|subjects?\s+of)", nome)
    if m:
        return NUMERI[m.group(1).lower()]
    m = re.search(r"(?i)\((?:up to\s+)?(one|two|three|four|uno|due|tre)\b", nome)
    return NUMERI[m.group(1).lower()] if m else 1


def righe_da_piano(piano: dict) -> list[dict]:
    """Righe del piano: {anno, semestre, percorso, nome, cfu, obbligatorio, gruppo (id o None), segnaposto}."""
    righe: list[dict] = []
    anno = sem = percorso = None
    visti_anni = False
    n_gruppo = 0
    for titolo, blocchi in piano["sezioni"]:
        a, sm, pc = _anno_da_titolo(titolo or "")
        senza_anno = False
        if titolo:  # intestazione nuova; quelle vuote continuano la precedente
            if a:
                anno, sem, percorso, visti_anni = a, sm, pc, True
            else:
                anno, sem, percorso = None, None, None
                senza_anno = True
        # «… (A)» e «… (B)»: varianti dello stesso insegnamento, se ne sceglie una («Thesis Project Phase 1 … (A)*»)
        varianti: dict[str, list[dict]] = {}
        for b in blocchi:
            mv = re.match(r"^(.*?)\s*\(([A-D])\)$", b["nome"])
            if mv:
                varianti.setdefault(mv.group(1), []).append(b)
        in_variante = {id(b) for lista in varianti.values() if len(lista) > 1 for b in lista}
        for b in blocchi:
            nome, cfu_c, mods = b["nome"], b["cfu"], b["moduli"]
            somma = sum(c or 0 for _, c in mods)
            if id(b) in in_variante:
                mv = re.match(r"^(.*?)\s*\(([A-D])\)$", nome)
                n_gruppo += 1
                righe.append({"anno": anno, "semestre": sem, "percorso": percorso, "sezione": titolo if senza_anno else None,
                              "dopo_anni": senza_anno and visti_anni, "nome": nome,
                              "cfu": cfu_c if cfu_c is not None else (somma or None), "obbligatorio": False,
                              "gruppo": ("var", mv.group(1)), "richiesti": 1, "gruppo_cfu": None, "segnaposto": False})
                continue
            base = {"anno": anno, "semestre": sem, "percorso": percorso, "sezione": titolo if senza_anno else None,
                    "dopo_anni": senza_anno and visti_anni}
            if GRUPPO.search(nome) and mods:
                n = _quanti(nome)
                # alternative senza CFU propri (Informatica e Management, «one of the following» da 6): i CFU del gruppo
                alt = [(m, c if c is not None else (cfu_c if n == 1 else None)) for m, c in mods]
                n_gruppo += 1
                scelte = len(alt) > n
                etichetta = re.sub(r"(?i)\s*\(.*$|\s*:\s*$", "", nome).strip()
                for m, c in alt:
                    if re.match(r"^[A-Z]\s*[:.)]\s", m):  # «A: Didattica delle STEM» in più gruppi: il gruppo nel nome
                        m = f"{etichetta} - {m}"
                    righe.append(dict(base, nome=m, cfu=c, obbligatorio=not scelte, gruppo=n_gruppo, richiesti=n,
                                      gruppo_cfu=cfu_c, segnaposto=False))
                continue
            cfu = cfu_c if cfu_c is not None else (somma if mods and all(c is not None for _, c in mods) else None)
            libero = bool(LIBERI.match(nome))
            righe.append(dict(base, nome=nome, cfu=cfu, obbligatorio=not libero, gruppo=None, richiesti=None,
                              gruppo_cfu=None, segnaposto=libero or bool(SEGNAPOSTO.match(nome)), moduli=mods))
    return righe


# ---------------------------------------------------------------------------------------------------------------
# libri


_TITOLI_LIBRI = (("Required readings", "obbligatorio"), ("Bibliografia obbligatoria", "obbligatorio"),
                 ("Pflichtliteratur", "obbligatorio"), ("Pflichtlektüre", "obbligatorio"),
                 ("Supplementary readings", "consigliato"), ("Bibliografia facoltativa", "consigliato"),
                 ("Ergänzende Literatur", "consigliato"), ("Weiterführende Literatur", "consigliato"))
_FINE_LIBRI = r"Readings and further|Further information|Ulteriori informazioni|Weitere Informationen|Download as pdf|Scarica|</main>"


def leggi_scheda(s: str) -> list[dict]:
    """Libri della scheda: tutte le sezioni «Required/Supplementary readings» (una per modulo) o «Bibliografia obbligatoria/
    facoltativa» (schede in italiano)."""
    libri = []
    titoli = "|".join(re.escape(t) for t, _ in _TITOLI_LIBRI)
    tipi = dict(_TITOLI_LIBRI)
    for m in re.finditer(rf"({titoli})\s*</[^>]+>(.*?)(?={titoli}|{_FINE_LIBRI})", s, re.S):
        for lb in estrai_libri(m.group(2)):
            lb["tipo"] = lb.get("tipo") or tipi[m.group(1)]
            libri.append(lb)
    # lo stesso libro in più moduli: una volta
    visti, out = set(), []
    for lb in libri:
        k = re.sub(r"\W+", "", (lb.get("citazione") or lb.get("titolo") or "").lower())[:120]
        if k not in visti:
            visti.add(k)
            out.append(lb)
    return out


def _pagina_en(c: Client, url: str) -> str | None:
    u = re.sub(r"^http://", "https://", url.strip())
    u = re.sub(r"unibz\.it/(?:it|de)/", "unibz.it/en/", u).rstrip("/")
    r = c.get(u)
    return r.url.rstrip("/") if r else None


def _link_piani(c: Client, pagina: str) -> list[tuple[str, str, str]]:
    """[(ultimo segmento dell'url, url, testo del link)] dei piani di studio: le pagine in inglese e, se non ne hanno, quelle italiane o
    tedesche. Le pagine «not offered» e le sezioni linguistiche di Formazione primaria diverse da quella italiana non si
    leggono."""
    for lingua in ("en", "it", "de"):
        u = re.sub(r"unibz\.it/en/", f"unibz.it/{lingua}/", pagina)
        r = c.get(u)
        if not r:
            continue
        path = urllib.parse.urlparse(r.url).path.rstrip("/")
        trovati: dict[str, tuple[str, str]] = {}
        for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            hp = urllib.parse.urlparse(html.unescape(h)).path.rstrip("/")
            testo = _testo(t)
            if not hp.startswith(path + "/") or "offer" in hp or "offerti" in hp:
                continue
            ultimo = hp.split("/")[-1]
            if not (ultimo.startswith("study-plan") or re.match(r"(?i)^(study plan|piano degli studi|studienplan)\b", testo)):
                continue
            if re.search(r"(?i)not offered|non offert|nicht angeboten", testo):
                continue
            trovati.setdefault(ultimo, (urllib.parse.urljoin(BASE, hp), testo))
        if "study-plan-italian-section" in trovati:  # Formazione primaria: sezione italiana (le altre sono in tedesco e ladino)
            trovati = {"study-plan-italian-section": trovati["study-plan-italian-section"]}
        if trovati:
            return [(ultimo, url, testo) for ultimo, (url, testo) in trovati.items()]
    return []


def _link_offerte(c: Client, pagina: str, italiana: bool) -> list[tuple[bool, str]]:
    """[(per coorti precedenti, url)] degli erogati: prima quelli delle coorti attuali («enrolled from …»)."""
    lingue = ("it", "en") if italiana else ("en",)
    trovati: list[tuple[bool, str, int]] = []
    for lingua in lingue:
        u = re.sub(r"unibz\.it/en/", f"unibz.it/{lingua}/", pagina)
        r = c.get(u)
        if not r:
            continue
        path = urllib.parse.urlparse(r.url).path.rstrip("/")
        for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            hp = urllib.parse.urlparse(html.unescape(h)).path.rstrip("/")
            testo = _testo(t).lower()
            if not hp.startswith(path + "/") or not re.search(r"course offering|insegnamenti offerti|courses offered", testo):
                continue
            if italiana and not re.search(r"ital", testo + hp):
                continue
            ultimo = hp.split("/")[-1]
            da = re.search(r"(?:from|dal|ab)\s+(\d{4})", testo)
            vecchia = bool(re.search(r"before|prima del|vor ", testo) or re.fullmatch(r"course-offering-(?:old|ppa)", ultimo))
            url = urllib.parse.urljoin(BASE, hp)
            if url not in [x for _, x, _ in trovati]:
                trovati.append((vecchia, url, int(da.group(1)) if da else 0))
        if trovati:
            break
    # tra le coorti «from <anno>» è attuale solo quella con l'anno più alto (le altre hanno il regolamento precedente)
    ultimo_anno = max((a for v, _, a in trovati if not v), default=0)
    return [(v or (a != 0 and a < ultimo_anno), u) for v, u, a in sorted(trovati, key=lambda x: (x[0], -x[2]))]


def _sede(c: Client, pagina: str) -> str | None:
    """Campus della riga «Campus: …» della pagina del corso (anche «NOI Techpark Bozen-Bolzano»)."""
    for lingua in ("en", "it", "de"):
        r = c.get(re.sub(r"unibz\.it/en/", f"unibz.it/{lingua}/", pagina))
        righe = html_to_lines(r.text) if r else []
        m = next((x for x in (re.match(r"(?:Campus|Sede)\s*:\s*(.+)", l) for l in righe) if x), None)
        if m:
            t = _norm(m.group(1))
            for k, v in (("brixen", "Bressanone"), ("bressanone", "Bressanone"), ("bruneck", "Brunico"),
                         ("brunico", "Brunico"), ("bozen", "Bolzano"), ("bolzano", "Bolzano")):
                if k in t:
                    return v
    return None


_ROMANI = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6"}


def _chiave(nome: str) -> str:
    """Nome per l'abbinamento piano ↔ erogato: senza le note «(curr. LP)», «(FIN III)», i gruppi paralleli «1.a», con i
    numeri romani in cifre («Physics I» = «Physics 1»)."""
    n = re.sub(r"(?i)\((?:curr\.[^)]*|fin\s+[iv]+)\)", " ", nome or "")
    n = re.sub(r"(?<=\d)\s*\.\s*[a-z]", " ", n)
    return " ".join(_ROMANI.get(t, t) for t in _norm(n.replace("&", " and ")).split())


def _chiavi(nome: str) -> set[str]:
    """La chiave del nome e quella senza l'ultima parentesi («… (at University of Innsbruck)», «… (one mandatory course …)»)."""
    k = {_chiave(nome)}
    for rx in (r"\s*\([^()]*\)\s*$", r"\s+[–-]\s+[^–-]+$"):
        senza = re.sub(rx, "", nome or "")
        if senza and senza != nome and (len(_chiave(senza).split()) >= 2 or any(ch.isdigit() for ch in senza)):
            k.add(_chiave(senza))
    return k


def _abbina(riga: dict, erogato: list[dict], usati: set) -> list[dict]:
    """Voci dell'erogato per la riga del piano: stesso nome (chiave `_chiave`) e, se entrambi li hanno, stessi CFU (più voci =
    gruppi paralleli o un codice per percorso); altrimenti il nome più vicino (≥ 0,92, senza numeri diversi) con gli stessi
    CFU, tra le voci non già abbinate esattamente."""
    kr = _chiavi(riga["nome"])
    n = _chiave(riga["nome"])
    stessi = [e for e in erogato if kr & _chiavi(e["nome"]) and (riga["cfu"] is None or e["cfu"] is None or riga["cfu"] == e["cfu"])]
    if stessi:
        return stessi
    best = None
    for e in erogato:
        if riga["cfu"] is None or e["cfu"] != riga["cfu"] or id(e) in usati:
            continue
        ne = _chiave(e["nome"])
        if any(t.isdigit() for t in set(n.split()) ^ set(ne.split())):  # «Analysis 1» e «Analysis 2» sono due insegnamenti
            continue
        r = difflib.SequenceMatcher(None, n, ne).ratio()
        if r >= 0.92 and (best is None or r > best[0]):
            best = (r, e)
    return [best[1]] if best else []


def fetch_ateneo(uid: str = "unibz", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")

    # libri già raccolti: per codice (o per corso e nome, per le righe senza codice)
    riuso_cod: dict[tuple, dict] = {}
    for p in (ROOT / "database" / "contrib" / "auto" / f"{uid}.json", ROOT / "database" / "corsi" / f"{uid}.json"):
        if not p.exists():
            continue
        for co in json.loads(p.read_text(encoding="utf-8")).get("corsi", []):
            for i in co.get("insegnamenti") or []:
                chiave = (co["id"], i["codice"]) if i.get("codice") else (co["id"], _norm(i.get("nome") or ""))
                r = riuso_cod.setdefault(chiave, {"libri": [], "letto": False})
                if "study-course-offering" in (i.get("url") or ""):
                    r["letto"] = True
                viste = {re.sub(r"\W+", "", lb["citazione"].lower())[:120] for lb in r["libri"] if lb.get("citazione")}
                for lb in i.get("libri") or []:
                    k = re.sub(r"\W+", "", (lb.get("citazione") or "").lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        r["libri"].append(lb)

    def build(corso: dict) -> dict | None:
        pagina = _pagina_en(c, corso.get("url") or "")
        if not pagina:
            return None
        piani = _link_piani(c, pagina)
        if not piani:
            return None
        italiana = any("italian-section" in u for _, u, _ in piani)
        sede = _sede(c, pagina)
        # --- erogato dell'a.a.
        erogato: list[dict] = []
        fonte_off = None
        for vecchia, o in _link_offerte(c, pagina, italiana):
            u = o + f"?academicYear={anno}"
            ro = c.get(u)
            nuove = leggi_offerta(ro.text) if ro else []
            if nuove:
                fonte_off = fonte_off or u
                erogato += [dict(v, fonte=u, vecchia=vecchia) for v in nuove]
        # --- piani
        pagine = []
        for slug, url, testo in piani:
            r = c.get(url)
            pi = leggi_piano(r.text) if r else {}
            if not pi or not any(b for _, bl in pi["sezioni"] for b in bl):
                continue
            nome_pc = None
            if len(piani) > 1:
                nome_pc = re.sub(r"(?i)^\s*(?:study\s*plan|piano degli studi)\s*[-–:]?\s*(?:major\s+)?", "", testo).strip() or slug
                nome_pc = re.sub(r"\s*,\s*", " - ", nome_pc)  # (le virgole separano i percorsi: «Governance, Law and Management»)
            pagine.append((nome_pc, url, pi))
        if not pagine:
            return None
        durata = corso.get("durata_anni") or 3
        # righe di ogni pagina, poi unite per percorso
        per_riga: dict[tuple, dict] = {}
        ordine: list[tuple] = []
        percorsi_nomi: list[str] = []
        for nome_pc, url, pi in pagine:
            righe = righe_da_piano(pi)
            # sezioni senza anno dopo gli anni (aree, corsi di curriculum): l'anno del primo segnaposto che le richiama
            primo_segn = next((r["anno"] for r in righe if r["anno"] and SEGNAPOSTO.match(r["nome"])), None)
            tenute: list[dict] = []
            liberi: dict[tuple, dict] = {}  # crediti liberi dello stesso anno e percorso: una riga con i CFU sommati
            for r in righe:
                if r["anno"] is None and r["dopo_anni"] and primo_segn:
                    r["anno"] = primo_segn
                    r["obbligatorio"] = False
                    r["percorso"] = r["sezione"] if r["sezione"] and not re.search(r"(?i)areas?$|courses?$", r["sezione"]) else None
                if r["anno"] and r["anno"] > durata:
                    continue
                if r["segnaposto"] and LIBERI.match(r["nome"]):
                    k = (r["anno"], _norm(re.sub(r"(?i)\s*\(.*?\)\s*$", "", r["nome"])), r["percorso"])
                    if k in liberi:
                        liberi[k]["cfu"] = (liberi[k]["cfu"] or 0) + (r["cfu"] or 0)
                        continue
                    liberi[k] = r
                tenute.append(r)
            for r in tenute:
                chiave = (r["anno"], _norm(r["nome"]), r["cfu"], r["obbligatorio"], r["percorso"])
                if chiave not in per_riga:
                    per_riga[chiave] = dict(r, pagine=[], url=url)
                    ordine.append(chiave)
                per_riga[chiave]["pagine"].append(nome_pc)
            if nome_pc:
                percorsi_nomi.append(nome_pc)
            percorsi_nomi += [r["percorso"] for r in tenute if r["percorso"]]
        tutte = [n for n, _, _ in pagine]
        righe_u = []
        for k in ordine:
            r = per_riga[k]
            pc = [p for p in r["pagine"] if p]
            curr = []
            if r["percorso"]:
                curr.append(r["percorso"])
            if pc and len(set(pc)) < len(set(tutte)):
                curr = list(dict.fromkeys(pc)) if not curr else curr + list(dict.fromkeys(pc))
            r["curriculum"] = ", ".join(dict.fromkeys(curr)) if curr else None
            righe_u.append(r)
        # omonimi dello stesso anno con CFU diversi (percorsi diversi): i CFU nel nome
        gruppi: dict[tuple, list[dict]] = {}
        for r in righe_u:
            gruppi.setdefault((r["anno"], _norm(r["nome"]), r["obbligatorio"]), []).append(r)
        for lista in gruppi.values():
            if len({r["cfu"] for r in lista}) > 1:
                for r in lista:
                    if r["cfu"] is not None:
                        r["nome"] = f"{r['nome']} ({_intero(r['cfu'])} CFU)"
        ins = []
        esatti = set().union(*(_chiavi(r["nome"]) for r in righe_u)) if righe_u else set()
        usati = {id(e) for e in erogato if _chiavi(e["nome"]) & esatti}
        def riga_da(r: dict, es: list[dict]) -> dict:
            e = es[0] if es else None
            cod = e["codice"] if e else None
            sem = r.get("semestre")
            periodo = e["periodo"] if e else (("1" if sem % 2 else "2") if sem else None)
            libri, letto = [], False
            for x in es or [None]:
                ru = riuso_cod.get((corso["id"], x["codice"]) if x and x["codice"] else (corso["id"], _norm(r["nome"]))) or {}
                letto = letto or bool(ru.get("letto"))
                viste = {re.sub(r"\W+", "", (lb.get("citazione") or "").lower())[:120] for lb in libri}
                for lb in ru.get("libri") or []:
                    k = re.sub(r"\W+", "", (lb.get("citazione") or "").lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        libri.append(dict(lb))
            riga = {
                "codice": cod, "nome": r["nome"], "anno": r["anno"], "periodo": periodo, "cfu": _intero(r["cfu"]),
                "ssd": e["ssd"] if e else None, "obbligatorio": bool(r["obbligatorio"]),
                "curriculum": r.get("curriculum"),
                "docenti": list(dict.fromkeys(d for x in es for d in x["docenti"])),
                "url": urllib.parse.urljoin(BASE, e["url"]) if e and e["url"] else r["url"],
                "libri": libri, "esami": [], "fonte": r["url"], "verificato_il": oggi, "_letto": letto,
            }
            alt = [x["codice"] for x in es[1:] if x["codice"] and x["codice"] != cod]
            if alt:
                riga["codici_alternativi"] = list(dict.fromkeys(alt))
            return riga

        for r in righe_u:
            ins.append(riga_da(r, [] if r["segnaposto"] else _abbina(r, erogato, usati)))
        # insegnamenti erogati nelle coorti attuali che non sono nel piano: scelte (corsi della Facoltà per i crediti liberi,
        # stessa scelta con un codice per gruppo = una riga), nell'anno dei primi crediti liberi del piano
        codici = {x for i in ins for x in [i["codice"], *i.get("codici_alternativi", [])] if x}
        anno_scelte = min((r["anno"] for r in righe_u if r["anno"] and LIBERI.match(r["nome"])), default=None)
        nomi_piano = set().union(*(_chiavi(r["nome"]) for r in righe_u)) if righe_u else set()
        extra: dict[tuple, list[dict]] = {}
        for e in erogato:
            if e["vecchia"] or not e["cfu"] or e["codice"] in codici or _chiavi(e["nome"]) & nomi_piano:
                continue
            extra.setdefault((_chiave(e["nome"]), e["cfu"]), []).append(e)
        for es in extra.values():
            ins.append(riga_da({"nome": es[0]["nome"], "anno": anno_scelte, "cfu": es[0]["cfu"], "obbligatorio": False,
                                "url": es[0]["fonte"]}, es))
        urls = [u for _, u, _ in pagine]
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": pagina, "curricula": list(dict.fromkeys(percorsi_nomi)) or None, "sede": sede,
                "fonte": urls[0], "verificato_il": oggi, "insegnamenti": ins}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {len(items)} insegnamenti, "
        f"con anno {sum(1 for i in items if i['anno'])}, con codice {sum(1 for i in items if i['codice'])}")

    def scheda(i: dict) -> int:
        i.pop("_letto", None)
        if "study-course-offering" in (i["url"] or ""):
            try:
                r = c.get(i["url"])
                nuovi = leggi_scheda(r.text) if r else []
            except Exception:  # noqa: BLE001
                nuovi = []
            viste = {re.sub(r"\W+", "", (lb.get("citazione") or lb.get("titolo") or "").lower())[:120] for lb in nuovi}
            # i libri già raccolti restano (stesso libro = una volta)
            i["libri"] = nuovi + [lb for lb in i["libri"]
                                  if re.sub(r"\W+", "", (lb.get("citazione") or lb.get("titolo") or "").lower())[:120] not in viste]
        i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
        return len(i["libri"])

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            trovati = sum(ex.map(scheda, items))
    else:
        for i in items:
            i.pop("_letto", None)
    log(f"[{uid}] libri: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unibz.it, Study Plan e Course Offering "
                                                 "(adapters/unibz.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
