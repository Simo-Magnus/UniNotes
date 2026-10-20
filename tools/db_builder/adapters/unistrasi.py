"""Insegnamenti dell'Università per Stranieri di Siena dalle guide didattiche (PDF).

L'elenco degli insegnamenti per curriculum sulle pagine dei corsi (dipartimento.unistrasi.it) è vuoto: il piano
è nella «Guida didattica» in PDF (`online.unistrasi.it/docenti/Guide/<anno>/<sigla>.pdf`, linkata dalla pagina del
corso; per LM-38 dalla pagina `Articolo?…Codice=LM_LI…` raggiunta dall'elenco delle magistrali). Per ogni
«CURRICOLO: …» (o «LAUREA MAGISTRALE IN …» per LM-2/LM-89) ci sono le tabelle «I anno | CFU», «II anno», «III anno»:
è il piano della coorte dell'a.a. di iscrizione (il secondo e il terzo anno si insegnano dall'a.a. successivo), con una
riga «TOTALE CFU» (60) per anno.

Le tabelle si leggono con pypdf dalle posizioni sulla pagina (le colonne del testo estratto non sono allineate):
le celle sono i rettangoli del PDF, a sinistra le righe di testo e a destra i CFU della cella; una cella che continua
sulla pagina dopo non ha CFU. Una cella è:
- un insegnamento («SSD - Nome»), obbligatorio, con i CFU della cella; anche senza SSD («Tirocinio», «Prova finale»);
- un gruppo a scelta («1 esame a scelta fra», «1 lingua a scelta», «Due lingue a scelta fra», «2° annualità della prima
  lingua scelta», «Letteratura legata alla prima lingua scelta»…): una riga per opzione, a scelta, con i CFU di un
  esame: scritti («1 esame a scelta (6 cfu) tra») o il totale della cella diviso per gli esami da scegliere («Due
  lingue … 18» = 2 da 9: deduzione, elencata nel log); «oppure» separa alternative (tutte a scelta);
- «Modulo …» con «(6 cfu)» per voce: insegnamenti obbligatori con quei CFU; «6+6» = un CFU per ciascuna voce o gruppo;
- un credito libero («1 esame a scelta libera», «A scelta (1 esame)», «Due esami a scelta libera da 6 CFU»): «Esame a
  scelta libera» (numerato se più di uno nello stesso piano e anno);
- senza intestazione, più voci con un solo CFU (senza «(N cfu)»): alternative tra loro (deduzione, nel log).
Ogni curriculum ha il suo piano: una riga uguale in tutti i curricula (stesso anno, nome, CFU e obbligatorietà) vale per
tutti, le altre hanno i propri curricula. Il controllo contro la riga «TOTALE CFU» è in `RIEPILOGO` (per la
verifica dei CFU). Niente docenti né libri (non sono nelle guide).
"""
from __future__ import annotations

import io
import json
import math
import pathlib
import re
import time
import unicodedata

from .unibo import Client

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://dipartimento.unistrasi.it"
PAGINE = ["/1/92/Didattica.htm", "/1/153/1585/I_nostri_Corsi_di_Laurea_Triennale.htm",
          "/1/154/1599/I_nostri_Corsi_di_Laurea_Magistrale.htm"]
ROMANI = {"I": 1, "II": 2, "III": 3}
TRATTINI = str.maketrans({c: "-" for c in "‐‑‒–—―−"})
NUOVO = r"[A-Z]{3,5}\s?-\s?\d{2}\s?/\s?(?:-\s?)?[A-Za-z]"        # ITAL-01/A, «ASIA -01/G», «HIST-02/ - A»
VECCHIO = r"[A-Z]{1,4}(?:-[A-Z]{2,5})?/\d{2}[A-Z]?"            # M-STO/08, SPS/06, PHIL/04B
OPT = re.compile(rf"^(?:L-\s+)?(?P<ssd>{NUOVO}|{VECCHIO})(?![a-z0-9])\s*-*\s*(?P<nome>\S.*)?$")
# errori di battitura dei settori nelle guide (lo stesso nome ha il settore giusto altrove nella guida)
SSD_ERRATI = {"ARC-01/C": "ARCH-01/C", "FMLR-01/B": "FLMR-01/B", "GIU-09/A": "GIUR-09/A"}
INTESTAZIONE = re.compile(r"(?i)\b(scelta|scelte|scelti|legata|modulo)\b|\b(?:fra|tra):?$|"
                          r"^laboratorio di traduzione della prima lingua")
