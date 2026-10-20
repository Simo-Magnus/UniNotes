"""Semestre degli insegnamenti «annuali» dall'orario pubblico EasyCourse/EasyAcademy (units, unipd, unitn, unipg).

Il Course Catalogue Cineca dà «Annualità Singola» / «Ciclo Annuale» di default anche a insegnamenti che si
tengono in un solo semestre: il semestre vero si legge nell'orario delle lezioni, pubblico e senza login:

    units  https://orari.units.it/agendaweb                       unipd  https://agendastudentiunipd.easystaff.it
    unitn  https://easyacademy.unitn.it/AgendaStudentiUnitn       unipg  https://easyacademy.unipg.it/agendaweb

`combo_call.php?sw=ec_&aa=<anno>&page=corsi` elenca corsi di studio e anni/percorsi; `grid_call.php` (POST, gli
stessi campi del modulo «Orario per corso di studio», `all_events=1`) restituisce le lezioni pubblicate di un
anno/percorso, ciascuna con `CodiceGenerale` (= campo `codice` del database), data e ora.

Regola (solo per gli insegnamenti oggi «annuale» nel database e per quelli già corretti da questo stesso
modulo, così che a febbraio una correzione sbagliata di ottobre si rivede). Per ogni codice si raccolgono le
lezioni di TUTTI i corsi di studio e canali dell'orario (non annullate, esclusi esami e prove):
- tutte entro il 31/01 -> «1»; tutte dopo il 15/02 -> «2»;
- lezioni in entrambi i periodi, o solo tra il 1/02 e il 15/02 -> resta «annuale»;
- assente dall'orario -> resta «annuale»; lo stesso se moduli o canali dello stesso codice cadono in semestri
  diversi (lezioni in entrambi i periodi);
- lezioni di una sola «parte» (nomi con «UD1», «S1», «primo semestre»: l'altra parte esce più tardi) -> resta
  «annuale» finché l'orario del percorso non copre anche l'altro periodo;
- non si toccano tirocini, prove finali e altre attività senza semestre (`periodi.NON`).
Cautela sulle ore: finché è pubblicato un solo semestre un corso davvero annuale mostra solo la prima metà delle
lezioni. Un insegnamento è quindi corretto solo se le ore pubblicate per CFU raggiungono il 20° percentile delle
ore per CFU degli insegnamenti già dati per quel semestre dal database nello stesso ateneo (come
`ec_ratio2` dell'analisi); sotto soglia resta «annuale». La soglia non vale per un percorso il cui orario copre
anche l'altro periodo (es. i corsi SSLMIT di units pubblicano l'anno intero): lì l'assenza di lezioni nell'altro
semestre è una prova.

Risultato: `database/contrib/auto/<uid>_periodo_orario_periodi.json`, stesso formato degli altri `*_periodi.json` (id,
nome, periodo, periodo_inizio/periodo_fine = prima e ultima lezione, periodo_fonte = URL pubblico dell'orario) più
`periodo_nota`. Il nome finisce in `_periodi` (build_db applica questi overlay per ultimi) e viene dopo
`<uid>_periodi.json` in ordine alfabetico, quindi l'orario vince sul Course Catalogue. Le date delle lezioni servono: pulizia.periodo dà la precedenza alle date.
Il file si riscrive per intero a ogni esecuzione (niente unione con le esecuzioni precedenti).

Uso (dalla radice del repository; 1 richiesta al secondo, ~300-900 richieste per ateneo):
    python -X utf8 tools/db_builder/adapters/periodi_easyacademy.py units,unipd,unitn,unipg
    python -X utf8 tools/db_builder/adapters/periodi_easyacademy.py unitn --prova      # non scrive, stampa i conteggi
    opzioni: --anno 2026 (a.a. 2026/27), --cache <cartella> (risposte su disco, per riprendere o ripetere),
             --ritardo 1.0 (secondi tra le richieste), --sonde 15-11-2026,15-04-2027 (date da richiedere)
poi `python -X utf8 tools/db_builder/ricostruisci.py <uid>`.

Da rifare a febbraio 2027, quando esce l'orario del 2° semestre (e di nuovo a metà marzo per i corsi pubblicati
in ritardo): lo stesso comando, senza --cache o con una cartella nuova. Dal 15/01 le sonde sono due (una nel 1°,
una nel 2° semestre): se le lezioni di un periodo non comparissero, lanciare con --sonde esplicite.
Non si aggira nessuna protezione: su 403/CAPTCHA l'esecuzione si ferma senza scrivere.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import statistics
import sys
import time
from datetime import date
from urllib.parse import unquote

import requests

if __package__ in (None, ""):  # lancio diretto: python tools/db_builder/adapters/periodi_easyacademy.py
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from adapters import periodi  # type: ignore  # noqa: E402
else:
    from . import periodi

BASI = {
    "units": "https://orari.units.it/agendaweb",
    "unipd": "https://agendastudentiunipd.easystaff.it",
    "unitn": "https://easyacademy.unitn.it/AgendaStudentiUnitn",
    "unipg": "https://easyacademy.unipg.it/agendaweb",
}
HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
NON_LEZIONE = re.compile(r"(?i)chiusura|esam|prova|laurea|tesi|sospension")
TAG = re.compile(r"<[^>]*>")
# lezioni di una sola «parte» di un insegnamento (unità didattica 1, esercitazioni S1…): l'altra parte non è ancora in orario
PARTI = re.compile(r"(?i)\bUD\s*\.?\s*\d\b|\bunit[aà] didattica\s*\d|\bS[12]\b|\b[12]\s*[°^]\s*semestre|\b(?:primo|secondo) semestre")
HREF_ATT = re.compile(r'href="(index\.php\?view=easycourse[^"]*include=attivita[^"]*)"')


def _giorno(d: str) -> str:
    """«21-09-2026» -> «2026-09-21»."""
    return f"{d[6:10]}-{d[3:5]}-{d[0:2]}"


def _it(d: str) -> str:
    """«2026-09-21» -> «21/09/2026»."""
    return f"{d[8:10]}/{d[5:7]}/{d[0:4]}"


def _ore(a: str, b: str) -> float:
    try:
        return (int(b[:2]) * 60 + int(b[3:5]) - int(a[:2]) * 60 - int(a[3:5])) / 60
    except (ValueError, TypeError):
        return 0.0


class Agenda:
    """Client dell'orario pubblico di un ateneo (al massimo una richiesta ogni `ritardo` secondi)."""

    def __init__(self, uid: str, anno: int, ritardo: float = 1.0, cache: str | None = None, log=print):
        self.uid, self.base, self.anno, self.ritardo, self.log = uid, BASI[uid], anno, ritardo, log
        self.cache = pathlib.Path(cache) if cache else None
        if self.cache:
            self.cache.mkdir(parents=True, exist_ok=True)
        self.s = requests.Session()
        self.s.headers.update(HEADERS)
        self.richieste = 0
        self._ultima = 0.0

    def _attendi(self):
        w = self._ultima + self.ritardo - time.time()
        if w > 0:
            time.sleep(w)
        self._ultima = time.time()
        self.richieste += 1

    def corsi(self) -> list[dict]:
        """[{valore, nome, anni: [valore anno/percorso]}] dell'a.a. richiesto."""
        for tentativo in range(3):
            self._attendi()
            r = self.s.get(f"{self.base}/combo_call.php", params={"sw": "ec_", "aa": self.anno, "page": "corsi"}, timeout=90)
            if r.status_code in (401, 403, 429):
                raise SystemExit(f"[{self.uid}] {r.status_code} dall'orario: mi fermo (nessuna protezione si aggira)")
            if r.ok and "elenco_corsi" in r.text:
                break
            time.sleep(5 * (tentativo + 1))
        else:
            raise SystemExit(f"[{self.uid}] elenco dei corsi dell'orario non disponibile")
        t = r.text
        j, _ = json.JSONDecoder().raw_decode(t[t.index("["):])
        out = []
        for blocco in j:
            if str(blocco.get("valore")) != str(self.anno):
                continue
            for c in blocco.get("elenco") or []:
                anni = [a["valore"] for a in c.get("elenco_anni") or [] if a.get("valore")]
                if anni:
                    out.append({"valore": c["valore"], "nome": c.get("label"), "anni": anni})
        return out

    def lezioni(self, cds: str, anno2: str, sonda: str) -> list[dict] | None:
        """Lezioni pubblicate per un corso di studio e anno/percorso: [{id, cod, data, ini, fin, link}] o None."""
        chiave = hashlib.sha1(f"v2|{self.uid}|{self.anno}|{cds}|{anno2}|{sonda}".encode()).hexdigest()
        f = self.cache / f"{self.uid}_{chiave}.json" if self.cache else None
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = {"view": "easycourse", "form-type": "corso", "include": "corso", "anno": str(self.anno), "corso": cds,
                "anno2[]": anno2, "date": sonda, "_lang": "it", "all_events": "1"}
        g = None
        for tentativo in range(3):
            self._attendi()
            try:
                r = self.s.post(f"{self.base}/grid_call.php", data=dati, timeout=90)
                if r.status_code in (401, 403, 429):
                    raise SystemExit(f"[{self.uid}] {r.status_code} dall'orario: mi fermo (nessuna protezione si aggira)")
                r.raise_for_status()
                g = r.json()
                break
            except (requests.RequestException, ValueError):
                time.sleep(5 * (tentativo + 1))
        if not isinstance(g, dict):
            return None
        out = []
        for c in g.get("celle") or []:
            cod = (c.get("CodiceGenerale") or "").strip()
            d = c.get("data") or ""
            if not cod or not re.fullmatch(r"\d{2}-\d{2}-\d{4}", d):
                continue
            if str(c.get("Annullato") or "0") != "0" or NON_LEZIONE.search(f"{c.get('tipo') or ''} {c.get('tipologia') or ''}"):
                continue
            link = None
            m = HREF_ATT.search(json.dumps(c.get("informazioni_lezione") or "", ensure_ascii=False).replace('\\"', '"'))
            if m:
                link = m.group(1)
            out.append({"id": str(c.get("id") or ""), "cod": cod, "data": _giorno(d), "ini": c.get("ora_inizio"),
                        "fin": c.get("ora_fine"), "link": link,
                        "nome": (c.get("nome_insegnamento") or c.get("titolo_lezione") or "").strip()})
        if f:
            f.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
        return out


