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

Con la variabile d'ambiente UN_HTTP_CACHE le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import unicodedata

from . import cineca_catalogue
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


def fetch_ateneo(uid: str, anno: int, max_cds: int | None = None, syllabus: bool = True, log=print) -> dict:
    cineca_catalogue._testi_syllabus = testi_syllabus
    try:
        doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                            client=ClientCache(BASE), coorte_per_nome=True)
    finally:
        cineca_catalogue._testi_syllabus = _testi_syllabus_orig
    db = _corsi_db()
    if db:
        elenco: list[dict] = []
        cineca_catalogue._walk_cds(ClientCache(BASE).get("/corsi", {"anno": anno, "minimal": "true"}) or [], elenco)
        nomi_en = {x["cdsCod"]: x.get("des_en") for x in elenco}
        doc["corsi"] = associa(doc["corsi"], db, nomi_en, log=log)
    return doc