MARCATORE = re.compile(r"^\s*(?:CURRIC(?:OLO|ULUM)\s*:\s*|LAUREA MAGISTRALE IN\s+)(.+)$", re.I)
FINE_NOME = re.compile(r"^\s*a\.?\s?a\.?\s*20\d\d", re.I)
LIBERA = "Esame a scelta libera"

DEDUZIONI: list[str] = []   # cose non scritte sulla fonte (CFU per esame calcolati, alternative senza intestazione)
RIEPILOGO: list[dict] = []  # per corso, curriculum e anno: somma dei CFU delle celle contro il «TOTALE CFU» della guida


# --------------------------------------------------------------------------------------------------------------------
# lettura del PDF
# --------------------------------------------------------------------------------------------------------------------
def _larghezza(fd, testo: str, corpo: float) -> float:
    try:
        w = fd.get("/Widths")
        primo = int(fd.get("/FirstChar", 0))
        w = [float(x) for x in w] if w is not None else None
    except Exception:  # noqa: BLE001
        w, primo = None, 0
    tot = 0.0
    for c in testo:
        try:
            b = c.encode("cp1252")[0]
        except Exception:  # noqa: BLE001
            b = ord(c) & 255
        tot += w[b - primo] if (w and 0 <= b - primo < len(w)) else 500
    return tot / 1000 * corpo


def _frammenti(pagina) -> list[tuple]:
    out = []

    def v(testo, cm, tm, fd, fs):
        if not testo or not testo.strip():
            return
        x = tm[4] * cm[0] + tm[5] * cm[2] + cm[4]
        y = tm[4] * cm[1] + tm[5] * cm[3] + cm[5]
        corpo = (fs or 10) * (math.hypot(tm[0], tm[1]) or 1) * (math.hypot(cm[0], cm[1]) or 1)
        out.append((y, x, testo, _larghezza(fd or {}, testo, corpo), corpo))
    pagina.extract_text(visitor_text=v)
    return out


def _rettangoli(reader, pagina) -> dict:
    """{(y, altezza): {(x, larghezza), …}} dei rettangoli delle celle (non i bordi sottili né il foglio)."""
    from pypdf.generic import ContentStream
    per: dict = {}
    for ops, op in ContentStream(pagina.get_contents(), reader).operations:
        if op == b"re":
            x, y, w, h = (float(a) for a in ops)
            if h >= 3 and 20 <= w < 560 and h < 700:
                per.setdefault((round(y, 1), round(h, 1)), set()).add((round(x, 1), round(w, 1)))
    return per


def _unisci(frs: list[tuple]) -> str:
    s, fine = "", None
    for _, x, t, w, corpo in sorted(frs, key=lambda a: a[1]):
        if fine is not None and x - fine > 0.18 * corpo and not s.endswith(" ") and not t.startswith(" "):
            s += " "
        s += t
        fine = x + w
    return re.sub(r"\s+", " ", s).strip()


def _righe(frs: list[tuple], tol: float = 2.0) -> list[tuple[float, str]]:
    out, cur, cy = [], [], None
    for f in sorted(frs, key=lambda a: (-a[0], a[1])):
        if cy is None or abs(f[0] - cy) <= tol:
            cur.append(f)
            cy = f[0] if cy is None else cy
        else:
            out.append((cy, _unisci(cur)))
            cur, cy = [f], f[0]
    if cur:
        out.append((cy, _unisci(cur)))
    return [(y, t) for y, t in out if t]


def _elementi(reader, pagina) -> list[tuple]:
    """Dall'alto in basso: (y, 'cella', righe, testo dei CFU) e (y, 'testo', riga, None) fuori dalle celle."""
    fr = _frammenti(pagina)
    celle = []
    for (y, h), lst in _rettangoli(reader, pagina).items():
        lst = sorted(lst)
        if lst[0][0] > 120 or lst[0][1] < 250:  # la cella di sinistra: vicina al margine e larga
            continue
        celle.append((y, h, lst[1][0] - 2 if len(lst) > 1 else None))
    celle.sort(key=lambda c: -c[0])
    usati: set[int] = set()
    els = []
    for y, h, soglia in celle:
        dentro = [i for i, f in enumerate(fr) if y - 1.5 <= f[0] <= y + h + 1.5 and i not in usati]
        usati.update(dentro)
        sx = [fr[i] for i in dentro if soglia is None or fr[i][1] < soglia]
        dx = [fr[i] for i in dentro if soglia is not None and fr[i][1] >= soglia]
        els.append((y + h, "cella", [t for _, t in _righe(sx)], " ".join(t for _, t in _righe(dx))))
    for y, t in _righe([f for i, f in enumerate(fr) if i not in usati and f[0] > 1]):
        els.append((y, "testo", t, None))
    els.sort(key=lambda e: -e[0])
    return els


