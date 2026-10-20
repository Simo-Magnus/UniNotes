"""Insegnamenti, docenti e libri dell'Università Telematica San Raffaele Roma da www.uniroma5.it.

Stesso gruppo e stesso sito di Mercatorum e Pegaso (vedi adapters/unimercatorum.py, da cui si
usano il lettore delle pagine dei corsi e quello delle schede): pagine dei corsi `/triennale/<corso>`
e `/magistrale/<corso>` con i piani in una fisarmonica ("L-22 - … - PIANO STATUTARIO": una tabella
Anno / Insegnamento / SSD / CFU per piano) e le schede HTML degli insegnamenti
(`/insegnamenti/<codice>`: docente, "Testi consigliati").

Il piano di ogni corso somma 180 CFU (120 le magistrali), ma non con 60 CFU per anno (57+55+68 a Scienze
biologiche): le righe sono quelle della tabella, anno per anno, senza spostare nulla. Rispetto alla
lettura generica di unimercatorum.py:

- righe con lo stesso nome nello stesso anno e nello stesso piano (due «Insegnamento a scelta» da 6 o
  da 9 CFU, «Insegnamento a scelta affini» due volte, ...) restano righe distinte: prima si fondevano e
  il piano perdeva 6-9 CFU a scelta per anno. Si distinguono con il numero («Insegnamento a scelta 1»,
  come fa unicusano.py) e, se i CFU sono diversi tra le righe omonime, con «(N CFU)»;
- stessa riga in piani diversi: una riga sola con i piani in cui compare (curriculum), nome e CFU
  uguali; con CFU diversi tra i piani sono righe distinte (nome con «(N CFU)»);
- nomi senza le barre inverse che la pagina lascia nei testi («l\\'inserimento») e con l'accento al posto
  dell'apostrofo finale («attivita'» -> «attività»);
- nomi dei curricula senza il titolo del corso, senza la classe e senza «curriculum» («Indirizzo Calcio», «Schema Moda»);
  le virgole dentro un nome (percorsi() separa i percorsi sulle virgole) sono trattini;
- docenti e libri già raccolti (database/contrib/auto/uniroma5.json) si riusano; si scaricano solo le
  schede senza libri.

Le tabelle «Esami a scelta dello studente» (elenco degli esami tra cui scegliere i crediti liberi,
senza anno né numero di scelte) non diventano righe: il piano ha già le righe «Insegnamento a scelta».
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import pathlib
import re
import time

from . import unimercatorum as um
from .unibo import Client, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.uniroma5.it"
ELENCO = r"https://www\.uniroma5\.it/(?:triennale|magistrale)/[\w.-]+"
_ACCENTI = {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}
_PICCOLE = {"e", "di", "del", "della", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla", "il", "la",
            "lo", "le", "gli", "i", "ed", "nel", "nella", "sul", "tra", "and", "of", "the", "for", "to", "dell",
            "dello", "nei", "ai", "alle", "o", "una", "un", "uno"}


def _nome(s: str) -> str:
    """Nome di un insegnamento: senza barre inverse (`l\\'inserimento`), accento al posto dell'apostrofo
    finale (`attivita'`), spazi singoli."""
    s = s.replace("\\", "")
    s = re.sub(r"([A-Za-z]*[aeiou])'(?=\s|$|[,.;:)])",
               lambda m: m.group(1)[:-1] + _ACCENTI[m.group(1)[-1].lower()], s)
    return re.sub(r"\s+", " ", s).strip()


def _maiuscole(s: str) -> str:
    """Etichetta in maiuscolo -> iniziali maiuscole, con le parole piccole in minuscolo."""
    out = []
    for k, w in enumerate(s.lower().split()):
        sub = re.match(r"(\w+')(\w.*)", w)  # «dell'amministrazione»: l'articolo resta minuscolo
        if sub:
            out.append(sub.group(1) + sub.group(2)[:1].upper() + sub.group(2)[1:])
        elif k and w in _PICCOLE:
            out.append(w)
        else:
            out.append("-".join(x[:1].upper() + x[1:] for x in w.split("-")))
    return " ".join(out)


def etichetta_piano(lab: str, titolo: str | None) -> str:
    """«L-22 - SCIENZE MOTORIE - INDIRIZZO CALCIO» -> «Indirizzo Calcio»; il piano che porta solo il
    nome del corso resta con quel nome."""
    lab = re.sub(r"\s+", " ", lab.replace("\\", "")).strip()
    resto = re.sub(r"^\s*L(?:M)?[-/]?[\w/]*\s+-\s*", "", lab)
    parole = resto.split(" ")
    t = um._norm(re.sub(r"\s+(?:LM?-[\w/]+)\s*$", "", titolo or ""))
    for k in range(1, len(parole)):  # via il titolo del corso se è il prefisso e resta qualcosa
        if um._norm(" ".join(parole[:k])) == t:
            resto = re.sub(r"^[\s-]+", "", " ".join(parole[k:]))
            break
    resto = re.sub(r"^\((.*)\)$", r"\1", resto.strip())
    resto = re.sub(r"(?i)^curriculum\s+", "", resto)
    resto = resto.replace(", ", " - ")  # percorsi() separa i percorsi sulle virgole
    if re.sub(r"[àèéìòù]", lambda m: m.group(0).upper(), resto).isupper():
        resto = re.sub(r"(?i)24ore", "24 Ore", _maiuscole(resto))
    return _nome(resto)


def _righe_corso(piani: dict[str, list[dict]], etichette: dict[str, str], url: str, oggi: str) -> list[dict]:
    """Righe del corso: una per (anno, nome, CFU, n-esima occorrenza nel piano); curriculum = i piani in cui compare."""
    righe: dict[tuple, dict] = {}
    for k, voci in piani.items():
        visti: dict[tuple, int] = {}
        for v in voci:
            nome = _nome(v["nome"])
            base = (v["anno"], um._norm(nome), v["cfu"])
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
    # righe omonime nello stesso anno: nomi distinti (la costruzione del database fonde i nomi uguali)
    per_nome: dict[tuple, list[dict]] = {}
    for i in righe.values():
        per_nome.setdefault((i["anno"], um._norm(i["nome"])), []).append(i)
    for gruppo in per_nome.values():
        if len(gruppo) < 2:
            continue
        gruppo.sort(key=lambda i: (i["cfu"] or 0, i["_n"][3], sorted(i["_p"])))
        cfu_diversi = len({i["cfu"] for i in gruppo}) > 1
        per_cfu: dict = {}
        for i in gruppo:
            per_cfu.setdefault(i["cfu"], []).append(i)
        for cfu, stesse in per_cfu.items():
            for n, i in enumerate(stesse, 1):
                if i["codice"]:
                    continue  # l'id viene dal codice
                suff = f" {n}" if len(stesse) > 1 else ""
                if cfu_diversi:
                    suff += f" ({cfu:g} CFU)" if isinstance(cfu, (int, float)) else ""
                i["nome"] += suff
    return list(righe.values())


def _vecchi(uid: str) -> dict[str, dict]:
    """Docenti e libri già raccolti, per url della scheda (dall'ultimo contributo)."""
    f = ROOT / "database" / "contrib" / "auto" / f"{uid}.json"
    try:
        doc = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for c in doc.get("corsi") or []:
        for i in c.get("insegnamenti") or []:
            if i.get("url") and (i.get("libri") or i.get("docenti")):
                out.setdefault(i["url"], {"docenti": i.get("docenti") or [], "libri": i.get("libri") or []})
    return out


def fetch_ateneo(uid: str = "uniroma5", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(BASE + "/offerta-formativa")
    pagine = sorted({h.split("#")[0] for h in re.findall(rf'href="({ELENCO})', r.text if r else "")})
    sito = []
    for u in pagine:
        rc = c.get(u)
        if not rc:
            continue
        titolo, piani = um.leggi_corso(rc.text)
        classi = {m.group(1) for k in list(piani) + [titolo or ""] for m in um.CLASSE.finditer(k)}
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
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(sito)} corsi sul sito, {len(abbinati)} associati (su {len(corsi)})")
    out = []
    for corso, x in abbinati:
        etichette = {k: etichetta_piano(k, x["titolo"]) for k in x["piani"]}
        righe = _righe_corso(x["piani"], etichette, x["url"], oggi)
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
    vecchi = _vecchi(uid)
    log(f"[{uid}] {sum(len(x['insegnamenti']) for x in out)} insegnamenti; schede: {len(jobs) if syllabus else 0} "
        f"(con dati già raccolti: {sum(1 for u in jobs if u in vecchi)})")

    def scheda(u: str) -> int:
        d = {"docenti": [], "libri": []}
        if syllabus and not (vecchi.get(u) or {}).get("libri"):
            try:
                with c.lock:
                    c.requests += 1
                rp = c.s.get(u, timeout=90)
                if rp.content[:5] == b"%PDF-":
                    d = um.leggi_programma(rp.content)
                elif rp.ok and "html" in rp.headers.get("content-type", ""):
                    d = um.leggi_insegnamento(rp.text)
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
        trovati = sum(ex.map(scheda, list(jobs)))
    log(f"[{uid}] libri: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uniroma5.it, piani di studio e schede "
                                                 "(adapters/uniroma5.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
