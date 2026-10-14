"""Tabelle dei libri obbligatori del database (docs/libri/).

    python tools/db_builder/libri_obbligatori.py            # genera le tabelle
    python tools/db_builder/libri_obbligatori.py --verifica # controlla le tabelle

Tabelle (CSV UTF-8 con BOM e «;», si aprono direttamente con Excel):

1. libri_obbligatori_per_corso.csv — tutti i libri con tipo «obbligatorio»,
   ordinati per tipo di università → regione → corso di laurea → anno, con
   titolo, autori, anno, edizione e (se verificati) titolo, anno ed edizione
   della versione originale.
2. libri_obbligatori_per_insegnamento.csv — gli stessi libri raggruppati per
   insegnamento (classificazione dei nomi: «Analisi matematica 1», «Fisica»…)
   con il corso di laurea e l'ateneo per cui sono indicati.
3. versioni_libri.csv — un libro per riga con versione italiana, inglese e
   originale (da versioni_libri.json, compilato da versioni_libri.py; vuoto =
   non verificato).

La verifica rigenera le righe dal database e le confronta con i file: ogni
libro obbligatorio deve esserci una volta sola e con gli stessi dati; segnala
inoltre ISBN con cifra di controllo errata, anni impossibili e titoli vuoti
(colonna «Controlli» dei file). Esce con codice 1 se trova differenze.
"""
from __future__ import annotations

import csv
import io
import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DB = ROOT / "database"
OUT = ROOT / "docs" / "libri"
VERSIONI = OUT / "versioni_libri.json"

TIPI = {
    "statale": "Statale",
    "non_statale": "Non statale",
    "ordinamento_speciale": "Ordinamento speciale",
    "telematica": "Telematica",
}
ORDINE_TIPI = list(TIPI)
ANNO_MAX = 2027

COL_CORSO = [
    "Tipo di università", "Regione", "Ateneo", "Corso di laurea", "Tipo corso",
    "Classe", "Anno di corso", "Insegnamento", "Titolo", "Autori",
    "Anno di pubblicazione", "Edizione", "Editore", "ISBN", "Lingua",
    "Titolo originale", "Anno edizione originale", "Edizione originale",
    "Citazione nel programma", "Dati separati", "Controlli", "Fonte",
    "ID insegnamento", "Chiave libro",
]
COL_INS = [
    "Insegnamento (classificazione)", "Titolo", "Autori", "Anno di pubblicazione",
    "Corso di laurea", "Ateneo", "Tipo di università", "Regione",
    "Anno di corso", "Insegnamento (nome nel piano)", "Chiave libro",
]
COL_VER = [
    "Chiave libro", "Titolo", "Autori", "Lingua originale",
    "Versione italiana", "Versione inglese", "Versione originale",
    "Fonte", "Stato",
]


# ---------------------------------------------------------------- utilità

def norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def chiave_libro(b: dict) -> str:
    """Stesso libro = stesso ISBN, altrimenti stessi titolo e autori."""
    isbn = re.sub(r"[^0-9Xx]", "", b.get("isbn") or "").upper()
    if len(isbn) in (10, 13):
        return "isbn:" + isbn
    return "ta:" + norm(b.get("titolo"))[:120] + "|" + norm(b.get("autori"))[:60]


def isbn_valido(isbn: str) -> bool:
    d = re.sub(r"[^0-9Xx]", "", isbn).upper()
    if len(d) == 13 and d.isdigit():
        s = sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(d[:12]))
        return (10 - s % 10) % 10 == int(d[12])
    if len(d) == 10 and d[:9].isdigit():
        s = sum(int(c) * (10 - i) for i, c in enumerate(d[:9]))
        chk = (11 - s % 11) % 11
        return d[9] == ("X" if chk == 10 else str(chk))
    return False


ROMANI = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6"}


GRUPPO = re.compile(
    r"\b(a scelta|affini e integrative|attivit[aà]'? affini|quadro \d|indicare \d|"
    r"paniere|curriculum comune|insegnamenti suggeriti|scelta libera|"
    r"caratterizzanti)",
    re.I,
)


