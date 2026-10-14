"""Appelli d'esame dell'Università di Bologna dalle pagine "Appelli d'esame" dei siti dei corsi.

AlmaEsami (iscrizioni) richiede il login, ma ogni sito di corso pubblica gli appelli in
`corsi.unibo.it/<laurea|magistrale|…>/<Nome>/appelli` (20 insegnamenti per pagina,
`?b_start:int=20`, …): per ogni insegnamento codice, nome e docente
(`<span class="code">`, `<span class="docente">`) e una tabella per appello con "Data e ora",
"Lista iscrizioni" (dal … al …), "Tipo prova", "Luogo" e "Note".
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import pathlib
import re

from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
MESI = {m: i for i, m in enumerate(["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto",
                                    "settembre", "ottobre", "novembre", "dicembre"], 1)}
MESI.update({m: i for i, m in enumerate(["january", "february", "march", "april", "may", "june", "july", "august",
                                         "september", "october", "november", "december"], 1)})
TIPI = {"laurea", "magistrale", "magistralecu", "1cycle", "2cycle", "singlecycle"}
DATA = re.compile(r"(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})(?:\s+(?:ore|at|h)?\s*(\d{1,2})[:.](\d{2}))?")


def _data(s: str) -> tuple[str | None, str | None]:
    m = DATA.search(s or "")
    if not m or m.group(2).lower() not in MESI:
        return None, None
    d = f"{m.group(3)}-{MESI[m.group(2).lower()]:02d}-{int(m.group(1)):02d}"
    return d, f"{int(m.group(4)):02d}:{m.group(5)}" if m.group(4) else None


def _modalita(p: str) -> str | None:
    p = (p or "").lower()
    if not p:
        return None
    if ("scritt" in p or "written" in p) and ("oral" in p):
        return "scritto+orale"
    for k, v in (("scritt", "scritto"), ("written", "scritto"), ("oral", "orale"), ("test", "quiz"),
                 ("quiz", "quiz"), ("progett", "progetto"), ("project", "progetto")):
        if k in p:
            return v
    return "altro"


def leggi_pagina(s: str, fonte: str) -> list[tuple[str, dict]]:
    """[(codice, esame)] di una pagina di appelli."""
    out = []
    blocchi = re.split(r'<h3[^>]*role="tab"', s)[1:]
    for b in blocchi:
        cod = re.search(r'<span class="code">(.*?)</span>', b, re.S)
        if not cod:
            continue
        doc = re.search(r'<span class="docente">(.*?)</span>', b, re.S)
        testa = re.search(r'<a class="openclose-appelli"[^>]*>(.*?)</a>', b, re.S)
        nome = _testo(re.sub(r'<span class="(?:code|docente)">.*?</span>', "", testa.group(1), flags=re.S)) if testa else None
        for tab in re.findall(r'<table class="single-item">(.*?)</table>', b, re.S):
            campi = {_testo(k).rstrip(":").lower(): v for k, v in
                     re.findall(r"<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>", tab, re.S)}
            def campo(*chiavi: str) -> str:
                return next((v for k, v in campi.items() if any(c in k for c in chiavi)), "")

            data, ora = _data(_testo(campo("data e ora", "when", "date")))
            if not data:
                continue
            iscr = re.findall(r"<span>(.*?)</span>", campo("iscrizioni", "subscription", "registration"))
            prova = _testo(campo("tipo prova", "test type", "type"))
            note = _testo(campo("note")) or None
            out.append((_testo(cod.group(1)), {
                "tipo": "prova_in_itinere" if re.search(r"(?i)parzial|itinere|intermedi|partial", f"{prova} {note or ''}")
                else "appello",
                "titolo": nome or None, "data": data, "ora": ora,
                "luogo": _testo(campo("luogo", "place", "location", "where")) or None,
                "modalita": _modalita(prova),
                "iscrizioni_dal": _data(_testo(iscr[0]))[0] if len(iscr) >= 1 else None,
                "iscrizioni_al": _data(_testo(iscr[1]))[0] if len(iscr) >= 2 else None,
                "docenti": _testo(doc.group(1)) if doc else None, "note": note, "fonte": fonte}))
    return out


def fetch_appelli(uid: str = "unibo", corsi: list[dict] | None = None, log=print) -> dict[str, list[dict]]:
    """{codice insegnamento: [esame, …]} dalle pagine appelli dei siti dei corsi."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    siti: dict[str, str] = {}
    for u in [x.get(k) for x in corsi for k in ("url", "url_catalogo")] + \
             [i.get("fonte") for x in corsi for i in x.get("insegnamenti") or []]:
        m = re.match(r"https?://corsi\.unibo\.it/([^?#]+)", u or "")
        if not m:
            continue
        parti = [p for p in m.group(1).split("/") if p]
        # corsi.unibo.it/<tipo>/<Nome> o, per alcuni corsi, corsi.unibo.it/<nome>
        n = 2 if len(parti) >= 2 and parti[0].lower() in TIPI else 1
        base = "https://corsi.unibo.it/" + "/".join(parti[:n])
        siti.setdefault(base.lower(), base)
    siti = sorted(siti.values(), key=str.lower)
    c = Client(rate=4.0)

    def sito(base: str) -> list[tuple[str, dict]]:
        out, visti = [], set()
        for k in range(0, 2000, 20):
            pagina = "exam-dates" if re.search(r"(?i)/(?:\dcycle|singlecycle)/", base) else "appelli"
            url = f"{base}/{pagina}" + (f"?b_start:int={k}" if k else "")
            r = c.get(url)
            righe = leggi_pagina(r.text, url) if r else []
            nuovi = {(cod, e["docenti"], e["titolo"]) for cod, e in righe} - visti
            if not righe or not nuovi:
                break
            visti |= nuovi
            out += righe
            if f"b_start:int={k + 20}" not in r.text:
                break
        return out

    res: dict[str, dict[tuple, dict]] = {}
    with cf.ThreadPoolExecutor(4) as ex:
        for righe in ex.map(sito, siti):
            for cod, e in righe:  # stesso appello per più docenti o corsi: uno solo con tutti i docenti
                v = res.setdefault(cod, {}).setdefault((e["data"], e["ora"], e["tipo"]), dict(e))
                if e["docenti"] and e["docenti"] not in (v["docenti"] or "").split(", "):
                    v["docenti"] = ", ".join(x for x in (v["docenti"], e["docenti"]) if x)
    fin = {k: sorted(v.values(), key=lambda e: (e["data"], e["ora"] or "")) for k, v in res.items()}
    # moduli dei corsi integrati: le pagine degli appelli riportano il codice del corso integrato
    # (la riga "padre" del piano, campo interno `_ci` messo da adapters/unibo.py), non dei moduli
    moduli = 0
    for x in corsi:
        for i in x.get("insegnamenti") or []:
            ci, cod = i.pop("_ci", None), i.get("codice")
            if ci and cod and cod not in fin and ci in fin:
                fin[cod] = [dict(e, note="; ".join(n for n in (
                    f"Esame del corso integrato {ci} {e.get('titolo') or ''}".strip(), e.get("note")) if n))
                    for e in fin[ci]]
                moduli += 1
    if moduli:
        log(f"[{uid}] appelli dei corsi integrati assegnati a {moduli} codici di modulo")
    log(f"[{uid}] appelli: {len(siti)} siti, {sum(len(v) for v in fin.values())} date per {len(fin)} insegnamenti; "
        f"richieste: {c.requests}")
    return fin
