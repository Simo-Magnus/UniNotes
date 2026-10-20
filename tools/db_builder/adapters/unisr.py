"""Università Vita-Salute San Raffaele (UniSR): piani di studio dai PDF «Piano degli studi» di www.unisr.it.

Perché non il catalogo: `syllabus.unisr.it` (Course Catalogue Cineca) elenca gli insegnamenti senza l'anno di corso
(quasi tutti con `anno` nullo) e mescola coorti, sedi e attività elettive; il piano ufficiale per anno accademico è invece
un PDF per corso (pagina `…/<corso>/piano-studi` di www.unisr.it, un link per ogni a.a. «Piano degli studi A.A. 2026-2027»),
con testo estraibile (pypdf, modalità «layout»). Il PDF della coorte che si iscrive nell'a.a. A vale per chi frequenta il
k-esimo anno nell'a.a. A+k-1: per l'anno k nel 2026/27 si legge il PDF A=2026-k+1 e si prendono le sole righe di quell'anno.

Due famiglie di PDF:

- stampa Esse3 (corsi di Medicina e Chirurgia, Psicologia, Biotecnologie, …): una tabella «ATTIVITA' DIDATTICA | ANNO DI
  CORSO | SETTORE | TIPOLOGIA | AMBITO | CFU | OBB/OPZ | ORE | TIPO VAL». Le righe con «OBB» sono gli insegnamenti (integrati
  con i loro moduli, che sono le righe «- …» e non si leggono: i CFU dell'insegnamento sono quelli della riga principale);
  il nome può andare a capo prima o dopo la riga dei numeri e l'anno può stare sulla riga di continuazione. Ogni PDF può avere
  più sezioni (sedi dell'Infermieristica, canali di Medicina, curricula di Psicologia): la sezione si sceglie dal titolo della
  copertina. Le «attività a scelta» non sono righe della tabella ma una frase finale («dovrà frequentare attività a scelta per
  un totale di 8 crediti formativi sui 360 CFU totali»): sono una voce a scelta con quei CFU;
- Facoltà di Filosofia (L-5, LM-78, LM-89): tabelle per gruppi («Scegliere tre insegnamenti (27 CFU) tra i seguenti») con
  settore, nome, CFU, tipo di valutazione e anno (I, II, III, «I o III»); i gruppi fissi sono obbligatori, le opzioni di
  un gruppo a scelta sono a scelta (obbligatorie solo se i CFU richiesti sono quelli di tutte le opzioni).

Attività «in qualsiasi anno» (attività a scelta dello studente, ulteriori attività formative, corsi offerti in più) e CFU
liberi dichiarati dalla frase finale non hanno un anno nel piano: stanno nell'ultimo anno del corso. Per un anno la cui
coorte non ha il PDF (Osteopatia e Radiologia hanno solo 2025-26 e 2026-27) si legge il PDF più vicino (registrato nel log).

Codici, docenti, periodo, libri e appelli non stanno nel PDF: si riprendono dalle righe già raccolte (database/corsi/unisr.json
o, con il catalogo raggiungibile, dal Course Catalogue) per nome dell'insegnamento (stesso nome e stessi CFU); gli OFA, le
attività a 0 CFU e i seminari/ADE senza anno del catalogo non sono righe del piano ufficiale e non si riportano.

Con la variabile d'ambiente UNISR_PDF_DIR (una cartella) i PDF restano su disco (`<chiave>__<aa>.pdf`).

Esecuzione locale (scrive `database/contrib/auto/unisr.json`):

    python tools/db_builder/adapters/unisr.py
"""
from __future__ import annotations

import html
import io
import json
import logging
import os
import pathlib
import re
import sys
import time
import unicodedata
from collections import defaultdict

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .unibo import Client  # noqa: E402

logging.getLogger("pypdf").setLevel(logging.CRITICAL)

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unisr.it"
OFFERTA = BASE + "/offerta-formativa/"
CATALOGO = "https://syllabus.unisr.it"
SSD = r"(?:[A-Z]{3,5}-\d{2}/[A-Z]|[A-Z]{1,4}(?:-[A-Z]{1,4}){0,2}/\d{2})"  # codici nuovi (MEDS-24/C) e vecchi (MED/45)
NUM = r"\d+(?:[.,]\d+)?"
ANOMALIE: list[str] = []

# chiave del piano → pagina dei PDF (sotto /offerta-formativa/)
PAGINE = {
    "filosofia": "filosofia/piano-studi",
    "fisioterapia": "medicina-chirurgia/corso-di-laurea-fisioterapia/piano-studi",
    "igiene": "medicina-chirurgia/corso-di-laurea-igiene-dentale/piano-studi",
    "infermieristica": "medicina-chirurgia/corso-di-laurea-infermieristica/piano-studi",
    "osteopatia": "medicina-chirurgia/corso-di-laurea-osteopatia/piano-studi",
    "rbm": "medicina-chirurgia/corso-di-laurea-ricerca-biotecnologica-in-medicina/piano-studi",
    "radiologia": "medicina-chirurgia/corso-laurea-tecniche-di-radiologia-medica/piano-studi",
    "ostetricia": "medicina-chirurgia/corso-laurea-triennale-ostetricia/piano-studi",
    "stp": "psicologia/corso-di-laurea-triennale-scienze-tecniche-psicologiche/piano-studi",
    "lm_filosofia": "filosofia/corso-di-laurea-magistrale-filosofia-mondo-contemporaneo/piano-studi",
    "lm_tsai": "filosofia/corso-di-laurea-magistrale-in-teoria-e-storia-arti-immagine/piano-di-studi",
    "bmb": "medicina-chirurgia/corso-di-laurea-magistrale-biotechnology-medical-biology/piano-studi",
    "sio": "medicina-chirurgia/corso-di-laurea-magistrale-scienze-infermieristiche-ostetriche/piano-studi",
    "srps": "medicina-chirurgia/corso-di-laurea-magistrale-scienze-riabilitative-delle-professioni-sanitare/piano-studi",
    "hi": "medicina-chirurgia/corso-laurea-magistrale-health-informatics/piano-studi",
    "psicologia": "psicologia/corso-di-laurea-magistrale/piano-studi",
    "cph": "psicologia/corso-di-laurea-magistrale-cognitive-psychology-in-health-communication/piano-studi",
    "medicina": "medicina-chirurgia/corso-di-laurea-medicina-chirurgia/piano-studi",
    "odonto": "medicina-chirurgia/corso-di-laurea-odontoiatria/piano-studi",
    "imd": "medicina-chirurgia/international-medical-doctor-program/imdp-curriculum",
}
FILOSOFIA = {"filosofia", "lm_filosofia", "lm_tsai"}

