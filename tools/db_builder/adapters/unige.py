"""Piani di studio, docenti e libri dell'Università di Genova da corsi.unige.it e dal Manifesto degli studi.

UniGe non usa il Course Catalogue Cineca. Per ogni corso di studio:

- Manifesto degli studi `servizionline.unige.it/unige/stampa_manifesto/MF/<a.a.>/<codice>.html` (adapters/unige_piani.py):
  il piano di ogni anno e coorte attiva, per curriculum e sede, con insegnamenti obbligatori (e moduli), gruppi di scelta
  («18 CFU da acquisirsi dal 2° al 3° anno») e attività a scelta dello studente. Le coorti precedenti a un riordino stanno nel
  manifesto del codice del vecchio ordinamento, collegato dalla pagina degli insegnamenti («…nei precedenti anni
  accademici…»), anche a catena. Gli anni che nessun manifesto ha (corsi nuovi del 2025/2026) vengono dalla
  Programmazione didattica `PD/<a.a.>/<codice>.html` della coorte 2026/2027 (il `fonte` di ogni riga lo dice);
- `corsi.unige.it/corsi/<codice>/insegnamenti` → tabella "Codice, Insegnamento, Docenti, SSD" degli insegnamenti
  erogati nell'a.a.: i docenti di ogni codice;
- scheda `corsi.unige.it/off.f/<a.a.>/ins/<id>` → periodo, lingua, "Questo insegnamento è un modulo di",
  "TESTI/BIBLIOGRAFIA".

I CFU di un insegnamento integrato non si contano due volte: restano i moduli (`modulo_di`) se le loro quote fanno il
totale del contenitore, altrimenti il solo contenitore. Per i corsi senza manifesto resta l'elenco degli insegnamenti
erogati (`obbligatorio` null, senza curricula).

I corsi sono quelli già presenti in database/corsi/unige.json (da Universitaly), con il loro `id`: build_db.py li
associa senza ambiguità. Le repliche di sede («… REPLICA sede CHIAVARI») prendono il piano della loro sede.
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import pathlib
import re
import time

from . import unige_piani as P
from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://corsi.unige.it"
# corsi che Universitaly elenca senza link al sito: codice corsi.unige.it dalle pagine dei corsi
# della Scuola di Scienze Mediche e Farmaceutiche (medicina.unige.it/node/3362, /node/3374, /node/3375,
# /scienze-professioni-sanitarie-prevenzione), per id Universitaly
CODICI_SENZA_URL = {"1625455": "12134",  # Osteopatia
                    "1630380": "11975",  # Scienze delle professioni sanitarie della prevenzione
                    "1635663": "12189",  # Scienze infermieristiche specialistiche nelle cure neonatali e pediatriche
                    "1635561": "12187"}  # Scienze infermieristiche specialistiche nelle cure primarie


def _codice(url: str | None) -> str | None:
    m = re.match(r"https?://corsi\.unige\.it/(?:en/)?corsi/(\d+)", (url or "").strip())
    return m.group(1) if m else None


def leggi_elenco(s: str) -> tuple[list[dict], str | None]:
    """Righe della tabella degli insegnamenti e codice del vecchio ordinamento, se c'è."""
    vecchio = re.search(r"(?:precedenti anni accademici|previous academic years).*?href=[\"']/(?:en/)?corsi/(\d+)/"
                        r"(?:insegnamenti|teachings)[\"']", s, re.S)
    righe = []
    m = re.search(r"<table[^>]*>(.*?)</table>", s, re.S)
    for tr in re.findall(r"<tr>(.*?)</tr>", m.group(1) if m else "", re.S):
        td = re.findall(r"<td>(.*?)</td>(?=<td>|$)", tr, re.S)
        td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S) if len(td) < 4 else td
        if len(td) < 4:
            continue
        link = re.search(r"href=[\"']([^\"']+)[\"']", td[1])
        nome = _testo(re.sub(r"<span class=.small badge[^>]*>.*?</span>", "", td[1]))  # badge "EN" della lingua
        righe.append({
            "codice": _testo(td[0]) or None,
            "nome": _titolo(re.sub(r"\s*\(\d+(?:[.,]\d+)?\s*CFU\)\s*$", "", nome)),
            "url": BASE + link.group(1) if link and link.group(1).startswith("/") else (link.group(1) if link else None),
            "docenti": [_testo(x) for x in re.findall(r"<a [^>]*>(.*?)</a>", td[2], re.S) if _testo(x)],
            "ssd": _testo(td[3]) or None,
        })
    return righe, vecchio.group(1) if vecchio else None


