"""Università degli Studi di Bari Aldo Moro: insegnamenti e libri dal Course Catalogue Cineca.

`https://uniba.coursecatalogue.cineca.it` pubblica piani di studio e syllabus; il sito
uniba.it è protetto da Radware Bot Manager (CAPTCHA) e non si usa. Rispetto all'adattatore
comune (`cineca_catalogue`) questo adattatore:

- tiene le risposte su disco (variabile d'ambiente UN_HTTP_CACHE, cartella «uniba»): una
  raccolta interrotta riparte da dove era;
- lega ai corsi di Universitaly quelli del catalogo che il confronto per nome e classe non
  associa (stessa laurea in sedi diverse, es. «Economia aziendale - Brindisi» e il corso
  «Economia aziendale» di Brindisi in Universitaly): imposta `id_universitaly`, così
  build_db unisce i piani invece di lasciare un corso senza insegnamenti;
- per i syllabus il cui campo «testi» non ha riferimenti riconoscibili dall'estrazione comune
  (nessun editore o anno) tiene le righe che sono riferimenti, con la citazione com'è.
"""
from __future__ import annotations

import copy
import hashlib
import html
import json
import os
import pathlib
import re

from . import cineca_catalogue as cc
from .testi import _libero, html_to_lines

BASE = "https://uniba.coursecatalogue.cineca.it"

# codice del corso nel catalogo → id dei corsi del database a cui va il piano. Serve dove il
# confronto di build_db per nome e classe sbaglia: la stessa laurea in sedi diverse ha lo stesso
# nome (Giurisprudenza a Bari e a Taranto, Medicina, Farmacia), e Universitaly elenca anche corsi
# gemelli che il catalogo non distingue («Economia aziendale» a Bari e a Brindisi).
ID_CORSI = {
    "11434": ["uniba-l-18-economia-aziendale"],
    "11435": ["uniba-l-18-economia-aziendale-brindisi", "uniba-l-18-economia-aziendale-1629863"],
    "11466": ["uniba-l-31-informatica-e-tecnologie-dell-informazione-taranto",
              "uniba-l-31-informatica-e-tecnologie-dell-informazione"],
    "11422": ["uniba-lm-13-farmacia"],
    "11468": ["uniba-lm-13-farmacia-taranto"],
    "11423": ["uniba-lm-13-farmacia-1634825"],
    "11459": ["uniba-lmg-01-giurisprudenza"],
    "11460": ["uniba-lmg-01-giurisprudenza-gia-giurisprudenza-d-impresa", "uniba-lmg-01-giurisprudenza-1634842"],
    "11485": ["uniba-lmg-01-giurisprudenza-1635005"],
    "11450": ["uniba-lm-41-medicina-e-chirurgia-1635021"],
    "11658": ["uniba-lm-41-medicina-e-chirurgia-replica-taranto"],
    "11455": ["uniba-lm-41-medicine-and-surgery-medicina-e-chirurgia-in-lingua-inglese",
              "uniba-lm-41-medicina-e-chirurgia"],
}
# corsi di Universitaly senza un corso omonimo nel catalogo
ID_UNIVERSITALY = {
    "11657": "1625605",   # Tecniche di radiologia medica
    "11659": "1625604",   # Scienze e tecniche dello sport (LM-67/LM-68)
}


class ClientConCache(cc.Client):
    """Course Catalogue con cache su disco."""

    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "uniba" if d else None

    def get(self, path, params=None):
        if not self.cache:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.cache / key[:2] / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


# Righe che non sono un libro: materiale del docente, indicazioni «durante le lezioni», rimandi
_NON_LIBRO = re.compile(
    r"(?i)durante (le|il) (lezion|corso)|\bverr[àa]\b|\bverranno\b|\bsar[àa]\b|\bsaranno\b|\bslides?\b|\blucidi\b|"
    r"\bdispense\b|\bmateriale\b|\bappunti\b|\bfornit|\bindicat|\bqualsias|\bqualunque\b|\ba scelta\b|"
    r"\bdisponibil|\breperibil|\bconsult|\bnon (è|e'|sono) previst|\bnessun|\bnel corso\b|\bsul sito\b|"
    r"\bmoodle\b|\bpiattaforma\b|\bteams\b|\bda definire\b|\bda concordare\b|\bdel docente\b|"
    r"\b(textbook|book|books|manual)s? (will|is|are)\b|\bsee the\b|\bany manual\b|\b(è|nato|scaricabil\w*|citat[ae]|possono|devono|può)\b|:\s*$")
_CONTINUA = re.compile(r"^(?:(?i:aut\.|autori?\b|casa editrice|editore|a cura di|eds?[.:]|edited by|curato da)|[a-zà-ÿ(])")


def libri_testo_libero(sy: dict) -> list[dict]:
    """Per i syllabus in cui l'estrazione comune non riconosce nulla: ogni riga del campo
    «testi» che sembra un riferimento (non una frase come «materiale fornito dal docente»)
    è un libro, con la citazione così com'è nel syllabus."""
    out, viste = [], set()
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if not (isinstance(v, str) and re.search(r"(^|_)testi_it$", k)):
                continue
            righe: list[str] = []
            for r in html_to_lines(v):
                if righe and _CONTINUA.match(r):
                    righe[-1] += " " + r
                else:
                    righe.append(r)
            for r in righe:
                if _NON_LIBRO.search(r) or not 12 <= len(r) <= 400 or len(r.split()) < 4:
                    continue
                if not re.search(r"[A-ZÀ-Ý]", r):
                    continue
                b = _libero(r)
                key = re.sub(r"\W+", "", b["citazione"].lower())[:120]
                if key not in viste:
                    viste.add(key)
                    out.append(b)
    return out


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print) -> dict:
    doc = cc.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                          client=ClientConCache(BASE), libri_extra=libri_testo_libero)
    for c in doc["corsi"]:  # alcuni syllabus hanno le entità HTML annidate («&amp;#39;»)
        for ins in c.get("insegnamenti") or []:
            for b in ins.get("libri") or []:
                for k in ("titolo", "autori", "editore", "citazione"):
                    v = b.get(k)
                    while isinstance(v, str) and "&" in v and html.unescape(v) != v:
                        v = html.unescape(v)
                    b[k] = v
    corsi = []
    for c in doc["corsi"]:
        cod = str(c.get("url") or "").rsplit("/", 1)[-1]
        if cod in ID_CORSI:  # una copia del piano per ogni corso del database (id esplicito)
            corsi += [{**copy.deepcopy(c), "id": i} for i in ID_CORSI[cod]]
        else:
            if cod in ID_UNIVERSITALY:
                c["id_universitaly"] = ID_UNIVERSITALY[cod]
            corsi.append(c)
    copie = [c for c in corsi if c.get("id") or c.get("id_universitaly")]
    doc["corsi"] = corsi
    log(f"[{uid}] corsi del database legati per id: {len(copie)}")
    return doc
