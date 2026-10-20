"""Insegnamenti di Humanitas University da www.hunimed.eu.

Ogni corso ha una pagina con lo "Study Plan" in schede per anno ("First", "Primo", "1st Year", …):
insegnamento, crediti, semestre e moduli con il loro SSD. Il sito non ha un piano per coorte: la
pagina mostra l'unico piano in vigore, perciò il piano è quello (i crediti dichiarati nelle righe
«Total»/«Totale» si confrontano con la somma delle righe e le differenze si scrivono nel log).

Pagine usate (quella più aggiornata del sito, scelta per ogni corso):
- Fisioterapia e Infermieristica (con le repliche di sede): pagina inglese `/course/<corso>/programme-structure/`
  (i nomi degli insegnamenti, e quindi gli id, sono quelli inglesi);
- Osteopatia: pagina italiana (quella inglese mostra ancora il piano vecchio, con gli SSD
  antecedenti al riordino e crediti diversi);
- Tecniche di laboratorio biomedico, Tecniche di radiologia (con la replica), Biotechnologies for Human
  Health, Data Analytics (DAIHS), Medicina e chirurgia e MedTec: pagina italiana del corso (le pagine
  inglesi dei corsi magistrali mostrano il piano di un altro corso);
- le due lauree magistrali in Scienze infermieristiche specialistiche condividono una pagina con una
  scheda per percorso (cure intensive; cure primarie): ognuna è un corso del database.

Particolarità del sito:
- il nome sta in grassetto e i moduli sotto (Medicina, Biotechnologies); in altre tabelle il nome è
  la cella intera;
- «Annual»/«Annuale» nella colonna del semestre; «1 e 2» nella colonna dell'anno (laurea magistrale
  in Scienze infermieristiche): attività distribuita su due anni senza dire quanti crediti per anno, si
  tiene una sola riga nel primo anno con l'indicazione «(anni 1 e 2)» nel nome, così il totale dei
  crediti del corso resta quello dichiarato dalla pagina;
- righe «Total», «Totale II anno», «Tot.» sono totali, non insegnamenti;
- le attività elettive / a scelta sono `obbligatorio: False`;
- «1 elective course out of: A B C» (DAIHS) è una scelta da 6 CFU: una riga con l'elenco nel nome;
- la pagina inglese di Infermieristica non elenca i 6 CFU di attività elettive richiesti per la
  prova finale (lo dice solo il testo): non sono una riga del piano e il totale resta 174 su 180.
Le pagine possono mostrare il piano di un altro corso (errore del sito): si scarta un piano che non
ha tutti gli anni del corso o in cui manca una voce tipica del corso (`chiave`).
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import time

from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
SITO = "https://www.hunimed.eu"
ANNI = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6,
        "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6}

# id Universitaly del corso -> pagina del piano. `radice`: pagina del corso (url del corso, se il
# piano sta altrove); `chiave`: espressione che deve comparire in un nome del piano.
PIANI = {
    "fisioterapia": {"pagina": "/course/physiotherapy/programme-structure/", "radice": "/course/physiotherapy/",
                     "chiave": r"human anatomy|biological sciences", "ul": ["1629041"]},
    "infermieristica": {"pagina": "/course/nursing/programme-structure/", "radice": "/course/nursing/",
                        "chiave": r"nursing", "ul": ["1629040", "1629060", "1629061", "1629062"]},
    "osteopatia": {"pagina": "/it/course/osteopatia/struttura-del-programma/", "radice": "/course/osteopathy/",
                   "chiave": r"osteopatic", "ul": ["1629043"]},
    "laboratorio": {"pagina": "/it/course/tecniche-di-laboratorio-biomedico/struttura-del-programma/",
                    "chiave": r"patologia clinica|biologia molecolare", "ul": ["1629042"]},
    "radiologia": {"pagina": "/it/course/tecniche-di-radiologia-medica-per-immagini-e-radioterapia/struttura-del-programma/",
                   "chiave": r"tecniche diagnostiche", "ul": ["1629048", "1629063"]},
    "biotecnologie": {"pagina": "/it/course/laurea-magistrale-biotechnologies-for-human-health/",
                      "chiave": r"general pathology|omics", "ul": ["1625721"]},
    "daihs": {"pagina": "/it/daihs-struttura-del-programma/", "chiave": r"machine learning|advanced statistics",
              "ul": ["1629045"]},
    "medtec": {"pagina": "/it/course/medtec/struttura-del-programma/", "chiave": r"experimental physics",
               "ul": ["1629046"], "sede": "Milano e Pieve Emanuele"},
    "medicina": {"pagina": "/it/course/medicina/struttura-del-programma/", "chiave": r"building bodies|living matter",
                 "ul": ["1629047"], "sede": "Pieve Emanuele"},
    # una scheda per percorso (nome della scheda -> corso)
    "scienze_infermieristiche": {"pagina": "/it/course/magistrale-scienze-infermieristiche-specialistiche/",
                                 "schede": {"1635613": r"intensiv", "1635660": r"primarie"},
                                 "chiave": r"tirocinio", "ul": ["1635613", "1635660"]},
}
# nel nome di Infermieristica (pagina italiana) le sedi in cui si tiene l'insegnamento
_SEDI = re.compile(r"\s+[–-]\s+(?:Pieve Emanuele|Bergamo|Castellanza|Catania)\b.*$")
_ELETTIVA = re.compile(r"(?i)\b(elettiv[eoi]|electives?|a scelta|elective courses?)\b|\belective course out of\b")
_TOTALE = re.compile(r"(?i)^\s*(totale?|total|tot\.?)(?![a-zà-ù])")
_SSD = re.compile(r"\b([A-Z]{2,5}-\d{2}/[A-Z])\b")


def _anno_scheda(titolo: str) -> int | None:
    t = re.sub(r"(?i)\b(year|anno)\b", "", titolo).strip().lower()
    return ANNI.get(t)


def _plain(s: str) -> str:
    """Testo di una cella senza spazi inventati tra i tag (`<strong>PROFESSIONALIZZANT</strong>I`)."""
    s = re.sub(r"<br\s*/?>", " ", s)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()


_PICCOLE = {"dello", "dei", "dalla", "dalle", "nei", "nelle", "negli", "sui", "sulle", "at"}


def _nome(s: str) -> str:
    s = re.sub(r"\s+", " ", html.unescape(s)).strip().rstrip(":").strip()
    s = _SEDI.sub("", s)
    s = re.sub(r"\s*\*+$", "", s)  # «Doctor-patient Communication *»
    # «PROFESSIONALISING ACTIVITIES 1st YEAR»: le sigle ordinali non fanno perdere il maiuscolo
    s = _titolo(re.sub(r"(?<=\d)(st|nd|rd|th)\b", lambda m: m.group(1).upper(), s))
    s = re.sub(r"(?<=\d)(ST|ND|RD|TH)\b", lambda m: m.group(1).lower(), s)
    # numeri romani e sigle che _titolo lascia in minuscolo o con l'iniziale maiuscola
    s = re.sub(r"\b(Ii|Iii|Iv)\b", lambda m: m.group(1).upper(), s)
    s = re.sub(r"(?<=\s)i$|(?<=\s)i(?=\s+Anno\b)", "I", s)  # «Tirocinio – i Anno», «Mechanism of Diseases i»
    s = re.sub(r"\bRte\b", "RTE", s)
    s = " ".join(w.lower() if k and w.lower() in _PICCOLE else w for k, w in enumerate(s.split(" ")))
    s = re.sub(r"(?<=\s)(Dell|Nell|Sull|Dall|All)([’'])(?=\w)", lambda m: m.group(1).lower() + m.group(2), s)
    return s


def _periodo(testo: str) -> str | None:
    t = testo.strip().lower()
    if t.startswith("annual"):
        return "annuale"
    return t if t in ("1", "2") else None  # «1 e 2», «1-2»: più semestri


def _righe(tabella: str, anno: int | None, pagina: str) -> tuple[list[dict], dict[int, float]]:
    """Righe di una tabella del piano. `anno`: anno della scheda (None se la tabella ha la colonna dell'anno).
    Restituisce (insegnamenti, totali dichiarati per anno)."""
    testa = [_testo(x).upper() for x in re.findall(r"<th[^>]*>(.*?)</th>", tabella, re.S)]
    col_sem = next((k for k, h in enumerate(testa) if h.startswith("SEMEST")), None)
    col_anno = next((k for k, h in enumerate(testa) if h == "ANNO"), None)
    col_cfu = next((k for k, h in enumerate(testa) if re.match(r"(CFU|CREDIT)", h)), 1)
    col_nome = next(k for k in range(len(testa) or 1) if k not in (col_sem, col_anno))
    out, totali = [], {}
    for r in re.findall(r"<tr[^>]*>(.*?)</tr>", tabella, re.S):
        c = re.findall(r"<td[^>]*>(.*?)</td>", r, re.S)
        if len(c) <= max(col_cfu, col_nome):
            continue
        cella = c[col_nome]
        parti = re.split(r"<br\s*/?>", cella)
        if re.search(r"<strong", cella):  # nome in grassetto, sotto i moduli (SSD)
            testo_nome = _plain(parti[0])
            moduli = " ".join(_testo(x) for x in parti[1:])
        else:  # nome = cella intera, con le eventuali alternative («1 elective course out of: A; B; C»)
            testo_nome = _plain(parti[0])
            alt = [re.sub(r"^[–-]\s*", "", _plain(x)) for x in parti[1:] if _plain(x)]
            if alt:
                testo_nome += " " + "; ".join(alt)
            moduli = ""
        if not testo_nome:
            continue
        m = re.search(r"\d+(?:[.,]\d+)?", _testo(c[col_cfu]))
        v = float(m.group(0).replace(",", ".")) if m else None
        a = anno
        a_txt = ""
        if col_anno is not None:
            a_txt = _testo(c[col_anno])
            nums = re.findall(r"\d", a_txt)
            a = int(nums[0]) if nums else None
        if _TOTALE.match(testo_nome):
            if v is not None and a is not None and not re.search(r"(?i)\b(cfu|credit\w*)\b", testo_nome):
                totali[a] = v
            continue
        if a is None:
            continue
        nome = _nome(testo_nome)
        anni_riga = re.findall(r"\d", a_txt)
        if len(anni_riga) > 1:  # «1 e 2»: attività su più anni, senza crediti per anno
            nome = f"{nome} (anni {' e '.join(anni_riga)})"
        href = re.search(r'href="([^"]+)"', cella)
        # i codici SSD stanno nella colonna dei moduli o sotto il nome
        resto = moduli + " " + " ".join(_testo(x) for k, x in enumerate(c) if k not in (col_sem, col_anno, col_nome, col_cfu))
        ssd = sorted(set(_SSD.findall(resto)))
        sem = _periodo(_testo(c[col_sem])) if col_sem is not None else None
        out.append({"anno": a, "periodo": sem, "nome": nome, "cfu": int(v) if v is not None and v.is_integer() else v,
                    "ssd": ssd[0] if len(ssd) == 1 else None,
                    "obbligatorio": False if _ELETTIVA.search(testo_nome) else None,
                    "url": href.group(1) if href and href.group(1).startswith("http") and href.group(1).lower().endswith(".pdf") else pagina})
    return out, totali


def leggi_piano(s: str, scheda: str | None = None, pagina: str = "") -> tuple[list[dict], dict[int, float]]:
    """Insegnamenti e totali dichiarati della pagina. `scheda`: espressione per scegliere la scheda
    di un percorso (pagine con una scheda per percorso)."""
    out, totali = [], {}
    for titolo, corpo in re.findall(r'data-tab-title="([^"]*)"(.*?)(?=data-tab-title="|$)', s, re.S):
        t = re.search(r"<table.*?</table>", corpo, re.S)
        if not t:
            continue
        if scheda:
            if not re.search(scheda, titolo, re.I):
                continue
            anno = None
        else:
            anno = _anno_scheda(titolo)
            if anno is None:
                continue
        righe, tot = _righe(t.group(0), anno, pagina)
        out += righe
        totali.update(tot)
    return out, totali


def _confronta(uid: str, nome: str, voci: list[dict], totali: dict[int, float], log) -> None:
    for a in sorted({v["anno"] for v in voci}):
        somma = sum(v["cfu"] or 0 for v in voci if v["anno"] == a)
        if a in totali and abs(totali[a] - somma) > 0.01:
            log(f"[{uid}] {nome[:50]}: anno {a}, la pagina dichiara {totali[a]:g} CFU, le righe sommano {somma:g}")


def fetch_ateneo(uid: str = "hunimed", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    out = []
    for chiave_piano, p in PIANI.items():
        dei_corsi = [x for x in corsi if str(x.get("id_universitaly")) in p["ul"]]
        if not dei_corsi:
            continue
        url = SITO + p["pagina"]
        r = c.get(url)
        if not r:
            log(f"[{uid}] pagina non raggiungibile: {url}")
            continue
        for corso in dei_corsi:
            scheda = (p.get("schede") or {}).get(str(corso.get("id_universitaly")))
            voci, totali = leggi_piano(r.text, scheda, url)
            durata = corso.get("durata_anni") or 6
            anni = {v["anno"] for v in voci}
            # piano di un altro corso (errore del sito): anni diversi da quelli del corso o nessuna voce attesa
            if not voci or anni != set(range(1, durata + 1)) or not any(
                    re.search(p["chiave"], v["nome"], re.I) for v in voci):
                log(f"[{uid}] {corso['nome'][:50]}: piano scartato ({url}, anni {sorted(anni)})")
                continue
            _confronta(uid, corso["nome"], voci, totali, log)
            doc = {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                   "durata_anni": corso.get("durata_anni"),
                   "url": SITO + p["radice"] if p.get("radice") else url, "curricula": None,
                   "fonte": url, "verificato_il": oggi,
                   "insegnamenti": [{"codice": None, "nome": v["nome"], "anno": v["anno"], "periodo": v["periodo"],
                                     "cfu": v["cfu"], "ssd": v["ssd"], "obbligatorio": v["obbligatorio"],
                                     "curriculum": None, "docenti": [], "url": v["url"], "libri": [], "esami": [],
                                     "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere"}
                                    for v in voci]}
            if p.get("sede"):
                # le due lauree in Medicina e chirurgia hanno lo stesso nome e la stessa classe: la sede le distingue
                doc["sede"] = p["sede"]
            out.append(doc)
    log(f"[{uid}] {len(out)} corsi (su {len(corsi)}), {sum(len(x['insegnamenti']) for x in out)} insegnamenti")
    return {"universita_id": uid, "descrizione": "Generato da www.hunimed.eu, Study Plan (adapters/hunimed.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
