"""Genera le grafiche delle notifiche di UniNotes (nessuna immagine esterna).

Stesso disegno dell'icona dell'app (tools/genera_icona.py: fondo blu notte
con la luce azzurra, simbolo azzurro, punto arancione), con il simbolo del
tipo di notifica al posto della «U»:

- Android: res/drawable-nodpi/ic_notif_<canale>.png, icona grande (256 px)
  a destra della notifica; l'icona piccola monocromatica resta
  ic_stat_uninotes (tools/genera_icona.py --notifiche).
- Windows, iOS, macOS: assets/notifiche/<canale>.png (logo del tipo nel
  toast di Windows, miniatura allegata su iOS e macOS), assets/notifiche/
  uninotes.png (logo dell'app registrato per i toast di Windows) e le
  immagini larghe hero_<canale>.png (728×360, in cima al toast di Windows).

I nomi dei canali sono quelli di NotificationType (lib/core/reminders/
notification_plan.dart). I simboli sono quelli di Material Icons (font del
Flutter SDK, licenza Apache 2.0).

Uso, dalla cartella app: python tool/genera_grafiche_notifiche.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parent
sys.path.insert(0, str(ROOT / "tools"))
# disegno dell'icona dell'app (solo lettura: fondo, simbolo, sfumature)
from genera_icona import (  # noqa: E402
    GLOW,
    ORANGE_BOTTOM,
    ORANGE_TOP,
    U_BOTTOM,
    U_TOP,
    _arrotonda,
    _vgrad,
    sfondo,
    simbolo,
)

N = 1024  # disegno grande, poi rimpicciolito

# canale → simbolo di Material Icons (versione arrotondata)
SIMBOLI = {
    "prove": 0xF71B,  # event_note_rounded
    "sessioni": 0xF012E,  # school_rounded
    "esiti": 0xF021A,  # task_alt_rounded
    "collegamenti": 0xF859,  # link_off_rounded
    "registratore": 0xF8BD,  # mic_rounded
    "focus": 0xF023C,  # timer_rounded
    "focus_avvisi": 0xF553,  # alarm_rounded
    "recensione": 0xF01D4,  # star_rounded
    "sostegno": 0xF738,  # favorite_rounded
}

# immagini larghe solo per le notifiche rare (inizio della sessione
# d'esame, recensione, sostegno): sulle altre occuperebbero troppo spazio
HERO = ("sessioni", "recensione", "sostegno")


def _font_icone() -> ImageFont.FreeTypeFont:
    flutter = Path(os.environ.get("FLUTTER_ROOT", r"D:\flutter"))
    f = flutter / "bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"
    return ImageFont.truetype(str(f), size=int(N * 0.50))


def _glifo(codice: int, lato: int, scala: float = 0.50) -> Image.Image:
    """Simbolo con la sfumatura azzurra dell'icona e un alone tenue."""
    font = _font_icone().font_variant(size=int(lato * scala))
    mask = Image.new("L", (lato, lato), 0)
    d = ImageDraw.Draw(mask)
    ch = chr(codice)
    box = d.textbbox((0, 0), ch, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((lato - w) / 2 - box[0], (lato - h) / 2 - box[1]), ch, font=font,
           fill=255)
    out = Image.new("RGBA", (lato, lato), (0, 0, 0, 0))
    halo = mask.filter(ImageFilter.GaussianBlur(lato * 0.025))
    alone = Image.new("RGBA", (lato, lato), GLOW + (0,))
    alone.putalpha(halo.point(lambda v: int(v * 0.45)))
    out = Image.alpha_composite(out, alone)
    grad = _vgrad((lato, lato), U_TOP, U_BOTTOM).convert("RGBA")
    grad.putalpha(mask)
    return Image.alpha_composite(out, grad)


def _punto(img: Image.Image, cx: float, cy: float, r: float) -> Image.Image:
    """Punto arancione (l'azione dello studente), come nell'icona."""
    dot = Image.new("L", img.size, 0)
    ImageDraw.Draw(dot).ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    og = _vgrad(img.size, ORANGE_TOP, ORANGE_BOTTOM).convert("RGBA")
    og.putalpha(dot)
    return Image.alpha_composite(img, og)


def badge(canale: str) -> Image.Image:
    """Quadrato arrotondato blu notte con il simbolo del tipo."""
    img = sfondo(N)
    img = Image.alpha_composite(img, _glifo(SIMBOLI[canale], N, 0.54))
    img = _punto(img, N * 0.80, N * 0.20, N * 0.065)
    return _arrotonda(img, 0.225)


def logo() -> Image.Image:
    """Icona dell'app arrotondata (logo dei toast di Windows)."""
    return _arrotonda(Image.alpha_composite(sfondo(N), simbolo(N)), 0.225)


def hero(canale: str) -> Image.Image:
    """Immagine larga 2:1: la «U» dell'app a sinistra, il simbolo del tipo
    grande e sfumato a destra, luci azzurre come nel fondo dell'app."""
    w, h = 1456, 720
    img = _vgrad((w, h), (14, 34, 60), (2, 6, 15)).convert("RGBA")
    luce = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(luce)
    for cx, cy, r, a in ((w * 0.26, h * 0.42, h * 0.62, 110),
                         (w * 0.78, h * 0.30, h * 0.50, 70)):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=a)
    luce = luce.filter(ImageFilter.GaussianBlur(h * 0.22))
    strato = Image.new("RGBA", (w, h), GLOW + (0,))
    strato.putalpha(luce)
    img = Image.alpha_composite(img, strato)
    u = simbolo(h).resize((int(h * 0.92), int(h * 0.92)), Image.LANCZOS)
    img.alpha_composite(u, (int(w * 0.26 - u.width / 2), int((h - u.height) / 2)))
    g = _glifo(SIMBOLI[canale], h, 0.70)
    g.putalpha(g.getchannel("A").point(lambda v: int(v * 0.85)))
    img.alpha_composite(g, (int(w * 0.70 - h / 2), 0))
    return img


def _salva(img: Image.Image, path: Path, size: tuple[int, int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.resize(size, Image.LANCZOS).save(path, optimize=True)
    print(path.relative_to(APP))


def main() -> None:
    res = APP / "android/app/src/main/res/drawable-nodpi"
    assets = APP / "assets/notifiche"
    for canale in SIMBOLI:
        b = badge(canale)
        _salva(b, res / f"ic_notif_{canale}.png", (256, 256))
        _salva(b, assets / f"{canale}.png", (256, 256))
    _salva(logo(), assets / "uninotes.png", (256, 256))
    for canale in HERO:
        _salva(hero(canale), assets / f"hero_{canale}.png", (728, 360))


if __name__ == "__main__":
    main()
