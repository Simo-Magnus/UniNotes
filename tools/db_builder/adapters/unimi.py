"""Insegnamenti, docenti e libri dell'Università degli Studi di Milano dai siti dei corsi.

UniMi non usa il Course Catalogue Cineca: ogni corso ha un sito `<corso>.cdl.unimi.it`
con il piano didattico generato da U-GOV.

- `<sito>/it/insegnamenti/piano-didattico` (corsi in inglese: `/en/courses/educational-plan`)
  → un blocco per coorte ("Immatricolati nell'a.a. 2026/2027 (GAD)") con le schede
  "Anno: 1", "Anno: 2", …; un anno non offerto nell'a.a. corrente ha la nota
  "annualità non più attiva" o "sarà attivato dall'A.A. …". Si tengono gli anni senza nota.
- tabelle per periodo ("Primo semestre", …) con righe "Obbligatorio"/"Facoltativo",
  nome (link alla scheda), CFU, ore, lingua, SSD;
- scheda (`www.unimi.it/it/ugov/of/af…`) → docenti ("Docenti:") e "Materiale di riferimento".

I corsi sono quelli già presenti in database/corsi/unimi.json (da Universitaly), con il
loro `id`: build_db.py li associa senza ambiguità.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

from .testi import estrai_libri
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
PAGINE_PIANO = ("it/insegnamenti/piano-didattico", "en/courses/educational-plan")
PERIODI = {"primo semestre": "1", "secondo semestre": "2", "annuale": "annuale", "first semester": "1",
           "second semester": "2", "annual": "annuale", "primo trimestre": "1", "secondo trimestre": "2",
           "terzo trimestre": "3", "primo quadrimestre": "1", "secondo quadrimestre": "2",
           "terzo quadrimestre": "3", "first four-month period": "1", "second four-month period": "2",
           "third four-month period": "3"}
GRUPPO = re.compile(r"(?i)obbligator|facoltativ|compulsory|optional|mandatory|elective|a scelta")


def _sito(url: str | None) -> str | None:
    m = re.match(r"https?://([\w-]+\.cdl\.unimi\.it)", (url or "").strip())
    return f"https://{m.group(1)}" if m else None


def _blocchi(s: str) -> list[tuple[str, str]]:
    """(descrizione della coorte, html del piano) per ogni blocco della pagina."""
    parti = re.split(r'views-field-descrizione-coorte"><span class="field-content">', s)
    out = []
    for p in parti[1:]:
        desc = _testo(p.split("</span>", 1)[0])
        out.append((desc, p))
    return out


def _periodo(t: str) -> str | None:
    t = _testo(t)
    if not t or re.search(r"(?i)non definito|non è previsto|not defined|conclusiv|final", t):
        return None
    return PERIODI.get(t.lower(), t)


def _righe(corpo: str, anno: int | None, curriculum: str | None, coorte: str) -> list[dict]:
    """Righe delle tabelle di una scheda del piano (un anno, o tutto il piano se non è diviso
    per anni). Le colonne si leggono per `data-title` (Attività formative, Crediti massimi,
    Ore totali, Lingua, Periodo, SSD): «Periodo» c'è solo in alcune tabelle."""
    out = []
    periodo, gruppo_titolo = None, ""
    # titoletti di periodo/tipo, gruppi di insegnamenti obbligatori ("special-i") e regole
    # di scelta ("yyy N": «6 CFU in una delle seguenti discipline»)
    pezzi = re.split(r'(<div class="(?:top30 )?titoletto">.*?</div>|<div class="special-i">.*?</div>'
                     r'|<div class="yyy[^"]*"><div>.*?</div>)', corpo, flags=re.S)
    for pezzo in pezzi:
        if pezzo.startswith('<div class="special-i">'):
            gruppo_titolo = _testo(pezzo)
            continue
        if pezzo.startswith('<div class="yyy'):
            gruppo_titolo = "a scelta"
            continue
        if "titoletto" in pezzo[:40]:
            # il titoletto è il periodo ("Primo semestre") o, nelle pagine in
            # inglese, il tipo di attività ("Compulsory"); «Anno di corso a scelta dello
            # studente» introduce i piani non divisi per anni
            t = _testo(pezzo)
            if GRUPPO.match(t):
                gruppo_titolo, periodo = t, None
            elif re.match(r"(?i)anno di corso a scelta|year of study chosen|optional year", t):
                gruppo_titolo, periodo = "", None
            else:
                gruppo_titolo = ""
                periodo = _periodo(t)
            continue
        gruppo = gruppo_titolo
        for tabella in re.findall(r"<table.*?</table>", pezzo, re.S):
            if re.search(r"(?i)propedeutic|prerequisit", tabella.split("</thead>", 1)[0]):
                continue  # tabella delle propedeuticità
            for riga in re.findall(r"<tr[^>]*>(.*?)</tr>", tabella, re.S):
                sub = re.search(r'<td colspan="\d+">(.*?)</td>', riga, re.S)
                if sub:
                    gruppo = _testo(sub.group(1))
                    continue
                celle = re.findall(r'<td[^>]*data-title="([^"]*)"[^>]*>(.*?)</td>', riga, re.S)
                if not celle:
                    continue
                col = {html.unescape(k).strip().lower(): v for k, v in celle}
                val = [c[1] for c in celle]
                link = re.search(r'href="([^"]+)"', val[0])
                nome = _testo(val[0])
                cfu_c = next((v for k, v in col.items() if k.startswith(("crediti", "credits", "cfu", "ects"))),
                             val[1] if len(val) > 1 else "")
                cfu_t = _testo(cfu_c).replace(",", ".")
                cfu = float(cfu_t) if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None
                if cfu is not None and cfu.is_integer():
                    cfu = int(cfu)
                ssd = _testo(col.get("ssd") or col.get("scientific-disciplinary sector") or "")
                lingua = _testo(next((v for k, v in col.items() if k.startswith(("lingua", "language"))), ""))
                per_c = next((v for k, v in col.items() if k.startswith(("periodo", "period", "semester"))), None)
                out.append({
                    "nome": nome, "anno": anno, "periodo": _periodo(per_c) if per_c is not None else periodo,
                    "cfu": cfu, "ssd": ssd if ssd not in ("", "NN") else None, "lingua": lingua or None,
                    "obbligatorio": bool(re.match(r"(?i)(insegnamenti )?obbligator|compulsory|mandatory", gruppo)),
                    "url": html.unescape(link.group(1)) if link else None,
                    "curriculum": curriculum, "coorte": coorte,
                })
    return out


