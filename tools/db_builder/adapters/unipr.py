"""Insegnamenti, docenti e libri dell'Università di Parma da corsi.unipr.it.

Esse3 di UniPR non pubblica l'offerta e i siti `cdl-*.unipr.it` hanno una verifica anti-bot;
il portale `corsi.unipr.it` invece è pubblico:

- `/it/<corso>/insegnamenti-e-piano-degli-studi` → id della vista Drupal "insegnamenti"
  (`view_args`);
- `/it/views/ajax?view_name=insegnamenti&…&filter_anno_immatricolazione=<coorte>` → per la
  coorte: sezioni "Primo anno 2025/2026", "Secondo anno 2026/2027", … divise per periodo, con
  nome, codice Esse3 (lo stesso degli appelli), tipo di attività, CFU, responsabile e moduli.
  Si tiene la sezione dell'a.a. corrente di ogni coorte;
- scheda (`/it/ugov/degreecourse/<id>`) → "Bibliografia".
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

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


def leggi_elenco(s: str, aa: str) -> list[dict]:
    """Insegnamenti delle sezioni "<N> anno <aa>" (con i moduli degli integrati come `moduli`)."""
    out = []
    parti = re.split(r"<button[^>]*>\s*(?:<svg.*?</svg>)?\s*(\w+)\s+(?:anno|year)\s+(\d{4}/\d{4})\s*</button>", s, flags=re.S)
    for i in range(1, len(parti) - 2, 3):
        ordinale, a, corpo = parti[i].lower(), parti[i + 1], parti[i + 2]
        if a != aa or ordinale not in ORD:
            continue
        periodo = None
        for pezzo in re.split(r"(<h4[^>]*>.*?</h4>)", corpo, flags=re.S):
            if pezzo.startswith("<h4"):
                periodo = _periodo(_testo(pezzo))
                continue
            # una voce di primo livello = link alla scheda seguito dal <div> con tipo e CFU
            # (i moduli degli integrati non hanno il <div>)
            voci = re.split(r'(?=<li>\s*<a href="[^"]*/ugov/degreecourse/\d+"><span class="text-uppercase">[^<]*</span>'
                            r'\s*-\s*Cod\.[^<]*</a>\s*<div>)', pezzo)
            for li in voci:
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
                    "nome": _titolo(_testo(testa.group(2))), "codice": testa.group(3).strip(),
                    "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
                    "tipo": _testo(tipo.group(1)).strip(" -") if tipo else None,
                    "docenti": [] if not resp or "NON ASSEGNATO" in resp.group(1).upper()
                    else [" ".join(w.capitalize() if w.isupper() else w for w in _testo(resp.group(1)).split())],
                    "moduli": re.findall(r'<a href="([^"]*/ugov/degreecourse/\d+)"', li)[1:],
                })
    return out


def libri_scheda(s: str) -> list[dict]:
    m = re.search(r">\s*(?:Bibliografia|Bibliography)\s*</h2>(.*?)</article>", s, re.S)
    return estrai_libri(m.group(1)) if m else []


def fetch_ateneo(uid: str = "unipr", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    aa = f"{anno}/{anno + 1}"
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _slug(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi su corsi.unipr.it")
    c = Client(rate=4.0)
    c.s.headers.update({"User-Agent": UA})
    oggi = time.strftime("%Y-%m-%d")

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
        disp, cds, vpath, vbase, dom = vista.groups()
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        for k in range(1, durata + 1):
            coorte = anno - k + 1
            dati = {"view_name": "insegnamenti", "view_display_id": disp, "view_args": cds,
                    "view_path": vpath.replace("\\/", "/"), "view_base_path": vbase, "view_dom_id": dom,
                    "pager_element": "0", "filter_anno_immatricolazione": str(coorte),
                    "anno_immatricolazione": str(coorte), "filter_curriculum": "", "filtered_cds": cds,
                    "_drupal_ajax": "1"}
            frammenti = None
            for tentativo in range(3):
                try:
                    with c.lock:
                        time.sleep(c.min_gap)
                        c.requests += 1
                    ra = c.s.post(f"{BASE}/it/views/ajax?_wrapper_format=drupal_ajax&filter_anno_immatricolazione={coorte}"
                                  f"&anno_immatricolazione={coorte}&filtered_cds={cds}", data=dati,
                                  headers={"X-Requested-With": "XMLHttpRequest"}, timeout=90)
                    frammenti = [x.get("data", "") for x in ra.json() if x.get("command") == "insert"]
                    break
                except Exception:  # noqa: BLE001
                    time.sleep(2 ** tentativo)
            if not frammenti:
                continue
            for x in leggi_elenco("".join(frammenti), aa):
                if x["anno"] != k:
                    continue
                key = f"{k}:{x['codice']}"
                if key in righe:
                    continue
                righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": k, "periodo": x["periodo"], "cfu": x["cfu"],
                    "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": x["docenti"], "url": x["url"],
                    "libri": [], "esami": [], "fonte": pagina, "verificato_il": oggi,
                    "_schede": [x["url"]] + x["moduli"],
                }
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": f"{BASE}/it/{slug}", "fonte": pagina, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    urls = sorted({u for x in out for i in x["insegnamenti"] for u in i["_schede"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede da leggere: {len(urls) if syllabus else 0}")
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
            for u in i.pop("_schede"):
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
