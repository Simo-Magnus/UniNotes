"""Università degli Studi «G. d'Annunzio» di Chieti-Pescara: piani di studio per coorte dal Course Catalogue Cineca.

Parte dei piani di `adapters/unich.py` (che resta responsabile di libri, syllabus e appelli). Rispetto all'adattatore
comune (`cineca_catalogue`):

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo
  anno). Se quella coorte non ha l'anno (il piano 2026 di Biotecnologie avanzate è ancora vuoto, Beni culturali non ha la
  coorte 2025) si usa la coorte più vicina che lo ha, a parità la più recente (piano ufficiale più vicino, non il futuro);
- gruppi del piano: il catalogo UdA ha solo «OO» (Obbligatori) e «NO» (A scelta), senza il numero di scelte né i CFU
  richiesti: le attività «OO» sono obbligatorie, quelle «NO» a scelta. Fa eccezione la «Prova finale» unica di un anno
  che il catalogo mette tra le scelte (Biotecnologie avanzate): è obbligatoria (deduzione, non scritta dalla fonte);
- percorsi: il percorso «CORSO GENERICO» (campo `comune` del catalogo) vale per tutti i curricula, non è un curriculum;
  i curricula sono i percorsi specifici dell'anno (almeno due) e il loro nome si ritrova nelle coorti (nome, codice senza
  anno, insegnamenti in comune);
- attività a 0 CFU (lingua latina/greca di base, prove pratiche, corsi di recupero, ADO, cicli di incontri): non sono
  insegnamenti del piano e si tolgono; i CFU mancanti si leggono, se ci sono, dallo stesso codice in un'altra coorte;
- stesso codice obbligatorio in un percorso e a scelta in un altro: due righe (build_db le tiene separate se i curricula
  sono disgiunti), altrimenti una sola, obbligatoria;
- alternative omonime nello stesso anno e curriculum: con CFU diversi il nome porta i CFU, con gli stessi CFU e lo stesso
  docente (due codici per la stessa scheda) è un insegnamento solo, altrimenti il nome porta il semestre o il codice;
- periodo: se la scheda ha più frazioni/moduli tutti nello stesso semestre, è quello.

Le richieste le fa il client di `unich` (2 al secondo, cache su disco con UN_HTTP_CACHE).
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import re
import time
import unicodedata

from . import ammissione
from . import cineca_catalogue as cc

_COMUNE = re.compile(r"(?i)\bcomune\b|\bcorso generico\b")
_PROVA_FINALE = re.compile(r"(?i)^\s*prova finale\s*$")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti: le parentesi restano."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _cod_base(cds: str | None) -> str:
    return re.sub(r"(?<=\d)R$", "", (cds or "").strip())


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo|piano)\b", " ", nome)
    return _norm(n)


def _nome_percorso(nome: str) -> str:
    n = re.sub(r"\s+", " ", nome).strip(" -:,")
    if n.isupper() and len(n) > 6:
        n = " ".join(w if re.search(r"\d", w) else w.lower() for w in n.split())
        n = n[:1].upper() + n[1:]
    return n


def _stem_percorso(cod: str | None) -> str:
    """Codice del percorso senza lo zero (A08 e A008): «A08», «A008» → «A8»."""
    return re.sub(r"^([A-Za-z]+)0*(\d+)$", r"\1\2", (cod or "").strip())


def _adcod_percorso(p: dict) -> set:
    return {t.get("adCod") for a in p.get("anni") or [] if str(a.get("anno")).isdigit()
            for g in a.get("insegnamenti") or [] for t in g.get("attivita") or [] if t.get("adCod")}


def _vale(a: dict, k: int) -> bool:
    return str(a.get("anno")).isdigit() and int(a["anno"]) == k


def _gruppi(a: dict) -> list[dict]:
    return a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])


def _cfu_anno(det: dict, k: int) -> float:
    """CFU di tutte le attività dell'anno k nel percorso più ricco (0 se l'anno non c'è)."""
    best = 0.0
    for p in det.get("percorsi") or []:
        tot = 0.0
        for a in p.get("anni") or []:
            if _vale(a, k):
                for g in _gruppi(a):
                    tot += sum(float(t.get("crediti") or 0) for t in g.get("attivita") or [])
        best = max(best, tot)
    return best


def _sede(cur: dict, cohorts: dict) -> str | None:
    """Sede del corso: dell'elenco o, se manca, l'unica «altra sede» del dettaglio della coorte più recente."""
    s = cur.get("sedeDenominazioneComune") or cur.get("sede_des_it")
    if s:
        return s
    for y in sorted(cohorts, reverse=True):
        d = cohorts[y][1]
        s = d.get("sedeDenominazioneComune") or d.get("sede_des_it")
        if s:
            return s
        altre = [x.get("sedeDenominazioneComune") or x.get("sede_des_it") for x in d.get("altreSedi") or []]
        altre = [x for x in altre if x]
        if len(altre) == 1:
            return altre[0]
    return None


