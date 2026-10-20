"""Insegnamenti, docenti e libri dagli atenei che usano GOMP (es. Roma Tre, Cassino).

GOMP pubblica il catalogo con un'API JSON pubblica (`<ateneo>-public.gomp.it/CourseAPI`),
la stessa delle pagine "PublicData":

- `POST /CourseAPI/getDepartmentsAndCourses` {academicYear} → corsi di studio dell'a.a.
  (uid del regolamento, nome, classi);
- `POST /CourseAPI/getCourse` {uid, academicYear} → curricula → anni → periodi → attività
  (codice, nome, CFU e SSD, moduli, canali con docenti, "books" = testi adottati,
  "bibliography" = testi consigliati). L'API pubblica espone gli anni di corso del
  regolamento della coorte dell'a.a. richiesto (in pratica il 1° anno).
"""
from __future__ import annotations

import concurrent.futures as cf
import json
import pathlib
import re
import threading
import time
import unicodedata

import requests

from .testi import estrai_libri
from .unibo import HEADERS, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
HOSTS = {u: f"https://{u}-public.gomp.it" for u in ("uniroma3", "unicas", "unitus", "unicamillus", "unifortunato", "iul")}
HOSTS["uniroma2"] = "https://uniroma2public.gomp.it"  # Tor Vergata: host senza trattino
# Atenei il cui piano di ogni anno di corso è quello della coorte che lo segue (a.a. - k + 1): ogni coorte ha
# il suo regolamento (uid diverso, stesso `code` del corso) e solo il 1° anno è quello dell'a.a. corrente.
# Il piano si ricostruisce anno per anno, con i gruppi a scelta espansi negli insegnamenti che li compongono.
ANNI_PER_COORTE = {"uniroma3", "unitus", "unicas"}
# Corso GOMP il cui regolamento corrente è nuovo (code diverso) mentre le coorti precedenti stanno sotto un altro corso
# dello stesso ateneo: {ateneo: {code corrente: (code delle coorti precedenti, parte del nome dei percorsi da tenere)}}.
# (UniTus: la sede di Civitavecchia di Economia aziendale ha il suo regolamento solo dal 2026/27; gli anni 2 e 3 sono
# i percorsi «sede Civitavecchia» del corso «sedi di Viterbo e Civitavecchia».)
CORSI_COORTI_ALIAS = {"unitus": {"418": ("292", "civitavecchia")},
                      # UniCas: il riordino L-8 ha dato a «Ingegneria dell'Informazione» un codice nuovo; le coorti
                      # precedenti (2° e 3° anno) stanno nel corso «Ingegneria Informatica e delle Telecomunicazioni»
                      "unicas": {"7078^GEN^060019": ("7120", "")}}
# Abbinamento esplicito dei corsi del database ai corsi GOMP (codici), per i nomi che non coincidono: un omonimo di
# un'altra classe, il corso con la sede nel nome, o più corsi GOMP (uno per classe) fusi in un solo corso del database,
# che diventano percorsi con il nome della classe: {ateneo: {id corso del database: [codici GOMP]}}.
ABBINAMENTI_GOMP = {"unicas": {
    "unicas-l-9-ingegneria-gestionale": ["7098^GEN^060038"],
    "unicas-lm-33-mechanical-engineering": ["7094^GEN^060019"],
    "unicas-lm-35-lm-23-ingegneria-civile-per-l-ambiente-e-il-territorio": ["7002_23^GEN^060019", "7002_35^GEN^060019"],
    "unicas-lm-37-lm-38-lingue-e-letterature-moderne-per-i-servizi-interculturali-la": ["7006^COP^060019",
                                                                                      "7006_38^COP^060019"],
}}
# Atenei in cui insegnamenti con codici diversi e lo stesso nome nello stesso anno sono attività distinte (stesse
# etichette con CFU diversi, alternative di un gruppo): il nome le distingue e non sembrano doppioni.
NOMI_DISTINTI_PER_CODICE = {"unitus", "unicas"}
_LIBERA = re.compile(r"(?i)^\s*(a scelta\b|attivit[aà] (formative )?a scelta|insegnament[oi] a scelta|esam[ei] a scelta|"
                     r"crediti (liberi|a scelta)|corso a scelta|materia a scelta)")
