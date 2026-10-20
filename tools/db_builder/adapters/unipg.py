"""Insegnamenti, docenti e libri dell'Università di Perugia da www.unipg.it.

Esse3 di UniPG non pubblica l'offerta; il portale sì, per a.a. e regolamento (coorte):

- `/didattica/corsi-di-laurea-e-laurea-magistrale/archivio/offerta-formativa-<a.a.>?idcorso=<id>&annoregolamento=<coorte>`
  scheda "Insegnamenti" (`&view=elenco&tab=INS`) → "N° Anno" con insegnamento, curriculum,
  CFU, periodo; la pagina di una coorte elenca tutti gli anni del suo piano. Per l'anno di corso
  k nell'a.a. A serve il regolamento A-k+1;
- con il riordino dei corsi (2025) i regolamenti precedenti hanno un altro `idcorso` (Beni culturali:
  8442 dal 2025, 288 per la coorte 2024): `?view=elenco&ricerca=on&annoregolamento=<coorte>` elenca i
  corsi di quella coorte con il loro `idcorso`, e si abbinano per nome (senza «(abilitante …)» né
  «REPLICA …»), poi per classe; senza questo il piano si fermava al 2° anno;
- sotto le tabelle degli anni, «Gruppi insegnamenti opzionali»: ogni gruppo ha i CFU richiesti («6» o
  «Min1 - Max8») e le alternative (nome + percorso). Le alternative di un gruppo da cui si sceglie sono
  `obbligatorio: false` (l'opzionalità sta nel gruppo, non nella scheda); quelle di un gruppo da
  sostenere per intero (CFU richiesti = somma dei membri) sono obbligatorie;
- gli elenchi dei corsi di una coorte compaiono in più archivi (a.a. 2026-27, 2025-26, 2024-25: i più
  vecchi elencano più coorti); la sede (Perugia, Terni, Foligno…) distingue i corsi omonimi di una
  coorte (Infermieristica, Medicina e chirurgia) e va nel contributo;
- nella pagina di una coorte, righe con lo stesso nome ma schede (`idins`) diverse sono insegnamenti
  diversi (non si fondono per nome), e lo stesso nome con CFU diversi senza scheda (ADE, «A scelta dello
  studente» di percorsi diversi) o con la scheda ma nello stesso percorso («Storia greca» da 6 e da 12 CFU)
  sono righe diverse col CFU nel nome; le attività a 0 CFU (OFA, precorsi,
  moduli senza crediti) non si inseriscono;
- scheda (`…&idins=<id>`) → codice Esse3 (lo stesso degli appelli), docenti, CFU, anno,
  periodo, "Tipo insegnamento" (obbligatorio/opzionale), "Testi di riferimento" (uno per modulo),
  letti da `unipg_testi` (testo libero: prosa e frammenti scartati). Lo stesso codice insegnato in più
  corsi (mutuati) usa il programma di chi lo ha pubblicato.

Appelli: `adapters/unipg_appelli.py`.
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
from collections import Counter

from .unibo import Client, _testo, _titolo
from .testi import estrai_libri
from .unipg_testi import libri_unipg

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unipg.it"
ARCHIVIO = BASE + "/didattica/corsi-di-laurea-e-laurea-magistrale/archivio/offerta-formativa-{aa}"


def _id(url: str | None) -> str | None:
    m = re.search(r"unipg\.it/perm/offerta-formativa/\d{4}/corso/(\d+)|idcorso=(\d+)", url or "")
    return (m.group(1) or m.group(2)) if m else None


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nome_corso(nome: str | None) -> str:
    """Nome del corso senza «(abilitante …)» e senza «REPLICA …»."""
    n = re.sub(r"\(.*?\)", " ", nome or "")
    return _norm(re.sub(r"(?i)\breplica\b.*$", " ", n))


def _classi(s: str | None) -> set[str]:
    return {re.sub(r"[^A-Z0-9]", "", m.upper()) for m in re.findall(r"(?:LM|L|LMR)[-/ ]?(?:SNT|P)?[-]?\d+", s or "", re.I)}


def _periodo(t: str) -> str | None:
    t = t.lower()
    if not t:
        return None
    if "annual" in t:
        return "annuale"
    for k, v in (("primo", "1"), ("secondo", "2"), ("terzo", "3"), ("first", "1"), ("second", "2")):
        if t.startswith(k):
            return v
    return t


def aa_stringa(anno: int) -> str:
    return f"{anno}-{(anno + 1) % 100:02d}"


def leggi_elenco(s: str) -> list[dict]:
    """Corsi di una coorte (`ricerca=on&annoregolamento=`): idcorso, nome, dipartimento, sede, classe."""
    out = []
    for h2, tab in re.findall(r"<h2>(.*?)</h2>\s*<table[^>]*>(.*?)</table>", s, re.S):
        for tr in re.findall(r"<tr>(.*?)</tr>", tab, re.S):
            m = re.search(r'idcorso=(\d+)[^"]*">\s*(.*?)</a>', tr)
            td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if not m or len(td) < 4:
                continue
            out.append({"idcorso": m.group(1), "nome": _testo(m.group(2)), "dip": _testo(td[1]), "sede": _testo(td[2]),
                        "classe": _testo(re.sub(r"(?i)<br\s*/?>", " / ", td[3])), "sezione": _testo(h2)})
    return out


def leggi_insegnamenti(s: str) -> list[dict]:
    """Scheda "Insegnamenti" (tab=INS): "N° Anno" con insegnamento, curriculum, CFU, periodo, lingua."""
    out = []
    for anno, tab in re.findall(r"<h4>\s*(\d)°\s*Anno\s*</h4>\s*<table[^>]*>(.*?)</table>", s, re.S):
        for tr in re.findall(r"<tr>(.*?)</tr>", tab, re.S):
            td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(td) < 4:
                continue
            link = re.search(r'href="([^"]*idins=\d+[^"]*)"', td[0])
            cfu_t = _testo(td[2]).replace(",", ".")
            curr = _testo(td[1])
            out.append({
                "anno": int(anno), "nome": _titolo(_testo(td[0])), "periodo": _periodo(_testo(td[3])),
                "curriculum": None if re.match(r"(?i)comune a tutti", curr) else curr or None,
                "cfu": (int(float(cfu_t)) if float(cfu_t).is_integer() else float(cfu_t))
                if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None,
                "url": BASE + html.unescape(link.group(1)) if link else None,
            })
    return out


def leggi_scheda(s: str) -> dict:
    campi: dict[str, str] = {}
    for k, v in re.findall(r"<tr>\s*<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>\s*</tr>", s, re.S):
        campi.setdefault(_testo(k), v)  # il primo è dell'insegnamento, i seguenti dei moduli
    docenti = [_testo(x) for x in re.split(r"<br\s*/?>|</li>|</p>|</a>", campi.get("Docenti", "")) if _testo(x)]
    tipo = _testo(campi.get("Tipo insegnamento", "")).lower()
    testi = re.findall(r"<tr>\s*<th[^>]*>\s*Testi di riferimento\s*</th>\s*<td[^>]*>(.*?)</td>\s*</tr>", s, re.S)
    return {
        "codice": _testo(campi.get("Codice insegnamento", "")) or None,
        "docenti": sorted(set(docenti)) or ([_testo(campi["Docente responsabile"])] if campi.get("Docente responsabile")
                                           else []),
        "obbligatorio": True if "obbligatori" in tipo else (False if tipo else None),
        "ssd": _testo(campi.get("Settore", "")) or None,
        "lingua": _testo(campi.get("Lingua insegnamento", "")) or None,
        "libri": libri_unipg(testi) or estrai_libri(*testi),  # in mancanza, il riconoscimento comune (editore + anno)
        "senza_testi": not any(_testo(t) for t in testi),
    }


def leggi_gruppi(s: str) -> list[dict]:
    """«Gruppi insegnamenti opzionali»: [{nome, min, max, membri: [{nome, curriculum, cfu, url}]}].
    «CFU richiesti: 6» → min = max = 6; «Min1 - Max8» → 1 e 8."""
    i = s.find("Gruppi insegnamenti opzionali")
    if i < 0:
        return []
    out: list[dict] = []
    cur = None
    for tr in re.findall(r"<tr>(.*?)</tr>", s[i:], re.S):
        td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if "colspan" in tr and td:
            t = _testo(tr)
            m = re.search(r"Gruppo\s+(.*?)\s*CFU richiesti:\s*(?:Min(\d+)\s*-\s*Max(\d+)|(\d+))", t, re.S)
            cur = None
            if m:
                lo = int(m.group(2) or m.group(4))
                hi = int(m.group(3) or m.group(4))
                cur = {"nome": re.sub(r"^Gruppo\s+", "", m.group(1)).strip(), "min": lo, "max": hi, "membri": []}
                out.append(cur)
            else:  # «Insegnamenti richiesti: 1»: si sceglie un numero di insegnamenti, non di CFU
                m = re.search(r"Gruppo\s+(.*?)\s*Insegnamenti richiesti:\s*(\d+)", t, re.S)
                if m:
                    cur = {"nome": re.sub(r"^Gruppo\s+", "", m.group(1)).strip(), "min": None, "max": None,
                           "n_ins": int(m.group(2)), "membri": []}
                    out.append(cur)
            continue
        if cur is not None and len(td) >= 3:
            cfu_t = _testo(td[2]).replace(",", ".")
            curr = _testo(td[1])
            cur["membri"].append({
                "nome": _titolo(_testo(td[0])),
                "curriculum": None if re.match(r"(?i)comune a tutti", curr) else curr or None,
                "cfu": float(cfu_t) if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None,
                "url": bool(re.search(r"idins=\d+", td[0])),
            })
    return out


def marche_gruppi(gruppi: list[dict]) -> dict[tuple[str, str], str]:
    """(nome, percorso) delle alternative → «scelta» (gruppo da cui si sceglie) o «obbl» (gruppo da sostenere
    per intero: CFU richiesti pari alla somma dei membri). Se un'alternativa è in più gruppi, «scelta» prevale."""
    out: dict[tuple[str, str], str] = {}
    for g in gruppi:
        if re.search(r"(?i)recuper", g["nome"]):
            continue  # «Recupero attività I e II anno»: esami già nel piano (obbligatori) offerti per recuperare crediti
        cfu = [m["cfu"] for m in g["membri"]]
        if g.get("n_ins") is not None:
            per_intero = g["n_ins"] >= len(g["membri"])
        else:
            per_intero = bool(cfu) and None not in cfu and g["min"] == g["max"] and abs(sum(cfu) - g["max"]) < 1e-9
        for m in g["membri"]:
            k = (_norm(m["nome"]), _norm(m["curriculum"]))
            if not per_intero:
                out[k] = "scelta"
            else:
                out.setdefault(k, "obbl")
    return out


