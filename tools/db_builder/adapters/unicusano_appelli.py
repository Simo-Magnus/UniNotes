"""Appelli orali di UniCusano dalla pagina pubblica «Date Appelli» (www.unicusano.it/studenti/date-appelli).

La pagina elenca un link per corso di studio («Appelli orali Corso di studi in … (L/18)») verso
`sophia.unicusano.it/appelli?f=<id>`: una tabella (Materia, Docente, Data Esame, Orario, Prenotabile
Dal/Al, Note) senza login. Gli appelli si abbinano agli insegnamenti del corso con la stessa classe
(o lo stesso nome) per nome della materia. Come per UniMoRe/PoliMi, `fetch_appelli` scrive gli esami
direttamente negli insegnamenti dei corsi passati e restituisce un dizionario vuoto.
Al massimo 1 richiesta al secondo.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time
import unicodedata
from datetime import date

import requests

ROOT = pathlib.Path(__file__).resolve().parents[3]
PAGINA = "https://www.unicusano.it/studenti/date-appelli"
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("�", "")).encode("ascii", "ignore").decode().lower()
    return " ".join(re.findall(r"[a-z0-9]+", s))


def _classe(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def _giorno(s: str) -> str | None:
    m = re.fullmatch(r"\s*(\d{2})/(\d{2})/(\d{4})\s*", s or "")
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else None


def leggi_tabella(testo: str, fonte: str) -> list[dict]:
    out = []
    for tr in re.findall(r"<tr>(.*?)</tr>", testo, re.S):
        c = [html.unescape(re.sub(r"<[^>]+>", " ", x)).strip() for x in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        c = [re.sub(r"\s+", " ", x) for x in c]
        if len(c) < 4 or not _giorno(c[2]):
            continue
        ora = c[3] if re.fullmatch(r"\d{1,2}:\d{2}", c[3] or "") else None
        out.append({"materia": c[0], "tipo": "appello", "titolo": c[0], "data": _giorno(c[2]), "ora": ora, "luogo": None,
                    "modalita": "orale", "iscrizioni_dal": _giorno(c[4]) if len(c) > 4 else None,
                    "iscrizioni_al": _giorno(c[5]) if len(c) > 5 else None,
                    "docenti": c[1] or None, "note": (c[6] if len(c) > 6 else "") or None, "fonte": fonte})
    return out


def fetch_appelli(uid: str = "unicusano", corsi: list[dict] | None = None, log=print) -> dict[str, list[dict]]:
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    s = requests.Session()
    s.headers.update(HEADERS)
    pag = s.get(PAGINA, timeout=60)
    pag.encoding = "utf-8"
    link = re.findall(r'<a[^>]+href="(https://sophia\.unicusano\.it/appelli\?f=\d+)"[^>]*>\s*Appelli orali Corso di studi in '
                      r'([^<]*?)\s*</a>', pag.text)
    oggi = date.today().isoformat()
    tot = n_ins = 0
    for url, titolo in link:
        m = re.search(r"\(([A-Za-z]+\s*[/-]\s*\d+)\)\s*$", titolo)
        classe = _classe(m.group(1)) if m else None
        nome = _norm(re.sub(r"\([^)]*\)\s*$", "", titolo))
        cand = [c for c in corsi if classe and _classe(c.get("classe")) == classe]
        if len(cand) > 1:
            cand = [c for c in cand if _norm(c.get("nome")) == nome or nome in _norm(c.get("nome")) or
                    _norm(c.get("nome")) in nome] or cand
        time.sleep(1.0)
        r = s.get(url, timeout=60)
        r.encoding = "utf-8"
        righe = [e for e in leggi_tabella(r.text, url) if e["data"] >= oggi]
        if not righe:
            continue
        if len(cand) != 1:
            log(f"[{uid}] {titolo}: {len(cand)} corsi con la classe {classe}, salto")
            continue
        for rg in righe:
            mat = _norm(rg["materia"])
            for i in cand[0].get("insegnamenti") or []:
                ni = _norm(i["nome"])
                if ni == mat or (len(mat) > 12 and (mat in ni or ni in mat)):
                    e = {k: v for k, v in rg.items() if k != "materia"}
                    if not any(x["data"] == e["data"] and x["ora"] == e["ora"] for x in i.setdefault("esami", [])):
                        i["esami"].append(e)
                        tot += 1
                    i["stato_esami"] = "completo"
    for c in corsi:
        for i in c.get("insegnamenti") or []:
            if i.get("esami"):
                n_ins += 1
                i["esami"].sort(key=lambda x: (x["data"], x.get("ora") or ""))
    log(f"[{uid}] appelli orali: {len(link)} corsi, {tot} date assegnate, {n_ins} insegnamenti con esami")
    return {}