_P = "unisr-"
_INF = _P + "l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf"
# Corsi del database (id di Universitaly) che il contributo riempie: id, chiave del piano, parte del titolo della sezione,
# durata, id dei corsi del catalogo da cui riprendere codici e docenti (doppioni che la ricostruzione toglie). Il corso
# «Medicina e Chirurgia 1/2/3» del PDF sono il corso, la REPLICA 1 e la REPLICA 2 di Universitaly (stessa numerazione).
CORSI = [
    {"id": _INF, "chiave": "infermieristica", "sezione": "Milano", "durata": 3,
     "fonti": [_P + "l-snt1-corso-di-laurea-in-infermieristica"]},
    {"id": _INF + "-1627929", "chiave": "infermieristica", "sezione": "Ponte San Pietro", "durata": 3,
     "fonti": [_P + "l-snt1-corso-di-laurea-in-infermieristica-2"]},
    {"id": _P + "l-5-filosofia", "chiave": "filosofia", "durata": 3, "fonti": []},
    {"id": _P + "l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot", "chiave": "fisioterapia",
     "durata": 3, "fonti": []},
    {"id": _P + "l-snt3-igiene-dentale-abilitante-alla-professione-sanitaria-di-igie", "chiave": "igiene",
     "durata": 3, "fonti": []},
    {"id": _P + "l-snt4-osteopatia", "chiave": "osteopatia", "durata": 3, "fonti": []},
    {"id": _P + "l-snt1-ostetricia-abilitante-alla-professione-sanitaria-di-ostetric", "chiave": "ostetricia",
     "durata": 3, "fonti": []},
    {"id": _P + "l-2-ricerca-biotecnologica-in-medicina", "chiave": "rbm", "durata": 3, "fonti": []},
    {"id": _P + "l-24-scienze-e-tecniche-psicologiche", "chiave": "stp", "durata": 3, "fonti": []},
    {"id": _P + "l-snt3-tecniche-di-radiologia-medica-per-immagini-e-radioterapia-ab", "chiave": "radiologia",
     "durata": 3, "fonti": []},
    {"id": _P + "lm-9-biotechnology-for-innovative-therapeutics", "chiave": "bmb", "durata": 2, "fonti": []},
    {"id": _P + "lm-51-cognitive-psychology-in-health-communication", "chiave": "cph", "durata": 2,
     "fonti": [_P + "lm-51-corso-di-laurea-magistrale-in-psicologia-cognitiva-nella-com"]},
    {"id": _P + "lm-78-filosofia-del-mondo-contemporaneo", "chiave": "lm_filosofia", "durata": 2, "fonti": []},
    {"id": _P + "lm-18-health-informatics", "chiave": "hi", "durata": 2, "fonti": []},
    {"id": _P + "lm-51-psicologia", "chiave": "psicologia", "durata": 2, "fonti": []},
    {"id": _P + "lm-snt1-scienze-infermieristiche-e-ostetriche-profilo-infermieristic", "chiave": "sio",
     "durata": 2, "fonti": []},
    {"id": _P + "lm-snt2-scienze-riabilitative-delle-professioni-sanitarie", "chiave": "srps", "durata": 2,
     "fonti": []},
    {"id": _P + "lm-89-teoria-e-storia-delle-arti-e-dell-immagine", "chiave": "lm_tsai", "durata": 2, "fonti": []},
    {"id": _P + "lm-41-medicina-e-chirurgia", "chiave": "medicina", "sezione": "Chirurgia 1", "durata": 6,
     "fonti": []},
    {"id": _P + "lm-41-medicina-e-chirurgia-replica-1", "chiave": "medicina", "sezione": "Chirurgia 2", "durata": 6, "replica": True,
     "fonti": [_P + "lm-41-corso-di-laurea-magistrale-in-medicina-e-chirurgia-2"]},
    {"id": _P + "lm-41-medicina-e-chirurgia-replica-2", "chiave": "medicina", "sezione": "Chirurgia 3", "durata": 6, "replica": True,
     "fonti": [_P + "lm-41-corso-di-laurea-magistrale-in-medicina-e-chirurgia-3"]},
    {"id": _P + "lm-41-medicine-and-surgery", "chiave": "imd", "durata": 6, "fonti": []},
    {"id": _P + "lm-46-odontoiatria-e-protesi-dentaria", "chiave": "odonto", "durata": 6, "fonti": []},
]
# Nome del corso nel Course Catalogue (dove stanno codici, docenti e periodi), per corso del database: i corsi «2» e «3» di
# Medicina e il «2» dell'Infermieristica sono le repliche di Universitaly (canali B e C, sede di Ponte San Pietro)
_C = "Corso di Laurea "
NOMI_CATALOGO = {
    _INF: _C + "in Infermieristica",
    _INF + "-1627929": _C + "in Infermieristica 2",
    _P + "l-5-filosofia": _C + "in Filosofia",
    _P + "l-snt2-fisioterapia-abilitante-alla-professione-sanitaria-di-fisiot": _C + "in Fisioterapia",
    _P + "l-snt3-igiene-dentale-abilitante-alla-professione-sanitaria-di-igie": _C + "in Igiene Dentale",
    _P + "l-snt4-osteopatia": _C + "in Osteopatia",
    _P + "l-snt1-ostetricia-abilitante-alla-professione-sanitaria-di-ostetric": _C + "in Ostetricia",
    _P + "l-2-ricerca-biotecnologica-in-medicina": _C + "in Ricerca Biotecnologica in Medicina",
    _P + "l-24-scienze-e-tecniche-psicologiche": _C + "in Scienze e Tecniche Psicologiche",
    _P + "l-snt3-tecniche-di-radiologia-medica-per-immagini-e-radioterapia-ab":
        _C + "in Tecniche di Radiologia Medica per Immagini e Radioterapia",
    _P + "lm-9-biotechnology-for-innovative-therapeutics": "Biotechnology For Innovative Therapeutics",
    _P + "lm-51-cognitive-psychology-in-health-communication":
        _C + "Magistrale in Psicologia Cognitiva nella Comunicazione della Salute",
    _P + "lm-78-filosofia-del-mondo-contemporaneo": _C + "Magistrale in Filosofia del Mondo Contemporaneo",
    _P + "lm-18-health-informatics": _C + "Magistrale in Health Informatics",
    _P + "lm-51-psicologia": _C + "Magistrale in Psicologia",
    _P + "lm-snt2-scienze-riabilitative-delle-professioni-sanitarie":
        _C + "Magistrale in Scienze Riabilitative delle Professioni Sanitarie",
    _P + "lm-89-teoria-e-storia-delle-arti-e-dell-immagine":
        _C + "Magistrale in Teoria e Storia delle Arti e Dell'immagine",
    _P + "lm-41-medicina-e-chirurgia": _C + "Magistrale in Medicina e Chirurgia",
    _P + "lm-41-medicina-e-chirurgia-replica-1": _C + "Magistrale in Medicina e Chirurgia 2",
    _P + "lm-41-medicina-e-chirurgia-replica-2": _C + "Magistrale in Medicina e Chirurgia 3",
    _P + "lm-41-medicine-and-surgery": "International Md Program " + _C + "Magistrale in Medicina e Chirurgia",
    _P + "lm-46-odontoiatria-e-protesi-dentaria": _C + "Magistrale in Odontoiatria e Protesi Dentaria",
}
# Nomi del PDF che a capo si leggono male (nome grezzo letto → nome corretto), verificati sul PDF
NOMI: dict[str, str] = {}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _slug(s: str, maxlen: int) -> str:
    return _norm(s).replace(" ", "-")[:maxlen].strip("-")


