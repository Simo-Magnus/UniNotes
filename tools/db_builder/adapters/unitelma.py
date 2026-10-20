"""Università Telematica Unitelma Sapienza: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unitelma.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`, id espliciti): nel catalogo le lauree e il ciclo unico esistono solo
  nella coorte 2025 (le coorti 2024 e precedenti sono voci vuote «Chiuso» senza percorsi: `10149`, `10150`), le due magistrali
  nuove del 2026 (Scienze giuridiche, Studi europei) solo nella coorte 2026. Il piano della coorte 2025 comprende tutti gli
  anni (anno 1 offerto nel 2025/26, anno 2 nel 2026/27, ...): per ogni anno di corso si legge l'anno corrispondente di quel
  piano, che è il più vicino disponibile per le altre coorti (deduzione dichiarata in `piano_anni`);
- «Scienze giuridiche» (LM/SC-GI nel catalogo, LM/SC-GIUR in Universitaly) è un solo corso: si usa l'id del corso di
  Universitaly; l'id creato dall'adattatore comune (`unitelma-lm-sc-gi-scienze-giuridiche`) è in `corsi_sostituiti`;
- durata dal piano («5 anni» di Giurisprudenza: l'elenco minimale dei corsi non la dà e l'adattatore comune metteva 3);
- gruppi del piano (`cod`): «OO» obbligatori; «F» (a scelta tra, gruppi di alternative) e «W» (a scelta dello studente, elenco
  libero tra 12 e 20 CFU, ...) sono a scelta, tranne un'attività unica senza scelta nell'etichetta; «S» è la regola di scelta
  libera senza elenco («ESAME A SCELTA DELLO STUDENTE (fra 8 e 22 CFU)»): non ha attività e non diventa una voce;
- percorsi del catalogo → curricula (nomi con le iniziali maiuscole); un'attività è obbligatoria o a scelta per curriculum:
  stessa attività obbligatoria in un percorso e a scelta in un altro = due righe con curricula disgiunti;
- stessa attività (stesso codice) con CFU diversi nello stesso anno in percorsi diversi: due righe con id proprio
  (`-<cfu>cfu`) e il nome con «(N CFU)»; alternative omonime con CFU diversi: il nome porta i CFU (stesso nome e stessi CFU
  con codici diversi li unisce pulizia.unisci_omonimi);
- nomi: maiuscolo del catalogo → iniziali maiuscole (sigle, apostrofo finale «QUALITA'» → «Qualità»).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/unitelma.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unitelma.py [--senza-syllabus]
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
from .uniba import libri_testo_libero  # noqa: E402

BASE = "https://unitelma.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
ANNO = 2026  # a.a. 2026/27

# (id Universitaly, id del corso nel database, coorte del piano, codice del corso nel catalogo)
CORSI: list[tuple[str, str, int, str]] = [
    ("1628779", "unitelma-l-16-scienze-dell-amministrazione-e-della-sicurezza", 2025, "10552"),
    ("1628780", "unitelma-l-18-scienze-dell-economia-aziendale", 2025, "10554"),
    ("1628778", "unitelma-l-14-scienze-giuridiche", 2025, "10530"),
    ("1628781", "unitelma-l-36-scienze-politiche-e-delle-relazioni-internazionali-governanc", 2025, "10529"),
    ("1628783", "unitelma-lm-2-classical-archaeology", 2025, "10553"),
    ("1628785", "unitelma-lm-77-economia-management-e-innovazione", 2025, "10555"),
    ("1628784", "unitelma-lm-63-management-delle-organizzazioni-pubbliche-e-sanitarie", 2025, "10557"),
    ("1625601", "unitelma-lm-sc-giur-scienze-giuridiche", 2026, "10597"),
    ("1625600", "unitelma-lm-90-studi-europei", 2026, "10596"),
    ("1628782", "unitelma-lmg-01-giurisprudenza", 2025, "10556"),
]

_SMALL = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al", "alla",
          "alle", "ai", "agli", "il", "la", "lo", "le", "gli", "i", "nel", "nella", "nelle", "nei", "sul", "sulla", "tra",
          "fra", "o", "su", "dal", "dalla", "nell", "dell", "and", "of", "the", "to", "for", "on", "with", "an", "or", "at",
          "by", "from"}
_SIGLE = {"ESG", "GDPR", "UE", "EU", "UNESCO", "IT", "ICT", "AI", "IA", "OFA", "IUS", "CFU", "PA", "II", "III", "IV"}
_CREDITI_LIBERI = {"a scelta", "a libera scelta", "attivita libera", "attivita a scelta", "attivita a libera scelta"}
_SCELTA = re.compile(r"(?i)scelt|opzion|alternativ|elective|elettiv|optional|oppure|\btra\b|\bfra\b|\bor\b|among|betwee?n|\bone\b|\bchoice\b")
_PERIODI = {"primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale",
            "primo semestre": "1", "secondo semestre": "2", "annuale": "annuale"}
_ACCENTO = {"a": "à", "i": "ì", "o": "ò", "u": "ù"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


_ELISI = {"l", "d", "dell", "nell", "all", "dall", "sull", "un", "c", "quell", "po"}


def _parola(w: str, prima: bool, ultima: bool = False) -> str:
    """Una parola del nome in maiuscolo: iniziale maiuscola, sigle e numeri romani invariati, `QUALITA'` → `Qualità`."""
    if not w:
        return w
    core = re.sub(r"[^\w']", "", w)
    if re.fullmatch(r"(?:[a-z]\.){2,}", w.strip("()")):  # «p.a.» → «P.A.»
        return w.upper()
    if core == "i" and not ultima:  # articolo («per i contesti»), non il numero romano
        return w if not prima else "I"
    if core.upper() in _SIGLE or re.fullmatch(r"[ivx]{1,4}", core):
        return re.sub(re.escape(core), core.upper(), w, count=1)
    if not prima and core in _SMALL:
        return w
    if "'" in w:
        a, _, b = w.partition("'")
        if not b.strip(")"):  # apostrofo finale: «qualita'» → «qualità»
            m = re.search(r"([aiou])$", a)
            if m:
                a = a[:-1] + _ACCENTO[m.group(1)]
                return a if (not prima and a in _SMALL) else a[:1].upper() + a[1:] + b
            if a == "e":
                return "è"
            return a[:1].upper() + a[1:] + "'" + b
        if prima or a not in _ELISI and a not in _SMALL:
            a = a[:1].upper() + a[1:]
        bb = b.strip(")")
        resto = b[len(bb):]
        b = (bb.upper() if bb.upper() in _SIGLE else bb[:1].upper() + bb[1:]) + resto
        return a + "'" + b
    m = re.search(r"[a-zà-ÿ]", w)
    return w[:m.start()] + w[m.start()].upper() + w[m.start() + 1:] if m else w


def _titolo(des: str | None) -> str:
    """Nome dell'attività: maiuscolo del catalogo → iniziali maiuscole (sigle e numeri romani restano)."""
    des = re.sub(r"\s+", " ", (des or "").replace("’", "'")).strip()
    des = des.translate(str.maketrans("áíóúÁÍÓÚ", "àìòùÀÌÒÙ"))  # «Contabilitá» (accento acuto sbagliato nel catalogo)
    if not des.isupper():
        return des
    out = []
    parole = des.lower().split(" ")
    for i, w in enumerate(parole):
        ultima = i == len(parole) - 1
        if "-" in w and len(w) > 2:  # «traduzione-lingua» → «Traduzione-Lingua»
            out.append("-".join(_parola(p, i == 0 and j == 0, ultima) for j, p in enumerate(w.split("-"))))
        else:
            out.append(_parola(w, i == 0, ultima))
    return " ".join(out)