def _periodo(att: dict) -> str | None:
    p = cc._periodo(att.get("periodo_didattico_it"))
    if p:
        return p
    ps = {cc._periodo(x.get("periodo_didattico_it")) for x in (att.get("frazioni") or []) + (att.get("moduli") or [])}
    ps.discard(None)
    return ps.pop() if len(ps) == 1 else None


def fetch_piani(uid: str, anno: int, c, base: str, tipi: set, log=print, max_cds: int | None = None,
                con_syllabus: bool = True) -> tuple[list[dict], dict]:
    """Piani dei corsi di studio dell'a.a. `anno` (con i syllabus da leggere): (corsi, lavori syllabus).

    `lavori`: {(aa, cod della scheda): {"params": …, "items": [insegnamenti], "codice": adCod}}."""
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in tipi]
    attuali = coorti[anno][:max_cds] if max_cds else coorti[anno]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`."""
        elenco = coorti.get(y, [])
        for x in elenco:
            if x["cdsCod"] == cur["cdsCod"]:
                return x
        for x in elenco:
            if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"]):
                return x
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        if len(stessi) == 1:
            return stessi[0]
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("tipo_corso_cod")) == chiave[::2]]
        return stessi[0] if len(stessi) == 1 else None

    corsi_out: list[dict] = []
    jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                cohorts[y] = (x, d)
        if not any(d.get("percorsi") for _, d in cohorts.values()):
            return None
        durata = int(cur.get("durataAnni") or 3)
        amm = None
        if anno in cohorts and cohorts[anno][1].get("percorsi"):  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cur.get('cod')}")

        # nome canonico dei percorsi: quello della coorte più recente che li ha (confronto con le coorti già viste)
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple[str, str, str, set]] = []  # (chiave, codice, nome canonico, codici delle attività)
        for y in sorted(cohorts, reverse=True):
            det = cohorts[y][1]
            ps = det.get("percorsi") or []
            visti = list(riferimento)
            nuovi = []
            for p in ps:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                ch = _chiave_percorso(pn)
                cod = (p.get("pdsCod") or "").strip()
                trovato = next((r for r in visti if r[0] == ch), None)
                if not trovato and not (_COMUNE.search(pn) or p.get("comune")):
                    mio = _adcod_percorso(p)
                    usati = {canon[(yy, q)] for (yy, q) in list(canon) if yy == y}
                    migliori = sorted(((len(mio & r[3]) / max(1, len(mio | r[3])), r) for r in visti
                                       if r[3] and r[2] not in usati), key=lambda t: -t[0])
                    if mio and migliori and migliori[0][0] >= 0.4 and (len(migliori) == 1 or migliori[0][0] - migliori[1][0] >= 0.1):
                        trovato = migliori[0][1]
                    if not trovato:  # nome cambiato di poco
                        simili = difflib.get_close_matches(ch, [r[0] for r in visti], n=1, cutoff=0.85)
                        trovato = next((r for r in visti if simili and r[0] == simili[0]), None)
                if not trovato:
                    trovato = (ch, cod, _nome_percorso(pn), _adcod_percorso(p))
                    nuovi.append(trovato)
                canon[(y, pn)] = trovato[2]
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            ha = {y: _cfu_anno(d, k) for y, (_, d) in cohorts.items()}
            ha = {y: v for y, v in ha.items() if v > 0}
            if not ha:
                return None
            if y0 in ha:
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        # CFU di un'attività con 0 CFU in un piano e CFU nell'altro
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        insegnamenti: dict[tuple, dict] = {}
        percorsi_nomi: set[str] = set()
        coorti_anno: dict[int, int] = {}
        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            coorti_anno[k] = scelta
            x, d = cohorts[scelta]
            percorsi_k = [p for p in d.get("percorsi") or [] if any(_vale(a, k) for a in p.get("anni") or [])]
            nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi_k}
            comuni = {n for n in nomi_k if _COMUNE.search(n) or nomi_k[n].get("comune")}
            specifici = [n for n in nomi_k if n not in comuni]
            curricula = {canon[(scelta, n)] for n in specifici} if len(specifici) >= 2 else set()
            for pnome, p in nomi_k.items():
                comune = pnome in comuni or not curricula
                pcur = None if comune else canon[(scelta, pnome)]
                for a in p.get("anni") or []:
                    if not _vale(a, k):
                        continue
                    gruppi = _gruppi(a)
                    for g in gruppi:
                        atts = g.get("attivita") or []
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            obbl = g.get("cod") == "OO" or (
                                _PROVA_FINALE.match(att.get("des_it") or "") and g.get("cod") == "NO"
                                and k == durata
                                and sum(1 for t in atts if _PROVA_FINALE.match(t.get("des_it") or "")) == 1
                                and not any(_PROVA_FINALE.match(t.get("des_it") or "")
                                            for gg in gruppi if gg is not g for t in gg.get("attivita") or []))
                            cfu = att.get("crediti") or cfu_noti.get(ad)
                            if not cfu:  # attività a 0 CFU (prove, recuperi, livelli di lingua): non è un insegnamento del piano
                                continue
                            key = (k, ad, bool(obbl))
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": _periodo(att),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": cfu, "ssd": None, "obbligatorio": bool(obbl), "curriculum": None,
                                    "_percorsi": set(), "_tutti": curricula, "docenti": sorted(set(docenti)),
                                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                }
                                insegnamenti[key] = item
                                if con_syllabus:
                                    jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                                   "af_percorso": att.get("corso_percorso_id"),
                                                   "corso_cod": att.get("corso_cod"), "corso_aa": scelta,
                                                   "schema_id": att.get("schemaId")},
                                        "items": [], "codice": ad})["items"].append(item)
                            if comune:
                                item["_comune"] = True
                            elif pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
        ins = _rifinisci(list(insegnamenti.values()))
        out = {
            "nome": cc._titolo(cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or next(
                (d.get("classe_cod") for _, d in cohorts.values() if d.get("classe_cod")), None)),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": _sede(cur, cohorts),
            "codice_ateneo": cur.get("cdsCod"),
            "url": f"{base}/corsi/{anno}/{cur.get('cod')}",
            "curricula": sorted(percorsi_nomi) or None, "ammissione": amm,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        coorte_diversa = {k: y for k, y in coorti_anno.items() if y != anno - k + 1}
        if coorte_diversa:  # anni letti da un'altra coorte (piano della coorte più vicina)
            out["anni_da_altra_coorte"] = {str(k): y for k, y in sorted(coorte_diversa.items())}
        return out

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
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(jobs)}")
    return corsi_out, jobs


def _rifinisci(items: list[dict]) -> list[dict]:
    """Curricula, alternative omonime e doppioni dello stesso insegnamento con due codici."""
    ins = items
    for i in ins:
        ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
        if i.pop("_comune", False):
            ps = set()
        if ps and ps != tutti:
            i["curriculum"] = ", ".join(sorted(ps))
    # stesso nome nello stesso anno e curriculum con codici e CFU diversi (alternative omonime): il nome porta i CFU
    per_nome: dict[tuple, list] = {}
    for i in ins:
        per_nome.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
    for gruppo in per_nome.values():
        if len({i["cfu"] for i in gruppo}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo}) > 1:
            for i in gruppo:
                if isinstance(i["cfu"], (int, float)):
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
    # stesso nome, anno e curriculum, stessi CFU, codici diversi
    per_nome2: dict[tuple, list] = {}
    for i in ins:
        per_nome2.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
    for gruppo in per_nome2.values():
        if len({i["codice"] for i in gruppo}) < 2:
            continue
        # righe dello stesso codice (obbligatorio e a scelta): non sono doppioni
        per_cod: dict[str, list] = {}
        for i in gruppo:
            per_cod.setdefault(i["codice"], []).append(i)
        if len(per_cod) < 2:
            continue
        stessi_cfu = len({i["cfu"] for i in gruppo}) == 1
        docenti = [set(i["docenti"]) for i in gruppo]
        stesso_docente = all(not d for d in docenti) or (all(d for d in docenti) and all(d == docenti[0] for d in docenti))
        if stessi_cfu and stesso_docente and len({bool(i["obbligatorio"]) for i in gruppo}) == 1:
            # due codici per la stessa scheda (stesso nome, CFU e docenti): un insegnamento solo
            tieni = min(gruppo, key=lambda i: str(i["codice"]))
            for altro in gruppo:
                if altro is tieni:
                    continue
                tieni["docenti"] = sorted(set(tieni["docenti"]) | set(altro["docenti"]))
                tieni["periodo"] = tieni["periodo"] or altro["periodo"]
                ins.remove(altro)
            continue
        periodi = [i["periodo"] for i in gruppo]
        for i in gruppo:
            if all(periodi) and len(set(periodi)) == len(periodi):
                p = str(i["periodo"])
                i["nome"] = f"{i['nome']} ({p}° semestre)" if p in ("1", "2") else f"{i['nome']} ({p})"
            else:
                i["nome"] = f"{i['nome']} ({i['codice']})"
    return ins
