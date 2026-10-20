"""Università per Stranieri di Perugia: piani di studio dal sito dell'ateneo (unistrapg.it).

Il Course Catalogue Cineca (`unistrapg.coursecatalogue.cineca.it`) ha solo le tre lauree magistrali e, per ognuna, un
elenco di attività con anno e tipo poco affidabili (scelte a gruppi, alternative, crediti a scelta, attività di tutti i
percorsi insieme): così 4 corsi su 7 avevano un anno vuoto, CFU mancanti o anni da 33-57 CFU. La pagina di ogni corso,
`https://www.unistrapg.it/it/offerta-formativa/corsi-di-laurea-e-laurea-magistrale/<corso>`, ha invece:

- «Piano di studi» (lo stesso dell'Allegato 1 del manifesto 2026/27): una tabella con SSD, insegnamenti e CFU (una
  colonna per curriculum) per ogni anno di corso, con la riga «Totale … anno» (60). Le righe sono: un insegnamento
  obbligatorio (anche «Stage», «Prova finale», «Tirocinio» e i laboratori nominati); «Un esame opzionale tra: …» (una
  riga per alternativa, tutte a scelta, con i CFU della riga); «Attività formative a scelta» (crediti liberi, con i CFU
  della riga, a volte con l'elenco delle attività consigliate e i loro CFU); «Laboratori» (crediti di laboratorio); un
  insegnamento integrato (una riga con i moduli e il totale); «-» in una colonna = riga che quel curriculum non ha;
- «Programmi degli insegnamenti»: gli insegnamenti erogati nell'a.a. corrente per anno e semestre, con docenti e il link
  alla scheda (`ins=<codice>&cdl=<corso Esse3>`; i moduli degli integrati hanno `<codice>-1`, `<codice>-2`; il 3° anno
  è ancora quello del vecchio ordinamento, `LT0001`… «ad esaurimento», mentre 1° e 2° sono i corsi «R»).

Qui: anno, nome, CFU, obbligatorietà e curriculum dalla tabella (il piano 2026/27 vale per ogni anno: l'ateneo non
pubblica le tabelle delle coorti precedenti oltre al 2025/26 e il 3° anno del vecchio ordinamento non ha tabella);
codice, docenti, semestre e scheda dal programma (per nome, o per i moduli di un integrato); per le magistrali anche
docenti, periodo, modalità d'esame e libri del catalogo Cineca (stesso insegnamento per nome). Le alternative
«(non attivo nel 2026-2027)» non si tengono (non si possono scegliere). Gli insegnamenti del programma che non sono
nella tabella (3° anno del vecchio ordinamento, laboratori offerti) si aggiungono come insegnamenti a scelta con anno
e CFU della loro scheda (se la scheda non li dice, non si aggiungono). Il totale di ogni curriculum e anno si controlla
contro la riga «Totale» (`PROBLEMI`).

Esecuzione locale (scrive `database/contrib/auto/unistrapg.json`):

    python tools/db_builder/adapters/unistrapg.py [--senza-syllabus]
"""
from __future__ import annotations

import difflib
import html
import json
import pathlib
import re
import sys
import time
import unicodedata

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .unibo import Client  # noqa: E402

UID = "unistrapg"
ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://unistrapg.coursecatalogue.cineca.it"
SITO = "https://www.unistrapg.it/it/offerta-formativa/corsi-di-laurea-e-laurea-magistrale/"