def _a_scelta_studente(att: dict) -> bool:
    return (att.get("tafDes_it") or "").strip().lower() == "a scelta dello studente" or bool(
        re.search(r"(?i)a scelta dello studente|\bADE\b", att.get("des_it") or ""))


def _nome_attivita(att: dict) -> str:
    nome = _titolo(att.get("des_it") or att.get("adCod") or "")
    if _norm(nome) in _CREDITI_LIBERI and _a_scelta_studente(att):
        return "Attività formative a scelta dello studente"
    return nome


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return _PERIODI.get(re.sub(r"\s+", " ", s.lower()).strip(), s.strip())


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unitelma)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unitelma" if d else None

    def get(self, path, params=None):
        if not self.cache:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.cache / key[:2] / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L": 3, "L2": 3, "LM": 2, "LM5": 5}.get(tipo or "", 3)


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _obbligatorio(g: dict, att: dict, atts: list[dict]) -> bool:
    if _a_scelta_studente(att) and re.search(r"(?i)\bscelta\b|\bADE\b", att.get("des_it") or ""):
        return False  # «A libera scelta»: crediti liberi, a scelta anche dentro «Obbligatori»
    if g.get("cod") == "OO":
        return True
    if g.get("cod") == "W":  # attività a libera scelta «fra 12 e 20 CFU»
        return False
    # blocchi F: un'unica attività senza scelta nell'etichetta è obbligatoria; i blocchi di alternative sono a scelta
    return len(atts) == 1 and not _SCELTA.search(g.get("label_it") or "")


def _nome_percorso(p: dict) -> str:
    n = re.sub(r"\s+", " ", p.get("des_it") or p.get("pdsDes") or "").strip()
    if not n:
        return p.get("pdsCod") or ""
    n = _titolo(n) if n.isupper() else n
    n = re.sub(r"\s*,\s*", " - ", n)  # i curricula di un insegnamento si separano con la virgola
    return n[:1].upper() + n[1:]


