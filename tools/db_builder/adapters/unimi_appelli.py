"""Prossimi appelli d'esame dell'Università degli Studi di Milano.

Le pagine "Appelli d'esame" dei siti dei corsi (`<corso>.cdl.unimi.it/it/studiare/appelli-esame`)
caricano i dati da un servizio pubblico, senza login:

- `work.unimi.it/foProssimiEsami/json/<CDS>` → per ogni attività (`codW4`, es. "GAD-42",
  `descrIns`) l'elenco degli appelli aperti o in programma: data, ora, luogo, docente, tipo di
  prova, finestra di iscrizione, intervallo di cognomi, avviso.

`<CDS>` è il prefisso dei codici delle attività (in database/corsi/unimi.json il codice
"AF20270000GAD-42" è l'attività GAD-42 del corso GAD). Gli appelli si restituiscono con
il codice completo dell'insegnamento, come fa adapters/esse3_appelli.py.
"""
from __future__ import annotations

import json
import pathlib
import re

from .unibo import Client

ROOT = pathlib.Path(__file__).resolve().parents[3]
URL = "https://work.unimi.it/foProssimiEsami/json/{}"
CODICE = re.compile(r"AF\d{4}0*([A-Z0-9]+)-(\d+)$")


def _data(s: str | None) -> str | None:
    m = re.match(r"(\d{2})/(\d{2})/(\d{4})", s or "")
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else None


def _modalita(prova: str | None) -> str | None:
    p = (prova or "").lower()
    if not p:
        return None
    if "scritto" in p and "orale" in p:
        return "scritto+orale"
    for k, v in (("scritt", "scritto"), ("oral", "orale"), ("test", "quiz"), ("quiz", "quiz"),
                 ("progett", "progetto")):
        if k in p:
            return v
    return "altro"


def appelli_cds(c: Client, cds: str) -> dict[str, list[dict]]:
    """{codW4: [esame, …]} per un corso."""
    r = c.get(URL.format(cds))
    if not r:
        return {}
    try:
        dati = json.loads(r.text)  # anche dalla cache su disco (UN_HTTP_CACHE), che non ha .json()
    except ValueError:
        return {}
    out: dict[str, list[dict]] = {}
    for att in dati or []:
        cod = (att.get("codW4") or "").strip()
        if not re.fullmatch(r"[A-Z0-9]+-\d+", cod):
            continue  # accertamenti OFA ("0") e simili
        for a in att.get("appelli") or []:
            data = _data(a.get("dataStr"))
            if not data:
                continue
            doc = a.get("docente") or {}
            docente = " ".join(x for x in (doc.get("cognome"), doc.get("nome")) if x).strip() or None
            note = [x.strip() for x in (a.get("nomeAppello"), a.get("avviso")) if x and x.strip()]
            if (a.get("rangeDa"), a.get("rangeA")) not in ((None, None), ("A", "Z")):
                note.append(f"Cognomi da {a.get('rangeDa')} a {a.get('rangeA')}")
            ora = a.get("ora") if re.fullmatch(r"\d{1,2}[:.]\d{2}", a.get("ora") or "") else None
            out.setdefault(cod, []).append({
                "tipo": "prova_in_itinere" if re.search(r"(?i)itinere|parzial", a.get("tipoAppello") or "")
                else "appello",
                "titolo": (att.get("descrIns") or "").strip() or None,
                "data": data, "ora": f"{int(ora[:-3]):02d}:{ora[-2:]}" if ora else None,
                "luogo": (a.get("luogo") or "").strip() or None,
                "modalita": _modalita(a.get("prova")),
                "iscrizioni_dal": _data(a.get("aperturaStr")), "iscrizioni_al": _data(a.get("chiusuraStr")),
                "docenti": docente, "note": "; ".join(note) or None, "fonte": URL.format(cds),
                "_id": a.get("idAppello"),
            })
    return out


def _norm(t: str | None) -> str:
    import unicodedata
    t = unicodedata.normalize("NFKD", t or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", re.sub(r"\(.*?\)", "", t)).strip()


def fetch_appelli(uid: str = "unimi", corsi: list[dict] | None = None, log=print) -> dict[str, list[dict]]:
    """{codice insegnamento: [esame, …]} per gli insegnamenti di `corsi` (default: il database)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    per_w4: dict[str, set[str]] = {}
    per_cds: dict[str, list[dict]] = {}  # CDS -> insegnamenti dei corsi con quel prefisso
    for corso in corsi:
        prefissi = set()
        for i in corso.get("insegnamenti") or []:
            m = CODICE.match(i.get("codice") or "")
            if m:
                per_w4.setdefault(f"{m.group(1)}-{m.group(2)}", set()).add(i["codice"])
                prefissi.add(m.group(1))
        for p in prefissi:
            per_cds.setdefault(p, []).extend(corso.get("insegnamenti") or [])
    c = Client(rate=3.0)
    tutti: dict[str, dict[str, dict]] = {}
    da_cds: dict[str, set[str]] = {}
    for cds in sorted({k.split("-")[0] for k in per_w4}):
        for w4, lst in appelli_cds(c, cds).items():
            da_cds.setdefault(w4, set()).add(cds)
            for e in lst:
                tutti.setdefault(w4, {}).setdefault(e["_id"] or f"{e['data']}{e['ora']}{e['tipo']}", e)
    out: dict[str, list[dict]] = {}
    for w4, per_id in tutti.items():
        esami = sorted(({k: v for k, v in e.items() if k != "_id"} for e in per_id.values()),
                       key=lambda e: (e["data"], e["ora"] or ""))
        for cod in per_w4.get(w4, ()):
            out[cod] = esami
    # Attività con appelli che non sono nel piano dell'a.a. corrente (codici di ordinamenti o
    # coorti precedenti, es. B17-11 «Sociologia della comunicazione» per Comunicazione e società):
    # si associano all'insegnamento dello stesso corso con lo stesso nome SOLO se il presidente
    # della commissione è tra i docenti dell'insegnamento e l'insegnamento non ha appelli propri.
    aggiunti = 0
    for w4, per_id in tutti.items():
        if w4 in per_w4:
            continue
        esami = sorted(({k: v for k, v in e.items() if k != "_id"} for e in per_id.values()),
                       key=lambda e: (e["data"], e["ora"] or ""))
        nome = _norm(esami[0].get("titolo"))
        presidenti = {(e.get("docenti") or "").lower() for e in esami} - {""}
        for cds in da_cds.get(w4, ()):
            for i in per_cds.get(cds, []):
                cod = i.get("codice")
                if not cod or cod in out or _norm(i.get("nome")) != nome:
                    continue
                docenti = [d.lower() for d in i.get("docenti") or []]
                if not any(d == p or d.startswith(p.split()[0] + " ") for d in docenti for p in presidenti):
                    continue
                nota = f"Appello dell'attività {w4} ({(esami[0].get('titolo') or '').strip()})"
                out[cod] = [dict(e, note="; ".join(x for x in (e.get("note"), nota) if x)) for e in esami]
                aggiunti += 1
    log(f"[{uid}] insegnamenti con appelli di un'attività omonima dello stesso corso e docente: {aggiunti}")
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti "
        f"({len(tutti)} attività con appelli); richieste: {c.requests}")
    return out
