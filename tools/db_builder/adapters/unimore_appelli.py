"""Appelli d'esame di UniMoRe, un corso di studio alla volta.

Fonti pubbliche dell'ateneo:
- bacheca appelli di Esse3 (`unimore.esse3.cineca.it/Guide/PaginaListaAppelli.do`): si sceglie la
  struttura (dipartimento) e poi ogni corso di studio, così ogni appello è legato al suo corso
  («[16-311] Fisica»); l'adattatore comune per sola struttura perde il corso e abbina solo per codice;
- calendario esami del Dipartimento di Economia «Marco Biagi» (`appelliesame.unimore.it`, pagina
  «Per corso di laurea»), pubblicato prima della bacheca Esse3.

L'abbinamento agli insegnamenti del catalogo è per corso: prima per codice dell'attività, poi per
nome (i codici di Esse3 e del Course Catalogue spesso non coincidono, es. «AS_01» e «14-412-001»).
Con UN_HTTP_CACHE le risposte restano su disco per il giorno stesso.
"""
from __future__ import annotations

import datetime
import hashlib
import html
import json
import os
import pathlib
import re
import time
import unicodedata

import requests

from . import esse3_appelli as e3

ESSE3 = "https://unimore.esse3.cineca.it"
LISTA = ESSE3 + "/Guide/PaginaListaAppelli.do"
HEADERS = e3.HEADERS
ECONOMIA = "https://www.appelliesame.unimore.it/Calendario/Dipartimento_di_Economia_Marco_Biagi"


class _Cache:
    def __init__(self):
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unimore_appelli" / datetime.date.today().isoformat() if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def _f(self, chiave: str):
        return self.dir / (hashlib.sha1(chiave.encode()).hexdigest() + ".txt")

    def get(self, chiave: str):
        if not self.dir:
            return None
        f = self._f(chiave)
        return f.read_text(encoding="utf-8") if f.exists() else None

    def put(self, chiave: str, testo: str) -> None:
        if self.dir:
            self._f(chiave).write_text(testo, encoding="utf-8")


