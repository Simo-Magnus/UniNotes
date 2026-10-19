"""Insegnamenti, docenti e libri della Sapienza da corsidilaurea.uniroma1.it.

Esse3 della Sapienza non pubblica l'offerta, ma il catalogo dei corsi sì:

- `/it/course/<id>/attendance/lessons-plan` → didattica erogata nell'a.a. corrente per tutti
  gli anni e i curricula: codice Esse3 dell'attività (lo stesso degli appelli), nome, SSD,
  lingua, anno, semestre, CFU; gli insegnamenti con moduli hanno righe figlie; i gruppi a
  scelta compaiono come righe senza codice e i loro insegnamenti hanno il gruppo nel link;
- pagina dell'insegnamento (`…/attendance/lesson/…`) → canali (`?channel=N`);
- pagina del canale → "Docenti" e "Testi di riferimento".

- `/it/timeview/<anno>/<id>/study-plan` → piano ufficiale di una coorte: insegnamenti obbligatori,
  «Gruppo opzionale» con i CFU da acquisire («Lo studente deve acquisire 24 CFU fra i seguenti esami»),
  «A scelta dello studente». Il lessons-plan elenca l'erogato dell'a.a. corrente: l'anno k di un
  corso è il piano della coorte (anno corrente - k + 1), che ha un suo codice corso (menu «anno di
  riferimento»). Dal piano della coorte si prendono: i gruppi da sostenere per intero (CFU richiesti
  almeno quanti quelli dei suoi insegnamenti: obbligatori), le attività del piano non erogate e gli
  anni senza erogato.

I corsi sono quelli di database/corsi/uniroma1.json (da Universitaly), con `url`
`…/timeview/<anno>/<id>`.
"""
from __future__ import annotations

import concurrent.futures as cf
from collections import defaultdict
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


LIBERA = re.compile(r"(?i)a scelta dello studente|elective course|free choice")


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
                if not link or not LIBERA.search(riga["nome"]):
                    continue  # intestazione di un gruppo a scelta
                riga["nome"] = "A scelta dello studente" if re.search(r"(?i)a scelta", riga["nome"]) else riga["nome"]
                riga["obbligatorio"] = False  # crediti liberi: senza codice Esse3, li sceglie lo studente
                riga["libera"] = True
                out.append(riga)
                continue
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


# --- piano ufficiale di una coorte (study-plan) ---
def _righe(tbl: str) -> list[dict]:
    out = []
    for attr, tr in re.findall(r"<tr([^>]*)>(.*?)</tr>", tbl, re.S):
        td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if len(td) < 4:
            continue
        cl = re.search(r'class="([^"]*)"', attr)
        cod = re.search(r'class="activity-code">(.*?)</span>', td[0])
        nome = re.search(r'class="activity-name">(.*?)</span>', td[0], re.S)
        tag = re.search(r"<strong[^>]*>(.*?)</strong>", td[0], re.S)
        tag = re.findall(r"\[([^\]]*)\]", _testo(tag.group(1))) if tag else []
        cfu_t = _testo(td[3]).replace(",", ".")
        gid = re.search(r'data-group-id="([^"]+)"', attr)
        out.append({
            "classe": cl.group(1) if cl else "", "figlio": "data-parent-id" in attr,
            "codice": _testo(cod.group(1)) if cod else None, "nome": _titolo(_testo(nome.group(1))) if nome else "",
            "ssd": tag[0] if tag and tag[0] not in ("N/D", "") else None, "lingua": tag[1] if len(tag) > 1 else None,
            "anno": _num(td[1]), "periodo": str(_num(td[2])) if _num(td[2]) else None,
            "cfu": (int(float(cfu_t)) if float(cfu_t).is_integer() else float(cfu_t))
            if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None,
            "gruppo": gid.group(1) if gid else None})
    return out


def leggi_coorti(s: str) -> dict[int, str]:
    """Menu «anno di riferimento» della pagina study-plan: {anno di coorte: id del corso}."""
    return {int(a): i for a, i in re.findall(r'<option value="(\d{4})-(\d+)"', s)}


