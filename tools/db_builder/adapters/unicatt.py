"""Insegnamenti, docenti, libri e appelli dell'Università Cattolica da www.unicatt.it.

Esse3 della Cattolica non pubblica né l'offerta né gli appelli; li pubblicano il sito dei corsi
e l'applicazione «Programmi dei corsi, orari lezioni ed esami di profitto» dei campus.

Sito dei corsi (`www.unicatt.it`):

- pagina del corso (`/corsi/<tipo>/<corso>.html`) → link ai piani per coorte
  (`…/piano-di-studi-2025-26/<curriculum>.html`, nei corsi in inglese `study-plan-…`);
- piano → "1° anno", "2° anno", … con insegnamento (e SSD), crediti e programma da scaricare;
  le tabelle precedute da "a scelta"/"chosen from" sono insegnamenti opzionali.
  Per l'anno di corso k nell'a.a. A si usa il piano della coorte A-k+1;
- programma (`/upl/proguc/….docx` o `.pdf`) → docente ("Prof. …") e "BIBLIOGRAFIA"/"READING LIST".

API pubblica dei campus (`secure.unicatt.it/didatticaweb2`, la stessa che usano le pagine
`<campus>.unicatt.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni`):

- `v2/elenco-cdl` → i codici dei corsi (uno per coorte) di ogni sede (MI, BS, PC, CR, RM);
- `v2/elenco-insegnamenti` → per ogni codice: codice dell'insegnamento, docente e programma
  dell'a.a. richiesto (anche dove il piano sul sito non ha il link);
- `ps/esami` → gli appelli d'esame per corso e anno di corso (data, ora, aula, docente).
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
import threading
import time
import unicodedata

import requests

from .unicatt_programmi import coerente, leggi_programma
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unicatt.it"
API = "https://secure.unicatt.it/didatticaweb2"
SEDI = ("MI", "BS", "PC", "CR", "RM")
PIANO = re.compile(r'href="(/corsi/[^"]*?/(?:pian[oi]-di-studi?o?|piano-studi|study-plan)[\w-]*?-(\d{4})-(\d{2})/[\w-]+\.html)"')
LINK_API = re.compile(r"https://\w+\.unicatt\.it/polo-studenti-e-didattica-programmi-dei-corsi-orari-delle-lezioni/(\w\w)/"
                      r"insegnamenti\?([^\"\s<]+)")
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}


def _pagina(url: str | None) -> str | None:
    m = re.match(r"https?://www\.unicatt\.it(/corsi/[^?#]+?)(?:\.html)?/?$", (url or "").strip())
    return f"{BASE}{m.group(1)}.html" if m else None


def leggi_piano(s: str) -> list[dict]:
    out = []
    parti = re.split(r'<h2 class="cmp-table-title__text">\s*(\d)\s*(?:°|st|nd|rd|th|o)?\s*(?:anno|year)\s*</h2>', s, flags=re.I)
    for anno, corpo in zip(parti[1::2], parti[2::2]):
        # le tabelle "mobile" ripetono le righe: si leggono solo quelle "desk"
        pezzi = re.split(r'(<div class="cmp-info">.*?</div>)', corpo, flags=re.S)
        scelta = False
        for p in pezzi:
            if p.startswith('<div class="cmp-info">'):
                scelta = bool(re.search(r"(?i)a scelta|chosen from|choose|scegliere|opzional|elective", _testo(p)))
                continue
            for tab in re.findall(r'<table class="wrapper-tables-desk"[^>]*>(.*?)</table>', p, re.S):
                for tr in re.findall(r"<tr>(.*?)</tr>", tab, re.S):
                    nome = re.search(r'class="ins_description">(.*?)</td>', tr, re.S)
                    if not nome:
                        continue
                    cfu = re.search(r'class="cfu_value">(.*?)</td>', tr, re.S)
                    prog = re.search(r'class="programma_download">\s*<a href="([^"]+)"', tr)
                    t = _testo(nome.group(1))
                    ssd = re.search(r"\(([A-Z][A-Z/\-\d, ]+)\)\s*$", t)
                    v = _testo(cfu.group(1)).replace(",", ".") if cfu else ""
                    out.append({
                        "anno": int(anno), "nome": _titolo(re.sub(r"\s*\([A-Z][A-Z/\-\d, ]+\)\s*$", "", t)),
                        "ssd": ssd.group(1).replace(" ", "") if ssd else None,
                        "cfu": (int(float(v)) if float(v).is_integer() else float(v)) if re.fullmatch(r"\d+(\.\d+)?", v)
                        else None,
                        "programma": html.unescape(prog.group(1)) if prog else None, "obbligatorio": not scelta,
                    })
    return out


# --- API dei campus ----------------------------------------------------------------------------

def _ascii(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", " ", unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()).strip()


def _lossy(s: str | None) -> str:
    """Chiave che ignora ogni carattere non ASCII (nell'API le lettere accentate di alcuni nomi sono «�»)."""
    return re.sub(r"[^a-z0-9]+", "", re.sub(r"[^\x00-\x7f]", "", (s or "").lower()))


def _chiave_ins(s: str | None) -> str:
    """Nome di insegnamento senza le parentesi («(Gr. A-CA)», «(1 sem.)», «(annuale)», «(lt)»)."""
    return _ascii(re.sub(r"\([^)]*\)", " ", s or ""))


def _persona(nome: str | None, cognome: str | None) -> str | None:
    t = re.sub(r"\s+", " ", f"{nome or ''} {cognome or ''}").strip()
    if not t:
        return None
    return " ".join(w[:1].upper() + w[1:].lower() for w in t.split())


class Api:
    """POST JSON verso didatticaweb2: risposte in cache su disco, una richiesta alla volta."""

    def __init__(self, cache: pathlib.Path | None, gap: float = 0.5, log=print):
        self.s = requests.Session()
        self.s.headers.update({**HEADERS, "Content-Type": "application/json", "Origin": "https://milano.unicatt.it",
                               "Referer": "https://milano.unicatt.it/"})
        self.cache = cache
        self.gap = gap
        self.last = 0.0
        self.lock = threading.Lock()
        self.requests = 0
        self.log = log

    def post(self, path: str, body: dict):
        key = hashlib.sha1((path + json.dumps(body, sort_keys=True)).encode()).hexdigest()
        f = self.cache / key[:2] / f"{key}.json" if self.cache else None
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))["r"]
        for attempt in range(5):
            with self.lock:
                w = self.last + self.gap - time.monotonic()
                if w > 0:
                    time.sleep(w)
                self.last = time.monotonic()
                self.requests += 1
            try:
                r = self.s.post(API + path, json=body, timeout=60)
            except requests.RequestException:
                time.sleep(5 * (attempt + 1))
                continue
            if r.status_code >= 500 or r.status_code == 429:
                time.sleep(10 * (attempt + 1))
                continue
            if r.status_code == 204 or not r.content:
                res = []
            elif r.status_code == 200:
                try:
                    res = json.loads(r.content.decode("utf-8"))
                except ValueError:
                    return None
            else:
                return None  # 400 e simili: richiesta non valida, non si ritenta
            if f:
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(json.dumps({"r": res}, ensure_ascii=False), encoding="utf-8")
            return res
        return None


