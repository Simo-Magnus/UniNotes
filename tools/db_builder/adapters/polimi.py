"""Insegnamenti, docenti e libri del Politecnico di Milano dal Manifesto degli studi pubblico.

PoliMi non usa il Course Catalogue Cineca. Il Manifesto (`onlineservices.polimi.it/manifesti`)
è pubblico:

- `ManifestoPublic.do?evn_default=EVENTO&aa=<a.a.>&k_cf=<scuola>` → elenco dei corsi di
  studio della scuola (gruppi "Laurea di Primo Livello - ord. 96/23", "… - ord. 270", …):
  i corsi del vecchio ordinamento con lo stesso nome coprono gli anni delle coorti precedenti;
- manifesto di un corso e di un "piano di studio preventivamente approvato" (`k_indir`,
  il curriculum) → "1° Anno", "2° Anno", … con codice, SSD, nome, lingua, sede, tipo,
  periodo, CFU; le righe nei gruppi a scelta hanno `idGruppo` nel link;
- dettaglio della riga → docenti per scaglione e link al "Programma dettagliato"
  (`schedaincarico/…/SchedaPublic.do?c_classe=…`) → "Bibliografia" strutturata (autori,
  titolo, editore, anno, ISBN; icona di risorsa obbligatoria o facoltativa).

I corsi del manifesto si associano a quelli di database/corsi/polimi.json (da Universitaly)
per nome, tipo e sede (es. "Ingegneria Gestionale - CR" ↔ "Ingegneria Gestionale REPLICA CREMONA").
"""
from __future__ import annotations

import concurrent.futures as cf
import hashlib
import html
import json
import pathlib
import re
import time
import unicodedata

from .testi import _isbn
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://onlineservices.polimi.it"
MAN = BASE + "/manifesti/manifesti/controller/ManifestoPublic.do"
SCHEDA = BASE + "/schedaincarico/schedaincarico/controller/scheda_pubblica/SchedaPublic.do?&evn_default=evento&c_classe="
SEDI = {"cremona": "CR", "piacenza": "PC", "lecco": "LC", "mantova": "MN", "como": "CO"}


def _get_valid(c: Client, url: str, marker: str):
    """GET con verifica del contenuto: sotto carico il server risponde 200 con una pagina d'errore
    (che la cache su disco terrebbe per sempre). Se manca `marker` si riprova senza cache."""
    r = c.get(url)
    if r is not None and marker in r.text:
        return r
    for attempt in range(3):
        time.sleep(5 * (attempt + 1))
        r = c._get(url)
        if r is not None and marker in r.text:
            if c.cache:
                key = hashlib.sha1((url + "|" + json.dumps(sorted(c.s.headers.items()))).encode()).hexdigest()
                f = c.cache / key[:2] / f"{key}.json"
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(json.dumps({"ok": True, "url": r.url, "text": r.text}), encoding="utf-8")
            return r
    return None


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", " ")).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(w for w in s.split() if w not in {"e", "ed", "il", "la", "lo", "and", "the"})


def _tipo(gruppo: str) -> str | None:
    g = gruppo.lower()
    if "ciclo unico" in g:
        return "LMCU"
    if "magistrale" in g:
        return "LM"
    if "primo livello" in g:
        return "L"
    return None


def corsi_del_manifesto(s: str) -> list[dict]:
    """Opzioni del menu dei corsi: [{codice, nome, sedi, tipo, ordinamento}]."""
    m = re.search(r'<select[^>]*name="k_corso_la"[^>]*>(.*?)</select>', s, re.S | re.I)
    out = []
    for label, body in re.findall(r'<optgroup label="([^"]*)">(.*?)</optgroup>', m.group(1) if m else "", re.S):
        for cod, nome in re.findall(r'<option value="(\d+)"[^>]*>(.*?)</option>', body, re.S):
            nome = re.sub(r"\s*\(\d+\)\s*$", "", html.unescape(_testo(nome)))
            sedi = set()
            mm = re.match(r"(.*?)\s+-\s+([A-Z]{2}(?:,[A-Z]{2})*)$", nome)
            if mm:
                nome, sedi = mm.group(1), set(mm.group(2).split(","))
            out.append({"codice": cod, "nome": nome, "sedi": sedi, "tipo": _tipo(label), "ordinamento": label})
    return out


