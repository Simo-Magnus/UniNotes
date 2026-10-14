"""Appelli d'esame del Politecnico di Milano da fonti pubbliche, senza login.

1. «Info Appelli» (`onlineservices.polimi.it/info_appelli/app`, il servizio "Elenco appelli" linkato dai
   siti delle Scuole): l'app chiama un servizio REST pubblico
   - `POST /info_appelli/rest/search?lang=it` con `{"kCfScuola", "dataInizio", "dataFine"}` (date
     g/m/aaaa) → appelli già inseriti dai docenti: codice dell'insegnamento (`c_insegn_piano`),
     classe/scaglione (`c_classe`), sede (`sede_freq`), data e ora, aula, tipo (esame, prova in
     itinere, evento), a.a. e semestre dell'insegnamento;
   - `GET /info_appelli/rest/detail/cInsegn/<codice>/cClasse/<classe>` → periodo d'iscrizione.
2. Calendari (bozze) delle sessioni pubblicati in PDF dalle Scuole e dai Poli: sessione invernale
   gennaio/febbraio 2027 (Scuola 3I sede Leonardo e Bovisa 1° livello, Scuola ICAT corsi CIV e IAT,
   Polo di Piacenza) e prove in itinere di ottobre/novembre 2026. Si leggono con `pdftotext -table`
   (xpdf/poppler) riga per riga: codice dell'insegnamento, data, fascia o orario, docenti.

Gli appelli dipendono dalla sede (lo stesso codice può essere erogato a Milano e in un Polo con date
diverse): si assegnano a ogni insegnamento del contributo (corsi letti da adapters/polimi.py) per
codice e classe (le classi del dettaglio dell'insegnamento) o, se la classe non c'è, per codice e
sede della riga del manifesto. Per questo `fetch_appelli` scrive gli esami direttamente negli
insegnamenti dei corsi passati e restituisce un dizionario vuoto.
"""
from __future__ import annotations

import datetime as dt
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import time

import requests

from . import polimi
from .unibo import HEADERS, Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
REST = "https://onlineservices.polimi.it/info_appelli/rest"
APP = "https://onlineservices.polimi.it/info_appelli/app/"
SCUOLE = {222: "AUIC", 19: "Design", 1: "ICAT", 225: "3I"}

# (url, sede predefinita, tipo, descrizione)
PDF = [
    ("https://www.ingindinf.polimi.it/fileadmin/user_upload/upload/Studenti/Esami/2026-27/Invernale/Leo/"
     "Sessione_INVERNALE_20027_3I_LEO_sito.pdf", "MI", "appello",
     "Bozza calendario appelli sessione invernale 2027, Scuola 3I, 1° livello, sede Leonardo"),
    ("https://www.ingindinf.polimi.it/fileadmin/user_upload/upload/Studenti/Esami/2026-27/Invernale/BV/"
     "BOZZA_GEN_FEB_2027_3I_BV_1_LIVELLO_PAC_MEC_ENG_GES_AER_010926_sito.pdf", "BV", "appello",
     "Bozza calendario appelli sessione invernale 2027, Scuola 3I, 1° livello, sede Bovisa"),
    ("https://www.ingcat.polimi.it/fileadmin/asset/Studenti/Esami_di_profito/esame_di_profitto/INVERNALE_2026/"
     "Bozza_calendario_IAT_sessione-gen-febb_2027_agg_040826_sito.pdf.crdownload", "MI", "appello",
     "Bozza calendario sessione invernale 2027, Scuola ICAT, Ingegneria per l'Ambiente e il Territorio"),
    ("https://www.ingcat.polimi.it/fileadmin/asset/Studenti/Esami_di_profito/esame_di_profitto/"
     "Bozza_calendario_CIV_sessione-gen-febb_2027_agg030726_sito.pdf", "MI", "appello",
     "Bozza calendario sessione invernale 2027, Scuola ICAT, Ingegneria Civile"),
    ("https://www.polo-piacenza.polimi.it/fileadmin/user_upload/upload/Avvisi_Ingegneria/"
     "Appelli_invernali_ingegneria_2026_2027.pdf", "PC", "appello",
     "Calendario previsionale appelli sessione invernale, Polo di Piacenza, Ingegneria (insegnamenti 2026/27)"),
    ("https://www.polo-piacenza.polimi.it/fileadmin/user_upload/upload/Avvisi_Ingegneria/"
     "Appelli_invernali_ingegneria_2025_2026.pdf", "PC", "appello",
     "Calendario previsionale appelli sessione invernale, Polo di Piacenza, Ingegneria (insegnamenti 2025/26)"),
    ("https://www.ingindinf.polimi.it/fileadmin/user_upload/upload/Studenti/Esami/2026-27/PI_Novembre_26/"
     "Prove_itinere_novembre_2026_sito.pdf", "MI", "prova_in_itinere",
     "Bozza calendario prove in itinere novembre 2026, Scuola 3I, 1° livello, sede Leonardo"),
    ("https://www.ingindinf.polimi.it/fileadmin/user_upload/upload/Studenti/Esami/2026-27/PI_Novembre_26/"
     "BOZZA_ITINERE_N0V_2026_agg_280726_sito.pdf", "BV", "prova_in_itinere",
     "Bozza calendario prove in itinere novembre 2026, Scuola 3I, 1° livello, sede Bovisa"),
    ("https://www.ingcat.polimi.it/fileadmin/asset/Studenti/Esami_di_profito/prove__in_itinere/"
     "Bozza_calendario_Prove_in_itinere_ott-2026_020726_CIV_sito.pdf", "MI", "prova_in_itinere",
     "Bozza calendario prove in itinere ottobre 2026, Scuola ICAT, Ingegneria Civile"),
    ("https://www.ingcat.polimi.it/fileadmin/asset/Studenti/Esami_di_profito/prove__in_itinere/"
     "Bozza_calendario_Prove_in_Itinere_ott-2026_020726_IAT_sito.pdf", "MI", "prova_in_itinere",
     "Bozza calendario prove in itinere ottobre 2026, Scuola ICAT, Ingegneria per l'Ambiente e il Territorio"),
]

