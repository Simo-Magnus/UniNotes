"""Genera le grafiche delle notifiche di UniNotes (nessuna immagine esterna).

Colori del logo dell'app (docs/logo.svg): blu #1784FB -> #0F72F2, ombra
#0A54DA -> #1A66D3, blu notte #0E3A7F, bianco. Ogni tipo di notifica ha un
quadrato arrotondato blu con la zona in ombra in basso a destra (come nella
"U" del logo) e il simbolo bianco del tipo; il logo dell'app, su una
tessera bianca (tools/genera_icona.py), è il logo dei toast di Windows,
l'icona grande di Android e sta a sinistra nelle immagini larghe:

- Android: res/drawable-nodpi/ic_notif_uninotes.png, icona grande (256 px)
  a destra della notifica = logo dell'app, come su iPhone e iPad (tutte le
  notifiche tranne la registrazione in corso, che ha un layout proprio);
  ic_notif_recensione.png e ic_notif_sostegno.png (stella e cuore) per le
  due notifiche promozionali. L'icona piccola monocromatica resta
  ic_stat_uninotes (tools/genera_icona.py --notifiche).
- Windows, iOS, macOS: assets/notifiche/<canale>.png (logo del tipo nel
  toast di Windows; su iOS e macOS la miniatura allegata a recensione e
  sostegno: la sola stella o il solo cuore), assets/notifiche/uninotes.png
  (logo dell'app registrato per i toast di Windows) e le immagini larghe
  hero_<canale>.png (728x360: in cima al toast di Windows; su iOS e macOS
  allegata solo per l'inizio della sessione d'esame).

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
# logo dell'app (solo lettura: tessera bianca col logo, angoli arrotondati,
# campionamento delle curve)
from genera_icona import _arrotonda, _bezier, tessera  # noqa: E402

N = 1024  # disegno grande, poi rimpicciolito

# colori del logo (docs/logo.svg)
BLU_1 = (0x17, 0x84, 0xFB)
BLU_2 = (0x0F, 0x72, 0xF2)
OMBRA_1 = (0x0A, 0x54, 0xDA)
OMBRA_2 = (0x1A, 0x66, 0xD3)
NOTTE = (0x0E, 0x3A, 0x7F)
BIANCO = (255, 255, 255)


def _diagonale(size: tuple[int, int], c0, c1, salendo: bool = False) -> Image.Image:
    """Sfumatura lineare in diagonale sul riquadro: da in alto a sinistra a
    in basso a destra ([salendo]: da in basso a sinistra a in alto a
    destra), come le sfumature del logo."""
    w, h = size
    n = 64  # funzione lineare: griglia piccola, poi ingrandita
    small = Image.new("RGB", (n, n))
    for j in range(n):
        v = (j + 0.5) / n
        for i in range(n):
            u = (i + 0.5) / n
            t = (u + (1 - v if salendo else v)) / 2
            small.putpixel((i, j), tuple(round(c0[k] + (c1[k] - c0[k]) * t) for k in range(3)))
    return small.resize((w, h), Image.BILINEAR)


def sfondo(size: int = N) -> Image.Image:
    """Quadrato blu del logo con la zona in ombra in basso a destra,
    delimitata da una curva come nella «U»."""
    img = _diagonale((size, size), BLU_1, BLU_2).convert("RGBA")
    curva = _bezier([(0, 0.88), (0.38, 0.84), (0.80, 0.76), (1.0, 0.50)])
    pts = [(0, 0.88)] + curva + [(1.0, 1.0), (0, 1.0)]
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon([(x * size, y * size) for x, y in pts], fill=255)
    ombra = _diagonale((size, size), OMBRA_1, OMBRA_2, salendo=True).convert("RGBA")
    ombra.putalpha(m)
    return Image.alpha_composite(img, ombra)


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
    "anni_precedenti": 0xF7EE,  # history_edu_rounded
}

# icona grande propria su Android solo per le notifiche promozionali (stella
# e cuore); tutte le altre mostrano il logo dell'app
ANDROID = ("recensione", "sostegno")

# immagini larghe solo per le notifiche rare (inizio della sessione
# d'esame, recensione, sostegno): sulle altre occuperebbero troppo spazio
HERO = ("sessioni", "recensione", "sostegno")


def _font_icone() -> ImageFont.FreeTypeFont:
    """Material Icons dal Flutter SDK (FLUTTER_ROOT o le cartelle solite)."""
    radici = [os.environ.get("FLUTTER_ROOT", ""), r"D:\flutter", r"D:\tools\flutter"]
    for r in filter(None, radici):
        f = Path(r) / "bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"
        if f.exists():
            return ImageFont.truetype(str(f), size=int(N * 0.50))
    raise FileNotFoundError("MaterialIcons-Regular.otf: imposta FLUTTER_ROOT")


def _glifo(codice: int, lato: int, scala: float = 0.50, alfa: float = 1.0) -> Image.Image:
    """Simbolo bianco con un'ombra morbida blu notte sotto."""
    font = _font_icone().font_variant(size=int(lato * scala))
    mask = Image.new("L", (lato, lato), 0)
    d = ImageDraw.Draw(mask)
    ch = chr(codice)
    box = d.textbbox((0, 0), ch, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((lato - w) / 2 - box[0], (lato - h) / 2 - box[1]), ch, font=font,
           fill=255)
    out = Image.new("RGBA", (lato, lato), (0, 0, 0, 0))
    giu = Image.new("L", (lato, lato), 0)
    giu.paste(mask, (0, round(lato * 0.015)))
    ombra = Image.new("RGBA", (lato, lato), NOTTE + (0,))
    ombra.putalpha(giu.filter(ImageFilter.GaussianBlur(lato * 0.02))
                   .point(lambda v: int(v * 0.45 * alfa)))
    out = Image.alpha_composite(out, ombra)
    bianco = Image.new("RGBA", (lato, lato), BIANCO + (0,))
    bianco.putalpha(mask.point(lambda v: int(v * alfa)))
    return Image.alpha_composite(out, bianco)


