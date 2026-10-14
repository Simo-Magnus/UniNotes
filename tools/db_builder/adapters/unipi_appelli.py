"""Università di Pisa: date d'esame dal portale pubblico degli esami (esami.unipi.it).

La bacheca appelli di Esse3 (`unipi.esse3.cineca.it/Guide/PaginaListaAppelli.do`) risponde
403. UniPi pubblica però gli appelli sul proprio portale «Valutazione della didattica e
iscrizione agli esami» (esami.unipi.it), nella pagina pubblica «Calendario CdS»
(`calendariodipcds.php?did=<dipartimento>&cid=<corso>`, senza login): per ogni corso di
studio una tabella con a.a., corso, insegnamento («NOME - CODICE», il codice è quello
dell'attività in Esse3 e nel Course Catalogue), docente, data e ora, tipo (scritto/orale),
sede, apertura e chiusura delle iscrizioni e note. La stessa tabella c'è per ogni sessione
d'esame dei dipartimenti («Calendario sessioni», `calendario.php?id=<sessione>`): si leggono
anche quelle (non ancora concluse), che elencano pure appelli non mostrati per corso.
Infine la ricerca pubblica «Elenco appelli» per corso (`elencoappelli.php?cds=<codice>`) dà
per ogni appello anche gli insegnamenti mutuati o condivisi (stesso esame per un altro codice
o un altro corso): le date valgono anche per quei codici.

Si salvano solo i nomi dei docenti (nessun contatto).
"""
from __future__ import annotations

import codecs
import hashlib
import html
import os
import pathlib
import re
import time
from datetime import date

import requests

BASE = "https://esami.unipi.it"
PAGINA = f"{BASE}/calendariodipcds.php"
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
DATA_ORA = re.compile(r"(\d{2})-(\d{2})-(\d{4})(?:\s+(\d{1,2}):(\d{2}))?")
codecs.register_error("unipi_cp1252", lambda e: (e.object[e.start:e.end].decode("cp1252", errors="replace"), e.end))
ITINERE = re.compile(r"(?i)compitin|in itinere|prova parziale|prove parziali|\bparziale\b|esonero|intermedi")


def _get(s: requests.Session, url: str, params: dict, cache: pathlib.Path | None, delay: float) -> str:
    key = hashlib.sha1((url + repr(sorted(params.items()))).encode()).hexdigest()
    f = cache / f"{key}.html" if cache else None
    if f and f.exists():
        return f.read_text(encoding="utf-8")
    testo = ""
    for tentativo in range(3):
        try:
            r = s.get(url, params=params, headers=HEADERS, timeout=120)
            r.raise_for_status()
            # le pagine sono in UTF-8, ma qualche nota ha caratteri in Windows-1252
            testo = r.content.decode("utf-8", errors="unipi_cp1252")
            break
        except requests.RequestException:
            time.sleep(5 * (tentativo + 1))
    time.sleep(delay)
    if f and testo:
        f.write_text(testo, encoding="utf-8")
    return testo


def _testo(c: str) -> str:
    c = re.sub(r"<a [^>]*onClick='showDetail\(\"(.*?)\"\);'>Leggi tutto</a>", r"§\1", c, flags=re.S | re.I)
    if "§" in c:  # nota troncata: si usa il testo completo
        c = c.split("§", 1)[1]
    c = re.sub(r"(?i)<br\s*/?>", " ", c)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", c))).strip()


def _opzioni(pagina: str, nome: str) -> list[tuple[str, str]]:
    sel = re.search(rf'<select name="{nome}".*?</select>', pagina, re.S)
    if not sel:
        return []
    return [(v, html.unescape(t).strip()) for v, t in
            re.findall(r'<option value="(\d+)"[^>]*>([^<]*)', sel.group(0)) if v != "0" and t.strip()]


def _modalita(t: str) -> str | None:
    t = (t or "").lower()
    if "scritt" in t and "oral" in t:
        return "scritto+orale"
    for k, v in (("scritt", "scritto"), ("oral", "orale"), ("progett", "progetto"), ("pratic", "altro"),
                 ("quiz", "quiz"), ("test", "quiz"), ("telemat", "altro")):
        if k in t:
            return v
    return t.strip() or None


def _iso(m) -> str:
    return f"{m[2]}-{m[1]}-{m[0]}"


