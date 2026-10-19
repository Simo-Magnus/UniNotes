"""Raccoglie insegnamenti, libri e appelli dalle piattaforme pubbliche degli atenei.

Per ogni ateneo elencato in piattaforme.json:
- Course Catalogue Cineca → piani di studio per anno, CFU, periodo, docenti,
  modalità d'esame, libri dei syllabus (adapters/cineca_catalogue.py);
- Esse3 → date degli appelli e delle prove parziali (adapters/esse3_appelli.py);
  per gli atenei senza Esse3 pubblico, servizi propri (APPELLI, es. adapters/unimi_appelli.py);
- siti propri degli atenei senza Course Catalogue (SITI, es. adapters/unibo.py).

Scrive database/contrib/auto/<ateneo>.json (formato contributi di build_db.py).
Uso:
    python tools/db_builder/fetch_atenei.py                 # tutti
    python tools/db_builder/fetch_atenei.py --solo unito,unipd
    python tools/db_builder/fetch_atenei.py --shard 3/10    # per i job in parallelo
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time
from datetime import date

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from adapters.cineca_catalogue import fetch_ateneo  # noqa: E402
from adapters.esse3_appelli import fetch_appelli  # noqa: E402
from adapters import unibo_appelli, unict_appelli, unige_appelli, unimi_appelli, unipd_appelli, unipi_appelli, uniroma1_appelli  # noqa: E402
from adapters import polimi_appelli  # noqa: E402
from adapters import polito_appelli  # noqa: E402
from adapters import unifi  # noqa: E402
from adapters import unibs  # noqa: E402
from adapters import unitn  # noqa: E402
from adapters import uniba  # noqa: E402
from adapters import unipv  # noqa: E402
from adapters import unimore  # noqa: E402
from adapters import unisa  # noqa: E402
from adapters import units  # noqa: E402
from adapters import uniroma2  # noqa: E402
from adapters import unibg, unibg_appelli  # noqa: E402
from adapters import gomp, hunimed, lum, polimi, unito_campusnet, polito, unibo, unibocconi, unibz, unical, unicampania, unicatt, unicusano, unidarc, unict, unidav, unikore, unige, unimi, unimarconi, unimercatorum, unimib, unineuromed, unina, uninettuno, uniroma5, unipa, unipd, unipi, unipegaso, unipg, unipr, uniroma1, unisalento, unisob, unistrasi, uniupo, uniurb, unive, univr, universitaeuropea  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "database" / "contrib" / "auto"
PLAT = json.loads((pathlib.Path(__file__).parent / "piattaforme.json").read_text(encoding="utf-8"))["atenei"]
# Atenei con un adattatore per il proprio sito (insegnamenti e libri senza Course Catalogue)
# appelli da servizi propri dell'ateneo: (uid, corsi raccolti) -> {codice: [esami]}
APPELLI = {"unibg": unibg_appelli.fetch_appelli, "unipv": unipv.fetch_appelli, "polito": polito_appelli.fetch_appelli, "polimi": polimi_appelli.fetch_appelli, "unimi": unimi_appelli.fetch_appelli, "unige": unige_appelli.fetch_appelli,
           "unict": unict_appelli.fetch_appelli, "unibo": unibo_appelli.fetch_appelli,
           "uniroma1": uniroma1_appelli.fetch_appelli, "unito": unito_campusnet.fetch_appelli,
           "unipd": unipd_appelli.fetch_appelli,
           "unipi": unipi_appelli.fetch_appelli,
           "unibs": unibs.fetch_appelli,
           "unitn": unitn.fetch_appelli,
           "unicas": lambda uid, corsi: gomp.fetch_appelli(uid, corsi)}
SITI = {"unibo": unibo.fetch_ateneo, "unimi": unimi.fetch_ateneo, "unige": unige.fetch_ateneo,
        "unict": unict.fetch_ateneo, "polimi": polimi.fetch_ateneo,
        "polito": polito.fetch_ateneo, "uniroma1": uniroma1.fetch_ateneo,
        "univr": univr.fetch_ateneo, "unipg": unipg.fetch_ateneo,
        "unipr": unipr.fetch_ateneo, "unimib": unimib.fetch_ateneo,
        "unicatt": unicatt.fetch_ateneo, "unical": unical.fetch_ateneo,
        "unive": unive.fetch_ateneo, "unisalento": unisalento.fetch_ateneo,
        "uniurb": uniurb.fetch_ateneo, "unikore": unikore.fetch_ateneo,
        "uniroma3": gomp.fetch_ateneo, "unicas": gomp.fetch_ateneo,
        "unitus": gomp.fetch_ateneo, "unicamillus": gomp.fetch_ateneo, "unifortunato": gomp.fetch_ateneo,
        "iul": gomp.fetch_ateneo, "uniroma2": uniroma2.fetch_ateneo,
        "unibocconi": unibocconi.fetch_ateneo, "unicusano": unicusano.fetch_ateneo, "lum": lum.fetch_ateneo, "hunimed": hunimed.fetch_ateneo, "uniroma5": uniroma5.fetch_ateneo, "unidarc": unidarc.fetch_ateneo, "unimarconi": unimarconi.fetch_ateneo, "unistrasi": unistrasi.fetch_ateneo, "uninettuno": uninettuno.fetch_ateneo, "unidav": unidav.fetch_ateneo, "unineuromed": unineuromed.fetch_ateneo, "unisob": unisob.fetch_ateneo, "universitaeuropea": universitaeuropea.fetch_ateneo, "unimercatorum": unimercatorum.fetch_ateneo, "unipegaso": unipegaso.fetch_ateneo, "unibz": unibz.fetch_ateneo, "unicampania": unicampania.fetch_ateneo, "unina": unina.fetch_ateneo, "unipa": unipa.fetch_ateneo, "unipd": unipd.fetch_ateneo, "unipi": unipi.fetch_ateneo, "uniupo": uniupo.fetch_ateneo, "unifi": unifi.fetch_ateneo, "unibs": unibs.fetch_ateneo, "uniba": uniba.fetch_ateneo, "unitn": unitn.fetch_ateneo, "unipv": unipv.fetch_ateneo, "unibg": unibg.fetch_ateneo}
# atenei il cui adattatore in SITI legge già il Course Catalogue (con correzioni proprie)
CATALOGO_IN_SITI = {"unibg", "unipd", "unifi", "unipi", "unibs", "uniba", "unitn", "unipv"}
SITI["unimore"] = unimore.fetch_ateneo  # catalogo Cineca con coorti per nome, libri dai testi liberi e appelli per corso
CATALOGO_IN_SITI.add("unimore")
SITI["unisa"] = unisa.fetch_ateneo  # catalogo Cineca con coorti per nome, durata dal piano, libri dai testi liberi
CATALOGO_IN_SITI.add("unisa")
APPELLI["unisa"] = unisa.fetch_appelli  # bacheca Esse3 per corso di studio e per dipartimento
SITI["units"] = units.fetch_ateneo  # catalogo Cineca a 2 req/s, coorti per nome, libri dai testi liberi e dall'a.a. precedente
CATALOGO_IN_SITI.add("units")
APPELLI["units"] = units.fetch_appelli  # bacheca Esse3 per corso di studio (con codici riassegnati per nome) e per dipartimento
from adapters import uniss  # noqa: E402
SITI["uniss"] = uniss.fetch_ateneo  # catalogo Cineca: anno di corso dall'anno di erogazione, libri dai testi liberi
CATALOGO_IN_SITI.add("uniss")
APPELLI["uniss"] = uniss.fetch_appelli  # bacheca Esse3 per corso di studio e per dipartimento
from adapters import unipg_appelli  # noqa: E402
APPELLI["unipg"] = unipg_appelli.fetch_appelli  # bacheca Esse3 per corso di studio (abbinamento per nome) e per dipartimento
from adapters import unich  # noqa: E402
SITI["unich"] = unich.fetch_ateneo  # catalogo Cineca a 2 req/s: durata dal tipo, coorti per nome, libri dai testi liberi e dall'a.a. precedente
CATALOGO_IN_SITI.add("unich")
APPELLI["unich"] = unich.fetch_appelli  # bacheca Esse3 per corso di studio (codici riassegnati per nome) e per dipartimento
from adapters import univr_appelli  # noqa: E402
APPELLI["univr"] = univr_appelli.fetch_appelli  # bacheca Esse3 per corso di studio, abbinata a codice o nome dell'insegnamento
from adapters import uninsubria  # noqa: E402
SITI["uninsubria"] = uninsubria.fetch_ateneo  # catalogo Cineca a 2 req/s, durata dalla scheda, libri dalle liste Leganto (una sessione per codice)
CATALOGO_IN_SITI.add("uninsubria")
APPELLI["uninsubria"] = uninsubria.fetch_appelli  # bacheca Esse3 per corso di studio (codici riassegnati per nome) e per dipartimento
from adapters import unica  # noqa: E402
SITI["unica"] = unica.fetch_ateneo  # catalogo Cineca a 2 req/s: coorti per nome, anno dall'anno di erogazione, libri dai testi liberi e dall'a.a. precedente
CATALOGO_IN_SITI.add("unica")
APPELLI["unica"] = unica.fetch_appelli  # bacheca Esse3 per corso di studio (codici riassegnati per nome) e per dipartimento
from adapters import unicusano_appelli  # noqa: E402
APPELLI["unicusano"] = unicusano_appelli.fetch_appelli  # pagina «Date Appelli» (sophia.unicusano.it), appelli orali per corso
from adapters import unito  # noqa: E402
SITI["unito"] = unito.fetch_ateneo  # catalogo Cineca: durata dal piano, coorti per nome, piano di ogni sede nel suo corso, blocchi obbligatori
CATALOGO_IN_SITI.add("unito")
from adapters import unisi  # noqa: E402
SITI["unisi"] = unisi.fetch_ateneo  # catalogo Cineca: anno di corso dalle date delle attività («altreAttivita»), durata dal piano, coorti per nome
CATALOGO_IN_SITI.add("unisi")
# Integrazioni: dati che il catalogo non ha (es. i libri di UniTO dalle pagine Campusnet),
# letti a partire dagli insegnamenti già nel database e uniti dopo il catalogo
INTEGRAZIONI = {"unito": unito_campusnet.fetch_ateneo}


def anno_accademico_corrente(oggi: date | None = None) -> int:
    """L'a.a. inizia il 1° settembre: il 4/10/2026 è il 2026/27 → 2026."""
    oggi = oggi or date.today()
    return oggi.year if oggi.month >= 9 else oggi.year - 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--solo", help="id atenei separati da virgola")
    ap.add_argument("--shard", help="i/n: elabora solo una parte degli atenei")
    ap.add_argument("--anno", type=int, default=anno_accademico_corrente())
    ap.add_argument("--max-cds", type=int, default=None, help="per prove veloci")
    ap.add_argument("--senza-syllabus", action="store_true")
    a = ap.parse_args()
    ids = sorted(set(PLAT) | set(SITI))
    if a.solo:
        ids = [i for i in a.solo.split(",") if i in PLAT or i in SITI]
    if a.shard:
        i, n = map(int, a.shard.split("/"))
        ids = ids[i::n]
    OUT.mkdir(parents=True, exist_ok=True)
    print(f"Atenei: {', '.join(ids)} (a.a. {a.anno}/{(a.anno + 1) % 100:02d})")
    for uid in ids:
        t0 = time.time()
        p = PLAT.get(uid, {})
        doc = {"universita_id": uid, "corsi": [], "canali": [], "appelli": {}}
        try:
            if p.get("coursecatalogue") and uid not in CATALOGO_IN_SITI:
                doc.update(fetch_ateneo(uid, p["coursecatalogue"], a.anno, max_cds=a.max_cds,
                                        syllabus=not a.senza_syllabus))
        except Exception as e:  # noqa: BLE001 - un ateneo che fallisce non ferma gli altri
            print(f"[{uid}] ERRORE catalogo: {e!r}")
        try:
            if uid in SITI:
                doc.update(SITI[uid](uid, a.anno, max_cds=a.max_cds, syllabus=not a.senza_syllabus))
        except Exception as e:  # noqa: BLE001
            print(f"[{uid}] ERRORE sito: {e!r}")
        try:
            if uid in INTEGRAZIONI:
                doc["corsi"] += INTEGRAZIONI[uid](uid, a.anno, max_cds=a.max_cds,
                                                  syllabus=not a.senza_syllabus)["corsi"]
        except Exception as e:  # noqa: BLE001
            print(f"[{uid}] ERRORE integrazione: {e!r}")
        try:
            if uid in APPELLI and doc["corsi"]:  # prima dell'Esse3: alcune bacheche pubbliche sono vuote
                doc["appelli"] = APPELLI[uid](uid, doc["corsi"])
            elif p.get("esse3"):
                doc["appelli"] = fetch_appelli(uid, p["esse3"])
        except Exception as e:  # noqa: BLE001
            print(f"[{uid}] ERRORE esse3: {e!r}")
        doc.setdefault("appelli", {})
        if doc["corsi"] or doc["appelli"]:
            (OUT / f"{uid}.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")),
                                             encoding="utf-8")
        print(f"[{uid}] fatto in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