def leggi_studyplan(s: str) -> list[dict]:
    """Curricula della pagina study-plan: {'nome', 'fissi': [righe], 'gruppi': [{'nome', 'cfu', 'righe'}]}.
    Le righe senza codice che non sono moduli (anno e CFU, «A scelta dello studente») sono crediti liberi."""
    parti = re.split(r'<legend class="panel-heading">\s*<(?:a|span)[^>]*>(.*?)</(?:a|span)>\s*</legend>', s,
                     flags=re.S)
    out = []
    for nome, corpo in zip(parti[1::2], parti[2::2]):
        modali = {}
        for m in re.finditer(r'<div class="modal fade" id="(modal-[^"]+)".*?<h5 class="modal-title">(.*?)</h5>'
                             r'.*?<div class="modal-body">(.*?)</table>', corpo, re.S):
            modali[m.group(1)] = (_testo(m.group(2)), _righe(m.group(3)))
        t = re.search(r"<table.*?</table>", corpo, re.S)
        fissi, gruppi = [], []
        for r in _righe(t.group(0)) if t else []:
            if "group-optional-link" in r["classe"]:
                titolo, righe = modali.get(r["gruppo"], ("", []))
                m = re.search(r"acquisire (\d+(?:[.,]\d+)?) CFU", titolo)
                gruppi.append({"nome": re.sub(r"^Gruppo opzionale:\s*", "", r["nome"]),
                               "cfu": float(m.group(1).replace(",", ".")) if m else None,
                               "righe": [x for x in righe if not x["figlio"] and "text" not in x["classe"]
                                         and x["anno"] and (x["codice"] or x["cfu"])]})
            elif "text" in r["classe"] or (r["figlio"] and not r["codice"]) or not r["anno"]:
                continue  # descrizione o modulo di un insegnamento integrato
            elif r["codice"] or (LIBERA.search(r["nome"]) and r["cfu"]):
                fissi.append(r)
        out.append({"nome": _testo(nome), "fissi": fissi, "gruppi": gruppi})
    return out


def gruppi_interi(curricula: list[dict]) -> set[str]:
    """Codici degli insegnamenti nei gruppi opzionali da sostenere per intero: i CFU da acquisire
    sono almeno quelli di tutti gli insegnamenti del gruppo (un solo insegnamento da 12 CFU
    «da acquisire 12», due da 6 «da acquisire 12»)."""
    out = set()
    for cu in curricula:
        for g in cu["gruppi"]:
            cod = {x["codice"]: x["cfu"] or 0 for x in g["righe"] if x["codice"]}
            if g["cfu"] and cod and sum(cod.values()) <= g["cfu"] + 1e-9:
                out |= set(cod)
    return out


def _gruppi_distinti(cu: dict) -> list[dict]:
    """Gruppi opzionali del curriculum senza ripetizioni (lo stesso gruppo compare più volte nel piano)."""
    visti, out = set(), []
    for g in cu["gruppi"]:
        k = (g["nome"], g["cfu"], frozenset((x["codice"], x["anno"]) for x in g["righe"]))
        if k not in visti:
            visti.add(k)
            out.append(g)
    return out