# Etichette di crediti liberi in più (attività fisse del piano, non gruppi) per ateneo: «Elective classes», «Gruppo a scelta
# libera …», «15 CFU a scelta dello studente»: non sono insegnamenti obbligatori né hanno un codice proprio.
# Atenei (tra quelli per coorte) i cui regolamenti per a.a. sono l'erogato di quell'a.a. (gli anni insegnati allora; i
# corsi nuovi hanno solo gli anni già attivati): l'anno k è nel regolamento dell'a.a. corrente, se manca nel più recente
# precedente che lo ha. (UniCas: es. «Economics with data science», regolamento 2023 con il solo 1° anno, 2024 con 1-2.)
ANNI_EROGATO = {"unicas", "uniroma3", "unitus"}
# Atenei con nomi di percorso che contengono virgole («Narrazione, traduzione e nuove tecnologie»): la virgola diventa « - ».
PERCORSI_SENZA_VIRGOLE = {"unicas"}
LIBERA_EXTRA = {"unicas": re.compile(r"(?i)^\s*(\d+\s*cfu\s+a scelta\b|gruppo a scelta libera\b|elective classes\b)")}


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
    def __init__(self, base: str, rate: float = 3.0):
        self.base, self.s, self.lock, self.gap, self.last, self.requests = base, requests.Session(), threading.Lock(), \
            1.0 / rate, 0.0, 0

    def post(self, metodo: str, dati: dict) -> dict | None:
        for tentativo in range(4):
            with self.lock:
                attesa = self.last + self.gap - time.monotonic()
                if attesa > 0:
                    time.sleep(attesa)
                self.last = time.monotonic()
                self.requests += 1
            try:
                r = self.s.post(f"{self.base}/CourseAPI/{metodo}", json=dati, timeout=180,
                                headers={**HEADERS, "Accept": "application/json", "Content-Type": "application/json"})
                d = r.json()
                return d.get("data") if d.get("success") else None
            except (requests.RequestException, ValueError):
                time.sleep(2 ** tentativo)
        return None

    def corso(self, uid: str, anno: int) -> dict | None:
        return self.post("getCourse", {"mode": "CourseDetail", "uid": uid, "code": "", "academicYear": anno,
                                       "curricula": None, "years": None, "iso": "ita", "showCUINs": "False"})


def _libri(professori: list[dict]) -> list[dict]:
    libri, viste = [], set()
    for p in professori:
        for campo, tipo in (("books", "obbligatorio"), ("bibliography", "consigliato")):
            testo = _ita(p.get(campo)).replace("\n", "<br>")
            for lb in estrai_libri(testo):
                lb["tipo"] = lb["tipo"] or tipo
                k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
                if k not in viste:
                    viste.add(k)
                    libri.append(lb)
    return libri


def _attivita(a: dict) -> dict:
    cfu = sum(c.get("credits") or 0 for c in a.get("credits") or []) or None
    ssd = ", ".join(sorted({c.get("sector") for c in a.get("credits") or [] if c.get("sector")})) or None
    prof = [p for part in a.get("partitions") or [] for p in part.get("professors") or []]
    for figlio in a.get("children") or []:
        prof += [p for part in figlio.get("partitions") or [] for p in part.get("professors") or []]
    docenti = sorted({" ".join(w.capitalize() for w in f"{p.get('lastName', '')} {p.get('name', '')}".split())
                      for p in prof if p.get("lastName")})
    return {"codice": a.get("code"), "nome": _titolo(_ita(a.get("name"))), "cfu": int(cfu) if cfu and float(cfu).is_integer()
            else cfu, "ssd": ssd, "docenti": docenti, "libri": _libri(prof),
            "gruppo": bool(a.get("linkedGroup")) or a.get("type") not in (None, "activity")}


def _cfu_attivita(a: dict) -> float:
    return float(sum(c.get("credits") or 0 for c in a.get("credits") or []))


