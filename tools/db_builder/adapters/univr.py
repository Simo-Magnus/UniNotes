"""Insegnamenti e docenti dell'Università di Verona da www.corsi.univr.it.

Esse3 di UniVR non pubblica l'offerta; il portale dei corsi sì:

- `/?ent=cs&id=<id>&menu=studiare&tab=insegnamenti&erogata=1&aa=<a.a.>` (richiesta con
  `X-Requested-With: XMLHttpRequest`, come fa la pagina) → insegnamenti erogati nell'a.a.
  divisi per periodo (con le date) e anno di iscrizione: nome, TAF, SSD, docenti e codice
  Esse3 dell'attività (`codins`, lo stesso degli appelli);
- dettaglio dell'insegnamento (stessa URL con `codins`) → crediti e moduli.

La bibliografia è su Leganto: il dettaglio ha il link pubblico della lista (`…/leganto/public/
39UVR_INST/lists?courseCode=…`), che si legge senza credenziali se la lista è pubblicata
(adapters/leganto.py); se la lista del 2026/27 non c'è ancora si usa quella degli anni precedenti
(adapters/univr_testi.py). Le attività TAF D (a scelta dello studente) hanno `obbligatorio: false`.

Corsi con più ordinamenti: la pagina del corso nuovo («R», immatricolati dal 2026/27 o dal 2025/26) ha
solo gli anni attivati dal nuovo piano; gli anni successivi sono nella pagina del corso «Immatricolazione
fino a …» (link nell'avviso arancione del piano didattico): si leggono anche quelle e si uniscono per
anno e codice (insegnamenti erogati nel 2026/27 per le coorti precedenti).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import itertools
import json
import pathlib
import re
import threading
import time
from html.parser import HTMLParser

from . import leganto, univr_testi
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.corsi.univr.it"
XHR = {"X-Requested-With": "XMLHttpRequest"}
# Corsi dello stesso corso di laurea con ordinamento precedente (pagine «Laurea in … - Immatricolazione fino a …»,
# per gli studenti già iscritti), per id del corso attuale. Il corso attuale cita quelli che hanno un avviso nel piano
# (`corsi_precedenti`); per gli altri è la pagina vecchia a rimandare a quella nuova, quindi sono elencati qui
# (trovati leggendo gli avvisi delle pagine www.corsi.univr.it/?ent=cs&id=<n>).
# Attività erogate che non sono insegnamenti del piano: gli obblighi formativi aggiuntivi («Conoscenze per l'accesso:
# biologia», senza crediti) e i crediti liberi, già nel piano come «Attività a scelta dello studente»
NON_INSEGNAMENTO = re.compile(r"(?i)^(conoscenze per l.accesso|attivit.{1,2}\s+(formative\s+)?a scelta)")
PRECEDENTI: dict[str, list[str]] = {
    "1290": ["950"], "1291": ["1173"], "1292": ["698"], "1293": ["418"], "1301": ["948"], "1302": ["951"],
    "1303": ["949"], "1306": ["902"], "1307": ["952"], "1308": ["953"], "1309": ["998"], "1310": ["1126"],
    "1311": ["1000"], "1312": ["691"], "1313": ["999"], "1318": ["697"], "1321": ["1042"], "1324": ["904"],
    "1326": ["1048"], "1330": ["861"], "1331": ["1041"], "1333": ["490"], "1334": ["696"], "1335": ["860"],
    "1336": ["1045"], "1337": ["1127"], "1340": ["1129"], "1342": ["493"], "1343": ["538"], "1347": ["419"],
    "1348": ["420"], "1349": ["1001"], "1351": ["417"], "1353": ["769"], "1354": ["907"], "1355": ["1046"],
    "1362": ["523"], "1416": ["477"], "1417": ["479"], "1418": ["478"], "1419": ["602"], "1420": ["482"],
    "1421": ["471"], "1422": ["475"], "1423": ["473"], "1424": ["474"], "1425": ["472"], "1426": ["469"],
    "1427": ["862"], "1430": ["563"],
}


def _id(url: str | None) -> str | None:
    m = re.search(r"(?:corsi|medicina)\.univr\.it/\?ent=cs&id=(\d+)", url or "")
    return m.group(1) if m else None


def _date(s: str) -> str | None:
    m = re.match(r"(\d\d)/(\d\d)/(\d\d)$", s)
    return f"{m.group(1)}/{m.group(2)}/20{m.group(3)}" if m else None


def _periodo(titolo: str) -> str | None:
    t = titolo.lower()
    if "non assegnato" in t:
        return None
    if "annual" in t or ("1°" in t and "2°" in t):
        return "annuale"
    m = re.match(r"\s*(\d)\s*(?:°\s*)?(semestre|trimestre|quadrimestre|ciclo|periodo)", t)
    return m.group(1) if m else (re.sub(r"\s+Dal\s.*$", "", titolo).strip() or None)


def leggi_erogata(s: str) -> list[dict]:
    out = []
    for titolo, corpo in re.findall(r"<caption>(.*?)</caption>(.*?)</table>", s, re.S):
        t = _testo(titolo)
        date = re.search(r"Dal\s+(\d\d/\d\d/\d\d)\s+Al\s+(\d\d/\d\d/\d\d)", t)
        for tr in re.findall(r"<tr>(.*?)</tr>", corpo, re.S):
            td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(td) < 6:
                continue
            link = re.search(r'href="([^"]*codins=([^&"]+)[^"]*)"', td[1])
            anno = re.match(r"\s*(\d)", _testo(td[0]))
            docenti = [] if "non ancora assegnato" in _testo(td[5]).lower() else [
                _testo(re.sub(r"\(.*?\)", "", x)) for x in re.split(r"<br\s*/?>|</a>|</div>", td[5])]
            ssd = [_testo(x) for x in re.findall(r"<span[^>]*>(.*?)</span>", td[3], re.S)]
            out.append({
                "anno": int(anno.group(1)) if anno else None, "nome": _testo(td[1]),
                "codice": html.unescape(link.group(2)) if link else None,
                "url": BASE + "/" + html.unescape(link.group(1)).lstrip("/") if link else None,
                "taf": _testo(td[2]) or None,
                "ssd": next((x for x in reversed(ssd) if re.match(r"[A-Z]{4}-\d", x)), ssd[-1] if ssd else None),
                "docenti": sorted({d for d in docenti if d}),
                "periodo": _periodo(t), "inizio": _date(date.group(1)) if date else None,
                "fine": _date(date.group(2)) if date else None,
            })
    return out


def crediti(s: str) -> float | int | None:
    m = re.search(r"Crediti\s*</[^>]+>\s*<[^>]+>\s*([\d.,]+)", s) or re.search(r"Crediti\s*\|?\s*([\d.,]+)", _testo(s))
    if not m:
        return None
    v = float(m.group(1).replace(",", "."))
    return int(v) if v.is_integer() else v


# ---------------------------------------------------------------------------------------------------------------------
# Piano didattico (pagina `tab=Insegnamenti`): elenco ufficiale per coorte, con tutti gli anni del corso
# ---------------------------------------------------------------------------------------------------------------------
_VUOTI = {"br", "img", "input", "hr", "meta", "link", "path", "col", "area", "base", "source", "wbr"}


class _Nodo:
    __slots__ = ("tag", "a", "c", "p")

    def __init__(self, tag, attrs, p):
        self.tag, self.a, self.c, self.p = tag, dict(attrs), [], p

    def classi(self) -> list[str]:
        return (self.a.get("class") or "").split()

    def testo(self) -> str:
        return "".join(x if isinstance(x, str) else x.testo() for x in self.c)

    def cerca(self, pred):
        for x in self.c:
            if isinstance(x, _Nodo):
                if pred(x):
                    yield x
                yield from x.cerca(pred)

    def figli(self) -> list:
        return [x for x in self.c if isinstance(x, _Nodo)]


class _Albero(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.radice = _Nodo("root", [], None)
        self.cur = self.radice

    def handle_starttag(self, tag, attrs):
        n = _Nodo(tag, attrs, self.cur)
        self.cur.c.append(n)
        if tag not in _VUOTI:
            self.cur = n

    def handle_startendtag(self, tag, attrs):
        self.cur.c.append(_Nodo(tag, attrs, self.cur))

    def handle_endtag(self, tag):
        n = self.cur
        while n is not None and n.tag != tag:
            n = n.p
        if n is not None and n.p is not None:
            self.cur = n.p

    def handle_data(self, d):
        self.cur.c.append(d)


def _albero(s: str) -> _Nodo:
    a = _Albero()
    a.feed(s)
    return a.radice


def _pulito(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").replace("\xa0", " ")).strip()


def _numero(s: str) -> float | int | None:
    m = re.search(r"\d+(?:[.,]\d+)?", s or "")
    if not m:
        return None
    v = float(m.group(0).replace(",", "."))
    return int(v) if v.is_integer() else v


_GRUPPI = itertools.count(1)
_NUM_PAROLE = {"un": 1, "uno": 1, "una": 1, "one": 1, "due": 2, "two": 2, "tre": 3, "three": 3, "quattro": 4,
               "four": 4, "cinque": 5, "five": 5, "sei": 6, "six": 6}


def gruppo_da_didascalia(didascalia: str, membri: int) -> dict:
    """Didascalia di un blocco del piano → {"didascalia", "scelta", "n"}. «Un/2/Due insegnamenti a scelta»,
    «One module among the following», lingue, letterature, filologie e «Coppia N» sono scelte (si sostiene
    una parte dei membri); «Il Semestre Aperto si compone dei seguenti tre insegnamenti», «Percorso …»,
    «Tirocinio …», «Altre attività formative» sono insegnamenti da sostenere tutti. Se i membri non sono più
    di quelli da scegliere, si sostengono tutti."""
    cap = _pulito(didascalia)
    low = cap.lower()
    if "si compone" in low or "si compongono" in low or re.match(r"percorso\b", low):
        return {"id": next(_GRUPPI), "didascalia": cap, "scelta": False, "n": None}
    m = re.match(r"(\d+|un[oa]?|due|tre|quattro|cinque|sei|one|two|three|four|five|six)\s+(insegnament\w*|modul\w*)", low)
    n = None
    if m:
        n = int(m.group(1)) if m.group(1).isdigit() else _NUM_PAROLE.get(m.group(1))
    elif re.search(r"lingua|language|letteratur|literature|filologi|coppia|a scelta", low):
        n = 1
    if n is None or membri <= n:
        return {"id": next(_GRUPPI), "didascalia": cap, "scelta": False, "n": n}
    return {"id": next(_GRUPPI), "didascalia": cap, "scelta": True, "n": n}


def _riga_piano(div: _Nodo) -> dict | None:
    celle = div.figli()
    if len(celle) < 4:
        return None
    c0 = celle[0]
    link = next(iter(c0.cerca(lambda n: n.tag == "a" and "callIns" in n.classi())), None)
    etichetta = next(iter(c0.cerca(lambda n: n.tag == "p" and "labelDropdownIns" in n.classi())), None)
    if etichetta is not None:
        nome = _pulito(etichetta.testo())
    elif link is not None:
        nome = _pulito("".join(x if isinstance(x, str) else ("" if x.tag == "em" else x.testo()) for x in link.c))
    else:
        nome = _pulito(c0.testo())
    if not nome:
        return None
    href = html.unescape(link.a.get("href", "")) if link is not None else ""
    cod = re.search(r"codins=([^&]+)", href)
    ssd = [x.strip() for x in re.split(r"\s*,\s*", _pulito(celle[3].testo())) if x.strip() and x.strip() != "-"]
    return {"nome": nome, "codice": html.unescape(cod.group(1)) if cod else None,
            "cfu": _numero(celle[1].testo()), "taf": _pulito(celle[2].testo()) or None,
            "ssd": "; ".join(ssd) or None,
            "erogata": (link.a.get("data-tipo") == "Erogata") if link is not None else None,
            "href": href or None}


def _righe_piano(nodo: _Nodo, gruppo: dict | None = None) -> list[dict]:
    out: list[dict] = []
    for f in nodo.figli():
        cl = f.classi()
        if "rowTabella" in cl:
            r = _riga_piano(f)
            if r:
                r["gruppo"] = gruppo
                out.append(r)
        elif "tableSceltaIns" in cl:
            didascalia = next(iter(f.cerca(lambda n: "captionSceltaIns" in n.classi())), None)
            cap = didascalia.testo() if didascalia is not None else ""
            membri = _righe_piano(f)
            g = gruppo_da_didascalia(cap, len(membri))
            for r in membri:
                r["gruppo"] = r["gruppo"] or g
            out += membri
    return out


def leggi_piano(s: str) -> dict:
    """Pagina del piano didattico → {"aa", "aa_link", "curricula", "anni": {k: {"attivato", "righe"}},
    "tra_anni": [riga con "anni"]}. `attivato`: a.a. in cui l'anno «sarà attivato» (assente se già attivo);
    `tra_anni`: attività «Tra gli anni: 2°- 3°» (tirocinio, crediti a scelta)."""
    radice = _albero(s)
    aa_sel = next(iter(radice.cerca(lambda n: n.a.get("id") == "dropdownMenuSelectAA")), None)
    m_aa = re.search(r"\d{4}/\d{4}", aa_sel.testo()) if aa_sel is not None else None
    aa_link: list[str] = []
    for a in radice.cerca(lambda n: n.tag == "a" and "dropdown-item" in n.classi()):
        m = re.search(r"[?&]aa=(\d{4}/\d{4})", html.unescape(a.a.get("href", "")))
        if m and m.group(1) not in aa_link:
            aa_link.append(m.group(1))
    curricula = []
    sel = next(iter(radice.cerca(lambda n: n.a.get("id") == "curriculumSelect")), None)
    if sel is not None:
        for o in sel.cerca(lambda n: n.tag == "option"):
            curricula.append({"id": o.a.get("value"), "nome": _pulito(o.testo()), "scelto": "selected" in o.a})
    anni: dict[int, dict] = {}
    for b in radice.cerca(lambda n: "separatoreAnni" in n.classi()):
        p = next(iter(b.cerca(lambda n: n.tag == "p")), None)
        titolo = _pulito(p.testo()) if p is not None else ""
        m = re.match(r"(\d)\s*°?\s*Anno", titolo)
        if not m:
            continue
        att = re.search(r"[Ss]ar[àa] attivato nell'A\.A\.\s*(\d{4}/\d{4})", titolo)
        anni[int(m.group(1))] = {"attivato": att.group(1) if att else None, "righe": _righe_piano(b)}
    if not anni:  # senza la scheda «Tutti»: una scheda per anno
        for k in range(1, 8):
            pane = next(iter(radice.cerca(lambda n, k=k: n.a.get("id") == f"card-annotab{k}")), None)
            if pane is not None:
                anni[k] = {"attivato": None, "righe": _righe_piano(pane)}
    tra: list[dict] = []
    for blocco in radice.cerca(lambda n: "tableSceltaIns" in n.classi()
                               and any("captionAnni" in x.classi() for x in n.figli())):
        did = next(x for x in blocco.figli() if "captionAnni" in x.classi()).testo()
        a_ = [int(x) for x in re.findall(r"(\d)\s*°", did)] or [int(x) for x in re.findall(r"\b(\d)\b", did)]
        interna = next(iter(blocco.cerca(lambda n: "captionSceltaIns" in n.classi() and "captionAnni" not in n.classi())),
                       None)
        membri = _righe_piano(blocco)
        g = gruppo_da_didascalia(interna.testo().split(chr(10))[0], len(membri)) if interna is not None else None
        for r in membri:
            r["anni"] = a_
            r["gruppo"] = g
            tra.append(r)
    return {"aa": m_aa.group(0) if m_aa else None, "aa_link": aa_link, "curricula": curricula, "anni": anni,
            "tra_anni": tra}


class Portale(Client):
    """Client del portale: le pagine dei piani didattici vanno chieste senza l'intestazione XHR
    (con XHR rispondono con un errore), le liste degli insegnamenti con."""

    def get(self, url: str, xhr: bool = True):
        if xhr:
            return super().get(url)
        saved = self.s.headers.pop("X-Requested-With", None)
        try:
            return super().get(url)
        finally:
            if saved:
                self.s.headers["X-Requested-With"] = saved


def corsi_precedenti(pagina: str, propri: set[str]) -> list[str]:
    """Id dei corsi «Immatricolazione fino a …» citati nell'avviso arancione del piano didattico."""
    m = re.search(r"#ffa500.*?</div>", pagina or "", re.S)
    ids = re.findall(r'href="/\?ent=cs&(?:amp;)?id=(\d+)&(?:amp;)?menu=studiare&(?:amp;)?tab=Insegnamenti"',
                     m.group(0) if m else "")
    return [i for i in dict.fromkeys(ids) if i not in propri]


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def riuso_dal_database(uid: str = "univr") -> dict:
    """{(id corso, codice o nome normalizzato): {"docenti", "libri", "stato_libri"}} dalle righe già nel database:
    per gli insegnamenti già raccolti non si rileggono i dettagli né le liste Leganto."""
    p = ROOT / "database" / "corsi" / f"{uid}.json"
    if not p.exists():
        return {}
    out: dict = {}
    for c in json.loads(p.read_text(encoding="utf-8")).get("corsi", []):
        for i in c.get("insegnamenti") or []:
            k = (c["id"], i.get("codice") or _norm(i.get("nome")))
            if k not in out or (i.get("libri") and not out[k]["libri"]):
                out[k] = {"docenti": i.get("docenti") or [], "libri": i.get("libri") or [],
                          "stato_libri": i.get("stato_libri"), "cfu": i.get("cfu")}
    return out


