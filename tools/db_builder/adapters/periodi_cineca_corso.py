"""Periodo didattico degli insegnamenti dal Course Catalogue Cineca, scheda per scheda dello STESSO corso di studio.

Come `periodi_cineca_sem` (piani delle coorti con `frazioni`/`moduli`, poi il syllabus), ma l'abbinamento
dell'insegnamento mancante alle schede del catalogo è più rigido: nel catalogo il codice della scheda
(`/insegnamenti/<aa>/<cod>/…`) è condiviso da più corsi di studio (stesso insegnamento offerto in più corsi),
quindi il corso di studio del catalogo si ricava per voto dalle schede di TUTTI gli insegnamenti del corso del
database (stesso `aa`, `cod`, ordinamento, percorso e stesso codice AD), non dalla singola scheda.

Ordine di ricerca per un insegnamento mancante:
 1. le schede dello stesso corso di studio e dello stesso codice AD (a.a. più recente che riporta il periodo,
    scheda del piano o syllabus); se in quell'a.a. le schede sono discordi: lacuna;
 2. se il corso non ha altre schede con periodo: lo stesso codice AD, nello stesso a.a. di offerta, in altri corsi
    dell'ateneo (stesso insegnamento condiviso), solo se tutte le schede concordano.
Il periodo non si deduce mai dall'anno di corso, dal codice o dal nome. Le date di un altro a.a. non si copiano
(resta il semestre che ne ricava pulizia.periodo). `fonte` è la pagina del catalogo che lo dice.
"""
from __future__ import annotations

import os
import re
from collections import Counter, defaultdict

from . import periodi, periodi_cineca_sem as sem

URL = re.compile(r"/insegnamenti/(\d{4})/([^/]+)/(\d+)/([^/?]+)\?coorte=(\d{4})")


def _chiave(e: dict, base_aa=None) -> tuple:
    a = e["att"]
    return (str(a.get("aa")), str(a.get("cod")), str(a.get("ordinamento_aa")), str(a.get("corso_percorso_id")))


def fetch(uid: str, base: str, anno: int = 2026, anni=None, log=print, usa_syllabus: bool | None = None,
          rate: float = 1.6) -> tuple[dict, dict]:
    """({id_insegnamento: {periodo…, fonte}}, {id: motivo della lacuna})."""
    if usa_syllabus is None:
        usa_syllabus = os.environ.get("SEMESTRI_SYLLABUS", "1") == "1"
    db = periodi.carica(uid)
    manc = periodi.mancanti(uid)
    c = sem.Cache(uid, base, rate)
    log(f"[{uid}] {len(manc)} insegnamenti senza periodo; lettura dei piani delle coorti")
    idx = sem.indice(c, anni or range(anno - 8, anno + 1), log)
    per_ad: dict[str, list[dict]] = defaultdict(list)
    per_chiave: dict[tuple, list[dict]] = defaultdict(list)
    for e in idx:
        per_ad[e["ad"]].append(e)
        per_chiave[_chiave(e)].append(e)

    # corso del database -> corso di studio del catalogo (voto sulle schede di tutti i suoi insegnamenti)
    cds_di: dict[str, str | None] = {}
    for corso in db["corsi"]:
        voti: Counter = Counter()
        chiavi: dict = {}
        for i in corso.get("insegnamenti") or []:
            mm = URL.search(i.get("url") or "")
            if not mm or not i.get("codice"):
                continue
            k = (mm.group(1), mm.group(2), mm.group(3), mm.group(4))
            for e in per_chiave.get(k, []):
                if e["ad"] == str(i["codice"]):
                    voti[e["cds"]] += 1
                    chiavi[e["cds"]] = e["chiave"]
        cds_di[corso["id"]] = (voti.most_common(1)[0][0], chiavi[voti.most_common(1)[0][0]]) if voti else None

    ris: dict[str, dict] = {}
    lacune: dict[str, str] = {}
    via: dict[str, int] = defaultdict(int)

    def cerca(es: list[dict], solo_aa=None, pid=None):
        """Tra le schede `es` (stesso insegnamento), la più recente che riporta il periodo: (voce, scheda)."""
        for aa in sorted({int(e["att"].get("aa") or 0) for e in es}, reverse=True):
            if solo_aa is not None and aa != solo_aa:
                continue
            gruppo = [e for e in es if int(e["att"].get("aa") or 0) == aa]
            trovati = []
            for e in sorted(gruppo, key=lambda e: -e["y"]):
                r = sem.periodo_attivita(e["att"])
                if not r and usa_syllabus and e["att"].get("statoErogMod") not in ("NE",):
                    r = sem.syllabus(c, e)
                if r:
                    trovati.append((r, e))
            if trovati and len({t[0]["sem"] for t in trovati}) == 1:
                return trovati[0]
            if trovati and pid is not None:  # percorsi discordi: valgono le schede del percorso dell'insegnamento
                stesso_p = [t for t in trovati if str(t[1]["att"].get("corso_percorso_id")) == pid]
                if stesso_p and len({t[0]["sem"] for t in stesso_p}) == 1:
                    return stesso_p[0]
            if trovati:
                return "conflitto"
        return None

    for m in manc:
        mm = URL.search(m.get("url") or "")
        ad = str(m["codice"]) if m.get("codice") else None
        cds, chiave = cds_di.get(m["corso"]) or (None, None)
        stesso = list(per_ad.get(ad, [])) if ad else []
        # stesso corso di studio: stesso codice oppure stesso nome, sede e tipo (il codice cambia con un nuovo ordinamento)
        stessi = [e for e in stesso if cds and (e["cds"] == cds or e["chiave"] == chiave)]
        altri = [e for e in stesso if e not in stessi]
        propria = [e for e in stessi if mm and _chiave(e) == (mm.group(1), mm.group(2), mm.group(3), mm.group(4))]
        ordine = propria + [e for e in stessi if e not in propria]
        r = cerca(ordine, pid=mm.group(4) if mm else None) if ordine else None
        livello = "stesso corso"
        if r is None and altri and mm:
            r = cerca(altri, solo_aa=int(mm.group(1)))
            livello = "altro corso, stesso a.a."
        if isinstance(r, tuple):
            voce, e = r
            out = {k: v for k, v in voce.items() if k != "sem"}
            if "periodo_inizio" in out and str(e["att"].get("aa")) != (mm.group(1) if mm else None):
                out.pop("periodo_inizio"), out.pop("periodo_fine")
                out["periodo"] = voce["sem"]
            out["fonte"] = sem.pagina(base, e["att"], e["y"])
            ris[m["id"]] = out
            via[livello] += 1
        elif r == "conflitto":
            lacune[m["id"]] = "schede dell'ateneo discordanti sul periodo"
        elif not stesso:
            lacune[m["id"]] = "nessuna scheda del catalogo con questo codice di insegnamento"
        else:
            lacune[m["id"]] = "il catalogo non riporta il periodo (né piano né syllabus) per questo insegnamento"
    log(f"[{uid}] trovati {len(ris)} su {len(manc)}; {dict(via)}")
    return ris, lacune