def _periodo(s: str) -> str | None:
    t = s.lower()
    if not t:
        return None
    if "annual" in t:
        return "annuale"
    m = re.match(r"(\d)\s*°?\s*(semestre|semester|trimestre|quadrimestre)", t)
    return m.group(1) if m else s


# Citazioni che estrai_libri non riconosce (niente anno né editore della sua lista), frequenti nelle schede
# UniGe: «G. Donzellini. Introduzione al progetto di sistemi digitali. Springer», «Paul L-Marino The ICU
# Book Terapia Intensiva ed. Masson», «Titolo» / «Autori: …» / «Casa editrice: …» su righe separate.
# Si prendono solo righe con un autore riconoscibile (cognome e iniziali) o un editore noto, e non
# righe che parlano di slide, AulaWeb, materiale del docente, normativa ecc.
_NON_CIT = re.compile(
    r"(?i)slide|aulaweb|aula web|teams|materiale|\bmaterials?\b|dispens|appunti|lucidi|verr[aà]|saranno|fornit|"
    r"provided|disponibil|available|indicazion|consulta|\bvedi\b|si veda|si vedano|rimanda|moduli|modulo|module|"
    r"http|www\.|psw|password|lezion|lecture|docente|teacher|professor|articoli|articles|papers?\b|\bnotes\b|"
    r"esercizi|exercis|video|\bsito\b|website|online|power ?point|diapositiv|programma|syllabus|handout|e-?learning|"
    r"piattaforma|platform|studenti|students|frequentant|attending|concordat|agreed|richiesta|request|"
    r"non (?:vi )?sono|there (?:is|are) no|nessun|\bnone\b|normativ|regolament|legislat|codice civile|costituzione|"
    r"sentenz|gazzetta|\bD\.\s?Lgs|\bD\.?P\.?R\b|^(?:casa editrice|editore)\s*:")
_EDITORI_UNIGE = (
    "pensa multimedia", "scienza medica", "verduci", "minerva medica", "masson", "monduzzi", "sorbona", "delfino",
    "il castello", "amacom", "libreriauniversitaria", "edi-ermes", "edi ermes", "casa editrice", "editori", "verlag",
    "éditions", "editions", "ediciones", "hachette", "gallimard", "klett", "hueber", "cornelsen", "penguin", "harper",
    "macmillan", "norton", "mcgraw", "taylor", "palgrave", "de gruyter", "brill", "bloomsbury", "vita e pensiero",
    "franco angeli", "il melangolo", "ecig", "genova university press", "marsilio", "quodlibet", "electa", "skira",
    "dedalo", "laterza", "zanichelli", "edises", "edra", "piccin", "idelson", "esculapio", "utet", "giappichelli",
    "cedam", "giuffrè", "giuffre", "il mulino", "carocci", "springer", "wiley", "elsevier", "pearson", "hoepli",
    "calzetti", "cuzzolin", "bollati", "boringhieri", "morgan kaufmann", "world scientific", "chapman", "tecniche nuove")
_AUTORE = re.compile(r"\b[A-ZÀ-Ý][a-zà-ÿ'’]+(?:\s[A-ZÀ-Ý][a-zà-ÿ'’]+)?,?\s(?:[A-Z]\.\s?-?){1,3}(?=[\s,.;:(]|$)"
                     r"|\b(?:[A-Z]\.\s?-?){1,3}\s?[A-ZÀ-Ý][a-zà-ÿ'’]+")
