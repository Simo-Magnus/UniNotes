"""Costruisce database/corsi/<ateneo>.json, indice_corsi.json e meta.json.

Input:
- database/universita.json                (da parse_mur.py)
- data/raw/universitaly/corsi.json.gz     (da fetch_universitaly.py)
- database/contrib/*.json                 (insegnamenti, libri ed esami
                                           raccolti a mano, dagli adattatori per
                                           ateneo o dalle segnalazioni degli utenti)
- database/corsi/*.json esistenti         (si conservano insegnamenti e dati già
                                           raccolti per i corsi che restano attivi)

Regole: un dato mancante resta null / "da_aggiungere"; non si inventa nulla.

Uso:
    python tools/db_builder/build_db.py                # tutti gli atenei
    python tools/db_builder/build_db.py --solo unibo   # solo questi: gli altri file, le
        # loro voci in meta.json e in indice_corsi.json restano come sono (utile in locale,
        # dove mancano i contributi automatici database/contrib/auto degli altri atenei)
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import pathlib
import html
import re
import sys
import unicodedata
from collections import defaultdict
from datetime import date, datetime, timezone

import pulizia

ROOT = pathlib.Path(__file__).resolve().parents[2]
DB = ROOT / "database"
RAW = ROOT / "data" / "raw" / "universitaly" / "corsi.json.gz"
REPORT = ROOT / "data" / "raw" / "universitaly" / "non_associati.json"

STOP = {"universita", "degli", "studi", "di", "del", "della", "dell", "dei", "delle", "e", "the", "of",
        "telematica", "statale", "libera", "internazionale", "s", "l", "a", "per", "in", "ateneo", "alma",
        "mater", "studiorum", "university", "universitas", "istituto", "scuola", "superiore", "sede"}

# codeUn Universitaly (codice MUR dell'ateneo) -> id del database, quando il nome
# non basta a riconoscerlo. Si completa leggendo non_associati.json.
CODE_OVERRIDES: dict[str, str] = {}

NAME_OVERRIDES = {
    "alma mater studiorum universita di bologna": "unibo",
    "universita degli studi di milano bicocca": "unimib",
    "universita degli studi di milano": "unimi",
    "politecnico di milano": "polimi",
    "politecnico di torino": "polito",
    "politecnico di bari": "poliba",
    "universita degli studi di torino": "unito",
    "universita degli studi di roma la sapienza": "uniroma1",
    "universita degli studi di roma tor vergata": "uniroma2",
    "universita degli studi roma tre": "uniroma3",
    "universita degli studi di roma foro italico": "uniroma4",
    "universita degli studi di napoli federico ii": "unina",
    "universita degli studi di napoli l orientale": "unior",
    "universita degli studi di napoli parthenope": "uniparthenope",
    "universita degli studi della campania luigi vanvitelli": "unicampania",
    "universita telematica san raffaele roma": "uniroma5",
    "universita vita salute san raffaele": "unisr",
    "universita per stranieri di siena": "unistrasi",
    "universita per stranieri di perugia": "unistrapg",
    "universita degli studi di siena": "unisi",
    "universita degli studi di perugia": "unipg",
    "universita degli studi dell aquila": "univaq",
    "universita degli studi di roma unitelmasapienza": "unitelma",
}


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def slug(s: str, maxlen: int = 60) -> str:
    return norm(s).replace(" ", "-")[:maxlen].strip("-")


def tokens(s: str) -> set[str]:
    return {t for t in norm(s).split() if t not in STOP and len(t) > 1}


class Matcher:
    def __init__(self, unis: list[dict]):
        self.unis = unis
        self.index = []
        for u in unis:
            names = {u["nome"], u["sigla"]} | {s.get("nome_mur") or "" for s in u["sedi"]}
            for n in names:
                if n:
                    self.index.append((tokens(n), u["id"]))
        self.cache: dict[tuple[str, str], str | None] = {}

    def match(self, nome: str, code: str) -> str | None:
        key = (nome, code)
        if key in self.cache:
            return self.cache[key]
        res = CODE_OVERRIDES.get(code) or NAME_OVERRIDES.get(norm(nome))
        if not res:
            t = tokens(nome)
            best, score = None, 0.0
            for toks, uid in self.index:
                if not toks:
                    continue
                j = len(t & toks) / len(t | toks)
                if j > score:
                    best, score = uid, j
            res = best if score >= 0.5 else None
        self.cache[key] = res
        return res


def tipo_corso(c: dict) -> str:
    d = norm((c.get("tipoLaurea") or {}).get("descrizione") or "")
    classe = ((c.get("classe") or {}).get("codice") or "").strip()
    if classe.startswith("L-P"):
        return "LP"
    if "ciclo unico" in d or "unico" in d:
        return "LMCU"
    if "magistrale" in d:
        return "LM"
    if "triennale" in d or d == "laurea":
        return "L"
    return "altro"


LINGUA = {"IT": "it", "EN": "en", "MU": "it/en"}


def corso_da_universitaly(c: dict, uid: str) -> dict:
    classe = ((c.get("classe") or {}).get("codice") or "").strip() or None
    inter = ((c.get("classeInterclasse") or {}) or {}).get("codice")
    sede = c.get("sede")
    if isinstance(sede, dict):
        sede = sede.get("comuneDescrizione") or None
    return {
        "id": None,  # assegnato dopo, gestendo i doppioni
        "id_universitaly": str(c["id"]),
        # Universitaly a volte lascia entità HTML e caratteri invisibili nel nome («nutraceutici&#8203;»)
        "nome": re.sub(r"\s+", " ", re.sub(r"[\u200b-\u200d\ufeff]", "", html.unescape(c.get("nomeCorso") or ""))).strip(),
        "nome_en": (c.get("nomeCorsoEn") or "").strip() or None,
        "tipo": tipo_corso(c),
        "classe": classe + (f" / {inter.strip()}" if inter else "") if classe else None,
        "durata_anni": int(c["durataAnni"]) if str(c.get("durataAnni") or "").isdigit() else None,
        "sede": sede,
        "lingua": LINGUA.get(str(c.get("lingua") or "").upper()),
        "accesso": {"Libero": "libero"}.get(((c.get("programmazione") or {}).get("descrizione") or ""), "programmato")
        if c.get("programmazione") else None,
        "erogazione": ((c.get("modalitaErogazione") or {}).get("descrizione")),
        "interateneo": bool(c.get("interateneo")),
        "url": (c.get("url") or "").strip() or None,
        "stato": "da_aggiungere",
        "fonte": "https://www.universitaly.it/cerca-corsi",
        "verificato_il": date.today().isoformat(),
        "insegnamenti": [],
    }


def classe_base(c: str | None) -> set[str]:
    """'LM-77 / LM-16' -> {'LM-77','LM-16'}; 'L-25 R' -> {'L-25'}; 'L/SNT1' -> {'L/SNT1'}."""
    out = set()
    for part in re.split(r"\s*/\s*(?=L)|,|&", c or ""):
        part = re.sub(r"\s+R$", "", part.strip().upper().replace(" ", ""))
        part = part.replace("C.U.", "").replace("CU", "")
        if part:
            out.add(part)
    return out


def tipo_da_classe(classe: str | None, tipo_catalogo: str | None = None) -> str:
    c = (classe or "").upper()
    t = (tipo_catalogo or "").upper()
    if c.startswith("L-P"):
        return "LP"
    if t in ("LM5", "LM6", "LMCU", "CU") or c in {"LMG/01", "LM-41", "LM-42", "LM-46", "LM-13", "LM-85BIS", "LM-4C.U."}:
        return "LMCU"
    if c.startswith("LM") or t == "LM":
        return "LM"
    if c.startswith("L") or t == "L":
        return "L"
    return "altro"


def trova_corso(corsi: list[dict], cc: dict) -> dict | None:
    """Associa un corso dei contributi a quello di Universitaly: id, id Universitaly,
    poi nome + classe, poi solo nome o sola classe se univoci."""
    for c in corsi:
        if cc.get("id") and c["id"] == cc["id"]:
            return c
        if cc.get("id_universitaly") and c.get("id_universitaly") == str(cc["id_universitaly"]):
            return c
    def norm_nome(s: str) -> str:
        # l'apostrofo tipografico (’) si perde in norm(): "l’interculturalità" -> "linterculturalita"
        s = re.sub(r"[’‘`´]", "'", s or "")
        # nei cataloghi: "Corso di Laurea Magistrale (a ciclo unico) in Psicologia" -> "Psicologia"
        s = re.sub(r"(?i)^\s*corso di laurea(?: magistrale)?(?: a ciclo unico)?\s+in\s+", "", s)
        return norm(s)

    nome = norm_nome(cc.get("nome"))
    cl = classe_base(cc.get("classe"))
    same_name = [c for c in corsi if nome in (norm_nome(c["nome"]), norm_nome(c.get("nome_en")))]
    both = [c for c in same_name if not cl or classe_base(c.get("classe")) & cl]
    if cc.get("sede") and len(both) > 1:
        sede = norm(cc["sede"]).split()[0] if norm(cc["sede"]) else ""
        both = [c for c in both if sede and sede in norm(c.get("sede") or "")] or both
    if both:
        return both[0]
    if len(same_name) == 1:
        return same_name[0]
    if cl:
        same_cl = [c for c in corsi if classe_base(c.get("classe")) & cl and
                   (cc.get("durata_anni") in (None, c.get("durata_anni")))]
        toks = set(nome.split())
        same_cl = [c for c in same_cl if len(toks & set(norm(c["nome"]).split())) >= max(1, len(toks) // 2)]
        if len(same_cl) == 1:
            return same_cl[0]
    return None


def load_json(p: pathlib.Path, default):
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else default


def write_json(p: pathlib.Path, data) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def _docenti_in_comune(docenti: list[str], esami: list[dict]) -> bool:
    """Almeno un cognome (parola di 3+ lettere) dei docenti dell'insegnamento negli appelli."""
    parole = {w for d in docenti for w in norm(d).split() if len(w) >= 3}
    return bool(parole & {w for e in esami for w in norm(e.get("docenti") or "").split() if len(w) >= 3})


