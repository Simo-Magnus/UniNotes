"""Insegnamenti, docenti e libri dell'Università Telematica Pegaso da www.unipegaso.it.

Stesso gruppo e stesso sito dell'Universitas Mercatorum (vedi adapters/unimercatorum.py): pagine dei corsi
`/lauree-triennali/<corso>`, `/lauree-magistrali/<corso>`, `/lauree-magistrali-ciclo-unico/<corso>` con una fisarmonica
«piano di studi - indirizzo …» (o «- statutario») per curriculum e, in ogni piano, una tabella con anno, insegnamento
(link al programma in PDF `/pdf/programma/<codice>`), SSD e CFU. Dal modulo comune (`um`) si usano solo le funzioni
di lettura dei programmi e di normalizzazione dei nomi (`um._nome`, `um._maiuscole`, `um._vecchi`,
`um.leggi_programma`); la lettura delle tabelle è qui.

- un piano per curriculum, ogni riga della tabella è una riga del corso: la stessa riga in più piani (stesso anno, nome,
  CFU e codice) è una riga sola con i curricula in cui compare; le righe omonime dello stesso piano («Insegnamento a
  scelta» tre volte) restano distinte (numero nel nome); lo stesso codice con CFU o nome diversi nello stesso anno
  (tra curricula) resta distinto;
- «Insegnamento a scelta caratterizzante» con un elenco puntato di alternative (nessun codice, SSD per alternativa) è
  una scelta da `cfu` CFU: nome «Scelta caratterizzante [n]: alternativa 1; alternativa 2; …» (la riga ripetuta n volte
  nel piano è una scelta per ogni ripetizione, il numero sta all'inizio perché build_db tronca lo slug dell'id a 40
  caratteri);
- tutte le righe «a scelta» sono `obbligatorio: false`; ogni curriculum somma 180 CFU (120 le magistrali, 300 il ciclo
  unico), non sempre 60 per anno (sul sito alcuni anni hanno 54, 57, 63, 72 CFU);
- la classe della pagina («LMG-01») è quella di Universitaly («LMG/01»);
- docenti e libri già raccolti (database/contrib/auto) si riusano, si scaricano solo i programmi mai provati; dai
  nomi dei docenti si tolgono gli indirizzi email.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import re
import time

from . import unimercatorum as um
from .unibo import Client, _testo, _titolo

BASE = "https://www.unipegaso.it"
ELENCO = r"https://www\.unipegaso\.it/(?:lauree|laurea)[\w-]*/[\w-]+"
CLASSE = re.compile(r"\b(LMG[-/]\d+|L(?:M)?-\d+[A-Z]?)\b")
_SIGLE = {"Esg": "ESG"}
_EN_PICCOLE = {"And", "The", "Of"}


def _classe(s: str) -> str:
    return re.sub(r"^LMG[-/]", "LMG/", s)


def _unescape(s: str) -> str:
    """Il sito scrive alcune entità due volte (`&amp;#8217;`): `_testo` ne toglie una sola."""
    return re.sub(r"\s+", " ", html.unescape(html.unescape(s))).strip()


def _opzione(s: str) -> str:
    """«Diritto privato (SSD IUS/01 (GIUR-01/A))» → «Diritto privato (GIUR-01/A)»."""
    return _unescape(re.sub(r"\(SSD [^()]*\(([^()]*)\)\)", r"(\1)", s))


def leggi_corso(s: str) -> tuple[str | None, dict[str, list[dict]]]:
    """Titolo del corso e piani: etichetta del piano → righe della tabella (con `opzioni` se la riga ha un elenco
    puntato di alternative)."""
    t = re.search(r"<h1[^>]*>(.*?)</h1>", s, re.S)
    piani: dict[str, list[dict]] = {}
    tabelle = re.findall(r'<button[^>]*accordion-button[^>]*>\s*(piano di studi[^<]*?)\s*</button>.*?'
                         r'<table>(.*?)</table>', s, re.S | re.I)
    for lab, tab in tabelle:
        righe = []
        for r in re.findall(r"<tr>(.*?)</tr>", tab, re.S):
            c = re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", r, re.S)
            if len(c) < 4 or not re.fullmatch(r"\d", _testo(c[0])):
                continue
            link = re.search(r'href="([^"]+/(?:programma|insegnamenti)/[^"]+)"', c[1])
            opzioni = [_opzione(_testo(x)) for x in re.findall(r"<li[^>]*>(.*?)</li>", c[1], re.S)]
            testa = _unescape(_testo(re.sub(r"<ul.*?</ul>", " ", c[1], flags=re.S)))
            ssd = _testo(c[2])
            nuovo = re.search(r"\(([A-Z]{2,5}-\d{2}/[A-Z])\)", ssd)
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[3]))
            v_cfu = float(cfu.group(0).replace(",", ".")) if cfu else None
            righe.append({"anno": int(_testo(c[0])), "nome": testa, "opzioni": opzioni,
                          "url": html.unescape(link.group(1)) if link else None,
                          "ssd": nuovo.group(1) if nuovo else (ssd.split()[0] if ssd else None),
                          "cfu": int(v_cfu) if v_cfu is not None and v_cfu.is_integer() else v_cfu})
        if righe:
            piani[re.sub(r"\s+", " ", html.unescape(lab)).strip()] = righe
    return (_unescape(_testo(t.group(1))) if t else None), piani


def etichetta_piano(lab: str) -> str:
    """«piano di studi - indirizzo filosofie comparate, dell'asia e del medio oriente» → «Filosofie Comparate - dell'Asia
    e del Medio Oriente»; «piano di studi - statutario» → «Statutario». Le virgole dentro un nome (percorsi() separa i
    percorsi sulle virgole) sono trattini."""
    resto = re.sub(r"(?i)^\s*piano di studi\s*-\s*(?:indirizzo\s+)?", "", lab).strip()
    resto = resto.replace(", ", " - ")
    resto = um._maiuscole(resto) if resto.islower() else resto
    resto = " ".join(_SIGLE.get(w, w.lower() if w in _EN_PICCOLE and k else w) for k, w in enumerate(resto.split()))
    return um._nome(resto)


def _parti_nome(v: dict, n: int | None) -> tuple[str, str]:
    """Nome della riga in due parti (testa, elenco): quello della tabella con il numero se la riga è ripetuta nel piano;
    una scelta con elenco di alternative è «Scelta caratterizzante [n]: alt 1; alt 2»."""
    nome = um._nome(v["nome"])
    if v["opzioni"]:
        testa = re.sub(r"(?i)^insegnamento a scelta\b", "Scelta", nome)
        return f"{testa}{f' {n}' if n else ''}", "; ".join(um._nome(o) for o in v["opzioni"])
    return f"{nome}{f' {n}' if n else ''}", ""


def _nome_riga(v: dict, n: int | None) -> str:
    t, o = _parti_nome(v, n)
    return f"{t}: {o}" if o else t


def righe_corso(piani: dict[str, list[dict]], url: str, oggi: str) -> list[dict]:
    """Righe del corso: una per (anno, nome, CFU, codice, n-esima occorrenza nel piano); curriculum = i piani in cui
    compare."""
    ripetute: dict[tuple, int] = {}  # quante volte compare nello stesso piano la stessa riga (per numerarla)
    for voci in piani.values():
        c: dict[tuple, int] = {}
        for v in voci:
            b = (v["anno"], um._norm(_nome_riga(v, None)), v["cfu"], v["url"])
            c[b] = c.get(b, 0) + 1
        for b, n in c.items():
            ripetute[b] = max(ripetute.get(b, 0), n)
    righe: dict[tuple, dict] = {}
    for k, voci in piani.items():
        visti: dict[tuple, int] = {}
        for v in voci:
            base = (v["anno"], um._norm(_nome_riga(v, None)), v["cfu"], v["url"])
            visti[base] = visti.get(base, 0) + 1
            key = base + (visti[base],)
            item = righe.get(key)
            if not item:
                testa, elenco = _parti_nome(v, visti[base] if ripetute[base] > 1 else None)
                a_scelta = bool(v["opzioni"]) or bool(re.search(r"(?i)a scelta", v["nome"]))
                item = righe[key] = {
                    "codice": v["url"].rsplit("/", 1)[-1] if v["url"] else None, "nome": _titolo(testa),
                    "anno": v["anno"], "periodo": None, "cfu": v["cfu"], "ssd": v["ssd"],
                    "obbligatorio": False if a_scelta else None,
                    "curriculum": None, "docenti": [], "url": v["url"] or url, "libri": [], "esami": [],
                    "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere", "_p": set(), "_n": key,
                    "_e": elenco,
                }
            item["_p"].add(k)
    righe_l = list(righe.values())
    _disambigua(righe_l)
    for i in righe_l:
        e = i.pop("_e")
        if e:
            i["nome"] = f"{i['nome']}: {e}"
    return righe_l


def _disambigua(righe: list[dict]) -> None:
    """build_db tronca lo slug dell'id a 40 caratteri e fonde le righe senza codice dello stesso anno con lo stesso
    slug: righe diverse con lo stesso inizio di nome (stesso nome con CFU diversi tra i curricula, due elenchi di
    alternative che cominciano allo stesso modo) hanno il CFU («Insegnamento a scelta (9 CFU)») o la «variante A/B»
    subito dopo la testa del nome."""
    from build_db import slug
    gruppi: dict[tuple, list[dict]] = {}
    for i in righe:
        if not i["codice"]:
            gruppi.setdefault((i["anno"], slug(i["nome"] + ": " + i["_e"] if i["_e"] else i["nome"], 40)), []).append(i)
    for g in gruppi.values():
        if len(g) < 2:
            continue
        g.sort(key=lambda i: (i["cfu"] or 0, len(i["_e"]), i["_e"], sorted(i["_p"])))
        if len({i["cfu"] for i in g}) > 1:
            for i in g:
                i["nome"] += f" ({i['cfu']:g} CFU)" if isinstance(i["cfu"], (int, float)) else ""
        else:
            for n, i in enumerate(g):
                i["nome"] += f" (variante {chr(65 + n)})"


def collisioni(righe: list[dict]) -> list[str]:
    """Righe dello stesso anno che build_db fonderebbe (stesso slug di codice o nome a 40 caratteri) pur essendo
    diverse: elenco dei casi."""
    from build_db import slug
    visti: dict[tuple, dict] = {}
    out = []
    for i in righe:
        k = (i["anno"], slug(i["codice"] or i["nome"], 40))
        if k in visti:
            a = visti[k]
            out.append(f"anno {i['anno']}: «{a['nome']}» ({a['codice']}, {a['cfu']} CFU) e «{i['nome']}» "
                       f"({i['codice']}, {i['cfu']} CFU) → {k[1]}")
        else:
            visti[k] = i
    return out


def _pulisci_docenti(docenti: list[str]) -> list[str]:
    """Senza l'indirizzo email: «Nome Cognome (nome.cognome@unipegaso.it)» → «Nome Cognome»."""
    out = []
    for d in docenti or []:
        d = re.sub(r"\s*[(\[<]?\S+@\S+[)\]>]?\s*", " ", d).strip(" :,;")
        if d and d not in out:
            out.append(d)
    return out


