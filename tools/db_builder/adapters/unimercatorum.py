"""Insegnamenti, docenti e libri dell'Universitas Mercatorum da www.unimercatorum.it.

- `/corsi-di-laurea` → pagine dei corsi (`/corsi-di-laurea/<corso>`);
- pagina del corso → "Piano di studi" in uno di due formati: un menu con i piani o, come su
  www.unipegaso.it (stesso gruppo e stesso sito, adapters/unipegaso.py), una tabella per ogni
  "piano di studi - indirizzo …" in una fisarmonica;
- pagina del corso → "Piano di studi": un menu con i piani (`<option value="677">L-18 -
  STATUTARIO</option>`, la classe e il profilo) e per ciascuno una tabella
  (`v-show="selectedPianoDiStudi === '677'"`) con anno, insegnamento (link al programma),
  SSD ("SECS-P/01 (ECON-01/A)": tra parentesi il settore nuovo) e CFU;
- Mercatorum (`_fetch_mercatorum`): un piano per curriculum (Statutario, Profilo …, coppie di lingue), ogni riga
  della tabella è una riga del corso: le righe omonime dello stesso anno («Insegnamento a scelta affine» due
  volte) restano distinte (numero o «(N CFU)» nel nome), la stessa riga in più piani è una riga sola con i
  curricula; ogni piano somma 180 CFU (120 le magistrali), non sempre 60 per anno. Docenti e libri già raccolti
  si riusano, si scaricano solo i programmi mai provati. Pegaso e San Raffaele Roma usano `fetch_ateneo` e le
  funzioni di lettura qui sotto, rimaste identiche;
- programma (`/programma/<codice>`, PDF) → "DOCENTE" e, in "MATERIALE DIDATTICO UTILIZZATO",
  il testo di riferimento suggerito dal docente (facoltativo, quindi consigliato).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import io
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unimercatorum.it"
ELENCO = r"https://www\.unimercatorum\.it/corsi-di-laurea/[\w-]+"
CLASSE = re.compile(r"\b(L(?:M)?(?:-|/)[\w/-]*\d[\w]*|LMG/01|L/GASTR)\b")


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_corso(s: str) -> tuple[str | None, dict[str, list[dict]]]:
    """Titolo del corso e piani: etichetta del piano → righe della tabella."""
    t = re.search(r"<h1[^>]*>(.*?)</h1>", s, re.S)
    piani = {}
    tabelle = []
    for v, lab in re.findall(r'<option value="(\d+)">\s*(.*?)\s*</option>', s, re.S):
        tab = re.search(rf"selectedPianoDiStudi === '{v}'\"\s*>(.*?)</table>", s, re.S)
        tabelle.append((lab, tab.group(1) if tab else ""))
    if not tabelle:  # fisarmonica (Pegaso): "piano di studi - indirizzo …" e la tabella
        tabelle = re.findall(r'<button[^>]*accordion-button[^>]*>\s*(piano di studi[^<]*?)\s*</button>.*?'
                             r'<table>(.*?)</table>', s, re.S | re.I)
    if not tabelle:  # fisarmonica (San Raffaele Roma): "<h4>L-22 - … [- PIANO STATUTARIO]</h4>" e la tabella
        tabelle = re.findall(r'<h4[^>]*>\s*(L[\w/-]*\s+-[^<]*?)\s*</h4>.*?<table[^>]*>(.*?)</table>', s, re.S)
    for lab, tab in tabelle:
        righe = []
        for r in re.findall(r"<tr>(.*?)</tr>", tab, re.S):
            c = re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", r, re.S)  # l'anno può essere in un <th>
            if len(c) < 4 or not re.fullmatch(r"\d", _testo(c[0])):
                continue
            link = re.search(r'href="([^"]+/(?:programma|insegnamenti)/[^"]+)"', c[1])
            ssd = _testo(c[2])
            nuovo = re.search(r"\(([A-Z]{2,5}-\d{2}/[A-Z])\)", ssd)
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[3]))
            v_cfu = float(cfu.group(0).replace(",", ".")) if cfu else None
            righe.append({"anno": int(_testo(c[0])), "nome": _testo(c[1]),
                          "url": html.unescape(link.group(1)) if link else None,
                          "ssd": nuovo.group(1) if nuovo else (ssd.split()[0] if ssd else None),
                          "cfu": int(v_cfu) if v_cfu is not None and v_cfu.is_integer() else v_cfu})
        if righe:
            piani[re.sub(r"\s+", " ", html.unescape(lab)).strip()] = righe
    return (_testo(t.group(1)) if t else None), piani


def _testo_grezzo(pdf) -> str:
    """Testo dai flussi di contenuto quando pypdf non riesce a interpretarli (i PDF di Pegaso hanno
    stringhe UTF-16 non codificate tra parentesi): una riga per blocco BT…ET, righe con la stessa
    ordinata unite."""
    righe: list[tuple[float, str]] = []
    for p in pdf.pages:
        dati = p.get_contents().get_data()
        for blocco in re.findall(rb"BT(.*?)ET", dati, re.S):
            y = re.search(rb"[\d.]+\s+([\d.]+)\s+Td", blocco)
            parti = []
            for s in re.findall(rb"\(((?:\\.|[^\\)])*)\)", blocco, re.S):
                s = re.sub(rb"\\(.)", rb"\1", s)
                parti.append(s.decode("utf-16-be", "ignore") if len(s) % 2 == 0 and s[:1] == b"\x00"
                             else s.decode("latin-1"))
            t = "".join(parti).strip()
            if t:
                yy = float(y.group(1)) if y else -1.0
                if righe and abs(righe[-1][0] - yy) < 1:
                    righe[-1] = (yy, righe[-1][1] + " " + t)
                else:
                    righe.append((yy, t))
    return "\n".join(t for _, t in righe)


def leggi_insegnamento(s: str) -> dict:
    """Pagina HTML dell'insegnamento (San Raffaele Roma): docente e "Testi consigliati"."""
    from .testi import html_to_lines
    righe = html_to_lines(s)
    docenti = []
    if "Docente" in righe:
        i = righe.index("Docente")  # etichette SSD, CFU, Docente e poi i valori nello stesso ordine
        v = righe[i + 3] if i + 3 < len(righe) else ""
        if v and not re.match(r"(?i)nessun", v) and len(v) < 80:
            docenti = [" ".join(x.split()) for x in re.split(r",|;| e ", v) if x.strip()]
    m = re.search(r"Testi consigliati\s*</[^>]+>(.*?)(?=<h[1-4]|$)", s, re.S)
    libri = []
    for lb in estrai_libri(m.group(1)) if m else []:
        lb["tipo"] = lb.get("tipo") or "consigliato"
        libri.append(lb)
    return {"docenti": docenti, "libri": libri}


