"""Università di Padova: Course Catalogue Cineca con le correzioni che servono a UniPD.

- Con il nuovo ordinamento molti corsi hanno cambiato codice (es. Ingegneria dell'energia:
  IN0515 nella coorte 2024, IN2917 dalla 2025): il piano del 2° e 3° anno si cerca nella
  coorte giusta per nome, sede e tipo (`coorte_per_nome`), invece di prendere il piano
  futuro della coorte che si iscrive ora.
- Ogni sede è un corso a sé nel catalogo, con docenti e syllabus propri (Medicina Padova 1-4
  e Treviso, Infermieristica in 8 sedi, …): si associa al corso giusto del database (le
  «REPLICA <città>» di Universitaly) scrivendo il suo `id` nel contributo.

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

BASE = "https://unipd.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]

# corsi con lo stesso nome in più sedi che il nome di Universitaly non distingue:
# (nome normalizzato, sede del catalogo) -> id del corso nel database
SEDI_SPECIALI = {
    ("medicina e chirurgia", "PADOVA 1"): "unipd-lm-41-medicina-e-chirurgia",
    ("medicina e chirurgia", "PADOVA 2"): "unipd-lm-41-medicina-e-chirurgia-replica-med-2",
    ("medicina e chirurgia", "PADOVA 3"): "unipd-lm-41-medicina-e-chirurgia-replica-med-3",
    ("medicina e chirurgia", "PADOVA 4"): "unipd-lm-41-medicina-e-chirurgia-replica-med-4",
    ("medicina e chirurgia", "TREVISO"): "unipd-lm-41-medicina-e-chirurgia-1631444",
    # www.unipd.it/corsi-di-laurea/giurisprudenza-treviso e …/giurisprudenza
    ("giurisprudenza", "TREVISO"): "unipd-lmg-01-giurisprudenza",
    ("giurisprudenza", "PADOVA"): "unipd-lmg-01-giurisprudenza-1631413",
    # …/assistenza-sanitaria-…-assistente-0 (Treviso) e …-assistente-sanitario (Bolzano)
    ("assistenza sanitaria abilitante alla professione sanitaria di assistente sanitario", "TREVISO"):
        "unipd-l-snt4-assistenza-sanitaria-abilitante-alla-professione-sanitaria-d",
    ("assistenza sanitaria abilitante alla professione sanitaria di assistente sanitario", "BOLZANO"):
        "unipd-l-snt4-assistenza-sanitaria-abilitante-alla-professione-sanitaria-d-1631320",
}
TIPI = {"L": "L", "LM": "LM", "LM5": "LMCU", "LM6": "LMCU"}


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unipd_cc" if d else None
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


def _corsi_db() -> list[dict]:
    p = ROOT / "database" / "corsi" / "unipd.json"
    return json.loads(p.read_text(encoding="utf-8"))["corsi"] if p.exists() else []


def associa(corsi: list[dict], db: list[dict], log=print) -> int:
    """Scrive in ogni corso del contributo l'`id` del corso del database (stessa sede)."""
    gruppi: dict[tuple[str, str], list[dict]] = {}
    for c in db:
        base = re.sub(r"(?i)\s+replica\b.*", "", c["nome"])
        gruppi.setdefault((_norm(base), c.get("tipo")), []).append(c)
    usati, n = set(), 0
    for cc in corsi:
        nome, sede = _norm(cc["nome"]), (cc.get("sede_catalogo") or "").upper()
        cid = SEDI_SPECIALI.get((nome, sede))
        if not cid:
            tipo = TIPI.get(cc.get("tipo_catalogo") or "", "")
            cand = [c for t in ([tipo, "LP"] if tipo == "L" else [tipo])  # lauree professionalizzanti: L nel catalogo
                    for c in gruppi.get((nome, t), []) if c["id"] not in usati]
            if len(cand) > 1:
                citta = [c for c in cand if re.search(r"(?i)\breplica\b", c["nome"])
                         and _norm(sede).split()[0] in _norm(c["nome"].split("REPLICA", 1)[-1]).split()]
                cand = citta or [c for c in cand if not re.search(r"(?i)\breplica\b", c["nome"])]
            cid = cand[0]["id"] if len(cand) == 1 else None
        if cid and cid not in usati:
            cc["id"] = cid
            usati.add(cid)
            n += 1
        else:
            log(f"[unipd]   corso del catalogo non associato: {cc['nome']} ({sede})")
    return n


