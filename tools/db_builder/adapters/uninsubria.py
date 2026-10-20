"""Università dell'Insubria: insegnamenti, libri e appelli.

Piani e syllabus: `https://uninsubria.coursecatalogue.cineca.it` (Course Catalogue Cineca, API pubblica).
Rispetto all'adattatore comune (`cineca_catalogue`) all'Insubria serve:

- ritmo: al massimo 2 richieste al secondo (il client comune ne fa 8);
- piani: li legge `uninsubria_piani` (piano per coorte A-k+1 per l'anno k, codici riordinati F011 → F11R, anni senza
  coorte dalla più vicina, gruppi «OO»/«F»/«W»/«S»/«G» con i CFU delle etichette, contenitori degli insegnamenti integrati
  e attività a 0 CFU tolti, percorsi «comune» e part-time, un corso per ogni sede dell'Infermieristica). La durata viene
  dalla scheda del corso («5 anni»: l'elenco minimale non ha `durataAnni`);
- corsi: solo lauree e lauree magistrali (anche a ciclo unico): il «Semestre filtro» non è un corso di studio;
  sei corsi del catalogo (sedi e repliche) hanno un nome diverso da quello di Universitaly, `ID_UNIVERSITALY` li lega;
- libri: i syllabus rimandano alla bibliografia su Leganto (`uninsubria.alma.exlibrisgroup.com`, liste pubbliche).
  La sessione anonima di Leganto vale solo per il `courseCode` della pagina con cui è stata aperta: una sessione per
  codice. Con il codice dell'insegnamento (es. «SCV0394») la ricerca restituisce le liste di tutti gli anni
  accademici («aa 2026-27 - …»): si usa quella del 2026/27 e, se il docente non l'ha ancora pubblicata, quella
  dell'a.a. più recente dal 2022/23, dicendolo nella nota di ogni libro. In mancanza di una lista si usano i
  testi del syllabus che hanno la forma di una citazione;
- appelli: bacheca dell'offerta di Esse3 (ListaAppelliOfferta) un corso di studio per volta, più la bacheca
  per dipartimento; gli appelli con un codice che il catalogo non ha si attribuiscono all'insegnamento omonimo.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte restano su disco.
"""
from __future__ import annotations

import hashlib
import html as _h
import json
import os
import pathlib
import re
import threading
import time
import unicodedata
import urllib.parse

import requests

from . import cineca_catalogue, leganto, uninsubria_piani, unifi_testi
from .testi import YEAR, _isbn

BASE = "https://uninsubria.coursecatalogue.cineca.it"
ESSE3 = "https://uninsubria.esse3.cineca.it"
LEGANTO = "https://uninsubria.alma.exlibrisgroup.com/leganto"
PUBBLICO = LEGANTO + "/public/39INS_INST/lists?courseCode={}"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 2.0  # richieste al secondo (catalogo)
GAP_LEGANTO = 0.5  # secondi tra due richieste a Leganto
ANNO_MIN = 2022  # liste più vecchie non si usano
# codice del corso nel catalogo (cdsCod) → id Universitaly dello stesso corso (sedi e repliche con nome diverso)
ID_UNIVERSITALY = {
    "L011": "1630200",  # Infermieristica, Varese
    "L11B": "1630240",  # Infermieristica, replica Busto Arsizio
    "L11C": "1630241",  # Infermieristica, replica Como
    "FR4R": "1630243",  # Informatica, replica Como
    "U16R": "1630237",  # Global Entrepreneurship Economics and Management (GEEM)
    "A19R": "1630242",  # Giurisprudenza, replica Varese
}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _cartella(nome: str) -> pathlib.Path | None:
    d = os.environ.get("UN_HTTP_CACHE")
    if not d:
        return None
    p = pathlib.Path(d) / nome
    p.mkdir(parents=True, exist_ok=True)
    return p


