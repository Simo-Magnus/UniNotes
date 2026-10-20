"""Insegnamenti, docenti e libri del Politecnico di Torino dal Portale della Didattica.

PoliTO non usa il Course Catalogue Cineca. Il piano completo di una coorte è pubblico:

- `didattica.polito.it/pls/portal30/sviluppo.offerta_formativa_2019.vis?p_coorte=<C>&p_sdu=<sdu>&p_cds=<cds>`
  (`p_coorte` = anno di fine dell'a.a. di immatricolazione: 2027 = coorte 2026/27) → percorsi,
  sezioni "N° anno AAAA/AAAA" con periodo, codice, SSD, nome, lingua, crediti, docenti;
  le tabelle "… a scelta da Tabella N" che seguono elencano gli insegnamenti tra cui scegliere.
  Per ogni coorte si prende la sezione dell'a.a. corrente; se la coorte appartiene al vecchio
  ordinamento si usa il corso "fratello" con lo stesso nome nel menu (es. 80_1 per 80_458);
- guida dell'insegnamento (`sviluppo.guide.visualizza?p_cod_ins=…&p_a_acc=…`) → "Bibliografia".

I corsi sono quelli di database/corsi/polito.json (da Universitaly) con `url`
`www.polito.it/corsi/<sdu>-<cds>`.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import estrai_libri
from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://didattica.polito.it"
PIANO = BASE + "/pls/portal30/sviluppo.offerta_formativa_2019.vis?p_coorte={c}&p_sdu={sdu}&p_cds={cds}"


def _codici(url: str | None) -> tuple[str, str] | None:
    m = re.search(r"polito\.it/corsi/(\d+)-(\d+)", url or "")
    return (m.group(1), m.group(2)) if m else None


def fratelli(s: str, sdu: str, cds: str) -> list[str]:
    """Codici cds con lo stesso nome (vecchio/nuovo ordinamento) dal menu dei corsi."""
    opz = dict((v, _testo(t)) for v, t in re.findall(r'<option[^>]*value="(\d+_\d+)"[^>]*>(.*?)</option>', s, re.S))
    nome = opz.get(f"{sdu}_{cds}")
    if not nome:
        return []
    base = re.sub(r"\s*DM\s*\d+/\d+\s*$", "", nome).strip().lower()
    return [v.split("_")[1] for v, t in opz.items()
            if v.startswith(f"{sdu}_") and v != f"{sdu}_{cds}" and re.sub(r"\s*DM\s*\d+/\d+\s*$", "", t).strip().lower() == base]


_INT_ANNO = re.compile(r"(\d)\s*°\s*anno\s+(\d{4}/\d{4})")
_P_INTEST = '<p style="font-weight: bold;font-size:14px;padding:10px;"'
_SEGNAPOSTO = re.compile(r"(?i)a scelta da tabella|crediti liberi|free ects")


def _riga(tr: str) -> dict | None:
    td = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
    if len(td) < 7:
        return None
    link = re.search(r'href="([^"]*sviluppo\.guide\.visualizza[^"]*)"', td[3])
    # negli insegnamenti integrati dopo il nome c'è l'elenco dei moduli (<p><ul>…)
    nome = _testo(re.split(r"<p\b|<ul\b", td[3], maxsplit=1)[0])
    if not nome:
        return None
    cfu_t = _testo(td[5]).replace(",", ".")
    cfu = float(cfu_t) if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None
    docenti = re.findall(r'class="policorpolink" target="_new">(.*?)</a>', td[6], re.S)
    per = _testo(td[0])
    return {
        "codice": _testo(td[1]) or None, "nome": nome,
        "ssd": "; ".join(_testo(x).strip(" ;") for x in re.split(r"<br\s*/?>", td[2]) if _testo(x)) or None,
        "periodo": per if per in ("1", "2", "3") else ("annuale" if per in ("1,2", "1; 2") else per or None),
        "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
        "docenti": sorted({_testo(d) for d in docenti if _testo(d)}),
        "url": BASE + html.unescape(link.group(1)) if link else None,
    }


def leggi_piano(s: str, aa: str) -> list[dict]:
    """Righe della sezione dell'a.a. `aa` ("2026/2027") di ogni percorso, con le tabelle a scelta.

    Il piano di un percorso ha una tabella per ogni anno («N° anno AAAA/AAAA») e, dopo gli anni, le tabelle
    degli insegnamenti tra cui scegliere (titolo libero: «Insegnamento a scelta da Tabella C», «Elective
    courses», «Thesis», …). Le tabelle non dicono a quale anno appartengono: le richiama, nell'anno, una riga
    senza guida col loro stesso nome (e i CFU da acquisire, a volte anche un codice). Quella riga è il gruppo
    (`gruppo: True`, a scelta, con i CFU dichiarati) e gli insegnamenti della tabella sono le alternative
    dello stesso anno (`obbligatorio: False`). Una tabella che nessuna riga dell'anno richiama non è di
    quell'anno."""
    out = []
    percorsi = re.split(r'<a name="\d+"\s*class="accordion-toggle"[^>]*>(.*?)</a>', s, flags=re.S)
    for nome_percorso, corpo in zip(percorsi[1::2], percorsi[2::2]):
        percorso = _testo(nome_percorso)
        sezioni: list[tuple[str, list[dict]]] = []
        for p in re.split(r'(' + re.escape(_P_INTEST) + r'[^>]*>.*?</p>)', corpo, flags=re.S):
            if p.startswith(_P_INTEST):
                sezioni.append((_testo(p), []))
            elif sezioni:
                sezioni[-1][1].extend(r for r in (_riga(tr) for tr in re.findall(r"<tr>(.*?)</tr>", p, re.S)) if r)
        tabelle = {}
        for titolo, righe in sezioni:
            if not _INT_ANNO.match(titolo):
                tabelle.setdefault(titolo.lower(), righe)
        for titolo, righe in sezioni:
            m = _INT_ANNO.match(titolo)
            if not m or m.group(2) != aa:
                continue
            anno = int(m.group(1))
            usate: set[str] = set()

            def espandi(tab_righe: list[dict], nome_gruppo: str, livello: int) -> None:
                # le righe di una tabella possono richiamare altre tabelle (es. «Challenge» dentro «Elective
                # courses»): anche quelle sono alternative dello stesso anno
                for x in tab_righe:
                    annidata = tabelle.get(x["nome"].lower()) if not x["url"] else None
                    if annidata is not None:
                        out.append(dict(x, anno=anno, obbligatorio=False, percorso=percorso, gruppo=True,
                                        annidato=True, da_gruppo=nome_gruppo))
                        if x["nome"].lower() not in usate and livello < 4:
                            usate.add(x["nome"].lower())
                            espandi(annidata, x["nome"], livello + 1)
                    else:
                        out.append(dict(x, anno=anno, obbligatorio=False, percorso=percorso, gruppo=False,
                                        annidato=False, da_gruppo=nome_gruppo))

            for r in righe:
                tab = tabelle.get(r["nome"].lower()) if not r["url"] else None
                segnaposto = tab is not None or (not r["url"] and _SEGNAPOSTO.search(r["nome"]))
                if not segnaposto:
                    out.append(dict(r, anno=anno, obbligatorio=True, percorso=percorso, gruppo=False, annidato=False,
                                    da_gruppo=None))
                    continue
                out.append(dict(r, anno=anno, obbligatorio=False, percorso=percorso, gruppo=True, annidato=False,
                                da_gruppo=None))
                if tab is not None and r["nome"].lower() not in usate:
                    usate.add(r["nome"].lower())
                    espandi(tab, r["nome"], 1)
    return out


