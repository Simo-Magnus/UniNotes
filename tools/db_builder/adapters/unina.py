"""Insegnamenti, docenti, libri e appelli dell'Università di Napoli Federico II da www.corsi.unina.it
e www.docenti.unina.it.

Il portale dei corsi di studio (Angular) legge un'API pubblica (`/corsidistudio-be/v1`):

- `courses?status=attivi|esaurimento&page=…&size=…` → corsi (cdsCod, nome, tipo, classe, durata) e
  `courses/details/<cds>` (dipartimento, anno di attivazione, sito);
- `courses/details/<cds>/study-plans-years` e `…/study-plans/<aa>-<aa+1>` → piani (curricula);
- `…/study-plans/<aa>-<aa+1>/teachings?codPiano=…` → insegnamenti per anno di corso con codice,
  semestre, CFU; `tipo == "G"` è un gruppo a scelta, i cui insegnamenti sono in
  `…/child-teachings?codPiano=…&annoCorso=…&codInsegnamentoPadre=…`;
- `…/teachings/<aa>?page=…` → insegnamenti erogati nell'anno (anche i moduli, con il codice
  dell'insegnamento integrato), `…/teachings/<aa>/<codice>/professors` → docenti con il link
  alla scheda su www.docenti.unina.it, che rimanda a `/teaching/<id docente>/sl/<id scheda>`; la
  scheda è in `www.docenti.unina.it/webdocenti-be/docenti/programmi/schedainsegnamento/<id>`
  (anno di corso, CFU, semestre, SSD, "Materiale didattico" con i testi);
- appelli (la bacheca Esse3 di Federico II è vuota): docenti dei corsi (`…/professors/<aa>`, con
  l'e-mail, usata solo per trovare la pagina) → `www.docenti.unina.it/<nome.cognome>` rimanda a
  `/teacher/<id>` → `webdocenti-be/docenti/<id>/insegnamenti-appelli` e
  `…/insegnamenti/<codice>/<progressivo>/appelli`.

Un corso di studio del database può corrispondere a più codici del portale: il corso nuovo
(spesso attivato nel 2025 o nel 2026, con il solo primo anno o i primi anni) e il corso "ad
esaurimento" con lo stesso nome, in cui si erogano gli anni successivi. Gli anni che mancano al
piano del corso nuovo si prendono dal corso ad esaurimento (stesso nome, classe e dipartimento).
Un corso senza piano pubblicato si ricostruisce dagli insegnamenti erogati nell'anno e dalle loro
schede (anno di corso, CFU, semestre).

Il backend risponde a volte 404 per errore (un nodo del bilanciatore): le richieste JSON si
ripetono con una connessione nuova.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import threading
import time
import unicodedata

import requests

from .testi import _EDITORI_CIT, NON_LIBRO, YEAR, _isbn, _libero, estrai_libri, html_to_lines
from .unibo import HEADERS, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
API = "https://www.corsi.unina.it/corsidistudio-be/v1"
SITO = "https://www.corsi.unina.it"
DOCENTI = "https://www.docenti.unina.it/webdocenti-be/docenti"
SCHEDA = DOCENTI + "/programmi/schedainsegnamento/"
SEM = {"1": "1", "2": "2", "A": "annuale", "0": "annuale"}
# Righe del piano che sono crediti a scelta dello studente («Attività a scelta», «Insegnamento a scelta dello
# studente», «Un esame a scelta libera tra…»), non un insegnamento
_A_SCELTA = re.compile(r"(?i)\ba scelta\b|scelta libera|\bscelte\b")
SEM_SCHEDA = {"primo semestre": "1", "secondo semestre": "2", "annuale": "annuale"}

# Corsi del database con più corsi omonimi sul portale (stesso nome e classe): codice scelto
# guardando il sito del corso (campo `link` del portale / `url` di Universitaly) e il dipartimento.
SCELTE = {
    # profili attivati nel 2026: il secondo anno si eroga nel corso unico precedente (M91)
    "unina-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic": ["DM7", "M91"],
    "unina-lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-ostetrico": ["DM6", "M91"],
    "unina-lm-41-medicina-e-chirurgia": ["DF8", "M39"],  # m39.corsidistudio.unina.it, Medicina clinica
    "unina-lm-41-medicina-e-chirurgia-1634044": ["DM0", "P63"],  # Dip. di Sanità pubblica
    "unina-lm-41-medicine-and-surgery": ["DH6", "P11"],  # stesso sito www.medicina.unina.it/P11
}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _senza_prefisso(s: str | None) -> str:
    """«CORSO DI LAUREA IN INGEGNERIA CHIMICA» -> «ingegneria chimica»."""
    return re.sub(r"^corso di laurea (magistrale )?(a ciclo unico )?(in )?", "", _norm(s))


def _classe(s: str | None) -> str:
    """«LM-4 c.u R», «LM-4 c.u.», «LM-13.», «LM-41 R» -> «LM-4», «LM-4», «LM-13», «LM-41»."""
    m = re.match(r"\S+", (s or "").strip())
    return m.group(0).rstrip(".") if m else ""


class Http:
    """GET con pausa minima tra le richieste e cache su disco (variabile UN_HTTP_CACHE)."""

    def __init__(self, rate: float = 6.0):
        self.gap = 1.0 / rate
        self.lock = threading.Lock()
        self.last = 0.0
        self.requests = 0
        cache = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(cache) if cache else None
        self.oggi = time.strftime("%Y-%m-%d")

    def _attendi(self) -> None:
        with self.lock:
            w = self.last + self.gap - time.monotonic()
            if w > 0:
                time.sleep(w)
            self.last = time.monotonic()
            self.requests += 1

    def _file(self, chiave: str) -> pathlib.Path | None:
        if not self.cache:
            return None
        k = hashlib.sha1(chiave.encode()).hexdigest()
        return self.cache / k[:2] / f"{k}.json"

    def json(self, url: str, tentativi: int = 10, fresco: bool = False):
        """JSON; `fresco` = la cache vale solo per oggi (appelli)."""
        f = self._file(("json|" + url) if not fresco else f"json|{self.oggi}|{url}")
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        for n in range(tentativi):
            self._attendi()
            try:
                r = requests.get(url, timeout=60, headers={**HEADERS, "Accept": "application/json"})
                if r.status_code == 200 and r.text.lstrip()[:1] in "[{":
                    d = r.json()
                    if f:
                        f.parent.mkdir(parents=True, exist_ok=True)
                        f.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
                    return d
            except (requests.RequestException, ValueError):
                pass
            time.sleep(0.3 + 0.4 * n)
        return None

    def redirect(self, url: str) -> str | None:
        """Indirizzo finale dopo i rimandi (solo quello va in cache)."""
        f = self._file("redir|" + url)
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))["url"]
        for n in range(4):
            self._attendi()
            try:
                r = requests.get(url, timeout=60, headers=HEADERS, allow_redirects=True)
                if r.status_code == 404:
                    return None
                if r.status_code == 200:
                    if f:
                        f.parent.mkdir(parents=True, exist_ok=True)
                        f.write_text(json.dumps({"url": r.url}), encoding="utf-8")
                    return r.url
            except requests.RequestException:
                pass
            time.sleep(1 + n)
        return None


def _tipo(x: dict) -> str:
    t = (x.get("tipoCorsoCod") or "").upper()
    if t.startswith("LM") and (x.get("durataAnni") or 0) >= 5:
        return "LMCU"
    return "LM" if t.startswith("LM") else ("L" if t.startswith("L") else t)


def _docente(cognome: str, nome: str) -> str:
    return " ".join(w.capitalize() for w in f"{nome or ''} {cognome or ''}".split())


# --- libri -----------------------------------------------------------------------------------
_SEGNALE = re.compile(r"(?i)\b(autor[ei]|testo|testi|libro|manuale|volume|edizione|edition|ed\.|a cura di|"
                      r"edited by|eds?\.)")
_AUTORE_INIZ = re.compile(r"\b[A-Z]\.\s?(?:[A-Z]\.\s?)?(?:[A-Z][a-zà-ÿ]+|[A-Z]{2,})|\b[A-Z][a-zà-ÿ]+,?\s[A-Z]\.(?:\s?[A-Z]\.)?")
_NON_LIBRO_LIBERO = re.compile(r"(?i)\b(slides?|appunti|dispense|lucidi|materiale (didattico )?(fornito|del docente|"
                               r"disponibile|distribuito)|e-?learning|piattaforma|teams|registrazioni)\b")


def _libri_liberi(testo: str) -> list[dict]:
    """Seconda lettura, solo se `estrai_libri` non trova nulla: righe con un editore noto o con
    autori (iniziali e cognome) e una parola come «testo», «libro», «edizione». La citazione resta
    quella del programma."""
    out = []
    for line in html_to_lines(testo):
        if len(line) < 20 or len(line) > 400 or NON_LIBRO.match(line):
            continue
        editore = bool(_EDITORI_CIT.search(line))
        autori = bool(_AUTORE_INIZ.search(line))
        if _NON_LIBRO_LIBERO.search(line) and not editore:
            continue
        sep = line.count(",") + line.count(";") + line.count(":") + line.count(" - ") + len(re.findall(r"[“\"«]", line))
        if (editore and sep >= 1 and (autori or YEAR.search(line) or _SEGNALE.search(line))) or \
                (autori and _SEGNALE.search(line) and sep >= 1) or _isbn(line):
            out.append(_libero(line))
    return out


_NON_CITAZIONE = re.compile(r"(?i)^\W*(il |i |lo |le |gli )?(materiale (didattico|del corso)|slides?|dispense|appunti|"
                            r"lucidi|registrazioni)\b")


def libri_scheda(d: dict) -> list[dict]:
    """Libri dal "Materiale didattico" della scheda; si scartano le righe che parlano di slide,
    dispense o appunti senza un editore o un ISBN."""
    md = d.get("materialeDidattico") or ""
    libri = estrai_libri(md) or _libri_liberi(md)
    return [lb for lb in libri if not (_NON_CITAZIONE.match(lb["citazione"]) and not _isbn(lb["citazione"])
                                       and not _EDITORI_CIT.search(lb["citazione"]))]


def leggi_scheda(d: dict) -> dict:
    sem = SEM_SCHEDA.get((d.get("semestre") or "").strip().lower())
    return {"libri": libri_scheda(d),
            "ssd": (re.search(r"\(([A-Z]{2,5}-\d{2}/[A-Z])\)", d.get("ssd") or "") or [None, None])[1]
            or (d.get("ssd") or None),
            "anno": int(d["annoDiCorso"]) if str(d.get("annoDiCorso") or "").isdigit() else None,
            "cfu": float(d["cfu"]) if re.fullmatch(r"\d+(\.\d+)?", str(d.get("cfu") or "")) else None,
            "periodo": sem}


def leggi_appelli(d: dict | None, docente: str, fonte: str) -> list[dict]:
    """Appelli pubblicati dal docente (`appelliEsis`), solo quelli non ancora svolti."""
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for a in (d or {}).get("appelliEsis") or []:
        m = re.match(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})", a.get("data") or "")
        if not m or m.group(1) < oggi or a.get("giaSvolto"):
            continue
        dal = re.match(r"\d{4}-\d{2}-\d{2}", a.get("dataInizioPrenotazioni") or "")
        al = re.match(r"\d{4}-\d{2}-\d{2}", a.get("dataFinePrenotazioni") or "")
        out.append({"tipo": "appello", "data": m.group(1), "ora": None if m.group(2) == "00:00" else m.group(2),
                    "luogo": None if re.match(r"(?i)\s*(da definire|n\.?d\.?)?\s*$", a.get("aula") or "")
                    else a["aula"].strip(), "modalita": None,
                    "iscrizioni_dal": dal.group(0) if dal else None, "iscrizioni_al": al.group(0) if al else None,
                    "docenti": docente or None, "note": a.get("sessione") and f"Sessione {a['sessione'].lower()}",
                    "fonte": fonte})
    return out


# --- corsi del portale -------------------------------------------------------------------------
def corsi_portale(h: Http, log=print) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for stato in ("attivi", "esaurimento"):
        p = 0
        while True:
            d = h.json(f"{API}/courses?status={stato}&page={p}&size=50")
            if not d:
                log(f"  elenco corsi {stato}: pagina {p} non letta")
                break
            for x in d.get("items") or []:
                out.setdefault(x["cdsCod"], dict(x, _stato=stato))
            p += 1
            if p >= (d.get("totalPages") or 0):
                break
    for cds, x in out.items():
        det = h.json(f"{API}/courses/details/{cds}") or {}
        x.update({k: v for k, v in det.items() if v is not None and k not in x})
        x["link"] = det.get("link")
        x["annoAttivazione"] = det.get("annoAttivazione")
    return out


def gruppi(corsi: list[dict], portale: dict[str, dict]) -> dict[str, list[str]]:
    """Corso del database -> codici del portale (il principale per primo, poi i corsi ad
    esaurimento con lo stesso nome, classe e dipartimento, dal più recente)."""
    attivi = [x for x in portale.values() if x["_stato"] == "attivi"]
    esaur = [x for x in portale.values() if x["_stato"] == "esaurimento"]
    per_nome: dict[tuple[str, str], list[dict]] = {}
    per_eng: dict[tuple[str, str], list[dict]] = {}
    for x in attivi:
        per_nome.setdefault((_norm(x.get("nomeCds")), _tipo(x)), []).append(x)
        if x.get("nomeCdsEng"):
            per_eng.setdefault((_norm(x["nomeCdsEng"]), _tipo(x)), []).append(x)
    res: dict[str, list[str]] = {}
    for corso in corsi:
        if corso["id"] in SCELTE:
            res[corso["id"]] = [c for c in SCELTE[corso["id"]] if c in portale]
            continue
        tipo = "L" if corso["tipo"] == "LP" else corso["tipo"]
        cand = per_nome.get((_norm(corso["nome"]), tipo)) or per_eng.get((_norm(corso.get("nome_en") or ""), tipo)) \
            or per_eng.get((_norm(corso["nome"]), tipo)) or []
        if len(cand) > 1 and corso.get("classe"):
            cand = [x for x in cand if _classe(x.get("claMiurCod")) == _classe(corso["classe"].split(" / ")[0])] or cand
        if not cand:
            continue
        # più corsi attivi omonimi (ordinamento nuovo e vecchio): il più recente per primo
        cand = sorted(cand, key=lambda x: -(x.get("annoAttivazione") or 0))
        if len({x["dipCod"] for x in cand}) > 1:
            continue  # omonimi di dipartimenti diversi: serve una scelta esplicita (SCELTE)
        prim = cand[0]
        vecchi = [x for x in esaur if _senza_prefisso(x.get("nomeCds")) == _senza_prefisso(prim.get("nomeCds"))
                  and _classe(x.get("claMiurCod")) == _classe(prim.get("claMiurCod"))
                  and x.get("dipCod") == prim.get("dipCod")]
        vecchi.sort(key=lambda x: -(x.get("annoAttivazione") or 0))
        res[corso["id"]] = [x["cdsCod"] for x in cand] + [x["cdsCod"] for x in vecchi]
    return res


def fetch_ateneo(uid: str = "unina", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if not c.get("piano_da")]
    h = Http(rate=6.0)
    oggi = time.strftime("%Y-%m-%d")
    portale = corsi_portale(h, log)
    gr = gruppi(corsi, portale)
    if max_cds:
        gr = dict(list(gr.items())[:max_cds])
    log(f"[{uid}] {len(portale)} corsi sul portale, {len(gr)} corsi del database associati (su {len(corsi)})")
    tutti_cds = sorted({c for v in gr.values() for c in v})

    # insegnamenti erogati (anche moduli) per corso e anno
    erog: dict[tuple[str, int], list[dict]] = {}

    def leggi_erog(job):
        cds, a = job
        items, p = [], 0
        while True:
            d = h.json(f"{API}/courses/details/{cds}/teachings/{a}?page={p}&size=100")
            if not d:
                break
            items += d.get("items") or []
            p += 1
            if p >= (d.get("totalPages") or 0):
                break
        return job, items

    with cf.ThreadPoolExecutor(4) as ex:
        for job, items in ex.map(leggi_erog, [(cds, a) for cds in tutti_cds for a in (anno, anno - 1)]):
            erog[job] = items
    log(f"[{uid}] erogati letti: {sum(len(v) for v in erog.values())} righe in {len(erog)} elenchi")

    # docenti e schede: (cds, anno, codice) -> [(docente, link, scheda)]
    lock = threading.Lock()
    cache_doc: dict[tuple[str, int, str], list] = {}

    def schede(cds: str, a: int, cod: str) -> list[tuple[str, str | None, dict | None]]:
        k = (cds, a, cod)
        with lock:
            if k in cache_doc:
                return cache_doc[k]
        out = []
        profs = h.json(f"{API}/courses/details/{cds}/teachings/{a}/{cod}/professors", 4) or []
        for p in profs:
            nome = _docente(p.get("cognome"), p.get("nome")) if p.get("cognome") else None
            d = None
            if p.get("link"):
                u = h.redirect(p["link"])
                m = re.search(r"/sl/(\d+)", u or "")
                d = h.json(SCHEDA + m.group(1), 4) if m else None
            out.append((nome, p.get("link"), d))
        with lock:
            cache_doc[k] = out
        return out

    def moduli(cds: str, a: int, cod: str) -> list[str]:
        return sorted({t["codInsegnamento"] for t in erog.get((cds, a), []) if t.get("codIntegrato") == cod
                       and t["codInsegnamento"] != cod})

    # piani per corso del portale
    def piano(cds: str) -> list[tuple[int, dict[int, list[dict]], dict[str, str]]]:
        """Piani degli ultimi anni accademici (il più recente per primo): gli anni successivi al
        primo si erogano spesso secondo il piano della coorte precedente."""
        trovati = []
        anni = h.json(f"{API}/courses/details/{cds}/study-plans-years") or []
        for aa in sorted((a for a in anni if a <= anno), reverse=True)[:3]:
            aas = f"{aa}-{aa + 1}"
            piani = h.json(f"{API}/courses/details/{cds}/study-plans/{aas}") or []
            piani = [pi for pi in piani if not pi.get("aaDisattiva") or pi["aaDisattiva"] > aa] or piani
            fonte = f"{SITO}/{cds}/piani-degli-studi?anno={aas}"
            nomi = {pi["codPiano"]: _titolo(re.sub(r"(?i)\s*(da|dall'|dal)\s*(l')?\s*(a\.?\s?a\.?\s*)?\d{2,4}\s*[/-]\s*\d{2,4}\s*$",
                                                   "", pi.get("descPiano") or pi["codPiano"]).strip())
                    for pi in piani}
            righe: dict[str, dict] = {}

            def aggiungi(t: dict, pc: str, obbl: bool, segnaposto: bool = False) -> None:
                k, cod = t.get("annoCorso"), t.get("codInsegnamento")
                if not k or not cod:
                    return
                item = righe.get(f"{k}:{cod}")
                if not item:
                    nome = re.sub(r"\s*\(\s*integrato\s*\)\s*$", "", t.get("descInsegnamento") or "", flags=re.I)
                    item = righe[f"{k}:{cod}"] = {
                        # i segnaposto «a scelta» hanno lo stesso codice in anni diversi: uno per anno
                        "codice": f"{cod}-a{k}" if segnaposto else cod, "nome": _titolo(nome), "anno": k,
                        "periodo": SEM.get(str(t.get("semestre") or "")), "cfu": t.get("cfu"),
                        "ssd": t.get("ssd") or None, "obbligatorio": obbl, "curriculum": None, "docenti": [],
                        "url": None if segnaposto else f"{SITO}/{cds}/insegnamenti/{aa}/{cod}", "libri": [],
                        "esami": [], "fonte": fonte, "verificato_il": oggi, "_p": set(), "_cds": cds, "_aa": aa,
                        "_ph": segnaposto}
                item["obbligatorio"] = item["obbligatorio"] or obbl
                item["_p"].add(pc)

            tot: dict[tuple, float] = {}  # (piano, anno di corso) -> CFU del piano (gruppi a scelta una volta sola)
            for pi in piani:
                for t in h.json(f"{API}/courses/details/{cds}/study-plans/{aas}/teachings?codPiano={pi['codPiano']}") or []:
                    tot[(pi["codPiano"], t.get("annoCorso"))] = tot.get((pi["codPiano"], t.get("annoCorso")), 0) +                         (t.get("cfu") if isinstance(t.get("cfu"), (int, float)) else 0)
                    if t.get("tipo") == "G":
                        figli = h.json(f"{API}/courses/details/{cds}/study-plans/{aas}/child-teachings?codPiano="
                                       f"{pi['codPiano']}&annoCorso={t.get('annoCorso')}&codInsegnamentoPadre="
                                       f"{t.get('codInsegnamento')}") or []
                        if not figli or not any(isinstance(f.get("cfu"), (int, float)) and f["cfu"] > 0 for f in figli):
                            # gruppo senza elenco o con insegnamenti senza CFU: i CFU a scelta restano nel piano
                            aggiungi(t, pi["codPiano"], False, segnaposto=True)
                        # gruppo da sostenere per intero (i CFU dei figli non superano quelli del gruppo): obbligatorio
                        intero = bool(t.get("cfu")) and all(isinstance(f.get("cfu"), (int, float)) and f["cfu"] > 0
                                                            for f in figli)                             and sum(f["cfu"] for f in figli) <= t["cfu"] + 0.01
                        for f in figli:
                            aggiungi(f, pi["codPiano"], intero)
                    elif _A_SCELTA.search(t.get("descInsegnamento") or ""):
                        # crediti a scelta dello studente: nel piano come riga unica con i suoi CFU
                        aggiungi(t, pi["codPiano"], False, segnaposto=True)
                    else:
                        aggiungi(t, pi["codPiano"], True)
            if not righe:
                continue
            tutti = set(nomi)
            per_anno: dict[int, list[dict]] = {}
            for i in righe.values():
                ps = i.pop("_p")
                i["_tot"] = max([v for (q, a), v in tot.items() if a == i["anno"] and q in ps] or [0])
                if len(tutti) > 1 and ps != tutti:
                    i["curriculum"] = ", ".join(sorted(nomi[q] for q in ps))
                per_anno.setdefault(i["anno"], []).append(i)
            trovati.append((aa, per_anno, (nomi if len(tutti) > 1 else {})))
        return trovati

    def da_erogati(cds: str) -> dict[int | None, list[dict]]:
        """Insegnamenti erogati nell'anno (corso senza piano pubblicato): i moduli si raccolgono
        sotto l'insegnamento integrato; anno, CFU e semestre dalle schede."""
        gruppi_i: dict[str, dict] = {}
        for t in erog.get((cds, anno), []):
            padre = t.get("codIntegrato")
            cod = padre or t["codInsegnamento"]
            g = gruppi_i.setdefault(cod, {"cod": cod, "nome": t.get("descIntegrato") if padre else t["descInsegnamento"],
                                          "mod": []})
            g["mod"].append(t["codInsegnamento"])
        out: dict[int | None, list[dict]] = {}
        for g in gruppi_i.values():
            anni, cfu, per, ssd, ok = set(), 0.0, set(), None, True
            for m in sorted(set(g["mod"])):
                sch = [leggi_scheda(d) for _, _, d in schede(cds, anno, m) if d]
                if not sch:
                    ok = False
                    continue
                anni.add(sch[0]["anno"])
                per.add(sch[0]["periodo"])
                ssd = ssd or (sch[0]["ssd"] if len(set(g["mod"])) == 1 else None)
                if sch[0]["cfu"] is None:
                    ok = False
                else:
                    cfu += sch[0]["cfu"]
            anni.discard(None)
            k = anni.pop() if len(anni) == 1 else None
            per.discard(None)
            out.setdefault(k, []).append({
                "codice": g["cod"], "nome": _titolo(g["nome"] or g["cod"]), "anno": k,
                "periodo": per.pop() if len(per) == 1 else None,
                "cfu": (int(cfu) if cfu == int(cfu) else cfu) if ok and cfu else None, "ssd": ssd,
                "obbligatorio": None, "curriculum": None, "docenti": [],
                "url": f"{SITO}/{cds}/insegnamenti/{anno}/{g['cod']}", "libri": [], "esami": [],
                "fonte": f"{SITO}/{cds}/insegnamenti?anno={anno}", "verificato_il": oggi, "_cds": cds, "_aa": anno})
        return out

    def erogati(cds: str) -> set[str]:
        return {c for t in erog.get((cds, anno), []) for c in (t["codInsegnamento"], t.get("codIntegrato")) if c}

    def build(cid: str) -> dict | None:
        """Per ogni anno di corso si prendono gli insegnamenti del primo codice del gruppo che li
        eroga davvero nell'a.a. (il corso nuovo per i primi anni, il corso ad esaurimento per gli
        anni successivi); se nessuno li eroga, quelli del piano del corso principale."""
        corso = next(c for c in corsi if c["id"] == cid)
        codici = gr[cid]
        dur = corso.get("durata_anni") or portale[codici[0]].get("durataAnni") or 0
        dati = []
        for cds in codici:
            for aa, per_anno, nomi in piano(cds):
                dati.append((cds, per_anno, nomi, erogati(cds)))
        if not dati and re.search(r"(?i)\breplica\b", corso["nome"]):
            return None  # replica di sede senza piano proprio: riceve la struttura del corso principale (pulizia.repliche)
        coperti = {k for _, pa, _, _ in dati for k in pa}
        if not dati or (dur and not all(k in coperti for k in range(1, dur + 1))):
            for cds in codici:  # anni senza piano: dagli insegnamenti erogati e dalle loro schede
                dati.append((cds, da_erogati(cds), {}, erogati(cds)))
        presi: dict[int | None, list[dict]] = {}
        erogati_corso = None
        curricula: dict[str, str] = {}
        fonti: list[str] = []
        anni = sorted({k for _, pa, _, _ in dati for k in pa if k is not None and (not dur or k <= dur)})
        for k in anni:
            cand = [(cds, pa[k], nomi, er) for cds, pa, nomi, er in dati if pa.get(k)]
            scelto = next((c for c in cand if sum(r["codice"] in c[3] for r in c[1]) >= max(1, 0.3 * len(c[1]))),
                          cand[0])

            def cfu_piano(c):
                return max((r.get("_tot") or 0 for r in c[1]), default=0)

            # piano di quell'anno quasi vuoto (corso nuovo con anni ancora da pubblicare): si prende
            # l'anno più completo tra gli altri piani dello stesso corso (coorte precedente)
            if cfu_piano(scelto) < 40:
                meglio = max(cand, key=cfu_piano)
                if cfu_piano(meglio) > cfu_piano(scelto) + 10:
                    scelto = meglio
            presi[k] = scelto[1]
            if 0 < cfu_piano(scelto) < 40:
                # piano di quell'anno molto incompleto: si aggiungono gli insegnamenti erogati nell'anno
                # (con anno di corso, CFU e semestre dalle schede) che il piano non ha
                if erogati_corso is None:
                    erogati_corso = da_erogati(codici[0])
                noti = {r["codice"] for r in presi[k]}
                presi[k] = presi[k] + [r for r in erogati_corso.get(k, []) if r["codice"] not in noti]
            curricula.update(scelto[2])
            if scelto[0] not in fonti:
                fonti.append(scelto[0])
        senza_anno = next((pa[None] for cds, pa, _, _ in dati if cds == codici[0] and pa.get(None)), None)
        if senza_anno and not any(k for k in presi if k):  # anno di corso ignoto: solo se non c'è altro
            presi[None] = senza_anno
        elif senza_anno:
            noti = {r["codice"] for v in presi.values() for r in v}
            presi[None] = [r for r in senza_anno if r["codice"] not in noti]
        righe = [r for v in presi.values() for r in v]
        if not righe:
            return None
        cds0 = codici[0]
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": f"{SITO}/{cds0}",
                "curricula": sorted(set(curricula.values())) or None,
                "fonte": righe[0]["fonte"], "verificato_il": oggi, "insegnamenti": righe, "_codici": codici,
                "_fonti": fonti}

    out = []
    with cf.ThreadPoolExecutor(4) as ex:
        for n, r in enumerate(ex.map(lambda k: _sicuro(build, k, log), list(gr)), 1):
            if r:
                out.append(r)
            if n % 20 == 0:
                log(f"[{uid}]   corsi {n}/{len(gr)}")
    log(f"[{uid}] piani: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti "
        f"(da più codici: {sum(1 for x in out if len(x['_fonti']) > 1)})")

    # indice codice -> corsi del portale in cui è erogato
    dove: dict[tuple[int, str], list[str]] = {}
    for (cds, a), items in erog.items():
        for t in items:
            for cod in {t["codInsegnamento"], t.get("codIntegrato")} - {None}:
                dove.setdefault((a, cod), [])
                if cds not in dove[(a, cod)]:
                    dove[(a, cod)].append(cds)
    nomi_cds = {k: _titolo(v.get("nomeCds") or k) for k, v in portale.items()}

    def scheda_job(job) -> int:
        x, it = job
        cod, cds_r = it["codice"], it.pop("_cds")
        it.pop("_aa", None)
        if it.pop("_ph", False):  # crediti a scelta: nessuna scheda
            it["stato_libri"] = "da_aggiungere"
            return 0
        gruppo = [cds_r] + [c for c in x["_codici"] if c != cds_r]
        livelli = []
        for a in (anno, anno - 1):
            livelli.append([(c, a) for c in gruppo])
        if not _NON_INSEGNAMENTO.search(it["nome"] or ""):
            # stesso insegnamento in altri corsi: al più 6 corsi per anno (i codici comuni come
            # «Lingua inglese» sono erogati in decine di corsi)
            for a in (anno, anno - 1):
                livelli.append([(c, a) for c in dove.get((a, cod), []) if c not in gruppo][:6])
        docenti_ok = False
        for li, livello in enumerate(livelli):
            libri, viste, url_sito = [], set(), None
            for cds, a in livello:
                coppie = schede(cds, a, cod)
                if not coppie:
                    for m in moduli(cds, a, cod):
                        coppie = coppie + schede(cds, a, m)
                if not coppie:
                    continue
                if not docenti_ok and li < 2:
                    it["docenti"] = sorted({n for n, _, _ in coppie if n})
                    docenti_ok = bool(it["docenti"])
                for _, link, d in coppie:
                    if not d:
                        continue
                    s = leggi_scheda(d)
                    it["ssd"] = it["ssd"] or s["ssd"]
                    if it.get("cfu") is None and s["cfu"] and cds == cds_r:
                        it["cfu"] = int(s["cfu"]) if s["cfu"] == int(s["cfu"]) else s["cfu"]
                    for lb in s["libri"]:
                        k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                        if k in viste:
                            continue
                        viste.add(k)
                        if li >= 2 or cds not in x["_codici"]:
                            lb["note"] = f"Dal programma dello stesso insegnamento ({cod}) nel corso " \
                                         f"{nomi_cds.get(cds, cds)}, a.a. {a}/{(a + 1) % 100:02d}"
                        elif a != anno:
                            lb["note"] = f"Dal programma dell'a.a. {a}/{(a + 1) % 100:02d}"
                        libri.append(lb)
                        url_sito = url_sito or link
            if libri:
                it["libri"] = libri
                it["url_sito"] = it.get("url_sito") or url_sito
                it["stato_libri"] = "completo"
                return len(libri)
        it["stato_libri"] = "da_aggiungere"
        return 0

    jobs = [(x, i) for x in out for i in x["insegnamenti"]]
    trovati = 0
    # UN_RIUSA=<contributo precedente>: per gli insegnamenti già raccolti (stesso corso, codice e anno)
    # si riprendono libri e docenti, e si leggono le schede solo dei nuovi
    riusa: dict[tuple, dict] = {}
    if os.environ.get("UN_RIUSA") and pathlib.Path(os.environ["UN_RIUSA"]).exists():
        for x in json.loads(pathlib.Path(os.environ["UN_RIUSA"]).read_text(encoding="utf-8")).get("corsi") or []:
            for i in x.get("insegnamenti") or []:
                if i.get("stato_libri") == "completo" or i.get("docenti"):
                    riusa[(x["id"], i.get("codice"), i.get("anno"))] = i
        log(f"[{uid}] insegnamenti da riusare: {len(riusa)}")
    nuovi_jobs = []
    for x, it in jobs:
        vecchio = riusa.get((x["id"], it["codice"], it["anno"]))
        if vecchio:
            for k in ("libri", "docenti", "url_sito", "stato_libri"):
                if vecchio.get(k):
                    it[k] = vecchio[k]
            it["ssd"] = it.get("ssd") or vecchio.get("ssd")
            it.pop("_cds", None)
            it.pop("_ph", None)
            it.setdefault("stato_libri", "da_aggiungere")
        else:
            nuovi_jobs.append((x, it))
    if riusa:
        log(f"[{uid}] schede da leggere: {len(nuovi_jobs)} su {len(jobs)}")
        jobs = nuovi_jobs
    if syllabus:
        with cf.ThreadPoolExecutor(6) as ex:
            for n, k in enumerate(ex.map(lambda j: _sicuro(scheda_job, j, log) or 0, jobs), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
        log(f"[{uid}] libri trovati: {trovati}; richieste: {h.requests}")
        n = appelli(h, out, erog, anno, log=lambda s: log(f"[{uid}] {s}"))
        log(f"[{uid}] appelli: {n} date; richieste: {h.requests}")
    for x in out:
        x.pop("_codici", None)
        x.pop("_fonti", None)
        for i in x["insegnamenti"]:
            i.pop("_cds", None)
            i.pop("_aa", None)
            i.pop("_ph", None)
            i.pop("_tot", None)
    return {"universita_id": uid, "descrizione": "Generato da www.corsi.unina.it e www.docenti.unina.it "
                                                 "(adapters/unina.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


_NON_INSEGNAMENTO = re.compile(r"(?i)prova finale|tesi|tirocini|stage|altre attivit|ulteriori attivit|a scelta|"
                               r"crediti liberi|seminari|attivit[aà] formativ|\bade\b|laboratorio professionalizzante")


def _sicuro(f, arg, log):
    try:
        return f(arg)
    except Exception as e:  # noqa: BLE001 - si salta solo quell'elemento
        log(f"  errore {f.__name__}: {e!r}")
        return None


def appelli(h: Http, out: list[dict], erog: dict, anno: int, log=print) -> int:
    """Appelli dalle pagine dei docenti: docenti dei corsi (corsi.unina.it, a.a. corrente e
    precedente, anche dei corsi ad esaurimento collegati) → pagina su www.docenti.unina.it
    (dall'indirizzo e-mail) → insegnamenti con appelli → date. Si agganciano agli insegnamenti con
    lo stesso codice (o all'insegnamento integrato di cui il codice è un modulo) nei corsi del
    database che comprendono quel corso del portale."""
    per_cds: dict[str, list[dict]] = {}
    for x in out:
        for c in x["_codici"]:
            per_cds.setdefault(c, []).append(x)
    padre: dict[tuple[str, str], str] = {}
    for (cds, a), items in erog.items():
        for t in items:
            if t.get("codIntegrato") and t["codIntegrato"] != t["codInsegnamento"]:
                padre.setdefault((cds, t["codInsegnamento"]), t["codIntegrato"])
    email: set[str] = set()
    for cds in per_cds:
        for a in (anno, anno - 1):
            p = 0
            while True:
                d = h.json(f"{API}/courses/details/{cds}/professors/{a}?page={p}&size=100", 6)
                for pr in (d or {}).get("items") or []:
                    if (pr.get("email") or "").endswith("@unina.it"):
                        email.add(pr["email"].split("@")[0].lower())
                p += 1
                if not d or p >= (d.get("totalPages") or 0):
                    break
    log(f"{len(email)} docenti dei corsi")

    def docente(e: str) -> list[tuple[dict, str, str]]:
        u = h.redirect(f"https://www.docenti.unina.it/{e}")
        m = re.search(r"/teacher/([\w-]+)", u or "")
        if not m:
            return []
        d = h.json(f"{DOCENTI}/{m.group(1)}/insegnamenti-appelli?p=0&s=99", 4, fresco=True) or {}
        res = []
        for ins in d.get("content") or []:
            if ins.get("codCorso") not in per_cds or ins.get("progInse") is None:
                continue
            a = h.json(f"{DOCENTI}/{m.group(1)}/insegnamenti/{ins['codInse']}/{ins['progInse']}/appelli?p=0&s=99", 4,
                       fresco=True)
            nome = _docente(ins.get("cognomeDocente"), ins.get("nomeDocente"))
            res += [(e2, ins["codCorso"], ins["codInse"])
                    for e2 in leggi_appelli(a, nome, f"https://www.docenti.unina.it/{m.group(0).lstrip('/')}")]
        return res

    tot = 0
    with cf.ThreadPoolExecutor(6) as ex:
        for n, res in enumerate(ex.map(lambda e: _sicuro(docente, e, log) or [], sorted(email)), 1):
            for e, cds, cod in res:
                codici = {cod, padre.get((cds, cod))} - {None}
                for x in per_cds[cds]:
                    for it in x["insegnamenti"]:
                        if it["codice"] in codici and (e["data"], e["ora"], e["docenti"]) not in \
                                {(y["data"], y["ora"], y.get("docenti")) for y in it["esami"]}:
                            it["esami"].append(dict(e))
                            it["esami"].sort(key=lambda y: (y["data"], y["ora"] or ""))
                            it["stato_esami"] = "completo"
                            tot += 1
            if n % 500 == 0:
                log(f"  docenti {n}/{len(email)}")
    return tot
