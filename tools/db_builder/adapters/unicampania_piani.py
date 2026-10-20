"""Piani di studio delle professioni sanitarie dell'Università della Campania "Luigi Vanvitelli".

Le pagine U-GOV dei corsi integrati (`docenti?COD_ATTIVITA=…`) elencano solo le unità didattiche con un docente
assegnato: i CFU di un integrato letti da lì sono spesso troppo bassi e mancano del tutto le attività senza scheda
(tirocinio, attività a scelta, laboratori, seminari, prova finale). I documenti ufficiali di ciascun corso (piano di
studio, programmazione didattica) hanno invece tutte le attività, ciascuna con il suo codice, i CFU e l'anno:

- `codici`: tabelle con una riga per attività («A6501A … 3 3 27 I.1°», «Tirocinio I A6108 25»), con o senza la colonna
  «A.S.» (anno e semestre); i CFU di un integrato sono quelli dell'intestazione («A7101 7») o la somma delle sue unità;
- `ugov`: stampa «Offerta didattica - Dettaglio» di U-GOV (Infermieristica): il codice dell'attività con i CFU e le sue
  unità sulle righe sotto (non riporta l'anno: si ricava dai codici già letti e dalle attività vicine);
- `nomi`: piani senza codici (Assistenza sanitaria, Prevenzione): il CFU di un integrato è il numero che segue il suo nome.

Le funzioni `leggi_*` sono pure (testo → dati), `applica_piano` aggiorna un corso già letto dall'adattatore.
"""
from __future__ import annotations

import re
import unicodedata

NUM = r"\d{1,3}(?:[.,]\d{1,2})?"
# «CFU [CFU] [ORE] A.S.»: l'ultimo elemento è l'anno e il semestre («I.1°», «II.2», «III.1») o l'annualità
_RUN = re.compile(rf"(?<![\w.,/])(?P<n1>{NUM})\s+(?:(?P<n2>{NUM})\s+)?(?:(?P<n3>{NUM})\s+)?"
                  r"(?P<as>(?:III|II|I|IV)\s*\.\s*[12]\s*[°º]?|(?:III|II|I|IV)(?![\w.])(?!\s*(?:sem|anno)))", re.I)
_ROM = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6}
_PAR = {"PRIMO": 1, "SECONDO": 2, "TERZO": 3, "QUARTO": 4, "QUINTO": 5, "SESTO": 6}
_HEAD_CAPS = re.compile(
    r"(?<![\w°º])(?:(?P<r>VI|IV|V|III|II|I)\s*[°º]?\s*ANNO|(?P<n>[1-6])\s*[°º]\s*ANNO|ANNO\s+(?P<r2>VI|IV|V|III|II|I)\b(?!\s*SEM)|"
    r"(?P<w>PRIMO|SECONDO|TERZO|QUARTO|QUINTO|SESTO)\s+ANNO)")
_HEAD_PAROLE = re.compile(r"(?<![\w°º])(?P<w>primo|secondo|terzo|quarto|quinto|sesto)\s+anno\b", re.I)
_MUTUATO = re.compile(r"(?i)mutuat\w*\s*(?:con|da|di)?\s*[-\w/ ]{0,12}$")
_SSD_ANY = re.compile(r"\b[A-Z]{1,5}-\s*[A-Z]{1,4}\s*/\s*\d{2}\b|\b[A-Z]{2,5}-?\s*\d{2}\s*/\s*[A-Z]\b|\b[A-Z]{2,5}\s*/\s*\d{2}\b")
_SSD_RIGA = re.compile(r"\b(?:[A-Z]{2,5}-\d{2}/[A-Z]|[A-Z]{2,5}/\d{2}|NN)\b|\(\s*[A-Z]{2,5}/\d{2}\s*\)")


def _num(s: str) -> float:
    return float(s.replace(",", "."))


def _anno_as(a: str) -> int | None:
    m = re.match(r"(III|II|IV|VI|V|I)", a.strip().upper())
    return _ROM[m.group(1)] if m else None


