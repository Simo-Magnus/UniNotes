"""Università di Scienze Gastronomiche (UNISG, Pollenzo): piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unisg.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- un corso per ogni corso di Universitaly (`CORSI`, id espliciti) e, per ogni anno di corso, il piano della coorte che lo
  frequenta nel 2026/27 (coorte 2026 per il 1° anno, 2025 per il 2°, 2024 per il 3°). I codici del catalogo cambiano con
  l'ordinamento (Scienze e Culture Gastronomiche: `LSG18` = cod 10050 fino alla coorte 2024, `LSG18R` = cod 10080 dalla 2025),
  quindi la coorte si legge con il codice giusto per ogni anno. L'adattatore comune mescolava i piani di coorti diverse
  (stesso anno con CFU e insegnamenti di tre ordinamenti) e dava gli insegnamenti «integrati» come righe a 0 CFU;
- le lauree nuove del 2026 (Food Tech for Ecological Transition, Food and Planetary Health) hanno una sola coorte: gli anni
  successivi al 1° sono quelli dello stesso piano (deduzione dichiarata in `piano_anni`);
- insegnamenti integrati: il catalogo li pubblica come contenitori a 0 CFU (`adFiglie`) con i moduli, che hanno i CFU, come
  righe distinte dello stesso piano. Il contenitore non è un insegnamento a CFU: si toglie e i moduli tengono i propri CFU; i
  libri di un modulo senza programma sono quelli del contenitore (nota nel libro). Un'attività a 0 CFU senza moduli (per
  esempio «Study Trip - I Year») non vale crediti e non è una riga;
- gruppi del piano (`cod`): «OO» obbligatori; «F» (lingue a livelli, attività a scelta) sono a scelta;
- Food Tech for Ecological Transition: il catalogo pubblica fra le «altre attività» il corso a scelta del 3° anno
  (`SGSC177`, 9 CFU, offerto nel 2028/29); gli altri corsi a scelta indicati dal sito dell'ateneo non sono nel catalogo;
- nomi: maiuscolo del catalogo → iniziali maiuscole (sigle, livelli A1/B2, numeri romani e ordinali restano).

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/unisg.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/unisg.py [--senza-syllabus]
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

BASE = "https://unisg.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
ANNO = 2026  # a.a. 2026/27

# (id Universitaly, id del corso nel database, {anno di corso: (coorte, codice del corso nel catalogo)}, coorte per l'ammissione)
CORSI: list[tuple[str, str, dict[int, tuple[int, str]], int, str]] = [
    ("1626000", "unisg-l-gastr-food-tech-for-ecological-transition",
     {1: (2026, "10082"), 2: (2026, "10082"), 3: (2026, "10082")}, 2026, "10082"),
    ("1627697", "unisg-l-gastr-scienze-e-culture-gastronomiche",
     {1: (2026, "10080"), 2: (2025, "10080"), 3: (2024, "10050")}, 2026, "10080"),
    ("1626001", "unisg-lm-gastr-food-and-planetary-health",
     {1: (2026, "10083"), 2: (2026, "10083")}, 2026, "10083"),
    ("1627698", "unisg-lm-gastr-food-industry-management",
     {1: (2026, "10081"), 2: (2025, "10081")}, 2026, "10081"),
]
# corsi a scelta del catalogo non legati a un anno («altre attività») da assegnare all'anno in cui sono offerti
ALTRE_ATTIVITA = {"unisg-l-gastr-food-tech-for-ecological-transition"}

_SMALL = {"e", "ed", "di", "del", "della", "dei", "delle", "degli", "dello", "per", "in", "con", "da", "a", "al", "alla",
          "alle", "ai", "agli", "il", "la", "lo", "le", "gli", "i", "nel", "nella", "nelle", "nei", "sul", "sulla", "tra",
          "fra", "o", "su", "dal", "dalla", "nell", "dell", "and", "of", "the", "to", "for", "on", "with", "an", "or", "at",
          "by", "from", "as", "into"}
_SIGLE = {"ESG", "GDPR", "UE", "EU", "UNESCO", "IT", "ICT", "AI", "IA", "II", "III", "IV", "PHD"}
_PERIODI = {"primo ciclo semestrale": "1", "secondo ciclo semestrale": "2", "ciclo annuale unico": "annuale",
            "primo semestre": "1", "secondo semestre": "2", "annuale": "annuale"}
_ACCENTO = {"a": "à", "i": "ì", "o": "ò", "u": "ù"}
_ELISI = {"l", "d", "dell", "nell", "all", "dall", "sull", "un", "c", "quell", "po"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _parola(w: str, prima: bool, precedente: str = "", successiva: str = "") -> str:
    """Una parola del nome in maiuscolo: iniziale maiuscola; sigle, livelli (b2), numeri romani e ordinali invariati."""
    if not w:
        return w
    core = re.sub(r"[^\w']", "", w)
    if re.fullmatch(r"\d+(?:st|nd|rd|th)", core):  # «1st year»
        return w
    if core == "iot":
        return w.replace("iot", "IoT")
    if re.fullmatch(r"[a-c][12]", core):  # livelli QCER
        return w.upper()
    if core == "i":  # articolo («per i contesti») o numero romano («- I Anno»)
        romano = precedente in ("-", "–") or successiva in ("anno", "year", "semestre", "semester", "modulo")
        return "I" if (romano or prima) else w
    if core.upper() in _SIGLE or re.fullmatch(r"[ivx]{2,4}", core):
        return re.sub(re.escape(core), core.upper(), w, count=1)
    if not prima and core in _SMALL:
        return w
    if "'" in w:
        a, _, b = w.partition("'")
        if not b.strip(")"):  # apostrofo finale: «qualita'» → «qualità»
            m = re.search(r"([aiou])$", a)
            if m:
                return a[:-1].capitalize() + _ACCENTO[m.group(1)] if len(a) > 1 else a
            return a[:1].upper() + a[1:] + "'"
        if prima or a not in _ELISI and a not in _SMALL:
            a = a[:1].upper() + a[1:]
        return a + "'" + b[:1].upper() + b[1:]
    m = re.search(r"[a-zà-ÿ]", w)
    return w[:m.start()] + w[m.start()].upper() + w[m.start() + 1:] if m else w


def _titolo(des: str | None) -> str:
    """Nome dell'attività: maiuscolo del catalogo → iniziali maiuscole."""
    des = re.sub(r"\s+", " ", (des or "").replace("’", "'")).strip()
    des = des.translate(str.maketrans("áíóúÁÍÓÚ", "àìòùÀÌÒÙ"))
    if not des.isupper():
        return des
    parole = des.lower().split(" ")
    out = []
    for i, w in enumerate(parole):
        prec = parole[i - 1] if i else ""
        succ = parole[i + 1] if i + 1 < len(parole) else ""
        prima = i == 0 or prec.endswith(":")  # dopo i due punti si riparte con la maiuscola
        parti = re.split(r"([-/–])", w) if len(w) > 2 else [w]
        # «pre-intermedio» → «Pre-Intermedio», «intermediate/advanced» → «Intermediate/Advanced»
        out.append("".join(p if p in "-/–" else _parola(p, prima and j == 0, prec, succ)
                           for j, p in enumerate(parti)))
    return " ".join(out)


