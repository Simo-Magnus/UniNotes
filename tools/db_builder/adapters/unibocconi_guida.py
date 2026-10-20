"""Piano di studi dalla «Guide to the University» di Bocconi (didattica.unibocconi.eu/tsg)."""
from __future__ import annotations

import re

HEAD = re.compile(r'^(\d+(?:\.\d+)+)\.?$')
CODE = re.compile(r'^\d{4,6}$')
LANG = re.compile(r'^(ENG|ITA|FRA|SPA|DEU|ENG\s*/\s*ITA|ITA\s*/\s*ENG|ITA\s*\(.*\).*|ENG\s*\(.*\).*|ENG and ITA|ITA and ENG)$')
NUM = re.compile(r'^(\d+(?:[.,]\d+)?)(?:\s*\(\*+\))?$')
SEMCOL = re.compile(r'^(I|II|I and II|I\s*/\s*II|I or II)$')
ANNO = re.compile(r'^(First|Second|Third|Fourth|Fifth) year(?: of studies)?\b', re.I)
ORD = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5}
SEMH = re.compile(r'^(?:(I|II|First|Second|1st|2nd) semester|(?:First|I) or (?:second|II) semester|I/II semester|Semester (I|II|1|2))$', re.I)
INTEST = {x.lower() for x in (
    "Code", "Educational activity", "Educational activities", "Course title", "Language of instruction", "CP",
    "Semester", "Courses", "English translation", "Notes", "Course", "Credit points", "Translation", "Language of",
    "instruction", "ECTS", "Local credit points", "Bocconi course equivalent", "Academic activities", "Title", "Cp",
    "Concentration")}
LABEL = re.compile(r'(?i)^(major in|track\b|curriculum\b|path\b|program track)\b.{0,80}$')
GRUPPO = re.compile(r'(?i)\b(chosen|select\w*|choose|between|among|from the following|to be chosen|out of the following|'
                    r'out of \d|from among)\b')
PERIODO_BIM = re.compile(r'(?i)^(first|second|third|fourth|1st|2nd|3rd|4th) (bimester|semester|quarter)$')
NOTA = re.compile(r'(?i)^(note\b|\(\*|\*|the program structure|the concentration structure|during the first year|'
                  r'for students|students\b|list of|a\)|b\)|c\)|d\)|bocconi course|local credit|list [ab]\b|\(\*\*)')
SEGNAPOSTO = re.compile(r'(?i)\b(elective|opzional\w*|activity chosen by the student|attivit\w+ a scelta|workshops?$)')
INF = float("inf")


def albero(righe: list[str]) -> list[dict]:
    """Capitoli numerati: {num, title, start, level, parent, end (con i sottocapitoli), own_end (primo figlio)}."""
    nodi = []
    for i, x in enumerate(righe[:-1]):
        m = HEAD.match(x)
        if m and not re.match(r'^[\d.]+$', righe[i + 1]) and len(righe[i + 1]) < 400:
            nodi.append({"num": m.group(1), "title": righe[i + 1].strip(), "start": i,
                         "level": m.group(1).count(".")})
    for k, n in enumerate(nodi):
        n["idx"] = k
        n["end"] = n["own_end"] = len(righe)
        n["parent"] = next((j for j in range(k - 1, -1, -1) if nodi[j]["level"] < n["level"]), None)
        for m in nodi[k + 1:]:
            if n["own_end"] == len(righe):
                n["own_end"] = m["start"]
            if m["level"] <= n["level"]:
                n["end"] = m["start"]
                break
    return nodi