def _opzioni(page: str, campo: str) -> list[tuple[str, str]]:
    sel = re.search(rf'<select[^>]*name="{campo}".*?</select>', page, re.S)
    if not sel:
        return []
    out = []
    for v, t in re.findall(r'<option value="([^"]*)"[^>]*>(.*?)</option>', sel.group(0), re.S):
        if v and v not in ("X", "-1"):
            out.append((v, re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", t))).strip()))
    return out


def appelli_esse3(log=print, delay: float = 0.4) -> list[dict]:
    """[{cds_cod, cds_nome, fac, appelli: {codice_ad: [esami]}}] per ogni corso di studio della bacheca."""
    cache = _Cache()
    s = requests.Session()
    r = s.get(LISTA, headers=HEADERS, timeout=60)
    facs = _opzioni(r.text, "FAC_ID")
    out = []

    def post(dati: dict) -> str:
        chiave = json.dumps(dati, sort_keys=True)
        t = cache.get(chiave)
        if t is None:
            for tentativo in range(3):
                try:
                    t = s.post(LISTA, data=dati, headers=HEADERS, timeout=300).text
                    break
                except requests.RequestException as e:
                    log(f"[unimore] esse3 {dati}: {e!r} (tentativo {tentativo + 1})")
                    time.sleep(5)
            else:
                return ""
            cache.put(chiave, t)
            time.sleep(delay)
        return t

    base = {"FAC_ID": "X", "CDS_ID": "X", "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "",
            "form_id_form1": "form1", "actionBar1": "Cerca"}
    for fac, fac_nome in facs:
        pagina = post({**base, "FAC_ID": fac})
        for cid, cnome in _opzioni(pagina, "CDS_ID"):
            t = post({**base, "FAC_ID": fac, "CDS_ID": cid})
            ap = e3._parse(t, LISTA)
            m = re.match(r"\[([^\]]+)\]\s*(.*)", cnome)
            out.append({"cds_cod": m.group(1) if m else None, "cds_nome": (m.group(2) if m else cnome).strip(),
                        "fac": fac_nome, "appelli": ap})
    log(f"[unimore] esse3: {len(out)} corsi di studio, {sum(len(c['appelli']) for c in out)} attività con appelli")
    return out


# ---------------------------------------------------------------- Dipartimento di Economia
_CHIAMATA = re.compile(r"^(?:I|II|III|IV|V|VI|VII|VIII)\s+appello:?$")
_PROVA = re.compile(
    r"^(?:esame|prova)\s*(?P<tipo>[a-zà-ÿ ]*?)\s*(?:luned[iì]|marted[iì]|mercoled[iì]|gioved[iì]|venerd[iì]|sabato|"
    r"domenica)\s+(?P<g>\d{2})-(?P<m>\d{2})-(?P<a>\d{4})\s*-\s*(?P<ora>\d{1,2}:\d{2})(?:\s*-\s*(?P<luogo>.*))?$", re.I)


def appelli_economia(log=print) -> list[dict]:
    """Calendari esami di Economia (a.a. 2026/2027, versione italiana, «Per corso di laurea»):
    [{cds_cod, cds_nome, sessione, fonte, esami: [{nome, docenti, data, ora, modalita, luogo}]}]."""
    cache = _Cache()

    def scarica(u: str) -> str:
        t = cache.get(u)
        if t is None:
            r = requests.get(u, headers=HEADERS, timeout=60)
            if r.status_code != 200:
                return ""
            t = r.content.decode("latin-1")
            cache.put(u, t)
        return t

    indice = scarica(ECONOMIA + "/index.html")
    out: dict = {}
    for numero in dict.fromkeys(re.findall(r"href=['\"](\d+)/index\.html", indice)):
        url = f"{ECONOMIA}/{numero}/ttCdlHtml.html"
        pagina = scarica(url)
        if not pagina or "2026/2027" not in pagina:
            continue
        testo = html.unescape(re.sub(r"<[^>]+>", "\n", pagina))
        righe = [re.sub(r"\s+", " ", x).strip() for x in testo.split("\n")]
        righe = [x for x in righe if x and x != "\xa0"]
        if "Corso di laurea" not in righe:  # versione inglese dello stesso calendario
            continue
        sess = next((righe[k + 1].lstrip(": ").strip() for k, x in enumerate(righe[:-1])
                     if x == "Sessione d'esame"), None)
        cds = None
        k = 0
        while k < len(righe):
            x = righe[k]
            if x == "Corso di laurea" and k + 2 < len(righe):
                m = re.match(r"(.*?)\s*\[([\d\-]+)\]", righe[k + 2])
                if m:
                    nome = re.sub(r"\s*-\s*Laurea.*$", "", m.group(1)).strip()
                    cds = out.setdefault((m.group(2), sess), {
                        "cds_cod": m.group(2), "cds_nome": nome, "sessione": sess, "fonte": url, "esami": []})
                k += 1
                continue
            if cds and re.fullmatch(r"\d{1,3}", x) and k + 2 < len(righe):
                nome, j = righe[k + 1], k + 2
                docenti = []
                while j < len(righe) and not _CHIAMATA.match(righe[j]) and not re.fullmatch(r"\d{1,3}", righe[j]) \
                        and len(docenti) < 12:
                    if righe[j] != ",":
                        docenti.append(righe[j])
                    j += 1
                while j + 1 < len(righe) and _CHIAMATA.match(righe[j]):
                    pr = _PROVA.match(righe[j + 1])
                    if pr:
                        e = {"nome": nome, "docenti": ", ".join(docenti), "data": f"{pr['a']}-{pr['m']}-{pr['g']}",
                             "ora": pr["ora"].zfill(5), "modalita": (pr["tipo"] or "").strip().lower() or None,
                             "luogo": (pr["luogo"] or "").strip() or None}
                        if not any((q["nome"], q["data"], q["ora"]) == (e["nome"], e["data"], e["ora"])
                                   for q in cds["esami"]):
                            cds["esami"].append(e)
                    j += 2
                k = j
                continue
            k += 1
    risultato = list(out.values())
    log(f"[unimore] economia: {sum(len(c['esami']) for c in risultato)} appelli in {len(risultato)} corsi")
    return risultato


# ---------------------------------------------------------------- abbinamento agli insegnamenti
def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\b(modulo|mod|corso integrato|c i)\b", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _chiave_cds(cod: str | None) -> str | None:
    """«16-215» (coorte precedente) e «16-315» sono lo stesso corso: 2xx -> 3xx."""
    m = re.fullmatch(r"([\w]+)-(\d)(\d\d)", (cod or "").strip())
    if not m:
        return (cod or "").strip() or None
    return f"{m.group(1)}-{'3' if m.group(2) == '2' else m.group(2)}{m.group(3)}"


def _nome_corso(s: str | None) -> str:
    s = re.sub(r"\s*\((?:mo|re|mn)\)\s*$", "", (s or "").strip(), flags=re.I)
    return _norm(re.sub(r"\s*-\s*Laurea.*$", "", s))


def _tipo_es(e: dict) -> dict:
    return {k: v for k, v in e.items() if k != "titolo"}


def _aggiungi(ins: dict, esami: list[dict]) -> int:
    viste = {(x.get("data"), x.get("ora"), x.get("tipo")) for x in ins.get("esami") or []}
    n = 0
    for e in esami:
        k = (e.get("data"), e.get("ora"), e.get("tipo"))
        if k not in viste:
            viste.add(k)
            ins.setdefault("esami", []).append(e)
            n += 1
    if ins.get("esami"):
        ins["esami"].sort(key=lambda x: x.get("data") or "")
        ins["stato_esami"] = "completo"
    return n


def _trova_corsi(corsi: list[dict], cod: str | None, nome: str) -> list[dict]:
    k = _chiave_cds(cod)
    per_codice = [c for c in corsi if _chiave_cds(c.get("codice_ateneo")) == k] if k else []
    if per_codice:
        return per_codice
    nomi = {_nome_corso(nome), _nome_corso(nome.split(" - ")[0])} - {""}  # «… - Corso professionalizzante»
    return [c for c in corsi if _nome_corso(c["nome"]) in nomi]


def abbina(corsi: list[dict], log=print) -> dict:
    """Aggiunge `esami` agli insegnamenti dei corsi del catalogo (contributo di fetch_ateneo)."""
    stat = {"esse3": 0, "economia": 0, "corsi_non_trovati": []}
    # 1) bacheca Esse3 per corso di studio
    for blocco in appelli_esse3(log):
        if not blocco["appelli"]:
            continue
        cs = _trova_corsi(corsi, blocco["cds_cod"], blocco["cds_nome"])
        if len(cs) > 1 and not _chiave_cds(blocco["cds_cod"]) in {_chiave_cds(c.get("codice_ateneo")) for c in cs}:
            cs = []  # stesso nome in più corsi (laurea e magistrale): senza il codice non si sa quale sia
        if not cs:
            stat["corsi_non_trovati"].append((blocco["cds_cod"], blocco["cds_nome"]))
            continue
        for c in cs:
            per_cod = {}
            per_nome: dict[str, list[dict]] = {}
            for i in c["insegnamenti"]:
                per_cod.setdefault(i["codice"], []).append(i)
                per_nome.setdefault(_norm(i["nome"]), []).append(i)
            for cod, lst in blocco["appelli"].items():
                esami = [_tipo_es(e) for e in lst]
                bersagli = per_cod.get(cod) or per_nome.get(_norm(lst[0].get("titolo"))) or []
                for i in bersagli:
                    stat["esse3"] += _aggiungi(i, esami)
    # 2) Economia
    for blocco in appelli_economia(log):
        cs = _trova_corsi(corsi, blocco["cds_cod"], blocco["cds_nome"])
        if not cs:
            stat["corsi_non_trovati"].append((blocco["cds_cod"], blocco["cds_nome"]))
            continue
        for c in cs:
            per_nome: dict[str, list[dict]] = {}
            for i in c["insegnamenti"]:
                per_nome.setdefault(_norm(i["nome"]), []).append(i)
            raggr: dict[str, list[dict]] = {}
            for e in blocco["esami"]:
                raggr.setdefault(e["nome"], []).append(e)
            for nome, lst in raggr.items():
                bers = per_nome.get(_norm(nome)) or per_nome.get(_norm(re.sub(r"\s+-\s+[^-]+$", "", nome))) or []
                esami = [{"tipo": "appello", "data": e["data"], "ora": e["ora"], "luogo": e["luogo"],
                          "modalita": e["modalita"], "iscrizioni_dal": None, "iscrizioni_al": None,
                          "docenti": e["docenti"], "note": None, "fonte": blocco["fonte"]} for e in lst]
                for i in bers:
                    stat["economia"] += _aggiungi(i, esami)
    log(f"[unimore] appelli abbinati: esse3 {stat['esse3']}, economia {stat['economia']}; "
        f"corsi non trovati: {stat['corsi_non_trovati']}")
    return stat