def classe_insegnamento(nome: str) -> str:
    """«ANALISI MATEMATICA I (modulo A)» → «Analisi matematica 1».

    I nomi che nel piano sono gruppi di insegnamenti a scelta («Attività
    affini e integrative», «Quadro 1 - un esame da 12 CFU…») finiscono nella
    classe «Gruppo di insegnamenti a scelta».
    """
    if GRUPPO.search(nome or ""):
        return "Gruppo di insegnamenti a scelta"
    s = re.sub(r"\binsegnamento a numero chiuso\b", " ", nome or "", flags=re.I)
    s = re.sub(r"\s+[-–—]\s+[ivx]+\s+(anno|annualit[aà]).*$", " ", s, flags=re.I)
    s = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", s)
    s = re.split(r"\s+[-–—:]\s+(?:mod(?:ulo)?\.?\s|parte\s|module\s)", s, flags=re.I)[0]
    s = re.sub(r"\b(mod(?:ulo)?\.?|module|parte|part|canale|corso)\s+[a-z0-9]{1,3}\b", " ", s, flags=re.I)
    s = re.sub(r"\s+", " ", s).strip(" -–—:.,;")
    parole = s.split(" ")
    if parole and parole[-1].lower() in ROMANI:
        parole[-1] = ROMANI[parole[-1].lower()]
    s = " ".join(parole)
    if s.isupper() or s.islower():
        s = s.lower()
    return (s[:1].upper() + s[1:]) if s else (nome or "")


def controlli(b: dict) -> str:
    out = []
    if not (b.get("titolo") or "").strip():
        out.append("titolo vuoto")
    isbn = b.get("isbn")
    if isbn and not isbn_valido(isbn):
        out.append("ISBN con cifra di controllo errata")
    anno = b.get("anno")
    if anno is not None and not (1450 <= int(anno) <= ANNO_MAX):
        out.append("anno di pubblicazione impossibile")
    return "; ".join(out)


# ---------------------------------------------------------------- dati

def atenei() -> dict:
    d = json.loads((DB / "universita.json").read_text(encoding="utf-8"))
    return {u["id"]: u for u in d["universita"]}


def regione(u: dict, corso: dict) -> str:
    sede = norm(corso.get("sede"))
    if sede:
        for s in u.get("sedi") or []:
            if sede and sede in norm(s.get("citta")):
                return s["regione"]
    return " / ".join(u.get("regioni") or []) or "—"


def versioni() -> dict:
    if VERSIONI.exists():
        return json.loads(VERSIONI.read_text(encoding="utf-8"))
    return {}


def libri_obbligatori():
    """Una voce per ogni libro obbligatorio di ogni insegnamento."""
    us = atenei()
    for fn in sorted((DB / "corsi").glob("*.json")):
        d = json.loads(fn.read_text(encoding="utf-8"))
        u = us.get(d.get("universita_id")) or {}
        for c in d.get("corsi") or []:
            if c.get("piano_da"):
                continue  # replica di sede: stessi libri del corso principale
            for i in c.get("insegnamenti") or []:
                for b in i.get("libri") or []:
                    if b.get("tipo") == "obbligatorio":
                        yield u, c, i, b


def righe_corso(ver: dict) -> list[list]:
    rows = []
    for u, c, i, b in libri_obbligatori():
        k = chiave_libro(b)
        orig = (ver.get(k) or {}).get("originale") or {}
        separati = b.get("titolo") != b.get("citazione") or not b.get("citazione")
        anno = b.get("anno")
        nota_anno = ""
        if anno is None and not separati:
            # anno ricavato dalla citazione solo se ce n'è uno e uno solo
            anni = set(re.findall(r"(?<!\d)(1[5-9]\d\d|20[0-2]\d)(?!\d)", b.get("citazione") or ""))
            if len(anni) == 1:
                anno = int(anni.pop())
                nota_anno = "; anno dalla citazione"
        rows.append([
            TIPI.get(u.get("tipo"), u.get("tipo") or "—"),
            regione(u, c),
            u.get("nome") or c["id"].split("-")[0],
            c.get("nome") or "",
            c.get("tipo") or "",
            c.get("classe") or "",
            i.get("anno") if i.get("anno") is not None else "",
            i.get("nome") or "",
            b.get("titolo") or "",
            b.get("autori") or "",
            anno if anno is not None else "",
            b.get("edizione") or "",
            b.get("editore") or "",
            b.get("isbn") or "",
            b.get("lingua") or "",
            orig.get("titolo") or "",
            orig.get("anno") or "",
            orig.get("edizione") or "",
            b.get("citazione") or "",
            ("sì" if separati else "no (titolo = citazione)") + nota_anno,
            controlli(b),
            i.get("url") or c.get("url") or "",
            i.get("id") or "",
            k,
        ])

    def ordine(r):
        tipo = next((n for n, t in enumerate(ORDINE_TIPI) if TIPI[t] == r[0]), 9)
        anno = r[6] if isinstance(r[6], int) else 99
        return (tipo, r[1], r[2], r[3], anno, r[7], r[8])

    rows.sort(key=ordine)
    return rows