_CUE = re.compile(r"(?i)\b(textbooks?|books?|libri|libro|testi|testo|reference|references|reading|readings|"
                  r"bibliograph\w*|manuali?|manuals?|riferimenti|volumi)\b")
_GENERICA_RE = re.compile(r"(?i)(slides?|dispens|appunti|lucidi|lecture|portal|\bweb\b|\bsito\b|presentation|recording|"
                          r"videolezion|will be|saranno|sar[àa]|verr|forniti|fornita|fornite|provided|available|"
                          r"disponibil|handout|\bnotes?\b|\barticles?\b|\barticoli\b|\bpapers?\b|further|ulteriori|"
                          r"http|www\.|esercizi|exercises|teaching material|course material|"
                          r"materiale (didattico|di supporto|fornito|aggiuntivo)|potranno|potr[àa]|may be|could be|"
                          r"parte comune|^(altri|other|ulteriori|additional)\b|^bibliografia\b|^parte\b|"
                          r"\b(is|are|can|should|è|sono|viene|vengono|non|no|not)\b)")
ISBN_RE = re.compile(r"ISBN", re.I)


def _generica(riga: str) -> bool:
    if _EDIT.search(riga) or ISBN_RE.search(riga) or (_ANNO.search(riga) and re.search(r"[“\"«][^”\"»]{3,}", riga)):
        return False  # un editore, un ISBN o «titolo» + anno: è un riferimento anche se contiene parole come «is»
    return bool(_GENERICA_RE.search(riga))