def _token(x: str, ects: bool = False) -> list[tuple]:
    x = x.strip()
    if re.match(r'(?i)^last change\b', x):
        return [("hdr", x)]
    m = re.match(r'^(\d{4,6})\s*[-–]?\s+(\S.*)$', x) if ects else re.match(r'^(\d{4,6})\s+(\S.*)$', x)
    if m and not NUM.match(x):
        return [("code", m.group(1)), ("text", m.group(2).lstrip("-– ").strip())]
    if CODE.match(x) and len(x) >= 5:
        return [("code", x)]
    if LANG.match(x):
        return [("lang", x)]
    if NUM.match(x):
        return [("num", float(NUM.match(x).group(1).replace(",", ".")))]
    if SEMH.match(x):
        return [("semh", x)]
    m = ANNO.match(x)
    if m and len(x) < 120:
        return [("annoh", ORD[m.group(1).lower()], x)]
    if re.match(r'(?i)^(total|totale)\b', x) and len(x) < 160:
        return [("total", x)]
    if x.lower() in INTEST:
        return [("hdr", x)]
    if SEMCOL.match(x):
        return [("sem", x)]
    return [("text", x)]


def eventi(righe: list[str], ects: bool = False) -> list[tuple]:
    """Righe di un capitolo → eventi: ('annoh', k, testo), ('semh', testo), ('label', testo), ('riga', {...}),
    ('total', testo, numero)."""
    ev: list[tuple] = []
    toks = [t for x in righe for t in _token(x, ects)]
    row = {"codici": [], "testi": [], "lang": None}
    conc = False

    def reset():
        row.update(codici=[], testi=[], lang=None)
        row.pop("sem", None)

    def svuota():
        for t in row["testi"]:
            if LABEL.match(t):
                ev.append(("label", t))
        reset()

    i = 0
    while i < len(toks):
        t = toks[i]
        k = t[0]
        if k == "annoh":
            svuota()
            ev.append(("annoh", t[1], t[2]))
        elif k == "semh":
            svuota()
            ev.append(("semh", t[1]))
        elif k == "total":
            svuota()
            n = None
            if i + 1 < len(toks) and toks[i + 1][0] == "num":
                n = toks[i + 1][1]
                i += 1
            ev.append(("total", t[1], n))
        elif k == "hdr":
            if t[1].lower() == "concentration":
                conc = True
        elif k == "code":
            if row["testi"] and not row["codici"]:
                for x in [x for x in row["testi"] if LABEL.match(x)]:
                    ev.append(("label", x))
                    row["testi"].remove(x)
            elif row["testi"] and row["codici"] and not row["lang"]:
                # riga senza CFU (cella unita con un'altra): si chiude qui
                ev.append(("riga", dict(row, cp=None, sem=row.get("sem"), parziale=True, conc=conc)))
                reset()
            row["codici"].append(t[1])
        elif k == "text":
            row["testi"].append(t[1])
        elif k == "lang":
            row["lang"] = t[1]
        elif k == "sem":
            if row["codici"] or row["testi"]:
                row["sem"] = t[1]
        elif k == "num":
            if row["codici"] or row["testi"]:
                cp = t[1]
                if ects and i + 1 < len(toks) and toks[i + 1][0] == "num":
                    cp = toks[i + 1][1]
                    i += 1
                r = dict(row, cp=cp, conc=conc)
                r.setdefault("sem", None)
                if i + 1 < len(toks) and toks[i + 1][0] == "sem":
                    r["sem"] = toks[i + 1][1]
                    i += 1
                ev.append(("riga", r))
                reset()
        i += 1
    svuota()
    return ev


def _pulisci(t: str) -> str:
    t = re.sub(r'\s*\(\*+\)\s*', ' ', t)
    t = re.sub(r'\s*\((?:see note\s*\d*)\)\s*', ' ', t, flags=re.I)
    return re.sub(r'\s+', ' ', t).strip(" -–")


def _unisci_parentesi(testi: list[str]) -> list[str]:
    """Un nome andato a capo dentro una parentesi («… (Empirical research» / «methods and data analysis)»)."""
    out: list[str] = []
    for t in testi:
        if out and out[-1].count("(") > out[-1].count(")"):
            out[-1] = out[-1] + " " + t
        else:
            out.append(t)
    return out