def _valida(path: str, r) -> bool:
    """Controllo del contenuto prima di metterlo in cache."""
    if path == "/corsi":
        return isinstance(r, list)
    d = r[0] if isinstance(r, list) and r else r
    if path.startswith("/corso/"):
        return isinstance(d, dict) and "percorsi" in d
    if path == "/insegnamento":
        return isinstance(d, dict) and "testiTotali" in d
    return r is not None


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = RATE, anno: int = 2026):
        super().__init__(base, rate)
        self.dir = _cartella("uninsubria_cc")
        self.anno = anno
        self.af: dict[tuple[str, str], str] = {}  # (aa, cod della scheda) → afId (il courseCode di Leganto)

    def _get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is not None and _valida(path, r):
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r

    def _note_af(self, d: dict | None) -> None:
        def cammina(x):
            if isinstance(x, dict):
                if "afId" in x and "cod" in x and "aa" in x:
                    self.af[(str(x["aa"]), str(x["cod"]))] = str(x["afId"])
                for v in x.values():
                    cammina(v)
            elif isinstance(x, list):
                for v in x:
                    cammina(v)
        cammina((d or {}).get("percorsi"))


# --- libri: testi del syllabus e liste Leganto -----------------------------------------------
_lock_leganto = threading.Lock()
_ultimo = {"t": 0.0}


def _attendi() -> None:
    with _lock_leganto:
        attesa = _ultimo["t"] + GAP_LEGANTO - time.monotonic()
        if attesa > 0:
            time.sleep(attesa)
        _ultimo["t"] = time.monotonic()


def _json(s: requests.Session, url: str, **kw):
    for tentativo in range(3):
        _attendi()
        try:
            r = s.get(url, timeout=60, **kw)
            if r.status_code in (401, 403, 404):
                return None
            return r.json()
        except (requests.RequestException, ValueError):
            time.sleep(2 ** tentativo)
    return None


def _anno_lista(l: dict) -> int | None:
    m = re.search(r"(20\d\d)\s*[-/–]\s*(?:20)?\d\d\b", l.get("name") or "")
    if m:
        return int(m.group(1))
    for c in l.get("courses") or []:
        m = re.search(r"-(20\d\d)$", c.get("code") or "")
        if m:
            return int(m.group(1))
    return None


class Sessione:
    """Una sessione anonima di Leganto per codice: si apre la pagina pubblica di quel codice (senza seguire il
    reindirizzamento: i cookie arrivano con la prima risposta) e poi si cerca con lo stesso codice."""

    def __init__(self, codice: str):
        self.codice = codice
        self.s = requests.Session()
        self.s.headers.update(leganto.HEADERS)
        self.aperta = False

    def apri(self) -> bool:
        for tentativo in range(3):
            _attendi()
            try:
                self.s.get(PUBBLICO.format(urllib.parse.quote(self.codice)), timeout=60, allow_redirects=False,
                           headers={"Accept": "text/html"})
                self.aperta = True
                return True
            except requests.RequestException:
                time.sleep(2 ** tentativo)
        return False


_cache_mem: dict[str, list[dict] | None] = {}
_sess_mem: dict[str, Sessione] = {}


def _liste(codice: str) -> list[dict] | None:
    """Liste pubblicate del codice (tutti gli a.a.): [{id, anno, nome, cds, libri: None}]. None se non raggiungibile."""
    if codice in _cache_mem:
        return _cache_mem[codice]
    cd = _cartella("uninsubria_leganto")
    f = cd / f"liste_{hashlib.sha1(codice.encode()).hexdigest()}.json" if cd else None
    if f and f.exists():
        _cache_mem[codice] = json.loads(f.read_text(encoding="utf-8"))
        return _cache_mem[codice]
    ses = Sessione(codice)
    if not ses.apri():
        return None
    d = _json(ses.s, f"{LEGANTO}/rl/search/find/lists",
              params={"course_code": codice, "scope": "all_lists", "maxResults": 50, "startPos": 0})
    if not isinstance(d, dict) or not isinstance((d.get("object") or {}).get("lists"), list):
        # nessuna risposta valida: non si mette in cache e si riprova alla prossima raccolta
        return None if d is None else []
    out = []
    for l in d["object"]["lists"]:
        if l.get("rlStatus") not in (None, "PUBLISHED"):
            continue
        out.append({"id": l["id"], "anno": _anno_lista(l), "nome": l.get("name") or ""})
    _sess_mem[codice] = ses
    if f:
        f.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    _cache_mem[codice] = out
    return out


