"""Piani di studio, docenti, libri e appelli dell'Università Suor Orsola Benincasa da www.unisob.na.it.

Il LePrE (`/universita/facolta/<dip>/lepre/`, dip = giurisprudenza, formazione, lettere) elenca solo l'erogato
dell'a.a. corrente (insegnamenti di tutte le coorti e di tutti i curricula mescolati, senza obbligatorietà né
curriculum): sommando le righe un anno arrivava a 135-243 CFU. Il piano di studi è invece nel «Manifesto degli studi»
di ogni corso, una tabella per anno e per curriculum con il «Totale CFU» dell'anno:

- `<corso>/manifesti.htm` elenca i manifesti per a.a. (`manifesto.htm` = 2026/27, poi `manifesto2526.htm`,
  `imm2526_manifesto.htm`, …): per l'anno di corso k nell'a.a. A si usa il manifesto della coorte A-k+1 (una
  tabella «I anno», «II anno», … per curriculum);
- righe della tabella: attività, CFU, SSD, TAF; «Una lingua a scelta tra:», «Due letterature a scelta tra:»,
  «Un'attività a scelta tra:» aprono un gruppo di alternative (a scelta, tutte le righe fino alla riga vuota o al
  gruppo successivo); «Attività laboratoriali obbligatorie» apre un gruppo di attività obbligatorie; i «Cluster»
  di Management del Turismo sono solo raggruppamenti (le righe si sommano tutte); «Laboratori obbligatori a scelta
  tra» di Conservazione e restauro sono i laboratori del percorso formativo professionalizzante (PFP1, PFP2,
  PFP4: colonna SSD), che diventano i curricula del corso; «Crediti a scelta (dello studente)» = TAF D, a scelta;
- `aaf.htm` (o `aaf2.htm`, `lab1.htm`) elenca per ogni curriculum e anno i «Crediti a scelta consigliati
  dall'Ateneo» con CFU e docenti: sostituiscono il segnaposto «Crediti a scelta» dell'anno in cui sono offerti;
- LePrE: `programmi.asp` (form: R1 corso, R3 tipologia, R4 anno di corso, R5 a.a., R2 ordine) → attività,
  docenti, anno e CFU con il link a `programma.asp?id=…` (SSD e «Testi adottati»); `esami.asp` → calendario
  degli appelli per insegnamento, con giorno e mese ma senza anno ("14 Dicembre ore 09:30 - sessione:
  straordinaria"): l'anno è quello dell'a.a. (settembre-dicembre il primo, gennaio-agosto il secondo).

Ogni riga del manifesto ha docenti, scheda, libri e appelli del programma LePrE con lo stesso nome (stesso anno, poi
qualsiasi anno del corso). Il totale di ogni anno e curriculum si controlla contro la riga «Totale CFU … anno»
(`PROBLEMI`).
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import hashlib
import html
import json
import os
import pathlib
import re
import time
import unicodedata
from urllib.parse import urljoin

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

UID = "unisob"
ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unisob.na.it/universita/facolta/{}/lepre/"
DIPARTIMENTI = ("giurisprudenza", "formazione", "lettere")
MESI = {m: i for i, m in enumerate(("gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto",
                                    "settembre", "ottobre", "novembre", "dicembre"), 1)}
ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
PROBLEMI: list[str] = []   # totali di anno/curriculum che non tornano con la riga «Totale» del manifesto, ripieghi di coorte
DEDUZIONI: list[str] = []  # correzioni non lette dalla fonte


def _scarica(c: Client, url: str, data: dict | None = None) -> str:
    """Le pagine del sito sono in Windows-1252 o in UTF-8, senza charset nell'intestazione: si scaricano e si
    decodificano qui (il Client le leggerebbe sempre come UTF-8). Con UN_HTTP_CACHE le pagine si salvano su disco."""
    f = None
    if c.cache:
        key = hashlib.sha1((url + "|" + json.dumps(data, sort_keys=True)).encode()).hexdigest()
        f = c.cache / key[:2] / f"{key}.unisob.txt"
        if f.exists():
            return f.read_text(encoding="utf-8")
    for tentativo in range(3):
        with c.lock:
            attesa = c.last + c.min_gap - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            c.last = time.monotonic()
            c.requests += 1
        try:
            r = c.s.post(url, data=data, timeout=90) if data else c.s.get(url, timeout=90)
            if r.status_code == 404:
                return ""
            if r.ok:
                try:  # alcune pagine sono in UTF-8
                    t = r.content.decode("utf-8")
                except UnicodeDecodeError:
                    t = r.content.decode("cp1252", "replace")
                if f:
                    f.parent.mkdir(parents=True, exist_ok=True)
                    f.write_text(t, encoding="utf-8")
                return t
        except Exception:  # noqa: BLE001
            time.sleep(2 ** tentativo)
    return ""


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _slug(s: str, maxlen: int) -> str:
    return _norm(s).replace(" ", "-")[:maxlen].strip("-")


# --------------------------------------------------------------------------- LePrE

def leggi_programmi(s: str) -> list[dict]:
    out = []
    for r in re.findall(r"<tr>(.*?)</tr>", s, re.S):
        c = re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)
        p = re.search(r'programma\.asp\?vr=1&amp;id=(\d+)', c[0]) if c else None
        if len(c) < 4 or not p:
            continue
        anno = re.search(r"\d", _testo(c[2]))
        cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(c[3]))
        v = float(cfu.group(0).replace(",", ".")) if cfu else None
        out.append({"id": p.group(1), "nome": html.unescape(_testo(c[0])),
                    "docenti": [html.unescape(_testo(d)) for d in re.findall(r"<a[^>]*>(.*?)</a>", c[1], re.S)],
                    "anno": int(anno.group(0)) if anno else None,
                    "cfu": int(v) if v is not None and v.is_integer() else v})
    return out


def leggi_programma(s: str) -> dict:
    t = _testo(s)
    ssd = re.search(r"SSD:\s*([A-Z]{2,5}[-/][\w/-]+)", t)
    m = re.search(r"Testi adottati(.*?)(?:Metodo di valutazione|English version|Ultimo aggiornamento)", s, re.S)
    return {"ssd": ssd.group(1) if ssd else None, "libri": estrai_libri(m.group(1)) if m else []}


def leggi_esami(s: str, anno: int, fonte: str) -> dict[str, list[dict]]:
    """Nome normalizzato dell'insegnamento → appelli."""
    oggi = time.strftime("%Y-%m-%d")
    out: dict[str, list[dict]] = {}
    for blocco in re.findall(r'<div class="sfondolepre">(.*?)</div>', s, re.S):
        nome = re.search(r"<a[^>]*>\s*<b>(.*?)</b>", blocco, re.S)
        if not nome:
            continue
        doc = re.search(r"Docent[ei]:\s*<b>(.*?)</b>", blocco, re.S)
        for g, mese, h, mi, nota in re.findall(r"(\d{1,2})\s+([A-Za-z]+)\s+ore\s+(\d{1,2})[:.](\d{2})([^<]*)", blocco):
            mm = MESI.get(mese.lower())
            if not mm:
                continue
            data = f"{anno if mm >= 9 else anno + 1}-{mm:02d}-{int(g):02d}"
            if data < oggi:
                continue
            prova = re.search(r"\(([^)]*)\)", nota)
            sess = re.search(r"sessione:\s*(\w+)", nota)
            out.setdefault(_norm(html.unescape(_testo(nome.group(1)))), []).append({
                "tipo": "prova_in_itinere" if prova and re.search(r"(?i)intercors|parzial|itinere", prova.group(1))
                else "appello", "data": data, "ora": f"{int(h):02d}:{mi}", "luogo": None,
                "modalita": ("scritto" if "scritt" in prova.group(1).lower() else "orale" if "oral" in prova.group(1).lower()
                             else None) if prova else None,
                "iscrizioni_dal": None, "iscrizioni_al": None,
                "docenti": html.unescape(_testo(doc.group(1))) if doc else None,
                "note": f"Sessione {sess.group(1)}" if sess else None, "fonte": fonte})
    return out


