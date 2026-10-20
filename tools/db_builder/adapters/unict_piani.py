"""Piani di studio dell'Università di Catania dall'API pubblica GOMP (`public.smartedu.unict.it`).

I siti dei dipartimenti (adapters/unict.py) elencano solo la didattica erogata nell'a.a. corrente: mancano i CFU, le
attività senza docente (lingua, altre conoscenze, tirocini, prova finale, crediti a scelta) e i gruppi a scelta. Il
regolamento di ogni corso è invece pubblico nell'API GOMP (la stessa di `periodi_unict` e `cfu_unict`): per ogni coorte
(a.a. di immatricolazione) dà i curricula, gli anni, i semestri e le attività con CFU e settore; i gruppi
(`linkedGroup`) elencano gli insegnamenti tra cui scegliere e i CFU da acquisire.

Come per gli altri atenei GOMP con regolamenti per coorte (vedi `gomp.ANNI_PER_COORTE`), il piano dell'anno `k` è quello
del regolamento della coorte che nell'a.a. corrente frequenta l'anno `k` (a.a. - k + 1), cercato per codice del corso e,
se il codice è cambiato con il riordino, per nome e classe; se quella coorte non esiste o non ha l'anno, si prende la
coorte più vicina che lo ha (a parità la più recente) e l'anno è segnalato come dedotto.

`integra()` parte dal contributo dei siti dei dipartimenti (docenti, link ai syllabus, libri, appelli) e lo riporta sul
piano del regolamento: le righe del piano tengono i dati della riga del dipartimento con lo stesso codice (o,
in mancanza, lo stesso nome). Le righe del dipartimento che non sono nel piano di quell'anno restano come insegnamenti a
scelta (corsi offerti ma non in regolamento) solo se né il loro codice né il loro nome sono in qualche anno del piano; le
altre sono lo stesso insegnamento del piano e si scartano. Righe fuori piano con lo stesso nome e anno sono lo stesso
insegnamento elencato più volte: una sola, con gli altri codici in `codici_alternativi`. Le attività senza crediti
(OFA, doppioni senza crediti) non sono insegnamenti del piano. Attività diverse con lo stesso nome nello stesso anno
(es. tirocinio di due semestri) si distinguono nel nome, perché build_db/pulizia unirebbero quelle con stesso nome,
anno e CFU perdendo i crediti.

Al massimo 2 richieste al secondo; cache su disco in `$UN_HTTP_CACHE/unict_gomp` (se impostata).

Uso per rielaborare un contributo già raccolto (senza rileggere syllabus e appelli):
    python -X utf8 tools/db_builder/adapters/unict_piani.py [contributo.json [uscita.json]]
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import time

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from .gomp import Api, _LIBERA, _attivita, _cfu_attivita, _ita, _nomi_distinti, _norm  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://public.smartedu.unict.it"


def anno_corrente() -> int:
    t = time.localtime()
    return t.tm_year if t.tm_mon >= 9 else t.tm_year - 1


def _cl(classi) -> set[str]:
    return {re.sub(r"\s+R$", "", x.strip()) for x in classi or []}


def _prepara(dati: dict) -> dict:
    """Un insegnamento integrato con i CFU solo nei moduli (padre senza crediti) prende la somma dei moduli."""
    def vai(a: dict) -> None:
        figli = a.get("children") or []
        if figli and not a.get("linkedGroup") and a.get("type") in (None, "activity"):
            if not sum(c.get("credits") or 0 for c in a.get("credits") or []):
                tot = sum(c.get("credits") or 0 for f in figli for c in f.get("credits") or [])
                if tot:
                    a["credits"] = [{"sector": next((c.get("sector") for f in figli for c in f.get("credits") or []
                                                     if c.get("sector")), None), "credits": tot}]
        for f in figli:
            vai(f)
    for cu in dati.get("curricula") or []:
        for y in cu.get("years") or []:
            for u in y.get("units") or []:
                for a in u.get("activities") or []:
                    vai(a)
    return dati


# Copia di gomp._righe_anno con una sola differenza (vedi `key`): le righe dei crediti liberi hanno il codice nella chiave.
def _righe_anno_unict(dati: dict, k: int) -> tuple[list[dict], set[str]]:
    """Righe dell'anno `k` del regolamento (tutti i curricula) e nomi dei curricula del regolamento.

    Un gruppo (`linkedGroup`) elenca nelle sue unità gli insegnamenti tra cui scegliere e i CFU da acquisire:
    si espande negli insegnamenti, da sostenere per intero (obbligatori) se i CFU del gruppo bastano per tutti,
    altrimenti a scelta. Un gruppo senza insegnamenti ("A scelta dello studente", "Tirocinio") resta una voce
    senza codice a scelta. Le righe hanno `_c` (curricula) e `_pc` (curricula del regolamento)."""
    curr_list = dati.get("curricula") or []
    nomi_curr = {_ita(cu.get("name")) for cu in curr_list if len(curr_list) > 1 and _ita(cu.get("name"))}
    righe: dict[str, dict] = {}
    for cu in curr_list:
        nome_c = _ita(cu.get("name")) if len(curr_list) > 1 else None
        for y in cu.get("years") or []:
            if y.get("number") != k:
                continue
            gruppi: dict[str, dict] = {}
            semplici: list[tuple[dict, int | None]] = []
            for u in y.get("units") or []:
                for a in u.get("activities") or []:
                    if a.get("linkedGroup") or a.get("type") not in (None, "activity"):
                        g = gruppi.setdefault(a.get("linkedGroup") or a.get("uid") or _ita(a.get("name")),
                                              {"a": a, "cfu": 0.0, "figli": {}, "periodo": u.get("number")})
                        g["cfu"] = max(g["cfu"], _cfu_attivita(a))
                        for f in a.get("children") or []:
                            g["figli"].setdefault(f.get("code") or _norm(_ita(f.get("name"))), (f, u.get("number")))
                    else:
                        semplici.append((a, u.get("number")))
            voci: list[tuple[dict, int | None, bool]] = [(a, n, True) for a, n in semplici]
            for g in gruppi.values():
                if g["figli"]:
                    intero = 0 < g["cfu"] and sum(_cfu_attivita(f) for f, _ in g["figli"].values()) <= g["cfu"] + 1e-9
                    voci += [(f, n, intero) for f, n in g["figli"].values()]
                else:
                    voci.append((g["a"], g["periodo"], False))
            for a, n, obb in voci:
                x = _attivita(a)
                if not x["nome"]:
                    continue
                libera = bool(_LIBERA.search(x["nome"]))
                codice = None if libera or not x["codice"] else x["codice"]
                # (a differenza di gomp: due crediti liberi con codici diversi sono due voci, es. uno per semestre)
                key = f"{k}:{codice}" if codice else (f"{k}:{x['codice']}" if x["codice"]
                                                      else f"{k}:#{_norm(x['nome'])}:{x['cfu']}")
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": codice, "nome": x["nome"], "anno": k, "periodo": str(n) if n else None,
                        "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": bool(obb and not libera), "curriculum": None,
                        "docenti": x["docenti"], "libri": x["libri"], "_c": set(), "_pc": nomi_curr,
                    }
                else:
                    item["obbligatorio"] = item["obbligatorio"] or bool(obb and not libera)
                    for d in x["docenti"]:
                        if d not in item["docenti"]:
                            item["docenti"].append(d)
                    visti = {lb["citazione"] for lb in item["libri"]}
                    item["libri"] += [lb for lb in x["libri"] if lb["citazione"] not in visti]
                    item["ssd"] = item["ssd"] or x["ssd"]
                item["_c"].add(nome_c)
    return list(righe.values()), nomi_curr


def cfu_dichiarati(dati: dict, k: int) -> float:
    """CFU dell'anno `k` dichiarati dal regolamento: attività semplici (una volta per codice) e gruppi (i CFU del gruppo,
    non quelli di tutti gli insegnamenti tra cui scegliere); per più curricula vale il più alto."""
    migliore = 0.0
    for cu in dati.get("curricula") or []:
        visti: dict[str, float] = {}
        for y in cu.get("years") or []:
            if y.get("number") != k:
                continue
            for u in y.get("units") or []:
                for a in u.get("activities") or []:
                    chiave = ("g:" + str(a.get("linkedGroup"))) if a.get("linkedGroup") else str(a.get("code") or a.get("uid")
                                                                                              or _norm(_ita(a.get("name"))))
                    cfu = sum(c.get("credits") or 0 for c in a.get("credits") or [])
                    if not cfu and a.get("children") and not a.get("linkedGroup"):
                        cfu = sum(c.get("credits") or 0 for f in a["children"] for c in f.get("credits") or [])
                    visti[chiave] = max(visti.get(chiave, 0.0), float(cfu))
        migliore = max(migliore, sum(visti.values()))
    return migliore


class Gomp:
    def __init__(self, anno: int, log=print):
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = (pathlib.Path(d) / "unict_gomp") if d else None
        if self.cache:
            self.cache.mkdir(parents=True, exist_ok=True)
        self.api = Api(BASE, rate=2.0)
        self.anno, self.log = anno, log
        self.elenchi: dict[int, list[dict]] = {}
        self.piani: dict[tuple[str, int], dict | None] = {}

    def _cached(self, nome: str, produci):
        f = self.cache / nome if self.cache else None
        if f and f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        r = produci()
        if f and r is not None:
            f.write_text(json.dumps(r, ensure_ascii=False), encoding="utf-8")
        return r

    def elenco(self, aa: int) -> list[dict]:
        if aa not in self.elenchi:
            def lista():
                r = self.api.post("getDepartmentsAndCourses",
                                  {"mode": "CourseDetail", "academicYear": aa, "courseTypes": ["CorsoDiStudio"]})
                return [{"uid": c["uid"], "code": c.get("code"), "ita": _ita(c.get("name")), "classes": c.get("classes") or [],
                         "years": c.get("years"),
                         "eng": " ".join(t.get("text") or "" for t in c.get("name") or [] if t.get("iso") == "eng")}
                        for s in (r or {}).get("data") or [] for c in s.get("courses") or []] if r else None
            self.elenchi[aa] = self._cached(f"elenco_{aa}.json", lista) or []
        return self.elenchi[aa]

    def piano(self, uid: str, aa: int) -> dict | None:
        if (uid, aa) not in self.piani:
            self.piani[(uid, aa)] = self._cached(f"c_{uid}_{aa}.json", lambda: self.api.corso(uid, aa))
        return self.piani[(uid, aa)]

    def abbina(self, corso: dict, aa: int, codice: str | None = None) -> dict | None:
        """Corso GOMP dell'a.a. `aa` che corrisponde al corso del database: per codice (se dato), poi per nome
        italiano e classe, poi per nome inglese e classe."""
        el = self.elenco(aa)
        if codice:
            per_codice = [g for g in el if g["code"] == codice]
            if len(per_codice) == 1:
                return per_codice[0]
            if per_codice:
                el = per_codice
        n, ne = _norm(corso["nome"]), _norm(corso.get("nome_en") or corso["nome"])
        cl = _cl((corso.get("classe") or "").split("/"))
        for cand in ([g for g in el if _norm(g["ita"]) == n], [g for g in el if _norm(g["eng"]) == ne]):
            if not cand:
                continue
            giuste = [g for g in cand if _cl(g["classes"]) & cl] or ([] if codice else cand)
            if giuste:
                esatte = [g for g in giuste if _cl(g["classes"]) == cl]
                return (esatte or giuste)[0]
        return None


def piano_corso(corso: dict, g: Gomp) -> dict | None:
    """Righe del piano del corso (tutti gli anni) con l'elenco degli anni dedotti da una coorte diversa."""
    anno = g.anno
    durata = corso.get("durata_anni") or 3
    base = g.abbina(corso, anno)
    if not base:
        return None
    righe: list[dict] = []
    curricula: set[str] = set()
    fonti: dict[int, tuple[int, str, bool, float]] = {}
    for k in range(1, durata + 1):
        coorti = sorted(range(anno - durata + 1, anno + 1), key=lambda a: (abs(a - (anno - k + 1)), -a))
        for a in coorti:
            gc = base if a == anno else g.abbina(corso, a, base.get("code"))
            if not gc:
                continue
            dati = g.piano(gc["uid"], a)
            if not dati:
                continue
            rk, nomi = _righe_anno_unict(_prepara(dati), k)
            if not rk:
                continue
            fonte = f"{BASE}/PublicData?uid={gc['uid']}&mode=CourseDetail&iso=ita&academicYear={a}"
            for i in rk:
                cs, pc = i.pop("_c"), i.pop("_pc")
                if None not in cs and pc and cs != pc:
                    i["curriculum"] = ", ".join(sorted(c for c in cs if c))
                i.update({"url": fonte, "esami": [], "fonte": fonte})
            curricula |= nomi
            righe += rk
            fonti[k] = (a, fonte, a == anno - k + 1, cfu_dichiarati(dati, k))
            break
    if not righe:
        return None
    for i in righe:
        if re.search(r"\s[iI]$", i["nome"]) and i["nome"].upper() != i["nome"]:
            i["nome"] = i["nome"][:-1] + "I"
    # attività senza crediti: gli obblighi formativi aggiuntivi (OFA) non sono insegnamenti del piano (stanno
    # nei requisiti di accesso) e una voce senza crediti con lo stesso nome di un'altra dello stesso anno è un doppione
    con_cfu = {(i["anno"], _norm(i["nome"])) for i in righe if i["cfu"]}
    righe = [i for i in righe if i["cfu"] or not (re.search(r"(?i)\bofa\b", i["nome"])
                                                   or (i["anno"], _norm(i["nome"])) in con_cfu)]
    for i in righe:
        i["_n0"] = i["nome"]
    _nomi_distinti(righe)
    _distingui_omonimi(righe)
    return {"righe": righe, "curricula": sorted(curricula) if len(curricula) > 1 else None, "fonti": fonti,
            "fonte": f"{BASE}/PublicData?uid={base['uid']}&mode=CourseDetail&iso=ita&academicYear={anno}"}


