"""Pagine web dell'informativa privacy e dei termini per il sito (GitHub Pages).

    python tools/pagine_legali.py

Legge PRIVACY.md e TERMINI.md e scrive sito/privacy.html e sito/termini.html
(stesso stile scuro della pagina di download). Va rilanciato quando cambiano i
due testi.
"""
import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PAGINA = """<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{titolo} · UniNotes</title>
<link rel="icon" href="favicon.png">
<style>
  :root {{ --bg: #02060f; --card: #0a1628; --text: #dcebf7; --muted: #9db4c8; --c2: #38BDF8; --line: #16304a; }}
  html {{ background: var(--bg); -webkit-text-size-adjust: 100%; }}
  body {{ margin: 0; background: var(--bg); color: var(--text);
         font: 16px/1.6 "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif; }}
  main {{ max-width: 860px; margin: 0 auto; padding: 32px 16px 64px; }}
  a {{ color: var(--c2); }}
  h1 {{ font-size: 1.9rem; line-height: 1.25; margin: 0 0 8px; }}
  h2 {{ font-size: 1.35rem; margin: 36px 0 8px; padding-top: 12px; border-top: 1px solid var(--line); }}
  h3 {{ font-size: 1.1rem; margin: 24px 0 6px; }}
  h4 {{ font-size: 1rem; margin: 18px 0 4px; }}
  code {{ background: var(--card); padding: 1px 5px; border-radius: 4px; font-size: .92em; overflow-wrap: anywhere; }}
  ul, ol {{ padding-left: 22px; }}
  li {{ margin: 4px 0; }}
  table {{ border-collapse: collapse; width: 100%; display: block; overflow-x: auto; }}
  th, td {{ border: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }}
  .torna {{ display: inline-block; margin-bottom: 20px; color: var(--muted); text-decoration: none; }}
</style>
<script data-goatcounter="https://uninotes.goatcounter.com/count"
        async src="//gc.zgo.at/count.js"></script>
</head>
<body>
<main>
<a class="torna" href="./">← UniNotes</a>
{corpo}
</main>
</body>
</html>
"""


def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', t)
    t = re.sub(r"&lt;(https?://[^\s&]+)&gt;", r'<a href="\1">\1</a>', t)
    t = t.replace('href="PRIVACY.md', 'href="privacy.html').replace('href="TERMINI.md', 'href="termini.html')
    t = t.replace('href="LICENSE"', 'href="https://github.com/Simo-Magnus/UniNotes/blob/main/LICENSE"')
    return t


def converti(md):
    md = re.sub(r"<!--.*?-->", "", md, flags=re.S)
    out, para, lista, tabella = [], [], None, []

    def chiudi():
        nonlocal para, lista, tabella
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para = []
        if lista:
            out.append(f"</{lista}>")
            lista = None
        if tabella:
            righe = [r for r in tabella if not re.fullmatch(r"\|[\s:|-]+\|", r)]
            celle = [[c.strip() for c in r.strip("|").split("|")] for r in righe]
            out.append("<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in celle[0]) + "</tr></thead><tbody>")
            out.extend(["<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in celle[1:]])
            out.append("</tbody></table>")
            tabella = []

    for riga in md.splitlines():
        s = riga.rstrip()
        if not s.strip():
            chiudi()
            continue
        if s.startswith("|"):
            if para or lista:
                chiudi()
            tabella.append(s)
            continue
        m = re.match(r"(#{1,4})\s+(.*)", s)
        if m:
            chiudi()
            n = len(m.group(1))
            ident = re.sub(r"[^a-z0-9]+", "-", m.group(2).lower()).strip("-")
            out.append(f'<h{n} id="{ident}">{inline(m.group(2))}</h{n}>')
            continue
        m = re.match(r"\s*([-*]|\d+\.)\s+(.*)", s)
        if m:
            tipo = "ol" if m.group(1)[0].isdigit() else "ul"
            if para:
                out.append("<p>" + inline(" ".join(para)) + "</p>")
                para = []
            if lista != tipo:
                if lista:
                    out.append(f"</{lista}>")
                out.append(f"<{tipo}>")
                lista = tipo
            out.append("<li>" + inline(m.group(2)) + "</li>")
            continue
        if lista and riga.startswith("  "):
            out[-1] = out[-1][:-5] + " " + inline(s.strip()) + "</li>"
            continue
        if lista:
            out.append(f"</{lista}>")
            lista = None
        para.append(s.strip())
    chiudi()
    return "\n".join(out)


def main():
    for src, dst, titolo in (("PRIVACY.md", "privacy.html", "Informativa sulla privacy"),
                             ("TERMINI.md", "termini.html", "Termini di utilizzo")):
        corpo = converti((ROOT / src).read_text(encoding="utf-8"))
        (ROOT / "sito" / dst).write_text(PAGINA.format(titolo=titolo, corpo=corpo), encoding="utf-8")
        print("scritto sito/" + dst)


if __name__ == "__main__":
    main()