MESI = {"gen": 1, "feb": 2, "mar": 3, "apr": 4, "mag": 5, "giu": 6, "lug": 7, "ago": 8, "set": 9, "ott": 10,
        "nov": 11, "dic": 12}
SEDI = {"MI", "BV", "CR", "LC", "PC", "MN", "CO"}
FASCE = {"PRIMA": "F1", "SECONDA": "F2", "TERZA": "F3", "QUARTA": "F4"}
R_COD = re.compile(r"(?<![\d/.:,-])(0?\d{5})(?![\d/.:])")
# "07/01/27", "13 gennaio 2027", "25 GENNAIO", "30-ott" (non "1 mar": anno di corso e martedì)
R_DATA = re.compile(r"(?i)\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b|\b(\d{1,2})(?:\s+(?=(?:gennaio|febbraio|marzo|aprile|maggio|giugno|"
                    r"luglio|agosto|settembre|ottobre|novembre|dicembre)\b)|-(?=[a-z]{3}\b))"
                    r"(gen|feb|mar|apr|mag|giu|lug|ago|set|ott|nov|dic)[a-z]*(?:\s+(\d{4}))?\b")
R_ORA = re.compile(r"\b(\d{1,2})[:.](\d{2})\b")
R_FASCIA = re.compile(r"\b(F[1-4](?:\s*[-+]\s*F[1-4])?)\b|\b(PRIMA|SECONDA|TERZA|QUARTA)\b")
R_TURNO = re.compile(r"\b([1-4])°?\s*turno|tutto il\s+giorno", re.I)


def _anno(mese: int) -> int:
    """Calendari dell'a.a. 2026/27: da settembre 2026 a agosto 2027."""
    return 2026 if mese >= 9 else 2027


def _date(riga: str) -> list[str]:
    out = []
    for m in R_DATA.finditer(riga):
        if m.group(1):
            g, mm, a = int(m.group(1)), int(m.group(2)), int(m.group(3))
            a = a + 2000 if a < 100 else a
        else:
            g, mm = int(m.group(4)), MESI[m.group(5).lower()[:3]]
            a = int(m.group(6)) if m.group(6) else _anno(mm)
        try:
            out.append(dt.date(a, mm, g).isoformat())
        except ValueError:
            continue
    return out


