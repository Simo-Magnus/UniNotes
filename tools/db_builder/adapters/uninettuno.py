"""Insegnamenti, docenti e libri dell'Università Telematica Internazionale UNINETTUNO.

- `www.uninettunouniversity.net/it/offertaformativa.aspx` → pagine dei corsi; la pagina di un corso
  rimanda ai suoi indirizzi (`…aspx?faculty=…&degree=<id>&idIndirizzo=<id>&mode=cs`);
- pagina del piano → "Piano degli Studi (A.A. 2026/2027)", titolo "<corso> (Anno Accademico …) -
  <indirizzo>" e tabelle "Primo anno", "Secondo anno", …: insegnamento (link al programma), settore,
  CFU, lingua (una riga per lingua: italiano e inglese hanno gli stessi CFU), docenti delle videolezioni
  (spesso di altri atenei) e docente/tutor dell'insegnamento (quello che si mette in `docenti`).
  Sotto ogni anno «Numero di CFU riservati ai moduli a scelta: N» → riga «A scelta dello studente»
  (a scelta, N CFU) in quell'anno; la tabella «Esami suggeriti» elenca esami consigliati per la scelta
  e non si legge come piano;
- programma (`cyberspaziomateria.aspx?courseid=…`) → sezione "Testi".

Casi del sito: «Laboratori 4 CFU» è seguito dai laboratori tra cui scegliere, senza CFU (alternative del gruppo,
non righe); «Prova finale» o «Altre attività» con CFU «-» in un indirizzo prendono i CFU della stessa riga nello
stesso anno di un altro indirizzo del corso (il corso ha una sola regola; è una deduzione dichiarata nel log);
«X» e «X nuova edizione» sono la stessa materia (una riga); le «Insegnamenti a libera scelta» del piano non si
sommano ai «CFU riservati ai moduli a scelta» dello stesso anno; indirizzi con lo stesso insegnamento a CFU
diversi: il nome porta «(N CFU)»; id che collidono dopo il troncamento a 40 caratteri (build_db): codice =
id dell'insegnamento nel sito. Percorsi che non sono lauree (MOOC, BIM, master, 292) non si leggono.

La riga di un insegnamento è nel formato `<td rowspan="N">nome</td><td rowspan="N"><center>CFU</center></td>`
seguita dalle righe delle lingue: il `</tr>` della riga compare prima dell'ultimo `</td>`, quindi si legge
per celle e non per righe `<tr>`. «(Ed. maggio 2024)» nel titolo è l'edizione dei contenuti, non fa parte
del nome. Una pagina che il sito sostituisce con la sfida del WAF (HTTP 202 a corpo vuoto) non è un
piano: si riprova più tardi con pause crescenti, senza aggirare la sfida.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import html
import json
import os
import pathlib
import re
import threading
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.uninettunouniversity.net"
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
RIGA = re.compile(r'<td[^>]*rowspan="\d+"[^>]*>\s*(.*?)\s*</td>\s*<td[^>]*rowspan="\d+"[^>]*>\s*<center>(.*?)</center>\s*</td>', re.S)
EDIZIONE = re.compile(r"(?i)(?:\s*\((?:ed\.|edizione|nuova edizione)[^)]*\))+\s*$")
CONTENITORE = re.compile(r"(?i)^laboratori$")
NOME_SCELTA = "A scelta dello studente"
SCELTA = re.compile(r"(?i)\bscelta\b")  # «Insegnamenti a libera scelta», «Esami a scelta dello studente»


def _href(s: str) -> str:
    """Indirizzo di un link: decodifica le entità ma non la «&» nuda dei parametri. html.unescape da sola
    trasforma «&degree=239» in «°ree=239» (entità «&deg» senza punto e virgola): il link del programma
    finiva sulla pagina generica e i libri non si trovavano mai."""
    return html.unescape(re.sub(r"&(?!(?:amp|quot|apos|lt|gt|#\d+|#x[0-9a-fA-F]+);)", "&amp;", s))


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class Sito(Client):
    """Client che non tiene in cache le risposte vuote o di sfida del WAF e le riprova con pause crescenti.
    Il WAF del sito risponde con la sfida (HTTP 202 vuoto) dopo pochi accessi ravvicinati dallo stesso indirizzo:
    con UN_HTTP_CACHE (cartella) le pagine già lette non si richiedono più, con UN_SOLO_CACHE=1 non si richiede
    nient'altro."""

    PAUSE = (20, 60, 120, 240)
    # con UN_INTERVALLO=<secondi> le richieste vere partono a ritmo costante, una per intervallo (anche tra
    # thread diversi), poco sotto il limite del WAF: meno risposte di sfida e meno pagine abbandonate
    _ritmo = threading.Lock()
    _ultima = 0.0

    def _get(self, url: str):
        intervallo = float(os.environ.get("UN_INTERVALLO") or 0)
        pause = (0,) + (self.PAUSE if not intervallo else (0,) * 5)
        for pausa in pause:
            if pausa:
                time.sleep(pausa)
            if intervallo:
                with Sito._ritmo:
                    attesa = intervallo - (time.time() - Sito._ultima)
                    if attesa > 0:
                        time.sleep(attesa)
                    Sito._ultima = time.time()
            r = super()._get(url)
            if r is None:
                return None
            if r.status_code == 200 and r.text.strip():
                return r
        return None

    def get(self, url: str):
        if self.cache:
            key = hashlib.sha1((url + "|" + json.dumps(sorted(self.s.headers.items()))).encode()).hexdigest()
            f = self.cache / key[:2] / f"{key}.json"
            if f.exists():
                d = json.loads(f.read_text(encoding="utf-8"))
                if d["ok"]:
                    return type("Cached", (), {"url": d["url"], "text": d["text"], "status_code": 200})()
            if os.environ.get("UN_SOLO_CACHE"):  # il sito limita le richieste: pagine non ancora in cache = non lette
                return None
            r = self._get(url)
            if r is not None:
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(json.dumps({"ok": True, "url": r.url, "text": r.text}), encoding="utf-8")
            return r
        return self._get(url)