def _link_pubblico(base: str, anno: int, rel: str | None, cds: str, anno2: str) -> str:
    """URL della pagina pubblica dell'orario: l'attività (se la cella la indica) o l'orario del corso di studio."""
    if rel:
        m = re.search(r"attivita(?:%5B%5D|\[\])=([^&]+)", rel)
        if m:
            return f"{base}/index.php?view=easycourse&_lang=it&include=attivita&anno={anno}&attivita[]={unquote(m.group(1))}"
    return f"{base}/index.php?view=easycourse&_lang=it&include=corso&anno={anno}&corso={cds}&anno2[]={anno2}"


def scansiona(uid: str, anno: int = 2026, ritardo: float = 1.0, cache: str | None = None, sonde: list[str] | None = None,
              log=print) -> dict:
    """Legge l'orario dell'ateneo. {'per_cod': {cod: {primo, ultimo, link}}, 'per_cds': {(cds, cod): {ore, primo, ultimo, intero}}}"""
    ag = Agenda(uid, anno, ritardo, cache, log)
    if not sonde:
        sonde = [f"15-11-{anno}"]
        if date.today() >= date(anno + 1, 1, 15):
            sonde.append(f"15-04-{anno + 1}")
    corsi = ag.corsi()
    lavori = [(c["valore"], a) for c in corsi for a in c["anni"]]
    log(f"[{uid}] orario a.a. {anno}/{anno + 1}: {len(corsi)} corsi di studio, {len(lavori)} anni/percorsi, sonde {sonde}")
    primo_gen = f"{anno}-08-01"
    per_cod: dict[str, dict] = {}
    per_cds: dict[tuple[str, str], dict] = {}
    visti_cds: set[tuple[str, str]] = set()
    falliti = 0
    for n, (cds, a2) in enumerate(lavori, 1):
        lez: dict[str, dict] = {}
        for sonda in sonde:
            r = ag.lezioni(cds, a2, sonda)
            if r is None:
                falliti += 1
                continue
            for x in r:
                lez[x["id"] or f"{x['cod']}|{x['data']}|{x['ini']}"] = x
        # il percorso pubblica anche l'altro periodo? (prova che l'assenza di lezioni lì è vera)
        dd = [x["data"] for x in lez.values() if x["data"] >= primo_gen]
        intero = bool(dd) and min(dd) <= f"{anno + 1}-01-31" and max(dd) > f"{anno + 1}-02-15"
        for x in lez.values():
            if x["data"] < primo_gen:
                continue
            e = per_cod.setdefault(x["cod"], {"primo": x["data"], "ultimo": x["data"], "link": None, "sedi": set(), "nomi": set()})
            e["nomi"].add(x.get("nome") or "")
            e["primo"], e["ultimo"] = min(e["primo"], x["data"]), max(e["ultimo"], x["data"])
            e["sedi"].add((cds, a2))
            if not e["link"]:
                e["link"] = _link_pubblico(ag.base, anno, x.get("link"), cds, a2)
            k = (cds, x["cod"])
            c = per_cds.setdefault(k, {"ore": 0.0, "primo": x["data"], "ultimo": x["data"], "intero": False})
            if (k, x["id"]) not in visti_cds or not x["id"]:
                c["ore"] += _ore(x["ini"] or "", x["fin"] or "")
                if x["id"]:
                    visti_cds.add((k, x["id"]))
            c["primo"], c["ultimo"] = min(c["primo"], x["data"]), max(c["ultimo"], x["data"])
            c["intero"] = c["intero"] or intero
        if n % 50 == 0:
            log(f"[{uid}]   {n}/{len(lavori)} richieste di anni/percorsi, {len(per_cod)} codici con lezioni")
    if falliti > len(lavori) * len(sonde) * 0.05:
        raise SystemExit(f"[{uid}] troppe richieste fallite ({falliti}): orario incompleto, non scrivo")
    for e in per_cod.values():
        e["sedi"] = len(e["sedi"])
    log(f"[{uid}] orario letto: {len(per_cod)} codici con lezioni, {ag.richieste} richieste, {falliti} fallite")
    return {"per_cod": per_cod, "per_cds": per_cds, "sonde": sonde}