def _nome_cu(nome: str) -> str:
    """Nome di un percorso senza virgole (il database separa i percorsi con le virgole)."""
    return _pulito(nome.replace(", ", " - ").replace(",", " -"))


def _nome_attivita(nome: str) -> str:
    """«Attività a scelta dello studente: insegnamenti con voto per complessivi 12 CFU, oppure …» → la parte
    prima dei due punti, se il resto è una spiegazione lunga."""
    if len(nome) > 70 and ":" in nome:
        return nome.split(":", 1)[0].strip()
    return nome


def cfu_piano(voci: list[dict]) -> dict:
    """CFU di un anno del piano (righe di `leggi_piano`): `cfu_fissi` (insegnamenti da sostenere tutti), `cfu_a_scelta`
    (crediti liberi di TAF D e, per ogni blocco «N insegnamenti a scelta», gli N più piccoli) e `cfu_totale`. I blocchi
    con gli stessi membri e la didascalia «mutually exclusive with the previous ones» si contano una volta."""
    fissi = libere = scelte = 0.0
    gruppi: dict[int, list] = {}
    for r in voci:
        c = r["cfu"] or 0
        g = r["gruppo"]
        if g and g["scelta"]:
            gruppi.setdefault(g["id"], []).append((c, g["n"] or 1, r["codice"] or _norm(r["nome"]), g["didascalia"]))
        elif r["taf"] == "D":
            libere += c
        else:
            fissi += c
    viste = set()
    for membri in gruppi.values():
        chiave = frozenset(m[2] for m in membri)
        if chiave in viste and re.search(r"(?i)mutually exclusive|mutuamente esclusiv|alternativ", membri[0][3]):
            continue
        viste.add(chiave)
        scelte += sum(sorted(m[0] for m in membri)[:membri[0][1]])

    def num(v: float) -> float | int:
        return int(v) if float(v).is_integer() else v

    return {"cfu_fissi": num(fissi), "cfu_a_scelta": num(libere + scelte), "cfu_totale": num(fissi + libere + scelte)}


