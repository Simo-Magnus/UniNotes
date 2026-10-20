"""Università di Pisa: Course Catalogue Cineca con le correzioni che servono a UniPi.

- Con il nuovo ordinamento (a.a. 2026/27) quasi tutti i corsi hanno cambiato codice
  (Fisica: FIS-L fino alla coorte 2025, FISR-L dalla 2026): il piano del 2°, 3°… anno si
  cerca nella coorte giusta per nome, sede e tipo (`coorte_per_nome`, come per UniPD) invece
  di prendere il piano futuro della coorte che si iscrive ora; la durata (assente
  nell'elenco dei corsi) si legge dal piano, così i cicli unici hanno tutti e 5-6 gli anni.
- Ogni corso del catalogo si associa al corso giusto del database scrivendone l'`id`
  (stesso nome e classe; Giurisprudenza dell'Accademia Navale di Livorno è un corso a sé;
  il nome inglese per «INFORMATICA» LM-18 = «COMPUTER SCIENCE»). Se nel database lo stesso
  corso compare due volte (voce di Universitaly e voce creata dal catalogo con un nome un po'
  diverso), il piano va a tutte e due.
- Libri: molti syllabus UniPi citano i testi in forma breve («Fisica Generale 1, Rosati»),
  più testi su una riga separati da «;», o senza virgole («Brown. T. Poon. Introduzione alla
  Chimica Organica. EdiSES»). Se il riconoscimento generale (testi.estrai_libri) non trova
  nulla, si rilegge solo la sezione «Bibliografia e materiale didattico» riga per riga con
  regole più larghe ma prudenti (frasi descrittive, materiale del docente, slide, link e
  moduli on line ICoN esclusi). La citazione resta sempre quella del syllabus.

- Piani (`_fetch_piani`, come per UniME/UniTO ma con le etichette di UniPi): ogni anno si legge dalla coorte degli
  iscritti all'anno k oggi (anno - k + 1; il codice cambia con il riordino: «FIL-L» → «FILR-L»); se il corso non
  c'era, la coorte non ha l'anno o il suo piano è incompleto (tirocini e tesi non ancora inseriti), la coorte più
  vicina con un piano completo, di preferenza dello stesso ordinamento (la coorte è nell'`url` di ogni
  insegnamento). I gruppi del piano («GRUPPO CAR 1 II ANNO (12 CFU)») sono obbligatori solo se si sostengono per
  intero (una sola attività o CFU richiesti uguali alla somma); altrimenti le attività sono a scelta. I gruppi senza
  attività elencate («LIBERA SCELTA (12 CFU)», «fra 8 e 12 CFU» = il massimo) diventano una voce a scelta senza codice,
  con l'anno nel nome se si ripete in anni diversi. «Anno 0» e `altreAttivita` (non legati a un anno) vanno
  all'ultimo anno, a scelta, senza ripetere le attività già in un gruppo. Attività senza crediti (test, OFA,
  certificazioni) non sono insegnamenti. Stesso nome, anno e CFU con codici diversi: una voce sola; stesso nome con
  CFU diversi (Estetica 12 e 6 CFU): il nome porta i CFU. Percorsi «III anno», «V ANNO CTF» (piani per chi entra ad
  anni successivi) non sono curricula. I libri già raccolti nel contributo precedente non si rileggono.

Con la variabile d'ambiente UN_HTTP_CACHE le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import time
import unicodedata

from . import ammissione, cineca_catalogue
from .testi import (YEAR, _AUTORE, _BLOCCO, _EDITORI_CIT, _SEP, NON_LIBRO, _libero, _sembra_libro, _tipo,
                    estrai_libri, html_to_lines)

BASE = "https://unipi.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]

# corsi del catalogo che il nome non basta ad associare: (codice catalogo) -> id del corso nel database
SPECIALI = {
    "GACR": ["unipi-lmg-01-giurisprudenza-1634621"],  # Giurisprudenza, Accademia Navale (Livorno)
    "LMGR": ["unipi-lmg-01-giurisprudenza"],          # Giurisprudenza, Pisa
}


def _norm(s: str | None) -> str:
    s = re.sub(r"[’‘`´]", "'", s or "")  # apostrofo tipografico
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\((?:abilitante|abilitanti)[^)]*\)", " ", s)
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\bed\b", "e", s).strip()  # «naturali ed ambientali» = «naturali e ambientali»


def _classe(s: str | None) -> set[str]:
    """«L-3 / L-20» -> {L-3, L-20}; «LM-4 c.u.» -> {LM-4}; «L/SNT3», «LM/SC-GIUR» restano interi."""
    s = re.sub(r"(?i)\s*c\.?\s*u\.?$|\s+R$", "", (s or "").strip())
    return {re.sub(r"\s+", "", x).upper() for x in re.split(r"\s+/\s+|&|,", s) if x.strip()}


def _stessa_classe(a: set[str], b: set[str]) -> bool:
    """Classi in comune; «LM/SC-GI» del catalogo = «LM/SC-GIUR» di Universitaly."""
    return any(x == y or (len(x) >= 6 and len(y) >= 6 and (x.startswith(y) or y.startswith(x))) for x in a for y in b)


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str = BASE, rate: float = 5.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unipi_cc" if d else None
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
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


# --- libri -----------------------------------------------------------------------------------
_ETICHETTA = re.compile(r"(?i)^\s*(?:\d+[.)]\s*)?(?:bibliografia(?: e materiale didattico)?|testi?(?: (?:di riferimento|"
                        r"consigliat\w*|adottat\w*|suggerit\w*|obbligatori\w*|d'esame|per l'esame|principal\w*))?|"
                        r"libr[oi] di testo(?: consigliat\w*| adottat\w*)?|manual[ei](?: consigliat\w*| adottat\w*)?|"
                        r"reference(?:s| texts?| books?)?|textbooks?|readings?|letture(?: consigliate)?|"
                        r"(?:per )?(?:approfondiment\w+|consultazione)|(?:studenti )?(?:non )?frequentanti|"
                        r"parte [a-z0-9]+|modulo [a-z0-9]+)\s*[:.\-–]\s*")
_FRASE = re.compile(r"(?i)\b(?:verr[aà]|verranno|saranno|sar[aà]|viene|vengono|[eè] (?:richiest|consigliat|possibile|"
                    r"disponibil|necessari|sufficient)|sono (?:disponibil|consigliat|indicat|fornit|reperibil)|"
                    r"disponibil[ei] (?:sul|su|nella|in|presso)|fornit[oiae] (?:dal|dai|durante|a lezione)|"
                    r"indicat[oiae] (?:dal|dai|durante|a lezione|nel corso)|messo a disposizione|messi a disposizione|"
                    r"consultare|si consiglia|consigliamo|lo studente|gli studenti|le studentesse|students|will be|"
                    r"available|provided|lecture notes|slides?\b|lucidi|dispense del|appunti|materiale (?:didattico|"
                    r"fornito|del docente|delle lezioni|on ?line|integrativo)|e-?learning|moodle|teams|https?://|www\.|"
                    r"durante (?:il corso|le lezioni)|nel corso delle lezioni|a lezione|articoli scientifici|"
                    r"consorzio icon|nessun[oa]?\b|vedi sopra|see above|non (?:sono previsti|ci sono|è previsto)|"
                    r"qualsiasi|any (?:textbook|book)|a scelta (?:dello|dello studente)|it is recommended|pu[oò] essere|"
                    r"rappresentat[oa] da|in alternativa ai|reso disponibile|resi disponibili|scaricabil|diapositiv|"
                    r"note del corso|\bprof\.|\bparte [a-z0-9]\b|\bil corso\b|\bthe course\b)")
_ONLY_LABEL = re.compile(r"(?i)^[\w\s'’]{0,60}:$")


def _segmenti(line: str) -> list[str]:
    line = _ETICHETTA.sub("", line).strip(" -–•*·")
    out = []
    for p in re.split(r";\s*|\s+\|\s+", line):
        p = p.strip(" -–•*·")
        # «lo studio di 1 fra questi libri …: L'uomo medievale, …»: si tiene quello che segue i due punti
        m = re.match(r"([a-zà-ÿ][^:]{15,200}):\s+(\S.*)$", p)
        if m and len(m.group(1).split()) >= 4:
            p = m.group(2)
        m = None if re.search(r"(?i)(?:autor[ei]|editore|edizione|titolo|isbn)\s*:", p) else _INTRO.match(p)  # «Il manuale di riferimento è: P. Borghi, …»
        if m:
            p = m.group(1)
        if p:
            out.append(p)
    return out


def _breve(seg: str) -> bool:
    """«Fisica Generale 1, Rosati», «Termodinamica, Fermi»: titolo, cognome dell'autore."""
    m = re.fullmatch(r"([A-ZÀ-Ý][^,]{2,90}),\s*((?:[A-Z]\.\s?)*[A-ZÀ-Ý][a-zà-ÿ'’]+(?:\s(?:[A-Z]\.\s?)*[A-ZÀ-Ý][a-zà-ÿ'’]+)?"
                     r"(?:\s(?:e|and|&)\s(?:[A-Z]\.\s?)*[A-ZÀ-Ý][a-zà-ÿ'’]+)?)\.?", seg)
    return bool(m) and not re.search(r"\d{3,}", m.group(2))