def abbina_corso(corso: dict, elenco: list[dict], sede: str | None = None, proprio: bool = True) -> list[str]:
    """`idcorso` dei corsi di una coorte che sono il corso del database (anche con altro nome o sede).
    Con più corsi omonimi (Infermieristica a Perugia, Terni e Foligno) conta la sede."""
    own = _id(corso.get("url"))
    if proprio and own and any(e["idcorso"] == own for e in elenco):
        return [own]
    k = _nome_corso(corso["nome"])
    cl = _classi(corso.get("classe"))
    stessi = [e for e in elenco if _nome_corso(e["nome"]) == k]
    if len(stessi) > 1:
        con_classe = [e for e in stessi if _classi(e["classe"]) & cl]
        stessi = con_classe or stessi
    if len(stessi) > 1 and sede:
        stessa_sede = [e for e in stessi if _norm(e["sede"]) == _norm(sede)]
        stessi = stessa_sede or stessi
    if stessi:
        return [e["idcorso"] for e in stessi]
    # nome cambiato con il riordino: stessa classe e nome molto simile
    simili = [(difflib.SequenceMatcher(None, k, _nome_corso(e["nome"])).ratio(), e) for e in elenco
              if cl and _classi(e["classe"]) & cl]
    simili = [(r, e) for r, e in simili if r >= 0.8]
    if simili:
        migliore = max(r for r, _ in simili)
        return [e["idcorso"] for r, e in simili if r == migliore][:1]
    return []


