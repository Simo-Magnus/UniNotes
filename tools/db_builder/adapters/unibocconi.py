"""Insegnamenti, docenti, libri e appelli dell'Università Bocconi.

Fonti pubbliche (`anno` nei parametri = anno in cui inizia l'a.a.; nelle url `anno=2027` = a.a. 2026/27):

- «Guide to the University» (`didattica.unibocconi.eu/tsg/guide.php?volume=N3|R2|R5|WB|CY&edizione=2027`): il capitolo
  «Program structure» di ogni volume ha il piano di studi di ogni corso **per coorte** (immatricolati dal 2025/26,
  fino al 2024/25, …) con anno, semestre, codice, CFU di ogni attività, i gruppi a scelta («1 course to be chosen
  from»), i percorsi (major, track, concentration, curricula) e gli elenchi dei corsi che li compongono
  (`adapters/unibocconi_guida.py` legge queste tabelle e controlla i totali di anno stampati nella guida);
- `didattica.unibocconi.eu/ts/index.php?ric_ordinamento=N3|R2|R5` → corsi di studio come sigle (CLEAM, BIEF, …)
  con il codice per i filtri (`ric_cdl`);
- `ts/tsn_ric_alf.php?ric_cdl=<codice>` → insegnamenti erogati nell'a.a.: codice, nome, CFU, semestre;
- `ts/tsn_anteprima.php?cod_ins=<codice>&ric_cdl=<codice corso>` → scheda: "(N credits - I sem. - OB | SSD)",
  docenti delle classi, "Teaching materials";
- `esami/esami_calendario.php?esame=<codice>` → appelli per corso (PI = parziale, S/O = generale).

Prima l'elenco erogato di ogni sigla (circa 140-200 insegnamenti, di tutti gli anni e di tutti i programmi) era
l'unica fonte: quasi nessun insegnamento aveva l'anno (l'anno si leggeva dal sito di marketing dei corsi, che ora
mostra il piano di una coorte futura) e i CFU erano quelli dell'elenco erogato. Ora ogni anno k è il piano della
coorte che lo frequenta nell'a.a. corrente (anno 1: immatricolati 2026/27, anno 2: 2025/26, …); dove la guida non ha
una sezione per quella coorte (es. ciclo unico: solo 2022/23 e 2023/24) si usa la coorte più vicina, indicata nella
`nota` degli insegnamenti. Gli insegnamenti si agganciano all'erogato per codice (libri, docenti, SSD, appelli);
quelli senza codice nella guida (es. terzo anno di Economia aziendale) per nome.

Le scelte del piano sono righe `obbligatorio: false` (alternative di un gruppo, segnaposto «Elective 1», «4 elective
courses», corsi di una concentrazione/major, elenco degli opzionali della guida), con il percorso in `curriculum`.
Gli insegnamenti erogati che non sono nel piano né in un elenco della guida non si importano più.

I libri, i docenti, gli appelli e le schede già raccolti (database/contrib/auto/unibocconi*.json e
database/corsi/unibocconi.json) si riusano per codice senza rileggere le schede; solo i codici nuovi si scaricano.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata
import urllib.parse

from . import unibocconi_guida as G
from .testi import estrai_libri, html_to_lines
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
TS = "https://didattica.unibocconi.eu/ts/"
GUIDA = "https://didattica.unibocconi.eu/tsg/"
ESAMI = "https://didattica.unibocconi.eu/esami/esami_calendario.php?IdPag=106&esame="
# «I/II sem.» NON è annuale: sulle schede vuol dire che le classi parallele sono in entrambi i semestri («Classes: 31 (I sem.) -
# 32 (II sem.)»). Resta senza periodo, a meno che tutte le classi siano nello stesso semestre (`semestre_classi`).
SEM = {"I sem.": "1", "II sem.": "2"}
PARALLELE = "I/II sem."


def semestre_classi(s: str) -> str | None:
    """Semestre dalla riga «Classes: 31 (I sem.) - 32 (II sem.)» della scheda: solo se tutte le classi sono nello stesso
    semestre; se sono in entrambi (o la riga non c'è) nessun periodo."""
    m = re.search(r"Classes?\s*:\s*((?:[\w.]+\s*\((?:I|II)\s+sem\.\)\s*-?\s*)+)", _testo(s))
    if not m:
        return None
    sem = set(re.findall(r"\((I|II)\s+sem\.\)", m.group(1)))
    return SEM.get(sem.pop() + " sem.") if len(sem) == 1 else None

# corso del database (prefisso dell'id) → sigle dell'erogato (la prima è quella del corso), volume della guida e
# programma nella guida: ("sigla", "BIEF") = capitolo con «(BIEF)» nel titolo, ("titolo", regex) = capitolo con quel
# titolo, ("tutto",) = tutto il volume; "solo_elenco": elenco di corsi (senza tabelle di piano) all'anno indicato.
CORSI = [
    ("unibocconi-l-18-business-world", ["WBB"], "WB", [("tutto",)], {"ects": True}),
    ("unibocconi-l-18-economia-aziendale", ["CLEAM"], "N3", [("sigla", "CLEAM")], {"elettivi": True}),
    ("unibocconi-l-18-economia-e-management-per-arte", ["CLEACC"], "N3", [("sigla", "CLEACC")], {}),
    ("unibocconi-l-33-economic-and-social-sciences", ["BESS"], "N3", [("sigla", "BESS")], {"elettivi": True}),
    ("unibocconi-l-33-economics-management-and-computer", ["BEMACS"], "N3", [("sigla", "BEMACS")], {"elettivi": True}),
    ("unibocconi-l-14-global-law", ["BGL"], "N3", [("sigla", "BGL")], {}),
    ("unibocconi-l-33-international-economics-and-finance", ["BIEF"], "N3", [("sigla", "BIEF")], {"elettivi": True}),
    ("unibocconi-l-18-international-economics-and-management", ["BIEM"], "N3", [("sigla", "BIEM")], {"elettivi": True}),
    ("unibocconi-l-36-", ["BIG"], "N3", [("sigla", "BIG")], {"elettivi": True}),
    ("unibocconi-l-35-", ["BAI"], "N3", [("sigla", "BAI")], {}),
    ("unibocconi-lm-77-accounting", ["AFM"], "R2", [("sigla", "AFM")], {}),
    ("unibocconi-lm-18-", ["AI"], "R2", [("sigla", "AI")], {}),
    ("unibocconi-lm-91-", ["CYBER"], "CY", [("sigla", "Cyber")], {}),
    ("unibocconi-lm-82-", ["DSBA"], "R2", [("sigla", "DSBA")], {}),
    ("unibocconi-lm-56-economic", ["ESS"], "R2", [("sigla", "ESS")], {}),
    ("unibocconi-lm-77-economics-and-management-in-arts", ["ACME"], "R2", [("sigla", "ACME")], {}),
    ("unibocconi-lm-77-economics-and-management-of-gov", ["GIO"], "R2", [("sigla", "GIO")], {}),
    ("unibocconi-lm-16-", ["FIN"], "R2", [("sigla", "FIN")], {}),
    ("unibocconi-lm-sc-giur", ["GLOBE"], "R2", [("sigla", "GLOBE")], {}),
    ("unibocconi-lm-56-innovation", ["INTENT", "EMIT"], "R2", [("sigla", "INTENT"), ("sigla", "EMIT")], {}),
    ("unibocconi-lm-77-international-management", ["IM"], "R2", [("sigla", "IM")], {}),
    ("unibocconi-lm-77-marketing", ["MM"], "R2", [("sigla", "MM")], {}),
    ("unibocconi-lm-62-", ["PPA"], "R2", [("sigla", "PPA")], {}),
    ("unibocconi-lm-76-", ["TS"], "CY", [("sigla", "TS")], {}),
    ("unibocconi-lmg-01", ["CLMG"], "R5", [("titolo", r"^Program Structure$"),
                                         ("titolo", r"^Elective courses in the fifth year$", 5)], {}),
]


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _parti(nome: str) -> list[str]:
    """"ITALIANO / ENGLISH" o "ITALIANO [ENGLISH]" → nomi normalizzati di entrambe le lingue."""
    m = re.match(r"(.*?)\s*\[(.*)\]\s*$", nome)
    parti = [m.group(1), m.group(2)] if m else nome.split(" / ")
    return [_norm(p) for p in parti if p.strip()]


def leggi_elenco(s: str) -> list[dict]:
    out = []
    for cod, label in re.findall(r'href="tsn_anteprima\.php\?cod_ins=(\d+)[^"]*"[^>]*>\s*<span[^>]*>\d+</span>\s*'
                                 r'<span[^>]*>(.*?)</span>', s, re.S):
        label = html.unescape(_testo(label))
        m = re.match(r"(.*?)\s+-\s+([\d.,]+)\s+cfu\s+-\s+(.*?)\s*$", label)
        nome, cfu, sem = (m.group(1), m.group(2), m.group(3)) if m else (label, None, "")
        v = float(cfu.replace(",", ".")) if cfu else None
        out.append({"codice": cod, "nome": nome.strip(), "cfu": int(v) if v is not None and v.is_integer() else v,
                    "periodo": SEM.get(sem.strip()), "parallele": sem.strip() == PARALLELE})
    return out


def leggi_scheda(s: str, sigla: str) -> dict:
    blocchi = re.split(r'<div style="background-color: #5686CE', s)[1:]
    for b in blocchi:
        intest = _testo(b[:b.find("</div>")])
        m = re.search(rf"\b{re.escape(sigla)}\s*\(([\d.,]+)\s*credits\s*-\s*(.*?)\s*-\s*(\w+)\s*\|\s*([^)]*)\)", intest)
        if not m:
            continue
        docenti = []
        for d in re.findall(r"(?:Class|Classe)\s*\d+\s*:\s*(.*?)(?=,\s*(?:Class|Classe)\s*\d|$)",
                            _testo(re.split(r"Suggested background|Conoscenze pregresse|Mission", b)[0])):
            d = d.strip(" ,")
            if d and d.upper() == d:
                d = " ".join(w.capitalize() for w in d.split())
            if d and d not in docenti:
                docenti.append(d)
        t = re.search(r"(?:Teaching materials|Materiali didattici)(.*?)(?:Scroll to top|Torna su|$)", b, re.S)
        ssd = [x.strip() for x in m.group(4).split("|") if x.strip()]
        return {"tipo": m.group(3), "ssd": ssd[0] if ssd else None, "docenti": docenti,
                "libri": estrai_libri(t.group(1)) if t else []}
    return {"tipo": None, "ssd": None, "docenti": [], "libri": []}


def leggi_esami(s: str, sigla: str, fonte: str) -> list[dict]:
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for r in re.findall(r"<tr.*?</tr>", s, re.S):
        c = [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", x))).strip()
             for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", r, re.S)]
        if len(c) < 7 or c[1] != sigla:
            continue
        d = re.match(r"(\d{2})/(\d{2})/(\d{4})", c[3])
        if not d or f"{d[3]}-{d[2]}-{d[1]}" < oggi:
            continue
        sc = re.match(r"(\d{2})/(\d{2})/(\d{4})", c[6])
        ora = re.match(r"(\d{1,2})[.:](\d{2})", c[4])
        out.append({"tipo": "prova_in_itinere" if c[2] == "PI" else "appello",
                    "data": f"{d[3]}-{d[2]}-{d[1]}", "ora": f"{int(ora[1]):02d}:{ora[2]}" if ora else None,
                    "luogo": None, "modalita": {"S": "scritto", "O": "orale"}.get(c[2]),
                    "iscrizioni_dal": None, "iscrizioni_al": f"{sc[3]}-{sc[2]}-{sc[1]}" if sc else None,
                    "docenti": None, "note": None, "fonte": fonte})
    return out


# ------------------------------------------------------------------------------------------- guida
def _leggi_volume(c: Client, vol: str, fine: int, log) -> dict | None:
    """Righe e capitoli del capitolo «Program structure» di un volume della guida."""
    idx = c.get(f"{GUIDA}guide.php?volume={vol}&edizione={fine}&Invia=ENTRA")
    if not idx:
        return None
    capitoli = re.findall(r"Vai\('Apri', (\d+)\) ; \" class=\"indice\">(.*?)</a>", idx.text)
    cap = next((i for i, t in capitoli if re.search(r"(?i)structure", html.unescape(t))), None)
    if not cap:
        return None
    url = f"{GUIDA}testo.php?idr={cap}&comando=Base&edizione={fine}&volume={vol}&idAnt={cap}&strperc="
    r = c.get(url)
    if not r:
        return None
    m = re.search(r"<main", r.text)
    righe = html_to_lines(r.text[m.start():] if m else r.text)
    nodi = G.albero(righe)
    log(f"[unibocconi] guida {vol}: {len(righe)} righe, {len(nodi)} capitoli")
    return {"righe": righe, "nodi": nodi, "url": url}


def _programma(vol: dict, spec: tuple) -> dict | None:
    righe, nodi = vol["righe"], vol["nodi"]
    if spec[0] == "tutto":
        return {"start": 0, "end": len(righe)}
    if spec[0] == "sigla":
        pat = re.compile(r"\(\s*%s\s*\)" % re.escape(spec[1]), re.I)
    else:
        pat = re.compile(spec[1], re.I)
    cand = [n for n in nodi if pat.search(n["title"]) and n["level"] <= (3 if spec[0] == "sigla" else 4)]
    if not cand:
        return None
    n = max(cand, key=lambda n: (n["end"] - n["start"], -n["start"]))
    p = {"start": n["start"], "end": n["end"]}
    if len(spec) > 2:
        p.update(solo_elenco=True, anno=spec[2])
    return p


def _elettivi_bsc(vol: dict) -> list[dict]:
    """Elenco degli opzionali dei corsi triennali (capitolo «Elective courses»): 6 CFU l'uno."""
    righe, nodi = vol["righe"], vol["nodi"]
    n = next((n for n in nodi if n["title"].strip().lower() == "elective courses" and n["level"] == 1), None)
    if not n:
        return []
    testo = " ".join(righe[n["start"]:n["own_end"]])
    m = re.search(r"elective course is worth (\d+) CP", testo)
    cp = float(m.group(1)) if m else None
    return G.elenco_semplice(righe[n["start"] + 2:n["own_end"]], cp)


# --------------------------------------------------------------------------------------- riuso
def _riusa() -> dict[str, dict]:
    """codice → ultimi dati raccolti (docenti, libri, SSD, appelli, stato) dai file già nel repository."""
    db = ROOT / "database"
    out: dict[str, dict] = {}

    def prendi(i: dict):
        cod = i.get("codice")
        if not cod:
            return
        cur = out.setdefault(cod, {"libri": [], "docenti": [], "esami": [], "ssd": None, "periodo": None})
        if len(i.get("libri") or []) > len(cur["libri"]):
            cur["libri"] = i["libri"]
        if len(i.get("docenti") or []) > len(cur["docenti"]):
            cur["docenti"] = i["docenti"]
        if len(i.get("esami") or []) > len(cur["esami"]):
            cur["esami"] = i["esami"]
        if i.get("ssd") and not cur["ssd"]:
            cur["ssd"] = i["ssd"]

    for f in ("corsi/unibocconi.json", "contrib/auto/unibocconi.json", "contrib/auto/unibocconi_piani.json",
              "contrib/auto/unibocconi_syl_b2.json", "contrib/auto/unibocconi_syl_b3.json"):
        p = db / f
        if not p.exists():
            continue
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except ValueError:
            continue
        for c in d.get("corsi") or []:
            for i in c.get("insegnamenti") or []:
                prendi(i)
    return out


def _correzioni(sigla: str, voci: list[dict]) -> None:
    """Righe della guida che il parser delle tabelle non ricostruisce da sole."""
    if sigla == "BIG":
        # «Capstone project in one of the following fields: 15 CP» (30715 Political Science, 30716 Sociology, 30717
        # Contemporary History) + «Field work/Academies 6 CP»: nella tabella le celle sono unite e il parser le legge
        # come un'unica riga da 6
        base = None
        for v in list(voci):
            if v["codice"] in ("30715", "30716", "30717"):
                voci.remove(v)
                base = v
        if base:
            for cod, campo in (("30715", "Political Science"), ("30716", "Sociology"), ("30717", "Contemporary History")):
                voci.append(dict(base, codice=cod, nome=f"Capstone project ({campo})", nome_alt=None, cp=15.0,
                                 gid=9001, obb=None))
            voci.append(dict(base, codice=None, nome="Field work/Academies", nome_alt=None, cp=6.0, gid=None, obb=True))
    if sigla == "GLOBE":
        # «Activity chosen by the student»: due attività da 6 CFU («1 activity to be chosen from: internship or 1
        # elective course» e «1 activity to be chosen from: moot court or legal clinic or 2 professional skills
        # seminars») lette come un solo gruppo da 6
        for v in list(voci):
            if v["anno"] == 2 and v["nome"].lower().startswith(("activity chosen by the student",
                                                                 "internship or 1 elective course",
                                                                 "moot court or legal clinic")):
                voci.remove(v)
                base = v
        if any(v["anno"] == 2 for v in voci):
            for nome in ("Activity chosen by the student: internship or 1 elective course from a list",
                         "Activity chosen by the student: moot court, legal clinic or 2 professional skills seminars"):
                voci.append(dict(base, nome=nome, cp=6.0, gid=None, codice=None, nome_alt=None))
    if sigla == "CLMG":
        # «Activities chosen by students»: 12 + 6 + 6 CFU (tre attività) lette come un unico gruppo da 12
        nuove = []
        for v in list(voci):
            if v["nome"].lower().startswith(("activities chosen by students", "2 insegnamenti devono",
                                             "stage oppure un terzo", "2 seminari per lo sviluppo",
                                             "4 attività a scelta", "4 activity chosen", "2 courses must be chosen",
                                             "internship or 1 elective", "legal clinics or participation",
                                             "2 seminars for the development")):
                voci.remove(v)
                if v["anno"] not in {n["anno"] for n in nuove}:
                    for nome, cp in (("Two electives chosen among the pure electives or the 4th-5th year compulsory "
                                      "courses not already chosen", 12.0),
                                     ("Internship or third elective", 6.0),
                                     ("Two professional skills seminars, legal clinics, moot court or fourth elective",
                                      6.0)):
                        nuove.append(dict(v, nome=nome, nome_alt=None, cp=cp, gid=None, codice=None))
        voci.extend(nuove)


def _primo_maiuscolo(s: str) -> str:
    s = _titolo(re.sub(r"\s+", " ", s or "").strip())
    return s[:1].upper() + s[1:]


def fetch_ateneo(uid: str = "unibocconi", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    fine = anno + 1
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    # sigle dell'erogato e loro insegnamenti
    programmi: dict[str, dict] = {}
    for o in ("N3", "R2", "R5"):
        r = c.get(f"{TS}index.php?IdPag=8227&ric_ordinamento={o}&anno={fine}")
        sel = re.search(r'<select name="ric_cdl".*?</select>', r.text if r else "", re.S)
        for v, t in re.findall(r'<option value="([^"]+)"[^>]*>(.*?)</option>', sel.group(0) if sel else ""):
            sigla = html.unescape(t).strip()
            re_ = c.get(f"{TS}tsn_ric_alf.php?anno={fine}&IdPag=8227&ric_cdl={urllib.parse.quote(v)}")
            ins = leggi_elenco(re_.text) if re_ else []
            if ins:
                programmi[sigla] = {"cdl": v.split("^")[-1], "v": v, "ins": ins}
    log(f"[{uid}] {len(programmi)} sigle dell'erogato")
    ero: dict[str, tuple[str, dict]] = {}  # codice → (sigla, riga erogato)
    for sigla, p in programmi.items():
        for i in p["ins"]:
            ero.setdefault(i["codice"], (sigla, i))
    per_nome: dict[str, list[str]] = {}
    for cod, (sigla, i) in ero.items():
        for n in _parti(i["nome"]):
            per_nome.setdefault(n, []).append(cod)
    volumi: dict[str, dict | None] = {}
    riusa = _riusa()
    out = []
    controllo: dict[str, list] = {}
    for corso in corsi:
        cfg = next((x for x in CORSI if corso["id"].startswith(x[0])), None)
        if not cfg:
            continue
        if max_cds and len(out) >= max_cds:
            break
        _, sigle, vol, progs, opz = cfg
        if vol not in volumi:
            volumi[vol] = _leggi_volume(c, vol, fine, log)
        v = volumi[vol]
        if not v:
            log(f"[{uid}] guida {vol} non letta: {corso['id']} saltato")
            continue
        programmi_g = [_programma(v, s) for s in progs]
        if not all(programmi_g):
            log(f"[{uid}] programma non trovato nella guida per {corso['id']}")
            continue
        it = (corso.get("lingua") or "").lower().startswith("it")
        durata = corso.get("durata_anni") or 3
        voci, scelte = G.piano(v["righe"], v["nodi"], programmi_g, durata, fine, it, opz.get("ects", False))
        _correzioni(sigle[0], voci)
        if opz.get("elettivi"):
            if "n3_elettivi" not in volumi:
                volumi["n3_elettivi"] = _elettivi_bsc(v)
            for k in {x["anno"] for x in voci if not x["pool"] and G.SEGNAPOSTO.search(x["nome"])
                      and re.search(r"(?i)\belective|opzional", x["nome"])}:
                for e in volumi["n3_elettivi"]:
                    w = dict(e)
                    w.update(anno=k, nodo="2.2", curr=None, pool=True, d=0)
                    voci.append(w)
        righe_out = _righe(corso, voci, scelte, ero, programmi, sigle, per_nome, riusa, it, v, fine, oggi)
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": corso.get("url"),
                    "curricula": sorted({p for r in righe_out for p in _percorsi(r.get("curriculum"))}) or None,
                    "fonte": v["url"], "verificato_il": oggi, "insegnamenti": righe_out})
        controllo[corso["id"]] = _controllo(scelte, voci, durata)
        log(f"[{uid}] {corso['id']}: {len(righe_out)} insegnamenti")
    items = [i for x in out for i in x["insegnamenti"]]
    nuovi = [i for i in items if i.get("codice") and i["codice"] in ero and not i.pop("_riusato", False)]
    log(f"[{uid}] {len(items)} insegnamenti; da leggere: {len(nuovi)}")

    def scheda(i: dict) -> int:
        sigla = i.pop("_sigla", None)
        try:
            r = c.get(i["url"])
            d = leggi_scheda(r.text, sigla) if r and sigla else None
            if d:
                i["ssd"] = d["ssd"]
                i["docenti"] = d["docenti"]
                i["libri"] = d["libri"]
                i["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
            e = c.get(ESAMI + i["codice"])
            i["esami"] = leggi_esami(e.text, sigla, ESAMI + i["codice"]) if e and sigla else []
            if i["esami"]:
                i["stato_esami"] = "completo"
            return len(i["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, nuovi), 1):
                trovati += k
                if n % 100 == 0:
                    log(f"[{uid}]   schede {n}/{len(nuovi)}")
    # «I/II sem.» nell'elenco: il semestre si legge dalle classi della scheda (solo se sono tutte nello stesso semestre)
    da_classi = {i["url"] for i in items if i.pop("_classi", False) and i.get("url")} if syllabus else set()
    sem_classi: dict[str, str | None] = {}
    for u in sorted(da_classi):
        r = c.get(u)
        sem_classi[u] = semestre_classi(r.text) if r else None
    for i in items:
        if i.get("url") in sem_classi and sem_classi[i["url"]]:
            i["periodo"] = sem_classi[i["url"]]
            i["periodo_fonte"] = i["url"]
    log(f"[{uid}] «I/II sem.»: {len(da_classi)} schede lette, semestre dalle classi per "
        f"{sum(1 for u in sem_classi.values() if u)}")
    for x in out:
        x["insegnamenti"].sort(key=lambda r: (r["anno"], str(r["periodo"] or ""), r["nome"]))
    for i in items:
        i.pop("_sigla", None)
        i.pop("_riusato", None)
        i.pop("_classi", None)
    log(f"[{uid}] libri nuovi: {trovati}, richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da didattica.unibocconi.eu (Guide to the University e "
                                                 "insegnamenti erogati; adapters/unibocconi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": [],
            "controllo_piano": controllo}


def _percorsi(curriculum: str | None) -> list[str]:
    return [p.strip() for p in re.split(r",(?![^(]*\))", curriculum or "") if p.strip()]


def _obbligatorio(v: dict) -> bool:
    if v.get("gid"):
        return False
    if G.SEGNAPOSTO.search(v["nome"]) or re.search(r"(?i)concentration workshops|to be chosen|selected from", v["nome"]):
        return False
    if v.get("obb") is True:
        return True
    if v.get("pool") and v.get("codice"):
        return False
    return True


def _righe(corso, voci, scelte, ero, programmi, sigle, per_nome, riusa, it, vol, fine, oggi) -> list[dict]:
    """Voci del piano → insegnamenti del contributo (con riuso di docenti, libri e appelli per codice)."""
    cdl_corso = programmi[sigle[0]]["cdl"] if sigle[0] in programmi else None
    maggiori = {(x["anno"]) for x in voci if x["pool"] and x["codice"] and x["curr"]}
    righe: dict[tuple, dict] = {}
    for v in voci:
        if v["cp"] == 0 or (v["cp"] is None and not v["codice"]):
            continue  # (prove e corsi propedeutici a 0 CFU non sono insegnamenti del piano)
        if re.search(r"(?i)compulsory courses for the major", v["nome"]) and v["anno"] in maggiori:
            continue  # sostituita dall'elenco dei corsi del major
        nome = v["nome"]
        alt = v.get("nome_alt")
        if alt and not it:
            nome = alt
        if v["pool"] and v["nodo"] == "2.2" and v["codice"] in ero:
            # elenco degli opzionali: i nomi della guida vanno a capo a metà; si usa il nome dell'erogato
            pezzi = re.match(r"(.*?)\s*\[(.*)\]\s*$", ero[v["codice"]][1]["nome"])
            pezzi = [pezzi.group(1), pezzi.group(2)] if pezzi else ero[v["codice"]][1]["nome"].split(" / ")
            nome = pezzi[0] if it or len(pezzi) == 1 else pezzi[-1]
        if len(nome) > 160 or re.match(r"(?i)^in addition\b", nome):
            continue
        cod = v["codice"]
        er = ero.get(cod) if cod else None
        if not cod:
            cand = []
            for n in (_norm(v["nome"]), _norm(alt or "")):
                cand += per_nome.get(n, [])
            cand = sorted(set(cand))
            if len(cand) == 1 and not G.SEGNAPOSTO.search(v["nome"]):
                cod = cand[0]
                er = ero.get(cod)
        cp = v["cp"]
        if cp is None and er and er[1]["cfu"] is not None:
            cp = er[1]["cfu"]
        if cp is None:
            continue
        obb = _obbligatorio(v)
        cp = int(cp) if float(cp).is_integer() else cp
        periodo = (er[1]["periodo"] if er and er[1]["periodo"] else None) or v.get("periodo")
        classi = bool(er and er[1].get("parallele") and not periodo)  # «I/II sem.»: il semestre dipende dalle classi
        sigla = er[0] if er else None
        scheda = (f"{TS}tsn_anteprima.php?cod_ins={cod}&anno={fine}&ric_cdl={programmi[sigla]['cdl']}&IdPag=8229"
                  if sigla else None)
        nota = None
        if v["d"] > 0:
            nota = ("piano della coorte più vicina nella guida (nessuna sezione per la coorte che frequenta "
                    f"l'anno {v['anno']})")
        elif v["pool"] and v["nodo"] == "2.2":
            nota = "elenco degli opzionali della guida (capitolo 2.2)"
        r = {"codice": cod, "nome": _primo_maiuscolo(nome), "anno": v["anno"], "periodo": periodo, "cfu": cp,
             "ssd": None, "obbligatorio": obb, "curriculum": v.get("curr"), "docenti": [], "url": scheda,
             "libri": [], "esami": [], "fonte": vol["url"], "verificato_il": oggi}
        if nota:
            r["nota"] = nota
        if classi and sigla:
            r["_classi"] = True
        if cod:
            old = riusa.get(cod)
            if old:
                r.update(ssd=old["ssd"], docenti=list(old["docenti"]), libri=list(old["libri"]),
                         esami=[e for e in old["esami"] if (e.get("data") or "") >= oggi])
                r["stato_libri"] = "completo" if r["libri"] else "da_aggiungere"
                if r["esami"]:
                    r["stato_esami"] = "completo"
                r["_riusato"] = True
            if sigla:
                r["_sigla"] = sigla
        key = (cod or _norm(r["nome"]), r["anno"], r["obbligatorio"])
        if key in righe:
            a = righe[key]
            if a["curriculum"] and r["curriculum"]:
                ps = _percorsi(a["curriculum"]) + [p for p in _percorsi(r["curriculum"]) if p not in _percorsi(a["curriculum"])]
                a["curriculum"] = ", ".join(ps)
            else:
                a["curriculum"] = None
            for k in ("periodo", "ssd"):
                a[k] = a[k] or r[k]
            a.setdefault("nota", r.get("nota"))
            continue
        righe[key] = r
    # lo stesso insegnamento obbligatorio e a scelta nello stesso anno: resta obbligatorio (come build_db)
    out = []
    obbl = {(k[0], k[1]) for k, r in righe.items() if r["obbligatorio"]}
    for k, r in righe.items():
        if not r["obbligatorio"] and (k[0], k[1]) in obbl and not r["curriculum"]:
            continue
        if r.get("nota") is None:
            r.pop("nota", None)
        out.append(r)
    # omonimi nello stesso anno con codici diversi (es. «Sociology» obbligatorio di BESS e opzionale 30197): se i CFU
    # sono uguali resta l'insegnamento del piano, altrimenti i CFU nel nome dell'opzionale
    per_nome = {}
    for r in out:
        per_nome.setdefault((_norm(r["nome"]), r["anno"]), []).append(r)
    for rs in per_nome.values():
        codici = {r["codice"] for r in rs if r["codice"]}
        if len(rs) > 1 and len(codici) > 1:
            piano = [r for r in rs if r["obbligatorio"] or not str(r.get("nota") or "").startswith("elenco")]
            for r in rs:
                if r.get("nota", "").startswith("elenco degli opzionali") and piano:
                    if any(x["cfu"] == r["cfu"] for x in piano):
                        out.remove(r)
                    else:
                        r["nome"] = f"{r['nome']} ({r['cfu']} CFU)"
    out.sort(key=lambda r: (r["anno"], str(r["periodo"] or ""), r["nome"]))
    return out


def _controllo(scelte, voci, durata) -> list[dict]:
    """Per ogni anno, sezione della guida e percorso: totale stampato nella guida e somma dei CFU letti (di un gruppo
    a scelta si conta una sola volta la quota richiesta)."""
    out = []
    for k in range(1, durata + 1):
        sc = scelte.get(k)
        if not sc:
            continue
        for s in sc["nodi"]:
            righe = s["anni"][k]
            percorsi = sorted({x["curriculum"] or x.get("label") for x in righe if x["curriculum"] or x.get("label")}) or [None]
            for p in percorsi:
                somma, visti = 0.0, set()
                for x in righe:
                    pr = x["curriculum"] or x.get("label")
                    if pr and p and pr != p:
                        continue
                    if x.get("gid"):
                        if x["gid"] in visti:
                            continue
                        visti.add(x["gid"])
                        somma += (x["cp"] or 0) * (x.get("n_gruppo") or 1)
                    else:
                        somma += x["cp"] or 0
                out.append({"anno": k, "sezione": s["num"], "titolo": s["titolo"],
                            "curriculum": p or s["curriculum"], "coorte_dist": sc["dist"],
                            "dichiarato": s["totali"].get(k), "somma": somma})
    return out
