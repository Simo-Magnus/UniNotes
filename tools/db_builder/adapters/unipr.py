"""Insegnamenti, docenti e libri dell'Università di Parma da corsi.unipr.it.

Esse3 di UniPR non pubblica l'offerta e i siti `cdl-*.unipr.it` hanno una verifica anti-bot;
il portale `corsi.unipr.it` invece è pubblico:

- `/it/<corso>/insegnamenti-e-piano-degli-studi` → id della vista Drupal "insegnamenti"
  (`view_args`);
- `/it/views/ajax?view_name=insegnamenti&…&filter_anno_immatricolazione=<coorte>&filter_curriculum=<id>` →
  per la coorte (e il curriculum): sezioni "Primo anno 2025/2026", "Secondo anno 2026/2027", … divise per
  periodo, con nome, codice Esse3 (lo stesso degli appelli), tipo di attività, CFU, responsabile, moduli
  e il blocco «insegnamenti a scelta libera o vincolata». Il filtro del curriculum va nella query string
  (nel corpo del POST è ignorato) e senza di esso la vista dà solo gli insegnamenti comuni a tutti i
  curricula: la pagina elenca i curricula di ogni coorte nell'attributo `data-curriculum` delle opzioni
  dell'anno di immatricolazione. Per l'anno di corso k si legge la coorte A-k+1 (la sezione del suo k-esimo
  anno), una volta per ogni curriculum; le righe di tutti i curricula si uniscono per codice (comune a
  tutti = nessun curriculum); stesso codice con CFU o obbligatorietà diversi tra i curricula = righe distinte
  (la più diffusa tiene l'id del codice, le altre `<corso>-<codice>-<N>cfu`). Il blocco «a scelta libera o
  vincolata» e il tipo «A scelta dello studente» danno `obbligatorio: false`. Se la coorte non esiste (corsi
  nuovi) o non ha quell'anno si usa la coorte più vicina che lo ha;
- scheda (`/it/ugov/degreecourse/<id>`) → "Bibliografia" (non riletta per i codici già nel contributo
  precedente);
- elenco dei corsi nella home `corsi.unipr.it/it` → pagina dei corsi che Universitaly non collega (per nome).

Correzioni: Infermieristica elenca nello stesso piano i tre insegnamenti PR (Parma), PC (Piacenza) e AZ (Parma
AUSL) e il corso di Universitaly (o la sua replica) tiene solo il proprio prefisso; insegnamenti con lo stesso
nome nello stesso anno e curriculum ma codici diversi: stessi CFU = un insegnamento solo (stesso docente sotto due
codici, per esempio caratterizzante e affine; resta il codice che ha gli appelli), CFU diversi = il nome porta
«(N CFU)»; «Ingegneria gestionale (prevalentemente a distanza)» ha la sede «Parma (prevalentemente a distanza)»
perché Universitaly non dà la sede e il corso è omonimo di quello in presenza.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://corsi.unipr.it"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36"
ORD = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6,
       "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6}


def _slug(url: str | None) -> str | None:
    u = (url or "").strip().rstrip("/")
    # cdl-…, cdlm-…, cdlmcu-… come sottodominio o come percorso di corsi.unipr.it (anche /scheda/…)
    m = re.match(r"https?://(cdl\w*-[\w-]+)\.unipr\.it", u) or         re.match(r"https?://corsi\.unipr\.it/(?:\w\w/)?(?:scheda/)?(cdl\w*-[\w-]+)", u)
    return m.group(1).lower() if m else None


def _periodo(t: str) -> str | None:
    t = t.lower()
    if "annual" in t:
        return "annuale"
    m = re.match(r"(\w+)\s+(?:semestre|trimestre|periodo|semester)", t)
    return str(ORD[m.group(1)]) if m and m.group(1) in ORD else (t or None)


def _nome(s: str) -> str:
    """Nome dell'insegnamento: apostrofi tipografici normali; maiuscolo fuori dalle parentesi -> iniziali maiuscole
    («STORIA DELL'ARTE (Integr. LM)» come «STORIA DELL'ARTE (INTEGR. LM)», che il titolo tutto maiuscolo rende uguale)."""
    s = s.replace("’", "'")
    if s.isupper():
        return _titolo(s)
    lettere = [ch for ch in re.sub(r"\([^)]*\)", "", s) if ch.isalpha()]
    if lettere and all(ch.isupper() for ch in lettere):
        t = " ".join(p.strip() if p.startswith("(") else _titolo(p) for p in re.split(r"(\([^)]*\))", s) if p.strip())
        return re.sub(r"\(([^)]*)\)", lambda m: "(" + _titolo(m.group(1).upper()) + ")", t)
    return _titolo(s)


def _opzioni(testo: str) -> dict[int, list[tuple[str, str]]]:
    """Coorti della pagina (opzioni «anno di immatricolazione») con i loro curricula (nome, id)."""
    out: dict[int, list[tuple[str, str]]] = {}
    for m in re.finditer(r'<option value="(\d{4})"([^>]*)>', testo):
        lista: list[tuple[str, str]] = []
        cur = re.search(r'data-curriculum="([^"]*)"', m.group(2))
        if cur:
            try:
                lista = [(_titolo(str(d["text"]).strip()), str(d["value"])) for d in json.loads(html.unescape(cur.group(1)))]
            except (ValueError, KeyError, TypeError):
                lista = []
        out.setdefault(int(m.group(1)), lista)
    return out


def leggi_elenco(s: str, aa: str | None = None) -> list[dict]:
    """Insegnamenti delle sezioni "<N> anno <aa>" (con i moduli degli integrati come `moduli`; `opzionale`
    per quelli del blocco «insegnamenti a scelta libera o vincolata»). Senza `aa`, tutte le sezioni."""
    out = []
    parti = re.split(r"<button[^>]*>\s*(?:<svg.*?</svg>)?\s*(\w+)\s+(?:anno|year)\s+(\d{4}/\d{4})\s*</button>", s, flags=re.S)
    for i in range(1, len(parti) - 2, 3):
        ordinale, a, corpo = parti[i].lower(), parti[i + 1], parti[i + 2]
        if (aa and a != aa) or ordinale not in ORD:
            continue
        periodo = None
        for pezzo in re.split(r"(<h4[^>]*>.*?</h4>)", corpo, flags=re.S):
            if pezzo.startswith("<h4"):
                periodo = _periodo(_testo(pezzo))
                continue
            soglia = pezzo.find("elenco-insegnamenti__opzionali")
            # una voce di primo livello = link alla scheda seguito dal <div> con tipo e CFU
            # (i moduli degli integrati non hanno il <div>)
            voci = re.split(r'(?=<li>\s*<a href="[^"]*/ugov/degreecourse/\d+"><span class="text-uppercase">[^<]*</span>'
                            r'\s*-\s*Cod\.[^<]*</a>\s*<div>)', pezzo)
            pos = 0
            for li in voci:
                inizio, pos = pos, pos + len(li)
                li = re.sub(r"^<li>\s*", "", li)
                testa = re.match(r'<a href="([^"]+)"><span class="text-uppercase">(.*?)</span>\s*-\s*Cod\.\s*([^<\s]+)\s*</a>',
                                 li, re.S)
                if not testa:
                    continue
                tipo = re.search(r"<div>\s*(.*?)<strong>\s*([\d.,]+)\s*CFU", li, re.S)
                resp = re.search(r"Responsabile dell[^<]*</dt>\s*<dd>(.*?)</dd>", li, re.S)
                cfu = float(tipo.group(2).replace(",", ".")) if tipo else None
                out.append({
                    "anno": ORD[ordinale], "periodo": periodo, "url": html.unescape(testa.group(1)),
                    "nome": _nome(_testo(testa.group(2))), "codice": testa.group(3).strip(),
                    "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
                    "tipo": _testo(tipo.group(1)).strip(" -") if tipo else None,
                    "opzionale": soglia >= 0 and inizio >= soglia,
                    "docenti": [] if not resp or "NON ASSEGNATO" in resp.group(1).upper()
                    else [" ".join(w.capitalize() if w.isupper() else w for w in _testo(resp.group(1)).split())],
                    "moduli": re.findall(r'<a href="([^"]*/ugov/degreecourse/\d+)"', li)[1:],
                })
    return out


def libri_scheda(s: str) -> list[dict]:
    m = re.search(r">\s*(?:Bibliografia|Bibliography)\s*</h2>(.*?)</article>", s, re.S)
    return estrai_libri(m.group(1)) if m else []


def _slug_id(s: str, maxlen: int = 40) -> str:
    """Come `build_db.slug`: l'id di un insegnamento è `<corso>-<slug del codice>`."""
    t = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip().replace(" ", "-")[:maxlen].strip("-")