_NOMI = r"(?:[A-ZÀ-Ý][\w'’.]*\.?\s?){1,4}"
_AUTORI_DOPO = re.compile(rf"(.{{6,160}}?)\s[-–]\s({_NOMI}(?:(?:,\s|\se\s|\sand\s|\s&\s){_NOMI})*(?:\s?et al\.?)?)"
                          r"\s*(?:\([^)]*\))?\.?")
_AUTORI_PRIMA = re.compile(rf"(?:{_AUTORE})(?:{_SEP}(?:{_AUTORE}))*(?:,?\set\.?\sal\.?)?\s[-–]\s\S")
_INTRO = re.compile(r"(?i)^(?:[^:]{0,80}\b(?:è|sono|seguent\w*|riferimento|consigliat\w*|test[oi]|libr[oi]|manual[ei]|"
                    r"adottat\w*|suggerit\w*|studio|esame)\b[^:]{0,60}):\s+(\S.*)$")


def _forma_libro(seg: str, parole: int) -> bool:
    """Forme di citazione riconoscibili anche senza editore noto o anno."""
    if re.match(r"(?i)(?:ed\.|editore|edizion)", seg):  # solo l'editore: pezzo di una citazione spezzata
        return False
    if len(re.findall(r"[A-Za-zÀ-ÿ]{3,}", re.sub(_AUTORE, " ", seg))) < 2:  # solo nomi di autori
        return False
    return bool(
        _sembra_libro(seg)
        or (_EDITORI_CIT.search(seg) and parole >= 4)
        or (_BLOCCO.match(seg) and parole >= 4 and re.search(r"[.,:]\s+\S+\s+\S+", seg))
        or _breve(seg)
        # «… Autore: Francesco Giovagnorio», «Manuale … - a cura di Diego Lo Presti»
        or (re.search(r"(?i)\bautor[ei]\s*:|\ba cura di\s+[A-Z]", seg) and parole >= 4)
        # «Wiedemann, "Particle Accelerator Physics"», «“Manuale di …”, vol. I (Autori: …)»
        or (re.search(r"[“\"«][^”\"»]{6,}[”\"»]", seg) and re.search(r"[A-ZÀ-Ý][a-zà-ÿ]{2,}", seg) and parole >= 3)
        # «Il Colore della Luna - Paola Bressan», «Spinta delle terre … - Clayton, Milititsky, Woods»
        or (_AUTORI_DOPO.fullmatch(seg) and parole >= 4)
        # «L. Kirkup, R. B. Frenkel - An Introduction to …»
        or (_AUTORI_PRIMA.match(seg) and parole >= 4)
        # «Signorelli, Igiene e sanità pubblica. … 2021 SEU»
        or (re.match(r"[A-ZÀ-Ý][a-zà-ÿ'’]+(?:\s[A-Z]\.)*,\s[A-ZÀ-Ý]", seg) and YEAR.search(seg) and parole >= 4)
        # «… Ed. Calzetti Mariucci», «Editore: Esculapio»
        or (re.search(r"\b(?:Ed\.|Edizioni|Editore:?|Editrice)\s*[A-ZÀ-Ý]", seg) and parole >= 4))


