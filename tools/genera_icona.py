"""Genera le icone di UniNotes dal logo vettoriale docs/logo.svg.

Disegno (docs/logo.svg, unica fonte): una «U» blu con una zona in ombra in
basso a destra e un tocco di laurea blu notte appoggiato sull'asta sinistra
(tavola, fascia dietro la U, cordino e nappa), su fondo bianco. Lo script
legge l'SVG (solo quello che usa il logo: rettangoli, tracciati con linee,
curve di Bézier e archi, sfumature lineari, una maschera di ritaglio) e lo
disegna con Pillow a 4096 px campionando le curve in poligoni fitti, poi
rimpicciolisce: niente browser né librerie SVG.

Scrive tutte le versioni usate dalle piattaforme:
- Android: mipmap-*/ic_launcher.png (tessera bianca arrotondata), icona
  adattiva di Android 8+ (primo piano trasparente nella zona sicura, fondo
  bianco) e icona monocromatica per le icone a tema di Android 13
- Android: drawable-*/ic_stat_uninotes.png, icona piccola delle notifiche
  (sagoma bianca della U e del cappello, su fondo trasparente)
- iOS: Assets.xcassets/AppIcon.appiconset (quadrato bianco, senza trasparenza)
- macOS: Assets.xcassets/AppIcon.appiconset (forma arrotondata con margine e
  ombra leggera, come il modello di Apple)
- Windows: runner/resources/app_icon.ico e icona dell'area di notifica
  (assets/tray), con il logo più grande nella tessera per restare leggibile
  a 16 px
- docs/icona.png (anteprima 1024), sito/icona.png e sito/favicon.png

Le icone del pacchetto MSIX (app/windows/msix/genera_icone.py) e le grafiche
delle notifiche (app/tool/genera_grafiche_notifiche.py) usano le funzioni di
questo script: dopo un cambio del logo vanno rieseguiti anche loro.

Uso, dalla radice del repository: python tools/genera_icona.py
Solo l'icona delle notifiche: python tools/genera_icona.py --notifiche
"""
from __future__ import annotations

import json
import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
SITO = ROOT / "sito"
SVG = ROOT / "docs" / "logo.svg"
S = 4096  # disegno grande, poi rimpicciolito (bordi morbidi)

NS = "{http://www.w3.org/2000/svg}"
BIANCO = (255, 255, 255)
RAGGIO = 0.225  # angoli delle tessere arrotondate, rispetto al lato
# icone piccole (16-64 px: Windows, area di notifica, favicon): logo più
# grande e centrato nella tessera, alto questa frazione del lato
ALTEZZA_PICCOLE = 0.84
# icona adattiva di Android: raggio del cerchio che contiene il logo, sul
# lato di 108 dp (zona sicura: cerchio di 66 dp, raggio 33)
RAGGIO_ADATTIVA = 32 / 108
# icone monocromatiche: distacco tra la fascia del cappello e la U (unità
# dell'SVG), così nella sagoma la curva della U resta visibile
STACCO = 20
DENS = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


# ---------------------------------------------------------------------------
# Lettura dell'SVG
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Sfumatura:
    """Sfumatura lineare in coordinate del riquadro della forma (0-1)."""
    x1: float
    y1: float
    x2: float
    y2: float
    tappe: tuple[tuple[float, tuple[int, int, int]], ...]

    def colore(self, t: float) -> tuple[int, int, int]:
        t = min(1.0, max(0.0, t))
        tappe = self.tappe
        if t <= tappe[0][0]:
            return tappe[0][1]
        for (o0, c0), (o1, c1) in zip(tappe, tappe[1:]):
            if t <= o1:
                f = (t - o0) / ((o1 - o0) or 1)
                return tuple(round(c0[i] + (c1[i] - c0[i]) * f) for i in range(3))
        return tappe[-1][1]


@dataclass(frozen=True)
class Forma:
    id: str
    contorni: tuple  # poligoni chiusi, in unità dell'SVG
    riempimento: object  # colore (r, g, b) o Sfumatura
    tratto: float = 0.0  # bordo dello stesso colore, giunzioni arrotondate
    ritaglio: tuple | None = None  # contorni della maschera di ritaglio