def classifica(uid: str, orario: dict, anno: int = 2026, log=print) -> tuple[dict[str, dict], dict]:
    """Applica la regola agli insegnamenti annuali: ({id: risultato per scrivi}, statistiche)."""
    db = periodi.carica(uid)
    fine_s1, inizio_s2 = f"{anno + 1}-01-31", f"{anno + 1}-02-15"
    per_cod, per_cds = orario["per_cod"], orario["per_cds"]
    prec = _precedenti(uid)

    migliore: dict[str, dict] = {}  # il codice sta in un altro corso di studio dell'orario: il più ricco di ore
    for (_, k), x in per_cds.items():
        if k not in migliore or x["ore"] > migliore[k]["ore"]:
            migliore[k] = x

    def ore_di(cds, cod):
        return per_cds.get((cds, cod)) or migliore.get(cod)

    # soglie: 20° percentile delle ore per CFU degli insegnamenti già dati dal database per quel semestre
    rif: dict[str, list[float]] = {"1": [], "2": []}
    for c in db["corsi"]:
        for i in c.get("insegnamenti") or []:
            if i.get("periodo") in rif and i.get("cfu") and i["id"] not in prec and i.get("codice"):
                v = ore_di(c.get("codice_ateneo"), i["codice"])
                if v and v["ore"] > 0:
                    rif[i["periodo"]].append(v["ore"] / i["cfu"])
    soglia = {p: (statistics.quantiles(l, n=10)[1] if len(l) >= 20 else None) for p, l in rif.items()}
    for p in ("1", "2"):
        if soglia[p] is None:
            soglia[p] = soglia["2" if p == "1" else "1"]
    st = {"annuali": 0, "assenti": 0, "misti": 0, "sotto_soglia": 0, "cfu_mancanti": 0, "senza_semestre": 0, "in_parti": 0,
          "a1": 0, "a2": 0, "riferimenti": {p: len(l) for p, l in rif.items()}, "soglia": soglia}
    out: dict[str, dict] = {}
    oggi = date.today().strftime("%d/%m/%Y")
    for c in db["corsi"]:
        if c.get("piano_da"):
            continue
        for i in c.get("insegnamenti") or []:
            if not (i.get("periodo") == "annuale" or i["id"] in prec):
                continue
            if periodi.NON.search(i.get("nome") or ""):
                st["senza_semestre"] += 1
                continue
            st["annuali"] += 1
            e = per_cod.get((i.get("codice") or "").strip())
            if not e:
                st["assenti"] += 1
                continue
            if e["ultimo"] <= fine_s1:
                p = "1"
            elif e["primo"] > inizio_s2:
                p = "2"
            else:
                st["misti"] += 1
                continue
            v = ore_di(c.get("codice_ateneo"), i["codice"])
            if not (v and v["intero"]):  # orario di un solo periodo: le ore devono bastare per un corso di quel semestre
                if any(PARTI.search(TAG.sub("", n)) for n in e["nomi"]):  # «(UD1)», «… S1»: l'altra parte esce più tardi
                    st["in_parti"] += 1
                    continue
                cfu, s = i.get("cfu"), soglia.get(p)
                if not cfu:
                    st["cfu_mancanti"] += 1
                    continue
                if s is None or not v or v["ore"] / cfu < s:
                    st["sotto_soglia"] += 1
                    continue
            ore = round(v["ore"]) if v else None
            ore_t = f"; {ore} ore pubblicate" if ore else ""
            out[i["id"]] = {
                "periodo": p, "periodo_inizio": _it(e["primo"]), "periodo_fine": _it(e["ultimo"]), "fonte": e["link"],
                "nota": f"Orario delle lezioni pubblico (EasyCourse, a.a. {anno}/{str(anno + 1)[2:]}, letto il {oggi}): "
                        f"prima lezione {_it(e['primo'])}, ultima {_it(e['ultimo'])}, tutte nel "
                        f"{'1°' if p == '1' else '2°'} semestre{ore_t}"}
            st["a" + p] += 1
    log(f"[{uid}] {st['annuali']} insegnamenti annuali nel database: -> 1: {st['a1']}, -> 2: {st['a2']}; restano annuali: "
        f"assenti dall'orario {st['assenti']}, lezioni in entrambi i periodi {st['misti']}, ore sotto soglia {st['sotto_soglia']}, solo una parte in orario {st['in_parti']}, "
        f"senza CFU {st['cfu_mancanti']}; attività senza semestre non toccate {st['senza_semestre']}")
    return out, st


