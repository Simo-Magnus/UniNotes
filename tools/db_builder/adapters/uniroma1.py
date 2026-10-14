"""Insegnamenti, docenti e libri della Sapienza da corsidilaurea.uniroma1.it.

Esse3 della Sapienza non pubblica l'offerta, ma il catalogo dei corsi sì:

- `/it/course/<id>/attendance/lessons-plan` → didattica erogata nell'a.a. corrente per tutti
  gli anni e i curricula: codice Esse3 dell'attività (lo stesso degli appelli), nome, SSD,
  lingua, anno, semestre, CFU; gli insegnamenti con moduli hanno righe figlie; i gruppi a
  scelta compaiono come righe senza codice e i loro insegnamenti hanno il gruppo nel link;
- pagina dell'insegnamento (`…/attendance/lesson/…`) → canali (`?channel=N`);
- pagina del canale → "Docenti" e "Testi di riferimento".

I corsi sono quelli di database/corsi/uniroma1.json (da Universitaly), con `url`
`…/timeview/<anno>/<id>`.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

from .testi import YEAR, _EDITORI_CIT, _libero, _tipo, estrai_libri, html_to_lines
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://corsidilaurea.uniroma1.it"
ORD = {"1º": 1, "2º": 2, "3º": 3, "4º": 4, "5º": 5, "6º": 6}


def _id(url: str | None) -> str | None:
    m = re.search(r"corsidilaurea\.uniroma1\.it/\w+/(?:timeview/\d{4}|course)/(\d+)", url or "")
    return m.group(1) if m else None


def _num(t: str) -> int | None:
    m = re.match(r"(\d)", _testo(t))
    return int(m.group(1)) if m else None


def leggi_piano(s: str) -> list[dict]:
    """Insegnamenti della pagina lessons-plan (un elemento per attività con codice)."""
    out: list[dict] = []
    # titolo del curriculum: link se ce ne sono più di uno, <span> se è unico
    curricula = re.split(r'<legend class="panel-heading">\s*<(?:a|span)[^>]*>(.*?)</(?:a|span)>\s*</legend>', s,
                         flags=re.S)
    for curr, corpo in zip(curricula[1::2], curricula[2::2]):
        curr = _testo(curr)
        padri: dict[str, dict] = {}
        for attr, tr in re.findall(r"<tr([^>]*)>(.*?)</tr>", corpo, re.S):
            td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(td) < 4:
                continue
            cod = re.search(r'class="activity-code">(.*?)</span>', td[0])
            nome = re.search(r'class="activity-name">(.*?)</span>', td[0], re.S)
            link = re.search(r'href="(/\w+/course/\d+/attendance/lesson/[^"]+)"', td[0])
            tag = re.findall(r"\[([^\]]*)\]", _testo(re.search(r"<strong[^>]*>(.*?)</strong>", td[0], re.S).group(1))
                             if "<strong" in td[0] else "")
            cfu_t = _testo(td[3]).replace(",", ".")
            riga = {
                "codice": _testo(cod.group(1)) if cod else None, "nome": _titolo(_testo(nome.group(1))) if nome else "",
                "ssd": tag[0] if tag and tag[0] != "N/D" else None, "lingua": tag[1] if len(tag) > 1 else None,
                "anno": _num(td[1]), "periodo": str(_num(td[2])) if _num(td[2]) else None,
                "cfu": (int(float(cfu_t)) if float(cfu_t).is_integer() else float(cfu_t))
                if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None,
                "lezioni": [html.unescape(link.group(1))] if link else [], "curriculum": curr,
            }
            gid = re.search(r'data-group-id="([^"]+)"', attr)
            aid = re.search(r'data-activity-id="([^"]+)"', attr)
            pid = re.search(r'data-parent-id="([^"]+)"', attr)
            if pid and pid.group(1) in padri and not cod:
                padri[pid.group(1)]["lezioni"] += riga["lezioni"]  # modulo dell'insegnamento integrato
                continue
            if not riga["codice"]:
                continue  # intestazione di un gruppo a scelta
            propri = {x.group(1) for x in (gid, aid) if x}
            percorso = re.sub(r"^/\w+/course/\d+/attendance/lesson/[^/]+/\d/\d/", "", riga["lezioni"][0]).split("/") \
                if riga["lezioni"] else []
            riga["obbligatorio"] = not percorso or percorso[0] in propri if riga["lezioni"] else None
            if gid:
                padri[gid.group(1)] = riga
            out.append(riga)
    # obbligatorietà degli integrati: dal primo modulo
    for r in out:
        if r["obbligatorio"] is None and r["lezioni"]:
            seg = re.sub(r"^/\w+/course/\d+/attendance/lesson/[^/]+/\d/\d/", "", r["lezioni"][0]).split("/")
            r["obbligatorio"] = len(seg) <= 2
    return out


# --- citazioni della sezione «Testi di riferimento» che estrai_libri non riconosce ---
# («Sadava D., Hillis D.M. Elementi di biologia e genetica.», titolo/autori/editore su righe
# separate, «M Biondi (a cura di). Compendio di psichiatria. Alpes, 2017»)
_U = "A-ZÀ-ÖØ-Ý"
_W = r"[\w'’\-]"
_AUTORE_INIZIO = re.compile(
    rf"^(?:[{_U}]{_W}+(?:\s[{_U}]{_W}+)?,?\s(?:[{_U}]\.\s?-?){{1,3}}"  # Sadava D., Neri G.
    rf"|(?:[{_U}]\.\s?-?){{1,3}}\s?[{_U}]{_W}+"  # G.M. Pontieri, K.S. SALADIN
    rf"|[{_U}]{{2,}}{_W}*(?:[\s\-][{_U}]{{2,}}{_W}*)*\s?[,.(:]"  # PATTON-THIBODEAU, ROSSI,
    rf"|[{_U}][a-zà-ÿ'’]+(?:\s[{_U}][a-zà-ÿ'’]+){{0,2}},\s"  # Rossi Mario, Titolo
    rf"|[{_U}][a-zà-ÿ'’]+(?:\s(?:e|and|&)\s[{_U}][a-zà-ÿ'’]+)+[.,:]\s)")  # Marchi e Rubatta. Titolo
# titolo tra virgolette, «… di Allen B. Downey», «… (Paterson and Wong)»
_TITOLO_AUTORE = re.compile(
    r"[“\"«][^”\"»]{8,}[”\"»]"
    rf"|\b(?:di|by)\s[{_U}][a-zà-ÿ'’]+\s(?:[{_U}]\.\s?){{0,2}}[{_U}][a-zà-ÿ'’]+"
    rf"|\((?:[{_U}][a-zà-ÿ'’]+(?:\s|\s(?:and|e|&)\s)){{1,4}}[{_U}][a-zà-ÿ'’]+\)\s*\.?$")
_CURA = re.compile(r"(?i)\(a cura di\)|\ba cura di\b|\(eds?\.?\)|\beds?\.\s|\bedit\.|\bby\s[A-Z]|\bed\.\s|"
                   r"\bedizione\b|\bedition\b|\bvol\.|\bpp\.")
_GENERICO = re.compile(r"(?i)(slide|dispens|appunt|materiale|lucidi|articol|piattaforma|e-?learning|moodle|classroom|"
                       r"verr[àa]|sarann|fornit|indicat|comunicat|lezion|docent|nessun|non previst|qualsiasi|"
                       r"handout|lecture|will be|provided|sito|website|bibliografia|linee guida|guidelines|"
                       r"materials?\b|notes\b)")
_ND = re.compile(r"(?i)^(n/?d|nessuno|none|-|non previsti?|modulo:.*)$")


def _intestazione(riga: str) -> bool:
    return (len(riga) < 70 and riga.rstrip().endswith(":")) or bool(
        re.fullmatch(r"(?i)(testi?|libri|textbooks?|references?|bibliografia)\W*", riga))


def _candidati(testo: str) -> list[tuple[str, str | None]]:
    """Righe dei testi di riferimento che hanno la forma di una citazione (con il tipo
    obbligatorio/consigliato dell'intestazione che le precede, se c'è)."""
    out, tipo, corte = [], None, []
    for riga in html_to_lines(testo):
        riga = re.sub(r"^[\s‐‑‒—―•▪◦●·*\-–]+", "", riga).strip()
        if not riga:
            continue
        if _ND.match(riga):
            corte = []
            tipo = None if riga.lower().startswith("modulo") else tipo
            continue
        if _intestazione(riga) and not YEAR.search(riga):
            tipo, corte = _tipo(riga), []
            continue
        pub, anno = bool(_EDITORI_CIT.search(riga)), bool(YEAR.search(riga))
        aut, cura, gen = bool(_AUTORE_INIZIO.match(riga)), bool(_CURA.search(riga)), bool(_GENERICO.search(riga))
        if re.match(r"(?i)(editore|publisher|casa editrice)\s*:", riga) and not corte:
            continue  # editore senza titolo
        if corte and not anno and (re.match(r"(?i)(editore|publisher|casa editrice)\s*:", riga) or (
                pub and len(riga.split()) <= 4 and len(riga) < 40)):
            out.append((", ".join(corte[-2:] + [riga]), tipo))  # titolo / autori / editore su righe separate
            corte = []
            continue
        tit = bool(_TITOLO_AUTORE.search(riga))
        ok = 15 <= len(riga) <= 700 and (pub or (anno and (aut or cura or tit or "," in riga))
                                         or (aut and (cura or (len(riga) >= 30 and not gen)))
                                         or ((cura or tit) and not gen))
        resto = _EDITORI_CIT.sub(" ", re.sub(r"(?i)\b(ed|edit|casa editrice|ultima edizione)\b\.?", " ", riga))
        if (gen and not (pub or anno)) or re.match(r"(?i)(https?://|www\.)", riga) or \
                len(re.findall(r"[^\W\d_]{3,}", resto)) < 2:
            ok = False
        if ok:
            out.append((riga, tipo))
            corte = []
        elif len(riga) < 60 and not gen and not pub and not re.match(r"(?i)(https?://|www\.)", riga):
            corte.append(riga)
        else:
            corte = []
    return out


def libri_testi(testo: str) -> list[dict]:
    """Libri dei testi di riferimento: le citazioni riconosciute da estrai_libri più le righe che
    ne hanno la forma (autori con iniziali, editore, anno, «a cura di»…). La sezione contiene solo
    riferimenti, quindi qui si accettano anche citazioni senza anno né ISBN."""
    libri = estrai_libri(testo)
    viste = {re.sub(r"\W+", "", b["citazione"].lower())[:120] for b in libri}
    for riga, tipo in _candidati(testo):
        k = re.sub(r"\W+", "", riga.lower())[:120]
        if k in viste or any(k in v or v in k for v in viste if len(v) > 20):
            continue
        viste.add(k)
        b = _libero(riga)
        if not b.get("tipo") and tipo:
            b["tipo"] = tipo
        libri.append(b)
    return libri

def _sezioni(s: str) -> dict[str, str]:
    """Riquadri a fisarmonica della pagina del canale: titolo -> html del contenuto."""
    return {_testo(t): c for t, c in re.findall(
        r'<div class="accordion-title">\s*<h4>(.*?)</h4>.*?<div class="accordion-content">(.*?)</div>\s*</div>', s, re.S)}


def leggi_canale(s: str) -> dict:
    sez = _sezioni(s)
    docenti = re.findall(r'href="/\w+/lecturer/[^"]*"[^>]*>(.*?)</a>', sez.get("Docenti", "") or s)
    testi = "<br>".join(sez.get(k) or "" for k in ("Testi di riferimento", "Reference books", "Reference texts",
                                                   "Bibliografia", "Bibliography"))
    return {"docenti": sorted({_titolo(_testo(d)) for d in docenti if _testo(d)}),
            "libri": libri_testi(testi) if testi.strip() else []}


def fetch_ateneo(uid: str = "uniroma1", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi sul catalogo corsidilaurea.uniroma1.it")
    c = Client(rate=5.0)
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        cid = _id(corso["url"])
        fonte = f"{BASE}/it/course/{cid}/attendance/lessons-plan"
        r = c.get(fonte)
        if not r:
            return None
        righe: dict[str, dict] = {}
        curricula = set()
        for x in leggi_piano(r.text):
            if not x["anno"]:
                continue
            curricula.add(x["curriculum"])
            key = f"{x['anno']}:{x['codice']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": x["periodo"],
                    "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None,
                    "docenti": [], "url": BASE + x["lezioni"][0] if x["lezioni"] else None, "libri": [],
                    "esami": [], "fonte": fonte, "verificato_il": oggi, "_curr": set(), "_lez": [],
                }
            item["obbligatorio"] = bool(item["obbligatorio"] or x["obbligatorio"])
            item["_curr"].add(x["curriculum"])
            item["_lez"] += [BASE + u for u in x["lezioni"] if BASE + u not in item["_lez"]]
        for i in righe.values():
            cs = i.pop("_curr")
            if len(curricula) > 1 and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": f"{BASE}/it/course/{cid}",
                "curricula": sorted(curricula) if len(curricula) > 1 else None,
                "fonte": fonte, "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    lezioni = sorted({u for x in out for i in x["insegnamenti"] for u in i["_lez"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"pagine di insegnamento: {len(lezioni) if syllabus else 0}")
    dati: dict[str, dict] = {}

    def leggi(u: str) -> None:
        try:
            r = c.get(u)
            canali = sorted(set(re.findall(r'href="([^"]*\?channel=\d+)"', r.text))) if r else []
            docenti, libri, viste = set(), [], set()
            for cu in canali or ([u] if r else []):
                rc = c.get(html.unescape(cu if cu.startswith("http") else BASE + cu)) if canali else r
                if not rc:
                    continue
                d = leggi_canale(rc.text)
                docenti |= set(d["docenti"])
                for lb in d["libri"]:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        libri.append(lb)
            dati[u] = {"docenti": sorted(docenti), "libri": libri}
        except Exception:  # noqa: BLE001 - una pagina illeggibile non ferma le altre
            dati[u] = {"docenti": [], "libri": []}

    if syllabus:
        with cf.ThreadPoolExecutor(5) as ex:
            for n, _ in enumerate(ex.map(leggi, lezioni), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   insegnamenti {n}/{len(lezioni)}")
    trovati = 0
    for x in out:
        for i in x["insegnamenti"]:
            docenti, viste = set(), set()
            for u in i.pop("_lez"):
                d = dati.get(u)
                if not d:
                    continue
                docenti |= set(d["docenti"])
                for lb in d["libri"]:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        i["libri"].append(lb)
            i["docenti"] = sorted(docenti)
            if syllabus:
                i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
            trovati += len(i["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da corsidilaurea.uniroma1.it (adapters/uniroma1.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
