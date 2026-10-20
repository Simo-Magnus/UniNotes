"""Università Giustino Fortunato (Benevento, telematica): piani di studio, docenti e libri dall'API pubblica GOMP.

Piani: `https://unifortunato-public.gomp.it` (stessa API di `gomp.py`). Rispetto all'adattatore comune servono:

- il regolamento dell'a.a. corrente contiene TUTTI gli anni del corso (l'adattatore comune leggeva solo il 1° anno e lasciava
  vuoti il 2° e il 3°): ogni anno si legge dal regolamento 2026/27 di ogni corso (codice GOMP), e se un anno manca dal più
  recente che lo ha;
- Diritto ed economia delle imprese (DEI-09) e Psicologia comportamentale e cognitiva applicata (PSI-08) non sono più
  nell'elenco dei corsi 2026 ma il loro regolamento 2026 risponde ancora (uid in `REGOLAMENTI_NOTI`, quelli della fonte già
  raccolta): se il codice manca dall'elenco si usa quello, altrimenti l'elenco dell'a.a. più recente che lo ha;
- percorsi senza nessuna attività (il «Curriculum unico» di DEI-09 è vuoto in tutti gli anni) non sono percorsi del corso;
- le attività a 0 CFU (prova pratica valutativa) e i gruppi a 0 CFU «Extracurriculare - percorso Honors» (esami in più, che
  non fanno parte dei crediti del piano) non sono righe del piano;
- docenti segnaposto («Docente Docente») tolti;
- i gruppi a scelta sono espansi negli insegnamenti che li compongono (a scelta; da sostenere per intero solo se i CFU del
  gruppo bastano per tutti); un gruppo ripetuto in due semestri con lo stesso `linkedGroup` è un solo gruppo;
- libri mancanti nel regolamento corrente: quelli dello stesso insegnamento (stesso codice) nei regolamenti degli a.a.
  precedenti, di qualunque corso (il codice è del catalogo dell'ateneo).

Con la variabile d'ambiente UNIFORTUNATO_HTTP_CACHE (una cartella) le risposte dell'API restano su disco.
Richieste: 3 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unifortunato.json`):

    python tools/db_builder/adapters/unifortunato.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import sys
import time

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .gomp import HOSTS, Api, _cfu_attivita, _ita, _nomi_distinti, _norm, _righe_anno  # noqa: E402

UID = "unifortunato"
ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = HOSTS[UID]

# id del corso del database → codice del corso in GOMP
CORSI = {
    "unifortunato-l-14-l-18-diritto-ed-economia-delle-imprese": "DEI-09",
    "unifortunato-l-8-ingegneria-informatica": "ING-10",
    "unifortunato-l-19-scienze-dell-educazione": "EDU-06",
    "unifortunato-l-22-scienze-delle-attivita-motorie-sportive-e-delleducazione-psi": "SM-11",
    "unifortunato-l-24-scienze-e-tecniche-psicologiche": "PSI-07",
    "unifortunato-l-28-scienze-e-tecnologie-dei-trasporti": "AIR-05",
    "unifortunato-lm-77-economia-aziendale": "ECO-04",
    "unifortunato-lm-47-organizzazione-e-gestione-dei-servizi-per-lo-sport-e-le-atti": "SAM-12",
    "unifortunato-lm-51-psicologia-comportamentale-e-cognitiva-applicata": "PSI-08",
    "unifortunato-lm-85-scienze-pedagogiche-e-neuroscienze-cognitive": "PED-13",
    "unifortunato-lmg-01-giurisprudenza": "LMG-01",
}
# regolamento 2026 dei corsi che l'elenco dei corsi 2026 non riporta più (codice → uid): rispondono ancora a getCourse
REGOLAMENTI_NOTI = {"DEI-09": "6679b7fe-8a9f-4da9-8ffa-a98f0a926081",
                    "PSI-08": "afd61e34-4172-4824-b29a-f494c30b5b35"}
_EXTRA = re.compile(r"(?i)extracurricular")
_SEGNAPOSTO = re.compile(r"(?i)^(docente\s*)+$")


class _ApiCache(Api):
    """Api di GOMP con le risposte su disco (UNIFORTUNATO_HTTP_CACHE)."""

    def post(self, metodo: str, dati: dict):
        cartella = os.environ.get("UNIFORTUNATO_HTTP_CACHE")
        if not cartella:
            return super().post(metodo, dati)
        f = pathlib.Path(cartella) / (hashlib.sha1(f"{metodo}{json.dumps(dati, sort_keys=True)}".encode()).hexdigest() + ".json")
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().post(metodo, dati)
        if r is not None:
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _pulito(dati: dict) -> dict:
    """Regolamento senza i percorsi vuoti, le attività a 0 CFU e i gruppi extracurriculari."""
    def utile(a: dict) -> bool:
        if a.get("type") not in (None, "activity") or a.get("linkedGroup"):  # gruppo
            return not (_EXTRA.search(_ita(a.get("name"))) or (_cfu_attivita(a) == 0 and a.get("children")))
        return _cfu_attivita(a) > 0

    curricula = []
    for cu in dati.get("curricula") or []:
        anni = [{**y, "units": [{**u, "activities": [a for a in u.get("activities") or [] if utile(a)]}
                                for u in y.get("units") or []]} for y in cu.get("years") or []]
        if any(u["activities"] for y in anni for u in y["units"]):
            curricula.append({**cu, "years": anni})
    return {**dati, "curricula": curricula}


def _stesso_percorso(a: dict, b: dict) -> bool:
    """Le due righe sono nello stesso percorso (una riga senza percorso è in tutti)."""
    ca, cb = a.get("curriculum"), b.get("curriculum")
    return not ca or not cb or bool(set(ca.split(", ")) & set(cb.split(", ")))


def _nomi_distinti_codici(righe: list[dict]) -> None:
    """Insegnamenti con codici diversi, stesso anno, stesso nome e uno stesso percorso (es. «Informatica» obbligatoria e
    «Informatica» a scelta del 2° anno di Diritto ed economia delle imprese, entrambe da 6 CFU): restano distinti e il nome
    indica i CFU (o il codice se i CFU sono uguali). Nei percorsi diversi sono insegnamenti diversi dello stesso nome
    (es. «Lingua inglese» da 12 CFU a Trasporto terrestre e da 9 a Trasporto navale) e il nome non cambia."""
    per_nome: dict[tuple, list[dict]] = {}
    for i in righe:
        if i["codice"]:
            per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
    for voci in per_nome.values():
        da_distinguere = [i for i in voci if any(j is not i and j["codice"] != i["codice"] and _stesso_percorso(i, j)
                                                 for j in voci)]
        if not da_distinguere:
            continue
        cfu = {i["cfu"] for i in da_distinguere}
        for i in da_distinguere:
            if len(cfu) == len(da_distinguere) and i["cfu"]:
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            else:
                i["nome"] = f"{i['nome']} (cod. {i['codice']})"


def _bel_nome(nome: str) -> str:
    """«Probabilita'» → «Probabilità»; «Diritto Dell'energia» → «Diritto dell'Energia»."""
    accento = {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}
    nome = re.sub(r"([aeiou])'(?=\s|$)", lambda m: accento[m.group(1)], nome)
    nome = re.sub(r"(?<=\s)(Dell|All|Nell|Sull|Dall|Coll|Un)'(\w)",
                  lambda m: m.group(1).lower() + "'" + m.group(2).upper(), nome)
    return nome


