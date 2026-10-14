"""Controlli di qualità sul database (database/corsi/*.json).

Non corregge nulla: elenca per ateneo i dati sospetti, da verificare alla fonte o da correggere
nell'adattatore che li ha prodotti. Scrive data/verifica_db.json (tutti i casi) e stampa un
riepilogo in Markdown.

Controlli:
- struttura: id duplicati, anno fuori da 1..durata, CFU fuori da 0..90, periodo non valido,
  fonte o verificato_il mancanti;
- testo: caratteri rovinati da una codifica sbagliata (Ã, â€, �), entità o tag HTML rimasti,
  nomi vuoti o troppo lunghi, docenti con titoli, e-mail, cifre o più nomi uniti;
- libri: citazioni troppo corte o lunghe, righe che non sono riferimenti (modalità d'esame,
  ricevimento, …), stesso libro ripetuto nello stesso insegnamento, ISBN con cifra di controllo
  errata, anni di pubblicazione impossibili;
- esami: date non valide o lontane dall'a.a., ore non valide, duplicati;
- corsi: piani identici in corsi diversi dello stesso ateneo (spesso una pagina del sito che
  mostra il piano di un altro corso), stesso insegnamento più volte nello stesso anno.

    python tools/db_builder/verifica_db.py [--solo unibo,unimi]
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
DB = ROOT / "database"
OUT = ROOT / "data" / "verifica_db.json"

MOJIBAKE = re.compile(r"Ã.|â€|Â[^\w]|�")
HTML_RESTI = re.compile(r"&(?:[a-z]{2,8}|#\d{2,5});|<\s*/?\s*(?:br|p|span|div|strong|em|a|li|ul|b|i)\b[^>]*>", re.I)
NON_LIBRO = re.compile(r"(?i)^(il voto|la prova|l'esame|esame|modalit|ricevimento|orario|prerequisit|obiettiv|"
                       r"risultati di apprendimento|lo studente|gli studenti|il corso|le lezioni|frequenza|"
                       r"durante il corso|metodi didattici|valutazione)\b")
DOCENTE_STRANO = re.compile(r"(?i)\bprof\b\.?|@|\d|\bdott\b\.?|docente|nessun|da definire|tbd|n\.d\.")
PERIODI = {None, "1", "2", "3", "4", "annuale"}


def isbn_valido(s: str) -> bool:
    d = re.sub(r"[^0-9Xx]", "", s or "")
    if len(d) == 13 and d.isdigit():
        return sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(d)) % 10 == 0
    if len(d) == 10:
        try:
            return sum((10 - i) * (10 if c in "Xx" else int(c)) for i, c in enumerate(d)) % 11 == 0
        except ValueError:
            return False
    return False


def controlla(uid: str, doc: dict, oggi: dt.date) -> list[dict]:
    casi = []

    def caso(tipo, dove, dettaglio=""):
        casi.append({"ateneo": uid, "tipo": tipo, "dove": dove, "dettaglio": str(dettaglio)[:300]})

    ids = collections.Counter()
    piani = collections.defaultdict(list)
    for c in doc.get("corsi", []):
        durata = c.get("durata_anni") or 6
        ins = c.get("insegnamenti") or []
        firma = tuple(sorted((i.get("anno") or 0, (i.get("nome") or "").lower()) for i in ins))
        if len(ins) >= 8:
            piani[firma].append(c["id"])
        per_anno = collections.Counter(((i.get("anno"), (i.get("nome") or "").lower().strip(), i.get("curriculum"))
                                        for i in ins))
        for (anno, nome, cur), n in per_anno.items():
            if n > 1:
                caso("insegnamento_ripetuto", c["id"], f"{nome} (anno {anno}, curriculum {cur}) x{n}")
        for i in ins:
            dove = f"{c['id']} / {i.get('id')}"
            ids[i.get("id")] += 1
            nome = i.get("nome") or ""
            if not nome.strip():
                caso("nome_vuoto", dove)
            elif len(nome) > 160:
                caso("nome_lungo", dove, nome)
            for campo in ("nome", "curriculum"):
                v = i.get(campo) or ""
                if MOJIBAKE.search(v):
                    caso("codifica", dove, f"{campo}: {v}")
                if HTML_RESTI.search(v):
                    caso("html", dove, f"{campo}: {v}")
            a = i.get("anno")
            if a is not None and not (isinstance(a, int) and 1 <= a <= durata):
                caso("anno_fuori_durata", dove, f"anno {a}, durata {durata}")
            cfu = i.get("cfu")
            if cfu is not None and not (isinstance(cfu, (int, float)) and 0 <= cfu <= 90):
                caso("cfu_strani", dove, cfu)
            if i.get("periodo") not in PERIODI:
                caso("periodo", dove, i.get("periodo"))
            if not i.get("fonte") or not i.get("verificato_il"):
                caso("senza_fonte", dove)
            for d in i.get("docenti") or []:
                if DOCENTE_STRANO.search(d) or len(d) > 60 or len(d.split()) > 5 or len(d.split()) < 2:
                    caso("docente", dove, d)
                if MOJIBAKE.search(d) or HTML_RESTI.search(d):
                    caso("codifica", dove, f"docente: {d}")
            viste = collections.Counter()
            for lb in i.get("libri") or []:
                cit = lb.get("citazione") or lb.get("titolo") or ""
                viste[re.sub(r"\W+", "", cit.lower())[:120]] += 1
                if len(cit) < 15:
                    caso("libro_corto", dove, cit)
                elif len(cit) > 450:
                    caso("libro_lungo", dove, cit)
                if NON_LIBRO.search(cit):
                    caso("non_libro", dove, cit)
                if MOJIBAKE.search(cit):
                    caso("codifica", dove, f"libro: {cit}")
                if HTML_RESTI.search(cit):
                    caso("html", dove, f"libro: {cit}")
                if lb.get("isbn") and not isbn_valido(lb["isbn"]):
                    caso("isbn", dove, f"{lb['isbn']} in {cit[:80]}")
                an = lb.get("anno")
                if an is not None and not (1450 <= an <= oggi.year + 1):
                    caso("anno_libro", dove, f"{an}: {cit[:80]}")
            for k, n in viste.items():
                if n > 1 and k:
                    caso("libro_ripetuto", dove, f"{k[:80]} x{n}")
            date_viste = collections.Counter()
            for e in i.get("esami") or []:
                try:
                    d = dt.date.fromisoformat(e.get("data") or "")
                except ValueError:
                    caso("data_esame", dove, e.get("data"))
                    continue
                if not (oggi - dt.timedelta(days=400) <= d <= oggi + dt.timedelta(days=730)):
                    caso("data_esame_lontana", dove, e.get("data"))
                if e.get("ora") and not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", e["ora"]):
                    caso("ora_esame", dove, e["ora"])
                date_viste[(e.get("data"), e.get("ora"), e.get("tipo"), e.get("docenti"))] += 1
            for k, n in date_viste.items():
                if n > 1:
                    caso("esame_ripetuto", dove, f"{k} x{n}")
    for k, n in ids.items():
        if n > 1:
            caso("id_duplicato", k, f"x{n}")
    for firma, cs in piani.items():
        if len(cs) > 1:
            caso("piano_identico", ", ".join(cs), f"{len(firma)} insegnamenti uguali")
    return casi


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--solo", help="id atenei separati da virgola")
    args = ap.parse_args()
    solo = set(args.solo.split(",")) if args.solo else None
    oggi = dt.date.today()
    casi = []
    for f in sorted((DB / "corsi").glob("*.json")):
        if solo and f.stem not in solo:
            continue
        casi += controlla(f.stem, json.loads(f.read_text(encoding="utf-8")), oggi)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(casi, ensure_ascii=False, indent=1), encoding="utf-8")
    per_tipo = collections.Counter(c["tipo"] for c in casi)
    per_ateneo = collections.defaultdict(collections.Counter)
    for c in casi:
        per_ateneo[c["ateneo"]][c["tipo"]] += 1
    print(f"## Verifica del database — {len(casi)} casi\n")
    print("| Tipo | Casi |\n|---|---:|")
    for t, n in per_tipo.most_common():
        print(f"| {t} | {n} |")
    print("\n| Ateneo | Casi | Principali |\n|---|---:|---|")
    for uid, cnt in sorted(per_ateneo.items(), key=lambda x: -sum(x[1].values())):
        print(f"| {uid} | {sum(cnt.values())} | {', '.join(f'{t} {n}' for t, n in cnt.most_common(4))} |")
    print(f"\nDettaglio: {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
