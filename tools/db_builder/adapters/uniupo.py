"""Insegnamenti, docenti e libri dell'Università del Piemonte Orientale da of.uniupo.it.

Il sito dell'offerta formativa pubblica la "Didattica erogata" di ogni corso:

- `/syllabus/<a.a.>` → dipartimenti; `/syllabus/<a.a.>/<dip>` → corsi (nome, tipo, link);
- `/syllabus/<a.a.>/<dip>/<corso>` → "N° Anno" con anno, codice, insegnamento, docenti, SSD,
  sede, curriculum, CFU; le righe con sfondo grigio sono attività opzionali;
- scheda dell'insegnamento (`…/C<id>`) → "Testi di riferimento" e periodo.

Una stessa pagina serve il corso principale e le sue repliche di sede («… REPLICA Alessandria» in Universitaly):
ogni riga ha la sua sede (`data-sede`), e il corso principale e ogni replica ricevono le sole righe della propria
sede (altrimenti il principale riceve i codici di tutte le sedi e le repliche restano senza CFU). I corsi con più
sedi ma senza repliche (una sola scheda per sedi diverse, es. Intelligenza artificiale a Vercelli e Alessandria)
tengono tutte le righe. Due corsi con lo stesso nome in dipartimenti diversi (Giurisprudenza a Novara e Alessandria)
si distinguono dal sito del dipartimento dell'url del corso.
Non sono insegnamenti le attività a 0 CFU (OFA, «Conoscenze iniziali», tutorati, esercitazioni, idoneità) né la
«Didattica integrativa» (un caso ha 39 CFU, evidentemente le ore).
La pagina non elenca tirocinio, prova finale e crediti liberi dei corsi che non li hanno tra gli insegnamenti: gli
anni con totale sotto 60 CFU sono incompleti sulla fonte.
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

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://of.uniupo.it"


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


# «CORSO GENERICO», «PERCORSO GENERICO», «GENERICO», «000-GENERICO», «TUTTI», «percorso comune»: nessun percorso
_GENERICO = re.compile(r"(?i)^(?:\d+\s*-\s*)?(?:(?:corso|percorso)\s+)?(?:generico|comune)$|^tutti$")
# dipartimento (codice nell'url del sito dell'offerta formativa) → sito del dipartimento o della scuola
_SITO_DIP = {"300069": "digspes", "300070": "scuolamed", "300071": "dsf", "300072": "scuolamed", "300073": "disit",
             "300074": "disum", "300075": "disei", "300489": "disste"}
# insegnamenti che non lo sono: «Didattica integrativa di …», «DID. INTEGRATIVA - …», «attività integrativa alla didattica»
_INTEGRATIVA = re.compile(r"(?i)^\s*(?:didattica\s+integrativa|did\.?\s*integrativa)\b|attivit.\s+integrativa\s+alla\s+didattica")


def _non_insegnamento(nome: str, cfu) -> bool:
    return cfu == 0 or bool(_INTEGRATIVA.search(nome or ""))


def _tipo(t: str) -> str | None:
    t = t.lower()
    if "ciclo unico" in t:
        return "LMCU"
    if "magistrale" in t:
        return "LM"
    if "laurea" in t:
        return "L"
    return None


def leggi_corso(s: str) -> list[dict]:
    out = []
    for attr, corpo in re.findall(r'<div\s+class="corso-row([^"]*)"([^>]*>.*?)(?=<div\s+class="corso-row|</main>|$)', s, re.S):
        # valore singolo (<span class="corso-value">) o più valori (<div|span class="corso-values …">)
        campi = {}
        for k, v1, v2 in re.findall(
                r'<span class="corso-label">([^<]*)</span>\s*(?:<span class="corso-values?[^"]*">(.*?)</span>\s*(?=<|$)|'
                r'<div\s+class="corso-values[^"]*">(.*?)</div>|<div\s+class="docenti-value">.*?</div>)', corpo, re.S):
            v = v1 or ", ".join(_testo(x) for x in re.findall(r'<span class="corso-value">(.*?)</span>', v2, re.S))
            campi.setdefault(_testo(k), v)
        doc = re.search(r'<div\s+class="docenti-value">(.*?)</div>', corpo, re.S)
        url = re.search(r'data-url="([^"]+)"', corpo)
        nome = _testo(campi.get("Insegnamento", ""))
        if not nome:
            continue
        anno = re.match(r"\s*(\d)", _testo(campi.get("Anno corso", "")))
        v = _testo(campi.get("CFU", "")).replace(",", ".")
        cfu = float(v) if re.fullmatch(r"\d+(\.\d+)?", v) else None
        curr = _testo(campi.get("Curriculum", ""))
        sede = re.search(r'data-sede="([^"]*)"', corpo)
        out.append({
            "sedi": {_norm(x) for x in sede.group(1).split(",") if _norm(x)} if sede else set(),
            "anno": int(anno.group(1)) if anno else None, "codice": _testo(campi.get("Codice", "")) or None,
            "nome": _titolo(nome), "ssd": (_testo(campi.get("SSD", "")) or None) if _testo(campi.get("SSD", "")) != "NN"
            else None,
            "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
            "curriculum": None if _GENERICO.match(curr) else (curr or None),
            "docenti": sorted({" ".join(w.capitalize() if w.isupper() else w for w in _testo(d).split())
                               for d in re.findall(r"<a\s[^>]*>(.*?)</a>", doc.group(1) if doc else "", re.S)
                               if _testo(d)}),
            "url": BASE + html.unescape(url.group(1)) if url else None,
            "opzionale": bool(attr.strip()),
        })
    return out


def leggi_scheda(s: str) -> dict:
    campi = {_testo(k): v for k, v in re.findall(
        r'<span class="attivita-label">(.*?)</span>\s*<div class="attivita-value">(.*?)</div>', s, re.S)}
    per = _testo(campi.get("Periodo", "") or campi.get("Periodo didattico", "")).lower()
    m = re.search(r"(primo|secondo|terzo|\d)\W*(?:°\s*)?(semestre|periodo|trimestre)", per)
    periodo = "annuale" if "annual" in per else ({"primo": "1", "secondo": "2", "terzo": "3"}.get(m.group(1), m.group(1))
                                                if m else None)
    return {"libri": estrai_libri(campi.get("Testi di riferimento", "")), "periodo": periodo}


# Attività che la «Didattica erogata» 2026/27 non elenca ma il piano prevede (tirocinio, ADO/ADE, prova finale, tesi,
# stage, ulteriori attività, crediti a scelta); i CFU si leggono dal programma dell'a.a. precedente, stesso corso
_ATTIVITA_PIANO = re.compile(r"(?i)tirocin|\bADO\b|\bADE\b|prova finale|\btesi\b|ulteriori attivit|\bstage\b|"
                             r"altre attivit|laboratori professionali|\ba (?:libera )?scelta")


def leggi_vecchio(s: str) -> list[dict]:
    """Schede della pagina del vecchio sito (`/syllabus_old/didattica.php/it/<a.a.>/<corso>`) per i soli insegnamenti
    di primo livello (senza i moduli): nome, codice, CFU, anno, fruizione (OBB/OPZ), curriculum."""
    t = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", s, flags=re.S)
    t = html.unescape(re.sub(r"<[^>]+>", "\n", t))
    t = re.sub(r"\n\s*\n+", "\n", re.sub(r"[ \t\xa0]+", " ", t))
    schede = []
    for b in re.split(r"\nInsegnamento\n", t)[1:]:
        d = {"nome": b.split("\n")[0].strip()}
        for k in ("Codice", "CFU", "Anno", "Fruizione insegnamento", "Curriculum", "Tipo di insegnamento", "Periodo"):
            m = re.search(r"\n" + re.escape(k) + r"\n(.*?)\n", b)
            if m:
                d[k] = m.group(1).strip()
        if d.get("Codice") and d["nome"]:
            schede.append(d)
    nomi = {d["nome"] for d in schede}
    return [d for d in schede if "Modulo" not in d.get("Tipo di insegnamento", "")
            and not any(d["nome"].startswith(n + ": ") for n in nomi)]


def _base_nome(nome: str) -> tuple[str, str | None]:
    """Nome del corso senza «(abilitante …)» e senza «REPLICA <sede>»; → (nome normalizzato, sede della replica)."""
    n = re.sub(r"(?i)\s*\(abilitante.*?\)", "", nome or "")
    m = re.search(r"(?i)\s+replica\s+(.+)$", n)
    return _norm(re.sub(r"(?i)\s+replica\b.*$", "", n)), (_norm(m.group(1)) if m else None)


def fetch_ateneo(uid: str = "uniupo", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, riusa: dict | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py).
    `riusa`: {url della scheda: {"libri": …, "periodo": …}} già raccolti (non si rileggono)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(f"{BASE}/syllabus/{anno}")
    dips = sorted(set(re.findall(rf'href="/syllabus/{anno}/(\d+)"', r.text if r else "")))
    pagine: dict[tuple[str, str], list[str]] = {}
    for d in dips:
        rd = c.get(f"{BASE}/syllabus/{anno}/{d}")
        for tipo, nome, url in re.findall(r'<div\s+class="cds-card"\s+data-tipo="([^"]*)"[^>]*>\s*<div class="corso-titolo">'
                                          r'\s*(.*?)\s*</div>.*?href="([^"]+)"', rd.text if rd else "", re.S):
            pagine.setdefault((_norm(re.sub(r"(?i)\s*\(abilitante.*?\)", "", _testo(nome))), _tipo(tipo) or ""), []).append(BASE + url)
    # una pagina serve il corso principale e le sue repliche di sede: (pagina) → [(corso, sede della replica | None)]
    gruppi: dict[str, list[tuple[dict, str | None]]] = {}
    for corso in corsi:
        nome, sede_replica = _base_nome(corso["nome"])
        cand = pagine.get((nome, corso["tipo"])) or pagine.get((nome, "L" if corso["tipo"] == "LMCU" else "")) or []
        if len(cand) > 1:  # stesso nome in dipartimenti diversi: il sito del dipartimento è nell'url del corso
            host = (urllib.parse.urlparse(corso.get("url") or "").hostname or "").split(".")[0]
            cand = [u for u in cand if _SITO_DIP.get(u.split("/")[5]) == host]
        if len(cand) == 1:
            gruppi.setdefault(cand[0], []).append((corso, sede_replica))
    abbinati = list(gruppi.items())
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {sum(len(v) for v in pagine.values())} corsi sul sito, "
        f"{sum(len(v) for _, v in abbinati)} associati (su {len(corsi)})")

    def build(gruppo) -> list[dict]:
        url, membri = gruppo
        r = c.get(url)
        if not r:
            return []
        letti = [x for x in leggi_corso(r.text) if x["anno"] and not _non_insegnamento(x["nome"], x["cfu"])]
        sedi_pagina = set().union(*(x["sedi"] for x in letti)) if letti else set()
        sedi_replica = {s for _, s in membri if s}
        # il principale ha le sedi della pagina che non sono repliche; se non resta nessuna, tutte
        sedi_principale = (sedi_pagina - sedi_replica) or sedi_pagina
        vecchie: list[tuple[dict, str]] = []
        for tk in url.rsplit("/", 1)[-1].split("_"):
            u_vecchio = f"{BASE}/syllabus_old/didattica.php/it/{anno - 1}/{tk}"
            rv = c.get(u_vecchio)
            vecchie += [(d, u_vecchio) for d in (leggi_vecchio(rv.text) if rv else [])]
        out = []
        for corso, sede_replica in membri:
            ammesse = {sede_replica} if sede_replica else sedi_principale
            righe: dict[str, dict] = {}
            curricula = set()
            for x in letti:
                if sedi_replica and x["sedi"] and not (x["sedi"] & ammesse):
                    continue
                if x["curriculum"]:
                    curricula.add(x["curriculum"])
                key = f"{x['anno']}:{x['codice'] or x['nome']}"
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                        "ssd": x["ssd"], "obbligatorio": not x["opzionale"], "curriculum": None,
                        "docenti": x["docenti"], "url": x["url"], "libri": [], "esami": [], "fonte": url,
                        "verificato_il": oggi, "_c": set(),
                    }
                item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
                item["_c"].add(x["curriculum"])
            for i in righe.values():
                cs = i.pop("_c")
                if None not in cs and curricula and cs != curricula:
                    i["curriculum"] = ", ".join(sorted(cs))
            if not righe:
                continue
            # attività del piano che la didattica erogata non elenca, dal programma dell'a.a. precedente (stessa fonte
            # ufficiale, url nel campo `fonte`): solo obbligatorie (o crediti a scelta), non già presenti per codice o nome
            codici = {i["codice"] for i in righe.values()}
            nomi_anno = {(i["anno"], _norm(i["nome"])) for i in righe.values()}
            for d, u_v in vecchie:
                a = re.match(r"\s*(\d)", d.get("Anno", ""))
                try:
                    cfu_v = float(d.get("CFU", "").replace(",", "."))
                except ValueError:
                    continue
                gen = _GENERICO.match(d.get("Curriculum", "")) or not d.get("Curriculum")
                if (not a or cfu_v <= 0 or not gen or not _ATTIVITA_PIANO.search(d["nome"])
                        or d["Codice"] in codici or (int(a.group(1)), _norm(d["nome"])) in nomi_anno
                        or (d.get("Fruizione insegnamento") != "OBB" and not re.search(r"(?i)a (libera )?scelta", d["nome"]))):
                    continue
                codici.add(d["Codice"])
                per = _testo(d.get("Periodo", "")).lower()
                righe[f"{a.group(1)}:{d['Codice']}"] = {
                    "codice": d["Codice"], "nome": _titolo(d["nome"]), "anno": int(a.group(1)),
                    "periodo": "annuale" if "annual" in per else None, "cfu": int(cfu_v) if cfu_v.is_integer() else cfu_v,
                    "ssd": None, "obbligatorio": d.get("Fruizione insegnamento") == "OBB", "curriculum": None,
                    "docenti": [], "url": None, "libri": [], "esami": [], "fonte": u_v, "verificato_il": oggi,
                    "stato_libri": "da_aggiungere",
                }
            ins = list(righe.values())
            # stesso nome, anno e percorso con codici e CFU diversi (es. «Teorie politiche della contemporaneità»
            # da 6 e da 3 CFU): i CFU nel nome, altrimenti sembrano un doppione
            per_nome: dict[tuple, list[dict]] = {}
            for i in ins:
                per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"]), []).append(i)
            for g in per_nome.values():
                if len(g) > 1 and len({i["cfu"] for i in g}) > 1:
                    for i in g:
                        if isinstance(i["cfu"], (int, float)):
                            i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                        "durata_anni": corso.get("durata_anni"), "url": url, "curricula": sorted(curricula) or None,
                        "fonte": url, "verificato_il": oggi, "insegnamenti": ins})
        return out

    def build_safe(gruppo) -> list[dict]:
        try:
            return build(gruppo)
        except Exception as e:  # noqa: BLE001 - si salta solo quel gruppo
            log(f"[{uid}]   pagina {gruppo[0]} saltata: {e!r}")
            return []

    with cf.ThreadPoolExecutor(4) as ex:
        out = [x for r in ex.map(build_safe, abbinati) for x in r]
    jobs: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    riusa = riusa or {}
    da_leggere = [u for u in jobs if u not in riusa]
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(da_leggere) if syllabus else 0} (già raccolte: {len(jobs) - len(da_leggere)})")

    def applica(u: str, d: dict) -> None:
        for it in jobs[u]:
            it["periodo"] = d["periodo"]
            it["libri"] = d["libri"]
            it["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"

    for u in jobs:
        if u in riusa:
            applica(u, riusa[u])

    def scheda(u: str) -> int:
        try:
            r = c.get(u)
            if not r:
                return 0
            d = leggi_scheda(r.text)
            applica(u, d)
            return len(d["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, da_leggere), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(da_leggere)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da of.uniupo.it, Didattica erogata (adapters/uniupo.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
