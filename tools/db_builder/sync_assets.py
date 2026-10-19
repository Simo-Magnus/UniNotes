"""Copia nell'app la parte del database inclusa negli asset.

L'app è leggera: negli asset ci sono solo i file comuni, `universita.json`
e `indice_corsi.json` (e `meta.json` e `corsi_sostituiti.json`, se ci
sono), circa 1 MB, per scegliere ateneo e corso anche senza internet. I dati
del corso scelto (`per_corso/<ateneo>/<corso>.json`: tutti gli anni, libri,
appelli e moduli) e le sessioni d'esame dell'ateneo l'app li scarica da
internet e li salva sul dispositivo. Le build di GitHub Actions usano questo
script.

Le cartelle dei file per ateneo delle versioni precedenti (`corsi/`,
`sessioni/`, `moduli/` negli asset) vengono eliminate.

Uso (dalla radice del repository):

    python tools/db_builder/sync_assets.py

Un file mancante in `database/` viene saltato (con un avviso); se manca
`indice_corsi.json` negli asset viene scritto un indice vuoto valido.
"""
from __future__ import annotations

import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "database"
DEST = ROOT / "app" / "assets" / "database"
FILES = ("universita.json", "indice_corsi.json", "meta.json", "corsi_sostituiti.json")
# cartelle negli asset delle versioni precedenti (file per ateneo)
VECCHIE = ("corsi", "sessioni", "moduli")


def _valid_json(path: pathlib.Path) -> bool:
    try:
        with path.open(encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"! {path.name}: JSON non valido ({e})", file=sys.stderr)
        return False
    return isinstance(data, dict) and data.get("schema", 1) == 1


def _pulisci_vecchie() -> int:
    """Toglie dagli asset le cartelle dei file per ateneo."""
    n = 0
    for sub in VECCHIE:
        out = DEST / sub
        if out.is_dir():
            n += sum(1 for f in out.rglob("*") if f.is_file())
            shutil.rmtree(out)
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
    removed = _pulisci_vecchie()
    if removed:
        print(f"- {removed} file per ateneo tolti dagli asset (si scaricano nell'app)")
    print(f"{copied} file copiati in {DEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
