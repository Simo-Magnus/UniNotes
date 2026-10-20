"""Insegnamenti, docenti e libri dell'Università del Salento da www.unisalento.it.

Esse3 di UniSalento non pubblica l'offerta; il portale sì:

- elenchi `…/cosa-studiare/corsi-di-laurea`, `…-magistrale`, `…-magistrale-a-ciclo-unico`
  → schede dei corsi (`…/dettaglio/corso/<codice>/<nome>`);
- scheda del corso → "N° anno - Per gli immatricolati nel AAAA / AAAA" (cioè gli
  insegnamenti erogati nell'a.a. corrente per ogni anno di corso), per percorso:
  nome (SSD), crediti, tipo di attività, "Obbligatorio/Non obbligatorio", codice Esse3;
- scheda dell'insegnamento → docente responsabile, "Testi di riferimento".

I corsi del database (da Universitaly) si associano per codice nell'URL o per nome.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import os
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unisalento.it"
DIP = "https://www.bbcc.unisalento.it"
ELENCHI = ["corsi-di-laurea", "corsi-di-laurea-magistrale", "corsi-di-laurea-magistrale-a-ciclo-unico"]


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


_INTESTAZIONE = re.compile(
    r'<button class="header[^"]*"[^>]*>\s*<span>\s*(\d)\s*(?:°|<sup>\w+</sup>)\s*(?:anno|year)\s*-\s*'
    r'(Per gli immatricolati nel|For matriculated students in)?\s*(\d{4})\s*/\s*\d{4}\s*</span>\s*</button>')
# settore scientifico-disciplinare in coda al nome: «(ING-INF/05)», «(INFO-01/A)», «(NN)», «(PROFIN_S)»; altre parentesi
# («(STAGE DA 1 CFU)», «(MOD. B)») fanno parte del nome
_SSD = re.compile(r"\s*\((NN|PROFIN_\w+|[A-Z][A-Z\-]*/\d{2}|[A-Z]{2,}-\d{2}/[A-Z])\)\s*$")
_TAB = re.compile(r'<div class="tab-pane[^"]*"\s+id="tabplan-[^"]*">\s*(?:<h3[^>]*>(.*?)</h3>)?', re.S)
_TIPI_NON_OBBLIGATORI = ("non obbligatorio", "optional", "non compulsory", "not compulsory")


def _url_scheda(u: str) -> str:
    """Alcune voci puntano alla pagina del portlet (`…?p_p_id=…TrainingOfferDisplayPortlet_id=<id>…`): la scheda
    dell'insegnamento ha comunque l'indirizzo `…/-/dettaglio/insegnamento/<id>/<nome>`."""
    m = re.search(r"TrainingOfferDisplayPortlet_id=(\d+)", u)
    return f"{DIP}/offerta-formativa/percorsi-di-studio/-/dettaglio/insegnamento/{m.group(1)}/x" if m else u


def _obbligatorio(info: str) -> bool | None:
    t = info.lower()
    if any(x in t for x in _TIPI_NON_OBBLIGATORI):
        return False
    return True if ("obbligatorio" in t or "compulsory" in t) else None


def leggi_piano(s: str, anno: int) -> tuple[list[dict], list[dict]]:
    """Insegnamenti dell'a.a. `anno` per anno di corso e percorso, e i «buchi»: anni di corso senza
    insegnamenti ma con il rimando alla scheda dell'offerta di un a.a. precedente
    (`link-ooff-previous-year`), che per quella coorte è l'unico piano pubblicato.

    Nella scheda corrente l'intestazione è «N° anno - Per gli immatricolati nel C / C+1» (anno di corso
    erogato nell'a.a. C+N-1); nelle schede degli anni passati «N° anno - A / A+1» (A = a.a. in cui si
    segue quell'anno). Le pagine in inglese hanno «Nst year - For matriculated students in …»."""
    out, buchi = [], []
    parti = _TAB.split(s)
    # split con un gruppo: [prima, titolo1, corpo1, titolo2, corpo2, …]; senza schede a tab, tutto è un corpo
    tabs = list(zip(parti[1::2], parti[2::2])) if len(parti) > 1 else [(None, s)]
    for titolo, testo in tabs:
        blocchi = _INTESTAZIONE.split(testo)
        tab_nome = None
        voci = []
        for k, coorte, aa, corpo in zip(blocchi[1::4], blocchi[2::4], blocchi[3::4], blocchi[4::4]):
            k = int(k)
            if (int(aa) + k - 1 if coorte else int(aa)) != anno:
                continue  # anno di corso non erogato nell'a.a. corrente
            studi = []
            for st in re.findall(r'<div class="study">(.*?)</div>', corpo, re.S):
                a = re.search(r'<a href="([^"]+)"[^>]*aria-label="([^"]*)"[^>]*>(.*?)</a>', st, re.S)
                p = re.search(r"<p>\s*(.*?)\s*</p>", st, re.S)
                if not a:
                    continue
                t = _testo(a.group(3))
                ssd = _SSD.search(t)
                label = html.unescape(a.group(2))
                percorso = label.split(" - ", 1)[0].strip() if " - " in label else None
                tab_nome = tab_nome or percorso
                info = _testo(p.group(1)) if p else ""
                cfu = re.match(r"([\d.,]+)\s*(?:crediti|credits)", info)
                cod = re.search(r"\[(?:Cod\.|Code):\s*(\w+)\]", info)
                v = float(cfu.group(1).replace(",", ".")) if cfu else None
                studi.append({
                    "anno": k, "nome": _titolo(_SSD.sub("", t)),
                    "ssd": ssd.group(1) if ssd and ssd.group(1) != "NN" else None,
                    "cfu": int(v) if v is not None and v.is_integer() else v,
                    "obbligatorio": _obbligatorio(info),
                    "codice": cod.group(1) if cod else None, "url": _url_scheda(html.unescape(a.group(1))), "percorso": percorso,
                })
            link = re.search(r'<a [^>]*class="[^"]*link-ooff-previous-year[^"]*"[^>]*href="([^"]+)"', corpo) or \
                re.search(r'<a [^>]*href="([^"]+)"[^>]*class="[^"]*link-ooff-previous-year', corpo)
            voci.append((k, studi, html.unescape(link.group(1)) if link else None))
        nome_tab = tab_nome or (_testo(titolo) if titolo else None)
        for k, studi, link in voci:
            out.extend(studi)
            if not studi and link:
                buchi.append({"anno": k, "percorso": nome_tab, "link": link})
    return out, buchi