def _classe(s: str | None) -> str:
    return _ascii(re.sub(r"\s+R$", "", (s or "").strip()))


def _elenco_cdl(api: Api, sede: str, anno: int) -> list[dict]:
    r = api.post("/v2/elenco-cdl?limit=1000&offset=0", {"codiceSede": sede, "annoAccademico": str(anno), "tipoCorso": "CDL"})
    return r if isinstance(r, list) else []


def _elenco_ins(api: Api, sede: str, anno: int, cdl: dict) -> list[dict]:
    body = {"codiceSede": sede, "annoAccademico": str(anno), "tipoCorso": "CDL",
            "codiceFacolta": (cdl.get("facolta") or {}).get("codiceFacolta"), "codiceCdl": cdl["codiceCDL"]}
    body = {k: v for k, v in body.items() if v}
    r = api.post("/v2/elenco-insegnamenti?limit=1000&offset=0", body)
    return r if isinstance(r, list) else []


def _voce_api(x: dict) -> dict:
    ci = x.get("corsoIntegrato") or {}
    d = x.get("docente") or {}
    return {
        "codice": x.get("codiceInsegnamento"), "nome": x.get("descrizioneInsegnamento") or "",
        "url": x.get("urlFileProgramma") or ci.get("urlFileProgramma") or None,
        "docente": _persona(d.get("nome"), d.get("cognome")),
        "integrato": ci.get("codiceCorsoIntegrato"), "integrato_nome": ci.get("descrizione"),
    }