def leggi_piano(s: str) -> tuple[str | None, str | None, list[dict], dict[int, int]]:
    """(corso, indirizzo, insegnamenti, CFU a scelta per anno) dalla pagina del piano."""
    h1 = re.search(r"<h1[^>]*>(.*?)</h1>", s, re.S)
    t = html.unescape(_testo(h1.group(1))) if h1 else ""
    m = re.match(r"(.*?)\s*\(Anno Accademico [^)]*\)\s*(?:-\s*(.*))?$", t)
    corso, indirizzo = (m.group(1), m.group(2)) if m else (t or None, None)
    if corso:  # «Scienze e Tecnologie della Mente (In corso di attivazione)»
        corso = re.sub(r"(?i)\s*\((?:in corso di attivazione|richiesta di accreditamento[^)]*)\)", "", corso).strip()
    out: list[dict] = []
    scelta: dict[int, int] = {}
    sezioni = list(re.finditer(r"<h3[^>]*>\s*(\w+) anno\s*</h3>", s, re.I))
    for n, sm in enumerate(sezioni):
        k = ANNI.get(sm.group(1).lower())
        if not k:
            continue
        corpo = s[sm.end(): sezioni[n + 1].start() if n + 1 < len(sezioni) else len(s)]
        sc = re.search(r"riservati ai moduli a scelta:\s*(\d+)", corpo)
        if sc and int(sc.group(1)) > 0:
            scelta[k] = int(sc.group(1))
        righe = list(RIGA.finditer(corpo))
        contenitore = None
        for j, mm in enumerate(righe):
            resto = corpo[mm.end(): righe[j + 1].start() if j + 1 < len(righe) else len(corpo)]
            nome = re.search(r"<span title='.*?'\s+area='[^']*'\s*>(.*?)</span>", mm.group(1), re.S)
            link = re.search(r"href='([^']*cyberspaziomateria\.aspx[^']*)'", mm.group(1))
            ssd = re.search(r"Settore:\s*([A-Z]{2,5}-\d{2}/[A-Z]|[A-Z-]+/\d{2})", _testo(mm.group(1)))
            cfu = re.search(r"\d+(?:[.,]\d+)?", _testo(mm.group(2)))
            v = float(cfu.group(0).replace(",", ".")) if cfu else None
            docenti = [_testo(x) for x in re.findall(
                r"cyberspaziopagina(?:materia)?(?:tutor|titolare)\.aspx[^>]*>(.*?)</a>", resto, re.S)]
            testo = _testo(nome.group(1)) if nome else _testo(mm.group(1)).split(" - ")[0]
            riga = {"anno": k, "nome": EDIZIONE.sub("", re.sub(r"\s+", " ", testo)).strip(),
                    "ssd": ssd.group(1) if ssd else None, "cfu": int(v) if v is not None and v.is_integer() else v,
                    "url": _href(link.group(1)) if link else None,
                    "docenti": list(dict.fromkeys(x for x in docenti if x))}
            # «Laboratori 4 CFU» è seguito dai laboratori tra cui scegliere, senza CFU: sono alternative del gruppo
            if riga["cfu"] is None and contenitore is not None:
                contenitore["alternative"].append(riga["nome"])
                continue
            contenitore = {**riga, "alternative": []} if riga["cfu"] and CONTENITORE.search(riga["nome"]) else None
            if contenitore is not None:
                riga["alternative"] = contenitore["alternative"]
            out.append(riga)
    return corso, indirizzo, out, scelta


