"""Semestre degli insegnamenti dell'Università Suor Orsola Benincasa dal servizio LePrE «Orari delle lezioni».

`/universita/facolta/<dip>/lepre/lezioni.asp` (form R1 corso, R3 tipologia, R4 anno, R5 modalità elenco,
R2 ordinamento) elenca per ogni insegnamento «Semestre di svolgimento: I semestre | II semestre |
annuale» (più date di inizio e fine delle lezioni). L'abbinamento con gli insegnamenti del db è per
corso (stesso criterio di adapters/unisob.py) e nome normalizzato; se lo stesso nome compare con
semestri diversi nello stesso corso non si scrive nulla. Se la scheda non indica il semestre
(orario non ancora pubblicato) l'insegnamento resta senza periodo.
"""
from __future__ import annotations

import difflib
import html
import re

from . import periodi
from .unibo import Client, _testo
from .unisob import BASE, DIPARTIMENTI, _norm, _scarica

SEM = re.compile(r"Semestre di svolgimento:\s*([^<]+)")


def _codice(s: str) -> str | None:
    s = s.strip().lower()
    if s in ("i semestre", "primo semestre", "1 semestre"):
        return "1"
    if s in ("ii semestre", "secondo semestre", "2 semestre"):
        return "2"
    if s == "annuale":
        return "annuale"
    return None


def leggi_lezioni(s: str) -> list[tuple[str, str, str | None]]:
    """[(nome normalizzato, codice periodo, idp della scheda corso.asp)] dai blocchi della pagina dell'elenco."""
    out = []
    for b in re.findall(r'<div class="sfondolepre">(.*?)</div>', s, re.S):
        nome = re.search(r"<a[^>]*href=\"corso\.asp\?vr=1&amp;idp=(\d+)\"[^>]*>\s*<b>(.*?)</b>", b, re.S)
        sem = SEM.search(b)
        if not nome or not sem:
            continue
        cod = _codice(html.unescape(_testo(sem.group(1))))
        if cod:
            out.append((_norm(html.unescape(_testo(nome.group(2)))), cod, nome.group(1)))
    return out


def fetch_periodi(uid: str = "unisob", log=print) -> dict:
    db = periodi.carica(uid)
    manc = {m["id"]: m for m in periodi.mancanti(uid)}
    c = Client(rate=1.5)
    opzioni = []
    for d in DIPARTIMENTI:
        sel = re.search(r'name="R1".*?</select>', _scarica(c, BASE.format(d) + "lezioni.asp?vr=1"), re.S)
        opzioni += [(d, v, html.unescape(t).strip()) for v, t in
                    re.findall(r'<option[^>]*value="(\d+)"[^>]*>(.*?)</option>', sel.group(0) if sel else "")
                    if v != "0"]
    ris: dict[str, dict] = {}
    for corso in db["corsi"]:
        da_fare = [i for i in corso.get("insegnamenti") or [] if i["id"] in manc]
        if not da_fare:
            continue
        n = _norm(corso["nome"])
        punti = sorted(((difflib.SequenceMatcher(None, n, _norm(o[2])).ratio(), o) for o in opzioni), reverse=True)
        if not (punti and punti[0][0] >= 0.75 and (len(punti) == 1 or punti[0][0] - punti[1][0] > 0.05)):
            # «Conservazione e restauro dei beni culturali (abilitante …)» = «Conservazione e Restauro dei Beni Culturali»
            pref = [o for o in opzioni if len(_norm(o[2])) >= 20 and n.startswith(_norm(o[2]))]
            if len(pref) != 1:
                log(f"[{uid}] corso senza abbinamento nel LePrE: {corso['nome']}")
                continue
            punti = [(1.0, pref[0])]
        d, v, nome = punti[0][1]
        base = BASE.format(d)
        pagina = _scarica(c, base + "lezioni.asp?vr=1&mod=el", {"R1": v, "R3": "0", "R4": "0", "R5": "1", "R2": "1"})
        per_nome: dict[str, set[str]] = {}
        for k, cod, _ in leggi_lezioni(pagina):
            per_nome.setdefault(k, set()).add(cod)
        for i in da_fare:
            cod = per_nome.get(_norm(i["nome"]))
            if cod and len(cod) == 1:
                ris[i["id"]] = {"periodo": next(iter(cod)), "fonte": base + "lezioni.asp"}
        log(f"[{uid}] {corso['nome']}: {len(per_nome)} insegnamenti con semestre, {len(da_fare)} da valorizzare")
    # Insegnamenti non presenti nell'elenco del loro corso (es. attività a scelta offerte da altri corsi):
    # si cerca lo stesso nome negli elenchi degli altri corsi del LePrE e si accetta solo se la scheda
    # corso.asp di quell'insegnamento rimanda allo stesso programma (programma.asp?id=…) del db.
    resto = {i["id"]: i for corso in db["corsi"] for i in corso.get("insegnamenti") or []
             if i["id"] in manc and i["id"] not in ris and i.get("url")}
    if resto:
        voci: dict[str, list[tuple[str, str, str]]] = {}
        for d, v, nome in opzioni:
            base = BASE.format(d)
            pagina = _scarica(c, base + "lezioni.asp?vr=1&mod=el", {"R1": v, "R3": "0", "R4": "0", "R5": "1", "R2": "1"})
            for k, cod, idp in leggi_lezioni(pagina):
                voci.setdefault(k, []).append((cod, idp, base))
        for iid, i in resto.items():
            pid = re.search(r"[?&]id=(\d+)", i["url"])
            for cod, idp, base in dict.fromkeys(voci.get(_norm(i["nome"]), [])):
                scheda = _scarica(c, f"{base}corso.asp?vr=1&idp={idp}")
                if pid and re.search(rf"programma\.asp\?vr=1&amp;id={pid.group(1)}\"", scheda)                         and (m := SEM.search(scheda)) and _codice(html.unescape(_testo(m.group(1)))) == cod:
                    ris[iid] = {"periodo": cod, "fonte": f"{base}corso.asp?vr=1&idp={idp}"}
                    break
    log(f"[{uid}] periodi trovati: {len(ris)}; richieste: {c.requests}")
    return ris
