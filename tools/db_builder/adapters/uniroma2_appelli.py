"""Tor Vergata: appelli d'esame dalle pagine pubbliche di DidatticaWeb (https://didatticaweb.uniroma2.it).

DidatticaWeb ("Lista dei corsi" per Facoltà e anno accademico, visitatore senza login) ha per ogni
insegnamento la scheda `/it/esami/index/insegnamento/<id>-<slug>` con gli «Esami calendarizzati»:
data, ora, aula, sessione, modalità e periodo di prenotazione. Il codice di verbalizzazione non è
quello del regolamento GOMP e cambia da un anno all'altro: gli appelli si abbinano agli
insegnamenti già raccolti da `uniroma2.py` per nome (normalizzato) e docente.

Si tengono solo gli appelli non ancora passati (`date_box` senza la classe `old`).
Al massimo 2 richieste al secondo; cache su disco (UN_HTTP_CACHE, cartella «uniroma2_dw») con scadenza
di un giorno per le pagine degli appelli.
"""
from __future__ import annotations

import hashlib
import html
import os
import pathlib
import re
import time
import unicodedata
from datetime import date

import requests

from .unibo import HEADERS

BASE = "https://didatticaweb.uniroma2.it"
FACOLTA = ["1-Economia", "2-Giurisprudenza", "3-Ingegneria", "4-Lettere", "5-Medicina", "6-Scienze"]
ANNI = [("20", "2026-2027"), ("19", "2025-2026")]  # id interno dell'anno accademico su DidatticaWeb
MESI = {m: i for i, m in enumerate(["January", "February", "March", "April", "May", "June", "July", "August",
                                    "September", "October", "November", "December"], 1)}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", html.unescape(s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class Client:
    def __init__(self, rate: float = 1.8, scadenza_h: float = 20.0):
        self.s, self.gap, self.last, self.requests = requests.Session(), 1.0 / rate, 0.0, 0
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "uniroma2_dw" if d else None
        self.scadenza = scadenza_h * 3600
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, url: str) -> str | None:
        f = self.dir / hashlib.sha1(url.encode()).hexdigest() if self.dir else None
        if f and f.exists() and time.time() - f.stat().st_mtime < self.scadenza:
            return f.read_text(encoding="utf-8")
        for tentativo in range(4):
            attesa = self.last + self.gap - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            self.last = time.monotonic()
            self.requests += 1
            try:
                r = self.s.get(url, headers=HEADERS, timeout=60)
                if r.status_code == 200:
                    r.encoding = "utf-8"
                    if f:
                        f.write_text(r.text, encoding="utf-8")
                    return r.text
                if r.status_code in (404, 410):
                    return None
            except requests.RequestException:
                pass
            time.sleep(2 ** tentativo)
        return None


def lista_corsi(c: Client, fac: str, anno: tuple[str, str], log=print) -> list[dict]:
    """Insegnamenti (non moduli) di una Facoltà in un anno accademico: id, nome, corso di laurea, docenti."""
    url0 = f"{BASE}/it/corsi/index/{fac}/{anno[0]}-{anno[1]}"
    t = c.get(url0)
    m = re.search(r"\(#(\d+)\)", t or "")
    if not t or not m or int(m.group(1)) == 0:
        return []
    totale = int(m.group(1))
    out = []
    for off in range(0, totale, 20):
        pag = t if off == 0 else c.get(f"{BASE}/corsi/index/{fac}/{anno[0]}-{anno[1]}/{off}")
        for riga in re.findall(r"<tr class=\"(?:even|odd)\">(.*?)</tr>", pag or "", flags=re.S):
            mi = re.search(r'href="[^"]*/informazioni/index/insegnamento/(\d+-[^/"]*)/?\d*"[^>]*>(.*?)</a>', riga, flags=re.S)
            if not mi:
                continue
            cdl = re.search(r"<!--\s*<td>(.*?)</td>\s*-->", riga, flags=re.S)
            out.append({"id": mi.group(1), "nome": html.unescape(mi.group(2)).strip(),
                        "cdl": html.unescape(cdl.group(1)).strip() if cdl else "",
                        "docenti": [html.unescape(re.sub(r"<[^>]+>", "", d)).strip()
                                    for d in re.findall(r'/docenti/curriculum/[^"]+">(.*?)</a>', riga, flags=re.S)],
                        "fac": fac, "anno": anno[1]})
    log(f"[uniroma2-dw] {fac} {anno[1]}: {len(out)} insegnamenti (su {totale} righe)")
    return out