def _data_iso(g: str) -> str:
    return f"{g[6:10]}-{g[3:5]}-{g[:2]}"


def _esami_ps(api: Api, sede: str, anno: int, cdl: dict, anno_corso: int) -> list[dict]:
    """Appelli (ps/esami) di un codice-corso e un anno di corso: lista piatta con data ISO."""
    body = {"codiceSede": sede, "annoAccademico": str(anno), "codiceFacolta": (cdl.get("facolta") or {}).get("codiceFacolta"),
            "codiceCorsoDiLaurea": cdl["codiceCDL"], "annoDiCorso": str(anno_corso)}
    r = api.post("/ps/esami/", body)
    if not isinstance(r, dict):
        return []
    out = []
    for chiave, lst in (r.get("appelliCalendario") or {}).items():
        m = re.search(r"sessione=(.*?), periodo=", chiave)
        sessione = m.group(1).strip() if m else None
        for e in lst or []:
            if not e.get("dataEvento"):
                continue
            out.append({**e, "_sessione": sessione})
    return out


def fetch_ateneo(uid: str = "unicatt", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print, api: bool = True) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    tutti = list(corsi)
    corsi = [c for c in corsi if _pagina(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi su www.unicatt.it")
    c = Client(rate=2.0)
    oggi = time.strftime("%Y-%m-%d")
    cache_dir = os.environ.get("UN_HTTP_CACHE")
    cache = pathlib.Path(cache_dir) if cache_dir else None
    links: dict[str, list[tuple[str, dict]]] = {}  # id corso → [(sede, parametri)] dalle pagine del corso

    def build(corso: dict) -> dict | None:
        pagina = _pagina(corso["url"])
        r = c.get(pagina)
        if not r:
            return None
        links[corso["id"]] = [(sede, dict(re.findall(r"([A-Za-z]+)=([^&]*)", q.replace("&amp;", "&"))))
                              for sede, q in LINK_API.findall(r.text)]
        piani: dict[int, list[str]] = {}
        for path, a, _ in PIANO.findall(r.text):
            piani.setdefault(int(a), [])
            if BASE + path not in piani[int(a)]:
                piani[int(a)].append(BASE + path)
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        for k in range(1, durata + 1):
            for url in piani.get(anno - k + 1, []):
                rp = c.get(url)
                if not rp:
                    continue
                curr = url.rsplit("/", 1)[-1].removesuffix(".html")
                curr = None if curr in ("curriculum", "piano-di-studi", "piani-di-studio", "study-plan") else curr.replace("-", " ")
                if curr and len(piani.get(anno - k + 1, [])) > 1:
                    curricula.add(curr)
                for x in leggi_piano(rp.text):
                    if x["anno"] != k:
                        continue
                    key = f"{k}:{x['nome'].lower()}"
                    item = righe.get(key)
                    if not item:
                        item = righe[key] = {
                            "codice": None, "nome": x["nome"], "anno": k, "periodo": None, "cfu": x["cfu"],
                            "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None, "docenti": [],
                            "url": x["programma"], "libri": [], "esami": [], "fonte": url, "verificato_il": oggi,
                        }
                    item["obbligatorio"] = item["obbligatorio"] or x["obbligatorio"]
                    if not item["url"] and x["programma"]:
                        item["url"] = x["programma"]
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": pagina, "curricula": sorted(curricula) or None, "fonte": pagina, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(2) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti")

    if api:
        _api_campus(uid, anno, tutti, out, links, cache, log)

    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            u = (i.get("url") or "").strip()
            if re.search(r"\.(docx|pdf)$", u, re.I):
                jobs.setdefault(u, []).append(i)
    log(f"[{uid}] programmi da leggere: {len(jobs) if syllabus else 0}")

    prog_dir = (cache / "unicatt_prog") if cache else None
    sess = requests.Session()
    sess.headers.update(HEADERS)
    lock = threading.Lock()
    stato = {"last": 0.0, "requests": 0}

    def valido(data: bytes | None, url: str) -> bool:
        """Il sito risponde 200 con la pagina «404» al posto dei file che mancano: si controlla il tipo."""
        if not data:
            return False
        return data[:4] == b"%PDF" if url.lower().endswith(".pdf") else data[:2] == b"PK"

    def scarica(url: str) -> bytes | None:
        f = prog_dir / (hashlib.sha1(url.encode()).hexdigest() + ".bin") if prog_dir else None
        if f and f.exists():
            data = f.read_bytes()
            return data if valido(data, url) else None
        for attempt in range(4):
            with lock:
                w = stato["last"] + 0.5 - time.monotonic()
                if w > 0:
                    time.sleep(w)
                stato["last"] = time.monotonic()
                stato["requests"] += 1
            try:
                r = sess.get(url, timeout=90)
            except requests.RequestException:
                time.sleep(4 * (attempt + 1))
                continue
            if r.status_code == 200:
                if f:
                    f.parent.mkdir(parents=True, exist_ok=True)
                    f.write_bytes(r.content)
                return r.content if valido(r.content, url) else None
            if r.status_code in (403, 404, 410):
                return None
            time.sleep(4 * (attempt + 1))
        return None

    def assegna(it: dict, p: dict, url: str, ok: bool) -> None:
        aa = it.pop("_programma_aa", None)
        it.pop("_alt", None)
        if not ok:
            incoerenti.append((it["nome"], url))
            it["url"] = None  # il link dell'ateneo punta al programma di un altro insegnamento
            return
        libri = p["libri"]
        if aa and aa != anno:  # programma di un a.a. precedente (quello corrente non è ancora pubblicato)
            libri = [{**lb, "note": lb.get("note") or f"Dal programma {aa}/{str(aa + 1)[2:]}"} for lb in libri]
        it["url"] = url
        it["docenti"] = sorted(set(it.get("docenti") or []) | set(p["docenti"]))
        it["libri"] = libri
        it["stato_libri"] = "completo" if libri else "da_aggiungere"
        it["_biblio"] = p["bibliografia"]

    def programma(url: str) -> int:
        try:
            data = scarica(url)
            formato = "pdf" if url.lower().endswith(".pdf") else "docx"
            if data is not None:
                p = leggi_programma(data, formato)
                ok = {id(it): coerente(p["intestazione"], url, it["nome"], it.get("codice")) for it in jobs[url]}
                # un link condiviso da insegnamenti con nomi diversi: valgono solo quelli che c'entrano col documento
                # (se nessuno c'entra, il documento è in un'altra lingua: si accetta)
                scarta = p["righe"] and any(ok.values()) and not all(ok.values())
                for it in jobs[url]:
                    assegna(it, p, url, not (scarta and not ok[id(it)]))
                return len(p["libri"])
            # il link non porta a un file (pagina «404»): si prova con quelli dell'API per lo stesso insegnamento
            n = 0
            for it in jobs[url]:
                for alt in it.get("_alt") or []:
                    if alt == url:
                        continue
                    d2 = scarica(alt)
                    if d2 is not None:
                        p = leggi_programma(d2, "pdf" if alt.lower().endswith(".pdf") else "docx")
                        assegna(it, p, alt, coerente(p["intestazione"], alt, it["nome"], it.get("codice")))
                        n += len(it["libri"])
                        break
                else:
                    it["url"] = None  # nessun file raggiungibile
                    it.pop("_alt", None)
                    it.pop("_programma_aa", None)
                    senza_file.append((it["nome"], url))
            return n
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}]   programma {url}: {e!r}")
            return 0

    senza_file: list[tuple[str, str]] = []

    incoerenti: list[tuple[str, str]] = []
    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(2) as ex:
            for n, k in enumerate(ex.map(programma, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   programmi {n}/{len(jobs)}")
    n_biblio = 0
    for corso in out:
        for i in corso["insegnamenti"]:
            i.pop("_programma_aa", None)
            i.pop("_alt", None)
            n_biblio += bool(i.pop("_biblio", False))
    if senza_file:
        log(f"[{uid}] link a programmi che non portano a un file (pagina 404), senza alternative: {len(senza_file)}")
        for nome, u in senza_file[:300]:
            log(f"[{uid}]   {nome} -> {u}")
    log(f"[{uid}] programmi con una sezione di bibliografia: {n_biblio}")
    if incoerenti:
        log(f"[{uid}] programmi che non corrispondono all'insegnamento (scartati): {len(incoerenti)}")
        for nome, u in incoerenti[:400]:
            log(f"[{uid}]   {nome} -> {u}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests + stato['requests']}")
    return {"universita_id": uid, "descrizione": "Generato da www.unicatt.it e dall'API dei campus (adapters/unicatt.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def _ps_insegnamenti(api: Api, sede: str, anno: int, cdl: dict) -> dict[int, list[dict]]:
    """Piano degli studi dell'API (ps/insegnamenti): anno di corso → insegnamenti con codice, crediti e programma."""
    r = api.post("/ps/insegnamenti/", {
        "codiceSede": sede, "annoAccademico": str(anno), "codiceFacolta": (cdl.get("facolta") or {}).get("codiceFacolta"),
        "codiceCorsoDiLaurea": cdl["codiceCDL"], "codiceClasseLaurea": cdl.get("codiceClasseLaurea"),
        "codiceTipoMinisteriale": cdl.get("codiceTipoMinisteriale")})
    out: dict[int, list[dict]] = {}
    ps = r.get("pianoStudi") if isinstance(r, dict) else None
    for k, lst in (ps or {}).items():
        if not str(k).isdigit():
            continue
        for x in lst or []:
            url = x.get("urlProgrammaIT")
            cfu = str(x.get("cfu") or "").replace(",", ".")
            out.setdefault(int(k), []).append({
                "codice": x.get("codiceInsegnamento"), "nome": x.get("descrizioneInsegnamento") or "",
                "integrato": x.get("codiceCorsoIntegrato"), "integrato_nome": x.get("descrizioneCorsoIntegrato"),
                "url": url if url and url.startswith("http") else None,
                "cfu": (int(float(cfu)) if float(cfu).is_integer() else float(cfu))
                if re.fullmatch(r"\d+(\.\d+)?", cfu) else None,
            })
    return out


SEDE_NOMI = {"milano": "MI", "brescia": "BS", "piacenza": "PC", "cremona": "CR", "roma": "RM"}


def _sedi_corso(corso: dict, links: list) -> list[str] | None:
    """Sedi dell'API in cui cercare il corso: [] = nessuna (replica in un'altra città), None = tutte."""
    m = re.search(r"(?i)REPLICA(.*)$", corso["nome"])
    if m:
        coda = _ascii(m.group(1))
        for nome, cod in SEDE_NOMI.items():
            if nome in coda.split():
                return [cod]
        return []
    sedi = list(dict.fromkeys(s for s, _ in links if s in SEDI))
    if sedi:
        return sedi
    slug = (corso.get("url") or "").rsplit("/", 1)[-1].removesuffix(".html")
    for nome, cod in SEDE_NOMI.items():
        if slug.endswith("-" + nome):
            return [cod]
    return None


def _nome_corso(s: str | None) -> str:
    s = re.sub(r"(?i)\s+REPLICA.*$", "", s or "")
    s = re.sub(r"\([^)]*\)", " ", s)
    return re.sub(r"\s+-\s+[A-Z0-9]{2,8}\s*$", "", s.strip()).strip()


def _scheletro(s: str | None) -> str:
    """Solo le consonanti (le vocali accentate sono «�» in alcuni nomi dell'API e «a'» in altri)."""
    t = unicodedata.normalize("NFKD", (s or "").replace("�", "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^bcdfghjklmnpqrstvwxyz]", "", t)


def _classi(s: str | None) -> set[str]:
    return {_classe(p) for p in re.split(r"\s+/\s+", s or "") if p.strip()}


def _corsi_uguali(corso: dict, voci: list[tuple[int, dict]]) -> list[tuple[int, dict]]:
    """Le voci di elenco-cdl (a.a., corso) che sono questo corso: stesso nome e stessa classe."""
    k = _scheletro(_nome_corso(corso["nome"]))
    classi = _classi(corso.get("classe"))
    ok_classe = lambda e: not classi or bool(classi & _classi(e.get("codiceClasseLaurea")))  # noqa: E731
    uguali = [(a, e) for a, e in voci if ok_classe(e) and k and k in (_scheletro(_nome_corso(e.get("descrizione"))),
                                                                       _scheletro(_nome_corso(e.get("descrizioneInglese"))))]
    if uguali:
        return uguali
    base = _ascii(_nome_corso(corso["nome"]))
    return [(a, e) for a, e in voci if ok_classe(e) and difflib.SequenceMatcher(
        None, base, _ascii(_nome_corso(e.get("descrizione")))).ratio() >= 0.9]


def _api_campus(uid: str, anno: int, tutti: list[dict], out: list[dict], links: dict, cache, log) -> None:
    """Codici, docenti, programmi mancanti, piani senza pagina e appelli dall'API dei campus (vedi docstring)."""
    api = Api((cache / "unicatt_api") if cache else None, log=log)
    oggi = time.strftime("%Y-%m-%d")
    elenchi: dict[tuple[str, int], list[dict]] = {}

    def cdl_di(sede: str, a: int) -> list[dict]:
        if (sede, a) not in elenchi:
            elenchi[(sede, a)] = _elenco_cdl(api, sede, a)
        return elenchi[(sede, a)]

    gia = {c["id"] for c in out}
    for meta in tutti:  # corsi senza piano sul sito: si riempiono dall'API (se la trova)
        if meta["id"] not in gia:
            out.append({"id": meta["id"], "nome": meta["nome"], "classe": meta.get("classe"),
                        "durata_anni": meta.get("durata_anni") or 3, "url": meta.get("url"), "curricula": None,
                        "fonte": API, "verificato_il": oggi, "insegnamenti": [], "_stub": True})
    stat = {"corsi_api": 0, "corsi_stub_riempiti": 0, "ins_codice": 0, "url_nuovi": 0, "esami": 0, "corsi_ambigui": [],
            "corsi_senza_api": []}
    for corso in out:
        sedi = _sedi_corso(corso, links.get(corso["id"], []))
        if sedi == []:
            continue  # replica in una città che non ha il suo calendario nell'API dei campus
        per_sede: dict[str, list[tuple[int, dict]]] = {}
        for sede in sedi or SEDI:
            voci = [(a, e) for a in (anno, anno - 1, anno - 2) for e in cdl_di(sede, a)]
            for a, e in _corsi_uguali(corso, voci):
                per_sede.setdefault(sede, []).append((a, e))
        if len(per_sede) > 1:
            stat["corsi_ambigui"].append(corso["id"])
            continue
        if not per_sede:
            stat["corsi_senza_api"].append(corso["id"])
            continue
        sede, voci_cdl = next(iter(per_sede.items()))
        stat["corsi_api"] += 1
        durata = corso.get("durata_anni") or 3
        # piano dell'API (anno di corso, codice, crediti, programma) e docenti, a.a. corrente e precedenti
        ps_voci: list[dict] = []   # tutte le voci (anche componenti di corsi integrati)
        elenco: dict[str, list[dict]] = {}
        for a, e in voci_cdl:
            if a >= anno - 1:
                for ac, lst in _ps_insegnamenti(api, sede, a, e).items():
                    for v in lst:
                        ps_voci.append({**v, "anno_corso": ac, "anno_acc": a, "cdl": e["codiceCDL"]})
            for x in _elenco_ins(api, sede, a, e):
                v = _voce_api(x)
                v["anno_acc"] = a
                elenco.setdefault(_chiave_ins(v["nome"]), []).append(v)
        ps_chiave: dict[str, list[dict]] = {}
        for v in ps_voci:
            ps_chiave.setdefault(_chiave_ins(v["nome"]), []).append(v)
        if corso.get("_stub"):  # nessun piano sul sito: gli insegnamenti di primo livello dell'a.a. corrente
            visti = set()
            for v in sorted((v for v in ps_voci if v["anno_acc"] == anno and not v["integrato"]),
                            key=lambda v: (v["anno_corso"], v["nome"])):
                k = (v["anno_corso"], _chiave_ins(v["nome"]))
                if k in visti or v["anno_corso"] > durata:
                    continue
                visti.add(k)
                corso["insegnamenti"].append({
                    "codice": None, "nome": _titolo(v["nome"]), "anno": v["anno_corso"], "periodo": None, "cfu": v["cfu"],
                    "ssd": None, "obbligatorio": True, "curriculum": None, "docenti": [], "url": None, "libri": [],
                    "esami": [], "fonte": f"{API}/ps/insegnamenti/", "verificato_il": oggi})
            if corso["insegnamenti"]:
                stat["corsi_stub_riempiti"] += 1
                corso["fonte"] = f"{API}/ps/insegnamenti/"
        for it in corso["insegnamenti"]:
            kk = _chiave_ins(it["nome"])
            pv = [v for v in ps_chiave.get(kk, []) if v["anno_corso"] == it["anno"]] or ps_chiave.get(kk, [])
            ev = elenco.get(kk, [])
            if not pv and not ev:
                continue
            cod = [v["codice"] for v in sorted(pv, key=lambda v: (v["integrato"] is not None, -v["anno_acc"]))
                   if v["codice"]] + [v["codice"] for v in ev if v["codice"]]
            it["codice"] = it.get("codice") or (cod[0] if cod else None)
            stat["ins_codice"] += 1
            correnti = [v for v in ev if v["anno_acc"] == anno]
            it["docenti"] = sorted(set(it.get("docenti") or []) | {v["docente"] for v in correnti if v["docente"]})
            if it.get("cfu") is None:
                it["cfu"] = next((v["cfu"] for v in pv if v["cfu"] is not None and v["anno_acc"] == anno), None)
            cand = sorted({(v["anno_acc"], v["url"]) for v in pv + ev if v.get("url")}, reverse=True)
            if not it.get("url") and cand:
                it["url"] = cand[0][1]
                if cand[0][0] != anno:
                    it["_programma_aa"] = cand[0][0]
                stat["url_nuovi"] += 1
            it["_alt"] = [u for _, u in cand if u != it.get("url")][:3]
        # appelli: ps/esami per codice-corso e anno di corso (a.a. corrente e precedente), solo date da oggi in poi
        trovati: dict[str, list[dict]] = {}
        anni_corso = {(v["anno_acc"], v["cdl"], v["anno_corso"]) for v in ps_voci}
        for a, e in voci_cdl:
            if a < anno - 1:
                continue
            for ac in sorted({k[2] for k in anni_corso if k[0] == a and k[1] == e["codiceCDL"]}) or range(1, durata + 1):
                for x in _esami_ps(api, sede, a, e, ac):
                    if _data_iso(x["dataEvento"]) < oggi:
                        continue
                    trovati.setdefault(_chiave_ins(x.get("descrizioneInsegnamento")), []).append(x)
                    for cod in (x.get("codiceInsegnamento"), x.get("codiceCorsoIntegrato")):
                        if cod:
                            trovati.setdefault("#" + cod, []).append(x)
        for it in corso["insegnamenti"]:
            lst = (trovati.get("#" + it["codice"]) if it.get("codice") else None) or trovati.get(_chiave_ins(it["nome"]))
            if not lst:
                continue
            viste, esami = set(), []
            for x in sorted(lst, key=lambda x: (_data_iso(x["dataEvento"]), x.get("oraInizio") or "")):
                k = (x["dataEvento"], x.get("oraInizio"))
                if k in viste:
                    continue
                viste.add(k)
                luogo = " ".join(p for p in (x.get("edificio"), f"aula {x['aula']}" if x.get("aula") else None) if p) or None
                esami.append({
                    "tipo": "appello", "titolo": it["nome"], "data": _data_iso(x["dataEvento"]), "ora": x.get("oraInizio"),
                    "luogo": luogo, "docenti": x.get("docente"),
                    "note": " - ".join(p for p in (x.get("_sessione"), x.get("note")) if p) or None,
                    "fonte": f"{API}/ps/esami/",
                })
            it["esami"] = esami
            it["stato_esami"] = "completo"
            stat["esami"] += len(esami)
    out[:] = [c for c in out if c["insegnamenti"]]
    for c in out:
        c.pop("_stub", None)
    log(f"[{uid}] API campus: {stat}; richieste {api.requests}")
