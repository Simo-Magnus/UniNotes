"""Insegnamenti, docenti e libri dell'Università di Bologna dai siti dei corsi.

UniBo non usa il Course Catalogue Cineca: pubblica l'offerta su `corsi.unibo.it`.

- `<sito corso>/insegnamenti` (e `?code=<codice>` per gli ordinamenti precedenti)
  → elenco dei piani didattici: `…/insegnamenti/piano/<a.a.>/<codice>/<curr>/000/<coorte>`
- pagina del piano → "Primo Anno di Corso", "Secondo…" → tabelle con codice,
  nome, periodo, tipo attività, SSD e CFU; le sezioni "obbligatorie" e "a scelta"
- scheda dell'insegnamento (`www.unibo.it/…/insegnamento/<a.a.>/<id>`) → docente
  e sezione "Testi/Bibliografia" (o "Readings/Bibliography").

Le righe "non attivo / not available for the year" (e i moduli dei corsi integrati non
attivati) non si tengono; i moduli portano il codice del corso integrato (`_ci`, campo interno
che adapters/unibo_appelli.py usa per gli appelli e poi toglie). Se il riconoscimento generico
dei libri non trova nulla (o solo frammenti) si leggono le righe della sezione con
`libri_fallback`; il tipo obbligatorio/consigliato viene dalle intestazioni della sezione.

Per l'anno di corso k nell'a.a. A si usa il piano della coorte A-k+1, come per il
Course Catalogue. I corsi sono quelli già presenti in database/corsi/unibo.json
(da Universitaly), con il loro `id`: build_db.py li associa senza ambiguità.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import html
import json
import os
import pathlib
import re
import threading
import time

import requests

from .testi import _EDITORI_CIT, _libero, _sembra_libro, estrai_libri, html_to_lines

ROOT = pathlib.Path(__file__).resolve().parents[3]
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
ORDINALI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6,
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6}
PIANO = re.compile(r'href="(https://corsi\.unibo\.it/[^"]*/(?:insegnamenti|course-structure-diagram)/piano/(\d{4})/(\w+)/(\w+)/(\w+)/(\d{4}))"[^>]*>'
                   r'(.*?)</a>', re.S)


class _Cached:
    def __init__(self, url: str, text: str):
        self.url, self.text, self.status_code = url, text, 200


class Client:
    """GET con limite di richieste al secondo. Con la variabile d'ambiente UN_HTTP_CACHE
    (una cartella) le pagine scaricate si salvano su disco: una raccolta interrotta riparte
    senza riscaricare ciò che ha già letto."""

    def __init__(self, rate: float = 5.0):
        self.s = requests.Session()
        self.s.headers.update(HEADERS)
        self.lock = threading.Lock()
        self.min_gap = 1.0 / rate
        self.last = 0.0
        self.requests = 0
        cache = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(cache) if cache else None

    def get(self, url: str) -> requests.Response | _Cached | None:
        if self.cache:
            key = hashlib.sha1((url + "|" + json.dumps(sorted(self.s.headers.items()))).encode()).hexdigest()
            f = self.cache / key[:2] / f"{key}.json"
            if f.exists():
                d = json.loads(f.read_text(encoding="utf-8"))
                return _Cached(d["url"], d["text"]) if d["ok"] else None
            r = self._get(url)
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps({"ok": r is not None, "url": r.url if r else url, "text": r.text if r else ""}),
                         encoding="utf-8")
            return r
        return self._get(url)

    def _get(self, url: str) -> requests.Response | None:
        for attempt in range(4):
            with self.lock:
                wait = self.last + self.min_gap - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
                self.last = time.monotonic()
                self.requests += 1
            try:
                r = self.s.get(url, timeout=60)
                if r.status_code == 404:
                    return None
                r.raise_for_status()
                r.encoding = "utf-8"
                return r
            except requests.RequestException:
                time.sleep(2 ** attempt)
        return None


def _testo(s: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s or ""))).strip()


def _titolo(des: str) -> str:
    """Nomi in maiuscolo -> iniziale maiuscola (le sigle restano)."""
    des = re.sub(r"\s+", " ", des).strip()
    if not des.isupper():
        return des
    small = {"e", "di", "del", "della", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla", "il",
             "la", "lo", "le", "gli", "i", "ed", "nel", "nella", "sul", "tra", "and", "of", "the", "for", "to"}
    out = []
    for i, w in enumerate(des.lower().split()):
        if re.fullmatch(r"[ivx]+|c\.i\.|t-?\d*|[a-z]-\d+", w) and w not in ("i", "di"):
            out.append(w.upper())
        elif i and w in small:
            out.append(w)
        else:
            out.append(w[:1].upper() + w[1:])
    return " ".join(out)


def _curriculum(etichetta: str) -> str | None:
    """'Curriculum X: per studenti immatricolati…' -> 'X'; 'Piano didattico per studenti
    immatricolati…' -> None; 'Piano … del percorso di Doppio Titolo … immatricolati' -> 'percorso di …'."""
    t = _testo(etichetta)
    m = re.match(r"(?i)curriculum\s+(.*?)\s*:", t)
    if m:
        return m.group(1).strip()
    m = re.search(r"(?i)per studenti (?:del|della|dei)\s+(.*?)\s+immatricolati", t)
    if m:
        return m.group(1).strip()
    m = re.match(r"(?i)(.*?)\s*:\s*(?:piano|per studenti|study plan|for students)", t)
    if m and not re.match(r"(?i)piano didattico|study plan", m.group(1)):
        return m.group(1).strip()
    return None


