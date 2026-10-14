"""Tabella dei libri per insegnamento (docs/libri/libri_obbligatori_per_insegnamento.csv).

    python tools/db_builder/libri_per_insegnamento.py

Una riga per libro di ogni insegnamento, con un solo dato per colonna e la
colonna «Obbligatorio» (Sì / No):
- se il programma indica quali libri sono obbligatori o consigliati, si
  elencano quelli (obbligatorio = Sì, consigliato = No);
- se un insegnamento indica solo libri senza questa informazione, si elencano
  tutti come consigliati (No), come fa l'app.

Autori, titolo, editore, anno, edizione e ISBN vengono dai campi del database;
quando nel database c'è solo la citazione intera, dai dati separati a mano in
privato/libri/citazioni/dati_*.json (solo ciò che è scritto nella citazione).
Le voci che non sono libri (slide, appunti, materiale del docente) non entrano
nella tabella. File CSV UTF-8 con BOM e «;», si apre direttamente con Excel.
"""
from __future__ import annotations

import csv
import gzip
import io
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from libri_obbligatori import TIPI, ORDINE_TIPI, atenei, classe_insegnamento, norm

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "database"
CIT = ROOT / "privato" / "libri" / "citazioni"
OUT = ROOT / "docs" / "libri" / "libri_obbligatori_per_insegnamento.csv"

COLONNE = [
    "Insegnamento (classificazione)", "Insegnamento (nome nel piano)", "Obbligatorio",
    "Autori", "Titolo", "Editore", "Anno di pubblicazione", "Edizione", "ISBN",
    "Corso di laurea", "Tipo corso", "Classe", "Ateneo", "Tipo di università",
    "Regione", "Anno di corso",
]


def dati_separati() -> dict:
    d = {}
    # in ordine numerico: i file successivi (riletture) correggono i precedenti
    files = [f for f in CIT.glob("dati_*.json") if re.fullmatch(r"dati_\d+\.json", f.name)]
    for f in sorted(files, key=lambda f: int(f.stem.split("_")[1])):
        d.update(json.loads(f.read_text(encoding="utf-8")))
    return d


def _isbn(s) -> str:
    return re.sub(r"[^0-9Xx]", "", str(s or ""))


_ANNO = re.compile(r"[\s,;]*\(?((?:1[5-9]|20)\d\d)[a-z]?\)?[\s,;.]*$")


_CITTA = {
    "Milano", "Torino", "Roma", "Bologna", "Napoli", "Firenze", "Padova", "Bari",
    "Venezia", "Genova", "Pisa", "Palermo", "Catania", "Verona", "Trento", "Brescia",
    "Bergamo", "Parma", "Modena", "Perugia", "Cagliari", "Messina", "Salerno",
    "Rimini", "Lecce", "Trieste", "Udine", "Siena", "Macerata", "Urbino", "Pavia",
    "London", "Londra", "New York", "Oxford", "Cambridge", "Mass", "MA", "Boston",
    "Berlin", "Berlino", "Paris", "Parigi", "Madrid", "Barcelona", "Amsterdam",
    "Heidelberg", "Hoboken", "Chicago", "Princeton", "Upper Saddle River",
    "Thousand Oaks", "Los Angeles", "San Francisco", "Philadelphia", "Washington",
}


def _pulisci(x: dict) -> dict:
    """Un dato per campo anche quando i campi vengono dal database: anno tolto
    da autori e titolo, città tolta dall'editore («Milano: Hoepli»), spazi e
    punteggiatura finale."""
    def pul(v, punto=True):
        if not v:
            return v
        v = re.sub(r"\s+", " ", str(v)).strip(" ,;:")
        return v.rstrip(".") if punto else v
    aut = pul(x.get("autori"), punto=False)  # il punto delle iniziali resta
    if aut:
        m = _ANNO.search(aut)
        if m:
            x["anno"] = x.get("anno") or int(m.group(1))
            aut = pul(aut[:m.start()], punto=False)
    x["autori"] = aut
    tit = pul(x.get("titolo"))
    if tit:
        m = re.search(r"\s*\((?:1[5-9]|20)\d\d\)\s*$", tit)
        if m:
            tit = pul(tit[:m.start()])
    x["titolo"] = tit
    ed = pul(x.get("editore"))
    if ed and ":" in ed:
        prima, dopo = ed.split(":", 1)
        if len(prima) <= 25 and dopo.strip():
            ed = pul(dopo)
    # città prima dell'editore separata da virgola («Torino, Pearson»)
    while ed and "," in ed:
        prima, dopo = ed.split(",", 1)
        if prima.strip().rstrip(".") not in _CITTA or not dopo.strip():
            break
        ed = pul(dopo)
    if ed:
        m = _ANNO.search(ed)
        if m:
            x["anno"] = x.get("anno") or int(m.group(1))
            ed = pul(ed[:m.start()])
    x["editore"] = ed
    x["edizione"] = pul(x.get("edizione"))
    return x