def _nome_base(s: str | None) -> str:
    """Nome senza il numero d'ordine dell'integrato («16 - Infermieristica clinica …») e confrontabile (il trattino lungo
    di alcuni PDF è letto come «?»)."""
    return _norm(re.sub(r"^\s*\d+\s*[-?‐-―−]\s*", "", s or ""))


def _num(s: str | None):
    if s is None:
        return None
    v = float(str(s).replace(",", "."))
    return int(v) if v.is_integer() else v


# ---------------------------------------------------------------- lettura dei PDF

def _pagine(data: bytes) -> list[list[tuple[int, str]]]:
    """Righe (rientro, testo) di ogni pagina dal testo «layout» di pypdf; le celle sono separate da « | »."""
    from pypdf import PdfReader
    out = []
    for p in PdfReader(io.BytesIO(data)).pages:
        righe = []
        for riga in (p.extract_text(extraction_mode="layout") or "").split("\n"):
            if riga.strip():
                riga = re.sub("[‐-―−]", "-", riga)  # trattini tipografici dei PDF più vecchi
                righe.append((len(riga) - len(riga.lstrip()), re.sub(r" {3,}", " | ", riga.strip()).rstrip()))
        out.append(righe)
    return out


def _intestazione(l: str) -> bool:
    t = re.sub(r"\s+", " ", l.replace("|", " ")).strip()
    if re.search(r"20\d\d/20\d\d", t):
        return True
    if re.fullmatch(r"(?i)(piano )?(degli )?(studi)?|studi|degli studi|piano|degli|piano degli", t):
        return True
    return bool(re.search(r"ATTIVITA' DIDATTICA|OBB/OPZ|^CORSO\b|ANNO\s*DI\s*CORSO|^CORSO \| CFU", t))


def _copertina(righe) -> bool:
    testa = " ".join(l for _, l in righe[:4])
    return ("Facolta'" in testa or "Facoltà" in testa) and not any("ATTIVITA'" in l for _, l in righe)


def _sezioni(pgs) -> list[dict]:
    """Sezioni (corso, sede, canale, curriculum): una per ogni copertina, con le righe delle pagine seguenti."""
    out: list[dict] = []
    for righe in pgs:
        if _copertina(righe):
            titolo = " ".join(re.sub(r"\s*\|\s*", " ", l) for _, l in righe)
            out.append({"titolo": re.sub(r"\s+", " ", titolo).strip(), "righe": []})
        else:
            if not out:
                out.append({"titolo": "", "righe": []})
            out[-1]["righe"].extend((i, l) for i, l in righe if not _intestazione(l))
    return out


def _riga_numeri(l: str) -> dict:
    """Riga con OBB: nome (celle prima dell'anno), anno, CFU e settore."""
    m = re.search(r"(?<![A-Za-z])(OBB|OPZ)", l) or re.search(r"PROFIN_S", l)
    left, right = l[: m.start()], l[m.end():]
    if m.group(0) == "PROFIN_S":  # la prova finale di alcuni PDF non ha «OBB»: il settore PROFIN_S resta nel nome
        left = l[: m.end()]
    cfu = None
    mm = re.search(rf"({NUM})\s*\|?\s*$", left)
    left_wo = left
    if mm and not re.search(SSD + r"\*{0,2}\W*$", left):
        cfu, left_wo = mm.group(1), left[: mm.start()]
    else:  # CFU incollati al tipo di ore o di valutazione («…diagnostica1 LEZ», «…prova finale7 | G»)
        cand = list(re.finditer(rf"({NUM})(?=\s*\|?\s*(?:LEZ|TPV|SEM|APRO|TIR|LAB|ESE|SIM|Lingua|[GV]\b|$))", right))
        if cand:
            cfu = (cand[-1] if len(cand) == 1 else cand[0]).group(1)
    left_wo = left_wo.rstrip(" |")
    nome_parti, anno, fermo = [], None, False
    for k, c in enumerate(c.strip() for c in left_wo.split(" | ")):
        if fermo:
            continue
        a0 = re.match(rf"^(.*?\S)\s+([1-6])\s*(?:{SSD}\*{{0,2}}|PROFIN_S)(?:\s.*)?$", c) if k == 0 else None
        if a0:  # «Fisica 1 PHYS-06/A»: nome, anno e settore incollati
            nome_parti.append(a0.group(1))
            anno, fermo = int(a0.group(2)), True
            continue
        if k > 0:
            a = re.match(rf"^([1-6])\s*(?:(?:{SSD}|PROFIN_S)\S*.*)?$", c)
            if a:
                anno, fermo = int(a.group(1)), True
                continue
            if re.match(rf"^{SSD}", c) or re.match(r"^(PROFIN_S|MEDS-\s*$)", c):
                fermo = True
                continue
        nome_parti.append(c)
    nome = re.sub(r"\s+", " ", " ".join(nome_parti))
    nome = re.sub(r"^(\d+)\s+(-\s)", r"\1 \2", nome)
    nome = re.sub(r"^(\d+)\s*\?\s+", r"\1 - ", nome)  # «11 ? Competenze»: il trattino lungo del PDF è letto come «?»
    ssd = re.search(SSD, left_wo)
    nome = re.sub(rf"\s+{SSD}\*{{0,2}}$", "", nome)
    return {"nome": nome, "anno": anno, "cfu": cfu, "ssd": ssd.group(0) if ssd else None}


_CONT = re.compile(r"^([^|]*?)\s*\|\s*([1-6])\s*(?:\||$)")


def _tipo(l: str) -> str:
    t = l.lstrip(" |")
    if t.startswith("-") and not re.match(r"^\d+\s*\|", l):
        return "D"  # modulo (in alcuni PDF anche la riga del modulo ha «OBB»)
    if re.search(r"(?<![A-Za-z])(OBB|OPZ)", l) or re.search(r"PROFIN_S", l):
        return "M"  # riga principale (insegnamento)
    if _CONT.match(l.strip()) and not re.search(SSD, l):
        return "C"  # fine del nome con l'anno
    if "|" not in l.strip(" |") and not re.search(SSD, l):
        return "P"  # testo semplice (nome a capo)
    return "X"


