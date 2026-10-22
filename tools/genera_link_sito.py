"""Pagina dei link (tipo Linktree) e link corti del sito GitHub Pages, senza servizi esterni.

- sito/link/index.html: pagina aggregatore con il download, la community, i social, il sostegno e i contatti;
- sito/go/<nome>/index.html: link corti che portano a una destinazione (si cambia qui in un punto solo, i link
  già pubblicati o stampati restano validi);
- sito/<social>/index.html: un link per ogni bio (es. /ig/ per Instagram), che porta alla pagina aggregatore con
  ?s=<social>; quando l'app sarà negli store, la pagina aggiungerà la fonte ai link degli store (console degli
  store: installazioni per fonte), senza contare nulla nel sito.

Statistiche: GoatCounter (senza cookie, nessun dato personale salvato). La pagina aggregatore conta le visite con
lo script ufficiale (il percorso include ?s=<sigla>, quindi si vede da quale bio arriva la gente); ogni link corto
conta se stesso con una richiesta all'endpoint e poi porta alla destinazione, così le visite a /go/<nome>/ sono i
clic verso quella destinazione. I link della pagina aggregatore si aprono in una nuova scheda. Uso, dalla radice del
repository:
    python tools/genera_link_sito.py
"""
from __future__ import annotations

import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SITO = ROOT / "sito"
ICONE = ROOT / "tools" / "icone_social"
BASE = "https://simo-magnus.github.io/UniNotes/"
GOATCOUNTER = "https://uninotes.goatcounter.com/count"
NUOVA = 'target="_blank" rel="noopener"'  # nuova scheda; il referrer resta, per sapere da dove arriva il clic

# link corti: /go/<nome>/ → destinazione
GO = {
    "download": BASE,
    "discord": "https://discord.gg/UccnEZ2mzz",
    "telegram": "https://t.me/uninotes_community",
    "telegram-canale": "https://t.me/uninotes_app",
    "telegram-atenei": "https://t.me/uninotes_atenei",
    "whatsapp": "https://whatsapp.com/channel/0029VbDunIXGehETlRnd6t1E",
    "reddit": "https://www.reddit.com/r/UniNotes",
    "instagram": "https://www.instagram.com/uninotes_app/",
    "tiktok": "https://www.tiktok.com/@uninotes_app",
    "threads": "https://www.threads.com/@uninotes_app",
    "x": "https://x.com/UniNotes_app",
    "facebook": "https://www.facebook.com/UniNotes",
    "github": "https://github.com/Simo-Magnus/UniNotes",
    "sostieni": BASE + "sostieni.html",
}

# un link per ogni bio o descrizione: /<sigla>/ → pagina aggregatore con ?s=<sigla>
FONTI = {
    "ig": "Instagram", "tt": "TikTok", "th": "Threads", "x": "X", "fb": "Facebook",
    "yt": "YouTube", "tg": "Telegram", "dc": "Discord", "rd": "Reddit", "wa": "WhatsApp",
}

# pulsanti della pagina aggregatore: (sezione, testo, descrizione, link corto, icona)
PULSANTI = [
    ("Community", "Server Discord", "Aule studio, spazi per regione, fuorisede, Erasmus, svago", "discord", "discord"),
    ("Community", "Gruppo Telegram", "Assistenza, idee, studio e vita universitaria", "telegram", "telegram"),
    ("Community", "Il tuo ateneo su Telegram", "Un argomento per ogni regione", "telegram-atenei", "telegram"),
    ("Community", "r/UniNotes su Reddit", "Domande e discussioni aperte a tutti", "reddit", "reddit"),
    ("Novità", "Canale Telegram", "Nuove versioni e aggiornamenti dei dati", "telegram-canale", "telegram"),
    ("Novità", "Canale WhatsApp", "Le stesse novità su WhatsApp", "whatsapp", "whatsapp"),
]
SOCIAL = [("Instagram", "instagram"), ("TikTok", "tiktok"), ("Threads", "threads"), ("X", "x"),
          ("Facebook", "facebook")]
CONTATTI = [
    ("Assistenza", "uninotes-supporto@googlegroups.com"),
    ("Stampa", "uninotes-stampa.stir677@passinbox.com"),
    ("Aziende ed enti", "uninotes-partner.stem084@passinbox.com"),
]


def icona(nome: str) -> str:
    """Tracciato dell'icona (Simple Icons, CC0) come SVG in linea, colore del testo."""
    s = (ICONE / f"{nome}.svg").read_text(encoding="utf-8")
    d = re.search(r'<path d="([^"]+)"', s).group(1)
    return f'<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="{d}"/></svg>'