def campi_libro(b: dict, sep: dict) -> list[dict]:
    """Uno o più libri (una citazione può contenerne più d'uno), ognuno con i
    suoi campi; lista vuota se la voce non è un libro."""
    cit = b.get("citazione") or b.get("titolo") or ""
    separato = b.get("autori") and b.get("titolo") and b.get("titolo") != b.get("citazione")
    # i dati separati a mano valgono più di quelli separati in automatico
    if separato and cit not in sep:
        return [_pulisci({
            "autori": b.get("autori"), "titolo": b.get("titolo"), "editore": b.get("editore"),
            "anno": b.get("anno"), "edizione": b.get("edizione"), "isbn": _isbn(b.get("isbn")),
        })]
    x = sep.get(cit)
    if x is None:
        return [{"mancante": cit}]
    if not x.get("libro", True):
        return []
    out = [_pulisci({k: x.get(k) for k in ("autori", "titolo", "editore", "anno", "edizione")}
                    | {"isbn": _isbn(x.get("isbn"))})]
    for altro in x.get("altri") or []:
        y = sep.get(altro) if isinstance(altro, str) else altro
        if isinstance(y, dict) and y.get("libro", True) and y.get("titolo"):
            out.append(_pulisci({k: y.get(k) for k in ("autori", "titolo", "editore", "anno", "edizione")}
                                | {"isbn": _isbn(y.get("isbn"))}))
    return out


def regione(u: dict, corso: dict) -> str:
    sede = norm(corso.get("sede"))
    for s in u.get("sedi") or []:
        if sede and sede in norm(s.get("citta")):
            return s["regione"]
    reg = u.get("regioni") or []
    return reg[0] if reg else ""


def righe() -> tuple[list[list], Counter]:
    us = atenei()
    sep = dati_separati()
    stat = Counter()
    rows = []
    for fn in sorted((DB / "corsi").glob("*.json")):
        d = json.loads(fn.read_text(encoding="utf-8"))
        u = us.get(d.get("universita_id")) or {}
        for c in d.get("corsi") or []:
            if c.get("piano_da"):
                continue  # replica di sede: stessi libri del corso principale
            for i in c.get("insegnamenti") or []:
                libri = i.get("libri") or []
                noti = [b for b in libri if b.get("tipo") in ("obbligatorio", "consigliato")]
                scelti = noti or libri
                for b in scelti:
                    obbl = "Sì" if b.get("tipo") == "obbligatorio" else "No"
                    for x in campi_libro(b, sep):
                        if "mancante" in x:
                            stat["citazioni non ancora separate"] += 1
                            continue
                        if not x.get("titolo"):
                            stat["senza titolo"] += 1
                            continue
                        stat["righe"] += 1
                        rows.append([
                            "",  # classificazione, sotto
                            i.get("nome") or "", obbl,
                            x.get("autori") or "", x.get("titolo") or "", x.get("editore") or "",
                            x.get("anno") if x.get("anno") is not None else "",
                            x.get("edizione") or "", x.get("isbn") or "",
                            c.get("nome") or "", c.get("tipo") or "", c.get("classe") or "",
                            u.get("nome") or d.get("universita_id"),
                            TIPI.get(u.get("tipo"), u.get("tipo") or ""),
                            regione(u, c),
                            i.get("anno") if i.get("anno") is not None else "",
                        ])
    # classificazione: la grafia più frequente per ogni insegnamento
    grafie: dict[str, Counter] = defaultdict(Counter)
    for r in rows:
        cl = classe_insegnamento(r[1])
        grafie[norm(cl)][cl] += 1
    for r in rows:
        r[0] = grafie[norm(classe_insegnamento(r[1]))].most_common(1)[0][0]
    # niente righe doppie
    visti, uniche = set(), []
    for r in rows:
        k = tuple(str(x) for x in r)
        if k not in visti:
            visti.add(k)
            uniche.append(r)
    ordine_tipo = {TIPI[t]: n for n, t in enumerate(ORDINE_TIPI)}
    uniche.sort(key=lambda r: (norm(r[0]), norm(r[1]), r[2] != "Sì", norm(r[4]),
                               ordine_tipo.get(r[13], 9), norm(r[12]), norm(r[9])))
    return uniche, stat


def main() -> int:
    rows, stat = righe()
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";", lineterminator="\n")
    w.writerow(COLONNE)
    for r in rows:
        w.writerow(["" if x is None else x for x in r])
    OUT.write_text(buf.getvalue(), encoding="utf-8-sig")
    # nel repository va la copia compressa: il CSV supera il limite di 100 MB di GitHub
    with gzip.GzipFile(OUT.with_suffix(".csv.gz"), "wb", mtime=0, compresslevel=9) as gz:
        gz.write(OUT.read_bytes())
    print(f"scritto {OUT} {len(rows)} righe, {OUT.stat().st_size // 1_000_000} MB", dict(stat))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