def associa(opzioni: list[dict], corsi: list[dict]) -> dict[str, list[dict]]:
    """id del corso del database -> opzioni del manifesto (nuovo e vecchio ordinamento)."""
    out: dict[str, list[dict]] = {}
    for o in opzioni:
        # nomi bilingui: "Sustainable Architecture … - Architettura Sostenibile …"
        basi = {_norm(o["nome"])} | {_norm(p) for p in o["nome"].split(" - ")}
        cand = []
        for c in corsi:
            nomi = {_norm(re.sub(r"(?i)\s+replica\s+\w+$", "", c.get(k) or "")) for k in ("nome", "nome_en")}
            if c["tipo"] == o["tipo"] and basi & nomi:
                cand.append(c)
        if not cand:
            continue
        repliche = {}
        for c in cand:
            m = re.search(r"(?i)replica\s+(\w+)$", c["nome"])
            repliche[SEDI.get(m.group(1).lower()) if m else None] = c
        scelto = None
        if len(o["sedi"]) == 1:
            scelto = repliche.get(next(iter(o["sedi"])))
        scelto = scelto or repliche.get(None)
        if scelto:
            out.setdefault(scelto["id"], []).append(o)
    return out


def leggi_manifesto(s: str) -> list[dict]:
    """Righe del manifesto di un piano (tutti gli anni presenti)."""
    out = []
    parti = re.split(r'<TD class="TitleInfoCard">\s*(\d)<sup><small>o</small></sup>\s*Anno\s*</TD>', s)
    for anno, corpo in zip(parti[1::2], parti[2::2]):
        for tr in re.findall(r"<tr>(.*?)</tr>", corpo, re.S | re.I):
            celle = re.findall(r"<TD([^>]*)>(.*?)</TD>", tr, re.S | re.I)
            # la cella del nome ha colspan; prima ci sono codice, uno o due SSD e la cella dell'orario,
            # dopo lingua, sede, tipo, periodo, CFU, CFU del gruppo
            k = next((j for j, (attr, _) in enumerate(celle) if "colspan" in attr.lower() and j > 0), None)
            if k is None or len(celle) < k + 6:
                continue
            td = [x for _, x in celle]
            ssd = " ".join(_testo(x) for (attr, x) in celle[1:k] if "orario_td" not in attr and _testo(x))
            link = re.search(r'href="([^"]*EVN_DETTAGLIO_RIGA_MANIFESTO[^"]*)"', td[k])
            cfu_t = _testo(td[k + 5]).replace(",", ".")
            cfu = float(cfu_t) if re.fullmatch(r"\d+(\.\d+)?", cfu_t) else None
            per = _testo(td[k + 4]).lower()
            m = re.match(r"(\d)\D*sem", per)
            out.append({
                "anno": int(anno), "codice": _testo(td[0]) or None, "ssd": ssd or None,
                # le note del manifesto ("Insegnamento a numero chiuso", …) sono in un div a parte
                "nome": _titolo(_testo(re.sub(r'<div class="cls_note".*?</div>', " ", td[k], flags=re.S))), "sede": _testo(td[k + 2]) or None, "tipo": _testo(td[k + 3]) or None,
                "periodo": m.group(1) if m else ("annuale" if "ann" in per else (_testo(td[k + 4]) or None)),
                "cfu": int(cfu) if cfu is not None and cfu.is_integer() else cfu,
                "url": BASE + html.unescape(link.group(1)) if link else None,
                "obbligatorio": bool(link) and "idGruppo=" not in link.group(1),
            })
    return out


def leggi_dettaglio(s: str) -> tuple[list[str], list[str]]:
    """Docenti e c_classe dei "Programma dettagliato" dal dettaglio della riga."""
    docenti = [_testo(x) for x in re.findall(r"RicercaPerDocentiPublic\.do[^\"]*evn_didattica[^\"]*\"[^>]*>(.*?)</a>",
                                               s, re.S)]
    classi = re.findall(r"id_servizio=178&(?:amp;)?c_classe=(\d+)", s)
    return sorted({d for d in docenti if d}), list(dict.fromkeys(classi))


