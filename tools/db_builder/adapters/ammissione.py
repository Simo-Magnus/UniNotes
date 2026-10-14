"""Requisiti di accesso di un corso di studio (OFA, test d'ingresso, livello d'inglese).

Il testo è quello pubblicato dall'ateneo (quadro A3 della SUA-CdS, "Conoscenze richieste per
l'accesso" e modalità di verifica, ripreso dal Course Catalogue Cineca o dalla pagina del corso):
si conserva com'è in `requisiti`; gli altri campi sono solo ciò che il testo dice esplicitamente.

- `test`: prove citate (TOLC-I, TOLC-E, …, CEnT-S, English TOLC);
- `ofa`: true se il testo prevede OFA / obblighi formativi aggiuntivi / debiti formativi, false se
  dice che non sono previsti, null se non ne parla;
- `livello_inglese`: livello QCER richiesto per l'inglese, se il testo lo indica.
"""
from __future__ import annotations

import html
import re
import time

TEST = re.compile(r"\b(English\s+TOLC(?:-[A-Z]+)?|TOLC[\s@-]*(?:CASA\s*[-–]?\s*)?(?:-?\s*(?:AV|SU|PSI|LP|MED|[IESFB]))?"
                  r"|CEnT-S|TIL-?[IE]?)\b")
OFA = re.compile(r"(?i)\bOFA\b|obblighi\s+formativi\s+aggiuntivi|debit[oi]\s+formativ[oi]")
NO_OFA = re.compile(r"(?i)non\s+(?:sono\s+|vengono\s+)?(?:previsti|attribuiti|assegnati)\s+(?:gli\s+)?"
                    r"(?:OFA|obblighi\s+formativi)")
INGLESE = re.compile(r"(?i)ingles[ei][^.;]{0,140}?\b(A2|B1|B2|C1|C2)\b|\b(A2|B1|B2|C1|C2)\b[^.;]{0,80}?ingles[ei]")


def _pulisci(t: str) -> str:
    t = html.unescape(re.sub(r"<[^>]+>", " ", t or "")).replace("‑", "-").replace("‐", "-")
    return re.sub(r"[ \t\r\f\v]+", " ", re.sub(r"\s*\n\s*", "\n", t)).strip()


def _test(nome: str) -> str:
    n = re.sub(r"\s+", " ", nome.upper()).replace("@", " ")
    if n.startswith("ENGLISH"):
        return "English TOLC" + ("-" + n.split("-")[-1] if "-" in n else "")
    m = re.match(r"TOLC\s*(?:CASA\s*[-–]?\s*)?-?\s*([A-Z]+)?", n)
    if m:
        return "TOLC" + (f"-{m.group(1)}" if m.group(1) and m.group(1) != "CASA" else "")
    return nome.strip()


def da_testo(testo: str, accesso: str | None = None, fonte: str | None = None) -> dict | None:
    testo = _pulisci(testo)
    if not testo and not accesso:
        return None
    test = list(dict.fromkeys(_test(m.group(1)) for m in TEST.finditer(testo)))
    if any(t.startswith("TOLC-") for t in test):
        test = [t for t in test if t != "TOLC"]  # "il TOLC (TOLC-I)": basta la variante
    ofa = False if NO_OFA.search(testo) else (True if OFA.search(testo) else None)
    ing = INGLESE.search(testo)
    return {"accesso": accesso, "requisiti": testo[:4000] or None, "test": test,
            "ofa": ofa, "livello_inglese": (ing.group(1) or ing.group(2)).upper() if ing else None,
            "fonte": fonte, "verificato_il": time.strftime("%Y-%m-%d")}


def da_catalogo(d: dict, fonte: str | None = None) -> dict | None:
    """Dal dettaglio di un corso del Course Catalogue Cineca (`/api/v1/corso/<coorte>/<cod>`)."""
    req = d.get("requisiti_it") or {}
    parti = []
    for k in ("conoscenze", "modalita", "obbligatori", "optional"):
        for x in req.get(k) or []:
            if isinstance(x, dict):
                parti.append(x.get("tipoTitDes") or x.get("des_it") or x.get("testo") or "")
            elif isinstance(x, str):
                parti.append(x)
    acc = (d.get("accesso_it") or "").strip().lower() or None
    if acc:
        acc = "libero" if acc.startswith("libero") else ("programmato" if "programmat" in acc else acc)
    return da_testo("\n".join(p for p in parti if p), acc, fonte)
