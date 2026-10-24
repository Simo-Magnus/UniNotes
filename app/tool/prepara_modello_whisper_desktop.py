"""Prepara il modello Whisper incluso nelle build desktop (Windows, macOS).

    python tool/prepara_modello_whisper_desktop.py
    python tool/prepara_modello_whisper_desktop.py --installa build/macos/Build/Products/Release/UniNotes.app/Contents/Resources/whisper

1. Scarica (una volta) `ggml-small-q5_1.bin` (Whisper small multilingue di
   OpenAI convertito in ggml e quantizzato q5_1 da whisper.cpp, 181 MiB,
   licenza MIT) dal repository ufficiale di whisper.cpp su Hugging Face
   (`ggerganov/whisper.cpp`) nella cache `app/build/whisper/`, controllando
   lo SHA-256 (impronta LFS pubblicata da Hugging Face, la stessa di
   lib/features/links/whisper_models.dart e di windows/CMakeLists.txt) e lo
   SHA-1 della tabella del README di whisper.cpp. La cache non è nel
   repository (`build/` è in .gitignore); nella CI la conserva
   actions/cache. Un file già controllato ha accanto `<nome>.sha256`: non si
   rilegge ogni volta.
2. Con `--installa CARTELLA` copia nella cartella il modello e il testo delle
   licenze MIT (pesi di OpenAI e conversione di whisper.cpp). Serve su macOS
   (Resources/whisper nel bundle, prima della firma); su Windows lo fa
   windows/CMakeLists.txt durante `flutter build windows` (data/whisper
   accanto a uninotes.exe), che usa la stessa cache.

Il modello ritrascrive, fissato sulla lingua della lezione, le frasi che
Parakeet scrive in un'altra lingua (docs/registratore.md). Il modello del
telefono (base q5_1) è un'altra cosa: tool/prepara_modello_whisper.py.

Esce con 1 se il file non si scarica o non corrisponde.
"""
import argparse
import hashlib
import pathlib
import shutil
import sys
import urllib.request

APP = pathlib.Path(__file__).resolve().parents[1]
NAME = "ggml-small-q5_1.bin"
URL = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{NAME}"
SIZE = 190085487
# SHA-256: oid LFS di Hugging Face (X-Linked-ETag / API paths-info, 24/10/2026)
SHA256 = "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
# SHA-1: tabella «Available models» del README di whisper.cpp
SHA1 = "6fe57ddcfdd1c6b07cdcc73aaf620810ce5fc771"
CACHE = APP / "build" / "whisper"
LICENSE = APP / "assets" / "licenses" / "whisper_LICENSE.txt"


def digest(path: pathlib.Path, algo: str) -> str:
    h = hashlib.new(algo)
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def checked(path: pathlib.Path) -> bool:
    stamp = path.with_name(path.name + ".sha256")
    if path.exists() and stamp.exists() and stamp.read_text().strip() == SHA256:
        return path.stat().st_size == SIZE
    if path.exists() and digest(path, "sha256") == SHA256:
        stamp.write_text(SHA256)
        return True
    return False


def download() -> bool:
    target = CACHE / NAME
    if checked(target):
        print(f"Già presente: {NAME}")
        return True
    part = target.with_name(NAME + ".part")
    print(f"Scarico {URL}")
    req = urllib.request.Request(URL, headers={"User-Agent": "UniNotes-build"})
    with urllib.request.urlopen(req, timeout=300) as r, part.open("wb") as out:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            out.write(block)
    got256 = digest(part, "sha256")
    got1 = digest(part, "sha1")
    if got256 != SHA256 or got1 != SHA1:
        part.unlink()
        print(
            f"Impronta diversa per {NAME} (SHA-256 {got256}, SHA-1 {got1}): scartato",
            file=sys.stderr,
        )
        return False
    part.replace(target)
    target.with_name(NAME + ".sha256").write_text(SHA256)
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--installa", type=pathlib.Path, help="cartella di destinazione")
    args = ap.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    if not download():
        return 1
    if args.installa:
        dest = args.installa
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CACHE / NAME, dest / NAME)
        shutil.copyfile(LICENSE, dest / "LICENSE.txt")
        total = sum(f.stat().st_size for f in dest.iterdir())
        print(f"Installato in {dest} ({total / 2**20:.0f} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