def _percorso(uid: str) -> pathlib.Path:
    return periodi.DB / "contrib" / "auto" / f"{uid}_periodo_orario_periodi.json"


def _precedenti(uid: str) -> set[str]:
    """Id già corretti da una esecuzione precedente (tornano candidati: a febbraio si rivedono)."""
    p = _percorso(uid)
    if not p.exists():
        return set()
    d = json.loads(p.read_text(encoding="utf-8"))
    return {i["id"] for c in d.get("corsi", []) for i in c.get("insegnamenti", [])}


def scrivi(uid: str, risultati: dict[str, dict]) -> int:
    """Scrive `<uid>_periodo_orario_periodi.json` (per intero) nel formato dei contributi dei periodi."""
    db = periodi.carica(uid)
    nomi = {i["id"]: i.get("nome") for c in db["corsi"] for i in c.get("insegnamenti") or []}
    corso_di = {i["id"]: c["id"] for c in db["corsi"] for i in c.get("insegnamenti") or []}
    per_corso: dict[str, list] = {}
    for iid, r in risultati.items():
        if iid not in corso_di or not r.get("fonte"):
            continue
        voce = {"id": iid, "nome": nomi[iid], "periodo": r["periodo"], "periodo_inizio": r["periodo_inizio"],
                "periodo_fine": r["periodo_fine"], "periodo_fonte": r["fonte"], "periodo_nota": r["nota"]}
        per_corso.setdefault(corso_di[iid], []).append(voce)
    doc = {"universita_id": uid, "verificato_il": date.today().isoformat(),
           "corsi": [{"id": cid, "insegnamenti": sorted(v, key=lambda x: x["id"])} for cid, v in sorted(per_corso.items())]}
    _percorso(uid).write_text(json.dumps(doc, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    return sum(len(v) for v in per_corso.values())


def fetch_periodi(uid: str, anno: int = 2026, log=print, ritardo: float = 1.0, cache: str | None = None,
                  sonde: list[str] | None = None) -> dict[str, dict]:
    """Come gli altri `periodi_<uid>.fetch_periodi`: {id: {periodo, periodo_inizio, periodo_fine, fonte, nota}}."""
    return classifica(uid, scansiona(uid, anno, ritardo, cache, sonde, log), anno, log)[0]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("atenei", help="uid separati da virgola (units, unipd, unitn, unipg)")
    ap.add_argument("--anno", type=int, default=2026)
    ap.add_argument("--cache")
    ap.add_argument("--ritardo", type=float, default=1.0)
    ap.add_argument("--sonde", help="date GG-MM-AAAA separate da virgola")
    ap.add_argument("--prova", action="store_true", help="non scrive il file")
    a = ap.parse_args(argv)
    for uid in [u for u in a.atenei.split(",") if u]:
        if uid not in BASI:
            print(f"{uid}: ateneo non gestito ({', '.join(BASI)})")
            return 2
        ris, st = classifica(uid, scansiona(uid, a.anno, a.ritardo, a.cache, a.sonde.split(",") if a.sonde else None), a.anno)
        print(f"[{uid}] soglie ore/CFU {st['soglia']} (riferimenti {st['riferimenti']})")
        if not a.prova:
            print(f"[{uid}] scritto {_percorso(uid).name}: {scrivi(uid, ris)} insegnamenti")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
