"""Insegnamenti, docenti, libri e appelli dell'Università di Milano-Bicocca.

Esse3 di UniMiB non pubblica l'offerta; la piattaforma Moodle sì, come albero di categorie
pubbliche: Area → "Corso di Laurea Triennale/Magistrale/…" → "<Corso> [<codice>]" →
"Insegnamenti" → "A.A. 2026-2027" (in inglese "A.Y.") → "1° anno", "2° anno", … → un corso
Moodle per insegnamento (codice `2627-<anno>-<cds><ad>`, CFU) con la pagina pubblica "Course
Syllabus" (`course/info.php?id=…`): testi di riferimento, periodo, lingua, docenti.

Il piano di un corso di studio può stare in più categorie: il nuovo ordinamento ha una
categoria per sede e per il 1° anno, mentre il 2° e il 3° anno del 2026/27 restano nella
categoria del vecchio codice (es. Infermieristica: 1° anno in «sede di Monza», 2°-3° anno in
«Infermieristica»); i corsi rinominati hanno ancora il 3° anno nella categoria del nome
vecchio. Le categorie con lo stesso nome (o con un alias noto) si uniscono, senza duplicare
gli insegnamenti con lo stesso nome nello stesso anno.

I libri si leggono dal testo libero del syllabus (adapters/unimib_testi.py); gli appelli dalla
bacheca Esse3, un corso di studio alla volta (adapters/unimib_appelli.py), abbinati ai corsi
tramite il codice del corso (lo stesso nel titolo delle categorie Moodle e nell'elenco Esse3).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .unibo import Client, _testo
from .unimib_piani import integra as integra_piano
from .unimib_testi import libri_unimib, periodo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://elearning.unimib.it"

# corsi rinominati o con nome diverso nelle categorie Moodle: codice di corso → id nel database
ALIAS_CODICI: dict[str, list[str]] = {
    # corsi rinominati: il 3° anno del 2026/27 sta ancora nella categoria del vecchio corso
    "E1803M": ["unimib-l-18-economia-banca-e-finanza"],  # Economia delle Banche, delle Assicurazioni… → Economia, Banca e Finanza
    "E4103B": ["unimib-l-41-statistica-machine-learning-ed-economia"],  # Scienze Statistiche ed Economiche (L) → Statistica, ML ed Economia
    "E4101B": ["unimib-l-41-statistica-machine-learning-ed-economia"],
    # la LM in Scienze infermieristiche e ostetriche ha una categoria comune e due per profilo
    "K0101D": ["unimib-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic",
               "unimib-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-ostetrico"],
    # corsi con altro nome in Esse3 (nessun insegnamento 2026/27 in e-learning, ma ci sono appelli)
    "F0101R": ["unimib-lm-1-antropologia-culturale-e-sociale"],
    "E2701Q": ["unimib-l-sc-mat-scienza-e-nanotecnologia-dei-materiali"],
    "F5801Q": ["unimib-lm-58-astrophysics-and-space-physics"],
    "F5302Q": ["unimib-lm-sc-mat-materials-science-and-nanotechnology"],
}


def _norm(s: str) -> str:
    s = (s or "").replace("'", "").replace("’", "").replace("`", "")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def sottocategorie(s: str) -> list[tuple[str, str]]:
    return [(cid, html.unescape(t)) for cid, t in
            re.findall(r'data-categoryid=(\d+)[^>]*>\s*<a [^>]*href="[^"]*categoryid=\d+"[^>]*title="([^"]*)"', s)]


def corsi_moodle(s: str) -> list[dict]:
    out = []
    for blocco in re.split(r'(?=<div class="card mb-1 coursebox)', s)[1:]:
        nome = re.search(r'course-fullname[^"]*">(.*?)</div>', blocco, re.S)
        cod = re.search(r'course-shortname[^"]*">(.*?)</div>', blocco, re.S)
        cfu = re.search(r"CFU:\s*([\d.,]+)", blocco)
        info = re.search(r'href="([^"]*/course/info\.php\?id=\d+)"', blocco)
        if not nome:
            continue
        v = float(cfu.group(1).replace(",", ".")) if cfu else None
        out.append({"nome": _testo(nome.group(1)), "codice": _testo(cod.group(1)) if cod else None,
                    "cfu": int(v) if v is not None and v.is_integer() else v,
                    "url": html.unescape(info.group(1)) if info else None})
    return out


def campi_syllabus(s: str) -> dict[str, str]:
    """Campi della scheda (id «…it» = versione italiana) con l'HTML, per `libri_unimib`."""
    return {m.group(1): m.group(2) for m in
            re.finditer(r'<div id="(\w+(?:it|en))" class="collapse"><div class="field-content[^"]*">(.*?)</div></div>', s, re.S)}