def norm(x: str | None) -> str:
    x = unicodedata.normalize("NFKD", x or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", x)


def _titolo(s: str) -> str:
    s = re.sub(r"(?i)\battivita['’]", lambda m: "ATTIVITÀ" if m.group(0)[:2].isupper() else "attività", s)
    s = re.sub(r"\s+", " ", s).strip(" -–:.,;")
    return s[:1].upper() + s[1:].lower() if s.isupper() else s[:1].upper() + s[1:]


def leggi_codici(testo: str, prefisso: str, alias: dict[str, str] | None = None, head: str = "caps", fine: str | None = None) -> dict[str, dict]:
    """{codice: {cfu, tot, anno, as, pos, ctx, ordine}} dalle righe «codice … CFU [ORE] A.S.» del testo. `cfu` è il CFU
    letto dalla riga dell'attività (con la colonna A.S.), `tot` il numero subito dopo un codice senza A.S. (CFU dell'integrato
    dell'intestazione o dell'attività di una tabella «nome codice CFU»); l'anno è quello dell'A.S. o dell'intestazione
    «PRIMO ANNO» / «II ANNO» più vicina sopra. Una riga ripetuta (altre sedi di formazione) vale la prima."""
    t = re.sub(r"\s+", " ", testo)
    if fine and fine in t:  # documento con più sedi di formazione: vale la prima sezione
        t = t[:t.index(fine)]
    for a, b in (alias or {}).items():
        t = t.replace(a, b)
    t = _SSD_ANY.sub(" ", t)  # «MED/30», «BIOS-07/A», «ING-INF/ 05», «SECS- P/10»: i numeri dell'SSD non sono CFU
    heads = []
    rx = _HEAD_PAROLE if head == "parole" else _HEAD_CAPS
    for m in rx.finditer(t):
        if head == "caps" and not m.group(0).isupper():
            continue
        v = m.groupdict().get("r") or m.groupdict().get("r2")
        if v:
            a = _ROM[v]
        elif m.groupdict().get("n"):
            a = int(m.group("n"))
        else:
            a = _PAR[m.group("w").upper()]
        heads.append((m.start(), a))
    toks = [m for m in re.finditer(rf"(?<![\w(])({prefisso})([A-Z])?\b", t)
            if not _MUTUATO.search(t[max(0, m.start() - 30):m.start()])]
    out: dict[str, dict] = {}
    for k, m in enumerate(toks):
        code = m.group(1) + (m.group(2) or "")
        fine = toks[k + 1].start() if k + 1 < len(toks) else len(t)
        seg = t[m.end():min(fine, m.end() + 300)]
        r = _RUN.search(seg)
        anno = cfu = tot = None
        if r:
            cfu, anno = _num(r.group("n1")), _anno_as(r.group("as"))
        else:
            r2 = re.match(r"\s*(?:[A-Za-z_ .'’\-–/()]{0,60}?)(\d{1,2}(?:[.,]\d)?)(?![\w/])", seg)
            if r2:
                tot = _num(r2.group(1))
        as_ok = anno is not None
        if anno is None:
            hh = [a for p, a in heads if p < m.start()]
            anno = hh[-1] if hh else None
        rec = {"cfu": cfu, "tot": tot, "anno": anno, "as": as_ok, "pos": m.start(), "ordine": k,
               "ctx": t[max(0, m.start() - 70):m.start()], "dopo": seg[:50]}
        prima = out.get(code)
        if prima is None or (prima["cfu"] is None and cfu is not None):
            out[code] = rec
        elif cfu is not None and prima["cfu"] is not None and prima["as"] and as_ok and prima["anno"] == anno:
            prima["cfu"] += cfu  # stessa unità su due righe (ambito base + affine): i CFU si sommano
    return out


_INIZIO_NOME = re.compile(r"(?i)(?:\ba\s+scelta|\bade\b|attivit\w*\s+(?:a\s+scelta|seminar|formative)|altre\s+attivit|tirocin|stage|prova\s+finale|preparazione|"
                          r"laborator|seminar|inglese|lingua|esame\s+(?:di\s+tirocinio|finale))")


def nome_da_contesto(ctx: str, autonoma: bool = False) -> str:
    """Nome dell'attività: il testo subito prima del codice, senza SSD e senza i resti della riga precedente. Per le attività
    singole (tirocinio, attività a scelta, laboratorio…) il nome comincia dall'ultima parola chiave."""
    c = _SSD_RIGA.sub(" ", ctx)
    c = re.sub(r"\([^)]*mutuat[^)]*\)?", " ", c, flags=re.I)
    c = re.sub(r"\s+", " ", c).strip()
    if autonoma:
        ks = list(_INIZIO_NOME.finditer(c))
        if ks:
            c = c[ks[-1].start():]
    # il nome inizia dopo l'ultimo numero isolato (CFU/ore della riga precedente) o dopo un codice
    parti = [c] if autonoma else re.split(r"(?:\s|^)(?:\d{1,3}(?:[.,]\d)?|[IV]{1,3}\.[12]°?|A\d{4,6}[A-Z]?)(?=\s|$)", c)
    c = parti[-1].strip() if parti and parti[-1].strip() else c
    c = re.sub(r"(?i)\bPROFIN_\s?S\b", " ", c)
    c = re.sub(r"(?i)\s+(?:NN|L|FS|annuale|annualit\w*)$", "", c).strip()
    return _titolo(c)


# ---------------------------------------------------------------------------------------------
# stampa U-GOV «Offerta didattica - Dettaglio»

_AD = re.compile(r"^(?P<cod>A\d{4,6})\s+(?:No|Si)\s*(?:No|Si)\s*(?:No|Si)\s+\w+\s+Voto Finale\s+(?P<cfu>\d+(?:,\d+)?)\s*(?P<per>Primo Semestre|Secondo Semestre|Annualit[àa] Singola)?", re.I)
_UD = re.compile(r"^(?P<af>[A-F])\s+(?P<tipo>LEZ|SEM|LAB|TIR|PRF|ALT|STA|ESA|\w{3})\s+(?P<ore>\d+(?:,\d+)?)\s+(?P<min>\d+(?:,\d+)?)\s+(?P<cfu>\d+(?:,\d+)?)\s*(?P<nome>.*?)(?P<seg>\d)(?P<cod>A\d{4,6}[A-Z]?)\s*$")


def leggi_ugov(testo: str) -> dict[str, dict]:
    """{codice AD: {cfu, periodo, unita: [{cod, nome, cfu, tipo}]}} dalla stampa U-GOV; si usa la sezione dell'ultima
    offerta (l'ultimo «Anno Accademico di offerta» con le attività), senza ripetere quelle di sezioni precedenti."""
    righe = [r.strip() for r in testo.split("\n")]
    ad: dict[str, dict] = {}
    corrente = None
    for r in righe:
        m = _AD.match(r)
        if m:
            cod = m.group("cod")
            per = (m.group("per") or "").lower()
            ad[cod] = {"cfu": _num(m.group("cfu")), "periodo": "1" if per.startswith("primo") else "2" if per.startswith("secondo")
                       else "annuale" if per.startswith("annual") else None, "unita": []}
            corrente = ad[cod]
            continue
        u = _UD.match(r)
        if u and corrente is not None:
            nome = re.sub(r"\s+", " ", u.group("nome")).strip()
            nome = re.sub(r"\s+[A-Za-z]{2,5}/\d{2}\s*-\s*.*$|\s+NN\s*-\s*.*$|\s+[A-Z]{2,5}-\d{2}/[A-Z]\s*-\s*.*$|\s+PROFIN_S\s*-\s*.*$", "", nome).strip()
            corrente["unita"].append({"cod": u.group("cod"), "nome": nome, "cfu": _num(u.group("cfu")), "tipo": u.group("tipo")})
    return ad


# ---------------------------------------------------------------------------------------------
# piani senza codici

def cfu_per_nome(testo: str, nomi: list[str]) -> dict[str, float]:
    """{nome: CFU} per i corsi integrati di un piano senza codici: il CFU è il primo numero dopo il nome (sulla stessa
    riga o su quella dopo). Il nome si cerca senza badare a maiuscole, accenti, apostrofi e a capo."""
    t2 = unicodedata.normalize("NFKD", re.sub(r"\s+", " ", testo)).encode("ascii", "ignore").decode()
    out = {}
    for nome in nomi:
        parole = re.findall(r"[A-Za-z0-9]+", unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode())
        if not parole:
            continue
        rx = re.compile(r"(?i)\b" + r"[^A-Za-z0-9]+".join(re.escape(p) for p in parole) + r"\b[^0-9A-Za-z]*(\d{1,2})(?![\w/])")
        m = rx.search(t2)
        if m:
            out[nome] = float(m.group(1))
    return out


# ---------------------------------------------------------------------------------------------
# raggruppamento dei codici letti in attività (integrati, attività singole)

_UNITA_LETTERA = re.compile(r"A\d{4,6}[A-Z]")
_AUTONOMA = re.compile(r"(?i)tirocin|stage|a\s+scelta|\bade\b|prova\s+finale|esame\s+finale|\btesi\b|laborator|seminar|attivit\w*\s+formative\s+prof|"
                       r"altre\s+attivit|\blingua\b|\binglese\b")


def raggruppa(recs: dict[str, dict], unita_di: dict[str, str] | None = None) -> list[dict]:
    """Attività del piano: [{cod, tot, cfu, anno, unita: [(codice, cfu)], ctx, aut}] in ordine di documento. Una voce con CFU
    e A.S. è un'attività singola (tirocinio, attività a scelta, inglese) o un'unità del corso integrato aperto sopra di
    essa; le unità con la lettera («A6501A») stanno sotto l'intestazione del loro integrato o, se questa manca, formano
    un integrato col codice senza lettera."""
    forzate = dict(unita_di or {})  # codice → codice dell'integrato di cui è unità (quando il documento non lo dice)
    voci = sorted(((c, r) for c, r in recs.items() if c not in forzate), key=lambda q: q[1]["pos"])
    gruppi: list[dict] = []
    cur: dict | None = None

    def aperto(g) -> bool:
        if g is None or g["aut"] or g.get("pseudo"):
            return False
        if g["tot"] is None:
            return True
        return sum(c or 0 for _, c in g["unita"]) < g["tot"] - 1e-6

    for k, (code, r) in enumerate(voci):
        v = r["cfu"] if r["cfu"] is not None else r["tot"]
        lettera = bool(_UNITA_LETTERA.fullmatch(code))
        kw = bool(_AUTONOMA.search(r["ctx"][-45:] + " " + r.get("dopo", "")))
        if lettera:
            base = code[:-1]
            if cur is not None and not cur["aut"] and (cur["cod"] == base or aperto(cur)):
                cur["unita"].append((code, v))
                cur["anno"] = cur["anno"] or r["anno"]
            else:
                cur = {"cod": base, "tot": None, "cfu": None, "anno": r["anno"], "unita": [(code, v)], "ctx": r["ctx"], "aut": False, "pseudo": True}
                gruppi.append(cur)
            continue
        # codice senza lettera
        if r["cfu"] is None and v is None:  # intestazione di un integrato senza totale
            cur = {"cod": code, "tot": None, "cfu": None, "anno": r["anno"], "unita": [], "ctx": r["ctx"], "aut": False}
            gruppi.append(cur)
            continue
        succ_lettera = k + 1 < len(voci) and (bool(_UNITA_LETTERA.fullmatch(voci[k + 1][0])) or voci[k + 1][1]["cfu"] is not None)
        if r["cfu"] is None and succ_lettera and not kw:  # intestazione con il totale («A7101 7»)
            cur = {"cod": code, "tot": v, "cfu": None, "anno": r["anno"], "unita": [], "ctx": r["ctx"], "aut": False}
            gruppi.append(cur)
            continue
        if aperto(cur) and not kw:  # unità senza lettera (A422816) dell'integrato aperto
            cur["unita"].append((code, v))
            continue
        cur = {"cod": code, "tot": None, "cfu": v, "anno": r["anno"], "unita": [], "ctx": r["ctx"], "aut": True}
        gruppi.append(cur)
    for u, cod in forzate.items():
        if u not in recs:
            continue
        g = next((g for g in gruppi if g["cod"] == cod), None)
        if g is None:
            g = {"cod": cod, "tot": None, "cfu": None, "anno": recs[u]["anno"], "unita": [], "ctx": recs[u]["ctx"], "aut": False, "pseudo": True}
            gruppi.append(g)
        r = recs[u]
        g["unita"].append((u, r["cfu"] if r["cfu"] is not None else r["tot"]))
    for g in gruppi:
        somma = sum(c or 0 for _, c in g["unita"])
        con_as = [recs[u]["anno"] for u, _ in g["unita"] if recs[u]["as"]]
        if con_as:  # l'anno delle unità (colonna A.S.) vale più dell'intestazione più vicina sopra
            g["anno"] = con_as[0]
        if not g["aut"]:
            g["cfu"] = max(g["tot"] or 0, somma) or None
            if g["tot"] and somma and abs(g["tot"] - somma) > 1e-6:
                g["discordante"] = (g["tot"], somma)
    return gruppi


# ---------------------------------------------------------------------------------------------
# applicazione a un corso già letto dall'adattatore

_SCELTA = re.compile(r"(?i)\ba\s+scelta\b|\bade\b|\bchoice\b")


def _riga_nuova(codice, nome, anno, cfu, url, oggi, scelta=None) -> dict:
    return {"codice": codice, "nome": nome, "anno": anno, "periodo": None, "cfu": int(cfu) if float(cfu).is_integer() else cfu,
            "ssd": None, "obbligatorio": False if (_SCELTA.search(nome) if scelta is None else scelta) else True, "curriculum": None,
            "docenti": [], "url": url, "libri": [], "esami": [], "fonte": url, "verificato_il": oggi, "stato_libri": "da_aggiungere"}


def _distingui(x: dict, nuove: list[dict]) -> None:
    """Righe con lo stesso nome nello stesso anno (due «A scelta dello studente», due laboratori): «- parte N»."""
    viste: dict[tuple, int] = {}
    for i in x["insegnamenti"]:
        viste[(i.get("anno"), norm(i["nome"]))] = viste.get((i.get("anno"), norm(i["nome"])), 0) + (0 if i in nuove else 1)
    for i in nuove:
        k = (i.get("anno"), norm(i["nome"]))
        if viste.get(k):
            viste[k] += 1
            i["nome"] = f"{i['nome']} - parte {viste[k]}"
        else:
            viste[k] = 1


def applica_codici(x: dict, recs: dict[str, dict], cfg: dict, url: str, oggi: str, log=print) -> dict:
    """Aggiorna i CFU degli integrati del corso `x` con quelli del piano e aggiunge le attività del piano che mancano
    (identificate dal codice): tirocini, attività a scelta, laboratori, seminari, prova finale, integrati senza scheda."""
    gr = raggruppa(recs, cfg.get("unita_di"))
    righe = {i["codice"]: i for i in x["insegnamenti"] if i.get("codice")}
    nomi = cfg.get("nomi") or {}
    anni = cfg.get("anni") or {}
    ignora = set(cfg.get("ignora") or [])
    nuove, corretti = [], 0
    for g in gr:
        if g["cod"] in ignora:
            continue
        anno = anni.get(g["cod"]) or g["anno"] or next((recs[u]["anno"] for u, _ in g["unita"] if recs[u]["anno"]), None)
        if g["cfu"] is None:
            continue
        r = righe.get(g["cod"])
        if r is not None:
            if r.get("cfu") != g["cfu"] and not (isinstance(r.get("cfu"), (int, float)) and abs(r["cfu"] - g["cfu"]) < 1e-6):
                r["cfu"] = int(g["cfu"]) if float(g["cfu"]).is_integer() else g["cfu"]
                corretti += 1
            continue
        nome = nomi.get(g["cod"]) or nome_da_contesto(g["ctx"], g["aut"])
        if not anno or not nome:
            log(f"[unicampania]   piano {url[-40:]}: {g['cod']} senza anno o nome ({anno!r}, {nome!r}): saltato")
            continue
        nuove.append(_riga_nuova(g["cod"], nome, anno, g["cfu"], url, oggi))
    tolte = _togli_doppi(x, gr, nuove, anni)
    _distingui(x, nuove)
    x["insegnamenti"].extend(nuove)
    return {"corretti": corretti, "aggiunti": len(nuove), "tolte": tolte}


def _togli_doppi(x: dict, gruppi: list[dict], nuove: list[dict], anni: dict) -> int:
    """Dopo aver letto un piano con i codici: si tolgono le righe che lo stesso piano rende doppie, cioè la stessa attività
    con un altro anno (l'elenco HTML la assegna all'anno sbagliato) e le righe senza codice di un'attività del piano
    (riga di tabella «A scelta dello studente», «Laboratorio professionale»)."""
    anno_codice = {g["cod"]: (anni.get(g["cod"]) or g["anno"]) for g in gruppi if g["cfu"] is not None}
    nomi_piano = {(i.get("anno"), norm(re.sub(r" - parte \d+$", "", i["nome"]))) for i in nuove}
    prima = len(x["insegnamenti"])
    x["insegnamenti"] = [
        i for i in x["insegnamenti"]
        if not (i.get("codice") in anno_codice and anno_codice[i["codice"]] and i.get("anno") != anno_codice[i["codice"]])
        and not (not i.get("codice") and i not in nuove and (i.get("anno"), norm(i["nome"])) in nomi_piano)]
    return prima - len(x["insegnamenti"])


def applica_tabella(x: dict, righe: list[tuple], url: str, oggi: str, log=print) -> dict:
    """Piano trascritto dal documento ufficiale (quando il testo del PDF non si legge in modo regolare): per ogni
    `(anno, codice, nome, cfu[, scelta])` il CFU dell'integrato già presente (stesso codice) o una riga nuova."""
    esistenti = {i["codice"]: i for i in x["insegnamenti"] if i.get("codice")}
    per_nome = {(i.get("anno"), norm(i["nome"])): i for i in x["insegnamenti"]}
    nuove, corretti, aggiunte_copie = [], 0, 0
    for r in righe:
        anno, codice, nome, cfu = r[:4]
        scelta = r[4] if len(r) > 4 else None
        if len(r) > 6 and r[6] == "copia" and codice in esistenti:
            # insegnamento a scelta offerto anche in questo anno: una copia della riga già letta (stesso codice, libri compresi)
            if not any(q.get("codice") == codice and q.get("anno") == anno for q in x["insegnamenti"]):
                import copy
                q = copy.deepcopy(esistenti[codice])
                q.update({"anno": anno, "obbligatorio": False, "cfu": cfu})
                x["insegnamenti"].append(q)
                aggiunte_copie += 1
            continue
        # riga senza codice (attività del piano senza scheda): si riconosce dall'anno e dal nome
        i = esistenti.get(codice) if codice else per_nome.get((anno, norm(nome)))
        if i is not None:
            if i.get("cfu") != cfu:
                i["cfu"] = cfu
                corretti += 1
            if scelta:  # attività a scelta dello studente
                i["obbligatorio"] = False
            if len(r) > 5 and r[5]:  # il nome della riga già letta è quello di un solo modulo: si usa quello del piano
                i["nome"] = nome
            if i.get("anno") != anno:
                i["anno"] = anno
            continue
        nuove.append(_riga_nuova(codice, nome, anno, cfu, url, oggi, scelta))
    _distingui(x, nuove)
    x["insegnamenti"].extend(nuove)
    return {"corretti": corretti, "aggiunti": len(nuove), "copie": aggiunte_copie}


def applica_ugov(x: dict, ad: dict[str, dict], cfg: dict, url: str, oggi: str, log=print) -> dict:
    """Piano U-GOV (Infermieristica): CFU degli integrati dal totale dell'attività didattica e attività senza scheda
    (tirocini, attività a scelta, seminari, laboratori, tesi) con l'anno dell'ultimo integrato di cui si conosce l'anno
    (i codici seguono l'ordine del piano) oppure, se il nome lo dice («2° anno»), da quello."""
    righe = {i["codice"]: i for i in x["insegnamenti"] if i.get("codice")}
    corretti = 0
    anno_corrente = None
    nuove = []
    anni = cfg.get("anni") or {}
    for cod in sorted(ad, key=lambda c: int(re.sub(r"\D", "", c))):
        a = ad[cod]
        r = righe.get(cod)
        if r is not None:
            anno_corrente = r.get("anno") or anno_corrente
            if r.get("cfu") != int(a["cfu"]) and abs((r.get("cfu") or 0) - a["cfu"]) > 1e-6:
                r["cfu"] = int(a["cfu"]) if float(a["cfu"]).is_integer() else a["cfu"]
                corretti += 1
            continue
        nome_ud = a["unita"][0]["nome"] if len(a["unita"]) == 1 else None
        if nome_ud is None:
            log(f"[unicampania]   piano U-GOV: {cod} non è nel corso e ha più unità: saltato")
            continue
        nome = re.sub(r"^C\.\s?I\.?\s+", "", nome_ud).strip()
        nome = re.sub(r"\s+", " ", nome.replace("°ANNO", "° ANNO"))
        anno = anni.get(cod)
        m = re.search(r"(\d)\s*°\s*ANNO", nome)
        if not anno and m:
            anno = int(m.group(1))
        anno = anno or anno_corrente
        if not anno:
            continue
        nuove.append(_riga_nuova(cod, _titolo(nome), anno, a["cfu"], url, oggi))
    _distingui(x, nuove)
    x["insegnamenti"].extend(nuove)
    return {"corretti": corretti, "aggiunti": len(nuove)}


def applica_nomi(x: dict, testo: str, url: str, cfg: dict | None = None, log=print) -> dict:
    """Piani senza codici: il CFU degli integrati già presenti è quello che il documento riporta dopo il nome;
    `cfu_nomi` (nome → CFU) vale per i nomi che il testo del PDF spezza su più righe."""
    nomi = [i["nome"] for i in x["insegnamenti"] if i.get("codice")]
    trovati = cfu_per_nome(testo, nomi)
    trovati.update({n: v for n, v in ((cfg or {}).get("cfu_nomi") or {}).items() if n in nomi})
    corretti = 0
    for i in x["insegnamenti"]:
        v = trovati.get(i["nome"]) if i.get("codice") else None
        if v is not None and i.get("cfu") != v:
            i["cfu"] = int(v) if float(v).is_integer() else v
            corretti += 1
    return {"corretti": corretti, "trovati": len(trovati), "su": len(nomi)}


# ---------------------------------------------------------------------------------------------
# piani per coorte (Medicina e chirurgia di Caserta): un PDF per coorte con tutti i sei anni

_RIGA_COORTE = re.compile(r"^(?P<nome>.+?)\s+(?:(?:[A-Z]{2,5}-\d{2}/[A-Z]|[A-Z]{2,5}/\d{2})\s+)*(?P<cfu>\d+(?:,\d+)?)\s+(?P<ore>\d+(?:,\d+)?)\s+(?:(?P<sem>[12&]+)\s+)?(?P<val>V|G|VF)$")
_STOP = {"e", "ed", "di", "del", "della", "dei", "delle", "dell", "da", "in", "la", "il", "lo", "le", "i", "gli", "per", "a", "al", "e'"}


def leggi_coorte(testo: str, erogato: str) -> list[dict]:
    """Esami e attività della sezione «<erogato> N ANNO» del piano di una coorte: una voce per riga che termina con la
    valutazione (V = voto, G = giudizio) con il CFU complessivo; le righe dei moduli (senza valutazione) sono già nel totale.
    Una riga di intestazione spezzata su due righe (nome senza numeri) si unisce alla successiva."""
    righe = [re.sub(r"\s+", " ", r).strip() for r in testo.split("\n")]
    out, dentro, prec = [], False, ""
    for r in righe:
        m = re.match(r"^(\d{4}/\d{4})\s+(?:I|II|III|IV|V|VI)\s+ANNO\b", r)
        if m:
            dentro, prec = (m.group(1) == erogato), ""
            continue
        if not dentro or not r:
            continue
        m = _RIGA_COORTE.match(r)
        if m:
            nome = m.group("nome")
            if prec and not re.search(r"\d", prec) and not _SSD_ANY.search(prec) and prec.isupper() and nome.isupper():
                nome = prec + " " + nome  # «BASI METODOLOGICHE IN MEDICINA, BIOETICA E BIOSTATISTICA E» + «INGLESE SCIENTIFICO»
            nome = re.sub(r"\(\s*(?:esame(?: finale)?|corso i parte|integrato)\s*\)|\(\s*prof[^)]*\)?|\*", " ", nome, flags=re.I)
            nome = re.sub(r"^C\.\s?I\.?\s+", "", nome.strip(), flags=re.I)
            nome = re.sub(r"\s+", " ", nome).strip(" ,-")
            nome = _titolo(nome)
            nome = re.sub(r"(?i)\b(afp|ade|tpv)\b", lambda q: q.group(1).upper(), nome)
            nome = re.sub(r"(?i)\b(i{1,3}|iv|v|vi)(\s+anno)\b", lambda q: q.group(1).upper() + q.group(2), nome)
            out.append({"nome": nome, "cfu": _num(m.group("cfu")), "val": m.group("val")})
        prec = r if not m else ""
    return out


def _token(n: str) -> set[str]:
    return {t for t in re.findall(r"[a-z0-9]+", norm_spazi(n)) if t not in _STOP and len(t) > 2}


def norm_spazi(x: str) -> str:
    return unicodedata.normalize("NFKD", x or "").encode("ascii", "ignore").decode().lower()


def applica_coorti(x: dict, specs: list[tuple], oggi: str, log=print) -> dict:
    """Il piano di ogni anno è quello della coorte che lo frequenta nel 2026/27: `specs` = [(anno, url, testo, erogato)].
    Le righe già lette il cui nome corrisponde a un esame del piano (stesse parole, o parole di uno contenute nell'altro)
    restano con codice, docenti e libri e prendono il CFU del piano; le altre righe di quell'anno (altre coorti, moduli,
    AFP) si tolgono; gli esami del piano senza riga si aggiungono."""
    corretti = aggiunti = tolti = 0
    for anno, url, testo, erogato in specs:
        voci = leggi_coorte(testo, erogato)
        if not voci:
            log(f"[unicampania]   coorte {url[-40:]}: sezione {erogato} vuota")
            continue
        esistenti = [i for i in x["insegnamenti"] if i.get("anno") == anno]
        usate: set[int] = set()
        nuove = []
        for v in voci:
            tv = _token(v["nome"])
            best = None
            for k, i in enumerate(esistenti):
                if k in usate:
                    continue
                ti = _token(i["nome"])
                if ti and tv and (ti <= tv or tv <= ti):
                    sc = len(ti & tv) / max(len(ti | tv), 1)
                    if best is None or sc > best[0]:
                        best = (sc, k)
            if best:
                i = esistenti[best[1]]
                usate.add(best[1])
                if i.get("cfu") != v["cfu"]:
                    corretti += 1
                i["cfu"] = int(v["cfu"]) if float(v["cfu"]).is_integer() else v["cfu"]
                if _token(i["nome"]) < tv:  # la riga era di un solo modulo («Inglese scientifico»): il piano ha il nome dell'esame
                    i["nome"] = v["nome"]
                if _SCELTA.search(i["nome"]):
                    i["obbligatorio"] = False
            else:
                r = _riga_nuova(None, v["nome"], anno, v["cfu"], url, oggi)
                nuove.append(r)
        for k, i in enumerate(esistenti):
            if k not in usate:
                x["insegnamenti"].remove(i)
                tolti += 1
        _distingui(x, nuove)
        x["insegnamenti"].extend(nuove)
        aggiunti += len(nuove)
    return {"corretti": corretti, "aggiunti": aggiunti, "tolti": tolti}