def stato_corso(c: dict) -> str:
    ins = c.get("insegnamenti") or []
    if not ins:
        return "da_aggiungere"
    anni = {i.get("anno") for i in ins}
    completo = c.get("durata_anni") and len(anni) >= c["durata_anni"] and all(
        i.get("stato_libri") in ("completo", "nessun_libro") for i in ins)
    return "completo" if completo else "parziale"


def _unisci_stesso_anno(base: dict, altro: dict) -> None:
    """Stesso codice due volte nello stesso anno del piano (una riga per percorso):
    un solo insegnamento, con i percorsi, i docenti, i libri e gli appelli di entrambe."""
    base["curriculum"] = pulizia._unisci_percorsi(base.get("curriculum"), altro.get("curriculum"))
    if base.get("obbligatorio") is False and altro.get("obbligatorio"):
        base["obbligatorio"] = True
    for k in ("docenti", "libri", "esami"):
        for x in altro.get(k) or []:
            if x not in (base.get(k) or []):
                base.setdefault(k, []).append(x)
    for k, v in altro.items():
        if base.get(k) in (None, "", []) and v not in (None, "", []):
            base[k] = v


def _a_scelta(i: dict) -> bool:
    return i.get("obbligatorio") is False  # (come controllo_cfu e l'app: senza indicazione è obbligatorio)