def _periodi(s: str) -> dict[str, tuple[str, str]]:
    """Legenda 'periodo': '1: 14/09/2026 - 18/12/2026 2: … E: …' -> {codice: (inizio, fine)}."""
    m = re.search(r'class="info">\s*(?:periodo|period)\s*<span class="legend">.*?<span>(.*?)</span>', s, re.S | re.I)
    if not m:
        return {}
    return {k: (a, b) for k, a, b in re.findall(r"(\w+):\s*(\d\d/\d\d/\d{4})\s*-\s*(\d\d/\d\d/\d{4})", _testo(m.group(1)))}


def _periodo(cod: str, legenda: dict[str, tuple[str, str]]) -> str | None:
    cod = cod.strip()
    if not cod:
        return None
    if cod.isdigit():
        return cod
    date = legenda.get(cod)
    if date:
        for k, v in legenda.items():
            if k.isdigit() and v == date:
                return k
        semestri = [v for k, v in legenda.items() if k.isdigit()]
        if len(semestri) >= 2 and date[0] == semestri[0][0] and date[1] == semestri[-1][1]:
            return "annuale"
    return cod


def leggi_piano(s: str, anno_corso: int) -> list[dict]:
    """Righe del piano per l'anno di corso indicato."""
    legenda = _periodi(s)
    sezioni = re.split(r"<h3[^>]*>(.*?)</h3>", s, flags=re.S)
    out = []
    for titolo_h3, corpo in zip(sezioni[1::2], sezioni[2::2]):
        m = re.match(r"(\w+)", _testo(titolo_h3).lower())
        if not m or ORDINALI.get(m.group(1)) != anno_corso:
            continue
        gruppi = re.split(r"<h4[^>]*>(.*?)</h4>", corpo, flags=re.S)
        for i in range(0, len(gruppi), 2):
            gruppo = _testo(gruppi[i - 1]) if i else ""
            obbl = bool(re.search(r"(?i)obbligatori|mandatory|compulsory", gruppo))
            padre = None
            for tabella in re.findall(r"<table[^>]*>(.*?)</table>", gruppi[i], re.S):
                # colonne: codice, nome e poi (non sempre tutte) periodo, tipo, ssd, cfu
                intest = [(_testo(re.sub(r'<span class="legend">.*', "", h, flags=re.S)).split() or [""])[0].lower()
                          for h in re.findall(r"<th[^>]*>(.*?)</th>", tabella, re.S)]
                col = {n: k for k, n in enumerate(intest) if n}
                col = {"periodo": col.get("periodo", col.get("period")), "tipo": col.get("tipo", col.get("type")),
                       "ssd": col.get("ssd"), "cfu": col.get("cfu", col.get("credits"))}
                for tr_attr, tr in re.findall(r"<tr([^>]*)>(.*?)</tr>", tabella, re.S):
                    celle = [c[1] for c in re.findall(r"<td( [^>]*)?>(.*?)</td>", tr, re.S)]
                    if len(celle) < 2:
                        continue
                    padre = _riga(celle, col, tr_attr, obbl, legenda, padre, out)
    return out


