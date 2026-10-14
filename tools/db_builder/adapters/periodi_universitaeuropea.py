"""Semestre degli insegnamenti dell'Università Europea di Roma dal suo Course Catalogue Cineca.

Le pagine del corso su www.uer.it non riportano il periodo; l'ateneo però pubblica il piano di studi anche
su `unier.coursecatalogue.cineca.it` (API pubblica `/api/v1/corso/<coorte>/<cod>`), dove ogni attività ha
«Primo/Secondo Ciclo Semestrale» con le date del ciclo. L'insegnamento si ritrova nel piano dello stesso
corso di studio per nome e anno di corso (coorte = 2026 - anno + 1; in subordine un'altra coorte dello
stesso corso). Se i percorsi dello stesso corso danno periodi diversi, l'insegnamento resta senza periodo.
"""
from __future__ import annotations

import re
from collections import defaultdict

from . import periodi
from .periodi_cineca_syllabus import Api, _periodo, _walk, data_gma
import sys
sys.path.insert(0, str(periodi.ROOT / "tools" / "db_builder"))
import pulizia  # noqa: E402

HOST = "unier.coursecatalogue.cineca.it"
ANNO = 2026
LACUNE: dict[str, str] = {}


def _norm(s: str) -> str:
    s = (s or "").lower().replace("à", "a").replace("è", "e").replace("é", "e").replace("ì", "i").replace("ò", "o").replace("ù", "u")
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _attivita(piano) -> list[tuple[int | None, dict]]:
    out = []
    if isinstance(piano, list):
        piano = piano[0] if piano else None
    for p in (piano or {}).get("percorsi") or []:
        for a in p.get("anni") or []:
            k = int(a["anno"]) if str(a.get("anno")).isdigit() else None
            for g in a.get("insegnamenti") or ([{"attivita": a["attivita"]}] if a.get("attivita") else []):
                for att in g.get("attivita") or []:
                    out.append((k, att))
    return out


def fetch_periodi(uid: str = "universitaeuropea", log=print) -> dict:
    api = Api(HOST)
    base = f"https://{HOST}"
    mancanti = periodi.mancanti(uid)
    corsi = {c["id"]: c for c in periodi.carica(uid)["corsi"]}
    # corsi del catalogo per coorte: (coorte, nome normalizzato) -> cod
    cat: dict[tuple, str] = {}
    for y in range(ANNO - 5, ANNO + 1):
        cds: list[dict] = []
        _walk(api.get("/corsi", {"anno": y, "minimal": "true"}) or [], lambda x: "cdsCod" in x and "aa" in x and "cod" in x and "des_it" in x, cds)
        for x in cds:
            if str(x["aa"]) == str(y):
                cat[(y, _norm(x["des_it"]))] = str(x["cod"])
    voci: dict[tuple, dict] = defaultdict(lambda: defaultdict(set))  # (corso, anno, nome) -> {(periodo, ini, fin, url, y)}
    visti = set()
    for m in mancanti:
        c = corsi[m["corso"]]
        for y in range(ANNO - 5, ANNO + 1):
            cod = cat.get((y, _norm(c["nome"])))
            if not cod or (m["corso"], y) in visti:
                continue
            visti.add((m["corso"], y))
            for k, att in _attivita(api.get(f"/corso/{y}/{cod}")):
                testo = (att.get("periodo_didattico_it") or "").strip() or None
                ini, fin = data_gma(att.get("data_inizio_periodo_didattico")), data_gma(att.get("data_fine_periodo_didattico"))
                p, ini2, fin2, _ = _periodo({"periodo_didattico_it": testo, "data_inizio_periodo_didattico": ini,
                                             "data_fine_periodo_didattico": fin})
                if not p:
                    continue
                url = (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}/"
                       f"{att.get('corso_percorso_id')}?coorte={y}")
                voci[(m["corso"], k, _norm(att.get("des_it")))]["v"].add((p, ini2, fin2, url, y))
    out: dict[str, dict] = {}
    for m in mancanti:
        occ = voci.get((m["corso"], m["anno"], _norm(m["nome"])), {}).get("v")
        if not occ:
            LACUNE[m["id"]] = "il piano del catalogo non riporta il periodo per questo insegnamento (o non lo elenca)"
            continue
        y_att = (ANNO - (m["anno"] or 1) + 1)
        scelte = [o for o in occ if o[4] == y_att] or [o for o in occ if o[4] == max(x[4] for x in occ)]
        if len({pulizia.periodo(o[0], o[1], o[2]) for o in scelte}) != 1:
            LACUNE[m["id"]] = "periodi diversi nei percorsi del corso"
            continue
        p, ini, fin, url, y = sorted(scelte)[0]
        out[m["id"]] = {"periodo": p, "periodo_inizio": ini, "periodo_fine": fin, "fonte": url}
    log(f"[{uid}] semestri trovati {len(out)} su {len(mancanti)}; richieste {api.richieste}")
    return out