def _nota_nome(nome: str) -> tuple[str, str | None]:
    """Toglie le annotazioni tra parentesi in coda («(students of concentration B…)», «(2nd semester - Turin*)»)
    e ne ricava il periodo."""
    per = None
    m = re.search(r'\s*\(\s*((?:1st|2nd|I|II|first|second)\s+sem[^)]*)\)\s*$', nome, re.I)
    if m:
        per = periodo(m.group(1).split("-")[0].strip())
        nome = nome[:m.start()].strip()
    m = re.search(r'\s*\((?:students of|see )[^)]*\)\s*$', nome, re.I)
    if m:
        nome = nome[:m.start()].strip()
    return nome, per


def interpreta(r: dict, trad: bool = False) -> list[dict]:
    """Una riga di tabella → insegnamenti {codice, nome, nome_alt, cp, curriculum, gruppo, sem, obb}."""
    cod = list(r["codici"])
    gruppo = None
    obb = None
    nomi: list[str] = []
    mh = re.search(r'(?i)" + bs + "b(first|second|third|fourth|fifth)" + bs + "s+year" + bs + "b', " ".join(r["testi"]))
    anno_hint = ORD[mh.group(1).lower()] if mh else None
    solo_intest = None
    for t in _unisci_parentesi([t.strip() for t in r["testi"] if t.strip()]):
        if t.endswith(":") or PERIODO_BIM.match(t) or NOTA.match(t) or len(t) > 220:
            if GRUPPO.search(t) and gruppo is None and len(t) < 110:
                gruppo = t
                solo_intest = _pulisci(t.rstrip(":"))
            elif re.search(r'(?i)\bcompulsory\b', t) and not GRUPPO.search(t) and t.endswith(":"):
                obb = True
            continue
        if GRUPPO.search(t) and re.match(r'(?i)^(\d+|one|two|three|four|n\.?\s*\d+)\b', t) and not SEGNAPOSTO.search(t):
            gruppo = gruppo or t
            solo_intest = solo_intest or _pulisci(t.rstrip(":"))
            continue
        if re.match(r'(?i)^or$', t):
            continue
        t = re.sub(r'(?i)\s+or$', '', t)
        nomi.append(_pulisci(t))
    nomi = [n for n in nomi if n]
    lang = r.get("lang") or ""
    ita = lang.startswith("ITA") or trad
    if len(nomi) > 1:
        nomi = [n for i, n in enumerate(nomi) if not (i and re.match(r'(?i)^or\b', n))]
    curr_col = None
    if r.get("conc") and len(nomi) >= 2 and len(cod) == 1:
        curr_col = re.sub(r'\s*/\s*', ", ", nomi[-1])
        nomi = nomi[:-1]
    out: list[dict] = []
    extra: list[str] = []
    if len(cod) >= 2:
        n = len(cod)
        if len(nomi) >= 2 * n and ita:
            pr, alt = nomi[:n], nomi[n:2 * n]
        elif len(nomi) > n:
            pr, alt = nomi[:n], [None] * n
            extra = nomi[n:]
        else:
            pr, alt = nomi, [None] * n
        pr = pr + [None] * (n - len(pr))
        for c, a, b in zip(cod, pr, alt):
            out.append({"codice": c, "nome": a, "nome_alt": b})
        for x in extra:
            out.append({"codice": None, "nome": x, "nome_alt": None})
    elif len(cod) == 1:
        if len(nomi) >= 2 and ita:
            out.append({"codice": cod[0], "nome": nomi[0], "nome_alt": nomi[1]})
        elif len(nomi) >= 2:
            if re.match(r'(?i)^(module|mod\.|\()', nomi[-1]):
                out.append({"codice": cod[0], "nome": " - ".join(nomi[-2:]), "nome_alt": None})
            else:
                out.append({"codice": cod[0], "nome": nomi[-1], "nome_alt": None})
        elif nomi:
            out.append({"codice": cod[0], "nome": nomi[0], "nome_alt": None})
    else:
        if len(nomi) == 2 and ita:
            out.append({"codice": None, "nome": nomi[0], "nome_alt": nomi[1]})
        else:
            for n in nomi:
                out.append({"codice": None, "nome": n, "nome_alt": None})
    if not out and solo_intest and not cod and r.get("cp"):
        # riga con la sola frase «1 compulsory course to be chosen» e i CFU: segnaposto della scelta
        out = [{"codice": None, "nome": solo_intest, "nome_alt": None}]
        gruppo = None
    res = []
    for o in out:
        o["anno_hint"] = anno_hint
        if not o["nome"] or re.search(r'(?i)no longer offered|not offered', o["nome"]):
            continue
        o.update(cp=r["cp"], gruppo=gruppo, lang=lang, sem=r.get("sem"), curriculum=curr_col, obb=obb, per_nome=None)
        o["nome"], o["per_nome"] = _nota_nome(o["nome"])
        for ch in ("nome", "nome_alt"):
            m = re.search(r'\s*\(for ([^)]+)\)\s*$', o.get(ch) or "", re.I)
            if m:
                if ch == "nome":
                    o["curriculum"] = m.group(1).strip()
                o[ch] = o[ch][:m.start()].strip()
        res.append(o)
    return res