def _righe_anno(dati: dict, k: int, libera_extra=None, senza_virgole: bool = False) -> tuple[list[dict], set[str]]:
    """Righe dell'anno `k` del regolamento (tutti i curricula) e nomi dei curricula del regolamento.

    Un gruppo (`linkedGroup`) elenca nelle sue unità gli insegnamenti tra cui scegliere e i CFU da acquisire:
    si espande negli insegnamenti, da sostenere per intero (obbligatori) se i CFU del gruppo bastano per tutti,
    altrimenti a scelta. Un gruppo senza insegnamenti ("A scelta dello studente", "Tirocinio") resta una voce
    senza codice a scelta. Le righe hanno `_c` (curricula) e `_pc` (curricula del regolamento)."""
    curr_list = dati.get("curricula") or []
    def nome_percorso(cu: dict) -> str:
        # una virgola nel nome di un percorso lo farebbe leggere come due percorsi (pulizia.percorsi)
        n = _ita(cu.get("name"))
        return re.sub(r"\s*,\s*", " - ", n) if senza_virgole else n

    nomi_curr = {nome_percorso(cu) for cu in curr_list if len(curr_list) > 1 and nome_percorso(cu)}
    righe: dict[str, dict] = {}
    for cu in curr_list:
        nome_c = nome_percorso(cu) if len(curr_list) > 1 else None
        for y in cu.get("years") or []:
            if y.get("number") != k:
                continue
            gruppi: dict[str, dict] = {}
            semplici: list[tuple[dict, int | None]] = []
            for u in y.get("units") or []:
                for a in u.get("activities") or []:
                    if a.get("linkedGroup") or a.get("type") not in (None, "activity"):
                        g = gruppi.setdefault(a.get("linkedGroup") or a.get("uid") or _ita(a.get("name")),
                                              {"a": a, "cfu": 0.0, "figli": {}, "periodo": u.get("number")})
                        g["cfu"] = max(g["cfu"], _cfu_attivita(a))
                        for f in a.get("children") or []:
                            g["figli"].setdefault(f.get("code") or _norm(_ita(f.get("name"))), (f, u.get("number")))
                    else:
                        semplici.append((a, u.get("number")))
            voci: list[tuple[dict, int | None, bool]] = [(a, n, True) for a, n in semplici]
            for g in gruppi.values():
                if g["figli"]:
                    intero = 0 < g["cfu"] and sum(_cfu_attivita(f) for f, _ in g["figli"].values()) <= g["cfu"] + 1e-9
                    voci += [(f, n, intero) for f, n in g["figli"].values()]
                else:
                    voci.append((g["a"], g["periodo"], False))
            for a, n, obb in voci:
                x = _attivita(a)
                if not x["nome"]:
                    continue
                libera = bool(_LIBERA.search(x["nome"]) or (libera_extra and libera_extra.search(x["nome"])))
                codice = None if libera or not x["codice"] else x["codice"]
                key = f"{k}:{codice}" if codice else f"{k}:#{_norm(x['nome'])}:{x['cfu']}"
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": codice, "nome": x["nome"], "anno": k, "periodo": str(n) if n else None,
                        "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": bool(obb and not libera), "curriculum": None,
                        "docenti": x["docenti"], "libri": x["libri"], "_c": set(), "_pc": nomi_curr,
                    }
                else:
                    item["obbligatorio"] = item["obbligatorio"] or bool(obb and not libera)
                    for d in x["docenti"]:
                        if d not in item["docenti"]:
                            item["docenti"].append(d)
                    visti = {lb["citazione"] for lb in item["libri"]}
                    item["libri"] += [lb for lb in x["libri"] if lb["citazione"] not in visti]
                    item["ssd"] = item["ssd"] or x["ssd"]
                item["_c"].add(nome_c)
    return list(righe.values()), nomi_curr


def _nomi_distinti(righe: list[dict]) -> None:
    """Voci senza codice con lo stesso nome (es. «A scelta dello studente» di anni diversi) sono crediti liberi
    distinti: build_db unisce per nome le voci senza codice, quindi si distinguono per anno (e CFU)."""
    per_nome: dict[str, list[dict]] = {}
    for i in righe:
        if not i["codice"]:
            per_nome.setdefault(_norm(i["nome"]), []).append(i)
    for voci in per_nome.values():
        if len(voci) < 2:
            continue
        anni = {i["anno"] for i in voci}
        for i in voci:
            if len(anni) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        visti: dict[str, list[dict]] = {}
        for i in voci:
            visti.setdefault(_norm(i["nome"]), []).append(i)
        for gruppo in visti.values():
            if len(gruppo) > 1:
                for n, i in enumerate(sorted(gruppo, key=lambda i: (i["periodo"] or "", i["cfu"] or 0)), 1):
                    i["nome"] = f"{i['nome']} {n}"