def _libri_lista(codice: str, lista: dict) -> list[dict] | None:
    cd = _cartella("uninsubria_leganto")
    f = cd / f"lista_{lista['id']}.json" if cd else None
    if f and f.exists():
        return json.loads(f.read_text(encoding="utf-8"))
    ses = _sess_mem.get(codice)
    if ses is None:  # le liste sono già in cache ma non questa: nuova sessione per il codice
        ses = Sessione(codice)
        if not ses.apri():
            return None
        _sess_mem[codice] = ses
    x = _json(ses.s, f"{LEGANTO}/rl/main/lists/{lista['id']}")
    if not isinstance(x, dict) or not isinstance((x.get("object") or {}).get("sections"), list):
        return None
    libri, viste = [], set()
    for sez in x["object"]["sections"]:
        for c in sez.get("citations") or []:
            if c.get("type") not in ("BK", "BC") or c.get("secondaryType") not in (None, "BK", "BC", "E_BK"):
                continue
            lb = leganto._libro(c.get("dc") or {}, sez.get("name") or "")
            if lb:
                k = lb["isbn"] or re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(lb)
    if f:
        f.write_text(json.dumps(libri, ensure_ascii=False), encoding="utf-8")
    return libri


def _e_libro(b: dict) -> bool:
    """Scarta le voci che sono avvisi e non libri («Materiale didattico reso disponibile dal docente…»):
    senza autori, editore, ISBN né anno, o con un titolo da avviso."""
    if re.match(r"(?i)\s*(materiale|dispense|slide|appunti|lucidi|nessun|non previst|da definire|testi? (?:indicat|fornit|forniti))",
                b.get("titolo") or ""):
        return False
    return bool(b.get("autori") or b.get("editore") or b.get("isbn") or b.get("anno"))


