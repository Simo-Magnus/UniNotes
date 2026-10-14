"""Trascrive un file audio con l'API Gemini (Files API), come fa l'app.

Richiede la variabile GEMINI_API_KEY (secret del repository). Uso:
    python gemini_test.py audio/sintetico.wav [modello]
"""
import json
import mimetypes
import os
import pathlib
import sys
import time
import urllib.request

KEY = os.environ.get("GEMINI_API_KEY")
if not KEY:
    print("GEMINI_API_KEY non impostata: test Gemini saltato")
    sys.exit(0)
path = pathlib.Path(sys.argv[1])
model = sys.argv[2] if len(sys.argv) > 2 else "gemini-flash-latest"
mime = mimetypes.guess_type(path.name)[0] or "audio/wav"
data = path.read_bytes()
BASE = "https://generativelanguage.googleapis.com"

# 1. upload resumable
req = urllib.request.Request(f"{BASE}/upload/v1beta/files", method="POST", headers={
    "x-goog-api-key": KEY, "X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start",
    "X-Goog-Upload-Header-Content-Length": str(len(data)), "X-Goog-Upload-Header-Content-Type": mime,
    "Content-Type": "application/json"}, data=json.dumps({"file": {"display_name": path.name}}).encode())
upload_url = urllib.request.urlopen(req, timeout=60).headers["X-Goog-Upload-URL"]
req = urllib.request.Request(upload_url, method="POST", data=data, headers={
    "X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize", "Content-Length": str(len(data))})
file = json.load(urllib.request.urlopen(req, timeout=300))["file"]
while file.get("state") == "PROCESSING":
    time.sleep(3)
    file = json.load(urllib.request.urlopen(urllib.request.Request(f"{BASE}/v1beta/{file['name']}",
                                                                   headers={"x-goog-api-key": KEY}), timeout=60))
# 2. trascrizione
prompt = ("Trascrivi fedelmente in italiano questa registrazione di una lezione universitaria. "
          "Restituisci solo il testo, senza commenti.")
body = {"contents": [{"parts": [{"text": prompt}, {"file_data": {"mime_type": mime, "file_uri": file["uri"]}}]}]}
req = urllib.request.Request(f"{BASE}/v1beta/models/{model}:generateContent", method="POST",
                             data=json.dumps(body).encode(),
                             headers={"x-goog-api-key": KEY, "Content-Type": "application/json"})
res = json.load(urllib.request.urlopen(req, timeout=600))
text = "".join(p.get("text", "") for p in res["candidates"][0]["content"]["parts"])
out = path.with_suffix(".gemini.txt")
out.write_text(text, encoding="utf-8")
print(text[:2000])
