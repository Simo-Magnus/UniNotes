"""IUAV di Venezia: piani di studio per coorte, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://iuav.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) il catalogo dello IUAV richiede:

- un corso per ogni corso di Universitaly (tabella `CORSI`: id Universitaly → catena dei codici del catalogo, dal più recente
  al più vecchio). Ogni riordino o coorte di un corso ha un codice nuovo (Architettura L-17: «B07» coorte 2022-2024, «B08»
  coorte 2025, «B09» coorte 2026) e il piano completo (tutti gli anni) è pubblicato solo nella coorte in cui il codice è nato:
  `/corso/2026/B07` è vuoto, il piano di chi si è iscritto nel 2024 è `/corso/2024/B07`. L'adattatore comune cercava lo stesso
  codice nelle coorti precedenti, non lo trovava e usava per tutti gli anni il piano della coorte 2026 (anni 2° e 3° di
  un'altra coorte, insegnamenti dell'ordinamento 2026 mescolati con quelli del 2024). Qui per l'anno di corso k nell'a.a. A si
  legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno) col primo codice della catena che in quella coorte ha
  il piano con quell'anno; se la coorte non c'è (il ciclo unico di Architettura N40 parte dal 2024: il 4° e il 5° anno non hanno
  ancora iscritti) si usa la coorte più vicina che ha quell'anno e l'anno è segnalato in `anni_da_altra_coorte`;
- un unico corso per «Architettura» a ciclo unico (N40/N41/N42 sono la stessa laurea in tre coorti: prima il catalogo creava
  anche un secondo corso «…-n42» e il piano della sola coorte 2026) e per Curatela delle Arti (il catalogo la chiama in
  italiano, Universitaly con il titolo inglese: è lo stesso corso, «CURATING ARTS AND HERITAGE…» nel catalogo);
- prova finale e tirocinio: i piani delle coorti meno recenti (ordinamenti 2013-2022, e alcune del 2025) li mettono nell'anno 1
  del catalogo; sono attività dell'ultimo anno (Manifesto degli studi: «Prova finale» all'ultimo anno, «Sessioni di Laurea»;
  Design della moda: «Tirocinio» al 3° anno). La prova finale è sempre messa nell'ultimo anno; il tirocinio, se il catalogo lo
  mette in un altro anno di una coorte letta per l'ultimo anno (e non per il 1°), si aggiunge anche all'ultimo anno;
- durata dal tipo del catalogo (L2 3, LM 2, LM5 5): l'elenco minimale non ha `durataAnni`;
- percorsi: riconosciuti tra le coorti per il codice del percorso (`pdsCod`: ARTI, COM, MODA, MAT, I_DES, P_VDES, COMU, INT,
  PROD, UPT_ENG_1, UPT_ITA), il nome senza «Percorso»; con un solo percorso nessun curriculum («PERCORSO COMUNE», «GGG»);
- tipo di insegnamento del catalogo: OBB obbligatorio, OPZ opzionale o scelto fra alternative (laboratori integrati
  alternativi, attività affini «obbligatorie in alternativa», TAF D, tirocinio interno/estero in alternativa): a scelta;
- attività a 0 CFU (OFA e simili): non sono insegnamenti del piano e si tolgono;
- stesso codice obbligatorio in un percorso e a scelta in un altro: due righe (build_db le tiene separate se i curricula sono
  disgiunti), altrimenti una sola, obbligatoria;
- alternative omonime nello stesso anno e curriculum: con CFU diversi il nome porta i CFU, altrimenti il codice;
- libri: quelli già raccolti per lo stesso codice nel database non si rileggono; gli altri dal syllabus.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte restano su disco (`iuav_cc`). Richieste: 4 al secondo.

Esecuzione locale (scrive `database/contrib/auto/iuav.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/iuav.py [--senza-syllabus]
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
import unicodedata

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402

BASE = "https://iuav.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 4.0
TIPI = {"L2", "LM", "LM5"}
DURATA_TIPO = {"L2": 3, "LM": 2, "LM5": 5}

# Un corso per ogni corso di Universitaly: id Universitaly → (id del corso nel database, codici del corso nel catalogo, dal più
# recente al più vecchio). Ogni coorte ha il suo codice quando il piano cambia (riordino): vedi la docstring.
CORSI = {
    "1627303": ("iuav-l-17-architettura", ["B09", "B08", "B07"]),                  # Architettura (L-17)
    "1627296": ("iuav-l-4-design", ["G13", "G10", "G03"]),                          # Design, sede di Vicenza (L-4)
    "1627292": ("iuav-l-4-design-del-prodotto-della-comunicazione-visiva-e-degli-inter", ["G12", "G07", "G02"]),
    "1627300": ("iuav-l-4-design-della-moda-e-arti-multimediali", ["B10", "B05", "B04"]),
    "1627306": ("iuav-l-21-urbanistica-e-pianificazione-del-territorio", ["G14", "G11", "G09"]),
    "1627309": ("iuav-lm-4-architecture", ["B84", "B81", "B77"]),                   # Architecture (LM-4, in inglese)
    "1627313": ("iuav-lm-4-architettura", ["B83", "B82", "B79"]),                   # Architettura (LM-4)
    "1627343": ("iuav-lm-65-arti-visive-e-cinema-espanso", ["B89", "B86", "B85"]),
    "1627353": ("iuav-lm-89-curating-arts-and-heritage-in-intercultural-perspectives", ["B88", "B87"]),
    "1627318": ("iuav-lm-12-design-del-prodotto-della-comunicazione-e-degli-interni", ["G82", "G74", "G72"]),
    "1627333": ("iuav-lm-35-ingegneria-per-le-energie-rinnovabili-in-ambienti-costieri", ["N36", "N35"]),
    "1627328": ("iuav-lm-23-mobilita-sostenibile-e-connessioni-intelligenti-in-ambienti", ["N24", "N23"]),
    "1631079": ("iuav-lm-12-moda", ["N13", "N12"]),
    "1627347": ("iuav-lm-65-teatro-e-arti-performative", ["G83", "G78", "G77"]),
    "1627336": ("iuav-lm-48-urbanistica-e-pianificazione-del-territorio", ["G81", "G80", "G79"]),
    "1627362": ("iuav-lm-4-c-u-architettura", ["N42", "N41", "N40"]),               # Architettura a ciclo unico (LM-4 c.u.)
}
ANNI_COORTI = 6  # coorti lette prima di quella attuale (il ciclo unico dura 5 anni)


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


_ACCENTATE = {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}


def _nome_att(des: str | None) -> str:
    """Nome dell'attività: iniziali maiuscole, numeri romani e accenti scritti con l'apostrofo («CITTA'» → «Città»)."""
    s = re.sub(r"\s+", " ", des or "").strip()
    if s.isupper():
        s = cc._titolo(s)
        s = re.sub(r"\b(Ii|Iii|Iv|Vi|Vii|Viii|Ix)\b(?=[\s:.,)]|$)", lambda m: m.group(1).upper(), s)
        # «Dell'architettura» → «dell'Architettura» (l'articolo con l'apostrofo resta minuscolo, il nome ha l'iniziale)
        s = re.sub(r"\b(Dell|Nell|Sull|Dall|All|Coll|Un|Quest|Quell|D)'([a-z])",
                   lambda m: m.group(1).lower() + "'" + m.group(2).upper(), s)
    return re.sub(r"(?<=[A-Za-z])([aeiouAEIOU])'(?=\s|$|[,.;:)])",
                  lambda m: _ACCENTATE[m.group(1).lower()], s)


def _nome_percorso(p: dict) -> str:
    n = re.sub(r"\s+", " ", p.get("des_it") or p.get("pdsDes") or "").strip()
    n = re.sub(r"(?i)^percorso\s+", "", n)
    if n.isupper() and len(n) > 3:
        n = cc._titolo(n)
        n = re.sub(r"\b(Ms|Upt)\b", lambda m: m.group(1).upper(), n)
        n = re.sub(r"(?<=\s)(And|For|Of|The|In|To)\b", lambda m: m.group(1).lower(), n)
    return n[:1].upper() + n[1:]


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/iuav_cc)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "iuav_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