def _colore(hex_: str) -> tuple[int, int, int]:
    h = hex_.strip().lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _bezier(c: list[tuple[float, float]], n: int = 64) -> list[tuple[float, float]]:
    """Punti di una curva di Bézier (quadratica o cubica), senza il primo."""
    grado = len(c) - 1
    out = []
    for k in range(1, n + 1):
        t = k / n
        x = y = 0.0
        for j, (px, py) in enumerate(c):
            b = math.comb(grado, j) * (1 - t) ** (grado - j) * t ** j
            x += b * px
            y += b * py
        out.append((x, y))
    return out


def _arco(p0, rx, ry, phi, grande, verso, p1) -> list[tuple[float, float]]:
    """Arco ellittico dell'SVG (dagli estremi al centro, SVG 1.1 F.6.5),
    campionato a passi di mezzo grado, senza il primo punto."""
    (x1, y1), (x2, y2) = p0, p1
    if rx == 0 or ry == 0:
        return [p1]
    cp, sp = math.cos(math.radians(phi)), math.sin(math.radians(phi))
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if grande == verso:
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2

    def angolo(ux, uy, vx, vy):
        return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    t1 = angolo(1, 0, ux, uy)
    dt = angolo(ux, uy, vx, vy)
    if not verso and dt > 0:
        dt -= 2 * math.pi
    elif verso and dt < 0:
        dt += 2 * math.pi
    n = max(8, int(abs(math.degrees(dt)) * 2))
    out = []
    for k in range(1, n + 1):
        t = t1 + dt * k / n
        ex, ey = rx * math.cos(t), ry * math.sin(t)
        out.append((cx + ex * cp - ey * sp, cy + ex * sp + ey * cp))
    out[-1] = (x2, y2)
    return out


def _contorni(d: str) -> tuple:
    """Poligoni chiusi di un tracciato (comandi assoluti M L H V C Q A Z)."""
    tok = re.findall(r"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", d)
    i = 0
    cmd = ""
    cur = start = (0.0, 0.0)
    contorni: list[list[tuple[float, float]]] = []
    pts: list[tuple[float, float]] = []

    def num() -> float:
        nonlocal i
        v = float(tok[i])
        i += 1
        return v

    while i < len(tok):
        if tok[i].isalpha():
            cmd = tok[i]
            i += 1
            if cmd.islower():
                raise ValueError(f"comando relativo non gestito: {cmd}")
            if cmd == "Z":
                if pts:
                    contorni.append(pts)
                pts, cur = [], start
                continue
        if cmd == "M":
            if pts:
                contorni.append(pts)
            cur = start = (num(), num())
            pts = [cur]
            cmd = "L"  # coppie successive: linee
        elif cmd == "L":
            cur = (num(), num())
            pts.append(cur)
        elif cmd == "H":
            cur = (num(), cur[1])
            pts.append(cur)
        elif cmd == "V":
            cur = (cur[0], num())
            pts.append(cur)
        elif cmd == "C":
            c1, c2, p = (num(), num()), (num(), num()), (num(), num())
            pts += _bezier([cur, c1, c2, p])
            cur = p
        elif cmd == "Q":
            c1, p = (num(), num()), (num(), num())
            pts += _bezier([cur, c1, p])
            cur = p
        elif cmd == "A":
            rx, ry, phi, grande, verso = num(), num(), num(), num(), num()
            p = (num(), num())
            pts += _arco(cur, rx, ry, phi, int(grande), int(verso), p)
            cur = p
        else:
            raise ValueError(f"comando non gestito: {cmd}")
    if pts:
        contorni.append(pts)
    return tuple(tuple(c) for c in contorni)


