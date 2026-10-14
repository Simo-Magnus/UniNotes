"""Verifica i calendari delle sessioni d'esame (database/sessioni/<id>.json).

Per ogni ateneo controlla: formato, date valide (AAAA-MM-GG, fine non prima
dell'inizio, dentro l'anno accademico 2026/27 allargato), fonte https,
ogni corso di laurea del database in un solo calendario oppure tra i
«corsi_scoperti», nessun id sconosciuto. Stampa un riepilogo per ateneo e
gli errori; esce con 1 se ci sono errori o atenei senza file.

Uso (dalla radice del repository):

    python tools/db_builder/verifica_sessioni.py [id ...]
"""

from __future__ import annotations

import datetime as dt
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "database"
MIN = dt.date(2026, 8, 1)
MAX = dt.date(2028, 4, 30)


def _date(v: object) -> dt.date | None:
    try:
        return dt.date.fromisoformat(str(v))
    except ValueError:
        return None


def verifica(uid: str) -> tuple[list[str], str]:
    errs: list[str] = []
    f = DB / "sessioni" / f"{uid}.json"
    if not f.exists():
        return ["file mancante"], "-"
    try:
        d = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return [f"JSON non valido: {e}"], "-"
    corsi_file = DB / "corsi" / f"{uid}.json"
    ids = set()
    if corsi_file.exists():
        corsi = json.loads(corsi_file.read_text(encoding="utf-8")).get("corsi", [])
        ids = {c["id"] for c in corsi if isinstance(c, dict) and c.get("id")}
    if d.get("universita_id") != uid:
        errs.append(f"universita_id {d.get('universita_id')!r} diverso da {uid!r}")
    seen: dict[str, str] = {}
    n_sess = 0
    for i, cal in enumerate(d.get("calendari") or []):
        where = f"calendario {i + 1} ({cal.get('ambito')})"
        fonte = cal.get("fonte") or ""
        if not str(fonte).startswith("https://") and not str(fonte).startswith("http://"):
            errs.append(f"{where}: fonte mancante")
        sess = cal.get("sessioni") or []
        if not sess:
            errs.append(f"{where}: nessuna sessione")
        for s in sess:
            n_sess += 1
            a, b = _date(s.get("inizio")), _date(s.get("fine"))
            if not s.get("nome"):
                errs.append(f"{where}: sessione senza nome")
            if a is None or b is None:
                errs.append(f"{where}: {s.get('nome')}: date non valide")
                continue
            if b < a:
                errs.append(f"{where}: {s.get('nome')}: fine prima dell'inizio")
            if a < MIN or b > MAX:
                errs.append(f"{where}: {s.get('nome')}: {a}–{b} fuori dal 2026/27")
        for cid in cal.get("corsi") or []:
            if ids and cid not in ids:
                errs.append(f"{where}: corso sconosciuto {cid}")
            if cid in seen:
                errs.append(f"corso {cid} in due calendari")
            seen[cid] = where
    scoperti = set(d.get("corsi_scoperti") or [])
    for cid in scoperti:
        if ids and cid not in ids:
            errs.append(f"corso scoperto sconosciuto {cid}")
        if cid in seen:
            errs.append(f"corso {cid} sia coperto sia scoperto")
    mancano = ids - set(seen) - scoperti
    if mancano:
        errs.append(f"{len(mancano)} corsi né coperti né scoperti (es. {sorted(mancano)[:3]})")
    riepilogo = f"{len(d.get('calendari') or [])} cal · {n_sess} sess · {len(set(seen) & ids if ids else seen)}/{len(ids)} corsi"
    return errs, riepilogo


def main(argv: list[str]) -> int:
    uids = argv or sorted(p.stem for p in (DB / "corsi").glob("*.json"))
    bad = 0
    for uid in uids:
        errs, riep = verifica(uid)
        flag = "OK " if not errs else "ERR"
        print(f"{flag} {uid:22} {riep}")
        for e in errs[:8]:
            print(f"      - {e}")
        bad += bool(errs)
    print(f"\n{len(uids) - bad}/{len(uids)} atenei senza errori")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