def leggi_bibliografia(s: str) -> list[dict]:
    m = re.search(r'class="TitleInfoCard">\s*Bibliografia\s*</td>.*?<td[^>]*jaf-card-element">(.*?)</td>', s,
                  re.S | re.I)
    if not m:
        return []
    out = []
    for voce in re.split(r'<div style="height:1em; border-top[^>]*></div>', m.group(1)):
        tipo_img = re.search(r'<img title="([^"]*)"', voce)
        autori = re.search(r"<i>(.*?)</i>", voce, re.S)
        titolo = re.search(r"<b>(.*?)</b>", voce, re.S)
        resto = _testo(re.sub(r"<i>.*?</i>|<b>.*?</b>|<span.*?</span>", "", voce, flags=re.S))
        if not titolo:
            continue
        ed = re.search(r"Editore:\s*([^,]+)", resto)
        anno = re.search(r"Anno edizione:\s*(\d{4})", resto)
        cit = _testo(re.sub(r"<span.*?</span>", "", voce, flags=re.S))
        t = (tipo_img.group(1).lower() if tipo_img else "")
        out.append({
            "titolo": _testo(titolo.group(1)), "autori": _testo(autori.group(1)) if autori else None,
            "editore": ed.group(1).strip() if ed else None, "anno": int(anno.group(1)) if anno else None,
            "edizione": None, "isbn": _isbn(resto), "lingua": None,
            "tipo": "obbligatorio" if "obbligatori" in t else ("consigliato" if "facoltativ" in t else None),
            "note": None, "citazione": cit,
        })
    return out