def libri_larghi(testi: list[str]) -> list[dict]:
    """Rilettura prudente della bibliografia quando estrai_libri non trova nulla."""
    out, viste, tipo_ctx = [], set(), None
    for t in testi:
        for line in html_to_lines(t):
            if _ONLY_LABEL.match(line) or (len(line) < 80 and line.rstrip().endswith(":")):
                tipo_ctx = _tipo(line) or tipo_ctx
                continue
            for seg in _segmenti(line):
                if len(seg) < 10 or len(seg) > 320 or NON_LIBRO.match(seg) or _FRASE.search(seg):
                    continue
                parole = len(re.findall(r"[A-Za-zÀ-ÿ]{2,}", seg))
                if not _forma_libro(seg, parole):
                    continue
                item = _libero(seg)
                item["tipo"] = item["tipo"] or tipo_ctx
                key = re.sub(r"\W+", "", item["citazione"].lower())[:120]
                if key not in viste:
                    viste.add(key)
                    out.append(item)
    return out[:30]


def _testi_bibliografia(sy: dict) -> list[str]:
    testi = []
    for t in sy.get("testiTotali") or []:
        for k, v in t.items():
            if isinstance(v, str) and re.search(r"(^|_)testi_it$", k):
                testi.append(v)
        for a in (cineca_catalogue._lista(t.get("altri_testi")) + cineca_catalogue._lista(t.get("mod_altri_testi"))
                  + cineca_catalogue._lista(t.get("altri_testi_ugov"))):
            lab = a.get("etichetta_it") or a.get("ugov_etichetta_it") or ""
            if re.search(r"testi|bibliograf|libr", lab, re.I) and "disponibilit" not in lab.lower():
                testi.append(a.get("altri_testi_it") or a.get("ugov_altri_testi_it") or "")
    return testi