def anno_attivita(r: dict, anni_pagina: list[int], erogate: dict) -> int | None:
    """Anno in cui mettere un'attività «Tra gli anni: 1°- 2°» di una pagina del piano che vale per gli anni
    `anni_pagina`: quello dell'intervallo in cui l'insegnamento (se ha il codice) è erogato, altrimenti l'ultimo anno
    dell'intervallo servito dalla pagina (tirocinio e crediti a scelta). Le coorti non si mescolano: gli anni serviti
    da un'altra pagina non contano."""
    cand = sorted(j for j in anni_pagina if j in (r.get("anni") or []))
    if not cand:
        return None
    dove = [j for j in cand if r.get("codice") and (j, r["codice"]) in erogate]
    return dove[0] if dove else cand[-1]


def scegli_pagine(candidati: list[tuple[str, str]], principale: str, anno: int, durata: int,
                  ha_anno) -> dict[int, tuple[tuple[str, str], bool]]:
    """Per ogni anno di corso k, la pagina del piano da usare: la coorte che nel 2026/27 frequenta quell'anno
    (immatricolati nel `anno - k + 1`), nel corso principale o in uno dei corsi «Immatricolazione fino a …». Senza
    quella coorte, la più vicina (a parità, la più recente): il secondo valore è False (anno dedotto)."""
    out = {}
    for k in range(1, durata + 1):
        coorte = anno - k + 1
        for x in sorted(candidati, key=lambda x: (abs(int(x[1][:4]) - coorte), -int(x[1][:4]), x[0] != principale)):
            if ha_anno(x, k):
                out[k] = (x, int(x[1][:4]) == coorte)
                break
    return out


