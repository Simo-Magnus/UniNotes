"""Insegnamenti, docenti e libri dell'Università di Urbino Carlo Bo da www.uniurb.it.

Esse3 di Uniurb non pubblica l'offerta; il portale sì:

- `/corsi/<id>/insegnamenti-e-programmi` → insegnamenti erogati nell'a.a. corrente (tutti gli anni, anche
  di coorti diverse): nome (link a `/insegnamenti-e-programmi/<id>`), docente, curriculum, SSD, anno, CFU
  della lezione (non sempre quelli del piano: moduli mancanti, laboratori);
- scheda dell'insegnamento → periodo e "Testi di studio";
- `/it/off/bandi/piano-degli-studi_<id>.pdf` → piano di studi ufficiale della coorte dell'a.a. (tutti gli anni,
  percorsi, gruppi a scelta, CFU liberi). I PDF sono impaginati a colonne e ogni corso ha un formato proprio:
  sono trascritti in `uniurb_piani.txt` (sintassi nell'intestazione del file), che è la fonte di anni, CFU e
  obbligatorietà per i corsi che lo contengono («piano»); il portale dà docenti, scheda e libri, abbinati
  per nome. Per i corsi con insegnamenti «a slot» (Lingue moderne applicate: «Lingua A I», «Lingua B I»…)
  si tengono le righe del portale e il piano aggiunge solo gli anni non ancora erogati («integra»).

Le righe del portale a 0 CFU (esercitazioni, laboratori senza crediti) non si inseriscono.
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.uniurb.it"
PIANI = pathlib.Path(__file__).with_name("uniurb_piani.txt")
SEMESTRI = {"I": "1", "II": "2", "I-II": "annuale", "II-I": "annuale"}


def _id(url: str | None) -> str | None:
    m = re.search(r"uniurb\.it/corsi/(\d+)", url or "")
    return m.group(1) if m else None


def leggi_elenco(s: str) -> list[dict]:
    out = []
    for tr in re.findall(r'<tr valign="middle">(.*?)</tr>', s, re.S):
        td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if len(td) < 6:
            continue
        link = re.search(r'href="(/insegnamenti-e-programmi/(\d+))"[^>]*>\s*<strong>(.*?)</strong>', td[0], re.S)
        if not link:
            continue
        anno = re.match(r"\s*(\d)", _testo(td[4]))
        v = _testo(td[5]).replace(",", ".")
        cfu = float(v) if re.fullmatch(r"\d+(\.\d+)?", v) else None
        curr = _testo(td[2])
        out.append({
            "id": link.group(2), "url": BASE + link.group(1), "nome": _titolo(_testo(link.group(3))),
            "docenti": [_testo(x) for x in re.findall(r"<a [^>]*>(.*?)</a>", td[1], re.S) if _testo(x)],
            "curriculum": None if re.search(r"(?i)percorso comune|comune", curr) and len(curr) < 40 else (curr.title() or None),
            "ssd": _testo(td[3]) or None, "anno": int(anno.group(1)) if anno else None,
            "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
        })
    return out


def leggi_scheda(s: str) -> dict:
    testi = re.search(r"<dt>\s*Testi di studio\s*</dt>\s*<dd>(.*?)</dd>", s, re.S)
    per = re.search(r'<td class="text-uppercase hidden-xs hidden-sm">\s*((?:Primo|Secondo|Terzo)\s+\w+|Annual\w*)\s*</td>',
                    s, re.I)
    p = per.group(1).lower() if per else ""
    periodo = "annuale" if p.startswith("annual") else {"primo": "1", "secondo": "2", "terzo": "3"}.get(
        p.split(" ")[0]) if p else None
    return {"libri": estrai_libri(testi.group(1)) if testi else [], "periodo": periodo}


# ---------------------------------------------------------------- piani di studio (PDF trascritti)

_PICCOLE = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al",
            "alla", "il", "la", "lo", "le", "gli", "i", "nel", "nella", "sul", "tra", "fra", "su", "o", "oppure",
            "and", "of", "the", "for", "to", "or", "from", "in", "on", "a", "an"}


def _titolo_piano(nome: str) -> str:
    """Iniziali maiuscole come nelle righe del portale («Chimica Generale ed Inorganica»): si cambiano solo le
    parole tutte minuscole (non le parole piccole, né quelle tra parentesi); sigle e numeri romani restano."""
    out = []
    aperte = 0
    for k, w in enumerate(nome.split(" ")):
        m = re.match(r"^(\W*)(.*?)(\W*)$", w)
        pre, core, post = m.groups()
        aperte += pre.count("(")
        if not core or core != core.lower() or aperte or (k and core in _PICCOLE):
            out.append(w)
        else:
            out.append(pre + core[:1].upper() + core[1:] + post)
        aperte = max(0, aperte - w.count(")"))
    return " ".join(out)


def leggi_piani(testo: str) -> dict[str, dict]:
    """Legge `uniurb_piani.txt`: {id corso: {pdf, modo, anni, righe, totali, curricula}}."""
    piani: dict[str, dict] = {}
    p = None
    curr = anno = grp = None
    ngrp = 0

    def riga(nome, ssd, cfu, sem, obbl, kind, gruppo=None):
        p["righe"].append({"anno": anno, "curriculum": curr, "nome": nome, "ssd": ssd or None, "cfu": cfu,
                           "periodo": SEMESTRI.get(sem) if sem else None, "obbligatorio": obbl, "kind": kind,
                           "gruppo": gruppo})

    for n, r in enumerate(testo.splitlines(), 1):
        r = r.strip()
        if not r or r.startswith("#"):
            continue
        try:
            if r.startswith("@"):
                k, _, v = r[1:].partition(" ")
                v = v.strip()
                if k == "corso":
                    p = piani[v] = {"pdf": None, "modo": "piano", "anni": set(), "righe": [], "totali": {},
                                    "curricula": [], "gruppi": {}, "alias": {}, "scelte": set()}
                    curr = anno = grp = None
                elif k == "pdf":
                    p["pdf"] = v
                elif k == "modo":
                    p["modo"] = v
                elif k == "anni":
                    p["anni"] = {int(x) for x in v.replace(",", " ").split()}
                elif k == "curriculum":
                    curr = None if v == "*" else v.replace(", ", " - ")
                    if curr and curr not in p["curricula"]:
                        p["curricula"].append(curr)
                    grp = None
                elif k == "anno":
                    anno, grp = int(v), None
                elif k == "totale":
                    p["totali"][(curr, anno)] = int(v)
                elif k == "scelte":
                    p["scelte"] = {int(x) for x in v.replace(",", " ").split()}
                elif k == "alias":
                    nome_p, _, resto = v.partition("=")
                    p["alias"][_n(nome_p)] = [_n(x) for x in resto.split(";") if x.strip()]
                else:
                    raise ValueError(f"direttiva sconosciuta @{k}")
                continue
            if r.startswith(">"):
                cfu, _, desc = r[1:].partition("|")
                ngrp += 1
                grp = {"id": ngrp, "cfu": int(cfu), "nome": desc.strip()}
                p["gruppi"][ngrp] = int(cfu)
                continue
            if r.startswith("="):
                parts = [x.strip() for x in r[1:].split("|")]
                riga(parts[0], None, int(parts[1]), None, False, "libera")
                grp = None
                continue
            if r.startswith("- "):
                parts = [x.strip() for x in r[2:].split("|")]
                cfu = int(parts[2]) if len(parts) > 2 and parts[2] else grp["cfu"]
                riga(parts[0], parts[1] if len(parts) > 1 else None, cfu, parts[3] if len(parts) > 3 else None,
                     False, "scelta", grp["id"])
                continue
            parts = [x.strip() for x in r.split("|")]
            riga(parts[0], parts[1], int(parts[2]), parts[3] if len(parts) > 3 else None, True, "obbligatorio")
            grp = None
        except Exception as e:  # noqa: BLE001
            raise ValueError(f"uniurb_piani.txt, riga {n}: {r!r}: {e}") from e
    return piani


def carica_piani() -> dict[str, dict]:
    try:
        return leggi_piani(PIANI.read_text(encoding="utf-8"))
    except OSError:
        return {}


# ---------------------------------------------------------------- abbinamento piano / portale

def _n(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _slug40(s: str) -> str:
    return _n(s).replace(" ", "-")[:40].strip("-")


_MODULO = re.compile(r"\b(modulo di|modulo|mod|unita didattica)\b")
_VUOTE = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al",
          "alla", "il", "la", "lo", "le", "gli", "nel", "nella", "sul", "tra", "fra", "su", "o", "and", "of", "the",
          "for", "to"}


def _chiavi(nome: str) -> dict:
    """Nome intero, parte prima e dopo « - » (contenitore e modulo), senza le parole «Modulo di»; «X I Modulo»
    e «X II Modulo» hanno X come contenitore."""
    nome = re.sub(r"(?i)\(?\s*\bi e ii modulo\b\s*\)?", " ", nome)
    pezzi = [x for x in re.split(r"\s+-\s+|:\s+", nome) if x.strip()]
    m = re.match(r"(?i)^(.*?)\s+(?:i|ii|iii|iv)\s+modulo$", nome.strip())
    full = " ".join(_MODULO.sub(" ", _n(nome)).split())
    testa = coda = None
    if len(pezzi) > 1:
        testa = " ".join(_MODULO.sub(" ", _n(pezzi[0])).split())
        coda = " ".join(_MODULO.sub(" ", _n(pezzi[-1])).split())
    elif m:
        testa, coda = _n(m.group(1)), full
    return {"full": full, "testa": testa, "coda": coda}


def _tok(s: str) -> set[str]:
    return {w for w in s.split() if w not in _VUOTE}


def _simili(a: str, b: str) -> bool:
    """Stesse parole significative (numeri e numeri romani compresi) e testo quasi uguale."""
    ta, tb = _tok(a), _tok(b)
    if not ta or not tb:
        return False
    return len(ta & tb) / len(ta | tb) >= 0.8 and difflib.SequenceMatcher(None, a, b).ratio() >= 0.85


def abbina(nome: str, items: list[dict], anno: int | None, alias: dict | None = None) -> list[dict]:
    """Righe del portale che corrispondono a una riga del piano: stesso nome (o stessa parte «modulo»), nome quasi
    uguale, tutti i moduli di un contenitore («Biologia cellulare e genetica» → i suoi due moduli) o i nomi
    indicati con `@alias`. Le copie dello stesso insegnamento (una per percorso) si prendono tutte."""
    k = _chiavi(nome)
    cand = [(it, _chiavi(it["nome"])) for it in items]

    def meglio(lst):
        stesso = [x for x in lst if x[0].get("anno") == anno]
        return [x[0] for x in (stesso or lst)]

    pref = (alias or {}).get(_n(nome))
    if pref:
        trovati = [c for c in cand if any(_n(c[0]["nome"]).startswith(p) for p in pref)]
        if trovati:
            return meglio(trovati)
    uguali = [c for c in cand if c[1]["full"] == k["full"]]
    if not uguali and anno:
        uguali = [c for c in cand if c[1]["full"] == f"{k['full']} {anno} anno"]
    if uguali:
        return meglio(uguali)
    if k["coda"]:
        mod = [c for c in cand if k["coda"] in (c[1]["full"], c[1]["coda"])
               and (k["testa"] is None or c[1]["testa"] in (None, k["testa"]) or _simili(k["testa"], c[1]["testa"] or ""))]
        if mod:
            return meglio(mod)
    cont = [c for c in cand if c[1]["testa"] and c[1]["testa"] == k["full"]]
    if cont:
        return meglio(cont) if len({c[0]["nome"] for c in cont}) == 1 else             [c[0] for c in cont if c[0].get("anno") == anno] or [c[0] for c in cont]
    simili = [c for c in cand if _simili(k["full"], c[1]["full"]) or
              (k["coda"] and c[1]["coda"] and _simili(k["coda"], c[1]["coda"]))]
    if simili:
        migliore = max(difflib.SequenceMatcher(None, k["full"], c[1]["full"]).ratio() for c in simili)
        return meglio([c for c in simili
                       if difflib.SequenceMatcher(None, k["full"], c[1]["full"]).ratio() == migliore])
    return []


def _unisci_curricula(cs: set, tutti: set) -> str | None:
    if None in cs or not cs or (tutti and cs >= tutti):
        return None
    return ", ".join(sorted(cs))


def _righe_piano(piano: dict, items: list[dict], anni: set | None, oggi: str, fonte: str,
                 mappa_curr: dict[str, str] | None = None) -> tuple[list[dict], list[str]]:
    """Righe (formato contributo) del piano. `items`: righe del portale per metadati. Restituisce anche i nomi
    del piano senza scheda."""
    mappa_curr = mappa_curr or {}
    tutti = {mappa_curr.get(c.lower(), c) for c in piano["curricula"]}
    grezze: dict[tuple, dict] = {}
    senza = []
    for x in piano["righe"]:
        if anni is not None and x["anno"] not in anni:
            continue
        nome = _titolo_piano(x["nome"])
        trovati = abbina(x["nome"], items, x["anno"], piano.get("alias")) if x["kind"] != "libera" and items else []
        if len(trovati) == 1 and x["kind"] != "libera":
            nome = trovati[0]["nome"]
        elif not trovati and x["kind"] == "obbligatorio" and items and x["cfu"] and x["cfu"] > 1:
            senza.append(f"{x['anno']}: {x['nome']}")
        curr = x["curriculum"]
        curr = mappa_curr.get(curr.lower(), curr) if curr else None
        key = (x["anno"], _n(nome), x["cfu"], x["obbligatorio"], x["gruppo"] is not None)
        r = grezze.get(key)
        if not r:
            r = grezze[key] = {
                "codice": None, "nome": nome, "anno": x["anno"], "periodo": x["periodo"], "cfu": x["cfu"],
                "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None, "docenti": [],
                "url": None, "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi, "_ids": [],
                "_curr": set()}
        r["_curr"].add(curr)
        for it in trovati:
            if it["url"] not in r["_ids"]:
                r["_ids"].append(it["url"])
            r["docenti"] = sorted(set(r["docenti"]) | set(it["docenti"]))
            r["url"] = r["url"] or it["url"]
            r["ssd"] = r["ssd"] or it["ssd"]
    righe = list(grezze.values())
    # moduli di uno stesso contenitore: l'id dell'insegnamento si ricava dai primi 40 caratteri del nome, quindi
    # «Contenitore - Modulo di X» e «Contenitore - Modulo di Y» sarebbero la stessa riga: il modulo passa davanti
    per_id: dict[tuple, list[dict]] = {}
    for r in righe:
        per_id.setdefault((r["anno"], _slug40(r["nome"])), []).append(r)
    for g in per_id.values():
        if len({_n(r["nome"]) for r in g}) > 1:
            for r in g:
                m = re.match(r"^(.*?)\s+-\s+(?:modulo(?:\s+di)?\s+)?(.+)$", r["nome"], re.I)
                if m:
                    r["nome"] = f"{m.group(2)[:1].upper()}{m.group(2)[1:]} ({m.group(1)})"
    # stesso insegnamento nello stesso anno con CFU diversi tra i percorsi: il nome porta i CFU
    per_nome: dict[tuple, list[dict]] = {}
    for r in righe:
        per_nome.setdefault((r["anno"], _slug40(r["nome"])), []).append(r)
    for g in per_nome.values():
        if len({r["cfu"] for r in g}) > 1:
            for r in g:
                r["nome"] = f"{r['nome']} ({r['cfu']:g} CFU)"
    for r in righe:
        r["curriculum"] = _unisci_curricula(r.pop("_curr"), tutti)
    return righe, senza


def _righe_portale(items: list[dict], url: str, oggi: str, anni_esclusi: set | None = None) -> tuple[list[dict], set]:
    righe: dict[str, dict] = {}
    curricula = set()
    for x in items:
        if not x["anno"] or x["cfu"] == 0 or (anni_esclusi and x["anno"] in anni_esclusi):
            continue
        if x["curriculum"]:
            curricula.add(x["curriculum"])
        key = f"{x['anno']}:{x['nome'].lower()}"
        item = righe.get(key)
        if not item:
            item = righe[key] = {
                "codice": None, "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                "ssd": x["ssd"], "obbligatorio": None, "curriculum": None, "docenti": [], "url": x["url"],
                "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "_ids": [], "_curr": set(),
            }
        item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
        item["_ids"].append(x["url"])
        item["_curr"].add(x["curriculum"])
    for i in righe.values():
        cs = i.pop("_curr")
        if None not in cs and cs != curricula:
            i["curriculum"] = ", ".join(sorted(cs))
    return list(righe.values()), curricula


def fetch_ateneo(uid: str = "uniurb", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    piani = carica_piani()
    corsi = [c for c in corsi if _id(c.get("url")) or c.get("id") in piani]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi su www.uniurb.it, {len(piani)} con il piano di studi ufficiale")
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        piano = piani.get(corso["id"])
        cid = _id(corso.get("url"))
        url = f"{BASE}/corsi/{cid}/insegnamenti-e-programmi" if cid else None
        items: list[dict] = []
        if url:
            r = c.get(url)
            if r:
                vistI = set()
                for x in leggi_elenco(r.text):
                    if x["id"] not in vistI:
                        vistI.add(x["id"])
                        items.append(x)
        fonte = (piano or {}).get("pdf") or url
        if piano and piano["modo"] == "piano":
            righe, senza = _righe_piano(piano, items, None, oggi, piano["pdf"])
            curricula = sorted({c2 for c2 in piano["curricula"]})
            usati = {u for r2 in righe for u in r2["_ids"]}
            # corsi a scelta: gli insegnamenti erogati che il piano non nomina, negli anni in cui ha crediti liberi
            visti = {(r2["anno"], _n(r2["nome"])) for r2 in righe}
            for it in items:
                k = (it["anno"], _n(it["nome"]))
                if it["anno"] in piano["scelte"] and it["url"] not in usati and k not in visti and it["cfu"]:
                    visti.add(k)
                    righe.append({
                        "codice": None, "nome": it["nome"], "anno": it["anno"], "periodo": None, "cfu": it["cfu"],
                        "ssd": it["ssd"], "obbligatorio": False, "curriculum": None, "docenti": list(it["docenti"]),
                        "url": it["url"], "libri": [], "esami": [], "fonte": url, "verificato_il": oggi,
                        "_ids": [it["url"]]})
            log(f"[{uid}]   {corso['id']}: piano {len(righe)} righe, portale {len(items)} (usate {len(usati)}); "
                f"senza scheda: {len(senza)}")
        elif piano and piano["modo"] == "integra":
            portale, curricula_p = _righe_portale(items, url, oggi, anni_esclusi=piano["anni"])
            mappa = {x.lower(): x for x in curricula_p}
            aggiunte, _ = _righe_piano(piano, items, piano["anni"], oggi, piano["pdf"], mappa)
            righe = portale + aggiunte
            curricula = sorted(curricula_p | {mappa.get(x.lower(), x) for x in piano["curricula"]})
        else:
            righe, cs = _righe_portale(items, url, oggi)
            curricula = sorted(cs)
        if not righe:
            return None
        for r2 in righe:
            r2.setdefault("_ids", [])
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": url.rsplit("/", 1)[0] if url else corso.get("url"),
                "curricula": curricula or None, "fonte": fonte, "verificato_il": oggi,
                "insegnamenti": righe}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    urls = sorted({u for x in out for i in x["insegnamenti"] for u in i["_ids"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(urls) if syllabus else 0}")
    dati: dict[str, dict] = {}

    def leggi(u: str) -> None:
        try:
            r = c.get(u)
            dati[u] = leggi_scheda(r.text) if r else {"libri": [], "periodo": None}
        except Exception:  # noqa: BLE001
            dati[u] = {"libri": [], "periodo": None}

    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, _ in enumerate(ex.map(leggi, urls), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(urls)}")
    trovati = 0
    for x in out:
        for it in x["insegnamenti"]:
            for u in it.pop("_ids"):
                d = dati.get(u) or {}
                it["periodo"] = it["periodo"] or d.get("periodo")
                viste = {re.sub(r"\W+", "", lb["citazione"].lower())[:120] for lb in it["libri"]}
                for lb in d.get("libri") or []:
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        it["libri"].append(lb)
            if syllabus:
                it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
            trovati += len(it["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uniurb.it, Insegnamenti e programmi e piani di studio "
            "(adapters/uniurb.py, uniurb_piani.txt)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
