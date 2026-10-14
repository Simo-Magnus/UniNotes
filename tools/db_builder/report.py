"""Riepilogo del database in Markdown (per il sommario del workflow)."""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
meta = json.loads((ROOT / "database/meta.json").read_text(encoding="utf-8"))
unis = {u["id"]: u for u in json.loads((ROOT / "database/universita.json").read_text(encoding="utf-8"))["universita"]}
rows = sorted(meta["atenei"].items(), key=lambda x: -x[1]["corsi"])
tot = {k: sum(v[k] for _, v in rows) for k in ("corsi", "insegnamenti", "libri", "esami")}
print(f"## Database {meta['anno_accademico']} — versione {meta['versione']}\n")
print(f"**{len(unis)} atenei · {tot['corsi']} corsi di studio · {tot['insegnamenti']} insegnamenti · "
      f"{tot['libri']} libri · {tot['esami']} date d'esame**\n")
print("| Ateneo | Corsi | Insegnamenti | Libri | Esami |\n|---|---:|---:|---:|---:|")
for uid, m in rows:
    print(f"| {unis.get(uid, {}).get('nome', uid)} | {m['corsi']} | {m['insegnamenti']} | {m['libri']} | {m['esami']} |")
