"""Semestre (periodo didattico) degli insegnamenti: contributo `database/contrib/auto/<uid>_periodi.json`.

Gli adattatori per ateneo (`periodi_<uid>.py`) ricavano il periodo dalle pagine ufficiali
dell'ateneo (campo «Periodo didattico» di Campusnet, Course Catalogue, Esse3, guide…) e lo
passano a `scrivi(uid, risultati)`, che controlla che gli insegnamenti esistano già in
`database/corsi/<uid>.json` (build_db.py non deve crearne di nuovi) e scrive il contributo.

`risultati`: {id_insegnamento: {"periodo": "1"|"2"|"annuale"|testo del periodo (es. "Primo semestre"),
                                "periodo_inizio": "GG/MM/AAAA" (facoltativo), "periodo_fine": …,
                                "fonte": URL della pagina che dice il periodo}}

`periodo_fonte` (URL reale della pagina: può essere di un altro anno accademico o di un'altra
coorte, purché dello stesso insegnamento) è un campo in più dell'insegnamento. Il periodo non
si deduce mai dall'anno di corso, dal codice o da altri insegnamenti: solo da ciò che dice la fonte.
"""
from __future__ import annotations

import json
import pathlib
import re
from datetime import date

ROOT = pathlib.Path(__file__).resolve().parents[3]
DB = ROOT / "database"
# attività che non hanno un semestre (come in SP\stats_uid.py)
NON = re.compile(r"prova finale|tesi|tirocini|stage|internship|altre attivit|ulteriori attivit|idoneit|a scelta|"
                 r"scelta libera|crediti liberi|attivit[aà] formative|seminari|laboratorio di tesi|final exam|thesis|"
                 r"elective|esame finale|abilit[aà] informatiche|ofa|corso zero|ADE\b", re.I)
VALIDI = {"1", "2", "3", "4", "annuale"}
# percorso locale della cartella di lavoro con le cache delle pagine (una riga):
# non nel repository, perché contiene il nome dell'utente del computer
CARTELLA_LAVORO = ROOT / "tools" / "db_builder" / "cartella_lavoro.txt"


def cartella_lavoro() -> str:
    """Cartella delle cache dei semestri (`SP` degli adattatori): la variabile
    SEMESTRI_SP, altrimenti il percorso scritto in `cartella_lavoro.txt`,
    altrimenti una cartella nella cartella temporanea."""
    import os
    import tempfile

    if os.environ.get("SEMESTRI_SP"):
        return os.environ["SEMESTRI_SP"]
    try:
        riga = CARTELLA_LAVORO.read_text(encoding="utf-8").strip()
    except OSError:
        riga = ""
    return riga or os.path.join(tempfile.gettempdir(), "uninotes_semestri")


def carica(uid: str) -> dict:
    return json.loads((DB / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))


def mancanti(uid: str) -> list[dict]:
    """Insegnamenti «veri» (non prove finali, tirocini…) senza semestre, nei corsi che non sono repliche."""
    out = []
    for c in carica(uid)["corsi"]:
        if c.get("piano_da"):
            continue
        for i in c.get("insegnamenti") or []:
            if NON.search(i.get("nome") or "") or i.get("periodo") or i.get("periodo_inizio"):
                continue
            out.append({"corso": c["id"], "corso_nome": c["nome"], "id": i["id"], "codice": i.get("codice"),
                        "nome": i.get("nome"), "anno": i.get("anno"), "url": i.get("url"),
                        "url_sito": i.get("url_sito"), "docenti": i.get("docenti") or []})
    return out


def _normalizza(p, inizio=None, fine=None) -> str | None:
    """Il periodo come lo usa l'app ("1", "2", "3", "4", "annuale") con le stesse regole di build_db
    (pulizia.periodo: date del periodo, «Primo semestre», …). Testi non riconosciuti («Da definire», «Ciclo 3»
    senza date…) -> None: non si inventa."""
    import sys
    sys.path.insert(0, str(ROOT / "tools" / "db_builder"))
    import pulizia
    if p is None and not (inizio and fine):
        return None
    r = pulizia.periodo(str(p).strip() if p is not None else None, inizio, fine)
    return r if r in VALIDI or re.fullmatch(r"[1-6]° periodo", r or "") else None  # «2° periodo»: ciclo dichiarato


def scrivi(uid: str, risultati: dict[str, dict], unisci: bool = True, nome_file: str | None = None) -> tuple[int, int]:
    """Scrive database/contrib/auto/<uid>_periodi.json (o `nome_file`: i contributi si applicano in ordine alfabetico,
    un file che deve vincere su <uid>_piani.json ecc. ha un nome che viene dopo). Con `unisci` mantiene i risultati
    già nel file. Ritorna (voci scritte, id sconosciuti scartati)."""
    db = carica(uid)
    esistenti = {i["id"]: c["id"] for c in db["corsi"] for i in c.get("insegnamenti") or []}
    nomi = {i["id"]: i.get("nome") for c in db["corsi"] for i in c.get("insegnamenti") or []}  # build_db vuole il nome
    out_path = DB / "contrib" / "auto" / (nome_file or f"{uid}_periodi.json")
    tutti: dict[str, dict] = {}
    if unisci and out_path.exists():
        old = json.loads(out_path.read_text(encoding="utf-8"))
        for c in old.get("corsi", []):
            for i in c["insegnamenti"]:
                if _normalizza(i.get("periodo"), i.get("periodo_inizio"), i.get("periodo_fine")):
                    tutti[i["id"]] = i
    scartati = 0
    oggi = date.today().isoformat()
    for iid, r in risultati.items():
        p = _normalizza(r.get("periodo"), r.get("periodo_inizio"), r.get("periodo_fine"))
        if iid not in esistenti or not p or not r.get("fonte"):
            scartati += 1
            continue
        voce = {"id": iid, "nome": nomi[iid], "periodo": p}
        if r.get("periodo_inizio") and r.get("periodo_fine"):
            voce["periodo_inizio"], voce["periodo_fine"] = r["periodo_inizio"], r["periodo_fine"]
        voce["periodo_fonte"] = r["fonte"]
        tutti[iid] = voce
    per_corso: dict[str, list] = {}
    for iid, v in tutti.items():
        v["nome"] = nomi.get(iid, v.get("nome"))
        if iid in esistenti:
            per_corso.setdefault(esistenti[iid], []).append(v)
    doc = {"universita_id": uid, "verificato_il": oggi,
           "corsi": [{"id": cid, "insegnamenti": sorted(l, key=lambda x: x["id"])} for cid, l in sorted(per_corso.items())]}
    out_path.write_text(json.dumps(doc, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    return len(tutti), scartati
