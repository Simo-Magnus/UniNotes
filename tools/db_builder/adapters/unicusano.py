"""Insegnamenti e docenti dell'Università Niccolò Cusano da www.unicusano.it.

Ogni piano di studi è una pagina `/<area>/piano-di-studi-…` (nella sitemap dei corsi, `corsi_cpt-sitemap.xml`; il link
«Piano di Studi» della pagina del corso a volte punta al piano di un altro corso, come per LM-56 che rimanda al piano di
L-18). La pagina dichiara nella tabella iniziale la «Classe di Laurea» e il «Curriculum»; per l'a.a. («A.A. 2026-2027»)
ha una tabella con le righe «PRIMO ANNO», «SECONDO ANNO», … e per ogni esame nome (seguito dai docenti, link alle pagine
`ricerca.unicusano.it/author/<nome-cognome>/`), SSD 2015, SSD 2024 e CFU, e una riga «Totale CFU» (60) per anno.

- un corso ha un piano per curriculum (L-7, L-8, L-9, L-19, L-40, LM-23, LM-33, LM-51, LM-52, LM-56, LM-88, LMG/01): ogni
  piano è un percorso; una riga uguale in tutti i piani (stesso anno, nome e CFU) vale per tutti, le altre hanno i propri
  percorsi. Il piano di LM-56 «Mercati globali e innovazione digitale» è fermo all'a.a. 2024/25 (non c'è l'a.a. 2026/27) e
  non si legge;
- i piani si associano al corso del database per classe di laurea (non per il link della pagina del corso);
- «Esame a scelta» è un credito libero (obbligatorio=false); due righe con lo stesso nome nello stesso anno non si fondono
  (CFU nel nome se diversi tra piani o righe, numero altrimenti: «Esame a scelta 1», «Esame a scelta 2»);
- le righe con più insegnamenti («una materia a scelta tra», «in alternativa tra loro», «Materia opzionale», «Due esami
  opzionali a scelta tra», «18 crediti da acquisire tra … (6+6+6)») diventano un insegnamento a scelta per opzione, con
  i CFU dell'esame: quelli scritti («1 esame da 12 cfu», «6+6+6»), il totale della riga per una sola scelta, il totale
  diviso per il numero di esami («Due esami … 12» = 2 da 6, deduzione) altrimenti;
- «P<a>rogettazione …» (la prima lettera fuori dal link nel codice HTML) è un solo nome;
- le tabelle «Materia a scelta» (elenco delle materie tra cui scegliere gli «Esame a scelta») non si leggono: la fonte
  non dice in quale anno si scelgono.
I programmi degli insegnamenti sono sulla piattaforma e-learning (con accesso): niente libri.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
SITEMAP = "https://www.unicusano.it/corsi_cpt-sitemap.xml"
NUMERI = {"un": 1, "uno": 1, "una": 1, "1": 1, "due": 2, "2": 2, "tre": 3, "3": 3}

# Curriculum dei piani la cui intestazione («Curriculum: …») è assente o copiata da un altro piano (verificato sulla
# pagina): slug della pagina -> curriculum del titolo della tabella.
CURRICULUM = {
    "piano-di-studi-classe-l-7-edilizia": "Edilizia",
    "piano-di-studi-ingegneria-civile-l-7-curriculum-ambiente-e-sostenibilita": "Ambiente e sostenibilità",
    "piano-di-studi-classe-l-9-curriculum-biomedico": "Biomedico",
    "piano-di-studi-giurisprudenza-lmg-01-indirizzo-giurista-dimpresa": "Giurista d’impresa",
    "piano-di-studi-giurisprudenza-lmg-01": "Generale",
}
# piani da non leggere: fermi a un a.a. passato anche se la pagina è ancora online
IGNORA = {"piano-di-studi-scienze-economiche-lm-56"}

DEDUZIONI: list[str] = []  # CFU per esame calcolati dal totale della riga (non scritti sulla fonte)


def _slug(url: str) -> str | None:
    m = re.search(r"ricerca\.unicusano\.it/author/([a-z0-9-]+)", url)
    return m.group(1) if m else None


def classe_norm(c: str | None) -> str:
    """«L-05» -> L-5, «LMG/01» -> LMG-1, «LM-56» -> LM-56."""
    m = re.match(r"(?i)\s*(LMG|LM|L)\s*[-/]?\s*0*(\d+)", c or "")
    return f"{m.group(1).upper()}-{int(m.group(2))}" if m else ""


def nome_docente(c: Client, slug: str) -> str:
    """Nome dalla pagina del docente (titolo "Nome Cognome – Anagrafica Docenti…"): lo slug
    perde apostrofi e spazi ("marino-damore" è Marino D'Amore)."""
    r = c.get(f"https://ricerca.unicusano.it/author/{slug}/")
    t = re.search(r"<title>(.*?)</title>", r.text if r else "", re.S)
    nome = html.unescape(t.group(1)).split("–")[0].strip() if t else ""
    return nome or " ".join(w.capitalize() for w in slug.split("-"))


def _pulisci(nome: str) -> str:
    nome = html.unescape(nome).replace(" ", " ")
    nome = re.sub(r"^[\s–—-]+|[\s–—-]+$", "", nome)
    return re.sub(r"\s+", " ", nome).strip()


def _nome_e_docenti(cella: str) -> tuple[str, list[str]]:
    """Nome dell'esame e docenti (slug) di una cella: il nome è il testo prima del primo link («Fortuna – Miglio» sono
    i docenti); se il testo inizia col link è il testo del link (la pagina del docente). Una lettera sola prima del
    link senza spazio («P<a>rogettazione …») fa parte del nome."""
    docenti = [x for x in (_slug(h) for h, _ in re.findall(r'<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>', cella, re.S)) if x]
    primo = re.search(r'<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>', cella, re.S)
    if not primo:
        return _pulisci(_testo(cella)), docenti
    prima = _pulisci(_testo(cella[:primo.start()]))
    testo_link = _testo(primo.group(2))
    if prima and re.search(r"\w$", cella[:primo.start()].replace("&nbsp;", " ")) and testo_link[:1].islower():
        return _pulisci(prima + testo_link), docenti  # nome spezzato dal link
    if prima:
        return prima, docenti
    # nessun testo prima del link: il nome è il testo del link («<a>English for Business</a>»), più il testo che lo
    # segue fino al link successivo se non inizia con un trattino («<a>Pedagogia sociale</a> e laboratorio <a>Faraoni</a>»)
    dopo = cella[primo.end():]
    seguito = re.split(r"<a\s", dopo, 1)[0]
    seguito = _pulisci(_testo(seguito)) if not re.match(r"[\s ]*(&nbsp;)*[\s]*(–|-|&#8211;)", seguito) else ""
    return _pulisci(f"{testo_link} {seguito}"), docenti


def _cfu(testo: str) -> int | float | None:
    m = re.search(r"\d+(?:[.,]\d+)?", testo or "")
    if not m:
        return None
    v = float(m.group(0).replace(",", "."))
    return int(v) if v.is_integer() else v


def _ssd_token(testo: str) -> list[str]:
    """Settori (2024, «ECON-06/A») di un testo; la fonte scrive anche «IMIS 01/A», «FICP -01/A», «IINF‑05/A»."""
    t = re.sub("[‐-―−]", "-", testo or "")
    return [re.sub(r"[\s-]+", "-", x) for x in re.findall(r"[A-Z]{3,5}[\s-]+\d{2}/[A-Z]", t)]


def _ssd_opzioni(cella: str, n: int) -> list[str | None]:
    """SSD (2024) delle n opzioni di una riga: uno per riga se i settori sono n, lo stesso per tutte se è uno solo."""
    tok = _ssd_token(_testo(cella))
    if len(tok) == n:
        return list(tok)
    if tok and len(set(tok)) == 1:
        return [tok[0]] * n
    return [None] * n


def _cfu_per_esame(testata: str, cella_cfu: str, n_opzioni: int, dove: str) -> int | float | None:
    """CFU di ciascuna opzione di una riga con più esami. Scritti: «1 esame da 12 cfu», «18 (6+6+6)». Altrimenti il
    totale della riga è per una sola scelta, o diviso per il numero di esami scelti («Due esami …») (deduzione)."""
    tot = _cfu(cella_cfu)
    m = re.search(r"\((\d+(?:\s*\+\s*\d+)+)\)", cella_cfu)
    if m:
        parti = {int(x) for x in re.findall(r"\d+", m.group(1))}
        if len(parti) == 1:
            return parti.pop()
    m = re.search(r"(?i)\b\d+\s+esam[ei]\s+da\s+(\d+)", testata)
    if m:
        return int(m.group(1))
    m = re.search(r"(?i)\b(un|uno|una|1|due|2|tre|3)\s+(?:esam[ei]|materi[ae])", testata)
    scelte = NUMERI[m.group(1).lower()] if m else 1
    if scelte > 1 and tot is not None:
        v = tot / scelte
        DEDUZIONI.append(f"{dove}: «{testata}» {tot:g} CFU / {scelte} esami = {v:g} a esame")
        return int(v) if float(v).is_integer() else v
    return tot


def leggi_piano(s: str, anno: int, dove: str = "") -> tuple[list[dict], dict[int, float]]:
    """Esami del piano per l'a.a. `anno` (le tabelle con le righe «PRIMO ANNO», … della sezione «A.A. anno-anno+1») e il
    totale CFU dichiarato per ogni anno."""
    m = next((x for x in re.finditer(rf"A\.A\.\s*{anno}\s*[-/]\s*{anno + 1}(.*?)(?=A\.A\.\s*\d{{4}}\s*[-/]\s*\d{{4}}"
                                     rf"|<footer|$)", s, re.S) if re.search(r"PRIMO\s+ANNO", x.group(1), re.I)), None)
    if not m:
        return [], {}
    out: list[dict] = []
    totali: dict[int, float] = {}
    gruppo = 0
    for tab in re.findall(r"<table.*?</table>", m.group(1), re.S):
        if not re.search(r"(?i)\bPRIMO\s+ANNO\b", _testo(tab)):  # solo la tabella del piano
            continue
        k = None
        for riga in re.findall(r"<tr.*?</tr>", tab, re.S):
            celle = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", riga, re.S)
            testo = _testo(riga)
            a = re.fullmatch(r"(?i)(PRIMO|SECONDO|TERZO|QUARTO|QUINTO|SESTO)\s+ANNO", testo)
            if a:
                k = ANNI[a.group(1).lower()]
                continue
            if len(celle) < 3 or not k:
                continue
            c0, c_cfu = celle[0], celle[-1]
            if re.match(r"(?i)\s*totale", _testo(c0)):
                v = _cfu(_testo(c_cfu))
                if v is not None:
                    totali[k] = v
                continue
            ssd_cella = celle[-2] if len(celle) >= 4 else ""
            base = {"anno": k}
            linee = [x for x in re.split(r"<br\s*/?>", c0) if _pulisci(_testo(x))]
            testata = None
            opzioni: list[str] = []
            if len(linee) >= 2:
                # riga con più insegnamenti: una testata («una materia a scelta tra») e un'opzione per riga, oppure
                # «A / oppure / B»
                if any(_pulisci(_testo(x)).lower() == "oppure" for x in linee):
                    opzioni = [x for x in linee if _pulisci(_testo(x)).lower() != "oppure"]
                else:
                    testata = _pulisci(_testo(linee[0]))
                    opzioni = linee[1:]
            if opzioni:
                per = _cfu_per_esame(testata or "in alternativa", _testo(c_cfu), len(opzioni), f"{dove} anno {k}")
                ssd = _ssd_opzioni(ssd_cella, len(opzioni))
                gruppo += 1
                for o, sd in zip(opzioni, ssd):
                    nome, doc = _nome_e_docenti(o)
                    if nome:
                        out.append(dict(base, nome=_titolo(nome), docenti=doc, cfu=per, ssd=sd, a_scelta=True,
                                        gruppo=gruppo, cfu_riga=_cfu(_testo(c_cfu))))
                continue
            nome, doc = _nome_e_docenti(c0)
            if not nome:
                continue
            sd = _ssd_token(_testo(ssd_cella))
            out.append(dict(base, nome=_titolo(nome), docenti=doc, cfu=_cfu(_testo(c_cfu)),
                            ssd=sd[0] if sd else None,
                            a_scelta=bool(re.search(r"(?i)a scelta|opzional", nome))))
    return out, totali


def _intestazione(s: str) -> tuple[str, str | None]:
    """Classe di laurea (normalizzata) e curriculum dichiarati nella tabella iniziale della pagina."""
    t = _testo(s)
    c = re.search(r"Classe di Laurea\s+([A-Z]+\s*[-/]?\s*\d+)", t)
    cu = re.search(r"Curriculum:\s*(.*?)\s*Anno Accademico", t)
    cur = _pulisci(cu.group(1)) if cu else ""
    return classe_norm(c.group(1) if c else ""), (None if cur in ("", "-") else cur.replace(",", " –").replace("'", "’"))


def _nomi_univoci(righe: list[dict], piani: list[str]) -> None:
    """Nome distinto per le righe che la fonte ripete: due righe di un piano con lo stesso nome nello stesso anno non si
    fondono (numero se i CFU sono uguali), lo stesso nome con CFU diversi nello stesso anno (tra piani o righe) porta i
    CFU tra parentesi. Modifica `righe` (campo `nome`)."""
    cfu_per: dict[tuple, set] = {}
    for r in righe:
        cfu_per.setdefault((r["anno"], r["nome"].lower()), set()).add(r["cfu"])
    for r in righe:
        if len(cfu_per[(r["anno"], r["nome"].lower())]) > 1 and r["cfu"] is not None:
            r["nome"] = f"{r['nome']} ({r['cfu']:g} CFU)"
    for p in piani:
        per_nome: dict[tuple, list[dict]] = {}
        for r in righe:
            if r["piano"] == p:
                per_nome.setdefault((r["anno"], r["nome"].lower()), []).append(r)
        for lst in per_nome.values():
            if len(lst) > 1:
                for n, r in enumerate(lst, 1):
                    r["nome"] = f"{r['nome']} {n}"


def fetch_ateneo(uid: str = "unicusano", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if "unicusano.it/" in (x.get("url") or "")]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    DEDUZIONI.clear()

    # piani di studio: sitemap dei corsi + link «Piano di Studi» della pagina di ogni corso
    urls: list[str] = []
    r = c.get(SITEMAP)
    if r:
        urls += [u for u in re.findall(r"<loc>([^<]+)</loc>", r.text) if "/piano-di-studi" in u]
    pagine_corso: dict[str, str] = {}
    for corso in corsi:
        rc = c.get(corso["url"])
        if rc:
            pagine_corso[corso["id"]] = rc.text
            for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', rc.text, re.S):
                if "piano-di-studi" in h and "piano di studi" in _testo(t).lower() and h not in urls:
                    urls.append(h)
    urls = [u for u in dict.fromkeys(urls) if u.rstrip("/").rsplit("/", 1)[-1] not in IGNORA]

    def scarica(u: str):
        rp = c.get(u)
        if not rp:
            return None
        classe, cur = _intestazione(rp.text)
        slug = u.rstrip("/").rsplit("/", 1)[-1]
        voci, totali = leggi_piano(rp.text, anno, slug)
        return {"url": u, "slug": slug, "classe": classe, "curriculum": CURRICULUM.get(slug, cur), "voci": voci,
                "totali": totali}

    with cf.ThreadPoolExecutor(4) as ex:
        pagine = [p for p in ex.map(scarica, urls) if p and p["voci"]]
    per_classe: dict[str, list[dict]] = {}
    for p in pagine:
        per_classe.setdefault(p["classe"], []).append(p)

    def build(corso: dict) -> dict | None:
        piani = per_classe.get(classe_norm(corso.get("classe")))
        if not piani:
            return None
        piani = sorted(piani, key=lambda p: p["url"])
        for p in piani:  # il piano senza curriculum, se ce ne sono altri, è il «generale»
            if len(piani) > 1 and not p["curriculum"]:
                p["curriculum"] = "Generale"
        nomi_piano = [p["curriculum"] or p["slug"] for p in piani]
        righe_tutte: list[dict] = []
        for p, np_ in zip(piani, nomi_piano):
            for v in p["voci"]:
                righe_tutte.append(dict(v, piano=np_, url=p["url"]))
        _nomi_univoci(righe_tutte, nomi_piano)
        righe: dict[tuple, dict] = {}
        for v in righe_tutte:
            key = (v["anno"], v["nome"].lower(), v["cfu"], v["a_scelta"])
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": v["ssd"], "obbligatorio": not v["a_scelta"], "curriculum": None,
                    "docenti": [], "url": v["url"], "libri": [], "esami": [], "fonte": v["url"], "verificato_il": oggi,
                    "stato_libri": "da_aggiungere", "_c": set(),
                }
            item["docenti"] = sorted(set(item["docenti"]) | set(v["docenti"]))
            item["_c"].add(v["piano"])
            if not item["ssd"]:
                item["ssd"] = v["ssd"]
        for i in righe.values():
            cs = i.pop("_c")
            if len(piani) > 1 and cs != set(nomi_piano):
                i["curriculum"] = ", ".join(sorted(cs))
        # controllo: i CFU di ogni anno e piano contro il «Totale CFU» della pagina
        for p, np_ in zip(piani, nomi_piano):
            for k, tot in sorted(p["totali"].items()):
                somma = _somma_anno(p["voci"], k)
                if abs(somma - tot) > 0.01:
                    log(f"[{uid}]   {corso['id']} {np_} anno {k}: letti {somma:g} CFU, totale della pagina {tot:g}")
        curricula = sorted({p["curriculum"] for p in piani if p["curriculum"]})
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": corso["url"],
                "curricula": curricula if len(piani) > 1 else None, "fonte": piani[0]["url"], "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    out = []
    for corso in corsi:
        try:
            x = build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            continue
        if x:
            out.append(x)
        else:
            log(f"[{uid}]   corso {corso.get('id')} senza piano per l'a.a. {anno}/{anno + 1}")
    slugs = sorted({d for x in out for i in x["insegnamenti"] for d in i["docenti"]})
    with cf.ThreadPoolExecutor(4) as ex:
        nomi = dict(zip(slugs, ex.map(lambda x: nome_docente(c, x), slugs)))
    for x in out:
        for i in x["insegnamenti"]:
            i["docenti"] = sorted({nomi[d] for d in i["docenti"]})
    for d in DEDUZIONI:
        log(f"[{uid}]   CFU per esame calcolato: {d}")
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"{len(pagine)} piani; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unicusano.it, Piano di Studi (adapters/unicusano.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def _somma_anno(voci: list[dict], k: int) -> float:
    """CFU dell'anno k come li conta il «Totale CFU» della pagina: un esame per riga; di una riga con più opzioni solo
    quanti ne sceglie lo studente (qui: le opzioni di una stessa riga si sono già separate, quindi si contano una volta
    sola per riga)."""
    tot = 0.0
    visti: set[int] = set()
    for v in voci:
        if v["anno"] != k:
            continue
        g = v.get("gruppo")
        if g is not None:
            if g in visti:
                continue
            visti.add(g)
            tot += v.get("cfu_riga") or 0
        else:
            tot += v["cfu"] or 0
    return tot