def _sede(s: str | None) -> str | None:
    """«ROMA (RM)» → «Roma (RM)»."""
    if not s:
        return None
    s = re.sub(r"\s+", " ", s).strip()
    if s.isupper():
        s = re.sub(r"\(([A-Za-z]{2})\)", lambda m: "(" + m.group(1).upper() + ")", s.title())
    return s


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    oggi = time.strftime("%Y-%m-%d")
    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}

    def build(id_ul: str, id_corso: str, coorte: int, cod: str) -> dict | None:
        d = _un(c.get(f"/corso/{coorte}/{cod}"))
        if not d or not d.get("percorsi"):
            log(f"[{uid}]   {id_corso}: piano {coorte}/{cod} non disponibile")
            return None
        durata = _durata(d, d.get("tipo_corso_cod"))
        amm = None
        if coorte == anno:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(d, f"{base}/corsi/{coorte}/{cod}")
        percorsi = d["percorsi"]
        nomi = {id(p): _nome_percorso(p) for p in percorsi}
        tutti_nomi = {nomi[id(p)] for p in percorsi} if len(percorsi) > 1 else set()

        alt_per_ad: dict[str, dict] = {}
        for p in percorsi:
            for a in p.get("anni") or []:
                for g in _gruppi(a):
                    for t in g.get("attivita") or []:
                        alt_per_ad.setdefault(t.get("adCod") or t.get("cod"), {})[(str(t.get("aa")), str(t.get("cod")))] = t

        insegnamenti: dict[str, dict] = {}
        stati: dict[str, dict[str | None, bool]] = {}  # (anno:codice:cfu) → {curriculum: obbligatorio}
        piano_anni: dict[str, dict] = {}
        for p in percorsi:
            pcur = nomi[id(p)] if tutti_nomi else None
            for a in p.get("anni") or []:
                if not str(a.get("anno")).isdigit() or not 1 <= int(a["anno"]) <= durata:
                    log(f"[{uid}]   {id_corso}: anno {a.get('anno')!r} del percorso {nomi[id(p)]} non letto")
                    continue
                k = int(a["anno"])
                piano_anni.setdefault(str(k), {"coorte": coorte, "annoOfferta": a.get("annoOfferta"),
                                               "url": f"{base}/corsi/{coorte}/{cod}"})
                for g in _gruppi(a):
                    atts = [t for t in g.get("attivita") or [] if (t.get("crediti") or 0) > 0]
                    for att in atts:
                        ad = att.get("adCod") or att.get("cod")
                        obbl = _obbligatorio(g, att, atts)
                        key = f"{k}:{ad}:{att.get('crediti'):g}"  # stesso codice con CFU diversi nei percorsi: righe distinte
                        st = stati.setdefault(key, {})
                        st[pcur] = st.get(pcur, False) or obbl
                        if key in insegnamenti:
                            continue
                        docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                        item = {
                            "codice": ad, "nome": _nome_attivita(att), "anno": k,
                            "periodo": _periodo(att.get("periodo_didattico_it")),
                            "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                            "periodo_fine": att.get("data_fine_periodo_didattico"),
                            "cfu": att.get("crediti"), "ssd": None,
                            "obbligatorio": False, "curriculum": None,
                            "docenti": sorted(set(docenti)),
                            "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                   f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={coorte}",
                            "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                        }
                        insegnamenti[key] = item
                        if syllabus:
                            syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                           "ordinamento_aa": att.get("ordinamento_aa"),
                                           "af_percorso": att.get("corso_percorso_id"),
                                           "corso_cod": att.get("corso_cod"), "corso_aa": coorte,
                                           "schema_id": att.get("schemaId")},
                                "items": [], "codice": ad,
                                "alt": [t for (_a, _c), t in sorted(alt_per_ad.get(ad, {}).items(), reverse=True)
                                        if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                                "coorte": coorte,
                            })["items"].append(item)

        ins = []
        for key, item in insegnamenti.items():
            st = stati[key]
            if not tutti_nomi:  # un solo percorso: vale per tutti, obbligatoria se lo è
                valore = {None: any(st.values())}
            else:
                valore = {c_: v for c_, v in st.items()}
            per_valore: dict[bool, set] = {}
            for c_, v in valore.items():
                per_valore.setdefault(bool(v), set()).add(c_)
            tutti_k = {nomi[id(p)] for p in percorsi if any(
                int(a["anno"]) == item["anno"] for a in p.get("anni") or [] if str(a.get("anno")).isdigit())}
            for v, cur_set in sorted(per_valore.items(), reverse=True):
                riga = dict(item)
                riga["obbligatorio"] = v
                # senza curriculum se vale per tutti (con una sola riga); altrimenti ogni riga porta i suoi curricula
                riga["curriculum"] = None if (not tutti_nomi or (cur_set == tutti_k and len(per_valore) == 1)) \
                    else ", ".join(sorted(cur_set))
                riga["_orig"] = item
                ins.append(riga)
        # stesso nome nello stesso anno con CFU diversi (alternative omonime, per esempio «Diritto commerciale» da 10 e da 12
        # CFU in due codici): il nome porta i CFU. Con lo stesso nome e gli stessi CFU i codici sono lo stesso insegnamento
        # (un codice per corso di laurea): lo unisce pulizia.unisci_omonimi, lasciando gli altri in `codici_alternativi`
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        # stessa attività con CFU diversi nello stesso anno (percorsi diversi): build_db unisce le righe con lo stesso codice e
        # anno in una sola e perderebbe uno dei due CFU; ogni riga ha l'id proprio e il nome con i suoi CFU
        per_cod: dict[tuple, list] = {}
        for i in ins:
            if i["codice"]:
                per_cod.setdefault((i["anno"], i["codice"]), []).append(i)
        for gruppo_i in per_cod.values():
            if len({i["cfu"] for i in gruppo_i}) < 2:
                continue
            viste: dict[str, int] = {}
            for i in gruppo_i:
                if not re.search(r"\(\d+(?:[.,]\d+)? CFU", i["nome"]):
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
                base_id = f"{id_corso}-{_norm(i['codice']).replace(' ', '-')[:40].strip('-')}-{i['cfu']:g}cfu"
                n = viste.get(base_id, 0)
                viste[base_id] = n + 1
                i["id"] = base_id if not n else f"{base_id}-{'obbl' if i['obbligatorio'] else 'scelta'}"
        return {
            "id": id_corso, "id_universitaly": id_ul,
            "nome": _titolo(d.get("des_it") or ""),
            "classe": cc._classe(d.get("classe_cod")),
            "tipo_catalogo": d.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(d.get("sedeDenominazioneComune") or d.get("sede_des_it")),
            "codice_ateneo": d.get("cdsCod"),
            "url": f"{base}/corsi/{coorte}/{cod}",
            "curricula": sorted(tutti_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

    def build_safe(r: tuple[str, str, int, str]) -> dict | None:
        try:
            return build(*r)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {r[3]} saltato: {e!r}")
            return None

    elenco = CORSI[:max_cds] if max_cds else CORSI
    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, elenco):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def leggi(params: dict):
        return c.get("/insegnamento", {k: v for k, v in params.items() if v not in (None, "")})

    def libri_da(sy: dict):
        libri, modalita, legati = cc._testi_syllabus(sy)
        libri = libri or libri_testo_libero(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cc.leganto.libri(u)
        return libri, modalita

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
        sy = leggi(job["params"])
        if not isinstance(sy, dict):
            sy = {}
        libri, modalita = libri_da(sy) if sy else ([], None)
        nota = None
        if not libri:  # scheda di un'altra coorte o di un altro a.a. dello stesso insegnamento (con la fonte)
            for att in job.get("alt") or []:
                sy2 = leggi({"anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                             "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"),
                             "corso_aa": job["coorte"], "schema_id": att.get("schemaId")})
                if not isinstance(sy2, dict):
                    continue
                l2, m2 = libri_da(sy2)
                if l2:
                    aa = int(att.get("aa"))
                    url = (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}"
                           f"/{att.get('corso_percorso_id')}?coorte={job['coorte']}")
                    nota = f"Dal programma dell'a.a. {aa}/{(aa + 1) % 100:02d} dello stesso insegnamento ({url})"
                    libri, modalita, sy = l2, modalita or m2, {**sy2, **{k: v for k, v in sy.items() if v}}
                    break
        if nota:
            libri = [{**b, "note": ((b.get("note") + " | ") if b.get("note") else "") + nota} for b in libri]
        ssd = sy.get("ssd")
        for it in job["items"]:
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
            if i % 200 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    for corso_ in corsi_out:
        for riga in corso_["insegnamenti"]:
            orig = riga.pop("_orig", None)
            if orig is not None:
                for k_ in ("libri", "stato_libri", "modalita_esame", "ssd", "url_sito"):
                    if k_ in orig:
                        riga[k_] = orig[k_]
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unitelma.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "unitelma.json", ROOT / "database" / "contrib" / "auto" / "unitelma_piani.json",
              ROOT / "database" / "contrib" / "auto" / "unitelma_syl_b2.json"):
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            for i in corso.get("insegnamenti") or []:
                cod = i.get("codice")
                if cod and i.get("libri") and cod not in out:
                    out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def fetch_ateneo(uid: str = "unitelma", anno: int = ANNO, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unitelma.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unitelma] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
