"""Insegnamenti dell'Università degli Studi di Enna "Kore" dalle API pubbliche del sito.

Il sito uke.it (Next.js) legge i dati da due API GraphQL pubbliche:

- `admin.uke.it/graphql` (WordPress) → corsi con titolo e `middlewareId`;
- `api.uke.it/graphql` → `curriculum(courseId: middlewareId)`: piano dell'a.a. corrente per
  anno ("FIRST_YEAR", …), percorso, insegnamenti con SSD, CFU, semestre, link alla scheda di
  trasparenza (PDF) e gruppi di insegnamenti a scelta.

Le schede di trasparenza sono PDF (S3): con pypdf si leggono docenti ("Docente Ruolo SSD") e
"Testi per lo studio della disciplina".
I corsi si associano a quelli del database per nome (e sede, per le repliche).
"""
from __future__ import annotations

import json
import pathlib
import re
import time
import unicodedata

import requests

from .testi import estrai_libri
from .unibo import HEADERS, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
WP = "https://admin.uke.it/graphql"
API = "https://api.uke.it/graphql"
ANNI = {"FIRST_YEAR": 1, "SECOND_YEAR": 2, "THIRD_YEAR": 3, "FOURTH_YEAR": 4, "FIFTH_YEAR": 5, "SIXTH_YEAR": 6}
SEM = {"FIRST_SEMESTER": "1", "SECOND_SEMESTER": "2", "ANNUAL": "annuale", "YEARLY": "annuale", "ALL_YEAR": "annuale"}
# spazi «a scelta dello studente» (Materia a scelta, Insegnamento a scelta, …): crediti a scelta, non un esame
SCELTA = re.compile(r"(?i)\bscelta\b")
SCELTA_TRA = re.compile(r"(?i)\bscelta\s+tra\b")  # «Due lingue a scelta tra»: l'elenco è nelle note, resta com'è
Q_CORSI = "{ courses(first: 300, where:{language: IT}) { nodes { title slug customFields { middlewareId } } } }"
Q_PIANO = """query getCurriculum($language: Language!, $courseId: Int!) { curriculum(language: $language, courseId: $courseId)
{ curriculum { annuality track year optionalGroups { name subjects { ssd title cfu semester } }
subjects { annuality cfu id link semester ssd title } } } }"""


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nome_corso(s: str) -> str:
    """Nome per abbinare un corso del database alla pagina del sito: senza parentesi, «replica …»,
    «- profilo …», «magistrale», con «ed» = «e» (Scienze infermieristiche ed ostetriche)."""
    s = re.sub(r"(?i)\s*\(.*?\)|\s+replica\s+.*$|\s+[-–]\s+profilo\s+.*$|\s+profilo\s+infermieristico$|"
               r"\s+magistrale$", "", s)
    return re.sub(r"\bed\b", "e", _norm(s))


