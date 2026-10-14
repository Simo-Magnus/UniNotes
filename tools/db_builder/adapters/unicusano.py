"""Insegnamenti e docenti dell'Università Niccolò Cusano da www.unicusano.it.

La pagina di ogni corso ha il link "Piano di Studi" (`/<area>/piano-di-studi-…`): per
l'a.a. ("A.A. 2026-2027") una tabella per curriculum ("Curriculum generale classe L-18")
con le righe "PRIMO ANNO", "SECONDO ANNO", … e per ogni esame nome, docenti (link alle
pagine `ricerca.unicusano.it/author/<nome-cognome>/`), SSD 2015, SSD 2024 e CFU.
I programmi degli insegnamenti sono sulla piattaforma e-learning (con accesso): niente libri.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}


def _slug(url: str) -> str | None:
    m = re.search(r"ricerca\.unicusano\.it/author/([a-z0-9-]+)", url)
    return m.group(1) if m else None


def nome_docente(c: Client, slug: str) -> str:
    """Nome dalla pagina del docente (titolo "Nome Cognome – Anagrafica Docenti…"): lo slug
    perde apostrofi e spazi ("marino-damore" è Marino D'Amore)."""
    r = c.get(f"https://ricerca.unicusano.it/author/{slug}/")
    t = re.search(r"<title>(.*?)</title>", r.text if r else "", re.S)
    nome = html.unescape(t.group(1)).split("–")[0].strip() if t else ""
    return nome or " ".join(w.capitalize() for w in slug.split("-"))


def leggi_piano(s: str, anno: int) -> list[dict]:
    """Esami del piano per l'a.a. `anno` (tutte le tabelle della sezione "A.A. anno-anno+1")."""
    # la prima occorrenza dell'a.a. seguita dalla tabella del piano (le altre sono nel menu e nelle schede)
    m = next((x for x in re.finditer(rf"A\.A\.\s*{anno}\s*[-/]\s*{anno + 1}(.*?)(?=A\.A\.\s*\d{{4}}\s*[-/]\s*\d{{4}}"
                                     rf"|<footer|$)", s, re.S) if re.search(r"PRIMO\s+ANNO", x.group(1), re.I)), None)
    if not m:
        return []
    out = []
    for prima, tab in re.findall(r"(.{0,600}?)(<table.*?</table>)", m.group(1), re.S):
        cur = re.search(r"Curriculum\s+([^<]+?)\s*<br", prima)
        curriculum = _testo(cur.group(1)) if cur else None
        k = None
        for riga in re.findall(r"<tr.*?</tr>", tab, re.S):
            a = re.search(r"\b(PRIMO|SECONDO|TERZO|QUARTO|QUINTO|SESTO)\s+ANNO\b", _testo(riga), re.I)
            if a and "<td" not in riga:
                k = ANNI[a.group(1).lower()]
                continue
            celle = re.findall(r"<td[^>]*>(.*?)</td>", riga, re.S)
            if len(celle) < 3 or not k:
                continue
            nome_html = celle[0]
            prima_link = re.split(r"<a\s", nome_html, 1)[0]
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(celle[-1]))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            ssd = _testo(celle[-2]) if len(celle) >= 4 else _testo(celle[1])
            base = {"anno": k, "curriculum": curriculum,
                    "ssd": ssd if re.match(r"[A-Z]{2,5}[-/]", ssd or "") else None,
                    "cfu": int(v) if v is not None and v.is_integer() else v}
            links = re.findall(r'<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>', nome_html, re.S)
            if re.search(r"(?i)alternativa|a scelta tra", _testo(prima_link)):
                # "in alternativa tra loro": un insegnamento a scelta per ogni link
                for h, t in links:
                    if _testo(t):
                        out.append(dict(base, nome=_titolo(_testo(t)), docenti=[x for x in [_slug(h)] if x],
                                        a_scelta=True))
                continue
            nome = re.sub(r"\s*[–-]\s*$", "", _testo(prima_link) or _testo(nome_html)).strip()
            if not nome or re.match(r"(?i)totale", nome):
                continue
            out.append(dict(base, nome=_titolo(html.unescape(nome)),
                            docenti=[x for x in (_slug(h) for h, _ in links) if x],
                            a_scelta=bool(re.search(r"(?i)a scelta|opzional", nome))))
    return out


def fetch_ateneo(uid: str = "unicusano", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [x for x in corsi if "unicusano.it/" in (x.get("url") or "")]
    if max_cds:
        corsi = corsi[:max_cds]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        r = c.get(corso["url"])
        if not r:
            return None
        piani = [h for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S)
                 if "piano-di-studi" in h and "piano di studi" in _testo(t).lower()]
        if not piani:
            return None
        fonte = piani[0]
        rp = c.get(fonte)
        voci = leggi_piano(rp.text, anno) if rp else []
        if not voci:
            return None
        curricula = sorted({v["curriculum"] for v in voci if v["curriculum"]})
        righe: dict[str, dict] = {}
        for v in voci:
            key = f"{v['anno']}:{v['nome'].lower()}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": v["ssd"], "obbligatorio": False if v["a_scelta"] else None, "curriculum": None,
                    "docenti": [], "url": fonte, "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi,
                    "stato_libri": "da_aggiungere", "_c": set(),
                }
            item["docenti"] = sorted(set(item["docenti"]) | set(v["docenti"]))
            item["_c"].add(v["curriculum"])
        for i in righe.values():
            cs = i.pop("_c")
            if len(curricula) > 1 and None not in cs and cs != set(curricula):
                i["curriculum"] = ", ".join(sorted(cs))
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": corso["url"],
                "curricula": curricula if len(curricula) > 1 else None, "fonte": fonte, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    slugs = sorted({d for x in out for i in x["insegnamenti"] for d in i["docenti"]})
    with cf.ThreadPoolExecutor(4) as ex:
        nomi = dict(zip(slugs, ex.map(lambda x: nome_docente(c, x), slugs)))
    for x in out:
        for i in x["insegnamenti"]:
            i["docenti"] = sorted({nomi[d] for d in i["docenti"]})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unicusano.it, Piano di Studi (adapters/unicusano.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