_GENERICO = re.compile(r"(?i)^(generale|percorso comune|comune|nessun curriculum|unico)$")


def _post(c: Client, url: str, dati: dict) -> str | None:
    """POST della vista Drupal (con la cache su disco di `Client`, se attiva): HTML dei frammenti inseriti."""
    f = None
    if c.cache:
        key = hashlib.sha1((url + "|" + json.dumps(sorted(dati.items()))).encode()).hexdigest()
        f = c.cache / key[:2] / f"post_{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))["html"]
    risposta = None
    for tentativo in range(4):
        try:
            with c.lock:
                time.sleep(c.min_gap)
                c.requests += 1
            ra = c.s.post(url, data=dati, headers={"X-Requested-With": "XMLHttpRequest"}, timeout=90)
            ra.raise_for_status()
            risposta = "".join(x.get("data", "") for x in ra.json() if x.get("command") == "insert")
            break
        except Exception:  # noqa: BLE001
            time.sleep(2 ** tentativo)
    if f is not None and risposta is not None:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"html": risposta}), encoding="utf-8")
    return risposta


def _libri_precedenti(uid: str) -> dict[str, dict]:
    """Libri già raccolti per codice dell'insegnamento (contributo precedente): le schede non si rileggono."""
    p = ROOT / "database" / "contrib" / "auto" / f"{uid}.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("stato_libri") and (cod not in out or (i.get("libri") and not out[cod]["libri"])):
                out[cod] = {"libri": i.get("libri") or [], "stato_libri": i["stato_libri"]}
    return out