def sede_del_corso(corso: dict, elenchi: dict[int, list[tuple[str, list[dict]]]], anno: int) -> str | None:
    """Sede: «REPLICA Terni» → Terni; altrimenti quella del corso nell'elenco della coorte corrente."""
    m = re.search(r"(?i)\breplica\b\s*(.*)$", corso.get("nome") or "")
    if m:
        return m.group(1).strip() or None
    own = _id(corso.get("url"))
    for _, el in elenchi.get(anno, []):
        for e in el:
            if e["idcorso"] == own:
                return e["sede"] or None
    return None


def righe_anno(righe_pagine: list[tuple[str, list[dict], list[dict]]], k: int) -> list[dict]:
    """Righe dell'anno `k` da una o più pagine di coorte. Una riga è una scheda (`idins`) o, senza scheda, un
    nome con i suoi CFU; i percorsi della stessa riga si uniscono. Il gruppo da cui si sceglie dà `obbligatorio`."""
    righe: dict[tuple, dict] = {}
    oggi = time.strftime("%Y-%m-%d")
    for url, rows, gruppi in righe_pagine:
        marche = marche_gruppi(gruppi)
        rows_k = [x for x in rows if x["anno"] == k and x["cfu"] != 0]
        if _insieme_doppio(rows_k):
            visti, unici = set(), []
            for x in rows_k:  # la pagina elenca due volte lo stesso piano (due serie di schede): si tiene la prima
                kk = (_norm(x["nome"]), x["cfu"], _norm(x["curriculum"]), x["periodo"])
                if kk not in visti:
                    visti.add(kk)
                    unici.append(x)
            rows_k = unici
        for x in rows_k:
            m = marche.get((_norm(x["nome"]), _norm(x["curriculum"])))
            flag = {"scelta": False, "obbl": True}.get(m)
            key = (x["url"] or ("n", _norm(x["nome"]), x["cfu"], x["periodo"]), flag)
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": x["nome"], "anno": k, "periodo": x["periodo"], "cfu": x["cfu"],
                    "ssd": None, "obbligatorio": flag, "curriculum": None, "docenti": [], "url": x["url"],
                    "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "_curr": set(), "_flag": flag,
                }
            elif not x["url"] and flag is None and item["fonte"] == url and x["curriculum"] in item["_curr"]:
                item["cfu"] = (item["cfu"] or 0) + (x["cfu"] or 0)  # stessa riga due volte nella tabella: i crediti si sommano
            item["_curr"].add(x["curriculum"])
    # stesso nome, CFU diversi, senza scheda (ADE, «A scelta dello studente» per percorso): i CFU nel nome
    per_nome: dict[str, list[dict]] = {}
    for it in righe.values():
        per_nome.setdefault(_norm(it["nome"]), []).append(it)
    def sovrapposti(a: dict, b: dict) -> bool:
        return None in a["_curr"] or None in b["_curr"] or bool(a["_curr"] & b["_curr"])

    for g in per_nome.values():
        for it in g:
            altri = [o for o in g if o is not it and o["cfu"] != it["cfu"]]
            if it["cfu"] is not None and altri and (not it["url"] or any(sovrapposti(it, o) for o in altri)):
                it["nome"] = f"{it['nome']} ({it['cfu']:g} CFU)"
    # stesso nome e CFU, senza scheda, in semestri diversi («Attività a scelta dello studente» 6 CFU al 1° e al 2°): il periodo
    for g in per_nome.values():
        for it in g:
            if not it["url"] and "CFU)" not in it["nome"] and any(
                    o is not it and not o["url"] and o["cfu"] == it["cfu"] and sovrapposti(it, o) for o in g):
                p = it["periodo"]
                it["nome"] = f"{it['nome']} ({p}° semestre)" if p in ("1", "2") else f"{it['nome']} ({p or 'annuale'})"
    return list(righe.values())


