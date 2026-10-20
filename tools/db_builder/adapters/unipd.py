"""Università di Padova: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unipd.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) il catalogo di UniPD richiede:

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo
  anno). Con il nuovo ordinamento molti corsi hanno cambiato codice (Ingegneria dell'energia: IN0515 → IN2917) e le
  coorti precedenti si ritrovano per codice (senza il suffisso «-25»), per nome, sede e tipo, o per nome e tipo se è
  l'unico. Se la coorte non ha quell'anno nel suo piano, si legge la più vicina che lo ha (a parità la più recente); se
  il piano 2026 non è ancora pubblicato (Osteopatia, Tecniche audiometriche, Terapia occupazionale) valgono le coorti
  precedenti. Una coorte con tutti gli insegnamenti tra i «Non obbligatori» (percorsi «Studenti iscritti…» della 2023 di
  Farmacia e Odontoiatria) mentre le due o più coorti seguenti li hanno obbligatori non vale: si prende la più vicina;
- durata dal piano («3 anni», «6 anni»): l'elenco minimale non ha `durataAnni`;
- gruppi del piano: il catalogo ne ha solo due, «OO» (Obbligatori) e «NO» (Non obbligatori: la scelta dello studente).
  Un'attività è obbligatoria solo se sta in «OO» (prima «Non obbligatori» conteneva «obbligator» e leggeva tutto come
  obbligatorio); la prova finale lo è sempre. Il catalogo la colloca al 1° anno in tutti i corsi (anche nelle lauree
  triennali e magistrali): è l'ultima attività del percorso e va nell'ultimo anno;
- attività a 0 CFU (obblighi formativi aggiuntivi, prove pratiche): non sono insegnamenti del piano; gli OFA vanno tra i
  requisiti di accesso. Se lo stesso codice ha CFU in un'altra coorte, si usano quelli;
- alternative omonime nello stesso anno con codici diversi: se sono tutte a scelta e hanno gli stessi CFU un solo
  insegnamento, altrimenti il nome porta i CFU, il semestre o il codice;
- ogni sede è un corso a sé nel catalogo, con docenti e syllabus propri (Medicina Padova 1-4 e Treviso, Infermieristica
  in 8 sedi, …): si associa al corso giusto del database (le «REPLICA <città>» di Universitaly) scrivendo il suo `id`
  nel contributo (`associa`, `SEDI_SPECIALI`).

Con la variabile d'ambiente UN_HTTP_CACHE le risposte del catalogo restano su disco. I libri già raccolti nel
contributo (per id del corso e codice dell'insegnamento) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/unipd.json`, conservando gli appelli):

    python tools/db_builder/adapters/unipd.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
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
from . import cineca_catalogue  # noqa: E402

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


# --- piani di studio -------------------------------------------------------------------------------------------------
# Il catalogo di UniPD ha due soli gruppi per anno: «OO» (Obbligatori) e «NO» (Non obbligatori, la scelta dello studente).
# Le attività a 0 CFU (obblighi formativi aggiuntivi, prove pratiche) non sono insegnamenti del piano.
_DEBITO = re.compile(r"(?i)\bdebito\b|obblig\w*\s+formativ|additional learning requirement|\bofa\b")
_FINALE = re.compile(r"(?i)^\s*(prova finale|final (?:exam|examination|project|dissertation|test)|master'?s thesis|thesis|tesi)\b")
_COMUNE = re.compile(r"(?i)\bcomune\b")

# Correzioni al catalogo dove il piano ufficiale dice altro: (cdsCod, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "cfu=<n>".
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}
# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (cdsCod, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}


def _nn(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _cod_base(cds: str | None) -> str:
    return re.sub(r"-\d{2}$", "", (cds or "").strip())


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L": 3, "LM": 2, "LM5": 5, "LM6": 6}.get(tipo or "", 3)


def _gruppi_di_anno(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _obbligatorio(g: dict, att: dict) -> bool:
    """«OO» sono gli obbligatori; la prova finale è obbligatoria anche dove il catalogo la mette tra i «Non obbligatori»."""
    return g.get("cod") == "OO" or bool(_FINALE.search(att.get("des_it") or ""))


def _cfu_anno(det: dict, k: int) -> float:
    """CFU elencati dall'anno k di un piano (percorso più ricco); -1 se l'anno non c'è."""
    best = -1.0
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                continue
            visti, tot = set(), 0.0
            for g in _gruppi_di_anno(a):
                for x in g.get("attivita") or []:
                    ad = x.get("adCod") or x.get("cod")
                    if ad not in visti:
                        visti.add(ad)
                        tot += float(x.get("crediti") or 0)
            best = max(best, tot)
    return best


