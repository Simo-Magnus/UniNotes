"""Controllo dei CFU per anno: trova i piani di studio incompleti.

Ogni anno di un corso di laurea vale 60 CFU (DM 270/2004). Per ogni corso, anno e
percorso (si prende il percorso con più CFU in quell'anno) si sommano:

- obbligatori: insegnamenti con `obbligatorio` diverso da false (prova finale compresa);
- a scelta: insegnamenti con `obbligatorio: false` (tabelle a scelta, crediti liberi).

Un anno è segnalato se gli obbligatori sono sotto 40 CFU o se obbligatori più scelte
non arrivano a 60 (minimo annuale) e nemmeno il corso intero arriva a 60 CFU per anno
(un anno da 58 e uno da 62 sono solo una diversa distribuzione). La causa probabile:

- `vuoto`: nessun insegnamento in quell'anno;
- `senza_cfu`: più di un terzo degli insegnamenti dell'anno non ha i CFU;
- `totale_basso`: anche con tutte le scelte l'anno resta sotto 60 CFU (mancano insegnamenti);
- `obbligatori_bassi`: con le scelte si arriva a 60 ma gli obbligatori sono sotto 40
  (piano con molte scelte: va verificato sulla fonte, può essere corretto).

Anni verificati sulla fonte e corretti così (per esempio un secondo anno di laurea
magistrale con pochi obbligatori e molte scelte): `tools/db_builder/cfu_verificati.json`,
`{"<id corso>": {"<anno>": {"fonte": "<url ufficiale>", "nota": "…"}}}`; non si segnalano.

Uso:

    python tools/db_builder/controllo_cfu.py [--solo id1,id2] [--json percorso] [--dettaglio]

Senza `--json` stampa il riepilogo per ateneo; con `--json` scrive l'elenco completo.
"""
from __future__ import annotations

import json
import pathlib
import sys
from collections import Counter, defaultdict

import pulizia

ROOT = pathlib.Path(__file__).resolve().parents[2]
DB = ROOT / "database"
MIN_OBBLIGATORI = 40
MIN_ANNO = 60


def _cfu(i: dict) -> float:
    v = i.get("cfu")
    return float(v) if isinstance(v, (int, float)) else 0.0


def anni_corso(c: dict) -> list[dict]:
    ins = [i for i in c.get("insegnamenti") or [] if isinstance(i, dict)]
    if not ins:
        return []
    durata = c.get("durata_anni") or 3
    percorsi = sorted({p for i in ins for p in pulizia.percorsi(i.get("curriculum"))}) or [None]
    out = []
    righe = []
    for a in range(1, durata + 1):
        dell_anno = [i for i in ins if i.get("anno") == a]
        migliore = None
        for p in percorsi:
            sel = [i for i in dell_anno
                   if p is None or not i.get("curriculum") or p in pulizia.percorsi(i.get("curriculum"))]
            obb = sum(_cfu(i) for i in sel if i.get("obbligatorio") is not False)
            sce = sum(_cfu(i) for i in sel if i.get("obbligatorio") is False)
            r = (obb, sce, p, sel)
            if migliore is None or (obb, obb + sce) > (migliore[0], migliore[0] + migliore[1]):
                migliore = r
        obb, sce, p, sel = migliore
        righe.append((a, obb, sce, p, sel))
    totale_corso = sum(r[1] + r[2] for r in righe)
    for a, obb, sce, p, sel in righe:
        senza = sum(1 for i in sel if not isinstance(i.get("cfu"), (int, float)))
        if not sel:
            causa = "vuoto"
        elif senza * 3 > len(sel):
            causa = "senza_cfu"
        elif obb + sce < MIN_ANNO and totale_corso < MIN_ANNO * durata:
            causa = "totale_basso"
        elif obb < MIN_OBBLIGATORI:
            causa = "obbligatori_bassi"
        else:
            causa = None
        out.append({"corso": c.get("id"), "nome": c.get("nome"), "anno": a, "percorso": p,
                    "obbligatori": obb, "a_scelta": sce, "insegnamenti": len(sel),
                    "senza_cfu": senza, "causa": causa, "fonte": c.get("fonte")})
    return out


VERIFICATI = pathlib.Path(__file__).resolve().parent / "cfu_verificati.json"


def _verificati() -> dict:
    try:
        return json.loads(VERIFICATI.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def controlla(uid: str, verificati: dict | None = None) -> list[dict]:
    p = DB / "corsi" / f"{uid}.json"
    if not p.exists():
        return []
    verificati = _verificati() if verificati is None else verificati
    doc = json.loads(p.read_text(encoding="utf-8"))
    righe = []
    for c in doc.get("corsi") or []:
        ok = verificati.get(c.get("id")) or {}
        for r in anni_corso(c):
            if r["causa"] and str(r["anno"]) not in ok:
                r["ateneo"] = uid
                righe.append(r)
    return righe


def main(argv: list[str]) -> int:
    solo = set(argv[argv.index("--solo") + 1].split(",")) if "--solo" in argv else None
    uids = sorted(p.stem for p in (DB / "corsi").glob("*.json"))
    tutte = []
    verificati = _verificati()
    for uid in uids:
        if solo and uid not in solo:
            continue
        tutte.extend(controlla(uid, verificati))
    if "--json" in argv:
        out = pathlib.Path(argv[argv.index("--json") + 1])
        out.write_text(json.dumps(tutte, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    per = defaultdict(Counter)
    for r in tutte:
        per[r["ateneo"]][r["causa"]] += 1
    tot = Counter(r["causa"] for r in tutte)
    print(f"anni segnalati: {len(tutte)} ({', '.join(f'{k} {v}' for k, v in tot.most_common())})")
    for uid, cnt in sorted(per.items(), key=lambda x: -sum(x[1].values())):
        print(f"{uid}: {sum(cnt.values())} ({', '.join(f'{k} {v}' for k, v in cnt.most_common())})")
        if "--dettaglio" in argv:
            for r in tutte:
                if r["ateneo"] == uid:
                    print(f"   {r['corso']} anno {r['anno']}: obbligatori {r['obbligatori']:g}, "
                          f"scelte {r['a_scelta']:g}, senza CFU {r['senza_cfu']}/{r['insegnamenti']} → {r['causa']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