def testi_syllabus(sy: dict):
    libri, modalita, legati = _testi_syllabus_orig(sy)
    if not libri:
        libri = libri_larghi(_testi_bibliografia(sy))
    return libri, modalita, legati


_testi_syllabus_orig = cineca_catalogue._testi_syllabus


# --- associazione ai corsi del database -------------------------------------------------------
def _corsi_db() -> list[dict]:
    p = ROOT / "database" / "corsi" / "unipi.json"
    return json.loads(p.read_text(encoding="utf-8"))["corsi"] if p.exists() else []


def associa(corsi: list[dict], db: list[dict], nomi_en: dict[str, str] | None = None, log=print) -> list[dict]:
    """Un contributo per ogni corso del database a cui va il piano (di solito uno)."""
    out, senza = [], []
    nomi_en = nomi_en or {}
    for c in corsi:
        cod = c.get("codice_ateneo") or ""
        if cod in SPECIALI:
            ids = SPECIALI[cod]
        else:
            cl = _classe(c.get("classe"))
            ok_cl = lambda d: not cl or not d.get("classe") or _stessa_classe(cl, _classe(d.get("classe")))  # noqa: E731
            cand = []
            for nome in (_norm(c["nome"]), _norm(nomi_en.get(cod))):
                if nome and not cand:
                    cand = [d for d in db if nome in (_norm(d["nome"]), _norm(d.get("nome_en"))) and ok_cl(d)]
            # voce creata dal catalogo (senza id Universitaly) + voce Universitaly dello stesso corso con nome più lungo
            stessa = [d for d in db if cod and d.get("codice_ateneo") == cod and not d.get("id_universitaly")]
            if stessa:
                cl_s = _classe(stessa[0].get("classe"))
                cand = list({d["id"]: d for d in cand + stessa + [
                    d for d in db if d.get("id_universitaly") and _stessa_classe(_classe(d.get("classe")), cl_s)
                    and _norm(d["nome"]).startswith(_norm(stessa[0]["nome"]) + " ")]}.values())
            ids = [d["id"] for d in cand]
        if not ids:
            senza.append(f"{cod} {c['nome']} ({c.get('classe')})")
            continue
        for i in ids:
            out.append({**c, "id": i})
    if senza:
        log(f"[unipi] corsi del catalogo senza corso nel database: {senza}")
    return out


# --- piani di studio ---------------------------------------------------------------------------
# Il piano di una coorte è fatto di gruppi («Obbligatori», «GRUPPO CAR 1 II ANNO (12 CFU)», «LIBERA SCELTA
# (12 CFU)», «TEST (1 attività didattica)»…) e, a parte, di una sezione `altreAttivita` (elenco di attività non legate
# a un anno) e talvolta di un «anno 0». L'adattatore comune (cineca_catalogue) non leggeva le etichette dei gruppi:
# scartava i crediti a scelta senza insegnamenti elencati, lasciava senza anno l'elenco delle altre attività (292
# righe), teneva due volte gli insegnamenti omonimi con codici e CFU diversi e, per i piani di una coorte senza
# anni strutturati (Ingegneria chimica 2024), lasciava vuoti gli anni.
TIPI = {"L", "LM", "LM5", "LM6"}  # lauree, magistrali, cicli unici (le altre righe sono corsi di perfezionamento, FC)
RATE = 5.0
_ETICHETTA_CFU = re.compile(r"\(\s*(?:fra\s+([\d.,]+)\s+e\s+)?([\d.,]+)\s*CFU\s*\)", re.I)
_ETICHETTA_ATT = re.compile(r"\(\s*(\d+)\s+attivit[àa]\s+didattich?[ae]\s*\)", re.I)
# parti dell'etichetta che non sono il nome: «REGOLA S», «(CFU 9)», «6CFU», «9 CFU»
_RUMORE_ETICHETTA = re.compile(r"(?i)\(\s*CFU\s*\d+\s*\)|\bregola\s+[a-z]\b|\b\d+\s*CFU\b|\bCFU\b")
_COMUNE = re.compile(r"(?i)\b(?:comune|statutario|generico|unico)\b|^\s*statutory\b")
_CLASSE_NOME = re.compile(r"(?i)\bclasse\b|\bLM?[-\s]?\d{1,2}\b")
_PREFISSO = re.compile(r"(?i)^\s*(?:curriculum|percorso|orientamento|orientation)\s*:?\s+")
# percorsi con il nome di un'altra sede / profili che sono corsi a sé nel database restano curricula
REPORT: dict = {}  # per corso e anno: coorte usata (riempito da fetch_ateneo, serve ai controlli)