@lru_cache(maxsize=1)
def leggi_logo() -> tuple[float, tuple[Forma, ...]]:
    """Lato del viewBox (quadrato) e forme del logo, nell'ordine dell'SVG."""
    root = ET.parse(SVG).getroot()
    vb = [float(v) for v in root.get("viewBox").replace(",", " ").split()]
    if vb[0] or vb[1] or vb[2] != vb[3]:
        raise ValueError("il viewBox del logo deve essere quadrato e partire da 0,0")
    sfumature: dict[str, Sfumatura] = {}
    for g in root.iter(NS + "linearGradient"):
        tappe = tuple((float(s.get("offset")), _colore(s.get("stop-color")))
                      for s in g.findall(NS + "stop"))
        sfumature[g.get("id")] = Sfumatura(
            float(g.get("x1", 0)), float(g.get("y1", 0)),
            float(g.get("x2", 1)), float(g.get("y2", 0)), tappe)
    ritagli = {c.get("id"): tuple(p for el in c.iter(NS + "path") for p in _contorni(el.get("d")))
               for c in root.iter(NS + "clipPath")}
    forme = []
    for el in root:  # solo i figli diretti: <defs> resta fuori
        tag = el.tag.replace(NS, "")
        if tag == "rect":
            x, y = float(el.get("x", 0)), float(el.get("y", 0))
            w, h = float(el.get("width")), float(el.get("height"))
            contorni = (((x, y), (x + w, y), (x + w, y + h), (x, y + h)),)
        elif tag == "path":
            contorni = _contorni(el.get("d"))
        else:
            continue
        fill = el.get("fill", "#000000")
        rif = re.fullmatch(r"url\(#(.+)\)", fill)
        riempimento = sfumature[rif.group(1)] if rif else _colore(fill)
        tratto = 0.0
        if el.get("stroke"):
            if el.get("stroke") != fill:
                raise ValueError("gestito solo il bordo dello stesso colore del riempimento")
            tratto = float(el.get("stroke-width", 1))
        clip = re.fullmatch(r"url\(#(.+)\)", el.get("clip-path", ""))
        forme.append(Forma(el.get("id", ""), contorni, riempimento, tratto,
                           ritagli[clip.group(1)] if clip else None))
    return vb[2], tuple(forme)


def _forma(id_: str) -> Forma:
    return next(f for f in leggi_logo()[1] if f.id == id_)


# ---------------------------------------------------------------------------
# Disegno
# ---------------------------------------------------------------------------

def _trasforma(lato: int, zoom: float, centro):
    """Da unità dell'SVG a pixel: [centro] (unità dell'SVG) va al centro
    dell'immagine; zoom 1 = tutto il viewBox nell'immagine."""
    vb = leggi_logo()[0]
    cx, cy = centro or (vb / 2, vb / 2)
    k = lato / vb * zoom
    return k, (lambda p: ((p[0] - cx) * k + lato / 2, (p[1] - cy) * k + lato / 2))


def _maschera(contorni, lato: int, tr, tratto_px: float = 0.0) -> Image.Image:
    m = Image.new("L", (lato, lato), 0)
    d = ImageDraw.Draw(m)
    for c in contorni:
        pts = [tr(p) for p in c]
        d.polygon(pts, fill=255)
        if tratto_px > 0:
            r = tratto_px / 2
            d.line(pts + [pts[0]], fill=255, width=max(1, round(tratto_px)))
            for x, y in pts:
                d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    return m


def _riempi(sf: Sfumatura, contorni, lato: int, tr) -> Image.Image:
    """Sfumatura lineare sull'immagine intera (riquadro della forma come
    riferimento, valori fuori dal riquadro estesi)."""
    pts = [tr(p) for c in contorni for p in c]
    x0, y0 = min(p[0] for p in pts), min(p[1] for p in pts)
    w = (max(p[0] for p in pts) - x0) or 1
    h = (max(p[1] for p in pts) - y0) or 1
    dx, dy = sf.x2 - sf.x1, sf.y2 - sf.y1
    den = (dx * dx + dy * dy) or 1
    n = 256  # una funzione lineare: basta una griglia piccola, poi ingrandita
    small = Image.new("RGB", (n, n))
    for j in range(n):
        v = ((j + 0.5) / n * lato - y0) / h
        for i in range(n):
            u = ((i + 0.5) / n * lato - x0) / w
            small.putpixel((i, j), sf.colore(((u - sf.x1) * dx + (v - sf.y1) * dy) / den))
    return small.resize((lato, lato), Image.BILINEAR)


def disegna(lato: int = S, zoom: float = 1.0, centro=None,
            senza: tuple[str, ...] = ("sfondo",)) -> Image.Image:
    """Il logo a colori su fondo trasparente (con senza=() anche il fondo
    bianco dell'SVG)."""
    k, tr = _trasforma(lato, zoom, centro)
    img = Image.new("RGBA", (lato, lato), (0, 0, 0, 0))
    for f in leggi_logo()[1]:
        if f.id in senza:
            continue
        m = _maschera(f.contorni, lato, tr, f.tratto * k)
        if f.ritaglio:
            m = ImageChops.multiply(m, _maschera(f.ritaglio, lato, tr))
        if isinstance(f.riempimento, Sfumatura):
            strato = _riempi(f.riempimento, f.contorni, lato, tr).convert("RGBA")
        else:
            strato = Image.new("RGBA", (lato, lato), f.riempimento + (255,))
        strato.putalpha(m)
        img = Image.alpha_composite(img, strato)
    return img