def _stessa_riga(a: dict, b: dict) -> bool:
    """Due righe con lo stesso codice nello stesso anno sono un solo insegnamento, salvo
    quando è obbligatorio in un percorso e a scelta in un altro (percorsi indicati e
    disgiunti, es. UniCAS «Complementi di costruzione di strade» obbligatorio in LM-23 e a
    scelta in LM-35): un solo `obbligatorio` non vale per entrambi, quindi una riga per
    ciascuno con i suoi percorsi (l'app filtra le righe per percorso)."""
    if _a_scelta(a) == _a_scelta(b):
        return True
    pa, pb = set(pulizia.percorsi(a.get("curriculum"))), set(pulizia.percorsi(b.get("curriculum")))
    return not pa or not pb or bool(pa & pb)


def assegna_id(corso_id: str, items: list[dict]) -> list[dict]:
    """id degli insegnamenti di un contributo: `<corso>-<slug del codice o del nome>`.
    Lo stesso codice ripetuto nel piano è un solo insegnamento se è nello stesso anno
    (righe di percorsi diversi: i percorsi si uniscono) e insegnamenti diversi se è in
    anni diversi (es. PoliTO, «Fondamenti di biologia, anatomia e fisiologia» al 1° anno
    a Torino e al 2° per chi fa il primo anno a Mondovì): l'anno più basso tiene l'id,
    gli altri hanno `-a<anno>`. Prima l'ultima riga sovrascriveva le altre.
    Vale anche per gli insegnamenti a scelta offerti in più anni (es. «Diritto tributario»
    a scelta al 1°, 2° e 3° anno): prima restavano solo nel primo anno e gli anni successivi
    sembravano più poveri; ora compaiono in ogni anno in cui la fonte li elenca.
    Nello stesso anno, obbligatorio in un percorso e a scelta in un altro (vedi
    `_stessa_riga`): la prima riga della fonte tiene l'id, l'altra ha `-obbl` o `-scelta`."""
    out: list[dict] = []
    gruppi: dict[str, dict] = {}
    for i in items:
        i = dict(i)
        if "id" in i:  # (i contributi dei periodi hanno già l'id e non il nome)
            out.append(i)
            continue
        base = f"{corso_id}-{slug(i.get('codice') or i['nome'], 40)}"
        righe = gruppi.setdefault(base, {}).setdefault(i.get("anno"), [])
        prima = next((r for r in righe if _a_scelta(r) == _a_scelta(i)), None) or \
            next((r for r in righe if _stessa_riga(r, i)), None)
        if prima:
            _unisci_stesso_anno(prima, i)
        else:
            righe.append(i)
    for base, per_anno in gruppi.items():
        anni = sorted(per_anno, key=lambda a: (not isinstance(a, int), a if isinstance(a, int) else 0))
        tenuti: list[dict] = []
        for a in anni:
            if not isinstance(a, int) and tenuti:
                # anno non indicato: è lo stesso insegnamento di un anno del piano
                for i in per_anno[a]:
                    _unisci_stesso_anno(tenuti[0], i)
                continue
            id_anno = base if not tenuti else f"{base}-a{a if isinstance(a, int) else 'x'}"
            for k, i in enumerate(per_anno[a]):
                i["id"] = id_anno if not k else f"{id_anno}-{'scelta' if _a_scelta(i) else 'obbl'}"
                tenuti.append(i)
        out.extend(tenuti)
    return out