NON_ATTIVO = re.compile(r"(?i)non attiv[oa]|not active|not available for the year|non disponibile per l")


def _riga(celle: list[str], col: dict, tr_attr: str, obbl: bool, legenda: dict, padre: tuple | None,
          out: list[dict]) -> tuple | None:
    """Aggiunge a `out` la riga del piano; restituisce (nome, codice) dell'ultimo insegnamento
    "padre" (per i moduli dei corsi integrati, righe con class="modulo")."""
    def cella(nome: str) -> str:
        k = col.get(nome)
        return celle[k] if k is not None and k < len(celle) else ""

    cod, tit = celle[0], celle[1]
    per, tipo, ssd, cfu = cella("periodo"), cella("tipo"), cella("ssd"), cella("cfu")
    link = re.search(r'href="([^"]+)"', tit)
    nome_cod = _testo(re.split(r"(?i)<br\s*/?>", tit)[0])  # dopo l'a-capo c'è la descrizione dell'attività
    codice = _testo(cod)
    modulo = "modulo" in tr_attr
    if modulo and not codice:
        mm = re.match(r"(\w+)\s+(.*)", nome_cod)
        if mm:
            codice, nome_cod = mm.group(1), mm.group(2)
    if not modulo:
        padre = (nome_cod, codice or None)
    cfu_t = _testo(cfu).replace(",", ".")
    riga = {
        "codice": codice or None, "nome": _titolo(nome_cod.strip()), "periodo_cod": _testo(per),
        "ssd": _testo(ssd) or None, "cfu": float(cfu_t) if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None,
        "tipo_attivita": _testo(tipo) or None, "obbligatorio": obbl,
        "url_ricerca": html.unescape(link.group(1)) if link else None,
        "modulo_di": _titolo(padre[0]) if modulo and padre else None,
        "codice_ci": padre[1] if modulo and padre else None,
    }
    if riga["cfu"] is not None and riga["cfu"].is_integer():
        riga["cfu"] = int(riga["cfu"])
    # Il corso integrato senza CFU propri si rappresenta con i suoi moduli.
    if not modulo and not link and riga["cfu"] is None:
        return padre
    # insegnamenti (o moduli di corsi integrati) non attivati nell'anno: non si tengono
    if NON_ATTIVO.search(nome_cod) or (modulo and padre and NON_ATTIVO.search(padre[0])):
        return padre
    riga["periodo"] = _periodo(riga["periodo_cod"], legenda)
    d = legenda.get(riga["periodo_cod"])
    riga["periodo_inizio"], riga["periodo_fine"] = d if d else (None, None)
    out.append(riga)
    return padre


def _blocchi_testi(s: str) -> str | None:
    m = re.search(r"<h2>\s*(?:Testi/Bibliografia|Readings/Bibliography)\s*</h2>(.*?)(?:<h2>|<footer|</article>)", s,
                  re.S | re.I)
    return m.group(1) if m else None


def libri_da_scheda(sezione: str) -> list[dict]:
    """Ogni paragrafo/voce di elenco è un riferimento; se un paragrafo contiene più
    riferimenti separati da a-capo, si tengono le righe."""
    libri, viste = [], set()
    blocchi = re.findall(r"<(p|li)[^>]*>(.*?)</\1>", sezione, re.S) or [("p", sezione)]
    for _, b in blocchi:
        righe = [r for r in html_to_lines(b)]
        if len(righe) > 1 and sum(_sembra_libro(r) for r in righe) >= 2:
            candidati = [(r, None, None) for r in righe]
        else:
            unito = _testo(re.sub(r"(?i)<br\s*/?>", " ", b))
            strong = [_testo(x) for x in re.findall(r"<strong>(.*?)</strong>", b, re.S) if _testo(x)]
            em = [_testo(x) for x in re.findall(r"<em>(.*?)</em>", b, re.S) if _testo(x)]
            candidati = [(unito, strong[0] if len(strong) == 1 else None, em[0] if len(em) == 1 else None)]
        for testo, tit, aut in candidati:
            testo = testo.strip().lstrip(".;,:-–•*· ").strip()
            for lb in estrai_libri(html.escape(testo)):
                if tit and 3 <= len(tit) <= 200 and tit != lb["citazione"]:
                    lb["titolo"] = tit.strip(" .,")
                    if aut and aut != tit and len(aut) <= 200:
                        lb["autori"] = aut.strip(" .,")
                key = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if key not in viste:
                    viste.add(key)
                    libri.append(lb)
    return libri