def _piano_anno(c: Client, ctx: tuple, k: int, anno: int,
                opzioni: dict[int, list[tuple[str, str]]]) -> tuple[list[dict], int | None]:
    """Insegnamenti dell'anno di corso `k` dalla coorte `anno-k+1` (una richiesta per curriculum), con
    la coorte usata; se la coorte manca o non ha il k-esimo anno, la coorte più vicina che lo ha.
    Ogni riga porta `_cur` (nome del curriculum, None se la coorte non ne ha) e `_curricula` (quelli della coorte)."""
    disp, cds, vpath, vbase, dom = ctx
    base = anno - k + 1
    vicine = [base] + [b for d in range(1, 8) for b in (base + d, base - d)]
    for coorte in vicine:
        if coorte not in opzioni or coorte > anno:
            continue
        curricula = opzioni[coorte]
        if len(curricula) == 1 and _GENERICO.match(curricula[0][0]):
            curricula = [(None, curricula[0][1])]
        righe: list[dict] = []
        for nome_cur, id_cur in (curricula or [(None, "")]):
            dati = {"view_name": "insegnamenti", "view_display_id": disp, "view_args": cds,
                    "view_path": vpath.replace("\\/", "/"), "view_base_path": vbase, "view_dom_id": dom,
                    "pager_element": "0", "filter_anno_immatricolazione": str(coorte),
                    "anno_immatricolazione": str(coorte), "filter_curriculum": id_cur, "filtered_cds": cds,
                    "_drupal_ajax": "1"}
            # il filtro va anche nella query string: nel corpo del POST la vista lo ignora
            url = (f"{BASE}/it/views/ajax?_wrapper_format=drupal_ajax&filter_anno_immatricolazione={coorte}"
                   f"&anno_immatricolazione={coorte}&filtered_cds={cds}&filter_curriculum={id_cur}")
            testo = _post(c, url, dati)
            if not testo:
                continue
            for x in leggi_elenco(testo):
                if x["anno"] == k:
                    x["_cur"] = nome_cur
                    x["_curricula"] = [n for n, _ in curricula if n]
                    righe.append(x)
        if righe:
            return righe, coorte
    return [], None


