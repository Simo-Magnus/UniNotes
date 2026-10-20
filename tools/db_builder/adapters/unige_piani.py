"""Piani di studio dell'Università di Genova dal Manifesto degli studi (servizionline.unige.it).

La pagina del corso su corsi.unige.it rimanda a tre stampe del servizio «stampa_manifesto»:

- `MF/<a.a.>/<codice corso>.html`: Manifesto degli studi, con il piano di ogni anno e di ogni
  coorte attiva nell'a.a. («1° anno (coorte 2026/2027)», «2° anno (coorte 2025/2026)», …) e, per ogni
  curriculum, gli insegnamenti obbligatori (con i loro moduli), i gruppi di scelta («18 CFU da
  acquisirsi dal 2° al 3° anno», «12 CFU tra i seguenti insegnamenti», «1 insegnamenti relativi
  alla lingua 1») e le attività a scelta dello studente, ognuno con codice, settore, CFU, tipologia e
  docenti. Dopo un riordino le coorti vecchie stanno nel manifesto del codice del vecchio ordinamento
  (collegato dalla pagina degli insegnamenti: `unige.leggi_elenco`), anche a catena (Farmacia 5° anno);
- `PD/<a.a.>/<codice>.html`: Programmazione didattica della coorte dell'a.a. per tutti gli anni di corso,
  usata solo per gli anni che nessun manifesto ha ancora (corsi nuovi del 2025 e 2026: Computer
  Engineering L-8, Ingegneria meccanica per l'automazione, Osteopatia).

Questo modulo non scarica nulla: legge le pagine che gli passa `unige.fetch_ateneo` (con la cache HTTP) e
restituisce le righe del piano per anno e curriculum.

Regole:
- un insegnamento integrato (riga con i moduli sotto) resta il solo contenitore se i CFU dei moduli non
  fanno il suo totale, altrimenti restano i soli moduli (`modulo_di` = contenitore), così i CFU
  dell'anno non si contano due volte (stessa regola di unipa/unilink);
- gruppi senza intestazione: obbligatori (le righe «A SCELTA» o «A scelta dello studente» sono a scelta);
- gruppi con intestazione «N CFU …»: a scelta, salvo che gli insegnamenti elencati sommino proprio N CFU
  (allora si sostengono tutti); la riga senza CFU del gruppo («A scelta tra gli insegnamenti attivati
  nell'ateneo») diventa una voce a scelta con gli N CFU del gruppo, una volta sola nel primo anno
  in cui il gruppo compare;
- «Da N a M CFU»: la riga libera prende il minimo N;
- «N insegnamenti relativi alla lingua K»: N a scelta tra gli insegnamenti elencati;
- «Parte di insegnamento su più anni»: modulo di un integrato che continua dall'anno prima, come riga normale.
"""
from __future__ import annotations

import html as _h
import re

BASE_SERVIZI = "https://servizionline.unige.it/unige/stampa_manifesto"
SEDI = {"CHIAVARI": "CV", "GENOVA ASL 3": "AS", "GENOVA E.O. OSPEDALI GALLIERA": "GL", "IMPERIA": "IM",
        "LA SPEZIA": "SP", "SAVONA": "SV"}
NOME_SEDE = {"CV": "Chiavari", "AS": "Genova ASL 3", "GL": "Genova E.O. Ospedali Galliera", "IM": "Imperia",
             "LA SPEZIA": "La Spezia", "SP": "La Spezia", "SV": "Savona", "GE": "Genova"}


def _t(s: str | None) -> str:
    s = re.sub(r"<br\s*/?>", " ", s or "")
    s = re.sub(r"<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", _h.unescape(s)).strip()


def url_mf(codice: str, anno: int = 2026) -> str:
    return f"{BASE_SERVIZI}/MF/{anno}/{codice}.html"


def url_pd(codice: str, anno: int = 2026) -> str:
    return f"{BASE_SERVIZI}/PD/{anno}/{codice}.html"


