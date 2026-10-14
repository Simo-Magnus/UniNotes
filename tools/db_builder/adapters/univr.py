"""Insegnamenti e docenti dell'Università di Verona da www.corsi.univr.it.

Esse3 di UniVR non pubblica l'offerta; il portale dei corsi sì:

- `/?ent=cs&id=<id>&menu=studiare&tab=insegnamenti&erogata=1&aa=<a.a.>` (richiesta con
  `X-Requested-With: XMLHttpRequest`, come fa la pagina) → insegnamenti erogati nell'a.a.
  divisi per periodo (con le date) e anno di iscrizione: nome, TAF, SSD, docenti e codice
  Esse3 dell'attività (`codins`, lo stesso degli appelli);
- dettaglio dell'insegnamento (stessa URL con `codins`) → crediti e moduli.

La bibliografia è su Leganto: il dettaglio ha il link pubblico della lista (`…/leganto/public/
39UVR_INST/lists?courseCode=…`), che si legge senza credenziali se la lista è pubblicata
(adapters/leganto.py); se la lista del 2026/27 non c'è ancora si usa quella degli anni precedenti
(adapters/univr_testi.py). Le attività TAF D (a scelta dello studente) hanno `obbligatorio: false`.

Corsi con più ordinamenti: la pagina del corso nuovo («R», immatricolati dal 2026/27 o dal 2025/26) ha
solo gli anni attivati dal nuovo piano; gli anni successivi sono nella pagina del corso «Immatricolazione
fino a …» (link nell'avviso arancione del piano didattico): si leggono anche quelle e si uniscono per
anno e codice (insegnamenti erogati nel 2026/27 per le coorti precedenti).
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time

from . import leganto, univr_testi
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.corsi.univr.it"
XHR = {"X-Requested-With": "XMLHttpRequest"}


def _id(url: str | None) -> str | None:
    m = re.search(r"(?:corsi|medicina)\.univr\.it/\?ent=cs&id=(\d+)", url or "")
    return m.group(1) if m else None


def _date(s: str) -> str | None:
    m = re.match(r"(\d\d)/(\d\d)/(\d\d)$", s)
    return f"{m.group(1)}/{m.group(2)}/20{m.group(3)}" if m else None


def _periodo(titolo: str) -> str | None:
    t = titolo.lower()
    if "non assegnato" in t:
        return None
    if "annual" in t or ("1°" in t and "2°" in t):
        return "annuale"
    m = re.match(r"\s*(\d)\s*(?:°\s*)?(semestre|trimestre|quadrimestre|ciclo|periodo)", t)
    return m.group(1) if m else (re.sub(r"\s+Dal\s.*$", "", titolo).strip() or None)


def leggi_erogata(s: str) -> list[dict]:
    out = []
    for titolo, corpo in re.findall(r"<caption>(.*?)</caption>(.*?)</table>", s, re.S):
        t = _testo(titolo)
        date = re.search(r"Dal\s+(\d\d/\d\d/\d\d)\s+Al\s+(\d\d/\d\d/\d\d)", t)
        for tr in re.findall(r"<tr>(.*?)</tr>", corpo, re.S):
            td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(td) < 6:
                continue
            link = re.search(r'href="([^"]*codins=([^&"]+)[^"]*)"', td[1])
            anno = re.match(r"\s*(\d)", _testo(td[0]))
            docenti = [] if "non ancora assegnato" in _testo(td[5]).lower() else [
                _testo(re.sub(r"\(.*?\)", "", x)) for x in re.split(r"<br\s*/?>|</a>|</div>", td[5])]
            ssd = [_testo(x) for x in re.findall(r"<span[^>]*>(.*?)</span>", td[3], re.S)]
            out.append({
                "anno": int(anno.group(1)) if anno else None, "nome": _testo(td[1]),
                "codice": html.unescape(link.group(2)) if link else None,
                "url": BASE + "/" + html.unescape(link.group(1)).lstrip("/") if link else None,
                "taf": _testo(td[2]) or None,
                "ssd": next((x for x in reversed(ssd) if re.match(r"[A-Z]{4}-\d", x)), ssd[-1] if ssd else None),
                "docenti": sorted({d for d in docenti if d}),
                "periodo": _periodo(t), "inizio": _date(date.group(1)) if date else None,
                "fine": _date(date.group(2)) if date else None,
            })
    return out


def crediti(s: str) -> float | int | None:
    m = re.search(r"Crediti\s*</[^>]+>\s*<[^>]+>\s*([\d.,]+)", s) or re.search(r"Crediti\s*\|?\s*([\d.,]+)", _testo(s))
    if not m:
        return None
    v = float(m.group(1).replace(",", "."))
    return int(v) if v.is_integer() else v


class Portale(Client):
    """Client del portale: le pagine dei piani didattici vanno chieste senza l'intestazione XHR
    (con XHR rispondono con un errore), le liste degli insegnamenti con."""

    def get(self, url: str, xhr: bool = True):
        if xhr:
            return super().get(url)
        saved = self.s.headers.pop("X-Requested-With", None)
        try:
            return super().get(url)
        finally:
            if saved:
                self.s.headers["X-Requested-With"] = saved


def corsi_precedenti(pagina: str, propri: set[str]) -> list[str]:
    """Id dei corsi «Immatricolazione fino a …» citati nell'avviso arancione del piano didattico."""
    m = re.search(r"#ffa500.*?</div>", pagina or "", re.S)
    ids = re.findall(r'href="/\?ent=cs&(?:amp;)?id=(\d+)&(?:amp;)?menu=studiare&(?:amp;)?tab=Insegnamenti"',
                     m.group(0) if m else "")
    return [i for i in dict.fromkeys(ids) if i not in propri]


