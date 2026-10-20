"""Semestre degli insegnamenti dell'Università di Enna «Kore» dalla scheda di trasparenza (PDF).

L'API del sito (`api.uke.it/graphql`, campo `semester`) riporta «ALL_YEAR» («Tutto l'anno») come valore
predefinito anche per insegnamenti la cui scheda dice «Primo semestre» o «Secondo semestre»: non è una fonte
affidabile e non si usa. La scheda di trasparenza di ogni insegnamento (PDF su uke-transparency-docs.s3…, il `url`
dell'insegnamento nel database) ha invece la riga «Periodo di svolgimento <valore>» (a volte a capo dopo «Periodo di»):
è quella la fonte. Insegnamenti senza scheda PDF (il sito non ne dà il link) o con PDF scansionato (senza testo)
restano senza periodo.

Il PDF prevale anche sul valore predefinito dell'API: gli insegnamenti che il database ha già come «annuale»
(`ALL_YEAR`) e che hanno la scheda PDF si rileggono, e se la scheda dice «Primo» o «Secondo semestre» quel semestre
sostituisce «annuale» (se dice «Tutto l'anno»/«Annuale» non cambia nulla e non si scrive niente).

Le schede si salvano su disco in `$UN_HTTP_CACHE/unikore_pdf` (se la variabile è impostata). Al massimo 1,6 richieste
al secondo.
"""
from __future__ import annotations

import hashlib
import io
import os
import pathlib
import re
import sys
import time

import requests

from . import periodi

sys.path.insert(0, str(periodi.ROOT / "tools" / "db_builder"))
import pulizia  # noqa: E402

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
RIGA = re.compile(r"Periodo\s+di\s+svolgimento[ \t]+([^\n]+)", re.I)
LACUNE: dict[str, str] = {}


def codice(testo: str) -> str | None:
    t = re.sub(r"\s+", " ", testo).strip(" .")
    if re.fullmatch(r"(?i)tutto l['’]anno|annuale|annual", t):
        return "annuale"
    p = pulizia.periodo(t)
    return p if p in ("1", "2", "annuale") else None


def periodo_pdf(data: bytes) -> tuple[str | None, str]:
    """(codice, motivo se assente) dal testo di una scheda di trasparenza."""
    try:
        from pypdf import PdfReader
        testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages[:2])
    except Exception:  # noqa: BLE001
        return None, "PDF illeggibile"
    if len(testo.strip()) < 200:
        return None, "scheda PDF scansionata (senza testo)"
    m = RIGA.search(testo)
    if not m:
        return None, "la scheda non riporta il periodo di svolgimento"
    c = codice(m.group(1))
    return (c, "") if c else (None, f"periodo non interpretabile: «{m.group(1).strip()}»")


def annuali_con_pdf(uid: str) -> list[dict]:
    """Insegnamenti con periodo «annuale» (valore predefinito `ALL_YEAR` dell'API) che hanno la scheda PDF."""
    out = []
    for c in periodi.carica(uid)["corsi"]:
        if c.get("piano_da"):
            continue
        for i in c.get("insegnamenti") or []:
            if i.get("periodo") == "annuale" and (i.get("url") or "").lower().endswith(".pdf"):
                out.append({"corso": c["id"], "corso_nome": c["nome"], "id": i["id"], "codice": i.get("codice"),
                            "nome": i.get("nome"), "anno": i.get("anno"), "url": i.get("url"),
                            "url_sito": i.get("url_sito"), "docenti": i.get("docenti") or []})
    return out


def fetch_periodi(uid: str = "unikore", log=print) -> dict:
    manc = periodi.mancanti(uid)
    ids = {m["id"] for m in manc}
    gia_annuali = [m for m in annuali_con_pdf(uid) if m["id"] not in ids]
    manc = manc + gia_annuali
    gia = {m["id"] for m in gia_annuali}
    cache = os.environ.get("UN_HTTP_CACHE")
    cache = pathlib.Path(cache) / "unikore_pdf" if cache else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)
    out: dict[str, dict] = {}
    ultimo = 0.0
    n_pdf = 0
    for m in manc:
        u = m.get("url") or ""
        if not u.lower().endswith(".pdf"):
            LACUNE[m["id"]] = "nessuna scheda di trasparenza (PDF) per l'insegnamento: il sito riporta solo «Tutto l'anno» predefinito"
            continue
        n_pdf += 1
        f = cache / (hashlib.sha1(u.encode()).hexdigest() + ".pdf") if cache else None
        if f and f.exists():
            data = f.read_bytes()
        else:
            w = ultimo + 1 / 1.6 - time.monotonic()
            if w > 0:
                time.sleep(w)
            ultimo = time.monotonic()
            try:
                r = requests.get(u, headers=HEADERS, timeout=90)
            except requests.RequestException:
                LACUNE[m["id"]] = "scheda PDF non raggiungibile"
                continue
            if r.status_code != 200:
                LACUNE[m["id"]] = f"scheda PDF non disponibile (HTTP {r.status_code})"
                continue
            data = r.content
            if f:
                f.write_bytes(data)
        c, motivo = periodo_pdf(data)
        if m["id"] in gia:  # già «annuale» dall'API: la scheda cambia il valore solo se dice un semestre
            if c in ("1", "2"):
                out[m["id"]] = {"periodo": c, "fonte": u}
            elif c is None:
                LACUNE[m["id"]] = f"annuale dall'API, la scheda non lo smentisce ({motivo})"
            continue
        if c:
            out[m["id"]] = {"periodo": c, "fonte": u}
        else:
            LACUNE[m["id"]] = motivo
    log(f"[{uid}] trovati {len(out)} su {len(manc)} ({n_pdf} con scheda PDF; "
        f"{sum(1 for i in out if i in gia)} annuali dell'API corretti dalla scheda su {len(gia)})")
    d = os.environ.get("SEMESTRI_LACUNE")
    if d:
        import json
        pathlib.Path(d, f"lacune_{uid}.json").write_text(json.dumps(LACUNE, ensure_ascii=False, indent=0), encoding="utf-8")
    return out