def parse_tabella(pagina: str, fonte: str) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    corpo = re.search(r'id="datatable-calendario".*?<tbody>(.*?)</tbody>', pagina, re.S)
    if not corpo:
        return out
    for riga in re.findall(r"<tr.*?</tr>", corpo.group(1), re.S | re.I):
        celle = re.findall(r"<td[^>]*>(.*?)</td>", riga, re.S | re.I)
        if len(celle) < 9:
            continue
        aa, cds, ins, doc, quando, tipo, sede, dal, al = (_testo(c) for c in celle[:9])
        note = _testo(celle[9]) if len(celle) > 9 else ""
        m = re.match(r"(.*\S)\s+-\s+([A-Z0-9]{3,8})$", ins)
        if not m:
            continue
        nome, cod = m.group(1).strip(), m.group(2)
        d = DATA_ORA.search(quando)
        if not d:
            continue
        i1, i2 = DATA_ORA.search(dal), DATA_ORA.search(al)
        prova_in_itinere = bool(ITINERE.search(tipo) or ITINERE.search(nome))
        out.setdefault(cod, []).append({
            "tipo": "prova_in_itinere" if prova_in_itinere else "appello", "titolo": nome,
            "data": _iso(d.groups()), "ora": f"{int(d.group(4)):02d}:{d.group(5)}" if d.group(4) else None,
            "luogo": sede or None, "modalita": _modalita(tipo),
            "iscrizioni_dal": _iso(i1.groups()) if i1 else None, "iscrizioni_al": _iso(i2.groups()) if i2 else None,
            "docenti": doc or None, "note": note or None, "fonte": fonte,
        })
    return out


def parse_elenco(pagina: str, fonte: str) -> dict[str, list[dict]]:
    """Blocchi di elencoappelli.php: appelli di un insegnamento + codici mutuati/condivisi."""
    out: dict[str, list[dict]] = {}
    for b in pagina.split('<tr class="corso">')[1:]:
        dopo = re.search(r"table-appelli.*?</table>\s*</td>(.*)$", b, re.S)
        if not dopo:
            continue
        celle = [_testo(c) for c in re.findall(r"<td>(.*?)</td>", re.split(r"<table", dopo.group(1))[0], re.S)]
        if len(celle) < 4 or not re.fullmatch(r"[A-Z0-9]{3,8}", celle[3]):
            continue
        nome, cod = celle[2], celle[3]
        docente = celle[5] if len(celle) > 5 else None
        codici = [cod] + [m[3] for m in re.findall(r"<td>(Mutuazione|Condivisione)</td>\s*<td>([^<]*)</td>\s*"
                                                    r"<td>([^<]*)</td>\s*<td>([A-Z0-9]{3,8})</td>", b)]
        tab = re.search(r"table-appelli.*?<tbody>(.*?)</tbody>", b, re.S)
        for riga in re.findall(r"<tr>(.*?)</tr>", tab.group(1) if tab else "", re.S):
            c = re.findall(r"<td>(.*?)</td>", riga, re.S)
            if len(c) < 7:
                continue
            tipo, quando, sede, note = _testo(c[0]), _testo(c[1]), _testo(c[2]), _testo(c[3])
            d = DATA_ORA.search(quando)
            if not d:
                continue
            iscr = DATA_ORA.findall(c[6])
            extra = re.sub(r"(?i)(inizio|termine) iscrizioni:\s*[\d-]+\s*[\d:]*", "", _testo(c[6])).strip(" .")
            x = {"tipo": "prova_in_itinere" if ITINERE.search(tipo) or ITINERE.search(nome) else "appello",
                 "titolo": nome, "data": _iso(d.groups()),
                 "ora": f"{int(d.group(4)):02d}:{d.group(5)}" if d.group(4) else None,
                 "luogo": sede or None, "modalita": _modalita(tipo),
                 "iscrizioni_dal": _iso(iscr[0][:3]) if iscr else None,
                 "iscrizioni_al": _iso(iscr[1][:3]) if len(iscr) > 1 else None,
                 "docenti": docente or None, "note": "; ".join(t for t in (note, extra) if t) or None,
                 "fonte": fonte}
            for k in dict.fromkeys(codici):
                out.setdefault(k, []).append(dict(x))
    return out


