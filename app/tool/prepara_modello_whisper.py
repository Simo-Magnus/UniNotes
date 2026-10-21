"""Scarica il modello Whisper integrato nell'app (asset delle build Android
e iOS).

    python tool/prepara_modello_whisper.py

Da lanciare una volta prima di `flutter build apk|appbundle|ios`
(e nella CI prima delle build): mette `ggml-base-q5_1.bin` (57 MiB, base
multilingue quantizzato q5_1 di whisper.cpp, licenza MIT) in
`app/assets/whisper/`, controllando lo SHA-1 pubblicato. Il file non è nel
repository (.gitignore). Senza il file la build funziona lo stesso: l'app
scarica il modello la prima volta che serve.

PC e Mac (Windows, macOS, Linux) non usano questo asset (in pubspec.yaml ha
`platforms: [android, ios]`): il loro testo dal vivo è di Parakeet, che
l'app scarica alla prima registrazione.
"""
import hashlib
import pathlib
import sys
import urllib.request

NAME = "ggml-base-q5_1.bin"
URL = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{NAME}"
SHA1 = "a3733eda680ef76256db5fc5dd9de8629e62c5e7"  # whisper.cpp models/README.md
TARGET = pathlib.Path(__file__).resolve().parents[1] / "assets" / "whisper" / NAME


def sha1(path: pathlib.Path) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    if TARGET.exists() and sha1(TARGET) == SHA1:
        print(f"Già presente: {TARGET}")
        return 0
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    part = TARGET.with_suffix(".part")
    print(f"Scarico {URL}")
    req = urllib.request.Request(URL, headers={"User-Agent": "UniNotes-build"})
    with urllib.request.urlopen(req, timeout=120) as r, part.open("wb") as out:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            out.write(block)
    got = sha1(part)
    if got != SHA1:
        part.unlink()
        print(f"SHA-1 diverso ({got}): file scartato", file=sys.stderr)
        return 1
    part.replace(TARGET)
    print(f"Pronto: {TARGET} ({TARGET.stat().st_size / 2**20:.0f} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