def leggi_programma(data: bytes) -> dict:
    try:
        from pypdf import PdfReader
        pdf = PdfReader(io.BytesIO(data))
    except Exception:  # noqa: BLE001 - PDF illeggibile
        return {"docenti": [], "libri": []}
    try:
        testo = "\n".join(p.extract_text() or "" for p in pdf.pages)
    except Exception:  # noqa: BLE001
        try:
            testo = _testo_grezzo(pdf)
        except Exception:  # noqa: BLE001
            return {"docenti": [], "libri": []}
    docenti = []
    d = re.search(r"\nDOCENT[EI]\s*\n(.*)", testo, re.S)
    for riga in (d.group(1).splitlines() if d else [])[:8]:
        riga = riga.strip()
        if riga == "/**/":
            continue
        if not riga or riga.upper() == riga:  # titolo della sezione successiva: fine
            break
        # Pegaso: "Prof.ssa Nome Cognome: indirizzo@unipegaso.it"
        riga = re.sub(r"^Prof(?:\.ssa|\.)?\s+|\s*:\s*\S+@\S+$", "", riga)
        docenti += [" ".join(x.split()) for x in re.split(r",|;| e ", riga) if x.strip()]
    m = re.search(r"Testo di riferimento[^\n]*\n(.*?)(?:\nIl materiale didattico è sempre disponibile|\Z)", testo, re.S)
    libri = []
    if m:
        for lb in estrai_libri("<br>".join(x.strip(" è•-") for x in m.group(1).splitlines() if x.strip())):
            lb["tipo"] = lb.get("tipo") or "consigliato"
            libri.append(lb)
    return {"docenti": docenti, "libri": libri}


_ACCENTI = {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}
_PICCOLE = {"e", "di", "del", "della", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla", "il",
            "la", "lo", "le", "gli", "i", "ed", "nel", "nella", "sul", "tra", "dell", "dello", "nei", "ai", "alle", "o"}