_EDIT = re.compile(r"(?i)\b(zanichelli|mcgraw|mc graw|pearson|hoepli|giappichelli|il mulino|carocci|laterza|utet|franco ?angeli|"
                   r"springer|wiley|elsevier|einaudi|cambridge|oxford|routledge|prentice|addison|cengage|clut|celid|"
                   r"levrotto|clup|cleup|esculapio|egea|edises|mit press|crc|academic press|cedam|liguori|kluwer|"
                   r"pitagora|publisher|publishers|ed\.)\b")
_ANNO = re.compile(r"\b(19|20)\d\d\b")


def _paragrafi(testo: str) -> list[list[str]]:
    from .testi import html_to_lines  # noqa: PLC0415
    t = re.sub(r"(?i)<\s*br\s*/?>|</p>|</li>|</div>", "\n", testo)
    t = re.sub(r"(?i)<\s*li[^>]*>", "\n- ", re.sub(r"(?i)<\s*p[^>]*>", "\n\n", t))
    out = []
    for blocco in re.split(r"\n\s*\n", t.replace("\r", "")):
        righe = html_to_lines(blocco)
        if righe:
            out.append(righe)
    return out


def _tipo_intestazione(h: str) -> str | None:
    if re.search(r"(?i)consigliat|suggest|recommend|approfond|further|additional|optional|facoltativ|supplement", h):
        return "consigliato"
    if re.search(r"(?i)obbligator|required|mandatory|adott", h):
        return "obbligatorio"
    return None


def _completo(riga: str) -> bool:
    return bool(_EDIT.search(riga) or _ANNO.search(riga) or re.search(r"[“\"«][^”\"»]{3,}[”\"»]", riga))