def _classi(reader) -> set[str]:
    testo = " ".join((reader.pages[n].extract_text() or "") for n in range(min(10, len(reader.pages))))
    out: set[str] = set()
    for m in re.finditer(r"CLASSE\s+((?:LM|L)\s*-?\s*\d+(?:\s*/\s*(?:LM|L)\s*-?\s*\d+)*)", testo):
        for c in re.findall(r"(LM|L)\s*-?\s*(\d+)", m.group(1)):
            out.add(f"{c[0]}-{int(c[1])}")
    return out


def leggi_guida(data: bytes) -> tuple[set[str], list[dict]]:
    """(classi di laurea della guida, piani): un piano per curriculum e anno, con le celle [righe, testo dei CFU]
    (le celle che continuano sulla pagina dopo sono già unite) e il testo dei CFU del «TOTALE CFU»."""
    import pypdf
    reader = pypdf.PdfReader(io.BytesIO(data))
    piani: list[dict] = []
    curriculum, cur, nome = None, None, None
    for n, pagina in enumerate(reader.pages, 1):
        for _, tipo, a, b in _elementi(reader, pagina):
            if tipo == "testo":
                if nome is not None:  # il nome del curriculum continua a capo fino a «a.a. 2026/2027» (al più 3 righe)
                    if FINE_NOME.match(a):
                        curriculum, nome = " ".join(nome), None
                        continue
                    if len(nome) < 3 and a.upper() == a and not MARCATORE.match(a):
                        nome.append(a)
                        continue
                    nome = None  # non era l'intestazione di un curriculum (un titolo nel testo della guida)
                m = MARCATORE.match(a)
                if m and len(a) < 120:
                    if FINE_NOME.search(m.group(1)):
                        curriculum = re.split(r"\s+a\.?\s?a\.?\s*20", m.group(1), flags=re.I)[0].strip()
                    else:
                        nome = [m.group(1)]
                continue
            righe, cfu = a, b
            if righe and re.match(r"^\s*I{1,3}\s+anno\b", righe[0]):
                if nome is not None:
                    curriculum, nome = " ".join(nome), None
                cur = {"curriculum": curriculum, "anno": ROMANI[re.match(r"^\s*(I{1,3})", righe[0]).group(1)],
                       "celle": [], "totale": None, "pagina": n, "nota": righe[0]}
                piani.append(cur)
                continue
            if cur is None or cur["totale"] is not None:
                continue
            if re.match(r"(?i)\s*(totale cfu|cfu totali)", " ".join(righe)):
                cur["totale"] = cfu
                continue
            if not righe and not cfu:
                continue
            if not cfu and cur["celle"]:
                cur["celle"][-1][0].extend(righe)  # la cella continua dalla pagina prima
            else:
                cur["celle"].append([list(righe), cfu])
    return _classi(reader), [p for p in piani if p["celle"]]


# --------------------------------------------------------------------------------------------------------------------
# significato delle celle
# --------------------------------------------------------------------------------------------------------------------
def _nome(t: str) -> str:
    t = re.sub(r"\s*\(\s*\d+\s*cfu\s*\)", "", t, flags=re.I)
    t = re.sub(r"\s+", " ", t.strip(" ,;:-*"))
    t = re.sub(r"(?<=[a-zà-ù])(\d)$", r" \1", t)  # «Letteratura e cultura cinese1»
    if t.isupper():
        t = t.capitalize()
    return t[:1].upper() + t[1:]


def _ssd(s: str) -> str:
    s = re.sub(r"\s+", "", s).replace("/-", "/")
    s = re.sub(r"^([A-Z]{3,5})/(\d{2})([A-Z])$", r"\1-\2/\3", s)
    s = re.sub(r"/([a-z])$", lambda m: "/" + m.group(1).upper(), s)
    return SSD_ERRATI.get(s, s)


