"""Toglie dai nomi degli insegnamenti del database già costruito i CFU e i codici.

    python tools/db_builder/nomi_insegnamenti.py [ateneo ...] [--esiti percorso.json]   # corregge
    python tools/db_builder/nomi_insegnamenti.py --verifica                             # controlla soltanto

Nel database il nome di un insegnamento è solo il nome: «Analisi matematica I (10 CFU)
(16ACFYO)» → «Analisi matematica I», «Storia contemporanea (cod. 120851)» → «Storia
contemporanea», «A422439 - Economics» → «Economics». I CFU e il codice stanno nei loro campi.
La build lo fa già (`pulizia.nomi_insegnamenti`, ultimo passo di build_db.py, e di nuovo in
dividi_per_corso.py); questo script applica la stessa pulizia ai file `corsi/<ateneo>.json`
esistenti senza rifare la raccolta, sotto il lucchetto delle ricostruzioni, controlla che id,
ordine e numero degli insegnamenti non cambino (l'app vi collega i dati dello studente),
aggiorna le impronte in `meta.json` e rigenera i file per corso degli atenei toccati
(dividi_per_corso.py). Poi serve `python tools/db_builder/sync_assets.py`.

`--esiti`: scrive i casi da controllare (CFU del nome diversi dal campo, omonimi che tengono il
codice, campi riempiti) in un file JSON.

Con --verifica non scrive nulla ed esce con 1 se in `corsi/` o in `per_corso/` c'è ancora un
nome che la pulizia cambierebbe.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

QUI = Path(__file__).resolve().parent
sys.path.insert(0, str(QUI))
from pulizia import nomi_insegnamenti  # noqa: E402
from togli_email import _dump, _formato  # noqa: E402

ROOT = QUI.parents[1]
DB = ROOT / "database"


def _ids(corsi: list[dict]) -> list[tuple]:
    return [(c.get("id"), tuple(i.get("id") for i in c.get("insegnamenti") or [])) for c in corsi]


def _correggi_file(percorso: str) -> dict:
    """Pulisce i nomi di un file `corsi/<ateneo>.json`: esito con impronta ed esiti."""
    f = Path(percorso)
    testo = f.read_text(encoding="utf-8")
    dati = json.loads(testo)
    formato = _formato(testo, dati)
    if formato is None:
        return {"uid": f.stem, "errore": "formato diverso da quello della build, non toccato"}
    prima = _ids(dati.get("corsi") or [])
    esiti: list = []
    n = nomi_insegnamenti(dati.get("corsi") or [], esiti)
    if _ids(dati.get("corsi") or []) != prima:
        return {"uid": f.stem, "errore": "id o ordine degli insegnamenti cambiati, non toccato"}
    out = {"uid": f.stem, "cambiati": n, "esiti": [e for e in esiti if e[0] != "nome"],
           "nomi": sum(1 for e in esiti if e[0] == "nome")}
    if n:
        testo = _dump(dati, formato).encode("utf-8")
        # su Windows un file appena letto da un altro processo (antivirus, indicizzazione) può
        # rifiutare per un attimo la scrittura (OSError 22/13): si riprova, come dividi_per_corso
        for prova in range(10):
            try:
                f.write_bytes(testo)
                break
            except OSError:
                if prova == 9:
                    raise
                time.sleep(0.6 * (prova + 1))
    # l'impronta sempre: un giro interrotto può aver già scritto il file senza aggiornare meta.json
    out["sha256"] = hashlib.sha256(f.read_bytes()).hexdigest()
    return out


def _da_cambiare(percorso: str) -> tuple[str, int]:
    dati = json.loads(Path(percorso).read_text(encoding="utf-8"))
    return percorso, nomi_insegnamenti(dati.get("corsi") or [])


def verifica(db: Path = DB, processi: int | None = None) -> int:
    file = [str(f) for f in sorted((db / "corsi").glob("*.json"))]
    file += [str(f) for f in sorted((db / "per_corso").rglob("*.json")) if f.name != "indice.json"]
    trovati = 0
    with ProcessPoolExecutor(processi or min(8, os.cpu_count() or 2)) as ex:
        for percorso, n in ex.map(_da_cambiare, file, chunksize=32):
            if n:
                trovati += n
                print(f"  · {Path(percorso).relative_to(db).as_posix()}: {n} nomi con CFU o codice")
    if trovati:
        print(f"{trovati} nomi di insegnamenti con CFU o codice: python tools/db_builder/nomi_insegnamenti.py")
        return 1
    print("Nessun nome di insegnamento con CFU o codice dell'insegnamento.")
    return 0


def main(argv: list[str]) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    if "--verifica" in argv:
        return verifica()
    dest_esiti = None
    if "--esiti" in argv:
        k = argv.index("--esiti")
        dest_esiti = Path(argv[k + 1])
        argv = argv[:k] + argv[k + 2:]
    solo = set(argv)
    from ricostruisci import LOCK, _blocca, versione_nuova  # lo stesso lucchetto delle ricostruzioni

    fd = _blocca()
    toccati: set[str] = set()
    tutti_esiti: dict[str, list] = {}
    try:
        meta_path = DB / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        file = [str(f) for f in sorted((DB / "corsi").glob("*.json")) if not solo or f.stem in solo]
        with ProcessPoolExecutor(min(4, os.cpu_count() or 2)) as ex:
            for r in ex.map(_correggi_file, file):
                uid = r["uid"]
                if r.get("errore"):
                    print(f"! corsi/{uid}.json: {r['errore']}")
                    continue
                if r["esiti"]:
                    tutti_esiti[uid] = r["esiti"]
                m = meta.get("atenei", {}).get(uid)
                cambiato = r["cambiati"] or (m is not None and m.get("sha256") != r["sha256"])
                if not cambiato:
                    continue
                toccati.add(uid)
                print(f"corsi/{uid}.json: {r['nomi']} nomi di insegnamenti ripuliti")
                if m is not None and m.get("file") == f"corsi/{uid}.json":
                    m["sha256"] = r["sha256"]
        if dest_esiti:
            dest_esiti.write_text(json.dumps(tutti_esiti, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        if toccati:
            now = datetime.now(timezone.utc)
            # stessa data di una versione già pubblicata: «AAAA.MM.GG.2», così l'app la vede nuova
            meta["versione"] = versione_nuova(meta.get("versione"), now.strftime("%Y.%m.%d"))
            meta["generato_il"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
            meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n", encoding="utf-8",
                                 newline="\n")
            r = subprocess.run([sys.executable, "-X", "utf8", str(QUI / "dividi_per_corso.py"),
                                "--solo", ",".join(sorted(toccati))], cwd=ROOT)
            if r.returncode:
                return r.returncode
    finally:
        os.close(fd)
        LOCK.unlink(missing_ok=True)
    print(f"atenei corretti: {', '.join(sorted(toccati)) or 'nessuno'}")
    return verifica()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