_COPIA = re.compile(r"(-a(\d+|x))?(-(scelta|obbl))?$")


def libri_delle_copie(c: dict) -> int:
    """Le righe che `assegna_id` crea per lo stesso codice (stessa scelta in un altro anno,
    `-a<anno>`, o riga per i percorsi con l'altro `obbligatorio`, `-obbl`/`-scelta`) sono lo
    stesso insegnamento della fonte: senza libri propri prendono quelli della riga del
    codice (i programmi raccolti per id arrivano solo su quella). Non per gli obbligatori
    in anni diversi (es. PoliTO a Mondovì), che restano insegnamenti distinti.
    Restituisce il numero di righe completate."""
    per_id = {i["id"]: i for i in c.get("insegnamenti") or []}
    n = 0
    for i in per_id.values():
        if i.get("libri") or i.get("stato_libri") == "nessun_libro" or not i.get("codice"):
            continue
        m = _COPIA.search(i["id"])
        cand = [i["id"][:m.start(3)] if m.group(3) and m.group(1) else None, i["id"][:m.start()]]
        for b in (per_id.get(x) for x in cand if x and x != i["id"]):
            if not b or b.get("codice") != i.get("codice") or not b.get("libri"):
                continue
            if b.get("anno") != i.get("anno") and not (_a_scelta(b) and _a_scelta(i)):
                continue
            i["libri"] = json.loads(json.dumps(b["libri"]))
            i["stato_libri"] = b.get("stato_libri") or "completo"
            n += 1
            break
    return n


# Dove stanno nel piano: li decide il contributo (anche quando li toglie, es. un
# percorso che diventa comune a tutti), non la copia precedente del database.
_STRUTTURA = ("anno", "periodo", "curriculum", "obbligatorio")


