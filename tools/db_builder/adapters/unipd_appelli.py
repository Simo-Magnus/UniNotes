"""Università di Padova: date d'esame dal calendario esami pubblico per corso di studio.

L'Agenda studenti di UniPD (EasyAcademy, `agendastudentiunipd.easystaff.it`, «Calendario
esami per corso di studio», collegato dalle pagine «Calendario esami» delle Scuole) pubblica
per ogni corso e anno gli appelli dell'intero anno accademico, con il codice Esse3
dell'attività (`CodiceGenerale`, lo stesso del Course Catalogue), data, ora, aula e tipo
d'esame. La bacheca appelli di Uniweb (Esse3) ha invece solo gli appelli già aperti alle
iscrizioni: da lì si aggiungono i periodi d'iscrizione e le date che l'agenda non ha.

Non si salvano email né altri contatti dei docenti, solo i nomi.
"""
from __future__ import annotations

import json
import re
import time
from datetime import date

import requests

from .esse3_appelli import fetch_appelli as fetch_esse3

BASE = "https://agendastudentiunipd.easystaff.it"
PAGINA = f"{BASE}/index.php?view=easytest&include=et_cdl&_lang=it"
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
           "Referer": PAGINA}


def _modalita(t: str) -> str | None:
    t = (t or "").lower()
    if "scritt" in t and "oral" in t:
        return "scritto+orale"
    for k, v in (("scritt", "scritto"), ("oral", "orale"), ("progett", "progetto"), ("pratic", "altro"),
                 ("quiz", "quiz"), ("test", "quiz"), ("moodle", "altro")):
        if k in t:
            return v
    return t.strip() or None


def _docenti(lst) -> str | None:
    nomi = [f"{(d.get('Cognome') or '').strip()} {(d.get('Nome') or '').strip()}".strip().upper()
            for d in lst or [] if isinstance(d, dict)]
    return ", ".join(n for n in dict.fromkeys(nomi) if n) or None


def corsi_agenda(s: requests.Session) -> dict[str, dict]:
    r = s.get(f"{BASE}/combo.php?sw=et_&page=corsi", headers=HEADERS, timeout=60)
    m = re.search(r"var esami_cdl\s*=\s*(\{.*?\});", r.text, re.S)
    return json.loads(m.group(1)) if m else {}


def esami_corso(s: requests.Session, cdl: str, dal: str, al: str) -> dict:
    data = [("view", "easytest"), ("form-type", "et_cdl"), ("include", "et_cdl"), ("et_er", "1"),
            ("esami_cdl", cdl)] + [("anno2[]", str(a)) for a in range(1, 7)] + \
           [("datefrom", dal), ("dateto", al), ("_lang", "it")]
    for tentativo in range(3):
        try:
            r = s.post(f"{BASE}/test_call.php", data=data, headers=HEADERS, timeout=120)
            r.raise_for_status()
            return r.json()
        except (requests.RequestException, ValueError):
            time.sleep(5 * (tentativo + 1))
    return {}


def fetch_agenda(anno: int, log=print, delay: float = 1.0) -> dict[str, list[dict]]:
    s = requests.Session()
    cdl = corsi_agenda(s)
    dal, al = f"01-10-{anno}", f"30-09-{anno + 1}"
    fonte = PAGINA
    out: dict[str, list[dict]] = {}
    for i, cod in enumerate(sorted(cdl), 1):
        d = esami_corso(s, cod, dal, al)
        ins = d.get("Insegnamenti") or {}
        for v in (ins.values() if isinstance(ins, dict) else ins):
            di = v.get("DatiInsegnamento") or {}
            codice = (di.get("CodiceGenerale") or "").strip()
            if not codice:
                continue
            for a in v.get("Appelli") or []:
                if str(a.get("event_Annullato") or "0") != "0":
                    continue
                m = re.match(r"(\d{2})-(\d{2})-(\d{4})", a.get("Data") or "")
                if not m:
                    continue
                tipo_t = f"{a.get('Tipo') or ''} {a.get('TipoEsame') or ''}".lower()
                aula = (a.get("aula_sede") or "").strip() or None
                e = {
                    "tipo": "prova_in_itinere" if re.search(r"parzial|itinere|intermedi|esonero", tipo_t) else "appello",
                    "titolo": (di.get("Nome") or "").strip() or None,
                    "data": f"{m.group(3)}-{m.group(2)}-{m.group(1)}",
                    "ora": (a.get("OraInizio") or "").strip() or None,
                    "luogo": aula if aula and aula not in ("[]", "-") else None,
                    "modalita": _modalita(a.get("TipoEsame") or ""),
                    "iscrizioni_dal": None, "iscrizioni_al": None,
                    "docenti": _docenti(a.get("event_docenti") or v.get("DatiDocente")),
                    "note": re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", a.get("Notes") or "")).strip() or None,
                    "fonte": fonte,
                }
                lst = out.setdefault(codice, [])
                if not any((x["data"], x["ora"], x["tipo"]) == (e["data"], e["ora"], e["tipo"]) for x in lst):
                    lst.append(e)
        if i % 25 == 0:
            log(f"[unipd] agenda esami: {i}/{len(cdl)} corsi, {len(out)} insegnamenti")
        time.sleep(delay)
    log(f"[unipd] agenda esami: {len(cdl)} corsi, {len(out)} insegnamenti con appelli, "
        f"{sum(len(v) for v in out.values())} date")
    return out


def unisci(agenda: dict[str, list[dict]], esse3: dict[str, list[dict]]) -> dict[str, list[dict]]:
    """Le date dell'agenda, con il periodo d'iscrizione di Uniweb quando c'è lo stesso appello
    (stessa data), più le date che sono solo su Uniweb."""
    out = {k: [dict(e) for e in v] for k, v in agenda.items()}
    for cod, lst in esse3.items():
        cur = out.setdefault(cod, [])
        for e in lst:
            same = [x for x in cur if x["data"] == e["data"] and x["tipo"] == e["tipo"]]
            if same:
                for x in same:
                    x["iscrizioni_dal"] = x["iscrizioni_dal"] or e.get("iscrizioni_dal")
                    x["iscrizioni_al"] = x["iscrizioni_al"] or e.get("iscrizioni_al")
            else:
                cur.append(dict(e))
        cur.sort(key=lambda x: (x["data"], x["ora"] or ""))
    return out


def fetch_appelli(uid: str = "unipd", corsi=None, anno: int | None = None, log=print) -> dict[str, list[dict]]:
    if anno is None:
        oggi = date.today()
        anno = oggi.year if oggi.month >= 9 else oggi.year - 1
    agenda = fetch_agenda(anno, log=log)
    try:
        esse3 = fetch_esse3(uid, "https://uniweb.unipd.it", log=log)
    except Exception as e:  # noqa: BLE001 - l'agenda basta
        log(f"[{uid}] esse3: {e!r}")
        esse3 = {}
    return unisci(agenda, esse3)
