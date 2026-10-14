"""Insegnamenti, docenti, libri e appelli dell'Università Bocconi.

Fonti pubbliche (`anno` nei parametri = anno in cui finisce l'a.a.: 2027 = a.a. 2026/27):

- `didattica.unibocconi.eu/ts/index.php?ric_ordinamento=N3|R2|R5` → corsi di studio come sigle
  (CLEAM, BIEF, …) con il codice per i filtri (`ric_cdl`);
- `ts/tsn_ric_alf.php?ric_cdl=<codice>` → insegnamenti del corso: codice, nome, CFU, semestre;
- `ts/tsn_anteprima.php?cod_ins=<codice>&ric_cdl=<codice corso>` → scheda per quel corso:
  "(N credits - I sem. - OB | SSD)", docenti delle classi, "Teaching materials";
- `esami/esami_calendario.php?esame=<codice>` → appelli per corso (PI = parziale, S/O = generale);
- piano di studi del corso su www.unibocconi.it (link "Study Plan"/"Piano studi" dalla pagina del
  corso) → anno di corso degli insegnamenti, per nome.

Le sigle non hanno il nome esteso: ogni corso del database si associa alla sigla i cui
insegnamenti coincidono di più con quelli del suo piano di studi.
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

from .testi import estrai_libri
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
TS = "https://didattica.unibocconi.eu/ts/"
ESAMI = "https://didattica.unibocconi.eu/esami/esami_calendario.php?IdPag=106&esame="
SEM = {"I sem.": "1", "II sem.": "2", "I/II sem.": "annuale"}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _parti(nome: str) -> list[str]:
    """"ITALIANO / ENGLISH" o "ITALIANO [ENGLISH]" → nomi normalizzati di entrambe le lingue."""
    m = re.match(r"(.*?)\s*\[(.*)\]\s*$", nome)
    parti = [m.group(1), m.group(2)] if m else nome.split(" / ")
    return [_norm(p) for p in parti if p.strip()]


def leggi_elenco(s: str) -> list[dict]:
    out = []
    for cod, label in re.findall(r'href="tsn_anteprima\.php\?cod_ins=(\d+)[^"]*"[^>]*>\s*<span[^>]*>\d+</span>\s*'
                                 r'<span[^>]*>(.*?)</span>', s, re.S):
        label = html.unescape(_testo(label))
        m = re.match(r"(.*?)\s+-\s+([\d.,]+)\s+cfu\s+-\s+(.*?)\s*$", label)
        nome, cfu, sem = (m.group(1), m.group(2), m.group(3)) if m else (label, None, "")
        v = float(cfu.replace(",", ".")) if cfu else None
        out.append({"codice": cod, "nome": nome.strip(), "cfu": int(v) if v is not None and v.is_integer() else v,
                    "periodo": SEM.get(sem.strip())})
    return out


def leggi_piano(s: str) -> tuple[dict[str, int], set[str]]:
    """Dal piano di studi su www.unibocconi.it: nome normalizzato → anno di corso (dove il piano
    ha semestri e CFU) e tutte le righe della pagina (per riconoscere il corso)."""
    from .testi import html_to_lines
    m = re.search(r"<main", s)
    righe = html_to_lines(s[m.start():] if m else s)
    anni: dict[str, int] = {}
    anno, ultimo_sem = 0, 2
    for i, r in enumerate(righe):
        sm = re.match(r"(?i)(?:semester|semestre)\s*(\d|I{1,2})$|^(\d|I{1,2})\s*[°º]?\s*semestre$", r)
        if sm:
            n = {"I": 1, "II": 2}.get((sm.group(1) or sm.group(2)).upper()) or int(sm.group(1) or sm.group(2))
            if n <= ultimo_sem and n == 1:
                anno += 1
            ultimo_sem = n
            continue
        if anno and i + 1 < len(righe) and re.fullmatch(r"\d{1,2}", righe[i + 1]) and not re.fullmatch(r"\d+", r):
            anni.setdefault(_norm(r), anno)
    return anni, {_norm(r) for r in righe}


def leggi_scheda(s: str, sigla: str) -> dict:
    blocchi = re.split(r'<div style="background-color: #5686CE', s)[1:]
    for b in blocchi:
        intest = _testo(b[:b.find("</div>")])
        m = re.search(rf"\b{re.escape(sigla)}\s*\(([\d.,]+)\s*credits\s*-\s*(.*?)\s*-\s*(\w+)\s*\|\s*([^)]*)\)", intest)
        if not m:
            continue
        docenti = []
        for d in re.findall(r"(?:Class|Classe)\s*\d+\s*:\s*(.*?)(?=,\s*(?:Class|Classe)\s*\d|$)",
                            _testo(re.split(r"Suggested background|Conoscenze pregresse|Mission", b)[0])):
            d = d.strip(" ,")
            if d and d.upper() == d:
                d = " ".join(w.capitalize() for w in d.split())
            if d and d not in docenti:
                docenti.append(d)
        t = re.search(r"(?:Teaching materials|Materiali didattici)(.*?)(?:Scroll to top|Torna su|$)", b, re.S)
        ssd = [x.strip() for x in m.group(4).split("|") if x.strip()]
        return {"tipo": m.group(3), "ssd": ssd[0] if ssd else None, "docenti": docenti,
                "libri": estrai_libri(t.group(1)) if t else []}
    return {"tipo": None, "ssd": None, "docenti": [], "libri": []}


def leggi_esami(s: str, sigla: str, fonte: str) -> list[dict]:
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for r in re.findall(r"<tr.*?</tr>", s, re.S):
        c = [re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", x))).strip()
             for x in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", r, re.S)]
        if len(c) < 7 or c[1] != sigla:
            continue
        d = re.match(r"(\d{2})/(\d{2})/(\d{4})", c[3])
        if not d or f"{d[3]}-{d[2]}-{d[1]}" < oggi:
            continue
        sc = re.match(r"(\d{2})/(\d{2})/(\d{4})", c[6])
        ora = re.match(r"(\d{1,2})[.:](\d{2})", c[4])
        out.append({"tipo": "prova_in_itinere" if c[2] == "PI" else "appello",
                    "data": f"{d[3]}-{d[2]}-{d[1]}", "ora": f"{int(ora[1]):02d}:{ora[2]}" if ora else None,
                    "luogo": None, "modalita": {"S": "scritto", "O": "orale"}.get(c[2]),
                    "iscrizioni_dal": None, "iscrizioni_al": f"{sc[3]}-{sc[2]}-{sc[1]}" if sc else None,
                    "docenti": None, "note": None, "fonte": fonte})
    return out


def _piano_url(c: Client, url: str) -> str | None:
    r = c.get(url)
    if not r:
        return None
    path = urllib.parse.urlparse(r.url).path.rstrip("/")
    cand = {urllib.parse.urlparse(urllib.parse.urljoin(r.url, html.unescape(h))).path.rstrip("/")
            for h, t in re.findall(r'href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S)
            if re.search(r"(?i)study plan|piano (?:di )?stud", _testo(t))}
    # il piano del corso stesso (…/<corso>/study-plan) o, per i corsi rinominati, quello il cui
    # percorso è l'inizio del percorso del corso (economia-aziendale → economia-aziendale-e-management)
    for ok in (lambda b: b == path, lambda b: path.startswith(b) and len(b) > path.rfind("/") + 4):
        scelti = sorted(h for h in cand if ok(h.rsplit("/", 1)[0]))
        if scelti:
            return urllib.parse.urljoin(r.url, scelti[0])
    return None


def fetch_ateneo(uid: str = "unibocconi", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    fine = anno + 1
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    oggi = time.strftime("%Y-%m-%d")
    # sigle dei corsi e insegnamenti di ciascuno
    programmi: dict[str, dict] = {}
    for o in ("N3", "R2", "R5"):
        r = c.get(f"{TS}index.php?IdPag=8227&ric_ordinamento={o}&anno={fine}")
        sel = re.search(r'<select name="ric_cdl".*?</select>', r.text if r else "", re.S)
        for v, t in re.findall(r'<option value="([^"]+)"[^>]*>(.*?)</option>', sel.group(0) if sel else ""):
            sigla = html.unescape(t).strip()
            re_ = c.get(f"{TS}tsn_ric_alf.php?anno={fine}&IdPag=8227&ric_cdl={urllib.parse.quote(v)}")
            ins = leggi_elenco(re_.text) if re_ else []
            if ins:
                programmi[sigla] = {"cdl": v.split("^")[-1], "ins": ins}
    log(f"[{uid}] {len(programmi)} corsi di studio (sigle) con insegnamenti")
    # piani di studio dei corsi del database e associazione alla sigla
    piani = {}
    for corso in corsi:
        u = _piano_url(c, corso.get("url") or "") if corso.get("url") else None
        r = c.get(u) if u else None
        piani[corso["id"]] = (u, *(leggi_piano(r.text) if r else ({}, set())))
    punteggi = []
    for corso in corsi:
        nomi = piani[corso["id"]][2]
        for sigla, p in programmi.items():
            n = sum(1 for i in p["ins"] if any(x in nomi for x in _parti(i["nome"])))
            if n >= 3:
                punteggi.append((n / len(p["ins"]) + n / max(len(nomi), 1), n, corso["id"], sigla))
    abbinati, usati_c, usati_s = {}, set(), set()
    for _, _, cid, sigla in sorted(punteggi, reverse=True):
        if cid not in usati_c and sigla not in usati_s:
            abbinati[cid] = sigla
            usati_c.add(cid)
            usati_s.add(sigla)
    log(f"[{uid}] {len(abbinati)} corsi associati a una sigla (su {len(corsi)}): "
        + ", ".join(f"{s}" for s in sorted(abbinati.values())))
    sel = [x for x in corsi if x["id"] in abbinati]
    if max_cds:
        sel = sel[:max_cds]
    out = []
    for corso in sel:
        sigla = abbinati[corso["id"]]
        p = programmi[sigla]
        piano_url, anni, _ = piani[corso["id"]]
        italiano = (corso.get("lingua") or "it") == "it"
        ins = []
        for i in p["ins"]:
            parti = re.match(r"(.*?)\s*\[(.*)\]\s*$", i["nome"])
            parti = [parti.group(1), parti.group(2)] if parti else i["nome"].split(" / ")
            nome = parti[0] if italiano or len(parti) == 1 else parti[-1]
            k = next((anni[x] for x in _parti(i["nome"]) if x in anni), None)
            fonte = f"{TS}tsn_anteprima.php?cod_ins={i['codice']}&anno={fine}&ric_cdl={p['cdl']}&IdPag=8229"
            ins.append({"codice": i["codice"], "nome": _titolo(nome.strip()), "anno": k, "periodo": i["periodo"],
                        "cfu": i["cfu"], "ssd": None, "obbligatorio": None, "curriculum": None, "docenti": [],
                        "url": fonte, "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi,
                        "_sigla": sigla})
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": corso.get("url"), "curricula": None,
                    "fonte": f"{TS}tsn_ric_alf.php?anno={fine}&IdPag=8227&ric_cdl={urllib.parse.quote(p['cdl'])}",
                    "verificato_il": oggi, "insegnamenti": ins})
    items = [i for x in out for i in x["insegnamenti"]]
    log(f"[{uid}] {len(items)} insegnamenti; anno di corso dal piano per "
        f"{sum(1 for i in items if i['anno'])}")

    def scheda(i: dict) -> int:
        sigla = i.pop("_sigla")
        try:
            r = c.get(i["url"])
            d = leggi_scheda(r.text, sigla) if r else None
            if d:
                i["ssd"] = d["ssd"]
                i["obbligatorio"] = d["tipo"].startswith("OB") if d["tipo"] else None
                i["docenti"] = d["docenti"]
                i["libri"] = d["libri"]
                i["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
            e = c.get(ESAMI + i["codice"])
            i["esami"] = leggi_esami(e.text, sigla, ESAMI + i["codice"]) if e else []
            if i["esami"]:
                i["stato_esami"] = "completo"
            return len(i["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(scheda, items), 1):
                trovati += k
                if n % 300 == 0:
                    log(f"[{uid}]   schede {n}/{len(items)}")
    else:
        for i in items:
            i.pop("_sigla", None)
    log(f"[{uid}] libri trovati: {trovati}, esami: {sum(len(i['esami']) for i in items)}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da didattica.unibocconi.eu e www.unibocconi.it "
                                                 "(adapters/unibocconi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