def merge_insegnamenti(old: list[dict], new: list[dict]) -> list[dict]:
    """Unisce per id: i campi non nulli del nuovo vincono, libri ed esami si uniscono.
    Per un insegnamento completo del contributo (con il nome) anno, periodo, percorso e
    obbligatorietà sono sempre quelli del contributo."""
    by_id = {i["id"]: dict(i) for i in old}
    for n in new:
        cur = by_id.get(n["id"])
        if not cur:
            by_id[n["id"]] = n
            continue
        if n.get("nome"):
            for k in _STRUTTURA:
                if k in n:
                    cur[k] = n[k]
        for k, v in n.items():
            if k in ("libri", "esami"):
                seen = {json.dumps(x, sort_keys=True) for x in cur.get(k) or []}
                cur[k] = (cur.get(k) or []) + [x for x in v or [] if json.dumps(x, sort_keys=True) not in seen]
            elif v not in (None, "", []):
                cur[k] = v
    out = list(by_id.values())
    for i in out:
        i.setdefault("libri", [])
        i.setdefault("esami", [])
        i.setdefault("stato_libri", "completo" if i["libri"] else "da_aggiungere")
        i.setdefault("stato_esami", "completo" if i["esami"] else "da_aggiungere")
    return sorted(out, key=lambda i: (i.get("anno") or 99, str(i.get("periodo") or ""), i.get("nome") or ""))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--solo", help="id atenei separati da virgola: ricostruisce solo questi")
    solo = set((ap.parse_args().solo or "").split(",")) - {""}
    unis = load_json(DB / "universita.json", None)
    if not unis:
        raise SystemExit("Manca database/universita.json: eseguire parse_mur.py")
    if not RAW.exists():
        raise SystemExit(f"Manca {RAW}: eseguire fetch_universitaly.py")
    with gzip.open(RAW, "rt", encoding="utf-8") as f:
        raw = json.load(f)
    matcher = Matcher(unis["universita"])
    anno_acc = None
    per_uni: dict[str, list[dict]] = defaultdict(list)
    unmatched: dict[str, dict] = {}
    for c in raw["corsi"]:
        anno_acc = anno_acc or ((c.get("anno") or {}).get("descrizione") or "").replace("/20", "/")
        uid = matcher.match(c.get("nomeStruttura") or "", str(c.get("codeUn") or ""))
        if not uid:
            u = unmatched.setdefault(c.get("nomeStruttura") or "?", {"codeUn": c.get("codeUn"), "corsi": 0})
            u["corsi"] += 1
            continue
        per_uni[uid].append(corso_da_universitaly(c, uid))
    if not anno_acc:
        anno_acc = f"{date.today().year}/{(date.today().year + 1) % 100:02d}" if date.today().month >= 9 else \
            f"{date.today().year - 1}/{date.today().year % 100:02d}"

    contrib = defaultdict(list)  # (uid, corso_id|id_universitaly) -> insegnamenti
    contrib_corsi = defaultdict(list)
    appelli: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    # gli overlay dei periodi (`<uid>_periodi.json`) per ultimi: un contributo completo che viene dopo
    # in ordine alfabetico (`<uid>_piani.json`) riscrive il periodo anche quando non lo conosce
    for p in sorted((DB / "contrib").rglob("*.json"), key=lambda p: (p.stem.endswith("_periodi"), str(p))):
        data = load_json(p, {})
        for corso in data.get("corsi", []):
            contrib_corsi[data["universita_id"]].append(corso)
        for cod, lst in (data.get("appelli") or {}).items():
            appelli[data["universita_id"]][cod].extend(lst)

    indice, meta_atenei = [], {}
    old_meta = load_json(DB / "meta.json", {}).get("atenei", {})
    old_indice = load_json(DB / "indice_corsi.json", {}).get("corsi", [])
    for u in unis["universita"]:
        uid = u["id"]
        if solo and uid not in solo:
            indice.extend(r for r in old_indice if r[0] == uid)
            if uid in old_meta:
                meta_atenei[uid] = old_meta[uid]
            continue
        old = load_json(DB / "corsi" / f"{uid}.json", {"corsi": []})
        old_by_ul = {c.get("id_universitaly"): c for c in old["corsi"] if c.get("id_universitaly")}
        old_by_id = {c["id"]: c for c in old["corsi"]}
        corsi = per_uni.get(uid, [])
        used = set()
        for c in corsi:
            base = f"{uid}-{slug(c['classe'] or c['tipo'], 20)}-{slug(c['nome'])}"
            prev = old_by_ul.get(c["id_universitaly"])
            cid = prev["id"] if prev else base
            if cid in used:
                cid = f"{base}-{slug(c['sede'] or '', 20) or c['id_universitaly']}"
            if cid in used:
                cid = f"{base}-{c['id_universitaly']}"
            used.add(cid)
            c["id"] = cid
            prev = prev or old_by_id.get(cid)
            if prev:
                c["insegnamenti"] = prev.get("insegnamenti") or []
                for k in ("curricula", "ammissione"):
                    if prev.get(k):
                        c[k] = prev[k]
        if solo:
            # In locale mancano i contributi automatici (contrib/auto) degli atenei con catalogo:
            # i corsi creati da quei contributi (senza id Universitaly) si conservano come sono, e
            # prima dei contributi, perché un contributo che li indica per id (es. i requisiti di
            # accesso) li trovi invece di crearne una copia vuota.
            for oc in old["corsi"]:
                if not oc.get("id_universitaly") and oc["id"] not in used:
                    used.add(oc["id"])
                    corsi.append(oc)
        # contributi: per id del corso, per id Universitaly o per nome+classe
        for cc in contrib_corsi.get(uid, []):
            target = trova_corso(corsi, cc)
            if not target and not cc.get("classe"):
                # senza classe di laurea non è un corso di studio (master, percorsi
                # abilitanti, corsi singoli): non si aggiunge
                continue
            if not target:
                target = {k: cc.get(k) for k in ("id", "nome", "tipo", "classe", "durata_anni", "sede", "lingua",
                                                   "accesso", "url")}
                target["tipo"] = target.get("tipo") or tipo_da_classe(cc.get("classe"), cc.get("tipo_catalogo"))
                target["id"] = target.get("id") or f"{uid}-{slug(cc.get('classe') or target['tipo'], 20)}-{slug(cc['nome'])}"
                if target["id"] in used:
                    target["id"] = f"{target['id']}-{slug(cc.get('codice_ateneo') or '', 20)}"
                used.add(target["id"])
                target.update(id_universitaly=None, stato="da_aggiungere", fonte=cc.get("fonte"),
                              verificato_il=cc.get("verificato_il"), insegnamenti=[])
                corsi.append(target)
            # sede: Universitaly a volte non la dà e due corsi omonimi (es. Pisa e Livorno) sembrerebbero doppioni
            for k in ("curricula", "url", "codice_ateneo", "sede"):
                if cc.get(k) and not target.get(k):
                    target[k] = cc[k]
            if cc.get("url"):
                target["url_catalogo"] = cc["url"]
            if cc.get("ammissione"):  # requisiti di accesso (OFA, test, inglese): il più recente vale
                target["ammissione"] = cc["ammissione"]
            ins = assegna_id(target["id"], cc.get("insegnamenti", []))
            target["insegnamenti"] = merge_insegnamenti(target.get("insegnamenti") or [], ins)
        for c in corsi:
            libri_delle_copie(c)  # stessa scelta in più anni: i libri della riga del codice
        app = appelli.get(uid, {})
        oggi = date.today().isoformat()
        # insegnamenti senza codice Esse3 (siti che non lo pubblicano): appelli per nome, solo se
        # il nome corrisponde a un unico codice dell'ateneo
        per_nome: dict[str, set[str]] = defaultdict(set)
        for cod, lst in app.items():
            for e in lst:
                if e.get("titolo"):
                    per_nome[norm(e["titolo"])].add(cod)
        for c in corsi:
            copia = c.get("piano_da") or (re.search(r"(?i)\breplica\b", c.get("nome") or "") and not any(
                i.get("docenti") for i in c.get("insegnamenti") or []))
            for i in ([] if copia else c.get("insegnamenti") or []):  # gli appelli cambiano da sede a sede
                cod = i.get("codice") or ""
                stesso_nome = per_nome.get(norm(i.get("nome") or ""), ())
                if not cod and len(stesso_nome) == 1:
                    cod = next(iter(stesso_nome))
                elif cod and cod not in app and len(stesso_nome) == 1:
                    # codice del catalogo diverso da quello della bacheca (es. eCampus): lo stesso nome
                    # non basta (corsi diversi hanno insegnamenti omonimi), servono anche i docenti
                    cand = next(iter(stesso_nome))
                    if _docenti_in_comune(i.get("docenti") or [], app[cand]):
                        cod = cand
                nuovi = [e for e in app.get(cod, []) if (e.get("data") or "") >= oggi[:4]]
                if nuovi:
                    viste = {(e.get("data"), e.get("ora"), e.get("tipo")) for e in i.get("esami") or []}
                    aggiunti = []
                    for e in sorted(nuovi, key=lambda e: e.get("ora") is None):  # prima gli appelli con l'ora
                        k = (e.get("data"), e.get("ora"), e.get("tipo"))
                        # stessa data da fonti diverse (es. bacheca Esse3 e Agenda Web): una sola volta
                        if k in viste or (e.get("ora") is None and any(v[0] == k[0] and v[2] == k[2] for v in viste)):
                            continue
                        viste.add(k)
                        aggiunti.append({k2: v for k2, v in e.items() if k2 != "titolo"})
                    i["esami"] = sorted((i.get("esami") or []) + aggiunti, key=lambda e: e.get("data") or "")
                    i["stato_esami"] = "completo"
            c["insegnamenti"] = merge_insegnamenti([], c.get("insegnamenti") or [])
            c["stato"] = stato_corso(c)
        pulizia.durata_per_tipo(corsi)  # durata coerente con il tipo (LM 2 anni, ciclo unico 5 o 6)
        pulizia.pulisci_corsi(corsi)  # normalizzazioni sicure (periodi, testi, docenti, libri, esami)
        pulizia.rivedi_varianti(corsi)  # varianti già nel file che non sono una traduzione: di nuovo insegnamenti
        pulizia.varianti_lingua(corsi)  # versioni in inglese degli insegnamenti: varianti della versione italiana
        pulizia.varianti_lingua_gemelli(corsi)  # stesso insegnamento in italiano e inglese nello stesso piano
        pulizia.varianti_lingua_scelta(corsi)  # italiano e inglese nello stesso gruppo di scelta (lingua e gruppo dalla fonte)
        esistenti = {i.get("id") for oc in old["corsi"] for i in oc.get("insegnamenti") or []}
        pulizia.unisci_omonimi(corsi, esistenti)  # stesso insegnamento per più canali/sedi: uno solo (id già esistenti prima)
        pulizia.segna_a_scelta(corsi)  # segnaposto «a scelta» (es. «Esame a scelta 1»): a scelta
        pulizia.repliche(corsi)  # repliche di sede vuote: struttura del piano del corso principale
        for c in corsi:
            c["stato"] = stato_corso(c)
        corsi.sort(key=lambda c: (c["tipo"], norm(c["nome"])))
        doc = {"schema": 1, "universita_id": uid, "anno_accademico": anno_acc,
               "aggiornato_il": date.today().isoformat(), "fonte": raw.get("fonte"), "corsi": corsi}
        path = DB / "corsi" / f"{uid}.json"
        write_json(path, doc)
        for c in corsi:
            indice.append([uid, c["id"], c["nome"], c["tipo"], c["classe"], c["durata_anni"], c["sede"], c["lingua"]])
        ins_all = [i for c in corsi for i in c["insegnamenti"]]
        meta_atenei[uid] = {
            "corsi": len(corsi), "insegnamenti": len(ins_all),
            "libri": sum(len(i["libri"]) for i in ins_all), "esami": sum(len(i["esami"]) for i in ins_all),
            "file": f"corsi/{uid}.json",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    write_json(DB / "indice_corsi.json", {"schema": 1, "anno_accademico": anno_acc, "corsi": indice})
    now = datetime.now(timezone.utc)
    write_json(DB / "meta.json", {"schema": 1, "anno_accademico": anno_acc, "versione": now.strftime("%Y.%m.%d"),
                                  "generato_il": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "atenei": meta_atenei})
    write_json(REPORT, unmatched)
    tot = sum(m["corsi"] for m in meta_atenei.values())
    print(f"{tot} corsi associati a {sum(1 for m in meta_atenei.values() if m['corsi'])} atenei; "
          f"{sum(u['corsi'] for u in unmatched.values())} corsi non associati ({len(unmatched)} nomi) -> {REPORT.name}")
    for n, u in sorted(unmatched.items(), key=lambda x: -x[1]["corsi"])[:40]:
        print(f"  NON ASSOCIATO: {n} (codeUn {u['codeUn']}, {u['corsi']} corsi)", file=sys.stderr)


if __name__ == "__main__":
    main()