def attivita_esse3(sez: dict, noti: set[str]) -> list[dict]:
    """Insegnamenti (righe principali) di una sezione di un PDF Esse3: nome, anno, CFU, settore."""
    righe = sez["righe"]
    tipi = [_tipo(l) for _, l in righe]
    out = []
    for i, (ind, l) in enumerate(righe):
        if tipi[i] != "M":
            continue
        r = _riga_numeri(l)
        if not r["nome"] and i > 0 and tipi[i - 1] == "X":  # nome e ambito sulla riga prima, numeri su quella dopo
            r["nome"] = righe[i - 1][1].split(" | ")[0].strip()
        elif r["nome"][:1].islower() and i > 0 and tipi[i - 1] == "X" and not _CONT.match(righe[i - 1][1]):
            # inizio del nome (con l'ambito) sulla riga prima: «Attività …: Approccio all'ambiente» + «medico-chirurgico»
            r["nome"] = righe[i - 1][1].split(" | ")[0].strip() + " " + r["nome"]
        cont = None
        if i + 1 < len(righe) and tipi[i + 1] == "C":
            m = _CONT.match(righe[i + 1][1].strip())
            if r["anno"] is None:
                r["anno"] = int(m.group(2))
            cont = m.group(1).strip()
        # righe di testo semplice allineate al nome: prima (nome a capo) e dopo (se seguono moduli)
        pre = []
        for k in (i - 1, i - 2):
            if k >= 0 and tipi[k] == "P" and abs(righe[k][0] - ind) <= 6:
                pre.insert(0, righe[k][1].strip(" |"))
            else:
                break
        post, j = [], i + 1
        while j < len(righe) and tipi[j] in ("C", "P", "X"):
            if tipi[j] == "P" and abs(righe[j][0] - ind) <= 6:
                post.append(righe[j][1].strip(" |"))
            if tipi[j] == "C":
                break
            j += 1
        if post and not (j < len(righe) and tipi[j] in ("D", "C")):
            post = []  # senza moduli sono le righe del nome dell'insegnamento successivo
        nome = r["nome"]
        opts = []
        for pre_k in ([[], pre[-1:], pre[-2:]] if pre else [[]]):
            for post_k in ([[], ([cont] if cont else []), post, ([cont] if cont else []) + post] if (post or cont) else [[]]):
                opts.append(re.sub(r"\s+", " ", " ".join(pre_k + [nome] + post_k)))
        opts = sorted(dict.fromkeys(opts), key=lambda o: -len(o))
        scelta = next((o for o in opts if _nome_base(o) in noti), None)
        if scelta is None:
            for o in opts:
                a = re.match(r"^(.*?)\s+([1-6])$", o)
                if a and _nome_base(a.group(1)) in noti and r["anno"] is None:
                    scelta, r["anno"] = a.group(1), int(a.group(2))
                    break
        if scelta is None:
            ok = nome[:1].islower() and pre
            scelta = re.sub(r"\s+", " ", " ".join((pre[-1:] if ok else []) + [nome] + ([cont] if cont else []) + post))
        scelta = NOMI.get(scelta, scelta)
        out.append({"nome": scelta, "anno": r["anno"], "cfu": _num(r["cfu"]), "ssd": r["ssd"],
                    "riconosciuto": _nome_base(scelta) in noti})
    # anno mancante: quello della riga precedente (le pagine sono in ordine di anno)
    prec = None
    for r in out:
        if r["anno"] is None:
            r["anno"] = prec
        prec = r["anno"] or prec
    return out


def _liberi(sez: dict) -> list[tuple[str, float]]:
    """CFU a scelta e ulteriori attività dichiarati dalla frase finale del piano."""
    t = re.sub(r"\s+", " ", " ".join(l for _, l in sez["righe"]).replace("|", " "))
    out = []
    m = re.search(r"attivit[àa] a scelta per un totale di (\d+) crediti formativi ed ulteriori attivit[àa] formative "
                  r"per un totale di (\d+) crediti", t)
    if m:  # Igiene dentale
        return [("Attività a scelta dello studente", int(m.group(1))), ("Ulteriori attività formative", int(m.group(2)))]
    m = re.search(r"ottenga (\d+) CFU attraverso la frequenza di Corsi a scelta.*?e (\d+) CFU di ulteriori attivit", t)
    if m:  # Ostetricia
        return [("Attività a scelta dello studente", int(m.group(1))), ("Ulteriori attività formative", int(m.group(2)))]
    m = (re.search(r"(?:attivit[àa] a scelta|Elective Course|dei seminari) per un totale (?:di )?(?:almeno )?(\d+) crediti", t)
         or re.search(r"corsi elettivi che gli permetta di ottenere almeno (\d+) CFU", t))
    if m:
        out.append(("Attività a scelta dello studente", int(m.group(1))))
    return out


def _totale_dichiarato(sez: dict) -> int | None:
    t = re.sub(r"\s+", " ", " ".join(l for _, l in sez["righe"]).replace("|", " "))
    m = re.search(r"sui (\d+) (?:CFU )?total", t)
    return int(m.group(1)) if m else None


# ------------------------------------------------- piani della Facoltà di Filosofia

_ANNI = {"I": 1, "II": 2, "III": 3, "IV": 4}
_ANNO = r"(?:I{1,3}|IV)(?:\s+o\s+(?:I{1,3}|IV))?"


def _anni_celle(s: str) -> set[int]:
    return {_ANNI[x] for x in re.findall(r"\b(I{1,3}|IV)\b", s)}


def _gruppi_filosofia(pgs) -> list[dict]:
    """Gruppi del piano: {tipo, cfu, anno, titolo, righe}. Due impaginazioni: con la colonna ANNO (I, II, «I o III»; PDF
    2026/27 e delle magistrali) o con le intestazioni «PRIMO ANNO», «SECONDO ANNO», «TERZO ANNO» (PDF della triennale
    2024/25 e 2025/26)."""
    gruppi: list[dict] = []
    corrente = None
    anno_def = None

    def nuovo(tipo, cfu=None, titolo=""):
        nonlocal corrente
        corrente = {"tipo": tipo, "cfu": cfu, "titolo": titolo, "anno": anno_def, "linee": []}
        gruppi.append(corrente)

    for righe in pgs:
        for _, l in righe:
            t = re.sub(r"\s+", " ", l.replace("|", " ")).strip()
            if not t or ("SETTORE" in t and "ATTIVIT" in t):
                continue
            if re.search(r"Piano degli studi", t) or (re.search(r"^(Facolt|Corso di Laurea|20\d\d/20\d\d)", t)
                                                       and "CFU" not in t):
                continue
            if re.match(r"^\*{1,2}\s|^V = |^G = |^Conformemente|^laurea |^non possono|^Nota:|^Metodologie didattiche e "
                        r"scrittura filosofica\.$|^\*\* Tipo valutazione", t):
                continue
            m = re.match(r"^(PRIMO|SECONDO|TERZO)\s+ANNO\b", t)
            if m:
                anno_def = {"PRIMO": 1, "SECONDO": 2, "TERZO": 3}[m.group(1)]
                corrente = None
                continue
            m = re.match(r"^Tot\. esami (I{1,3}) anno (\d+) CFU", t)
            if m:
                nuovo("totale_anno", int(m.group(2)), t)
                corrente["anno"] = _ANNI[m.group(1)]
                continue
            m = re.match(r"^(?:In qualsiasi anno:\s*)?Ulteriori attivit[àa] formative(?:\s*\((\d+) CFU)?", t)
            if m:
                anno_def = None
                nuovo("ulteriori", int(m.group(1)) if m.group(1) else None, t)
                continue
            if re.match(r"^In qualsiasi anno:?\s*$", t):
                anno_def = None
                continue
            if re.match(r"^(?:In qualsiasi anno:\s*)?Attivit[àa] a scelta dello studente", t):
                anno_def = None
                nuovo("libere", None, t)
                continue
            m = re.match(r"^(\d+) CFU a scelta (?:tra|dello studente)", t)
            if m and corrente and corrente["tipo"] == "libere":
                corrente["cfu"] = int(m.group(1))
                continue
            if re.match(r"^Inoltre,", t):
                anno_def = None
                nuovo("offerti", None, t)
                continue
            m = re.match(r"^(\d+) CFU tra i seguenti insegnamenti", t)
            if m and corrente and corrente["tipo"] == "ulteriori":
                corrente["cfu"] = int(m.group(1))
                continue
            m = re.match(r"^Tesi di laurea\s+(\d+) CFU", t)
            if m:
                nuovo("tesi", int(m.group(1)), t)
                continue
            m = re.match(r"^(\d+) CFU prova finale", t)
            if m:
                nuovo("tesi", int(m.group(1)), t)
                continue
            if re.match(r"^(Tot\. esami|Totale (complessivo|generale))", t):
                nuovo("totale", None, t)
                continue
            m = (re.match(r"^(?:Scegliere .*?|di cui .*?)\((?:fino a |non pi. di )?(\d+) CFU\)", t)
                 or re.match(r"^Scegliere (\d+) CFU", t) or re.match(r"^(\d+) CFU tra i seguenti", t))
            if m:
                nuovo("scelta", int(m.group(1)), t)
                continue
            m = re.match(r"^Attivit[àa] (di base|caratterizzanti|affini)\b", t)
            if m and not re.search(rf"\s{NUM}\s", t):
                mc = re.search(r"\((\d+) CFU\)\s*$", t)
                nuovo("fisso", int(mc.group(1)) if mc else None, t)
                continue
            if corrente is None:
                continue
            if corrente["tipo"] == "fisso" and not corrente["linee"] and re.match(r"^[a-zàèéìòù]", t) and "CFU" not in t:
                corrente["titolo"] += " " + t  # titolo del gruppo a capo
                continue
            corrente["linee"].append(l)
    for g in gruppi:
        g["righe"], g["alternative"] = _righe_filosofia(g["linee"])
    return gruppi