def appelli_insegnamento(c: Client, id_: str) -> list[dict]:
    t = c.get(f"{BASE}/it/esami/index/insegnamento/{id_}")
    out = []
    for b in (t or "").split('<div class="section box">')[1:]:
        if "date_box" not in b or 'date_box old' in b:
            continue
        mt = re.search(r'title="(\w+) (\d{4}) \(\w+\)">(\d{1,2})</p>', b)
        if not mt or mt.group(1) not in MESI:
            continue
        data = f"{int(mt.group(2)):04d}-{MESI[mt.group(1)]:02d}-{int(mt.group(3)):02d}"

        def campo(nome: str) -> str | None:
            m = re.search(rf"<strong[^>]*>{nome}:</strong>\s*(.*?)\s*(?=<strong|<hr|</div>|$)", b, flags=re.S)
            v = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", m.group(1)))).strip() if m else ""
            return v or None

        ora = re.search(r"(\d{1,2}:\d{2})", campo("Orari") or "")
        tip = (campo("Tipologia") or "").lower()
        mod = (campo("Modalità") or campo("Modalit&agrave;") or "").lower()
        modalita = {"orale": "orale", "scritto": "scritto", "scritto e orale": "scritto+orale", "pratico": "altro",
                    "scritto + orale": "scritto+orale"}.get(mod, "altro" if mod else None)

        def giorno(v: str | None) -> str | None:
            m = re.match(r"(\d{1,2}) (\w+), (\d{4})", v or "")
            return f"{int(m.group(3)):04d}-{MESI[m.group(2)]:02d}-{int(m.group(1)):02d}" if m and m.group(2) in MESI else None

        sess = " ".join(x for x in [(campo("Appello") or ""), "-", (campo("Sessione") or "")] if x and x != "-")
        out.append({"tipo": "prova_in_itinere" if re.search(r"itinere|parziale", tip) else "appello",
                    "titolo": (f"Appello {campo('Appello')} - sessione {campo('Sessione').lower()}"
                               if campo("Appello") and campo("Sessione") else (sess or None)),
                    "data": data, "ora": ora.group(1) if ora else None, "luogo": campo("Aula / Luogo"),
                    "modalita": modalita, "iscrizioni_dal": giorno(campo("Inizio Prenotazioni")),
                    "iscrizioni_al": giorno(campo("Fine Prenotazioni")), "docenti": None, "note": campo("Tipologia"),
                    "fonte": f"{BASE}/it/esami/index/insegnamento/{id_}"})
    return out


def _chiavi_nome(nome: str) -> set[str]:
    n = _norm(nome)
    n = re.sub(r"\b(?:lm|lmcu|laurea magistrale)\b", " ", n)
    n = re.sub(r"\s+", " ", n).strip()
    ks = {n}
    base = re.sub(r"\s+(?:a|b|c|d|al|mz|a l|m z|a k|l z|unico|canale [a-z]+)$", "", n)
    if base:
        ks.add(base)
    return {k for k in ks if k}


def _cognomi(docenti: list[str]) -> set[str]:
    return {t for d in docenti for t in _norm(d).split() if len(t) >= 4}


def abbina(corsi_out: list[dict], elenco: list[dict]) -> dict[str, list[dict]]:
    """id DidatticaWeb -> insegnamenti (dict del contributo) con lo stesso nome e almeno un docente in comune."""
    per_nome: dict[str, list[dict]] = {}
    for c in corsi_out:
        for i in c["insegnamenti"]:
            for k in _chiavi_nome(i["nome"]):
                per_nome.setdefault(k, []).append(i)
    out: dict[str, list[dict]] = {}
    nomi_dw: dict[str, int] = {}
    for e in elenco:
        for k in _chiavi_nome(e["nome"]):
            nomi_dw[k] = nomi_dw.get(k, 0) + 1
    for e in elenco:
        cogn = _cognomi(e["docenti"])
        trovati = []
        for k in _chiavi_nome(e["nome"]):
            for i in per_nome.get(k, []):
                dbc = _cognomi(i.get("docenti") or [])
                if (dbc & cogn) or (not dbc and nomi_dw.get(k) == 1):
                    if i not in trovati:
                        trovati.append(i)
        if trovati:
            out[e["id"]] = trovati
    return out


_NON_VERO = re.compile(r"prova finale|tesi|tirocini|stage|internship|altre attivit|ulteriori attivit|idoneit|a scelta|"
                       r"scelta libera|crediti liberi|attivit[aà] formative|seminari|final exam|thesis|elective|esame finale|"
                       r"abilit[aà] informatiche|\bofa\b|corso zero", re.I)
_TESTI_INIZIO = re.compile(r"(?i)^(?:libri? di testo|testi? (?:adottati|consigliati|di riferimento|d'esame|obbligatori)|"
                           r"bibliografia(?: d'esame| di riferimento| essenziale)?|letture obbligatorie)\s*(?:[:\-–]\s*(.*))?$")
