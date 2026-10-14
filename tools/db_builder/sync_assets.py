"""Copia nell'app la parte del database inclusa negli asset.

L'app è leggera: negli asset ci sono solo i file comuni, `universita.json`
e `indice_corsi.json` (e `meta.json` e `corsi_sostituiti.json`, se ci
sono), circa 1 MB, per scegliere ateneo e corso anche senza internet. I dati
di ogni ateneo (corsi, sessioni, moduli) l'app li scarica da
internet solo per l'ateneo scelto e li salva sul dispositivo. Le build di
GitHub Actions usano questo script senza opzioni.

Con `--completo` (solo per le build locali, per esempio per provare l'app
senza rete o con un database non pubblicato) copia anche i file per ateneo:
`corsi/<id>.json.gz` e `moduli/<id>.json.gz` compressi
e `sessioni/<id>.json` (circa 95 MB in tutto). Senza `--completo` i file per
ateneo rimasti negli asset da un'esecuzione precedente vengono eliminati,
così una build locale torna leggera. Nel repository questi file non vengono
salvati (.gitignore).

Uso (dalla radice del repository):

    python tools/db_builder/sync_assets.py [--completo]

Un file mancante in `database/` viene saltato (con un avviso); se manca
`indice_corsi.json` negli asset viene scritto un indice vuoto valido.
"""
from __future__ import annotations

import gzip
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "database"
DEST = ROOT / "app" / "assets" / "database"
FILES = ("universita.json", "indice_corsi.json", "meta.json", "corsi_sostituiti.json")
# cartelle dei file per ateneo (True = compressi in .json.gz negli asset)
PER_ATENEO = (("corsi", True), ("sessioni", False), ("moduli", True))


def _valid_json(path: pathlib.Path) -> bool:
    try:
        with path.open(encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"! {path.name}: JSON non valido ({e})", file=sys.stderr)
        return False
    return isinstance(data, dict) and data.get("schema", 1) == 1


def _pulisci_per_ateneo() -> int:
    """Toglie dagli asset i file per ateneo (restano le cartelle con .gitkeep,
    dichiarate in pubspec.yaml)."""
    n = 0
    for sub, _ in PER_ATENEO:
        out = DEST / sub
        out.mkdir(parents=True, exist_ok=True)
        for old in out.glob("*.json*"):
            old.unlink()
            n += 1
    return n


def _per_ateneo() -> int:
    """corsi/ e moduli/<id>.json -> <id>.json.gz; sessioni/<id>.json negli asset."""
    _pulisci_per_ateneo()
    n = 0
    for sub, compress in PER_ATENEO:
        out = DEST / sub
        for src in sorted((SRC / sub).glob("*.json")):
            if compress:
                # mtime=0: stesso contenuto, stesso file compresso
                with (out / (src.name + ".gz")).open("wb") as raw, \
                        gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
                    gz.write(src.read_bytes())
            else:
                shutil.copyfile(src, out / src.name)
            n += 1
    size = sum(f.stat().st_size for f in DEST.rglob("*.json*"))
    print(f"+ {n} file per ateneo (asset totali {size // (1024 * 1024)} MB)")
    return n


def main() -> int:
    DEST.mkdir(parents=True, exist_ok=True)
    copied = 0
    for name in FILES:
        src = SRC / name
        if not src.exists():
            print(f"- {name}: non presente in database/, saltato")
            continue
        if not _valid_json(src):
            return 1
        shutil.copyfile(src, DEST / name)
        copied += 1
        print(f"+ {name} ({src.stat().st_size // 1024} KB)")
    index = DEST / "indice_corsi.json"
    if not index.exists():
        index.write_text(
            json.dumps({"schema": 1, "anno_accademico": None, "corsi": []},
                       ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8",
        )
        print("+ indice_corsi.json vuoto (segnaposto)")
    if "--completo" in sys.argv[1:]:
        _per_ateneo()
    else:
        removed = _pulisci_per_ateneo()
        if removed:
            print(f"- {removed} file per ateneo tolti dagli asset (si scaricano nell'app)")
    print(f"{copied} file copiati in {DEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