# --- riferimenti che il riconoscimento generico (testi.estrai_libri) non coglie ---------------
# Si usano solo se la sezione "Testi/Bibliografia" non ha dato nessun libro: righe con anno,
# ISBN, editore, iniziali degli autori o titolo tra virgolette; oppure una sola citazione
# scritta su più righe brevi (titolo / autori / editore). Mai slide, dispense, materiali su Virtuale.
_ANNO = re.compile(r"\b(1[89]\d\d|20[0-3]\d)\b")
_EDIT = re.compile(r"(?i)mc ?graw|mac ?graw|\beditor[ei]\b|\beditrice\b|\bedizioni\b|\bed\.\s|\bpress\b|verlag|"
                   r"publish|\bisbn\b")
_AUTORE = re.compile(r"\b[A-ZÀ-Ý][a-zà-ÿ'’-]+,?\s+(?:[A-Z]\.\s?-?){1,3}(?=[\s,;:(.&]|$)|"
                     r"\b(?:[A-Z]\.\s?-?){1,3}\s*[A-ZÀ-Ý][a-zà-ÿ'’-]{2,}")
_VIRGOLETTE = re.compile(r"[“\"«][^”\"»]{4,}[”\"»]")
_ESCLUSI = re.compile(r"(?i)slide|piattaforma|platform|medesim|\breview|letteratura|dispens|virtuale|appunti|lucidi|materiale|materiali|materials|handout|lecture notes|"
                      r"\bnotes\b|articoli|lavori scientifici|papers?\b|http|www\.|copisteria|ricevimento|"
                      r"frequentant|attending|\bverr|\bsar[àa]\b|saranno|\bwill\b|\bpotr|\bdovr|consultare|"
                      r"indicat[aie]|segnalat|fornit[aie]|provided|distribuit|messo a disposizione|made available|"
                      r"non è necessario|not necessary|\bsito\b|website|\bpdf\b")
_ETICHETTA = re.compile(r"(?i)^\s*((?:modul[oe]|module|parte|part|libr[oi]|test[oi]|texts?|textbook|manual[ei]|"
                        r"esercizi|exercises|bibliografia|bibliography|readings?|letture|lettura|si consiglia|"
                        r"consigliat|obbligatori|required|recommended|suggested|optional|per |for |reference|"
                        r"\(?[a-z0-9]\)|[ivx]+\))[^:]{0,70}):\s*(.+)$")
_OBBL = re.compile(r"(?i)obbligator|necessari[oaie]|indispensabil|required|compulsory|mandatory|essential")
_CONS = re.compile(r"(?i)consigliat|facoltativ|approfondiment|integrativ|supplementar|suggerit|recommended|"
                   r"suggested|optional|further|additional|complementar")


_NEUTRA = re.compile(r"(?i)test[oi]|bibliograf|lettur|reading|libr[oi]|manual|textbook|references?\b")


def _nuovo_tipo(intestazione: str, tipo: str | None) -> str | None:
    """Tipo dopo un'intestazione: quello che dice, oppure nessuno se è un'intestazione di
    testi senza indicazione ("Testi di riferimento"), altrimenti resta il precedente."""
    t = _tipo_intestazione(intestazione)
    if t:
        return t
    return None if _NEUTRA.search(intestazione) else tipo


def _tipo_intestazione(t: str) -> str | None:
    o, c = _OBBL.search(t), _CONS.search(t)
    if c and (not o or re.search(r"(?i)non (?:è |sono )?obbligator|not (?:required|compulsory|mandatory)", t)):
        return "consigliato"
    if o and not c:
        return "obbligatorio"
    return None