def leggi_corso(s: str, anno: int) -> list[dict]:
    return leggi_piano(s, anno)[0]


def leggi_insegnamento(s: str) -> dict:
    campi = {_testo(a): b for a, b in re.findall(r"<dt>(.*?)</dt>\s*<dd>(.*?)</dd>", s, re.S)}
    doc = [_testo(x) for x in re.findall(r"<a [^>]*>(.*?)</a>", campi.get("Docente responsabile dell'erogazione", "") or
                                         campi.get("Reference professor for teaching", ""))]
    testi = re.search(r'title="(?:Testi di riferimento|Reference text books)".*?<div class="content[^"]*"[^>]*>(.*?)</div>', s, re.S)
    per = _testo(campi.get("Periodo", "") or campi.get("Semestre", "")).lower()
    m = re.search(r"(primo|secondo|terzo|\d)", per)
    return {
        "docenti": sorted({" ".join(w.capitalize() for w in d.split()) for d in doc if d}),
        "periodo": ("annuale" if "annual" in per else {"primo": "1", "secondo": "2", "terzo": "3"}.get(m.group(1),
                                                                                                        m.group(1)))
        if m else None,
        "libri": estrai_libri(testi.group(1)) if testi else [],
    }


def _con_o_senza_r(link: str) -> str:
    m = re.search(r"/corso/(\w+)/", link)
    if not m:
        return link
    cod = m.group(1)
    return link.replace(f"/corso/{cod}/", f"/corso/{cod[:-1] if cod.endswith('R') else cod + 'R'}/", 1)


def _percorso_vicino(nome: str | None, correnti: set[str]) -> str | None:
    """Percorso attuale che corrisponde a un percorso di una coorte passata (stesso nome o nome contenuto nell'altro)."""
    if not nome:
        return None
    vuote = {"percorso", "curriculum", "indirizzo", "e", "di", "del", "della", "dei", "delle", "in", "per", "sede"}
    toc = lambda t: {w for w in _norm(t).split() if w not in vuote}  # noqa: E731
    uguali = [p for p in correnti if _norm(p) == _norm(nome)]
    if uguali:
        return uguali[0]
    t = toc(nome)
    vicini = [p for p in correnti if t and toc(p) and (t <= toc(p) or toc(p) <= t)]
    return vicini[0] if len(vicini) == 1 else None


