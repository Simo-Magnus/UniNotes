"""Università di Trento: Course Catalogue Cineca con le correzioni che servono a UniTN.

- cache su disco delle risposte del catalogo (variabile d'ambiente UN_HTTP_CACHE);
- piano del 2° e 3° anno dalla coorte giusta (anche quando il corso ha cambiato codice);
- libri dai testi in forma libera dei syllabus (estrazione di UniFI e di UniPD);
- se il syllabus dell'a.a. 2026/27 non ha ancora i testi (il catalogo si compila a ottobre), si
  usa il syllabus ufficiale della stessa attività dell'anno precedente.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import unicodedata

from . import cineca_catalogue, unifi_testi, unipd, unitn_testi

BASE = "https://unitn.coursecatalogue.cineca.it"


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unitn_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


_testi_originale = cineca_catalogue._testi_syllabus
_CON_TESTO: set[tuple[str, str]] = set()  # (anno, codice) dei syllabus che hanno un testo nel campo dei testi


def _ha_testo(sy: dict) -> bool:
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if isinstance(v, str) and re.search(r"(^|_)testi_(it|en)$", k) and                     len(re.sub(r"(?i)<[^>]+>|&nbsp;|[^a-z0-9]", "", v)) >= 5:
                return True
    return False


def _testi_syllabus(sy: dict):
    if _ha_testo(sy):
        _CON_TESTO.add((str(sy.get("aa")), str(sy.get("cod"))))
    libri, modalita, legati = _testi_originale(sy)
    return [unitn_testi.ripulisci(b) for b in libri], modalita, legati


def libri_extra(sy: dict) -> list[dict]:
    libri = unifi_testi.libri_unifi(sy) or unipd.libri_liberi(sy) or unitn_testi.libri_unitn(sy)
    return [unitn_testi.ripulisci(b) for b in libri]


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _attivita(piano: dict):
    """Tutte le attività di un piano: (anno di corso, attività)."""
    for p in piano.get("percorsi") or []:
        for a in p.get("anni") or []:
            gruppi = a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                for att in g.get("attivita") or []:
                    yield a.get("anno"), att


def indice_anni_precedenti(client: ClientCache, anno: int, indietro: int = 5, log=print) -> tuple[dict, dict]:
    """Attività offerte negli anni accademici precedenti, dai piani delle coorti passate:
    per codice dell'attività e per (nome del corso, nome dell'attività)."""
    per_codice: dict[str, list[dict]] = {}
    per_nome: dict[tuple[str, str], list[dict]] = {}
    for y in range(anno - 1, anno - 1 - indietro, -1):
        lst: list[dict] = []
        cineca_catalogue._walk_cds(client.get("/corsi", {"anno": y, "minimal": "true"}) or [], lst)
        cds = [x for x in lst if str(x.get("aa")) == str(y)]
        log(f"[unitn] coorte {y}: {len(cds)} corsi")
        for x in cds:
            piano = client.get(f"/corso/{y}/{x['cod']}")
            if isinstance(piano, list):
                piano = piano[0] if piano else None
            if not piano:
                continue
            for _, att in _attivita(piano):
                try:
                    aa = int(att.get("aa"))
                except (TypeError, ValueError):
                    continue
                if aa >= anno:  # syllabus dell'anno corrente o futuri: non servono
                    continue
                voce = {"aa": aa, "params": {k: v for k, v in {
                    "anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                    "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y,
                    "schema_id": att.get("schemaId")}.items() if v not in (None, "")}}
                per_codice.setdefault(str(att.get("adCod")), []).append(voce)
                per_nome.setdefault((_norm(x.get("des_it")), _norm(att.get("des_it"))), []).append(voce)
    return per_codice, per_nome


def completa_da_anni_precedenti(doc: dict, client: ClientCache, anno: int, log=print) -> int:
    """Insegnamenti 2026/27 senza libri perché il syllabus non ha ancora i testi: si cerca il syllabus
    ufficiale della stessa attività negli anni accademici precedenti (il più recente che li ha)."""
    per_codice, per_nome = indice_anni_precedenti(client, anno, log=log)
    cache: dict[tuple, list[dict]] = {}

    def libri_di(voce: dict) -> list[dict]:
        k = (voce["aa"], json.dumps(voce["params"], sort_keys=True))
        if k not in cache:
            sy = client.get("/insegnamento", voce["params"])
            libri: list[dict] = []
            if isinstance(sy, dict):
                libri = cineca_catalogue._testi_syllabus(sy)[0] or libri_extra(sy)
            cache[k] = libri
        return cache[k]

    trovati = 0
    for cs in doc["corsi"]:
        nome_cds = _norm(cs.get("nome"))
        for it in cs["insegnamenti"]:
            if it.get("libri"):
                continue
            m = re.search(r"/insegnamenti/(\d+)/([^/?]+)", it.get("url") or "")
            if m and (m.group(1), m.group(2)) in _CON_TESTO:
                continue  # il syllabus attuale ha un testo (senza libri: materiali su Moodle, da indicare…)
            cand = list(per_codice.get(str(it.get("codice")), [])) + list(per_nome.get((nome_cds, _norm(it["nome"])), []))
            visti = set()
            for voce in sorted(cand, key=lambda v: -v["aa"]):
                k = (voce["aa"], json.dumps(voce["params"], sort_keys=True))
                if k in visti:
                    continue
                visti.add(k)
                libri = libri_di(voce)
                if libri:
                    aa = voce["aa"]
                    nota = f"Dal syllabus {aa}/{(aa + 1) % 100:02d} (quello {anno}/{(anno + 1) % 100:02d} non ha ancora i testi)"
                    it["libri"] = [dict(b, note=(b.get("note") + "; " if b.get("note") else "") + nota) for b in libri]
                    it["stato_libri"] = "completo"
                    trovati += 1
                    break
    log(f"[unitn] insegnamenti con libri dal syllabus di un anno precedente: {trovati}")
    return trovati


def fetch_ateneo(uid: str = "unitn", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    client = ClientCache(BASE)
    cineca_catalogue._testi_syllabus = _testi_syllabus
    try:
        doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                            client=client, coorte_per_nome=True, libri_extra=libri_extra)
        if syllabus:
            completa_da_anni_precedenti(doc, client, anno, log)
    finally:
        cineca_catalogue._testi_syllabus = _testi_originale
    associa(doc, log)
    return doc


# Universitaly ha due corsi «Management» LM-77: 1627991 (corsi.unitn.it/it/management, Dipartimento di
# Economia e Management) e 1627989 (corsi.unitn.it/en/european-master-business-studies, EMBS). Nel
# catalogo sono 0132H «Management» e 0138H «Management - EMBS». Il nome non li distingue: si indica l'id.
ID_CORSI = {"0132H": "unitn-lm-77-management-1627991"}
ID_EMBS_UNIVERSITALY = "unitn-lm-77-management"  # 1627989: ha lo stesso piano di «Management - EMBS» (0138H)


def associa(doc: dict, log=print) -> None:
    import copy

    extra = []
    for cs in doc["corsi"]:
        cod = cs.get("codice_ateneo")
        if cod in ID_CORSI:
            cs["id"] = ID_CORSI[cod]
        elif cod == "0138H":
            copia = copy.deepcopy(cs)
            copia["id"] = ID_EMBS_UNIVERSITALY
            extra.append(copia)
    doc["corsi"] += extra
    log(f"[unitn] corsi associati per id: {len(ID_CORSI) + len(extra)}")


# --- appelli: bacheca pubblica di Esse3 (tutte le strutture) + codici di attività dei piani precedenti ---

ESSE3 = "https://unitn.esse3.cineca.it"


def _parole(s: str | None) -> set[str]:
    return {w for w in _norm(s).split() if len(w) >= 3}


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli della bacheca di Esse3. La bacheca usa spesso il codice di un piano precedente (o di un
    altro corso di studio) per lo stesso insegnamento: l'appello si assegna anche agli insegnamenti dei
    corsi con lo stesso nome e almeno un docente in comune (stesso esame, codice diverso)."""
    from .esse3_appelli import fetch_appelli as esse3

    app = esse3(uid, ESSE3, log=log)
    codici = {i["codice"] for c in corsi for i in c["insegnamenti"]}
    estesi = 0
    for cod, lst in list(app.items()):
        if cod in codici or not lst:
            continue
        nome = _norm(lst[0].get("titolo"))
        doc_app = set().union(*(_parole(e.get("docenti")) for e in lst))
        if not nome or not doc_app:
            continue
        for c in corsi:
            for i in c["insegnamenti"]:
                if _norm(i["nome"]) != nome or i["codice"] in app and i["codice"] != cod:
                    continue
                if not doc_app & set().union(*(_parole(d) for d in i.get("docenti") or [])):
                    continue
                viste = {(e["data"], e["ora"], e["tipo"]) for e in app.get(i["codice"], [])}
                nuovi = [e for e in lst if (e["data"], e["ora"], e["tipo"]) not in viste]
                if nuovi:
                    app.setdefault(i["codice"], []).extend(nuovi)
                    estesi += 1
    log(f"[unitn] insegnamenti con appelli per nome e docente (codice diverso): {estesi}")
    return app