def righe_insegnamento(corso_rows: list[list]) -> list[list]:
    # nome mostrato per ogni classe: la grafia più frequente
    grafie: dict[str, Counter] = defaultdict(Counter)
    for r in corso_rows:
        cl = classe_insegnamento(r[7])
        grafie[norm(cl)][cl] += 1
    rows = []
    for r in corso_rows:
        cl = grafie[norm(classe_insegnamento(r[7]))].most_common(1)[0][0]
        rows.append([cl, r[8], r[9], r[10], r[3], r[2], r[0], r[1], r[6], r[7], r[23]])
    rows.sort(key=lambda x: (norm(x[0]), norm(x[1]), x[5], x[4]))
    return rows


def righe_versioni(corso_rows: list[list], ver: dict) -> list[list]:
    visti = {}
    for r in corso_rows:
        visti.setdefault(r[23], r)

    def ed(v: dict | None) -> str:
        if not v:
            return ""
        parti = [v.get("titolo"), v.get("editore"), v.get("anno"),
                 ("ed. " + str(v["edizione"])) if v.get("edizione") else None,
                 ("ISBN " + v["isbn"]) if v.get("isbn") else None]
        return " · ".join(str(p) for p in parti if p)

    rows = []
    for k, r in visti.items():
        v = ver.get(k) or {}
        rows.append([
            k, r[8], r[9], v.get("lingua_originale") or "",
            ed(v.get("italiana")), ed(v.get("inglese")), ed(v.get("originale")),
            v.get("fonte") or "", v.get("stato") or "non verificato",
        ])
    rows.sort(key=lambda x: (norm(x[1]), norm(x[2])))
    return rows


# ---------------------------------------------------------------- file

def csv_text(header: list[str], rows: list[list]) -> str:
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";", lineterminator="\n")
    w.writerow(header)
    for r in rows:
        w.writerow(["" if x is None else x for x in r])
    return buf.getvalue()


FILES = {
    "libri_obbligatori_per_corso.csv": COL_CORSO,
    "libri_obbligatori_per_insegnamento.csv": COL_INS,
    "versioni_libri.csv": COL_VER,
}


def genera() -> dict[str, str]:
    ver = versioni()
    corso = righe_corso(ver)
    return {
        "libri_obbligatori_per_corso.csv": csv_text(COL_CORSO, corso),
        "libri_obbligatori_per_insegnamento.csv": csv_text(COL_INS, righe_insegnamento(corso)),
        "versioni_libri.csv": csv_text(COL_VER, righe_versioni(corso, ver)),
    }


def leggi(name: str) -> list[list[str]]:
    text = (OUT / name).read_text(encoding="utf-8-sig")
    return list(csv.reader(io.StringIO(text), delimiter=";"))


def verifica() -> int:
    """Confronta i file con il database. Restituisce il numero di errori."""
    errori = 0
    attesi = genera()
    for name, header in FILES.items():
        if not (OUT / name).exists():
            print(f"MANCA {name}")
            errori += 1
            continue
        got = leggi(name)
        exp = list(csv.reader(io.StringIO(attesi[name]), delimiter=";"))
        if got[:1] != exp[:1]:
            print(f"{name}: intestazione diversa")
            errori += 1
        g, e = Counter(map(tuple, got[1:])), Counter(map(tuple, exp[1:]))
        mancanti, extra = e - g, g - e
        for r in list(mancanti)[:5]:
            print(f"{name}: MANCA {r[:10]}")
        for r in list(extra)[:5]:
            print(f"{name}: IN PIÙ {r[:10]}")
        errori += sum(mancanti.values()) + sum(extra.values())
    # ogni libro obbligatorio del database compare esattamente una volta
    n_db = sum(1 for _ in libri_obbligatori())
    rows = leggi("libri_obbligatori_per_corso.csv")[1:]
    if len(rows) != n_db:
        print(f"righe {len(rows)} ≠ libri obbligatori nel database {n_db}")
        errori += 1
    chiavi = Counter((r[22], r[23], r[18]) for r in rows)
    doppie = [k for k, n in chiavi.items() if n > 1]
    for k in doppie[:5]:
        print(f"riga ripetuta {k}")
    # anomalie dei dati (segnalate nella colonna «Controlli», non errori del file)
    anom = Counter(x for r in rows for x in r[20].split("; ") if x)
    print(f"libri obbligatori: {n_db} voci, {len({r[23] for r in rows})} libri distinti")
    for a, n in anom.most_common():
        print(f"  segnalati nella colonna Controlli — {a}: {n}")
    return errori


def main() -> int:
    if "--verifica" in sys.argv:
        e = verifica()
        print("verifica:", "nessun errore" if e == 0 else f"{e} errori")
        return 1 if e else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in genera().items():
        (OUT / name).write_text("﻿" + text, encoding="utf-8")
        print("scritto", OUT / name, text.count("\n") - 1, "righe")
    return 0


if __name__ == "__main__":
    sys.exit(main())
