"""IUL - Università Telematica degli Studi (iuline.it): piani di studio, docenti e libri.

L'API pubblica GOMP (`iul-public.gomp.it`, vedi `gomp.py`) ha un regolamento per ogni a.a., ma il piano che pubblica è
confuso: gruppi «AFFINI» ripartiti su più anni (18 CFU divisi tra 2° e 3° anno), alternative che non fanno parte del
piano della coorte, CFU di un anno che non tornano con il piano ufficiale (L-20: 72 e 66 invece di 63 e 57; L-33:
69 invece di 60) e, per Scienze e tecniche dell'educazione e dei servizi per l'infanzia (L-19), tre curricula nuovi che
hanno solo il 1° anno accanto al «Curriculum unico» degli anni 2 e 3.

Il sito dell'ateneo pubblica, nella pagina di ogni corso dell'a.a. (`/corsi-di-laurea-online/2026-2027/<corso>/`), il
«Piano di Studi» di ogni coorte in PDF, con i CFU di ogni riga e il totale di ogni anno («Tot I anno 60»). Qui:

- l'anno k di corso è quello della coorte (a.a. - k + 1), cioè ciò che si insegna nell'a.a. corrente («Insegnamenti
  erogati nell'anno accademico 2026/2027» della pagina del corso): 1° anno dalla coorte 2026/27, 2° dalla 2025/26,
  3° dalla 2024/25 (se manca il PDF di una coorte si usa quello della coorte più vicina);
- le righe sono quelle del PDF (nome, SSD, CFU); ogni anno si controlla contro il «Tot … anno» dichiarato (la somma
  delle righe deve tornare; unica eccezione le alternative «a scelta dello studente», che il PDF non somma);
- le righe «a scelta dello studente» (generiche: «A scelta dello Studente 18», «Esami a scelta … 12»; o alternative
  contrassegnate «* a scelta dello studente») sono a scelta; il resto, prova finale e tirocini compresi, è obbligatorio;
- codice, docenti, periodo e libri vengono dall'attività GOMP con lo stesso nome (e gli stessi CFU) nei regolamenti
  2026, 2025 e 2024 (nome uguale o molto simile: «Pedagogia generale e delle attività ludico-motorie per l'infanzia» è
  «Pedagogia delle attività ludico-motorie per l'infanzia» in GOMP); le righe senza corrispondenza restano senza codice;
- nessun curriculum: i curricula di L-19 (nuovi dal 2026/27) differiscono solo dal 3° anno della coorte 2026/27, che sarà
  erogato nel 2028/29; il 3° anno oggi insegnato è quello del «Curriculum unico».

Esecuzione locale (scrive `database/contrib/auto/iul.json`):

    python tools/db_builder/adapters/iul.py [--senza-syllabus]
"""
from __future__ import annotations

import difflib
import io
import json
import pathlib
import re
import sys
import time

import requests

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .gomp import HOSTS, Api, _attivita, _cfu_attivita, _ita, _norm  # noqa: E402
from .unibo import HEADERS  # noqa: E402

UID = "iul"
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITO = "https://www.iuline.it"
ELENCO = f"{SITO}/corsi-di-laurea-online/{{aa}}-{{bb}}/"

SSD_N = r"[A-Z]{3,5}-\d{2}/[A-Z]"
SSD_O = r"[A-Z]{1,5}-?[A-Z]{0,5}/\d{2}"
RIGA = re.compile(rf"^(?P<nome>.+?)(?:\s+(?P<ssdn>{SSD_N}))?(?:\s+(?P<ssdo>{SSD_O}))?\s+(?P<cfu>\d{{1,2}})(?P<resto>(?:\s+.*)?)$")
ANNO = re.compile(r"^(I{1,3})\s+Anno\b", re.I)
TOT = re.compile(r"^T?tot(?:ale)?\s+(I{1,3})\s+anno\s+(\d+)", re.I)
INTESTAZIONE = re.compile(r"(?i)^(insegnamento|ssd |639/2024|n\. 639)")
# «A scelta dello Studente 18», «Esami a scelta dello Studente 12», «Esame a scelta dello studente 9»
GENERICA = re.compile(r"(?i)^\s*(esam[ei]\s+)?a\s+scelta(\s+dello\s+studente)?\s*$")
# «… * a scelta dello studente», «(* a scelta dello studente)», «(a scelta dello Studente)», «* opzionale»
MARCA_SCELTA = re.compile(r"(?i)\s*\(?\s*\*?\s*(a\s+scelta(\s+dello\s+studente)?|opzionale)\s*\)?\s*$")
# docenti segnaposto di GOMP («Docente Da Inserire», «Bando Di Concorso Docente»)
SEGNAPOSTO = re.compile(r"(?i)\b(docente|bando|concorso|da inserire|da assegnare|da definire)\b")
STOP = {"e", "di", "del", "della", "dei", "delle", "dello", "degli", "in", "per", "a", "al", "ed", "nel", "nella", "con",
        "il", "la", "le", "i", "gli", "lo", "dell", "all", "alla"}