def leggi(s: str) -> list[dict]:
    """Sezioni (una per sede) di una stampa MF o PD: anni (coorte, intestazione del curriculum) con i gruppi e le righe."""
    i = s.find('id="piano"')
    if i < 0:
        i = s.find("<!-- Anni di corso -->")
        if i < 0:
            return []
    b = s[i:]
    fine = b.find("<!-- Testi aggiuntivi -->")
    if fine > 0:
        b = b[:fine]
    sezioni = []
    for p in re.split(r"(?=<!-- Titolo per ogni classe -->)", b):
        if "<!-- Anni di corso -->" not in p:
            continue
        h2 = re.search(r"<h2>(.*?)</h2>", p, re.S)
        h2t = _t(h2.group(1)) if h2 else ""
        m = re.match(r"Sede\s+(\w+)\s*-\s*Classe\s+(.*)", h2t)
        sez = {"sede": m.group(1) if m else None, "classe": m.group(2) if m else h2t, "anni": []}
        for bl in re.split(r"(?=<h1>\d°\s*anno\s*\(coorte)", p):
            mh = re.match(r"<h1>(\d)°\s*anno\s*\(coorte\s*(\d{4})/(\d{4})\)</h1>", bl)
            if not mh:
                continue
            ic = re.search(r'<div class="intestazione_curriculum">(.*?)</div>', bl, re.S)
            raw = re.sub(r"<!--.*?-->", "", ic.group(1), flags=re.S) if ic else ""
            interno = re.findall(r"<span>([^<]*)</span>", raw)
            nomi = [_t(x) for x in interno if _t(x) and not re.match(r"(?i)comune ai curricula", _t(x))]
            if not nomi and _t(raw) and not re.match(r"(?i)comune ai curricula", _t(raw)):
                nomi = [_t(raw)]
            dopo = re.search(r"</table>(.*?)(?=<!--\s*Fine|<h1>|$)", bl, re.S)
            nota = re.search(r"conseguire anche\s+(\d+)\s*CFU\s+A SCELTA", _t(dopo.group(1)) if dopo else "", re.I)
            anno = {"anno": int(mh.group(1)), "coorte": int(mh.group(2)), "curricula": nomi, "gruppi": [],
                    "cfu_scelta_nota": int(nota.group(1)) if nota else None}
            for tb in re.findall(r"<tbody>(.*?)</tbody>", bl, re.S):
                g = {"testo": "", "righe": []}
                for tr in re.findall(r"<tr>(.*?)</tr>", tb, re.S):
                    if "nosideborder" in tr:
                        g["testo"] = (g["testo"] + " " + _t(tr)).strip()
                        continue
                    tds = re.findall(r"<td([^>]*)>(.*?)</td>", tr, re.S)
                    if len(tds) < 7:
                        continue
                    figlio = "rightBfiglio" in tds[0][0]
                    primo = re.search(r"<span[^>]*>(.*?)</span>", tds[1][1], re.S)
                    primo = primo.group(1) if primo else tds[1][1]
                    ancore = re.findall(r'<a [^>]*href="[^"]*?/ins/(\d+)(?:\.html)?[^"]*"[^>]*>(.*?)</a>', primo, re.S)
                    fuori = _t(re.sub(r"<a [^>]*>.*?</a>", "", primo, flags=re.S))
                    if figlio:
                        mm = re.match(r"\s*([0-9A-Za-z_.-]+)\s*-\s*(.*)$", fuori)
                        cod = mm.group(1) if mm else None
                        fuori = mm.group(2).strip() if mm else fuori
                    else:
                        cod = _t(tds[0][1]) or None
                    # corsi con canali (A, B): nome fuori dai link, una scheda per canale
                    if ancore and fuori and all(re.fullmatch(r"[A-Z0-9]{1,2}(?:\s*[,/-]\s*[A-Z0-9]{1,2})*", _t(t)) for _, t in ancore):
                        nome, schede = fuori, [i for i, _ in ancore]
                    elif ancore:
                        nome, schede = _t(ancore[0][1]), [i for i, _ in ancore][:1]
                    else:
                        nome, schede = fuori, []
                    resto = _t(re.sub(r"<a [^>]*>.*?</a>", "", tds[1][1], flags=re.S))
                    per = re.search(r"\(([^)]*(?:Semestre|Annuale|Bimestre|Trimestre|Quadrimestre)[^)]*)\)", resto, re.I)
                    g["righe"].append({
                        "figlio": figlio, "codice": cod, "nome": nome, "scheda": schede[0] if schede else None, "schede": schede,
                        "periodo": per.group(1) if per else None, "ssd": _t(tds[2][1]) or None,
                        "cfu_t": _t(tds[3][1]), "tip": _t(tds[4][1]),
                        "docenti": [_t(x) for x in re.findall(r"<span[^>]*>(.*?)</span>", tds[5][1], re.S) if _t(x)],
                    })
                if g["righe"] or g["testo"]:
                    anno["gruppi"].append(g)
            sez["anni"].append(anno)
        sezioni.append(sez)
    return sezioni


def _num(t: str) -> float | None:
    try:
        v = float(t.replace(",", "."))
    except ValueError:
        return None
    return int(v) if v.is_integer() else v


_ROMANO = {"i": "I", "ii": "II", "iii": "III", "iv": "IV", "v": "V"}