def fetch_appelli(uid: str = "unipi", corsi: list | None = None, log=print, delay: float = 1.0) -> dict[str, list[dict]]:
    """{codice attività: [esami]} di tutti i corsi di studio di tutti i dipartimenti."""
    d = os.environ.get("UN_HTTP_CACHE")
    cache = pathlib.Path(d) / "unipi_esami" / date.today().isoformat() if d else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)
    s = requests.Session()
    home = _get(s, PAGINA, {}, cache, delay)
    appelli: dict[str, list[dict]] = {}
    n_cds = 0
    for did, dnome in _opzioni(home, "did"):
        pd = _get(s, PAGINA, {"did": did}, cache, delay)
        for cid, cnome in _opzioni(pd, "cid"):
            n_cds += 1
            fonte = f"{PAGINA}?did={did}&cid={cid}"
            pc = _get(s, PAGINA, {"did": did, "cid": cid}, cache, delay)
            for cod, lst in parse_tabella(pc, fonte).items():
                viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(cod, [])}
                for x in lst:
                    if (x["data"], x["ora"], x["tipo"]) not in viste:
                        viste.add((x["data"], x["ora"], x["tipo"]))
                        appelli.setdefault(cod, []).append(x)
        log(f"[{uid}] esami.unipi.it: {dnome}: totale {len(appelli)} insegnamenti, "
            f"{sum(len(v) for v in appelli.values())} date")
    # sessioni dei dipartimenti non ancora concluse
    cal = _get(s, f"{BASE}/calendario.php", {}, cache, delay)
    oggi = date.today().isoformat()
    sessioni = re.findall(r'<a href="calendario\.php\?id=(\d+)">([^<]*?)\s+dal\s+(\d{2}-\d{2}-\d{4})\s+al\s+'
                          r'(\d{2}-\d{2}-\d{4})', cal)
    n_sess = 0
    for sid, snome, dal, al in sessioni:
        if _iso(al.split("-")) < oggi:
            continue
        n_sess += 1
        fonte = f"{BASE}/calendario.php?id={sid}"
        itinere = bool(ITINERE.search(snome))  # sessione «Prove in itinere / compitini»
        for cod, lst in parse_tabella(_get(s, f"{BASE}/calendario.php", {"id": sid}, cache, delay), fonte).items():
            gia = {(x["data"], x["ora"]): x for x in appelli.get(cod, [])}
            for x in lst:
                if itinere:
                    x["tipo"] = "prova_in_itinere"
                if (x["data"], x["ora"]) in gia:
                    if itinere:
                        gia[(x["data"], x["ora"])]["tipo"] = "prova_in_itinere"
                    continue
                gia[(x["data"], x["ora"])] = x
                appelli.setdefault(cod, []).append(x)
    # ricerca «Elenco appelli» per corso: aggiunge le date ai codici mutuati e condivisi
    ricerca = _get(s, f"{BASE}/elencoappelli.php", {}, cache, delay)
    sel = re.search(r'<select name="cds".*?</select>', ricerca, re.S)
    for cds in re.findall(r'<option value="([^"]+)"', sel.group(0) if sel else ""):
        fonte = f"{BASE}/elencoappelli.php?from=sappelli&cds={cds}"
        pagina = _get(s, f"{BASE}/elencoappelli.php", {"from": "sappelli", "docente": "", "insegnamento": "",
                                                       "cds": cds}, cache, delay)
        for cod, lst in parse_elenco(pagina, fonte).items():
            gia = {(x["data"], x["ora"]) for x in appelli.get(cod, [])}
            for x in lst:
                if (x["data"], x["ora"]) not in gia:
                    gia.add((x["data"], x["ora"]))
                    appelli.setdefault(cod, []).append(x)
    # solo gli appelli in programma (da oggi): il portale elenca anche le date già passate
    appelli = {k: sorted((x for x in v if x["data"] >= oggi), key=lambda x: (x["data"], x["ora"] or ""))
               for k, v in appelli.items()}
    appelli = {k: v for k, v in appelli.items() if v}
    log(f"[{uid}] esami.unipi.it: {n_sess} sessioni in corso o future lette")
    log(f"[{uid}] esami.unipi.it: {n_cds} corsi di studio, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli
