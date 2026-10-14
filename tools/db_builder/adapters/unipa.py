"""Insegnamenti e docenti dell'Università di Palermo da www.unipa.it.

Il Course Catalogue di UniPa è vuoto; i siti dei corsi pubblicano la "Didattica erogata":

- `/dipartimenti/<dip>/cds/<corso><codice>/?pagina=insegnamenti` → "Insegnamenti del primo
  anno (manifesto degli studi 2026/2027)", "… del secondo anno (manifesto … 2025/2026)", …:
  codice (lo stesso di Esse3), nome, CFU, docente, curriculum.

- scheda di trasparenza PDF (`offertaformativa.unipa.it/offweb/schedaTrasparenza?…`) →
  "PERIODO DELLE LEZIONI" e "TESTI CONSIGLIATI" (letti con pypdf, se installato).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unipa.it"
SCHEDA = "https://offertaformativa.unipa.it/offweb/schedaTrasparenza?lingua=ITA&oidCurrInsegnamento="
INTESTAZIONI = (r"(?:PROGRAMMA|OBIETTIVI FORMATIVI|MODALITA'? DI VERIFICA|METODI DIDATTICI|ORARIO DI RICEVIMENTO|"
                r"RISULTATI DI APPRENDIMENTO|PREREQUISITI|MODULO\b|DOCENTE\b)")


def _bundle() -> str:
    """Certificati di certifi + l'intermedio GEANT TLS RSA 1 che offertaformativa.unipa.it non invia
    (i browser lo scaricano dall'AIA, requests no): la verifica TLS resta attiva."""
    import certifi
    import tempfile
    f = pathlib.Path(tempfile.gettempdir()) / "university_notes_unipa_ca.pem"
    if not f.exists():
        certi = [pathlib.Path(certifi.where()), pathlib.Path(__file__).parent / "certs" / "geant_tls_rsa_1.pem"]
        f.write_text("\n".join(p.read_text(encoding="utf-8") for p in certi), encoding="utf-8")
    return str(f)


def leggi_scheda_pdf(data: bytes) -> dict:
    """Periodo e testi consigliati dalla scheda di trasparenza in PDF."""
    try:
        import io
        from pypdf import PdfReader
        testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - pypdf assente o PDF illeggibile
        return {"periodo": None, "libri": []}
    per = re.search(r"PERIODO DELLE LEZIONI\s+(\d)\s*°?\s*semestre", testo, re.I)
    if not per and re.search(r"PERIODO DELLE LEZIONI\s+annual", testo, re.I):
        periodo = "annuale"
    else:
        periodo = per.group(1) if per else None
    libri, viste = [], set()
    for m in re.finditer(r"TESTI CONSIGLIATI\s+(.*?)(?=\n" + INTESTAZIONI + r"|\Z)", testo, re.S):
        blocco = re.sub(r"\s*\n\s*", " ", m.group(1)).strip()
        # un riferimento per riga: si va a capo dopo il punto che chiude anno/ISBN, prima di "Cognome X."
        righe = re.split(r"(?<=[\d)]\.)\s+(?=[A-ZÀ-Ý][\w'’-]+,?\s+(?:[A-Z]\.|[A-ZÀ-Ý][a-zà-ù]+\s+[A-Z]\.))", blocco)
        for lb in estrai_libri("<br>".join(righe)):
            k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
            if k not in viste:
                viste.add(k)
                libri.append(lb)
    return {"periodo": periodo, "libri": libri}


ORD = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _pagina(url: str | None) -> str | None:
    m = re.match(r"https?://(?:www|portale)\.unipa\.it(/dipartimenti/[\w.-]+/cds/[\w.-]+)", (url or "").strip())
    return f"{BASE}{m.group(1)}/" if m else None


def leggi_erogata(s: str) -> list[dict]:
    out = []
    sezioni = re.split(r'<h3 class="title">\s*Insegnamenti del (\w+) anno[^<]*</h3>', s)
    for ordinale, corpo in zip(sezioni[1::2], sezioni[2::2]):
        k = ORD.get(ordinale.lower())
        if not k:
            continue
        for art in re.findall(r'<article class="course-item[^"]*">(.*?)</article>', corpo, re.S):
            col = re.findall(r'<div class="col-md-\d+[^"]*">(.*?)</div>', art, re.S)
            link = re.search(r'<a href="(\?[^"]*pagina=insegnamento[^"]*)">\s*([^<]*?)\s*</a>', art)
            nome = re.search(r'Nome:\s*</span>\s*(?:<a [^>]*>)?\s*([^<]*?)\s*(?:</a>|</div>)', art)
            cod = re.search(r"Codice:\s*</span>\s*(?:<a [^>]*>)?\s*(\w+)", art)
            cfu = re.search(r"CFU:\s*</span>\s*([\d.,]+)", art)
            doc = re.findall(r'Docente:\s*</span>(.*?)</div>', art, re.S)
            curr = re.search(r"Curriculum:\s*</span>\s*([^<]*?)\s*</div>", art)
            if not nome:
                continue
            v = float(cfu.group(1).replace(",", ".")) if cfu else None
            out.append({
                "anno": k, "codice": cod.group(1) if cod else None, "nome": _titolo(html.unescape(nome.group(1))),
                "cfu": int(v) if v is not None and v.is_integer() else v,
                "docenti": [" ".join(w.capitalize() for w in _testo(d).split())
                            for d in re.findall(r"<a [^>]*>(.*?)</a>", doc[0] if doc else "", re.S) if _testo(d)],
                "curriculum": _testo(curr.group(1)) if curr else None,
                "url": html.unescape(link.group(1)) if link else None,
                "id_ins": (re.search(r"idInsegnamento=(\d+)", link.group(1)) or [None, None])[1] if link else None,
            })
    return out


def fetch_ateneo(uid: str = "unipa", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    # corsi con l'URL dell'elenco del dipartimento (`/dipartimenti/<dip>/?pagina=cds`): si cerca il
    # link al corso per nome
    elenchi: dict[str, list[tuple[str, str]]] = {}
    for corso in corsi:
        m = re.match(r"https?://(?:www|portale)\.unipa\.it(/dipartimenti/[\w.-]+)/\?pagina=cds", corso.get("url") or "")
        if _pagina(corso.get("url")) or not m:
            continue
        if m.group(1) not in elenchi:
            r = c.get(f"{BASE}{m.group(1)}/?pagina=cds")
            elenchi[m.group(1)] = re.findall(r'href="([^"]*/cds/[\w.-]+/?)"[^>]*>(.*?)</a>', r.text if r else "", re.S)
        nome = _norm(corso["nome"])
        cand = {h for h, t in elenchi[m.group(1)] if _norm(_testo(t)).endswith(nome) or nome in _norm(_testo(t))}
        if len(cand) == 1:
            h = cand.pop()
            corso["url"] = h if h.startswith("http") else BASE + h
    corsi = [c for c in corsi if _pagina(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con sito su www.unipa.it")
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        base = _pagina(corso["url"])
        url = base + "?pagina=insegnamenti"
        r = c.get(url)
        if not r:
            return None
        righe: dict[str, dict] = {}
        curricula = set()
        for x in leggi_erogata(r.text):
            if x["curriculum"]:
                curricula.add(x["curriculum"])
            key = f"{x['anno']}:{x['codice'] or x['nome']}"
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": [],
                    "url": base + x["url"] if x["url"] else url, "libri": [], "esami": [], "fonte": url,
                    "verificato_il": oggi, "_c": set(), "_pdf": x["id_ins"],
                }
            item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
            item["_c"].add(x["curriculum"])
        for i in righe.values():
            cs = i.pop("_c")
            if len(curricula) > 1 and None not in cs and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": base,
                "curricula": sorted(curricula) if len(curricula) > 1 else None, "fonte": url,
                "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    out = []
    with cf.ThreadPoolExecutor(4) as ex:
        for n, r in enumerate(ex.map(build_safe, corsi), 1):
            if r:
                out.append(r)
            if n % 25 == 0:
                log(f"[{uid}]   corsi {n}/{len(corsi)}")
    jobs: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            pid = i.pop("_pdf", None)
            if pid:
                jobs.setdefault(pid, []).append(i)
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede PDF da leggere: {len(jobs) if syllabus else 0}")

    def scheda(pid: str) -> int:
        try:
            with c.lock:
                time.sleep(c.min_gap)
                c.requests += 1
            r = c.s.get(SCHEDA + pid, timeout=120, verify=_bundle())
            if r.status_code != 200 or not r.content.startswith(b"%PDF"):
                return 0
            d = leggi_scheda_pdf(r.content)
            for it in jobs[pid]:
                it["periodo"] = it["periodo"] or d["periodo"]
                it["libri"] = d["libri"]
                it["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
                it["url_sito"] = SCHEDA + pid
            return len(d["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.unipa.it, Didattica erogata (adapters/unipa.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