_PROVA_FINALE = re.compile(r"(?i)prova finale|final (?:thesis|exam|examination|project)|\btesi\b")
_TIROCINIO = re.compile(r"(?i)\btirocinio\b|\binternship\b")


def _senza_anno(g: dict, att: dict) -> str | None:
    """«prova» per la prova finale, «tirocinio» per il tirocinio (anche «interno»/«estero»): nel catalogo i piani meno
    recenti li mettono nell'anno 1, ma sono attività dell'ultimo anno (Manifesto degli studi: «Prova finale» all'ultimo anno,
    «Sessioni di Laurea»; tirocinio dell'ultimo anno nel Design della moda)."""
    etichetta = g.get("label_it") or ""
    nome = att.get("des_it") or ""
    if _PROVA_FINALE.search(etichetta) or _PROVA_FINALE.search(nome):
        return "prova"
    if _TIROCINIO.search(etichetta) or _TIROCINIO.search(nome):
        return "tirocinio"
    return None


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _anni(d: dict) -> set[int]:
    """Anni di corso per cui il piano ha almeno un'attività con CFU."""
    out = set()
    for p in d.get("percorsi") or []:
        for a in p.get("anni") or []:
            if str(a.get("anno")).isdigit() and any(t.get("crediti") for g in _gruppi(a) for t in g.get("attivita") or []):
                out.add(int(a["anno"]))
    return out