_TITOLO_Q = re.compile(r"[“\"«]([^”\"»]{5,200})[”\"»]")
_INTESTAZIONE = re.compile(r"(?i)consigliat|approfondiment|facoltativ|suggested|further|optional|recommended|"
                           r"obbligator|adottat|required|mandatory")


def _citazioni_extra(sezione: str) -> list[dict]:
    from .testi import YEAR, _libero, _tipo, html_to_lines
    righe = html_to_lines(sezione)
    out, ctx, viste, i = [], None, set(), 0
    while i < len(righe):
        r = righe[i]
        cit = None
        if re.match(r"(?i)autor[ei]\s*:", r) and i > 0 and not _NON_CIT.search(righe[i - 1]):
            parti = [righe[i - 1], r]
            if i + 1 < len(righe) and re.match(r"(?i)(?:casa editrice|editore)\s*:", righe[i + 1]):
                parti.append(righe[i + 1])
                i += 1
            cit = ". ".join(p.strip(" .") for p in parti)
        elif 15 <= len(r) <= 300 and not _NON_CIT.search(r):
            low = r.lower()
            ed = any(e in low for e in _EDITORI_UNIGE)
            aut = bool(_AUTORE.search(r))
            q = bool(_TITOLO_Q.search(r))
            anno = bool(YEAR.search(r))
            resto = re.sub(r"\bet al\.?|\bed\.?\b|[^A-Za-zÀ-ÿ ]", " ", _AUTORE.sub(" ", r)).split()
            if len([w for w in resto if len(w) > 2]) >= 2 and (
                    (aut and (ed or anno or q or r.count(",") + r.count("|") + r.count(".") >= 2))
                    or (ed and len(r.split()) >= 4) or (q and (aut or ed or anno))):
                cit = r
        if not cit and len(r) < 60 and _INTESTAZIONE.search(r):
            ctx = r
        if cit:
            key = re.sub(r"\W+", "", cit.lower())[:120]
            if key not in viste:
                viste.add(key)
                libro = _libero(cit)
                if libro["autori"] and re.match(r"(?i)(?:libr[oi]|test[oi]|textbook|manuale|letture|reading)\b",
                                                libro["autori"]):  # «LIBRO DI TESTO "Titolo"»: non è l'autore
                    libro["autori"] = None
                libro["tipo"] = libro["tipo"] or (_tipo(ctx) if ctx else None)
                out.append(libro)
        i += 1
    return out


def leggi_scheda(s: str) -> dict:
    campi = {_testo(th).upper(): td for th, td in re.findall(r"<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>", s, re.S)}
    anni = []  # (cfu, anno, codice corso)
    for li in re.findall(r"<li[^>]*>(.*?)</li>", (campi.get("CFU") or campi.get("CREDITS") or ""), re.S):
        m = re.match(r"\s*([\d.,]+)\s*cfu\s+(?:anno|year)\s+(\d)", _testo(li), re.I)
        corso = re.search(r"href=[\"']/(?:en/)?corsi/(\d+)[\"']", li)
        if m and corso:
            cfu = float(m.group(1).replace(",", "."))
            anni.append((int(cfu) if cfu.is_integer() else cfu, int(m.group(2)), corso.group(1)))
    modulo = re.search(r"(?:modulo di|module of):.*?<a [^>]*>(?:<i[^>]*></i>)?(.*?)</a>",
                       campi.get("MODULI") or campi.get("MODULES") or "", re.S | re.I)
    testi = re.search(r"<h3>\s*(?:TESTI/BIBLIOGRAFIA|RECOMMENDED READING/BIBLIOGRAPHY|TEXTBOOKS?/BIBLIOGRAPHY)\s*</h3>"
                      r"\s*<p class=[\"']schedains_data[\"']>(.*?)</div>", s, re.S | re.I)
    return {
        "anni": anni, "periodo": _periodo(_testo(campi.get("PERIODO") or campi.get("SEMESTER") or "")),
        "lingua": _testo(campi.get("LINGUA") or campi.get("LANGUAGE") or "") or None,
        "modulo_di": _titolo(_testo(modulo.group(1))) if modulo else None,
        "libri": (estrai_libri(testi.group(1)) or _citazioni_extra(testi.group(1))) if testi else [],
    }