def sagoma(lato: int = S, zoom: float = 1.0, centro=None, nappa: bool = True) -> Image.Image:
    """Forma piena del logo, un solo colore (maschera L): per le icone
    monocromatiche. La fascia del cappello è staccata dalla U di STACCO
    unità, così la curva in alto della U resta visibile; [nappa] False
    toglie cordino e nappa (i dettagli più sottili)."""
    k, tr = _trasforma(lato, zoom, centro)
    lettera = _forma("lettera")
    m = Image.new("L", (lato, lato), 0)
    for f in leggi_logo()[1]:
        if f.id in ("sfondo", "ombreggiatura") or (not nappa and f.id in ("cordino", "nappa")):
            continue
        parte = _maschera(f.contorni, lato, tr, f.tratto * k)
        if f.id == "fascia":
            allargata = _maschera(lettera.contorni, lato, tr, 2 * STACCO * k)
            parte = ImageChops.subtract(parte, allargata)
        m = ImageChops.lighter(m, parte)
    return m


def _punti_logo() -> list[tuple[float, float, float]]:
    """Punti dei contorni del logo (senza il fondo) con il mezzo bordo."""
    punti = []
    for f in leggi_logo()[1]:
        if f.id in ("sfondo", "ombreggiatura"):
            continue
        punti += [(x, y, f.tratto / 2) for c in f.contorni for x, y in c]
    return punti


def riquadro_logo() -> tuple[float, float, float, float]:
    """Riquadro (x0, y0, x1, y1) del logo, in unità dell'SVG."""
    p = _punti_logo()
    return (min(x - r for x, _, r in p), min(y - r for _, y, r in p),
            max(x + r for x, _, r in p), max(y + r for _, y, r in p))


@lru_cache(maxsize=1)
def cerchio_logo() -> tuple[float, float, float]:
    """Centro e raggio (unità dell'SVG) del cerchio più piccolo che contiene
    il logo: serve a centrarlo nelle maschere rotonde (icona adattiva)."""
    punti = _punti_logo()

    def raggio(cx, cy):
        return max(math.hypot(x - cx, y - cy) + r for x, y, r in punti)

    cx = (min(p[0] for p in punti) + max(p[0] for p in punti)) / 2
    cy = (min(p[1] for p in punti) + max(p[1] for p in punti)) / 2
    best = raggio(cx, cy)
    passo = 32.0
    while passo > 0.25:  # discesa a passi che si dimezzano (funzione convessa)
        meglio = False
        for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            r = raggio(cx + ddx * passo, cy + ddy * passo)
            if r < best:
                cx, cy, best, meglio = cx + ddx * passo, cy + ddy * passo, r, True
        if not meglio:
            passo /= 2
    return cx, cy, best


def posizione_adattiva() -> tuple[tuple[float, float], float]:
    """Centro e zoom del logo nell'icona adattiva di Android."""
    cx, cy, r = cerchio_logo()
    return (cx, cy), RAGGIO_ADATTIVA * leggi_logo()[0] / r


def _arrotonda(img: Image.Image, raggio: float = RAGGIO, margine: float = 0.0) -> Image.Image:
    size = img.width
    m = int(size * margine)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (m, m, size - m - 1, size - m - 1), radius=int((size - 2 * m) * raggio), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def tessera(lato: int = S, piccola: bool = False) -> Image.Image:
    """Il logo su un quadrato bianco con gli angoli arrotondati (fondo
    trasparente fuori). Come nell'SVG approvato o, per le icone [piccola],
    centrato e alto ALTEZZA_PICCOLE del lato."""
    zoom, centro = 1.0, None
    if piccola:
        x0, y0, x1, y1 = riquadro_logo()
        zoom = ALTEZZA_PICCOLE * leggi_logo()[0] / (y1 - y0)
        centro = ((x0 + x1) / 2, (y0 + y1) / 2)
    base = Image.new("RGBA", (lato, lato), BIANCO + (255,))
    return _arrotonda(Image.alpha_composite(base, disegna(lato, zoom, centro)))


def icona_piena() -> Image.Image:
    """Quadrato bianco pieno come nell'SVG (iOS lo arrotonda da sé)."""
    return disegna(S, senza=())


