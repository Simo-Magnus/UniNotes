"""Appelli d'esame di UniPG dalla bacheca pubblica di Esse3 (`ListaAppelliOfferta.do`).

La bacheca per dipartimento (`esse3_appelli`) dà gli appelli per codice dell'attività didattica (AD) di
Esse3, ma il portale www.unipg.it pubblica per gli insegnamenti un altro codice («GP003822»): solo un
quarto degli insegnamenti si abbinava per codice. La bacheca «offerta» si interroga un corso di studio
per volta (anche gli ordinamenti e le coorti precedenti, che hanno lo stesso nome del corso di oggi):
gli appelli di un'AD compaiono nei corsi di studio che la erogano, e si attribuiscono all'insegnamento
con lo stesso nome del corso omonimo del database. Il dipartimento di Economia non ha corsi di studio
in questa bacheca: per quello resta la bacheca per dipartimento, con l'abbinamento per codice.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le pagine già lette per ogni corso di studio
restano su disco (`unipg_esse3/`).
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import pathlib
import re
import time
import unicodedata

ESSE3 = "https://unipg.esse3.cineca.it"


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nome_corso(nome: str | None) -> str:
    """Nome del corso senza «(abilitante …)» e senza «REPLICA …»."""
    n = re.sub(r"\(.*?(?:\)|$)", " ", nome or "")  # anche con la parentesi tagliata: «(ABILITANTE … SANI...»
    n = re.sub(r"(?i)\breplica\b.*$", " ", n)
    return _norm(n)


def _nome_ad(nome: str | None) -> str:
    n = re.sub(r"(?i)\b(?:mod\.?|modulo)\s*[0-9ivx]+\b", " ", nome or "")
    n = re.sub(r"(?i)[-–\s]+canale\s*[a-z0-9]\b|\b(?:canale|can\.)\s*[a-z0-9]\b", " ", n)  # «- CANALE B»
    n = re.sub(r"(?i)(?<=\s)[a-z]\s?-\s?[a-z]\s*$", " ", n)  # «DIRITTO ROMANO M-Z»: lettere del cognome
    parole = _norm(re.sub(r"\(.*?\)", " ", n)).split()
    romani = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6"}
    if len(parole) > 1 and parole[-1] in romani:  # «Letteratura Tedesca III» = «Letteratura Tedesca 3»
        parole[-1] = romani[parole[-1]]
    return " ".join(parole)


def _cache_dir() -> pathlib.Path | None:
    d = os.environ.get("UN_HTTP_CACHE")
    if not d:
        return None
    p = pathlib.Path(d) / "unipg_esse3"
    p.mkdir(parents=True, exist_ok=True)
    return p


def fetch_bacheca(log=print, pausa: float = 0.6, da: str = "01/10/2026", a: str = "31/12/2027"):
    """Appelli per corso di studio. Restituisce {etichetta corso Esse3: {AD: [appelli]}} e {AD: titolo}."""
    import requests

    from .esse3_appelli import HEADERS, _parse
    cache = _cache_dir()
    s = requests.Session()
    s.headers.update(HEADERS)
    r = s.get(ESSE3 + "/ListaAppelliOfferta.do", timeout=60)
    form = re.search(r'<form action="([^"]+)" id="formRicercaCds"', r.text)
    if r.status_code != 200 or not form:
        log(f"[unipg] esse3: bacheca non raggiungibile (HTTP {r.status_code})")
        return {}, {}
    url = ESSE3 + "/" + form.group(1).split(";")[0]
    base = {"data_da": da, "data_a": a, "TIPO_FORM": "1", "form_id_formRicercaCds": "formRicercaCds"}
    sel = re.search(r'<select id="selectionFacolta".*?</select>', r.text, re.S)
    facs = re.findall(r'<option value="([^"]+)"', sel.group(0)) if sel else []

    def post(dati: dict) -> str | None:
        for tentativo in range(3):
            try:
                x = s.post(url, data=dati, timeout=240)
                if x.status_code == 200:
                    return x.text
            except requests.RequestException:
                pass
            time.sleep(3 * (tentativo + 1))
        return None

    per_corso: dict[str, dict[str, list[dict]]] = {}
    titoli: dict[str, str] = {}
    for fac in facs:
        t = post({**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "", "_fw_refresh-form": "selectionFacolta"})
        time.sleep(pausa)
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        for cod, etichetta in (re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []):
            nome = re.sub(r"^\s*\[\w+\]\s*", "", html.unescape(etichetta)).strip()
            chiave = f"{cod}|{nome}"
            f = cache / f"{hashlib.sha1(chiave.encode()).hexdigest()}.json" if cache else None
            if f and f.exists():
                got = json.loads(f.read_text(encoding="utf-8"))
            else:
                t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"})
                time.sleep(pausa)
                if t is None:
                    log(f"[unipg] esse3: corso {cod} {nome} non letto")
                    continue
                got = _parse(t.replace("Date e ora del turno", "Data e ora del turno"), ESSE3 + "/ListaAppelliOfferta.do")
                if f:
                    f.write_text(json.dumps(got, ensure_ascii=False), encoding="utf-8")
            d = per_corso.setdefault(nome, {})
            for ad, lst in got.items():
                titoli.setdefault(ad, lst[0].get("titolo") or "")
                v = d.setdefault(ad, [])
                viste = {(x["data"], x["ora"], x["tipo"]) for x in v}
                v.extend(x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste)
    log(f"[unipg] esse3: {len(per_corso)} corsi di studio, {len(titoli)} attività con appelli")
    return per_corso, titoli


def _aggiungi(out: dict[str, list[dict]], cod: str, lst: list[dict]) -> bool:
    v = out.setdefault(cod, [])
    viste = {(x["data"], x["ora"], x["tipo"]) for x in v}
    nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
    v.extend(nuovi)
    return bool(nuovi)


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """{codice dell'insegnamento nel database: appelli}. Per codice AD uguale (bacheca per corso e per
    dipartimento) e, per gli altri, per nome dell'insegnamento nei corsi di studio omonimi."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    per_corso, _ = fetch_bacheca(log=log)
    out: dict[str, list[dict]] = {}
    ad_tutti: dict[str, list[dict]] = {}
    for d in per_corso.values():
        for ad, lst in d.items():
            _aggiungi(ad_tutti, ad, lst)
    try:
        dip = per_dipartimento(uid, ESSE3, log=log)
    except Exception as e:  # noqa: BLE001
        log(f"[{uid}] esse3 per dipartimento: {e!r}")
        dip = {}
    for ad, lst in dip.items():
        _aggiungi(ad_tutti, ad, lst)
    corsi_esse3: dict[str, list[str]] = {}
    for nome in per_corso:
        corsi_esse3.setdefault(_nome_corso(nome), []).append(nome)
    n_cod = n_nome = 0
    for c in corsi:
        k = _nome_corso(c["nome"])
        etichette = list(corsi_esse3.get(k, []))
        if not etichette:  # nome più lungo o più corto nell'una o nell'altra fonte, se è un caso solo
            simili = [x for x in corsi_esse3 if len(x) >= 15 and (k.startswith(x) or x.startswith(k))]
            if len(simili) == 1:
                etichette = list(corsi_esse3[simili[0]])
        per_nome: dict[str, list[str]] = {}
        for e in etichette:
            for ad, lst in per_corso[e].items():
                per_nome.setdefault(_nome_ad(lst[0].get("titolo")), []).append(ad)
        for i in c.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and cod in ad_tutti:
                n_cod += _aggiungi(out, cod, ad_tutti[cod])
                continue
            if not cod:
                continue
            for ad in dict.fromkeys(per_nome.get(_nome_ad(i.get("nome")), [])):
                if _aggiungi(out, cod, ad_tutti[ad]):
                    n_nome += 1
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti "
        f"({n_cod} per codice, {n_nome} per nome)")
    # le attività senza abbinamento restano con il loro codice Esse3 (build_db le riconosce per codice o nome)
    for ad, lst in ad_tutti.items():
        if ad not in out:
            _aggiungi(out, ad, lst)
    return out
