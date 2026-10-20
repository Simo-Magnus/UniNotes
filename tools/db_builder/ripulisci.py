"""Applica le pulizie strutturali ai file del database già costruiti.

    python tools/db_builder/ripulisci.py [ateneo ...]

Senza rifare la raccolta né la build: per ogni `database/corsi/<ateneo>.json`
esegue `pulizia.rivedi_varianti` (le varianti in inglese già presenti si
ricontrollano: quelle che non sono la traduzione dell'insegnamento tornano
insegnamenti a sé), `pulizia.varianti_lingua`, `pulizia.varianti_lingua_gemelli` e
`pulizia.varianti_lingua_scelta` (versioni in inglese → varianti della versione italiana),
`pulizia.unisci_omonimi`
(stesso insegnamento ripetuto per canale/sede/curriculum → uno solo),
`pulizia.segna_a_scelta` (segnaposto «a scelta» → a scelta) e
`pulizia.scomponi_citazioni` (libri con tutta la citazione nel titolo → autori,
titolo, editore, anno), poi aggiorna conteggi e sha256 in `database/meta.json`.
Le stesse pulizie sono già nella build (build_db.py).

Il percorso originale delle versioni inglesi da rimettere come insegnamenti si
prende dal dato dell'adapter (`database/contrib/auto/<ateneo>.json`) se c'è.
L'elenco delle coppie italiano/inglese tenute, nuove e tolte va in
`tools/db_builder/report_varianti.md` (solo se qualcosa è cambiato).
"""
from __future__ import annotations

import hashlib
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

import pulizia

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "database"
REPORT = Path(__file__).resolve().parent / "report_varianti.md"


def originali(uid: str) -> dict:
    """{id corso: {codice: insegnamento}} dal dato dell'adapter, se c'è."""
    f = DB / "contrib" / "auto" / f"{uid}.json"
    if not f.exists():
        return {}
    try:
        raw = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for c in raw.get("corsi") or []:
        if c.get("id"):
            d = out.setdefault(c["id"], {})
            for i in c.get("insegnamenti") or []:
                if i.get("codice"):
                    d.setdefault(i["codice"], i)
    return out


def _cella(s) -> str:
    return str(s if s is not None else "").replace("|", "/").replace("\n", " ")


def scrivi_report(esiti: list[tuple], tenute: list[tuple]) -> None:
    per = defaultdict(Counter)
    for tipo, uid, *_, nota in esiti + tenute:
        per[uid][tipo] += 1
        per[uid]["ricreata"] += "ricreato come insegnamento" in nota
    righe = [
        "# Varianti italiano/inglese: revisione",
        "",
        f"Generato da `ripulisci.py` il {datetime.now(timezone.utc).strftime('%Y-%m-%d')}. "
        "Regola (`pulizia._abbinamento`): stesso corso, anno, CFU e SSD; nome della versione inglese in "
        "inglese e della versione italiana in italiano; i due nomi devono essere la traduzione l'uno "
        "dell'altro (parole affini, dizionario `_TRADUZIONI`, titoli in uso `_FRASI`; numeri e lettere di "
        "modulo uguali) con somiglianza almeno 0,60 (0,75 per gli insegnamenti a scelta e per le coppie "
        "nello stesso piano, «gemelli»; −0,10 con docenti in comune; 0,90 se il semestre è diverso, 0,75 "
        "con docenti in comune); abbinamenti uno a uno, i casi a pari punteggio restano separati.",
        "",
        "- **tenuta**: variante già presente che rispetta la regola;",
        "- **annullata**: variante tolta dall'insegnamento; se il corso non aveva già quell'insegnamento "
        "inglese, è tornato un insegnamento a sé (campi della variante; anno, CFU, SSD dal genitore; "
        "percorso e obbligatorietà dal dato originale dell'adapter quando c'è);",
        "- **nuova**: variante creata ora (percorso in lingua inglese o stesso piano).",
        "",
        "Le annullate contano ogni coppia insegnamento/variante tolta (una versione inglese poteva essere "
        "variante di più insegnamenti); «ricreate» sono le versioni inglesi tornate insegnamenti a sé.",
        "",
        "| Ateneo | Tenute | Annullate | Ricreate come insegnamenti | Nuove |",
        "|---|---:|---:|---:|---:|",
    ]
    for uid in sorted(per):
        c = per[uid]
        righe.append(f"| {uid} | {c['tenuta']} | {c['annullata']} | {c['ricreata']} | {c['nuova']} |")
    tot = Counter()
    for c in per.values():
        tot.update(c)
    righe.append(f"| **totale** | {tot['tenuta']} | {tot['annullata']} | {tot['ricreata']} | {tot['nuova']} |")
    for tipo, titolo in (("annullata", "Annullate"), ("nuova", "Nuove"), ("tenuta", "Tenute")):
        lst = [e for e in esiti + tenute if e[0] == tipo]
        if not lst:
            continue
        righe += ["", f"## {titolo} ({len(lst)})", "",
                  "| Ateneo | Corso | Insegnamento italiano | Versione inglese | Somiglianza | Note |",
                  "|---|---|---|---|---:|---|"]
        for _, uid, cid, it_nome, it_cod, en_nome, en_cod, s, nota in sorted(lst, key=lambda e: (e[1], e[2], e[3])):
            righe.append(f"| {uid} | {_cella(cid)} | {_cella(it_nome)} ({_cella(it_cod)}) | "
                         f"{_cella(en_nome)} ({_cella(en_cod)}) | {s:.2f} | {_cella(nota)} |")
    REPORT.write_text("\n".join(righe) + "\n", encoding="utf-8")


