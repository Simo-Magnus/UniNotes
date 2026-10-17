"""Appelli d'esame dalla bacheca pubblica di Esse3 per corso di studio (`ListaAppelliOfferta.do`).

Generalizza l'adattatore di UniPG (`unipg_appelli`) a qualsiasi ateneo con Esse3 pubblico: la bacheca si
interroga un corso di studio per volta (le pagine già lette restano su disco con UN_HTTP_CACHE, in
`esse3_offerta/<uid>/`), gli appelli di un'attività didattica (AD) si attribuiscono all'insegnamento del
database con lo stesso codice e, se il codice è diverso, con lo stesso nome nel corso omonimo. Più la
bacheca per dipartimento (`esse3_appelli`), per le AD che non stanno in nessun corso dell'offerta.

Se Esse3 risponde con la verifica anti-bot di Cloudflare (HTTP 403, `cf-mitigated: challenge`) la raccolta
si ferma con `Esse3Bloccato`: la verifica non si aggira.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import pathlib
import re
import time

from .unipg_appelli import _nome_ad, _nome_corso

PAUSA = 0.6  # secondi tra le richieste allo stesso sito (massimo ~1,7 al secondo)


class Esse3Bloccato(RuntimeError):
    """Cloudflare (o un altro filtro) chiede la verifica anti-bot: si ferma, senza aggirarla."""


def _cache_dir(uid: str) -> pathlib.Path | None:
    d = os.environ.get("UN_HTTP_CACHE")
    if not d:
        return None
    p = pathlib.Path(d) / "esse3_offerta" / uid
    p.mkdir(parents=True, exist_ok=True)
    return p


def _inizio_aa() -> str:
    import datetime
    oggi = datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1).strftime("%d/%m/%Y")


def fetch_bacheca(uid: str, base: str, log=print, da: str | None = None, a: str = "31/12/2027"):
    """Appelli per corso di studio. Restituisce {etichetta corso Esse3: {AD: [appelli]}} e {AD: titolo}."""
    import requests

    from .esse3_appelli import HEADERS, _parse
    da = da or _inizio_aa()
    cache = _cache_dir(uid)
    s = requests.Session()
    s.headers.update(HEADERS)
    pagina = base.rstrip("/") + "/ListaAppelliOfferta.do"
    r = s.get(pagina, timeout=60)
    if r.status_code == 403 or r.headers.get("cf-mitigated"):
        raise Esse3Bloccato(f"{uid}: HTTP {r.status_code}, cf-mitigated={r.headers.get('cf-mitigated')}")
    form = re.search(r'<form action="([^"]+)" id="formRicercaCds"', r.text)
    if r.status_code != 200 or not form:
        log(f"[{uid}] esse3: bacheca per corso non disponibile (HTTP {r.status_code})")
        return {}, {}
    url = base.rstrip("/") + "/" + form.group(1).split(";")[0]
    dati0 = {"data_da": da, "data_a": a, "TIPO_FORM": "1", "form_id_formRicercaCds": "formRicercaCds"}
    sel = re.search(r'<select id="selectionFacolta".*?</select>', r.text, re.S)
    facs = re.findall(r'<option value="([^"]+)"', sel.group(0)) if sel else []

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                x = s.post(url, data=dati, timeout=240)
                if x.status_code == 403 or x.headers.get("cf-mitigated"):
                    raise Esse3Bloccato(f"{uid}: HTTP 403 durante la raccolta")
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            time.sleep(3 * (tentativo + 1))
        return None

    per_corso: dict[str, dict[str, list[dict]]] = {}
    titoli: dict[str, str] = {}
    for fac in facs:
        t = post({**dati0, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "", "_fw_refresh-form": "selectionFacolta"})
        time.sleep(PAUSA)
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        for cod, etichetta in (re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []):
            nome = re.sub(r"^\s*\[\w+\]\s*", "", html.unescape(etichetta)).strip()
            f = cache / (hashlib.sha1(f"{cod}|{nome}|{da}".encode()).hexdigest() + ".json") if cache else None
            if f and f.exists():
                got = json.loads(f.read_text(encoding="utf-8"))
            else:
                t = post({**dati0, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
                time.sleep(PAUSA)
                if t is None:
                    log(f"[{uid}] esse3: corso {cod} {nome} non letto")
                    continue
                got = _parse(t.replace("Date e ora del turno", "Data e ora del turno"), pagina)
                if f:
                    f.write_text(json.dumps(got, ensure_ascii=False), encoding="utf-8")
            d = per_corso.setdefault(nome, {})
            for ad, lst in got.items():
                titoli.setdefault(ad, lst[0].get("titolo") or "")
                v = d.setdefault(ad, [])
                viste = {(x["data"], x["ora"], x["tipo"]) for x in v}
                v.extend(x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste)
    log(f"[{uid}] esse3: {len(per_corso)} corsi di studio, {len(titoli)} attività con appelli")
    return per_corso, titoli


def _aggiungi(out: dict[str, list[dict]], cod: str, lst: list[dict]) -> bool:
    v = out.setdefault(cod, [])
    viste = {(x["data"], x["ora"], x["tipo"]) for x in v}
    nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
    v.extend(nuovi)
    return bool(nuovi)


def fetch_appelli(uid: str, base: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """{codice dell'insegnamento nel database: appelli}; le AD senza abbinamento restano con il codice Esse3."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    per_corso, _ = fetch_bacheca(uid, base, log=log)
    ad_tutti: dict[str, list[dict]] = {}
    for d in per_corso.values():
        for ad, lst in d.items():
            _aggiungi(ad_tutti, ad, lst)
    dip: dict[str, list[dict]] = {}
    if not per_corso:  # senza corsi di studio nell'offerta (o con il modulo diverso): bacheca per dipartimento
        try:
            dip = per_dipartimento(uid, base, log=log)
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}] esse3 per dipartimento: {e!r}")
    for ad, lst in dip.items():
        _aggiungi(ad_tutti, ad, lst)
    out: dict[str, list[dict]] = {}
    corsi_esse3: dict[str, list[str]] = {}
    for nome in per_corso:
        corsi_esse3.setdefault(_nome_corso(nome), []).append(nome)
    n_cod = n_nome = 0
    for c in corsi:
        if c.get("piano_da"):
            continue
        k = _nome_corso(c["nome"])
        etichette = list(corsi_esse3.get(k, []))
        if not etichette:
            simili = [x for x in corsi_esse3 if len(x) >= 15 and (k.startswith(x) or x.startswith(k))]
            if len(simili) == 1:
                etichette = list(corsi_esse3[simili[0]])
        per_nome: dict[str, list[str]] = {}
        for e in etichette:
            for ad, lst in per_corso[e].items():
                per_nome.setdefault(_nome_ad(lst[0].get("titolo")), []).append(ad)
        for i in c.get("insegnamenti") or []:
            cod = i.get("codice")
            if not cod:
                continue
            if cod in ad_tutti:
                n_cod += _aggiungi(out, cod, ad_tutti[cod])
                continue
            for ad in dict.fromkeys(per_nome.get(_nome_ad(i.get("nome")), [])):
                if _aggiungi(out, cod, ad_tutti[ad]):
                    n_nome += 1
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti "
        f"({n_cod} per codice, {n_nome} per nome)")
    for ad, lst in ad_tutti.items():
        if ad not in out:
            _aggiungi(out, ad, lst)
    return out