def _bundle() -> str:
    """Certificati di certifi + l'intermedio «GlobalSign GCC R6 AlphaSSL CA 2025» che www.iuline.it non invia (i browser lo
    scaricano dall'AIA, requests no): la verifica TLS resta attiva."""
    import certifi
    import tempfile
    f = pathlib.Path(tempfile.gettempdir()) / "university_notes_iul_ca.pem"
    if not f.exists():
        certi = [pathlib.Path(certifi.where()), pathlib.Path(__file__).parent / "certs" / "globalsign_gcc_r6_alphassl_ca_2025.pem"]
        f.write_text("\n".join(p.read_text(encoding="utf-8") for p in certi), encoding="utf-8")
    return str(f)


def _get(url: str, binario: bool = False):
    for tentativo in range(4):
        try:
            r = requests.get(url, headers=HEADERS, timeout=60, verify=_bundle())
            if r.status_code == 200:
                return r.content if binario else r.text
            if r.status_code == 404:
                return None
        except requests.RequestException:
            pass
        time.sleep(2 ** tentativo)
    return None


def _token(s: str) -> set[str]:
    return {t for t in _norm(s).split() if len(t) > 3 and t not in STOP}


SOGLIA = 0.85


def _somiglianza(a: str, b: str) -> float:
    """1 se i nomi (normalizzati) coincidono; altrimenti la somiglianza, o 0.9 se le parole significative (radici di 6 lettere:
    «tirocinio» = «tirocini») di uno sono tutte nell'altro («Ulteriori conoscenze linguistiche (Laboratorio di lingua inglese)»
    contiene «Ulteriori conoscenze linguistiche»), con al più 4 parole di differenza o con almeno 3 parole in comune."""
    if a == b:
        return 1.0
    ta = {t[:6] for t in _token(a)}
    tb = {t[:6] for t in _token(b)}
    contenuto = bool(ta and tb) and (ta <= tb or tb <= ta) and (abs(len(ta) - len(tb)) <= 4 or min(len(ta), len(tb)) >= 3)
    return max(difflib.SequenceMatcher(None, a, b).ratio(), 0.9 if contenuto else 0.0)


def pagine_corsi(anno: int, log=print) -> dict[str, str]:
    """Pagine dei corsi dell'a.a.: {url: slug}."""
    html = _get(ELENCO.format(aa=anno, bb=anno + 1)) or ""
    urls = sorted(set(re.findall(r'href="(https://www\.iuline\.it/corsi-di-laurea-online/%d-%d/[^"/]+/)"' % (anno, anno + 1), html)))
    return {u: u.rstrip("/").rsplit("/", 1)[1] for u in urls if not u.endswith("/feed/")}


def pagina_del_corso(corso: dict, pagine: dict[str, str]) -> str | None:
    """Pagina del corso: la sua classe nello slug («l-20-…») o, per gli altri, più parole del nome in comune."""
    classe = _norm(corso.get("classe") or "").replace(" ", "-")
    for u, s in pagine.items():
        if classe and s.startswith(classe + "-"):
            return u
    nome = _token(corso["nome"])
    punt = sorted(((len(nome & _token(s.replace("-", " "))), u) for u, s in pagine.items()), reverse=True)
    if punt and punt[0][0] >= 3 and (len(punt) == 1 or punt[0][0] > punt[1][0]):
        return punt[0][1]
    return None