def abbina_corso(corso: dict, slug_per_cod: dict[str, str]) -> str | None:
    """Codice della scheda del portale per un corso del database. Con il riordino i codici cambiano
    (LB07 -> LB07R, LM54 -> LM90) e lo stesso nome esiste in triennale e magistrale: si prova il codice
    dell'url (anche con la «R»), poi lo slug dell'url, poi il nome, sempre dentro lo stesso livello."""
    liv = "L" if corso.get("tipo") == "L" else "M"
    cand = {c: s for c, s in slug_per_cod.items() if (c.startswith("LB")) == (liv == "L")}
    m = re.search(r"dettaglio/corso/(\w+)/([\w-]+)", corso.get("url") or "")
    trovati: list[str] = []
    if m:
        trovati = [c for c in (m.group(1), m.group(1) + "R") if c in cand][:1] or \
            [c for c, s in cand.items() if s == m.group(2)]
    if len(set(trovati)) != 1:
        trovati = [c for c, s in cand.items() if _norm(s.replace("-", " ")) == _norm(corso.get("nome"))]
    if not trovati:  # nome del portale più corto (o più lungo) di quello del database
        n = _norm(corso.get("nome"))
        trovati = [c for c, s in cand.items() if min(len(n), len(_norm(s.replace("-", " ")))) >= 15 and
                   (n.startswith(_norm(s.replace("-", " "))) or _norm(s.replace("-", " ")).startswith(n))]
    if len(set(trovati)) > 1 and re.search(r"(?i)replica", corso.get("sede") or ""):
        trovati = sorted(trovati)[-1:]  # sede in replica (es. Infermieristica a Tricase: LB51T accanto a LB51L)
    elif len(set(trovati)) > 1:
        trovati = sorted(trovati)[:1]
    return trovati[0] if len(set(trovati)) == 1 else None


def _nome_da_scheda(s: str) -> str | None:
    """Nome dell'insegnamento dalla sua scheda, quando nel piano compare solo «(SSD)»."""
    campi = {_testo(a): _testo(b) for a, b in re.findall(r"<dt>(.*?)</dt>\s*<dd>(.*?)</dd>", s, re.S)}
    for k in ("Insegnamento", "Teaching in italian", "Teaching"):
        if campi.get(k):
            return _titolo(campi[k])
    return None


def _nomi_distinti(righe: list[dict]) -> None:
    """Voci senza codice con lo stesso nome in anni diversi (le schede degli anni passati non hanno il
    codice): build_db le unisce per nome, quindi il nome porta l'anno."""
    per_nome: dict[str, set] = {}
    for i in righe:
        if not i["codice"]:
            per_nome.setdefault(_norm(i["nome"]), set()).add(i["anno"])
    for i in righe:
        if not i["codice"] and len(per_nome[_norm(i["nome"])]) > 1:
            i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
    # stesso nome e anno con codici e CFU diversi (es. «Tirocinio» da 3, 4 o 8 CFU): sono insegnamenti distinti sulla
    # fonte; con gli stessi CFU sono lo stesso insegnamento per percorsi o canali diversi (lo unisce pulizia)
    gruppi: dict[tuple, list[dict]] = {}
    for i in righe:
        if i["nome"]:  # (nome vuoto: si ricava dalla scheda dell'insegnamento)
            gruppi.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
    for g in gruppi.values():
        if len({i["codice"] or i["nome"] for i in g}) > 1 and len({i["cfu"] for i in g}) > 1:
            for i in g:
                if i["cfu"] is not None:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"