# --------------------------------------------------------------------------- manifesto

def _t(s: str) -> str:
    """Testo di una cella: tag tolti, spazi uniti, a capo dei <br> mantenuti come «\\n»."""
    s = re.sub(r"(?i)<br\s*/?>", "\n", s or "")
    s = html.unescape(re.sub(r"<[^>]+>", " ", s)).replace("\xa0", " ")
    return "\n".join(x for x in (re.sub(r"[ \t\r\f\v]+", " ", r).strip() for r in s.split("\n")) if x)


def _righe_tabella(t: str) -> list[list[str]]:
    """Righe di una tabella con rowspan e colspan espansi (le celle unite si ripetono)."""
    out, pend = [], {}
    for r in re.findall(r"<tr[^>]*>(.*?)</tr>", t, re.S):
        celle = re.findall(r"<t[dh]([^>]*)>(.*?)</t[dh]>", r, re.S)
        riga, col, k = [], 0, 0
        while k < len(celle) or col in pend:
            if col in pend:
                testo, n = pend[col]
                riga.append(testo)
                if n > 1:
                    pend[col] = (testo, n - 1)
                else:
                    del pend[col]
                col += 1
                continue
            attr, inner = celle[k]
            k += 1
            testo = _t(inner)
            rs = re.search(r'rowspan="?(\d+)', attr)
            cs = re.search(r'colspan="?(\d+)', attr)
            for j in range(int(cs.group(1)) if cs else 1):
                riga.append(testo if j == 0 else "")
                if rs and int(rs.group(1)) > 1:
                    pend[col] = (testo if j == 0 else "", int(rs.group(1)) - 1)
                col += 1
        out.append(riga)
    return out


def _nome_curriculum(raw: str) -> str:
    """«Curriculum "Scenari e profili territoriali"» -> «Scenari e profili territoriali»; le virgole (che
    pulizia.percorsi() usa per separare i percorsi) diventano trattini."""
    s = html.unescape(raw or "")
    s = re.sub(r"(?i)^\s*(curriculum|percorso)\s*:?\s*", "", s).strip()
    s = s.replace('"', "").replace("“", "").replace("”", "")
    s = s.replace(", ", " - ")
    s = re.sub(r"\s+", " ", s).strip()
    return s[:1].upper() + s[1:]


_SSD_VECCHIO = re.compile(r"^[A-Z]{1,5}(?:-[A-Z]{2,5})?/\d{2}$")
_CRED_SCELTA = re.compile(r"(?i)^\s*(crediti a scelta|a scelta dello studente)")
_NUMERI = {"un": 1, "uno": 1, "una": 1, "un'": 1, "due": 2, "tre": 3, "quattro": 4}


def _cfu(s: str) -> int | None:
    m = re.fullmatch(r"\s*(\d+)(?:[.,]0+)?\s*", s or "")
    return int(m.group(1)) if m else None


