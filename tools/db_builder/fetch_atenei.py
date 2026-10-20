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
SITI["unisa"] = unisa.fetch_ateneo  # catalogo Cineca: piani per coorte (codici cambiati con il riordino, sei corsi rinominati, piani di più coorti nello stesso elenco), gruppi OO/F/W/S con CFU dalle etichette, attività a 0 CFU tolte o con i CFU di un'altra coorte, libri dai testi liberi
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
from adapters import unime  # noqa: E402
SITI["unime"] = unime.fetch_ateneo  # catalogo Cineca: durata dal piano, coorti per codice e nome, CFU fissi/liberi dalle etichette dei gruppi, id dei corsi gemelli
CATALOGO_IN_SITI.add("unime")
from adapters import univpm  # noqa: E402
SITI["univpm"] = univpm.fetch_ateneo  # catalogo Cineca: piani «altreAttivita» con l'anno da annoCorso, codici riordinati, sedi come percorsi
CATALOGO_IN_SITI.add("univpm")
from adapters import unilink  # noqa: E402
SITI["unilink"] = unilink.fetch_ateneo  # catalogo Cineca: durata dal piano, piani per coorte (percorsi «Coorte …»), integrati con i moduli, una sede per corso di Universitaly
CATALOGO_IN_SITI.add("unilink")
APPELLI["unilink"] = lambda uid, corsi: unilink.appelli_moduli(corsi, fetch_appelli(uid, PLAT[uid]["esse3"]))  # bacheca Esse3, più gli appelli dei moduli degli integrati
from adapters import unibas  # noqa: E402
SITI["unibas"] = unibas.fetch_ateneo  # catalogo Cineca: durata dal piano, anno di corso dall'a.a. di erogazione, voci del piano ufficiale che il catalogo non ha
CATALOGO_IN_SITI.add("unibas")
from adapters import univaq  # noqa: E402
SITI["univaq"] = univaq.fetch_ateneo  # catalogo Cineca: durata dal piano, piani per coorte (codici e nomi cambiati con il riordino), crediti dei gruppi a scelta dalle etichette, una sede per corso di Universitaly
CATALOGO_IN_SITI.add("univaq")
from adapters import unife  # noqa: E402
SITI["unife"] = unife.fetch_ateneo  # catalogo Cineca: durata dal piano, piani per coorte (codici cambiati con i riordini), gruppi OO/F/W/S del piano con CFU dalle etichette, una sede per corso di Universitaly
CATALOGO_IN_SITI.add("unife")
from adapters import uniud  # noqa: E402
SITI["uniud"] = uniud.fetch_ateneo  # catalogo Cineca: piani per coorte (codici cambiati con il riordino), uno schema per curriculum, gruppi OO/F/G/W/S del piano con i CFU della libera scelta da etichette e note, stesso codice con CFU diversi tra i curricula
CATALOGO_IN_SITI.add("uniud")
from adapters import unimol  # noqa: E402
SITI["unimol"] = unimol.fetch_ateneo  # catalogo Cineca: durata dal piano, piani per coorte (codici con la «R» del riordino e tre corsi con altro nome e codice), gruppi OO/F/G/S con CFU dalle etichette, attività a 0 CFU tolte, un corso per ogni corso di Universitaly
CATALOGO_IN_SITI.add("unimol")
from adapters import unicz  # noqa: E402
SITI["unicz"] = unicz.fetch_ateneo  # catalogo Cineca: piani per coorte (2025/2026 senza anni: coorte più vicina con ≥30 CFU obbligatori), gruppi OO/F/W/S con CFU dalle etichette, corsi e anni mancanti dall'elenco degli insegnamenti erogati dei siti delle Scuole/Dipartimento
CATALOGO_IN_SITI.add("unicz")
from adapters import unimc  # noqa: E402
SITI["unimc"] = unimc.fetch_ateneo  # catalogo Cineca: durata dal piano (FI = 1 anno), piani per coorte (codici con la «R» del riordino, percorsi per codice o per insegnamenti in comune), gruppi OO/F/G/W/S con CFU dalle etichette e dalle note, scelte senza anno nell'ultimo anno
CATALOGO_IN_SITI.add("unimc")
from adapters import poliba  # noqa: E402
SITI["poliba"] = poliba.fetch_ateneo  # catalogo Cineca: piani per coorte (codici «-R» del riordino), gruppi OO/F/G/W/S con CFU dalle etichette, anni 0 e «1° e 2° anno» riassegnati, corso e replica di Taranto con i propri percorsi
CATALOGO_IN_SITI.add("poliba")
from adapters import uniparthenope  # noqa: E402
SITI["uniparthenope"] = uniparthenope.fetch_ateneo  # catalogo Cineca: piani per coorte (codici «R» del riordino = «0»), gruppi OO/F/G/S con CFU dalle etichette, percorsi senza nome come «Percorso <codice>», corsi omonimi di sedi diverse (Napoli, Nola, Caivano) ognuno con il proprio id, stesso codice con CFU diversi tra i percorsi
CATALOGO_IN_SITI.add("uniparthenope")
from adapters import unifg  # noqa: E402
SITI["unifg"] = unifg.fetch_ateneo  # catalogo Cineca: piani per coorte (codici cambiati con il riordino, tipo e sede dei corsi omonimi), gruppi OO/F/W/S con CFU dalle etichette «fra A e B CFU», regole di scelta libera senza elenco come voce a scelta, percorsi doppi uniti, repliche di sede dell'Infermieristica con id Universitaly espliciti
CATALOGO_IN_SITI.add("unifg")
from adapters import unicampus  # noqa: E402
SITI["unicampus"] = unicampus.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici del riordino: INPL04>INPL01, MCLM08>MCLM01, ...), piani per coorte con ripiego sulla più vicina, gruppi OO/F/W con scelte riconosciute, ADE e tirocini opzionali nell'anno di erogazione, attività a 0 CFU e «altreAttivita» (erogato) escluse
CATALOGO_IN_SITI.add("unicampus")
from adapters import unicamillus  # noqa: E402
SITI["unicamillus"] = unicamillus.fetch_ateneo  # GOMP: regolamenti per a.a. = erogato (l'anno k dal più recente che lo ha), anni non ancora insegnati dal piano 2026/27 del regolamento didattico (PDF), un corso per ogni id Universitaly (Medicina Roma in inglese, Venezia, Roma in italiano, Cefalù; Odontoiatria Roma e Venezia-Mestre) con la sede, crediti liberi a scelta, righe omonime dello stesso anno distinte
from adapters import unior  # noqa: E402
SITI["unior"] = unior.fetch_ateneo  # catalogo Cineca: piani per coorte (codici «R» del riordino 2025, percorsi cambiati tra le coorti), gruppi OO/F/W/S con CFU dalle etichette, anno «altreAttivita» nell'ultimo anno, esame a scelta libera e insegnamenti del piano senza doppioni, id Universitaly espliciti
CATALOGO_IN_SITI.add("unior")
from adapters import unifortunato  # noqa: E402
SITI["unifortunato"] = unifortunato.fetch_ateneo  # GOMP: ogni anno dal regolamento 2026 (il 1° anno solo era letto prima), DEI-09 e PSI-08 dal regolamento 2026 non più nell'elenco, percorsi vuoti, attività a 0 CFU e gruppi extracurriculari esclusi, gruppi a scelta espansi, libri dai regolamenti precedenti
from adapters import unicam  # noqa: E402
SITI["unicam"] = unicam.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici: L-CHI > L-CHIR, LM-FAR > LM-FARA > LM-FARAR), piani per coorte con ripiego sulla più vicina, durata dal piano (cicli unici di 5 anni), gruppi OO/F/G/W con stage e scelte come attività a scelta, curricula veri anche col flag «comune» del catalogo (Bioscienze e Biotecnologia), attività a 0 CFU (OFA) escluse
CATALOGO_IN_SITI.add("unicam")
from adapters import uniecampus  # noqa: E402
SITI["uniecampus"] = uniecampus.fetch_ateneo  # catalogo Cineca: piani per coorte (codici dei riordini DM 1648/23 e 1649/23 ritrovati per nome), gruppi OO/F con CFU dalle etichette, solo L2/LM/LM5, un corso per ogni corso di Universitaly (id espliciti, niente «(DM …)» nel nome), attività a 0 CFU tolte, libri dai testi liberi
CATALOGO_IN_SITI.add("uniecampus")
from adapters import luiss  # noqa: E402
SITI["luiss"] = luiss.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici per codice ministeriale: L25xx > L21xx, LM26FIN > LM25W > LM19W, ...), piano della coorte di ogni anno, percorsi «N anno <curriculum>» senza prefisso e suffisso «da orientamento», ACE Program come percorso alternativo, tipo di insegnamento OBB/OPZ del catalogo, attività a 0 CFU escluse, segnaposto «***CORE/ELECTIVE ABROAD***» distinti per codice
CATALOGO_IN_SITI.add("luiss")
from adapters import unint  # noqa: E402
SITI["unint"] = unint.fetch_ateneo  # piani di studio dalle pagine dei corsi di unint.eu (il catalogo Cineca ha solo un elenco di attività senza anno), insegnamenti abbinati per nome alle attività del catalogo (codice, docenti, periodo, libri), alternative «oppure»/«a scelta tra»/lingue come scelte, curricula per indirizzo, L-18 dal regolamento 2025/26, un corso per ogni corso di Universitaly (id espliciti)
CATALOGO_IN_SITI.add("unint")
from adapters import lumsa  # noqa: E402
SITI["lumsa"] = lumsa.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici del riordino 2025: R403/02 > L18, 400/15 > LMG01R, ...), piani per coorte con ripiego sulla più vicina, piano della sede (Roma/Palermo/Taranto), percorsi riconosciuti tra i codici, gruppi OO/F/W con CFU dalle etichette, attività a 0 CFU tolte, «altreAttivita» a scelta nell'anno in cui sono offerte
CATALOGO_IN_SITI.add("lumsa")
from adapters import unirc  # noqa: E402
SITI["unirc"] = unirc.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici dei riordini: 87.L < 86.L, L7-R < 57.L < 56.L, 010MR < 010M, ...), piano della coorte di ogni anno, durata dal piano (cicli unici di 5 anni), gruppi OO/F/G/W/S con CFU dalle etichette, regole di scelta libera con i CFU dei regolamenti, attività a 0 CFU tolte
CATALOGO_IN_SITI.add("unirc")
from adapters import iuav  # noqa: E402
SITI["iuav"] = iuav.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (ogni coorte ha un codice proprio: B07 > B08 > B09, N40 > N41 > N42, ...), piano della coorte di ogni anno (prima si usava per tutti gli anni quello del 2026), ciclo unico di Architettura e Curatela delle Arti senza il secondo corso del catalogo, prova finale (e tirocinio) nell'ultimo anno, curricula per codice del percorso, tipo OBB/OPZ del catalogo, attività a 0 CFU tolte, libri già raccolti per codice
CATALOGO_IN_SITI.add("iuav")
from adapters import iul  # noqa: E402
SITI["iul"] = iul.fetch_ateneo  # piani di studio dai PDF per coorte di iuline.it (il regolamento GOMP ripartisce i gruppi AFFINI su più anni e ha curricula nuovi con il solo 1° anno), anno k dalla coorte a.a. - k + 1 con totali di ogni anno controllati, righe a scelta, codice/docenti/periodo/libri dalle attività GOMP con lo stesso nome (2026, 2025, 2024)
from adapters import iulm  # noqa: E402
SITI["iulm"] = iulm.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici del riordino 2025: 59 > 361, 64 > 360, 68 > 368, ...), durata dal tipo (L 3, LM 2), piano della coorte di ogni anno (A-k+1), percorsi del catalogo ricondotti ai curricula, contenitori di moduli a 0 CFU tolti, crediti a scelta/stage/field project/prova finale dalla pagina «Piano di studi» del corso
CATALOGO_IN_SITI.add("iulm")
from adapters import uniroma4  # noqa: E402
SITI["uniroma4"] = uniroma4.fetch_ateneo  # catalogo Cineca + pagine AFS di uniroma4.it: un corso per ogni corso di Universitaly (id espliciti, catene di codici dei riordini L22R > L22, LM67I-R > LM67INT, ...), piano della coorte di ogni anno (3° anno di Scienze motorie e sportive dall'ordinamento 2014), AFS e internati elettivi con gli anni di corso dalle pagine ufficiali (nel catalogo sono un gruppo senza anno), Health and Physical Activity senza AFS, curricula Gestione e organizzazione dello sport di alto livello / Scienze motorie e sportive, Management / Giuridico-Gestionale, libri già raccolti per codice
CATALOGO_IN_SITI.add("uniroma4")
from adapters import unite  # noqa: E402
SITI["unite"] = unite.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici del riordino 2025: 65 > 99, 46 > 108, 86 > 118, 84 > 92 > 113, ...), piano della coorte di ogni anno, durata dal piano (Medicina veterinaria e Giurisprudenza di 5 anni), sede Avezzano = replica di Giurisprudenza, gruppi OO/F/W con CFU dalle etichette, OFA a 0 CFU tolti (ofa nei requisiti), nomi dei percorsi ripuliti, prova finale di Scienze politiche dalla pagina ufficiale
CATALOGO_IN_SITI.add("unite")
from adapters import liuc  # noqa: E402
SITI["liuc"] = liuc.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici L18C > L18B > L18A, L09B > L09A, LM77C > LM77B > LM77A), piano della coorte di ogni anno, durata dalla tabella, contenitori a 0 CFU e consigliati senza crediti tolti, percorsi con il nome della coorte più recente e senza virgole, gruppi «F» a scelta salvo quelli obbligatori del piano ufficiale, crediti a scelta (regola «S») nell'ultimo anno, elenco «X SUA» degli insegnamenti a scelta di LM-77
CATALOGO_IN_SITI.add("liuc")
from adapters import unisannio  # noqa: E402
SITI["unisannio"] = unisannio.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici del riordino 2025: 172 > 101, 261 > 201, 865 > 802, 388 > 302, 904 > 905, ...), piano della coorte di ogni anno (prima le attività di tutte le coorti si sommavano: anni da 138 e 219 CFU), Scienze geologiche = piano L-34 di «Scienze naturali, geologiche e ambientali», gruppi OO/F/W/S con le scelte dalle note («DEVI SCEGLIERE N»), crediti a scelta dei gruppi senza elenco, percorsi per codice, OFA e attività a 0 CFU tolti
CATALOGO_IN_SITI.add("unisannio")
from adapters import unitelma  # noqa: E402
SITI["unitelma"] = unitelma.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (id espliciti; Scienze giuridiche LM/SC-GI = LM/SC-GIUR), lauree e ciclo unico dalla sola coorte 2025 disponibile (anni 1-3 e 4-5 di Giurisprudenza), magistrali nuove dalla coorte 2026, durata dal piano, gruppi OO/F/W (S senza elenco non è una voce), curricula ripuliti (niente virgole nei nomi), alternative omonime distinte da CFU e codice, nomi in maiuscolo con apostrofi e accenti corretti, libri già raccolti per codice
CATALOGO_IN_SITI.add("unitelma")
from adapters import unistrapg  # noqa: E402
SITI["unistrapg"] = unistrapg.fetch_ateneo  # piano di studi dalle pagine dei corsi di unistrapg.it (tabella per anno e curriculum con il totale di 60 CFU; il catalogo Cineca ha solo le 3 magistrali con anni e CFU incompleti), codice/docenti/semestre dai programmi degli insegnamenti, insegnamenti erogati non in tabella con anno e CFU dalla scheda, id Universitaly espliciti, docenti/periodo/libri del catalogo per le magistrali
CATALOGO_IN_SITI.add("unistrapg")
from adapters import univda  # noqa: E402
SITI["univda"] = univda.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (catene di codici del riordino 2025: C06 > C07, E02 > E03, D03 > D05, F02 > F03, G01 > G02), piano della coorte di ogni anno (con ripiego sulla più vicina completa: 4° anno 2023 e 3° anno 2024 di Scienze della formazione primaria incompleti nel catalogo), durata dalla tabella (Scienze della formazione primaria 5 anni, prima erano letti solo i primi 3), piani «proposto» e «altreAttivita» (doppi diplomi, vecchi piani, moduli S_, esercitazioni e precorsi a 0 CFU) non letti, curricula senza «Piano di studi … Curriculum», segnaposto OPZIONALI e stage a scelta, libri già raccolti per codice
CATALOGO_IN_SITI.add("univda")
from adapters import unisg  # noqa: E402
SITI["unisg"] = unisg.fetch_ateneo  # catalogo Cineca: un corso per ogni corso di Universitaly (id espliciti), piano della coorte di ogni anno (Scienze e Culture Gastronomiche: LSG18R coorti 2026 e 2025, LSG18 coorte 2024; prima il piano si mescolava tra tre ordinamenti), contenitori degli insegnamenti integrati a 0 CFU tolti (i moduli hanno i CFU), attività a 0 CFU senza moduli tolte, corso a scelta del 3° anno di Food Tech dalle altre attività, nomi in maiuscolo corretti, libri già raccolti per codice
CATALOGO_IN_SITI.add("unisg")
from adapters import unisr  # noqa: E402
SITI["unisr"] = unisr.fetch_ateneo  # piano della coorte di ogni anno dai PDF «Piano degli studi» di www.unisr.it (il catalogo non ha l'anno di corso; Esse3: sezioni per sede/canale/curriculum, Filosofia: gruppi a scelta), codici, docenti e libri ripresi dal catalogo (o dal database se è in manutenzione) per nome, doppioni del catalogo (Infermieristica 2, Medicina 2 e 3, Psicologia cognitiva) sui corsi di Universitaly, corsi elettivi del catalogo a scelta
CATALOGO_IN_SITI.add("unisr")
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