def cfu_atteso(curricula: list[dict], anno: int) -> dict[str, float]:
    """CFU dell'anno secondo il piano ufficiale, per curriculum: attività fisse (ognuna una volta) più i CFU
    da acquisire nei gruppi opzionali dell'anno (gruppo che ha insegnamenti in anni diversi: non attribuibile,
    si omette). Serve a verificare un anno che sul database sembra incompleto."""
    out = {}
    for cu in curricula:
        fissi, tot = {}, 0.0
        for x in cu["fissi"]:
            if x["anno"] == anno:
                fissi[x["codice"] or f"#{x['nome']}{x['periodo']}{len(fissi)}"] = x["cfu"] or 0
        for g in _gruppi_distinti(cu):
            anni = {x["anno"] for x in g["righe"]}
            if anni == {anno}:
                tot += g["cfu"] or 0
        out[cu["nome"]] = sum(fissi.values()) + tot
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
                 corsi: list[dict] | None = None, log=print, riuso: dict | None = None) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py).

    `riuso`: {(id corso, anno, codice): {"docenti", "libri", "stato_libri"}} di una raccolta precedente; per
    gli insegnamenti già presenti non si rileggono le pagine di docenti e libri (solo i piani)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi sul catalogo corsidilaurea.uniroma1.it")
    c = Client(rate=5.0)
    oggi = time.strftime("%Y-%m-%d")

    def piani_coorte(corso: dict, cid: str) -> dict[int, tuple[str, list[dict]]]:
        """{anno di corso k: (url del piano, curricula)} dal piano ufficiale della coorte (anno corrente - k + 1)."""
        m = re.search(r"/timeview/(\d{4})/", corso["url"])
        a0 = int(m.group(1)) if m else anno
        if not a0:
            return {}
        out: dict[int, tuple[str, list[dict]]] = {}
        base = f"{BASE}/it/timeview/{a0}/{cid}/study-plan"
        rb = c.get(base)
        if not rb:
            return out
        coorti = leggi_coorti(rb.text)
        for k in range(1, (corso.get("durata_anni") or 3) + 1):
            y = a0 - k + 1
            if k == 1:
                url, testo = base, rb.text
            elif y in coorti:
                url = f"{BASE}/it/timeview/{y}/{coorti[y]}/study-plan"
                rc = c.get(url)
                testo = rc.text if rc else None
            else:
                continue
            if testo:
                out[k] = (url, leggi_studyplan(testo))
        return out

    def piano_anno_senza_erogato(corso: dict, cid: str, k: int) -> tuple[str, list[dict]] | None:
        """Anno che l'erogato non elenca e senza una coorte propria (corso istituito da poco): il piano
        della coorte più recente che lo prevede."""
        m = re.search(r"/timeview/(\d{4})/", corso["url"])
        a0 = int(m.group(1)) if m else anno
        rb = c.get(f"{BASE}/it/timeview/{a0}/{cid}/study-plan") if a0 else None
        if not rb:
            return None
        coorti = leggi_coorti(rb.text)
        for y in sorted(coorti, reverse=True):
            url = f"{BASE}/it/timeview/{y}/{coorti[y]}/study-plan"
            rc = c.get(url)
            cus = leggi_studyplan(rc.text) if rc else []
            if any(x["anno"] == k for cu in cus for x in cu["fissi"] + [z for g in cu["gruppi"] for z in g["righe"]]):
                return url, cus
        return None

    def build(corso: dict) -> dict | None:
        cid = _id(corso["url"])
        fonte = f"{BASE}/it/course/{cid}/attendance/lessons-plan"
        r = c.get(fonte)
        if not r:
            return None
        righe: dict[str, dict] = {}
        curricula = set()
        piani = piani_coorte(corso, cid)
        interi = {k: gruppi_interi(cu) for k, (_, cu) in piani.items()}
        interi_curr = {(k, cu["nome"]): gruppi_interi([cu]) for k, (_, cus) in piani.items() for cu in cus}
        lp = [x for x in leggi_piano(r.text) if x["anno"]]
        for k in range(1, (corso.get("durata_anni") or 3) + 1):
            if k not in piani and not any(x["anno"] == k for x in lp):
                alt = piano_anno_senza_erogato(corso, cid, k)
                if alt:
                    piani[k] = alt
                    interi[k] = gruppi_interi(alt[1])
                    interi_curr.update({(k, cu["nome"]): gruppi_interi([cu]) for cu in alt[1]})
        n_libere: dict = defaultdict(int)
        for x in lp:
            curricula.add(x["curriculum"])
            if x.get("libera"):
                # più righe «A scelta dello studente» nello stesso anno sono voci diverse (12 CFU = 6 + 6)
                sl = re.sub(r"[^a-z0-9]+", "", x["nome"].lower())
                n_libere[(x["curriculum"], x["anno"], sl)] += 1
                n = n_libere[(x["curriculum"], x["anno"], sl)]
                key = f"{x['anno']}:#{sl}:{n}:{x['periodo']}:{x['cfu']}"
            else:
                key = f"{x['anno']}:{x['codice']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": x["periodo"],
                    "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None,
                    "docenti": [], "url": BASE + x["lezioni"][0] if x["lezioni"] and not x.get("libera") else None,
                    "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi, "_curr": set(), "_lez": [],
                }
                if x.get("libera"):
                    item["_n"] = n
            # gruppo da sostenere per intero (CFU richiesti almeno quanti quelli dei suoi insegnamenti)
            intero = x["codice"] in interi_curr.get((x["anno"], x["curriculum"]), interi.get(x["anno"], ()))
            item["obbligatorio"] = bool(item["obbligatorio"] or x["obbligatorio"] or intero)
            item["_curr"].add(x["curriculum"])
            if not x.get("libera"):
                item["_lez"] += [BASE + u for u in x["lezioni"] if BASE + u not in item["_lez"]]
        # attività del piano ufficiale della coorte che l'erogato dell'a.a. non elenca
        for k, (url, cus) in piani.items():
            unico = len(curricula) == 1 and len(cus) == 1
            libere_lp = any(i["anno"] == k and not i["codice"] for i in righe.values())
            n_sp: dict = defaultdict(int)
            for cu in cus:
                nome_cu = next(iter(curricula)) if unico else cu["nome"]
                if curricula and nome_cu not in curricula:
                    continue
                gruppi_ok = gruppi_interi([cu])
                voci = [(x, True) for x in cu["fissi"]]
                voci += [(x, x["codice"] in gruppi_ok) for g in cu["gruppi"] for x in g["righe"]]
                for x, obb in voci:
                    if x["anno"] != k:
                        continue
                    if not x["codice"]:
                        if libere_lp or not LIBERA.search(x["nome"]) or not x["cfu"]:
                            continue
                        sl = re.sub(r"[^a-z0-9]+", "", x["nome"].lower())
                        n_sp[(cu["nome"], sl)] += 1
                        n = n_sp[(cu["nome"], sl)]
                        key = f"{k}:#{sl}:{n}:{x['periodo']}:{x['cfu']}"
                        x = {**x, "nome": "A scelta dello studente" if re.search(r"(?i)a scelta", x["nome"])
                             else x["nome"]}
                    else:
                        key = f"{k}:{x['codice']}"
                    item = righe.get(key)
                    if not item:
                        item = righe[key] = {
                            "codice": x["codice"], "nome": x["nome"], "anno": k, "periodo": x["periodo"],
                            "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": obb if x["codice"] else False,
                            "curriculum": None, "docenti": [], "url": None, "libri": [], "esami": [],
                            "fonte": url, "verificato_il": oggi, "_curr": set(), "_lez": [],
                        }
                        if not x["codice"]:
                            item["_n"] = n
                    item["_curr"].add(nome_cu)
                    curricula.add(nome_cu)
        # più voci «A scelta dello studente» nel corso: numerate. Il database unisce le voci con lo stesso nome
        # (nello stesso anno, o in anni diversi se a scelta), e invece sono crediti liberi distinti
        per_nome: dict[str, list[dict]] = defaultdict(list)
        for i in righe.values():
            if i.pop("_n", None):
                per_nome[re.sub(r"[^a-z0-9]+", "", i["nome"].lower())].append(i)
        for voci in per_nome.values():
            if len(voci) > 1:
                for n, i in enumerate(sorted(voci, key=lambda i: (i["anno"], i["periodo"] or "", i["cfu"] or 0)), 1):
                    i["nome"] = f"{i['nome']} {n}"
        for i in righe.values():
            vecchio = (riuso or {}).get((corso["id"], i["anno"], i["codice"])) if i["codice"] else None
            if vecchio:
                i.update(docenti=vecchio["docenti"], libri=vecchio["libri"], _riusato=True)
                if vecchio.get("stato_libri"):
                    i["stato_libri"] = vecchio["stato_libri"]
                i["_lez"] = []
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
            if i.pop("_riusato", False):
                i.pop("_lez", None)
                trovati += len(i["libri"])
                continue
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