def _gruppo(testo: str) -> dict | None:
    """«Una lingua a scelta tra:» -> gruppo di alternative (n = 1), «Due letterature a scelta tra:» (n = 2),
    «Attività laboratoriali a scelta: 6 CFU» (CFU del gruppo), «Attività laboratoriali a scelta:» (n non
    dichiarato), «Attività laboratoriali obbligatorie»."""
    t = re.sub(r"\s+", " ", testo).strip()
    if re.search(r"(?i)\ba scelta\b", t):
        m = re.match(r"(?i)^(\d+|un'|uno|una|un|due|tre|quattro)\b\s*(.*)$", t)
        n = (int(m.group(1)) if m.group(1).isdigit() else _NUMERI.get(m.group(1).lower())) if m else None
        k = re.search(r"(\d+)\s*CFU", t)
        return {"titolo": t.rstrip(":").strip(), "kind": "scelta", "n": n, "cfu_tot": int(k.group(1)) if k else None,
                "opzioni": []}
    if re.search(r"(?i)\bobbligatori[eao]\s*$", t):
        return {"titolo": t.rstrip(":").strip(), "kind": "obbl", "n": None, "opzioni": []}
    return None


def _colonne(testata: list[str]) -> dict | None:
    """Colonne della tabella dal suo capoverso: attività/insegnamento/discipline, CFU/crediti, SSD, TAF."""
    nome = next((i for i, x in enumerate(testata) if re.search(r"(?i)attivit|insegnament|disciplin", x)
                 and not re.search(r"(?i)ambit", x)), None)
    cfu = next((i for i, x in enumerate(testata) if re.match(r"(?i)^(cfu|crediti)\b", x.strip())), None)
    if nome is None or cfu is None:
        return None
    ssd = next((i for i, x in enumerate(testata) if re.match(r"(?i)^(ssd|settore)", x.strip()) and "639" not in x), None)
    taf = next((i for i, x in enumerate(testata) if re.match(r"(?i)^taf\b", x.strip())), None)
    return {"nome": nome, "cfu": cfu, "ssd": ssd, "taf": taf}


def _pulisci_nome(nome: str) -> tuple[str, str | None]:
    """(nome, nota): «Pedagogia generale (A-L/M-Z)» è lo stesso insegnamento in due canali."""
    nome = re.sub(r"\s*\*+$", "", re.sub(r"\s+", " ", nome)).strip()
    m = re.search(r"\s*\((A-L\s*/\s*M-Z)\)\s*$", nome)
    if m:
        return nome[:m.start()].strip(), "Due canali (A-L e M-Z)"
    return nome, None


def leggi_tabella(t: str) -> tuple[list[dict], int | None, int | None]:
    """(righe, totale dell'anno, totale del corso). Una riga: nome, cfu, ssd, taf, obbl, gruppo, curr, cluster."""
    righe: list[dict] = []
    totale = totale_corso = None
    gruppo = None
    cluster = None
    col = None
    for cells in _righe_tabella(t):
        if col is None:
            col = _colonne(cells)
            if col is None:
                return [], None, None
            continue
        cells = cells + [""] * (max(col.values(), key=lambda v: -1 if v is None else v) + 1 - len(cells))
        if not any(cells):
            gruppo = None
            continue
        nonvuote = [x for x in cells if x]
        tot = next((x for x in cells if re.match(r"(?i)^totale\b", x)), None)
        if tot:
            v = _cfu(cells[col["cfu"]]) if _cfu(cells[col["cfu"]]) is not None else next(
                (_cfu(x) for x in cells if _cfu(x) is not None), None)
            if re.search(r"(?i)\banno\b", tot):
                totale = v
            else:
                totale_corso = v
            gruppo = None
            continue
        nome, nota_nome = _pulisci_nome(cells[col["nome"]])
        cfu = _cfu(cells[col["cfu"]])
        if not nome:  # riga senza nome: il totale del corso, oppure un separatore
            if cfu is not None and len(nonvuote) == 1:
                totale_corso = totale_corso or cfu
            else:
                gruppo = None
            continue
        if len(nonvuote) == 1 and cfu is None:  # intestazione di gruppo (cella unita)
            g = _gruppo(nome)
            if g:
                gruppo = g
            continue
        ssd_cella = cells[col["ssd"]] if col["ssd"] is not None else ""
        if re.match(r"(?i)^cluster\b", nome):  # raggruppamento (le righe seguenti si sommano tutte)
            cluster = {"nome": nome, "resto": cfu or 0}  # (dura per i CFU dichiarati dal raggruppamento)
            gruppo = None
            continue
        if re.match(r"(?i)^laboratori obbligatori\b", nome) and not _SSD_VECCHIO.match(ssd_cella) and not re.fullmatch(
                r"PFP\d", ssd_cella):  # laboratori dei percorsi PFP
            gruppo = {"titolo": nome.rstrip(":"), "kind": "pfp", "n": None, "cfu": cfu, "opzioni": []}
            continue
        taf = cells[col["taf"]] if col["taf"] is not None and re.fullmatch(r"[A-FS]", cells[col["taf"]]) else None
        r = {"nome": nome, "cfu": cfu, "ssd": ssd_cella if _SSD_VECCHIO.match(ssd_cella) else None, "taf": taf,
             "obbl": True, "gruppo": None, "curr": None, "cluster": cluster["nome"] if cluster else None,
             "nota": nota_nome}
        if cluster:
            cluster["resto"] -= cfu or 0
            if cluster["resto"] <= 0:
                cluster = None
        if gruppo and gruppo["kind"] == "scelta":
            r["obbl"], r["gruppo"] = False, gruppo
            gruppo["opzioni"].append(r)
        elif gruppo and gruppo["kind"] == "pfp":
            r["gruppo"] = gruppo
            r["curr"] = ssd_cella if re.fullmatch(r"PFP\d", ssd_cella) else None
            r["ssd"] = None
            gruppo["opzioni"].append(r)
        elif gruppo and gruppo["kind"] == "obbl":
            r["gruppo"] = gruppo
            gruppo["opzioni"].append(r)
        if _CRED_SCELTA.match(nome) or taf == "D":
            r["obbl"] = False
            r["nome"] = "Crediti a scelta dello studente"
        m = re.search(r"\b(PFP\d)\s*$", nome)
        if m and not r["curr"]:  # «Laboratorio di sintesi per la tesi PFP2»
            r["curr"] = m.group(1)
        righe.append(r)
    return righe, totale, totale_corso