def main() -> int:
    meta_path = DB / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    files = sorted((DB / "corsi").glob("*.json"))
    solo = set(sys.argv[1:])
    tot_v = tot_u = tot_s = tot_r = tot_l = 0
    esiti_tutti: list[tuple] = []
    tenute_tutte: list[tuple] = []
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        uid = d.get("universita_id") or f.stem
        if solo and uid not in solo:
            continue
        corsi = d.get("corsi") or []
        esiti: list = []
        r = pulizia.rivedi_varianti(corsi, originali(uid), esiti)
        v = pulizia.varianti_lingua(corsi, esiti)
        v += pulizia.varianti_lingua_gemelli(corsi, esiti)
        v += pulizia.varianti_lingua_scelta(corsi, esiti)
        u = pulizia.unisci_omonimi(corsi)
        sc = pulizia.segna_a_scelta(corsi)
        lb = pulizia.scomponi_citazioni(corsi)
        for tipo, cid, it, var, s, nota in esiti:
            riga = (tipo, uid, cid, it.get("nome"), it.get("codice"), var.get("nome"), var.get("codice"), s, nota)
            if tipo != "tenuta":
                esiti_tutti.append(riga)
        # coppie presenti alla fine (dopo le unioni degli omonimi): tenute + nuove
        nuove = {(e[2], e[6]) for e in esiti_tutti if e[0] == "nuova" and e[1] == uid}
        for c in corsi:
            for i in c.get("insegnamenti") or []:
                for var in i.get("varianti") or []:
                    if var.get("lingua") == "en" and (c.get("id"), var.get("codice")) not in nuove:
                        s = pulizia._somiglianza_traduzione(i.get("nome"), var.get("nome"))
                        tenute_tutte.append(("tenuta", uid, c.get("id"), i.get("nome"), i.get("codice"),
                                             var.get("nome"), var.get("codice"), s, ""))
        if not (v or u or sc or r or lb):
            continue
        tot_v += v
        tot_u += u
        tot_r += r
        tot_l += lb
        f.write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        ins = [i for c in corsi for i in c.get("insegnamenti") or []]
        m = meta.setdefault("atenei", {}).setdefault(uid, {})
        m.update({
            "corsi": len(corsi),
            "insegnamenti": len(ins),
            "libri": sum(len(i.get("libri") or []) for i in ins),
            "esami": sum(len(i.get("esami") or []) for i in ins),
            "file": f"corsi/{uid}.json",
            "sha256": hashlib.sha256(f.read_bytes()).hexdigest(),
        })
        tot_s += sc
        print(f"{uid}: {r} varianti annullate, {v} varianti in inglese nuove, {u} insegnamenti uniti, "
              f"{sc} segnati a scelta, {lb} libri scomposti")
    if tot_v or tot_u or tot_s or tot_r or tot_l:
        now = datetime.now(timezone.utc)
        meta["versione"] = now.strftime("%Y.%m.%d")
        meta["generato_il"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if (tot_v or tot_r) and not solo:
        scrivi_report(esiti_tutti, tenute_tutte)
    print(f"totale: {tot_r} varianti annullate, {tot_v} nuove, {tot_u} uniti, {tot_s} a scelta, {tot_l} libri scomposti")
    return 0


if __name__ == "__main__":
    sys.exit(main())
