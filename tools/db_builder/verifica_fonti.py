"""Controllo a campione dei dati contro le fonti.

Per ogni ateneo si scelgono a caso alcuni insegnamenti con una pagina HTML (`url` o `url_sito`),
la si scarica di nuovo e si controlla che ci siano il nome dell'insegnamento e il titolo del primo
libro. Le pagine del Course Catalogue Cineca sono applicazioni JavaScript (i dati vengono dall'API,
non dall'HTML) e i PDF si saltano. Scrive data/verifica_fonti.json e stampa un riepilogo.

    python tools/db_builder/verifica_fonti.py [--per-ateneo 8] [--solo unibo,unimi]
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import html
import json
import pathlib
import random
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from adapters.unibo import Client  # noqa: E402

# applicazioni JavaScript (i dati vengono da un'API, non dall'HTML) e file binari
SALTA = re.compile(r"coursecatalogue\.|\?coorte=|gomp\.it|corsi\.unina\.it|docenti\.unina\.it|uke\.it|corsi\.unical\.it|"
                   r"\.(pdf|docx?)(\?|$)|/programma/|/pdf/", re.I)
VUOTE = {"di", "e", "del", "della", "dei", "delle", "la", "il", "lo", "in", "per", "con", "a", "da", "and", "of", "the",
         "i", "ii", "iii", "to", "for", "un", "una", "le", "gli", "al", "alla", "nel", "nella", "su"}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", html.unescape(s or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _parole(s: str) -> set[str]:
    return {w for w in _norm(s).split() if len(w) > 2 and w not in VUOTE}


def presente(testo: str, pagina: str, soglia: float = 0.8) -> bool:
    p = _parole(testo)
    if not p:
        return True
    return len(p & set(pagina.split())) / len(p) >= soglia


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-ateneo", type=int, default=8)
    ap.add_argument("--solo")
    ap.add_argument("--seme", type=int, default=7)
    args = ap.parse_args()
    random.seed(args.seme)
    solo = set(args.solo.split(",")) if args.solo else None
    lavori = []
    for f in sorted((ROOT / "database" / "corsi").glob("*.json")):
        if solo and f.stem not in solo:
            continue
        cand = []
        for c in json.loads(f.read_text(encoding="utf-8"))["corsi"]:
            for i in c.get("insegnamenti") or []:
                u = i.get("url_sito") if i.get("url_sito") and not SALTA.search(i["url_sito"]) else i.get("url")
                if u and u.startswith("http") and not SALTA.search(u):
                    cand.append((f.stem, c["id"], i, u))
        lavori += random.sample(cand, min(args.per_ateneo, len(cand)))
    c = Client(rate=6.0)

    def controlla(job):
        uid, cid, i, u = job
        r = c.get(u)
        if not r:
            return {"ateneo": uid, "corso": cid, "insegnamento": i.get("id"), "url": u, "esito": "non_raggiungibile"}
        pagina = " " + _norm(re.sub(r"<[^>]+>", " ", r.text)) + " "
        esito = {"ateneo": uid, "corso": cid, "insegnamento": i.get("id"), "url": u,
                 "nome": i.get("nome"), "nome_ok": presente(i.get("nome") or "", pagina)}
        libri = [lb for lb in i.get("libri") or [] if lb.get("titolo") or lb.get("citazione")]
        if libri:
            t = libri[0].get("titolo") or libri[0].get("citazione")
            esito["libro"] = t
            esito["libro_ok"] = presente(t, pagina, 0.6)
            # i libri possono stare in un'altra pagina dell'insegnamento (programma, syllabus)
            for altra in (i.get("url_sito"), u.rstrip("/") + "/programma"):
                if esito["libro_ok"] or not altra or altra == u or SALTA.search(altra):
                    continue
                ra = c.get(altra)
                if ra:
                    esito["libro_ok"] = presente(t, " " + _norm(re.sub(r"<[^>]+>", " ", ra.text)) + " ", 0.6)
        return esito

    with cf.ThreadPoolExecutor(6) as ex:
        esiti = list(ex.map(controlla, lavori))
    out = ROOT / "data" / "verifica_fonti.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(esiti, ensure_ascii=False, indent=1), encoding="utf-8")
    per = collections.defaultdict(lambda: collections.Counter())
    for e in esiti:
        k = per[e["ateneo"]]
        k["campione"] += 1
        if e["esito" if "esito" in e else "nome_ok"] == "non_raggiungibile":
            k["non_raggiungibili"] += 1
            continue
        k["nome_ok"] += e["nome_ok"]
        if "libro_ok" in e:
            k["libri"] += 1
            k["libro_ok"] += e["libro_ok"]
    print("| Ateneo | Campione | Nome trovato | Libro trovato | Pagine non raggiungibili |\n|---|---:|---:|---:|---:|")
    for uid, k in sorted(per.items()):
        print(f"| {uid} | {k['campione']} | {k['nome_ok']}/{k['campione'] - k['non_raggiungibili']} | "
              f"{k['libro_ok']}/{k['libri']} | {k['non_raggiungibili']} |")


if __name__ == "__main__":
    main()