def leggi_syllabus(s: str) -> dict:
    campi = campi_syllabus(s)
    per = _testo(campi.get("periodo_erogazioneit") or campi.get("periodoit") or campi.get("periodo_erogazioneen") or campi.get("periodoen") or "")
    staff = re.search(r'<ul class="summary-content teachers">(.*?)</ul>', s, re.S)
    docenti = re.findall(r'<div class="contact-name">(.*?)</div>', staff.group(1)) if staff else []
    return {"periodo": periodo(per), "libri": libri_unimib(campi),
            "docenti": sorted({_testo(d) for d in docenti if _testo(d)})}


def _cfu_testo(s: str) -> int | None:
    """CFU dichiarati nel testo libero della scheda quando l'elenco Moodle non li ha
    («…garantiscono l'acquisizione di 2CFU»: corsi di livellamento di Scienze statistiche ed economiche)."""
    m = re.search(r"acquisizione di\s*(\d+)\s*CFU", _testo(s))
    return int(m.group(1)) if m else None


def _tipo(titolo: str) -> str | None:
    t = titolo.lower()
    if "ciclo unico" in t:
        return "LMCU"
    if "magistrale" in t:
        return "LM"
    if "triennale" in t or "laurea" in t:
        return "L"
    return None


def _ad_norm(titolo: str) -> str:
    """Titolo dell'attività nel calendario esami senza i suffissi del gestionale:
    «FISICA II - I MODULO -  Modulo di corso integrato - T1», «DIRITTO PENALE A-L», «LINGUA ARABA II - Integrato»."""
    t = re.sub(r"\([^)]*\)", "", (titolo or "").replace(" ", " "))
    t = re.split(r"\s+-\s+(?=(?:[IVX]+\s+)?(?:modulo|integrato|tu\b|t\d|turno|frontale|lab))", t, flags=re.I)[0]
    t = re.sub(r"\s+(?:[A-Z]-[A-Z]|T\d|TU\w*)$", "", t.strip())
    return _norm(t)


def _senza_sede(nome: str) -> str:
    n = re.sub(r"(?i)\s*\((?:abilitante|sede di)[^)]*\)", "", nome or "")
    return re.sub(r"(?i)\s+replica\s+\w+$", "", n).strip()


def _priorita_sede(titolo: str) -> int:
    m = re.search(r"(?i)\(sede di ([^)]+)\)", titolo or "")
    if not m:
        return 0
    return 1 if _norm(m.group(1)) in ("monza", "carate brianza") else 2


def albero_corsi(c: Client, log=print) -> list[dict]:
    """Categorie «<Nome> [<codici>]» sotto le aree dei corsi di laurea."""
    cds: list[dict] = []
    coda = [("0", [], None)]
    viste = set()
    while coda:
        cid, percorso, tipo = coda.pop(0)
        if cid in viste or len(percorso) > 4:
            continue
        viste.add(cid)
        r = c.get(f"{BASE}/course/index.php?categoryid={cid}" if cid != "0" else f"{BASE}/course/index.php")
        if not r:
            continue
        for sub, titolo in sottocategorie(r.text):
            t = _tipo(titolo) if not tipo and re.search(r"(?i)corso di laurea|lauree", titolo) else tipo
            m = re.match(r"(.*?)\s*\[([\w\s-]+)\]", titolo)  # "Nome [E1807M - E1802M]": codici nuovo e vecchio
            if m and t:
                cds.append({"categoria": sub, "titolo": titolo, "nome": m.group(1).strip(),
                            "codici": re.findall(r"\w+", m.group(2)), "tipo": t})
            elif not m:
                coda.append((sub, percorso + [titolo], t))
    log(f"[unimib] {len(cds)} corsi di studio nell'albero Moodle")
    return cds