def unisci_edizioni(voci: list[dict]) -> list[dict]:
    """«X» e «X nuova edizione» nello stesso anno e con lo stesso settore sono la stessa materia in due edizioni
    dei contenuti (lo studente ne sostiene una): una sola riga, con il programma della nuova edizione."""
    base = {(v["anno"], _norm(v["nome"])): v for v in voci}
    out = []
    for v in voci:
        n = _norm(v["nome"])
        if n.endswith(" nuova edizione"):
            vecchia = base.get((v["anno"], n[: -len(" nuova edizione")]))
            if vecchia is not None and vecchia["ssd"] == v["ssd"]:
                vecchia["url"] = v["url"] or vecchia["url"]
                vecchia["docenti"] = list(dict.fromkeys(vecchia["docenti"] + v["docenti"]))
                continue
        out.append(v)
    return out


def leggi_programma(s: str) -> list[dict]:
    m = re.search(r'id="[^"]*_ctesti"[^>]*>(.*?)</span>\s*</td>', s, re.S)
    return estrai_libri(m.group(1)) if m else []


# Percorsi che non sono corsi di laurea: MOOC (209), Professional Course BIM/CDE (271-274), master Media education
# (290), «Il diritto al tempo del Covid» (292)
NON_LAUREE = {"209", "271", "272", "273", "274", "290", "292"}


def _chiave_pagina(h: str) -> tuple[str, str, str]:
    """Un indirizzo è identificato da (corso, indirizzo) qualunque sia l'indirizzo web della pagina (la stessa
    pagina ha più indirizzi con nomi e «faculty» diversi); le pagine senza indirizzo, dal percorso."""
    d = re.search(r"degree=(\d+)", h, re.I)
    i = re.search(r"idindirizzo=(\d*)", h, re.I)
    ind = i.group(1) if i else ""
    return ("" if ind else re.match(r"([^?]*)", h).group(1).lower(), d.group(1) if d else "", ind)


