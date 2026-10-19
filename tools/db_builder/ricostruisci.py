"""Ricostruisce il database di uno o più atenei, uno alla volta.

build_db.py e dividi_per_corso.py riscrivono anche file comuni (meta.json,
indice_corsi.json): con più lavori in parallelo (un agente per ateneo) si
eseguono sotto un lucchetto (`database/.ricostruzione.lock`), poi si stampa il
controllo dei CFU degli atenei ricostruiti.

    python tools/db_builder/ricostruisci.py <id1,id2>
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import time

QUI = pathlib.Path(__file__).resolve().parent
ROOT = QUI.parents[1]
LOCK = ROOT / "database" / ".ricostruzione.lock"


def _blocca():
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    inizio = time.time()
    while True:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            return fd
        except FileExistsError:
            # lucchetto rimasto da un processo interrotto: dopo 15 minuti si toglie
            if time.time() - LOCK.stat().st_mtime > 900:
                LOCK.unlink(missing_ok=True)
                continue
            if time.time() - inizio > 3600:
                raise SystemExit("Lucchetto occupato da più di un'ora")
            time.sleep(3)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    uids = argv[0]
    py = [sys.executable, "-X", "utf8"]
    fd = _blocca()
    try:
        for cmd in (["build_db.py", "--solo", uids], ["dividi_per_corso.py", "--solo", uids]):
            r = subprocess.run(py + [str(QUI / cmd[0])] + cmd[1:], cwd=ROOT)
            if r.returncode:
                return r.returncode
    finally:
        os.close(fd)
        LOCK.unlink(missing_ok=True)
    return subprocess.run(py + [str(QUI / "controllo_cfu.py"), "--solo", uids, "--dettaglio"], cwd=QUI).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
