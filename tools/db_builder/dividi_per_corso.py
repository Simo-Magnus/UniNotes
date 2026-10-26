"""Divide il database per corso di laurea: un file per ogni corso.

L'app non scarica più tutti i dati dell'ateneo (i file dei grandi atenei
superano i 50 MB di corsi e i 15 MB di moduli), ma solo quelli del corso
scelto: tutti gli anni, tutti i percorsi, libri, appelli e i moduli di
studio dei suoi insegnamenti. Lo script legge i file per ateneo già
costruiti (`corsi/<ateneo>.json` da build_db.py, `moduli/<ateneo>.json`)
e scrive:

- `per_corso/<ateneo>/<corso>.json`: stessa forma di `corsi/<ateneo>.json`
  con il solo corso in `corsi`, più `moduli` (insegnamento → moduli) con i
  moduli dei suoi insegnamenti; nei corsi con più percorsi, il corso ha anche
  `percorso_classico` (vedi percorso_classico.py);
- `per_corso/<ateneo>/indice.json`: per ogni corso l'impronta sha256 e la
  dimensione del file, così l'app riscarica un corso solo se è cambiato.

I file di corsi che non ci sono più vengono eliminati. In `meta.json` ogni
ateneo riceve `per_corso` (percorso dell'indice) e `sha256_per_corso`
(impronta dell'indice). Va eseguito dopo build_db.py e prima di
sync_assets.py:

    python tools/db_builder/dividi_per_corso.py [--solo id1,id2]
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys
import time

from percorso_classico import scegli as percorso_classico
from pulizia import nomi_insegnamenti, senza_email_personali, senza_parametri_di_accesso, senza_percorsi_locali

ROOT = pathlib.Path(__file__).resolve().parents[2]
DB = ROOT / "database"
OUT = DB / "per_corso"
ID_VALIDO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def _scrivi(path: pathlib.Path, data) -> bytes:
    """Scrive solo se il contenuto cambia (meno modifiche nel repository)."""
    testo = (json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if not path.exists() or path.read_bytes() != testo:
        path.parent.mkdir(parents=True, exist_ok=True)
        # su Windows un file appena letto da un altro processo (antivirus, indicizzazione,
        # git) può rifiutare per un attimo la scrittura (OSError 22/13): si riprova
        for prova in range(10):  # fino a ~30 s: a volte il blocco dura qualche secondo
            try:
                path.write_bytes(testo)
                break
            except OSError:
                if prova == 9:
                    raise
                time.sleep(0.6 * (prova + 1))
    return testo


def _base(ins_id: str) -> str:
    """Stesso codice in un altro anno del piano (`<id>-a2`) o con l'altra obbligatorietà in
    altri percorsi (`<id>-scelta`, `<id>-a2-obbl`): i moduli sono quelli del codice."""
    return re.sub(r"(-a(\d+|x))?(-(scelta|obbl))?$", "", ins_id)


def dividi(uid: str) -> dict | None:
    src = DB / "corsi" / f"{uid}.json"
    if not src.exists():
        return None
    # niente indirizzi email personali né link a file del computer di chi ha scritto la
    # pagina nei file per corso, anche se corsi/ o moduli/ dell'ateneo non sono ancora
    # stati ricostruiti con i filtri
    doc = senza_email_personali(json.loads(src.read_text(encoding="utf-8")))
    doc = senza_percorsi_locali(doc)
    doc = senza_parametri_di_accesso(doc)
    # nomi degli insegnamenti senza CFU e codici (come l'ultimo passo di build_db.py), anche se
    # corsi/<ateneo>.json non è ancora stato ricostruito con la pulizia: cambia solo il testo
    nomi_insegnamenti(doc.get("corsi") or [])
    mod_path = DB / "moduli" / f"{uid}.json"
    moduli = json.loads(mod_path.read_text(encoding="utf-8")).get("insegnamenti", {}) if mod_path.exists() else {}
    moduli = {k: senza_email_personali(v) for k, v in moduli.items()}
    moduli = {k: senza_percorsi_locali(v) for k, v in moduli.items()}
    moduli = {k: senza_parametri_di_accesso(v) for k, v in moduli.items()}
    testa = {k: v for k, v in doc.items() if k != "corsi"}
    cartella = OUT / uid
    indice: dict[str, dict] = {}
    for corso in doc.get("corsi", []):
        cid = corso.get("id") or ""
        if not ID_VALIDO.match(cid) or cid == "indice":
            print(f"! {uid}: id di corso non valido come nome di file: {cid!r}", file=sys.stderr)
            continue
        if cid in indice:
            print(f"! {uid}: corso ripetuto {cid}", file=sys.stderr)
            continue
        ins_ids = {i.get("id") for i in corso.get("insegnamenti", []) if i.get("id")}
        # corsi con più percorsi: quello da proporre già scelto
        classico = percorso_classico(corso)
        if classico:
            corso = {**corso, "percorso_classico": classico}
        dati = {**testa, "corsi": [corso],
                "moduli": {k: moduli[k] if k in moduli else moduli[_base(k)]
                           for k in sorted(ins_ids) if k in moduli or _base(k) in moduli}}
        testo = _scrivi(cartella / f"{cid}.json", dati)
        indice[cid] = {"sha256": hashlib.sha256(testo).hexdigest(), "byte": len(testo)}
    # corsi non più presenti
    if cartella.exists():
        for f in cartella.glob("*.json"):
            if f.stem != "indice" and f.stem not in indice:
                f.unlink()
    testo = _scrivi(cartella / "indice.json", {
        "schema": 1, "universita_id": uid, "anno_accademico": doc.get("anno_accademico"),
        "aggiornato_il": doc.get("aggiornato_il"), "corsi": dict(sorted(indice.items())),
    })
    return {"per_corso": f"per_corso/{uid}/indice.json",
            "sha256_per_corso": hashlib.sha256(testo).hexdigest(),
            "corsi_file": len(indice),
            "byte_max": max((v["byte"] for v in indice.values()), default=0)}


def main(argv: list[str]) -> int:
    solo = None
    if "--solo" in argv:
        solo = set(argv[argv.index("--solo") + 1].split(","))
    meta_path = DB / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    tot = 0
    massimo = (0, "")
    for uid in sorted(meta.get("atenei", {})):
        if solo and uid not in solo:
            continue
        r = dividi(uid)
        if r is None:
            continue
        m = meta["atenei"][uid]
        m["per_corso"] = r["per_corso"]
        m["sha256_per_corso"] = r["sha256_per_corso"]
        tot += r["corsi_file"]
        massimo = max(massimo, (r["byte_max"], uid))
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{tot} file per corso; il più grande {massimo[0] // 1024} KB ({massimo[1]})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