def fetch_ateneo(uid: str = "univr", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    aa = f"{anno}/{anno + 1}"
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    corsi = [c for c in corsi if _id(c.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi sul portale www.corsi.univr.it")
    c = Portale(rate=2.0)  # al massimo 2 richieste al secondo
    c.s.headers.update(XHR)
    oggi = time.strftime("%Y-%m-%d")
    propri = {_id(x["url"]) for x in corsi}

    def righe_di(cid: str, righe: dict[str, dict]) -> bool:
        fonte = f"{BASE}/?ent=cs&id={cid}&menu=studiare&tab=insegnamenti&erogata=1&aa={aa}&lang=it"
        r = c.get(fonte)
        if not r:
            return False
        for x in leggi_erogata(r.text):
            if not x["anno"]:
                continue
            key = f"{x['anno']}:{x['codice'] or x['nome']}"
            if key in righe:
                righe[key]["docenti"] = sorted(set(righe[key]["docenti"]) | set(x["docenti"]))
                continue
            righe[key] = {
                "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": x["periodo"],
                "periodo_inizio": x["inizio"], "periodo_fine": x["fine"], "cfu": None, "ssd": x["ssd"],
                "obbligatorio": False if x["taf"] == "D" else None, "curriculum": None,
                "docenti": x["docenti"], "url": x["url"], "libri": [], "esami": [],
                "fonte": fonte, "verificato_il": oggi,
            }
        return True

    def build(corso: dict) -> dict | None:
        cid = _id(corso["url"])
        fonte = f"{BASE}/?ent=cs&id={cid}&menu=studiare&tab=insegnamenti&erogata=1&aa={aa}&lang=it"
        righe: dict[str, dict] = {}
        righe_di(cid, righe)
        # anni successivi del piano: nel corso «Immatricolazione fino a …» (coorti precedenti)
        piano = c.get(f"{BASE}/?ent=cs&id={cid}&menu=studiare&tab=Insegnamenti&lang=it", xhr=False)
        for oid in corsi_precedenti(piano.text if piano else "", propri):
            righe_di(oid, righe)
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                "durata_anni": corso.get("durata_anni"), "url": f"{BASE}/?ent=cs&id={cid}",
                "fonte": fonte, "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    jobs: dict[str, list[dict]] = {}
    sede_di: dict[int, str | None] = {}
    for corso in out:
        m = re.search(r"(?i)replica\s+(\w+)", corso["nome"])
        for i in corso["insegnamenti"]:
            sede_di[id(i)] = m.group(1).upper() if m else None
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"dettagli da leggere: {len(jobs) if syllabus else 0}")
    pagine: dict[str, str] = {}

    def dettaglio(url: str) -> None:
        try:
            r = c.get(url)
            if not r:
                return
            pagine[url] = r.text
            cfu = crediti(r.text)
            for it in jobs[url]:
                it["cfu"] = cfu
        except Exception:  # noqa: BLE001
            pass

    if syllabus:
        with cf.ThreadPoolExecutor(5) as ex:
            for n, _ in enumerate(ex.map(dettaglio, list(jobs)), 1):
                if n % 500 == 0:
                    log(f"[{uid}]   dettagli {n}/{len(jobs)}")
        libri_leganto(out, pagine, sede_di, log, precedente=lambda u, a: (c.get(u.replace("aa=2026/2027", "aa=" + a)) or None))
    log(f"[{uid}] libri (Leganto): {sum(len(i['libri']) for x in out for i in x['insegnamenti'])}; "
        f"richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato da www.corsi.univr.it (adapters/univr.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def libri_leganto(out: list[dict], pagine: dict[str, str], sede_di: dict[int, str | None], log=print,
                  precedente=None) -> None:
    """Libri per ogni insegnamento: lista Leganto del suo corso (2026/27) o, se non pubblicata, la
    lista con lo stesso nome dell'anno più recente; vedi adapters/univr_testi.py."""
    T = univr_testi
    tutti = [i for x in out for i in x["insegnamenti"]]
    # codici Leganto citati dalle pagine, per codice di insegnamento (lo stesso insegnamento in più corsi)
    cod_leg: dict[str, set[str]] = {}
    chi_cita: dict[str, set[str]] = {}
    for i in tutti:
        lc = T.codice_dal_link(pagine.get(i.get("url") or "", ""))
        i["_leg"] = lc
        if lc:
            cod_leg.setdefault(i.get("codice") or i["nome"], set()).add(lc)
            chi_cita.setdefault(lc, set()).add(i.get("codice") or i["nome"])
    # insegnamenti distinti con lo stesso nome (codice e crediti diversi): il nome non basta per
    # scegliere la lista di un anno precedente
    gruppi: dict[str, set] = {}
    for i in tutti:
        gruppi.setdefault(T.norm(T.nome_base(i["nome"])), set()).add((i.get("codice"), i.get("cfu")))
    ambigui = {k for k, v in gruppi.items() if len({f for _, f in v}) > 1 or len({c for c, _ in v}) > 2}
    esito: dict[tuple, tuple] = {}

    def trova(i: dict):
        nome, sede = i["nome"], sede_di.get(id(i))
        libri: list[dict] = []
        ids: list[str] = []
        codici = [i["_leg"]] if i.get("_leg") else []
        codici += sorted(cod_leg.get(i.get("codice") or i["nome"], set()) - set(codici))
        for lc in codici:
            lb, li = T.libri_codice(lc)
            ids += li
            libri += [x for x in lb if x["citazione"] not in {y["citazione"] for y in libri}]
            if libri:
                return libri, "2026/2027", ",".join(ids)
        # bibliografia scritta come testo nella pagina del 2026/27
        libri = T.libri_testo(pagine.get(i.get("url") or "", ""))
        if libri:
            return libri, "2026/2027", None
        if T.norm(T.nome_base(nome)) not in ambigui:
            r = per_nome(i, nome, sede)
            if r[0]:
                return r
        # pagina dell'insegnamento degli anni precedenti: lista Leganto del suo corso o testo
        if precedente and i.get("url") and "aa=2026/2027" in i["url"]:
            for a in ("2025/2026", "2024/2025"):
                r = precedente(i["url"], a)
                t = getattr(r, "text", None) if r else None
                if not t or "Codice insegnamento" not in t:
                    continue
                lc = T.codice_dal_link(t)
                libri, ids = T.libri_codice(lc) if lc else ([], [])
                if libri:
                    return libri, a, ",".join(ids)
                libri = T.libri_testo(t)
                if libri:
                    return libri, a, None
        return [], None, None

    def per_nome(i: dict, nome: str, sede: str | None):
        libri: list[dict] = []
        for a in T.ANNI:
            liste = T.cerca(nome, a)
            if a == T.ANNI[0]:  # 2026/27: le liste di un corso che la pagina di un altro insegnamento già cita non sono sue
                liste = [x for x in liste if not (chi_cita.get(x["ccode"]) and
                                                 (i.get("codice") or i["nome"]) not in chi_cita[x["ccode"]])]
            if not liste:
                continue
            pref = [x for x in liste if x["sede"] == (sede or "VERONA")] or [x for x in liste if x["sede"] == "VERONA"] or liste
            for l in pref:
                libri += [x for x in T.libri_lista(l["id"]) if x["citazione"] not in {y["citazione"] for y in libri}]
            if libri:
                return libri, a, ",".join(l["id"] for l in pref)
        return [], None, None

    def lavora(i: dict) -> None:
        chiave = (i.get("codice") or i["nome"], sede_di.get(id(i)), i.get("_leg"))
        if chiave not in esito:
            try:
                esito[chiave] = trova(i)
            except Exception as e:  # noqa: BLE001
                log(f"[univr]   libri di {i['nome']!r}: {e!r}")
                esito[chiave] = ([], None, None)
        libri, aa_lista, _ = esito[chiave]
        i["libri"] = [dict(b) for b in libri]
        if aa_lista and aa_lista != "2026/2027":
            nota = (f"Dalla bibliografia dell'a.a. {aa_lista.replace('/20', '/')} (Leganto o programma): quella del "
                    f"2026/27 non è ancora pubblicata")
            for b in i["libri"]:
                b["note"] = f"{nota}; {b['note']}" if b.get("note") else nota
        i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"

    with cf.ThreadPoolExecutor(4) as ex:
        for n, _ in enumerate(ex.map(lavora, tutti), 1):
            if n % 250 == 0:
                log(f"[univr]   libri {n}/{len(tutti)}")
    for i in tutti:
        i.pop("_leg", None)