def fetch_ateneo(uid: str = "unisalento", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    slug_per_cod: dict[str, str] = {}  # codice corso del portale -> slug
    for e in ELENCHI:
        r = c.get(f"{BASE}/didattica/cosa-studiare/{e}")
        for cod, slug in re.findall(r'href="[^"]*dettaglio/corso/(\w+)/([\w-]+)"', r.text if r else ""):
            slug_per_cod.setdefault(cod, slug)
    abbinati = []
    for corso in corsi:
        cod = abbina_corso(corso, slug_per_cod)
        if cod:
            abbinati.append((corso, cod))
        else:
            log(f"[{uid}] corso senza scheda sul portale: {corso.get('id')}")
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(slug_per_cod)} schede corso, {len(abbinati)} corsi del database associati (su {len(corsi)})")
    # UN_RIUSA=<contributo precedente>: le schede già lette (docenti, periodo, libri) non si rileggono
    precedente: dict[str, dict] = {}
    vecchio = pathlib.Path(os.environ.get("UN_RIUSA") or "")
    if os.environ.get("UN_RIUSA") and vecchio.exists():
        for cs in json.loads(vecchio.read_text(encoding="utf-8")).get("corsi", []):
            for i in cs.get("insegnamenti", []):
                if i.get("url") and i.get("nome") and (i.get("docenti") or i.get("libri") or i.get("periodo")):
                    precedente.setdefault(i["url"], i)

    pagine: dict[str, list[dict]] = {}  # pagine delle offerte degli anni passati, lette una volta
    elenchi: dict[int, dict[str, str]] = {}

    def _elenco_anno(coorte: int) -> dict[str, str]:
        """Corsi (codice -> slug) dell'offerta formativa dell'a.a. `coorte`/`coorte+1`."""
        if coorte not in elenchi:
            rl = c.get(f"{BASE}/offerta-formativa-a.a.-{coorte}/{coorte + 1}") if coorte >= 2018 else None
            elenchi[coorte] = dict(re.findall(r'dettaglio/corso/(\w+)/([\w-]+)', rl.text)) if rl else {}
        return elenchi[coorte]

    def build(coppia) -> dict | None:
        corso, cod = coppia
        # la scheda con il piano è quella dei siti di dipartimento (qualsiasi dipartimento la mostra);
        # la scheda del portale centrale non ha il piano. Il codice è quello trovato nell'elenco del portale
        # (l'url del database può avere il codice di prima del riordino).
        url = f"{DIP}/offerta-formativa/percorsi-di-studio/-/dettaglio/corso/{cod}/{cod.lower()}"
        r = c.get(url)
        if not r:
            return None
        voci, buchi = leggi_piano(r.text, anno)
        for x in voci:
            x["_fonte"] = url
        # anni di corso di coorti non più attive: il portale rimanda alla scheda dell'offerta di quell'anno
        # accademico, che ha il piano ufficiale della coorte (stesso anno di corso). I percorsi cambiano da una
        # coorte all'altra: quello dell'anno passato si associa a un percorso attuale se i nomi coincidono,
        # altrimenti resta con il suo nome (è il percorso che quella coorte ha davvero).
        correnti = {p for p in [x["percorso"] for x in voci] + [b["percorso"] for b in buchi] if p}
        sede = re.search(r"<dt><span>Sede</span></dt>\s*<dd><span>\s*(.*?)\s*</span>", r.text)
        sede = _norm(sede.group(1)) if sede else ""
        gruppi: dict[tuple, set] = {}
        for b in buchi:
            gruppi.setdefault((b["link"], b["anno"]), set()).add(b["percorso"])
        # anni di corso che il portale non ha per nessun percorso (corso riordinato: la coorte è nella scheda
        # del vecchio codice): si cerca il corso nell'elenco dell'a.a. di quella coorte
        durata = corso.get("durata_anni") or 3
        for k in range(2, durata + 1):
            if any(x["anno"] == k for x in voci) or any(kk == k for _, kk in gruppi):
                continue
            coorte = anno - k + 1
            vecchio = _elenco_anno(coorte)
            cod_v = abbina_corso(corso, vecchio) if vecchio else None
            if cod_v:
                gruppi[(f"{BASE}/offerta-formativa-a.a.-{coorte}/{coorte + 1}/-/dettaglio/corso/{cod_v}/{vecchio[cod_v]}", k)] = set(correnti)
        for (link, k), tab_vuoti in gruppi.items():
            if link not in pagine:
                # a volte il codice del corso nell'indirizzo ha (o non ha) la «R» del riordino
                rp = c.get(link) or c.get(_con_o_senza_r(link))
                pagine[link] = leggi_piano(rp.text, anno)[0] if rp else []
            vecchi = [dict(x, _fonte=link) for x in pagine[link] if x["anno"] == k]
            if vecchi and all(_norm(x["percorso"]).startswith("sede ") for x in vecchi):
                vecchi = [x for x in vecchi if _norm(x["percorso"])[5:] == sede] or vecchi
                for x in vecchi:
                    x["percorso"] = next(iter(tab_vuoti)) if tab_vuoti else x["percorso"]
            pieni = {p for p in correnti if p not in tab_vuoti}  # percorsi che il portale ha già per questo anno
            ok = 0
            for x in vecchi:
                m = _percorso_vicino(x["percorso"], correnti)
                if m in tab_vuoti or (m is None and not any(v["anno"] == k and v["percorso"] in pieni for v in voci)):
                    voci.append(dict(x, percorso=m or x["percorso"]))
                    ok += 1
            if not ok:
                log(f"[{uid}]   {corso.get('id')}: anno {k} ({', '.join(sorted(map(str, tab_vuoti)))}) senza piano in {link}")
        righe: dict[str, dict] = {}
        percorsi = set()
        for x in voci:
            percorsi.add(x["percorso"])
            key = f"{x['anno']}:{x['codice'] or _norm(x['nome']) or x['url']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None, "docenti": [],
                    "url": x["url"], "libri": [], "esami": [], "fonte": x.get("_fonte") or url, "verificato_il": oggi, "_p": set(),
                    "_urls": [],
                }
            item["_p"].add(x["percorso"])
            if x["url"] not in item["_urls"]:
                item["_urls"].append(x["url"])  # una scheda per percorso: testi e docenti si uniscono
        for i in righe.values():
            ps = i.pop("_p")
            if len(percorsi) > 1 and ps != percorsi:
                i["curriculum"] = ", ".join(sorted(p for p in ps if p))
        if not righe:
            return None
        elenco = list(righe.values())
        _nomi_distinti(elenco)
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": url,
                "curricula": sorted(p for p in percorsi if p) if len(percorsi) > 1 else None,
                "fonte": url, "verificato_il": oggi, "insegnamenti": elenco}

    def build_safe(coppia) -> dict | None:
        try:
            return build(coppia)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {coppia[0].get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, abbinati) if r]
    urls = list(dict.fromkeys(u for corso in out for i in corso["insegnamenti"] for u in i["_urls"]))
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(urls) if syllabus else 0}")

    def scheda(url: str) -> dict | None:
        try:
            prima = precedente.get(url)
            if prima:
                return {"docenti": prima.get("docenti") or [], "periodo": prima.get("periodo"),
                        "libri": prima.get("libri") or [], "nome": prima["nome"]}
            r = c.get(url)
            if not r:
                return None
            return dict(leggi_insegnamento(r.text), nome=_nome_da_scheda(r.text))
        except Exception:  # noqa: BLE001
            return None

    risultati: dict[str, dict | None] = {}
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, (u, d) in enumerate(zip(urls, ex.map(scheda, urls)), 1):
                risultati[u] = d
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(urls)}")
    trovati = 0
    for corso in out:
        for it in corso["insegnamenti"]:
            ds = [risultati[u] for u in it.pop("_urls") if risultati.get(u)]
            if not ds:
                continue
            it["docenti"] = sorted({d for x in ds for d in x["docenti"]})
            it["periodo"] = next((x["periodo"] for x in ds if x["periodo"]), None)
            visti = set()
            for x in ds:
                for l in x["libri"]:
                    k = (_norm(l.get("titolo")), _norm(l.get("autori")))
                    if k not in visti:
                        visti.add(k)
                        it["libri"].append(l)
            it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
            trovati += len(it["libri"])
            if not it["nome"]:  # nel piano compare solo «(SSD)»: il nome è nella scheda
                it["nome"] = next((x["nome"] for x in ds if x.get("nome")), "")
    for corso in out:  # nome vuoto anche nella scheda: la voce non è un insegnamento
        corso["insegnamenti"] = [i for i in corso["insegnamenti"] if i["nome"]]
        for i in corso["insegnamenti"]:
            i.pop("_urls", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unisalento.it, schede corso (adapters/unisalento.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