def libri_codice(codice: str, anno: int, cds: str | None = None) -> list[dict] | None:
    """Libri della lista più recente (a.a. `anno` se c'è, ma non prima del 2022/23) del codice; la nota dice l'a.a.
    se è precedente. Tra le liste dello stesso a.a. si preferiscono quelle con il codice del corso nel nome
    (es. «… - F11R»). None se Leganto non risponde (da riprovare), [] se non ci sono liste con libri."""
    liste = _liste(codice)
    if liste is None:
        return None
    per_anno: dict[int, list[dict]] = {}
    for l in liste:
        if l["anno"] and ANNO_MIN <= l["anno"] <= anno:
            per_anno.setdefault(l["anno"], []).append(l)
    for a in sorted(per_anno, reverse=True):
        ls = per_anno[a]
        if cds:
            sue = [l for l in ls if re.search(rf"\b{re.escape(cds)}\b", l["nome"], re.I)]
            ls = sue or ls
        out, viste = [], set()
        for l in ls:
            lb = _libri_lista(codice, l)
            if lb is None:
                return None
            for b in filter(_e_libro, lb):
                k = b["isbn"] or re.sub(r"\W+", "", b["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    b = dict(b)
                    if a < anno:
                        b["note"] = (f"Dalla bibliografia Leganto dell'a.a. {a}/{(a + 1) % 100:02d} dello stesso "
                                     f"insegnamento: quella del {anno}/{(anno + 1) % 100:02d} non è ancora pubblicata")
                    out.append(b)
        if out:
            return out
    return []


def _codici_leganto(sy: dict) -> list[str]:
    """courseCode dei link a Leganto nel syllabus (di solito l'id dell'attività nel catalogo)."""
    out = []
    for t in sy.get("testiTotali") or []:
        for a in (list(cineca_catalogue._lista(t.get("altri_testi"))) + list(cineca_catalogue._lista(t.get("mod_altri_testi")))
                  + list(cineca_catalogue._lista(t.get("altri_testi_ugov")))):
            testo = " ".join(str(a.get(k) or "") for k in ("altri_testi_it", "altri_testi_en", "ugov_altri_testi_it",
                                                            "ugov_altri_testi_en"))
            for m in re.finditer(r"courseCode=([\w.\-]+)", _h.unescape(testo)):
                if m.group(1) not in out:
                    out.append(m.group(1))
    return out


EDITORI = re.compile(r"(?i)\b(ed\.|edizion\w*|edra|edises|edi\.?\s?ermes|masson|elsevier|zanichelli|pearson|piccin|springer|"
                     r"mcgraw|mondadori|giuffr\w+|cedam|il mulino|wiley|cambridge|oxford|utet|esculapio|minerva|amplifon|"
                     r"apogeo|hoepli|laterza|einaudi|carocci|franco ?angeli|giappichelli|jovene|wolters|lippincott)(?!\w)")
MARCATORE = re.compile(r"(?i)(?:\btest[oi]\s+(?:di\s+riferimento|consigliat\w+|adottat\w+|d['’]esame)[^:：\n]{0,60}?[:：]"
                       r"|\b(?:si\s+consigliano|sono\s+consigliati|vengono\s+consigliati)\s+(?:i\s+seguenti\s+)?(?:testi|libri)\s*[:：]"
                       r"|\b(?:il\s+)?(?:testo|libro)\s+(?:consigliato|di\s+testo(?:\s+obbligatorio)?)\s*(?:è|:)\s*[:：]?"
                       r"|\btesti\s*[:：]|\btesto\s+e\s+materiale\s+di\s+studio)")
STOP = re.compile(r"(?i)\b(il\s+docente|la\s+docente|ricevimento|appuntament\w+|e-?mail|risultati\s+di\s+apprendimento|"
                  r"slides?|dispense|materiale\s+didattico|orario|titolare)\b")


def _pulito(v) -> str:
    t = _h.unescape(re.sub(r"<[^>]+>", " ", str(v or "")))
    t = re.sub(r"\[Text Wrapping Break\]", "\n", t)
    return re.sub(r"[ \t\r\f\v\xa0]+", " ", re.sub(r"\s*\n\s*", "\n", t)).strip()


def _forma(c: str) -> bool:
    """La voce ha la forma di una citazione: non è un avviso, un contatto o un rimando alle slide."""
    if len(c) < 15 or (not c[0].isalpha() and c[0] not in "“\"«'"):
        return False
    if re.search(r"(?i)@|https?://|www\.|^(?:dispens|slide|materiale|nessun|non previst|da definire|vedi|si rimanda|sarà|saranno|il docente)", c):
        return False
    return bool(re.search(r"\b(?:19|20)\d\d\b", c) or _isbn(c) or EDITORI.search(c)
                or re.search(r"[“\"«][^”\"»]{4,}[”\"»]", c))


def _libri_marcatori(sy: dict) -> list[dict]:
    """Testi indicati a mano nei campi «testi» e «altro» del syllabus (compresi i moduli): dopo un'etichetta come
    «Testi di riferimento:» o «il testo consigliato è:» fino al primo avviso (ricevimento, e-mail, slide…)."""
    voci: list[str] = []
    for t in sy.get("testiTotali") or []:
        for k in ("testi_it", "mod_testi_it", "altro_it", "mod_altro_it"):
            txt = _pulito(t.get(k))
            if not txt:
                continue
            if MARCATORE.search(txt):
                resto = MARCATORE.split(txt)[1:]
            elif k.endswith("testi_it"):
                resto = [txt]  # il campo «testi» senza etichetta: tutto il testo
            else:
                continue
            for r in resto:
                m = STOP.search(r)
                r = r[:m.start()] if m else r
                for riga in re.split(r"\n|;\s+(?=[A-Z“\"])", r):
                    riga = riga.strip(" .:;-–—")
                    riga = re.sub(r"^(?:e|ed)\s+", "", riga)
                    if _forma(riga) and riga not in voci:
                        voci.append(riga)
    out = []
    for c in voci:
        y = re.findall(r"\b((?:19|20)\d\d)\b", c)
        out.append({"titolo": c, "autori": None, "editore": None, "anno": int(y[-1]) if y else None,
                    "edizione": None, "isbn": _isbn(c), "lingua": None, "tipo": None, "note": None, "citazione": c})
    return out


def libri_testo(sy: dict) -> list[dict]:
    """Testi scritti a mano nel syllabus, solo le voci che hanno la forma di una citazione (anno, ISBN o editore)."""
    marcati = _libri_marcatori(sy)
    if marcati:
        return marcati
    testi = [{"testi_it": t.get("altro_it") or "", "mod_testi_it": t.get("mod_altro_it") or ""}
             for t in sy.get("testiTotali") or []]
    out = []
    for b in unifi_testi.libri_unifi({"testiTotali": testi}):
        c = b.get("citazione") or ""
        if len(c) >= 25 and c[0].isupper() and (YEAR.search(c) or _isbn(c) or unifi_testi._editore(c.lower())):
            out.append(b)
    return out


_testi_originale = cineca_catalogue._testi_syllabus


def _testi_syllabus(sy: dict):
    """Libri del syllabus (marcati `_testo`) più i codici Leganto del syllabus (`_leganto`); le liste si leggono dopo,
    per codice e a.a., con una sessione per codice."""
    libri, modalita, _ = _testi_originale(sy)
    libri = [b for b in libri if len(b.get("citazione") or "") <= 350]  # prosa («Per preparare i test OFA: …»), non citazioni
    if not libri:
        libri = libri_testo(sy)
    libri = [dict(b, _testo=True) for b in libri]
    return libri + [{"_leganto": c} for c in _codici_leganto(sy)], modalita, []


def _codici_item(i: dict) -> list[str]:
    cod = str(i.get("codice") or "").strip()
    if not cod:
        return []
    base = re.sub(r"-\d+$", "", cod)  # «SME0207-2» → «SME0207»
    return list(dict.fromkeys(x for x in (cod, base) if x))


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    p = ROOT / "database" / "corsi" / "uninsubria.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("stato_libri") and (i.get("libri") or cod not in out):
                out[cod] = {k: i.get(k) for k in ("libri", "stato_libri", "modalita_esame", "ssd", "url_sito")}
                out[cod]["libri"] = out[cod]["libri"] or []
    return out


def fetch_ateneo(uid: str = "uninsubria", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    c = ClientCache(anno=anno)
    doc = uninsubria_piani.fetch_piani(uid, anno, c, BASE, _testi_syllabus, _libri_database() if syllabus else {},
                                       max_cds=max_cds, syllabus=syllabus, log=log, id_universitaly=ID_UNIVERSITALY)
    for cc in doc["corsi"]:
        for i in cc["insegnamenti"]:
            if re.match(r"(?i)\s*non disponibile", i.get("periodo") or ""):
                i["periodo"] = None
    if not syllabus:
        return doc
    # libri: lista Leganto dell'a.a. corrente > testi del syllabus > lista Leganto di un a.a. precedente
    tutti = [(cc, i) for cc in doc["corsi"] for i in cc["insegnamenti"]]
    n_ins = n_lib = n_att = n_old = 0
    t0 = time.time()
    for k, (cc, i) in enumerate(tutti, 1):
        if i.pop("_noto", False):  # libri già nel database per questo codice: non si rileggono
            if i.get("libri"):
                n_ins += 1
                n_lib += len(i["libri"])
            continue
        testo = [b for b in i.get("libri") or [] if b.get("_testo")]
        link = [b["_leganto"] for b in i.get("libri") or [] if b.get("_leganto")]
        m = re.search(r"/insegnamenti/(\d+)/(\d+)/", i.get("url") or "")
        af = c.af.get((m.group(1), m.group(2))) if m else None
        leg: list[dict] | None = []
        fonte = None
        for cod in list(dict.fromkeys(_codici_item(i) + link + ([af] if af else []))):
            r = libri_codice(cod, anno, cc.get("codice_ateneo"))
            if r is None:
                leg = None
                continue
            if r:
                fonte = PUBBLICO.format(urllib.parse.quote(cod))
                leg = [dict(b, fonte=fonte) for b in r]
                break
        if leg and not leg[0].get("note"):  # lista dell'a.a. corrente: vale più di tutto
            scelti = leg
        elif testo:  # testi del syllabus corrente, meglio di una lista di un a.a. precedente
            scelti = [dict({k2: v for k2, v in b.items() if k2 != "_testo"}, fonte=i.get("url")) for b in testo]
        else:
            scelti = leg or []
        if scelti and scelti[0].get("note") and scelti[0].get("fonte") == fonte:
            n_old += 1
        i["libri"] = scelti
        i["stato_libri"] = "completo" if scelti else "da_aggiungere"
        if scelti:
            n_ins += 1
            n_lib += len(scelti)
        if k % 200 == 0:
            log(f"[{uid}] Leganto {k}/{len(tutti)} insegnamenti ({time.time() - t0:.0f}s): {n_ins} con libri")
    log(f"[{uid}] libri: {n_ins} insegnamenti con libri ({n_lib} libri), di cui {n_old} da un a.a. precedente")
    return doc


# --- appelli ---------------------------------------------------------------------------------
def _inizio_aa(oggi=None):
    import datetime
    oggi = oggi or datetime.date.today()
    return datetime.date(oggi.year if oggi.month >= 10 else oggi.year - 1, 10, 1)


def _pagina_valida(t: str | None) -> bool:
    """La risposta è la pagina dei risultati (con la tabella degli appelli o l'avviso di assenza), non un errore."""
    return bool(t) and ("tabellaAppelli" in t or "Nessun appello" in t or "nessun appello" in t or "Nessun risultato" in t)


def fetch_bacheca(uid: str = "uninsubria", log=print, pausa: float = 0.6, da: str | None = None,
                  a: str = "31/12/2027") -> tuple[dict[str, list[dict]], dict[str, set[str]], dict[str, str]]:
    """Bacheca degli appelli dell'offerta di Esse3 (ListaAppelliOfferta), un corso di studio per volta.
    Restituisce gli appelli per codice AD, i nomi dei corsi di studio in cui compare ogni codice e il titolo
    di ogni codice."""
    from .esse3_appelli import HEADERS, _parse
    da = da or _inizio_aa().strftime("%d/%m/%Y")
    cd = _cartella("uninsubria_esse3")
    oggi = time.strftime("%Y%m%d")
    s = requests.Session()
    s.headers.update(HEADERS)
    r = s.get(ESSE3 + "/ListaAppelliOfferta.do", timeout=60)
    form = re.search(r'<form action="([^"]+)" id="formRicercaCds"', r.text)
    if r.status_code != 200 or not form:
        log(f"[{uid}] esse3: bacheca non raggiungibile (HTTP {r.status_code})")
        return {}, {}, {}
    url = ESSE3 + "/" + form.group(1).split(";")[0]
    base = {"data_da": da, "data_a": a, "TIPO_FORM": "1", "form_id_formRicercaCds": "formRicercaCds"}
    sel = re.search(r'<select id="selectionFacolta".*?</select>', r.text, re.S)
    facs = [v for v in re.findall(r'<option value="([^"]*)"', sel.group(0)) if v] if sel else []
    appelli: dict[str, list[dict]] = {}
    origine: dict[str, set[str]] = {}
    titoli: dict[str, str] = {}
    n_cds = 0

    def post(dati: dict, chiave: str) -> str | None:
        f = cd / f"{oggi}_{hashlib.sha1((chiave + da + a).encode()).hexdigest()}.html" if cd else None
        if f and f.exists():
            return f.read_text(encoding="utf-8")
        for tentativo in range(3):
            try:
                x = s.post(url, data=dati, timeout=180)
                time.sleep(pausa)
                if x.status_code == 200 and _pagina_valida(x.text):
                    if f:
                        f.write_text(x.text, encoding="utf-8")
                    return x.text
            except requests.RequestException:
                pass
            time.sleep(3 * (tentativo + 1))
        return None

    for fac in facs:
        t = None
        # l'elenco dei corsi di studio del dipartimento arriva dal refresh del modulo (non si mette in cache)
        for tentativo in range(3):
            try:
                x = s.post(url, data={**base, "fac_id": fac, "cds_id": "", "ad_id": "", "docente_id": "",
                                      "_fw_refresh-form": "selectionFacolta"}, timeout=180)
                time.sleep(pausa)
                if x.status_code == 200:
                    t = x.text
                    break
            except requests.RequestException:
                pass
            time.sleep(3 * (tentativo + 1))
        m = re.search(r'<select id="selectionCds".*?</select>', t or "", re.S)
        cds = re.findall(r'<option value="([^"]+)"[^>]*>([^<]*)', m.group(0)) if m else []
        for cod, etichetta in cds:
            t = post({**base, "fac_id": fac, "cds_id": cod, "ad_id": "", "docente_id": "", "btnSubmit": "Avvia Ricerca"},
                     f"cds{fac}_{cod}")
            if t is None:
                log(f"[{uid}] esse3: corso {cod} (dipartimento {fac}) non letto")
                continue
            n_cds += 1
            nome_cds = re.sub(r"^\s*\[\w+\]\s*", "", _h.unescape(etichetta)).strip()
            for ad, lst in _parse(t.replace("Date e ora del turno", "Data e ora del turno"),
                                  ESSE3 + "/ListaAppelliOfferta.do").items():
                origine.setdefault(ad, set()).add(nome_cds)
                titoli.setdefault(ad, lst[0].get("titolo") or "")
                viste = {(x["data"], x["ora"], x["tipo"]) for x in appelli.get(ad, [])}
                for x in lst:
                    k = (x["data"], x["ora"], x["tipo"])
                    if k not in viste:
                        viste.add(k)
                        appelli.setdefault(ad, []).append(x)
    log(f"[{uid}] esse3: {n_cds} corsi di studio, {len(appelli)} insegnamenti con appelli, "
        f"{sum(len(v) for v in appelli.values())} date")
    return appelli, origine, titoli


def _chiave_nome(nome: str | None) -> str:
    """Nome del corso o dell'attività senza le parentesi («(abilitante alla professione …)»)."""
    return _norm(re.sub(r"\(.*?\)", " ", nome or ""))


def associa_appelli(appelli: dict[str, list[dict]], origine: dict[str, set[str]], titoli: dict[str, str],
                    corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Gli appelli il cui codice AD non è quello del catalogo (altro codice in un'altra coorte o ordinamento)
    si attribuiscono all'insegnamento omonimo del corso di studio che li ospita in Esse3."""
    codici = {i.get("codice") for c in corsi for i in c.get("insegnamenti") or []}
    per_corso: dict[str, dict[str, set[str]]] = {}
    for c in corsi:
        for i in c.get("insegnamenti") or []:
            if i.get("codice"):
                per_corso.setdefault(_chiave_nome(c["nome"]), {}).setdefault(_chiave_nome(i["nome"]), set()).add(i["codice"])
    out = {k: list(v) for k, v in appelli.items()}
    n = 0
    for ad, lst in appelli.items():
        if ad in codici:
            continue
        nome = _chiave_nome(titoli.get(ad) or lst[0].get("titolo"))
        dest: set[str] = set()
        for nome_cds in origine.get(ad, ()):
            dest |= per_corso.get(_chiave_nome(nome_cds), {}).get(nome, set())
        for cod in dest:
            viste = {(x["data"], x["ora"], x["tipo"]) for x in out.get(cod, [])}
            nuovi = [x for x in lst if (x["data"], x["ora"], x["tipo"]) not in viste]
            if nuovi:
                out.setdefault(cod, []).extend(nuovi)
                n += 1
    log(f"[uninsubria] appelli riassegnati per nome e corso: {n} insegnamenti")
    return out


def fetch_appelli(uid: str, corsi: list[dict], log=print) -> dict[str, list[dict]]:
    """Appelli dell'a.a. in corso: bacheca dell'offerta per corso di studio (con riassegnazione per nome dei
    codici che il catalogo non ha), più quella per dipartimento (attività fuori dall'offerta dei corsi)."""
    from .esse3_appelli import fetch_appelli as per_dipartimento
    off, origine, titoli = fetch_bacheca(uid, log=log)
    out = associa_appelli(off, origine, titoli, corsi, log=log) if corsi else off
    try:
        dip = per_dipartimento(uid, ESSE3, log=log, delay=0.6)
    except Exception as e:  # noqa: BLE001
        log(f"[{uid}] esse3 per dipartimento: {e!r}")
        dip = {}
    for cod, lst in dip.items():
        v = out.setdefault(cod, [])
        viste = {(e["data"], e["ora"], e["tipo"]) for e in v}
        for e in lst:
            if (e["data"], e["ora"], e["tipo"]) not in viste:
                viste.add((e["data"], e["ora"], e["tipo"]))
                v.append(e)
    log(f"[{uid}] appelli: {sum(len(v) for v in out.values())} date per {len(out)} insegnamenti")
    return out
