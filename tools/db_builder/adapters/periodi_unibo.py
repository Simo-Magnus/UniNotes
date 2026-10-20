"""Periodo didattico degli insegnamenti UniBo che il piano didattico non riporta.

Il piano di corsi.unibo.it (adapters/unibo.py) ha la colonna «periodo» solo per alcuni corsi di
studio; per gli altri il periodo si legge nella scheda ufficiale dell'insegnamento su www.unibo.it,
che riporta le date delle lezioni: «Orario delle lezioni [(Modulo N)] dal GG/MM/AAAA al GG/MM/AAAA»
(in inglese «Course Timetable [(Module N)] from Mon GG, AAAA to Mon GG, AAAA»). Le date passano
così come sono (periodo_inizio/periodo_fine): build_db le converte in semestre con pulizia.periodo.
Con più moduli si prende dal primo inizio all'ultima fine. Se la scheda non pubblica l'orario non
si scrive nulla (il periodo non si deduce da anno di corso, codice o nome).
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import re
import sys
from datetime import datetime

from . import periodi
from .periodi import DB, ROOT
from .unibo import Client, _testo, segui_risultato

IT = re.compile(r"Orario delle lezioni(?: \([^)]*\))? dal (\d\d/\d\d/\d{4}) al (\d\d/\d\d/\d{4})")
EN = re.compile(r"Course Timetable(?: \([^)]*\))? from ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4}) to ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4})")


def _data_en(s: str) -> str | None:
    s = s.replace(".", "")
    for f in ("%b %d, %Y", "%B %d, %Y"):
        try:
            return datetime.strptime(s, f).strftime("%d/%m/%Y")
        except ValueError:
            pass
    return None


def date_lezioni(html_scheda: str) -> tuple[str, str] | None:
    """(inizio, fine) GG/MM/AAAA delle lezioni dalla scheda, o None se non pubblicate."""
    t = re.sub(r"<(script|style).*?</\1>", " ", html_scheda, flags=re.S)
    t = _testo(t)
    coppie = IT.findall(t)
    if not coppie:
        coppie = [(_data_en(a), _data_en(b)) for a, b in EN.findall(t)]
        coppie = [(a, b) for a, b in coppie if a and b]
    if not coppie:
        return None
    k = lambda d: datetime.strptime(d, "%d/%m/%Y")  # noqa: E731
    return min((a for a, _ in coppie), key=k), max((b for _, b in coppie), key=k)


def fetch_periodi(uid: str = "unibo", log=print) -> dict:
    mancanti = periodi.mancanti(uid)
    per_url: dict[str, list[dict]] = {}
    for m in mancanti:
        if m.get("url"):
            per_url.setdefault(m["url"], []).append(m)
    log(f"[{uid}] {len(mancanti)} insegnamenti senza periodo, {len(per_url)} schede da leggere")
    c = Client(rate=1.6)
    ris: dict[str, dict] = {}

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if r and not re.search(r"/(insegnamento|course-unit)/\d{4}/", r.url):
                r = segui_risultato(c, r.text, per_url[url][0].get("codice"))
            if not r:
                return 0
            d = date_lezioni(r.text)
            if not d:
                return 0
            for m in per_url[url]:
                ris[m["id"]] = {"periodo": None, "periodo_inizio": d[0], "periodo_fine": d[1], "fonte": r.url}
            return len(per_url[url])
        except Exception as e:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            log(f"[{uid}]   {url}: {e!r}")
            return 0

    n = 0
    with cf.ThreadPoolExecutor(4) as ex:
        for k, v in enumerate(ex.map(scheda, list(per_url)), 1):
            n += v
            if k % 200 == 0:
                log(f"[{uid}]   schede {k}/{len(per_url)}: periodi trovati {n}")
    log(f"[{uid}] periodi trovati: {len(ris)}; richieste: {c.requests}")
    return ris


# --- insegnamenti «annuali» le cui lezioni sono in un solo semestre ---------------------------------
# I codici di anno intero del piano (E, A, ...) dicono solo che l'insegnamento ha un esame nell'anno: la scheda
# dice quando sono le lezioni. Si corregge il semestre solo quando la scheda è inequivocabile:
#  - c'è un orario delle lezioni per ogni modulo dell'insegnamento (o uno solo, senza moduli, o uno non riferito
#    a un modulo che vale per tutto l'insegnamento): se l'orario di un modulo manca (di solito è il secondo
#    semestre, non ancora pubblicato) il periodo resta com'è;
#  - tutte le lezioni sono entro il 31/01 (1° semestre) o dal 01/02 in poi (2° semestre), nello stesso anno
#    accademico. Moduli in semestri diversi o date a cavallo restano annuali.
# Chi ha un codice numerico (1, 2, ...) nel piano non si tocca: vale il codice del piano.
# Le date vere delle lezioni passano come periodo_inizio/periodo_fine: pulizia.periodo dà la precedenza alle
# date, e quelle del piano (l'anno intero) darebbero di nuovo «annuale».
NOME_FILE_LEZIONI = "unibo_semestri_periodi.json"  # build_db applica per ultimi i *_periodi.json, in ordine alfabetico: questo dopo unibo_periodi.json
IT_M = re.compile(r"Orario delle lezioni(?: \(([^)]*)\))? dal (\d\d/\d\d/\d{4}) al (\d\d/\d\d/\d{4})")
EN_M = re.compile(r"Course Timetable(?: \(([^)]*)\))? from ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4}) to ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4})")
MODULO = re.compile(r"(?:Modulo|Module)\s+(\S.*)", re.I)
MODULO_CITATO = re.compile(r"\((?:Modulo|Module)\s+([^)]+)\)")
CODICE_NUMERICO = re.compile(r"\d(?:\s*,\s*\d)*")


def lezioni(html_scheda: str) -> tuple[list[tuple[str | None, datetime, datetime]], set[str]]:
    """([(modulo|None, inizio, fine)] degli orari delle lezioni, etichette di tutti i moduli citati nella scheda)."""
    t = re.sub(r"<(script|style).*?</\1>", " ", html_scheda, flags=re.S)
    t = _testo(t)
    voci = {m.groups() for m in IT_M.finditer(t)}
    if not voci:
        for m in EN_M.finditer(t):
            a, b = _data_en(m.group(2)), _data_en(m.group(3))
            if a and b:
                voci.add((m.group(1), a, b))
    out = []
    for lab, a, b in voci:
        if lab:
            m = MODULO.fullmatch(lab.strip())
            lab = m.group(1).strip() if m else "?"
        out.append((lab or None, datetime.strptime(a, "%d/%m/%Y"), datetime.strptime(b, "%d/%m/%Y")))
    return out, {x.strip() for x in MODULO_CITATO.findall(t)}


def semestre_lezioni(voci: list[tuple[str | None, datetime, datetime]], moduli: set[str]) -> tuple[str | None, str]:
    """(semestre "1"|"2" o None, motivo). Il motivo spiega perché non si decide."""
    if not voci:
        return None, "nessun orario"
    etichette = {v[0] for v in voci}
    if "?" in etichette:
        return None, "modulo non riconosciuto"
    if None not in etichette and not moduli <= etichette:
        return None, "orario di alcuni moduli non pubblicato"
    a, b = min(v[1] for v in voci), max(v[2] for v in voci)
    if b < a:
        return None, "date incoerenti"
    anno = a.year if a.month >= 8 else a.year - 1  # anno accademico
    if a >= datetime(anno, 8, 1) and b <= datetime(anno + 1, 1, 31):
        return "1", "ok"
    if a >= datetime(anno + 1, 2, 1) and b <= datetime(anno + 1, 9, 30):
        return "2", "ok"
    return None, "moduli in semestri diversi" if len(voci) > 1 else "lezioni a cavallo dei semestri"


def candidati_annuali(uid: str = "unibo") -> list[dict]:
    """Insegnamenti oggi «annuale» con una scheda e senza codice numerico di periodo nel piano."""
    sys.path.insert(0, str(ROOT / "tools" / "db_builder"))
    from build_db import assegna_id  # noqa: PLC0415 - gli id dei contributi li assegna build_db
    contrib = json.loads((DB / "contrib" / "auto" / f"{uid}.json").read_text(encoding="utf-8"))
    codice: dict[str, str | None] = {}
    for c in contrib["corsi"]:
        for i in assegna_id(c["id"], c.get("insegnamenti") or []):
            codice[i["id"]] = i.get("periodo")
    out = []
    for c in periodi.carica(uid)["corsi"]:
        if c.get("piano_da"):
            continue
        for i in c.get("insegnamenti") or []:
            if i.get("periodo") != "annuale" or not i.get("url") or periodi.NON.search(i.get("nome") or ""):
                continue
            cod = codice.get(i["id"])
            if cod and CODICE_NUMERICO.fullmatch(str(cod).strip()):
                continue
            out.append({"corso": c["id"], "id": i["id"], "codice": i.get("codice"), "nome": i.get("nome"),
                        "url": i["url"], "cod_piano": cod})
    return out


def fetch_semestri_annuali(uid: str = "unibo", log=print) -> tuple[dict, dict]:
    """({id: risultato per periodi.scrivi}, {id: motivo per cui non si decide}) per gli annuali con scheda."""
    cand = candidati_annuali(uid)
    per_url: dict[str, list[dict]] = {}
    for m in cand:
        per_url.setdefault(m["url"], []).append(m)
    log(f"[{uid}] {len(cand)} insegnamenti annuali con scheda, {len(per_url)} schede da leggere")
    c = Client(rate=1.6)
    ris: dict[str, dict] = {}
    no: dict[str, str] = {}

    def scheda(url: str) -> None:
        try:
            r = c.get(url)
            if r and not re.search(r"/(insegnamento|course-unit)/\d{4}/", r.url):
                r = segui_risultato(c, r.text, per_url[url][0].get("codice"))
            if not r:
                voci, sem, motivo = [], None, "scheda non raggiungibile"
            else:
                voci, moduli = lezioni(r.text)
                sem, motivo = semestre_lezioni(voci, moduli)
        except Exception as e:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            log(f"[{uid}]   {url}: {e!r}")
            return
        for m in per_url[url]:
            if sem:
                ris[m["id"]] = {"periodo": sem, "fonte": r.url,
                                "periodo_inizio": min(v[1] for v in voci).strftime("%d/%m/%Y"),
                                "periodo_fine": max(v[2] for v in voci).strftime("%d/%m/%Y")}
            else:
                no[m["id"]] = motivo

    with cf.ThreadPoolExecutor(4) as ex:
        for k, _ in enumerate(ex.map(scheda, list(per_url)), 1):
            if k % 100 == 0:
                log(f"[{uid}]   schede {k}/{len(per_url)}: semestre deciso per {len(ris)} insegnamenti")
    log(f"[{uid}] semestre deciso: {len(ris)}; restano annuali: {len(no)}; richieste: {c.requests}")
    return ris, no


def scrivi_semestri_annuali(uid: str = "unibo", log=print) -> dict:
    """Legge le schede e scrive database/contrib/auto/unibo_semestri_periodi.json (build_db applica per ultimi i *_periodi.json
    in ordine alfabetico: questo viene dopo unibo_periodi.json)."""
    ris, no = fetch_semestri_annuali(uid, log)
    n, scartati = periodi.scrivi(uid, ris, unisci=False, nome_file=NOME_FILE_LEZIONI)
    log(f"[{uid}] scritti {n} insegnamenti in {NOME_FILE_LEZIONI} (scartati {scartati})")
    return {"scritti": n, "annuali": no}