def badge(canale: str) -> Image.Image:
    """Quadrato arrotondato blu con il simbolo bianco del tipo."""
    img = Image.alpha_composite(sfondo(N), _glifo(SIMBOLI[canale], N, 0.54))
    return _arrotonda(img, 0.225)


def logo() -> Image.Image:
    """Logo dell'app sulla tessera bianca (logo dei toast di Windows, che
    lo mostra piccolo: versione per le icone piccole)."""
    return tessera(piccola=True)


def _logo_con_ombra(lato: int) -> Image.Image:
    """Tessera bianca col logo e un'ombra morbida blu notte sotto, su
    trasparente (tela più grande di [lato] per far stare l'ombra)."""
    m = lato // 6
    tela = Image.new("RGBA", (lato + 2 * m, lato + 2 * m), (0, 0, 0, 0))
    t = tessera().resize((lato, lato), Image.LANCZOS)  # disegnata grande
    scuro = Image.new("RGBA", t.size, (4, 20, 50, 255))
    scuro.putalpha(t.getchannel("A").point(lambda v: int(v * 0.55)))
    tela.paste(scuro, (m, m + lato // 30))
    tela = tela.filter(ImageFilter.GaussianBlur(lato * 0.04))
    tela.alpha_composite(t, (m, m))
    return tela


def hero(canale: str) -> Image.Image:
    """Immagine larga 2:1: fondo dal blu notte al blu del logo con due luci
    morbide, il logo dell'app a sinistra (tessera bianca), il simbolo del
    tipo grande e bianco a destra."""
    w, h = 1456, 720
    img = _diagonale((w, h), NOTTE, OMBRA_1).convert("RGBA")
    luce = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(luce)
    for cx, cy, r, a in ((w * 0.26, h * 0.42, h * 0.62, 120),
                         (w * 0.78, h * 0.30, h * 0.50, 90)):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=a)
    luce = luce.filter(ImageFilter.GaussianBlur(h * 0.22))
    strato = Image.new("RGBA", (w, h), BLU_1 + (0,))
    strato.putalpha(luce)
    img = Image.alpha_composite(img, strato)
    u = _logo_con_ombra(int(h * 0.62))
    img.alpha_composite(u, (int(w * 0.26 - u.width / 2), int((h - u.height) / 2)))
    g = _glifo(SIMBOLI[canale], h, 0.70, alfa=0.9)
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
        if canale in ANDROID:
            _salva(b, res / f"ic_notif_{canale}.png", (256, 256))
        _salva(b, assets / f"{canale}.png", (256, 256))
    # logo dell'app: icona grande di Android e logo dei toast di Windows
    _salva(logo(), res / "ic_notif_uninotes.png", (256, 256))
    _salva(logo(), assets / "uninotes.png", (256, 256))
    # le grafiche per tipo di Android non più usate (versioni precedenti)
    for canale in SIMBOLI:
        if canale not in ANDROID:
            (res / f"ic_notif_{canale}.png").unlink(missing_ok=True)
    for canale in HERO:
        _salva(hero(canale), assets / f"hero_{canale}.png", (728, 360))


if __name__ == "__main__":
    main()
