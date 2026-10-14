"""Prepara i file audio per il test di trascrizione.

1. sintetico.wav: frase italiana nota letta da espeak-ng (testo in sintetico.txt),
   per misurare l'accuratezza (WER) in modo ripetibile;
2. lezione.mp3: 2 minuti di un audiolibro italiano LibriVox (pubblico dominio,
   archive.org), voce umana reale.
"""
import json
import pathlib
import subprocess
import urllib.parse
import urllib.request

OUT = pathlib.Path(__file__).parent / "audio"
OUT.mkdir(exist_ok=True)
TESTO = ("Buongiorno a tutti, oggi parliamo del teorema fondamentale del calcolo integrale. "
         "La derivata della funzione integrale è uguale alla funzione integranda, "
         "purché questa sia continua sull'intervallo considerato. "
         "Per l'esame di gennaio studiate i capitoli tre e quattro del libro di testo.")
(OUT / "sintetico.txt").write_text(TESTO, encoding="utf-8")
subprocess.run(["espeak-ng", "-v", "it", "-s", "150", "-w", str(OUT / "sintetico.wav"), TESTO], check=True)

UA = {"User-Agent": "UniversityNotes-transcription-test"}
items = []
for query in ["collection:librivoxaudio AND language:(Italian)", "collection:librivoxaudio AND language:(ita)",
              "collection:librivoxaudio AND title:(italiano OR italian)", "librivox AND language:(Italian)"]:
    q = urllib.parse.urlencode({"q": query, "fl[]": "identifier", "rows": "50", "output": "json"})
    req = urllib.request.Request(f"https://archive.org/advancedsearch.php?{q}", headers=UA)
    try:
        docs = json.load(urllib.request.urlopen(req, timeout=60))["response"]["docs"]
    except Exception as e:  # noqa: BLE001
        print("ricerca archive.org non riuscita:", e)
        docs = []
    print(f"{query!r}: {len(docs)} risultati")
    items += [d["identifier"] for d in docs]
    if items:
        break
for ident in items:
    meta = json.load(urllib.request.urlopen(urllib.request.Request(f"https://archive.org/metadata/{ident}", headers=UA),
                                            timeout=60))
    files = [f["name"] for f in meta.get("files", []) if f["name"].lower().endswith(".mp3")]
    mp3 = sorted(files, key=lambda n: (not n.endswith("_64kb.mp3"), n))
    if not mp3:
        continue
    url = f"https://archive.org/download/{ident}/{urllib.parse.quote(mp3[0])}"
    full = OUT / "librivox_full.mp3"
    urllib.request.urlretrieve(url, full)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "30", "-t", "120", "-i", str(full),
                    "-ac", "1", "-ar", "16000", str(OUT / "lezione.wav")], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(OUT / "lezione.wav"), str(OUT / "lezione.mp3")],
                   check=True)
    (OUT / "lezione_fonte.txt").write_text(f"{ident}\n{url}\nLibriVox, pubblico dominio\n", encoding="utf-8")
    print("Audiolibro:", url)
    break
else:
    print("::warning::Nessun audiolibro LibriVox italiano trovato: si usa solo l'audio sintetico")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(OUT / "sintetico.wav"), "-ar", "16000", "-ac", "1",
                str(OUT / "sintetico16k.wav")], check=True)
print("Audio pronti in", OUT)