def fetch_ateneo(uid: str = "unipegaso", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((um.ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    pagine: set[str] = set()
    for extra in ("/lauree", "/lauree-triennali", "/lauree-magistrali", "/lauree-magistrali-ciclo-unico"):
        r = c.get(BASE + extra)
        pagine |= {h.split("#")[0] for h in re.findall(rf'href="({ELENCO})', r.text if r else "")}
    sito = []
    for u in sorted(pagine):
        rc = c.get(u)
        if not rc:
            continue
        titolo, piani = leggi_corso(rc.text)
        classi = {_classe(m.group(1)) for m in CLASSE.finditer(titolo or "")}
        if piani:
            sito.append({"url": u, "titolo": titolo, "piani": piani, "classi": classi})
    abbinati = []
    for corso in corsi:
        cand = [x for x in sito if corso.get("classe") in x["classi"]]
        if len(cand) > 1:
            cand = [x for x in cand if um._norm(corso["nome"]) in um._norm(x["titolo"] or "")
                    or um._norm(x["titolo"] or "") in um._norm(corso["nome"])] or \
                   [x for x in cand if (corso["tipo"] == "LM") == ("magistrale" in x["url"])]
        if len(cand) == 1:
            abbinati.append((corso, cand[0]))
        else:
            log(f"[{uid}] corso senza piano sul sito: {corso['id']} ({len(cand)} pagine con la classe)")
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(sito)} corsi sul sito, {len(abbinati)} associati (su {len(corsi)})")
    out = []
    for corso, x in abbinati:
        etichette = {k: etichetta_piano(k) for k in x["piani"]}
        righe = righe_corso(x["piani"], x["url"], oggi)
        for i in righe:
            ps = i.pop("_p")
            i.pop("_n")
            if len(etichette) > 1 and ps != set(etichette):
                i["curriculum"] = ", ".join(sorted(etichette[p] for p in ps))
        for msg in collisioni(righe):
            log(f"[{uid}] ATTENZIONE {corso['id']}: {msg}")
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": x["url"],
                    "curricula": sorted(etichette.values()) if len(etichette) > 1 else None,
                    "fonte": x["url"], "verificato_il": oggi, "insegnamenti": righe})
    jobs: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            if re.search(r"/(?:programma|insegnamenti)/", i["url"] or ""):
                jobs.setdefault(i["url"], []).append(i)
    vecchi, provati = um._vecchi(uid)
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
                    d = um.leggi_programma(rp.content)
            except Exception:  # noqa: BLE001
                d = {"docenti": [], "libri": []}
        old = vecchi.get(u) or {}
        if not d["libri"]:
            d["libri"] = old.get("libri") or []
        d["docenti"] = _pulisci_docenti(d["docenti"] or old.get("docenti") or [])
        for i in jobs[u]:
            i["docenti"] = d["docenti"]
            i["libri"] = d["libri"]
            i["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
        return len(d["libri"])

    with cf.ThreadPoolExecutor(4) as ex:
        trovati = sum(ex.map(programma, list(jobs)))
    log(f"[{uid}] libri: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unipegaso.it, piani di studio e programmi "
                                                 "(adapters/unipegaso.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
