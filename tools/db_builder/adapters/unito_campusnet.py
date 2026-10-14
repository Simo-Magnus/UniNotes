"""Libri degli insegnamenti dell'Università di Torino dalle pagine Campusnet.

Il Course Catalogue di UniTO ha gli insegnamenti ma non i testi; li pubblicano le pagine
dei corsi di studio (`<corso>.campusnet.unito.it/do/corsi.pl/Show?_id=…` o i siti
`www.<corso>.unito.it/do/corsi.pl/Show?_id=…`). Le pagine si trovano:

- dal campo `url_sito` degli insegnamenti (link del syllabus del catalogo);
- per codice dell'attività didattica negli elenchi «Corsi e moduli» dei siti Campusnet
  dei corsi (`/do/corsi.pl/Search?title=Corsi e moduli`), per gli insegnamenti senza link
  (per esempio quelli del 2° e 3° anno).

Nella sezione "Testi consigliati e bibliografia" ci sono:

- schede "Libro" strutturate (Titolo, Anno pubblicazione, Editore, Autore, ISBN, Obbligatorio);
- eventuale testo libero, letto con `testi.estrai_libri`.

Se la pagina non ha testi si leggono le pagine collegate: l'insegnamento da cui è mutuato
("Mutuato da") e i moduli dei corsi integrati ("Moduli didattici").

Restituisce un contributo con i soli libri, agganciati agli insegnamenti esistenti per `id`
(build_db.py unisce i libri a quelli già presenti). `alias_appelli` associa gli appelli
della bacheca Esse3 registrati con il codice di un'altra coorte agli insegnamenti con lo
stesso nome e almeno un docente in comune.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import threading
import time
import unicodedata

from .testi import _isbn, estrai_libri
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
# siti Campusnet di corsi che nel database non hanno il link (es. Matematica)
HOST_EXTRA = ["www.matematica.unito.it", "www.clest.unito.it", "www.sme.unito.it"]


# etichette delle schede "Book" dei siti in inglese
CAMPI_EN = {"Title": "Titolo", "Year of publication": "Anno pubblicazione", "Publisher": "Editore",
            "Author": "Autore", "Required": "Obbligatorio"}


def leggi_testi(s: str) -> list[dict]:
    m = re.search(r"(?:Testi consigliati e bibliografia|Suggested readings and bibliography)\s*</h2>(.*?)"
                  r"(?:<H2 id=\"a_nota_|id=\"record_toolbar_)", s, re.S | re.I)
    if not m:
        return []
    sez = m.group(1)
    libri = []
    for blocco in re.split(r'<dd class="col-md-12">\s*(?:Libro|Book)\s*</dd>', sez)[1:]:
        campi = {CAMPI_EN.get(k, k): v for k, v in (
            (_testo(k).rstrip(": ").strip(), v) for k, v in
            re.findall(r'<dt class="col-md-3"><span>(.*?)</span></dt><dd class="col-md-9">(.*?)</dd>', blocco, re.S))}
        titolo = _testo(campi.get("Titolo", ""))
        if not titolo or re.match(r"(?i)(nessun|none\b|n\.?\s?d\.?$|-+$|vedi\b|see\b|si veda)", titolo):
            continue
        anno = re.search(r"\d{4}", _testo(campi.get("Anno pubblicazione", "")))
        autori = _testo(campi.get("Autore", "")) or None
        if autori and autori.isupper():
            autori = ", ".join(" ".join(w.capitalize() if len(w) > 2 else w for w in a.split()) for a in autori.split(","))
        obb = _testo(campi.get("Obbligatorio", "")).lower().replace("yes", "si")
        editore = _testo(campi.get("Editore", "")) or None
        cit = ", ".join(x for x in (autori, titolo, editore, anno.group(0) if anno else None) if x)
        libri.append({
            "titolo": titolo, "autori": autori, "editore": editore,
            "anno": int(anno.group(0)) if anno else None, "edizione": None,
            "isbn": _isbn(_testo(campi.get("ISBN", ""))), "lingua": None,
            "tipo": "obbligatorio" if obb.startswith("s") else ("consigliato" if obb.startswith("n") else None),
            "note": None, "citazione": cit,
        })
    # testo libero prima delle schede "Libro" (o al posto loro)
    libero = re.split(r'<dd class="col-md-12">\s*(?:Libro|Book)\s*</dd>', sez)[0]
    libero += "".join(re.findall(r'<H2 id="a_testi_\w+"></H2>(.*?)</dd>', s, re.S))
    viste = {re.sub(r"\W+", "", x["titolo"].lower()) for x in libri}
    for lb in estrai_libri(libero):
        if not any(v and v in re.sub(r"\W+", "", lb["citazione"].lower()) for v in viste):
            libri.append(lb)
    return libri


def _assoluto(href: str, pagina: str) -> str:
    href = html.unescape(href)
    if href.startswith("http"):
        return re.sub(r"^http://", "https://", href)
    m = re.match(r"https?://[^/]+", pagina)
    return (m.group(0) if m else "") + href


def collegate(s: str, pagina: str) -> list[str]:
    """Pagine da cui leggere i testi quando la pagina non ne ha: l'insegnamento da cui è
    mutuato ("Mutuato da") e i moduli di un corso integrato ("Moduli didattici")."""
    out: list[str] = []
    for m in re.finditer(r"<span>Mutuato da</span></dt>\s*<dd[^>]*>(.*?)</dd>", s, re.S | re.I):
        out += re.findall(r'href="([^"]*corsi\.pl/Show\?_id=\w+)"', m.group(1), re.I)
    for m in re.finditer(r'<H2 id="a_moduli_\w+">.*?</H2>(.*?)</dd>', s, re.S | re.I):
        out += re.findall(r'href="([^"]*corsi\.pl/Show\?_id=\w+)"', m.group(1), re.I)
    return list(dict.fromkeys(_assoluto(h, pagina) for h in out))


def elenco(c: Client, host: str) -> list[dict]:
    """Elenco «Corsi e moduli» di un sito Campusnet (al massimo 200 voci per pagina):
    pagina, nome, codice dell'attività didattica e anno accademico."""
    out: list[dict] = []
    first = 0
    while first <= 4000:
        r = c.get(f"https://{host}/do/corsi.pl/Search?title=Corsi%20e%20moduli;max=200"
                  + (f";first={first}" if first else ""))
        if not r:
            break
        voci = re.findall(r'<li class="mb-3">(.*?)</li>', r.text, re.S)
        for li in voci:
            m = re.search(r'href="([^"]*Show\?_id=(\w+))"[^>]*>(.*?)</a>\s*(?:\(([^)]*)\))?', li, re.S)
            if not m:
                continue
            aa = re.search(r"Anno accademico:\s*(\d{4}/\d{4})", _testo(li))
            out.append({"url": f"https://{host}/do/corsi.pl/Show?_id={m.group(2)}", "nome": _testo(m.group(3)),
                        "codice": re.sub(r"\s+", "", m.group(4) or "").upper(), "aa": aa.group(1) if aa else None})
        if len(voci) < 200:
            break
        first += 200
    return out