NOME_SCELTA = "Attività a scelta dello studente"  # + " (N° anno)": il nome diverso per anno evita che build_db le fonda in una sola
ORDINALI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
_ORD = "(primo|secondo|terzo|quarto|quinto|sesto)"
REGOLE_SCELTA = (
    # «Lo studente, al primo anno, deve altresì maturare 2 CFU in attività formative a scelta»
    # (anche «al termine del sesto anno»)
    re.compile(rf"(?i)\bal(?:\s+termine\s+del)?\s+{_ORD}\s+anno,?\s+deve\s+altresì\s+maturare\s+"
               r"(\d+)\s+CFU\s+in\s+attività\s+formative\s+a\s+scelta"),
    # «Nel secondo anno di corso lo studente deve acquisire 6 CFU scegliendo liberamente tra tutte le attività…»
    re.compile(rf"(?i)\bnel\s+{_ORD}\s+anno(?:\s+di\s+corso)?,?\s+lo\s+studente\s+deve\s+acquisire\s+"
               r"(\d+)\s+CFU\s+scegliendo\s+liberamente"),
)


def _regole_scelta(corpo: str, anno: int | None, curriculum: str | None, coorte: str) -> list[dict]:
    """«Regole di composizione» dell'anno: una regola che dice quanti CFU a scelta libera si fanno in
    quell'anno («Lo studente, al primo anno, deve altresì maturare 2 CFU in attività formative a
    scelta») → una riga «Attività a scelta dello studente (1° anno)» con i CFU della regola,
    non obbligatoria. Si usa solo se l'anno della regola è quello della scheda."""
    out = []
    for blocco in re.findall(r'class="ugov-of-pd-year-rules-\d+">(.*?)</div>\s*</div>', corpo, re.S):
        testo = _testo(blocco)
        for rx in REGOLE_SCELTA:
            m = rx.search(testo)
            if m and ORDINALI[m.group(1).lower()] == anno:
                out.append({
                    "nome": f"{NOME_SCELTA} ({anno}° anno)", "anno": anno,
                    "periodo": None, "cfu": int(m.group(2)), "ssd": None, "lingua": None, "obbligatorio": False,
                    "url": None, "curriculum": curriculum, "coorte": coorte,
                })
                break
    return out


def leggi_piano(s: str, anche_futuri: bool = False) -> list[dict]:
    """Righe degli anni offerti nell'a.a. corrente (schede senza nota), di tutti i blocchi.

    I piani divisi per anni hanno una scheda per anno ("ugov-of-pd-year-af-…"); quelli delle
    lauree magistrali con regole di scelta ("Anno di corso a scelta dello studente") no: tutto
    il pannello del curriculum è una scheda senza anno. Con `anche_futuri` si tengono anche gli
    anni con la nota «sarà attivato dall'A.A. …» (piano della coorte non ancora attivo)."""
    return [x for x in leggi_piano_stati(s) if x["stato"] == "attivo" or (anche_futuri and x["stato"] == "futuro")]