def _righe_filosofia(linee: list[str]) -> tuple[list[dict], bool]:
    """Righe di una tabella (settore | nome | CFU | V/G | anno): le righe a capo si uniscono alla precedente; le righe dei
    moduli (settore e CFU, senza tipo di valutazione né anno) non sono insegnamenti. Un gruppo di alternative («oppure»)
    ha i CFU una volta sola: ogni alternativa li ha."""
    alternative: list[dict] = []
    idx = next((k for k, l in enumerate(linee) if re.search(r"\boppure\b", l)), None)
    if idx is not None and idx > 0:
        # «A oppure B oppure C»: la riga prima del primo «oppure» è la prima alternativa; i CFU stanno su una riga sola
        alt_linee = linee[idx - 1:]
        linee = linee[: idx - 1]
        cfu_alt = None
        for l in alt_linee:
            for c in (c.strip() for c in l.split(" | ") if c.strip()):
                if re.fullmatch(NUM, c) and cfu_alt is None:
                    cfu_alt = c
        for l in alt_linee:
            celle = [c.strip() for c in l.split(" | ") if c.strip()]
            testo = [c for c in celle if not re.fullmatch(rf"{NUM}|[VG]I?|oppure", c) and not re.match(SSD, c)]
            ssd = next((c for c in celle if re.match(SSD, c)), None)
            if ssd and testo and cfu_alt is not None:
                alternative.append({"nome": " ".join(testo), "cfu": _num(cfu_alt), "ssd": ssd, "anni": None,
                                    "alt": True})
    blocchi: list[list[list[str]]] = []
    for l in linee:
        celle = [c.strip() for c in l.split(" | ") if c.strip()]
        if not celle:
            continue
        ha_ssd = bool(re.match(SSD, celle[0]))
        testo = [c for c in celle if not re.fullmatch(rf"{NUM}|[VG]I?|{_ANNO}|-", c) and not re.match(SSD, c)]
        numeri = [c for c in celle if re.fullmatch(NUM, c)]
        if ha_ssd or (testo and numeri):
            blocchi.append([celle])
        elif blocchi:
            blocchi[-1].append(celle)
    righe = []
    for b in blocchi:
        celle = [c for riga in b for c in riga]
        ssd = next((c for c in celle if re.match(SSD, c)), None)
        testo, cfu, anni, tv = [], None, set(), False
        for c in celle:
            if c == ssd:
                continue
            if re.fullmatch(NUM, c):
                cfu = cfu if cfu is not None else c
            elif re.fullmatch(r"[VG]I?", c):
                tv = True
            elif re.fullmatch(_ANNO, c):
                anni |= _anni_celle(c)
            else:
                testo.append(c)
        nome = re.sub(r"\s+", " ", " ".join(testo)).strip()
        if not nome or cfu is None or not (tv or anni):
            continue  # (le righe senza tipo di valutazione né anno sono i moduli di un insegnamento integrato)
        if re.search(r"(?i)singoli seminari", nome):
            continue  # 0,10 CFU per ogni seminario frequentato: il valore di una presenza, non un insegnamento
        righe.append({"nome": nome, "cfu": _num(cfu), "ssd": ssd, "anni": anni or None})
    return righe + alternative, bool(alternative)


def righe_filosofia(pgs, durata: int, noti: set[str]) -> tuple[list[dict], dict]:
    """Righe del piano di Filosofia: anni (insieme o None = ultimo anno), nome, CFU, obbligatorio. I gruppi fissi sono
    obbligatori; le opzioni di un gruppo a scelta lo sono solo se i CFU richiesti sono quelli di tutte le opzioni."""
    out = []
    info = {"tot_gruppi": 0, "tot_anno": {}, "req_anno": defaultdict(float)}
    for g in _gruppi_filosofia(pgs):
        tipo = g["tipo"]
        if tipo == "totale":
            continue
        if tipo == "totale_anno":
            info["tot_anno"][g["anno"]] = g["cfu"]
            continue
        anno_g = {g["anno"]} if g["anno"] else None
        if tipo in ("fisso", "scelta"):
            fisse = [r for r in g["righe"] if not r.get("alt")]
            alt = [r for r in g["righe"] if r.get("alt")]  # «oppure»: una sola tra le alternative
            somma = sum(r["cfu"] for r in fisse)
            cfu_g = g["cfu"]
            tutte = tipo == "fisso" or (cfu_g is not None and somma <= cfu_g + 1e-9)
            for r in fisse:
                out.append({**r, "anni": r["anni"] or anno_g, "obbligatorio": tutte, "gruppo": g["titolo"],
                            "cfu_gruppo": cfu_g})
            for r in alt:
                out.append({**r, "anni": anno_g, "obbligatorio": False, "gruppo": g["titolo"], "cfu_gruppo": r["cfu"]})
            richiesti = (somma if tutte else (cfu_g or 0)) + (alt[0]["cfu"] if alt else 0)
            info["tot_gruppi"] += richiesti
            for a in (anno_g or ()):
                info["req_anno"][a] += richiesti
        elif tipo == "libere":
            out.append({"nome": "Attività a scelta dello studente", "cfu": g["cfu"], "ssd": None, "anni": None,
                        "obbligatorio": False, "gruppo": g["titolo"], "cfu_gruppo": g["cfu"]})
            info["tot_gruppi"] += g["cfu"] or 0
        elif tipo == "ulteriori":
            for r in g["righe"]:
                out.append({**r, "anni": None, "obbligatorio": False, "gruppo": g["titolo"], "cfu_gruppo": g["cfu"]})
            info["tot_gruppi"] += g["cfu"] or 0
        elif tipo == "offerti":
            for r in g["righe"]:
                out.append({**r, "anni": None, "obbligatorio": False, "gruppo": "Corsi offerti in più",
                            "cfu_gruppo": None})
        elif tipo == "tesi":
            out.append({"nome": "Prova finale" if "prova finale" in g["titolo"].lower() else "Tesi di laurea",
                        "cfu": g["cfu"], "ssd": None, "anni": {durata}, "obbligatorio": True,
                        "gruppo": g["titolo"], "cfu_gruppo": g["cfu"]})
            info["tot_gruppi"] += g["cfu"] or 0
    return out, info