def fetch_ateneo(uid: str = "uninettuno", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Sito(rate=0.5)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(f"{BASE}/it/offertaformativa.aspx")
    trovate = re.findall(r'href="(/it/[^"]+\.aspx\?[^"]*degree=\d+[^"]*)"', r.text if r else "")
    da_leggere: dict[tuple[str, str, str], str] = {}
    for h in sorted({_href(x) for x in trovate}):
        if _chiave_pagina(h)[1] not in NON_LAUREE:
            da_leggere.setdefault(_chiave_pagina(h), h)
    piani: dict[str, list[tuple[str, str | None, list[dict], dict[int, int]]]] = {}
    visti: set[tuple[str, str, str]] = set()
    coda = list(da_leggere.items())
    while coda:
        chiave, p = coda.pop(0)
        if chiave in visti:
            continue
        visti.add(chiave)
        rp = c.get(BASE + p)
        if not rp:
            log(f"[{uid}] pagina non letta: {p}")
            continue
        corso, indirizzo, voci, scelta = leggi_piano(rp.text)
        if corso and voci:
            piani.setdefault(_norm(corso), []).append((BASE + p, indirizzo, voci, scelta))
        # la pagina di un corso rimanda ai piani dei suoi indirizzi (e al «Piano studi» del corso)
        for h in sorted({_href(x).rstrip("&") for x in re.findall(
                r'href="(/it/[^"]+\.aspx\?[^"]*degree=\d+[^"]*mode=cs[^"]*)"', rp.text, re.I)}):
            k = _chiave_pagina(h)
            if k not in visti and k[1] not in NON_LAUREE and k not in dict(coda):
                coda.append((k, h))
    out = []
    for corso in corsi:
        cand = piani.get(_norm(corso["nome"])) or []
        durata = corso.get("durata_anni") or 3
        # stesso nome per triennale e magistrale (Ingegneria gestionale): si tiene il piano con la durata giusta
        cand = [x for x in cand if max(v["anno"] for v in x[2]) <= durata
                and (durata > 2 or max(v["anno"] for v in x[2]) <= 2)]
        if corso.get("tipo") == "L":
            cand = [x for x in cand if max(v["anno"] for v in x[2]) == 3] or cand
        if not cand:
            continue
        indirizzi = sorted({x[1] for x in cand if x[1]})
        cand = [(u, i, unisci_edizioni(vv), sc) for u, i, vv, sc in cand]
        # CFU «-» (prova finale, altre attività): se un altro indirizzo dello stesso corso ha la stessa riga
        # nello stesso anno con CFU, quelli sono i CFU (deduzione dagli altri indirizzi, non scritti in questa pagina)
        cfu_altri: dict[tuple, set] = {}
        for _, _, vv, _ in cand:
            for v in vv:
                if v["cfu"] is not None:
                    cfu_altri.setdefault((v["anno"], _norm(v["nome"])), set()).add(v["cfu"])
        for _, _, vv, _ in cand:
            for v in vv:
                if v["cfu"] is None and len(cfu_altri.get((v["anno"], _norm(v["nome"])), ())) == 1:
                    v["cfu"] = next(iter(cfu_altri[(v["anno"], _norm(v["nome"]))]))
                    log(f"[{uid}] {corso['id']}: «{v['nome']}» anno {v['anno']} senza CFU nella pagina, "
                        f"{v['cfu']} dagli altri indirizzi")
        righe: dict[tuple, dict] = {}
        for url, indirizzo, voci, scelta in cand:
            # i CFU «riservati ai moduli a scelta» di un anno si aggiungono solo se il piano non ha già una riga a scelta
            con_riga = {v["anno"] for v in voci if SCELTA.search(v["nome"])}
            tutte = list(voci) + [{"anno": k, "nome": NOME_SCELTA, "ssd": None, "cfu": n, "url": None, "docenti": []}
                                  for k, n in sorted(scelta.items()) if k not in con_riga]
            for v in tutte:
                key = (v["anno"], _norm(v["nome"]), v["cfu"])
                item = righe.setdefault(key, {
                    "codice": None, "nome": _titolo(v["nome"]), "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": v["ssd"], "obbligatorio": False if SCELTA.search(v["nome"]) else True, "curriculum": None,
                    "docenti": [], "url": v["url"] or url, "libri": [], "esami": [], "fonte": url,
                    "verificato_il": oggi, "stato_libri": "da_aggiungere", "_c": set()})
                item["docenti"] = list(dict.fromkeys(item["docenti"] + v["docenti"]))
                item["_c"].add(indirizzo)
        # stesso nome e anno con CFU diversi tra indirizzi: il nome porta i CFU
        per_nome: dict[tuple, int] = {}
        for (a, n, _), i in righe.items():
            per_nome[(a, n)] = per_nome.get((a, n), 0) + 1
        for (a, n, cfu), i in righe.items():
            if per_nome[(a, n)] > 1 and isinstance(cfu, (int, float)):
                i["nome"] = f"{i['nome']} ({cfu:g} CFU)"
        # build_db tronca lo slug dell'id a 40 caratteri: «Reti Neurali e intelligenza artificiale I» e «… II» nello
        # stesso anno diventerebbero la stessa riga; chi collide prende come codice l'id dell'insegnamento nel sito
        per_id: dict[tuple, list] = {}
        for i in righe.values():
            per_id.setdefault((i["anno"], _norm(i["nome"]).replace(" ", "-")[:40].strip("-")), []).append(i)
        for gruppo in per_id.values():
            if len({_norm(i["nome"]) for i in gruppo}) > 1:
                for i in gruppo:
                    m = re.search(r"courseid=(\d+)", i["url"] or "")
                    if m:
                        i["codice"] = m.group(1)
                if len({i["codice"] for i in gruppo}) < len(gruppo):  # stesso insegnamento con CFU diversi
                    for i in gruppo:
                        i["codice"] = f"{i['codice'] or _norm(re.sub(r' *[(][^)]*CFU[)]$', '', i['nome'])).replace(' ', '-')[:30].strip('-')}-{i['cfu']:g}cfu"
        for i in righe.values():
            cs = i.pop("_c")
            if len(indirizzi) > 1 and None not in cs and cs != set(indirizzi):
                i["curriculum"] = ", ".join(sorted(cs))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": cand[0][0],
                    "curricula": indirizzi if len(indirizzi) > 1 else None, "fonte": cand[0][0],
                    "verificato_il": oggi, "insegnamenti": list(righe.values())})
    items = [i for x in out for i in x["insegnamenti"] if "cyberspaziomateria" in (i["url"] or "")]
    log(f"[{uid}] {len(piani)} corsi sul sito, {len(out)} associati (su {len(corsi)}), "
        f"{sum(len(x['insegnamenti']) for x in out)} insegnamenti")

    def programma(url: str) -> list[dict]:
        rp = c.get(url)
        return leggi_programma(rp.text) if rp else []

    trovati = 0
    if syllabus:
        # una sola richiesta per programma (le righe di più indirizzi hanno lo stesso link)
        urls = sorted({i["url"] for i in items})
        with cf.ThreadPoolExecutor(3) as ex:
            libri = dict(zip(urls, ex.map(programma, urls)))
        for i in items:
            i["libri"] = libri[i["url"]]
            i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
        trovati = sum(len(libri[u]) for u in urls)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.uninettunouniversity.net, piani di studio e "
                                                 "programmi (adapters/uninettuno.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