def _slug40(nome: str) -> str:
    """Come `slug(nome, 40)` di build_db.py (lo slug dell'id di un insegnamento)."""
    n = unicodedata.normalize("NFKD", nome or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", n).strip().replace(" ", "-")[:40].strip("-")


def _id_distinti(corso_id: str, righe: list[dict], log=print) -> None:
    """Righe diverse con lo stesso inizio di nome (40 caratteri dello slug), anno e tipo (obbligatorio o a scelta)
    sarebbero fuse da build_db: la prima tiene l'id del nome, le altre un id proprio (il sito non dà il codice)."""
    viste: dict[tuple, int] = {}
    for r in righe:
        j = (r["anno"], _slug40(r["nome"]), r["obbligatorio"] is False)
        viste[j] = viste.get(j, 0) + 1
        if viste[j] > 1:
            r["id"] = f"{corso_id}-{j[1]}-{viste[j]}"
            log(f"[unikore]   {corso_id} anno {r['anno']}: «{r['nome']}» ha lo stesso inizio di un'altra riga, "
                f"id {r['id']}")


def _schede_raccolte(uid: str) -> dict[str, dict]:
    """Docenti e libri già letti dalle schede di trasparenza (per url), dal contributo precedente."""
    f = ROOT / "database" / "contrib" / "auto" / f"{uid}.json"
    try:
        doc = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for c in doc.get("corsi") or []:
        for i in c.get("insegnamenti") or []:
            u = i.get("url") or ""
            # le schede senza docenti né libri si rileggono (potevano essere un errore di rete)
            if u.lower().endswith(".pdf") and (i.get("libri") or i.get("docenti")):
                out.setdefault(u, {"docenti": i.get("docenti") or [], "libri": i.get("libri") or []})
    return out


def _gql(url: str, query: str, variables: dict | None = None) -> dict:
    for tentativo in range(3):
        try:
            r = requests.post(url, json={"query": query, "variables": variables or {}}, timeout=90,
                              headers={**HEADERS, "content-type": "application/json", "origin": "https://uke.it"})
            return r.json().get("data") or {}
        except (requests.RequestException, ValueError):
            time.sleep(2 ** tentativo)
    return {}


def leggi_scheda_pdf(data: bytes) -> dict:
    try:
        import io
        from pypdf import PdfReader
        testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - pypdf assente o PDF illeggibile
        return {"docenti": [], "libri": []}
    docenti = []
    m = re.search(r"Docente\s+Ruolo\s+SSD\s*\n(.*?)\n(?:Risultati|Obiettivi|Contenuti|Programma)", testo, re.S)
    for riga in (m.group(1).splitlines() if m else []):
        d = re.match(r"\s*(.+?)\s+(?:PO|PA|RU|RTD\w*|RTT|Ric\w*|Contratto|Docente)\b", riga)
        if d:
            docenti.append(d.group(1).strip())
    m = re.search(r"Testi per lo studio della disciplina\s*\n(.*?)(?:\n(?:Date di esame|Metodi didattici|"
                  r"Modalit|Programma|Obiettivi)|\Z)", testo, re.S)
    righe: list[str] = []
    for r in (m.group(1).splitlines() if m else []):
        r = r.strip()
        if not r:
            continue
        # le righe che continuano un riferimento (minuscola, cifra, parentesi) si uniscono alla precedente
        if righe and (r[0].islower() or r[0].isdigit() or r[0] in "(,;") and not righe[-1].endswith("."):
            righe[-1] += " " + r
        else:
            righe.append(r)
    return {"docenti": docenti, "libri": estrai_libri("<br>".join(righe))}


def fetch_ateneo(uid: str = "unikore", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    oggi = time.strftime("%Y-%m-%d")
    wp = [x for x in ((_gql(WP, Q_CORSI).get("courses") or {}).get("nodes") or [])
          if str((x.get("customFields") or {}).get("middlewareId") or "0") != "0"]
    per_nome: dict[str, list[dict]] = {}
    for x in wp:
        per_nome.setdefault(_nome_corso(re.sub(r"\s+[–-]\s+sede di\s+.*$", "", x["title"], flags=re.I)),
                            []).append(x)
    abbinati = []
    for corso in corsi:
        cand = per_nome.get(_nome_corso(corso["nome"])) or []
        replica = re.search(r"(?i)replica\s+(\w+)", corso["nome"])
        if replica:
            cand = [x for x in cand if replica.group(1).lower() in x["title"].lower()]
        else:
            # la sede principale: la pagina senza sede, o quella di Enna (Infermieristica ha le pagine
            # «sede di Enna» e «sede di Caltagirone»: quest'ultima è la replica)
            cand = ([x for x in cand if "sede di" not in x["title"].lower()]
                    or [x for x in cand if "sede di enna" in x["title"].lower()] or cand[:1])
        # laurea e laurea magistrale con lo stesso nome (Ingegneria aerospaziale): la pagina «… magistrale»
        # è della LM, l'altra della triennale
        mag = [x for x in cand if "magistrale" in x["title"].lower()]
        if (corso.get("tipo") or "").startswith("LM"):
            cand = mag or cand
        else:
            cand = [x for x in cand if x not in mag]
        if cand:
            abbinati.append((corso, cand[0]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(wp)} corsi sul sito, {len(abbinati)} associati al database (su {len(corsi)})")
    riuso = _schede_raccolte(uid)
    out = []
    for corso, x in abbinati:
        mid = int(x["customFields"]["middlewareId"])
        piani = ((_gql(API, Q_PIANO, {"language": "IT", "courseId": mid}).get("curriculum") or {})
                 .get("curriculum") or [])
        righe: dict[tuple, dict] = {}
        tracce = {p.get("track") for p in piani if p.get("track")}
        fonte = f"https://uke.it/didattica/corsi/{x['slug']}"
        # stesso titolo nello stesso anno con CFU diversi (tra curricula o nello stesso piano): righe distinte
        cfu_titolo: dict[tuple, set] = {}
        for p in piani:
            for s in p.get("subjects") or []:
                cfu_titolo.setdefault((p.get("annuality"), _norm(s.get("title"))), set()).add(s.get("cfu"))
        for p in piani:
            k = ANNI.get(p.get("annuality") or "")
            if not k:
                continue
            gruppi = [(s, True) for s in p.get("subjects") or []] + \
                     [(s, False) for g in p.get("optionalGroups") or [] for s in g.get("subjects") or []]
            visti: dict[tuple, int] = {}
            for s, obbl in gruppi:
                nome = _titolo(s.get("title") or "")
                nt = _norm(s.get("title"))
                if len(cfu_titolo.get((p.get("annuality"), nt), ())) > 1 and s.get("cfu"):
                    nome = f"{nome} ({s['cfu']:g} CFU)"
                n = visti[(nt, s.get("cfu"))] = visti.get((nt, s.get("cfu")), 0) + 1
                if n > 1:  # due righe identiche nello stesso piano sono due voci diverse
                    nome = f"{nome} ({n})"
                if SCELTA.search(nome) and not SCELTA_TRA.search(nome):
                    obbl = False
                key = (k, _norm(nome))
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": None, "nome": nome, "anno": k,
                        "periodo": SEM.get(s.get("semester") or "", None), "cfu": s.get("cfu"),
                        "ssd": s.get("ssd") or None, "obbligatorio": obbl, "curriculum": None, "docenti": [],
                        "url": s.get("link") or fonte, "libri": [], "esami": [], "fonte": fonte,
                        "verificato_il": oggi, "_t": set(),
                    }
                item["obbligatorio"] = item["obbligatorio"] or obbl
                item["_t"].add(p.get("track"))
        for i in righe.values():
            ts = i.pop("_t")
            if None not in ts and tracce and ts != tracce:
                i["curriculum"] = ", ".join(sorted(ts))
        _id_distinti(corso["id"], list(righe.values()), log)
        if righe:
            out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                        "durata_anni": corso.get("durata_anni"), "url": fonte,
                        "curricula": sorted(tracce) or None, "fonte": fonte, "verificato_il": oggi,
                        "insegnamenti": list(righe.values())})
        time.sleep(0.3)
    pdf: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            if (i.get("url") or "").lower().endswith(".pdf"):
                pdf.setdefault(i["url"], []).append(i)
    trovati = riusate = 0
    if syllabus:
        for n, (u, items) in enumerate(pdf.items(), 1):
            if u in riuso:  # scheda già letta in una raccolta precedente: docenti e libri si riusano
                d = riuso[u]
                riusate += 1
            else:
                try:
                    r = requests.get(u, headers=HEADERS, timeout=90)
                    d = leggi_scheda_pdf(r.content) if r.status_code == 200 and r.content.startswith(b"%PDF")                         else {"docenti": [], "libri": []}
                except requests.RequestException:
                    d = {"docenti": [], "libri": []}
                time.sleep(0.2)
            for i in items:
                i["docenti"] = d["docenti"]
                i["libri"] = d["libri"]
                i["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
            trovati += len(d["libri"])
            if n % 200 == 0:
                log(f"[{uid}]   schede {n}/{len(pdf)}")
    log(f"[{uid}] schede: {len(pdf)} ({riusate} già raccolte)")
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {trovati}")
    return {"universita_id": uid, "descrizione": "Generato dalle API GraphQL di uke.it (adapters/unikore.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
