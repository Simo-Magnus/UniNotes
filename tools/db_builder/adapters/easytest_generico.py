"""Calendario esami pubblico dell'Agenda Web (EasyAcademy / EasyTest) di un ateneo qualsiasi, senza login.

Molti atenei pubblicano gli appelli nell'Agenda Web (`<base>/index.php?view=easytest&include=et_cdl`): UniPD, UniMI,
UniMIB, UniTN, UniVR, UniBG, UniPR, UniTS, UniVE, UniCA, IULM, Tor Vergata… L'elenco dei corsi è in
`<base>/combo.php?sw=et_&page=corsi`, in due varianti:

a) `var esami_cdl = {codice: {label, elenco_anni}}`: gli appelli di un corso si leggono con `POST test_call.php`
   (corso, anni, intervallo di date);
b) `var et_elenco_cdl = [a.a. → corso → anno/percorso → sessioni]`: un POST per sessione (si leggono solo le sessioni
   non ancora concluse, dall'intervallo di date nell'etichetta).

Per ogni insegnamento: codice generale (`CodiceGenerale`, il codice Esse3), nome e per ogni appello data, ora, aula,
tipo di prova e se è annullato. Si tengono solo le date da oggi in poi. Non si salvano email né altri recapiti dei
docenti, solo i nomi. Al massimo 1 richiesta al secondo.
"""
from __future__ import annotations

import json
import re
import time

import requests

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}


def _modalita(t: str) -> str | None:
    t = (t or "").lower()
    if "scritt" in t and "oral" in t:
        return "scritto+orale"
    for k, v in (("scritt", "scritto"), ("oral", "orale"), ("progett", "progetto"), ("pratic", "altro"),
                 ("quiz", "quiz"), ("test", "quiz")):
        if k in t:
            return v
    return None


def _nome_docente(d) -> str | None:
    if isinstance(d, dict) and ("Cognome" in d or "Nome" in d):
        d = [d]
    elif isinstance(d, dict):
        d = list(d.values())
    nomi = [f"{(x.get('Cognome') or '').strip()} {(x.get('Nome') or '').strip()}".strip().upper()
            for x in d or [] if isinstance(x, dict)]
    return ", ".join(n for n in dict.fromkeys(nomi) if n) or None


def leggi_risposta(d: dict, fonte: str, oggi: str) -> dict[str, list[dict]]:
    """{CodiceGenerale: [esame, …]} da una risposta di test_call.php (date da `oggi` in poi)."""
    out: dict[str, list[dict]] = {}
    ins = d.get("Insegnamenti") or {}
    for v in (ins.values() if isinstance(ins, dict) else ins):
        di = v.get("DatiInsegnamento") or {}
        codice = (di.get("CodiceGenerale") or "").strip()
        if not codice:
            continue
        for a in v.get("Appelli") or []:
            m = re.match(r"(\d{2})-(\d{2})-(\d{4})", a.get("Data") or "")
            if not m or str(a.get("Annullato") or a.get("event_Annullato") or "0") != "0":
                continue
            tt = (a.get("Tipo") or "").lower()
            if tt and not re.search(r"esam|prov|appell", tt):
                continue  # lezioni, eventi
            data = f"{m.group(3)}-{m.group(2)}-{m.group(1)}"
            if data < oggi:
                continue
            aula = (a.get("Aula") or a.get("aula_sede") or "").strip()
            prova = f"{a.get('TipoEsame') or ''} {aula}"
            mod = _modalita(prova) if re.search(r"scritt|oral", prova.lower()) else None
            sede = (a.get("Sede") or "").strip()
            luogo = None if (mod and aula.lower().startswith("esame")) else \
                (", ".join(x for x in (aula, sede) if x and x not in ("[]", "-")) or None)
            ora = (a.get("OraInizio") or "").strip()
            docente = (a.get("docente") or "").strip() or _nome_docente(a.get("event_docenti")) or \
                _nome_docente(v.get("DatiDocente"))
            out.setdefault(codice, []).append({
                "tipo": "prova_in_itinere" if re.search(r"parzial|itinere|intermedi|esonero", f"{tt} {a.get('TipoEsame') or ''}".lower())
                else "appello",
                "titolo": (di.get("Nome") or "").strip() or None, "data": data,
                "ora": ora if re.fullmatch(r"\d{1,2}:\d{2}", ora) else None, "luogo": luogo, "modalita": mod,
                "iscrizioni_dal": None, "iscrizioni_al": None, "docenti": docente,
                "note": re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", a.get("Notes") or "")).strip() or None,
                "fonte": fonte})
    return out


