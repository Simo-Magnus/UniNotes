"""UniCamillus (Roma): piani di studio, docenti e libri dall'API pubblica GOMP, più i piani dei regolamenti ufficiali.

Piani: `https://unicamillus-public.gomp.it` (stessa API di `gomp.py`). Rispetto all'adattatore comune servono:

- regolamenti per a.a. = erogato: GOMP pubblica per ogni a.a. un regolamento per corso con gli anni oggi insegnati (il
  regolamento 2026 di Fisioterapia ha i 3 anni, quello di Cefalù i primi 3, quello di Igiene dentale, nato nel 2026, solo il
  1°). L'anno k si legge dal regolamento più recente che lo ha; il 2026 ha tutti gli anni già insegnati. Il solo 1° anno
  dell'a.a. corrente (adattatore comune) lasciava vuoti gli anni successivi;
- anni non ancora insegnati (Medicina Roma in italiano 5°-6°, Venezia 5°-6°, Cefalù 4°-6°, Igiene dentale 2°-3°, Odontoiatria
  Venezia-Mestre 2°-6°): il piano della coorte 2026/27 dell'allegato «Piano di studi» del regolamento didattico ufficiale
  (PDF su unicamillus.org/wp-content/uploads/regolamenti), trascritto in `PIANI_REGOLAMENTO` con i CFU dell'insegnamento
  integrato e i settori delle sue materie; ogni anno vale 60 CFU (controllato all'avvio). Senza docenti né libri;
- un corso del database per ogni corso GOMP (codice) dell'id Universitaly: le quattro «Medicina e chirurgia» sono Roma in
  inglese (30005), Venezia (20011), Roma in italiano (20011_RM) e Cefalù (20013), con `sede` per distinguerle;
- crediti liberi: «Esami a scelta», «ADE - Attività didattica elettiva», «ADO - …opzionale» e «tirocinio a scelta dello
  studente» sono voci a scelta (senza codice); due righe con lo stesso nome nello stesso anno non si fondono (CFU nel nome
  se diversi, numero altrimenti: «Esami a scelta 1», «Tirocinio pratico valutativo 2»);
- i CFU dell'insegnamento integrato sono la somma dei CFU dei settori (`credits`); i moduli non si elencano.

Con la variabile d'ambiente UNICAMILLUS_HTTP_CACHE (una cartella) le risposte dell'API restano su disco.
Richieste: 3 al secondo.

Esecuzione locale (scrive `database/contrib/auto/unicamillus.json`):

    python tools/db_builder/adapters/unicamillus.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import pathlib
import re
import sys
import time

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .gomp import HOSTS, Api, _attivita, _cfu_attivita, _ita, _norm  # noqa: E402

UID = "unicamillus"
ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = HOSTS[UID]
REG = "https://unicamillus.org/wp-content/uploads/regolamenti/"

# id Universitaly del corso → codice del corso in GOMP e sede (dove serve a distinguere i corsi omonimi)
CORSI = {
    "1628617": {"gomp": "20003"},                                  # Fisioterapia
    "1625431": {"gomp": "20015"},                                  # Igiene dentale (dal 2026/27)
    "1628602": {"gomp": "20001"},                                  # Infermieristica
    "1628603": {"gomp": "20002"},                                  # Ostetricia
    "1628604": {"gomp": "20006"},                                  # Tecniche di radiologia medica
    "1628619": {"gomp": "20009"},                                  # Scienze della nutrizione umana
    "1628605": {"gomp": "30005", "sede": "Roma (in inglese)"},     # Medicina e chirurgia, Roma, in inglese
    "1628606": {"gomp": "20011", "sede": "Venezia"},               # Medicina e chirurgia, Venezia
    "1628607": {"gomp": "20011_RM", "sede": "Roma (in italiano)"},  # Medicina e chirurgia, Roma, in italiano
    "1628608": {"gomp": "20013", "sede": "Cefalù"},                # Medicina e chirurgia, Cefalù
    "1628609": {"gomp": "20007", "sede": "Roma"},                  # Odontoiatria e protesi dentaria, Roma
    "1628611": {"gomp": "20016", "sede": "Venezia - Mestre"},      # Odontoiatria e protesi dentaria, Venezia-Mestre
}

# Crediti liberi del piano (non sono insegnamenti obbligatori): a scelta, ADE (elettiva), ADO (opzionale), tirocinio a scelta
_LIBERA = re.compile(r"(?i)^\s*(a scelta\b|attivit[aà] (formative )?a scelta|insegnament[oi] a scelta|esam[ei] a scelta|"
                     r"crediti (liberi|a scelta)|corso a scelta|materia a scelta|ad[eo]\b|"
                     r"attivit[aà] didattic[ah]e? (elettiv|opzional)|tirocinio a scelta)")

# Piani dei regolamenti didattici 2026/27 (allegato «Piano di studi»), per gli anni che GOMP non ha ancora: id Universitaly →
# {anno: (PDF, [(nome, CFU, [settori], semestre|None, "o" obbligatorio / "s" a scelta)])}.
_V = REG + "205r-353-26dr-regolamento-medicina-e-chirurgia_italiano_venezia_a.a.-2026-2027.pdf"
_C = REG + "206r-354-26dr-regolamento-medicina-e-chirurgia_-italiano_cefalu-a.a.-2026-2027.pdf"
_R = REG + "204r-352_26dr-regolamento-medicina-e-chirurgia_italiano_roma_a.a.-2026-2027.pdf"
_M = REG + "199r_92-2026dr_regolamento_didattico-e-tirocinio_cdl_odontoiatria-e-protesi-dentaria-venezia-def.pdf"
_I = REG + "198r_91-2026dr_regolamento_didattico-e-tirocinio_cds-igiene-dentale.pdf"
_O = "MEDS-16/A"
PIANI_REGOLAMENTO = {
    # Medicina e chirurgia, Venezia (Rif. 205): 5° e 6° anno
    "1628606": {
        5: (_V, [
            ("Scienze neurologiche", 6, ["MEDS-12/A", "MEDS-15/A", "MEDS-22/B"], "1", "o"),
            ("Malattie dell'apparato locomotore", 4, ["MEDS-19/A"], "1", "o"),
            ("Discipline specialistiche", 6, ["MEDS-16/A", "MEDS-17/A", "MEDS-18/A"], "1", "o"),
            ("Tirocinio", 10, [], "1", "o"),
            ("Chirurgia generale", 8, ["MEDS-06/A"], "2", "o"),
            ("Dermatologia e chirurgia plastica", 4, ["MEDS-10/C", "MEDS-14/A"], "2", "o"),
            ("Diagnostica per immagini, radioterapia e tecnologia dei materiali", 7, ["MEDS-22/A", "IMAT-01/A"], "2", "o"),
            ("Preparazione tesi di laurea", 5, [], "2", "o"),
            ("Tirocinio", 5, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
        ]),
        6: (_V, [
            ("Medicina interna e clinica chirurgica", 13,
             ["MEDS-24/C", "MEDS-01/A", "MEDS-08/C", "MEDS-09/A", "MEDS-06/A", "MEDS-05/A"], "1", "o"),
            ("Medicina legale e medicina d'urgenza", 11, ["MEDS-25/A", "MEDS-23/A", "MEDS-05/A", "MEDS-06/A"], "1", "o"),
            ("Inglese scientifico", 3, ["ANGL-01/C"], "1", "o"),
            ("Tirocinio", 10, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
            ("Prova finale", 13, [], "2", "o"),
        ]),
    },
    # Medicina e chirurgia, Roma in italiano (Rif. 204): 5° e 6° anno
    "1628607": {
        5: (_R, [
            ("Malattie dell'apparato locomotore e diagnostica per immagini", 9, ["MEDS-19/A", "MEDS-22/A"], "1", "o"),
            ("Discipline specialistiche", 6, ["MEDS-16/A", "MEDS-17/A", "MEDS-18/A"], "1", "o"),
            ("Tirocinio", 10, [], "1", "o"),
            ("Esami a scelta", 3, [], "1", "s"),
            ("Chirurgia generale", 7, ["MEDS-06/A"], "2", "o"),
            ("Dermatologia e chirurgia plastica", 4, ["MEDS-10/C", "MEDS-14/A"], "2", "o"),
            ("Scienze neurologiche", 6, ["MEDS-12/A", "MEDS-15/A", "MEDS-22/B"], "2", "o"),
            ("Inglese scientifico", 5, ["ANGL-01/C"], "2", "o"),
            ("Tirocinio", 5, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
        ]),
        6: (_R, [
            ("Medicina oncologica e cure palliative", 5, ["MEDS-24/C", "MEDS-09/A"], "1", "o"),
            ("Medicina legale", 4, ["MEDS-25/A"], "1", "o"),
            ("Medicina d'urgenza e terapia del dolore", 12, ["MEDS-23/A", "MEDS-05/A", "MEDS-06/A"], "1", "o"),
            ("Preparazione tesi di laurea", 5, [], "1", "o"),
            ("Tirocinio", 2, [], "1", "o"),
            ("Tirocinio pratico valutativo", 5, [], "1", "o"),
            ("Clinica chirurgica e clinica medica", 4, ["MEDS-06/A", "MEDS-05/A"], "2", "o"),
            ("Tirocinio", 5, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
            ("Prova finale", 13, [], "2", "o"),
        ]),
    },
    # Medicina e chirurgia, Cefalù (Rif. 206): 4°, 5° e 6° anno
    "1628608": {
        4: (_C, [
            ("Anatomia patologica II", 8, ["MEDS-04/A"], "1", "o"),
            ("Patologia sistematica III", 10, ["MEDS-09/B", "MEDS-05/A", "MEDS-09/C", "MEDS-10/B"], "1", "o"),
            ("Medicina di genere nell'invecchiamento", 4, ["MEDS-05/A", "MEDS-19/B"], "1", "o"),
            ("Esami a scelta", 1, [], "1", "s"),
            ("Tirocinio", 7, [], "1", "o"),
            ("Ostetricia e ginecologia", 5, ["MEDS-21/A"], "2", "o"),
            ("Psichiatria", 5, ["MEDS-11/A", "PSIC-04/B"], "2", "o"),
            ("Scienze pediatriche", 9, ["MEDS-20/A", "MEDS-14/B", "MEDS-20/B"], "2", "o"),
            ("Tirocinio", 11, [], "2", "o"),
        ]),
        5: (_C, [
            ("Scienze neurologiche", 8, ["MEDS-12/A", "MEDS-15/A"], "1", "o"),
            ("Diagnostica per immagini, radioterapia e malattie dell'apparato locomotore", 8,
             ["MEDS-22/A", "MEDS-19/A"], "1", "o"),
            ("Tirocinio", 10, [], "1", "o"),
            ("Chirurgia generale", 9, ["MEDS-06/A"], "2", "o"),
            ("Dermatologia e chirurgia plastica", 4, ["MEDS-10/C", "MEDS-14/A"], "2", "o"),
            ("Discipline specialistiche", 6, ["MEDS-16/A", "MEDS-17/A", "MEDS-18/A"], "2", "o"),
            ("Preparazione tesi di laurea", 5, [], "2", "o"),
            ("Tirocinio", 5, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
        ]),
        6: (_C, [
            ("Oncologia e genetica medica", 7, ["MEDS-01/A", "MEDS-09/A"], "1", "o"),
            ("Medicina legale", 4, ["MEDS-25/A"], "1", "o"),
            ("Medicina d'urgenza", 9, ["MEDS-23/A", "MEDS-05/A", "MEDS-06/A", "MEDS-24/C"], "1", "o"),
            ("Esami a scelta", 3, [], "1", "s"),
            ("Tirocinio", 7, [], "1", "o"),
            ("Clinica chirurgica e clinica medica", 7, ["MEDS-06/A", "MEDS-05/A"], "2", "o"),
            ("Tirocinio", 5, [], "2", "o"),
            ("Tirocinio pratico valutativo", 5, [], "2", "o"),
            ("Prova finale", 13, [], "2", "o"),
        ]),
    },
    # Odontoiatria e protesi dentaria, Venezia-Mestre (Rif. 199): 2°-6° anno (il piano non indica i semestri)
    "1628611": {
        2: (_M, [
            ("Principi di odontoiatria", 13, ["MEDS-16/A", "MEDS-26/B"], None, "o"),
            ("Fisiologia", 10, ["BIOS-06/A"], None, "o"),
            ("Microbiologia e igiene", 12, ["MEDS-03/A", "MEDS-24/B"], None, "o"),
            ("Patologia generale", 8, ["MEDS-02/A"], None, "o"),
            ("Biologia molecolare e patologia clinica", 6, ["BIOS-08/A", "BIOS-09/A", "MEDS-02/B"], None, "o"),
            ("Diagnostica per immagini e radioterapia", 6, ["MEDS-22/A"], None, "o"),
            ("Medicina legale e del lavoro", 5, ["MEDS-25/A", "MEDS-25/B"], None, "o"),
        ]),
        3: (_M, [
            ("Materiali dentari e tecnologie protesiche", 17, [_O], None, "o"),
            ("Patologia speciale odontostomatologica", 12, [_O], None, "o"),
            ("Farmacologia", 6, ["BIOS-11/A"], None, "o"),
            ("Medicina interna e anatomia patologica", 16, ["MEDS-05/A", "MEDS-04/A", "MEDS-10/C"], None, "o"),
            ("Scienze mediche", 9, ["MEDS-09/B", "MEDS-07/B", "MEDS-08/A", "MEDS-09/A", "MEDS-10/A", "MEDS-02/B"], None, "o"),
        ]),
        4: (_M, [
            ("Chirurgia orale", 8, [_O], None, "o"),
            ("Neurologia e psichiatria", 4, ["MEDS-12/A", "MEDS-11/A"], None, "o"),
            ("Ortodonzia e gnatologia", 12, [_O], None, "o"),
            ("Discipline odontostomatologiche I", 21, [_O], None, "o"),
            ("Scienze chirurgiche", 14, ["MEDS-23/A", "MEDS-06/A", "MEDS-17/A", "MEDS-14/A"], None, "o"),
            ("ADE - Attività didattica elettiva", 1, [], None, "s"),
        ]),
        5: (_M, [
            ("Odontoiatria restaurativa", 11, [_O], None, "o"),
            ("Ortodonzia", 10, [_O], None, "o"),
            ("Implantologia", 12, [_O], None, "o"),
            ("Odontoiatria pediatrica", 8, [_O, "MEDS-20/A"], None, "o"),
            ("Riabilitazione protesica", 6, [_O], None, "o"),
            ("Parodontologia", 5, [_O], None, "o"),
            ("Patologia e terapia maxillo-facciale", 8, ["MEDS-15/B", "MEDS-18/A", _O, "MEDS-14/A"], None, "o"),
        ]),
        6: (_M, [
            ("Discipline odontostomatologiche II", 5, [_O], None, "o"),
            ("Discipline odontostomatologiche III", 5, [_O], None, "o"),
            ("Tirocinio a scelta dello studente", 8, [_O], None, "s"),
            ("Terapia odontostomatologica integrata - TPV", 30, [_O], None, "o"),
            ("ADE - Attività didattica elettiva", 4, [], None, "s"),
            ("Prova finale", 8, [], None, "o"),
        ]),
    },
    # Igiene dentale (Rif. 198): 2° e 3° anno
    "1625431": {
        2: (_I, [
            ("Principi di medicina generale", 7,
             ["MEDS-23/A", "BIOS-11/A", "MEDS-05/A", "MEDS-17/A", "MEDS-10/B", "MEDS-18/A"], "1", "o"),
            ("Principi di patologia del cavo orale", 6, ["MEDS-26/B", _O, "MEDS-22/A"], "1", "o"),
            ("Scienze dell'igiene dentale II", 6, ["MEDS-26/B", _O], "1", "o"),
            ("Odontoiatria dell'età evolutiva", 6, [_O, "MEDS-20/A"], "2", "o"),
            ("Odontoiatria ricostruttiva", 7, ["MEDS-26/B", _O], "2", "o"),
            ("Tirocinio", 22, ["MEDS-26/B"], None, "o"),
            ("Informatica/attività seminariali", 2, ["MEDS-26/B"], None, "o"),
            ("Esami a scelta", 3, [], None, "s"),
            ("Laboratori professionali", 1, ["MEDS-26/B"], None, "o"),
        ]),
        3: (_I, [
            ("Scienze dell'igiene dentale III", 6, ["MEDS-04/A", _O, "MEDS-26/B"], "1", "o"),
            ("Protocolli igienici in odontoiatria chirurgica e riabilitativa", 6, [_O], "1", "o"),
            ("Scienze medico-legali", 5, ["MEDS-26/B", "MEDS-25/A", "ECON-04/A", "ECON-06/A", "MEDS-25/B"], "2", "o"),
            ("Scienze dell'igiene dentale IV", 4, ["MEDS-26/B", _O], "2", "o"),
            ("Tirocinio", 27, ["MEDS-26/B"], None, "o"),
            ("Esami a scelta", 3, [], None, "s"),
            ("Informatica/attività seminariale", 2, ["MEDS-26/B"], None, "o"),
            ("Laboratori professionali", 1, ["MEDS-26/B"], None, "o"),
            ("Prova finale", 6, [], None, "o"),
        ]),
    },
}
for _id, _anni in PIANI_REGOLAMENTO.items():  # ogni anno del regolamento vale 60 CFU
    for _a, (_url, _righe) in _anni.items():
        assert sum(r[1] for r in _righe) == 60, (_id, _a, sum(r[1] for r in _righe))


class _ApiCache(Api):
    """Api di GOMP con le risposte su disco (UNICAMILLUS_HTTP_CACHE)."""

    def post(self, metodo: str, dati: dict):
        cartella = os.environ.get("UNICAMILLUS_HTTP_CACHE")
        if not cartella:
            return super().post(metodo, dati)
        pathlib.Path(cartella).mkdir(parents=True, exist_ok=True)
        p = pathlib.Path(cartella) / (hashlib.sha1(json.dumps([metodo, dati], sort_keys=True).encode()).hexdigest() + ".json")
        if p.exists():
            return json.loads(p.read_text(encoding="utf-8"))
        r = super().post(metodo, dati)
        if r is not None:
            p.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r


def _riga(a: dict, k: int, periodo, fonte: str, oggi: str, syllabus: bool) -> dict | None:
    x = _attivita(a)
    if not x["nome"] or not x["cfu"]:  # senza CFU non è un insegnamento del piano (prove, test)
        return None
    libera = bool(_LIBERA.search(x["nome"]) or a.get("linkedGroup"))
    r = {"codice": None if libera else x["codice"], "nome": x["nome"], "anno": k, "periodo": str(periodo) if periodo else None,
         "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": not libera, "curriculum": None, "docenti": x["docenti"],
         "libri": x["libri"], "url": fonte, "esami": [], "fonte": fonte, "verificato_il": oggi}
    if syllabus:
        r["stato_libri"] = "completo" if r["libri"] else "da_aggiungere"
    return r


def _righe_anno(dati: dict, k: int, fonte: str, oggi: str, syllabus: bool) -> list[dict]:
    """Righe dell'anno `k` del regolamento (un solo percorso): una per attività, ognuna con i CFU dell'integrato."""
    righe: dict[str, dict] = {}
    for cu in dati.get("curricula") or []:
        for y in cu.get("years") or []:
            if y.get("number") != k:
                continue
            for u in y.get("units") or []:
                for a in u.get("activities") or []:
                    r = _riga(a, k, u.get("number"), fonte, oggi, syllabus)
                    if r:
                        righe.setdefault(a.get("uid") or f"{r['codice']}:{r['nome']}", r)
    return list(righe.values())


def _riga_pdf(k: int, v: tuple, fonte: str, oggi: str, syllabus: bool) -> dict:
    nome, cfu, ssd, periodo, tipo = v
    r = {"codice": None, "nome": nome, "anno": k, "periodo": periodo, "cfu": cfu, "ssd": ", ".join(sorted(set(ssd))) or None,
         "obbligatorio": tipo == "o", "curriculum": None, "docenti": [], "libri": [], "url": fonte, "esami": [],
         "fonte": fonte, "verificato_il": oggi}
    if syllabus:
        r["stato_libri"] = "da_aggiungere"
    return r


def _nomi_distinti(righe: list[dict]) -> None:
    """Righe con lo stesso nome nello stesso anno (due «Tirocinio», due «Esami a scelta»): build_db le fonderebbe per
    nome. Con CFU diversi il nome porta i CFU, altrimenti un numero (nell'ordine del piano)."""
    per_nome: dict[tuple, list[dict]] = {}
    for i in righe:
        per_nome.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
    for voci in per_nome.values():
        if len(voci) < 2:
            continue
        if len({i["cfu"] for i in voci}) == len(voci):
            for i in voci:
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        else:
            cfu_visti: dict = {}
            for i in voci:
                cfu_visti.setdefault(i["cfu"], []).append(i)
            for i in voci:
                gruppo = cfu_visti[i["cfu"]]
                suffisso = f" ({i['cfu']:g} CFU)" if len(cfu_visti) > 1 else ""
                n = f" {gruppo.index(i) + 1}" if len(gruppo) > 1 else ""
                i["nome"] = f"{i['nome']}{suffisso}{n}"


def fetch_unicamillus(uid: str = UID, anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                      corsi: list[dict] | None = None, log=print) -> dict:
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    api = _ApiCache(BASE)
    oggi = time.strftime("%Y-%m-%d")
    elenchi: dict[int, dict[str, dict]] = {}
    for a in range(anno, anno - 7, -1):  # tutti i regolamenti dell'ateneo (il corso più lungo dura 6 anni)
        els = api.post("getDepartmentsAndCourses", {"mode": "CourseDetail", "academicYear": a,
                                                    "courseTypes": ["CorsoDiStudio"]}) or {}
        elenchi[a] = {c.get("code"): c for s in els.get("data") or [] for c in s.get("courses") or []}
    log(f"[{uid}] regolamenti: " + ", ".join(f"{a}: {len(v)} corsi" for a, v in sorted(elenchi.items())))
    regs: dict[tuple, tuple | None] = {}

    def regolamento(codice: str, a: int):
        if (codice, a) not in regs:
            c = elenchi.get(a, {}).get(codice)
            dati = api.corso(c["uid"], a) if c else None
            regs[(codice, a)] = (c["uid"], dati) if dati else None
        return regs[(codice, a)]

    def build(corso: dict) -> dict | None:
        cfg = CORSI.get(str(corso.get("id_universitaly")))
        if not cfg:
            return None
        codice, durata = cfg["gomp"], corso.get("durata_anni") or 3
        righe: list[dict] = []
        fonte0 = None
        for k in range(1, durata + 1):
            # il regolamento più recente che ha l'anno k (erogato), poi il piano del regolamento didattico 2026/27
            for a in range(anno, anno - durata, -1):
                p = regolamento(codice, a)
                if not p:
                    continue
                fonte = f"{BASE}/PublicData?uid={p[0]}&mode=CourseDetail&iso=ita&academicYear={a}"
                fonte0 = fonte0 or fonte
                rk = _righe_anno(p[1], k, fonte, oggi, syllabus)
                if rk:
                    righe += rk
                    break
            else:
                pdf = PIANI_REGOLAMENTO.get(str(corso["id_universitaly"]), {}).get(k)
                if pdf:
                    righe += [_riga_pdf(k, v, pdf[0], oggi, syllabus) for v in pdf[1]]
        if not righe:
            return None
        if syllabus:  # testi mancanti nel regolamento corrente: quelli dello stesso codice nei regolamenti precedenti
            altri: dict[str, list[dict]] = {}
            for a in range(anno - 1, anno - durata, -1):
                p = regolamento(codice, a)
                for k in range(1, durata + 1) if p else ():
                    for i in _righe_anno(p[1], k, "", oggi, True):
                        if i["codice"] and i["libri"]:
                            altri.setdefault(i["codice"], i["libri"])
            for i in righe:
                if not i["libri"] and i["codice"] in altri:
                    i["libri"], i["stato_libri"] = altri[i["codice"]], "completo"
        _nomi_distinti(righe)
        out = {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
               "url": fonte0, "curricula": None, "fonte": fonte0, "verificato_il": oggi, "insegnamenti": righe}
        if cfg.get("sede"):
            out["sede"] = cfg["sede"]
        return out

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    daf = [c for c in corsi if str(c.get("id_universitaly")) in CORSI]
    if max_cds:
        daf = daf[:max_cds]
    out = []
    with cf.ThreadPoolExecutor(3) as ex:
        for r in ex.map(build_safe, daf):
            if r:
                out.append(r)
    libri = sum(len(i["libri"]) for x in out for i in x["insegnamenti"])
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti, libri: {libri}; "
        f"richieste: {api.requests}")
    return {"universita_id": uid, "descrizione": f"Generato dall'API pubblica GOMP {BASE} e dai regolamenti didattici "
                                                 f"2026/27 (adapters/unicamillus.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def fetch_ateneo(uid: str, anno: int | None = None, **kw) -> dict:
    return fetch_unicamillus(uid, anno, **kw)


if __name__ == "__main__":
    doc = fetch_unicamillus(syllabus="--senza-syllabus" not in sys.argv)
    destinazione = ROOT / "database" / "contrib" / "auto" / f"{UID}.json"
    vecchio = json.loads(destinazione.read_text(encoding="utf-8")) if destinazione.exists() else {}
    doc["appelli"] = vecchio.get("appelli") or {}
    destinazione.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"scritto {destinazione}")