def reindirizzo(dest: str, titolo: str, conta: bool = False) -> str:
    """Pagina che porta subito a [dest] (anche senza JavaScript), con il link di riserva.

    Con [conta] la visita si registra su GoatCounter prima di partire (sendBeacon arriva anche se la pagina se ne va
    subito); senza JavaScript, con un blocco dei tracciatori o con il conteggio spento (#toggle-goatcounter) si va
    alla destinazione senza contare."""
    d = html.escape(dest, quote=True)
    if conta:
        script = f"""<script>
(function () {{
  try {{
    if (navigator.sendBeacon && !navigator.webdriver && localStorage.getItem('skipgc') !== 't') {{
      var e = encodeURIComponent;
      navigator.sendBeacon('{GOATCOUNTER}?p=' + e(location.pathname) + '&t=' + e(document.title) +
        '&r=' + e(document.referrer) + '&s=' + screen.width + '&rnd=' + Math.random().toString(36).slice(2, 7));
    }}
  }} catch (err) {{}}
  location.replace({json.dumps(dest)});
}})();
</script>
<noscript><meta http-equiv="refresh" content="0; url={d}"></noscript>"""
    else:
        script = f'<meta http-equiv="refresh" content="0; url={d}">'
    return f"""<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{html.escape(titolo)} · UniNotes</title>
{script}
<link rel="canonical" href="{d}">
<style>body{{margin:0;background:#02060f;color:#dcebf7;font:16px/1.6 system-ui,sans-serif;display:grid;place-items:center;min-height:100vh}}a{{color:#38BDF8}}</style>
</head>
<body><p>Apertura di <a href="{d}">{html.escape(titolo)}</a>…</p></body>
</html>
"""