def riferimenti(testo: str) -> list[dict]:
    """Libri citati nella Bibliografia di una guida PoliTO. Le citazioni si scrivono in molti modi: righe
    complete (autori, titolo, editore, anno), elenchi di «Autore, Titolo» sotto un'intestazione («Textbooks:»,
    «Testi di approfondimento»), citazioni su più righe (autori / titolo / editore) separate da una riga vuota."""
    from .testi import _libero, _sembra_libro, _strutturato  # noqa: PLC0415
    out, in_elenco, tipo = [], False, None
    for para in _paragrafi(testo):
        corpo, ha_intestazione = [], False
        for riga in para:
            riga = re.sub(r"^[\W_]+(?=\w)", "", riga) if re.match(r"^[•\-–·*\u2022\u00b7]\s*", riga) else riga
            m = re.match(r"^(.{3,70}?):\s*(.*)$", riga)
            testa, resto = (m.group(1), m.group(2)) if m else (riga, "")
            if _CUE.search(testa) and len(testa) < 75 and not re.search(r"[“\"«]", testa) and (m or not _completo(riga)):
                in_elenco, tipo, ha_intestazione = True, _tipo_intestazione(testa), True
                if resto:
                    corpo.append(resto)
                continue
            if m and not resto and re.match(r"(?i)^(teaching|course|didactic|material|materiale|slides?|lecture|notes?|"
                                            r"note|further|ulteriori|online|on-line)", testa):
                in_elenco = False
                continue
            corpo.append(riga)
        cand = [r for r in corpo if 10 <= len(r) <= 400 and not (r.endswith(":") and not _completo(r))]
        # una sola citazione spezzata su più righe (autori / titolo / editore)
        util = [r for r in cand if not _generica(r)]
        if 2 <= len(util) <= 4 and len(util) == len(cand) and _completo(util[-1]) and not any(_completo(r) for r in util[:-1]):
            util = [" ".join(util)]
        for r in util:
            pezzi = [r]
            if " - " in r:
                sp = [x.strip() for x in re.split(r"\s+-\s+(?=[A-ZÀ-Ý])", r)]
                if len(sp) > 1 and sum(("," in x) for x in sp) >= 2 and all(len(x) > 15 for x in sp):
                    pezzi = sp
            for x in pezzi:
                it = _strutturato(x)
                if not it and (_sembra_libro(x) or in_elenco and len(x.split()) >= 2 or _completo(x) and re.match(r"[A-ZÀ-Ý]", x)):
                    it = _libero(x)
                if it:
                    it["tipo"] = it["tipo"] or tipo
                    out.append(it)
        if corpo:  # l'intestazione vale per il paragrafo che la contiene (o per quello subito dopo, se era sola)
            in_elenco = in_elenco and ha_intestazione
            tipo = tipo if in_elenco else None
    visti, libri = set(), []
    for it in out:
        k = re.sub(r"\W+", "", it["citazione"].lower())[:120]
        if k not in visti and not _frase(it):
            visti.add(k)
            libri.append(it)
    return libri


def _frase(l: dict) -> bool:
    """Frase descrittiva scambiata per riferimento (nessun editore/anno/virgolette, lunga, con un verbo)."""
    c = l["citazione"]
    return (len(c) > 140 and not l.get("isbn") and not re.search(r"[“\"«]", c) and not _ANNO.search(c)
            and bool(re.search(r"(?i)\b(è|sono|viene|vengono|richiest\w+|is|are|will|should)\b", c)))


def libri_guida(s: str) -> list[dict]:
    """Bibliografia della guida: testo italiano; se vuoto o senza libri, il testo inglese."""
    m = re.search(r'Bibliografia<br\s*/?></span>.*?<div class="col-sm-10 formattata testo_it[^"]*">(.*?)</div>'
                  r'(.*?<div class="col-sm-10 formattata testo_en[^"]*">(.*?)</div>)?', s, re.S)
    if not m:
        return []
    for blocco in (m.group(1), m.group(3)):
        if not blocco:
            continue
        libri = riferimenti(re.sub(r'<span class="flag[^"]*"></span>', "", blocco))
        if libri:
            return libri
    return []


def _fmt(x) -> str:
    return f"{x:g}" if isinstance(x, (int, float)) else "?"