def _a_scelta(x: dict) -> bool:
    return bool(x["opzionale"] or "a scelta" in (x["tipo"] or "").lower())


def _unisci_curricula(grezze: list[dict], corso_id: str) -> list[dict]:
    """Righe per curriculum -> una riga per insegnamento: stesso codice e stessi CFU/obbligatorietà = un
    insegnamento (nessun curriculum se è in tutti); CFU o obbligatorietà diversi tra i curricula = righe
    distinte, ognuna con i propri curricula (la più diffusa tiene l'id del codice, le altre un id proprio)."""
    gruppi: dict[tuple, dict] = {}
    for x in grezze:
        key = (x["anno"], x["codice"], x["cfu"], _a_scelta(x))
        g = gruppi.setdefault(key, {"x": x, "cur": set(), "tutti": set(), "docenti": []})
        if x["_cur"]:
            g["cur"].add(x["_cur"])
        g["tutti"] |= set(x["_curricula"])
        for d in x["docenti"]:
            if d not in g["docenti"]:
                g["docenti"].append(d)
        if not g["x"]["periodo"] and x["periodo"]:
            g["x"]["periodo"] = x["periodo"]
    per_codice: dict[tuple, list[dict]] = {}
    for key, g in gruppi.items():
        per_codice.setdefault(key[:2], []).append(g)
    out = []
    for (anno_k, codice), gl in per_codice.items():
        tutti = set().union(*(g["tutti"] for g in gl))
        gl.sort(key=lambda g: (-len(g["cur"]) if g["cur"] else -99, -(g["x"]["cfu"] or 0)))
        for n, g in enumerate(gl):
            x = g["x"]
            r = {"codice": codice, "nome": x["nome"], "anno": anno_k, "periodo": x["periodo"], "cfu": x["cfu"],
                 "ssd": None, "obbligatorio": False if _a_scelta(x) else None,
                 "curriculum": None if not g["cur"] or g["cur"] >= tutti else ", ".join(sorted(g["cur"])),
                 "docenti": g["docenti"], "url": x["url"], "libri": [], "esami": [],
                 "_schede": [x["url"]] + x["moduli"]}
            if n:
                prima = gl[0]["x"]
                r["id"] = f"{corso_id}-{_slug_id(codice)}" + (f"-{x['cfu']:g}cfu" if x["cfu"] != prima["cfu"] else "") + (
                    "" if _a_scelta(x) == _a_scelta(prima) else "-scelta" if _a_scelta(x) else "-obbl")
            out.append(r)
    return out


_PREFISSI_SEDE = {"PR": "Parma", "PC": "Piacenza", "AZ": "Parma AUSL"}


def _filtra_sede(righe: list[dict], nome_corso: str) -> list[dict]:
    """Infermieristica: la pagina elenca i tre insegnamenti con lo stesso numero e prefisso PR (Parma), PC (Piacenza)
    o AZ (Parma AUSL); il corso di Universitaly e le sue repliche (nome «… REPLICA PIACENZA», «… REPLICA PARMA AUSL»)
    tengono solo il proprio."""
    sedi = {}
    for x in righe:
        m = re.fullmatch(r"(PR|PC|AZ)(\d+)", x["codice"])
        if m:
            sedi.setdefault(m.group(2), set()).add(m.group(1))
    if not any(len(v) > 1 for v in sedi.values()):
        return righe
    n = nome_corso.upper()
    mio = "PC" if "PIACENZA" in n else "AZ" if "AUSL" in n else "PR"
    return [x for x in righe if not re.fullmatch(r"(PR|PC|AZ)\d+", x["codice"]) or x["codice"].startswith(mio)]


def _norma(nome: str) -> str:
    return re.sub(r"\W+", " ", unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode().lower()).strip()


def _sovrapposti(a: dict, b: dict) -> bool:
    ca = set(x.strip() for x in (a["curriculum"] or "").split(", ") if x.strip())
    cb = set(x.strip() for x in (b["curriculum"] or "").split(", ") if x.strip())
    return not ca or not cb or bool(ca & cb)