# id del corso del database (da Universitaly) e pagina del sito; `curricula`: intestazione della colonna -> nome
CORSI = [
    {"slug": "corso-di-laurea-comunicazione-internazionale-e-pubblicitaria-comip", "classe": "L-20", "tipo": "L",
     "id": "unistrapg-l-20-comunicazione-internazionale-e-pubblicitaria", "id_universitaly": "1628245",
     "nome": "Comunicazione internazionale e pubblicitaria", "durata": 3,
     "curricula": {"comip-i": "Comunicazione internazionale", "comip-p": "Comunicazione pubblicitaria"}},
    {"slug": "corso-di-laurea-lingua-e-cultura-italiana-nel-mondo-digitale-licimod", "classe": "L-10", "tipo": "L",
     "id": "unistrapg-l-10-lingua-e-cultura-italiana-nel-mondo-digitale", "id_universitaly": "1628243",
     "nome": "Lingua e cultura italiana nel mondo digitale", "durata": 3,
     "curricula": {"digitale": "Digitale", "culturale": "Culturale"}},
    {"slug": "corso-di-laurea-made-italy-cibo-e-ospitalita-mico", "classe": "L-15", "tipo": "L",
     "id": "unistrapg-l-15-l-gastr-made-in-italy-cibo-e-ospitalita", "id_universitaly": "1628244",
     "nome": "Made in Italy, cibo e ospitalità", "durata": 3, "curricula": {}},
    {"slug": "corso-di-laurea-scienze-sociali-la-sostenibilita-e-la-cooperazione-internazionale-soci",
     "classe": "L-37", "tipo": "L",
     "id": "unistrapg-l-37-scienze-sociali-per-la-sostenibilita-e-la-cooperazione-inter", "id_universitaly": "1628246",
     "nome": "Scienze sociali per la sostenibilità e la cooperazione internazionale", "durata": 3, "curricula": {}},
    {"slug": "corso-di-laurea-magistrale-comunicazione-pubblicitaria-storytelling-e-cultura-dimmagine-compsi",
     "classe": "LM-92", "tipo": "LM",
     "id": "unistrapg-lm-92-comunicazione-pubblicitaria-storytelling-e-cultura-d-immagin", "id_universitaly": "1628248",
     "nome": "Comunicazione pubblicitaria, storytelling e cultura d'immagine", "durata": 2, "curricula": {}},
    {"slug": "corso-di-laurea-magistrale-italiano-linsegnamento-stranieri-itas", "classe": "LM-14", "tipo": "LM",
     "id": "unistrapg-lm-14-italiano-per-l-insegnamento-a-stranieri", "id_universitaly": "1628242",
     "nome": "Italiano per l'insegnamento a stranieri", "durata": 2,
     "curricula": {"itas-l": "Linguistico", "itas-c": "Cultura e civiltà"}},
    {"slug": "corso-di-laurea-magistrale-relazioni-internazionali-e-cooperazione-allo-sviluppo-rics",
     "classe": "LM-52", "tipo": "LM",
     "id": "unistrapg-lm-52-lm-81-relazioni-internazionali-e-cooperazione-allo-sviluppo", "id_universitaly": "1628247",
     "nome": "Relazioni Internazionali e Cooperazione allo Sviluppo", "durata": 2, "curricula": {}},
]

# Righe della tabella che il programma degli insegnamenti chiama in un altro modo: per eliminazione, nello stesso corso,
# anno e semestre c'è una sola attività della stessa materia (deduzione, non scritta sulla fonte).
ALIAS = {
    "L-10": {"geografie digitali": "A000955",                       # «Geografia» (2° anno, 2° semestre; appelli «GEOGRAFIA»)
             "laboratorio cartografia digitale delle geografie umane": "A000975"},  # «Laboratorio: Geografia digitale»
}

PROBLEMI: list[str] = []     # totali di anno/curriculum che non tornano con la riga «Totale» della tabella
DEDUZIONI: list[str] = []    # cose non scritte sulla fonte

ANNI = {"primo": 1, "secondo": 2, "terzo": 3, "i": 1, "ii": 2, "iii": 3}
ROMANI = {"I": 1, "II": 2, "III": 3}
OPZIONALE = re.compile(r"(?i)opzional[ei]\s+tra\b")
NON_ATTIVO = re.compile(r"(?i)\(?\s*non\s+attivo[^)]*\)?")
CFU_PAR = re.compile(r"\s*\(\s*(\d+)\s*CFU\s*\)", re.I)
INTEGRATO = re.compile(r"(?i)\s*\(\s*insegnamento\s+integrato\s*\)\s*:?\s*$")
SSD_OK = re.compile(r"^[A-Z]{3,5}-\d{2}/[A-Z]$")
GENERICA = re.compile(r"(?i)^attivit[àa] formative a scelta\b")
TITOLI = r"(?:prof\.?ssa|prof\.|dott\.?ssa|dott\.|dr\.?ssa|dr\.)"
APOSTROFI = str.maketrans({"’": "'", "‘": "'", "`": "'", "´": "'"})


def norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", (s or "").lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _righe(h: str) -> list[str]:
    h = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>", "\n", h)
    h = re.sub(r"<[^>]+>", "", h)
    h = html.unescape(h).replace("\xa0", " ").translate(APOSTROFI)
    return [re.sub(r"\s+", " ", x).strip() for x in h.split("\n") if x.strip()]


def _pulisci(nome: str) -> str:
    """Nome dalla tabella: senza «(N CFU)», «+» come «e», «(Insegnamento integrato)» e asterischi."""
    n = CFU_PAR.sub("", nome)
    n = INTEGRATO.sub("", n)
    n = re.sub(r"\s*\+\s*", " e ", n)
    n = re.sub(r"\*+$", "", n).strip()
    return re.sub(r"\s+", " ", n)


# --------------------------------------------------------------------------------------------------------------------
# tabella «Piano di studi»
# --------------------------------------------------------------------------------------------------------------------
def _tabella(t: str) -> str:
    i = t.find("Totale")
    j = t.rfind("<table", 0, i)
    k = t.find("</table>", i)
    if i < 0 or j < 0:
        raise ValueError("tabella del piano di studi non trovata")
    return t[j:k]


def _cfu_cella(testo: str) -> int | None:
    s = testo.strip().rstrip("*").strip()
    if s in ("", "-", "–"):
        return None
    if not s.isdigit():
        raise ValueError(f"CFU non numerici: {testo!r}")
    return int(s)