def nomi_distinti(righe: list[dict]) -> list[dict]:
    """Righe omonime dello stesso anno che sono voci diverse della fonte (codici diversi, o un gruppo a scelta
    con il nome dei suoi insegnamenti): non si uniscono, si distinguono nel nome. Il gruppo (es. «Thesis»)
    diventa «… (gruppo a scelta, N CFU)»; voci omonime con CFU diversi «… (N CFU)»; con gli stessi CFU e codici
    diversi «… (codice)». Lo stesso codice su più righe (obbligatorio in un percorso e a scelta in un altro)
    resta con lo stesso nome: è un solo insegnamento."""
    def entita(rows):
        e: dict[tuple, list[dict]] = {}
        for i in rows:
            e.setdefault((i["codice"], i["_g"], i["cfu"] if i["_g"] else None), []).append(i)
        return e

    def per_nome(rows):
        out: dict[str, dict[tuple, list[dict]]] = {}
        for k, v in entita(rows).items():
            out.setdefault(v[0]["nome"], {})[k] = v
        return out

    per: dict[tuple, list[dict]] = {}
    for i in righe:
        per.setdefault((i["anno"], re.sub(r"\W+", " ", i["nome"].lower()).strip()), []).append(i)
    for gruppo in per.values():
        ent = entita(gruppo)
        if len(ent) < 2:
            continue
        if any(not k[1] for k in ent):
            for k, v in ent.items():
                if k[1]:
                    for i in v:
                        i["nome"] = f"{i['nome']} (gruppo a scelta, {_fmt(i['cfu'])} CFU)"
        for nome, e in per_nome(gruppo).items():
            if len(e) > 1:
                for k, v in e.items():
                    for i in v:
                        if f"{_fmt(i['cfu'])} CFU)" not in i["nome"]:
                            i["nome"] = f"{i['nome']} ({_fmt(i['cfu'])} CFU)"
        for nome, e in per_nome(gruppo).items():
            if len(e) > 1:
                for k, v in e.items():
                    for i in v:
                        if i["codice"]:
                            i["nome"] = f"{i['nome']} ({i['codice']})"
    return righe