def _pdf_righe(pdf: pathlib.Path) -> list[str]:
    exe = shutil.which("pdftotext")
    if not exe:
        raise RuntimeError("pdftotext non trovato")
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "t.txt"
        subprocess.run([exe, "-table", "-enc", "UTF-8", str(pdf), str(out)], check=True, capture_output=True)
        return out.read_text(encoding="utf-8", errors="replace").splitlines()


def leggi_pdf(righe: list[str], sede: str, tipo: str, fonte: str, titolo: str) -> list[dict]:
    """Righe con un codice d'insegnamento a 5-6 cifre e una data (sulla riga o, nelle celle andate a capo,
    su una riga vicina senza codici). Restituisce [{codice, data, ora, sede, tipo, docenti, note, fonte}]."""
    out = []
    cod_righe = [bool(R_COD.search(re.sub(r"\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}[:.]\d{2}", " ", r))) for r in righe]
    for i, riga in enumerate(righe):
        pulita = re.sub(r"\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}[:.]\d{2}", lambda m: " " * len(m.group()), riga)
        mc = R_COD.search(pulita)
        if not mc:
            continue
        codice = mc.group(1).zfill(6)
        date = _date(riga)  # la data è prima del codice (ICAT) o dopo (3I, Piacenza)
        resto = riga
        if not date:  # cella della data andata a capo: righe vicine senza altri codici
            for j in (i - 1, i + 1, i - 2, i + 2):
                if 0 <= j < len(righe) and not cod_righe[j]:
                    date += [d for d in _date(righe[j]) if d not in date]
                    resto += " " + righe[j]
        if not date:
            continue
        # nome dell'insegnamento: testo dopo il codice fino a due spazi
        nome = re.split(r"\s{2,}", riga[mc.end():].strip())[0].strip()
        ora = None
        fascia = R_FASCIA.search(resto)
        # orario d'inizio: il primo (le celle "08:00 - 11:30" possono andare a capo)
        ore = sorted(f"{int(h):02d}:{m}" for h, m in R_ORA.findall(resto) if 7 <= int(h) <= 20 and int(m) < 60)
        if ore:
            ora = ore[0]
        note = []
        if fascia and not ora:
            note.append(f"fascia oraria {fascia.group(1) or FASCE[fascia.group(2)]}")
        mt = R_TURNO.search(resto)
        if mt:
            note.append(mt.group(0).replace("  ", " "))
        ms = re.search(r"\b(MI|BV|CR|LC|PC|MN|CO)\b", riga[mc.end():])
        aa = re.match(r"\s*(20\d\d/20\d\d)\b", riga)
        if aa and aa.group(1) != "2026/2027":
            note.append(f"appello per gli iscritti all'insegnamento nell'a.a. {aa.group(1)}")
        if "ultima" in resto.lower() and "itinere" in resto.lower():
            tipo_r = "prova_in_itinere"
        elif re.search(r"(?i)consunt", resto):
            tipo_r = "appello"
        else:
            tipo_r = tipo
        for d in date:
            out.append({"codice": codice, "nome": nome or None, "data": d, "ora": ora,
                        "sede": ms.group(1) if ms else sede, "tipo": tipo_r,
                        "note": "; ".join(dict.fromkeys(note + [titolo])),
                        "fonte": fonte})
    return out


def _post(s: requests.Session, scuola: int, da: dt.date, a: dt.date) -> list[dict]:
    body = {"kCfScuola": scuola, "dataInizio": f"{da.day}/{da.month}/{da.year}",
            "dataFine": f"{a.day}/{a.month}/{a.year}"}
    for attempt in range(4):
        try:
            r = s.post(f"{REST}/search?lang=it", json=body, timeout=120)
            r.raise_for_status()
            return r.json() or []
        except (requests.RequestException, ValueError):
            time.sleep(5 * (attempt + 1))
    return []