def _codici_con_appelli(uid: str) -> set[str]:
    out: set[str] = set()
    base = ROOT / "database" / "contrib" / "auto"
    for p in (base / f"{uid}.json", base / f"{uid}_appelli.json", base / "agenda" / f"{uid}.json"):
        try:
            out |= set((json.loads(p.read_text(encoding="utf-8")).get("appelli") or {}).keys())
        except (OSError, ValueError):
            pass
    return out


def _omonimi_nell_anno(righe: list[dict], con_appelli: set[str]) -> list[dict]:
    """Stesso nome nello stesso anno e negli stessi curricula con codici diversi (`doppione_anno`):
    stessi CFU = lo stesso insegnamento sotto due codici (per esempio come caratterizzante e come affine, con lo stesso
    docente): una riga sola, con il codice che ha gli appelli e i docenti di entrambe; CFU diversi = alternative
    distinte e il nome porta i CFU."""
    per_nome: dict[tuple, list[dict]] = {}
    for x in righe:
        per_nome.setdefault((x["anno"], _norma(x["nome"])), []).append(x)
    tolte: list[dict] = []
    for gl in per_nome.values():
        if len({x["codice"] for x in gl}) < 2:
            continue
        # componenti con curricula sovrapposti
        comp: list[list[dict]] = []
        for x in gl:
            uniti = [c for c in comp if any(_sovrapposti(x, y) for y in c)]
            nuova = [x] + [y for c in uniti for y in c]
            comp = [c for c in comp if c not in uniti] + [nuova]
        for c in comp:
            if len({y["codice"] for y in c}) < 2:
                continue
            per_cfu: dict = {}
            for y in c:
                per_cfu.setdefault(y["cfu"], []).append(y)
            for cfu, gc in per_cfu.items():
                if len({y["codice"] for y in gc}) < 2:
                    continue
                tieni = sorted(gc, key=lambda y: (y["codice"] not in con_appelli, y["_ord"]))[0]
                for y in gc:
                    if y is tieni:
                        continue
                    tieni["docenti"] = tieni["docenti"] + [d for d in y["docenti"] if d not in tieni["docenti"]]
                    tieni["_schede"] = tieni["_schede"] + [u for u in y["_schede"] if u not in tieni["_schede"]]
                    tieni["periodo"] = tieni["periodo"] or y["periodo"]
                    if y["obbligatorio"] is None:
                        tieni["obbligatorio"] = None
                    cu = [p for p in (tieni["curriculum"] or "").split(", ") + (y["curriculum"] or "").split(", ") if p]
                    tieni["curriculum"] = None if (not tieni["curriculum"] or not y["curriculum"]) else ", ".join(sorted(set(cu)))
                    tolte.append(y)
            resto = [y for y in c if y not in tolte]
            if len({y["cfu"] for y in resto}) > 1:
                for y in resto:
                    if isinstance(y["cfu"], (int, float)) and f"({y['cfu']:g} CFU)" not in y["nome"]:
                        y["nome"] = f"{y['nome']} ({y['cfu']:g} CFU)"
    return [x for x in righe if not any(x is t for t in tolte)]


def _con_url_portale(corsi: list[dict]) -> list[dict]:
    """Corsi con la pagina su corsi.unipr.it. Per quelli di Universitaly senza sito (o con un sito di altro tipo) la
    pagina è cercata per nome nell'elenco dei corsi della home del portale (attributo `data-…` con nome e link)."""
    pronti, mancanti = [], []
    for c in corsi:
        (pronti if _slug(c.get("url")) else mancanti).append(c)
    if mancanti:
        cl = Client(rate=2.0)
        cl.s.headers.update({"User-Agent": UA})
        r = cl.get(f"{BASE}/it")
        elenco: list[dict] = []
        if r:
            i = r.text.find("&quot;cod_dipartimento&quot;")
            if i > 0:
                a = r.text.rfind("[", 0, i)
                prof = 0
                for k in range(a, len(r.text)):
                    prof += r.text[k] == "[" 
                    prof -= r.text[k] == "]"
                    if prof == 0:
                        break
                try:
                    elenco = json.loads(html.unescape(r.text[a:k + 1]))
                except ValueError:
                    elenco = []
        per_nome = {_norma(x.get("text") or ""): x.get("link") for x in elenco if _slug(x.get("link"))}
        for c in mancanti:
            n = _norma(c.get("nome") or "")
            link = per_nome.get(n) or next((l for t, l in per_nome.items() if t and n.startswith(t + " ")), None)
            if link:
                pronti.append({**c, "url": link})
    return pronti