def associa(corsi: list[dict], cds: list[dict]) -> list[tuple[dict, list[dict]]]:
    """Per ogni corso del database (tranne le repliche di sede) le categorie Moodle del suo piano."""
    pieno: dict[tuple[str, str], list[dict]] = {}
    spezzato: dict[tuple[str, str], list[dict]] = {}
    for x in cds:
        pieno.setdefault((_norm(_senza_sede(x["nome"])), x["tipo"]), []).append(x)
        if " - " in x["nome"]:
            for p in re.split(r"\s+-\s+", _senza_sede(x["nome"])):
                spezzato.setdefault((_norm(p), x["tipo"]), []).append(x)
    risultato = []
    for corso in corsi:
        rep = re.search(r"(?i)\breplica\s+(\w+)", corso["nome"])
        if rep:  # replica di sede: categoria della sede (1° anno) + categoria comune (anni successivi)
            sede = f"sede di {_norm(rep.group(1))}"
            base = [x for x in pieno.get((_norm(_senza_sede(corso["nome"])), corso["tipo"]), [])
                    if _priorita_sede(x["titolo"]) == 0 or sede in _norm(x["titolo"])]
            if any(sede in _norm(x["titolo"]) for x in base):
                risultato.append((corso, sorted(base, key=lambda x: (sede not in _norm(x["titolo"]),
                                                                      _priorita_sede(x["titolo"])))))
            continue
        nomi = [corso["nome"]]
        cand = list(pieno.get((_norm(_senza_sede(corso["nome"])), corso["tipo"]), []))
        if not cand and corso.get("nome_en"):  # il nome inglese solo se quello italiano non c'è (Medicina / Medicine and Surgery)
            nomi = [corso["nome"], corso["nome_en"]]
            cand = list(pieno.get((_norm(_senza_sede(corso["nome_en"])), corso["tipo"]), []))
        if not cand:  # nomi bilingui («Marine Sciences - Scienze Marine») in un solo dei due lati
            for n in nomi:
                parti = re.split(r"\s+-\s+", _senza_sede(n)) if " - " in n else [_senza_sede(n)]
                for p in parti:
                    cand += spezzato.get((_norm(p), corso["tipo"]), []) + pieno.get((_norm(p), corso["tipo"]), [])
        for x in cds:
            if any(corso["id"] in ALIAS_CODICI.get(k, ()) for k in x["codici"]):
                cand.append(x)
        visti, uniche = set(), []
        for x in sorted(cand, key=lambda x: _priorita_sede(x["titolo"])):
            if _priorita_sede(x["titolo"]) > 1:  # le altre sedi (Bergamo, Lecco, Sondrio…) sono le repliche
                continue
            if x["categoria"] not in visti:
                visti.add(x["categoria"])
                uniche.append(x)
        if uniche:
            risultato.append((corso, uniche))
    return risultato


def _aa_regex(anno: int) -> re.Pattern:
    return re.compile(rf"(?i)^\s*A\.\s?[AY]\.\s*{anno}\s*[-/]\s*{anno + 1}\s*$")


def piano_categoria(c: Client, cat: dict, anno: int, log=print) -> list[dict]:
    """Insegnamenti dell'anno accademico di una categoria: [{anno, nome, codice, cfu, url, fonte}]."""
    righe = []
    r = c.get(f"{BASE}/course/index.php?categoryid={cat['categoria']}")
    ins = [s for s, t in sottocategorie(r.text) if re.match(r"(?i)\s*(insegnamenti|courses)\s*$", t)] if r else []
    for i_cat in ins:
        ri = c.get(f"{BASE}/course/index.php?categoryid={i_cat}")
        aa = [s for s, t in sottocategorie(ri.text) if _aa_regex(anno).match(t)] if ri else []
        for a_cat in aa:
            ra = c.get(f"{BASE}/course/index.php?categoryid={a_cat}")
            for y_cat, y_tit in sottocategorie(ra.text) if ra else []:
                m = re.match(r"\s*(\d)\s*°?\s*(?:anno|year)", y_tit.strip(), re.I)
                if not m:
                    log(f"[unimib]   categoria anno non riconosciuta: {y_tit!r} ({y_cat}) in {cat['titolo']}")
                    continue
                k = int(m.group(1))
                ry = c.get(f"{BASE}/course/index.php?categoryid={y_cat}&perpage=1000")
                for x in corsi_moodle(ry.text) if ry else []:
                    if x["cfu"] == 0:  # corsi di orientamento e simili a 0 CFU (la scheda dice «CFU 0»): non sono insegnamenti del piano
                        continue
                    ad = re.match(r"\d{4}-\d-(\w+)$", x["codice"] or "")
                    righe.append({"anno": k, "nome": x["nome"], "codice": ad.group(1) if ad else x["codice"],
                                  "cfu": x["cfu"], "url": x["url"],
                                  "fonte": f"{BASE}/course/index.php?categoryid={y_cat}"})
    return righe