def _post(s: requests.Session, url: str, dati, delay: float, conta: list) -> dict | None:
    for tentativo in range(3):
        time.sleep(delay)
        conta[0] += 1
        try:
            r = s.post(url, data=dati, timeout=120)
            r.raise_for_status()
            j = r.json()
            return j if isinstance(j, dict) else None
        except (requests.RequestException, ValueError):
            time.sleep(5 * (tentativo + 1))
    return None


def _unisci(out: dict, nuovi: dict) -> None:
    for k, lst in nuovi.items():
        cur = out.setdefault(k, [])
        for e in lst:
            if not any((x["data"], x["ora"], x["tipo"]) == (e["data"], e["ora"], e["tipo"]) for x in cur):
                cur.append(e)


def fetch_agenda(base: str, anno: int, log=print, delay: float = 1.0, tag: str = "agenda") -> dict[str, list[dict]]:
    """Appelli futuri dell'Agenda Web `base` (riconosce da solo la variante dell'elenco corsi)."""
    base = base.rstrip("/")
    pagina = f"{base}/index.php?view=easytest&include=et_cdl&_lang=it"
    s = requests.Session()
    s.headers.update(dict(HEADERS, Referer=pagina))
    s.get(pagina, timeout=60)
    t = s.get(f"{base}/combo.php?sw=et_&page=corsi", timeout=90).text
    oggi = time.strftime("%Y-%m-%d")
    out: dict[str, list[dict]] = {}
    n = [1]
    if t.lstrip().startswith("var et_elenco_cdl"):  # variante b
        elenco = json.loads(t[t.index("["):t.index("}];") + 2])
        for a in elenco:
            if int(a["valore"]) < anno - 1:
                continue
            for c in a.get("elenco") or []:
                for an in c.get("elenco_anni") or []:
                    for se in an.get("elenco_sessioni") or []:
                        m = re.search(r"\((\d{2})/(\d{2})/(\d{4})\s*-\s*(\d{2})/(\d{2})/(\d{4})\)\s*$", se.get("label") or "")
                        if m and f"{m.group(6)}-{m.group(5)}-{m.group(4)}" < oggi:
                            continue  # sessione già conclusa
                        dati = {"view": "easytest", "form-type": "et_cdl", "include": "et_cdl", "anno": a["valore"],
                                "cdl": c["valore"], "annocdl": an["valore"], "sessione": se["valore"], "_lang": "it",
                                "list": "", "week_grid_type": "-1", "ar_codes_": "", "ar_select_": "", "col_cells": "0",
                                "empty_box": "0", "only_grid": "0", "highlighted_date": "0", "all_events": "1"}
                        j = _post(s, f"{base}/test_call.php", dati, delay, n)
                        if j:
                            _unisci(out, leggi_risposta(j, pagina, oggi))
                        if n[0] % 100 == 0:
                            log(f"[{tag}] {n[0]} richieste, {len(out)} insegnamenti")
    else:  # variante a
        cdl = json.loads(t[t.index("{"):t.index("};") + 1])
        dal, al = f"01-09-{anno}", f"30-09-{anno + 1}"
        for i, (cod, info) in enumerate(cdl.items(), 1):
            ea = info.get("elenco_anni")
            anni = (list(ea.keys()) if isinstance(ea, dict) else
                    [str(x.get("valore")) for x in ea or [] if isinstance(x, dict) and x.get("valore") is not None])                 or [str(a) for a in range(1, 7)]
            dati = [("view", "easytest"), ("form-type", "et_cdl"), ("include", "et_cdl"), ("et_er", "1"),
                    ("scuola", info.get("scuola") or ""), ("esami_cdl", cod)] + [("anno2[]", str(a)) for a in anni] + \
                   [("datefrom", dal), ("dateto", al), ("_lang", "it"), ("list", ""), ("week_grid_type", "-1"),
                    ("all_events", "1")]
            j = _post(s, f"{base}/test_call.php", dati, delay, n)
            if j:
                _unisci(out, leggi_risposta(j, pagina, oggi))
            if i % 25 == 0:
                log(f"[{tag}] {i}/{len(cdl)} corsi, {len(out)} insegnamenti")
    for lst in out.values():
        lst.sort(key=lambda e: (e["data"], e["ora"] or ""))
    log(f"[{tag}] {base}: {n[0]} richieste, {len(out)} insegnamenti, {sum(len(v) for v in out.values())} date")
    return out