# ---------------------------------------------------------------- scaricamento

def _aa_da_link(href: str, etichetta: str) -> str | None:
    seg = href.split("/attachments/", 1)[-1].split("/", 1)[0]
    for t in (seg, etichetta):
        m = re.search(r"(20\d\d)\s*[-–./]\s*(?:20)?(\d\d)\b", t)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            if b == a % 100:  # «2025-2025» è un refuso del sito per 2025-26
                b = (a + 1) % 100
            return f"{a}-{b:02d}"
        m = re.search(r"(?<!\d)(20\d\d)(?!\d)", t)
        if m:
            return f"{int(m.group(1))}-{(int(m.group(1)) + 1) % 100:02d}"
    return None


def link_pdf(client, chiave: str, log=print) -> dict[str, str]:
    """a.a. («2026-27») → indirizzo del PDF del piano degli studi, dalla pagina dei piani del corso."""
    pagina = OFFERTA + PAGINE[chiave]
    r = client.get(pagina)
    out: dict[str, str] = {}
    for m in re.finditer(r'href="(/attachments/[^"]+\.pdf)"[^>]*>(.*?)</a>', r.text if r else "", re.S):
        href = html.unescape(m.group(1))
        etichetta = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", m.group(2)))).strip()
        if re.search(r"(?i)calendar|descrizione|accertamento", href + etichetta):
            continue
        aa = _aa_da_link(href, etichetta)
        if aa and aa not in out:
            out[aa] = BASE + href
    if not out:
        log(f"[unisr] nessun PDF in {pagina}")
    return out


def scarica(client, chiave: str, aa: str, url: str) -> bytes | None:
    cartella = os.environ.get("UNISR_PDF_DIR")
    f = pathlib.Path(cartella) / f"{chiave}__{aa}.pdf" if cartella else None
    if f and f.exists():
        return f.read_bytes()
    r = client.get(url)
    if not r or not r.content.startswith(b"%PDF"):
        return None
    if f:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(r.content)
    return r.content


# ---------------------------------------------------------------- righe già raccolte

def _righe_database(uid: str) -> dict[str, dict]:
    p = ROOT / "database" / "corsi" / f"{uid}.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {c["id"]: c for c in doc.get("corsi") or []}