def fetch_ateneo(uid: str = "polimi", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)
    oggi = time.strftime("%Y-%m-%d")
    r = c.get(f"{MAN}?evn_default=EVENTO&aa={anno}&lang=IT")
    scuole = re.findall(r'<option value="(\d+)"[^>]*>', re.search(r'<select[^>]*name="k_cf"[^>]*>(.*?)</select>',
                                                                  r.text, re.S | re.I).group(1)) if r else []
    opzioni = []
    for cf_ in scuole:
        rs = _get_valid(c, f"{MAN}?evn_default=EVENTO&aa={anno}&k_cf={cf_}&lang=IT", 'name="k_corso_la"')
        if rs:
            opzioni += [dict(o, scuola=cf_) for o in corsi_del_manifesto(rs.text)]
    mappa = associa(opzioni, corsi)
    per_id = {x["id"]: x for x in corsi}
    # repliche senza un corso proprio nel manifesto (es. "Ingegneria Informatica REPLICA CREMONA"): sono
    # i piani di studio (indirizzi) del corso principale erogati nella sede della replica
    sede_replica: dict[str, str] = {}
    for x in corsi:
        m = re.match(r"(?i)(.*?)\s+replica\s+(\w+)$", x.get("nome") or "")
        if not m or x["id"] in mappa or SEDI.get(m.group(2).lower()) is None:
            continue
        princ = [y for y in corsi if y["id"] in mappa and y.get("classe") == x.get("classe")
                 and _norm(y["nome"]) == _norm(m.group(1))]
        if len(princ) == 1:
            mappa[x["id"]] = mappa[princ[0]["id"]]
            sede_replica[x["id"]] = SEDI[m.group(2).lower()]
    ids = sorted(mappa)[:max_cds] if max_cds else sorted(mappa)
    log(f"[{uid}] {len(opzioni)} corsi nel manifesto, {len(ids)} associati al database")

    def url_piano(o: dict, indir: str | None) -> str:
        u = (f"{MAN}?evn_default=EVENTO&aa={anno}&k_cf={o['scuola']}&k_corso_la={o['codice']}&ac_ins=0"
             f"&lang=IT&tipoCorso=ALL_TIPO_CORSO&semestre=ALL_SEMESTRI")
        return u + (f"&k_indir={indir}" if indir else "")

    def build(cid: str) -> dict | None:
        corso = per_id[cid]
        durata = corso.get("durata_anni") or 3
        righe: dict[str, dict] = {}
        curricula = set()
        for o in mappa[cid]:
            r0 = _get_valid(c, url_piano(o, None), 'name="k_corso_la"')
            if not r0:
                continue
            m = re.search(r'<select[^>]*name="k_indir"[^>]*>(.*?)</select>', r0.text, re.S | re.I)
            indirizzi = re.findall(r'<option value="([^"]+)"[^>]*>(.*?)</option>', m.group(1), re.S) if m else []
            for ind, ind_nome in indirizzi or [(None, None)]:
                rp = r0 if len(indirizzi) <= 1 else _get_valid(c, url_piano(o, ind), 'name="k_corso_la"')
                if not rp:
                    continue
                curr = re.sub(r"^\w+\s*-\s*", "", _testo(ind_nome)) if ind_nome and len(indirizzi) > 1 else None
                piano = leggi_manifesto(rp.text)
                if cid in sede_replica:
                    # solo i piani il cui 1° anno si svolge nella sede della replica
                    sedi1 = [x["sede"] for x in piano if x["anno"] == 1 and x.get("sede") in set(SEDI.values()) | {"MI", "BV"}]
                    if not sedi1 or sedi1.count(sede_replica[cid]) * 2 <= len(sedi1):
                        continue
                for x in piano:
                    if not 1 <= x["anno"] <= durata:
                        continue
                    if curr:
                        curricula.add(curr)
                    key = f"{x['anno']}:{x['codice'] or x['nome']}"
                    item = righe.get(key)
                    if not item:
                        item = righe[key] = {
                            "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": x["periodo"],
                            "cfu": x["cfu"], "ssd": x["ssd"], "obbligatorio": x["obbligatorio"], "curriculum": None,
                            "docenti": [], "url": x["url"], "libri": [], "esami": [], "fonte": rp.url.split(";")[0],
                            "verificato_il": oggi, "_curr": set(),
                        }
                    item["obbligatorio"] = item["obbligatorio"] and x["obbligatorio"]
                    item["_curr"].add(curr)
        tutti = set().union(*(i["_curr"] for i in righe.values())) if righe else set()
        for i in righe.values():
            cs = i.pop("_curr")
            if None not in cs and cs != tutti:
                i["curriculum"] = ", ".join(sorted(cs))
        if not righe:
            return None
        return {"id": cid, "nome": corso["nome"], "classe": corso.get("classe"), "durata_anni": durata,
                "url": url_piano(mappa[cid][0], None), "curricula": sorted(curricula) or None,
                "fonte": MAN, "verificato_il": oggi, "insegnamenti": list(righe.values())}

    def build_safe(cid: str) -> dict | None:
        try:
            return build(cid)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {cid} saltato: {e!r}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        out = [r for r in ex.map(build_safe, ids) if r]
    jobs: dict[str, list[dict]] = {}
    for corso in out:
        for i in corso["insegnamenti"]:
            if i.get("url"):
                jobs.setdefault(i["url"], []).append(i)
    log(f"[{uid}] piani letti: {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"insegnamenti distinti da leggere: {len(jobs) if syllabus else 0}")

    def dettaglio(codice: str) -> int:
        try:
            items = jobs[codice]
            r = _get_valid(c, items[0]["url"], "Dati Insegnamento")
            if not r:
                return 0
            docenti, classi = leggi_dettaglio(r.text)
            libri, viste = [], set()
            for cl in classi[:3]:  # gli scaglioni hanno quasi sempre la stessa bibliografia
                rs = _get_valid(c, SCHEDA + cl, "Scheda Riassuntiva")
                for lb in leggi_bibliografia(rs.text) if rs else []:
                    k = _norm(lb["citazione"])[:120]
                    if k not in viste:
                        viste.add(k)
                        libri.append(lb)
            for it in items:
                it["url"] = r.url.split(";")[0] if ";" in r.url else r.url
                it["docenti"] = docenti
                it["libri"] = libri
                it["stato_libri"] = "completo" if libri else "da_aggiungere"
                if classi:
                    it["url_sito"] = SCHEDA + classi[0]
            return len(libri)
        except Exception:  # noqa: BLE001 - un dettaglio illeggibile non ferma gli altri
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(4) as ex:
            for n, k in enumerate(ex.map(dettaglio, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   insegnamenti {n}/{len(jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    if syllabus:
        libri_anno_precedente(out, anno, log=log, c=c)
    return {"universita_id": uid, "descrizione": "Generato dal Manifesto degli studi pubblico (adapters/polimi.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


RICERCA = BASE + "/manifesti/manifesti/controller/ricerche/RicercaPerInsegnamentoPublic.do"
_NON_LIBRI = re.compile(r"(?i)prova finale|tesi|tirocini|stage|internship|thesis|final exam|altre attivit|"
                        r"ulteriori|a scelta|elective|crediti liberi|workshop")


def libri_anno_precedente(corsi: list[dict], anno: int, log=print, c: Client | None = None) -> int:
    """Insegnamenti senza bibliografia nella scheda dell'a.a. `anno` (o senza scheda, "Docente non
    definito"): si usa la "Bibliografia" della scheda dell'a.a. precedente dello stesso insegnamento
    (stesso codice; se possibile lo stesso corso e piano), trovata con la ricerca pubblica per
    insegnamento del Manifesto. Ogni libro lo dice nella nota. Restituisce gli insegnamenti completati."""
    c = c or Client(rate=3.0)
    prec = anno - 1
    per_cod: dict[str, list[dict]] = {}
    for corso in corsi:
        for i in corso.get("insegnamenti") or []:
            if not i.get("libri") and i.get("codice") and not _NON_LIBRI.search(i.get("nome") or ""):
                per_cod.setdefault(i["codice"], []).append(i)
    log(f"[polimi] libri a.a. {prec}/{prec + 1 - 2000}: {len(per_cod)} codici da cercare")
    nota = (f"Dal programma dell'a.a. {prec}/{(prec + 1) % 100:02d}: la scheda {anno}/{(anno + 1) % 100:02d} "
            f"non riporta ancora la bibliografia")

    def param(u: str, k: str) -> str | None:
        m = re.search(rf"[?&]{k}=([^&]*)", u or "")
        return m.group(1) if m else None

    def uno(cod: str) -> int:
        try:
            r = _get_valid(c, f"{RICERCA}?evn_default=Esegui+Ricerca&aa={prec}&lang=IT&insegn_ricerca={cod}&k_cf=-1"
                              f"&sede=ALL_SEDI&tipoCorso=ALL_TIPO_CORSO&ac_ins=0&semestre=ALL_SEMESTRI&aree=-1"
                              f"&tipoInsegnamento=ALL_TIPO_INSEGNAMENTO", 'name="insegn_ricerca"')
            if not r:
                return 0
            links = [re.sub(r";jsessionid=[^?]*", "", html.unescape(h)) for h in
                     re.findall(r'href="([^"]*EVN_DETTAGLIO_RIGA_MANIFESTO[^"]*)"', r.text)]
            links = [BASE + h if h.startswith("/") else h for h in links if param(h, "codDescr") == cod]
            if not links:
                return 0
            cache: dict[str, list[dict]] = {}
            n = 0
            for i in per_cod[cod]:
                kc, ki = param(i.get("url"), "k_corso_la"), param(i.get("url"), "k_indir")
                best = ([h for h in links if param(h, "k_corso_la") == kc and param(h, "k_indir") == ki]
                        or [h for h in links if param(h, "k_corso_la") == kc] or links)[0]
                if best not in cache:
                    libri, viste = [], set()
                    rd = _get_valid(c, best, "Dati Insegnamento")
                    for cl in (leggi_dettaglio(rd.text)[1] if rd else [])[:3]:
                        rs = _get_valid(c, SCHEDA + cl, "Scheda Riassuntiva")
                        for lb in leggi_bibliografia(rs.text) if rs else []:
                            k = _norm(lb["citazione"])[:120]
                            if k not in viste:
                                viste.add(k)
                                libri.append(dict(lb, note=f"{nota} ({SCHEDA + cl})"))
                    cache[best] = libri
                if cache[best]:
                    i["libri"] = [dict(x) for x in cache[best]]
                    i["stato_libri"] = "completo"
                    n += 1
            return n
        except Exception:  # noqa: BLE001 - un insegnamento illeggibile non ferma gli altri
            return 0

    tot = 0
    with cf.ThreadPoolExecutor(4) as ex:
        for k, n in enumerate(ex.map(uno, sorted(per_cod)), 1):
            tot += n
            if k % 200 == 0:
                log(f"[polimi]   codici {k}/{len(per_cod)}, insegnamenti con libri {tot}")
    log(f"[polimi] libri dall'a.a. {prec}: {tot} insegnamenti")
    return tot
