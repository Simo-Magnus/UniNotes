"""Insegnamenti dell'Università per Stranieri di Siena dalle guide didattiche.

L'elenco degli insegnamenti per curriculum sulle pagine dei corsi (dipartimento.unistrasi.it,
`/sezione?…&pds_id=…`) è vuoto: il piano è nella "Guida didattica" in PDF
(`online.unistrasi.it/docenti/Guide/<anno>/<sigla>.pdf`, linkata dalle pagine dei corsi), che ha
per ogni "CURRICOLO: …" le tabelle "I anno | CFU", "II anno | CFU", … con righe
"SSD - Nome" e gruppi "1 esame a scelta (6 cfu) tra - SSD - Nome - …". Le tabelle si leggono con
pdfplumber; il corso si riconosce dalla classe ("(CLASSE L-10 R - …)"). Niente docenti né libri.
"""
from __future__ import annotations

import io
import json
import pathlib
import re
import time

from .unibo import Client

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://dipartimento.unistrasi.it"
PAGINE = ["/1/92/Didattica.htm", "/1/153/1585/I_nostri_Corsi_di_Laurea_Triennale.htm",
          "/1/154/1599/I_nostri_Corsi_di_Laurea_Magistrale.htm"]
ROMANI = {"I": 1, "II": 2, "III": 3}
SSD = r"[A-Z]{3,4}-\d{2}/\s?[A-Z]|[A-Z]+(?:-[A-Z]+)?/\d{2}"  # nuovi (ITAL-01/A) e vecchi (M-STO/08)
# "SSD - Nome" o "SSD Nome", anche più voci nella stessa cella
VOCE = re.compile(rf"({SSD})\s*-?\s*([^\n-][^\n]*?)(?=\s*(?:\n|-\s*{SSD}|$))")


def _classi(testo: str) -> set[str]:
    return {re.sub(r"\s+", "", m) for m in re.findall(r"CLASSE\s+(L(?:M)?\s*-\s*\d+)", testo)}


def leggi_guida(data: bytes) -> tuple[set[str], list[dict]]:
    import pdfplumber
    classi, out, curriculum = set(), [], None
    with pdfplumber.open(io.BytesIO(data)) as pdf:
        for n, pagina in enumerate(pdf.pages):
            testo = pagina.extract_text() or ""
            if n < 10:
                classi |= _classi(testo)
            m = re.search(r"CURRICOLO:\s*(.+)", testo)
            if m:
                curriculum = m.group(1).strip()
            for tab in pagina.extract_tables():
                if not tab or not tab[0] or len(tab[0]) < 2:
                    continue
                a = re.match(r"\s*(I{1,3})\s+anno\b", (tab[0][0] or ""))  # "II anno (dall'a.a.2027/2028)"
                if not a or "CFU" not in (tab[0][1] or ""):
                    continue
                k = ROMANI[a.group(1)]
                for riga in tab[1:]:
                    cella, cfu_t = (riga[0] or ""), (riga[-1] or "")
                    a = re.match(r"\s*(I{1,3})\s+anno", cella)
                    if a and len(cella.strip()) < 40:  # la tabella continua con l'anno dopo
                        k = ROMANI[a.group(1)]
                        continue
                    if re.match(r"(?i)\s*totale", cella):
                        continue
                    cfu = re.search(r"\d+", cfu_t)
                    scelta = bool(re.search(r"(?i)a scelta|oppure", cella))
                    voci = VOCE.findall(cella)
                    if not voci:
                        nome = re.sub(r"\s+", " ", cella).strip(" *–‐-")
                        if nome:
                            out.append({"anno": k, "nome": nome, "ssd": None, "cfu": int(cfu.group(0)) if cfu else None,
                                        "curriculum": curriculum, "a_scelta": scelta})
                        continue
                    cfu_sc = re.search(r"\((\d+)\s*cfu\)", cella, re.I)
                    for ssd, nome in voci:
                        out.append({"anno": k, "nome": re.sub(r"\s+", " ", nome).strip(" *–‐-"), "ssd": ssd,
                                    "cfu": int(cfu_sc.group(1)) if scelta and cfu_sc else
                                    (int(cfu.group(0)) if cfu and len(voci) == 1 else None),
                                    "curriculum": curriculum, "a_scelta": scelta or len(voci) > 1})
    return classi, out


def fetch_ateneo(uid: str = "unistrasi", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=2.0)
    oggi = time.strftime("%Y-%m-%d")
    guide = set()
    for u in [x.get("url") for x in corsi if x.get("url")] + [BASE + p for p in PAGINE]:
        r = c.get(u)
        testo = r.text if r else ""
        guide |= set(re.findall(rf"https?://online\.unistrasi\.it/docenti/Guide/{anno}/[\w.-]+\.pdf", testo))
        for h in re.findall(r"href=['\"](https://dipartimento\.unistrasi\.it/1/2\d\d/[^'\"]+\.htm)['\"]", testo):
            rh = c.get(h)
            guide |= set(re.findall(rf"https?://online\.unistrasi\.it/docenti/Guide/{anno}/[\w.-]+\.pdf",
                                    rh.text if rh else ""))
    per_classe: dict[str, list[tuple[str, list[dict]]]] = {}
    for g in sorted(guide):
        try:
            with c.lock:
                c.requests += 1
            rg = c.s.get(g, timeout=120)
            classi, voci = leggi_guida(rg.content) if rg.content[:5] == b"%PDF-" else (set(), [])
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}]   {g}: {e!r}")
            continue
        if len(classi) == 1 and voci:
            per_classe.setdefault(classi.pop(), []).append((g, voci))
    out = []
    for corso in corsi:
        cl = {re.sub(r"\s+", "", x) for x in (corso.get("classe") or "").split("/") if x.strip()}
        cand = [x for k in cl for x in per_classe.get(k, [])]
        if len(cand) != 1:
            continue
        fonte, voci = cand[0]
        curricula = sorted({v["curriculum"] for v in voci if v["curriculum"]})
        righe: dict[str, dict] = {}
        for v in voci:
            key = f"{v['anno']}:{v['nome'].lower()}"
            item = righe.setdefault(key, {
                "codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": None, "cfu": v["cfu"],
                "ssd": v["ssd"], "obbligatorio": False if v["a_scelta"] else None, "curriculum": None, "docenti": [],
                "url": fonte, "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi,
                "stato_libri": "da_aggiungere", "_c": set()})
            item["_c"].add(v["curriculum"])
        for i in righe.values():
            cs = i.pop("_c")
            if len(curricula) > 1 and None not in cs and cs != set(curricula):
                i["curriculum"] = ", ".join(sorted(x.title() for x in cs))
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                    "durata_anni": corso.get("durata_anni"), "url": corso.get("url"),
                    "curricula": [x.title() for x in curricula] if len(curricula) > 1 else None, "fonte": fonte,
                    "verificato_il": oggi, "insegnamenti": list(righe.values())})
    log(f"[{uid}] {len(guide)} guide, {len(out)} corsi (su {len(corsi)}), "
        f"{sum(len(x['insegnamenti']) for x in out)} insegnamenti; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dalle guide didattiche di dipartimento.unistrasi.it "
                                                 "(adapters/unistrasi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
