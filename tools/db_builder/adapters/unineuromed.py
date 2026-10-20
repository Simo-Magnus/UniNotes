"""Insegnamenti dell'Università Neuromed da unineuromed.it.

Le pagine dei corsi (`/corsi-di-laurea/<corso>/`, prima `/didattica/<corso>/`) hanno il piano di studi in
tabelle `table--pds`, una per anno (didascalia «… — Primo anno» o «… — 1° anno (a.a. 2026/2027)»). Tre forme:

- Scienza dei Materiali: colonne Semestre, insegnamento, modulo, SSD, TAF, CFU. Un insegnamento con più moduli
  occupa più righe (la prima ha il nome, le altre solo il modulo, ognuna con i propri CFU): i CFU
  dell'insegnamento sono la somma dei moduli (Fisica 6+6, Scienza dei Materiali 6+6, Impresa e Sicurezza 4+2).
  Tabella «Insegnamenti a scelta» (anno, semestre, …): le opzioni di libera scelta. I segnaposto «Un insegnamento
  a libera scelta» / «Due insegnamenti a libera scelta» del 2° e 3° anno si sostituiscono con le opzioni della
  tabella di quell'anno, a scelta.
- Medicine and Surgery: piano della coorte 2026/27 con colonne Sem., insegnamento/modulo, SSD, CFU, Verifica,
  area, attività, ambito. Gli insegnamenti hanno il semestre o la verifica (esame/idoneità); i moduli (CFU già
  contenuti nell'insegnamento) non hanno né l'uno né l'altra. La riga «Totale» di ogni anno si usa solo per controllo.
  AFASS (*) = attività formative a scelta dello studente, TPVES (**) = tirocinio pratico valutativo per
  l'esame di stato: le note sono sotto la tabella di riepilogo.
- Scienze cognitive e studi sulla mente (LM-55): colonne insegnamento, CFU, SSD, TAF, con righe-fascia
  «I Semestre» / «II Semestre»; il 2° anno ha una tabella per curriculum («… — Curriculum 1 - Nome»).
  Le righe uguali in tutti i curricula valgono per tutti.

Niente docenti né libri sulle pagine pubbliche.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://unineuromed.it"
ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
ROMANI = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
SEM = {"I": "1", "II": "2"}


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def _nome(s: str) -> str:
    """Nome in maiuscolo -> iniziale maiuscola; nei nomi misti le parole tutte maiuscole lunghe (BIOMATERIALI) idem."""
    s = html.unescape(_testo(s)).strip()
    s = re.sub(r"\s*\((?:\*+)\)\s*$", "", s)  # nota (*) / (**)
    if s.isupper():
        return _titolo(s)
    return " ".join(w[:1] + w[1:].lower() if len(w) > 5 and w.isupper() else w for w in s.split())


def _num(s: str):
    m = re.search(r"\d+(?:[.,]\d+)?", s or "")
    if not m:
        return None
    v = float(m.group(0).replace(",", "."))
    return int(v) if v.is_integer() else v


def _ssd(s: str) -> str | None:
    m = re.match(r"[A-Z]{2,5}-\d{2}/[A-Z]", (s or "").strip())
    return m.group(0) if m else None


def _righe(corpo: str):
    """Righe del corpo di una tabella: (classe della riga, th, [td...]) con `th` = (classe, testo) e td = (classe, testo)."""
    for r in re.findall(r"<tr([^>]*)>(.*?)</tr>", re.sub(r"<thead.*?</thead>", "", corpo, flags=re.S), re.S):
        ths = [(re.search(r'class="([^"]*)"', a).group(1) if re.search(r'class="([^"]*)"', a) else "", _testo(v))
               for a, v in re.findall(r"<th([^>]*)>(.*?)</th>", r[1], re.S)]
        tds = [(re.search(r'class="([^"]*)"', a).group(1) if re.search(r'class="([^"]*)"', a) else "", _testo(v))
               for a, v in re.findall(r"<td([^>]*)>(.*?)</td>", r[1], re.S)]
        yield r[0], ths, tds


def _tabelle(s: str):
    for cap, corpo in re.findall(r"<caption[^>]*>(.*?)</caption>(.*?)</table>", s, re.S):
        head = re.search(r"<thead.*?</thead>", corpo, re.S)
        yield _testo(cap), _testo(head.group(0)) if head else "", corpo


def _anno_cap(cap: str):
    a = re.search(r"(\d)\s*°\s*anno|\b(primo|secondo|terzo|quarto|quinto|sesto)\s+anno", cap, re.I)
    if not a:
        return None
    return int(a.group(1)) if a.group(1) else ANNI[a.group(2).lower()]


def _riga(anno, nome, cfu, ssd, periodo, scelta=False, curriculum=None, note=None):
    return {"anno": anno, "nome": nome, "cfu": cfu, "ssd": ssd, "periodo": periodo, "a_scelta": scelta,
            "curriculum": curriculum, "note": note}


def _tabella_moduli(cap: str, corpo: str, anno, scelte: bool) -> list[dict]:
    """Scienza dei Materiali: righe con nome + righe dei moduli (CFU da sommare)."""
    out: list[dict] = []
    cur = None
    for _, ths, tds in _righe(corpo):
        nome = next((t for c, t in ths if "pds__nome" in c), "")
        sem = [t for c, t in tds if "pds__sem" in c]
        codici = [t for c, t in tds if "pds__code" in c]
        cfu = next((_num(t) for c, t in tds if "pds__cfu" in c), None)
        mod = next((t for c, t in ths + tds if "pds__mod" in c), "")
        if nome:
            a = anno
            if scelte:
                a = ROMANI.get(sem[0].upper()) if sem else None
            cur = _riga(a, _nome(nome), cfu, _ssd(codici[0]) if codici else None,
                        SEM.get((sem[-1] if sem else "").upper()), scelte)
            cur["moduli"] = [mod] if mod else []
            out.append(cur)
        elif cur is not None and cfu is not None:  # modulo successivo: i CFU si sommano
            cur["cfu"] = (cur["cfu"] or 0) + cfu
            if mod:
                cur["moduli"].append(mod)
            if not cur["ssd"] and codici:
                cur["ssd"] = _ssd(codici[0])
    # insegnamenti omonimi nello stesso anno (Caratterizzazione dei Materiali ×2): il nome del primo modulo li distingue
    per_nome: dict[tuple, list[dict]] = {}
    for r in out:
        per_nome.setdefault((r["anno"], r["nome"].lower()), []).append(r)
    for rs in per_nome.values():
        if len(rs) > 1:
            for r in rs:
                m = re.sub(r"(?i)^modulo\s+", "", r["moduli"][0]) if r["moduli"] else ""
                if m:
                    r["nome"] = f"{r['nome']} - {_nome(m)}"
                    r["note"] = "omonimo nello stesso anno: nome distinto dal primo modulo"
    return out


def _tabella_medicina(corpo: str, anno: int) -> tuple[list[dict], float | None]:
    out: list[dict] = []
    cur = None
    tot = None
    for _, ths, tds in _righe(corpo):
        nome = next((t for c, t in ths if "pds__nome" in c), "")
        if not nome and len(tds) >= 4 and "pds__nome" in tds[1][0]:  # modulo: il nome è in una cella (th assente)
            if cur is not None and _ssd(tds[2][1]):
                cur["ssd_moduli"].add(_ssd(tds[2][1]))
            continue
        if not nome or len(tds) < 4:
            continue
        sem, ssd, cfu, verifica = tds[0][1], tds[1][1], _num(tds[2][1]), tds[3][1]
        if nome.lower() == "totale":
            tot = cfu
            continue
        if sem or verifica:
            n = _nome(nome)
            note = None
            scelta = False
            if re.match(r"(?i)afass\b", nome):
                n, scelta = "AFASS - Attività formative a scelta dello studente", True
                note = "(*) Attività Formative A Scelta dello Studente"
            elif re.match(r"(?i)tpves\b", nome):
                n = "TPVES - Tirocinio pratico valutativo per l'esame di stato"
                note = "(**) Tirocinio Pratico Valutativo per Esame di Stato"
            cur = _riga(anno, n, cfu, _ssd(ssd), SEM.get(sem.upper()), scelta, None, note)
            cur["ssd_moduli"] = set()
            out.append(cur)
    for r in out:
        sm = r.pop("ssd_moduli", set())
        if not r["ssd"] and len(sm) == 1:
            r["ssd"] = next(iter(sm))
    return out, tot


def _tabella_magistrale(corpo: str, anno: int, curriculum: str | None) -> tuple[list[dict], float | None]:
    out: list[dict] = []
    periodo = None
    tot = None
    for cls, ths, tds in _righe(corpo):
        if "pds__banda" in cls:
            m = re.match(r"(?i)(I|II)\s+semestre", ths[0][1] if ths else "")
            periodo = SEM.get(m.group(1).upper()) if m else None
            continue
        nome = next((t for c, t in ths if "pds__nome" in c), "")
        if not nome:
            continue
        cfu = next((_num(t) for c, t in tds if "pds__cfu" in c), None)
        codici = [t for c, t in tds if "pds__code" in c]
        if re.match(r"(?i)tot\b", nome):
            if re.search(r"(?i)anno", nome):
                tot = cfu
            continue
        n = _nome(nome)
        out.append(_riga(anno, n, cfu, _ssd(codici[0]) if codici else None, periodo,
                         bool(re.search(r"(?i)\ba scelta\b", n)), curriculum))
    return out, tot


def leggi_piano(s: str, log=print) -> list[dict]:
    """Righe del piano di una pagina corso (anno, nome, periodo, ssd, cfu, a_scelta, curriculum)."""
    righe: list[dict] = []
    opzioni: list[dict] = []
    for cap, head, corpo in _tabelle(s):
        if re.search(r"(?i)riepilogo", cap):
            continue
        if "Verifica" in head:  # Medicine and Surgery
            a = _anno_cap(cap)
            if not a:
                continue
            rr, tot = _tabella_medicina(corpo, a)
            somma = sum(r["cfu"] or 0 for r in rr)
            if tot is not None and somma != tot:
                log(f"  [avviso] {cap}: somma {somma} ≠ Totale {tot}")
            righe += rr
        elif "Semestre" in head and "Anno" in head:  # opzioni di libera scelta
            opzioni += _tabella_moduli(cap, corpo, None, True)
        elif "Semestre" in head or "Sem." in head:
            a = _anno_cap(cap)
            if a:
                righe += _tabella_moduli(cap, corpo, a, False)
        else:  # magistrale: pds__banda per semestre, curricula nella didascalia
            a = _anno_cap(cap)
            if not a:
                continue
            m = re.search(r"(?i)curriculum\s*\d*\s*[-–:]?\s*(.+)$", cap)
            cur = re.sub(r"\s+", " ", m.group(1)).strip() if m else None
            rr, tot = _tabella_magistrale(corpo, a, cur)
            somma = sum(r["cfu"] or 0 for r in rr)
            if tot is not None and somma != tot:
                log(f"  [avviso] {cap}: somma {somma} ≠ Tot CFU {tot}")
            righe += rr
    # segnaposto «a libera scelta» -> opzioni della tabella delle scelte nell'anno del segnaposto
    anni_con_opzioni = {o["anno"] for o in opzioni if o["anno"]}
    righe = [r for r in righe if not (re.search(r"(?i)libera scelta", r["nome"]) and r["anno"] in anni_con_opzioni)]
    righe += [o for o in opzioni if o["anno"]]
    # righe uguali in tutti i curricula del corso valgono per tutti
    curricula = sorted({r["curriculum"] for r in righe if r["curriculum"]})
    if len(curricula) > 1:
        nuove = []
        viste = set()
        for r in righe:
            if not r["curriculum"]:
                nuove.append(r)
                continue
            k = (r["anno"], r["nome"], r["cfu"], r["periodo"])
            cs = {x["curriculum"] for x in righe if (x["anno"], x["nome"], x["cfu"], x["periodo"]) == k and x["curriculum"]}
            if cs >= set(curricula):
                if k not in viste:
                    viste.add(k)
                    nuove.append({**r, "curriculum": None})
            else:
                nuove.append(r)
        righe = nuove
    return righe, curricula


def _pagina(c: Client, corso: dict, home_links: dict[str, str]):
    cand = []
    u = corso.get("url") or ""
    if "unineuromed.it/" in u:
        cand.append(u.replace("/didattica/", "/corsi-di-laurea/").rstrip("/") + "/")
    s = _slug(corso["nome"])
    cand.append(home_links.get(s) or f"{BASE}/corsi-di-laurea/{s}/")
    for u in cand:
        r = c.get(u)
        if r and "table--pds" in r.text:
            return r.url if getattr(r, "url", None) else u, r.text
    return None, None


def fetch_ateneo(uid: str = "unineuromed", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    home = c.get(BASE + "/")
    links = {}
    for h in re.findall(r'href="(/corsi-di-laurea/([^/"#]+)/)"', home.text if home else ""):
        links[h[1]] = BASE + h[0]
    out = []
    for corso in corsi:
        if not corso.get("id_universitaly") and not corso.get("url"):
            continue
        u, testo = _pagina(c, corso, links)
        if not u:
            continue
        voci, curricula = leggi_piano(testo, log)
        if not voci:
            continue
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": u, "curricula": curricula or None, "fonte": u,
                    "verificato_il": oggi,
                    "insegnamenti": [{"codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": v["periodo"],
                                      "cfu": v["cfu"], "ssd": v["ssd"],
                                      "obbligatorio": not v["a_scelta"], "curriculum": v["curriculum"],
                                      "docenti": [], "url": u, "libri": [], "esami": [], "fonte": u,
                                      "verificato_il": oggi, "stato_libri": "da_aggiungere"} for v in voci]})
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti")
    return {"universita_id": uid, "descrizione": "Generato da unineuromed.it, piani di studio (adapters/unineuromed.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
