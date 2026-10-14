"""Tor Vergata (uniroma2): piani di studio di tutti gli anni e testi dall'API pubblica GOMP.

L'API pubblica `uniroma2public.gomp.it/CourseAPI` espone, per ogni regolamento (a.a. di coorte),
tutti gli anni di corso con le attività, i docenti e i programmi dei docenti (testi adottati
`books`, bibliografia `bibliography`, modalità d'esame). Il regolamento 2026 contiene anche gli
anni 2 e 3 (e fino al 6°) della coorte 2026, ma per l'a.a. 2026/27 un insegnamento del
k-esimo anno è quello della coorte 2026-k+1: per l'anno k si usa quindi il regolamento
dello stesso corso (`code` del corso, stabile fra gli anni) dell'a.a. 2026-k+1. Se quel
regolamento non esiste (corso nuovo, o regolamento 2026 non ancora pubblicato) si ripiega sul
regolamento più vicino successivo e poi su quelli precedenti: l'URL dell'insegnamento
(`academicYear=`) dice sempre da quale regolamento viene.

Differenze da `gomp.py` (condiviso con altri atenei): tutti gli anni, i figli dei gruppi
«a scelta» sono insegnamenti veri, moduli e canali (figli di un'attività con codice) sono
uniti all'insegnamento padre, al massimo 2 richieste al secondo, cache su disco
(variabile UN_HTTP_CACHE, cartella «uniroma2_gomp»).
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata

import requests

from .testi import _EDITORI_CIT, YEAR, _libero, estrai_libri
from .unibo import HEADERS, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://uniroma2public.gomp.it"
ANNI_REG = range(2026, 2019, -1)

# corsi del database senza corrispondenza per nome/classe (id Universitaly -> codice GOMP del corso)
CODICE_DA_ID_UNIVERSITALY = {
    "1627324": "V89",     # Ingegneria Gestionale, corso prevalentemente a distanza
    "1627390": "N39",     # Medicine and Surgery (in inglese)
    "1627392": "N39",     # Medicine and Surgery (interateneo, in inglese)
    "1627391": "J54",     # Medicina e chirurgia (in italiano)
}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _ita(testi: list | None) -> str:
    for t in testi or []:
        if t.get("iso") == "ita" and (t.get("text") or "").strip():
            return t["text"].strip()
    for t in testi or []:
        if (t.get("text") or "").strip():
            return t["text"].strip()
    return ""


class Api:
    """GOMP: al massimo 2 richieste al secondo, risposte su disco."""

    def __init__(self, rate: float = 1.8):
        self.s, self.gap, self.last, self.requests = requests.Session(), 1.0 / rate, 0.0, 0
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "uniroma2_gomp" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def post(self, metodo: str, dati: dict) -> dict | None:
        f = None
        if self.dir:
            f = self.dir / (hashlib.sha1((metodo + json.dumps(dati, sort_keys=True)).encode()).hexdigest() + ".json")
            if f.exists():
                return json.loads(f.read_text(encoding="utf-8"))
        for tentativo in range(4):
            attesa = self.last + self.gap - time.monotonic()
            if attesa > 0:
                time.sleep(attesa)
            self.last = time.monotonic()
            self.requests += 1
            try:
                r = self.s.post(f"{BASE}/CourseAPI/{metodo}", json=dati, timeout=180,
                                headers={**HEADERS, "Accept": "application/json", "Content-Type": "application/json"})
                d = r.json()
                dati_ok = d.get("data") if d.get("success") else None
                if dati_ok is not None and f:
                    f.write_text(json.dumps(dati_ok, ensure_ascii=False), encoding="utf-8")
                return dati_ok
            except (requests.RequestException, ValueError):
                time.sleep(2 ** tentativo)
        return None

    def elenco(self, anno: int) -> list[dict]:
        d = self.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": anno,
                                                   "courseTypes": ["CorsoDiStudio"]}) or {}
        return [c for s in d.get("data") or [] for c in s.get("courses") or []]

    def corso(self, uid: str, anno: int) -> dict | None:
        return self.post("getCourse", {"mode": "CourseDetail", "uid": uid, "code": "", "academicYear": anno,
                                       "curricula": None, "years": None, "iso": "ita", "showCUINs": "False"})


_RUMORE = re.compile(
    r"(?i)dispens|slide|appunti|lucidi|materiale|material |will be|saranno|verranno|sar[àa]\b|fornit|disponibil|"
    r"indicat|suggerit|durante|a lezione|power ?point|presentazion|riferimenti normativi|legislazione|"
    r"\bnessun|\bnon (?:sono|ci sono|è|e'|vi sono|previst|richiest)|\bda definire|\bnd\b|n\.d\.|"
    r"piattaforma|\bteams\b|moodle|sito web|pagina web|\bonline\b|a cura del docente|note del|letture di approfondimento|"
    r"come sopra|\bil corso\b|la bibliografia|sito del|ricerche bibliografiche|\bsi articola|\bgli studenti\b|\blo studente\b|^vedi\b|"
    r"^le indicazioni|^capitol[oi]\s*:|pagine da studiare|^in alternativa$|^oppure$")
_BOZZA = re.compile(r"(?i)bozza compilata|da verificare prima dell|DidatticaWEB")
_SEGNALE = re.compile(r"[“\"«]|\b[A-Z]\.\s?[A-Z][a-zà-ÿ]|\b(?:vol|voll|cap|pp|ed)\b\.?|\bdi [A-Z]|\bet al|[A-Z][a-zà-ÿ]+ [A-Z][a-zà-ÿ]+,")
_NOMI = re.compile(r"^[A-ZÀ-Ý][\w'’.-]*(?:[ ,]+(?:e |and |& )?[A-ZÀ-Ý][\w'’.-]*){0,4}$")


def _segnale(cit: str) -> bool:
    from .testi import _isbn
    return bool(_EDITORI_CIT.search(cit) or YEAR.search(cit) or _isbn(cit) or _SEGNALE.search(cit))


_INTEST = re.compile(r"(?i)^\W*(?:testi?|libri?|manual[ei]|bibliografia|letture|modulo|mod\.?|parte|part|"
                     r"reading list|textbooks?|references|suggested|recommended|required)\b[^\n]{0,40}$")
_CONTINUA = re.compile(r"(?i)^\W*(?:autori?|editore|casa editrice|edizioni|ed\.|isbn|anno|\d{4}\b|\d+\s?(?:a|°)?\s?ed)")


def _blocchi_libero(testo: str, tipo: str) -> list[dict]:
    """Elenco di riferimenti in testo libero, una riga ciascuno (con le righe di editore/anno/autore
    unite alla riga del titolo). Le righe che parlano di dispense, slide o appunti non sono libri."""
    blocchi: list[tuple[str, str]] = []
    t = tipo
    for riga in testo.replace("\xa0", " ").split("\n"):
        r = re.sub(r"\s+", " ", riga).strip(" \t-•*·●▪–")
        r = re.sub(r"(?i)^(?:per gli )?studenti (?:non )?frequentanti\s*[:,;.-]?\s*", "", r)
        if not r or _RUMORE.search(r):
            continue
        if _INTEST.match(r) and len(r.split()) <= 4 and not YEAR.search(r) and not _EDITORI_CIT.search(r):
            if re.search(r"(?i)consigliat|recommended|suggested|approfondiment|facoltativ|optional", r):
                t = "consigliato"
            elif re.search(r"(?i)obbligator|adottat|required", r):
                t = "obbligatorio"
            continue
        corta_editore = len(r.split()) <= 6 and bool(_EDITORI_CIT.search(r))
        if blocchi and _NOMI.match(blocchi[-1][0]) and not _segnale(blocchi[-1][0]) and len(blocchi[-1][0].split()) <= 5:
            blocchi[-1] = (f"{blocchi[-1][0].rstrip(' .,;')}, {r}", blocchi[-1][1])  # autori su una riga, titolo dopo
        elif blocchi and (_CONTINUA.match(r) or corta_editore):
            blocchi[-1] = (f"{blocchi[-1][0].rstrip(' .,;')}, {r}", blocchi[-1][1])
        else:
            blocchi.append((r, t))
    out = []
    for cit, tp in blocchi:
        if len(cit) < 10 or len(cit) > 400 or len(cit.split()) < 2 or len(cit.split()) > 60 or not _segnale(cit):
            continue
        lb = _libero(cit)
        lb["tipo"] = lb["tipo"] or tp
        out.append(lb)
    return out


def _libri(professori: list[dict]) -> list[dict]:
    libri, viste = [], set()
    for p in professori:
        for campo, tipo in (("books", "obbligatorio"), ("bibliography", "consigliato")):
            grezzo = _ita(p.get(campo))
            if _BOZZA.search(grezzo):  # testo segnato dallo stesso ateneo come bozza da verificare
                continue
            trovati = estrai_libri(grezzo.replace("\n", "<br>")) or _blocchi_libero(grezzo, tipo)
            for lb in trovati:
                lb["tipo"] = lb["tipo"] or tipo
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(lb)
    return libri


def _professori(a: dict) -> list[dict]:
    prof = [p for part in a.get("partitions") or [] for p in part.get("professors") or []]
    for figlio in a.get("children") or []:
        prof += _professori(figlio)
    return prof


def _modalita(prof: list[dict]) -> str | None:
    scritto = any(p.get("writtenExam") or p.get("practiceTest") for p in prof)
    orale = any(p.get("oralExam") for p in prof)
    if scritto and orale:
        return "scritto e orale"
    return "scritto" if scritto else ("orale" if orale else None)


def _ripara(s: str) -> str:
    """Il servizio perde alcune lettere accentate (U+FFFD): «-ità» alla fine di parola, apostrofo fra due lettere."""
    s = re.sub(r"(?<=it)�", "à", s)
    return re.sub(r"(?<=[A-Za-z])�(?=[A-Za-z])", "'", s)


def _attivita(a: dict) -> dict:
    cfu = sum(c.get("credits") or 0 for c in a.get("credits") or [])
    ssd = ", ".join(sorted({c.get("sector") for c in a.get("credits") or [] if c.get("sector")})) or None
    if not cfu:  # moduli: somma dei CFU dei figli
        for f in a.get("children") or []:
            cfu += sum(c.get("credits") or 0 for c in f.get("credits") or [])
        ssd = ssd or ", ".join(sorted({c.get("sector") for f in a.get("children") or [] for c in f.get("credits") or []
                                       if c.get("sector")})) or None
    prof = _professori(a)
    docenti = sorted({" ".join(w.capitalize() for w in f"{p.get('lastName', '')} {p.get('name', '')}".split())
                      for p in prof if (p.get("lastName") or "").strip()})
    return {"codice": (a.get("code") or "").strip() or None, "nome": _ripara(re.sub(r"(?<=\s)i$", "I", _titolo(_ita(a.get("name"))))),
            "cfu": (int(cfu) if float(cfu).is_integer() else cfu) if cfu else None, "ssd": ssd, "docenti": docenti,
            "libri": _libri(prof), "modalita": _modalita(prof)}


def _espandi(a: dict, a_scelta: bool):
    """Attività da registrare come insegnamenti: (attività, a_scelta). I gruppi e le attività senza codice con
    figli (es. «Lingue straniere») cedono i figli; le attività con codice tengono moduli e canali."""
    if a.get("type") == "group" or a.get("linkedGroup") or (not (a.get("code") or "").strip() and a.get("children")):
        for f in a.get("children") or []:
            yield from _espandi(f, True)
    else:
        yield a, a_scelta


def _righe(dati: dict, k: int, fonte: str, oggi: str) -> dict[str, dict]:
    righe: dict[str, dict] = {}
    curr_list = dati.get("curricula") or []
    for cu in curr_list:
        nome_c = _ita(cu.get("name")) if len(curr_list) > 1 else None
        for y in cu.get("years") or []:
            if y.get("number") != k:
                continue
            for u in y.get("units") or []:
                annuale = (u.get("length") or 6) >= 12
                for att in u.get("activities") or []:
                    for a, a_scelta in _espandi(att, False):
                        x = _attivita(a)
                        if not x["nome"]:
                            continue
                        key = x["codice"] or x["nome"]
                        item = righe.get(key)
                        if not item:
                            item = righe[key] = {
                                "codice": x["codice"], "nome": x["nome"], "anno": k,
                                "periodo": "annuale" if annuale else (str(u.get("number")) if u.get("number") else None),
                                "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": not a_scelta, "curriculum": None,
                                "docenti": x["docenti"], "url": fonte, "libri": x["libri"], "esami": [],
                                "fonte": fonte, "verificato_il": oggi, "_c": set(),
                                "stato_libri": "completo" if x["libri"] else "da_aggiungere",
                            }
                            if x["modalita"]:
                                item["modalita_esame"] = x["modalita"]
                        item["_c"].add(nome_c)
    return righe


def trova_codici(corsi_db: list[dict], per_anno: dict[int, list[dict]]) -> dict[str, str]:
    """id del corso del database -> codice GOMP (stabile fra gli anni)."""
    tutti: dict[str, dict] = {}
    for anno in sorted(per_anno):  # i regolamenti più recenti prevalgono
        for g in per_anno[anno]:
            tutti[g["code"]] = g
    uid_codice = {g["uid"]: g["code"] for g in per_anno[max(per_anno)]}
    per_nome: dict[str, list[dict]] = {}
    for g in tutti.values():
        for n in {_norm(_ita(g.get("name"))), _norm(" ".join(t.get("text") or "" for t in g.get("name") or []
                                                             if t.get("iso") == "eng"))}:
            if n:
                per_nome.setdefault(n, []).append(g)
    nel_2026 = {g["code"] for g in per_anno[max(per_anno)]}
    out: dict[str, str] = {}
    for c in corsi_db:
        cod = CODICE_DA_ID_UNIVERSITALY.get(str(c.get("id_universitaly")))
        if not cod:
            def classe(x: str) -> str:
                return re.sub(r"\s+", "", re.sub(r"\s+R$", "", x.strip())).replace("c.u.", "").upper()

            cl = {classe(x) for x in (c.get("classe") or "").split("/")}
            cand = per_nome.get(_norm(c["nome"])) or per_nome.get(_norm(c.get("nome_en") or "")) or []
            cand = [g for g in cand if {classe(x) for x in g.get("classes") or []} & cl] or cand
            cand = sorted(cand, key=lambda g: (g["code"] not in nel_2026, -max(
                [a for a in per_anno if any(h["code"] == g["code"] for h in per_anno[a])] or [0])))
            if cand:
                cod = cand[0]["code"]
        if not cod:
            m = re.search(r"uid=([0-9a-f-]{36})", c.get("url_catalogo") or "")
            cod = uid_codice.get(m.group(1)) if m else None
        if cod:
            out[c["id"]] = cod
    return out


def fetch_ateneo(uid: str, anno: int = 2026, max_cds: int | None = None, syllabus: bool = True, log=print) -> dict:
    """Contributo nel formato di database/contrib (vedi build_db.py)."""
    corsi_db = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    api = Api()
    oggi = time.strftime("%Y-%m-%d")
    per_anno = {a: api.elenco(a) for a in ANNI_REG if a <= anno}
    per_anno = {a: v for a, v in per_anno.items() if v}
    codici = trova_codici([c for c in corsi_db if not c.get("piano_da")], per_anno)
    uid_gomp = {a: {g["code"]: g["uid"] for g in v} for a, v in per_anno.items()}
    log(f"[{uid}] regolamenti GOMP: " + ", ".join(f"{a}: {len(v)}" for a, v in sorted(per_anno.items())) +
        f"; corsi del database associati: {len(codici)}/{len(corsi_db)}")
    cache_dett: dict[tuple, dict | None] = {}

    def dettaglio(codice: str, a: int) -> dict | None:
        k = (codice, a)
        if k not in cache_dett:
            u = uid_gomp.get(a, {}).get(codice)
            cache_dett[k] = api.corso(u, a) if u else None
        return cache_dett[k]

    out = []
    lavoro = [c for c in corsi_db if c["id"] in codici]
    if max_cds:
        lavoro = lavoro[:max_cds]
    for n, corso in enumerate(lavoro, 1):
        cod = codici[corso["id"]]
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        for k in range(1, durata + 1):
            y = anno - k + 1
            candidati = [a for a in range(y, anno + 1)] + [a for a in range(y - 1, 2019, -1)]
            for a in candidati:
                if cod not in uid_gomp.get(a, {}):
                    continue
                dati = dettaglio(cod, a)
                fonte = f"{BASE}/PublicData?uid={uid_gomp[a][cod]}&mode=CourseDetail&iso=ita&academicYear={a}"
                r = _righe(dati, k, fonte, oggi) if dati else {}
                if r:
                    for cu in dati.get("curricula") or []:
                        if len(dati["curricula"]) > 1 and _ita(cu.get("name")):
                            curricula.add(_ita(cu["name"]))
                    for key, v in r.items():
                        righe[f"{k}:{key}"] = v
                    break
        for i in righe.values():
            cs = i.pop("_c")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(c for c in cs if c))
        if not righe:
            log(f"[{uid}]   {corso['nome']}: nessun insegnamento")
            continue
        fonte_c = next(iter(righe.values()))["fonte"]
        out.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                    "url": fonte_c, "curricula": sorted(curricula) or None, "fonte": fonte_c, "verificato_il": oggi,
                    "insegnamenti": list(righe.values())})
        if n % 10 == 0:
            log(f"[{uid}]   corsi {n}/{len(lavoro)} (richieste: {api.requests})")
    if syllabus:
        try:
            from . import uniroma2_testi
            uniroma2_testi.aggiungi_testi(out, corsi_db, log, anno)
        except Exception as e:  # noqa: BLE001 - i testi dai siti dei corsi sono un di più
            log(f"[{uid}] ERRORE testi dai siti dei corsi: {e!r}")
    try:
        from . import uniroma2_appelli
        uniroma2_appelli.aggiungi_appelli(out, log)
    except Exception as e:  # noqa: BLE001 - gli appelli sono un di più: senza, restano i piani
        log(f"[{uid}] ERRORE appelli DidatticaWeb: {e!r}")
    libri = sum(len(i["libri"]) for x in out for i in x["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {libri}; "
        f"richieste: {api.requests}")
    return {"universita_id": uid, "descrizione": f"Generato dall'API pubblica GOMP {BASE} (adapters/uniroma2.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