def _periodo(s: str | None) -> str | None:
    if not s:
        return None
    return _PERIODI.get(re.sub(r"\s+", " ", s.lower()).strip(), s.strip())


def _sede(s: str | None) -> str | None:
    """«BRA (CN)» → «Bra (CN)»."""
    if not s:
        return None
    s = re.sub(r"\s+", " ", s).strip()
    if s.isupper():
        s = re.sub(r"\(([A-Za-z]{2})\)", lambda m: "(" + m.group(1).upper() + ")", s.title())
    return s


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/unisg)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "unisg" if d else None

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


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    oggi = time.strftime("%Y-%m-%d")
    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}

    def build(id_ul: str, id_corso: str, per_anno: dict[int, tuple[int, str]], coorte_amm: int, cod_amm: str) -> dict | None:
        durata = max(per_anno)
        piani: dict[tuple[int, str], dict] = {}
        for coorte, cod in sorted(set(per_anno.values())):
            d = _un(c.get(f"/corso/{coorte}/{cod}"))
            if not d or not d.get("percorsi"):
                log(f"[{uid}]   {id_corso}: piano {coorte}/{cod} non disponibile")
                return None
            piani[(coorte, cod)] = d
        det_amm = piani.get((coorte_amm, cod_amm)) or _un(c.get(f"/corso/{coorte_amm}/{cod_amm}")) or {}
        amm = ammissione.da_catalogo(det_amm, f"{base}/corsi/{coorte_amm}/{cod_amm}") if det_amm else None

        insegnamenti: dict[str, dict] = {}
        piano_anni: dict[str, dict] = {}
        for k in range(1, durata + 1):
            coorte, cod = per_anno[k]
            d = piani[(coorte, cod)]
            padri: dict[str, dict] = {}
            for p in d["percorsi"]:
                for a in p.get("anni") or []:
                    for g in _gruppi(a):
                        for t in g.get("attivita") or []:
                            if not (t.get("crediti") or 0) and t.get("adFiglie"):
                                padri[t.get("adCod")] = t
            for p in d["percorsi"]:
                for a in p.get("anni") or []:
                    righe: list[tuple[dict, dict]] = []
                    if str(a.get("anno")) == str(k):
                        piano_anni[str(k)] = {"coorte": coorte, "annoOfferta": a.get("annoOfferta"),
                                              "url": f"{base}/corsi/{coorte}/{cod}"}
                        righe = [(g, t) for g in _gruppi(a) for t in g.get("attivita") or []]
                    elif a.get("anno") == "altreAttivita" and id_corso in ALTRE_ATTIVITA:
                        off = (d.get("percorsi")[0].get("anni") or [])
                        anno_off = next((x.get("annoOfferta") for x in off if str(x.get("anno")) == str(k)), None)
                        righe = [({"cod": "F", "label_it": "Altre attività a scelta"}, t) for t in a.get("attivita") or []
                                 if t.get("tipo_ins_cod") == "SCE" and anno_off and str(t.get("aa")) == str(anno_off)]
                    for g, att in righe:
                        ad = att.get("adCod") or att.get("cod")
                        if not (att.get("crediti") or 0):  # contenitore di moduli o attività senza crediti
                            continue
                        key = f"{k}:{ad}"
                        if key in insegnamenti:
                            continue
                        docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                        item = {
                            "codice": ad, "nome": _titolo(att.get("des_it") or ad), "anno": k,
                            "periodo": _periodo(att.get("periodo_didattico_it")),
                            "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                            "periodo_fine": att.get("data_fine_periodo_didattico"),
                            "cfu": att.get("crediti"), "ssd": None,
                            "obbligatorio": g.get("cod") == "OO", "curriculum": None,
                            "docenti": sorted(set(docenti)),
                            "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                   f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={coorte}",
                            "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                        }
                        insegnamenti[key] = item
                        padre = padri.get((att.get("adPadre") or {}).get("adCod"))
                        if syllabus:
                            syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod")), str(coorte)), {
                                "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                           "ordinamento_aa": att.get("ordinamento_aa"),
                                           "af_percorso": att.get("corso_percorso_id"),
                                           "corso_cod": att.get("corso_cod"), "corso_aa": coorte,
                                           "schema_id": att.get("schemaId")},
                                "items": [], "codice": ad, "coorte": coorte, "padre": padre, "alt": [],
                            })["items"].append(item)
        ins = list(insegnamenti.values())
        # stesso nome nello stesso anno con CFU diversi: il nome porta i CFU
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        d0 = piani[(coorte_amm, cod_amm)] if (coorte_amm, cod_amm) in piani else det_amm
        return {
            "id": id_corso, "id_universitaly": id_ul,
            "nome": _titolo(d0.get("des_it") or ""),
            "classe": cc._classe(d0.get("classe_cod")),
            "tipo_catalogo": d0.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(d0.get("sedeDenominazioneComune") or d0.get("sede_des_it")),
            "codice_ateneo": d0.get("cdsCod"),
            "url": f"{base}/corsi/{coorte_amm}/{cod_amm}",
            "curricula": None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

    def build_safe(r) -> dict | None:
        try:
            return build(*r[:3], *r[3:])
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {r[1]} saltato: {e!r}")
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
        padre = job.get("padre")
        if not libri and padre:  # modulo di un insegnamento integrato: il programma è quello del contenitore
            p = {"anno": padre.get("aa"), "insegnamento": padre.get("cod"), "ordinamento_aa": padre.get("ordinamento_aa"),
                 "af_percorso": padre.get("corso_percorso_id"), "corso_cod": padre.get("corso_cod"),
                 "corso_aa": job["coorte"], "schema_id": padre.get("schemaId")}
            sy2 = leggi(p)
            if isinstance(sy2, dict):
                l2, m2 = libri_da(sy2)
                if l2:
                    url = (f"{base}/insegnamenti/{padre.get('aa')}/{padre.get('cod')}/{padre.get('ordinamento_aa')}"
                           f"/{padre.get('corso_percorso_id')}?coorte={job['coorte']}")
                    nota = f"Dal programma dell'insegnamento integrato «{_titolo(padre.get('des_it'))}» ({url})"
                    libri, modalita, sy = l2, modalita or m2, {**sy2, **{k: v for k, v in sy.items() if v}}
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
        for n in ex.map(do_syllabus, syllabus_jobs.values()):
            trovati += n
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unisg.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    out: dict[str, dict] = {}
    for p in (ROOT / "database" / "corsi" / "unisg.json", ROOT / "database" / "contrib" / "auto" / "unisg_syl_b2.json",
              ROOT / "database" / "contrib" / "auto" / "unisg.json"):
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


def fetch_ateneo(uid: str = "unisg", anno: int = ANNO, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unisg.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unisg] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