def _pulisci(righe: list[str]) -> list[str]:
    out = []
    for r in righe:
        t = r.translate(TRATTINI)
        t = re.sub(r"\(\s*tace[^)]*\)", "", t, flags=re.I)   # (TACE): non attivato quest'anno, ma è nel piano
        t = re.sub(r"\*+", "", t)
        t = re.sub(r"^\s*[-•·]\s*", "", t)
        t = re.sub(r"\s+", " ", t).strip()
        if t:
            out.append(t)
    return out


def _numero(testo: str) -> int:
    t = re.sub(r"\d+\s*[°º]", " ", testo)
    t = re.sub(r"(?i)\(\s*\d+\s*cfu\s*\)|\bda\s+\d+\s*cfu", " ", t)
    m = re.search(r"(?i)\b(due|2|tre|3)\b", t)
    return {"due": 2, "2": 2, "tre": 3, "3": 3}[m.group(1).lower()] if m else 1


def _cfu_scritti(testo: str) -> int | None:
    m = re.search(r"(?i)\(\s*(\d+)\s*cfu\s*\)|\bda\s+(\d+)\s*cfu", testo)
    return int(m.group(1) or m.group(2)) if m else None


def _token(righe: list[str]) -> list[dict]:
    toks = []
    for r in righe:
        if re.fullmatch(r"(?i)oppure|o", r):
            toks.append({"k": "OPPURE"})
            continue
        if re.fullmatch(r"(?i)e", r):
            toks.append({"k": "E"})
            continue
        m = re.match(r"(?i)^o tra (.*)$", r)
        if m:
            toks += [{"k": "OPPURE"}, {"k": "H", "t": m.group(1)}]
            continue
        coppia = oppure = False
        if re.search(r"(?i)\s+oppure$", r):
            r, oppure = re.sub(r"(?i)\s+oppure$", "", r), True
        m = OPT.match(r)
        if m and re.search(r"\s+e$", r):  # «A e / B»: le voci della cella sono tutte richieste (se la riga dopo non la
            coppia = True                  # continua, vedi _gruppi)
        if not m and " / " in r:  # «Laboratorio A / Laboratorio B»: due alternative
            a, b = r.split(" / ", 1)
            toks += [{"k": "TXT", "t": a.strip(), "cfu": None, "coppia": False}, {"k": "OPPURE"}]
            r = b.strip()
        if m and m.group("nome"):
            toks.append({"k": "OPT", "ssd": _ssd(m.group("ssd")), "t": m.group("nome").strip(),
                         "cfu": _cfu_scritti(m.group("nome")), "coppia": coppia})
        elif INTESTAZIONE.search(r) and not m:
            toks.append({"k": "H", "t": r})
        else:
            toks.append({"k": "TXT", "t": r, "cfu": _cfu_scritti(r), "coppia": coppia})
        if oppure:
            toks.append({"k": "OPPURE"})
    return toks


def _gruppi(seg: list[dict]) -> list[dict]:
    gs, cur = [], None
    for t in seg:
        if t["k"] == "H":
            cur = {"h": t["t"], "opz": []}
            gs.append(cur)
        elif t["k"] in ("OPT", "TXT"):
            if t["k"] == "TXT" and cur and cur["opz"] and t["t"][:1].islower():
                cur["opz"][-1]["t"] += " " + t["t"]   # nome andato a capo
                cur["opz"][-1]["coppia"] = False
                continue
            if cur is None:
                cur = {"h": None, "opz": []}
                gs.append(cur)
            cur["opz"].append(dict(t))
        else:  # «e» da solo: i gruppi seguenti sono nuovi
            cur = None
    for g in gs:
        for o in g["opz"]:
            if o.get("coppia"):
                o["t"] = re.sub(r"\s+e$", "", o["t"])
    return [g for g in gs if g["opz"] or (g["h"] and re.search(r"(?i)\bscelta\b", g["h"]))]