def leggi_piano_stati(s: str) -> list[dict]:
    """Come `leggi_piano`, ma di ogni riga dice se l'anno è `attivo` (nessuna nota), `futuro` («sarà
    attivato dall'A.A. …») o `passato` («annualità non più attiva»)."""
    out = []
    for coorte, blocco in _blocchi(s):
        # curricula: pannelli "curr-…" con il titolo del curriculum ("Piano didattico" = nessuno)
        pannelli = re.split(r'<a data-toggle="collapse"[^>]*class="panel-title"[^>]*>', blocco)
        for pannello in pannelli[1:]:
            titolo = _testo(pannello.split("</a>", 1)[0])
            curriculum = None if re.fullmatch(r"(?i)piano didattico|educational plan|study plan", titolo) else titolo
            etichette = dict(re.findall(r'<a data-toggle="tab" href="#([^"]+)"><div>\s*(.*?)\s*</div>', pannello, re.S))
            schede = re.split(r'<div id="(ugov-of-pd-year-af-[^"]+)" class="tab-pane[^"]*">', pannello)
            if len(schede) == 1:
                out += [dict(x, senza_anni=True, stato="attivo", da=None)
                        for x in _righe(pannello.split("</a>", 1)[-1], None, curriculum, coorte)]
                continue
            for tab_id, corpo in zip(schede[1::2], schede[2::2]):
                nota = re.search(r'class="noteanno"[^>]*>(.*?)<', corpo, re.S)
                stato, da = "attivo", None
                if nota:
                    testo_nota = html.unescape(nota.group(1))
                    stato = "futuro" if re.search(r"(?i)sar[àa] attivat|will be activated", testo_nota) else "passato"
                    da = int(m_da.group(1)) if (m_da := re.search(r"(\d{4})", testo_nota)) else None
                m = re.search(r"(\d)", _testo(etichette.get(tab_id, "")))
                anno = int(m.group(1)) if m else None
                righe = _righe(corpo, anno, curriculum, coorte)
                if anno is not None:
                    righe += _regole_scelta(corpo, anno, curriculum, coorte)
                out += [dict(x, stato=stato, da=da) for x in righe]
    return out


def con_futuri_mancanti(piano: list[dict]) -> list[dict]:
    """Righe degli anni attivi; per gli anni che nessuna coorte offre ancora (nuovo corso o nuovo
    ordinamento: «sarà attivato dall'A.A. …») il piano pubblicato per la coorte che li attiverà
    per prima (tutti i curricula di quella coorte)."""
    attivi = [x for x in piano if x["stato"] == "attivo"]
    coperti = {x["anno"] for x in attivi if x["anno"] is not None and not x["nome"].startswith(NOME_SCELTA)}
    out = list(attivi)
    for anno in sorted({x["anno"] for x in piano if x["stato"] == "futuro" and x["anno"] is not None} - coperti):
        futuri = [x for x in piano if x["stato"] == "futuro" and x["anno"] == anno]
        prima = min(x["da"] or 9999 for x in futuri)
        coorte = next(x["coorte"] for x in futuri if (x["da"] or 9999) == prima)
        out += [x for x in futuri if x["coorte"] == coorte]
    return out


def leggi_scheda(s: str) -> dict:
    docenti = []
    for blocco in re.findall(r'class="af-edition-nomination">(.*?)</div>', s, re.S):
        docenti += [_testo(x) for x in re.findall(r"<a [^>]*>(.*?)</a>", blocco, re.S)]
    if not docenti:
        docenti = [_testo(x) for x in re.findall(r'field--name-uof-person.*?<div class="field--item"><a [^>]*>(.*?)</a>',
                                                 s, re.S)]
    testi = re.findall(r'class="bottom20 af-program-yes-material">\s*<strong[^>]*>.*?</strong>\s*<div[^>]*>(.*?)</div>',
                       s, re.S)
    libri = []
    viste = set()
    for t in testi:
        for lb in estrai_libri(t):
            key = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
            if key not in viste:
                viste.add(key)
                libri.append(lb)
    return {"docenti": sorted({d for d in docenti if d}), "libri": libri}


def _testo_pdf(dati: bytes) -> str:
    import io

    from pypdf import PdfReader
    return " ".join((p.extract_text() or "") for p in PdfReader(io.BytesIO(dati)).pages)