def nome_pulito(n: str) -> str:
    """Nome in maiuscolo del manifesto → iniziali maiuscole, numeri romani e apostrofi come nel resto del database."""
    from .unibo import _titolo
    n = re.sub(r"\s+", " ", n).strip()
    if n.isupper():
        n = _titolo(n)
        p = n.split(" ")
        for k, w in enumerate(p):
            if w.lower() in _ROMANO and k and (k == len(p) - 1 or p[k + 1].lower() in ("anno", "modulo", "parte")):
                p[k] = _ROMANO[w.lower()]
        n = " ".join(p)
    n = re.sub(r"(?<=[A-Za-zà-ù])([aeiouAEIOU])'(?=\s|$)",
               lambda m: {"a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù"}[m.group(1).lower()], n)
    n = re.sub(r"\b(Dell|All|Nell|Sull|Dall|Sugl|Un|L)'([a-zà-ù])", lambda m: m.group(1) + "'" + m.group(2).upper(), n)
    return n


def nome_curriculum(n: str, sedi: set[str]) -> str:
    """«CLASSICO - GE» → «Classico»; niente virgole (separano i percorsi in pulizia.percorsi)."""
    from .unibo import _titolo
    n = re.sub(r"\s+", " ", _h.unescape(n)).strip()
    m = re.match(r"(.*?)\s*-\s*([A-Z]{2})$", n)
    if m and m.group(2) in sedi:
        n = m.group(1)
    n = _titolo(n) if n.isupper() else n
    n = re.sub(r"\s*,\s*", " - ", n)
    return n[:1].upper() + n[1:]


def sede_di_curriculum(n: str, sedi: set[str]) -> str | None:
    m = re.search(r"-\s*([A-Z]{2})\s*$", _h.unescape(n).strip())
    return m.group(1) if m and m.group(1) in sedi else None


def sede_del_corso(nome_corso: str) -> str | None:
    """Sede di una replica dal nome di Universitaly («… REPLICA sede CHIAVARI»)."""
    m = re.search(r"(?i)replica\s+sede\s+(.+?)\s*$", nome_corso or "")
    if not m:
        return None
    chiave = re.sub(r"\s+", " ", m.group(1)).strip().upper()
    return SEDI.get(chiave)


def blocchi_per_sede(sezioni: list[dict], sede: str | None) -> tuple[list[dict], bool]:
    """Blocchi (anno, curricula, gruppi) della sede del corso. `sede`: codice della replica o None per il corso principale.
    Restituisce anche se la scelta è certa (una sola sede, o sede indicata)."""
    codici = set()
    for z in sezioni:
        if z["sede"]:
            codici.add(z["sede"])
        for a in z["anni"]:
            for n in a["curricula"]:
                m = re.search(r"-\s*([A-Z]{2})\s*$", _h.unescape(n).strip())
                if m:
                    codici.add(m.group(1))
    tutti = [dict(a, sede_sezione=z["sede"], classe=z["classe"]) for z in sezioni for a in z["anni"]]
    if len(codici) <= 1:
        return tutti, True
    if sede and sede in codici:
        scelta, certa = sede, True
    else:
        scelta = next((c for c in ("ST", "GE") if c in codici), sorted(codici)[0])
        certa = False
    out = []
    for a in tutti:
        sedi_blocco = {a["sede_sezione"]} if a["sede_sezione"] else \
            {s for s in (sede_di_curriculum(n, codici) for n in a["curricula"]) if s}
        if not sedi_blocco or scelta in sedi_blocco:
            out.append(a)
    return out, certa


def righe_blocco(blocco: dict, k_anno: int) -> list[dict]:
    """Righe di un blocco (un anno di un curriculum): dicts con nome, codice, scheda, cfu, obbligatorio, gruppo, modulo_di."""
    out: list[dict] = []
    for gid, g in enumerate(blocco["gruppi"]):
        # righe di primo livello con i loro moduli
        livello1: list[dict] = []
        for r in g["righe"]:
            if r["figlio"] and livello1 and not livello1[-1].get("orfano"):
                livello1[-1]["moduli"].append(r)
            elif r["figlio"]:  # modulo senza contenitore (continua da un anno prima)
                livello1.append(dict(r, moduli=[], orfano=True))
            else:
                livello1.append(dict(r, moduli=[]))
        testo = g["testo"]
        semplice = not testo or testo.startswith("Parte di insegnamento")
        n_cfu = None
        spread = None
        lingua = False
        if testo and not semplice:
            mm = re.match(r"(?:Da\s+)?(\d+)\s*(a\s*\d+\s*)?CFU", testo)
            if mm:
                n_cfu = int(mm.group(1))
            lingua = bool(re.match(r"(?:Da\s+)?\d+\s*(?:a\s*\d+\s*)?insegnamenti relativi", testo))
            ms = re.search(r"dal\s+(\d)°\s+al\s+(\d)°\s+anno", testo)
            if ms:
                spread = (int(ms.group(1)), int(ms.group(2)))
        voci = []
        for r in livello1:
            cfu = _num(r["cfu_t"])
            moduli = [m for m in r["moduli"] if _num(m["cfu_t"]) is not None]
            if moduli and cfu is not None and len(moduli) == len(r["moduli"]) and                     abs(sum(_num(m["cfu_t"]) for m in moduli) - cfu) < 1e-9:
                for m in moduli:
                    voci.append(dict(m, modulo_di=r["nome"], padre_codice=r["codice"], cfu=_num(m["cfu_t"])))
            else:
                voci.append(dict(r, cfu=cfu, modulo_di=None))
        somma = sum(v["cfu"] for v in voci if v["cfu"] is not None)
        con_libera = any(v["cfu"] is None for v in voci)
        tutti = bool(n_cfu and not lingua and not con_libera and abs(somma - n_cfu) < 1e-9 and not re.match(r"Da\s", testo))
        for v in voci:
            tip = v["tip"].upper()
            esplicita = "A SCELTA" in tip or bool(re.match(r"(?i)a scelta dello studente", v["nome"]))
            if semplice:
                a_scelta = esplicita
            elif lingua:
                a_scelta = True
            else:
                a_scelta = esplicita or not tutti
            out.append({
                "nome": v["nome"], "codice": v["codice"], "scheda": v["scheda"], "schede": v.get("schede") or [],
                "cfu": v["cfu"], "ssd": v["ssd"], "periodo": v["periodo"], "docenti": v["docenti"],
                "modulo_di": v["modulo_di"], "padre_codice": v.get("padre_codice"), "obbligatorio": not a_scelta, "gruppo": None if semplice else testo,
                "n_cfu": n_cfu, "spread": spread, "libera": bool(v["cfu"] is None and not semplice and n_cfu),
                "tip": v["tip"], "lingua": lingua, "gid": gid,
            })
    return out


