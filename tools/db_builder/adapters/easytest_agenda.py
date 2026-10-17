"""Calendario esami pubblico di «Agenda Web» / EasyAcademy (modulo EasyTest), senza login.

Alcuni atenei (UniPD, UniMI) pubblicano il calendario degli esami per corso di studio nell'Agenda studenti
(`<host>/index.php?view=easytest&include=et_cdl`): l'elenco dei corsi è in `combo.php?sw=et_&page=corsi`
(variabile `esami_cdl`) e gli appelli di un corso si leggono con `POST test_call.php` (corso, anni, intervallo di
date). Per ogni insegnamento: codice generale (`CodiceGenerale`), nome e per ogni appello data, ora, aula,
tipo di prova e se è annullato. Gli altri host EasyAcademy (UniGE, UniTN, UniVE, UniMoRe, UniPG…) rimandano al
«Portale di Autenticazione»: non si usano.

Non si salvano email né altri contatti dei docenti, solo i nomi. Al massimo 1 richiesta al secondo.
"""
from __future__ import annotations

import json
import re
import time

import requests

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}


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
    if isinstance(lst, dict):
        lst = list(lst.values())
    nomi = [f"{(d.get('Cognome') or '').strip()} {(d.get('Nome') or '').strip()}".strip().upper()
            for d in lst or [] if isinstance(d, dict)]
    return ", ".join(n for n in dict.fromkeys(nomi) if n) or None


class Agenda:
    def __init__(self, base: str, delay: float = 1.0):
        self.base = base.rstrip("/")
        self.pagina = f"{self.base}/index.php?view=easytest&include=et_cdl&_lang=it"
        self.s = requests.Session()
        self.h = dict(HEADERS, Referer=self.pagina)
        self.delay = delay
        self.requests = 0

    def corsi(self) -> dict[str, dict]:
        r = self.s.get(f"{self.base}/combo.php?sw=et_&page=corsi", headers=self.h, timeout=60)
        self.requests += 1
        m = re.search(r"var esami_cdl\s*=\s*(\{.*?\});", r.text, re.S)
        return json.loads(m.group(1)) if m else {}

    def esami_corso(self, cdl: str, dal: str, al: str) -> dict:
        data = [("view", "easytest"), ("form-type", "et_cdl"), ("include", "et_cdl"), ("et_er", "1"),
                ("esami_cdl", cdl)] + [("anno2[]", str(a)) for a in range(1, 7)] + \
               [("datefrom", dal), ("dateto", al), ("_lang", "it")]
        for tentativo in range(3):
            time.sleep(self.delay)
            self.requests += 1
            try:
                r = self.s.post(f"{self.base}/test_call.php", data=data, headers=self.h, timeout=120)
                r.raise_for_status()
                return r.json()
            except (requests.RequestException, ValueError):
                time.sleep(5 * (tentativo + 1))
        return {}


def leggi_corso(d: dict, fonte: str) -> dict[str, list[dict]]:
    """{CodiceGenerale: [esame, …]} da una risposta di test_call.php."""
    out: dict[str, list[dict]] = {}
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
            aula = (a.get("Aula") or a.get("aula_sede") or "").strip()
            sede = (a.get("Sede") or "").strip()
            luogo = ", ".join(x for x in (aula, sede) if x and x not in ("[]", "-")) or None
            ora = (a.get("OraInizio") or "").strip()
            e = {
                "tipo": "prova_in_itinere" if re.search(r"parzial|itinere|intermedi|esonero", tipo_t) else "appello",
                "titolo": (di.get("Nome") or "").strip() or None,
                "data": f"{m.group(3)}-{m.group(2)}-{m.group(1)}",
                "ora": ora if re.fullmatch(r"\d{1,2}:\d{2}", ora) else None,
                "luogo": luogo,
                "modalita": _modalita(a.get("TipoEsame") or ""),
                "iscrizioni_dal": None, "iscrizioni_al": None,
                "docenti": _docenti(a.get("event_docenti") or v.get("DatiDocente")),
                "note": re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", a.get("Notes") or "")).strip() or None,
                "fonte": fonte,
            }
            lst = out.setdefault(codice, [])
            if not any((x["data"], x["ora"], x["tipo"]) == (e["data"], e["ora"], e["tipo"]) for x in lst):
                lst.append(e)
    return out


def fetch_agenda(base: str, anno: int, cdl_ammessi: set[str] | None = None, log=print,
                 delay: float = 1.0) -> dict[str, list[dict]]:
    """Appelli dell'a.a. `anno`/`anno+1` per i corsi dell'Agenda (solo `cdl_ammessi` se dato)."""
    ag = Agenda(base, delay)
    cdl = ag.corsi()
    dal, al = f"01-10-{anno}", f"30-09-{anno + 1}"
    out: dict[str, list[dict]] = {}
    scelti = sorted(c for c in cdl if cdl_ammessi is None or c in cdl_ammessi)
    for i, cod in enumerate(scelti, 1):
        for k, lst in leggi_corso(ag.esami_corso(cod, dal, al), ag.pagina).items():
            cur = out.setdefault(k, [])
            for e in lst:
                if not any((x["data"], x["ora"], x["tipo"]) == (e["data"], e["ora"], e["tipo"]) for x in cur):
                    cur.append(e)
        if i % 25 == 0:
            log(f"[agenda {base}] {i}/{len(scelti)} corsi, {len(out)} insegnamenti")
    log(f"[agenda {base}] {len(scelti)} corsi (su {len(cdl)}), {len(out)} insegnamenti con appelli, "
        f"{sum(len(v) for v in out.values())} date; richieste: {ag.requests}")
    return out