def periodo(testo: str | None) -> str | None:
    t = (testo or "").strip().lower()
    if re.match(r'^(i|1st|first|semester (i|1))( semester)?$', t) or t in ("i semester", "first semester", "1st semester"):
        return "1"
    if re.match(r'^(ii|2nd|second|semester (ii|2))( semester)?$', t) or t in ("ii semester", "second semester", "2nd semester"):
        return "2"
    return None


# ------------------------------------------------------------------ piano di un programma
def _coorte(titolo: str) -> tuple[float, float]:
    """(da, a) coorti (anno di inizio) accettate dal titolo di una sezione."""
    t = titolo
    m = re.search(r'(?i)(until|up to|enrolled until)\D{0,16}(\d{4})', t)
    if m:
        return -INF, float(m.group(2))
    m = re.search(r'(?i)(starting from|starting in|from|starting)\D{0,12}(\d{4})', t)
    if m:
        return float(m.group(2)), INF
    m = re.search(r'(?i)enrolled in(?: the)?\D{0,12}(\d{4})|(?:students|cohort)\D{0,20}in the\D{0,4}(\d{4})', t)
    if m:
        y = float(m.group(1) or m.group(2))
        return y, y
    return -INF, INF


def _nome_curriculum(t: str) -> str:
    t = re.sub(r'(?i)^(major in|track\s*[-–:]?|curriculum in|study plan( im)?|program(me)? structure\s*[-–]\s*)\s*', '', t.strip())
    t = re.sub(r'\s+', ' ', t).strip(" -–:.")
    if t.isupper():
        piccole = {"and", "of", "the", "for", "in", "&", "to", "e", "di"}
        sigle = {"essec", "cems", "mim", "dd", "hec", "cpa", "ai", "im"}
        t = " ".join(w if w in piccole else (w.upper() if len(w) <= 3 or w in sigle else w.capitalize())
                     for w in t.lower().split())
    return t


def _curriculum_titolo(titolo: str) -> str | None:
    m = re.match(r'(?i)^(curriculum in|study plan( im)?\b|program(?:me)? structure\s*[-–]\s*)(.*)$', titolo.strip())
    if m and m.group(3).strip():
        return _nome_curriculum(titolo)
    return None


def leggi_nodo(righe, nodi, n, ects=False):
    """Eventi del testo proprio di un capitolo (senza i sottocapitoli)."""
    return eventi(righe[n["start"] + 2:n["own_end"]], ects)