def info_appelli(da: dt.date, a: dt.date, log=print) -> list[dict]:
    """Appelli di Info Appelli fra le due date, per tutte le Scuole, con il periodo d'iscrizione."""
    s = requests.Session()
    s.headers.update(HEADERS)
    grezzi = []
    for k in SCUOLE:
        lst = _post(s, k, da, a)
        log(f"[polimi] info_appelli scuola {SCUOLE[k]}: {len(lst)} righe")
        grezzi += lst
        time.sleep(2)
    # periodo d'iscrizione dal dettaglio (uno per codice+classe)
    iscr: dict[int, str] = {}
    c = Client(rate=2.0)
    oggi = dt.date.today().isoformat()  # le iscrizioni servono solo per gli appelli futuri
    for cod, cl in sorted({(x["c_insegn_piano"], x["c_classe"]) for x in grezzi
                           if (x.get("d_appello") or "")[:10] >= oggi}):
        r = c.get(f"{REST}/detail/cInsegn/{cod}/cClasse/{cl}?lang=it")
        try:
            for d in json.loads(r.text) if r else []:
                if d.get("periodo_iscrizioni"):
                    iscr[d["c_appello"]] = d["periodo_iscrizioni"]
        except ValueError:
            continue
    out = []
    for x in grezzi:
        t = (x.get("xTipoAppello") or "").upper()
        if "ITINERE" in t and "REGISTRAZIONE" not in t:
            tipo = "prova_in_itinere"
        elif t == "ESAME":
            tipo = "appello"
        else:
            continue  # eventi generici, registrazione degli esiti
        data = (x.get("d_appello") or "")[:10]
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", data):
            continue
        dal = al = None
        m = re.match(r"(\d{2})/(\d{2})/(\d{4})\s*-\s*(\d{2})/(\d{2})/(\d{4})", iscr.get(x.get("c_appello"), ""))
        if m:
            dal, al = f"{m.group(3)}-{m.group(2)}-{m.group(1)}", f"{m.group(6)}-{m.group(5)}-{m.group(4)}"
        note = [x["messaggio"].strip()] if (x.get("messaggio") or "").strip() else []
        sem = x.get("xAa_semestre") or ""
        if sem and "2026/2027" not in sem:
            note.append(f"appello per gli iscritti all'insegnamento nell'a.a. {sem.split(' - ')[-1]}")
        aula = (x.get("xAula") or "").strip()
        out.append({
            "codice": x["c_insegn_piano"], "classe": x.get("c_classe"), "sede": x.get("sede_freq"),
            "nome": re.sub(r"^\d+\s*-\s*", "", x.get("xInsegnamento") or "") or None,
            "data": data, "ora": x.get("h_appello") if re.fullmatch(r"\d{2}:\d{2}", x.get("h_appello") or "") else None,
            "luogo": None if not aula or aula.lower().startswith(("non ancora", "se non specificata")) else
            f"{aula} ({x.get('desc_sede_freq')})" if x.get("desc_sede_freq") else aula,
            "tipo": tipo, "iscrizioni_dal": dal, "iscrizioni_al": al,
            "docenti": (x.get("n_docente") or "").strip() or None, "note": "; ".join(note) or None,
            "fonte": APP, "_id": x.get("c_appello"),
        })
    return out


def calendari_pdf(cartella: pathlib.Path, log=print) -> list[dict]:
    cartella.mkdir(parents=True, exist_ok=True)
    s = requests.Session()
    s.headers.update(HEADERS)
    out = []
    for url, sede, tipo, titolo in PDF:
        f = cartella / re.sub(r"\.crdownload$", "", url.rsplit("/", 1)[1])
        if not f.exists():
            try:
                r = s.get(url, timeout=120)
                r.raise_for_status()
                if not r.content.startswith(b"%PDF"):
                    raise ValueError("non è un PDF")
                f.write_bytes(r.content)
                time.sleep(1)
            except (requests.RequestException, ValueError) as e:
                log(f"[polimi] PDF non letto {url}: {e!r}")
                continue
        righe = leggi_pdf(_pdf_righe(f), sede, tipo, url, titolo)
        log(f"[polimi] {f.name}: {len(righe)} date")
        out += righe
    return out