def _catena(c, cod: str, max_livelli: int = 3) -> tuple[list[str], dict[str, list[dict]]]:
    """Codice del corso e dei vecchi ordinamenti collegati a catena, con le righe dell'elenco degli insegnamenti di ognuno."""
    codici, liste = [cod], {}
    for _ in range(max_livelli + 1):
        r = c.get(f"{BASE}/corsi/{codici[-1]}/insegnamenti")
        righe, vecchio = leggi_elenco(r.text) if r else ([], None)
        liste[codici[-1]] = righe
        if not vecchio or vecchio in codici or len(codici) > max_livelli:
            break
        codici.append(vecchio)
    return codici, liste


def _periodo_mf(t: str | None) -> str | None:
    if not t:
        return None
    if re.search(r"(?i)annuale", t):
        return "annuale"
    m = re.match(r"(\d)\s*°?\s*(semestre|trimestre|quadrimestre)", t.strip(), re.I)
    return m.group(1) if m else None


def _slug(s: str) -> str:
    import unicodedata
    t = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def _righe_anno(v: dict, sedi: set[str]) -> list[dict]:
    """Righe di un anno (tutti i curricula): unisce lo stesso insegnamento di curricula diversi. I crediti liberi di un
    gruppo che vale per più anni («12 CFU dal 1° al 3° anno», riga senza CFU) restano a scelta con gli N CFU del gruppo."""
    out: dict[tuple, dict] = {}
    for b in v["blocchi"]:
        cur = P._chiave_curricula(b["curricula"], sedi)
        for r in b["righe"]:
            r = dict(r)
            if r["cfu"] is None and r.get("libera"):
                r["cfu"] = r["n_cfu"]
                r["_libera"] = True
            if r["cfu"] in (None, 0):  # prove, OFA e attività senza crediti
                continue
            key = (r["codice"] or P.nome_pulito(r["nome"]), r["cfu"], r["obbligatorio"], r["modulo_di"])
            if key in out:
                if cur and out[key]["_cur"] is not None and cur not in out[key]["_cur"]:
                    out[key]["_cur"].append(cur)
                elif not cur:
                    out[key]["_cur"] = None
                continue
            r["_cur"] = [cur] if cur else None
            out[key] = r
    return list(out.values())