def fetch_ateneo(uid: str = "univr", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print, riuso: dict | None = None) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py).

    Il piano di ogni anno è quello ufficiale della coorte che nel `anno`/`anno+1` frequenta quell'anno (pagina del
    piano didattico per a.a. di immatricolazione); docenti e periodi vengono dagli insegnamenti erogati.
    `riuso`: {(id corso, codice): {"docenti", "libri", "stato_libri"}} di una raccolta precedente (di default, il
    database); per gli insegnamenti già presenti non si rileggono dettagli e liste Leganto."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    aa = f"{anno}/{anno + 1}"
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    if riuso is None:
        riuso = riuso_dal_database(uid)
    log(f"[{uid}] {len(corsi)} corsi sul portale www.corsi.univr.it; righe da riusare: {len(riuso)}")
    c = Portale(rate=2.0)  # al massimo 2 richieste al secondo
    c.s.headers.update(XHR)
    oggi = time.strftime("%Y-%m-%d")
    propri = {_id(x["url"]) for x in corsi}
    memo: dict[str, dict | None] = {}
    lock = threading.Lock()

    def piano(cid: str, aa_: str | None = None, cu: str | None = None) -> dict | None:
        url = f"{BASE}/?ent=cs&id={cid}&menu=studiare&tab=Insegnamenti" + (f"&aa={aa_}" if aa_ else "") + \
              (f"&cu={cu}" if cu else "") + "&lang=it"
        with lock:
            if url in memo:
                return memo[url]
        r = None
        for tentativo in range(3):  # il portale a volte non risponde: si riprova prima di dare la pagina per assente
            r = c.get(url, xhr=False)
            if r:
                break
            time.sleep(4 * (tentativo + 1))
        p = None
        if r:
            p = leggi_piano(r.text)
            p["url"] = url
            p["precedenti"] = corsi_precedenti(r.text, propri)
        with lock:
            memo[url] = p
        return p

    erog_memo: dict[str, dict] = {}

    def erogate(cid: str) -> dict[tuple, dict]:
        with lock:
            if cid in erog_memo:
                return erog_memo[cid]
        fonte = f"{BASE}/?ent=cs&id={cid}&menu=studiare&tab=insegnamenti&erogata=1&aa={aa}&lang=it"
        r = None
        for tentativo in range(3):
            r = c.get(fonte)
            if r:
                break
            time.sleep(4 * (tentativo + 1))
        righe: dict[tuple, dict] = {}
        for x in leggi_erogata(r.text) if r else []:
            if not x["anno"] or not x["codice"]:
                continue
            k = (x["anno"], x["codice"])
            if k in righe:
                righe[k]["docenti"] = sorted(set(righe[k]["docenti"]) | set(x["docenti"]))
                continue
            righe[k] = dict(x, fonte=fonte)
        with lock:
            erog_memo[cid] = righe
        return righe

    def pagine_del_corso(corso: dict) -> tuple[list[tuple[str, str]], str, dict]:
        """Corso principale + corsi precedenti (avviso del piano e tabella PRECEDENTI): le coppie (id, a.a.)
        con un piano didattico."""
        cid = _id(corso["url"])
        base = piano(cid)
        ids = [cid] + [i for i in dict.fromkeys((base["precedenti"] if base else []) + PRECEDENTI.get(cid, []))
                       if i != cid]
        cand: list[tuple[str, str]] = []
        for pid in ids:
            p = base if pid == cid else piano(pid)
            if not p:
                continue
            for a in dict.fromkeys(p["aa_link"] + ([p["aa"]] if p["anni"] and p["aa"] else [])):
                cand.append((pid, a))
        return cand, cid, {"ids": ids}

    def pagina(pid: str, a: str, cu: str | None = None) -> dict | None:
        """Piano di (corso, a.a.): la pagina senza `aa` è quella dell'a.a. corrente."""
        return piano(pid, None if a == aa else a, cu)

    def build(corso: dict) -> dict | None:
        cand, cid, info = pagine_del_corso(corso)
        if not cand:
            return None
        durata = corso.get("durata_anni") or 3
        base = piano(cid)

        def ha_anno(x, k):
            p = pagina(x[0], x[1])
            return bool(p and p["anni"].get(k, {}).get("righe"))

        scelte = scegli_pagine(cand, cid, anno, durata, ha_anno)
        righe: list[dict] = []
        curricula_corso: list[str] = []
        fuori_piano: list[str] = []
        erog_tutte: dict[tuple, dict] = {}
        for pid2 in info["ids"]:
            for kk, v in erogate(pid2).items():
                erog_tutte.setdefault(kk, v)
        usati: set[tuple] = set()
        dedotti: list[int] = []
        serve: dict[tuple, list[int]] = {}  # (id, a.a.) -> anni di corso per cui si usa quella pagina
        for k, (x, _) in scelte.items():
            serve.setdefault(x, []).append(k)
        per_cu: dict[str, dict[int, list[dict]]] = {}  # percorso ("" se unico) -> anno -> righe del piano
        cu_anno: dict[int, set[str]] = {}
        tot_piano: dict[tuple, float] = {}  # (percorso, anno) -> CFU dell'intero piano della coorte di quella pagina
        coorti: dict[int, tuple[str, str, str]] = {}  # anno -> (a.a. della coorte, pagina, percorso)
        for k, ((pid, a), esatto) in sorted(scelte.items()):
            if not esatto:
                dedotti.append(k)
            p0 = pagina(pid, a)
            curr = p0["curricula"] if p0 else []
            if len(curr) > 1:
                for x in curr:
                    if _nome_cu(x["nome"]) not in curricula_corso:
                        curricula_corso.append(_nome_cu(x["nome"]))
                cu_anno[k] = {_nome_cu(x["nome"]) for x in curr}
            for x in (curr or [None]):
                pc = p0 if (x is None or x["scelto"]) else pagina(pid, a, x["id"])
                if not pc:
                    continue
                nome_cu = _nome_cu(x["nome"]) if x and len(curr) > 1 else ""
                voci = [dict(r, _tra=False, _fonte=pc["url"]) for r in pc["anni"].get(k, {}).get("righe") or []]
                voci += [dict(r, _tra=True, _fonte=pc["url"]) for r in pc["tra_anni"]
                         if anno_attivita(r, serve[(pid, a)], erog_tutte) == k]
                per_cu.setdefault(nome_cu, {})[k] = voci
                coorti.setdefault(k, (a, pc["url"], nome_cu))
                tot_piano[(nome_cu, k)] = (
                    sum(cfu_piano(v["righe"])["cfu_totale"] for v in pc["anni"].values())
                    + cfu_piano(pc["tra_anni"])["cfu_totale"])
        # CFU del piano per anno e percorso (insegnamenti fissi, crediti a scelta, scelte da sostenere), per il percorso
        # con più CFU: serve a controllare gli anni con pochi insegnamenti obbligatori
        piano_anni: dict[str, dict] = {}
        for nome_cu, anni_cu in per_cu.items():
            for k, voci in anni_cu.items():
                st = cfu_piano(voci)
                if str(k) not in piano_anni or st["cfu_totale"] > piano_anni[str(k)]["cfu_totale"]:
                    piano_anni[str(k)] = dict(st, cfu_piano_coorte=tot_piano.get((nome_cu, k)), coorte=coorti[k][0],
                                              pagina=coorti[k][1], percorso=nome_cu or None, dedotto=k in dedotti)
        raccolte: dict[int, dict[str, dict]] = {}
        for nome_cu, anni_cu in per_cu.items():
            for k, voci in anni_cu.items():
                for r in voci:
                    chiave = r["codice"] or _norm(r["nome"])
                    cur = raccolte.setdefault(k, {}).get(chiave)
                    if cur is None:
                        raccolte[k][chiave] = cur = dict(r, _cu=set(), _fonti=r["_fonte"])
                    cur["_cu"].add(nome_cu)
                    if not (r["gruppo"] and r["gruppo"]["scelta"]) and (cur["gruppo"] and cur["gruppo"]["scelta"]):
                        cur["gruppo"] = r["gruppo"]  # obbligatorio in un percorso: lo è
        for k in sorted(raccolte):
            tutti_cu = cu_anno.get(k, set())
            for r in raccolte[k].values():
                e = erog_tutte.get((k, r["codice"])) if r["codice"] else None
                codice = r["codice"]
                if not codice:  # senza link nel piano (es. «Tirocinio»): l'insegnamento erogato con lo stesso nome
                    anni_r = r.get("anni") or [k]
                    cand_e = [(kk, v) for kk, v in erog_tutte.items() if kk[0] in anni_r and kk not in usati
                              and _norm(v["nome"]) == _norm(r["nome"])]
                    if len(cand_e) == 1:
                        (_, codice), e = cand_e[0]
                        usati.add(cand_e[0][0])
                elif e:
                    usati.add((k, codice))
                scelta = bool(r["gruppo"] and r["gruppo"]["scelta"]) or r["taf"] == "D"
                cus = {x for x in r["_cu"] if x}
                cu_riga = None if (not cus or (tutti_cu and cus >= tutti_cu)) else ", ".join(sorted(cus))
                href = r["href"]
                righe.append({
                    "codice": codice, "nome": _nome_attivita(r["nome"]), "anno": k,
                    "periodo": e["periodo"] if e else None, "periodo_inizio": e["inizio"] if e else None,
                    "periodo_fine": e["fine"] if e else None, "cfu": r["cfu"], "ssd": r["ssd"] or (e["ssd"] if e else None),
                    "obbligatorio": False if scelta else True, "curriculum": cu_riga,
                    "docenti": list(e["docenti"]) if e else [],
                    "url": (e["url"] if e and e.get("url") else (BASE + "/" + href.lstrip("/") if href else None)),
                    "libri": [], "esami": [], "fonte": r["_fonti"], "verificato_il": oggi,
                    "_erogato": bool(e),
                })
        # insegnamenti a scelta offerti (TAF D) che il piano non elenca (ci sono solo i «crediti a scelta»): righe a
        # scelta, con i crediti dal dettaglio; gli altri insegnamenti erogati fuori dal piano (altre coorti) no
        for (k, cod), e in sorted(erog_tutte.items()):
            if (k, cod) in usati or k > durata:
                continue
            if e["taf"] == "D" and not NON_INSEGNAMENTO.match(e["nome"]):
                righe.append({
                    "codice": cod, "nome": e["nome"], "anno": k, "periodo": e["periodo"], "periodo_inizio": e["inizio"],
                    "periodo_fine": e["fine"], "cfu": None, "ssd": e["ssd"], "obbligatorio": False, "curriculum": None,
                    "docenti": list(e["docenti"]), "url": e["url"], "libri": [], "esami": [], "fonte": e["fonte"],
                    "verificato_il": oggi, "_erogato": True,
                })
            else:
                fuori_piano.append(f"{k}:{cod} {e['nome']} ({e['taf']})")
        if not righe:
            return None
        # voci senza codice in anni diversi con lo stesso nome (es. «Tirocinio»): nomi distinti per anno;
        # più voci senza codice con lo stesso nome nello stesso anno: numerate
        per_nome: dict[str, list[dict]] = {}
        for i in righe:
            if not i["codice"]:
                per_nome.setdefault(_norm(i["nome"]), []).append(i)
        for voci in per_nome.values():
            if len({i["anno"] for i in voci}) > 1:
                for i in voci:
                    i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
            n = {}
            for i in voci:
                n.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
            for gruppo in n.values():
                if len(gruppo) > 1:
                    for j, i in enumerate(gruppo, 1):
                        i["nome"] = f"{i['nome']} {j}"
        for i in righe:
            v = riuso.get((corso["id"], i["codice"] or _norm(i["nome"])))
            if v:
                i["_riusato"] = True
                if i["cfu"] is None:
                    i["cfu"] = v.get("cfu")
                if not i["docenti"]:
                    i["docenti"] = list(v["docenti"])
                i["libri"] = [dict(b) for b in v["libri"]]
                i["stato_libri"] = v.get("stato_libri") or ("completo" if i["libri"] else "da_aggiungere")
        info_log = f"{len(righe)} righe, erogate {sum(1 for i in righe if i['_erogato'])}, fuori piano {len(fuori_piano)}"
        if dedotti:
            info_log += f", anni da coorte vicina: {dedotti}"
        if fuori_piano:
            info_log += f"; fuori piano: {fuori_piano[:6]}"
        log(f"[{uid}]   {corso['id'][:60]}: {info_log}")
        piano_url = piano(cid)["url"] if base else None
        out = {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
               "durata_anni": corso.get("durata_anni"), "url": f"{BASE}/?ent=cs&id={cid}",
               "fonte": piano_url, "verificato_il": oggi, "insegnamenti": righe}
        if curricula_corso:
            out["curricula"] = curricula_corso
        out["piano_anni"] = piano_anni
        return out

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            import traceback
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}\n{traceback.format_exc()}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    jobs: dict[str, list[dict]] = {}
    sede_di: dict[int, str | None] = {}
    for corso in out:
        m = re.search(r"(?i)replica\s+(\w+)", corso["nome"])
        for i in corso["insegnamenti"]:
            sede_di[id(i)] = m.group(1).upper() if m else None
            if i.get("url") and (not i.get("_riusato") or i["cfu"] is None):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"dettagli da leggere: {len(jobs) if syllabus else 0}")
    pagine: dict[str, str] = {}

    def dettaglio(url: str) -> None:
        try:
            r = c.get(url)
            if not r:
                return
            pagine[url] = r.text
            cfu = crediti(r.text)
            for it in jobs[url]:
                if it["cfu"] is None:
                    it["cfu"] = cfu
        except Exception:  # noqa: BLE001
            pass

    if syllabus:
        with cf.ThreadPoolExecutor(5) as ex:
            for n, _ in enumerate(ex.map(dettaglio, list(jobs)), 1):
                if n % 500 == 0:
                    log(f"[{uid}]   dettagli {n}/{len(jobs)}")
        libri_leganto(out, pagine, sede_di, log,
                      precedente=lambda u, a: (c.get(u.replace("aa=2026/2027", "aa=" + a)) or None))
    for corso in out:
        for i in corso["insegnamenti"]:
            i.pop("_erogato", None)
            i.pop("_riusato", None)
    log(f"[{uid}] libri (Leganto): {sum(len(i['libri']) for x in out for i in x['insegnamenti'])}; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.corsi.univr.it (adapters/univr.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def libri_leganto(out: list[dict], pagine: dict[str, str], sede_di: dict[int, str | None], log=print,
                  precedente=None) -> None:
    """Libri per ogni insegnamento: lista Leganto del suo corso (2026/27) o, se non pubblicata, la
    lista con lo stesso nome dell'anno più recente; vedi adapters/univr_testi.py."""
    T = univr_testi
    tutti = [i for x in out for i in x["insegnamenti"]]
    da_fare = [i for i in tutti if not i.get("_riusato")]  # gli altri hanno già i libri della raccolta precedente
    # codici Leganto citati dalle pagine, per codice di insegnamento (lo stesso insegnamento in più corsi)
    cod_leg: dict[str, set[str]] = {}
    chi_cita: dict[str, set[str]] = {}
    for i in tutti:
        lc = T.codice_dal_link(pagine.get(i.get("url") or "", ""))
        i["_leg"] = lc
        if lc:
            cod_leg.setdefault(i.get("codice") or i["nome"], set()).add(lc)
            chi_cita.setdefault(lc, set()).add(i.get("codice") or i["nome"])
    # insegnamenti distinti con lo stesso nome (codice e crediti diversi): il nome non basta per
    # scegliere la lista di un anno precedente
    gruppi: dict[str, set] = {}
    for i in tutti:
        gruppi.setdefault(T.norm(T.nome_base(i["nome"])), set()).add((i.get("codice"), i.get("cfu")))
    ambigui = {k for k, v in gruppi.items() if len({f for _, f in v}) > 1 or len({c for c, _ in v}) > 2}
    esito: dict[tuple, tuple] = {}

    def trova(i: dict):
        nome, sede = i["nome"], sede_di.get(id(i))
        libri: list[dict] = []
        ids: list[str] = []
        codici = [i["_leg"]] if i.get("_leg") else []
        codici += sorted(cod_leg.get(i.get("codice") or i["nome"], set()) - set(codici))
        for lc in codici:
            lb, li = T.libri_codice(lc)
            ids += li
            libri += [x for x in lb if x["citazione"] not in {y["citazione"] for y in libri}]
            if libri:
                return libri, "2026/2027", ",".join(ids)
        # bibliografia scritta come testo nella pagina del 2026/27
        libri = T.libri_testo(pagine.get(i.get("url") or "", ""))
        if libri:
            return libri, "2026/2027", None
        if T.norm(T.nome_base(nome)) not in ambigui:
            r = per_nome(i, nome, sede)
            if r[0]:
                return r
        # pagina dell'insegnamento degli anni precedenti: lista Leganto del suo corso o testo
        if precedente and i.get("url") and "aa=2026/2027" in i["url"]:
            for a in ("2025/2026", "2024/2025"):
                r = precedente(i["url"], a)
                t = getattr(r, "text", None) if r else None
                if not t or "Codice insegnamento" not in t:
                    continue
                lc = T.codice_dal_link(t)
                libri, ids = T.libri_codice(lc) if lc else ([], [])
                if libri:
                    return libri, a, ",".join(ids)
                libri = T.libri_testo(t)
                if libri:
                    return libri, a, None
        return [], None, None

    def per_nome(i: dict, nome: str, sede: str | None):
        libri: list[dict] = []
        for a in T.ANNI:
            liste = T.cerca(nome, a)
            if a == T.ANNI[0]:  # 2026/27: le liste di un corso che la pagina di un altro insegnamento già cita non sono sue
                liste = [x for x in liste if not (chi_cita.get(x["ccode"]) and
                                                 (i.get("codice") or i["nome"]) not in chi_cita[x["ccode"]])]
            if not liste:
                continue
            pref = [x for x in liste if x["sede"] == (sede or "VERONA")] or [x for x in liste if x["sede"] == "VERONA"] or liste
            for l in pref:
                libri += [x for x in T.libri_lista(l["id"]) if x["citazione"] not in {y["citazione"] for y in libri}]
            if libri:
                return libri, a, ",".join(l["id"] for l in pref)
        return [], None, None

    def lavora(i: dict) -> None:
        chiave = (i.get("codice") or i["nome"], sede_di.get(id(i)), i.get("_leg"))
        if chiave not in esito:
            try:
                esito[chiave] = trova(i)
            except Exception as e:  # noqa: BLE001
                log(f"[univr]   libri di {i['nome']!r}: {e!r}")
                esito[chiave] = ([], None, None)
        libri, aa_lista, _ = esito[chiave]
        i["libri"] = [dict(b) for b in libri]
        if aa_lista and aa_lista != "2026/2027":
            nota = (f"Dalla bibliografia dell'a.a. {aa_lista.replace('/20', '/')} (Leganto o programma): quella del "
                    f"2026/27 non è ancora pubblicata")
            for b in i["libri"]:
                b["note"] = f"{nota}; {b['note']}" if b.get("note") else nota
        i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"

    with cf.ThreadPoolExecutor(4) as ex:
        for n, _ in enumerate(ex.map(lavora, da_fare), 1):
            if n % 250 == 0:
                log(f"[univr]   libri {n}/{len(da_fare)}")
    for i in tutti:
        i.pop("_leg", None)