def _righe(dati: dict, k: int) -> list[dict]:
    righe = _righe_anno(_pulito(dati), k, None, True)[0]
    for i in righe:
        i["nome"] = _bel_nome(i["nome"])
        i["docenti"] = [d for d in i["docenti"] if not _SEGNAPOSTO.match(d.strip())]
    return righe


def fetch_unifortunato(uid: str = UID, anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                       corsi: list[dict] | None = None, log=print) -> dict:
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    api = _ApiCache(BASE)
    oggi = time.strftime("%Y-%m-%d")
    elenchi: dict[int, dict[str, dict]] = {}
    for a in range(anno, anno - 8, -1):  # tutti i regolamenti dell'ateneo
        els = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": a,
                                                    "courseTypes": ["CorsoDiStudio"]}) or {}
        elenchi[a] = {c.get("code"): c for s in els.get("data") or [] for c in s.get("courses") or []}
    log(f"[{uid}] regolamenti: " + ", ".join(f"{a}: {len(v)} corsi" for a, v in sorted(elenchi.items())))
    regs: dict[tuple, tuple | None] = {}

    def regolamento(codice: str, a: int):
        if (codice, a) not in regs:
            c = elenchi.get(a, {}).get(codice)
            u = c["uid"] if c else (REGOLAMENTI_NOTI.get(codice) if a == anno else None)
            dati = api.corso(u, a) if u else None
            regs[(codice, a)] = (u, dati) if dati and dati.get("curricula") else None
        return regs[(codice, a)]

    def build(corso: dict) -> dict | None:
        codice, durata = CORSI.get(corso["id"]), corso.get("durata_anni") or 3
        if not codice:
            return None
        righe: list[dict] = []
        fonte0 = None
        for k in range(1, durata + 1):
            for a in range(anno, anno - 8, -1):  # il regolamento più recente che ha l'anno k
                p = regolamento(codice, a)
                if not p:
                    continue
                fonte = f"{BASE}/PublicData?uid={p[0]}&mode=CourseDetail&iso=ita&academicYear={a}"
                fonte0 = fonte0 or fonte
                rk = _righe(p[1], k)
                if not rk:
                    continue
                for i in rk:
                    cs, pc = i.pop("_c"), i.pop("_pc")
                    if None not in cs and pc and cs != pc:
                        i["curriculum"] = ", ".join(sorted(cs))
                    i.update({"url": fonte, "esami": [], "fonte": fonte, "verificato_il": oggi})
                righe += rk
                break
        if not righe:
            return None
        attuale = _pulito((regolamento(codice, anno) or (None, {}))[1]).get("curricula") or []
        curricula = sorted({_ita(cu.get("name")) for cu in attuale if _ita(cu.get("name"))}) if len(attuale) > 1 else []
        _nomi_distinti(righe)
        _nomi_distinti_codici(righe)
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": fonte0, "curricula": curricula or None, "fonte": fonte0, "verificato_il": oggi,
                "insegnamenti": righe}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    daf = [c for c in corsi if c["id"] in CORSI]
    if max_cds:
        daf = daf[:max_cds]
    out = []
    with cf.ThreadPoolExecutor(3) as ex:
        for r in ex.map(build_safe, daf):
            if r:
                out.append(r)
    if syllabus:  # libri: quelli dell'insegnamento (stesso codice) nel regolamento più recente che li ha
        libri_codice: dict[str, list[dict]] = {}
        codici = {c for c in CORSI.values()}
        for a in range(anno, anno - 8, -1):
            for codice in sorted(set(elenchi.get(a, {})) | (codici if a == anno else set())):
                p = regolamento(codice, a)
                if not p:
                    continue
                for k in range(1, 7):
                    for i in _righe(p[1], k):
                        if i["codice"] and i["libri"]:
                            libri_codice.setdefault(i["codice"], i["libri"])
        for x in out:
            for i in x["insegnamenti"]:
                if not i["libri"] and i["codice"] in libri_codice:
                    i["libri"] = libri_codice[i["codice"]]
                i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
    libri = sum(len(i["libri"]) for x in out for i in x["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {libri}; "
        f"richieste: {api.requests}")
    return {"universita_id": uid, "descrizione": f"Generato dall'API pubblica GOMP {BASE} (adapters/unifortunato.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def fetch_ateneo(uid: str, anno: int | None = None, **kw) -> dict:
    return fetch_unifortunato(uid, anno, **kw)


if __name__ == "__main__":
    doc = fetch_unifortunato(syllabus="--senza-syllabus" not in sys.argv)
    destinazione = ROOT / "database" / "contrib" / "auto" / f"{UID}.json"
    vecchio = json.loads(destinazione.read_text(encoding="utf-8")) if destinazione.exists() else {}
    doc["appelli"] = vecchio.get("appelli") or {}
    destinazione.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"scritto {destinazione}")