# --- riferimenti in forma libera che l'estrazione comune (testi.estrai_libri) non riconosce:
# «J.D. Klafter "Robotic Engineering: An Integrated Approach" Mc-Graw Hill», «K. Marx, Il Capitale,
# Libro I», «Bandalos, D. L. (2018). Measurement theory…». Si prende una riga solo se comincia
# (o finisce) con un autore e ha un altro segno di citazione; il testo resta com'è.
_NOME = r"[A-ZÀ-Ý][a-zà-ÿ'’\-]+"
_INIZ = r"(?:[A-Z]\.\s?-?){1,3}"
_AUTORE_INIZIO = re.compile(
    rf"^(?:{_INIZ}\s?{_NOME}|{_NOME},\s?{_INIZ}|{_NOME}(?:\s{_NOME})?\s?[,:]|{_NOME}\s{_INIZ}[,\s])")
_AUTORE_FINE = re.compile(rf",\s?(?:{_INIZ}\s?{_NOME}|{_NOME}\s{_NOME})\.?$")
_SEGNO = re.compile(r"\b(1[89]\d\d|20[0-4]\d)\b|[“\"«]|\b(ed\.|edizione|edition|editore|editrice|edizioni|press|"
                    r"hill|verlag|vol\.|capitol|chapter|pp\.)", re.I)
_NO = re.compile(r"moodle|slide|lucidi|dispens|appunti|materiale|materiali|fornit|docente|lezion|articol|"
                 r"\bsito\b|http|www\.|nessun|verrann|sarann|indicat|disponibil|non sono|non ci sono|review|"
                 r"paper|piattaforma|video|\bpdf\b|e-?learning|notes|handouts|will be|provided|lecture", re.I)
_ETICHETTA = re.compile(r"(?i)^(note|editore|publisher|organizzazione|pagine|pages|autori|authors?|title|titolo|isbn|"
                        r"introduzione|capitol|chapter|paragraf)\b")
_PROSA = re.compile(r"(?i)^(il|lo|la|i|gli|le|per|parte|sulla|oltre|durante|tutti|tutto|si|nella|nel|questo|"
                    r"questa|the|this|all|students|gli studenti|in|ogni|ulteriori)\b")
_MINUSCOLE = {"and", "et", "al", "van", "der", "von", "del", "della", "dos", "den", "eds", "cura"}


def libri_liberi(sy: dict) -> list[dict]:
    from .testi import _libero, estrai_libri, html_to_lines

    testi, materiali = [], []
    for t in sy.get("testiTotali") or []:
        testi += [t.get(k) or "" for k in ("testi_it", "mod_testi_it")]
        # «Eventuali indicazioni sui materiali di studio»: a volte i testi sono qui
        materiali += [a.get("altri_testi_it") or "" for a in cineca_catalogue._lista(t.get("altri_testi"))
                      if "materiali di studio" in (a.get("etichetta_it") or "").lower()]
    # in questo campo c'è soprattutto prosa («Il docente fornirà dispense…»): solo citazioni vere
    libri = [lb for lb in estrai_libri(*materiali)
             if not _NO.search(lb["citazione"]) and not _PROSA.match(lb["citazione"])]
    if libri:
        return libri
    testi += materiali
    viste = set()
    for line in (x for t in testi for x in html_to_lines(t)):
        line = re.sub(r"^\s*(?:\d{1,2}[.)]|[a-z]\))\s*", "", line).strip()
        if not (15 <= len(line) <= 400) or _NO.search(line) or _ETICHETTA.match(line) or _PROSA.match(line):
            continue
        # solo nomi («Pierno, M.; Bazzan, M.»): manca il titolo
        if not any(len(w) >= 3 and w not in _MINUSCOLE for w in re.findall(r"\b[a-zà-ÿ]+\b", line)):
            continue
        autore = _AUTORE_INIZIO.search(line)
        if not ((autore and (_SEGNO.search(line) or len(line[autore.end():].split()) >= 3))
                or (_AUTORE_FINE.search(line) and len(line.split()) >= 5)):
            continue
        k = re.sub(r"\W+", "", line.lower())[:120]
        if k not in viste:
            viste.add(k)
            libri.append(_libero(line))
    return libri


def fetch_ateneo(uid: str = "unipd", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                        client=ClientCache(BASE), coorte_per_nome=True, libri_extra=libri_liberi)
    # il campo `sede` del contributo è il comune; per associare il corso serve la sede del
    # catalogo (es. «PADOVA 2»)
    elenco: list[dict] = []
    cineca_catalogue._walk_cds(ClientCache(BASE).get("/corsi", {"anno": anno, "minimal": "true"}) or [], elenco)
    sedi = {x["cdsCod"]: x.get("sede_des_it") for x in elenco if str(x.get("aa")) == str(anno)}
    for cc in doc["corsi"]:
        cc["sede_catalogo"] = sedi.get(cc.get("codice_ateneo")) or cc.get("sede")
    n = associa(doc["corsi"], _corsi_db(), log)
    log(f"[{uid}] corsi associati al database: {n}/{len(doc['corsi'])}")
    return doc
