"""Toglie dal database già costruito email personali, link a file locali e parametri di accesso.

    python tools/db_builder/togli_email.py [ateneo ...]      # corregge
    python tools/db_builder/togli_email.py --verifica         # controlla soltanto

I testi dei programmi e dei libri copiati dalle pagine degli atenei contengono a
volte la casella personale di un docente o di una copisteria (Gmail, Libero,
Tiscali, …) o un collegamento a un file sul computer di chi ha scritto la pagina
(`file:///C:/Users/<nome>/Downloads/dispensa.pdf`: non lo apre nessuno e contiene
il nome di una persona) o un parametro di accesso dentro un collegamento
(`?token=…` del proxy di una biblioteca, `;jsessionid=…`, `&sid=…`, `?pwd=…` di una
riunione Zoom): nel database pubblico non vanno. La build li toglie già
(`pulizia.senza_email_personali`, `senza_percorsi_locali` e
`senza_parametri_di_accesso` in build_db.py, dividi_per_corso.py e nell'unione dei
moduli); questo script applica gli stessi
filtri ai file `corsi/<ateneo>.json` e `moduli/<ateneo>.json` esistenti senza
rifare la raccolta, aggiorna le impronte in `meta.json` e poi rigenera i file per
corso degli atenei toccati (dividi_per_corso.py). Le caselle istituzionali
(@unixx.it) restano. Dopo la correzione serve `python tools/db_builder/sync_assets.py`
(copia `meta.json` negli asset dell'app).

Con --verifica non scrive nulla ed esce con 1 se nei file pubblici di
`database/` (corsi, moduli, per_corso, sessioni, argomenti e i file della
cartella) c'è ancora un indirizzo personale, un link a un file locale o un parametro
di accesso (stampa
solo file e prime lettere). Il controllo legge ogni file una volta, cerca sui
byte partendo da «@» e dai prefissi dei percorsi e usa più processi (come il
controllo della copia pubblica).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

QUI = Path(__file__).resolve().parent
sys.path.insert(0, str(QUI))
from pulizia import (  # noqa: E402
    EMAIL_PERSONALE,
    PERCORSO_LOCALE,
    ha_email_personali,
    ha_parametri_di_accesso,
    ha_percorsi_locali,
    parametri_di_accesso_in,
    senza_email_personali,
    senza_parametri_di_accesso,
    senza_percorsi_locali,
)

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

# Controllo veloce: si cerca la «@» e un dominio (carattere fisso, quindi veloce) e solo
# attorno a ogni candidato si prova l'espressione completa; per i percorsi si cercano
# i prefissi `file:/` e `<lettera>:` + barra + Users (nel JSON la barra rovesciata è doppia).
_CANDIDATO_EMAIL = re.compile(rb"@[A-Za-z0-9\-]{1,63}\.[A-Za-z]")
_CANDIDATO_PERCORSO = re.compile(
    rb"(?<![A-Za-z0-9])(?:[Ff][Ii][Ll][Ee]:/|[A-Za-z]:(?:\\\\|\\|/)+(?:Users|USERS|users|Documents and Settings)[\\/])")


def _controlla_file(voce: tuple[str, str]) -> list[str]:
    """Indirizzi personali e percorsi locali di un file: righe «file: tipo (prime lettere)»."""
    rel, percorso = voce
    b = Path(percorso).read_bytes()
    out: list[str] = []
    if b"@" in b:
        for m in _CANDIDATO_EMAIL.finditer(b):
            a = m.start()
            inizio = max(0, a - 65)
            finestra = b[inizio:a + 90].decode("utf-8", errors="ignore")
            pos = len(b[inizio:a].decode("utf-8", errors="ignore"))  # posizione della «@» nella finestra
            for e in EMAIL_PERSONALE.finditer(finestra):
                if e.start() <= pos < e.end():
                    out.append(f"  · {rel}: indirizzo personale ({e.group(0)[:4]}…)")
                    break
    fine = 0  # un link con un percorso `C:/Users/<nome>/…` dentro `file:///…` conta una volta
    for m in _CANDIDATO_PERCORSO.finditer(b):
        if m.start() < fine:
            continue
        finestra = b[m.start():m.start() + 600].decode("utf-8", errors="ignore")
        trovato = PERCORSO_LOCALE.match(finestra)
        if trovato:
            fine = m.start() + len(trovato.group(0).encode("utf-8"))
            out.append(f"  · {rel}: link a un file del computer di chi ha scritto la pagina ({finestra[:4]}…)")
    for _, nome in parametri_di_accesso_in(b):
        out.append(f"  · {rel}: parametro di accesso o di sessione in un link ({nome}…)")
    return out


def _file_pubblici(db: Path):
    for cartella in PUBBLICHE:
        yield from sorted((db / cartella).rglob("*.json"))
    yield from sorted(db.glob("*.json"))


def verifica(db: Path = DB, processi: int | None = None) -> int:
    voci = [(f.relative_to(db).as_posix(), str(f)) for f in _file_pubblici(db)]
    trovati: list[str] = []
    if len(voci) > 8:
        with ProcessPoolExecutor(processi or min(8, os.cpu_count() or 2)) as ex:
            for righe in ex.map(_controlla_file, voci, chunksize=16):
                trovati += righe
    else:
        for v in voci:
            trovati += _controlla_file(v)
    for r in trovati:
        print(r)
    if trovati:
        print(f"{len(trovati)} dati personali nel database (indirizzi email, link a file locali, parametri di accesso): "
              "python tools/db_builder/togli_email.py")
        return 1
    print("Nessun indirizzo email personale, link a file locali o parametro di accesso nel database.")
    return 0


def _da_correggere(testo: str) -> bool:
    return ("@" in testo and EMAIL_PERSONALE.search(testo) is not None) or (
        PERCORSO_LOCALE.search(testo) is not None) or ha_parametri_di_accesso(testo)


def main(argv: list[str]) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    if "--verifica" in argv:
        return verifica()
    solo = set(argv)
    from ricostruisci import LOCK, _blocca, versione_nuova  # lo stesso lucchetto delle ricostruzioni

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
                if not _da_correggere(testo):
                    continue
                dati = json.loads(testo)
                formato = _formato(testo, dati)
                if formato is None:
                    print(f"! {cartella}/{f.name}: formato diverso da quello della build, non toccato")
                    continue
                nuovi = senza_parametri_di_accesso(senza_percorsi_locali(senza_email_personali(dati)))
                if ha_email_personali(nuovi) or ha_percorsi_locali(nuovi) or ha_parametri_di_accesso(nuovi):
                    print(f"! {cartella}/{f.name}: restano dati personali fuori dai testi JSON")
                f.write_text(_dump(nuovi, formato), encoding="utf-8", newline="\n")
                toccati.add(uid)
                print(f"{cartella}/{f.name}: indirizzi personali, link a file locali e parametri di accesso tolti")
                m = meta.get("atenei", {}).get(uid)
                if cartella == "corsi" and m is not None and m.get("file") == f"corsi/{uid}.json":
                    m["sha256"] = hashlib.sha256(f.read_bytes()).hexdigest()
        if toccati:
            now = datetime.now(timezone.utc)
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