_TESTI_FINE = re.compile(r"(?i)^(?:modalit|prerequisit|obiettiv|programma\b|orario|metodi|criteri|frequenza|esame\b|"
                         r"ricevimento|propedeuticit|contenuti|argomenti|syllabus|materiale didattico|note\b)")


def libri_da_programma(html_programma: str) -> list[dict]:
    """Libri citati nella pagina «Programma» di DidatticaWeb, sotto un titolo «Libri di testo», «Testi adottati»,
    «Testi consigliati» o «Bibliografia» (altrimenti nessuno: la pagina è di solito solo l'elenco degli argomenti)."""
    from .uniroma2_testi import libri_da_brano, unisci_righe
    i = html_programma.find("Aggiungi il corso ai tuoi preferiti")
    corpo = html.unescape(re.sub(r"<[^>]+>", "\n", html_programma[i:] if i >= 0 else html_programma))
    righe = [re.sub(r"\s+", " ", r.replace("\xa0", " ")).strip() for r in corpo.split("\n")]
    righe = [r for r in righe if r]
    raccolti: list[str] = []
    k = 0
    while k < len(righe):
        m = _TESTI_INIZIO.match(righe[k])
        if not m:
            k += 1
            continue
        if m.group(1):
            raccolti.append(m.group(1))
        j, n = k + 1, 0
        while j < len(righe) and n < 30 and not (_TESTI_FINE.match(righe[j]) and not _TESTI_INIZIO.match(righe[j])):
            if not _TESTI_INIZIO.match(righe[j]):
                raccolti.append(righe[j])
            j += 1
            n += 1
        k = j
    return libri_da_brano(unisci_righe("\n".join(raccolti))) if raccolti else []


def aggiungi_libri_da_programmi(c: "Client", ab: dict[str, list[dict]], log=print) -> int:
    """Per gli insegnamenti ancora senza libri, i testi dalla pagina «Programma» di DidatticaWeb (a.a. 2025/26)."""
    n_ok, letti = set(), 0
    for id_, items in ab.items():
        mancanti = [i for i in items if not i["libri"] and not _NON_VERO.search(i["nome"])]
        if not mancanti:
            continue
        url = f"{BASE}/it/programma/index/insegnamento/{id_}"
        t = c.get(url)
        letti += 1
        if not t:
            continue
        libri = libri_da_programma(t)
        for i in mancanti:
            if libri and not i["libri"]:
                i["libri"] = [dict(lb, note=f"Programma su DidatticaWeb a.a. 2025/26: {url}") for lb in libri]
                i["stato_libri"] = "completo"
                n_ok.add(id(i))
        if letti % 200 == 0:
            log(f"[uniroma2-dw]   programmi letti {letti} (richieste: {c.requests}), libri trovati per {len(n_ok)} insegnamenti")
    log(f"[uniroma2-dw] libri dai programmi di DidatticaWeb: {len(n_ok)} insegnamenti ({letti} pagine)")
    return len(n_ok)


def aggiungi_appelli(corsi_out: list[dict], log=print) -> int:
    """Aggiunge `esami` (appelli futuri) agli insegnamenti; restituisce il numero di insegnamenti coperti."""
    c = Client()
    oggi = date.today().isoformat()
    limite = date(date.today().year + 1, 12, 31).isoformat()
    elenco = []
    for fac in FACOLTA:
        for anno in ANNI:
            elenco += lista_corsi(c, fac, anno, log)
    ab = abbina(corsi_out, elenco)
    log(f"[uniroma2-dw] {len(elenco)} insegnamenti su DidatticaWeb, {len(ab)} abbinati a insegnamenti del database")
    coperti = set()
    for n, (id_, items) in enumerate(ab.items(), 1):
        ap = [a for a in appelli_insegnamento(c, id_) if oggi <= a["data"] <= limite]  # niente errori di battitura (es. 2064)
        for a in ap:
            for i in items:
                if not any(x["data"] == a["data"] and x["ora"] == a["ora"] for x in i["esami"]):
                    i["esami"].append(dict(a))
                coperti.add(id(i))
        if n % 200 == 0:
            log(f"[uniroma2-dw]   appelli letti {n}/{len(ab)} (richieste: {c.requests})")
    try:
        aggiungi_libri_da_programmi(c, ab, log)
    except Exception as e:  # noqa: BLE001 - i programmi sono un di più
        log(f"[uniroma2-dw] ERRORE programmi: {e!r}")
    for cc in corsi_out:
        for i in cc["insegnamenti"]:
            i["esami"].sort(key=lambda a: (a["data"], a["ora"] or ""))
            i["stato_esami"] = "completo" if i["esami"] else "da_aggiungere"
    log(f"[uniroma2-dw] insegnamenti con appelli futuri: {len(coperti)}; richieste: {c.requests}")
    return len(coperti)