def _intestazione(r: str) -> bool:
    return len(r) < 250 and (r.rstrip().endswith(":") or len(r.split()) <= 8)


def _forte(t: str) -> bool:
    return bool(_ANNO.search(t) or _EDIT.search(t) or _EDITORI_CIT.search(t))


_PICCOLE = {"e", "and", "et", "al", "al.", "di", "de", "van", "von", "da", "del", "della", "a", "cura", "eds", "ed"}


def _solo_nomi(t: str) -> bool:
    """'D. Halliday, R. Resnick, J. Walker': solo autori, senza titolo."""
    n = len(_AUTORE.findall(t))
    resto = re.findall(r"[^\s,;&\-–()]+", _AUTORE.sub(" ", t))
    resto = [w for w in resto if w.lower() not in _PICCOLE]
    return n > 0 and (len(resto) < 2 or (len(resto) <= n and all(w[0].isupper() for w in resto)))


def _citazione(t: str) -> bool:
    nudo = re.sub(r"\([^)]*\)", " ", t)  # le note tra parentesi ("disponibile su Virtuale") non contano
    if not 15 <= len(t) <= 400 or len(t.split()) < 4 or _ESCLUSI.search(nudo):
        return False
    if _forte(t):
        return True
    return bool(_AUTORE.search(t)) and not _solo_nomi(t)


def _solo_editore(t: str) -> bool:
    return _forte(t) and len(t.split()) <= 5


def _coppia(buf: list[str]) -> str | None:
    """Autore su una riga e titolo sulla successiva ('L. Corradi Dell'Acqua' / 'Meccanica delle
    Strutture – Vol. 1'), senza editore: si uniscono solo coppie così, niente di più lungo."""
    if len(buf) == 2 and _solo_nomi(buf[0]) and not _solo_nomi(buf[1]) and len(buf[1].split()) >= 2:
        return f"{buf[0].rstrip(' .,')}, {buf[1]}"
    return None


def _frammento(cit: str) -> bool:
    resto = re.sub(r"(?i)\bisbn\b[:\s]*|[\d-]{10,}|\b(1[89]\d\d|20[0-3]\d)\b", " ", cit)
    resto = _EDITORI_CIT.sub(" ", _EDIT.sub(" ", resto))
    if len(cit) < 25 and not re.search(r"[A-Za-zÀ-ÿ]{4,}\s+[A-Za-zÀ-ÿ]{4,}", resto):
        return True
    return _solo_nomi(cit) or (bool(_ESCLUSI.search(cit)) and not _forte(cit))


def libri_fallback(sezione: str) -> list[dict]:
    righe, tipo, buf = [], None, []

    def chiudi() -> None:
        c = _coppia(buf)
        if c:
            righe.append((c, tipo))
        buf.clear()

    linee = []
    for r in html_to_lines(sezione):  # più riferimenti con l'anno sulla stessa riga, separati da ';'
        linee += [x.strip() for x in r.split(";") if x.strip()] if len(_ANNO.findall(r)) >= 2 and ";" in r else [r]
    prec = False  # la riga precedente ha dato una citazione
    for r in linee:
        if prec and righe and _frammento(r) and _forte(r) and len(r.split()) <= 6:
            # "CRC Press 2020", "ISBN …" sulla riga dopo la citazione: fa parte di quella
            righe[-1] = (f"{righe[-1][0].rstrip(' .,')}, {r}", righe[-1][1])
            continue
        if re.fullmatch(r"(?i)(?:isbn[:\s-]*)?[\d\- Xx]{10,17}\.?", r):
            continue  # ISBN da solo su una riga (in mezzo a una citazione su più righe)
        prec = False
        m = _ETICHETTA.match(r)
        if m and _citazione(m.group(2)):
            tipo = _nuovo_tipo(m.group(1), tipo)
            r = m.group(2).strip()
        elif not _citazione(r):
            if _intestazione(r) and not _solo_editore(r) and not _solo_nomi(r) and (
                    r.rstrip().endswith(":") or _OBBL.search(r) or _CONS.search(r)
                    or (_NEUTRA.search(r) and len(r.split()) <= 3)):
                chiudi()  # intestazione ("Testi obbligatori", "Letture consigliate:"): chiude il blocco
                tipo = _nuovo_tipo(r, tipo)
                continue
            if _intestazione(r):
                tipo = _nuovo_tipo(r, tipo)
            if _solo_editore(r) and 1 <= len(buf) <= 5:
                # una citazione su più righe brevi: titolo / autori / … / editore
                righe.append((", ".join(x.rstrip(" .,") for x in buf + [r]), tipo))
                buf.clear()
                prec = True
            elif _ESCLUSI.search(r) or r.rstrip().endswith(":") or len(r) >= 120 or len(r.split()) < 2:
                chiudi()
            elif _solo_nomi(r) and buf:
                chiudi()
                buf.append(r)
            else:
                buf.append(r)
            continue
        chiudi()
        righe.append((r, tipo))
        prec = True
    chiudi()
    out, viste = [], set()
    for testo, t in righe:
        lb = _libero(testo)
        lb["tipo"] = lb.get("tipo") or t
        key = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
        if key not in viste:
            viste.add(key)
            out.append(lb)
    return out