def leggi_piano(t: str, spec: dict) -> list[dict]:
    """Righe della tabella: {anno, righe: [testo del nome], ssd: [..], cfu: [per colonna], colonne: [nomi]}."""
    tb = _tabella(t)
    intest = [_righe(x)[0] if _righe(x) else "" for x in re.findall(r"<th[^>]*>(.*?)</th>", tb, re.S)]
    nomi_col: list[str | None] = []
    for c in intest[2:]:
        if spec["curricula"]:
            k = norm(c).replace(" ", "-")
            if k not in spec["curricula"]:
                raise ValueError(f"{spec['classe']}: curriculum {c!r} sconosciuto")
            nomi_col.append(spec["curricula"][k])
        else:
            nomi_col.append(None)
    righe: list[dict] = []
    somme: dict[int, list[int]] = {}
    anno = None
    for tr in re.findall(r"<tr>(.*?)</tr>", tb, re.S):
        tds = [_righe(x) for x in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        if len(tds) < 2 or not any(tds):
            continue
        c0 = tds[0][0] if tds[0] else ""
        m = re.fullmatch(r"(?i)(primo|secondo|terzo|I{1,3})\s+anno", c0)
        if m:
            anno = ANNI[m.group(1).lower()]
            somme[anno] = [0] * len(nomi_col)
            continue
        nome = tds[1]
        if not nome or anno is None:
            continue
        cfu = [_cfu_cella(x[0] if x else "") for x in tds[2:]]
        if len(cfu) != len(nomi_col):
            raise ValueError(f"{spec['classe']} anno {anno}: {len(cfu)} colonne invece di {len(nomi_col)} in {nome}")
        if re.match(r"(?i)totale", nome[0]):
            for j, tot in enumerate(cfu):
                if tot != somme[anno][j]:
                    PROBLEMI.append(f"{spec['classe']} anno {anno} {nomi_col[j] or ''}: somma righe {somme[anno][j]} "
                                    f"invece di {tot}")
            continue
        for j, v in enumerate(cfu):
            somme[anno][j] += v or 0
        righe.append({"anno": anno, "righe": nome, "ssd": tds[0], "cfu": cfu, "colonne": nomi_col})
    return righe


def _ssd(s: str | None) -> str | None:
    return s if s and SSD_OK.match(s) else None


def espandi(r: dict) -> list[dict]:
    """Una riga della tabella -> righe di insegnamenti (una per alternativa) con CFU per colonna."""
    nome, ssd, cfu = r["righe"], r["ssd"], r["cfu"]
    base = {"anno": r["anno"], "cfu": cfu, "colonne": r["colonne"]}
    # --- gruppo «Un esame opzionale tra:»
    idx = next((k for k, x in enumerate(nome) if OPZIONALE.search(x)), None)
    if idx is not None:
        lab = bool(re.search(r"(?i)\blaboratorio\b", nome[idx]))
        opz: list[dict] = []
        for x in nome[idx + 1:]:
            if NON_ATTIVO.fullmatch(x.strip()):  # «(non attivo nell'a.a. …)» su una riga a parte: vale per la precedente
                if opz:
                    opz[-1]["attivo"] = False
                continue
            if re.fullmatch(r"(?i)oppure", x.strip()):
                continue
            attivo = not NON_ATTIVO.search(x)
            x = NON_ATTIVO.sub("", x).strip()
            if opz and opz[-1]["integrato"] and CFU_PAR.search(x) and not re.search(r"(?i)integrato", x):
                opz[-1]["moduli"].append(_pulisci(x))  # modulo dell'integrato precedente
                continue
            integ = bool(re.search(r"(?i)insegnamento\s+integrato", x))
            nome_o = _pulisci(x)
            if lab and not re.match(r"(?i)laboratorio", nome_o):
                nome_o = f"Laboratorio: {nome_o}"
            opz.append({"nome": nome_o, "attivo": attivo, "integrato": integ, "moduli": []})
        ssd_o = ssd if len(ssd) == len(opz) else None
        out = []
        for k, o in enumerate(opz):
            if o["attivo"]:
                out.append({**base, "nome": o["nome"], "tipo": "scelta", "moduli": o["moduli"],
                            "ssd": _ssd(ssd_o[k]) if ssd_o else None})
        return out
    # --- crediti a scelta (con eventuale elenco di attività consigliate)
    if GENERICA.match(nome[0]):
        out = [{**base, "nome": "Attività formative a scelta", "tipo": "afs", "ssd": None, "moduli": []}]
        sugg = nome[1:]
        for k, x in enumerate(sugg):
            m = CFU_PAR.search(x)
            if not m:
                raise ValueError(f"attività consigliata senza CFU: {x!r}")
            out.append({"anno": r["anno"], "nome": _pulisci(x), "tipo": "consigliata", "colonne": r["colonne"],
                        "cfu": [int(m.group(1)) if c is not None else None for c in cfu], "moduli": [],
                        "ssd": _ssd(ssd[k]) if len(ssd) == len(sugg) else None})
        return out
    if norm(nome[0]) == "laboratori":
        return [{**base, "nome": "Laboratori", "tipo": "laboratori", "ssd": None, "moduli": []}]
    # --- insegnamento integrato: «Titolo (insegnamento integrato):» + moduli
    if re.search(r"(?i)insegnamento\s+integrato", nome[0]) and len(nome) > 1:
        return [{**base, "nome": _pulisci(nome[0]), "tipo": "obbligatorio", "moduli": [_pulisci(x) for x in nome[1:]],
                 "ssd": _ssd(ssd[0]) if len(set(ssd)) == 1 else None}]
    # --- insegnamento semplice (il nome può andare a capo)
    return [{**base, "nome": _pulisci(" ".join(nome)), "tipo": "obbligatorio", "moduli": [],
             "ssd": _ssd(ssd[0]) if len(ssd) == 1 else None}]


# --------------------------------------------------------------------------------------------------------------------
# «Programmi degli insegnamenti»
# --------------------------------------------------------------------------------------------------------------------
def _docenti(txt: str, nome: str) -> list[str]:
    """Docenti dopo il nome nella riga del programma: «- prof. Mario Rossi - dott.ssa Anna Bianchi», anche senza titolo;
    «da definire» e testi che non sono nomi si saltano."""
    resto = txt
    k = resto.find(nome)
    if k >= 0:
        resto = resto[k + len(nome):]
    out = []
    resto = re.sub(rf"(?i)\s*[-–]\s*(?={TITOLI})", "|", resto.strip(" -–"))   # «…Sagnella- dott.ssa Maria Luisa …»
    for seg in re.split(r"\||\s+[-–]\s+", resto):
        seg = re.sub(rf"(?i)^{TITOLI}\s*", "", seg.strip(" -–"))
        if re.fullmatch(r"[A-Za-zÀ-ÿ'. -]{3,}", seg) and len(seg.split()) >= 2 and not re.search(r"(?i)da definire", seg):
            seg = re.sub(r"\s+", " ", seg)
            if seg not in out:
                out.append(seg)
    return out


def leggi_programmi(t: str) -> list[dict]:
    """Insegnamenti erogati: {anno, periodo, nome, codice, docenti, url, cdl, modulo (bool), base (codice senza -N)}."""
    i = t.find("Programmi degli insegnamenti")
    if i < 0:
        return []
    seg = t[i:]
    j = seg.find("Il corso raccontato")
    seg = seg[: j if j > 0 else len(seg)]
    out: list[dict] = []
    anno = sem = None
    for p in re.split(r"(?i)<br\s*/?>|</p>|</h4>|</h2>|</span></button>", seg):
        txt = html.unescape(re.sub(r"<[^>]+>", "", p)).replace("\xa0", " ").translate(APOSTROFI)
        txt = re.sub(r"\s+", " ", txt).strip()
        if not txt:
            continue
        m = re.fullmatch(r"(Primo|Secondo|Terzo) anno", txt)
        if m:
            anno, sem = ANNI[m.group(1).lower()], None
            continue
        m = re.fullmatch(r"(Primo|Secondo) semestre|Annuale", txt)
        if m:
            sem = {"Primo": "1", "Secondo": "2"}.get(m.group(1), "annuale")
            continue
        a = re.search(r'<a [^>]*href="([^"]*ins=([^"&]+)[^"]*)"[^>]*>(.*?)</a>', p, re.S)
        if not a:
            continue
        href = html.unescape(a.group(1))
        nome = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", a.group(3))).replace("\xa0", " ")).strip()
        nome = nome.translate(APOSTROFI)
        cod = a.group(2).upper()
        cdl = re.search(r"cdl=([A-Z0-9]+)", href)
        url = re.sub(r"[&?]rnd=\d+", "", href)
        modulo = bool(re.search(r"-\d+$", cod))
        out.append({"anno": anno, "periodo": sem, "nome": nome, "codice": cod, "docenti": _docenti(txt, nome),
                    "url": url, "cdl": cdl.group(1) if cdl else None, "modulo": modulo,
                    "base": re.sub(r"-\d+$", "", cod)})
    return out


# --------------------------------------------------------------------------------------------------------------------
# abbinamenti per nome
# --------------------------------------------------------------------------------------------------------------------
def _varianti(n: str) -> list[str]:
    v = [n]
    v.append(n[len("laboratorio "):] if n.startswith("laboratorio ") else "laboratorio " + n)
    return v


def abbina(nome: str, indice: dict[str, list[dict]], usati: set | None = None) -> dict | None:
    """Voce dell'indice (norm(nome) -> [voci]) con lo stesso nome: uguale, uguale a meno di «Laboratorio:», uno
    prefisso dell'altro («… dell'italiano» / «… dell'italiano e Laboratorio di …») o quasi uguale (rapporto 0,9)."""
    def prima(voci):
        voci = [x for x in voci if not usati or id(x) not in usati] or voci
        return voci[0]
    n = norm(nome)
    for v in _varianti(n):
        if v in indice:
            return prima(indice[v])
    for k, voci in indice.items():
        a, b = (n, k) if len(n) <= len(k) else (k, n)
        if len(a) >= 14 and b.startswith(a + " e ") and len(a) >= 0.55 * len(b):
            return prima(voci)
    cand = difflib.get_close_matches(n, list(indice), n=1, cutoff=0.9)
    return prima(indice[cand[0]]) if cand else None


def _indice(voci: list[dict], chiave="nome") -> dict[str, list[dict]]:
    d: dict[str, list[dict]] = {}
    for v in voci:
        d.setdefault(norm(v[chiave]), []).append(v)
    return d


def _scheda(c: Client, url: str) -> dict:
    """Anno di corso, semestre e CFU dalla scheda dell'insegnamento (vuoto se la scheda non è pubblicata)."""
    r = c.get(url)
    if r is None:
        return {}
    s = re.sub(r"(?s)<(script|style).*?</\1>", "", r.text)
    s = html.unescape(re.sub(r"<[^>]+>", "\n", s)).replace("\xa0", " ")
    righe = [re.sub(r"\s+", " ", x).strip() for x in s.split("\n") if x.strip()]
    d = {}
    for lab in ("Anno di corso", "Semestre", "CFU", "Insegnamento"):
        if lab in righe and righe.index(lab) + 1 < len(righe):
            d[lab] = righe[righe.index(lab) + 1]
    return d


def _curriculum(spec_cols: list, per_col: dict[int, int | None], v) -> str | None:
    """Percorsi (nomi delle colonne) che hanno la riga con `v` CFU; None se vale per tutti."""
    cols = [spec_cols[j] for j, x in per_col.items() if x == v]
    if len(cols) == len(spec_cols) or not any(cols):
        return None
    return ", ".join(cols)


def costruisci_corso(spec: dict, url: str, t: str, cat: dict, c: Client, oggi: str, log=print) -> dict:
    righe = []
    for r0 in leggi_piano(t, spec):
        righe.extend(espandi(r0))
    prog = leggi_programmi(t)
    ind_prog = _indice(prog)
    ind_cat = _indice(cat.get("insegnamenti") or [])
    usati_prog: set[int] = set()
    items: list[dict] = []
    codici_usati: set[str] = set()

    def dati_prog(nome: str, moduli: list[str]) -> tuple[dict | None, str | None]:
        """Voce del programma per nome; per un integrato anche dai moduli (codice del padre, docenti dei moduli)."""
        alias = ALIAS.get(spec["classe"], {}).get(norm(nome))
        p = next((x for x in prog if alias and x["codice"] == alias), None) or abbina(nome, ind_prog)
        if p and not p["modulo"]:
            usati_prog.add(id(p))
            return p, p["codice"]
        mod = [abbina(mn, ind_prog) for mn in moduli]
        mod = [m for m in mod if m and m["modulo"]]
        if mod:
            base = mod[0]["base"]
            figli = [x for x in prog if x["modulo"] and x["base"] == base]
            for f in figli:
                usati_prog.add(id(f))
            docenti = []
            for f in figli:
                docenti += [d for d in f["docenti"] if d not in docenti]
            return {**mod[0], "docenti": docenti, "codice": base, "nome": nome,
                    "url": re.sub(r"ins=[^&]+", f"ins={base}", mod[0]["url"])}, base
        if p:  # un modulo trovato per nome ma l'integrato non ha moduli indicati nel piano
            usati_prog.add(id(p))
            return p, p["base"]
        return None, None

    for r in righe:
        nome, tipo = r["nome"], r["tipo"]
        p, cod = dati_prog(nome, r.get("moduli") or [])
        k = abbina(nome, ind_cat)
        if tipo == "afs":  # tra i crediti a scelta del catalogo quello con gli stessi CFU
            val = [v for v in r["cfu"] if v is not None][0]
            k = next((x for x in ind_cat.get(norm(nome), []) if x.get("cfu") == val), None)
        cod = cod or (k or {}).get("codice")
        cfu_per_col = {j: v for j, v in enumerate(r["cfu"]) if v is not None}
        valori = sorted(set(cfu_per_col.values()))
        for v in valori:
            nome_v = nome if len(valori) == 1 else f"{nome} ({v} CFU)"
            if len(valori) > 1 and cod:
                cod = None  # lo stesso codice con CFU diversi per curriculum si fonderebbe in una riga sola
            it = {
                "codice": cod, "nome": nome_v, "anno": r["anno"],
                "periodo": (p or {}).get("periodo") or (k or {}).get("periodo"),
                "cfu": v, "ssd": r.get("ssd") or _ssd((k or {}).get("ssd")),
                "obbligatorio": tipo in ("obbligatorio", "laboratori"),
                "curriculum": _curriculum(r["colonne"], cfu_per_col, v) if len(r["colonne"]) > 1 else None,
                "docenti": (p or {}).get("docenti") or (k or {}).get("docenti") or [],
                "url": (k or {}).get("url") or (p or {}).get("url") or url,
                "libri": (k or {}).get("libri") or [], "esami": [],
                "fonte": url, "verificato_il": oggi,
            }
            if tipo == "laboratori":
                it["nota"] = "Crediti di laboratorio del piano di studi; i laboratori offerti sono insegnamenti a scelta"
            if tipo == "consigliata":
                it["obbligatorio"] = False
                it["nota"] = "Attività consigliata dal corso di studi tra le attività formative a scelta"
            for kk in ("periodo_inizio", "periodo_fine", "modalita_esame", "stato_libri", "url_sito"):
                if (k or {}).get(kk):
                    it[kk] = k[kk]
            if cod:
                codici_usati.add(cod)
            items.append(it)
    # insegnamenti erogati nel 2026/27 che non sono nella tabella (3° anno del vecchio ordinamento, laboratori offerti)
    visti = set(codici_usati)
    for p in prog:
        if id(p) in usati_prog or p["modulo"] or p["codice"] in visti:
            continue
        visti.add(p["codice"])
        sc = _scheda(c, p["url"])
        cfu = int(sc["CFU"]) if (sc.get("CFU") or "").isdigit() else None
        if cfu is None:
            log(f"[{UID}] {spec['classe']}: {p['codice']} {p['nome']} senza scheda: non aggiunto")
            continue
        anno = ROMANI.get(sc.get("Anno di corso") or "") or p["anno"]
        k = abbina(p["nome"], ind_cat)
        items.append({
            "codice": p["codice"], "nome": p["nome"], "anno": anno, "periodo": p["periodo"], "cfu": cfu,
            "ssd": _ssd((k or {}).get("ssd")), "obbligatorio": False, "curriculum": None, "docenti": p["docenti"],
            "url": p["url"], "libri": (k or {}).get("libri") or [], "esami": [], "fonte": url,
            "verificato_il": oggi,
            "nota": "Insegnamento erogato nel 2026/27 non presente nella tabella del piano di studi 2026/27 "
                    "(anno e CFU dalla scheda)",
        })
    return {
        "id": spec["id"], "id_universitaly": spec["id_universitaly"], "nome": spec["nome"], "classe": spec["classe"],
        "tipo_catalogo": spec["tipo"], "durata_anni": spec["durata"],
        "sede": cat.get("sede"), "codice_ateneo": cat.get("codice_ateneo") or next(
            (p["cdl"] for p in prog if p["cdl"] and p["cdl"].endswith("R")), None),
        "url": (cat.get("url") or url), "curricula": sorted(set(spec["curricula"].values())) or None,
        "ammissione": cat.get("ammissione"),
        "fonte": url, "verificato_il": oggi, "insegnamenti": items,
    }


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print,
                 client: Client | None = None) -> dict:
    from . import cineca_catalogue
    c = client or Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    # catalogo Cineca (solo le tre magistrali): docenti, periodo, modalità d'esame e libri dello stesso insegnamento
    try:
        cat = cineca_catalogue.fetch_ateneo(uid, BASE, anno, syllabus=syllabus, log=log)["corsi"]
    except Exception as e:  # noqa: BLE001 - senza catalogo restano i dati del sito
        log(f"[{uid}] catalogo non raggiungibile: {e!r}")
        cat = []
    cat_per_classe = {(x.get("classe") or "").split("/")[0].strip(): x for x in cat}
    corsi = []
    for spec in CORSI[: max_cds or None]:
        url = SITO + spec["slug"]
        r = c.get(url)
        if r is None:
            log(f"[{uid}] {spec['classe']}: pagina non raggiungibile")
            continue
        corso = costruisci_corso(spec, url, r.text, cat_per_classe.get(spec["classe"]) or {}, c, oggi, log)
        if corso["insegnamenti"]:
            corsi.append(corso)
        log(f"[{uid}] {spec['classe']}: {len(corso['insegnamenti'])} insegnamenti")
    for p in PROBLEMI:
        log(f"[{uid}] ATTENZIONE totale che non torna: {p}")
    return {"universita_id": uid,
            "descrizione": f"Generato da {SITO} (piano di studi e programmi degli insegnamenti) e da {BASE}",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi, "canali": []}


if __name__ == "__main__":
    out = ROOT / "database" / "contrib" / "auto" / "unistrapg.json"
    doc = fetch_ateneo(UID, 2026, syllabus="--senza-syllabus" not in sys.argv)
    doc["appelli"] = {}
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"scritto {out}")
