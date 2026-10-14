"""Genera l'icona di UniNotes con il codice (nessuna immagine esterna).

Disegno: una «U» spessa azzurra, con la sfumatura dell'app, su fondo blu
notte; in alto a destra il punto arancione della registrazione (l'azione
dello studente). Colori di Design 3 (docs/SPEC_DESIGN_3.md).

Scrive tutte le versioni usate dalle piattaforme:
- Android: mipmap-*/ic_launcher.png e icona adattiva (Android 8+)
- iOS: Assets.xcassets/AppIcon.appiconset (senza trasparenza)
- macOS: Assets.xcassets/AppIcon.appiconset (forma arrotondata con margine)
- Windows: runner/resources/app_icon.ico; icona dell'area di notifica
- Android: drawable-*/ic_stat_uninotes.png, icona piccola delle notifiche
  (sagoma bianca della «U» e del punto, su fondo trasparente)
- docs/icona.png (anteprima 1024)

Uso, dalla radice del repository: python tools/genera_icona.py
Solo l'icona delle notifiche: python tools/genera_icona.py --notifiche
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
S = 4096  # disegno grande, poi rimpicciolito (bordi morbidi)

BG_TOP = (14, 34, 60)
BG_BOTTOM = (2, 6, 15)
GLOW = (56, 189, 248)
U_TOP = (125, 232, 255)
U_BOTTOM = (14, 165, 233)
ORANGE_TOP = (255, 196, 107)
ORANGE_BOTTOM = (232, 111, 8)


def _vgrad(size: tuple[int, int], top, bottom) -> Image.Image:
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def sfondo(size: int = S) -> Image.Image:
    """Fondo blu notte con la luce azzurra in alto."""
    img = _vgrad((size, size), BG_TOP, BG_BOTTOM).convert("RGBA")
    glow = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(glow)
    r = int(size * 0.42)
    cx, cy = size // 2, int(size * 0.30)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
    layer = Image.new("RGBA", (size, size), GLOW + (0,))
    layer.putalpha(glow)
    return Image.alpha_composite(img, layer)


def simbolo(size: int = S, scala: float = 1.0) -> Image.Image:
    """La «U» (un unico tratto con le estremità arrotondate) e il punto
    arancione su fondo trasparente."""
    import math
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    c = size / 2
    w = size * 0.50 * scala          # larghezza esterna della U
    t = size * 0.13 * scala          # spessore del tratto
    r = (w - t) / 2                  # raggio della curva (asse del tratto)
    top = c - size * 0.20 * scala    # estremità alte delle aste
    yc = c + size * 0.06 * scala     # centro della curva
    xl, xr = c - r, c + r
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    ro, ri = r + t / 2, r - t / 2
    # curva in basso: anello (cerchio esterno meno interno), solo metà bassa
    ring = Image.new("L", (size, size), 0)
    dr = ImageDraw.Draw(ring)
    dr.ellipse((c - ro, yc - ro, c + ro, yc + ro), fill=255)
    dr.ellipse((c - ri, yc - ri, c + ri, yc + ri), fill=0)
    dr.rectangle((0, 0, size, yc), fill=0)
    mask.paste(255, (0, 0), ring)
    # aste e estremità arrotondate
    for x in (xl, xr):
        d.rectangle((x - t / 2, top, x + t / 2, yc + 1), fill=255)
        d.ellipse((x - t / 2, top - t / 2, x + t / 2, top + t / 2), fill=255)
    # punto arancione (registra) in alto a destra, staccato dalla U
    rr = size * 0.075 * scala
    ox, oy = xr + t * 0.95, top - t * 0.85
    gap = rr + size * 0.022 * scala
    ImageDraw.Draw(mask).ellipse((ox - gap, oy - gap, ox + gap, oy + gap), fill=0)
    grad = _vgrad((size, size), U_TOP, U_BOTTOM).convert("RGBA")
    grad.putalpha(mask)
    halo = mask.filter(ImageFilter.GaussianBlur(size * 0.02))
    halo_layer = Image.new("RGBA", (size, size), GLOW + (0,))
    halo_layer.putalpha(halo.point(lambda v: int(v * 0.35)))
    img = Image.alpha_composite(img, halo_layer)
    img = Image.alpha_composite(img, grad)
    dot = Image.new("L", (size, size), 0)
    ImageDraw.Draw(dot).ellipse((ox - rr, oy - rr, ox + rr, oy + rr), fill=255)
    og = _vgrad((size, size), ORANGE_TOP, ORANGE_BOTTOM).convert("RGBA")
    og.putalpha(dot)
    return Image.alpha_composite(img, og)


def _arrotonda(img: Image.Image, raggio: float, margine: float = 0.0) -> Image.Image:
    size = img.width
    m = int(size * margine)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (m, m, size - m - 1, size - m - 1), radius=int((size - 2 * m) * raggio), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def icona_piena() -> Image.Image:
    """Quadrato pieno (iOS lo arrotonda da sé)."""
    return Image.alpha_composite(sfondo(), simbolo())


def icona_arrotondata(margine: float = 0.0) -> Image.Image:
    return _arrotonda(icona_piena(), 0.225, margine)


def _salva(img: Image.Image, path: Path, px: int, rgb: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = img.resize((px, px), Image.LANCZOS)
    if rgb:
        out = out.convert("RGB")
    out.save(path, optimize=True)


def icona_notifica(px: int) -> Image.Image:
    """Icona piccola delle notifiche Android: sagoma bianca del simbolo
    (Android usa solo la trasparenza e la colora da sé), centrata con un
    margine di 2 dp su 24."""
    alpha = simbolo(S).getchannel("A")
    # via l'alone azzurro (trasparenza parziale): resta la sola forma
    alpha = alpha.point(lambda v: 255 if v >= 160 else 0)
    box = alpha.getbbox()
    forma = alpha.crop(box)
    lato = max(forma.size)
    quadro = Image.new("L", (lato, lato), 0)
    quadro.paste(forma, ((lato - forma.width) // 2, (lato - forma.height) // 2))
    interno = round(px * 20 / 24)
    quadro = quadro.resize((interno, interno), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (255, 255, 255, 0))
    bianco = Image.new("RGBA", (interno, interno), (255, 255, 255, 255))
    bianco.putalpha(quadro)
    m = (px - interno) // 2
    out.paste(bianco, (m, m), bianco)
    return out


def icone_notifica() -> None:
    res = APP / "android/app/src/main/res"
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for k, f in dens.items():
        px = round(24 * f)
        path = res / f"drawable-{k}/ic_stat_uninotes.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        icona_notifica(px).save(path, optimize=True)


def main() -> None:
    piena = icona_piena()
    arrot = icona_arrotondata()
    _salva(arrot, ROOT / "docs" / "icona.png", 1024)

    # Android: icona classica e icona adattiva
    res = APP / "android/app/src/main/res"
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    fg = simbolo(S, scala=0.62)  # dentro la zona sicura (66/108)
    bgc = sfondo()
    for k, f in dens.items():
        _salva(arrot, res / f"mipmap-{k}/ic_launcher.png", round(48 * f))
        _salva(fg, res / f"mipmap-{k}/ic_launcher_foreground.png", round(108 * f))
        _salva(bgc, res / f"mipmap-{k}/ic_launcher_background.png", round(108 * f))
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n', encoding="utf-8")

    # iOS: dimensioni dal Contents.json, senza trasparenza
    ios = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for im in json.loads((ios / "Contents.json").read_text(encoding="utf-8"))["images"]:
        px = round(float(im["size"].split("x")[0]) * int(im["scale"][0]))
        _salva(piena, ios / im["filename"], px, rgb=True)

    # macOS: forma arrotondata con margine (stile delle icone di macOS)
    mac_img = _arrotonda(piena, 0.225, 0.098)
    mac = APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        _salva(mac_img, mac / f"app_icon_{px}.png", px)

    # Windows e area di notifica
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    ico = arrot.resize((256, 256), Image.LANCZOS)
    ico.save(APP / "windows/runner/resources/app_icon.ico", sizes=sizes)
    ico.save(APP / "assets/tray/app_icon.ico", sizes=sizes)
    _salva(arrot, APP / "assets/tray/app_icon.png", 64)
    icone_notifica()
    print("icone scritte")


if __name__ == "__main__":
    import sys
    if "--notifiche" in sys.argv[1:]:
        icone_notifica()
        print("icone delle notifiche scritte")
    else:
        main()