def _distingui_omonimi(righe: list[dict]) -> None:
    """Attività diverse dello stesso piano (codici diversi) con lo stesso nome nello stesso anno e nello stesso
    curriculum (es. «Tirocinio professionalizzante III anno» in due semestri): build_db/pulizia unirebbero le righe con
    lo stesso nome, anno e CFU perdendo i crediti; si distinguono per semestre o con un numero."""
    gruppi: dict[tuple, list[dict]] = {}
    for i in righe:
        if i["codice"]:
            gruppi.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
    for voci in gruppi.values():
        if len({i["codice"] for i in voci}) < 2:
            continue
        # righe di curricula diversi non coesistono nello stesso piano: restano com'è
        coesistono = [i for i in voci if not i["curriculum"]] or []
        if len(coesistono) < 2:
            per_curr: dict[str, list[dict]] = {}
            for i in voci:
                for cu in (i["curriculum"] or "").split(", "):
                    per_curr.setdefault(cu, []).append(i)
            comuni = [v for v in per_curr.values() if len({i["codice"] for i in v}) > 1]
            if not comuni:
                continue
            coesistono = max(comuni, key=len)
        periodi = [i["periodo"] for i in coesistono]
        cfus = [i["cfu"] for i in coesistono]
        for n, i in enumerate(sorted(coesistono, key=lambda i: (i["periodo"] or "", i["codice"])), 1):
            if len(set(periodi)) == len(periodi) and i["periodo"]:
                i["nome"] = f"{i['nome']} ({i['periodo']}° semestre)"
            elif len(set(cfus)) == len(cfus) and i["cfu"]:
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
            else:
                i["nome"] = f"{i['nome']} {n}"


