"""Icone del pacchetto MSIX (Microsoft Store) dal logo dell'app.

Sorgente: l'icona 1024x1024 di iOS (stesso disegno di UniNotes_logo.png e di
app_icon.ico). Le icone quadrate hanno gli angoli arrotondati come
app_icon.ico e lo sfondo trasparente; il riquadro largo ha il logo al centro.

Uso (dalla cartella app):  python windows/msix/genera_icone.py
Richiede Pillow. Le icone finiscono in windows/msix/Assets/ e vanno
rigenerate solo se cambia il logo.
"""

from pathlib import Path

from PIL import Image, ImageDraw

QUI = Path(__file__).resolve().parent
LOGO = QUI.parents[1] / "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
USCITA = QUI / "Assets"

SCALE = (100, 125, 150, 200, 400)
# icona piccola (barra delle applicazioni, menu Start, Esplora file)
TARGETSIZE = (16, 24, 32, 48, 256)
# raggio degli angoli rispetto al lato, come app_icon.ico
RAGGIO = 0.18


def icona(lato: int) -> Image.Image:
    """Logo quadrato di [lato] pixel con gli angoli arrotondati."""
    base = Image.open(LOGO).convert("RGBA")
    grande = lato * 4  # maschera disegnata più grande: bordi più lisci
    maschera = Image.new("L", (grande, grande), 0)
    ImageDraw.Draw(maschera).rounded_rectangle(
        (0, 0, grande - 1, grande - 1), radius=round(grande * RAGGIO), fill=255
    )
    out = base.resize((lato, lato), Image.LANCZOS)
    out.putalpha(maschera.resize((lato, lato), Image.LANCZOS))
    return out


def su_tela(w: int, h: int, lato: int) -> Image.Image:
    """Logo di [lato] pixel al centro di una tela trasparente [w]x[h]."""
    tela = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    tela.alpha_composite(icona(lato), ((w - lato) // 2, (h - lato) // 2))
    return tela


def salva(img: Image.Image, nome: str) -> None:
    img.save(USCITA / nome, optimize=True)


def main() -> None:
    USCITA.mkdir(exist_ok=True)
    for vecchio in USCITA.glob("*.png"):
        vecchio.unlink()
    for s in SCALE:
        f = s / 100
        # icona dell'app: logo intero (Windows aggiunge il suo margine)
        salva(icona(round(44 * f)), f"Square44x44Logo.scale-{s}.png")
        # riquadri del menu Start: logo con margine attorno
        lato = round(150 * f)
        salva(su_tela(lato, lato, round(lato * 0.66)), f"Square150x150Logo.scale-{s}.png")
        w, h = round(310 * f), round(150 * f)
        salva(su_tela(w, h, round(h * 0.66)), f"Wide310x150Logo.scale-{s}.png")
        # logo nella pagina dello Store e nell'installazione
        salva(icona(round(50 * f)), f"StoreLogo.scale-{s}.png")
    for t in TARGETSIZE:
        img = icona(t)
        salva(img, f"Square44x44Logo.targetsize-{t}.png")
        # senza la «piastra» colorata (barra delle applicazioni, Start)
        salva(img, f"Square44x44Logo.targetsize-{t}_altform-unplated.png")
        salva(img, f"Square44x44Logo.targetsize-{t}_altform-lightunplated.png")
    print(f"Icone in {USCITA}: {len(list(USCITA.glob('*.png')))} file")


if __name__ == "__main__":
    main()
