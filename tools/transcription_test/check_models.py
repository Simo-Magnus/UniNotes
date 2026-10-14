"""Verifica che ogni modello Whisper della tabella dell'app sia scaricabile.

Legge i nomi `ggml-*.bin` da app/lib/features/links/ e fa una richiesta HEAD
all'indirizzo di download usato dall'app (Hugging Face, ggerganov/whisper.cpp).
"""
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
names = set()
for f in (ROOT / "app/lib").rglob("*.dart"):
    names |= set(re.findall(r"ggml-[a-z0-9.\-_]+?\.bin", f.read_text(encoding="utf-8")))
if not names:
    print("::warning::Nessun nome ggml-*.bin nel codice dell'app: controllo solo i modelli del test")
    names = {"ggml-small.bin", "ggml-large-v3-turbo-q5_0.bin"}
bad = []
for n in sorted(names):
    url = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{n}"
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "UniversityNotes-test"})
    try:
        r = urllib.request.urlopen(req, timeout=60)
        size = int(r.headers.get("Content-Length") or r.headers.get("x-linked-size") or 0)
        print(f"OK   {n:40s} {size / 1e6:8.0f} MB")
    except Exception as e:  # noqa: BLE001
        print(f"ERRORE {n}: {e}")
        bad.append(n)
sys.exit(1 if bad else 0)