def leggi_manifesto(s: str) -> list[dict]:
    """[{curriculum: nome grezzo o None, anni: {anno: {righe, totale, totale_corso}}}] in ordine di pagina."""
    s = s[s.find("<h1"):] if "<h1" in s else s
    sezioni: list[dict] = []
    pos = [(m.start(), "H", _t(m.group(1))) for m in re.finditer(r'<div class="[^"]*testagr[^"]*">(.*?)</div>', s, re.S)]
    pos += [(m.start(), "T", m.group(0)) for m in re.finditer(r"<table.*?</table>", s, re.S)]
    pos.sort()
    corrente = None
    for _, k, v in pos:
        if k == "H":
            corrente = {"curriculum": v, "anni": {}}
            sezioni.append(corrente)
            continue
        cap = re.search(r"<caption>(.*?)</caption>", v, re.S)
        cap = _t(cap.group(1)) if cap else ""
        tt = re.search(r"<tr[^>]*>(.*?)</tr>", v, re.S)
        if not tt or _colonne([_t(x) for x in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", tt.group(1), re.S)]) is None:
            continue  # propedeuticità e altre tabelle
        if corrente is None:
            corrente = {"curriculum": None, "anni": {}}
            sezioni.append(corrente)
        m = re.match(r"^(VI|IV|V|III|II|I)\s*anno", cap)
        anno = ROMANI[m.group(1)] if m else (max(corrente["anni"]) + 1 if corrente["anni"] else None)
        if anno is None:
            continue
        righe, totale, totale_corso = leggi_tabella(v)
        corrente["anni"][anno] = {"righe": righe, "totale": totale, "totale_corso": totale_corso}
    return [x for x in sezioni if x["anni"]]


def indice_manifesti(s: str, base: str) -> dict[int, str]:
    """a.a. di inizio → indirizzo del manifesto, da `manifesti.htm`."""
    out = {}
    for h, t in re.findall(r'<a[^>]*href="([^"]+)"[^>]*>\s*Manifesto degli studi a\.a\. (\d{4})/\d{2}\s*</a>', s):
        out.setdefault(int(t), urljoin(base, html.unescape(h)))
    return out


def _controlla_totale(corso: str, aa: int, anno: int, sez: str | None, tab: dict) -> None:
    """La somma delle righe (gruppi a scelta: n × CFU) deve tornare con «Totale CFU … anno»."""
    righe, totale = tab["righe"], tab["totale"]
    if totale is None:
        return
    pfps = sorted({r["curr"] for r in righe if r["curr"]}) or [None]
    for p in pfps:
        somma, ignoti, visti = 0, [], set()
        for r in righe:
            if r["curr"] and r["curr"] != p:
                continue
            g = r["gruppo"]
            if g is None or g["kind"] == "obbl":
                somma += r["cfu"] or 0
            elif g["kind"] == "pfp":
                somma += r["cfu"] or 0
            elif id(g) not in visti:
                visti.add(id(g))
                cfus = {o["cfu"] for o in g["opzioni"]}
                if g.get("cfu_tot"):
                    somma += g["cfu_tot"]
                elif g["n"] and len(cfus) == 1:
                    somma += g["n"] * next(iter(cfus))
                else:
                    ignoti.append(g)
        etichetta = f"{corso} {aa}/{(aa + 1) % 100:02d} {anno}° anno" + (f" ({sez})" if sez else "") + \
            (f" {p}" if p else "")
        if ignoti:
            mancano = totale - somma
            cfus = {o["cfu"] for g in ignoti for o in g["opzioni"]}
            if len(ignoti) == 1 and len(cfus) == 1 and mancano > 0 and mancano % next(iter(cfus)) == 0:
                n = mancano // next(iter(cfus))
                DEDUZIONI.append(f"{etichetta}: «{ignoti[0]['titolo']}» senza numero di scelte, {n} attività da "
                                 f"{next(iter(cfus))} CFU per tornare al totale {totale}")
            else:
                PROBLEMI.append(f"{etichetta}: gruppi senza numero di scelte, mancano {mancano} CFU al totale "
                                f"{totale}")
        elif somma != totale:
            PROBLEMI.append(f"{etichetta}: somma {somma} ≠ totale dichiarato {totale}")


# --------------------------------------------------------------------------- crediti a scelta (aaf.htm)

def leggi_aaf(s: str) -> dict[tuple[str | None, int], list[dict]]:
    """(curriculum grezzo o None, anno) → «Crediti a scelta consigliati dall'Ateneo» (nome, cfu, ssd, docenti)."""
    s = s[s.find("<h1"):s.find('id="coldx"')] if "<h1" in s else s
    pos = [(m.start(), "H", _t(m.group(1))) for m in re.finditer(r'<div class="[^"]*testagr[^"]*">(.*?)</div>', s, re.S)]
    pos += [(m.start(), "P", _t(m.group(1))) for m in re.finditer(r'<p class="tit_6">(.*?)</p>', s, re.S)]
    pos += [(m.start(), "T", m.group(0)) for m in re.finditer(r"<table.*?</table>", s, re.S)]
    pos.sort()
    curr, sezione, anno = None, None, None
    out: dict = {}
    for _, k, v in pos:
        if k == "H":
            if re.match(r"(?i)^(curriculum|percorso)\b", v):
                curr, sezione, anno = v, None, None
            else:
                sezione, anno = v, None
        elif k == "P":
            m = re.match(r"^(VI|IV|V|III|II|I)\s*anno", v)
            anno = ROMANI[m.group(1)] if m else None
        elif sezione and re.match(r"(?i)^crediti a scelta", sezione):
            righe = _righe_tabella(v)
            if not righe:
                continue
            ic = next((i for i, x in enumerate(righe[0]) if x.strip().upper() == "CFU"), None)
            iss = next((i for i, x in enumerate(righe[0]) if x.strip().upper() == "SSD"), None)
            idoc = next((i for i, x in enumerate(righe[0]) if x.strip().lower().startswith("docent")), None)
            if ic is None:
                continue
            for r in righe[1:]:
                if len(r) <= ic or _cfu(r[ic]) is None or not r[0]:
                    continue
                nome = re.split(r"\s*\*\s*", r[0].replace("\n", " "))[0].strip()
                nota = re.sub(r"^\*\s*", "", r[0].replace("\n", " ")[len(nome):]).strip(" *") or None
                out.setdefault((curr, anno or 0), []).append({  # senza anno: valgono per l'anno del segnaposto
                    "nome": re.sub(r"\s+", " ", nome), "cfu": _cfu(r[ic]),
                    "ssd": r[iss] if iss is not None and len(r) > iss and _SSD_VECCHIO.match(r[iss]) else None,
                    "docenti": [d for d in (r[idoc].split("\n") if idoc is not None and len(r) > idoc else []) if d],
                    "nota": nota})
    return out


# --------------------------------------------------------------------------- piano del corso

def _curr_corrispondente(nome: str, noti: list[str]) -> str:
    """Il curriculum di un manifesto precedente con il nome più vicino a uno dei curricula del manifesto corrente."""
    n = _norm(nome)
    for x in noti:
        if _norm(x) == n:
            return x
    punti = sorted(((difflib.SequenceMatcher(None, n, _norm(x)).ratio(), x) for x in noti), reverse=True)
    if punti and punti[0][0] >= 0.8 and (len(punti) == 1 or punti[0][0] - punti[1][0] > 0.05):
        return punti[0][1]
    return nome


def _mappa_curricula(nomi: list[str], noti: list[str], etichetta: str) -> dict[str, str]:
    """Nome del curriculum in un manifesto precedente -> nome nel manifesto corrente (stesso nome o molto simile;
    se resta un solo curriculum per parte e gli altri corrispondono, è lo stesso curriculum rinominato)."""
    mappa = {n: _curr_corrispondente(n, noti) for n in nomi}
    senza = [n for n, m in mappa.items() if m not in noti]
    liberi = [x for x in noti if x not in mappa.values()]
    if len(senza) == 1 and len(liberi) == 1 and len(nomi) == len(noti):
        mappa[senza[0]] = liberi[0]
        DEDUZIONI.append(f"{etichetta}: curriculum «{senza[0]}» ricondotto a «{liberi[0]}» (unico non corrispondente, stessa posizione)")
    return mappa


def piano_corso(c: Client, corso: dict, anno_acc: int, log=print) -> dict | None:
    """{curricula, righe: [riga con anno, fonte, curriculum…], aaf: …} dal manifesto della coorte di ogni anno."""
    base = (corso.get("url") or "").rsplit("/", 1)[0] + "/"
    if not base.startswith("http"):
        return None
    base = base.replace("http://", "https://")
    idx_url = base + "manifesti.htm?vr=1"
    man = indice_manifesti(_scarica(c, idx_url), idx_url)
    if not man:
        man = {anno_acc: base + "manifesto.htm?vr=1"}
    parsed: dict[int, list[dict]] = {}

    def sezioni(aa: int) -> list[dict]:
        if aa not in parsed:
            parsed[aa] = leggi_manifesto(_scarica(c, man[aa])) if aa in man else []
        return parsed[aa]

    corrente = sezioni(anno_acc) or sezioni(max(man))
    noti = [_nome_curriculum(x["curriculum"]) for x in corrente if x["curriculum"]]
    # curricula di Conservazione e restauro: percorsi PFP1, PFP2, PFP4 (colonna SSD dei laboratori), con il nome
    # dato nella «Descrizione del percorso formativo» («1. Curriculum Affreschi-lapideo. PFP1. …»)
    pfp = sorted({r["curr"] for x in corrente for t in x["anni"].values() for r in t["righe"] if r["curr"]})
    nomi_pfp: dict[str, str] = {}
    if pfp:
        desc = re.sub(r"\s+", " ", _t(_scarica(c, man.get(anno_acc) or man[max(man)])))
        for nm, cod in re.findall(r"Curriculum ([\w\- ]+?)\.\s*(PFP\d)\.", desc):
            nomi_pfp[cod] = f"{nm.strip()} ({cod})"
        for cod in pfp:
            nomi_pfp.setdefault(cod, cod)
        if not noti:
            noti = [nomi_pfp[cod] for cod in pfp]
    durata = corso.get("durata_anni") or 3
    voci: list[dict] = []
    for a in range(1, durata + 1):
        inizio = anno_acc - (a - 1)
        ordine = [inizio] + sorted((x for x in man if x != inizio), key=lambda x: (abs(x - inizio), -x))
        scelto = None
        for aa in ordine:
            ss = [x for x in sezioni(aa) if a in x["anni"]]
            if ss:
                scelto = (aa, ss)
                break
        if not scelto:
            PROBLEMI.append(f"{corso['id']}: anno {a} senza piano in nessun manifesto")
            continue
        aa, ss = scelto
        ripiego = aa != inizio
        if ripiego:
            PROBLEMI.append(f"{corso['id']}: anno {a} senza manifesto {inizio}/{(inizio + 1) % 100:02d}: "
                            f"si usa il {aa}/{(aa + 1) % 100:02d}")
        nomi_aa = [_nome_curriculum(x["curriculum"]) for x in ss if x["curriculum"]]
        mappa = _mappa_curricula(nomi_aa, noti, f"{corso['id']} {aa}/{(aa + 1) % 100:02d}") if noti and aa != anno_acc             else {}
        for x in ss:
            nome_c = _nome_curriculum(x["curriculum"]) if x["curriculum"] else None
            if nome_c:
                nome_c = mappa.get(nome_c, nome_c)
            tab = x["anni"][a]
            _controlla_totale(corso["id"], aa, a, nome_c, tab)
            for r in tab["righe"]:
                voci.append({**r, "curr": nomi_pfp.get(r["curr"], r["curr"]) if r["curr"] else None, "anno": a, "aa": aa,
                             "sez": nome_c, "ripiego": ripiego, "fonte": man[aa]})
    curricula = list(noti)
    for v in voci:
        if v["sez"] and v["sez"] not in curricula:
            curricula.append(v["sez"])
    # pagina dei crediti a scelta
    aaf = {}
    corr_html = _scarica(c, man.get(anno_acc) or man[max(man)])
    m = re.search(r'href="([^"]+)"[^>]*>\s*(?:Crediti a scelta|A scelta dello studente)', corr_html)
    if m and re.search(r"(?:aaf|lab)\w*\.htm", m.group(1)):
        u = urljoin(man.get(anno_acc) or man[max(man)], html.unescape(m.group(1)))
        for (cg, an), lst in leggi_aaf(_scarica(c, u)).items():
            nome_c = _curr_corrispondente(_nome_curriculum(cg), curricula) if cg else None
            aaf[(nome_c, an)] = [{**o, "fonte": u} for o in lst]
    return {"curricula": curricula, "voci": voci, "aaf": aaf}


def righe_corso(piano: dict, corso: dict, oggi: str) -> list[dict]:
    """Insegnamenti del corso dal piano: righe uguali di curricula diversi unite, segnaposto «Crediti a scelta»
    sostituiti dai crediti consigliati dell'anno."""
    curricula = piano["curricula"]
    voci = piano["voci"]
    aaf = piano["aaf"]
    per_anno_sez: dict[int, set] = {}
    for v in voci:
        per_anno_sez.setdefault(v["anno"], set()).add(v["sez"] or v["curr"])
    # curricula presenti in ogni anno (None = piano unico)
    def universo(anno: int) -> set:
        return {v["sez"] for v in voci if v["anno"] == anno} | {v["curr"] for v in voci if v["anno"] == anno and v["curr"]}

    # 1. segnaposto sostituiti
    esteso: list[dict] = []
    for v in voci:
        if not v["obbl"] and v["nome"] == "Crediti a scelta dello studente" and v["gruppo"] is None:
            cand = (aaf.get((v["sez"], v["anno"])) or aaf.get((v["sez"], 0)) or aaf.get((None, v["anno"]))
                    or aaf.get((None, 0)))
            if cand:
                for o in cand:
                    esteso.append({"nome": o["nome"], "cfu": o["cfu"], "ssd": o["ssd"], "taf": "D", "obbl": False,
                                   "gruppo": None, "curr": v["curr"], "cluster": None, "anno": v["anno"],
                                   "aa": v["aa"], "sez": v["sez"], "ripiego": v["ripiego"], "fonte": v["fonte"],
                                   "docenti": o["docenti"], "url_aaf": o["fonte"],
                                   "nota": f"Credito a scelta consigliato dall'Ateneo (il piano prevede "
                                           f"{v['cfu']} CFU a scelta dello studente, anche liberi nell'offerta "
                                           f"dell'Ateneo)" + (f"; {o['nota']}" if o.get("nota") else "")})
                continue
        esteso.append(v)
    # 2. righe uguali di curricula diversi
    gruppi: dict[tuple, dict] = {}
    for v in esteso:
        cur = v["curr"] or v["sez"]
        k = (v["anno"], _norm(v["nome"]), v["cfu"], v["obbl"])
        g = gruppi.setdefault(k, {**v, "_c": []})
        if cur not in g["_c"]:
            g["_c"].append(cur)
        if not g.get("ssd") and v.get("ssd"):
            g["ssd"] = v["ssd"]
        if v.get("ripiego"):
            g["ripiego"] = True
    # stesso nome e anno con CFU diversi: «Nome (N CFU)»
    per_nome: dict[tuple, set] = {}
    for (anno, n, cfu, obbl), g in gruppi.items():
        per_nome.setdefault((anno, n), set()).add(cfu)
    righe = []
    for (anno, n, cfu, obbl), g in gruppi.items():
        cs = g.pop("_c")
        tutti = universo(anno)
        curr = None if (set(cs) == tutti or cs == [None]) else ", ".join(x for x in cs if x)
        nome = g["nome"] if len(per_nome[(anno, n)]) == 1 else f"{g['nome']} ({cfu} CFU)"
        g.update(nome=nome, curriculum=curr)
        righe.append(g)
    # lo stesso insegnamento obbligatorio in alcuni curricula e proposto a scelta (crediti consigliati) in altri: due
    # righe con curricula disgiunti (build_db unisce le righe dello stesso anno se una non ha curricula)
    per_riga: dict[tuple, list[dict]] = {}
    for r in righe:
        per_riga.setdefault((r["anno"], _norm(re.sub(r" \(\d+ CFU\)$", "", r["nome"])), r["cfu"]), []).append(r)
    togliere = []
    for (anno, _, _), lst in per_riga.items():
        obb = [r for r in lst if r["obbl"]]
        sce = [r for r in lst if not r["obbl"]]
        if not (obb and sce):
            continue
        ordine = [x for x in curricula if x]
        tutti = [x for x in ordine if x in universo(anno)] or ordine
        cobb = set(tutti) if any(r["curriculum"] is None for r in obb) else \
            {p for r in obb for p in r["curriculum"].split(", ")}
        for r in sce:
            suoi = tutti if r["curriculum"] is None else r["curriculum"].split(", ")
            resto = [x for x in suoi if x not in cobb]
            if not resto:
                togliere.append(r)  # obbligatorio dove sarebbe proposto: non è una scelta
            elif len(resto) < len(suoi) or r["curriculum"] is None:
                r["curriculum"] = ", ".join(resto)
    return [r for r in righe if not any(r is t for t in togliere)]


def _id_espliciti(corso_id: str, items: list[dict]) -> None:
    """build_db tronca lo slug dell'id a 40 caratteri: due insegnamenti diversi con lo stesso inizio di nome nello
    stesso anno si fonderebbero: hanno un id esplicito."""
    per: dict[tuple, list[dict]] = {}
    for i in items:
        per.setdefault((_slug(i["nome"], 40), i["anno"], i["obbligatorio"] is False), []).append(i)
    usati: set[str] = set()
    for lst in per.values():
        if len({i["nome"].lower() for i in lst}) > 1:
            for i in lst:
                base = f"{corso_id}-{_slug(i['nome'], 90)}"
                nuovo = base
                for suff in (f"-a{i['anno']}", f"-a{i['anno']}-{'scelta' if i['obbligatorio'] is False else 'obbl'}"):
                    if nuovo in usati:
                        nuovo = base + suff
                usati.add(nuovo)
                i["id"] = nuovo


def _riuso(uid: str) -> dict[str, dict]:
    """Libri e SSD già raccolti (id del programma LePrE → dati) dal contributo precedente."""
    p = ROOT / "database" / "contrib" / "auto" / f"{uid}.json"
    out: dict[str, dict] = {}
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return out
    for c in d.get("corsi") or []:
        for i in c.get("insegnamenti") or []:
            m = re.search(r"[?&]id=(\d+)", i.get("url") or "")
            if m and i.get("libri"):
                out.setdefault(m.group(1), {"libri": i["libri"], "ssd": i.get("ssd")})
    return out


def _abbina(voci_lepre: list[dict], nome: str, anno: int | None, cfu: int | None,
            curriculum: str | None = None) -> list[dict]:
    """Programmi LePrE con lo stesso nome: stesso anno, poi altri anni; senza corrispondenza esatta, il più simile
    (≥ 0.93) dello stesso anno."""
    n = _norm(nome)
    esatti = [v for v in voci_lepre if _norm(v["nome"]) == n]
    for filtro in (lambda v: v["anno"] == anno and v["cfu"] == cfu, lambda v: v["anno"] == anno, lambda v: True):
        sel = [v for v in esatti if filtro(v)]
        if sel:
            return sel
    if esatti:
        return esatti
    # «Inglese II (Cinema e televisione)», «Antropologia culturale (A-L)»: stesso insegnamento con la specificazione
    # del curriculum o del canale; con il curriculum della riga si tengono le varianti che gli somigliano di più
    var = []
    for v in voci_lepre:
        m = re.match(r"^(.*?)\s*\(([^()]*)\)\s*$", v["nome"])
        if m and _norm(m.group(1)) == n:
            var.append((v, m.group(2)))
    if var:
        sel = [x for x in var if x[0]["anno"] == anno] or var
        if curriculum:
            gen = {"curriculum", "percorso", "di", "e", "per", "dei", "delle", "del", "della", "nei", "nel", "nelle",
                   "il", "la", "le", "lo", "gli", "i", "in", "a", "da", "con"}
            cur = [{t for t in _norm(c).split() if t not in gen} for c in curriculum.split(", ")]
            punti = [(max(len({t for t in _norm(q).split() if t not in gen} & c) for c in cur), v) for v, q in sel]
            migliore = max(p for p, _ in punti)
            if migliore > 0:
                return [v for p, v in punti if p == migliore]
        return [v for v, _ in sel]
    punti = sorted(((difflib.SequenceMatcher(None, n, _norm(v["nome"])).ratio(), v) for v in voci_lepre
                    if v["anno"] == anno), key=lambda x: -x[0])
    return [punti[0][1]] if punti and punti[0][0] >= 0.93 else []


def fetch_ateneo(uid: str = "unisob", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    PROBLEMI.clear()
    DEDUZIONI.clear()
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    riuso = _riuso(uid)
    opzioni = []  # (dip, valore, nome)
    for d in DIPARTIMENTI:
        sel = re.search(r'name="R1".*?</select>', _scarica(c, BASE.format(d) + "programmi.asp?vr=1"), re.S)
        opzioni += [(d, v, html.unescape(t).strip()) for v, t in
                    re.findall(r'<option[^>]*value="(\d+)"[^>]*>(.*?)</option>', sel.group(0) if sel else "")
                    if v != "0"]
    if max_cds:
        corsi = corsi[:max_cds]
    out = []
    for corso in corsi:
        n = _norm(corso["nome"])
        punti = sorted(((difflib.SequenceMatcher(None, n, _norm(o[2])).ratio(), o) for o in opzioni), reverse=True)
        lepre = punti[0][1] if punti and punti[0][0] >= 0.75 and (len(punti) == 1 or punti[0][0] - punti[1][0] > 0.05) \
            else None
        if lepre is None:  # «Conservazione e restauro dei beni culturali (abilitante …)» = «Conservazione e Restauro dei Beni Culturali»
            pref = [o for o in opzioni if len(_norm(o[2])) >= 20 and n.startswith(_norm(o[2]))]
            lepre = pref[0] if len(pref) == 1 else None
        piano = piano_corso(c, corso, anno, log)
        if not piano or not piano["voci"]:
            log(f"[{uid}] {corso['nome']}: nessun piano")
            continue
        voci_lepre, esami = [], {}
        if lepre:
            d, v, nome_l = lepre
            base = BASE.format(d)
            form = {"R1": v, "R3": "0", "R4": "0", "R5": f"{anno}/{anno + 1}", "R2": "1"}
            voci_lepre = leggi_programmi(_scarica(c, base + "programmi.asp?vr=1&mod=el", form))
            esami = leggi_esami(_scarica(c, base + "esami.asp?vr=1&mod=el",
                                         {"R1": v, "R3": "0", "R5": "0", "R4": "0", "R2": "1"}), anno,
                                base + "esami.asp")
            if voci_lepre:
                # schede: sia degli insegnamenti del corso sia degli altri corsi del dipartimento (crediti a scelta)
                pass
        else:
            log(f"[{uid}] {corso['nome']}: corso senza abbinamento nel LePrE")
        righe = righe_corso(piano, corso, oggi)
        items = []
        for r in sorted(righe, key=lambda r: (r["anno"], not r["obbl"], r["nome"])):
            link = _abbina(voci_lepre, re.sub(r" \(\d+ CFU\)$", "", r["nome"]), r["anno"], r["cfu"], r["curriculum"]) \
                if voci_lepre else []
            docenti = list(dict.fromkeys(r.get("docenti") or []))
            for v in link:
                docenti = list(dict.fromkeys(docenti + v["docenti"]))
            ap = []
            for v in link:
                for e in esami.get(_norm(v["nome"]), []):
                    if e not in ap:
                        ap.append(e)
            nota = r.get("nota")
            extra = None
            if r["gruppo"] and r["gruppo"]["kind"] == "scelta":
                g = r["gruppo"]
                extra = f"Gruppo del manifesto «{g['titolo']}»" + (f": se ne sceglie {g['n']}" if g["n"] else "")
            elif r["gruppo"] and r["gruppo"]["kind"] == "pfp":
                extra = f"Laboratorio obbligatorio del percorso {r['curr']}"
            elif r.get("cluster"):
                extra = f"Gruppo «{r['cluster']}»"
            nota = "; ".join(x for x in (nota, extra) if x) or None
            if r.get("ripiego"):
                nota = (nota + "; " if nota else "") + (
                    f"Piano del manifesto {r['aa']}/{(r['aa'] + 1) % 100:02d} (nessun manifesto della coorte "
                    f"che frequenta questo anno)")
            item = {
                "codice": None, "nome": r["nome"], "anno": r["anno"], "periodo": None, "cfu": r["cfu"],
                "ssd": r.get("ssd"), "obbligatorio": r["obbl"], "curriculum": r["curriculum"],
                "docenti": docenti,
                "url": (f"{BASE.format(lepre[0])}programma.asp?vr=1&id={link[0]['id']}" if link and lepre else
                        r.get("url_aaf") or r["fonte"]),
                "libri": [], "esami": ap, "fonte": r["fonte"], "verificato_il": oggi,
                "stato_libri": "da_aggiungere", "_p": [v["id"] for v in link],
            }
            if nota:
                item["nota"] = nota
            if ap:
                item["stato_esami"] = "completo"
            items.append(item)
        _id_espliciti(corso["id"], items)
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": corso.get("url"),
                    "curricula": piano["curricula"] if len(piano["curricula"]) > 1 else None,
                    "fonte": corso.get("url", "").rsplit("/", 1)[0].replace("http://", "https://") + "/manifesti.htm",
                    "verificato_il": oggi, "insegnamenti": items, "_lepre": lepre[0] if lepre else None})
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi, {len(items)} insegnamenti, {sum(len(i['esami']) for i in items)} appelli")

    def programma(i: dict) -> int:
        libri, viste = [], set()
        base = BASE.format(i.pop("_dip"))
        for pid in i.pop("_p"):
            d = riuso.get(pid)
            if d is None:
                try:
                    t = _scarica(c, base + f"programma.asp?vr=1&id={pid}")
                    d = leggi_programma(t) if t else None
                except Exception:  # noqa: BLE001
                    d = None
            if not d:
                continue
            if not i.get("ssd") and d.get("ssd") and _SSD_VECCHIO.match(d["ssd"]):
                i["ssd"] = d["ssd"]
            for lb in d["libri"]:
                if lb["citazione"] not in viste:
                    viste.add(lb["citazione"])
                    libri.append(lb)
        i["libri"] = libri
        i["stato_libri"] = "completo" if libri else "da_aggiungere"
        return len(libri)

    for x in out:
        for i in x["insegnamenti"]:
            i["_dip"] = x["_lepre"] or DIPARTIMENTI[0]
        x.pop("_lepre")
    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(3) as ex:
            trovati = sum(ex.map(programma, items))
    else:
        for i in items:
            i.pop("_p", None)
            i.pop("_dip", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    for p in PROBLEMI:
        log(f"[{uid}] PROBLEMA {p}")
    for p in DEDUZIONI:
        log(f"[{uid}] DEDUZIONE {p}")
    return {"universita_id": uid,
            "descrizione": "Generato dai manifesti degli studi e dal servizio LePrE di www.unisob.na.it (adapters/unisob.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