def _nomi_distinti_codici(righe: list[dict]) -> None:
    """Insegnamenti con codici diversi, stesso anno e stesso nome (es. «Further Training Activities» da 12 o da 8 CFU,
    alternative di uno stesso gruppo): restano distinti e il nome indica i CFU (o il codice se i CFU sono uguali)."""
    per_nome: dict[tuple, list[dict]] = {}
    for i in righe:
        if i["codice"]:
            per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
    for voci in per_nome.values():
        if len({i["codice"] for i in voci}) < 2:
            continue
        cfu = {i["cfu"] for i in voci}
        for i in voci:
            if len(cfu) == len(voci) and i["cfu"]:
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            else:
                i["nome"] = f"{i['nome']} (cod. {i['codice']})"


def fetch_gomp(uid: str, anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
               corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    base = HOSTS[uid]
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    api = Api(base)
    oggi = time.strftime("%Y-%m-%d")
    elenco = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": anno,
                                                   "courseTypes": ["CorsoDiStudio"]}) or {}
    gomp = [c for s in elenco.get("data") or [] for c in s.get("courses") or []]
    per_nome: dict[str, list[dict]] = {}
    for g in gomp:
        for n in {_norm(_ita(g.get("name"))), _norm(" ".join(t.get("text") or "" for t in g.get("name") or []
                                                             if t.get("iso") == "eng"))}:
            if n:
                per_nome.setdefault(n, []).append(g)
    abbinati = []
    forzati = ABBINAMENTI_GOMP.get(uid, {})
    per_codice = {g.get("code"): g for g in gomp}
    for corso in corsi:
        if corso["id"] in forzati:
            gl = [per_codice[c] for c in forzati[corso["id"]] if c in per_codice]
            if gl:
                abbinati.append((corso, gl[0] if len(gl) == 1 else gl))
            continue
        cand = per_nome.get(_norm(corso["nome"])) or per_nome.get(_norm(corso.get("nome_en") or "")) or []
        cl = {x.strip() for x in (corso.get("classe") or "").split("/")}
        both = [g for g in cand if {re.sub(r"\s+R$", "", x) for x in g.get("classes") or []} & cl] or cand
        if both:
            abbinati.append((corso, both[0]))
    if max_cds:
        abbinati = abbinati[:max_cds]
    log(f"[{uid}] {len(gomp)} corsi in GOMP, {len(abbinati)} associati al database (su {len(corsi)})")

    coorte_elenco: dict[int, list[dict]] = {}
    if uid in ANNI_PER_COORTE and abbinati:
        for a in range(anno - 1, anno - max((c.get("durata_anni") or g.get("years") or 3) for c, g in abbinati), -1):
            els = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": a,
                                                        "courseTypes": ["CorsoDiStudio"]}) or {}
            coorte_elenco[a] = [c for s in els.get("data") or [] for c in s.get("courses") or []]
        log(f"[{uid}] coorti: " + ", ".join(f"{a}: {len(v)} corsi" for a, v in sorted(coorte_elenco.items())))

    def coorte_corso(g: dict, a: int) -> dict | None:
        """Corso della coorte `a` che corrisponde al corso `g` dell'a.a. corrente: stesso `code`; se il codice è
        cambiato con il riordino, stesso nome e stessa classe."""
        if a == anno:
            return g
        elenco_a = coorte_elenco.get(a) or []
        for c in elenco_a:
            if c.get("code") == g.get("code"):
                return c
        alias = CORSI_COORTI_ALIAS.get(uid, {}).get(g.get("code"))
        if alias:
            for c in elenco_a:
                if c.get("code") == alias[0]:
                    return c
        nomi = {_norm(t.get("text") or "") for t in g.get("name") or [] if t.get("text")}
        cl = {re.sub(r"\s+R$", "", x) for x in g.get("classes") or []}
        for c in elenco_a:
            if nomi & {_norm(t.get("text") or "") for t in c.get("name") or []} and (
                    not cl or not c.get("classes") or cl & {re.sub(r"\s+R$", "", x) for x in c["classes"]}):
                return c
        return None

    def build_coorti(corso: dict, g: dict) -> dict | None:
        durata = corso.get("durata_anni") or g.get("years") or 3
        piani: dict[int, tuple[str, dict] | None] = {}

        def piano(a: int, corso_alias: bool = False):
            """Regolamento dell'a.a. `a`; con `corso_alias` quello (dello stesso a.a.) del corso GOMP che precede
            il corso `g` nel riordino (vedi CORSI_COORTI_ALIAS)."""
            if corso_alias:
                alias = CORSI_COORTI_ALIAS.get(uid, {}).get(g.get("code"))
                c = next((x for x in (gomp if a == anno else coorte_elenco.get(a, []))
                          if alias and x.get("code") == alias[0]), None)
                dati = api.corso(c["uid"], a) if c else None
                if dati:
                    dati = {**dati, "curricula": [cu for cu in dati.get("curricula") or []
                                                  if alias[1] in _ita(cu.get("name")).lower()]}
                return (c["uid"], dati) if dati else None
            if a not in piani:
                c = coorte_corso(g, a)
                dati = api.corso(c["uid"], a) if c else None
                alias = CORSI_COORTI_ALIAS.get(uid, {}).get(g.get("code"))
                if dati and alias and c.get("code") == alias[0]:  # solo i percorsi della sede di questo corso
                    dati = {**dati, "curricula": [cu for cu in dati.get("curricula") or []
                                                  if alias[1] in _ita(cu.get("name")).lower()]}
                piani[a] = (c["uid"], dati) if dati else None
            return piani[a]

        fonte0 = f"{base}/PublicData?uid={g['uid']}&mode=CourseDetail&iso=ita&academicYear={anno}"
        righe, curricula = [], set()
        for k in range(1, durata + 1):
            # piano dell'anno k: coorte (anno - k + 1); se non c'è o non ha quell'anno, la coorte più vicina
            # (a parità la più recente) che lo ha
            cohorts = sorted(range(anno - durata + 1, anno + 1), key=lambda a: (abs(a - (anno - k + 1)), -a))
            tentativi = [(a, False) for a in cohorts]
            if uid in ANNI_EROGATO:
                # i regolamenti per a.a. sono l'erogato di quell'a.a. (gli anni insegnati allora, non il piano della
                # coorte): l'anno k è nel regolamento dell'a.a. corrente (o del corso che precede nel riordino); se
                # non c'è, nel più recente precedente che lo ha
                tentativi = []
                for a in range(anno, anno - durata, -1):
                    tentativi += [(a, False)] + ([(a, True)] if g.get("code") in CORSI_COORTI_ALIAS.get(uid, {}) else [])
            for a, al in tentativi:
                if a != anno and a not in coorte_elenco:
                    continue
                p = piano(a, al)
                if not p:
                    continue
                rk, nomi = _righe_anno(p[1], k, LIBERA_EXTRA.get(uid), uid in PERCORSI_SENZA_VIRGOLE)
                if not rk:
                    continue
                fonte = f"{base}/PublicData?uid={p[0]}&mode=CourseDetail&iso=ita&academicYear={a}"
                for i in rk:
                    cs = i.pop("_c")
                    pc = i.pop("_pc")
                    if None not in cs and pc and cs != pc:
                        i["curriculum"] = ", ".join(sorted(cs))
                    i.update({"url": fonte, "esami": [], "fonte": fonte, "verificato_il": oggi})
                    if syllabus:
                        i["stato_libri"] = "completo" if i["libri"] else "da_aggiungere"
                curricula |= nomi
                righe += rk
                break
        if uid in ANNI_EROGATO and syllabus:
            # testi mancanti nel regolamento corrente: quelli dello stesso insegnamento (stesso codice) nei
            # regolamenti degli a.a. precedenti dello stesso corso (il più recente che li ha)
            altri: dict[str, list[dict]] = {}
            for a in range(anno, anno - durata, -1):
                if a != anno and a not in coorte_elenco:
                    continue
                for al in (False, True) if g.get("code") in CORSI_COORTI_ALIAS.get(uid, {}) else (False,):
                    p = piano(a, al)
                    for k in range(1, durata + 1) if p else ():
                        for i in _righe_anno(p[1], k)[0]:
                            if i["codice"] and i["libri"]:
                                altri.setdefault(i["codice"], i["libri"])
            for i in righe:
                if not i["libri"] and i["codice"] in altri:
                    i["libri"], i["stato_libri"] = altri[i["codice"]], "completo"
        _nomi_distinti(righe)
        if uid in NOMI_DISTINTI_PER_CODICE:
            _nomi_distinti_codici(righe)
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": fonte0, "curricula": sorted(curricula) or None, "fonte": fonte0, "verificato_il": oggi,
                "insegnamenti": righe}

    def build_classi(corso: dict, gl: list[dict]) -> dict | None:
        """Più corsi GOMP (uno per classe) fusi in un solo corso del database: ogni corso GOMP è un percorso,
        col nome della classe (es. «LM-23 - Ingegneria Civile»)."""
        parti, righe, curricula = [], [], set()
        for g in gl:
            r = build_coorti(corso, g)
            m = re.search(r"(LM|L)[- ]?(\d+)\s*-\s*(.+)$", _ita(g.get("name")))
            etichetta = f"{m.group(1)}-{m.group(2)} - {m.group(3).strip()}" if m else _ita(g.get("name"))
            if not r:
                continue
            for i in r["insegnamenti"]:
                i["curriculum"] = f"{etichetta}: {i['curriculum']}" if i.get("curriculum") else etichetta
            parti.append(r)
            righe += r["insegnamenti"]
            curricula.add(etichetta)
        if not parti:
            return None
        return {**parti[0], "curricula": sorted(curricula), "insegnamenti": righe}

    def build(coppia) -> dict | None:
        corso, g = coppia
        if isinstance(g, list):
            return build_classi(corso, g)
        if uid in ANNI_PER_COORTE:
            return build_coorti(corso, g)
        attuale = api.corso(g["uid"], anno)
        if not attuale:
            return None
        # Il "CourseDetail" pubblico mostra, per ogni regolamento, solo gli anni già pubblicati
        # (di fatto il 1° anno della coorte): gli anni successivi dell'a.a. corrente non sono
        # nei regolamenti delle coorti precedenti e restano da aggiungere.
        coorti = {anno: attuale}
        durata = corso.get("durata_anni") or g.get("years") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        fonte = f"{base}/PublicData?uid={g['uid']}&mode=CourseDetail&iso=ita&academicYear={anno}"
        for k in range(1, durata + 1):
            dati = coorti.get(anno - k + 1)
            if isinstance(dati, str):
                dati = api.corso(dati, anno - k + 1)
            if not dati:
                continue
            curr_list = dati.get("curricula") or []
            for cu in curr_list:
                nome_c = _ita(cu.get("name"))
                if nome_c and len(curr_list) > 1:
                    curricula.add(nome_c)
                for y in cu.get("years") or []:
                    if y.get("number") != k:
                        continue
                    for u in y.get("units") or []:
                        for a in u.get("activities") or []:
                            x = _attivita(a)
                            if not x["nome"]:
                                continue
                            key = f"{k}:{x['codice'] or x['nome']}"
                            item = righe.get(key)
                            if not item:
                                item = righe[key] = {
                                    "codice": x["codice"], "nome": x["nome"], "anno": k,
                                    "periodo": str(u.get("number")) if u.get("number") else None, "cfu": x["cfu"],
                                    "ssd": x["ssd"], "obbligatorio": not x["gruppo"], "curriculum": None,
                                    "docenti": x["docenti"], "url": fonte, "libri": x["libri"], "esami": [],
                                    "fonte": fonte, "verificato_il": oggi, "_c": set(),
                                }
                                if syllabus:
                                    item["stato_libri"] = "completo" if x["libri"] else "da_aggiungere"
                            item["_c"].add(nome_c if len(curr_list) > 1 else None)
        for i in righe.values():
            cs = i.pop("_c")
            if None not in cs and curricula and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": fonte, "curricula": sorted(curricula) or None, "fonte": fonte, "verificato_il": oggi,
                "insegnamenti": list(righe.values())}

    def build_safe(coppia) -> dict | None:
        try:
            return build(coppia)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {coppia[0].get('id')} saltato: {e!r}")
            return None

    out = []
    with cf.ThreadPoolExecutor(3) as ex:
        for n, r in enumerate(ex.map(build_safe, abbinati), 1):
            if r:
                out.append(r)
            if n % 10 == 0:
                log(f"[{uid}]   corsi {n}/{len(abbinati)}")
    libri = sum(len(i["libri"]) for x in out for i in x["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {libri}; "
        f"richieste: {api.requests}")
    return {"universita_id": uid, "descrizione": f"Generato dall'API pubblica GOMP {base} (adapters/gomp.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def fetch_ateneo(uid: str, anno: int | None = None, **kw) -> dict:
    return fetch_gomp(uid, anno, **kw)


def _data_gomp(s: str | None) -> tuple[str | None, str | None]:
    m = re.match(r"(\d{4}-\d{2}-\d{2})(?:T(\d{2}:\d{2}))?", s or "")
    return (m.group(1), m.group(2) if m and m.group(2) != "00:00" else None) if m else (None, None)


def fetch_appelli(uid: str, corsi: list[dict] | None = None, anno: int | None = None, log=print) -> dict[str, list[dict]]:
    """Appelli dalle schede pubbliche dei docenti (`getProfessor` → `appelliList`), per codice insegnamento.

    Solo alcuni atenei li pubblicano (Cassino sì; Roma Tre, Tor Vergata, Tuscia no). I docenti
    sono quelli dei corsi dell'a.a. nell'API pubblica.
    """
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    base = HOSTS[uid]
    api = Api(base)
    elenco = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": anno,
                                                   "courseTypes": ["CorsoDiStudio"]}) or {}
    profs: set[str] = set()

    def raccogli(o) -> None:
        if isinstance(o, dict):
            profs.update(p["uid"] for p in o.get("professors") or [] if p.get("uid"))
            for v in o.values():
                raccogli(v)
        elif isinstance(o, list):
            for v in o:
                raccogli(v)

    with cf.ThreadPoolExecutor(3) as ex:
        for d in ex.map(lambda g: api.corso(g["uid"], anno),
                        [c for s in elenco.get("data") or [] for c in s.get("courses") or []]):
            raccogli(d)
    fonte = f"{base}/PublicData"

    def appelli(p: str) -> list[dict]:
        for tentativo in range(3):
            try:
                r = api.s.post(f"{base}/CourseAPI/getProfessor", timeout=120,
                               json={"mode": "professorDetail", "uid": p, "code": "", "academicYear": anno, "name": "",
                                     "lastName": "", "iso": "ita"},
                               headers={**HEADERS, "Accept": "application/json", "Content-Type": "application/json"})
                with api.lock:
                    api.requests += 1
                d = r.json()
                return [{**a, "_doc": " ".join(w.capitalize() for w in
                                               f"{(d.get('data') or {}).get('lastName', '')} "
                                               f"{(d.get('data') or {}).get('name', '')}".split()) or None}
                        for a in d.get("appelliList") or []]
            except (requests.RequestException, ValueError):
                time.sleep(2 ** tentativo)
        return []

    out: dict[str, dict[tuple, dict]] = {}
    with cf.ThreadPoolExecutor(3) as ex:
        for lst in ex.map(appelli, sorted(profs)):
            for a in lst:
                data, ora = _data_gomp(a.get("DataAppello"))
                if not data:
                    continue
                prove = [n for k, n in (("valutazioneProvaScritta", "scritto"), ("valutazioneProvaOrale", "orale"),
                                        ("valutazioneTestAttitudinale", "quiz"), ("valutazioneProgetto", "progetto"))
                         if a.get(k)]
                e = {"tipo": "appello", "titolo": None, "data": data, "ora": ora, "luogo": (a.get("Aula") or "").strip() or None,
                     "modalita": "scritto+orale" if prove == ["scritto", "orale"] else (prove[0] if len(prove) == 1 else
                                                                                       ("altro" if prove else None)),
                     "iscrizioni_dal": _data_gomp(a.get("dataInizioPrenotazione"))[0],
                     "iscrizioni_al": _data_gomp(a.get("dataFinePrenotazione"))[0],
                     "docenti": a["_doc"], "note": (a.get("TipoSessione") or "").strip() or None, "fonte": fonte}
                for ins in a.get("Insegnamenti") or []:
                    if ins.get("CodiceInsegnamento"):
                        e2 = dict(e, titolo=_titolo(ins.get("DenominazioneInsegnamento") or "") or None)
                        out.setdefault(str(ins["CodiceInsegnamento"]), {})[(a.get("AppelloID"), data, ora)] = e2
    res = {k: sorted(v.values(), key=lambda e: (e["data"], e["ora"] or "")) for k, v in out.items()}
    log(f"[{uid}] appelli GOMP: {len(profs)} docenti, {sum(len(v) for v in res.values())} date per {len(res)} "
        f"insegnamenti; richieste: {api.requests}")
    return res
