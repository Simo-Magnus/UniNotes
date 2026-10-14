"""Insegnamenti, docenti e libri dell'Università di Catania dai siti dei dipartimenti.

UniCT non usa il Course Catalogue Cineca. Ogni corso ha una pagina sul sito del suo
dipartimento (`www.<dip>.unict.it/corsi/<classe>`), con:

- `…/programmi` → didattica erogata nell'a.a. corrente divisa per "1° anno", "2° anno", …;
  una riga per canale e modulo: "<codice> - <NOME> <canale>", modulo, docente, con il
  link al syllabus (`…/insegnamenti?seuid=…`);
- syllabus → "Testi di riferimento".

Le righe dello stesso insegnamento (canali e moduli) diventano un solo insegnamento con
tutti i docenti e tutti i testi. L'elenco non dice CFU, periodo e obbligatorietà: restano null.
I corsi sono quelli già presenti in database/corsi/unict.json (da Universitaly), con il
loro `id`: build_db.py li associa senza ambiguità.
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


def _sito(url: str | None) -> str | None:
    m = re.match(r"https?://((?:www|web)\.[\w-]+\.unict\.it)/(?:it/)?(?:corsi|courses)/([\w-]+)", (url or "").strip())
    return f"https://{m.group(1)}/corsi/{m.group(2)}" if m else None


def leggi_programmi(s: str) -> list[dict]:
    m = re.search(r"<tbody[^>]*>(.*?)</tbody>", s, re.S)
    # colonne: "Insegnamento, Modulo, Docente" oppure solo "Insegnamento, Docente"
    intest = [_testo(h).lower() for h in re.findall(r"<th[^>]*>(.*?)</th>", s.split("<tbody", 1)[0][-2000:], re.S)]
    i_mod = next((k for k, h in enumerate(intest) if h.startswith(("modul", "module"))), None)
    i_doc = next((k for k, h in enumerate(intest) if h.startswith(("docent", "teacher", "lecturer"))), None)
    anno, out = None, []
    for tr in re.findall(r"<tr>(.*?)</tr>", m.group(1) if m else "", re.S):
        sez = re.search(r'class="table-active"[^>]*>(.*?)</td>', tr, re.S)
        if sez:
            n = re.match(r"\s*(\d)", _testo(sez.group(1)))
            anno = int(n.group(1)) if n else None
            continue
        td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if not td:
            continue
        link = re.search(r'href="([^"]+)"', td[0])
        t = _testo(td[0])
        n = re.match(r"(\w+)\s*-\s*(.*?)(?:\s+(\d{1,2}))?$", t)
        codice, nome = (n.group(1), n.group(2)) if n else (None, t)
        nome = re.sub(r"\s+[A-Za-z]{1,2}\s*-\s*[A-Za-z]{1,2}$", "", nome)  # canale per iniziali: "A - E"
        out.append({
            "anno": anno, "codice": codice, "nome": _titolo(nome),
            "modulo": _titolo(_testo(td[i_mod])) if i_mod is not None and i_mod < len(td) and _testo(td[i_mod])
            else None,
            "docenti": [_titolo(_testo(x)) for x in re.split(r"<br\s*/?>|,|</a>", td[i_doc]) if _testo(x)]
            if i_doc is not None and i_doc < len(td) else [],
            "url": html.unescape(link.group(1)) if link else None,
        })
    return out


def libri_syllabus(s: str) -> list[dict]:
    m = re.search(r"<h2[^>]*>\s*(?:Testi di riferimento|Textbooks?(?: and reference)?[^<]*)\s*</h2>(.*?)<h2", s, re.S | re.I)
    if not m:
        return []
    t = re.sub(r"<!--\[if.*?<!\[endif\]-->", "", m.group(1), flags=re.S)
    t = re.sub(r"<!--.*?-->", "", t, flags=re.S)
    # tabelle "Autore | Titolo | Editore | Anno | ISBN": una riga = un riferimento
    t = re.sub(r"</t[dh]>\s*<t[dh][^>]*>", ", ", t)
    return estrai_libri(t)


def fetch_ateneo(uid: str = "unict", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _sito(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con pagina sul sito del dipartimento")
    c = Client()
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        sito = _sito(corso["url"])
        r = c.get(f"{sito}/programmi")
        if not r:
            return None
        base = re.match(r"https?://[^/]+", r.url).group(0)
        righe: dict[str, dict] = {}
        for x in leggi_programmi(r.text):
            key = f"{x['anno']}:{x['codice'] or x['nome']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": None,
                    "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": [],
                    "url": None, "libri": [], "esami": [], "fonte": r.url, "verificato_il": oggi, "_syl": [],
                }
            item["docenti"] = sorted(set(item["docenti"]) | {d for d in x["docenti"] if d})
            if x["url"]:
                u = x["url"] if x["url"].startswith("http") else base + x["url"]
                item["url"] = item["url"] or u
                item["_syl"].append(u)
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": sito, "fonte": r.url, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    urls = sorted({u for x in out for i in x["insegnamenti"] for u in i["_syl"]})
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"syllabus da leggere: {len(urls) if syllabus else 0}")
    libri_url: dict[str, list[dict]] = {}

    def leggi(u: str) -> None:
        try:
            r = c.get(u)
            libri_url[u] = libri_syllabus(r.text) if r else []
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            libri_url[u] = []

    if syllabus:
        with cf.ThreadPoolExecutor(6) as ex:
            for n, _ in enumerate(ex.map(leggi, urls), 1):
                if n % 1000 == 0:
                    log(f"[{uid}]   syllabus {n}/{len(urls)}")
    trovati = 0
    for x in out:
        for i in x["insegnamenti"]:
            viste = set()
            for u in i.pop("_syl"):
                for lb in libri_url.get(u, []):
                    k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                    if k not in viste:
                        viste.add(k)
                        i["libri"].append(lb)
            if syllabus:
                i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
            trovati += len(i["libri"])
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dai siti dei dipartimenti *.unict.it (adapters/unict.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
