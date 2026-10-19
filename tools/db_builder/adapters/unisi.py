"""Università degli Studi di Siena: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://unisi.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) il catalogo di Siena richiede:

- piano non diviso per anno: nella maggior parte dei corsi (lauree magistrali, professioni sanitarie,
  coorti 2024-2026) le attività stanno sotto «altreAttivita» e l'adattatore comune le lasciava senza anno
  (anni interi vuoti). L'anno di corso di ogni attività si ricava, nell'ordine, da:
  1. l'anno in cui la stessa attività sta in una sezione già divisa per anno dello stesso corso (coorte
     più recente che la divide: il piano delle coorti 2021-2023 delle professioni sanitarie, per esempio,
     ha «1° anno», «2° anno», «3° anno»);
  2. la data di inizio del periodo didattico: nell'ordinamento che inizia con la coorte, l'attività che
     inizia nell'a.a. A è del corso A - coorte + 1 (coorte 2025, «28/09/2026» → 2° anno). Nei piani
     condivisi da più coorti (ordinamento iniziato prima: l'offerta elenca anche gli a.a. delle coorti
     precedenti) l'attività è del corso (primo a.a. in cui compare) - (coorte più vecchia) + 1, oppure
     è il numero di a.a. in cui compare, se parte dalla coorte;
  3. il nome («TIROCINIO … SECONDO ANNO»); la prova finale è dell'ultimo anno.
  Le attività di cui non si ricava l'anno restano senza anno, come prima;
- durata dei corsi dal piano («3 anni»): l'elenco minimale non ha `durataAnni` e senza di essa si userebbe
  sempre 3 anni;
- coorti per nome: il codice cambia con il nuovo ordinamento (Scienze politiche: PE002 fino alla coorte
  2024, D622 dal 2025), quindi per l'anno di corso k si cerca il corso con lo stesso nome, sede e tipo
  nella coorte 2026 - k + 1; `ALIAS_NOMI` collega i corsi che hanno cambiato anche nome.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unisi.json` mantenendo appelli e canali già presenti):

    python tools/db_builder/adapters/unisi.py [--senza-syllabus]
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import pathlib
import re
import sys
import time
from collections import defaultdict

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import cineca_catalogue  # noqa: E402

BASE = "https://unisi.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0

# nome nelle coorti precedenti (normalizzato) -> nome attuale: corsi che hanno cambiato nome col nuovo ordinamento
ALIAS_NOMI = {
    "servizi giuridici": "scienze dei servizi giuridici",
    "finance finanza": "finance",
    "applied mathematics matematica applicata": "applied mathematics",
}

ORDINALI = {"PRIMO": 1, "SECONDO": 2, "TERZO": 3, "QUARTO": 4, "QUINTO": 5, "SESTO": 6,
            "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
_ANNO_NOME = re.compile(r"\b(PRIMO|SECONDO|TERZO|QUARTO|QUINTO|SESTO|VI|IV|V|III|II|I|[1-6]\s*°?)\s*(?:°\s*)?ANNO\b",
                        re.I)


def _norm(s: str | None) -> str:
    n = re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()
    return ALIAS_NOMI.get(n, n)


def _chiave(d: dict) -> tuple:
    """Corso (nome normalizzato, tipo): le attività dello stesso corso hanno lo stesso anno in ogni coorte."""
    return _norm(d.get("des_it")), d.get("tipo_corso_cod")


def _un(d):
    return d[0] if isinstance(d, list) and d else d


class ClientCache(cineca_catalogue.Client):
    """Client con cache su disco e piano normalizzato (anno di corso e durata)."""

    def __init__(self, base: str = BASE, rate: float = RATE, anno: int = 2026):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.dir = pathlib.Path(d) / "unisi_cc" if d else None
        if self.dir:
            self.dir.mkdir(parents=True, exist_ok=True)
        self.anno = anno
        self._mem: dict = {}
        self._canon: dict | None = None

    def _grezzo(self, path: str, params: dict | None = None):
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True, default=str)).encode()).hexdigest()
        if key in self._mem:
            return copy.deepcopy(self._mem[key])
        f = self.dir / f"{key}.json" if self.dir else None
        if f and f.exists():
            r = json.loads(f.read_text(encoding="utf-8"))
        else:
            r = super().get(path, params)
            if r is not None and f:
                f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        if path.startswith("/corso/") or path == "/corsi":
            self._mem[key] = r
            return copy.deepcopy(r)
        return r

    def canonico(self) -> dict:
        """{(corso, codice attività): anni} dalle sezioni già divise per anno, della coorte più recente che
        ha l'attività in una sezione per anno."""
        if self._canon is None:
            canon: dict = {}
            for y in range(self.anno - 7, self.anno + 1):
                cds: list[dict] = []
                cineca_catalogue._walk_cds(self._grezzo("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
                for x in cds:
                    if str(x.get("aa")) != str(y):
                        continue
                    d = _un(self._grezzo(f"/corso/{y}/{x['cod']}"))
                    if not isinstance(d, dict):
                        continue
                    k = _chiave(x)
                    for p in d.get("percorsi") or []:
                        for a in p.get("anni") or []:
                            if not str(a.get("anno")).isdigit():
                                continue
                            for g in _gruppi(a):
                                for att in g.get("attivita") or []:
                                    chiave = (k, att.get("adCod") or att.get("cod"))
                                    rec = canon.get(chiave)
                                    if rec is None or rec[0] < y:
                                        canon[chiave] = (y, {int(a["anno"])})
                                    elif rec[0] == y:
                                        rec[1].add(int(a["anno"]))
            self._canon = {k: sorted(v[1]) for k, v in canon.items()}
        return self._canon

    def get(self, path: str, params: dict | None = None):
        r = self._grezzo(path, params)
        if r is None:
            return None
        if path == "/corsi":
            anno = int((params or {}).get("anno") or 0)
            cds: list[dict] = []
            cineca_catalogue._walk_cds(r, cds)
            for x in cds:
                if not x.get("durataAnni") and anno:
                    x["durataAnni"] = _durata(self._grezzo(f"/corso/{anno}/{x['cod']}"))
                n = re.sub(r"[^a-z0-9]+", " ", (x.get("des_it") or "").lower()).strip()
                if n in ALIAS_NOMI and str(x.get("aa")) != str(self.anno):
                    x["des_it"] = ALIAS_NOMI[n].upper()
        elif re.fullmatch(r"/corso/\d+/\w+", path):
            d = _un(r)
            if isinstance(d, dict):
                r = _normalizza(d, int(path.split("/")[2]), self.anno, self.canonico())
        return r


def _durata(d) -> int | None:
    d = _un(d)
    m = re.match(r"\s*(\d+)", (d or {}).get("durata_it") or "")
    return int(m.group(1)) if m else None


def _aa(s: str | None) -> int | None:
    """Anno accademico (anno di inizio) di una data «gg/mm/aaaa …»: da settembre in poi è quello dell'anno."""
    m = re.match(r"\s*(\d{1,2})/(\d{1,2})/(\d{4})", s or "")
    if not m:
        return None
    mese, anno = int(m.group(2)), int(m.group(3))
    return anno if mese >= 9 else anno - 1


def _anno_da_nome(att: dict, durata: int) -> int | None:
    nome = (att.get("des_it") or "").upper()
    if re.match(r"\s*(PROVA FINALE|FINAL EXAM(INATION)?|DISCUSSIONE (DELLA )?TESI)\b", nome):  # è dell'ultimo anno
        return durata
    m = _ANNO_NOME.search(nome)
    if m:
        t = re.sub(r"[^A-Z0-9]", "", m.group(1).upper())
        k = ORDINALI.get(t) or (int(t) if t.isdigit() else None)
        if k and 1 <= k <= durata:
            return k
    return None


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _anni_condiviso(S: list[int], y: int, ordinamento: int, anno: int, durata: int) -> list[int]:
    """Anno di corso di un'attività nel piano condiviso da più coorti (ordinamento iniziato prima della coorte
    `y`): gli a.a. in cui compare, S (da y in poi), sono quelli delle coorti dall'ordinamento a y."""
    kmax = anno - y + 1
    prima = max(ordinamento, y - durata + 1)
    if S[0] > y:  # la coorte più vecchia dell'ordinamento è l'unica che la segue già
        j = S[0] - prima + 1
    else:
        j = len(S) if len(S) < kmax else kmax
    return [j] if 1 <= j <= durata else []


_COMUNE = re.compile(r"\s*(percorso|corso|perco+so)\s+(comune|generico)", re.I)


def _unisci_comuni(d: dict) -> None:
    """Il percorso «CORSO GENERICO» / «PERCORSO COMUNE» di un piano con altri percorsi (sedi, curricula) ha le
    attività comuni a tutti (prova finale, lingua…): si aggiungono a ciascun percorso, altrimenti
    resterebbero in un percorso a sé, fuori dal conteggio dei CFU di ogni sede."""
    percorsi = d.get("percorsi") or []
    comuni = [p for p in percorsi if _COMUNE.match(p.get("des_it") or p.get("pdsDes") or "")]
    altri = [p for p in percorsi if p not in comuni]
    if comuni and altri:
        for q in altri:
            for c in comuni:
                q["anni"] = (q.get("anni") or []) + copy.deepcopy(c.get("anni") or [])
        d["percorsi"] = altri


def _normalizza(d: dict, coorte: int, anno: int, canon: dict) -> dict:
    """Piano della coorte con le attività di «altreAttivita» spostate nell'anno di corso che si ricava."""
    durata = _durata(d) or 3
    try:
        ordinamento = int(d.get("ordinamento_aa") or coorte)
    except (TypeError, ValueError):
        ordinamento = coorte
    nuovo = ordinamento >= coorte  # l'ordinamento inizia con questa coorte: l'offerta è solo la sua
    chiave = _chiave(d)
    _unisci_comuni(d)
    for p in d.get("percorsi") or []:
        anni = p.get("anni") or []
        con_anno = {(int(a["anno"]), att.get("adCod") or att.get("cod"))
                    for a in anni if str(a.get("anno")).isdigit()
                    for g in _gruppi(a) for att in g.get("attivita") or []}
        voci: dict[str, list] = {}
        for a in anni:
            if not str(a.get("anno")).isdigit():
                for g in _gruppi(a):
                    for att in g.get("attivita") or []:
                        voci.setdefault(att.get("adCod") or att.get("cod"), []).append((att, g))
        nuovi: dict[int, dict] = defaultdict(dict)
        restano: dict[tuple, dict] = {}

        def metti(j: int, att: dict, g: dict):
            gk = (g.get("cod"), g.get("label_it"))
            nuovi[j].setdefault(gk, {**{x: v for x, v in g.items() if x != "attivita"}, "attivita": []})
            nuovi[j][gk]["attivita"].append(att)

        for ad, lista in voci.items():
            date = [(_aa(att.get("data_inizio_periodo_didattico")), att, g) for att, g in lista]
            S = sorted({aa for aa, _, _ in date if aa is not None and aa >= coorte})
            con_date = any(aa is not None for aa, _, _ in date)
            piazzate: list[tuple[int, dict, dict]] = []
            if con_date and not S:
                continue  # offerta di a.a. precedenti alla coorte: non è del suo piano
            canonici = canon.get((chiave, ad))
            if nuovo and S:  # ogni a.a. in cui è erogata è un anno di corso della coorte
                for aa, att, g in date:
                    if aa is not None and aa >= coorte and 1 <= aa - coorte + 1 <= durata:
                        piazzate.append((aa - coorte + 1, att, g))
            elif canonici:
                for j in canonici:
                    if 1 <= j <= durata and (j, ad) not in con_anno:
                        offerta = [(aa, att, g) for aa, att, g in date if aa == coorte + j - 1]
                        piazzate.append((j, *(offerta[0][1:] if offerta else date[-1][1:])))
            elif S:
                for j in _anni_condiviso(S, coorte, ordinamento, anno, durata):
                    offerta = [(aa, att, g) for aa, att, g in date if aa == coorte + j - 1] or [date[-1]]
                    piazzate.append((j, *offerta[0][1:]))
            if not piazzate and not con_date:
                j = _anno_da_nome(lista[0][0], durata)
                if j:
                    piazzate.append((j, *lista[0]))
            if not piazzate:
                if not con_date:
                    for att, g in lista[:1]:
                        gk = (g.get("cod"), g.get("label_it"))
                        restano.setdefault(gk, {**{x: v for x, v in g.items() if x != "attivita"}, "attivita": []})
                        restano[gk]["attivita"].append(att)
                continue
            for j, att, g in piazzate:
                if (j, ad) not in con_anno:
                    metti(j, att, g)
        sezioni = [a for a in anni if str(a.get("anno")).isdigit()]
        for j in sorted(nuovi):
            sezioni.append({"anno": j, "annoOfferta": j, "insegnamenti": list(nuovi[j].values())})
        if restano:
            sezioni.append({"anno": "altreAttivita", "annoOfferta": "altreAttivita",
                            "insegnamenti": list(restano.values())})
        p["anni"] = sezioni
    return d


def fetch_ateneo(uid: str = "unisi", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print) -> dict:
    doc = cineca_catalogue.fetch_ateneo(uid, BASE, anno, max_cds=max_cds, syllabus=syllabus, log=log,
                                        client=ClientCache(anno=anno), coorte_per_nome=True)
    doc["descrizione"] = f"Generato da {BASE} (Course Catalogue Cineca, adapters/unisi.py)"
    return doc


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "unisi.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[unisi] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
