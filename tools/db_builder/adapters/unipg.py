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


def abbina_corso(corso: dict, elenco: list[dict]) -> list[str]:
    """`idcorso` dei corsi di una coorte che sono il corso del database (anche con altro nome o sede)."""
    own = _id(corso.get("url"))
    if own and any(e["idcorso"] == own for e in elenco):
        return [own]
    k = _nome_corso(corso["nome"])
    cl = _classi(corso.get("classe"))
    stessi = [e for e in elenco if _nome_corso(e["nome"]) == k]
    if len(stessi) > 1:
        con_classe = [e for e in stessi if _classi(e["classe"]) & cl]
        stessi = con_classe or stessi
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


def fetch_ateneo(uid: str = "unipg", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    arch = ARCHIVIO.format(aa=aa_stringa(anno))
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi sul portale www.unipg.it")
    c = Client(rate=1.8)  # al massimo 2 richieste al secondo
    oggi = time.strftime("%Y-%m-%d")
    durata_max = max((cc.get("durata_anni") or 3) for cc in corsi) if corsi else 3

    # corsi di ogni coorte (il portale mostra le coorti dell'archivio dell'a.a.; la più vecchia sta in quello prima)
    elenchi: dict[int, tuple[str, list[dict]]] = {}
    for reg in range(anno, anno - durata_max, -1):
        for aa in (anno, anno - 1):
            base = ARCHIVIO.format(aa=aa_stringa(aa))
            r = c.get(f"{base}?view=elenco&ricerca=on&annoregolamento={reg}")
            el = leggi_elenco(r.text) if r else []
            if el:
                elenchi[reg] = (base, el)
                break
        log(f"[{uid}] coorte {reg}: {len(elenchi[reg][1]) if reg in elenchi else 0} corsi")

    def build(corso: dict) -> dict | None:
        cid = _id(corso["url"])
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        for k in range(1, durata + 1):
            reg = anno - k + 1  # l'anno k dell'a.a. corrente è nel regolamento della coorte reg
            base, el = elenchi.get(reg, (arch, []))
            ids = abbina_corso(corso, el) if el else ([cid] if k <= 2 else [])
            if not ids and el:
                # il corso manca nell'elenco di quella coorte (es. Odontoiatria 2022): si prova l'idcorso
                # che ha nelle coorti vicine; se la pagina non ha il piano, resta vuota
                for r2 in (reg + 1, reg - 1, reg + 2, reg - 2):
                    if r2 in elenchi and not ids:
                        ids = abbina_corso(corso, elenchi[r2][1])[:1]
            if not ids:
                log(f"[{uid}]   {corso['nome']}: anno {k} (coorte {reg}) senza corso abbinato")
            for idc in ids:
                url = f"{base}?view=elenco&idcorso={idc}&annoregolamento={reg}&tab=INS"
                r = c.get(url)
                if not r:
                    continue
                for x in leggi_insegnamenti(r.text):
                    if x["anno"] != k:
                        continue
                    if x["curriculum"]:
                        curricula.add(x["curriculum"])
                    key = f"{k}:{x['nome'].lower()}"
                    item = righe.get(key)
                    if not item:
                        item = righe[key] = {
                            "codice": None, "nome": x["nome"], "anno": k, "periodo": x["periodo"], "cfu": x["cfu"],
                            "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": [], "url": x["url"],
                            "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "_curr": set(),
                        }
                    elif not item["url"]:
                        item["url"] = x["url"]
                    item["_curr"].add(x["curriculum"])
            # lo stesso anno di corso della coorte precedente, erogato nell'a.a. scorso: serve solo se il
            # programma 2026/27 non ha i testi (le schede si leggono dopo, solo per quelle)
            if syllabus and (reg - 1) in elenchi:
                base2, el2 = elenchi[reg - 1]
                for idc in abbina_corso(corso, el2)[:2]:
                    r = c.get(f"{base2}?view=elenco&idcorso={idc}&annoregolamento={reg - 1}&tab=INS")
                    for x in (leggi_insegnamenti(r.text) if r else []):
                        key = f"{k}:{x['nome'].lower()}"
                        if x["anno"] == k and x["url"] and key in righe:
                            righe[key].setdefault("_prev", []).append((x["url"], aa_stringa(anno - 1)))
        for i in righe.values():
            cs = i.pop("_curr")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": f"{arch}?idcorso={cid}&annoregolamento={anno}", "curricula": sorted(curricula) or None,
                "fonte": f"{arch}?idcorso={cid}", "verificato_il": oggi, "insegnamenti": list(righe.values())}

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
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(jobs) if syllabus else 0}")

    def scheda(url: str) -> int:
        try:
            r = c.get(url)
            if not r:
                return 0
            sc = leggi_scheda(r.text)
            for it in jobs[url]:
                for k in ("codice", "obbligatorio", "ssd"):
                    if sc[k] is not None:
                        it[k] = sc[k]
                it["docenti"] = sc["docenti"]
                it["libri"] = sc["libri"]
                it["stato_libri"] = "completo" if sc["libri"] else "da_aggiungere"
            return len(sc["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
        mutuati = condividi_programmi(out)
        log(f"[{uid}] programmi condivisi tra insegnamenti con lo stesso codice: {mutuati}")
        prec = programmi_anno_precedente(out, c, log)
        log(f"[{uid}] insegnamenti con i testi del programma dell'a.a. precedente: {prec}")
    for corso in out:
        for i in corso["insegnamenti"]:
            i.pop("_prev", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unipg.it, offerta formativa (adapters/unipg.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def programmi_anno_precedente(corsi: list[dict], c, log=print) -> int:
    """Insegnamenti senza testi nel programma 2026/27: si usano quelli della scheda dello stesso
    insegnamento nel piano della coorte precedente (a.a. 2025/26), indicandolo nella nota di ogni libro."""
    da_fare = [(i, i["_prev"]) for corso in corsi for i in corso["insegnamenti"] if not i.get("libri") and i.get("_prev")]
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