def assegna_tipi(sezione: str, libri: list[dict]) -> None:
    """Tipo obbligatorio/consigliato dalle intestazioni della sezione ("Bibliografia necessaria",
    "Testi di approfondimento", "Required readings"…), solo se il programma lo dice."""
    norm = lambda t: re.sub(r"\W+", "", t.lower())  # noqa: E731
    stati, tipo = [], None
    for r in html_to_lines(sezione):
        m = _ETICHETTA.match(r)
        testa = m.group(1) if m else (r if _intestazione(r) and not _citazione(r) else "")
        tipo = _nuovo_tipo(testa, tipo) if testa else tipo
        stati.append((norm(r), tipo))
    for lb in libri:
        if lb.get("tipo"):
            continue
        k = norm(lb["citazione"])[:40]
        lb["tipo"] = next((t for r, t in stati if k and k in r), None)


def leggi_scheda(s: str) -> dict:
    out: dict = {}
    docenti = re.findall(r'<meta name="Docente" content="([^"]+)"', s)
    if not docenti:
        m = re.search(r"(?:Docente|Docenti|Teacher|Teachers)\s*:?\s*</?\w[^>]*>(.*?)</(?:p|li|div)>", s, re.S)
        if m:
            docenti = [x.strip() for x in re.split(r",|;", _testo(m.group(1))) if x.strip()]
    out["docenti"] = sorted({html.unescape(d).strip() for d in docenti if d.strip()})
    sez = _blocchi_testi(s)
    out["libri"] = []
    if sez:
        principali = libri_da_scheda(sez)
        # frammenti ("Pearson, 2023", "ISBN …", solo autori): si prova a leggere la sezione per righe
        buoni = [lb for lb in principali if not _frammento(lb["citazione"])]
        out["libri"] = buoni or libri_fallback(sez)
    if out["libri"]:
        assegna_tipi(sez, out["libri"])
    out["ha_sezione_testi"] = sez is not None
    return out


def segui_risultato(c: Client, s: str, codice: str | None) -> requests.Response | None:
    """Nella pagina dei risultati della ricerca, la scheda il cui titolo inizia con il codice."""
    link = re.findall(r'<a href="(https://www\.unibo\.it/[^"]*/(?:insegnamento|course-unit)/\d{4}/\d+)"[^>]*>\s*([^<]*)</a>', s)
    scelti = [u for u, t in link if codice and t.strip().upper().startswith(codice.upper() + " ")]
    if not scelti and len({u for u, _ in link}) == 1:
        scelti = [link[0][0]]
    return c.get(scelti[0]) if scelti else None


# corsi che in Universitaly hanno come sito una ricerca su www.unibo.it invece del sito del corso
SITI_CORSI = {
    "unibo-l-22-scienze-delle-attivita-motorie-e-sportive": "https://corsi.unibo.it/laurea/ScienzeMotorieSportive",
    "unibo-l-22-scienze-delle-attivita-motorie-e-sportive-replica-rimini":
        "https://corsi.unibo.it/laurea/ScienzeMotorieSportive-Rimini",
    "unibo-lm-50-progettazione-e-gestione-dell-intervento-educativo-nel-disag":
        "https://corsi.unibo.it/magistrale/InterventoEducativoDisagioSociale",
}