def icona_mac() -> Image.Image:
    """Modello delle icone di macOS: tessera di 824 su 1024 con 100 di
    margine e un'ombra leggera sotto (sul bianco dei Finder resta visibile)."""
    m = round(S * 100 / 1024)
    interno = S - 2 * m
    t = tessera(interno)
    ombra = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    nero = Image.new("RGBA", (interno, interno), (0, 0, 0, 255))
    nero.putalpha(t.getchannel("A").point(lambda v: int(v * 0.30)))
    ombra.paste(nero, (m, m + round(S * 0.010)))
    ombra = ombra.filter(ImageFilter.GaussianBlur(S * 0.012))
    ombra.alpha_composite(t, (m, m))
    return ombra


def _salva(img: Image.Image, path: Path, px: int, rgb: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = img.resize((px, px), Image.LANCZOS)
    if rgb:
        out = out.convert("RGB")
    out.save(path, optimize=True)


def _bianca(alpha: Image.Image) -> Image.Image:
    out = Image.new("RGBA", alpha.size, (255, 255, 255, 255))
    out.putalpha(alpha)
    return out


def icona_notifica(px: int) -> Image.Image:
    """Icona piccola delle notifiche Android: sagoma bianca della U e del
    cappello (Android usa solo la trasparenza e la colora da sé), centrata
    con un margine di 2 dp su 24."""
    alpha = sagoma(S)
    forma = alpha.crop(alpha.getbbox())
    lato = max(forma.size)
    quadro = Image.new("L", (lato, lato), 0)
    quadro.paste(forma, ((lato - forma.width) // 2, (lato - forma.height) // 2))
    interno = round(px * 20 / 24)
    quadro = quadro.resize((interno, interno), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (255, 255, 255, 0))
    m = (px - interno) // 2
    out.paste(_bianca(quadro), (m, m))
    return out


def icone_notifica() -> None:
    res = APP / "android/app/src/main/res"
    for k, f in DENS.items():
        px = round(24 * f)
        path = res / f"drawable-{k}/ic_stat_uninotes.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        icona_notifica(px).save(path, optimize=True)


def _ico(img: Image.Image, path: Path) -> None:
    """File .ico con ogni dimensione rimpicciolita dal disegno grande."""
    sizes = [16, 24, 32, 48, 64, 128, 256]
    imgs = [img.resize((s, s), Image.LANCZOS) for s in sizes]
    imgs[-1].save(path, sizes=[(s, s) for s in sizes], append_images=imgs[:-1])


def main() -> None:
    ufficiale = tessera()  # come l'SVG approvato: icone grandi e anteprime
    piccola = tessera(piccola=True)  # icone di 16-64 px
    _salva(ufficiale, ROOT / "docs" / "icona.png", 1024)
    _salva(ufficiale, SITO / "icona.png", 256)
    _salva(piccola, SITO / "favicon.png", 64)

    # Android: icona classica, adattiva (fondo bianco + logo nella zona
    # sicura) e monocromatica (icone a tema di Android 13)
    res = APP / "android/app/src/main/res"
    centro, zoom = posizione_adattiva()
    fg = disegna(S, zoom, centro)
    mono = _bianca(sagoma(S, zoom, centro))
    bgc = Image.new("RGB", (S, S), BIANCO)
    for k, f in DENS.items():
        _salva(ufficiale, res / f"mipmap-{k}/ic_launcher.png", round(48 * f))
        _salva(fg, res / f"mipmap-{k}/ic_launcher_foreground.png", round(108 * f))
        _salva(bgc, res / f"mipmap-{k}/ic_launcher_background.png", round(108 * f))
        _salva(mono, res / f"mipmap-{k}/ic_launcher_monochrome.png", round(108 * f))
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n', encoding="utf-8", newline="\n")

    # iOS: dimensioni dal Contents.json, senza trasparenza
    piena = icona_piena()
    ios = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for im in json.loads((ios / "Contents.json").read_text(encoding="utf-8"))["images"]:
        px = round(float(im["size"].split("x")[0]) * int(im["scale"][0]))
        _salva(piena, ios / im["filename"], px, rgb=True)

    # macOS: forma arrotondata con margine e ombra (modello di Apple)
    mac_img = icona_mac()
    mac = APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        _salva(mac_img, mac / f"app_icon_{px}.png", px)

    # Windows e area di notifica
    _ico(piccola, APP / "windows/runner/resources/app_icon.ico")
    _ico(piccola, APP / "assets/tray/app_icon.ico")
    _salva(piccola, APP / "assets/tray/app_icon.png", 64)
    icone_notifica()
    print("icone scritte")


if __name__ == "__main__":
    import sys
    if "--notifiche" in sys.argv[1:]:
        icone_notifica()
        print("icone delle notifiche scritte")
    else:
        main()