def _insieme_doppio(rows: list[dict]) -> bool:
    """La pagina di una coorte elenca due volte tutto il piano dell'anno (due serie di schede con gli stessi
    nomi e CFU, es. Odontoiatria 2023): quasi tutte le righe hanno un gemello con schede diverse."""
    if len(rows) < 6:
        return False
    cont = Counter((_norm(x["nome"]), x["cfu"], _norm(x["curriculum"])) for x in rows)
    in_coppia = sum(v for v in cont.values() if v >= 2)
    return in_coppia >= 0.8 * len(rows) and all(v == 2 for v in cont.values() if v >= 2)


def fetch_ateneo(uid: str = "unipg", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, riusa: dict | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py).
    `riusa`: {url della scheda: {codice, docenti, libri, obbligatorio, ssd}} già raccolti (non si rileggono)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    arch = ARCHIVIO.format(aa=aa_stringa(anno))
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    riusa = riusa or {}
    log(f"[{uid}] {len(corsi)} corsi sul portale www.unipg.it")
    c = Client(rate=1.8)  # al massimo 2 richieste al secondo
    oggi = time.strftime("%Y-%m-%d")
    durata_max = max((cc.get("durata_anni") or 3) for cc in corsi) if corsi else 3

    # corsi di ogni coorte: più archivi (le coorti più vecchie stanno solo nei precedenti)
    elenchi: dict[int, list[tuple[str, list[dict]]]] = {}
    for reg in range(anno, anno - durata_max, -1):
        for aa in (anno, anno - 1, anno - 2):
            base = ARCHIVIO.format(aa=aa_stringa(aa))
            r = c.get(f"{base}?view=elenco&ricerca=on&annoregolamento={reg}")
            el = leggi_elenco(r.text) if r else []
            if el:
                elenchi.setdefault(reg, []).append((base, el))
        log(f"[{uid}] coorte {reg}: {[len(el) for _, el in elenchi.get(reg, [])]} corsi")

    pagine: dict[str, tuple[list[dict], list[dict]]] = {}

    def pagina(url: str):
        if url not in pagine:
            r = c.get(url)
            pagine[url] = (leggi_insegnamenti(r.text), leggi_gruppi(r.text)) if r else ([], [])
        return pagine[url]

    def piano(corso: dict, sede: str | None, k: int, reg: int):
        """Pagine della coorte `reg` con righe all'anno `k` (dal primo archivio che elenca il corso)."""
        replica = bool(re.search(r"(?i)\breplica\b", corso["nome"]))
        out = []
        liste = elenchi.get(reg) or ([(arch, [])] if k <= 2 else [])
        for base, el in liste:
            ids = abbina_corso(corso, el, sede, proprio=not replica) if el else [_id(corso["url"])]
            for idc in ids:
                url = f"{base}?view=elenco&idcorso={idc}&annoregolamento={reg}&tab=INS"
                rows, gruppi = pagina(url)
                if any(x["anno"] == k for x in rows):
                    out.append((url, rows, gruppi))
            if out:
                break
        return out

    ctx: dict[str, tuple[dict, str | None]] = {}

    def build(corso: dict) -> dict | None:
        cid = _id(corso["url"])
        durata = corso.get("durata_anni") or 3
        sede = sede_del_corso(corso, elenchi, anno)
        ctx[corso["id"]] = (corso, sede)
        righe: list[dict] = []
        curricula = set()
        for k in range(1, durata + 1):
            reg = anno - k + 1  # l'anno k dell'a.a. corrente è nel regolamento della coorte reg
            usata = reg
            pg = piano(corso, sede, k, reg)
            if not pg:
                # coorte senza piano (es. Odontoiatria 2022): la più vicina che ne ha uno
                for r2 in (reg + 1, reg - 1, reg + 2, reg - 2):
                    if r2 <= anno and not pg:
                        pg = piano(corso, sede, k, r2)
                        usata = r2
                if pg:
                    log(f"[{uid}]   {corso['nome']}: anno {k} dal piano della coorte {usata} (la {reg} non ne ha)")
            if not pg:
                log(f"[{uid}]   {corso['nome']}: anno {k} (coorte {reg}) senza piano")
                continue
            for it in righe_anno(pg, k):
                it["_reg"] = usata
                righe.append(it)
                curricula |= {x for x in it["_curr"] if x}
        for i in righe:
            cs = i.pop("_curr")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        out = {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
               "url": f"{arch}?idcorso={cid}&annoregolamento={anno}", "curricula": sorted(curricula) or None,
               "fonte": f"{arch}?idcorso={cid}", "verificato_il": oggi, "insegnamenti": righe}
        if sede:
            out["sede"] = sede
        return out

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
    da_leggere = [u for u in jobs if u not in riusa]
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede: {len(jobs)}, da leggere {len(da_leggere) if syllabus else 0}, già raccolte {len(jobs) - len(da_leggere)}")

    def applica(url: str, sc: dict) -> int:
        for it in jobs[url]:
            for k in ("codice", "ssd"):
                if sc.get(k) is not None:
                    it[k] = sc[k]
            if sc.get("obbligatorio") is not None and it["_flag"] is None:
                it["obbligatorio"] = sc["obbligatorio"]
            it["docenti"] = list(sc.get("docenti") or [])
            it["libri"] = [dict(x) for x in sc.get("libri") or []]
            it["stato_libri"] = "completo" if it["libri"] else "da_aggiungere"
        return len(sc.get("libri") or [])

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if not r:
                return 0
            return applica(url, leggi_scheda(r.text))
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    for u in jobs:
        if u in riusa:
            trovati += applica(u, riusa[u])
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, da_leggere), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(da_leggere)}")
        mutuati = condividi_programmi(out)
        log(f"[{uid}] programmi condivisi tra insegnamenti con lo stesso codice: {mutuati}")
        prec = programmi_anno_precedente(out, c, elenchi, ctx, anno, pagina, set(riusa), log)
        log(f"[{uid}] insegnamenti con i testi del programma dell'a.a. precedente: {prec}")
    for corso in out:
        distingui_omonimi(corso["insegnamenti"])
        for i in corso["insegnamenti"]:
            i.pop("_reg", None)
            i.pop("_flag", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unipg.it, offerta formativa (adapters/unipg.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def distingui_omonimi(righe: list[dict]) -> int:
    """Stesso nome, anno e CFU con codici Esse3 diversi nello stesso percorso (due «Tirocinio» da 7 CFU nel 2° semestre di
    Scienze riabilitative: due attività obbligatorie): il codice nel nome, altrimenti build_db le unirebbe e i CFU dell'anno
    sarebbero meno. Percorsi disgiunti (la stessa materia con una scheda per percorso) restano unite."""
    def percorsi(i):
        return set(re.split(r",\s*", i["curriculum"])) if i.get("curriculum") else {None}

    def sovrapposti(a, b):
        pa, pb = percorsi(a), percorsi(b)
        return None in pa or None in pb or bool(pa & pb)

    gruppi: dict[tuple, list[dict]] = {}
    for i in righe:
        # solo righe obbligatorie: le alternative di gruppi diversi (stessa lingua «A» e «B») sono lo stesso insegnamento
        if i.get("codice") and i.get("obbligatorio") is not False:
            gruppi.setdefault((i["anno"], _norm(i["nome"]), i["cfu"]), []).append(i)
    n = 0
    for g in gruppi.values():
        for i in g:
            if any(o is not i and o["codice"] != i["codice"] and sovrapposti(i, o) for o in g):
                i["nome"] = f"{i['nome']} ({i['codice']})"
                n += 1
    return n


def programmi_anno_precedente(corsi: list[dict], c, elenchi, ctx, anno, pagina, gia_letti: set, log=print) -> int:
    """Insegnamenti senza testi nel programma 2026/27: si usano quelli della scheda dello stesso
    insegnamento nel piano della coorte precedente (a.a. 2025/26), indicandolo nella nota di ogni libro.
    Non per le schede già raccolte in una raccolta precedente (già provato)."""
    da_fare = []
    for corso in corsi:
        corso_db, sede = ctx[corso["id"]]
        prima: dict[tuple[int, int], dict[str, list]] = {}
        for i in corso["insegnamenti"]:
            if i.get("libri") or not i.get("url") or i["url"] in gia_letti:
                continue
            reg, k = i["_reg"] - 1, i["anno"]
            if (reg, k) not in prima:
                nomi: dict[str, list] = {}
                for base, el in elenchi.get(reg, []):
                    for idc in abbina_corso(corso_db, el, sede, proprio=False)[:2]:
                        rows, _ = pagina(f"{base}?view=elenco&idcorso={idc}&annoregolamento={reg}&tab=INS")
                        for x in rows:
                            if x["anno"] == k and x["url"]:
                                nomi.setdefault(_norm(x["nome"]), []).append((x["url"], aa_stringa(anno - 1)))
                    if nomi:
                        break
                prima[(reg, k)] = nomi
            prev = prima[(reg, k)].get(_norm(i["nome"]))
            if prev:
                da_fare.append((i, prev))
    log(f"[unipg] schede dell'a.a. precedente da leggere: {sum(len(p) for _, p in da_fare)}")

    def leggi(item_prev):
        i, prev = item_prev
        for url, aa in prev:
            try:
                r = c.get(url)
                sc = leggi_scheda(r.text) if r else None
            except Exception:  # noqa: BLE001
                sc = None
            if sc and sc["libri"]:
                return i, sc["libri"], aa, url
        return i, [], None, None

    n = 0
    with cf.ThreadPoolExecutor(4) as ex:
        for i, libri, aa, url in ex.map(leggi, da_fare):
            if libri:
                for b in libri:
                    b["note"] = f"Testi del programma dell'a.a. {aa.replace('-', '/')}: quello 2026/27 non li indica"
                i["libri"] = libri
                i["stato_libri"] = "completo"
                n += 1
    return n


def condividi_programmi(corsi: list[dict]) -> int:
    """Un insegnamento mutuato in più corsi ha lo stesso codice: chi non ha i testi usa quelli del
    corso che li ha pubblicati (stesso codice Esse3)."""
    per_codice: dict[str, list[dict]] = {}
    for c in corsi:
        for i in c["insegnamenti"]:
            if i.get("codice") and i.get("libri"):
                per_codice.setdefault(i["codice"], []).append(i)
    n = 0
    for c in corsi:
        for i in c["insegnamenti"]:
            if i.get("codice") and not i.get("libri") and i["codice"] in per_codice:
                origine = per_codice[i["codice"]][0]
                i["libri"] = [dict(x) for x in origine["libri"]]
                i["stato_libri"] = "completo"
                n += 1
    return n