_SIGLE = {"rcs", "p.a."}
# la classe «L-GASTR» sulla pagina del corso è «L/GASTR» per Universitaly
CLASSE_MERCATORUM = re.compile(r"\b(L(?:M)?(?:-|/)[\w/-]*\d[\w]*|LMG/01|L[-/]GASTR)\b")


def _classe(s: str) -> str:
    return s.replace("L-GASTR", "L/GASTR")


def _nome(s: str) -> str:
    """Nome di un insegnamento: senza barre inverse, accento al posto dell'apostrofo finale
    (`Abilita'` -> `Abilità`), spazi singoli."""
    s = s.replace("\\", "")
    s = re.sub(r"([A-Za-z]*[aeiou])'(?=\s|$|[,.;:)])",
               lambda m: m.group(1)[:-1] + _ACCENTI[m.group(1)[-1].lower()], s)
    return re.sub(r"\s+", " ", s).strip()


def _maiuscole(s: str) -> str:
    """Etichetta in maiuscolo -> iniziali maiuscole, con le parole piccole in minuscolo e le sigle (RCS, P.A.)."""
    out = []
    for k, w in enumerate(s.lower().split()):
        sub = re.match(r"(\w+')(\w.*)", w)  # «l'investigazione»: l'articolo resta minuscolo
        if w in _SIGLE:
            out.append(w.upper())
        elif sub and sub.group(1) != w:
            out.append(sub.group(1) + sub.group(2)[:1].upper() + sub.group(2)[1:])
        elif k and w in _PICCOLE:
            out.append(w)
        else:
            out.append("/".join("-".join(y[:1].upper() + y[1:] for y in x.split("-")) for x in w.split("/")))
    return " ".join(out)


def etichetta_piano(lab: str) -> str:
    """«L-20 - PROFILO COMUNICAZIONE E SOCIAL MEDIA PER LA P.A.» -> «Profilo Comunicazione e Social Media per la
    P.A.»; «L-12 - CINESE/FRANCESE» -> «Cinese/Francese». Le virgole dentro un nome (percorsi() separa i
    percorsi sulle virgole) sono trattini."""
    lab = re.sub(r"\s+", " ", lab.replace("\\", "")).strip()
    resto = re.sub(r"^\s*L(?:M)?[-/]?[\w/]*\s+-\s*", "", lab)
    resto = resto.replace(", ", " - ")
    if resto.isupper():
        resto = _maiuscole(resto)
    return _nome(resto)


def _righe_corso(piani: dict[str, list[dict]], url: str, oggi: str) -> list[dict]:
    """Righe del corso: una per (anno, nome, CFU, codice, n-esima occorrenza nel piano); curriculum = i piani in
    cui compare. Le righe omonime dello stesso anno («Insegnamento a scelta affine» due volte) restano distinte."""
    righe: dict[tuple, dict] = {}
    for k, voci in piani.items():
        visti: dict[tuple, int] = {}
        for v in voci:
            nome = _nome(v["nome"])
            base = (v["anno"], _norm(nome), v["cfu"], v["url"])
            visti[base] = visti.get(base, 0) + 1
            key = base + (visti[base],)
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": v["url"].rsplit("/", 1)[-1] if v["url"] else None, "nome": _titolo(nome),
                    "anno": v["anno"], "periodo": None, "cfu": v["cfu"], "ssd": v["ssd"],
                    "obbligatorio": False if re.search(r"(?i)a scelta", nome) else None,
                    "curriculum": None, "docenti": [], "url": v["url"] or url, "libri": [], "esami": [],
                    "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere", "_p": set(), "_n": key,
                }
            item["_p"].add(k)
    # righe omonime nello stesso anno senza codice: nomi distinti (build_db fonde i nomi uguali)
    per_nome: dict[tuple, list[dict]] = {}
    for i in righe.values():
        per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
    for gruppo in per_nome.values():
        if len(gruppo) < 2:
            continue
        gruppo.sort(key=lambda i: (i["cfu"] or 0, i["_n"][4], sorted(i["_p"])))
        cfu_diversi = len({i["cfu"] for i in gruppo}) > 1
        per_cfu: dict = {}
        for i in gruppo:
            per_cfu.setdefault(i["cfu"], []).append(i)
        for cfu, stesse in per_cfu.items():
            for n, i in enumerate(stesse, 1):
                if i["codice"]:
                    continue  # l'id viene dal codice
                suff = f" {n}" if len(stesse) > 1 else ""
                if cfu_diversi and isinstance(cfu, (int, float)):
                    suff += f" ({cfu:g} CFU)"
                i["nome"] += suff
    return list(righe.values())