def _contributo_precedente(uid: str) -> dict[str, dict]:
    """Corsi dell'ultimo contributo scritto (nome → corso): con il catalogo in manutenzione sono le ultime righe lette."""
    try:
        doc = json.loads((ROOT / "database" / "contrib" / "auto" / f"{uid}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {c["nome"]: c for c in doc.get("corsi") or [] if c.get("nome")}


def _righe_catalogo(uid: str, anno: int, log=print) -> dict[str, dict]:
    """Corsi del Course Catalogue (nome del corso → corso con i suoi insegnamenti), se il sito risponde (in manutenzione
    risponde con una pagina HTML: nessuna riga, si usano quelle già nel database)."""
    try:
        from . import cineca_catalogue as cc
        c = cc.Client(CATALOGO, rate=4)
        prova = c.get("/corsi", {"anno": anno, "minimal": "true"})
        if not isinstance(prova, list) or not prova:
            log("[unisr] catalogo non raggiungibile (manutenzione): righe già nel database")
            return {}
        doc = cc.fetch_ateneo(uid, CATALOGO, anno, client=c, log=log)
        return {x["nome"]: x for x in doc.get("corsi") or []}
    except Exception as e:  # noqa: BLE001 - il catalogo è solo un arricchimento
        log(f"[unisr] catalogo non letto ({e!r}): righe già nel database")
        return {}


def _indice_righe(corso: dict | None) -> dict[str, list[dict]]:
    idx: dict[str, list[dict]] = defaultdict(list)
    for i in (corso or {}).get("insegnamenti") or []:
        if not i.get("cfu") or re.match(r"(?i)OFA", str(i.get("codice") or "")):
            continue  # attività a 0 CFU e obblighi formativi aggiuntivi non sono insegnamenti del piano
        idx[_nome_base(i.get("nome"))].append(i)
    return idx


# «Attività a scelta» ha nomi diversi nel catalogo: la frase finale del PDF e la riga del catalogo sono la stessa voce
ALIAS = {"attivita a scelta dello studente": ["attivita scelta dello studente", "attivita a scelta"],
         "ulteriori attivita formative": ["altre attivita formative"]}


def _abbina(nome: str, cfu, anno, curriculum, indici: list[dict[str, list[dict]]]):
    """Riga già raccolta con lo stesso nome, dalla prima fonte (in ordine di priorità) che la ha: prima con gli stessi CFU
    (la più ricca di docenti, esami e libri; con più curricula, quella del suo curriculum, che può avere un altro codice);
    altrimenti, se i CFU cambiano da una coorte all'altra, quella del nome se ha un solo codice."""
    chiavi = [_nome_base(nome)] + ALIAS.get(_nome_base(nome), [])
    cand = [[i for chiave in chiavi for i in idx.get(chiave, [])] for idx in indici]
    cur = _norm(curriculum) if curriculum else None

    def del_curriculum(i):
        return bool(cur) and any(_norm(p) == cur for p in re.split(r",\s*", i.get("curriculum") or ""))

    def punti(i):
        return (del_curriculum(i), bool(i.get("docenti")), len(i.get("esami") or []), len(i.get("libri") or []),
                i.get("anno") == anno)

    for righe in cand:
        esatti = [i for i in righe if cfu is None or abs(float(i.get("cfu") or 0) - float(cfu)) <= 1e-6]
        if esatti:
            return max(esatti, key=punti)
    for righe in cand:
        if righe and len({i.get("codice") for i in righe}) == 1:
            return max(righe, key=punti)
    return None


CARICA = ("codice", "periodo", "periodo_inizio", "periodo_fine", "ssd", "docenti", "url", "libri", "esami",
          "modalita_esame", "stato_libri", "stato_esami")

# Insegnamenti che il piano elenca come obbligatori ma sono alternative tra loro, dichiarato dalla pagina del corso:
# (id del corso, nome normalizzato) → fonte. Health Informatics: «il piano di studi si personalizza, durante il primo
# semestre del primo anno, con due corsi alternativi» (Software systems design and operations / Biology, Genetics, Anatomy
# and Physiology), per chi proviene da esperienze formative diverse.
ALTERNATIVE = {
    (_P + "lm-18-health-informatics", "software systems design and operations"):
        BASE + "/offerta-formativa/medicina-chirurgia/corso-laurea-magistrale-health-informatics",
    (_P + "lm-18-health-informatics", "biology genetics anatomy and physiology"):
        BASE + "/offerta-formativa/medicina-chirurgia/corso-laurea-magistrale-health-informatics",
}


# ---------------------------------------------------------------- piano di un corso

def _aa_coorte(anno: int, k: int) -> str:
    a = anno - k + 1
    return f"{a}-{(a + 1) % 100:02d}"


def _carica_pdf(client, chiave: str, aa: str, url: str, cache: dict):
    k = (chiave, aa)
    if k not in cache:
        data = scarica(client, chiave, aa, url)
        if data is None:
            ANOMALIE.append(f"{chiave}: PDF {aa} non scaricato")
            cache[k] = None
        else:
            try:
                pgs = _pagine(data)
            except Exception as e:  # noqa: BLE001 - PDF illeggibile
                ANOMALIE.append(f"{chiave}: PDF {aa} illeggibile ({e!r})")
                cache[k] = None
                return None
            cache[k] = {"pgs": pgs, "sezioni": [] if chiave in FILOSOFIA else _sezioni(pgs)}
    return cache[k]


def _righe_anno(corso: dict, k: int, aa: str, url: str, doc: dict, noti: set[str], anno: int) -> list[dict]:
    """Righe dell'anno k (anno di corso) dal PDF della coorte aa."""
    chiave, durata = corso["chiave"], corso["durata"]
    righe: list[dict] = []
    if chiave in FILOSOFIA:
        voci, info = righe_filosofia(doc["pgs"], durata, noti)
        for v in voci:
            if k in (v["anni"] or {durata}):
                righe.append({"anno": k, "nome": v["nome"], "cfu": v["cfu"], "obbligatorio": v["obbligatorio"],
                              "ssd": v["ssd"], "curriculum": None, "fonte": url, "aa": aa})
        # controllo con i «Tot. esami … anno» del PDF (impaginazione per anno)
        tot = info["tot_anno"].get(k)
        if tot is not None and abs(info["req_anno"].get(k, 0) - tot) > 0.01:
            ANOMALIE.append(f"{corso['id']}: PDF {aa} anno {k}: gruppi {info['req_anno'].get(k, 0):g} CFU, «Tot. esami» {tot}")
        return righe
    sezioni = doc["sezioni"]
    sel = [s for s in sezioni if corso.get("sezione") and corso["sezione"] in s["titolo"]]
    if not sel:
        if corso.get("sezione") and len(sezioni) > 1:
            ANOMALIE.append(f"{corso['id']}: sezione «{corso['sezione']}» assente nel PDF {aa}")
        sel = sezioni if chiave == "psicologia" else sezioni[:1]
    libere_viste: set = set()
    for s in sel:
        cur = None
        m = re.search(r"Curriculum\s+(.+?)(?:\s+Corso di Laurea.*)?$", s["titolo"], re.I)
        if m and chiave == "psicologia":
            cur = m.group(1).strip()
            cur = None if re.search(r"(?i)comune", cur) else cur[:1].upper() + cur[1:]
        for a in attivita_esse3(s, noti):
            if a["anno"] == k:
                righe.append({"anno": k, "nome": a["nome"], "cfu": a["cfu"], "obbligatorio": True, "ssd": a["ssd"],
                              "curriculum": cur, "fonte": url, "aa": aa})
            if a["anno"] is None:
                ANOMALIE.append(f"{corso['id']}: «{a['nome']}» senza anno nel PDF {aa}")
        if k == durata:
            for nome, cfu in _liberi(s):
                if (nome, cfu) in libere_viste:
                    continue
                libere_viste.add((nome, cfu))
                righe.append({"anno": k, "nome": nome, "cfu": cfu, "obbligatorio": False, "ssd": None,
                              "curriculum": None, "fonte": url, "aa": aa})
    return righe


def piano_corso(corso: dict, anno: int, client, noti: set[str], cache: dict, log=print) -> list[dict]:
    """Righe (anno, nome, CFU, obbligatorio, curriculum, fonte) del corso per ogni anno 1..durata."""
    chiave, durata = corso["chiave"], corso["durata"]
    if chiave not in cache.setdefault("link", {}):
        cache["link"][chiave] = link_pdf(client, chiave, log)
    link = cache["link"][chiave]
    righe: list[dict] = []
    for k in range(1, durata + 1):
        voluto = _aa_coorte(anno, k)
        # coorte voluta, poi i PDF più vicini (a parità il più recente) finché uno ha righe per quell'anno
        ordine = sorted(link, key=lambda x: (x != voluto, abs(int(x[:4]) - int(voluto[:4])), -int(x[:4])))
        trovato = False
        for aa in ordine:
            doc = _carica_pdf(client, chiave, aa, link[aa], cache)
            if doc is None:
                continue
            r = _righe_anno(corso, k, aa, link[aa], doc, noti, anno)
            if r and k == durata and not any(x["obbligatorio"] is False and re.match(
                    r"(?i)(attivit|seminari|corsi? elettiv|ulteriori)", x["nome"]) for x in r) and chiave not in FILOSOFIA:
                # il PDF di quella coorte non ha la frase sui CFU a scelta: quella del PDF più vicino che la ha
                for aa2 in ordine:
                    d2 = cache.get((chiave, aa2))
                    lib = [(n, c) for s2 in (d2 or {}).get("sezioni", [])[:1] for n, c in _liberi(s2)]
                    if lib:
                        r += [{"anno": k, "nome": n, "cfu": c, "obbligatorio": False, "ssd": None, "curriculum": None,
                               "fonte": link[aa2], "aa": aa2} for n, c in lib]
                        ANOMALIE.append(f"{corso['id']}: CFU a scelta ({lib}) dal PDF {aa2}: il PDF {aa} non li dichiara")
                        break
            if r:
                if aa != voluto:
                    ANOMALIE.append(f"{corso['id']}: anno {k}: PDF {voluto} assente o senza testo, usato {aa}")
                righe.extend(r)
                trovato = True
                break
        if not trovato:
            ANOMALIE.append(f"{corso['id']}: anno {k}: nessun PDF con righe")
    return righe


# ---------------------------------------------------------------- contributo

def _id_espliciti(corso_id: str, items: list[dict]) -> None:
    """build_db tronca lo slug dell'id a 40 caratteri: due insegnamenti diversi con lo stesso inizio di nome nello stesso
    anno si fonderebbero: hanno un id esplicito."""
    per: dict[tuple, list[dict]] = defaultdict(list)
    for i in items:
        per[(_slug(i.get("codice") or i["nome"], 40), i["anno"])].append(i)
    usati: set[str] = set()
    for lst in per.values():
        if len({(i.get("codice"), _nome_base(i["nome"])) for i in lst}) > 1:
            for i in lst:
                base = f"{corso_id}-{_slug(i['nome'], 90)}"
                nuovo = base
                for suff in (f"-a{i['anno']}", f"-a{i['anno']}-{'scelta' if i['obbligatorio'] is False else 'obbl'}"):
                    if nuovo in usati:
                        nuovo = base + suff
                usati.add(nuovo)
                i["id"] = nuovo


def fetch_ateneo(uid: str = "unisr", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None, catalogo: dict | None = None) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    ANOMALIE.clear()
    client = client or Client(rate=3.0)
    db = _righe_database(uid)
    if catalogo is None:
        catalogo = _righe_catalogo(uid, anno, log) if syllabus else {}
    precedente = _contributo_precedente(uid)
    oggi = time.strftime("%Y-%m-%d")
    # tutti i nomi già raccolti (ricompongono i nomi andati a capo nel PDF)
    noti = {_nome_base(i.get("nome")) for c in list(db.values()) + list(catalogo.values()) + list(precedente.values())
            for i in c.get("insegnamenti") or [] if i.get("nome")}
    cache: dict = {}
    out = []
    for corso in CORSI[:max_cds] if max_cds else CORSI:
        righe = piano_corso(corso, anno, client, noti, cache, log)
        if not righe:
            continue
        esistente = db.get(corso["id"]) or {}
        nome_cat = NOMI_CATALOGO.get(corso["id"])
        # righe da cui riprendere codici e docenti: catalogo, ultimo contributo, corsi doppione del database, il corso
        sorgenti = [catalogo.get(nome_cat) or {}, precedente.get(nome_cat) or {}] +                    [db.get(f) or {} for f in corso["fonti"]] + ([] if corso.get("replica") else [esistente])
        indici = [_indice_righe(s) for s in sorgenti]
        ins = []
        viste: set = set()
        for r in righe:
            chiave_r = (r["anno"], _nome_base(r["nome"]), r["curriculum"], r["cfu"])
            if chiave_r in viste:
                continue
            viste.add(chiave_r)
            alt = ALTERNATIVE.get((corso["id"], _nome_base(r["nome"])))
            if alt:
                r["obbligatorio"] = False
            ex = _abbina(r["nome"], r["cfu"], r["anno"], r["curriculum"], indici)
            riga = {"codice": None, "nome": (ex or {}).get("nome") or r["nome"], "anno": r["anno"], "periodo": None,
                    "cfu": r["cfu"], "ssd": r["ssd"], "obbligatorio": r["obbligatorio"], "curriculum": r["curriculum"],
                    "docenti": [], "url": r["fonte"], "libri": [], "esami": [], "fonte": r["fonte"],
                    "verificato_il": oggi, "stato_libri": "da_aggiungere"}
            if ex:
                for k in CARICA:
                    if ex.get(k) not in (None, "", []):
                        riga[k] = json.loads(json.dumps(ex[k]))
            ins.append(riga)
        # corsi elettivi del catalogo che il piano ufficiale non elenca (ADE, seminari, «corsi elettivi» per i CFU a scelta):
        # a scelta, nell'anno del catalogo o, se non ne ha, nell'ultimo anno (solo se hanno un docente o un appello: sono
        # offerti davvero). Gli OFA, le righe a 0 CFU e quelle di altre versioni del piano (senza docenti né appelli) no.
        gia = {_nome_base(i["nome"]) for i in ins} | {i["codice"] for i in ins if i.get("codice")}
        for src in sorgenti:
            for e in src.get("insegnamenti") or []:
                if not e.get("cfu") or re.match(r"(?i)OFA", str(e.get("codice") or "")) \
                        or "syllabus.unisr.it" not in str(e.get("fonte") or ""):
                    continue
                anno_e = e.get("anno")
                if not (isinstance(anno_e, int) and 1 <= anno_e <= corso["durata"]):
                    # senza anno nel catalogo: attività elettive realmente offerte (con docente o appello), nell'ultimo anno
                    if corso.get("replica") or not (e.get("docenti") or e.get("esami")):
                        continue
                    anno_e = corso["durata"]
                if _nome_base(e["nome"]) in gia or (e.get("codice") and e["codice"] in gia):
                    continue
                gia.add(_nome_base(e["nome"]))
                riga = {k: json.loads(json.dumps(e[k])) for k in
                        ("codice", "nome", "periodo", "periodo_inizio", "periodo_fine", "cfu", "ssd", "docenti",
                         "url", "libri", "esami", "modalita_esame", "stato_libri", "fonte") if e.get(k) not in (None, "")}
                riga.update(anno=anno_e, obbligatorio=False, curriculum=None, verificato_il=oggi)
                riga.setdefault("libri", [])
                riga.setdefault("esami", [])
                riga.setdefault("docenti", [])
                riga.setdefault("stato_libri", "da_aggiungere")
                ins.append(riga)
        # lo stesso codice non può stare su due insegnamenti diversi dello stesso anno
        visti_cod: dict[tuple, str] = {}
        for i in ins:
            if i.get("codice"):
                k = (i["codice"], i["anno"])
                if k in visti_cod and visti_cod[k] != _nome_base(i["nome"]):
                    i["codice"] = None
                visti_cod.setdefault(k, _nome_base(i["nome"]))
        _id_espliciti(corso["id"], ins)
        url_piano = OFFERTA + PAGINE[corso["chiave"]]
        doppioni = [db.get(f) or {} for f in corso["fonti"]]

        def da_corso(chiave):  # dato del corso di Universitaly o, se manca, del doppione del catalogo
            return next((c[chiave] for c in [esistente] + doppioni if c.get(chiave)), None)

        out.append({"id": corso["id"], "nome": esistente.get("nome"), "classe": esistente.get("classe"),
                    "tipo_catalogo": None, "durata_anni": corso["durata"],
                    "sede": da_corso("sede"), "codice_ateneo": da_corso("codice_ateneo"),
                    "ammissione": da_corso("ammissione"), "url": url_piano,
                    "curricula": sorted({i["curriculum"] for i in ins if i["curriculum"]}) or None,
                    "fonte": url_piano, "verificato_il": oggi, "insegnamenti": ins})
    log(f"[{uid}] {len(out)} corsi, {sum(len(c['insegnamenti']) for c in out)} insegnamenti; anomalie: {len(ANOMALIE)}")
    for a in ANOMALIE:
        log(f"[{uid}]   {a}")
    return {"universita_id": uid, "descrizione": "Generato dai PDF «Piano degli studi» di www.unisr.it (adapters/unisr.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def main(argv: list[str]) -> int:
    doc = fetch_ateneo()
    out = ROOT / "database" / "contrib" / "auto" / "unisr.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unisr] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
