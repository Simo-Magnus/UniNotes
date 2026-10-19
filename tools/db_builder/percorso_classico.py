"""Percorso classico di un corso di laurea con più percorsi.

Il percorso classico è quello che segue la maggior parte degli studenti: il
piano «normale», senza percorsi speciali. Gli atenei non pubblicano quanti
studenti seguono ogni percorso, quindi la scelta segue regole dichiarate
(campo `criterio`), mai inventate:

1. `nome`: un percorso ha un nome da piano ordinario («Percorso»,
   «Generale», «Statutario», «Piano di studi statutario 2026», «Standard»,
   «Ordinario», «Tradizionale»…). Con più piani per anno si prende quello
   dell'anno più recente.
2. `unico_ordinario`: tolti i percorsi speciali (per pochi studenti o
   alternativi: eccellenza, «Grow Your Talents», «INTRAPRENDENTI», doppio
   titolo, part-time, in lingua inglese, online, sedi diverse da quella del
   corso, percorsi da 30/60 CFU per l'insegnamento…) ne resta uno solo.
3. `piu_insegnamenti`: altrimenti (percorsi tematici come «Management» e
   «Marketing») quello con più insegnamenti, come fa già l'app.

Le regole leggono i percorsi come l'app (app/lib/core/catalog/curricula.dart):
campo `curriculum` degli insegnamenti, elenco separato da virgole fuori dalle
parentesi, esclusi i nomi comuni a tutti.
"""
from __future__ import annotations

import re
from collections import Counter

_COMUNE = re.compile(r"\b(comune|non diversificato|generico|unico|common)\b", re.I)

# nomi da piano ordinario (tutto il nome, con un eventuale anno o coorte)
_ORDINARIO = re.compile(
    r"^(percorso|curriculum|piano( di studi?)?)?\s*"
    r"(generale|statutario|standard|ordinario|tradizionale|base|normale|regolare)?\s*"
    r"(\d{4}(\s*[/-]\s*\d{2,4})?)?$",
    re.I,
)

# percorsi speciali o alternativi (pochi studenti, requisiti o sedi diverse)
_SPECIALE = re.compile(
    r"eccellenza|honou?rs?|talent|intraprendent|doppio titolo|double degree|"
    r"titolo congiunto|joint degree|part[- ]?time|tempo parziale|"
    r"lingua inglese|in inglese|in english|taught in english|english[- ]taught|"
    r"international track|\d+\s*cfu|\ball(egato)?\.?\s*\d|abilitazione|"
    r"erasmus|telematic|\bonline\b|a distanza|studenti? atlet|lavorator",
    re.I,
)

# sede distaccata: «sede» (o «primo anno a/sede di») con una città diversa da
# quella del corso
_SEDE = re.compile(r"\bsede\b|primo anno a\b", re.I)


_VALIDO_ANCHE = re.compile(r"[(\[][^)\]]*valido anche[^)\]]*[)\]]", re.I)


def _speciale(nome: str, sede: str | None) -> bool:
    # «(percorso valido anche per il doppio titolo…)»: percorso ordinario
    nome = _VALIDO_ANCHE.sub("", nome)
    if _SPECIALE.search(nome):
        return True
    if _SEDE.search(nome):
        # sede del corso non nota: non si può dire che sia distaccata
        s = (sede or "").strip().lower()
        return bool(s) and s not in nome.lower()
    return False


_ANNO = re.compile(r"(\d{4})")


def percorsi_di(curriculum: str | None) -> list[str]:
    s = (curriculum or "").strip()
    if not s:
        return []
    out, depth, start = [], 0, 0
    for i, ch in enumerate(s):
        if ch == "(":
            depth += 1
        elif ch == ")" and depth > 0:
            depth -= 1
        elif ch == "," and depth == 0:
            part = s[start:i].strip()
            if part:
                out.append(part)
            start = i + 1
    last = s[start:].strip()
    if last:
        out.append(last)
    return out


def conteggi(corso: dict) -> Counter:
    """Percorso → numero di insegnamenti (come PercorsiCorso.di nell'app)."""
    n: Counter = Counter()
    for ins in corso.get("insegnamenti") or []:
        if not isinstance(ins, dict):
            continue
        for p in dict.fromkeys(percorsi_di(ins.get("curriculum"))):
            if not _COMUNE.search(p):
                n[p] += 1
    return n


def _ordine(n: Counter) -> list[str]:
    return sorted(n, key=lambda p: (-n[p], p))


def _anno(nome: str) -> int:
    m = _ANNO.findall(nome)
    return int(m[-1]) if m else 0


def scegli(corso: dict) -> dict | None:
    """`{"nome": …, "criterio": …}` per un corso con più percorsi, o None."""
    n = conteggi(corso)
    if len(n) < 2:
        return None
    nomi = _ordine(n)
    sede = corso.get("sede") if isinstance(corso.get("sede"), str) else None
    ordinari = [p for p in nomi if _ORDINARIO.match(p.strip()) and not _speciale(p, sede)]
    if ordinari:
        # statutario prima degli altri, poi l'anno più recente, poi più insegnamenti
        ordinari.sort(key=lambda p: (not re.search(r"statutari", p, re.I), -_anno(p), -n[p], p))
        return {"nome": ordinari[0], "criterio": "nome"}
    normali = [p for p in nomi if not _speciale(p, sede)]
    if len(normali) == 1:
        return {"nome": normali[0], "criterio": "unico_ordinario"}
    return {"nome": (normali or nomi)[0], "criterio": "piu_insegnamenti"}