def tabelle(ev, trad=False):
    """Eventi → (anni, elenco): anni = {k: [voci]} e voci dopo l'ultimo totale o senza anno (elenchi di scelta)."""
    anni: dict[int, list[dict]] = {}
    k = None
    sem = None
    label = None
    gruppo_resta = 0
    gruppo_id = 0
    gruppo = None
    prec = None
    pend: list[dict] = []
    obb_stato = None
    ultimo_tot = max([i for i, e in enumerate(ev) if e[0] == "total"], default=-1)
    elenco: list[dict] = []
    totali: dict[int, float] = {}

    hint = [None]

    def aggiungi(voci, idx):
        if idx > ultimo_tot and ultimo_tot >= 0 and k is not None:
            for v in voci:
                if v.get("anno_hint"):
                    hint[0] = v["anno_hint"]
                v["anno_hint"] = hint[0]
            elenco.extend(voci)
        elif k is not None:
            anni[k].extend(voci)
        else:
            elenco.extend(voci)

    for idx, e in enumerate(ev):
        if e[0] == "total":
            if k is not None and e[2] is not None:
                totali.setdefault(k, e[2])
        elif e[0] == "annoh":
            k = e[1]
            sem = None
            obb_stato = None
            anni.setdefault(k, [])
        elif e[0] == "semh":
            sem = periodo(e[1])
            obb_stato = None
        elif e[0] == "label":
            label = _nome_curriculum(e[1])
            obb_stato = None
        elif e[0] == "riga":
            r = e[1]
            if r.get("parziale"):
                intest = any(GRUPPO.search(t) for t in r["testi"])
                if intest or pend:
                    # «1 course to be chosen among: A» + «B» + … + CFU alla fine: i CFU sono quelli della riga che segue
                    voci = interpreta(dict(r, cp=None), trad)
                    if voci:
                        if intest or not pend:
                            gruppo_id += 1
                            gruppo = gruppo_id
                        for v in voci:
                            v.update(periodo=periodo(v["sem"]) if v["sem"] else sem, label=label,
                                     gid=(pend[0]["gid"] if pend and not intest else gruppo), obb=False)
                        pend = (pend if not intest else []) + voci
                        aggiungi(voci, idx)
                        prec = dict(voci[-1])
                    continue
                if prec is None:
                    continue
                r = dict(r, cp=prec["cp"])
            voci = interpreta(r, trad)
            if not voci:
                continue
            g = voci[0]["gruppo"]
            if voci[0]["obb"] is not None:
                obb_stato = voci[0]["obb"]
            elif g:
                obb_stato = False
            for v in voci:
                v["periodo"] = periodo(v["sem"]) if v["sem"] else (v["per_nome"] or sem)
                v["label"] = label
                v["gid"] = None
                v["obb"] = obb_stato
            if pend and not r.get("parziale"):
                for v in pend:
                    v["cp"] = r["cp"]
                for v in voci:
                    v["gid"] = pend[0]["gid"]
                pend = []
            elif g:
                gruppo_id += 1
                gruppo = gruppo_id
                n_opz = len(voci)
                gruppo_resta = 0
                if re.search(r'(?i)\bbetween\b|out of the following 2', g) and n_opz < 2:
                    gruppo_resta = 2 - n_opz
                for v in voci:
                    v["gid"] = gruppo
                m = re.match(r'(?i)^(\d+)\s+(?:major\s+)?(?:compulsory\s+)?(?:courses|electives)', g)
                if m and int(m.group(1)) >= 2 and n_opz > int(m.group(1)) and r["cp"] and r["cp"] % int(m.group(1)) == 0:
                    for v in voci:
                        v["cp"] = r["cp"] / int(m.group(1))
                        v["n_gruppo"] = int(m.group(1))
            elif gruppo_resta > 0:
                gruppo_resta -= len(voci)
                for v in voci:
                    v["gid"] = gruppo
            elif len(voci) > 1 and all(not v["curriculum"] for v in voci) and any(v["codice"] for v in voci):
                gruppo_id += 1
                for v in voci:
                    v["gid"] = gruppo_id
            prec = dict(voci[-1])
            aggiungi(voci, idx)
    return anni, elenco, totali