def aggregatore() -> str:
    sezioni: dict[str, list[str]] = {}
    for sez, testo, desc, go, ic in PULSANTI:
        sezioni.setdefault(sez, []).append(
            f'<a class="voce" href="../go/{go}/" {NUOVA}>{icona(ic)}<span><b>{html.escape(testo)}</b>'
            f'<small>{html.escape(desc)}</small></span></a>')
    blocchi = "\n".join(
        f'<section aria-label="{html.escape(s)}"><h2>{html.escape(s)}</h2>\n' + "\n".join(v) + "\n</section>"
        for s, v in sezioni.items())
    social = "\n".join(
        f'<a href="../go/{go}/" {NUOVA} aria-label="UniNotes su {html.escape(n)}" title="{html.escape(n)}">'
        f'{icona(go)}</a>'
        for n, go in SOCIAL)
    contatti = "\n".join(
        f'<div><dt>{html.escape(e)}</dt><dd><a href="mailto:{m}">{m}</a></dd></div>' for e, m in CONTATTI)
    return f"""<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>UniNotes · Link</title>
<meta name="description" content="UniNotes, l'app gratuita per organizzare l'università: download, community su Discord, Telegram, WhatsApp e Reddit, social e contatti.">
<link rel="icon" type="image/png" href="../favicon.png">
<link rel="apple-touch-icon" href="../apple-touch-icon.png">
<meta property="og:title" content="UniNotes · Link">
<meta property="og:description" content="Download, community e social di UniNotes, l'app gratuita per organizzare l'università.">
<meta property="og:image" content="{BASE}anteprima.png">
<meta property="og:url" content="{BASE}link/">
<script data-goatcounter="{GOATCOUNTER}"
        async src="//gc.zgo.at/count.js"></script>
<style>
  :root {{ --bg: #02060f; --card: rgba(255,255,255,.05); --line: rgba(255,255,255,.10); --text: #F3F7FB;
          --text2: rgba(235,245,255,.75); --muted: #8FA9C4; --blu: #1784FB; }}
  html {{ background: var(--bg); -webkit-text-size-adjust: 100%; }}
  body {{ margin: 0; color: var(--text); font: 16px/1.5 "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
         background: radial-gradient(120% 60% at 50% 0%, rgba(23,132,251,.28), transparent 60%), var(--bg); min-height: 100vh; }}
  main {{ max-width: 520px; margin: 0 auto; padding: 32px 16px 48px; }}
  header {{ text-align: center; margin-bottom: 24px; }}
  header img {{ width: 88px; height: 88px; border-radius: 22px; box-shadow: 0 8px 28px rgba(0,0,0,.45); }}
  h1 {{ font-size: 1.6rem; margin: 12px 0 4px; }}
  header p {{ margin: 0; color: var(--text2); }}
  .scarica {{ display: flex; align-items: center; justify-content: center; min-height: 52px; margin: 20px 0 8px;
             border-radius: 26px; background: linear-gradient(180deg, #FFB064 0%, #FF8A1F 52%, #E86F08 100%);
             color: #2a1300; font-weight: 700; font-size: 1.05rem; text-decoration: none; }}
  .scarica:focus-visible, .voce:focus-visible, .social a:focus-visible {{ outline: 3px solid #7DD3FC; outline-offset: 3px; }}
  .sotto {{ text-align: center; color: var(--muted); font-size: .9rem; margin: 0 0 8px; }}
  h2 {{ font-size: .8rem; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 28px 0 10px; }}
  .voce {{ display: flex; align-items: center; gap: 14px; min-height: 56px; padding: 10px 16px; margin-bottom: 10px;
          background: var(--card); border: 1px solid var(--line); border-radius: 16px; color: var(--text); text-decoration: none; }}
  .voce:hover {{ border-color: rgba(125,211,252,.55); }}
  .voce svg {{ width: 26px; height: 26px; fill: currentColor; flex: none; color: #CFE6FF; }}
  .voce span {{ display: flex; flex-direction: column; }}
  .voce small {{ color: var(--text2); font-size: .88rem; }}
  .social {{ display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; }}
  .social a {{ width: 48px; height: 48px; display: grid; place-items: center; border-radius: 50%;
              background: var(--card); border: 1px solid var(--line); color: #CFE6FF; }}
  .social a:hover {{ border-color: rgba(125,211,252,.55); }}
  .social svg {{ width: 22px; height: 22px; fill: currentColor; }}
  .altri {{ display: flex; flex-wrap: wrap; justify-content: center; gap: 8px 20px; }}
  .altri a {{ color: var(--text2); min-height: 32px; display: inline-flex; align-items: center; gap: 8px; }}
  .altri svg {{ width: 18px; height: 18px; fill: currentColor; }}
  footer {{ margin-top: 32px; padding-top: 20px; border-top: 1px solid var(--line); color: var(--muted); font-size: 13px;
           text-align: center; display: grid; gap: 12px; }}
  footer a {{ color: var(--text2); }}
  dl {{ margin: 0; display: grid; gap: 6px; }}
  dl div {{ display: flex; flex-wrap: wrap; justify-content: center; gap: 2px 8px; }}
  dt {{ font-weight: 600; color: var(--text2); }} dt::after {{ content: ":"; }}
  dd {{ margin: 0; overflow-wrap: anywhere; }}
</style>
</head>
<body>
<main>
<header>
  <img src="../icona.png" alt="Logo di UniNotes" width="88" height="88">
  <h1>UniNotes</h1>
  <p>L'app gratuita per organizzare l'università</p>
</header>
<a class="scarica" href="../go/download/" {NUOVA}>Scarica l'app</a>
<p class="sotto">Windows, macOS, Android e iPhone · senza account e senza pubblicità</p>
{blocchi}
<section aria-label="Social"><h2>Social</h2>
<nav class="social">
{social}
</nav>
</section>
<section aria-label="Progetto"><h2>Progetto</h2>
<nav class="altri">
<a href="../go/sostieni/" {NUOVA}>{icona("kofi")}Sostieni il progetto</a>
<a href="../go/github/" {NUOVA}>{icona("github")}Codice su GitHub</a>
</nav>
</section>
<footer>
<dl>
{contatti}
</dl>
<p>Visite e clic contati in forma anonima con GoatCounter, senza cookie
(<a href="../privacy.html#10-3-statistiche-della-pagina-dei-link" {NUOVA}>informativa sulla privacy</a>).<br>
UniNotes è sviluppata in modo indipendente e non è collegata a nessuna università.</p>
</footer>
</main>
</body>
</html>
"""


def scrivi(rel: str, testo: str) -> None:
    p = SITO / rel / "index.html"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(testo, encoding="utf-8", newline="\n")


def main() -> None:
    scrivi("link", aggregatore())
    for nome, dest in GO.items():
        scrivi(f"go/{nome}", reindirizzo(dest, nome.replace("-", " ").capitalize(), conta=True))
    for sigla, nome in FONTI.items():
        scrivi(sigla, reindirizzo(f"{BASE}link/?s={sigla}", f"UniNotes · {nome}"))
    print(f"scritte: link/, {len(GO)} link corti in go/, {len(FONTI)} link per le bio")


if __name__ == "__main__":
    main()