def _url_corso(corso: dict) -> str | None:
    return _sito(SITI_CORSI.get(corso.get("id")) or corso.get("url"))


def _sito(url: str) -> str | None:
    m = re.match(r"https?://corsi\.unibo\.it/(.+?)(?:/index\.html?)?/*$", (url or "").strip())
    return f"https://corsi.unibo.it/{m.group(1)}" if m else None


def fetch_ateneo(uid: str = "unibo", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _url_corso(c)]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con sito su corsi.unibo.it")
    c = Client()
    oggi = time.strftime("%Y-%m-%d")

    def piani_del_corso(sito: str) -> tuple[str, list[tuple]]:
        # corsi in italiano: /insegnamenti; corsi in inglese: /course-structure-diagram
        for pagina in ("insegnamenti", "course-structure-diagram"):
            r = c.get(f"{sito}/{pagina}")
            if r:
                break
        else:
            return sito, []
        base = re.sub(rf"/{pagina}.*$", "", r.url)
        pagine = [r.text]
        for code in sorted(set(re.findall(rf'{pagina}\?code=(\w+)"', r.text))):
            r2 = c.get(f"{base}/{pagina}?code={code}")
            if r2:
                pagine.append(r2.text)
        piani = {}
        for p in pagine:
            for m in PIANO.finditer(p):
                url, aa, cod, cur, _, coorte, etichetta = m.groups()
                if int(aa) != anno:
                    continue
                piani[url] = (url, cod, cur, int(coorte), _curriculum(etichetta))
        return base, list(piani.values())

    def build(corso: dict) -> dict | None:
        base, piani = piani_del_corso(_url_corso(corso))
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        curricula: set[str] = set()
        for url, cod, cur, coorte, curr in piani:
            reale = 2000 + coorte % 100 if coorte > 2100 else coorte  # 9026 = percorso speciale della coorte 2026
            k = anno - reale + 1
            if not 1 <= k <= durata:
                continue
            r = c.get(url)
            if not r:
                continue
            if curr:
                curricula.add(curr)
            for x in leggi_piano(r.text, k):
                key = f"{k}:{x['codice'] or x['nome']}"
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": x["codice"], "nome": x["nome"], "anno": k, "periodo": x["periodo"],
                        "periodo_inizio": x["periodo_inizio"], "periodo_fine": x["periodo_fine"],
                        "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None,
                        "modulo_di": x["modulo_di"], "_ci": x["codice_ci"], "docenti": [], "url": x["url_ricerca"],
                        "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "_curr": set(),
                    }
                item["obbligatorio"] = item["obbligatorio"] or x["obbligatorio"]
                item["_curr"].add(curr)
        tutti = set().union(*(i["_curr"] for i in righe.values())) if righe else set()
        for i in righe.values():
            cs = i.pop("_curr")
            if None not in cs and cs != tutti:
                i["curriculum"] = ", ".join(sorted(cs))
            if not i["modulo_di"]:
                i.pop("modulo_di")
            if not i["_ci"]:
                i.pop("_ci")
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": durata, "url": base, "curricula": sorted(curricula) or None,
                "fonte": piani[0][0].split("/piano/")[0], "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(jobs) if syllabus else 0}")

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if r and not re.search(r"/(insegnamento|course-unit)/\d{4}/", r.url):
                # pagina dei risultati (moduli dei corsi integrati): si segue la scheda del codice
                r = segui_risultato(c, r.text, jobs[url][0].get("codice"))
            if not r:
                return 0
            sc = leggi_scheda(r.text)
            for it in jobs[url]:
                it["url"] = r.url
                it["docenti"] = sc["docenti"]
                it["libri"] = sc["libri"]
                it["stato_libri"] = "completo" if sc["libri"] else "da_aggiungere"
            return len(sc["libri"])
        except Exception:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(6) as ex:
            for n, k in enumerate(ex.map(scheda, list(jobs)), 1):
                trovati += k
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dai siti dei corsi corsi.unibo.it (adapters/unibo.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