def piano_da_manifesto(c: Client, sito: str, anno: int = 2027) -> tuple[list[dict], str | None]:
    """Corsi il cui sito non ha ancora il piano dell'a.a. corrente (es. Informatica, nuovo
    ordinamento FAA): si prende il piano della coorte più recente pubblicato sul sito
    (`?uof_aa_target_id=All`, anche gli anni «sarà attivato dall'A.A. …») e si tengono solo gli
    insegnamenti che compaiono nel Manifesto degli studi dell'a.a. corrente
    (apps.unimi.it/files/manifesti/…_<anno>.pdf, linkato da «Manifesto e altri documenti»),
    che diventa la fonte. Le schede restano quelle dell'edizione precedente: non si usano
    (niente url), si tiene solo il codice dell'attività per gli appelli."""
    m = c.get(f"{sito}/it/il-corso/manifesto-e-altri-documenti")
    link = re.search(rf'href="(https://apps\.unimi\.it/files/manifesti/ita_manifesto_[^"]+_{anno}\.pdf)"',
                     m.text if m else "")
    if not link:
        return [], None
    pdf = c.s.get(link.group(1), timeout=60)
    if pdf.status_code != 200 or not pdf.content.startswith(b"%PDF"):
        return [], None
    norm = lambda t: re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()  # noqa: E731
    testo = norm(_testo_pdf(pdf.content))
    r = c.get(f"{sito}/it/insegnamenti/piano-didattico?uof_aa_target_id=All")
    if not r:
        return [], None
    blocchi = _blocchi(r.text)
    if not blocchi:
        return [], None
    ultimo = max(blocchi, key=lambda b: max(re.findall(r"ugov-of-pd-year-af-(\d{4})", b[1]) or ["0"]))
    righe = []
    for x in leggi_piano("views-field-descrizione-coorte\"><span class=\"field-content\">" + ultimo[0] + "</span>"
                         + ultimo[1], anche_futuri=True):
        if norm(x["nome"]) and norm(x["nome"]) in testo:
            righe.append(dict(x, url=None, url_codice=x["url"]))
    return righe, link.group(1)


def fetch_ateneo(uid: str = "unimi", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _sito(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con sito su *.cdl.unimi.it")
    c = Client()
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        sito = _sito(corso["url"])
        r = None
        for p in PAGINE_PIANO:
            r = c.get(f"{sito}/{p}")
            if r and ("ugov-of-pd-year-af-" in r.text or "ugovcdl_of_pd" in r.text):
                break
            r = None
        fonte = r.url if r else None
        if r:
            piano = con_futuri_mancanti(leggi_piano_stati(r.text))
        else:
            piano, fonte = piano_da_manifesto(c, sito)
            if not piano:
                return None
        righe: dict[str, dict] = {}
        curricula = set()
        for x in piano:
            if x["curriculum"]:
                curricula.add(x["curriculum"])
            key = f"{x['anno']}:{x['nome'].lower()}:{x['cfu']}"
            item = righe.get(key)
            if not item:
                senza_anni = x.get("senza_anni")
                item = righe[key] = {
                    "codice": None, "nome": x["nome"], "anno": x["anno"], "periodo": x["periodo"], "cfu": x["cfu"],
                    "ssd": x["ssd"], "obbligatorio": x["obbligatorio"] and (x["anno"] is not None or bool(senza_anni)),
                    "curriculum": None, "docenti": [], "url": x["url"], "libri": [], "esami": [], "fonte": fonte,
                    "verificato_il": oggi, "_curr": set(),
                }
                m = re.search(r"/of/(af[\w-]+)", x.get("url_codice") or x["url"] or "")
                item["codice"] = m.group(1).upper() if m else None
            item["_curr"].add(x["curriculum"])
        tutti = set().union(*(i["_curr"] for i in righe.values())) if righe else set()
        for i in righe.values():
            cs = i.pop("_curr")
            if None not in cs and cs != tutti:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": sito, "curricula": sorted(curricula) or None,
                "fonte": fonte, "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(jobs) if syllabus else 0}")

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if not r:
                return 0
            sc = leggi_scheda(r.text)
            for it in jobs[url]:
                it["url"] = r.url
                it["docenti"] = sc["docenti"]
                it["libri"] = sc["libri"]
                it["stato_libri"] = "completo" if sc["libri"] else "da_aggiungere"
            return len(sc["libri"])
        except Exception:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(6) as ex:
            for n, k in enumerate(ex.map(scheda, list(jobs)), 1):
                trovati += k
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dai siti dei corsi *.cdl.unimi.it (adapters/unimi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
