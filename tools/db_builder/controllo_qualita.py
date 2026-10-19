"""Controllo di qualità del database (oltre ai CFU per anno, vedi controllo_cfu.py).

Ogni controllo ha un codice, una gravità e conta i casi per ateneo, con alcuni esempi.
Gravità: `errore` (dato sbagliato o rotto: va corretto), `avviso` (probabile problema:
va verificato sulla fonte), `info` (normalizzazione o completezza).

Controlli:
- corsi: senza insegnamenti, durata non coerente con il tipo, doppioni, senza fonte;
- insegnamenti: nome non valido, anno mancante o oltre la durata, CFU mancanti/anomali,
  periodo non normalizzato, SSD non valido, doppioni nello stesso anno, testo con
  caratteri rovinati (mojibake), docenti non validi, obbligatorietà mancante;
- libri: ISBN non valido, anno impossibile, titolo mancante o sospetto, doppioni;
- appelli: data non valida, appelli vecchi (prima dell'anno accademico precedente),
  date troppo lontane, ora impossibile, doppioni, iscrizioni chiuse dopo l'appello;
- coerenza: meta.json, indice_corsi.json e file per corso rispetto a corsi/<ateneo>.json,
  corsi sostituiti verso corsi inesistenti.

Uso:

    python tools/db_builder/controllo_qualita.py [--solo id1,id2] [--json percorso] [--esempi N]
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
from collections import Counter, defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[2]
DB = ROOT / "database"
OGGI = dt.date.today()
INIZIO_AA = dt.date(OGGI.year if OGGI.month >= 9 else OGGI.year - 1, 9, 1)

GRAVITA = {
    "corso_vuoto": "avviso", "durata_tipo": "avviso", "corso_doppione": "avviso", "corso_senza_fonte": "info",
    "nome_non_valido": "errore", "anno_mancante": "avviso", "anno_oltre_durata": "errore",
    "cfu_mancanti": "avviso", "cfu_anomali": "avviso", "periodo_non_normalizzato": "info",
    "ssd_non_valido": "info", "doppione_anno": "avviso", "mojibake": "errore",
    "docente_non_valido": "avviso", "obbligatorio_mancante": "info",
    "isbn_non_valido": "errore", "libro_anno_impossibile": "errore", "libro_titolo": "avviso",
    "libro_doppione": "info", "appello_data_non_valida": "errore", "appello_vecchio": "info",
    "appello_lontano": "avviso", "appello_ora": "avviso", "appello_doppione": "info",
    "iscrizioni_dopo_appello": "avviso",
    "meta_incoerente": "errore", "indice_incoerente": "errore", "per_corso_incoerente": "errore",
    "sostituito_inesistente": "errore",
}

MOJIBAKE = re.compile(r"Ã[\x80-\xbf]|â€|Â[\xa0-\xbf]|�")
# SSD: vecchio formato (MAT/05, ING-INF/05, L-LIN/12, SECS-P/07, M-PSI/01), nuovo (MATH-02/B),
# tutti e due («MAT/03 (MATH-02/B)»), «NN» (attività senza settore)
_SSD1 = r"[A-Z]{1,4}(?:-[A-Z]{1,5})?/\d{2}"
_SSD2 = r"[A-Z]{3,5}-\d{2}/[A-Z]"
SSD = re.compile(rf"^(?:NN|{_SSD1}(?:\s*\({_SSD2}\))?|{_SSD2}(?:\s*\({_SSD1}\))?)$")
PERIODI = {"1", "2", "3", "4", "annuale", None}
DURATE = {"L": {3}, "LM": {2}, "LMCU": {5, 6}, "LM5": {5}, "LM6": {6}}
NOME_SPAZZATURA = re.compile(r"(?i)^(?:propedeuticit[àa]|prerequisiti|\d+[\s.,]*|n\.?d\.?|-+|totale(?:\s+cfu)?|cfu)$")


def isbn_ok(s: str) -> bool:
    d = re.sub(r"[^0-9Xx]", "", s or "")
    if len(d) == 10:
        if not re.fullmatch(r"\d{9}[\dXx]", d):
            return False
        tot = sum((10 - k) * (10 if c in "Xx" else int(c)) for k, c in enumerate(d))
        return tot % 11 == 0
    if len(d) == 13 and d.isdigit():
        tot = sum(int(c) * (1 if k % 2 == 0 else 3) for k, c in enumerate(d))
        return tot % 10 == 0
    return False


def _data(s):
    try:
        return dt.date.fromisoformat(str(s)[:10])
    except (TypeError, ValueError):
        return None


class Risultati:
    def __init__(self, esempi: int):
        self.n = defaultdict(Counter)  # codice -> ateneo -> numero
        self.es = defaultdict(list)
        self.max_es = esempi

    def add(self, codice: str, uid: str, esempio: str) -> None:
        self.n[codice][uid] += 1
        if len(self.es[codice]) < self.max_es:
            self.es[codice].append(f"{uid}: {esempio}")


def controlla_ateneo(uid: str, doc: dict, r: Risultati) -> None:
    visti_corsi = Counter((c.get("nome", "").lower(), c.get("classe"), c.get("sede")) for c in doc.get("corsi") or [])
    for c in doc.get("corsi") or []:
        cid = c.get("id")
        ins = c.get("insegnamenti") or []
        if not ins:
            r.add("corso_vuoto", uid, cid)
        tipo, durata = c.get("tipo"), c.get("durata_anni")
        if tipo in DURATE and durata not in DURATE[tipo]:
            r.add("durata_tipo", uid, f"{cid}: {tipo} con durata {durata}")
        if visti_corsi[(c.get("nome", "").lower(), c.get("classe"), c.get("sede"))] > 1:
            r.add("corso_doppione", uid, f"{cid}: {c.get('nome')} ({c.get('classe')}, {c.get('sede')})")
        if not c.get("fonte") and not c.get("url"):
            r.add("corso_senza_fonte", uid, cid)
        per_anno = defaultdict(list)
        for i in ins:
            nome = (i.get("nome") or "").strip()
            iid = i.get("id")
            if len(nome) < 3 or NOME_SPAZZATURA.search(nome):
                r.add("nome_non_valido", uid, f"{iid}: «{nome}»")
            for campo in ("nome",):
                if MOJIBAKE.search(i.get(campo) or ""):
                    r.add("mojibake", uid, f"{iid}: «{i.get(campo)}»")
            a = i.get("anno")
            if a is None:
                r.add("anno_mancante", uid, f"{iid}: {nome}")
            elif isinstance(a, int) and durata and a > durata:
                r.add("anno_oltre_durata", uid, f"{iid}: anno {a} > durata {durata}")
            cfu = i.get("cfu")
            if cfu is None:
                r.add("cfu_mancanti", uid, f"{iid}: {nome}")
            elif not isinstance(cfu, (int, float)) or cfu <= 0 or cfu > 30 or (cfu * 2) % 1:
                r.add("cfu_anomali", uid, f"{iid}: {nome} = {cfu} CFU")
            if i.get("periodo") not in PERIODI:
                r.add("periodo_non_normalizzato", uid, f"«{i.get('periodo')}»")
            s = i.get("ssd")
            if s and not all(SSD.match(x.strip()) for x in re.split(r"[;,]", s) if x.strip()):
                r.add("ssd_non_valido", uid, f"{iid}: «{s}»")
            for d in i.get("docenti") or []:
                if "@" in d or re.search(r"\d{3,}", d) or len(d) < 4 or re.search(r"(?i)da definire|tbd|n\.?d\.?$|docente", d):
                    r.add("docente_non_valido", uid, f"{iid}: «{d}»")
            if i.get("obbligatorio") is None:
                r.add("obbligatorio_mancante", uid, iid)
            per_anno[(a, re.sub(r"\W+", " ", nome.lower()).strip(), i.get("curriculum"))].append(i)
            visti_l = set()
            for lb in i.get("libri") or []:
                isbn = lb.get("isbn")
                if isbn and not isbn_ok(isbn):
                    r.add("isbn_non_valido", uid, f"{iid}: {isbn}")
                an = lb.get("anno")
                if isinstance(an, int) and (an < 1500 or an > OGGI.year + 1):
                    r.add("libro_anno_impossibile", uid, f"{iid}: {lb.get('titolo')} ({an})")
                t = (lb.get("titolo") or "").strip()
                if not t and not lb.get("citazione"):
                    r.add("libro_titolo", uid, f"{iid}: libro senza titolo né citazione")
                elif t and (len(t) < 3 or t.lower() == (lb.get("autori") or "").strip().lower()):
                    r.add("libro_titolo", uid, f"{iid}: «{t}»")
                if MOJIBAKE.search(t + (lb.get("autori") or "") + (lb.get("citazione") or "")):
                    r.add("mojibake", uid, f"{iid} (libro): «{(t or lb.get('citazione') or '')[:60]}»")
                k = (t.lower(), (lb.get("autori") or "").lower(), lb.get("citazione"))
                if k in visti_l:
                    r.add("libro_doppione", uid, f"{iid}: {t or (lb.get('citazione') or '')[:50]}")
                visti_l.add(k)
            visti_e = set()
            for e in i.get("esami") or []:
                d = _data(e.get("data"))
                if d is None:
                    r.add("appello_data_non_valida", uid, f"{iid}: «{e.get('data')}»")
                    continue
                if d < INIZIO_AA - dt.timedelta(days=365):
                    r.add("appello_vecchio", uid, f"{iid}: {d}")
                if d > OGGI + dt.timedelta(days=550):
                    r.add("appello_lontano", uid, f"{iid}: {d}")
                ora = e.get("ora")
                if ora and (not re.fullmatch(r"\d{1,2}:\d{2}", ora) or not (6 <= int(ora.split(":")[0]) <= 21)):
                    r.add("appello_ora", uid, f"{iid}: {d} ore «{ora}»")
                ke = (e.get("data"), e.get("ora"), e.get("tipo"), e.get("luogo"))
                if ke in visti_e:
                    r.add("appello_doppione", uid, f"{iid}: {d} {ora or ''}")
                visti_e.add(ke)
                fine = _data(e.get("iscrizioni_al"))
                if fine and fine > d:
                    r.add("iscrizioni_dopo_appello", uid, f"{iid}: appello {d}, iscrizioni fino al {fine}")
        for (a, nome, _), g in per_anno.items():
            codici = {x.get("codice") for x in g}
            if len(g) > 1 and len(codici) > 1 and nome:
                r.add("doppione_anno", uid, f"{c.get('id')} anno {a}: «{g[0].get('nome')}» ×{len(g)} ({', '.join(sorted(str(x) for x in codici))})")


def coerenza(uids: list[str], docs: dict, r: Risultati) -> None:
    meta = json.loads((DB / "meta.json").read_text(encoding="utf-8")).get("atenei", {})
    indice = json.loads((DB / "indice_corsi.json").read_text(encoding="utf-8")).get("corsi", [])
    per_ind = defaultdict(set)
    for row in indice:
        per_ind[row[0]].add(row[1])
    for uid in uids:
        doc = docs[uid]
        ids = {c["id"] for c in doc.get("corsi") or []}
        m = meta.get(uid)
        if not m:
            r.add("meta_incoerente", uid, "ateneo assente da meta.json")
        else:
            n_ins = sum(len(c.get("insegnamenti") or []) for c in doc["corsi"])
            if m.get("corsi") not in (None, len(ids)) or m.get("insegnamenti") not in (None, n_ins):
                r.add("meta_incoerente", uid, f"meta corsi {m.get('corsi')} / ins {m.get('insegnamenti')}, file {len(ids)} / {n_ins}")
        if per_ind.get(uid, set()) != ids:
            manca, extra = ids - per_ind.get(uid, set()), per_ind.get(uid, set()) - ids
            r.add("indice_incoerente", uid, f"{len(manca)} corsi non nell'indice, {len(extra)} nell'indice ma non nel file")
        pc = DB / "per_corso" / uid / "indice.json"
        if pc.exists():
            ind = json.loads(pc.read_text(encoding="utf-8")).get("corsi", {})
            if set(ind) != ids:
                r.add("per_corso_incoerente", uid, f"indice per corso: {len(set(ind) ^ ids)} corsi diversi")
            for cid, v in list(ind.items())[:400]:
                f = DB / "per_corso" / uid / f"{cid}.json"
                if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest() != v.get("sha256"):
                    r.add("per_corso_incoerente", uid, f"{cid}: file mancante o impronta diversa")
        elif ids:
            r.add("per_corso_incoerente", uid, "manca per_corso/<ateneo>/indice.json")
    sost = DB / "corsi_sostituiti.json"
    if sost.exists():
        tutti = {c["id"] for d in docs.values() for c in d.get("corsi") or []}
        dati = json.loads(sost.read_text(encoding="utf-8"))
        voci = dati.get("sostituiti") or dati.get("corsi") or {}
        for vecchio, nuovo in (voci.items() if isinstance(voci, dict) else []):
            dest = nuovo.get("id") if isinstance(nuovo, dict) else nuovo
            if isinstance(dest, str) and dest not in tutti and dest.split("-")[0] in docs:
                r.add("sostituito_inesistente", dest.split("-")[0], f"{vecchio} → {dest}")


def main(argv: list[str]) -> int:
    solo = set(argv[argv.index("--solo") + 1].split(",")) if "--solo" in argv else None
    esempi = int(argv[argv.index("--esempi") + 1]) if "--esempi" in argv else 3
    r = Risultati(esempi)
    docs = {}
    for p in sorted((DB / "corsi").glob("*.json")):
        if solo and p.stem not in solo:
            continue
        docs[p.stem] = json.loads(p.read_text(encoding="utf-8"))
        controlla_ateneo(p.stem, docs[p.stem], r)
    coerenza(sorted(docs), docs, r)
    ordine = {"errore": 0, "avviso": 1, "info": 2}
    righe = sorted(r.n.items(), key=lambda x: (ordine[GRAVITA[x[0]]], -sum(x[1].values())))
    for codice, per in righe:
        tot = sum(per.values())
        top = ", ".join(f"{u} {n}" for u, n in per.most_common(5))
        print(f"[{GRAVITA[codice]}] {codice}: {tot} in {len(per)} atenei ({top})")
        for e in r.es[codice]:
            print(f"     · {e[:180]}")
    if "--json" in argv:
        out = {c: {"gravita": GRAVITA[c], "totale": sum(p.values()), "atenei": dict(p), "esempi": r.es[c]} for c, p in r.n.items()}
        pathlib.Path(argv[argv.index("--json") + 1]).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