def elenco_semplice(righe, cp_default=None):
    """Elenco di corsi a scelta senza colonna dei CFU (Code, Course title, Translation, Semester, Language), o
    righe «codice nome (6 CP)»."""
    out = []
    cur = None
    for x in righe:
        for t in _token(x):
            if t[0] == "code":
                cur = {"codice": t[1], "testi": [], "sem": None, "lang": None}
                out.append(cur)
            elif cur is None:
                continue
            elif t[0] == "text":
                cur["testi"].append(t[1])
            elif t[0] == "sem":
                cur["sem"] = t[1]
            elif t[0] == "lang":
                cur["lang"] = t[1]
    res = []
    for c in out:
        testi = [t for t in c["testi"] if not t.endswith(":") and not NOTA.match(t)]
        if not testi:
            continue
        nomi = [_pulisci(t) for t in testi]
        cp = cp_default
        m = re.search(r'\((\d+(?:[.,]\d+)?)\s*CP\)\s*$', nomi[0])
        if m:
            cp = float(m.group(1).replace(",", "."))
            nomi[0] = nomi[0][:m.start()].strip()
        ita = (c["lang"] or "").startswith("ITA") or len(nomi) > 1
        if len(nomi) == 4:
            nome, alt = f"{nomi[0]} - {nomi[1]}", f"{nomi[2]} - {nomi[3]}"
        else:
            nome = " ".join(nomi) if not ita and len(nomi) > 1 else nomi[0]
            alt = nomi[1] if ita and len(nomi) > 1 else None
        res.append({"codice": c["codice"], "nome": nome,
                    "nome_alt": alt, "cp": cp,
                    "periodo": periodo(c["sem"] + " semester") if c["sem"] in ("I", "II") else None,
                    "gruppo": None, "gid": None, "curriculum": None, "label": None, "lang": c["lang"], "obb": None,
                    "sem": None, "per_nome": None})
    return res


def _classifica_nodi(righe, nodi, programma, ects=False):
    """Capitoli del programma con tabelle: strutture (anni con totali) ed elenchi."""
    out = []
    for n in nodi:
        if not (programma["start"] <= n["start"] < programma["end"]):
            continue
        ev = leggi_nodo(righe, nodi, n, ects)
        senza_cfu = None
        if not any(e[0] == "riga" for e in ev):
            senza_cfu = elenco_semplice(righe[n["start"] + 2:n["own_end"]])
            if len(senza_cfu) < 3:
                continue
        titolo = n["title"]
        coorte = _coorte(titolo)
        a = n
        while coorte == (-INF, INF) and a["parent"] is not None:
            a = nodi[a["parent"]]
            if a["start"] < programma["start"]:
                break
            coorte = _coorte(a["title"])
        classe = None
        m = re.search(r'(?i)\b(italian|english) class group', titolo)
        if m:
            classe = m.group(1).lower()
        trad = any(x.strip().lower() == "english translation" for x in righe[n["start"]:n["own_end"]])
        anni, elenco, totali = tabelle(ev, trad)
        if senza_cfu:
            elenco = senza_cfu
        con_totali = any(e[0] == "total" for e in ev)
        # anno del capitolo (da lui o da un antenato): «Second year of studies»
        anno_cap = None
        a = n
        while a is not None and a["start"] >= programma["start"]:
            m = ANNO.match(a["title"]) or re.search(r'(?i)\b(first|second|third|fourth|fifth) year\b', a["title"])
            if m:
                anno_cap = ORD[m.group(1).lower()]
                break
            a = nodi[a["parent"]] if a["parent"] is not None else None
        out.append({"nodo": n, "num": n["num"], "titolo": titolo, "coorte": coorte, "classe": classe,
                    "curriculum": _curriculum_titolo(titolo), "anni": anni, "elenco": elenco,
                    "struttura": bool(anni) and con_totali, "anno_cap": anno_cap, "totali": totali})
    return out


