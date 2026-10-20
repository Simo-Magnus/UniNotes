"""Piani di studio di UniPV dal Course Catalogue Cineca (gruppi di scelta, coorti, percorsi).

Il catalogo di Pavia descrive ogni anno come un elenco di gruppi: «Obbligatori», «Scegli un insegnamento»,
«Scegli due insegnamenti», «Scegli 12 crediti (12 CFU)», «12 CFU a libera scelta. È possibile … (12 CFU)» (senza
attività: crediti liberi), «12 CFU a scelta nei due anni (6 CFU)» (6 CFU in questo anno)… L'adattatore comune
(cineca_catalogue) non leggeva le etichette: i crediti liberi andavano persi, le attività dei piani di coorti diverse
si mescolavano (stesso insegnamento con codici diversi, doppioni) e dove la coorte che si iscrive ora non ha ancora il
piano (Dietistica, Logopedia, Fisiopatologia cardiocircolatoria…) l'anno restava vuoto.

- Per l'anno k si legge la coorte degli iscritti all'anno k oggi (anno - k + 1); se manca (corso nuovo o piano non
  ancora pubblicato), non ha l'anno o il suo piano è incompleto, la coorte più vicina con un piano completo, di
  preferenza dello stesso ordinamento (la coorte è nell'`url` di ogni insegnamento). Il catalogo ha solo le coorti dal
  2022: per gli anni 5-6 dei cicli unici si usa la più vicina.
- Obbligatori: i gruppi «Obbligatori» / «Esami obbligatori», i gruppi con una sola attività e quelli in cui si
  sostengono tutte le attività (CFU richiesti uguali alla somma, non più attività di quelle da scegliere). Il resto è
  a scelta (compresi i «consigliati» dei crediti a libera scelta).
- Gruppi senza attività elencate («12 CFU a libera scelta…»): una voce a scelta senza codice con i CFU dell'etichetta
  (il numero iniziale, se l'etichetta ha «(1 CFU)» per errore); con l'anno nel nome se si ripete in anni diversi.
- Attività senza crediti (test, OFA, elenchi dell'Ateneo a 0 CFU) e gruppi «sovrannumerari» non sono insegnamenti.
- Stesso nome, anno e percorso con codici diversi (stesso insegnamento di ordinamenti diversi): una voce sola; con CFU
  diversi il nome porta i CFU.
- Percorsi: «Percorso X», «CHIMICA - Curriculum X»; il piano comune («PERCORSO COMUNE») si somma a quello del
  percorso. I due percorsi di Scienze letterarie (classe 1L e L10) sono percorsi veri.

`RAPPORTO` ha, per corso e anno, la coorte letta e i CFU richiesti dal piano (per i controlli).
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import pathlib
import re
import time
import unicodedata

from . import ammissione, cineca_catalogue
from .unipv_testi import libri_unipv

cc = cineca_catalogue
ROOT = pathlib.Path(__file__).resolve().parents[3]
TIPI = {"L2", "L1", "L", "LM", "LM5", "LM6"}
RAPPORTO: dict = {}

NUMERI = {"un": 1, "uno": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7,
          "otto": 8, "nove": 9, "dieci": 10}
_N = r"(un|uno|una|due|tre|quattro|cinque|sei|sette|otto|nove|dieci|\d+)"
_PAR_CFU = re.compile(r"\(\s*(?:(?:fra|tra)\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_LEAD = re.compile(r"^\s*(?:da\s+[\d.,]+\s+a\s+)?([\d.,]+)\s*(?:CFU|crediti|credits)\b", re.I)
_SCEGLI = [re.compile(rf"\bscegli\s+{_N}\s+insegnament", re.I), re.compile(rf"\b{_N}\s+(?:corsi|insegnamenti|esami)\b", re.I),
           re.compile(rf"\bscegli\s+{_N}\s+(?=\(|$)", re.I), re.compile(rf"\bscegli\s+{_N}\s+(?:esam|materi)", re.I)]
_LIBERA = re.compile(r"(?i)libera scelta|scelta libera|a scelta dello studente|a scelta libera|\ba scelta\b|"
                     r"acquisibili|opzional|^\s*choose|^\s*other activity|attivit[àa] a scelta")
_EXTRA = re.compile(r"(?i)sovrannumer|in sovrannumero")
_OBBL = re.compile(r"(?i)obbligator")
_CC = re.compile(r"(?i)^\s*cc[-\s]*(?=\S)")
_PIANO_COMUNE = re.compile(r"(?i)\bpercorso comune\b|\bcomune\b|\bstatutario\b|\bgenerico\b")
_SCEGLI_COND = re.compile(r"(?i)^se hai scelto")
_SCELTA_SINGOLA = re.compile(r"(?i)^\s*(?:cc[-\s]*)?(?:sottopercorso\s+\w\s*-\s*)?(?:scelta|choose a|prima lingua|seconda lingua)\b")


def _norm(s: str | None) -> str:
    s = re.sub(r"[’‘`´]", "'", s or "")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _num(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _crediti(att: dict) -> float:
    v = att.get("crediti")
    return float(v) if isinstance(v, (int, float)) else 0.0


def etichetta(g: dict) -> dict:
    """Significato dell'etichetta di un gruppo: `par` = CFU del gruppo in questo anno («(6 CFU)», «(fra 6 e 12
    CFU)» = il massimo), `lead` = numero iniziale («12 CFU a libera scelta»), `n` = quante attività da scegliere,
    `libera` = crediti liberi/consigliati, `obbl`, `extra` (sovrannumerari)."""
    lab = re.sub(r"\s+", " ", g.get("label_it") or "").strip()
    pars = _PAR_CFU.findall(lab)
    par = _num(pars[-1][1]) if pars else None
    par_min = _num(pars[-1][0]) if pars and pars[-1][0] else None
    m = _LEAD.match(_CC.sub("", lab))
    lead = _num(m.group(1)) if m else None
    n = None
    for rx in _SCEGLI:
        ms = rx.search(lab)
        if ms:
            w = ms.group(1).lower()
            n = int(w) if w.isdigit() else NUMERI.get(w)
            break
    if n is None and _SCELTA_SINGOLA.match(lab) and not _LIBERA.search(lab) and not _OBBL.search(lab):
        n = 1  # «Scelta lingua alpha», «Scelta Filologia»: un insegnamento tra quelli elencati
    return {"lab": lab, "par": par, "par_min": par_min, "lead": lead, "n": n,
            "libera": bool(_LIBERA.search(lab)) and not _OBBL.search(lab), "extra": bool(_EXTRA.search(lab)),
            "obbl": bool(_OBBL.search(lab)) and not _SCEGLI_COND.search(lab) or g.get("cod") == "OO",
            "cond": bool(_SCEGLI_COND.search(lab))}


def _distinte(atts: list[dict]) -> list[dict]:
    viste, out = set(), []
    for a in atts:
        k = a.get("adCod") or a.get("cod")
        if k not in viste:
            viste.add(k)
            out.append(a)
    return out


def tutte_da_sostenere(g: dict, et: dict) -> bool:
    atts = [a for a in _distinte(g.get("attivita") or []) if _crediti(a) > 0]
    if not atts or et["extra"] or et["cond"]:
        return False
    if et["obbl"]:
        return True
    if et["libera"]:
        return len(atts) == 1 and et["par"] is None and et["lead"] is None
    if len(atts) == 1:
        return True
    tot = sum(_crediti(a) for a in atts)
    if et["par"] is not None and abs(tot - et["par"]) < 1e-6:
        return True
    return et["n"] is not None and len(atts) <= et["n"]


def richiesti(g: dict, atts: list[dict | None]) -> float:
    """CFU che il gruppo richiede in un anno (per il controllo del piano e la scelta della coorte)."""
    et = etichetta(g)
    if et["extra"]:
        return 0.0
    ats = [a for a in _distinte([a for a in atts if a]) if _crediti(a) > 0]
    if et["obbl"]:
        return sum(_crediti(a) for a in ats)
    if et["par"] is not None and not (et["libera"] and not ats and et["lead"] and et["lead"] > et["par"]):
        return float(et["par"])
    if et["lead"] is not None and (et["libera"] or not ats):
        return float(et["lead"])
    cr = sorted(_crediti(a) for a in ats)
    if not cr:
        return 0.0
    if et["n"]:
        return sum(cr) if et["n"] >= len(cr) else cr[len(cr) // 2] * et["n"]
    return sum(cr) if len(cr) == 1 else cr[len(cr) // 2]


def _titolo_voce(et: dict) -> str:
    lab = et["lab"]
    if _LIBERA.search(lab) or not lab:
        return "Attività a libera scelta"
    s = _PAR_CFU.sub(" ", lab)
    s = _CC.sub("", s)
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    return s[:1].upper() + s[1:] if s else "Attività a scelta"


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)^\s*(?:percorso|curriculum)\s*[-:]?\s*", "", nome or "")
    n = re.sub(r"(?i)^.*?\s-\s*curriculum\s+", "", n)
    return _norm(re.sub(r"\(.*?\)", " ", n))


def e_comune(nome: str) -> bool:
    return bool(_PIANO_COMUNE.search(nome or ""))


def voci_coorte(det: dict, durata: int) -> list:
    """Voci di un piano: (anno 1..durata, percorso, gruppo, attività o None, altre_attività)."""
    out = []
    for p in det.get("percorsi") or []:
        pnome = (p.get("des_it") or p.get("pdsDes") or "").strip()
        for a in p.get("anni") or []:
            anno = a.get("anno")
            altre = not str(anno).isdigit()
            k = int(anno) if str(anno).isdigit() and int(anno) >= 1 else durata
            if k > durata:
                continue
            if altre:
                for att in a.get("attivita") or []:
                    out.append((k, pnome, {"cod": "AA", "label_it": "", "attivita": [att]}, att, True))
                continue
            gruppi = a.get("insegnamenti") or ([{"label_it": "", "attivita": a["attivita"]}] if a.get("attivita") else [])
            for g in gruppi:
                atts = g.get("attivita") or []
                if not atts:
                    et = etichetta(g)
                    if (et["par"] or et["lead"]) and not et["extra"]:
                        out.append((k, pnome, g, None, False))
                    continue
                for att in atts:
                    out.append((k, pnome, g, att, False))
    return out


_SOTTOPERCORSO = re.compile(r"(?i)^\s*sottopercorso\s+([a-z])\b")


def _somma_percorso(gs: dict, gia: frozenset = frozenset()) -> float:
    """CFU di un percorso in un anno; i «Sottopercorso A/B» sono alternative (si conta la più ricca)."""
    fissi, alt = 0.0, {}
    for g, atts in gs.values():
        if gia and etichetta(g)["obbl"]:  # obbligatori già contati nel piano comune
            atts = [a for a in atts if a and (a.get("adCod") or a.get("cod")) not in gia]
        r = richiesti(g, atts)
        m = _SOTTOPERCORSO.match(g.get("label_it") or "")
        if m:
            alt[m.group(1).upper()] = alt.get(m.group(1).upper(), 0.0) + r
        else:
            fissi += r
    return fissi + (max(alt.values()) if alt else 0.0)


def cfu_anno(voci: list, k: int) -> float:
    """CFU richiesti dal piano nell'anno k (senza le altre attività): per i piani con percorsi quello con più CFU,
    più il piano comune."""
    per: dict[str, dict] = {}
    for kk, pn, g, att, altre in voci:
        if kk == k and not altre:
            per.setdefault(pn, {}).setdefault(id(g), (g, []))[1].append(att)
    gia = frozenset((a.get("adCod") or a.get("cod")) for pn, gs in per.items() if e_comune(pn)
                    for g, atts in gs.values() if etichetta(g)["obbl"] for a in atts if a)
    valori = {pn: _somma_percorso(gs, frozenset() if e_comune(pn) else gia) for pn, gs in per.items()}
    comuni = sum(v for pn, v in valori.items() if e_comune(pn))
    altri = [v for pn, v in valori.items() if not e_comune(pn)]
    return comuni + (max(altri) if altri else 0)


def _incerti(voci: list, k: int) -> list[str]:
    """Etichette dei gruppi dell'anno k, nel percorso più ricco (più il comune), i cui CFU richiesti non sono certi
    (intervalli «fra 6 e 12», regole condizionali, tabelle, scelte tra attività con CFU diversi): servono a decidere
    quali anni si possono controllare in automatico."""
    per: dict[str, dict] = {}
    for kk, pn, g, att, altre in voci:
        if kk == k and not altre:
            per.setdefault(pn, {}).setdefault(id(g), (g, []))[1].append(att)
    if not per:
        return []
    valori = {pn: _somma_percorso(gs) for pn, gs in per.items()}
    altri = [pn for pn in per if not e_comune(pn)]
    scelti = [pn for pn in per if e_comune(pn)] + ([max(altri, key=lambda pn: valori[pn])] if altri else [])
    out = []
    for pn in scelti:
        for g, atts in per[pn].values():
            et = etichetta(g)
            if et["extra"]:
                continue
            ats = [a for a in _distinte([a for a in g.get("attivita") or []]) if _crediti(a) > 0]
            dubbio = ((et["par_min"] is not None and et["par_min"] != et["par"]
                       and not (et["libera"] and et["lead"] == et["par"]))
                      or et["cond"] or
                      re.search(r"(?i)tabella|almeno|di cui", et["lab"]) or
                      (not et["obbl"] and not et["libera"] and et["par"] is None and et["lead"] is None
                       and et["n"] is None and len(ats) > 1) or
                      (et["par"] is not None and et["lead"] is not None and et["par"] != et["lead"] and ats) or
                      (et["par"] is None and et["n"] and et["n"] < len(ats) and len({_crediti(a) for a in ats}) > 1))
            if dubbio and et["lab"][:90] not in out:
                out.append(et["lab"][:90])
    return out


def coorte_anno(cohorts: dict, voci: dict, k: int, anno: int, durata: int) -> tuple[int | None, str]:
    """Coorte da cui leggere l'anno k (v. docstring del modulo)."""
    y0 = anno - k + 1
    ha = {y: cfu_anno(v, k) for y, v in voci.items() if any(x[0] == k and not x[4] for x in v)}
    if not ha:
        return None, "nessuna coorte ha l'anno strutturato"
    totale = {y: sum(cfu_anno(voci[y], kk) for kk in range(1, durata + 1)) for y in ha}
    completa = lambda y: totale[y] >= (cohorts[y][1].get("crediti") or 60 * durata) - 6  # noqa: E731
    ordin = lambda y: cohorts[y][1].get("ordinamento_aa")  # noqa: E731
    vicine = sorted(ha, key=lambda y: (abs(y - y0), -y))
    stesso = [y for y in vicine if y0 in cohorts and ordin(y) == ordin(y0)]
    if y0 in ha and (ha[y0] >= 54 or completa(y0)):
        return y0, "coorte degli iscritti"
    if y0 in ha:
        if ha[y0] < 30 or (not completa(y0) and y0 < anno):
            vincolo = (lambda y: True) if ha[y0] < 30 else (lambda y: abs(y - y0) <= 1)
            meglio = [y for y in vicine if y != y0 and completa(y) and ha[y] >= 40 and vincolo(y)]
            meglio.sort(key=lambda y: (y not in stesso, abs(y - y0), -y))
            if meglio:
                return meglio[0], "piano della coorte incompleto: coorte più vicina" + (
                    " dello stesso ordinamento" if meglio[0] in stesso else "")
        return y0, "coorte degli iscritti" + ("" if completa(y0) else " (piano incompleto sulla fonte)")
    base = stesso or vicine
    pieni = [y for y in base if completa(y) and ha[y] >= 40] or [y for y in base if ha[y] >= 54]
    scelta = (pieni or base)[0]
    return scelta, ("la coorte non ha l'anno" if y0 in cohorts else "il corso non c'era in quella coorte") + (
        ": coorte più vicina dello stesso ordinamento" if stesso else ": coorte più vicina")