def _host(u: str | None) -> str | None:
    m = re.match(r"https?://([^/]+\.unito\.it)", u or "", re.I)
    return m.group(1).lower() if m else None


def _chiave(cit: str) -> str:
    return re.sub(r"\W+", "", cit.lower())


def fetch_ateneo(uid: str = "unito", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if not x.get("piano_da")]  # repliche di sede: piano copiato, senza libri
    if max_cds:
        corsi = corsi[:max_cds]
    anno = anno or int(time.strftime("%Y"))
    aa_corrente = f"{anno}/{anno + 1}"
    c = Client(rate=5.0)
    oggi = time.strftime("%Y-%m-%d")

    # 1) elenchi degli insegnamenti dei siti Campusnet dei corsi
    host_corso: dict[str, set[str]] = {}
    for corso in corsi:
        hs = {_host(corso.get("url"))} | {_host(i.get("url_sito")) for i in corso.get("insegnamenti") or []}
        host_corso[corso["id"]] = {h for h in hs if h}
    hosts = sorted(set().union(*host_corso.values()) | set(HOST_EXTRA))
    per_codice: dict[str, list[tuple[str, dict]]] = {}
    if syllabus:
        with cf.ThreadPoolExecutor(3) as ex:
            for h, voci in zip(hosts, ex.map(lambda h: elenco(c, h), hosts)):
                for v in voci:
                    if v["codice"] and v["aa"] in (aa_corrente, None):
                        per_codice.setdefault(v["codice"], []).append((h, v))
    log(f"[{uid}] {len(hosts)} siti Campusnet, {sum(len(v) for v in per_codice.values())} pagine "
        f"di insegnamenti {aa_corrente}")

    def candidati(corso: dict, i: dict) -> list[str]:
        cod = re.sub(r"\s+", "", i.get("codice") or "").upper()
        if not cod:
            return []
        voci = per_codice.get(cod) or [x for k, v in per_codice.items()
                                        if re.fullmatch(re.escape(cod) + r"/?[A-Z]", k) for x in v]
        propri = [v["url"] for h, v in voci if h in host_corso[corso["id"]]]  # prima il sito del corso
        return list(dict.fromkeys(propri + [v["url"] for _, v in voci]))[:6]

    # 2) pagine di ogni insegnamento: quella del catalogo (url_sito), poi quelle trovate per codice
    jobs: list[tuple[str, dict, list[str]]] = []
    for corso in corsi:
        for i in corso.get("insegnamenti") or []:
            u = i.get("url_sito") or ""
            pagine = [_assoluto(u, u)] if re.search(r"unito\.it/do/corsi\.pl/Show\?_id=\w+", u) else []
            pagine += [x for x in candidati(corso, i) if x not in pagine]
            if pagine:
                jobs.append((corso["id"], i, pagine))
    lette: dict[str, tuple[list[dict], list[str]]] = {}
    lock = threading.Lock()

    def leggi(u: str) -> tuple[list[dict], list[str]]:
        with lock:
            if u in lette:
                return lette[u]
        try:
            r = c.get(u)
            res = (leggi_testi(r.text), collegate(r.text, u)) if r else ([], [])
        except Exception:  # noqa: BLE001 - una pagina illeggibile non ferma le altre
            res = ([], [])
        with lock:
            lette[u] = res
        return res

    def libri_di(pagine: list[str]) -> tuple[list[dict], str | None]:
        """Libri della prima pagina che ne ha; altrimenti quelli delle pagine collegate
        (insegnamento da cui è mutuato, moduli: dei moduli si uniscono tutti)."""
        for u in pagine:
            lb, _ = leggi(u)
            if lb:
                return lb, u
        for u in pagine:
            tutti: list[dict] = []
            prima = None
            for v in leggi(u)[1]:
                lb, coll2 = leggi(v)
                lb = list(lb)
                if not lb:  # mutuato da un corso integrato: i suoi moduli
                    for w in coll2:
                        lb += leggi(w)[0]
                if lb:
                    prima = prima or v
                    viste = {_chiave(x["citazione"]) for x in tutti}
                    tutti += [x for x in lb if _chiave(x["citazione"]) not in viste]
            if tutti:
                return tutti, prima
        return [], None

    risultati: list[tuple[str, dict, list[dict], str | None, list[str]]] = []
    if syllabus:
        log(f"[{uid}] {len(jobs)} insegnamenti con pagine Campusnet da leggere")
        with cf.ThreadPoolExecutor(5) as ex:
            for n, (job, (lb, fonte)) in enumerate(zip(jobs, ex.map(lambda j: libri_di(j[2]), jobs)), 1):
                risultati.append((job[0], job[1], lb, fonte, job[2]))
                if n % 500 == 0:
                    log(f"[{uid}]   insegnamenti {n}/{len(jobs)} (pagine lette {len(lette)})")
    per_corso: dict[str, list[dict]] = {}
    for cid, i, lb, fonte, pagine in risultati:
        if not lb:
            continue
        per_corso.setdefault(cid, []).append({
            "id": i["id"], "codice": i.get("codice"), "nome": i["nome"], "anno": i.get("anno"), "libri": lb,
            "stato_libri": "completo", "url_sito": i.get("url_sito") or fonte or pagine[0],
            "verificato_il": oggi})
    out = [{"id": cid, "nome": next(x["nome"] for x in corsi if x["id"] == cid), "insegnamenti": ins}
           for cid, ins in per_corso.items()]
    log(f"[{uid}] libri trovati per {sum(len(x['insegnamenti']) for x in out)} insegnamenti "
        f"({sum(len(i['libri']) for x in out for i in x['insegnamenti'])} libri); richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Libri dalle pagine Campusnet (adapters/unito_campusnet.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\((?:t|a distanza|[^)]*cfu[^)]*)\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _in_comune(docenti: list[str], esami: list[dict]) -> bool:
    """Almeno un docente del catalogo ("Cognome Nome") con cognome e nome tra quelli della
    bacheca ("COGNOME NOME COGNOME2 NOME2 …")."""
    parole = {w for e in esami for w in _norm(e.get("docenti")).split()}
    for d in docenti or []:
        p = _norm(d).split()
        if len(p) >= 2 and p[0] in parole and p[-1] in parole:
            return True
    return False


def alias_appelli(corsi: list[dict], appelli: dict[str, list[dict]]) -> dict[str, list[dict]]:
    """Appelli della bacheca Esse3 per gli insegnamenti il cui codice del catalogo non c'è
    nella bacheca (le coorti precedenti hanno codici diversi): stesso nome dell'attività e
    almeno un docente in comune. Restituisce {codice del catalogo: appelli}."""
    per_nome: dict[str, list[str]] = {}
    for cod, lst in appelli.items():
        for t in {_norm(e.get("titolo")) for e in lst if e.get("titolo")}:
            per_nome.setdefault(t, []).append(cod)
    out: dict[str, list[dict]] = {}
    for corso in corsi:
        if corso.get("piano_da"):
            continue
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if not cod or cod in appelli or cod in out:
                continue
            if not i.get("docenti"):
                continue
            lst: list[dict] = []
            for k in per_nome.get(_norm(i.get("nome")), []):
                if _in_comune(i["docenti"], appelli[k]):
                    viste = {(e["data"], e.get("ora"), e.get("tipo")) for e in lst}
                    lst += [e for e in appelli[k] if (e["data"], e.get("ora"), e.get("tipo")) not in viste]
            if lst:
                out[cod] = sorted(lst, key=lambda e: (e["data"], e.get("ora") or ""))
    return out


def appelli_per_corso(fac_ids: list[str], base: str = "https://unito.esse3.cineca.it", log=print,
                      delay: float = 1.0) -> dict[str, list[dict]]:
    """Bacheca appelli Esse3 corso per corso, per le strutture grandi la cui ricerca complessiva
    va in timeout (a UniTO: Filosofia e scienze dell'educazione, Studi storici, Studi umanistici)."""
    import requests

    from .esse3_appelli import HEADERS, _parse
    url = base.rstrip("/") + "/Guide/PaginaListaAppelli.do"
    s = requests.Session()
    s.get(url, headers=HEADERS, timeout=60)
    out: dict[str, list[dict]] = {}
    for fac in fac_ids:
        base_data = {"FAC_ID": fac, "CDS_ID": "X", "AD_ID": "X", "DOCENTE_ID": "X", "DATA_ESA": "",
                     "form_id_form1": "form1"}
        r = s.post(url, data=base_data, headers=HEADERS, timeout=120)
        sel = re.search(r'<select[^>]*name="CDS_ID".*?</select>', r.text, re.S)
        cds = [c for c in re.findall(r'<option value="([^"]+)"', sel.group(0) if sel else "") if c != "X"]
        n0 = sum(len(v) for v in out.values())
        for cd in cds:
            r2 = None
            for tentativo in range(2):
                try:
                    r2 = s.post(url, data={**base_data, "CDS_ID": cd, "actionBar1": "Cerca"}, headers=HEADERS,
                                timeout=300)
                    break
                except requests.RequestException as e:
                    log(f"[unito] esse3 {fac}/{cd} (tentativo {tentativo + 1}): {e!r}")
            if r2 is not None:
                for cod, lst in _parse(r2.text, url).items():
                    viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
                    out.setdefault(cod, []).extend(x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste)
            time.sleep(delay)
        log(f"[unito] esse3 {fac}: {len(cds)} corsi, {sum(len(v) for v in out.values()) - n0} date")
    return out


# strutture della bacheca Esse3 di UniTO la cui ricerca complessiva va in timeout
STRUTTURE_GRANDI = ["10110", "10089", "10088"]


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli UniTO per fetch_atenei.APPELLI: bacheca Esse3 per struttura, corso per corso per le
    strutture grandi, poi gli alias per nome e docente (codici di altre coorti)."""
    from .esse3_appelli import fetch_appelli as esse3
    app = esse3(uid, "https://unito.esse3.cineca.it", log=log)
    for cod, lst in appelli_per_corso(STRUTTURE_GRANDI, log=log).items():
        viste = {(x["data"], x.get("ora"), x.get("tipo")) for x in app.get(cod, [])}
        app.setdefault(cod, []).extend(x for x in lst if (x["data"], x.get("ora"), x.get("tipo")) not in viste)
    for cod, lst in alias_appelli(corsi, app).items():
        app.setdefault(cod, lst)
    return app