def _sedi_e_classi(corsi: list[dict], log=print) -> dict[int, tuple[set[str], set[int]]]:
    """id(insegnamento) -> (sedi delle righe del manifesto, classi del dettaglio), dalle stesse pagine
    lette da adapters/polimi.py (con UN_HTTP_CACHE si rileggono dalla cache)."""
    c = Client(rate=3.0)
    piani: dict[str, list[dict]] = {}
    out = {}
    for corso in corsi:
        for i in corso.get("insegnamenti") or []:
            sedi, classi = set(), set()
            f = i.get("fonte")
            if f and "ManifestoPublic" in f:
                if f not in piani:
                    r = polimi._get_valid(c, f, 'name="k_corso_la"')
                    piani[f] = polimi.leggi_manifesto(r.text) if r else []
                sedi = {x["sede"] for x in piani[f] if x["codice"] == i.get("codice") and x.get("sede")}
            u = i.get("url")
            if u and "EVN_DETTAGLIO_RIGA_MANIFESTO" in u:
                r = polimi._get_valid(c, u, "Dati Insegnamento")
                if r:
                    classi = {int(x) for x in polimi.leggi_dettaglio(r.text)[1]}
                    if not sedi:
                        m = re.search(r"\(ord\.[^)]*\)\s*-\s*([A-Z]{2})\s*\(\d+\)", r.text)
                        sedi = {m.group(1)} if m else set()
            out[id(i)] = (sedi, classi)
    log(f"[polimi] sedi e classi lette per {len(out)} insegnamenti ({c.requests} richieste)")
    return out


def assegna(corsi: list[dict], appelli: list[dict], sc: dict[int, tuple[set[str], set[int]]]) -> int:
    per_cod: dict[str, list[dict]] = {}
    for e in appelli:
        per_cod.setdefault(e["codice"], []).append(e)
    n = 0
    for corso in corsi:
        for i in corso.get("insegnamenti") or []:
            cand = per_cod.get(i.get("codice") or "")
            if not cand:
                continue
            sedi, classi = sc.get(id(i), (set(), set()))
            scelti = [e for e in cand if e.get("classe") and e["classe"] in classi]
            scelti += [e for e in cand if not (e.get("classe") and e["classe"] in classi) and
                       (not sedi or not e.get("sede") or e["sede"] in sedi)]
            esami, viste = list(i.get("esami") or []), {(x.get("data"), x.get("ora"), x.get("tipo"))
                                                        for x in i.get("esami") or []}
            # prima Info Appelli (ora e aula), poi i calendari PDF solo per le date che mancano
            for e in sorted(scelti, key=lambda e: (e["data"], e["fonte"] != APP, e.get("ora") or "")):
                k = (e["data"], e.get("ora"), e["tipo"])
                if k in viste or (e["data"], None, e["tipo"]) in viste or (
                        e["fonte"] != APP and any(v[0] == e["data"] and v[2] == e["tipo"] for v in viste)):
                    continue
                viste.add(k)
                esami.append({"tipo": e["tipo"], "titolo": None, "data": e["data"], "ora": e.get("ora"),
                              "luogo": e.get("luogo"), "modalita": None,
                              "iscrizioni_dal": e.get("iscrizioni_dal"), "iscrizioni_al": e.get("iscrizioni_al"),
                              "docenti": e.get("docenti"), "note": e.get("note"), "fonte": e["fonte"]})
            if len(esami) > len(i.get("esami") or []):
                i["esami"] = sorted(esami, key=lambda x: (x["data"] or "", x.get("ora") or ""))
                i["stato_esami"] = "completo"
                n += 1
    return n


def fetch_appelli(uid: str = "polimi", corsi: list[dict] | None = None, log=print,
                  cartella: pathlib.Path | None = None) -> dict[str, list[dict]]:
    """Scrive gli esami negli insegnamenti di `corsi` (contributo di adapters/polimi.py); restituisce {}."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    oggi = dt.date.today()
    inizio = max(dt.date(oggi.year if oggi.month >= 9 else oggi.year - 1, 9, 12), oggi - dt.timedelta(days=199))
    appelli = info_appelli(inizio, oggi + dt.timedelta(days=199), log=log)
    log(f"[polimi] info_appelli: {len(appelli)} date d'esame")
    try:
        appelli += calendari_pdf(cartella or pathlib.Path(tempfile.gettempdir()) / "polimi_pdf", log=log)
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:  # es. pdftotext non installato
        log(f"[polimi] calendari PDF non letti: {e!r}")
    # solo l'a.a. corrente: le lezioni del 1° semestre iniziano a metà settembre; la sessione di recupero
    # di fine agosto/inizio settembre è dell'a.a. precedente
    aa = oggi.year if oggi.month >= 9 else oggi.year - 1
    appelli = [e for e in appelli if e["data"] >= f"{aa}-09-12"]
    n = assegna(corsi, appelli, _sedi_e_classi(corsi, log=log))
    log(f"[polimi] insegnamenti con appelli: {n}")
    return {}
