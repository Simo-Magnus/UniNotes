"""Argomenti d'esame per insegnamento e corsi che condividono gli stessi argomenti.

    python tools/db_builder/argomenti.py polito        # raccoglie e scrive il report

Fonte: il programma pubblicato nella guida di ogni insegnamento (per ora
Politecnico di Torino: sezione «Programma» del Portale della Didattica). Gli
argomenti sono le voci del programma (righe numerate o puntate e righe brevi),
ripulite da numerazione e ore; i paragrafi descrittivi lunghi non diventano
argomenti. Nessun argomento viene dedotto o inventato: se il programma non è
pubblicato l'insegnamento resta senza argomenti.

Uscite:
- database/argomenti/<ateneo>.json: {id insegnamento: {argomenti, fonte,
  verificato_il}};
- docs/argomenti/<ateneo>.md: insegnamenti con gli stessi esatti argomenti in
  corsi di laurea diversi e quelli che differiscono di meno di 5 argomenti.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import html
import json
import re
import sys
import threading
import time
import unicodedata
import urllib.request
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "database" / "contrib" / "auto" / "programmi"
UA = "Mozilla/5.0 (UniversityNotes-DB; +https://github.com/Simo-Magnus/UniNotes)"
SOGLIA = 5  # «pochi argomenti diversi»

_lock = threading.Lock()
_last = [0.0]


def fetch(url: str, rate: float = 4.0) -> str:
    CACHE.mkdir(parents=True, exist_ok=True)
    f = CACHE / (hashlib.sha1(url.encode()).hexdigest() + ".html")
    if f.exists():
        return f.read_text(encoding="utf-8", errors="replace")
    with _lock:
        wait = 1 / rate - (time.time() - _last[0])
        if wait > 0:
            time.sleep(wait)
        _last[0] = time.time()
    for t in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=40) as r:
                s = r.read().decode("utf-8", errors="replace")
            f.write_text(s, encoding="utf-8")
            return s
        except Exception:  # noqa: BLE001
            time.sleep(5 * (t + 1))
    return ""


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


RIGA_ELENCO = re.compile(r"^\s*(?:\d+(?:\.\d+)*[.)]?|[-–•*·▪o]|[a-z][.)])\s+", re.I)


def argomenti(testo: str) -> list[str]:
    """Voci del programma: righe numerate/puntate o brevi, senza ore e numeri."""
    t = html.unescape(re.sub(r"<br\s*/?>|</p>|</li>", "\n", testo))
    t = re.sub(r"<[^>]+>", " ", t)
    out, visti = [], set()
    for riga in t.split("\n"):
        r = riga.strip()
        if not r:
            continue
        elenco = bool(RIGA_ELENCO.match(r))
        r = RIGA_ELENCO.sub("", r)
        r = re.sub(r"\(\s*\d+(?:[.,]\d+)?\s*(?:ore|h|hours?|cfu)\s*\)", "", r, flags=re.I)
        r = r.strip(" .;:,-–")
        if not r or len(r) < 3:
            continue
        if len(r) > 120 and not elenco:
            continue  # paragrafo descrittivo
        if len(r) > 160:
            continue
        k = norm(r)
        if k and k not in visti:
            visti.add(k)
            out.append(r)
    return out


def programma_polito(s: str) -> str | None:
    m = re.search(
        r'Programma<br\s*/?></span>.*?<div class="col-sm-10 formattata testo_it[^"]*">(.*?)</div>',
        s, re.S,
    )
    if not m:
        return None
    return re.sub(r'<span class="flag[^"]*"></span>', "", m.group(1))


def raccogli(uid: str) -> dict:
    d = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))
    per_url: dict[str, list[str]] = defaultdict(list)
    for c in d["corsi"]:
        if c.get("piano_da"):
            continue
        for i in c.get("insegnamenti") or []:
            if i.get("url"):
                per_url[i["url"]].append(i["id"])
    oggi = time.strftime("%Y-%m-%d")
    out = {}

    def uno(url: str):
        s = fetch(url)
        p = programma_polito(s) if s else None
        return url, (argomenti(p) if p else [])

    with cf.ThreadPoolExecutor(4) as ex:
        for n, (url, args) in enumerate(ex.map(uno, per_url), 1):
            if args:
                for iid in per_url[url]:
                    out[iid] = {"argomenti": args, "fonte": url, "verificato_il": oggi}
            if n % 250 == 0:
                print(f"{n}/{len(per_url)} programmi letti", flush=True)
    return out


def report(uid: str, dati: dict) -> str:
    d = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))
    info = {}
    for c in d["corsi"]:
        if c.get("piano_da"):
            continue
        for i in c.get("insegnamenti") or []:
            if i["id"] in dati:
                info[i["id"]] = (c["nome"], c.get("tipo") or "", i.get("anno"), i["nome"], i.get("codice") or "")
    insiemi = {k: frozenset(norm(a) for a in v["argomenti"]) for k, v in dati.items() if k in info}

    # 1) stessi esatti argomenti in corsi diversi
    gruppi = defaultdict(list)
    for k, s in insiemi.items():
        if len(s) >= 3:
            gruppi[s].append(k)
    uguali = [v for v in gruppi.values() if len({info[k][0] for k in v}) > 1]
    uguali.sort(key=lambda v: (-len(v), info[v[0]][3]))

    # 2) meno di SOGLIA argomenti diversi (tra rappresentanti di gruppi diversi)
    rapp = [(v[0], s) for s, v in gruppi.items()]
    indice = defaultdict(set)
    for n, (_, s) in enumerate(rapp):
        for a in s:
            indice[a].add(n)
    vicini = []
    for n, (k, s) in enumerate(rapp):
        cand = set()
        for a in s:
            cand |= indice[a]
        for m in cand:
            if m <= n:
                continue
            k2, s2 = rapp[m]
            diff = len(s ^ s2)
            if 0 < diff < SOGLIA and len(s & s2) >= 3:
                vicini.append((diff, k, k2, sorted(s - s2), sorted(s2 - s)))
    vicini.sort(key=lambda x: (x[0], info[x[1]][3]))

    def corsi(v):
        return "; ".join(sorted({f"{info[k][0]} ({info[k][1]}, {info[k][2]}° anno)" for k in v}))

    righe = [
        f"# Argomenti condivisi — {uid}",
        "",
        f"Generato da `tools/db_builder/argomenti.py` il {time.strftime('%d/%m/%Y')} dai programmi",
        "pubblicati nelle guide degli insegnamenti. Gli argomenti sono le voci dei programmi:",
        "due insegnamenti hanno «gli stessi argomenti» quando i loro programmi elencano le",
        "stesse voci (confronto senza maiuscole, accenti e punteggiatura).",
        "",
        f"- Insegnamenti con argomenti: {len(insiemi)} (con programma pubblicato e leggibile)",
        f"- Gruppi di insegnamenti con gli stessi esatti argomenti in più corsi di laurea: {len(uguali)}",
        f"- Coppie che differiscono di meno di {SOGLIA} argomenti: {len(vicini)}",
        "",
        "## Stessi esatti argomenti in corsi di laurea diversi",
        "",
        "| Insegnamento | Codice | Argomenti | Corsi di laurea |",
        "|---|---|---|---|",
    ]
    for v in uguali:
        k = v[0]
        righe.append(f"| {info[k][3]} | {info[k][4]} | {len(insiemi[k])} | {corsi(v)} |")
    righe += [
        "",
        f"## Differenze di meno di {SOGLIA} argomenti",
        "",
        "| Insegnamento A | Corso A | Insegnamento B | Corso B | Argomenti diversi | Solo in A | Solo in B |",
        "|---|---|---|---|---|---|---|",
    ]
    orig = {k: {norm(a): a for a in v["argomenti"]} for k, v in dati.items()}

    def nomi(k, xs):
        return "; ".join(orig[k].get(x, x) for x in xs)[:300] or "—"

    for diff, a, b, sa, sb in vicini[:2000]:
        righe.append(
            f"| {info[a][3]} | {info[a][0]} | {info[b][3]} | {info[b][0]} | {diff} | "
            f"{nomi(a, sa)} | {nomi(b, sb)} |"
        )
    if len(vicini) > 2000:
        righe.append(f"\n… altre {len(vicini) - 2000} coppie nel file JSON.")
    return "\n".join(r.replace("\n", " ") if r.startswith("|") else r for r in righe) + "\n"


def main() -> int:
    uid = sys.argv[1] if len(sys.argv) > 1 else "polito"
    if uid != "polito":
        print("per ora solo polito (programma dal Portale della Didattica)")
        return 2
    dati = raccogli(uid)
    out = ROOT / "database" / "argomenti" / f"{uid}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dati, ensure_ascii=False, indent=1), encoding="utf-8")
    rep = ROOT / "docs" / "argomenti" / f"{uid}.md"
    rep.parent.mkdir(parents=True, exist_ok=True)
    rep.write_text(report(uid, dati), encoding="utf-8")
    print("scritti", out, rep, len(dati), "insegnamenti con argomenti")
    return 0


if __name__ == "__main__":
    sys.exit(main())
