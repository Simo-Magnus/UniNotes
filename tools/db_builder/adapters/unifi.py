"""Università di Firenze: Course Catalogue Cineca con le correzioni che servono a UniFI.

- Molti corsi hanno cambiato codice con il nuovo ordinamento (es. Matematica: B036 nella
  coorte 2024, B327 dalla 2025): il piano del 2° e 3° anno si cerca nella coorte giusta per
  nome, sede e tipo (`coorte_per_nome`), non nel piano futuro della coorte che si iscrive ora
  (i cui insegnamenti avrebbero il syllabus del 2027/28, ancora inesistente).
- I testi dei syllabus sono spesso in forma libera: si usa l'estrazione propria di UniFI
  (`unifi_testi.libri_unifi`) e, in mancanza, quella di UniPD (`unipd.libri_liberi`).
- «Sostenimento / Superamento Verifica Conoscenze in Ingresso» (codici OFA…, 0 CFU): sono la prova di
  ingresso, non insegnamenti; il requisito sta già in `ammissione` (test e OFA del corso). Non si portano nel piano.
- Insegnamenti integrati: il catalogo elenca il contenitore a 0 CFU (es. «Analisi dei medicinali I») e,
  accanto, i suoi moduli con i CFU (`adFiglie`; nel piano ci sono i moduli offerti, non sempre tutti). Il contenitore non ha CFU, docenti né programma propri
  (gli appelli del contenitore sono gli stessi dei moduli): si toglie, i CFU restano nei moduli, così l'anno
  non conta i CFU due volte e non ha un insegnamento a 0 CFU.
- Lo stesso insegnamento offerto con più pesi in CFU (Storia dell'arte contemporanea da 6 e da 12 CFU,
  Tirocinio da 3, 6, 9 e 12 CFU) ha un codice per ogni peso: nello stesso anno il nome porta i CFU
  («Tirocinio (6 CFU)») invece di sembrare un doppione.
- Il catalogo non elenca i crediti «a scelta dello studente» né le altre attività senza esame: i piani di molti corsi
  restano sotto i CFU del titolo (es. 168 su 180). Non si inventano: gli anni coinvolti sono nei verificati.

Con la variabile d'ambiente UN_HTTP_CACHE le risposte del catalogo restano su disco.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import unicodedata

from . import cineca_catalogue, unifi_testi, unipd

BASE = "https://unifi.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def associa(corsi: list[dict], log=print) -> int:
    """Scrive in ogni corso del catalogo l'`id` del corso del database con lo stesso nome (e, se ce ne
    sono più d'uno, la stessa durata: Architettura LM-4 di 2 anni e LM-4 c.u. di 5, che la sola classe
    non distingue). Serve anche perché «Medicine and Surgery» è il nome inglese di «Medicina e
    chirurgia»: senza `id` il suo piano finirebbe nel corso italiano."""
    p = ROOT / "database" / "corsi" / "unifi.json"
    if not p.exists():
        return 0
    db = json.loads(p.read_text(encoding="utf-8"))["corsi"]
    n = 0
    for cc in corsi:
        cand = [c for c in db if c.get("id_universitaly") and _norm(c["nome"]) == _norm(cc["nome"])]
        if len(cand) > 1:
            cand = [c for c in cand if c.get("durata_anni") == cc.get("durata_anni")]
        if len(cand) == 1:
            cc["id"] = cand[0]["id"]
            n += 1
        else:
            log(f"[unifi]   corso del catalogo non associato: {cc['nome']} ({cc.get('classe')})")
    return n


# codice dell'insegnamento integrato → {codice del modulo: CFU}, dai piani letti (campo `adFiglie`)
FIGLIE: dict[str, dict[str, float]] = {}
_VERIFICA_INGRESSO = re.compile(r"(?i)verifica\s+(?:delle\s+)?conoscenze\s+in\s+ingresso")


def _registra_figlie(piano) -> None:
    """Ricorda, per ogni insegnamento integrato del piano, i suoi moduli e i loro CFU."""
    if isinstance(piano, list):
        piano = piano[0] if piano else None
    for p in (piano or {}).get("percorsi") or []:
        for a in p.get("anni") or []:
            for g in a.get("insegnamenti") or []:
                for att in g.get("attivita") or []:
                    figlie = {f.get("adCod"): f.get("crediti") for f in att.get("adFiglie") or [] if f.get("adCod")}
                    if figlie and att.get("adCod"):
                        FIGLIE[att["adCod"]] = figlie


class ClientCache(cineca_catalogue.Client):
    def __init__(self, base: str, rate: float = 6.0):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unifi_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, params: dict | None = None):
        r = self._get(path, params)
        if path.startswith("/corso/"):
            _registra_figlie(r)
        return r

    def _get(self, path: str, params: dict | None = None):
        if not self.dir:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        f = self.dir / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = super().get(path, params)
        if r is None and path == "/insegnamento" and params and params.get("af_percorso"):
            # lo stesso insegnamento è in più percorsi e il syllabus può stare sotto un altro percorso:
            # senza `af_percorso` il catalogo lo trova comunque
            r = super().get(path, {k: v for k, v in params.items() if k != "af_percorso"})
        if r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


# frasi che spiegano come studiare («Gli studenti frequentanti sosterranno l'esame sul testo …»):
# non sono la citazione di un libro; il libro, se c'è, lo estrae libri_extra dal testo spezzato
_PROSA_INIZIO = re.compile(r"(?i)^(?:gli|le)\s+student|^student[ie]\b|^(?:il|la|lo)\s+(?:corso|docente|candidat|materiale)|"
                           r"^(?:l'|l’)esame|^(?:il|lo)\s+student|^per (?:gli|le|i)\s+(?:student|frequentant|non)")
_testi_originale = cineca_catalogue._testi_syllabus


def _testi_syllabus(sy: dict):
    libri, modalita, legati = _testi_originale(sy)
    return [b for b in libri if not _PROSA_INIZIO.match(b.get("citazione") or "")], modalita, legati


def libri_extra(sy: dict) -> list[dict]:
    return unifi_testi.libri_unifi(sy) or unipd.libri_liberi(sy)


def _nome_chiave(s: str) -> str:
    return re.sub(r"\W+", " ", (s or "").lower()).strip()


def correggi_piano(corso: dict) -> dict:
    """Toglie la prova d'ingresso a 0 CFU e i contenitori degli integrati; distingue per CFU gli
    insegnamenti omonimi dello stesso anno (vedi la descrizione del modulo)."""
    ins = corso.get("insegnamenti") or []
    codici = {i.get("codice") for i in ins}
    tenuti = []
    for i in ins:
        if not i.get("cfu"):
            if _VERIFICA_INGRESSO.search(i.get("nome") or ""):
                continue
            moduli = FIGLIE.get(i.get("codice"))
            if moduli and any(m in codici for m in moduli):
                continue
        tenuti.append(i)
    gruppi: dict[tuple, list[dict]] = {}
    for i in tenuti:
        gruppi.setdefault((i.get("anno"), _nome_chiave(i.get("nome")), i.get("curriculum")), []).append(i)
    for g in gruppi.values():
        if len({x.get("codice") for x in g}) > 1 and len({x.get("cfu") for x in g}) == len(g):
            for x in g:
                if isinstance(x.get("cfu"), (int, float)):
                    cfu = f"{x['cfu']:g}"
                    x["nome"] = f"{x['nome']} ({cfu} CFU)"
    corso["insegnamenti"] = tenuti
    return corso


def fetch_ateneo(uid: str = "unifi", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    cineca_catalogue._testi_syllabus = _testi_syllabus
    try:
        doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                            client=ClientCache(BASE), coorte_per_nome=True,
                                            libri_extra=libri_extra)
    finally:
        cineca_catalogue._testi_syllabus = _testi_originale
    doc["corsi"] = [correggi_piano(c) for c in doc["corsi"]]
    log(f"[{uid}] corsi con id del database: {associa(doc['corsi'], log)}")
    return doc