def _sede(cur: dict) -> str | None:
    """«VENEZIA (VE)» → «Venezia (VE)»."""
    s = cur.get("sedeDenominazioneComune") or cur.get("sede_des_it")
    if not s:
        return None
    m = re.fullmatch(r"(.+?)\s*\((\w+)\)", s.strip())
    return f"{m.group(1).title()} ({m.group(2).upper()})" if m else s.strip().title()


def fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - ANNI_COORTI, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI}
    attuali = list(CORSI.items())[:max_cds] if max_cds else list(CORSI.items())
    log(f"[{uid}] {len(attuali)} corsi da leggere (coorti {anno - ANNI_COORTI}-{anno})")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    corsi_out: list[dict] = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(voce: tuple[str, tuple[str, list[str]]]) -> dict | None:
        id_ul, (id_corso, catena) = voce
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - ANNI_COORTI, anno + 1):
            for cod in catena:  # il primo codice della catena che in quella coorte ha il piano con gli anni
                x = coorti[y].get(cod)
                d = dettaglio(y, x) if x else None
                if d and _anni(d):
                    cohorts[y] = (x, d)
                    break
        if not cohorts:
            return None
        ultima = max(cohorts)
        cur = cohorts[ultima][0]
        durata = DURATA_TIPO.get(cur.get("tipo_corso_cod"), 3)
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cohorts[anno][0].get('cod')}")

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            ha = [y for y, (_, d) in cohorts.items() if k in _anni(d)]
            if not ha:
                return None
            if y0 in ha:
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        insegnamenti: dict[tuple, dict] = {}
        curricula_usati: set[str] = set()
        prova_da: dict[str, int] = {}
        coorti_anno: dict[int, int] = {}
        piano_anni: dict[str, dict] = {}
        cfu_noti: dict[str, float] = {}
        for _, d in cohorts.values():
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        def aggiungi(k, att, scelta, x, pcur, tutti, gruppo=None, canali=()):
            ad = att.get("adCod") or att.get("cod")
            obbl = str(att.get("tipo_ins_cod") or "").upper().startswith("OBB") or bool(canali)
            key = (k, ad, obbl)
            item = insegnamenti.get(key)
            if not item:
                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                for altro in canali:  # canali dello stesso insegnamento: i docenti di tutti
                    docenti += [cc._nome(t.get("des")) for t in altro.get("docenti") or [] if t.get("des")]
                periodo = cc._periodo(att.get("periodo_didattico_it"))
                if periodo and periodo.lower().startswith("periodo intensivo"):
                    periodo = None  # le date del periodo restano in periodo_inizio/fine
                nome = _nome_att(att.get("des_it") or ad)
                if gruppo and re.search(r"(?i)altra tipologia", gruppo.get("label_it") or "") and                         _norm(nome) == "internship":
                    nome = "In-house Internship"  # il catalogo lo chiama come il tirocinio obbligatorio (G81186: «In-house»)
                item = {
                    "codice": ad, "nome": nome, "anno": k,
                    "periodo": periodo,
                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                    "cfu": att.get("crediti") or cfu_noti.get(ad), "ssd": None, "obbligatorio": obbl, "curriculum": None,
                    "_percorsi": set(), "_tutti": set(tutti), "docenti": sorted(set(docenti)),
                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                }
                if canali:
                    item["codici_alternativi"] = [t.get("adCod") or t.get("cod") for t in canali]
                insegnamenti[key] = item
                if syllabus:
                    for t in (att, *canali):
                        syllabus_jobs.setdefault((str(t.get("aa")), str(t.get("cod"))), {
                            "params": {"anno": t.get("aa"), "insegnamento": t.get("cod"),
                                       "ordinamento_aa": t.get("ordinamento_aa"),
                                       "af_percorso": t.get("corso_percorso_id"),
                                       "corso_cod": t.get("corso_cod"), "corso_aa": scelta,
                                       "schema_id": t.get("schemaId")},
                            "items": [], "codice": t.get("adCod") or t.get("cod")})["items"].append(item)
            else:
                item["_tutti"] |= set(tutti)
                if not item["docenti"] and not canali:
                    item["docenti"] = sorted({cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")})
            if pcur:
                item["_percorsi"].add(pcur)

        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            coorti_anno[k] = scelta
            x, d = cohorts[scelta]
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(str(a.get("anno")) == str(k) for a in p.get("anni") or [])]
            multi = len(d.get("percorsi") or []) >= 2  # un solo piano: vale per tutti, nessun curriculum
            curricula = {_nome_percorso(p) for p in percorsi_k} if multi else set()
            curricula_usati |= curricula
            for p in percorsi_k:
                pcur = _nome_percorso(p) if multi else None
                for a in p.get("anni") or []:
                    if not str(a.get("anno")).isdigit():
                        continue
                    stesso = str(a.get("anno")) == str(k)
                    for g in _gruppi(a):
                        atts = [t for t in g.get("attivita") or []
                                if t.get("crediti") or cfu_noti.get(t.get("adCod") or t.get("cod"))]
                        # gruppo i cui insegnamenti hanno tutti lo stesso nome e gli stessi CFU: sono i canali dello stesso
                        # insegnamento (Laboratorio di Progetto 2 di Architettura: sei codici, «obbligatorio» nel Manifesto
                        # degli studi), uno solo da frequentare: una riga obbligatoria con i docenti di tutti i canali
                        canali = len(atts) >= 2 and len({_nome_att(t.get("des_it")) for t in atts}) == 1 and                             len({t.get("crediti") for t in atts}) == 1
                        for n, att in enumerate(atts):
                            if canali and n:
                                continue
                            tipo = _senza_anno(g, att)
                            gc = tuple(atts[1:]) if canali else ()
                            if stesso and not (tipo == "prova" and k < durata):
                                aggiungi(k, att, scelta, x, pcur, curricula, g, gc)
                            elif not stesso and k == durata and tipo and coorte_anno(1) != scelta:
                                # prova finale e tirocinio messi dal catalogo in un altro anno (di solito l'1°): ultimo anno
                                aggiungi(k, att, scelta, x, pcur, curricula, g, gc)
            if k == durata:
                # la coorte ha il gruppo «PROVA FINALE» vuoto (l'attività non è stata inserita nel catalogo): la prova finale
                # della coorte più vicina dello stesso corso (a parità di distanza, con lo stesso ordinamento), stessi CFU
                hanno = {pc for (kk, _, _), it in insegnamenti.items() if kk == k and "prova finale" in _norm(it["nome"])
                         for pc in (it["_percorsi"] or {None})}
                for p in percorsi_k:
                    pcur = _nome_percorso(p) if multi else None
                    vuoto = any(not g.get("attivita") and _PROVA_FINALE.search(g.get("label_it") or "")
                                for a in p.get("anni") or [] for g in _gruppi(a))
                    if not vuoto or pcur in hanno:
                        continue
                    altre = sorted((y for y in cohorts if y != scelta), key=lambda y: (
                        abs(y - scelta), cohorts[y][1].get("ordinamento_aa") != d.get("ordinamento_aa"), -y))
                    for y in altre:
                        trovate = [(att, g) for q in cohorts[y][1].get("percorsi") or []
                                   if not multi or _nome_percorso(q) == pcur
                                   for a in q.get("anni") or [] if str(a.get("anno")).isdigit()
                                   for g in _gruppi(a) for att in g.get("attivita") or []
                                   if _senza_anno(g, att) == "prova" and att.get("crediti")]
                        if trovate:
                            for att, g in trovate[:1]:
                                att = dict(att)
                                ad = att.get("adCod") or ""
                                src, dst = cohorts[y][0].get("cdsCod"), x.get("cdsCod")
                                if src and dst and ad.startswith(src):  # B89031 → B86031 (codice della prova finale della coorte)
                                    att["adCod"] = dst + ad[len(src):]
                                aggiungi(k, att, y, cohorts[y][0], pcur, curricula, g)
                            prova_da[str(k)] = y
                            break
        ins = _rifinisci(list(insegnamenti.values()))
        out = {
            "id": id_corso, "id_universitaly": id_ul,
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or next(
                (d.get("classe_cod") for _, d in cohorts.values() if d.get("classe_cod")), None)),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(cur),
            "codice_ateneo": catena[0],
            "url": f"{base}/corsi/{ultima}/{cur.get('cod')}",
            "curricula": sorted(curricula_usati) or None,
            "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        if prova_da:  # prova finale presa dalla scheda di un'altra coorte (nella propria il gruppo è vuoto)
            out["prova_finale_da_altra_coorte"] = prova_da
        coorte_diversa = {k: y for k, y in coorti_anno.items() if y != anno - k + 1}
        if coorte_diversa:  # anni letti da un'altra coorte (piano della coorte più vicina)
            out["anni_da_altra_coorte"] = {str(k): y for k, y in sorted(coorte_diversa.items())}
        return out

    def build_safe(voce) -> dict | None:
        try:
            return build_cds(voce)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {voce[0]} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        noto = libri_noti.get(job.get("codice"))
        if noto and noto.get("libri"):  # libri già raccolti per questo codice: non si rileggono
            for it in job["items"]:
                it["libri"] = noto["libri"]
                it["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        it[k_] = noto[k_]
            return len(noto["libri"])
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, legati = cc._testi_syllabus(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cc.leganto.libri(u)
        ssd = sy.get("ssd")
        for it in job["items"]:
            if not libri and it["libri"]:  # (canali: i libri del canale che li ha)
                continue
            it["libri"] = libri
            it["stato_libri"] = "completo" if libri else "da_aggiungere"
            if modalita:
                it["modalita_esame"] = modalita
            if ssd:
                it["ssd"] = ssd
            if sy.get("urlSitoWeb"):
                it["url_sito"] = sy["urlSitoWeb"].strip()
        return len(libri)

    trovati = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, syllabus_jobs.values()), 1):
            trovati += n
            if i % 500 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    # insegnamento senza libri nella sua scheda, ma con libri nella scheda dello stesso insegnamento (stesso nome) di un'altra
    # coorte dello stesso corso (codici B07xxx / B08xxx / B09xxx): stessi libri (la scheda della coorte più vicina)
    for corso in corsi_out:
        per_nome: dict[str, dict] = {}
        for i in corso["insegnamenti"]:
            if i["libri"]:
                per_nome.setdefault(_norm(i["nome"]), i)
        for i in corso["insegnamenti"]:
            fonte_i = per_nome.get(_norm(i["nome"]))
            if not i["libri"] and fonte_i and fonte_i["codice"] != i["codice"]:
                i["libri"] = fonte_i["libri"]
                i["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if fonte_i.get(k_) and not i.get(k_):
                        i[k_] = fonte_i[k_]
    for corso in corsi_out:  # i campi di lavoro non vanno nel contributo
        for i in corso["insegnamenti"]:
            i.pop("_tutti", None)
            i.pop("_percorsi", None)
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/iuav.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _rifinisci(ins: list[dict]) -> list[dict]:
    """Curricula e alternative omonime."""
    for i in ins:
        ps, tutti = i["_percorsi"], i["_tutti"]
        if ps and ps != tutti:
            i["curriculum"] = ", ".join(sorted(ps))
        i["_ps"] = ps
    # stesso codice obbligatorio in un percorso e a scelta nello stesso percorso: la voce a scelta si tiene solo dove non è
    # obbligatorio
    per_cod: dict[tuple, list] = {}
    for i in ins:
        per_cod.setdefault((i["anno"], i["codice"]), []).append(i)
    for righe in per_cod.values():
        obbl = [r for r in righe if r["obbligatorio"]]
        scelte = [r for r in righe if not r["obbligatorio"]]
        if not obbl or not scelte:
            continue

        def ambito(r):
            return set(r["_tutti"]) if not r["_percorsi"] else set(r["_percorsi"])
        coperti = set().union(*(ambito(r) for r in obbl))
        for r in scelte:
            resto = ambito(r) - coperti
            if not resto:
                ins.remove(r)
            elif resto != ambito(r):
                r["_percorsi"] = set(resto)
                r["curriculum"] = ", ".join(sorted(resto)) if resto != r["_tutti"] else None
    for i in ins:
        i.pop("_ps", None)
    # stesso nome nello stesso anno e curriculum con codici diversi (alternative omonime): il nome porta i CFU, o il codice
    per_nome: dict[tuple, list] = {}
    for i in ins:
        per_nome.setdefault((i["anno"], _norm(i["nome"]), i["curriculum"]), []).append(i)
    for gruppo in per_nome.values():
        if len({i["codice"] for i in gruppo}) < 2:
            continue
        if len({i["cfu"] for i in gruppo}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo}) > 1 and all(
                isinstance(i["cfu"], (int, float)) for i in gruppo):
            for i in gruppo:
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        else:
            for i in gruppo:
                i["nome"] = f"{i['nome']} ({i['codice']})"
    return ins


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    p = ROOT / "database" / "corsi" / "iuav.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("libri") and cod not in out:
                out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def fetch_ateneo(uid: str = "iuav", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "iuav.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[iuav] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