def _vecchi(uid: str) -> tuple[dict[str, dict], set[str]]:
    """Docenti e libri già raccolti, per url della scheda, e gli url già provati (contributi precedenti)."""
    dati: dict[str, dict] = {}
    provati: set[str] = set()
    d = ROOT / "database" / "contrib" / "auto"
    for nome in (f"{uid}.json", f"{uid}_piani.json"):
        try:
            doc = json.loads((d / nome).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for c in doc.get("corsi") or []:
            for i in c.get("insegnamenti") or []:
                if not i.get("url"):
                    continue
                if nome == f"{uid}.json":
                    provati.add(i["url"])
                if i.get("libri") or i.get("docenti"):
                    dati.setdefault(i["url"], {"docenti": i.get("docenti") or [], "libri": i.get("libri") or []})
    return dati, provati


def _fetch_mercatorum(uid: str, corsi: list[dict], syllabus: bool, log, max_cds: int | None) -> dict:
    """Piani di studio di www.unimercatorum.it: un piano per curriculum (Statutario, Profilo …, coppie di
    lingue), ogni riga della tabella come riga del corso. Docenti e libri già raccolti si riusano; si
    scaricano solo i programmi mai provati."""
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(BASE + "/corsi-di-laurea")
    pagine = sorted({h.split("#")[0] for h in re.findall(rf'href="({ELENCO})', r.text if r else "")})
    sito = []
    for u in pagine:
        rc = c.get(u)
        if not rc:
            continue
        titolo, piani = leggi_corso(rc.text)
        classi = {_classe(m.group(1)) for k in list(piani) + [titolo or ""] for m in CLASSE_MERCATORUM.finditer(k)}
        if piani:
            sito.append({"url": u, "titolo": titolo, "piani": piani, "classi": classi})
    abbinati = []
    for corso in corsi:
        cand = [x for x in sito if corso.get("classe") in x["classi"]]
        if len(cand) > 1:
            cand = [x for x in cand if _norm(corso["nome"]) in _norm(x["titolo"] or "")
                    or _norm(x["titolo"] or "") in _norm(corso["nome"])] or \
                   [x for x in cand if (corso["tipo"] == "LM") == ("magistrale" in x["url"])]
        if len(cand) == 1:
            abbinati.append((corso, cand[0]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(sito)} corsi sul sito, {len(abbinati)} associati (su {len(corsi)})")
    out = []
    for corso, x in abbinati:
        etichette = {k: etichetta_piano(k) for k in x["piani"]}
        righe = _righe_corso(x["piani"], x["url"], oggi)
        for i in righe:
            ps = i.pop("_p")
            i.pop("_n")
            if len(etichette) > 1 and ps != set(etichette):
                i["curriculum"] = ", ".join(sorted(etichette[p] for p in ps))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": x["url"],
                    "curricula": sorted(etichette.values()) if len(etichette) > 1 else None,
                    "fonte": x["url"], "verificato_il": oggi, "insegnamenti": righe})
    jobs: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            if re.search(r"/(?:programma|insegnamenti)/", i["url"] or ""):
                jobs.setdefault(i["url"], []).append(i)
    vecchi, provati = _vecchi(uid)
    nuovi = {u for u in jobs if u not in provati}
    log(f"[{uid}] {sum(len(x['insegnamenti']) for x in out)} insegnamenti; programmi: {len(jobs)} "
        f"(già raccolti {sum(1 for u in jobs if u in vecchi)}, da scaricare {len(nuovi) if syllabus else 0})")

    def programma(u: str) -> int:
        d = {"docenti": [], "libri": []}
        if syllabus and u in nuovi:
            try:
                with c.lock:
                    c.requests += 1
                rp = c.s.get(u, timeout=90)
                if rp.content[:5] == b"%PDF-":
                    d = leggi_programma(rp.content)
                elif rp.ok and "html" in rp.headers.get("content-type", ""):
                    d = leggi_insegnamento(rp.text)
            except Exception:  # noqa: BLE001
                d = {"docenti": [], "libri": []}
        old = vecchi.get(u) or {}
        if not d["libri"]:
            d["libri"] = old.get("libri") or []
        if not d["docenti"]:
            d["docenti"] = old.get("docenti") or []
        for i in jobs[u]:
            i["docenti"] = d["docenti"]
            i["libri"] = d["libri"]
            i["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
        return len(d["libri"])

    with cf.ThreadPoolExecutor(4) as ex:
        trovati = sum(ex.map(programma, list(jobs)))
    log(f"[{uid}] libri: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unimercatorum.it, piani di studio e programmi "
                                                 "(adapters/unimercatorum.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def fetch_ateneo(uid: str = "unimercatorum", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print, base: str = BASE,
                 elenco: str = ELENCO, pagina_elenco: str = "/corsi-di-laurea") -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    if uid == "unimercatorum" and base == BASE:  # Mercatorum: un piano per curriculum (Pegaso resta com'era)
        return _fetch_mercatorum(uid, corsi, syllabus, log, max_cds)
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(base + pagina_elenco)
    pagine = sorted({h.split("#")[0] for h in re.findall(rf'href="({elenco})', r.text if r else "")})
    sito = []
    for u in pagine:
        rc = c.get(u)
        if not rc:
            continue
        titolo, piani = leggi_corso(rc.text)
        # la classe è nelle etichette dei piani ("L-18 - STATUTARIO") o nel titolo ("… L-5")
        classi = {m.group(1) for k in list(piani) + [titolo or ""] for m in CLASSE.finditer(k)}
        if piani:
            sito.append({"url": u, "titolo": titolo, "piani": piani, "classi": classi})
    # associazione: stessa classe; se più corsi con la classe, anche il nome
    abbinati = []
    for corso in corsi:
        cand = [x for x in sito if corso.get("classe") in x["classi"]]
        if len(cand) > 1:
            cand = [x for x in cand if _norm(corso["nome"]) in _norm(x["titolo"] or "")
                    or _norm(x["titolo"] or "") in _norm(corso["nome"])] or \
                   [x for x in cand if (corso["tipo"] == "LM") == ("magistrale" in x["url"])]
        if len(cand) == 1:
            abbinati.append((corso, cand[0]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(sito)} corsi sul sito, {len(abbinati)} associati (su {len(corsi)})")
    out = []
    for corso, x in abbinati:
        nomi_piani = {k: re.sub(r"(?i)^\s*(?:piano di studi|\S+)\s+-\s*(?:indirizzo\s+)?", "", k).strip().title()
                      for k in x["piani"]}
        righe: dict[str, dict] = {}
        for k, voci in x["piani"].items():
            for v in voci:
                key = f"{v['anno']}:{_norm(v['nome'])}"
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": v["url"].rsplit("/", 1)[-1] if v["url"] else None, "nome": _titolo(v["nome"]),
                        "anno": v["anno"], "periodo": None, "cfu": v["cfu"], "ssd": v["ssd"],
                        "obbligatorio": False if re.search(r"(?i)a scelta", v["nome"]) else None,
                        "curriculum": None, "docenti": [], "url": v["url"] or x["url"], "libri": [], "esami": [],
                        "fonte": x["url"], "verificato_il": oggi, "stato_libri": "da_aggiungere", "_p": set(),
                    }
                item["_p"].add(k)
        for i in righe.values():
            ps = i.pop("_p")
            if len(nomi_piani) > 1 and ps != set(nomi_piani):
                i["curriculum"] = ", ".join(sorted(nomi_piani[p] for p in ps))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": x["url"],
                    "curricula": sorted(nomi_piani.values()) if len(nomi_piani) > 1 else None,
                    "fonte": x["url"], "verificato_il": oggi, "insegnamenti": list(righe.values())})
    jobs: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            if re.search(r"/(?:programma|insegnamenti)/", i["url"] or ""):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] {sum(len(x['insegnamenti']) for x in out)} insegnamenti; programmi: {len(jobs) if syllabus else 0}")

    def programma(u: str) -> int:
        try:
            with c.lock:
                c.requests += 1
            rp = c.s.get(u, timeout=90)
            if rp.content[:5] == b"%PDF-":
                d = leggi_programma(rp.content)
            elif rp.ok and "html" in rp.headers.get("content-type", ""):
                d = leggi_insegnamento(rp.text)
            else:
                d = {"docenti": [], "libri": []}
        except Exception:  # noqa: BLE001
            return 0
        for i in jobs[u]:
            i["docenti"] = d["docenti"]
            i["libri"] = d["libri"]
            i["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
        return len(d["libri"])

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            trovati = sum(ex.map(programma, list(jobs)))
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unimercatorum.it, piani di studio e programmi "
                                                 "(adapters/unimercatorum.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
