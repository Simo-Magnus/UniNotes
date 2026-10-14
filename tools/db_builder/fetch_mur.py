"""Scarica le 4 pagine MUR con l'elenco degli atenei in data/raw/mur/."""
import pathlib
import sys

import requests

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from parse_mur import PAGES, RAW  # noqa: E402

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder)"}

RAW.mkdir(parents=True, exist_ok=True)
for fname, url in PAGES.values():
    r = requests.get(url, headers=HEADERS, timeout=90)
    r.raise_for_status()
    if "<main" not in r.text:
        raise SystemExit(f"Pagina inattesa: {url}")
    (RAW / fname).write_text(r.text, encoding="utf-8")
    print("ok", url)
