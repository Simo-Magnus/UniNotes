"""Semestre degli insegnamenti «annuali» di UniPa dalla scheda di trasparenza (riga «PERIODO DELLE LEZIONI»).

Il periodo del database nasce dai dati aperti dell'ateneo (`dati.unipa.it/dataset/offerta-formativa-….csv`, colonne
SEMESTRE e ANNUALITA: 1,0 = annualità intera). La scheda di trasparenza PDF di ogni insegnamento
(`offertaformativa.unipa.it/offweb/schedaTrasparenza?lingua=ITA&oidCurrInsegnamento=<idInsegnamento>`, lo stesso
`idInsegnamento` del link nella «Didattica erogata» del sito del corso) dice invece «Annuale», «1° semestre» o
«2° semestre»: su un campione di 14 annuali del CSV 13 erano annuali e 1 era del 2° semestre («Cultura del libro»).
Qui si rilegge la scheda dei soli insegnamenti oggi «annuale» e, se dice un semestre preciso, quello prevale sul CSV
(la fonte diventa la scheda); se conferma «Annuale» si tiene annuale con la scheda come fonte; se la scheda non si
trova, non si legge o dice altro il valore del CSV resta com'è.

Se il sito risponde con altro che un PDF per 3 schede di fila (CAPTCHA/firewall) ci si ferma, senza insistere.
Al massimo ~1 richiesta al secondo; cache su disco in `$UN_HTTP_CACHE/periodi_unipa` (se impostata).
"""
from __future__ import annotations

import hashlib
import os
import re
import time

import requests

from . import periodi
from .unibo import HEADERS, Client
from .unipa import PAGINE_EXTRA, SCHEDA, _bundle, leggi_erogata, leggi_scheda_pdf


def _pdf(url: str, cache: str | None, stato: dict) -> bytes | None:
    f = os.path.join(cache, hashlib.sha1(url.encode()).hexdigest() + ".pdf") if cache else None
    if f and os.path.exists(f):
        return open(f, "rb").read()
    if stato["firewall"] >= 3:
        return None
    w = stato["ultima"] + 1.0 - time.monotonic()
    if w > 0:
        time.sleep(w)
    stato["ultima"] = time.monotonic()
    try:
        r = requests.get(url, headers=HEADERS, timeout=120, verify=_bundle())
    except requests.RequestException:
        return None
    if r.status_code != 200 or not r.content.startswith(b"%PDF"):
        stato["firewall"] += 1
        return None
    stato["firewall"] = 0
    if f:
        open(f, "wb").write(r.content)
    return r.content


def fetch_periodi(uid: str = "unipa", log=print) -> dict[str, dict]:
    d = os.environ.get("UN_HTTP_CACHE")
    cache = os.path.join(d, "periodi_unipa") if d else None
    if cache:
        os.makedirs(cache, exist_ok=True)
    stato = {"ultima": 0.0, "firewall": 0}
    c = Client(rate=4.0)
    db = periodi.carica(uid)
    out: dict[str, dict] = {}
    n_annuali = senza_id = 0
    esito = {"annuale": 0, "1": 0, "2": 0, "illeggibile": 0, "discordi": 0}
    for corso in db["corsi"]:
        bersagli = [i for i in corso.get("insegnamenti") or [] if i.get("periodo") == "annuale"]
        if not bersagli:
            continue
        n_annuali += len(bersagli)
        base = corso.get("url")
        pagine = [base] + PAGINE_EXTRA.get(corso["id"], [])
        ids: dict[tuple, list[str]] = {}  # (anno, codice) -> idInsegnamento
        for b in pagine:
            r = c.get(b.rstrip("/") + "/?pagina=insegnamenti") if b else None
            for x in leggi_erogata(r.text) if r else []:
                if x["id_ins"] and x["codice"]:
                    ids.setdefault((x["anno"], x["codice"]), [])
                    if x["id_ins"] not in ids[(x["anno"], x["codice"])]:
                        ids[(x["anno"], x["codice"])].append(x["id_ins"])
        for i in bersagli:
            cand = ids.get((i.get("anno"), i.get("codice"))) or []
            if not cand:
                senza_id += 1
                continue
            letti = {}
            for pid in cand:
                dati = _pdf(SCHEDA + pid, cache, stato)
                p = leggi_scheda_pdf(dati)["periodo"] if dati else None
                if p:
                    letti[pid] = p
            valori = set(letti.values())
            if not valori:
                esito["illeggibile"] += 1
            elif len(valori) > 1:
                esito["discordi"] += 1  # cattedre con periodi diversi: non si sceglie
            else:
                p = valori.pop()
                esito[p] += 1
                out[i["id"]] = {"periodo": p, "fonte": SCHEDA + next(iter(letti))}
        if stato["firewall"] >= 3:
            log(f"[{uid}] il sito chiede il CAPTCHA: letture interrotte")
            break
    log(f"[{uid}] annuali {n_annuali}; senza idInsegnamento nella didattica erogata {senza_id}; schede: {esito}")
    return out


if __name__ == "__main__":
    r = fetch_periodi()
    print(periodi.scrivi("unipa", r))