def pdf_coorti(html: str) -> dict[int, str]:
    """PDF dei piani di studio della pagina: {anno di inizio della coorte: url}."""
    out: dict[int, str] = {}
    for m in re.finditer(r'href="(https://www\.iuline\.it/[^"]*?Piano-di-Stud[io]+-[A-Z]+\d+_coorte_(\d\d)_(\d\d)[^"]*?\.pdf)"', html):
        out.setdefault(2000 + int(m.group(2)), m.group(1))
    return out


def leggi_pdf(url: str) -> dict[int, dict]:
    """{anno: {"righe": [...], "tot": CFU dichiarati}} del PDF del piano di una coorte."""
    import pypdf
    dati = _get(url, binario=True)
    if not dati:
        return {}
    testo = "\n".join(p.extract_text() for p in pypdf.PdfReader(io.BytesIO(dati)).pages)
    anni: dict[int, dict] = {}
    cur = None
    for riga in testo.splitlines():
        riga = riga.strip()
        m = ANNO.match(riga)
        if m:
            cur = len(m.group(1))
            anni[cur] = {"righe": [], "tot": None}
            continue
        m = TOT.match(riga)
        if m:
            anni[len(m.group(1))]["tot"] = int(m.group(2))
            cur = None
            continue
        if cur is None or INTESTAZIONE.match(riga):
            continue
        m = RIGA.match(riga)
        if m:
            anni[cur]["righe"].append({"nome": m.group("nome").strip(), "ssd": m.group("ssdn"), "ssd_vecchio": m.group("ssdo"),
                                       "cfu": int(m.group("cfu"))})
    return anni


def _riga_piano(r: dict) -> dict:
    """Nome pulito e se è a scelta."""
    nome = r["nome"].strip()
    if GENERICA.match(nome):
        return {**r, "nome": "A scelta dello studente", "scelta": True, "generica": True}
    pulito = MARCA_SCELTA.sub("", nome).strip(" *")
    return {**r, "nome": pulito, "scelta": pulito != nome, "generica": False}


def _attivita_gomp(dati: dict, anno_reg: int) -> list[dict]:
    """Tutte le attività (figli dei gruppi compresi) di un regolamento: nome, anno di corso, periodo e dati GOMP."""
    out = []
    for cu in dati.get("curricula") or []:
        for y in cu.get("years") or []:
            for u in y.get("units") or []:
                for a in u.get("activities") or []:
                    for x in [a] + list(a.get("children") or []):
                        if x.get("children") and x is not a:
                            continue
                        dato = _attivita(x)
                        if not dato["nome"] or not dato["codice"]:
                            continue
                        out.append({"reg": anno_reg, "anno": y.get("number"), "periodo": u.get("number"), "x": dato,
                                    "n": _norm(_ita(x.get("name"))), "cfu": _cfu_attivita(x)})
    return out


