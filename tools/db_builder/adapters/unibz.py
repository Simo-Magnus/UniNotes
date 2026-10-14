"""Insegnamenti, docenti e libri della Libera Università di Bolzano da www.unibz.it.

Per ogni corso di studio (pagine in inglese `/en/faculties/<facoltà>/<corso>/`):

- `…/course-offering?academicYear=<a.a.>` ("Course Offering - enrolled from …") → insegnamenti
  offerti nell'a.a.: semestre, nome, CFU, codice, SSD, lingua, docenti e link alla scheda
  `…/study-course-offering/<a.a.>/<id>`;
- `…/study-plan` → anno di corso degli insegnamenti ("1st Year", "2nd Year", …), per nome;
- scheda → "Required readings" (obbligatori) e "Supplementary readings" (consigliati).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata
import urllib.parse

from .testi import estrai_libri, html_to_lines
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unibz.it"
ANNI = {"1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_offerta(s: str) -> list[dict]:
    m = re.search(r"<main", s)
    s = s[m.start():] if m else s
    out = []
    blocchi = re.split(r'<div class="g g-6@md[^"]*">', s)[1:]
    for b in blocchi:
        a = re.search(r'<h2[^>]*>\s*(?:<a href="([^"#]+)"[^>]*>)?(.*?)(?:</a>\s*)?</h2>', b, re.S)
        if not a:
            continue
        sem = re.search(r"Semester\s*(\d)|(Annual|Yearly)", _testo(b[:a.start()]), re.I)
        info = re.search(r'<p class="u-tt-caps u-fw-bold[^"]*"[^>]*>(.*?)</p>', b, re.S)
        campi = [x.strip() for x in _testo(info.group(1)).split("·")] if info else []
        cfu = re.match(r"([\d.,]+)\s*CP", campi[0]) if campi else None
        v = float(cfu.group(1).replace(",", ".")) if cfu else None
        # docenti dell'insegnamento (non dei moduli, elencati sotto i loro titoli h3)
        testa = re.split(r'<div class="u-padd-lft', b)[0]
        docenti = [_testo(d) for d in re.findall(r'/person/[^"]*"[^>]*>\s*<span>(.*?)</span>', testa, re.S)]
        moduli = re.findall(r'/person/[^"]*"[^>]*>\s*<span>(.*?)</span>', b[len(testa):], re.S)
        out.append({
            "url": html.unescape(a.group(1)) if a.group(1) else None, "nome": _testo(a.group(2)),
            "periodo": "annuale" if sem and sem.group(2) else (sem.group(1) if sem else None),
            "cfu": int(v) if v is not None and v.is_integer() else v,
            "codice": campi[1] if len(campi) > 1 else None,
            "ssd": campi[2] if len(campi) > 2 and campi[2] != "NN" else None,
            "lingua": campi[3].lower() if len(campi) > 3 else None,
            "docenti": list(dict.fromkeys(docenti + [_testo(d) for d in moduli])),
        })
    return out


def leggi_piano(s: str) -> dict[str, int]:
    m = re.search(r"<main", s)
    anni, anno = {}, None
    for r in html_to_lines(s[m.start():] if m else s):
        y = re.match(r"(?i)(1st|2nd|3rd|4th|5th)\s+year$", r)
        if y:
            anno = ANNI[y.group(1).lower()]
        elif anno and not re.fullmatch(r"[\d.,]+\s*CP", r):
            anni.setdefault(_norm(re.sub(r"^M-?\d+:?\s*", "", r)), anno)
    return anni


def leggi_scheda(s: str) -> list[dict]:
    libri = []
    for titolo, tipo in (("Required readings", "obbligatorio"), ("Supplementary readings", "consigliato")):
        m = re.search(rf"{titolo}\s*</[^>]+>(.*?)(?=Supplementary readings|Further information|Download as pdf|</main>)",
                      s, re.S)
        for lb in estrai_libri(m.group(1)) if m else []:
            lb["tipo"] = lb.get("tipo") or tipo
            libri.append(lb)
    return libri


def _pagina_en(c: Client, url: str) -> str | None:
    u = re.sub(r"^http://", "https://", url.strip())
    u = re.sub(r"unibz\.it/(?:it|de)/", "unibz.it/en/", u).rstrip("/")
    r = c.get(u)
    return r.url.rstrip("/") if r else None


def fetch_ateneo(uid: str = "unibz", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        pagina = _pagina_en(c, corso.get("url") or "")
        if not pagina:
            return None
        r = c.get(pagina)
        path = urllib.parse.urlparse(pagina).path
        offerte = sorted({h for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text if r else "", re.S)
                          if "course offering" in _testo(t).lower()
                          and urllib.parse.urlparse(h).path.startswith(path)})
        # "enrolled from 2025" e "enrolled before 2025": il secondo copre gli anni successivi
        # degli iscritti con il regolamento precedente
        fonte, voci = None, []
        for o in offerte:
            u = urllib.parse.urljoin(BASE, o) + f"?academicYear={anno}"
            ro = c.get(u)
            nuove = leggi_offerta(ro.text) if ro else []
            if nuove:
                fonte = fonte or u
                voci += [dict(v, fonte=u) for v in nuove]
        if not voci:
            return None
        rp = c.get(pagina + "/study-plan")
        anni = leggi_piano(rp.text) if rp else {}
        ins = {}
        for v in voci:
            key = v["codice"] or v["nome"]
            if key in ins:
                continue
            k = anni.get(_norm(v["nome"]))
            ins[key] = {"codice": v["codice"], "nome": v["nome"], "anno": k,
                        # non nel piano di studi (che elenca gli insegnamenti obbligatori): a scelta
                        "periodo": v["periodo"], "cfu": v["cfu"], "ssd": v["ssd"],
                        "obbligatorio": None if k or len(anni) < 5 else False,
                        "curriculum": None, "docenti": v["docenti"], "url": urllib.parse.urljoin(BASE, v["url"]) if v["url"] else fonte,
                        "libri": [], "esami": [], "fonte": v["fonte"], "verificato_il": oggi}
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": pagina, "curricula": None, "fonte": fonte,
                "verificato_il": oggi, "insegnamenti": list(ins.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {len(items)} insegnamenti, "
        f"anno di corso dal piano per {sum(1 for i in items if i['anno'])}")

    def scheda(i: dict) -> int:
        if "study-course-offering" not in i["url"]:
            i["stato_libri"] = "da_aggiungere"
            return 0
        try:
            r = c.get(i["url"])
            i["libri"] = leggi_scheda(r.text) if r else []
        except Exception:  # noqa: BLE001
            i["libri"] = []
        i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
        return len(i["libri"])

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            trovati = sum(ex.map(scheda, items))
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unibz.it, Course Offering e Study Plan "
                                                 "(adapters/unibz.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
