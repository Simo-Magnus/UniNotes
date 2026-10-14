"""Rileva quali atenei hanno le piattaforme pubbliche Cineca e aggiorna piattaforme.json.

Per ogni ateneo prova <id>.coursecatalogue.cineca.it (insegnamenti e syllabus) e
<id>.esse3.cineca.it (bacheca appelli). Da eseguire ogni anno prima di fetch_atenei.py
(lo fa il workflow Database) o quando un ateneo cambia piattaforma.
"""
import concurrent.futures as cf
import json
import pathlib

import requests

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(__file__).parent / "piattaforme.json"
ALIAS = {"unicampania": ["unicampania", "unina2"], "uniroma1": ["uniroma1"], "unich": ["unich", "udanet"]}
HEAD = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder)"}


def check(url: str) -> str | None:
    try:
        r = requests.get(url, headers=HEAD, timeout=20, allow_redirects=True)
        return "https://" + r.url.split("/")[2] if r.status_code == 200 else None
    except requests.RequestException:
        return None


def main() -> None:
    unis = json.loads((ROOT / "database/universita.json").read_text(encoding="utf-8"))["universita"]
    old = json.loads(OUT.read_text(encoding="utf-8"))["atenei"] if OUT.exists() else {}
    jobs = {}
    for u in unis:
        for a in ALIAS.get(u["id"], [u["id"]]):
            jobs[(u["id"], "coursecatalogue", a)] = f"https://{a}.coursecatalogue.cineca.it/"
            jobs[(u["id"], "esse3", a)] = f"https://{a}.esse3.cineca.it/Home.do"
    with cf.ThreadPoolExecutor(16) as ex:
        res = dict(zip(jobs, ex.map(check, jobs.values())))
    out: dict[str, dict] = {}
    for (uid, kind, _), host in res.items():
        if host and kind not in out.get(uid, {}):
            out.setdefault(uid, {})[kind] = host
    # una piattaforma non raggiungibile oggi resta (può essere un errore temporaneo)
    for uid, v in old.items():
        for k, host in v.items():
            out.setdefault(uid, {}).setdefault(k, host)
    OUT.write_text(json.dumps({"descrizione": "Piattaforme pubbliche Cineca per ateneo (discover_platforms.py). "
                                              "coursecatalogue = insegnamenti e syllabus; esse3 = bacheca appelli.",
                               "atenei": dict(sorted(out.items()))}, indent=1, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print(f"{len(out)} atenei, {sum('coursecatalogue' in v for v in out.values())} con Course Catalogue, "
          f"{sum('esse3' in v for v in out.values())} con Esse3")


if __name__ == "__main__":
    main()