def leggi_cella(righe: list[str], cfu_testo: str, dove: str) -> tuple[list[dict], int | None]:
    """Gli insegnamenti di una cella [{nome, ssd, cfu, scelta}] e i suoi CFU (None se non scritti)."""
    righe = _pulisci(righe)
    nums = [int(x) for x in re.findall(r"\d+", cfu_testo or "")]
    parti: list[int] = nums if "+" in (cfu_testo or "") and len(nums) > 1 else []
    if parti:
        totale = sum(parti)
    elif nums:
        totale = nums[0]
        if len(set(nums)) > 1:
            DEDUZIONI.append(f"{dove}: più cifre diverse nella colonna CFU della cella ({cfu_testo!r}); ignorata")
            totale = None
        elif len(nums) > 1:
            DEDUZIONI.append(f"{dove}: cifra doppia nella colonna CFU della cella ({cfu_testo!r}) letta come {totale} "
                             f"(col «TOTALE CFU» della guida quadra solo così)")
    else:
        totale = None
    toks = _token(righe)
    segs: list[list[dict]] = [[]]
    for t in toks:
        if t["k"] == "OPPURE":
            segs.append([])
        else:
            segs[-1].append(t)
    segs = [s for s in segs if s]
    ha_oppure = len(segs) > 1
    piano = []  # (segmento, gruppo, tipo, n)
    for si, seg in enumerate(segs):
        for g in _gruppi(seg):
            h, opz = g["h"], g["opz"]
            if not opz:
                tipo, n = "libera", _numero(h)
            elif h and re.match(r"(?i)laboratorio di traduzione della prima lingua", h):
                tipo, n = "laboratorio", 1
            elif any(o.get("coppia") for o in opz):
                tipo, n = "coppia", len(opz)
            elif h and re.search(r"(?i)\b(scelta|scelte|scelti|legata|fra|tra)\b", h):
                tipo, n = "scelta", _numero(h)
            elif all(o.get("cfu") for o in opz) and len(opz) > 1:
                tipo, n = "modulo", 0
            elif len(opz) == 1:
                tipo, n = "singolo", 1
            else:  # più voci con un solo CFU e nessuna indicazione: alternative tra loro
                tipo, n = "alternative", 1
                DEDUZIONI.append(f"{dove}: «{' / '.join(_nome(o['t']) for o in opz)}» ({totale} CFU) senza indicazione "
                                 f"di quanti esami: letti come alternative tra loro")
            piano.append((si, g, tipo, n, _cfu_scritti(h or "")))
    # CFU per esame
    conta = [0] * max(len(segs), 1)
    for si, g, tipo, n, scr in piano:
        if tipo != "modulo" and not scr and not (tipo == "singolo" and g["opz"][0].get("cfu")):
            conta[si] += n
    esami = max(conta) if conta else 0
    out: list[dict] = []
    unita = iter(parti)
    for si, g, tipo, n, scr in piano:
        opz = g["opz"]
        scelta_alt = ha_oppure
        if tipo == "libera":
            per = scr or (parti and next(unita, None)) or (None if totale is None else totale / (esami or 1))
            for k in range(n):
                out.append({"nome": LIBERA, "ssd": None, "cfu": _int(per), "scelta": True, "libera": True})
            continue
        if tipo == "laboratorio":
            per = next(unita, None) if parti else totale
            out.append({"nome": _nome(g["h"]), "ssd": None, "cfu": _int(per), "scelta": scelta_alt})
            continue
        if tipo == "modulo":
            for o in opz:
                out.append({"nome": _nome(o["t"]), "ssd": o.get("ssd"), "cfu": o["cfu"], "scelta": scelta_alt})
            continue
        if parti:
            per = next(unita, None)
            if per is not None and tipo == "scelta" and n > 1:
                per = per / n
        elif scr:
            per = scr
        elif totale is None:
            per = None
        else:
            per = totale / (esami or 1)
            if esami > 1:
                DEDUZIONI.append(f"{dove}: {totale} CFU / {esami} esami = {per:g} a esame "
                                 f"(«{_nome(g['h'] or opz[0]['t'])}…»)")
        scelta = tipo in ("scelta", "alternative") or scelta_alt
        for o in opz:
            out.append({"nome": _nome(o["t"]), "ssd": o.get("ssd"), "scelta": scelta,
                        "cfu": _int(o["cfu"] if o.get("cfu") else per)})
    return out, totale


def _int(v):
    if v is None:
        return None
    return int(v) if float(v).is_integer() else round(float(v), 1)


def _titolo_curriculum(c: str | None) -> str | None:
    if not c:
        return None
    c = re.sub(r"\s+", " ", c).strip().lower()
    return (c[:1].upper() + c[1:]).replace(",", " –")  # (la virgola separa i percorsi nel database)