def _durata(det: dict, tipo: str | None) -> int:
    if str(det.get("durataAnni") or "").isdigit() and int(det["durataAnni"]) > 0:
        return int(det["durataAnni"])
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    return {"L": 3, "L2": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def vecchi_libri(path: pathlib.Path | None = None) -> dict:
    """Dati dei syllabus già raccolti per (anno, codice della scheda), dal contributo precedente."""
    path = path or ROOT / "database" / "contrib" / "auto" / "unipv.json"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out = {}
    for c in doc.get("corsi") or []:
        for i in c.get("insegnamenti") or []:
            m = re.search(r"/insegnamenti/(\d+)/([^/]+)/", i.get("url") or "")
            if m and i.get("libri"):
                out[(m.group(1), m.group(2))] = {k: i[k] for k in ("libri", "stato_libri", "modalita_esame", "ssd", "url_sito")
                                                if i.get(k)}
            elif m and i.get("ssd") and (m.group(1), m.group(2)) not in out:
                out[(m.group(1), m.group(2))] = {k: i[k] for k in ("ssd", "modalita_esame", "url_sito") if i.get(k)}
    return out


def fetch_piani(uid: str, base: str, client, anno: int, max_cds: int | None = None, syllabus: bool = True,
                log=print, riusa: dict | None = None, id_vecchio=None) -> dict:
    c = client
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")
    riusa = {} if riusa is None else riusa
    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            d = c.get(f"/corso/{y}/{x['cod']}")
            dettagli[k] = d[0] if isinstance(d, list) and d else (d if isinstance(d, dict) else None)
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        ch = cc._chiave_cds(cur)
        stessi = [x for x in elenco if cc._chiave_cds(x) == ch]
        if len(stessi) == 1:
            return stessi[0]
        stessi = [x for x in elenco if cc._chiave_cds(x)[::2] == ch[::2]]
        if len(stessi) == 1:
            return stessi[0]
        principale = re.sub(r"(?<=\d)[A-Z]$", "", cur["cdsCod"])  # 04403C (sede) -> 04403
        return next((x for x in stessi if x["cdsCod"] == principale), None)

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d and d.get("percorsi"):
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        voci = {y: voci_coorte(d, durata) for y, (_, d) in cohorts.items()}
        amm = None
        if anno in cohorts:
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")
        nomi_percorso: dict[str, str] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                if pn and not e_comune(pn):
                    nomi_percorso[_chiave_percorso(pn)] = re.sub(r"\s+", " ", pn).strip()
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        zero: set[str] = set()
        rapporto: dict[int, dict] = {}
        for k in range(1, durata + 1):
            scelta, perche = coorte_anno(cohorts, voci, k, anno, durata)
            if scelta is None:
                rapporto[k] = {"coorte": None, "perche": perche}
                continue
            x, d = cohorts[scelta]
            rapporto[k] = {"coorte": scelta, "perche": perche, "url": f"{base}/corsi/{scelta}/{x['cod']}",
                           "cfu_richiesti": cfu_anno(voci[scelta], k), "crediti_corso": d.get("crediti"),
                           "cfu_coorte": sum(cfu_anno(voci[scelta], kk) for kk in range(1, durata + 1))}
            rapporto[k]["incerti"] = _incerti(voci[scelta], k)
            veri = [(p.get("des_it") or p.get("pdsDes") or "").strip() for p in d.get("percorsi") or []]
            curricula = {nomi_percorso.get(_chiave_percorso(p), p) for p in veri if p and not e_comune(p)}
            if len(curricula) < 2:
                curricula = set()
            y0 = anno - k + 1
            lista = [(scelta, v) for v in voci[scelta]]
            if y0 != scelta and y0 in voci:  # coorte sostituita: le altre attività della coorte vera restano (a scelta)
                lista += [(y0, v) for v in voci[y0] if v[4]]
            for yc, (kk, pnome, g, att, altre) in sorted(lista, key=lambda t: t[1][4]):
                if kk != k:
                    continue
                if altre and (f"{k}:{att.get('adCod') or att.get('cod')}" in insegnamenti):
                    continue
                et = etichetta(g)
                if et["extra"]:
                    continue
                obbl = not altre and tutte_da_sostenere(g, et)
                comune = e_comune(pnome) or not curricula
                pcur = None if comune else nomi_percorso.get(_chiave_percorso(pnome), pnome)
                if att is None:  # crediti senza insegnamenti elencati: «12 CFU a libera scelta»
                    cfu = et["lead"] if (et["lead"] and (not et["par"] or et["lead"] > et["par"])) else et["par"]
                    nome = _titolo_voce(et)
                    if not cfu:
                        continue
                    key = f"{k}:#{_norm(nome)}:{cfu}:{_norm(g.get('label_it'))[:40]}"
                    item = insegnamenti.get(key)
                    if not item:
                        item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu, "ssd": None,
                                "obbligatorio": False, "curriculum": None, "_percorsi": set(), "_tutti": curricula,
                                "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}", "libri": [], "esami": [],
                                "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                        insegnamenti[key] = item
                else:
                    if _crediti(att) <= 0:  # verifiche, test e liste dell'Ateneo senza crediti
                        zero.add(cc._titolo(att.get("des_it") or ""))
                        continue
                    ad = att.get("adCod") or att.get("cod")
                    key = f"{k}:{ad}"
                    item = insegnamenti.get(key)
                    if not item:
                        docenti = [cc._nome(x_.get("des")) for x_ in att.get("docenti") or [] if x_.get("des")]
                        item = {
                            "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                            "periodo": cc._periodo(att.get("periodo_didattico_it")),
                            "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                            "periodo_fine": att.get("data_fine_periodo_didattico"),
                            "cfu": att.get("crediti"), "ssd": None,
                            "obbligatorio": bool(obbl or att.get("tipo_ins_cod") == "OBB"),
                            "curriculum": None, "_percorsi": set(), "_tutti": curricula,
                            "docenti": sorted(set(docenti)),
                            "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                   f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={yc}",
                            "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                        }
                        if altre:
                            item["_altre"] = True
                        insegnamenti[key] = item
                        if syllabus:
                            syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                           "ordinamento_aa": att.get("ordinamento_aa"),
                                           "af_percorso": att.get("corso_percorso_id"),
                                           "corso_cod": att.get("corso_cod"), "corso_aa": yc,
                                           "schema_id": att.get("schemaId")},
                                "items": []})["items"].append(item)
                    elif obbl or att.get("tipo_ins_cod") == "OBB":
                        item["obbligatorio"] = True
                if comune:
                    item["_comune"] = True
                elif pcur:
                    item["_percorsi"].add(pcur)
                    percorsi_nomi.add(pcur)
        nei_gruppi = {i["codice"] for i in insegnamenti.values() if i.get("codice") and not i.get("_altre")}
        ins = [i for i in insegnamenti.values() if not (i.get("_altre") and i.get("codice") in nei_gruppi)]
        for i in ins:
            i.pop("_altre", None)
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        # stesso nome, anno e curriculum con codici diversi
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"] if i.get("codice") else None), []).append(i)
        togli: set[int] = set()
        for gr in per_nome.values():
            if len(gr) < 2:
                continue
            per_cfu: dict = {}
            for i in gr:
                per_cfu.setdefault(i["cfu"], []).append(i)
            for cfu, uguali in per_cfu.items():
                tenuto = uguali[0]
                for altro in uguali[1:]:
                    if tenuto.get("codice") and altro.get("codice"):
                        if altro.get("obbligatorio"):
                            tenuto["obbligatorio"] = True
                        if tenuto.get("curriculum") is not None and altro.get("curriculum") is None:
                            tenuto["curriculum"] = None
                        for d_ in altro.get("docenti") or []:
                            if d_ not in tenuto["docenti"]:
                                tenuto["docenti"].append(d_)
                        togli.add(id(altro))
                        m = re.search(r"/insegnamenti/(\d+)/([^/]+)/", altro.get("url") or "")
                        if m:
                            tenuto.setdefault("_fratelli", []).append((m.group(1), m.group(2)))
            if len(per_cfu) > 1:
                for i in gr:
                    if id(i) not in togli and isinstance(i["cfu"], (int, float)):
                        i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        ins = [i for i in ins if id(i) not in togli]
        anni_nome: dict[str, set] = {}
        for i in ins:
            if i.pop("_senza_codice", False):
                anni_nome.setdefault(_norm(i["nome"]), set()).add(i["anno"])
                i["_nk"] = _norm(i["nome"])
        for i in ins:
            nk = i.pop("_nk", None)
            if nk and len(anni_nome[nk]) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        # più voci di crediti liberi nello stesso anno con lo stesso nome: una sola somma (stesso id nel database)
        liberi: dict[tuple, dict] = {}
        for i in list(ins):
            if i.get("codice") is None:
                k_ = (i["anno"], _norm(i["nome"]), i["curriculum"])
                if k_ in liberi:
                    liberi[k_]["cfu"] = (liberi[k_]["cfu"] or 0) + (i["cfu"] or 0)
                    ins.remove(i)
                else:
                    liberi[k_] = i
        RAPPORTO[cur["cdsCod"]] = {"anni": rapporto, "senza_crediti": sorted(zero), "nome": cur.get("des_it")}
        return {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

    def build_safe(cur: dict) -> dict | None:
        try:
            return build_cds(cur)
        except Exception as e:  # noqa: BLE001
            import traceback
            log(f"[{uid}]   corso {cur.get('cdsCod')} saltato: {e!r}\n{traceback.format_exc()}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; schede da leggere: {len(syllabus_jobs)}")

    risultati: dict[tuple, tuple] = {}

    def do_syllabus(item: tuple) -> int:
        chiave, job = item
        try:
            return _do_syllabus(chiave, job)
        except Exception:  # noqa: BLE001
            return 0

    def _do_syllabus(chiave: tuple, job: dict) -> int:
        vecchio = riusa.get(chiave)
        if vecchio and vecchio.get("libri"):
            libri, modalita, ssd, sito = vecchio["libri"], vecchio.get("modalita_esame"), vecchio.get("ssd"), vecchio.get("url_sito")
        else:
            sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
            if not isinstance(sy, dict):
                return 0
            libri, modalita, legati = cc._testi_syllabus(sy)
            if not libri:
                libri = libri_unipv(sy)
            if not libri:
                for u in legati:
                    libri += cc.leganto.libri(u)
            ssd, sito = sy.get("ssd"), (sy.get("urlSitoWeb") or "").strip() or None
        risultati[chiave] = (libri, modalita, ssd, sito)
        return len(libri)

    trovati = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, list(syllabus_jobs.items())), 1):
            trovati += n
            if i % 1000 == 0:
                log(f"[{uid}]   schede {i}/{len(syllabus_jobs)}")
    for chiave, job in syllabus_jobs.items():
        libri, modalita, ssd, sito = risultati.get(chiave, ([], None, None, None))
        for it in job["items"]:
            fr_ok = False
            for fr in it.pop("_fratelli", []) if not libri else []:
                if risultati.get(fr, ([],))[0] and not fr_ok:
                    libri, modalita, ssd, sito = risultati[fr][0], modalita or risultati[fr][1], ssd or risultati[fr][2], sito
                    fr_ok = True
            it["libri"] = libri
            it["stato_libri"] = "completo" if libri else "da_aggiungere"
            if modalita:
                it["modalita_esame"] = modalita
            if ssd:
                it["ssd"] = ssd
            if sito:
                it["url_sito"] = sito
            it.pop("_fratelli", None)
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unipv_piani.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}
