"""Prepara il modello Parakeet incluso nelle build desktop (Windows, macOS).

    python tool/prepara_modello_parakeet.py
    python tool/prepara_modello_parakeet.py --installa build/macos/Build/Products/Release/UniNotes.app/Contents/Resources/parakeet

1. Scarica (una volta) i quattro file di NVIDIA Parakeet TDT 0.6B v3 nella
   conversione ONNX int8 di sherpa-onnx (670 MB) da Hugging Face nella cache
   `app/build/parakeet/<cartella del modello>/`, controllando lo SHA-256 di
   ogni file (gli stessi di lib/features/links/parakeet_model.dart). La cache
   non è nel repository (`build/` è in .gitignore); nella CI la conserva
   actions/cache. Un file già controllato ha accanto `<nome>.sha256`: non si
   rilegge ogni volta.
2. Con `--installa CARTELLA` copia nella cartella il modello, Silero VAD e i
   testi delle licenze richiesti per la redistribuzione: LICENSE.txt (CC BY
   4.0), NOTICE.txt (attribuzione a NVIDIA, modifiche, nessuna affiliazione,
   esclusione di garanzia), le licenze MIT di Silero VAD e ONNX Runtime.
   Serve su macOS (Resources/parakeet nel bundle, prima della firma); su
   Windows lo fa windows/CMakeLists.txt durante `flutter build windows`
   (data/parakeet accanto a uninotes.exe), che usa la stessa cache.

Esce con 1 se un file non si scarica o non corrisponde.
"""
import argparse
import hashlib
import pathlib
import shutil
import sys
import urllib.request

APP = pathlib.Path(__file__).resolve().parents[1]
DIR = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
REPO = "https://huggingface.co/csukuangfj/" + DIR + "/resolve/main"
CACHE = APP / "build" / "parakeet" / DIR
FILES = {
    "tokens.txt": "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
    "joiner.int8.onnx": "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3",
    "decoder.int8.onnx": "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e",
    "encoder.int8.onnx": "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247",
}
LICENSES = APP / "assets" / "licenses"
EXTRA = {
    APP / "assets" / "vad" / "silero_vad.onnx": "silero_vad.onnx",
    LICENSES / "CC-BY-4.0.txt": "LICENSE.txt",
    LICENSES / "parakeet_NOTICE.txt": "NOTICE.txt",
    LICENSES / "silero_vad_LICENSE.txt": "silero_vad_LICENSE.txt",
    LICENSES / "onnxruntime_LICENSE.txt": "onnxruntime_LICENSE.txt",
}


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def checked(path: pathlib.Path, want: str) -> bool:
    stamp = path.with_name(path.name + ".sha256")
    if path.exists() and stamp.exists() and stamp.read_text().strip() == want:
        return True
    if path.exists() and sha256(path) == want:
        stamp.write_text(want)
        return True
    return False


def download(name: str, want: str) -> bool:
    target = CACHE / name
    if checked(target, want):
        print(f"Già presente: {name}")
        return True
    part = target.with_name(name + ".part")
    url = f"{REPO}/{name}"
    print(f"Scarico {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "UniNotes-build"})
    with urllib.request.urlopen(req, timeout=300) as r, part.open("wb") as out:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            out.write(block)
    got = sha256(part)
    if got != want:
        part.unlink()
        print(f"SHA-256 diverso per {name} ({got}): scartato", file=sys.stderr)
        return False
    part.replace(target)
    target.with_name(name + ".sha256").write_text(want)
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--installa", type=pathlib.Path, help="cartella di destinazione")
    args = ap.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    ok = all(download(n, s) for n, s in FILES.items())
    if not ok:
        return 1
    if args.installa:
        dest = args.installa
        dest.mkdir(parents=True, exist_ok=True)
        for name in FILES:
            shutil.copyfile(CACHE / name, dest / name)
        for src, name in EXTRA.items():
            shutil.copyfile(src, dest / name)
        total = sum(f.stat().st_size for f in dest.iterdir())
        print(f"Installato in {dest} ({total / 2**20:.0f} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