def fetch_ateneo(uid: str = "unige", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c if _codice(c.get("url")) or str(c.get("id_universitaly")) not in CODICI_SENZA_URL
             else dict(c, url=f"{BASE}/corsi/{CODICI_SENZA_URL[str(c['id_universitaly'])]}") for c in corsi]
    corsi = [c for c in corsi if _codice(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con pagina su corsi.unige.it")
    c = Client()
    oggi = time.strftime("%Y-%m-%d")
    aa = anno or 2026
    schede: dict[str, dict | None] = {}
    testi: dict[str, str | None] = {}
    catene: dict[str, tuple] = {}

    def scheda(url: str) -> dict | None:
        if url not in schede:
            r = c.get(url)
            schede[url] = leggi_scheda(r.text) if r else None
        return schede[url]

    def testo(url: str) -> str | None:
        if url not in testi:
            r = c.get(url)
            testi[url] = r.text if r else None
        return testi[url]

    def catena(cod: str) -> tuple:
        if cod not in catene:
            catene[cod] = _catena(c, cod)
        return catene[cod]

    def build_erogato(corso: dict) -> dict | None:
        """Corsi senza manifesto: gli insegnamenti erogati nell'a.a. (anno e CFU dalle schede)."""
        cod = _codice(corso["url"])
        codici, righe, fonte = {cod}, [], f"{BASE}/corsi/{cod}/insegnamenti"
        r = c.get(fonte)
        if not r:
            return None
        fonte = r.url
        nuove, vecchio = leggi_elenco(r.text)
        righe += nuove
        if vecchio:
            codici.add(vecchio)
            r2 = c.get(f"{BASE}/corsi/{vecchio}/insegnamenti")
            if r2:
                righe += leggi_elenco(r2.text)[0]
        out: dict[str, dict] = {}
        for x in righe:
            sc = scheda(x["url"]) if x["url"] and syllabus else None
            anni = [(cfu, a) for cfu, a, cc in (sc or {}).get("anni", []) if cc in codici] or [(None, None)]
            for cfu, a in anni:
                key = f"{a}:{x['codice'] or x['nome']}"
                if key in out:
                    continue
                item = {
                    "codice": x["codice"], "nome": x["nome"], "anno": a, "periodo": (sc or {}).get("periodo"),
                    "cfu": cfu, "ssd": x["ssd"], "obbligatorio": None, "curriculum": None,
                    "docenti": sorted({d.title() if d.isupper() else d for d in x["docenti"]}),
                    "url": x["url"], "libri": (sc or {}).get("libri", []), "esami": [],
                    "fonte": fonte, "verificato_il": oggi,
                }
                if sc:
                    item["stato_libri"] = "completo" if item["libri"] else "da_aggiungere"
                    if sc.get("modulo_di"):
                        item["modulo_di"] = sc["modulo_di"]
                out[key] = item
        if not out:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": f"{BASE}/corsi/{cod}",
                "fonte": fonte, "verificato_il": oggi, "insegnamenti": list(out.values())}

    def build(corso: dict) -> dict | None:
        cod = _codice(corso["url"])
        codici, liste = catena(cod)
        durata = corso.get("durata_anni") or 3
        sede = P.sede_del_corso(corso.get("nome"))
        piano = P.piano_corso(codici, durata, sede, lambda x: testo(P.url_mf(x, aa)), lambda x: testo(P.url_pd(x, aa)), aa)
        if not piano:
            return build_erogato(corso)
        per_codice = {}
        for lista in liste.values():
            for x in lista:
                per_codice.setdefault(x["codice"], x)
        out: list[dict] = []
        for k in sorted(piano):
            v = piano[k]
            for r in _righe_anno(v, v["sedi"]):
                cod_r = r["codice"]
                el = per_codice.get(cod_r) or {}
                sc = None
                if syllabus:
                    for sid in r["schede"] or []:
                        s1 = scheda(f"{BASE}/off.f/{aa}/ins/{sid}")
                        if s1 and (sc is None or (not sc["libri"] and s1["libri"])):
                            sc = s1
                        if sc and sc["libri"]:
                            break
                item = {
                    "codice": cod_r, "nome": P.nome_pulito(r["nome"]), "anno": k,
                    "periodo": (sc or {}).get("periodo") or _periodo_mf(r["periodo"]),
                    "cfu": r["cfu"], "ssd": r["ssd"] or el.get("ssd"), "obbligatorio": r["obbligatorio"],
                    "curriculum": ", ".join(r["_cur"]) if r["_cur"] else None,
                    "docenti": sorted({d.title() if d.isupper() else d for d in el.get("docenti") or []}),
                    "url": f"{BASE}/off.f/{aa}/ins/{r['scheda']}" if r["scheda"] else None,
                    "libri": (sc or {}).get("libri", []), "esami": [],
                    "fonte": v["fonte"], "verificato_il": oggi,
                }
                if syllabus and r["scheda"]:
                    item["stato_libri"] = "completo" if item["libri"] else "da_aggiungere"
                if r["modulo_di"]:
                    item["modulo_di"] = P.nome_pulito(r["modulo_di"])
                    item["_padre"] = r.get("padre_codice")
                if r.get("_libera"):
                    item["_libera"] = (r["gruppo"], r["spread"])
                if v["da_pd"]:
                    item["nota"] = (f"Programmazione didattica della coorte {v['coorte']}/{v['coorte'] + 1}: "
                                    "anno senza coorte attiva nel manifesto")
                out.append(item)
        # crediti liberi di un gruppo che vale per più anni («12 CFU dal 1° al 3° anno»): una voce sola, nel primo anno in cui compare
        primi: dict[tuple, int] = {}
        for it in out:
            if it.get("_libera") and it["_libera"][1]:
                kk = (it["nome"], it["cfu"], it["curriculum"], it["_libera"])
                primi[kk] = min(primi.get(kk, 99), it["anno"])
        out = [it for it in out if not (it.get("_libera") and it["_libera"][1]
                                        and it["anno"] != primi[(it["nome"], it["cfu"], it["curriculum"], it["_libera"])])]
        # voci senza codice (crediti liberi): id proprio, altrimenti build_db le fonderebbe (stesso nome, CFU diversi)
        for n, it in enumerate([x for x in out if not x["codice"]], 1):
            it["id"] = (f"{corso['id']}-{_slug(it['nome'])[:24]}-{str(it['cfu']).replace('.', '_')}cfu-a{it['anno']}"
                        + (f"-{_slug(it['curriculum'])[:20]}" if it["curriculum"] else "") + f"-{n}")
        for it in out:
            it.pop("_libera", None)
        # stesso codice nello stesso anno con CFU o obbligatorietà diversi tra curricula: build_db li fonderebbe
        visti: dict[tuple, int] = {}
        for it in out:
            if not it["codice"]:
                continue
            key = (it["anno"], it["codice"])
            visti[key] = visti.get(key, 0) + 1
            if visti[key] > 1:
                it["id"] = f"{corso['id']}-{_slug(it['codice'])[:30]}-{str(it['cfu']).replace('.', '_')}cfu-a{it['anno']}"
                if it["obbligatorio"] is False:
                    it["id"] += "-scelta"
        for it in out:
            it.pop("_padre", None)
        # insegnamenti omonimi (stesso anno e curriculum) con codici diversi: il nome dice di quale integrato sono moduli;
        # se restano uguali li distinguono i CFU (se diversi) o un numero
        def omonimi() -> list[list[dict]]:
            g: dict[tuple, list[dict]] = {}
            for it in out:
                g.setdefault((it["anno"], re.sub(r"\W+", " ", it["nome"].lower()).strip(), it["curriculum"]), []).append(it)
            return [x for x in g.values() if len({y["codice"] for y in x}) > 1]

        for g in omonimi():
            for x in g:
                if x.get("modulo_di") and x["modulo_di"].lower() != x["nome"].lower():
                    x["nome"] = f"{x['nome']} ({x['modulo_di']})"
        for g in omonimi():
            g.sort(key=lambda y: str(y["codice"]))
            if len({y["cfu"] for y in g}) == len(g):
                for y in g:
                    y["nome"] = f"{y['nome']} ({y['cfu']:g} CFU)"
            else:
                for n, y in enumerate(g, 1):
                    y["nome"] = f"{y['nome']} ({n})"
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": durata, "url": f"{BASE}/corsi/{cod}",
                "fonte": piano[min(piano)]["fonte"], "verificato_il": oggi, "insegnamenti": out,
                **({"sede": P.NOME_SEDE.get(sede, sede)} if sede else {})}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            import traceback
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r} {traceback.format_exc()[-300:]}")
            return None

    out = []
    with cf.ThreadPoolExecutor(6) as ex:
        for n, r in enumerate(ex.map(build_safe, corsi), 1):
            if r:
                out.append(r)
            if n % 20 == 0:
                log(f"[{uid}]   corsi {n}/{len(corsi)}")
    libri = sum(len(i["libri"]) for x in out for i in x["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {libri}; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da corsi.unige.it e dal Manifesto degli studi (adapters/unige.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