def _chiave(nome: str) -> str:
    return _norm(re.sub(r"\(.*?\)", " ", nome or ""))


def integra(out: list[dict], corsi: list[dict], g: Gomp, log=print) -> dict:
    """Sostituisce, nei corsi di `out` (contributo dei dipartimenti), il piano con quello del regolamento GOMP.

    Restituisce un riepilogo: corsi senza piano GOMP, anni dedotti, righe del dipartimento scartate."""
    oggi = time.strftime("%Y-%m-%d")
    per_id = {c["id"]: c for c in out}
    rapporto = {"senza_piano": [], "anni_dedotti": {}, "scartate": {}, "a_scelta_dip": {}}
    nuovi = []
    for corso in corsi:
        dip = per_id.get(corso["id"])
        p = piano_corso(corso, g)
        if not p:
            rapporto["senza_piano"].append(corso["id"])
            if dip:
                nuovi.append(dip)
            continue
        righe = p["righe"]
        dip_righe = list((dip or {}).get("insegnamenti") or [])
        per_codice: dict[str, list[dict]] = {}
        per_nome: dict[str, list[dict]] = {}
        for d in dip_righe:
            if d.get("codice"):
                per_codice.setdefault(str(d["codice"]), []).append(d)
            per_nome.setdefault(_chiave(d["nome"]), []).append(d)
        usate: set[int] = set()
        for r in righe:
            cand = per_codice.get(str(r["codice"])) if r["codice"] else None
            if not cand:
                cand = per_nome.get(_chiave(r["nome"])) if r["codice"] else None
            if not cand:
                continue
            cand = sorted(cand, key=lambda d: (d.get("anno") != r["anno"], id(d)))
            d0 = cand[0]
            for d in cand:
                usate.add(id(d))
            if d0.get("codice") == r["codice"] and r["nome"] == r["_n0"]:  # (non se il nome è stato distinto dagli omonimi)
                r["nome"] = d0["nome"]
            r["docenti"] = sorted({x for d in cand for x in d.get("docenti") or []} | set(r.get("docenti") or []))
            r["url"] = next((d["url"] for d in cand if d.get("url")), r["url"])
            visti = {lb["citazione"] for lb in r["libri"]}
            for d in cand:
                for lb in d.get("libri") or []:
                    if lb["citazione"] not in visti:
                        visti.add(lb["citazione"])
                        r["libri"].append(lb)
                r["esami"] += [e for e in d.get("esami") or [] if e not in r["esami"]]
        codici_piano = {str(r["codice"]) for r in righe if r["codice"]}
        nomi_piano = {_chiave(r["nome"]) for r in righe}
        scartate = []
        extra = []
        for d in dip_righe:
            if id(d) in usate:
                continue
            if (d.get("codice") and str(d["codice"]) in codici_piano) or _chiave(d["nome"]) in nomi_piano:
                scartate.append(d)  # stesso insegnamento del piano in un altro anno/canale: già unito o fuori coorte
            else:
                extra.append(d)
        # righe del dipartimento fuori dal piano con lo stesso nome nello stesso anno: lo stesso insegnamento elencato più
        # volte con codici diversi; si tiene la prima e le altre diventano codici alternativi
        per_chiave: dict[tuple, dict] = {}
        for d in list(extra):
            prima = per_chiave.setdefault((d.get("anno"), _chiave(d["nome"])), d)
            if prima is d:
                continue
            extra.remove(d)
            prima.setdefault("codici_alternativi", [])
            if d.get("codice") and d["codice"] != prima.get("codice"):
                prima["codici_alternativi"].append(d["codice"])
            prima["docenti"] = sorted(set(prima.get("docenti") or []) | set(d.get("docenti") or []))
            visti = {lb["citazione"] for lb in prima.get("libri") or []}
            prima.setdefault("libri", []).extend(lb for lb in d.get("libri") or [] if lb["citazione"] not in visti)
            scartate.append(d)
        for d in extra:
            if not d.get("codici_alternativi"):
                d.pop("codici_alternativi", None)
        for r in righe:
            r.pop("_n0", None)
            r["verificato_il"] = oggi
            r["stato_libri"] = "completo" if r["libri"] else "da_aggiungere"
        for d in extra:
            d["obbligatorio"] = False
        rapporto["scartate"][corso["id"]] = [(d.get("codice"), d["nome"], d.get("anno")) for d in scartate]
        rapporto["a_scelta_dip"][corso["id"]] = [(d.get("codice"), d["nome"], d.get("anno")) for d in extra]
        rapporto["anni_dedotti"][corso["id"]] = {k: v[0] for k, v in p["fonti"].items() if not v[2]}
        rapporto.setdefault("dichiarati", {})[corso["id"]] = {k: [v[3], v[0], v[1]] for k, v in p["fonti"].items()}
        nuovi.append({"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
                      "durata_anni": corso.get("durata_anni"), "url": (dip or {}).get("url") or p["fonte"],
                      "curricula": p["curricula"], "fonte": p["fonte"], "verificato_il": oggi,
                      "insegnamenti": righe + extra})
    out[:] = nuovi
    log(f"[unict] piani GOMP: {len(nuovi) - len(rapporto['senza_piano'])} corsi, senza piano {len(rapporto['senza_piano'])}; "
        f"richieste {g.api.requests}")
    return rapporto


def main(argv: list[str]) -> None:
    """Applica il piano GOMP a un contributo dei dipartimenti già raccolto (default: contrib/auto/unict.json)."""
    p = pathlib.Path(argv[0]) if argv else ROOT / "database" / "contrib" / "auto" / "unict.json"
    dest = pathlib.Path(argv[1]) if len(argv) > 1 else p
    doc = json.loads(p.read_text(encoding="utf-8"))
    corsi = json.loads((ROOT / "database" / "corsi" / "unict.json").read_text(encoding="utf-8"))["corsi"]
    rap = integra(doc["corsi"], corsi, Gomp(anno_corrente()))
    dest.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    if os.environ.get("UNICT_RAPPORTO"):  # fuori da database/contrib, dove ogni .json è un contributo
        pathlib.Path(os.environ["UNICT_RAPPORTO"]).write_text(json.dumps(rap, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1:])