def _chiave_curricula(nomi: list[str], sedi: set[str]) -> str | None:
    """Curricula di un blocco, separati da virgola; «Piano di studi comune» non è un curriculum (vale per tutti)."""
    n = [nome_curriculum(x, sedi) for x in nomi if not re.match(r"(?i)\s*piano di studi comune\s*$", _h.unescape(x))]
    return ", ".join(dict.fromkeys(n)) if n else None


def codici_sede(sezioni_per_codice: dict[str, list[dict]]) -> set[str]:
    out = set()
    for sezioni in sezioni_per_codice.values():
        for z in sezioni:
            if z["sede"]:
                out.add(z["sede"])
            for a in z["anni"]:
                for n in a["curricula"]:
                    m = re.search(r"-\s*([A-Z]{2})\s*$", _h.unescape(n).strip())
                    if m:
                        out.add(m.group(1))
    return out


def piano_corso(catena: list[str], durata: int, sede: str | None, leggi_mf, leggi_pd, anno_aa: int = 2026) -> dict[int, dict]:
    """Piano di ogni anno di corso: `catena` = codice del corso e dei vecchi ordinamenti; `leggi_mf(codice)` e
    `leggi_pd(codice)` danno il testo della stampa (o None). Restituisce {anno: {"fonte", "coorte", "da_pd", "blocchi": [
    {"curricula": [...], "righe": [...]}]}}; gli anni senza piano mancano."""
    mf = {c: leggi(t) for c in catena if (t := leggi_mf(c))}
    sedi = codici_sede(mf)
    out: dict[int, dict] = {}
    for k in range(1, durata + 1):
        target = anno_aa - k + 1
        cand = []  # (distanza coorte, posizione nella catena, codice, coorte, blocchi)
        for pos, c in enumerate(catena):
            if c not in mf:
                continue
            blocchi, _ = blocchi_per_sede(mf[c], sede)
            per_coorte: dict[int, list[dict]] = {}
            for b in blocchi:
                if b["anno"] == k:
                    per_coorte.setdefault(b["coorte"], []).append(b)
            for coorte, bl in per_coorte.items():
                cand.append((abs(coorte - target), pos, c, coorte, bl))
        if cand:
            cand.sort(key=lambda x: (x[0], x[1]))
            _, _, c, coorte, bl = cand[0]
            out[k] = {"fonte": url_mf(c, anno_aa), "coorte": coorte, "da_pd": False, "codice": c, "blocchi": bl}
            continue
        t = leggi_pd(catena[0])
        if t:
            pd = leggi(t)
            blocchi, _ = blocchi_per_sede(pd, sede)
            bl = [b for b in blocchi if b["anno"] == k]
            if bl:
                out[k] = {"fonte": url_pd(catena[0], anno_aa), "coorte": bl[0]["coorte"], "da_pd": True,
                          "codice": catena[0], "blocchi": bl}
    for k, v in out.items():
        v["sedi"] = sedi
        v["blocchi"] = [{"curricula": b["curricula"], "righe": righe_blocco(b, k), "anno": b["anno"],
                         "nota_scelta": b.get("cfu_scelta_nota"), "classe": b.get("classe")} for b in v["blocchi"]]
    return out