def fetch_ateneo(uid: str = "unipr", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = _con_url_portale(corsi)
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi su corsi.unipr.it")
    c = Client(rate=4.0)
    c.s.headers.update({"User-Agent": UA})
    oggi = time.strftime("%Y-%m-%d")
    precedenti = _libri_precedenti(uid)
    con_appelli = _codici_con_appelli(uid)

    def build(corso: dict) -> dict | None:
        slug = _slug(corso["url"])
        pagina = f"{BASE}/it/{slug}/insegnamenti-e-piano-degli-studi"
        r = c.get(pagina)
        if not r:
            return None
        # impostazioni della vista nella pagina: la vista si interroga in POST (CloudFront mette
        # in cache le GET ignorando i parametri e restituirebbe la coorte sbagliata)
        vista = re.search(r'"view_name":"insegnamenti","view_display_id":"(\w+)","view_args":"(\d+)",'
                          r'"view_path":"([^"]+)","view_base_path":"([^"]+)","view_dom_id":"(\w+)"', r.text)
        if not vista:
            return None
        opzioni = _opzioni(r.text)
        durata = corso.get("durata_anni") or 3
        grezze: list[dict] = []
        for k in range(1, durata + 1):
            righe, _ = _piano_anno(c, vista.groups(), k, anno, opzioni)
            grezze += righe
        righe = _unisci_curricula(_filtra_sede(grezze, corso["nome"]), corso["id"])
        for n, x in enumerate(righe):
            x["_ord"] = n
        righe = _omonimi_nell_anno(righe, con_appelli)
        for x in righe:
            x.pop("_ord", None)
        if not righe:
            return None
        for x in righe:
            x["fonte"], x["verificato_il"] = pagina, oggi
        doc = {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
               "url": f"{BASE}/it/{slug}", "fonte": pagina, "verificato_il": oggi, "insegnamenti": righe}
        titolo = re.search(r"<title>(.*?)</title>", r.text, re.S)
        if titolo and "prevalentemente a distanza" in html.unescape(titolo.group(1)).lower():
            # Universitaly non dà la sede e il corso è omonimo di quello in presenza (stessa classe): la sede lo distingue
            doc["sede"] = "Parma (prevalentemente a distanza)"
        return doc

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    daleggere = {i["codice"] for x in out for i in x["insegnamenti"] if i["codice"] not in precedenti}
    urls = sorted({u for x in out for i in x["insegnamenti"] if i["codice"] in daleggere for u in i["_schede"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(urls) if syllabus else 0} (libri già raccolti per {len(precedenti)} codici)")
    libri_url: dict[str, list[dict]] = {}

    def leggi(u: str) -> None:
        try:
            r = c.get(u)
            libri_url[u] = libri_scheda(r.text) if r else []
        except Exception:  # noqa: BLE001
            libri_url[u] = []

    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, _ in enumerate(ex.map(leggi, urls), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   schede {n}/{len(urls)}")
    trovati = 0
    for x in out:
        for i in x["insegnamenti"]:
            viste = set()
            schede = i.pop("_schede")
            if i["codice"] in precedenti:
                i["libri"] = json.loads(json.dumps(precedenti[i["codice"]]["libri"]))
                i["stato_libri"] = precedenti[i["codice"]]["stato_libri"]
                trovati += len(i["libri"])
                continue
            for u in schede:
                for lb in libri_url.get(u, []):
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        i["libri"].append(lb)
            if syllabus:
                i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
            trovati += len(i["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da corsi.unipr.it (adapters/unipr.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
