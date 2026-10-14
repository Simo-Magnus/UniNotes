"""Appelli d'esame del Politecnico di Torino dalla consultazione pubblica del Portale della Didattica.

`https://didattica.polito.it/pls/portal30/esami.visu.form` («Consultazione date appelli d'esame») è
raggiungibile senza login: il modulo (POST su `esami.visu.app`) accetta docente, codice
dell'insegnamento, sede, nome, data e aula e restituisce una tabella con docente, codici (uno o più,
per gli insegnamenti condivisi tra corsi), nome (con la lettera/e del cognome del gruppo), sede,
data, ora, aula, tipo di prova, scadenza dell'iscrizione e note.

La pagina mostra al massimo 200 appelli per ricerca e solo quelli futuri e già pubblicati dai
docenti: si interroga giorno per giorno (da oggi a fine a.a.), separando per sede (e, se ancora
200, per lettera del nome) quando il tetto è raggiunto. Un appello con più codici vale per ognuno.
Gli appelli compaiono mano a mano che i docenti li pubblicano (la sessione invernale di solito da
novembre/dicembre): il modulo va rilanciato di tanto in tanto.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import html
import json
import os
import pathlib
import re
import string
import time

import requests

BASE = "https://didattica.polito.it"
FORM = BASE + "/pls/portal30/esami.visu.form"
URL = BASE + "/pls/portal30/esami.visu.app"
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
TETTO = 200
SEDI = ["SEDE CENTRALE", "CASTELLO DEL VALENTINO", "MONDOVI"]


def _t(s: str) -> str:
    s = re.sub(r"<br\s*/?>", " / ", s)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip(" /")


def _modalita(tipo: str) -> str | None:
    t = tipo.lower()
    if not t:
        return None
    if "scritt" in t and "orale" in t:
        return "scritto+orale"
    if "orale" in t:
        return "orale"
    if "progetto" in t:
        return "progetto"
    if "quiz" in t:
        return "quiz"
    if "scritt" in t:
        return "scritto"
    return "altro"


def parse(page: str, fonte: str) -> list[tuple[str, dict, list[str]]]:
    """[(id riga, appello, codici)] dalla tabella dei risultati."""
    out = []
    for tr in re.findall(r"<TR onblur.*?</TR>", page, re.S):
        td = re.findall(r"<TD[^>]*>(.*?)</TD>", tr, re.S)
        if len(td) < 9:
            continue
        rid = re.search(r"<!--(\d+)-->", td[3])
        codici = re.findall(r"\b[0-9A-Z]{7}\b", _t(td[1]))
        d = re.fullmatch(r"(\d\d)/(\d\d)/(\d{4})", _t(td[4]))
        if not d or not codici:
            continue
        ora = re.search(r"(\d{1,2}):(\d\d)", _t(td[5]))
        scad = re.search(r"(\d\d)/(\d\d)/(\d{4})", _t(td[8]))
        tipo = _t(td[7])
        note = _t(td[9]) if len(td) > 9 else ""
        note = re.sub(r"https?://\S+", "", note)
        note = re.sub(r"\s*Coordinate: Latitudine [\d.]+ Longitudine [\d.]+", "", note).strip(" /")
        nome = _t(td[2])
        if "�" in note:  # il Portale ha già perso le lettere accentate: meglio nessuna nota
            note = ""
        luogo = _t(td[6]).replace("�", "").strip()
        out.append((rid.group(1) if rid else hashlib.sha1(tr.encode()).hexdigest(), {
            "tipo": "appello", "titolo": nome or None,
            "data": f"{d.group(3)}-{d.group(2)}-{d.group(1)}",
            "ora": f"{int(ora.group(1)):02d}:{ora.group(2)}" if ora else None,
            "luogo": luogo or None, "modalita": _modalita(tipo),
            "iscrizioni_dal": None,
            "iscrizioni_al": f"{scad.group(3)}-{scad.group(2)}-{scad.group(1)}" if scad else None,
            "docenti": _t(td[0]) or None, "note": note or (f"Prova: {tipo}" if tipo and not _modalita(tipo) else None) or None,
            "fonte": fonte,
        }, codici))
    return out


class _Sess:
    def __init__(self, delay: float):
        self.s = requests.Session()
        self.delay = delay
        base = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(base) / "polito_appelli" if base else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)
        self.oggi = dt.date.today().isoformat()

    def cerca(self, log, **campi) -> str | None:
        data = {"c_cognome": "", "c_cod_ins": "", "c_sede": "x", "c_descr": "", "c_data": "", "c_aula": "", **campi}
        key = hashlib.sha1((self.oggi + json.dumps(data, sort_keys=True)).encode()).hexdigest()
        f = self.dir / f"{key}.html" if self.dir else None
        if f and f.exists():
            return f.read_text(encoding="utf-8")
        for attempt in range(4):
            try:
                time.sleep(self.delay)
                r = self.s.post(URL, data=data, headers=HEADERS, timeout=90)
                r.raise_for_status()
                testo = r.content.decode("utf-8") if _utf8(r.content) else r.content.decode("cp1252", errors="replace")
                if f:
                    f.write_text(testo, encoding="utf-8")
                return testo
            except requests.RequestException as e:
                log(f"[polito] appelli {campi} (tentativo {attempt + 1}): {e!r}")
                time.sleep(5 * (attempt + 1))
        return None


def _utf8(b: bytes) -> bool:
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def _giorno(sess: _Sess, giorno: str, log) -> dict[str, tuple[dict, list[str]]]:
    """Tutti gli appelli di un giorno (g/m/aaaa), aggirando il tetto di 200 righe con sede e nome."""
    fonte = FORM
    pag = sess.cerca(log, c_data=giorno)
    if pag is None:
        return {}
    righe = parse(pag, fonte)
    if len(righe) < TETTO:
        return {rid: (a, c) for rid, a, c in righe}
    ris: dict[str, tuple[dict, list[str]]] = {}
    for sede in SEDI:
        p = sess.cerca(log, c_data=giorno, c_sede=sede)
        rr = parse(p, fonte) if p else []
        if len(rr) >= TETTO:
            log(f"[polito] {giorno} {sede}: tetto raggiunto, ricerca per iniziale del nome")
            for ch in string.ascii_lowercase + string.digits:
                pp = sess.cerca(log, c_data=giorno, c_sede=sede, c_descr=ch)
                sub = parse(pp, fonte) if pp else []
                if len(sub) >= TETTO:
                    log(f"[polito] {giorno} {sede} '{ch}': ancora al tetto, possibili appelli mancanti")
                rr += sub
        for rid, a, c in rr:
            ris[rid] = (a, c)
    return ris


def fetch_appelli(uid: str = "polito", corsi=None, log=print, delay: float = 1.0,
                  da: dt.date | None = None, fino_a: dt.date | None = None) -> dict[str, list[dict]]:
    """{codice insegnamento: [appelli]} per i giorni da oggi alla fine dell'a.a. corrente."""
    oggi = dt.date.today()
    da = da or oggi
    aa = oggi.year if oggi.month >= 9 else oggi.year - 1
    fino_a = fino_a or dt.date(aa + 1, 10, 31)
    sess = _Sess(delay)
    appelli: dict[str, list[dict]] = {}
    n_righe = 0
    giorno = da
    while giorno <= fino_a:
        if giorno.weekday() != 6:  # la domenica non ci sono appelli
            ris = _giorno(sess, giorno.strftime("%d/%m/%Y"), log)
            for a, codici in ris.values():
                n_righe += 1
                for cod in codici:
                    appelli.setdefault(cod, []).append(a)
            if ris:
                log(f"[polito] appelli {giorno}: {len(ris)}")
        giorno += dt.timedelta(days=1)
    log(f"[polito] appelli: {n_righe} appelli, {len(appelli)} codici")
    return appelli