def fetch_ateneo(uid: str = "unimib", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, appelli: bool = True, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=5.0)
    oggi = time.strftime("%Y-%m-%d")

    cds = albero_corsi(c, log)
    abbinati = associa(corsi, cds)
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(abbinati)} corsi del database associati")

    def build(coppia) -> dict | None:
        corso, categorie = coppia
        righe: dict[tuple[int, str, str | None], dict] = {}
        nomi_visti: set[tuple[int, str]] = set()  # (anno, nome) già letti da una categoria precedente
        for cat in categorie:  # prima la categoria senza sede, poi Monza, poi le altre sedi
            nomi_cat: set[tuple[int, str]] = set()
            for x in piano_categoria(c, cat, anno, log):
                # lo stesso insegnamento in più categorie (sede, nome vecchio) si tiene una volta sola; in una stessa
                # categoria due corsi con lo stesso nome e codici diversi (es. «Strategic Management» da 11 e da 14 CFU) restano due
                if (x["anno"], _norm(x["nome"])) in nomi_visti:
                    continue
                nomi_cat.add((x["anno"], _norm(x["nome"])))
                key = (x["anno"], _norm(x["nome"]), x["codice"])
                righe.setdefault(key, {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"],
                    "periodo": None, "cfu": x["cfu"], "ssd": None, "obbligatorio": None,
                    "curriculum": None, "docenti": [], "url": x["url"], "libri": [], "esami": [],
                    "fonte": x["fonte"], "verificato_il": oggi,
                })
            nomi_visti |= nomi_cat
        # lo stesso corso Moodle (stesso codice) elencato in più anni del piano è un'offerta a scelta (corsi elettivi,
        # tirocini e seminari offerti in due anni consecutivi): non è obbligatorio in nessuno dei due
        anni_codice: dict[str, set[int]] = {}
        for (a, _n, cod), r in righe.items():
            if cod:
                anni_codice.setdefault(cod, set()).add(a)
        for (a, _n, cod), r in righe.items():
            if cod and len(anni_codice[cod]) > 1:
                r["obbligatorio"] = False
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"),
                "url": f"{BASE}/course/index.php?categoryid={categorie[0]['categoria']}",
                "fonte": f"{BASE}/course/index.php?categoryid={categorie[0]['categoria']}", "verificato_il": oggi,
                "insegnamenti": sorted(righe.values(), key=lambda i: (i["anno"], _norm(i["nome"]))),
                "_categorie": [x["categoria"] for x in categorie],
                "_replica": bool(re.search(r"(?i)\breplica\b", corso["nome"])),
                "_cat_sede": [x["categoria"] for x in categorie if "sede di" in x["titolo"].lower()]}

    def build_safe(coppia) -> dict | None:
        try:
            return build(coppia)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {coppia[0].get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, abbinati) if r]
    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"syllabus da leggere: {len(jobs) if syllabus else 0}")

    def leggi(url: str) -> int:
        try:
            r = c.get(url)
            if not r:
                return 0
            sy = leggi_syllabus(r.text)
            cfu_t = _cfu_testo(r.text)
            if not sy["libri"]:
                # insegnamento integrato: il syllabus rinvia a quelli dei moduli (corsi Moodle elencati nella
                # stessa pagina, con codice «<insegnamento>-<modulo>»); i loro testi valgono per l'insegnamento
                for m in corsi_moodle(r.text):
                    if m["url"] and m["url"] != url and m["url"] not in jobs:
                        rm = c.get(m["url"])
                        if rm:
                            for b in leggi_syllabus(rm.text)["libri"]:
                                nome_m = re.sub(r"\s*(?:Codice identificativo del corso|Course ID number).*$", "", m["nome"]).strip()
                                b["note"] = f"Dal syllabus del modulo «{nome_m}»"
                                sy["libri"].append(b)
            for it in jobs[url]:
                if it.get("cfu") is None and cfu_t:
                    it["cfu"] = cfu_t
                it["periodo"] = sy["periodo"]
                it["docenti"] = sy["docenti"]
                it["libri"] = sy["libri"]
                it["stato_libri"] = "completo" if sy["libri"] else "da_aggiungere"
            return len(sy["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(5) as ex:
            for n, k in enumerate(ex.map(leggi, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   syllabus {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    for corso in out:
        if syllabus:  # scheda vuota senza CFU, docenti, periodo né testi: attività senza crediti (es. «Laboratorio Orientarsi»)
            corso["insegnamenti"] = [i for i in corso["insegnamenti"] if not (
                i["cfu"] is None and not i["libri"] and not i["docenti"] and not i["periodo"])]
        # due corsi con lo stesso nome e CFU diversi nello stesso anno sono alternative distinte (es. «Strategic Management»
        # da 11 e da 14 CFU, «Industrial Organization» da 9 e da 6): il nome dice quale
        per_nome: dict[tuple[int, str], list[dict]] = {}
        for i in corso["insegnamenti"]:
            per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
        for gruppo in per_nome.values():
            if len(gruppo) > 1 and len({i["cfu"] for i in gruppo}) == len(gruppo) and all(i["cfu"] is not None for i in gruppo):
                for i in gruppo:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        integra_piano(corso, oggi, log)  # voci del piano didattico che Moodle non ha (lingua, scelta, tesi, 2° anno delle LM)
    if appelli:
        try:
            n = attacca_appelli(out, cds, anno, log)
            log(f"[{uid}] appelli abbinati: {n} insegnamenti")
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}] appelli Esse3 non letti: {e!r}")
    for corso in out:
        corso.pop("_categorie", None)
        corso.pop("_replica", None)
        corso.pop("_cat_sede", None)
    return {"universita_id": uid, "descrizione": "Generato da elearning.unimib.it, Course Syllabus (adapters/unimib.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def attacca_appelli(out: list[dict], cds: list[dict], anno: int, log=print) -> int:
    """Appelli della bacheca Esse3, corso di studio per corso di studio, negli insegnamenti dei
    corsi `out`: il corso Esse3 si abbina a quello del database tramite il codice di corso
    (categorie Moodle «[E0202Q - E0201Q]» ↔ elenco Esse3 «[E0201Q]»), altrimenti per nome; l'attività
    si abbina all'insegnamento per codice o per nome."""
    from .unimib_appelli import fetch_appelli_cds
    # gli appelli cambiano da sede a sede: le repliche solo dai corsi Esse3/Agenda della propria sede
    from .unimib_agenda import fetch_agenda
    esse3 = fetch_appelli_cds(log)  # bacheca Esse3 (iscrizioni aperte)
    try:
        esse3 += fetch_agenda(anno, log)  # calendario esami dell'Agenda Web (data, ora, aula)
    except Exception as ex:  # noqa: BLE001
        log(f"[unimib] agenda web non letta: {ex!r}")
    cat_per_codice: dict[str, set[str]] = {}
    for x in cds:
        for k in x["codici"]:
            cat_per_codice.setdefault(k, set()).add(x["categoria"])
    per_nome: dict[str, list[dict]] = {}
    for c in (x for x in out if not x["_replica"]):
        per_nome.setdefault(_norm(_senza_sede(c["nome"])), []).append(c)
    toccati = set()
    for e in esse3:
        cats = cat_per_codice.get(e["codice"], set())
        bersagli = [c for c in out if cats & set(c["_cat_sede"] if c["_replica"] else c["_categorie"])]
        bersagli += [c for c in out if not c["_replica"] and c["id"] in ALIAS_CODICI.get(e["codice"], ())]
        bersagli += per_nome.get(_norm(_senza_sede(e["nome"])), [])
        visti = set()
        bersagli = [b for b in bersagli if not (b["id"] in visti or visti.add(b["id"]))]
        if not bersagli:
            if e["appelli"]:
                log(f"[unimib] esse3 [{e['codice']}] {e['nome']}: {len(e['appelli'])} attività senza corso del database")
            continue
        for cod, lst in e["appelli"].items():
            titolo = _ad_norm(lst[0].get("titolo") or "")
            for b in bersagli:
                for i in b["insegnamenti"]:
                    if i.get("codice") == cod or (titolo and titolo in (_norm(i["nome"]), _ad_norm(i["nome"]))):
                        presenti = {(x["data"], x["ora"], x["tipo"]): x for x in i["esami"]}
                        nuovi = []
                        for x in lst:
                            e0 = presenti.get((x["data"], x["ora"], x["tipo"]))
                            if e0:  # stesso appello da due fonti: si completano luogo e modalità
                                for k in ("luogo", "modalita", "docenti"):
                                    if not e0.get(k) and x.get(k):
                                        e0[k] = x[k]
                                continue
                            n = {k: v for k, v in x.items() if k != "titolo"}
                            presenti[(x["data"], x["ora"], x["tipo"])] = n
                            nuovi.append(n)
                        if nuovi:
                            i["esami"] = sorted(i["esami"] + nuovi, key=lambda x: x["data"] or "")
                            i["stato_esami"] = "completo"
                            toccati.add((b["id"], i["codice"], i["nome"]))
    return len(toccati)