def _distanza(coorte, y):
    lo, hi = coorte
    return max(lo - y, y - hi, 0)


def _tit_elenco(titolo, padre=""):
    """Un capitolo che elenca i corsi di una concentrazione/percorso è un curriculum; elenchi di elettivi, major senza
    nome proprio e simili no."""
    if re.search(r'(?i)(list|elective|free track|electives|^majors?$|workshops?)', titolo):
        return None
    if re.search(r'(?i)(concentrations?|tracks?)', padre) or re.search(r'(?i)\btrack$', titolo.strip()):
        return _nome_curriculum(titolo)
    return None


def piano(righe, nodi, programmi, durata, fine, classe_it=True, ects=False):
    """Voci del piano di ogni anno. `programmi`: capitoli dei programmi (uno o più). Ritorna (voci, scelte)."""
    classi = []
    for pi, p in enumerate(programmi):
        for x in _classifica_nodi(righe, nodi, p, ects):
            x["prog"] = pi
            classi.append(x)
    strutture = [x for x in classi if x["struttura"]]
    elenchi = [x for x in classi if not x["struttura"]]
    voci: list[dict] = []
    scelte: dict[int, dict] = {}
    for k in range(1, durata + 1):
        y = (fine - 1) - (k - 1)
        cand = [s for s in strutture if s["anni"].get(k)
                and (s["classe"] is None or s["classe"] == ("italian" if classe_it else "english"))]
        if not cand:
            continue
        dmin = min(_distanza(s["coorte"], y) for s in cand)
        visti, scelti = set(), []
        for s in cand:
            if _distanza(s["coorte"], y) != dmin or s["curriculum"] in visti:
                continue
            visti.add(s["curriculum"])
            scelti.append(s)
        scelte[k] = {"nodi": scelti, "dist": dmin, "y": y}
        for s in scelti:
            for v in s["anni"][k]:
                w = dict(v)
                w.update(anno=k, nodo=s["num"], curr=w["curriculum"] or w["label"] or s["curriculum"],
                         pool=False, d=dmin)
                voci.append(w)
            ha_seg = any(SEGNAPOSTO.search(v["nome"]) for v in s["anni"][k])
            for v in s["elenco"]:
                if (v.get("anno_hint") and v["anno_hint"] == k) or (not v.get("anno_hint") and ha_seg):
                    w = dict(v)
                    w.update(anno=k, nodo=s["num"], curr=w["curriculum"] or w["label"] or s["curriculum"],
                             pool=True, d=dmin)
                    voci.append(w)
    # elenchi propri (concentrazioni, major, elettivi di un programma)
    programmi_usati = {s["prog"] for sc in scelte.values() for s in sc["nodi"]}
    for el in elenchi:
        p = el["prog"]
        if p not in programmi_usati and not programmi[p].get("solo_elenco"):
            continue
        anni_p = sorted({k for s in strutture if s["prog"] == p for k in s["anni"]})
        k_def = programmi[p].get("anno") or el["anno_cap"] or (anni_p[-1] if anni_p else durata)
        padre = nodi[el["nodo"]["parent"]]["title"] if el["nodo"]["parent"] is not None else ""
        titolo_curr = _tit_elenco(el["titolo"], padre)
        elementi = [(k2, v) for k2, lst in el["anni"].items() for v in lst] + [(k_def, v) for v in el["elenco"]]
        for k2, v in elementi:
            if k2 > durata or (not programmi[p].get("solo_elenco")
                               and not any(s["prog"] == p for s in scelte.get(k2, {"nodi": []})["nodi"]) and k2 in scelte):
                continue
            w = dict(v)
            w.update(anno=k2, nodo=el["num"], curr=w["curriculum"] or w["label"] or titolo_curr, pool=True, d=0)
            voci.append(w)
    return voci, scelte