def _slug(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def id_senza_codice(corso_id: str, ins: list[dict]) -> list[dict]:
    """Le righe senza codice (gruppi a scelta) hanno un id esplicito dal nome intero: lo slug di build_db si
    ferma a 40 caratteri e «Insegnamento caratterizzante di orientamento 1/2/3» diventerebbe una voce sola.
    Lo stesso nome in anni diversi: `-a<anno>`, come per i codici."""
    usati = {f"{corso_id}-{_slug(i['codice'])[:40]}" for i in ins if i["codice"]}
    for i in sorted(ins, key=lambda i: i["anno"]):
        if i["codice"]:
            continue
        base = f"{corso_id}-{_slug(i['nome'])[:80]}".strip("-")
        cand = base if base not in usati else f"{base}-a{i['anno']}"
        n = 2
        while cand in usati:
            cand = f"{base}-a{i['anno']}-{n}"
            n += 1
        usati.add(cand)
        i["id"] = cand
    return ins


def fetch_ateneo(uid: str = "polito", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print, diag: dict | None = None) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py).
    `diag` (facoltativo) raccoglie per corso le righe con i campi `_g` (gruppo a scelta) e `_a` (annidato)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    aa = f"{anno}/{anno + 1}"
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=4.0)
    for corso in corsi:
        if not _codici(corso.get("url")) and corso.get("url"):
            # url di una pagina di www.polito.it/didattica/…: i codici sono nel link alla Guida
            r = c.get(corso["url"])
            m = re.search(r"guida/\d+/it/homepage\?cds=(\d+)(?:&amp;|&)sdu=(\d+)", r.text) if r else None
            if m:
                corso["_codici"] = (m.group(2), m.group(1))
    corsi = [c_ for c_ in corsi if _codici(c_.get("url")) or c_.get("_codici")]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con codice del Portale della Didattica")
    oggi = time.strftime("%Y-%m-%d")

    def build(corso: dict) -> dict | None:
        sdu, cds = corso.get("_codici") or _codici(corso["url"])
        durata = corso.get("durata_anni") or 3
        # il corso può avere più codici (vecchio e nuovo ordinamento, stesso nome nel menu): si cercano
        # prima di leggere i piani, perché la coorte più recente può essere solo sul codice nuovo
        cand = [cds]
        for k in range(1, durata + 1):
            r = c.get(PIANO.format(c=anno + 2 - k, sdu=sdu, cds=cds))
            if r:
                cand += fratelli(r.text, sdu, cds)
                break
        righe: dict[tuple, dict] = {}
        percorsi = set()
        fonte = None
        for k in range(1, durata + 1):
            coorte = anno + 2 - k  # p_coorte = anno di fine dell'a.a. di immatricolazione
            trovate, url_piano = [], None
            # senza coorte attiva in quell'anno (corso nuovo: nessuno è ancora al k-esimo anno) vale il piano
            # ufficiale della coorte successiva più vicina, che ha la sezione di quell'anno (per l'a.a. di
            # quella coorte: la stessa pagina del Portale, altro p_coorte)
            for delta in (0, 1, 2):
                aa_k = f"{anno + delta}/{anno + delta + 1}"
                for cod in cand:
                    url_piano = PIANO.format(c=coorte + delta, sdu=sdu, cds=cod)
                    r = c.get(url_piano)
                    if not r:
                        continue
                    trovate = [x for x in leggi_piano(r.text, aa_k) if x["anno"] == k]
                    if trovate:
                        fonte = fonte or url_piano
                        break
                if trovate:
                    break
            for x in trovate:
                if x["cfu"] == 0 and not x["gruppo"]:
                    continue  # attività a 0 CFU (es. sessioni estive senza crediti): non sono insegnamenti del piano
                percorsi.add(x["percorso"])
                # un gruppo con CFU diversi da un percorso all'altro è una riga per ogni valore
                key = (k, x["codice"] or x["nome"].lower(), x["obbligatorio"], x["cfu"] if x["gruppo"] else None)
                item = righe.get(key)
                if not item:
                    item = righe[key] = {
                        "codice": x["codice"], "nome": x["nome"], "anno": k, "periodo": x["periodo"], "cfu": x["cfu"],
                        "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None,
                        "docenti": x["docenti"], "url": x["url"], "libri": [], "esami": [],
                        "fonte": url_piano, "verificato_il": oggi, "_p": set(), "_g": x["gruppo"], "_a": x["annidato"],
                    }
                item["_p"].add(x["percorso"])
        nomi_p = sorted(p for p in percorsi if p and p.lower() != "percorso")
        for i in righe.values():
            ps = i.pop("_p")
            if len(percorsi) > 1 and ps != percorsi:
                i["curriculum"] = ", ".join(sorted(ps))
        if not righe:
            return None
        ins = id_senza_codice(corso["id"], nomi_distinti(list(righe.values())))
        if diag is not None:  # per i controlli: quali righe sono gruppi a scelta (e quali annidati in un altro gruppo)
            diag[corso["id"]] = [{k: i.get(k) for k in ("anno", "nome", "codice", "cfu", "obbligatorio", "curriculum",
                                                         "_g", "_a", "fonte", "id")} for i in ins]
        for i in ins:
            i.pop("_g", None)
            i.pop("_a", None)
        return {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": corso["url"], "curricula": nomi_p if len(percorsi) > 1 else None,
                "fonte": fonte, "verificato_il": oggi, "insegnamenti": ins}

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, corsi) if r]
    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            if not i.get("url") and re.fullmatch(r"[0-9][0-9A-Z]{6}", i.get("codice") or ""):
                # riga senza link nel piano (es. insegnamenti elencati nelle tabelle a scelta): la guida si
                # cerca per codice; l'url si tiene solo se la guida esiste davvero
                i["_prov"] = True
                i["url"] = f"{BASE}/pls/portal30/sviluppo.guide.visualizza?p_cod_ins={i['codice']}&p_a_acc={anno + 1}&p_lang="
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"guide da leggere: {len(jobs) if syllabus else 0}")

    def guida(url: str) -> int:
        try:
            r = c.get(url)
            libri = libri_guida(r.text) if r else []
            esiste = bool(r and "idBibliografia" in r.text)
            for it in jobs[url]:
                if it.pop("_prov", False) and not esiste:
                    it["url"] = None
                it["libri"] = libri
                it["stato_libri"] = "completo" if libri else "da_aggiungere"
            return len(libri)
        except Exception:  # noqa: BLE001 - una guida illeggibile non ferma le altre
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(guida, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   guide {n}/{len(jobs)}")
    for corso in out:
        for i in corso["insegnamenti"]:
            if i.pop("_prov", False):  # guida non letta: nessun url inventato
                i["url"] = None
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": "Generato dal Portale della Didattica (adapters/polito.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}
