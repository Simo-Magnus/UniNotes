"""Scarica l'offerta formativa (tutti i corsi di studio) da Universitaly.

Fonte: l'API pubblica usata dal sito www.universitaly.it (MUR/Cineca),
`https://universitaly-backend.cineca.it/api/offerta-formativa/cerca-corsi`,
10 corsi per pagina. Scrive data/raw/universitaly/corsi.json.gz.

Da eseguire dove internet è libero (GitHub Actions o il proprio PC):
    python tools/db_builder/fetch_universitaly.py
"""
from __future__ import annotations

import gzip
import json
import pathlib
import sys
import time

import requests

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "raw" / "universitaly" / "corsi.json.gz"
API = "https://universitaly-backend.cineca.it/api/offerta-formativa/cerca-corsi"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)",
    "Accept": "application/json",
    "Origin": "https://www.universitaly.it",
    "Referer": "https://www.universitaly.it/cerca-corsi",
}


def get_page(session: requests.Session, page: int) -> dict:
    params = {"searchType": "u", "page": page, "searchText": ""}
    for attempt in range(4):
        try:
            r = session.get(API, params=params, headers=HEADERS, timeout=30)
            r.raise_for_status()
            data = r.json()
            # con searchType=u la risposta è già il blocco "universita"
            data = data.get("universita", data) if isinstance(data, dict) else data
            if "corsi" not in data:
                raise ValueError(f"risposta inattesa: {str(data)[:200]}")
            return data
        except Exception as e:  # noqa: BLE001 - riprova su qualsiasi errore di rete
            wait = 2 ** attempt
            print(f"pagina {page}: {e!r}, riprovo tra {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise SystemExit(f"Pagina {page} non scaricata")


MAX_MINUTES = 25


def main() -> None:
    """Scarica tutto; se l'API è lenta o non risponde entro MAX_MINUTES si tiene
    la copia salvata in precedenza (data/raw/universitaly/corsi.json.gz)."""
    try:
        scarica()
    except (SystemExit, Exception) as e:  # noqa: BLE001
        if OUT.exists():
            print(f"::warning::Universitaly non scaricato ({e}); uso la copia salvata in {OUT.relative_to(ROOT)}")
            return
        raise


def scarica() -> None:
    inizio = time.monotonic()
    s = requests.Session()
    first = get_page(s, 1)
    total_pages = int(first["totalPages"])
    corsi = list(first["corsi"])
    print(f"{first['totalResults']} corsi in {total_pages} pagine")
    for page in range(2, total_pages + 1):
        if time.monotonic() - inizio > MAX_MINUTES * 60:
            raise TimeoutError(f"oltre {MAX_MINUTES} minuti alla pagina {page}/{total_pages}")
        corsi.extend(get_page(s, page)["corsi"])
        if page % 50 == 0:
            print(f"  pagina {page}/{total_pages}: {len(corsi)} corsi")
        time.sleep(0.3)
    # Un corso può comparire due volte se l'ordinamento cambia tra le pagine.
    unici = {str(c["id"]): c for c in corsi}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(OUT, "wt", encoding="utf-8") as f:
        json.dump({"scaricato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "fonte": API, "totale_dichiarato": first["totalResults"],
                   "corsi": sorted(unici.values(), key=lambda c: str(c["id"]))}, f, ensure_ascii=False)
    print(f"Salvati {len(unici)} corsi unici in {OUT.relative_to(ROOT)}")
    if len(unici) < int(first["totalResults"]) * 0.98:
        raise SystemExit("Mancano troppi corsi: ripetere il download")


if __name__ == "__main__":
    main()