def fetch_iul(uid: str = UID, anno: int | None = None, syllabus: bool = True, corsi: list[dict] | None = None,
              max_cds: int | None = None, log=print) -> dict:
    t = time.localtime()
    anno = anno or (t.tm_year if t.tm_mon >= 9 else t.tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    api = Api(HOSTS[uid])
    oggi = time.strftime("%Y-%m-%d")
    pagine = pagine_corsi(anno)
    log(f"[{uid}] pagine dei corsi {anno}/{anno + 1}: {len(pagine)}")
    elenchi = {}
    for a in range(anno, anno - 3, -1):
        e = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": a, "courseTypes": ["CorsoDiStudio"]}) or {}
        elenchi[a] = [c for s in e.get("data") or [] for c in s.get("courses") or []]

    def gomp_corso(classe: str, a: int) -> dict | None:
        cl = re.sub(r"\s+R$", "", classe or "")
        return next((c for c in elenchi.get(a, []) if any(re.sub(r"\s+R$", "", x) == cl for x in c.get("classes") or [])), None)

    out = []
    for corso in corsi[:max_cds] if max_cds else corsi:
        durata = corso.get("durata_anni") or 3
        pagina = pagina_del_corso(corso, pagine)
        if not pagina:
            log(f"[{uid}] {corso['id']}: pagina del corso non trovata")
            continue
        pdf = pdf_coorti(_get(pagina) or "")
        if not pdf:
            log(f"[{uid}] {corso['id']}: nessun PDF dei piani di studio in {pagina}")
            continue
        piani: dict[int, dict] = {}

        def piano(coorte: int) -> tuple[int, dict]:
            vicina = min(pdf, key=lambda a: (abs(a - coorte), -a))
            if vicina not in piani:
                piani[vicina] = leggi_pdf(pdf[vicina])
            return vicina, piani[vicina]

        # attività GOMP dei regolamenti 2026, 2025, 2024 (codici, docenti, periodi e libri)
        gomp: list[dict] = []
        for a in range(anno, anno - durata, -1):
            g = gomp_corso(corso.get("classe"), a)
            dati = api.corso(g["uid"], a) if g else None
            gomp += _attivita_gomp(dati or {}, a)
        righe = []
        for k in range(1, durata + 1):
            coorte = anno - k + 1
            c_usata, p = piano(coorte)
            if k not in p or not p[k]["righe"]:
                log(f"[{uid}] {corso['id']} anno {k}: assente nel PDF della coorte {c_usata}")
                continue
            rk = [_riga_piano(r) for r in p[k]["righe"]]
            somma = sum(r["cfu"] for r in rk)
            alt = sum(r["cfu"] for r in rk if r["scelta"] and not r["generica"])
            if p[k]["tot"] is not None and somma != p[k]["tot"] and somma - alt > p[k]["tot"]:
                log(f"[{uid}] ATTENZIONE {corso['id']} anno {k}: somma delle righe {somma}, totale dichiarato {p[k]['tot']}")
            fonte = pdf[c_usata]
            usati: set[str] = set()
            for r in rk:
                m = None
                if not r["generica"]:
                    cand = [g for g in gomp if abs(g["cfu"] - r["cfu"]) < 1e-9 and g["x"]["codice"] not in usati]
                    n = _norm(r["nome"])

                    def punti(g, n=n, k=k, coorte=coorte):
                        return (_somiglianza(n, g["n"]), g["anno"] == k, g["reg"] == anno, g["reg"] == coorte)
                    # nome uguale (in qualunque anno) o molto simile / contenuto nell'altro nello stesso anno di corso
                    cand = [g for g in cand if punti(g)[0] >= 1 or (punti(g)[0] >= SOGLIA and g["anno"] == k)]
                    if cand:
                        m = max(cand, key=punti)
                        usati.add(m["x"]["codice"])
                x = dict((m or {}).get("x") or {})
                if m:  # libri e docenti mancanti nel regolamento scelto: quelli dello stesso codice negli altri regolamenti
                    altri = sorted((g for g in gomp if g["x"]["codice"] == x["codice"]), key=lambda g: punti(g), reverse=True)
                    for campo in ("libri", "docenti"):
                        if not x.get(campo):
                            x[campo] = next((g["x"][campo] for g in altri if g["x"].get(campo)), [])
                libri = (x.get("libri") or []) if syllabus else []
                righe.append({
                    "codice": x.get("codice"), "nome": r["nome"], "anno": k,
                    "periodo": str(m["periodo"]) if m and m.get("periodo") else None,
                    "cfu": r["cfu"], "ssd": r["ssd"] or x.get("ssd"), "obbligatorio": not r["scelta"], "curriculum": None,
                    "docenti": [d for d in x.get("docenti") or [] if not SEGNAPOSTO.search(d)], "url": fonte, "libri": libri, "esami": [], "fonte": fonte,
                    "verificato_il": oggi, **({"stato_libri": "completo" if libri else "da_aggiungere"} if syllabus else {}),
                })
        if not righe:
            continue
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                    "url": pagina, "curricula": None, "fonte": pagina, "verificato_il": oggi, "insegnamenti": righe})
    libri = sum(len(i["libri"]) for c in out for i in c["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(c['insegnamenti']) for c in out)} insegnamenti, libri: {libri}; richieste GOMP: {api.requests}")
    return {"universita_id": uid, "descrizione": f"Piani di studio dei PDF per coorte di iuline.it, codici, docenti e libri da {HOSTS[uid]} (adapters/iul.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def fetch_ateneo(uid: str = UID, anno: int | None = None, **kw) -> dict:
    return fetch_iul(uid, anno, syllabus=kw.get("syllabus", True), max_cds=kw.get("max_cds"))


if __name__ == "__main__":
    doc = fetch_ateneo(UID, syllabus="--senza-syllabus" not in sys.argv)
    (ROOT / "database" / "contrib" / "auto" / f"{UID}.json").write_text(
        json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
