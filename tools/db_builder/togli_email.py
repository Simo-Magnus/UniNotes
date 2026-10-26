"""Toglie gli indirizzi email personali dai file del database già costruiti.

    python tools/db_builder/togli_email.py [ateneo ...]      # corregge
    python tools/db_builder/togli_email.py --verifica         # controlla soltanto

I testi dei programmi e dei libri copiati dalle pagine degli atenei contengono a
volte la casella personale di un docente o di una copisteria (Gmail, Libero,
Tiscali, …): nel database pubblico non vanno. La build li toglie già
(`pulizia.senza_email_personali` in build_db.py, dividi_per_corso.py e
nell'unione dei moduli); questo script applica lo stesso filtro ai file
`corsi/<ateneo>.json` e `moduli/<ateneo>.json` esistenti senza rifare la
raccolta, aggiorna le impronte in `meta.json` e poi rigenera i file per corso
degli atenei toccati (dividi_per_corso.py). Le caselle istituzionali
(@unixx.it) restano.

Con --verifica non scrive nulla ed esce con 1 se nei file pubblici di
`database/` (corsi, moduli, per_corso, sessioni, argomenti e i file della
cartella) c'è ancora un indirizzo personale (stampa solo file e prime lettere).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

QUI = Path(__file__).resolve().parent
sys.path.insert(0, str(QUI))
from pulizia import EMAIL_PERSONALE, ha_email_personali, senza_email_personali  # noqa: E402

ROOT = QUI.parents[1]
DB = ROOT / "database"


def _formato(testo: str, dati) -> str | None:
    """Serializzazione che riproduce il file così com'è (corsi: rientro 1; moduli: compatta)."""
    for formato in ("indent", "compatta"):
        if _dump(dati, formato) == testo:
            return formato
    return None


def _dump(dati, formato: str) -> str:
    if formato == "indent":
        return json.dumps(dati, ensure_ascii=False, indent=1) + "\n"
    return json.dumps(dati, ensure_ascii=False, separators=(",", ":")) + "\n"


# file del database che vanno nella copia pubblica (contatti e community restano
# nella repo privata, contrib/auto non è nel repository)
PUBBLICHE = ("corsi", "moduli", "per_corso", "sessioni", "argomenti")


def verifica(db: Path = DB) -> int:
    trovati = 0
    for cartella in PUBBLICHE + (".",):
        cerca = (db / cartella).glob("*.json") if cartella == "." else (db / cartella).rglob("*.json")
        for f in sorted(cerca):
            s = f.read_text(encoding="utf-8")
            if "@" not in s:
                continue
            for m in EMAIL_PERSONALE.finditer(s):
                trovati += 1
                print(f"  · {f.relative_to(db).as_posix()}: indirizzo personale ({m.group(0)[:4]}…)")
    if trovati:
        print(f"{trovati} indirizzi email personali nel database: python tools/db_builder/togli_email.py")
        return 1
    print("Nessun indirizzo email personale nel database.")
    return 0


def main(argv: list[str]) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    if "--verifica" in argv:
        return verifica()
    solo = set(argv)
    from ricostruisci import LOCK, _blocca  # lo stesso lucchetto delle ricostruzioni

    fd = _blocca()
    toccati: set[str] = set()
    try:
        meta_path = DB / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        for cartella in ("corsi", "moduli"):
            for f in sorted((DB / cartella).glob("*.json")):
                uid = f.stem
                if solo and uid not in solo:
                    continue
                testo = f.read_text(encoding="utf-8")
                if "@" not in testo or not EMAIL_PERSONALE.search(testo):
                    continue
                dati = json.loads(testo)
                formato = _formato(testo, dati)
                if formato is None:
                    print(f"! {cartella}/{f.name}: formato diverso da quello della build, non toccato")
                    continue
                nuovi = senza_email_personali(dati)
                if ha_email_personali(nuovi):
                    print(f"! {cartella}/{f.name}: restano indirizzi fuori dai testi JSON")
                f.write_text(_dump(nuovi, formato), encoding="utf-8", newline="\n")
                toccati.add(uid)
                print(f"{cartella}/{f.name}: indirizzi personali tolti")
                m = meta.get("atenei", {}).get(uid)
                if cartella == "corsi" and m is not None and m.get("file") == f"corsi/{uid}.json":
                    m["sha256"] = hashlib.sha256(f.read_bytes()).hexdigest()
        if toccati:
            now = datetime.now(timezone.utc)
            meta["versione"] = now.strftime("%Y.%m.%d")
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