# --------------------------------------------------------------------------------------------------------------------
# piani -> insegnamenti del corso
# --------------------------------------------------------------------------------------------------------------------
def _insegnamenti_piano(piano: dict, dove: str) -> tuple[list[dict], int | None]:
    voci: list[dict] = []
    somma, completo = 0, True
    for k, (righe, cfu) in enumerate(piano["celle"], 1):
        items, tot = leggi_cella(righe, cfu, f"{dove} cella {k}")
        if tot is None:
            completo = False
        else:
            somma += tot
        voci += items
    # stessa voce due volte nello stesso anno: crediti liberi numerati, altre uguali una volta sola
    liberi = [v for v in voci if v.get("libera")]
    for n, v in enumerate(liberi, 1):
        if len(liberi) > 1:
            v["nome"] = f"{LIBERA} {n}"
    visti: dict[tuple, dict] = {}
    out = []
    for v in voci:
        key = (v["nome"].lower(), v["scelta"])
        if key in visti and not v.get("libera"):
            if visti[key]["cfu"] != v["cfu"] and v["cfu"] is not None:
                v["nome"] = f"{v['nome']} ({v['cfu']:g} CFU)"
                key = (v["nome"].lower(), v["scelta"])
                if key in visti:
                    continue
            else:
                continue
        visti[key] = v
        out.append(v)
    return out, (somma if completo else None)


def _totale(testo: str | None) -> int | None:
    nums = re.findall(r"\d+", testo or "")
    return int(nums[0]) if nums else None


def costruisci_corso(corso: dict, fonte: str, piani: list[dict], oggi: str, log=print) -> dict:
    curricula = []
    for p in piani:
        c = _titolo_curriculum(p["curriculum"])
        if c and c not in curricula:
            curricula.append(c)
    righe: dict[tuple, dict] = {}
    for p in piani:
        cur = _titolo_curriculum(p["curriculum"])
        dove = f"{corso['id']} {cur or '-'} anno {p['anno']}"
        voci, somma = _insegnamenti_piano(p, dove)
        tot = _totale(p["totale"])
        RIEPILOGO.append({"corso": corso["id"], "curriculum": cur, "anno": p["anno"], "somma_celle": somma,
                          "totale_guida": tot, "celle": len(p["celle"]), "pagina": p["pagina"], "fonte": fonte,
                          "intestazione": p["nota"]})
        if somma != tot:
            log(f"[unistrasi]   {dove}: celle {somma}, totale della guida {tot}")
        for v in voci:
            key = (p["anno"], v["nome"].lower(), v["cfu"], v["scelta"])
            item = righe.get(key)
            if not item:
                item = righe[key] = {
                    "codice": None, "nome": v["nome"], "anno": p["anno"], "periodo": None, "cfu": v["cfu"],
                    "ssd": v["ssd"], "obbligatorio": False if v["scelta"] else True, "curriculum": None,
                    "docenti": [], "url": fonte, "libri": [], "esami": [], "fonte": fonte, "verificato_il": oggi,
                    "stato_libri": "da_aggiungere", "_c": set()}
            item["_c"].add(cur)
            if not item["ssd"]:
                item["ssd"] = v["ssd"]
    for i in righe.values():
        cs = i.pop("_c")
        if len(curricula) > 1 and None not in cs and cs != set(curricula):
            i["curriculum"] = ", ".join(sorted(cs))
    _nomi_distinti(righe)
    _id_espliciti(corso["id"], righe)
    return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
            "durata_anni": corso.get("durata_anni"), "url": corso.get("url"),
            "curricula": curricula if len(curricula) > 1 else None, "fonte": fonte, "verificato_il": oggi,
            "insegnamenti": sorted(righe.values(), key=lambda i: (i["anno"], not i["obbligatorio"], i["nome"]))}


def _slug(s: str, maxlen: int) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip().replace(" ", "-")[:maxlen].strip("-")


def _nomi_distinti(righe: dict) -> None:
    """Lo stesso nome nello stesso anno con CFU diversi (in curricula diversi) porta i CFU nel nome: build_db le
    fonderebbe in una riga sola (stesso id), perdendo uno dei due valori."""
    per: dict[tuple, list[dict]] = {}
    for i in righe.values():
        per.setdefault((i["anno"], i["nome"].lower(), i["obbligatorio"]), []).append(i)
    for lst in per.values():
        if len(lst) > 1:
            for i in lst:
                if i["cfu"] is not None:
                    i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"