def _num(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _etichetta(g: dict) -> dict:
    """Etichetta di un gruppo: CFU richiesti («(12 CFU)»), CFU liberi («(fra 8 e 12 CFU)»), numero di attività
    da sostenere («(1 attività didattica)») e nome senza queste indicazioni."""
    lab = g.get("label_it") or ""
    m = _ETICHETTA_CFU.search(lab)
    a = _ETICHETTA_ATT.search(lab)
    resto = _ETICHETTA_ATT.sub(" ", _ETICHETTA_CFU.sub(" ", lab))
    resto = re.split(r"\s*;|\s*,\s*tipo regola", resto, flags=re.I)[0]  # «…; TIPO REGOLA S», «…, Tipo regola S , TAF: D»
    resto = _RUMORE_ETICHETTA.sub(" ", resto).replace("\\", " ")
    resto = re.sub(r"\s+", " ", resto).strip(" -–:/")
    return {"cfu": _num(m.group(2)) if m else None, "fisso": bool(m and m.group(1) is None),
            "n_att": int(a.group(1)) if a else None, "nome": resto}


def _titolo_etichetta(s: str) -> str:
    """«ESAMI A LIBERA SCELTA» → «Esami a libera scelta» (le sigle in maiuscolo con meno di 5 lettere restano)."""
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        return s[:1].upper() + s[1:]
    out = []
    for i, w in enumerate(s.lower().split()):
        if re.fullmatch(r"[ivx]+", w):
            out.append(w.upper())
        elif i == 0:
            out.append(w[:1].upper() + w[1:])
        else:
            out.append(w)
    return " ".join(out)


def _crediti(att: dict) -> float:
    v = att.get("crediti")
    return float(v) if isinstance(v, (int, float)) else 0.0


def _distinte(atts: list[dict]) -> list[dict]:
    """Le attività di un gruppo senza ripetizioni dello stesso codice (il catalogo le elenca una volta per schema)."""
    viste, out = set(), []
    for a in atts:
        k = a.get("adCod") or a.get("cod")
        if k not in viste:
            viste.add(k)
            out.append(a)
    return out


def _tutte_da_sostenere(g: dict, et: dict) -> bool:
    """Gruppo le cui attività si sostengono tutte: una sola attività, CFU richiesti uguali alla somma delle
    attività, o non più attività di quelle richieste («(1 attività didattica)» con una sola attività). Altrimenti
    lo studente sceglie tra le attività del gruppo."""
    atts = _distinte(g.get("attivita") or [])
    if not atts:
        return False
    if len(atts) == 1:
        return True
    tot = sum(_crediti(a) for a in atts)
    if et["cfu"] is not None and abs(tot - et["cfu"]) < 1e-6:
        return True
    return et["cfu"] is None and et["n_att"] is not None and len(atts) <= et["n_att"]


_VARIANTE_INGRESSO = re.compile(r"(?i)\b(?:II|III|IV|V|VI)\s*°?\s*anno\b")


def _nomi_percorsi(det: dict) -> dict[str, str | None]:
    """Nome di ogni percorso del piano → nome usato (None = da non leggere). Farmacia e CTF (coorte 2023) hanno
    gli stessi anni ripetuti in percorsi «FARMACIA-III anno», «V ANNO CTF»…: i piani per chi si iscrive ad anni
    successivi, non curricula. Si tiene il piano standard («Schema standard coorte 2023»); se tutti i percorsi sono di
    questo tipo (CTF) sono lo stesso piano ripetuto: si legge il primo, come percorso comune."""
    nomi = [(p.get("des_it") or p.get("pdsDes") or "").strip() for p in det.get("percorsi") or []]
    varianti = [n for n in nomi if _VARIANTE_INGRESSO.search(n)]
    if not varianti:
        return {n: n for n in nomi}
    if len(varianti) < len(nomi):
        return {n: (None if n in varianti else n) for n in nomi}
    return {n: ("comune" if i == 0 else None) for i, n in enumerate(nomi)}


def _voci_coorte(det: dict, durata: int) -> list:
    """Voci del piano di una coorte: (anno 1..durata, percorso, gruppo, attività o None, altre_attività).

    Le sezioni senza anno (`anno` 0: crediti non legati a un anno; `altreAttivita`) vanno all'ultimo anno.
    Un gruppo senza attività elencate ma con i CFU nell'etichetta dà una voce con attività None."""
    out = []
    mappa = _nomi_percorsi(det)
    for p in det.get("percorsi") or []:
        pnome = mappa.get((p.get("des_it") or p.get("pdsDes") or "").strip())
        if pnome is None:
            continue
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
                    if _etichetta(g)["cfu"] is not None:
                        out.append((k, pnome, g, None, False))
                    continue
                for att in atts:
                    out.append((k, pnome, g, att, False))
    return out


def _cfu_gruppi(gruppi: dict) -> float:
    tot, viste = 0.0, set()
    for g, atts in gruppi.values():
        et = _etichetta(g)
        atts = [x for x in atts if x]
        if g.get("cod") == "OO" or "obbligator" in (g.get("label_it") or "").lower():
            for a in _distinte(atts):
                kd = a.get("adCod") or a.get("cod")
                if kd not in viste:
                    viste.add(kd)
                    tot += _crediti(a)
        elif et["cfu"] is not None:
            tot += et["cfu"]
        else:
            cr = sorted(_crediti(a) for a in _distinte(atts))
            tot += sum(cr) if _tutte_da_sostenere(g, et) else (cr[len(cr) // 2] * (et["n_att"] or 1) if cr else 0)
    return tot


def _cfu_anno(voci: list, k: int) -> float:
    """CFU richiesti dall'anno k di un piano (senza `altreAttivita`): attività obbligatorie, CFU delle etichette
    dei gruppi, attività dei gruppi senza CFU nell'etichetta; per i piani con curricula quello con più CFU, più i
    percorsi comuni. Serve a scegliere la coorte e a controllare i piani."""
    per: dict[str, dict] = {}
    for kk, pn, g, att, altre in voci:
        if kk == k and not altre:
            per.setdefault(pn, {}).setdefault(id(g), (g, []))[1].append(att)
    valori = {pn: _cfu_gruppi(gs) for pn, gs in per.items()}
    comuni = sum(v for pn, v in valori.items() if _e_comune(pn))
    altri = [v for pn, v in valori.items() if not _e_comune(pn)]
    return comuni + (max(altri) if altri else 0)


def _coorte_anno(cohorts: dict, voci: dict, k: int, anno: int, durata: int) -> tuple[int | None, str]:
    """Coorte da cui leggere l'anno k: quella degli iscritti all'anno k oggi (anno - k + 1), se il suo piano ha
    quell'anno ed è completo. Se la coorte non c'è (corso nuovo), non ha l'anno, ha un piano molto parziale o un piano
    che nel complesso non arriva ai CFU del corso, la coorte più vicina dello stesso ordinamento (altrimenti la più
    vicina) che ha l'anno, di preferenza con un piano completo."""
    y0 = anno - k + 1
    ha = {y: _cfu_anno(v, k) for y, v in voci.items() if any(x[0] == k and not x[4] for x in v)}
    if not ha:
        return None, "nessuna coorte ha l'anno strutturato"
    totale = {y: sum(_cfu_anno(voci[y], kk) for kk in range(1, durata + 1)) for y in ha}
    completa = lambda y: totale[y] >= (cohorts[y][1].get("crediti") or 60 * durata) - 6  # noqa: E731
    ordin = lambda y: cohorts[y][1].get("ordinamento_aa")  # noqa: E731
    vicine = sorted(ha, key=lambda y: (abs(y - y0), -y))
    stesso = [y for y in vicine if y0 in cohorts and ordin(y) == ordin(y0)]
    if y0 in ha and (ha[y0] >= 54 or completa(y0)):
        return y0, "coorte degli iscritti"
    if y0 in ha:
        # piano parziale (meno di mezzo anno): la coorte più vicina più completa, di preferenza dello stesso ordinamento;
        # piano incompleto di una coorte già iscritta (mancano tirocini, tesi…): la coorte adiacente completa, di preferenza
        # dello stesso ordinamento. Il piano della coorte che si iscrive ora si legge sempre com'è.
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
    return scelta, ("la coorte non ha l'anno" if y0 in cohorts else "il corso non c'era in quella coorte") +         (": coorte più vicina dello stesso ordinamento" if stesso else ": coorte più vicina")


def _chiave_percorso(pnome: str) -> str:
    n = _PREFISSO.sub("", re.sub(r"\(.*?\)", " ", pnome).strip())
    return re.sub(r"[^a-z0-9]+", " ", unicodedata.normalize("NFKD", n).encode("ascii", "ignore").decode().lower()).strip()


def _e_comune(pnome: str) -> bool:
    return bool(_COMUNE.search(pnome)) and not _CLASSE_NOME.search(pnome)


def _vecchi_libri(path: pathlib.Path | None = None) -> dict:
    """Dati dei syllabus già raccolti (libri, modalità d'esame, SSD, sito) per (anno, codice della scheda), dal
    contributo precedente: si rileggono dal catalogo solo le schede senza libri."""
    path = path or ROOT / "database" / "contrib" / "auto" / "unipi.json"
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


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, riusa=None,
                 coorte_unica: int | None = None) -> dict:
    cc = cineca_catalogue
    c = client or ClientCache(BASE, rate=RATE)
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

    def cod_base(cds: str | None) -> str:
        """Con il nuovo ordinamento il codice cambia («FIL-L» → «FILR-L»): senza la «R» è lo stesso corso."""
        return re.sub(r"R(?=-|$)", "", (cds or "").strip().upper())

    def trova(y: int, cur: dict) -> dict | None:
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        for x in elenco:
            if cod_base(x["cdsCod"]) == cod_base(cur["cdsCod"]):
                return x
        ch = cineca_catalogue._chiave_cds(cur)
        stessi = [x for x in elenco if cineca_catalogue._chiave_cds(x) == ch]
        return stessi[0] if len(stessi) == 1 else None

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        voci = {y: _voci_coorte(d, durata) for y, (_, d) in cohorts.items()}
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{BASE}/corsi/{anno}/{cur.get('cod')}")
        # nome dei curricula: quello della coorte più recente che ha lo stesso curriculum
        nomi_percorso: dict[str, str] = {}
        for y in sorted(cohorts):
            for pn in filter(None, _nomi_percorsi(cohorts[y][1]).values()):
                if not _e_comune(pn):
                    nomi_percorso[_chiave_percorso(pn)] = re.sub(r"\s+", " ", _PREFISSO.sub("", pn)).strip(": ")
        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        zero: set[str] = set()
        rapporto: dict[int, dict] = {}
        for k in range(1, durata + 1):
            if coorte_unica is None:
                scelta, perche = _coorte_anno(cohorts, voci, k, anno, durata)
            else:
                scelta, perche = ((coorte_unica, "coorte unica") if any(
                    v[0] == k and not v[4] for v in voci.get(coorte_unica, [])) else (None, "n/d"))
            if scelta is None:
                rapporto[k] = {"coorte": None, "perche": perche}
                continue
            x, d = cohorts[scelta]
            rapporto[k] = {"coorte": scelta, "perche": perche, "url": f"{BASE}/corsi/{scelta}/{x['cod']}",
                           "cfu_richiesti": _cfu_anno(voci[scelta], k), "crediti_corso": d.get("crediti"),
                           "cfu_coorte": sum(_cfu_anno(voci[scelta], kk) for kk in range(1, durata + 1))}
            veri = [p for p in _nomi_percorsi(d).values() if p]
            curricula = {nomi_percorso.get(_chiave_percorso(p), p) for p in veri if not _e_comune(p)}
            if len(curricula) < 2:  # un solo percorso oltre al comune: non è un curriculum
                curricula = set()
            # prima i gruppi del piano, poi le «altre attività» (non legate a un anno): quelle già presenti in un gruppo
            # (di questo o di un altro anno) non si ripetono
            y0 = anno - k + 1
            lista = [(scelta, v) for v in voci[scelta]]
            if y0 != scelta and y0 in voci:  # coorte sostituita: le altre attività della coorte vera restano (a scelta)
                lista += [(y0, v) for v in voci[y0] if v[4]]
            for yc, (kk, pnome, g, att, altre) in sorted(lista, key=lambda t: t[1][4]):
                if kk != k:
                    continue
                if altre and (f"{k}:{att.get('adCod') or att.get('cod')}" in insegnamenti):
                    continue
                et = _etichetta(g)
                etichetta = (g.get("label_it") or "").lower()
                obbl = not altre and ("obbligator" in etichetta or g.get("cod") == "OO" or _tutte_da_sostenere(g, et))
                comune = _e_comune(pnome) or not curricula
                pcur = None if comune else nomi_percorso.get(_chiave_percorso(pnome), pnome)
                if att is None:  # crediti senza insegnamenti elencati: «LIBERA SCELTA (12 CFU)»
                    nome = _titolo_etichetta(et["nome"])
                    if len(nome) < 3 or not et["cfu"]:
                        continue
                    key = f"{k}:#{_norm(nome)}:{et['cfu']}"
                    item = insegnamenti.get(key)
                    if not item:
                        item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": et["cfu"],
                                "ssd": None, "obbligatorio": False, "curriculum": None, "_percorsi": set(),
                                "_tutti": curricula, "docenti": [], "url": f"{BASE}/corsi/{scelta}/{x['cod']}",
                                "libri": [], "esami": [], "fonte": BASE, "verificato_il": oggi, "_senza_codice": True}
                        insegnamenti[key] = item
                else:
                    if _crediti(att) <= 0:  # verifiche e test senza crediti (OFA, certificazioni): non sono insegnamenti
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
                            "url": f"{BASE}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                   f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={yc}",
                            "libri": [], "esami": [], "fonte": BASE, "verificato_il": oggi,
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
        # le altre attività già presenti in un gruppo del piano di un altro anno non si ripetono
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
            # stesso insegnamento con CFU diversi (Estetica 12 CFU e Estetica 6 CFU: schede e codici diversi): il nome
            # porta i CFU; stessi CFU, schede diverse dello stesso insegnamento (placeholder «Libera scelta per
            # riconoscimenti» con un codice per ogni percorso): una voce sola
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
                        if m:  # se la scheda tenuta non ha libri si usano quelli della scheda omonima
                            tenuto.setdefault("_fratelli", []).append((m.group(1), m.group(2)))
            if len(per_cfu) > 1:
                for i in gr:
                    if id(i) not in togli and isinstance(i["cfu"], (int, float)):
                        i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        ins = [i for i in ins if id(i) not in togli]
        # voci senza codice con lo stesso nome in anni diversi: il nome porta l'anno (build_db unisce per nome)
        anni_nome: dict[str, set] = {}
        for i in ins:
            if i.pop("_senza_codice", False):
                anni_nome.setdefault(_norm(i["nome"]), set()).add(i["anno"])
                i["_nk"] = _norm(i["nome"])
        for i in ins:
            nk = i.pop("_nk", None)
            if nk and len(anni_nome[nk]) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        REPORT[cur["cdsCod"]] = {"anni": rapporto, "senza_crediti": sorted(zero)}
        return {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{BASE}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": BASE, "verificato_il": oggi, "insegnamenti": ins,
        }

    def build_safe(cur: dict) -> dict | None:
        try:
            return build_cds(cur)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {cur.get('cdsCod')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; schede da leggere: {len(syllabus_jobs)}")

    def do_syllabus(item: tuple) -> int:
        chiave, job = item
        if not job["items"]:
            return 0
        try:
            return _do_syllabus(chiave, job)
        except Exception:  # noqa: BLE001 - una scheda illeggibile non ferma le altre
            return 0

    def _do_syllabus(chiave: tuple, job: dict) -> int:
        vecchio = riusa.get(chiave)
        if vecchio and vecchio.get("libri"):  # libri già raccolti per questa scheda
            libri, modalita, ssd, sito = vecchio["libri"], vecchio.get("modalita_esame"), vecchio.get("ssd"), vecchio.get("url_sito")
        else:
            sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
            if not isinstance(sy, dict):
                return 0
            libri, modalita, legati = testi_syllabus(sy)
            if not libri:  # la bibliografia è su Leganto
                for u in legati:
                    libri += cineca_catalogue.leganto.libri(u)
            ssd, sito = sy.get("ssd"), (sy.get("urlSitoWeb") or "").strip() or None
        risultati[chiave] = (libri, modalita, ssd, sito)
        return len(libri)

    risultati: dict[tuple, tuple] = {}
    trovati = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, [(k, j) for k, j in syllabus_jobs.items()]), 1):
            trovati += n
            if i % 1000 == 0:
                log(f"[{uid}]   schede {i}/{len(syllabus_jobs)}")
    for chiave, job in syllabus_jobs.items():
        libri, modalita, ssd, sito = risultati.get(chiave, ([], None, None, None))
        for it in job["items"]:
            for fr in it.pop("_fratelli", []) if not libri else []:
                if risultati.get(fr, ([],))[0]:
                    libri, modalita, ssd, sito = risultati[fr][0], modalita or risultati[fr][1], ssd or risultati[fr][2], sito
                    break
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
    return {"universita_id": uid, "descrizione": f"Generato da {BASE} (Course Catalogue Cineca, adapters/unipi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _durata(det: dict, tipo: str | None) -> int:
    """Durata legale dal piano («3 anni»): l'elenco minimale del catalogo non ha `durataAnni`."""
    if str(det.get("durataAnni") or "").isdigit() and int(det["durataAnni"]) > 0:
        return int(det["durataAnni"])
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    return {"L": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print,
                 client=None, riusa_libri: bool = True, coorte_unica: int | None = None) -> dict:
    """`riusa_libri`: le schede con libri già nel contributo precedente non si rileggono dal catalogo.
    `coorte_unica`: solo per i controlli, legge tutti gli anni dal piano di una sola coorte."""
    doc = _fetch_piani(uid, anno, max_cds, syllabus, log, client, _vecchi_libri() if riusa_libri else None,
                       coorte_unica)
    db = _corsi_db()
    if db:
        elenco: list[dict] = []
        cineca_catalogue._walk_cds((client or ClientCache(BASE)).get("/corsi", {"anno": anno, "minimal": "true"}) or [],
                                   elenco)
        nomi_en = {x["cdsCod"]: x.get("des_en") for x in elenco}
        doc["corsi"] = associa(doc["corsi"], db, nomi_en, log=log)
    return doc