def _obb_anno(det: dict, k: int) -> float:
    """CFU del gruppo «Obbligatori» dell'anno k (percorso più ricco); -1 se l'anno non c'è."""
    best = -1.0
    for p in det.get("percorsi") or []:
        for a in p.get("anni") or []:
            if str(a.get("anno")).isdigit() and int(a["anno"]) == k:
                best = max(best, sum(float(x.get("crediti") or 0) for g in _gruppi_di_anno(a) if g.get("cod") == "OO"
                                     for x in g.get("attivita") or []))
    return best


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", " ", nome)
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo|piano)\b", " ", n)
    return _nn(n)


def _nome_percorso(nome: str) -> str:
    n = re.sub(r"(?i)[\s,-]*\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", "", nome)
    return re.sub(r"\s+", " ", n).strip(" -:,")


def _libri_database() -> dict[tuple[str, str], dict]:
    """Libri, modalità d'esame, SSD e sito già raccolti per (id del corso, codice dell'insegnamento): nessuna nuova richiesta."""
    p = ROOT / "database" / "contrib" / "auto" / "unipd.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[tuple[str, str], dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            if corso.get("id") and i.get("codice") and i.get("libri"):
                out.setdefault((corso["id"], i["codice"]), {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")})
    return out


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 5, anno + 1):
        cds: list[dict] = []
        cineca_catalogue._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur` (il codice cambia con i riordini)."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        for x in elenco:
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]):
                return x
        chiave = (_nn(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_nn(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        if len(stessi) == 1:
            return stessi[0]
        stessi = [x for x in elenco if (_nn(x.get("des_it")), x.get("tipo_corso_cod")) == chiave[::2]]
        return stessi[0] if len(stessi) == 1 else None

    def con_piano(cur: dict) -> bool:
        """Il corso ha un piano in almeno una coorte (la 2026 può non essere ancora pubblicata)."""
        for y in range(anno, anno - 6, -1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d and any(g.get("attivita") for p in d.get("percorsi") or [] for a in p.get("anni") or []
                         for g in _gruppi_di_anno(a)):
                return True
        return False

    attuali = [x for x in attuali if con_piano(x)]
    log(f"[{uid}] di cui con un piano: {len(attuali)}")

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 5, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")

        # nome canonico dei percorsi: quello della coorte più recente che li ha
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple[str, str, str]] = []
        for y in sorted(cohorts, reverse=True):
            ps = cohorts[y][1].get("percorsi") or []
            cods = [p.get("pdsCod") or "" for p in ps]
            visti = list(riferimento)
            nuovi = []
            for p in ps:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                ch = _chiave_percorso(pn)
                cod = (p.get("pdsCod") or "").strip()
                trovato = next((r for r in visti if r[0] == ch), None)
                if not trovato and cod and cods.count(cod) == 1:
                    cand = [r for r in visti if r[1] == cod and cod not in ("PDS0", "GEN", "COMUNE", "000ZZ")]
                    trovato = cand[0] if len(cand) == 1 else None
                if not trovato:
                    simili = difflib.get_close_matches(ch, [r[0] for r in visti], n=1, cutoff=0.85)
                    trovato = next((r for r in visti if r[0] == simili[0]), None) if simili else None
                if not trovato:
                    trovato = (ch, cod, _nome_percorso(pn))
                    nuovi.append(trovato)
                canon[(y, pn)] = trovato[2]
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((cur.get("cdsCod"), k))
            if forzata in cohorts:
                return forzata
            ha = {y: _cfu_anno(d, k) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v > 0}
            if not ha:
                return None
            if y0 in ha:
                # coorte con tutti gli insegnamenti tra i «Non obbligatori» (percorsi «Studenti iscritti…»: la 2023 di
                # Farmacia e Odontoiatria) mentre le due o più coorti seguenti li hanno obbligatori: vale la più vicina
                dopo = [y for y in ha if y > y0 and _obb_anno(cohorts[y][1], k) > 0]
                if _obb_anno(cohorts[y0][1], k) == 0 and len(dopo) >= 2:
                    return min(dopo)
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        # CFU di un'attività con 0 CFU in un piano e CFU nell'altro
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        debiti: list[str] = []
        piano_anni: dict[str, dict] = {}
        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}"}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(str(a.get("anno")).isdigit() and int(a["anno"]) == k for a in p.get("anni") or [])]
            percorsi_k = cineca_catalogue._percorsi_sede(percorsi_k, cur)
            nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi_k}
            anni_p = {n: max(int(a["anno"]) for a in p.get("anni") or [] if str(a.get("anno")).isdigit())
                      for n, p in nomi_k.items()}
            # percorsi comuni: «… comune» o un piano che copre solo i primi anni quando gli altri percorsi li coprono tutti
            comuni = {n for n in nomi_k if _COMUNE.search(n) or (len(nomi_k) > 1 and anni_p[n] < max(anni_p.values()))}
            specifici = [n for n in nomi_k if n not in comuni]
            curricula = {canon[(scelta, n)] for n in specifici} if len(specifici) >= 2 else set()
            for pnome, p in nomi_k.items():
                comune = pnome in comuni or not curricula
                pcur = None if comune else canon[(scelta, pnome)]
                for a in p.get("anni") or []:
                    if not (str(a.get("anno")).isdigit() and int(a["anno"]) == k):
                        continue
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            ad = att.get("adCod") or att.get("cod")
                            cfu_att = att.get("crediti") or cfu_noti.get(ad)
                            if not cfu_att:
                                if _DEBITO.search(att.get("des_it") or ""):
                                    nome_d = re.sub(r"(?i)^\s*(?:obbligo formativo aggiuntivo|debito)[:\s-]*", "",
                                                    cineca_catalogue._titolo(att["des_it"])).strip()
                                    debiti.append(nome_d or cineca_catalogue._titolo(att["des_it"]))
                                continue  # a 0 CFU: non è un insegnamento del piano
                            obbl = _obbligatorio(g, att)
                            key = f"{k}:{ad}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cineca_catalogue._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": cineca_catalogue._titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": cineca_catalogue._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": cfu_att, "ssd": None,
                                    "obbligatorio": bool(obbl), "curriculum": None, "_percorsi": set(), "_tutti": curricula,
                                    "docenti": sorted(set(docenti)),
                                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                    "_job": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                             "ordinamento_aa": att.get("ordinamento_aa"),
                                             "af_percorso": att.get("corso_percorso_id"),
                                             "corso_cod": att.get("corso_cod"), "corso_aa": scelta,
                                             "schema_id": att.get("schemaId")},
                                }
                                insegnamenti[key] = item
                            elif obbl:
                                item["obbligatorio"] = True
                            if comune:
                                item["_comune"] = True
                            elif pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
        # il catalogo colloca la prova finale al 1° anno (tutti i corsi: 114 lauree, 119 magistrali): è l'ultima attività
        # del percorso, i suoi CFU vanno nell'ultimo anno
        for key, item in list(insegnamenti.items()):
            if item["anno"] < durata and _FINALE.search(item["nome"]):
                nuova = f"{durata}:{item['codice']}"
                if nuova in insegnamenti:
                    del insegnamenti[key]
                    continue
                del insegnamenti[key]
                item["anno"] = durata
                insegnamenti[nuova] = item
        for (cds_c, anno_c), regole in CORREZIONI.items():
            if cds_c != cur.get("cdsCod"):
                continue
            for key, item in list(insegnamenti.items()):
                regola = regole.get(item.get("codice") or item["nome"]) if item["anno"] == anno_c else None
                if regola == "escludi":
                    del insegnamenti[key]
                elif regola == "scelta":
                    item["obbligatorio"] = False
                elif regola and regola.startswith("cfu="):
                    item["cfu"] = int(regola[4:])
        ins = list(insegnamenti.values())
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if i.pop("_comune", False):
                ps = set()
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        # stesso nome nello stesso anno con codici e CFU diversi (alternative omonime): il nome porta i CFU
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        # stesso nome, anno e curriculum con codici diversi e gli stessi CFU: se sono tutti a scelta è lo stesso insegnamento
        # con due codici (si unisce); altrimenti restano distinti e il nome porta il semestre o il codice
        per_nome2: dict[tuple, list] = {}
        for i in ins:
            per_nome2.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome2.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if all(not i["obbligatorio"] for i in gruppo_i) and len({i["cfu"] for i in gruppo_i}) == 1:
                tieni = min(gruppo_i, key=lambda i: str(i["codice"]))
                for altro in gruppo_i:
                    if altro is tieni:
                        continue
                    tieni["docenti"] = sorted(set(tieni["docenti"]) | set(altro["docenti"]))
                    tieni["periodo"] = tieni["periodo"] or altro["periodo"]
                    ins.remove(altro)
                continue
            periodi = [i["periodo"] for i in gruppo_i]
            for i in gruppo_i:
                if all(periodi) and len(set(periodi)) == len(periodi):
                    p = str(i["periodo"])
                    i["nome"] = f"{i['nome']} ({p}° semestre)" if p in ("1", "2") else f"{i['nome']} ({p})"
                else:
                    i["nome"] = f"{i['nome']} ({i['codice']})"
        if amm is not None and debiti:
            nomi = [t for t in dict.fromkeys(debiti) if t]
            frase = "Debiti formativi (OFA) previsti dal piano di studi" + (": " + ", ".join(nomi) if nomi else "")
            if frase.lower() not in (amm.get("requisiti") or "").lower():
                amm["requisiti"] = ((amm.get("requisiti") or "").rstrip() + "\n" + frase + ".").strip()
            if amm.get("ofa") is None:
                amm["ofa"] = True
        return {
            "nome": cineca_catalogue._titolo(cur.get("des_it") or ""),
            "classe": cineca_catalogue._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "sede_catalogo": cur.get("sede_des_it"),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
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
    n = associa(corsi_out, _corsi_db(), log)
    log(f"[{uid}] corsi associati al database: {n}/{len(corsi_out)}")

    # libri: quelli già raccolti per lo stesso insegnamento dello stesso corso non si rileggono
    libri_noti = libri_noti or {}
    for corso in corsi_out:
        for i in corso["insegnamenti"]:
            noto = libri_noti.get((corso.get("id"), i["codice"]))
            if noto and noto.get("libri"):
                i["libri"] = noto["libri"]
                i["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        i[k_] = noto[k_]
                i.pop("_job", None)
            elif syllabus:
                job = i["_job"]
                syllabus_jobs.setdefault((str(job["anno"]), str(job["insegnamento"]), str(job["corso_cod"])), {
                    "params": job, "items": []})["items"].append(i)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, legati = cineca_catalogue._testi_syllabus(sy)
        if not libri:
            libri = libri_liberi(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cineca_catalogue.leganto.libri(u)
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
            if i % 500 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    for corso in corsi_out:
        for i in corso["insegnamenti"]:
            i.pop("_job", None)
            i.setdefault("stato_libri", "completo" if i["libri"] else "da_aggiungere")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/unipd.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def fetch_ateneo(uid: str = "unipd", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unipd.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unipd] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