def _id_espliciti(corso_id: str, righe: dict) -> None:
    """build_db tronca lo slug dell'id a 40 caratteri: due insegnamenti diversi con lo stesso inizio di nome nello stesso
    anno si fonderebbero (es. i due «Laboratorio di comprensione testi e scrittura …»): hanno un id esplicito."""
    per: dict[tuple, list[dict]] = {}
    for i in righe.values():
        per.setdefault((_slug(i["nome"], 40), i["anno"], i["obbligatorio"] is False), []).append(i)
    usati: set[str] = set()
    for lst in per.values():
        if len({i["nome"].lower() for i in lst}) > 1:
            for i in lst:
                base = f"{corso_id}-{_slug(i['nome'], 90)}"
                nuovo = base
                for suff in (f"-a{i['anno']}", f"-a{i['anno']}-{'scelta' if i['obbligatorio'] is False else 'obbl'}"):
                    if nuovo in usati:
                        nuovo = base + suff
                usati.add(nuovo)
                i["id"] = nuovo


def _guide_nelle_pagine(c: Client, anno: int, corsi: list[dict], log=print) -> dict[str, str]:
    """{url della guida: pagina del corso che la linka (se è la pagina di un solo corso)}."""
    guide: dict[str, str] = {}
    rx = rf"https?://online\.unistrasi\.it/docenti/Guide/{anno}/[\w.-]+\.pdf"
    singole = re.compile(r"href=['\"](https://dipartimento\.unistrasi\.it/(?:1/2\d\d/[^'\"]+\.htm|Articolo\?[^'\"]*"
                         r"Codice=LM?_\w+[^'\"]*))['\"]")
    for u in [x.get("url") for x in corsi if x.get("url")] + [BASE + p for p in PAGINE]:
        r = c.get(u)
        testo = r.text if r else ""
        for g in re.findall(rx, testo):
            guide.setdefault(g, u)
        for h in dict.fromkeys(singole.findall(testo)):
            rh = c.get(h.replace("&amp;", "&"))
            for g in re.findall(rx, rh.text if rh else ""):
                guide[g] = rh.url if hasattr(rh, "url") else h
    return guide


def fetch_ateneo(uid: str = "unistrasi", anno: int | None = None, max_cds: int | None = None,
                 syllabus: bool = True, corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=2.0)
    oggi = time.strftime("%Y-%m-%d")
    DEDUZIONI.clear()
    RIEPILOGO.clear()
    guide = _guide_nelle_pagine(c, anno, corsi, log)
    per_classe: dict[frozenset, list[tuple[str, str, list[dict]]]] = {}
    for g, pagina in sorted(guide.items()):
        try:
            with c.lock:
                c.requests += 1
            rg = c.s.get(g, timeout=120)
            classi, piani = leggi_guida(rg.content) if rg.content[:5] == b"%PDF-" else (set(), [])
        except Exception as e:  # noqa: BLE001
            log(f"[{uid}]   {g}: {e!r}")
            continue
        if classi and piani:
            per_classe.setdefault(frozenset(classi), []).append((g, pagina, piani))
        else:
            log(f"[{uid}]   {g}: classe o piano non riconosciuti")
    out = []
    for corso in corsi:
        cl = frozenset(re.sub(r"\s+", "", x) for x in (corso.get("classe") or "").split("/") if x.strip())
        cand = per_classe.get(cl) or [x for k, v in per_classe.items() if k & cl for x in v]
        if len(cand) != 1:
            continue
        fonte, pagina, piani = cand[0]
        x = costruisci_corso(corso, fonte, piani, oggi, log)
        if pagina and re.search(r"/1/2\d\d/", pagina) and not re.search(r"/1/2\d\d/", corso.get("url") or ""):
            x["url"] = pagina  # il corso nel database ha l'elenco dei corsi (L-1, LM-2/LM-89) o una pagina rotta (LM-38)
        out.append(x)
    for d in DEDUZIONI:
        log(f"[{uid}]   {d}")
    log(f"[{uid}] {len(guide)} guide, {len(out)} corsi (su {len(corsi)}), "
        f"{sum(len(x['insegnamenti']) for x in out)} insegnamenti; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dalle guide didattiche di dipartimento.unistrasi.it "
                                                 "(adapters/unistrasi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
