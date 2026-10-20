"""Insegnamenti e docenti dell'Università di Palermo da www.unipa.it e dai dati aperti dell'ateneo.

Il Course Catalogue di UniPa è vuoto; i siti dei corsi pubblicano la "Didattica erogata":

- `/dipartimenti/<dip>/cds/<corso><codice>/?pagina=insegnamenti` → "Insegnamenti del primo
  anno (manifesto degli studi 2026/2027)", "… del secondo anno (manifesto … 2025/2026)", …:
  codice (lo stesso di Esse3), nome, CFU, docente, curriculum. Un asterisco accanto al nome segna
  un'«attività formativa opzionale» (legenda della pagina): `obbligatorio: false`, gli altri sono
  obbligatori. Gli insegnamenti integrati («… C.I.») sono elencati con il contenitore (CFU totali) e
  con i moduli «<contenitore> - <modulo> (Modulo)» (quote): se le quote dei moduli fanno il totale del
  contenitore resta il solo modulo (`modulo_di` = contenitore), altrimenti il solo contenitore, così
  i CFU dell'anno non si contano due volte.

- il piano di studi completo sta solo su `offertaformativa.unipa.it` (manifesto per coorte), che
  risponde con un CAPTCHA e non si interroga. L'erogato elenca solo gli insegnamenti con lezioni:
  mancano prova finale, tirocinio, altre attività e, per gli anni non ancora erogati, tutto l'anno. Si
  completa con il dataset aperto dell'ateneo `dati.unipa.it/dataset/offerta-formativa-<a.a. precedente>.csv`
  (CC BY 4.0; stesso anno di corso dell'a.a. precedente, indicato nel campo `fonte` di ogni voce): per gli
  anni con insegnamenti erogati si aggiungono le sole attività senza lezioni (prova finale, tirocinio/stage,
  altre attività, lingua, tesi), per gli anni senza erogato tutte le voci dell'anno (moduli al posto dei
  contenitori); semestre e SSD dello stesso codice. Ogni ordinamento di un corso ha un codice (2086 fino
  alla coorte 2024/25, 2460 «R» dalla 2025/26): gli anni che mancano nel codice della pagina si prendono
  dall'altro ordinamento dello stesso nome e classe.

- scheda di trasparenza PDF (`offertaformativa.unipa.it/offweb/schedaTrasparenza?…`) →
  "PERIODO DELLE LEZIONI" e "TESTI CONSIGLIATI" (letti con pypdf, se installato). Solo se il sito non chiede
  il CAPTCHA (se lo chiede non si insiste); i libri già raccolti si riusano.

Corsi senza la pagina nell'elenco di Universitaly: pagina del dipartimento (`?pagina=cds`) per nome e
classe, oppure `PAGINE`. Corsi omonimi (online, indirizzo MED-IT, repliche di sede) hanno la sede nel
contributo, altrimenti sembrerebbero doppioni.
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
from .unibo import Client, _testo, _titolo

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = "https://www.unipa.it"
SCHEDA = "https://offertaformativa.unipa.it/offweb/schedaTrasparenza?lingua=ITA&oidCurrInsegnamento="
INTESTAZIONI = (r"(?:PROGRAMMA|OBIETTIVI FORMATIVI|MODALITA'? DI VERIFICA|METODI DIDATTICI|ORARIO DI RICEVIMENTO|"
                r"RISULTATI DI APPRENDIMENTO|PREREQUISITI|MODULO\b|DOCENTE\b)")


def _bundle() -> str:
    """Certificati di certifi + l'intermedio GEANT TLS RSA 1 che offertaformativa.unipa.it non invia
    (i browser lo scaricano dall'AIA, requests no): la verifica TLS resta attiva."""
    import certifi
    import tempfile
    f = pathlib.Path(tempfile.gettempdir()) / "university_notes_unipa_ca.pem"
    if not f.exists():
        certi = [pathlib.Path(certifi.where()), pathlib.Path(__file__).parent / "certs" / "geant_tls_rsa_1.pem"]
        f.write_text("\n".join(p.read_text(encoding="utf-8") for p in certi), encoding="utf-8")
    return str(f)


def leggi_scheda_pdf(data: bytes) -> dict:
    """Periodo e testi consigliati dalla scheda di trasparenza in PDF."""
    try:
        import io
        from pypdf import PdfReader
        testo = "\n".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(data)).pages)
    except Exception:  # noqa: BLE001 - pypdf assente o PDF illeggibile
        return {"periodo": None, "libri": []}
    per = re.search(r"PERIODO DELLE LEZIONI\s+(\d)\s*°?\s*semestre", testo, re.I)
    if not per and re.search(r"PERIODO DELLE LEZIONI\s+annual", testo, re.I):
        periodo = "annuale"
    else:
        periodo = per.group(1) if per else None
    libri, viste = [], set()
    for m in re.finditer(r"TESTI CONSIGLIATI\s+(.*?)(?=\n" + INTESTAZIONI + r"|\Z)", testo, re.S):
        blocco = re.sub(r"\s*\n\s*", " ", m.group(1)).strip()
        # un riferimento per riga: si va a capo dopo il punto che chiude anno/ISBN, prima di "Cognome X."
        righe = re.split(r"(?<=[\d)]\.)\s+(?=[A-ZÀ-Ý][\w'’-]+,?\s+(?:[A-Z]\.|[A-ZÀ-Ý][a-zà-ù]+\s+[A-Z]\.))", blocco)
        for lb in estrai_libri("<br>".join(righe)):
            k = re.sub(r"\W+", "", lb["citazione"].lower())[:120]
            if k not in viste:
                viste.add(k)
                libri.append(lb)
    return {"periodo": periodo, "libri": libri}


ORD = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _pagina(url: str | None) -> str | None:
    m = re.match(r"https?://(?:www|portale)\.unipa\.it(/dipartimenti/[\w.-]+/cds/[\w.-]+)", (url or "").strip())
    return f"{BASE}{m.group(1)}/" if m else None


def _compatto(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", _norm(s))


def _codice_corso(url: str | None) -> str | None:
    """Codice del corso (2086) alla fine dell'indirizzo della pagina: è il CODICE_CORSO_DI_STUDI dei dati aperti."""
    m = re.search(r"/cds/[a-z.\-_]*?(\d{3,4})/?$", (url or "").rstrip("/") + "/")
    return m.group(1) if m else None


# Pagine dei corsi che Universitaly non collega alla pagina di www.unipa.it (url di un elenco di dipartimento, di un
# sito esterno o assente) e che l'elenco del dipartimento non permette di scegliere per nome (verificate a mano
# sulle pagine dei dipartimenti; con più ordinamenti dello stesso nome la pagina è quella dell'ordinamento attivo)
PAGINE = {
    "unipa-l-4-design": "https://www.unipa.it/dipartimenti/architettura/cds/design2512/",
    "unipa-l-snt2-educazione-professionale-abilitante-alla-professione-sanitar":
        "https://www.unipa.it/dipartimenti/promise/cds/educazioneprofessionale2311/",
    "unipa-l-8-l-9-industrial-and-information-engineering":
        "https://www.unipa.it/dipartimenti/ingegneria/cds/industrialandinformationengineering2493/",
    "unipa-l-9-ingegneria-elettrica": "https://www.unipa.it/dipartimenti/ingegneria/cds/ingegneriaelettrica2513/",
    "unipa-l-9-ingegneria-energetica": "https://www.unipa.it/dipartimenti/ingegneria/cds/ingegneriaenergetica2510/",
    "unipa-l-10-lettere": "https://www.unipa.it/dipartimenti/scienzeumanistiche/cds/lettere2440/",
    "unipa-l-11-l-12-lingue-e-letterature-studi-interculturali":
        "https://www.unipa.it/dipartimenti/scienzeumanistiche/cds/lingueeletteraturestudiinterculturali2364/",
    "unipa-l-25-scienze-forestali-e-sviluppo-rurale":
        "https://www.unipa.it/dipartimenti/saaf/cds/scienzeforestaliesvilupporurale2496/",
    "unipa-l-41-statistica-e-data-science": "https://www.unipa.it/dipartimenti/seas/cds/statisticaedatascience2467/",
    "unipa-l-snt3-tecniche-di-fisiopatologia-cardiocircolatoria-e-perfusione-c":
        "https://www.unipa.it/dipartimenti/me.pre.c.c./cds/tecnichedifisiopatologiacardiocircolatoriaeperfusionecardiovascolare1152/",
    "unipa-l-snt3-tecniche-ortopediche-abilitante-alla-professione-sanitaria-d":
        "https://www.unipa.it/dipartimenti/me.pre.c.c./cds/tecnicheortopediche2490/",
    "unipa-l-43-tecnologie-e-diagnostica-per-la-conservazione-del-patrimonio":
        "https://www.unipa.it/dipartimenti/stebicef/cds/tecnologieediagnosticaperlaconservazionedelpatrimonioculturale2425/",
    "unipa-l-21-urban-design-per-la-citta-in-transizione":
        "https://www.unipa.it/dipartimenti/architettura/cds/urbandesignperlacittaintransizione2448/",
    "unipa-lm-4-architettura-e-progetto-sostenibile-per-lesistente":
        "https://www.unipa.it/dipartimenti/architettura/cds/architetturaeprogettosostenibileperlesistente2495/",
    "unipa-lm-18-computer-science-and-artificial-intelligence":
        "https://www.unipa.it/dipartimenti/matematicaeinformatica/cds/computerscienceandartificialintelligence2323/",
    "unipa-lm-29-lm-27-electronics-and-telecommunications-engineering":
        "https://www.unipa.it/dipartimenti/ingegneria/cds/electronicsandtelecommunicationsengineeringfullyonline2258/",
    "unipa-lm-29-electronics-engineering": "https://www.unipa.it/dipartimenti/ingegneria/cds/electronicsengineering2234/",
    "unipa-lm-73-lm-69-scienze-e-tecnologie-agroingegneristiche-e-forestali":
        "https://www.unipa.it/dipartimenti/saaf/cds/scienzeetecnologieagroingegneristicheeforestali2259/",
    "unipa-lm-48-spatial-planning": "https://www.unipa.it/dipartimenti/architettura/cds/spatialplanning2333/",
    "unipa-lm-82-lm-data-statistica-e-data-science": "https://www.unipa.it/dipartimenti/seas/cds/statisticaedatascience2315/",
}

# Corsi rinominati con il nuovo ordinamento: il secondo anno (coorte precedente) sta ancora sulla pagina del corso
# con il nome vecchio; gli anni che la pagina principale non ha si leggono da lì
PAGINE_EXTRA = {
    "unipa-lm-4-architettura-e-progetto-sostenibile-per-lesistente":
        ["https://www.unipa.it/dipartimenti/architettura/cds/architetturaperilprogettosostenibiledellesistente2373/"],
}

# attività senza lezioni che l'elenco erogato non ha (completate dai dati aperti dell'a.a. precedente)
ATTIVITA = re.compile(
    r"(?i)prova finale|\btesi\b|thesis|final (?:exam|thesis)|tirocin|stage|internship|altre (?:attivit|conoscenz)|"
    r"other (?:activit|knowledge)|ulteriori|a scelta|information literacy|idoneit|seminar|abilit[àa']|"
    r"lingua|inglese|english|competenze linguistiche")
CSV_URL = "https://dati.unipa.it/dataset/offerta-formativa-{a}-{b}.csv"


def _num(s: str | None) -> float | None:
    try:
        v = float((s or "").replace(",", ".").strip())
    except ValueError:
        return None
    return int(v) if v.is_integer() else v


QUALIF = re.compile(r"(\(Modulo\)|\b(?:cattedra|sede|gruppo)\s+[\w.\-]+|suddivisa in moduli|Suddivisione per argomento)")


def _pulisci_nome(n: str) -> str:
    """Nome senza asterisco; in maiuscolo → iniziali maiuscole (anche con «(Modulo)», «cattedra A-L»…)."""
    n = html.unescape(n or "")
    n = re.sub(r"\s*\*+\s*$", "", n.strip())
    n = re.sub(r"\s+", " ", n).strip()
    # note dopo «(Modulo)» («Ricercatore», «Mutua da …», «da LM-59»): non fanno parte del nome
    n = re.sub(r"^(.*?\(Modulo\))\s+(?!(?:cattedra|sede|gruppo)\b)\S.*$", r"\1", n)
    parti = QUALIF.split(n)
    if not "".join(parti[0::2]).isupper():
        return n
    for j in range(0, len(parti), 2):
        p = parti[j]
        if p.strip():
            parti[j] = p[:len(p) - len(p.lstrip())] + _titolo(p) + p[len(p.rstrip()):]
    n = re.sub(r"\s+", " ", "".join(parti)).strip()
    # numeri romani in fondo al nome o prima di «:» e «-» («Analisi Matematica i», «Modulo Ii:»)
    return re.sub(r"(?<=\s)([IiVv]{1,4})(?=\s*(?::|-|$))",
                  lambda m: m.group(1).upper() if re.fullmatch(r"(?i)i{1,3}|iv|vi{0,3}", m.group(1)) else m.group(1), n)


def leggi_erogata(s: str) -> list[dict]:
    out = []
    sezioni = re.split(r'<h3 class="title">\s*Insegnamenti del (\w+) anno[^<]*</h3>', s)
    for ordinale, corpo in zip(sezioni[1::2], sezioni[2::2]):
        k = ORD.get(ordinale.lower())
        if not k:
            continue
        for art in re.findall(r'<article class="course-item[^"]*">(.*?)</article>', corpo, re.S):
            link = re.search(r'<a href="(\?[^"]*pagina=insegnamento[^"]*)">\s*([^<]*?)\s*</a>', art)
            nome = re.search(r'Nome:\s*</span>(.*?)</div>', art, re.S)
            cod = re.search(r"Codice:\s*</span>\s*(?:<a [^>]*>)?\s*(\w+)", art)
            cfu = re.search(r"CFU:\s*</span>\s*([\d.,]+)", art)
            doc = re.findall(r'Docente:\s*</span>(.*?)</div>', art, re.S)
            curr = re.search(r"Curriculum:\s*</span>\s*([^<]*?)\s*</div>", art)
            if not nome:
                continue
            grezzo = _testo(nome.group(1))
            v = _num(cfu.group(1)) if cfu else None
            out.append({
                "anno": k, "codice": cod.group(1) if cod else None, "nome": _pulisci_nome(grezzo),
                "opzionale": "*" in grezzo,
                "cfu": v,
                "docenti": [" ".join(w.capitalize() for w in _testo(d).split())
                            for d in re.findall(r"<a [^>]*>(.*?)</a>", doc[0] if doc else "", re.S) if _testo(d)],
                "curriculum": _testo(curr.group(1)) or None if curr else None,
                "url": html.unescape(link.group(1)) if link else None,
                "id_ins": (re.search(r"idInsegnamento=(\d+)", link.group(1)) or [None, None])[1] if link else None,
            })
    return out


def coorti(s: str) -> dict[int, str]:
    """anno di corso → a.a. del manifesto («Insegnamenti del secondo anno (manifesto degli studi 2025/2026)»)."""
    out = {}
    for ordinale, aa in re.findall(r'<h3 class="title">\s*Insegnamenti del (\w+) anno[^<]*?(\d{4}/\d{4})', s):
        if ORD.get(ordinale.lower()):
            out[ORD[ordinale.lower()]] = aa
    return out


# --- dati aperti ---------------------------------------------------------------------------------------

def leggi_csv(data: bytes) -> dict:
    """{"corsi": {codice corso → anno di corso → voci (una per codice e padre; i canali si uniscono)},
    "meta": {codice corso → (classe senza «R», nome normalizzato, riformato)}}."""
    import csv
    import io

    def dec(riga: bytes) -> str:  # il file ha qualche riga in cp1252
        try:
            return riga.decode("utf-8")
        except UnicodeDecodeError:
            return riga.decode("cp1252", errors="replace")

    testo = "\n".join(dec(r) for r in data.replace(b"\r", b"").split(b"\n"))
    out: dict[str, dict[int, dict]] = {}
    meta: dict[str, tuple] = {}
    for r in csv.DictReader(io.StringIO(testo), delimiter=";"):
        try:
            anno = int(r["ANNO_DI_CORSO"])
        except (KeyError, ValueError):
            continue
        cod = (r.get("CODICE_INSEGNAMENTO") or "").strip()
        cc = (r.get("CODICE_CORSO_DI_STUDI") or "").strip()
        if not cod or not cc:
            continue
        classe = (r.get("CLASSE_DI_LAUREA") or "").strip()
        meta.setdefault(cc, (re.sub(r"\s+R$", "", classe), _compatto(r.get("CORSO_DI_STUDI") or ""), classe.endswith(" R")))
        chiave = (cod, (r.get("COD_INSEGNAMENTO_PADRE") or "").strip())
        v = out.setdefault(cc, {}).setdefault(anno, {})
        if chiave not in v:
            v[chiave] = {
                "codice": cod, "nome": _titolo(re.sub(r"\s+", " ", r["INSEGNAMENTO"]).strip()),
                "tipo": (r.get("TIPO_INSEGNAMENTO") or "").strip(), "padre": chiave[1],
                "padre_nome": _titolo(re.sub(r"\s+", " ", r.get("DES_INSEGNAMENTO_PADRE") or "").strip()) or None,
                "cfu": _num(r.get("CFU")), "ssd": (r.get("SSD") or "").strip() or None,
                "semestre": (r.get("SEMESTRE") or "").strip(),
            }
    return {"corsi": {c: {a: list(v.values()) for a, v in anni.items()} for c, anni in out.items()}, "meta": meta}


def csv_del_corso(csv_dati: dict, codice: str | None, classe: str | None, nome: str) -> dict[int, list[dict]]:
    """Voci dei dati aperti del corso per anno. Un corso ha un codice per ordinamento (2086 per le coorti fino al
    2024/25, 2460 «R» per quelle dal 2025/26): gli anni che mancano nel codice della pagina si prendono
    dall'altro ordinamento (riformato o no) dello stesso nome e classe; con più sedi, da quello nella stessa
    posizione tra i codici."""
    corsi, meta = csv_dati.get("corsi") or {}, csv_dati.get("meta") or {}
    if not corsi:
        return {}
    proprio = corsi.get(codice or "", {})
    m = meta.get(codice or "")
    chiave = m[:2] if m else (re.sub(r"\s+R$", "", classe or ""), _compatto(nome))
    famiglia = sorted((c for c, mm in meta.items() if mm[:2] == chiave), key=int)
    out = dict(proprio)
    for anno in sorted({a for c in famiglia for a in corsi[c]} - set(proprio)):
        cand = [c for c in famiglia if c != codice and anno in corsi[c] and (m is None or meta[c][2] != m[2])]
        if len(cand) > 1 and m:
            miei = [c for c in famiglia if meta[c][2] == m[2]]
            altri = [c for c in famiglia if meta[c][2] != m[2]]
            cand = [altri[miei.index(codice)]] if len(miei) == len(altri) and altri[miei.index(codice)] in cand else []
        if len(cand) == 1:
            out[anno] = corsi[cand[0]][anno]
    return out


def scarica_csv(c, anno: int, log=print) -> tuple[dict, str | None]:
    """Dati aperti dell'a.a. precedente a quello in corso (fallback: quello prima)."""
    for a in (anno - 1, anno - 2):
        url = CSV_URL.format(a=a, b=a + 1)
        r = c.s.get(url, timeout=120)
        if r.status_code == 200 and r.content[:20].startswith(b"DES_DIPARTIMENTO"):
            log(f"[unipa] dati aperti {a}/{a + 1}: {len(r.content) // 1024} KB")
            return leggi_csv(r.content), url
    log("[unipa] dati aperti non disponibili")
    return {}, None


# --- piano di un corso ---------------------------------------------------------------------------------

def _stem(nome: str) -> str:
    return re.sub(r"\b(?:i{1,3}|iv|v|vi|\d+)\b|\(.*?\)", "", _norm(nome)).strip()


def _modulo(nome: str) -> tuple[str, str] | None:
    """«CONTENITORE C.I. - MODULO (Modulo)» → (contenitore, modulo)."""
    m = re.match(r"^(.*?)\s+-\s+(.*?)\s*\(Modulo\)(?:\s+.*)?$", nome, re.S)
    if not m:
        return None
    return m.group(1).strip(), m.group(2).strip()


def nome_modulo(contenitore: str, modulo: str) -> str:
    """Il modulo si chiama col suo titolo; se è generico («Modulo I», «Teoria») porta anche il contenitore."""
    m = re.sub(r"(?i)\s*\(modulo\)\s*$", "", modulo).strip()
    if len(m) < 12 or re.match(r"(?i)^(modulo|parte|mod\.)\b", m):
        return f"{contenitore} - {m}"
    return m


def _senza_ci(n: str) -> str:
    return re.sub(r"(?i)\s*[-–]?\s*\bC\.?\s?I\.?\s*$", "", n).strip()


def integrati(righe: list[dict]) -> list[dict]:
    """Per anno: contenitori «… C.I.» e moduli. Se le quote dei moduli fanno il totale del contenitore resta
    il solo modulo (`modulo_di`), altrimenti il solo contenitore."""
    out = []
    per_anno: dict[int, list[dict]] = {}
    for x in righe:
        per_anno.setdefault(x["anno"], []).append(x)
    for anno, lista in per_anno.items():
        moduli: dict[str, list[dict]] = {}
        for x in lista:
            mm = _modulo(x["nome"])
            if mm:
                moduli.setdefault(_norm(mm[0]), []).append(x)
        scartati = set()
        for x in lista:
            figli = moduli.get(_norm(re.sub(r"(?i)\s*\*+$", "", x["nome"])))
            if not figli or _modulo(x["nome"]):
                continue
            quote = {}
            for f in figli:
                quote[f["codice"] or f["nome"]] = f["cfu"] or 0
            if x["cfu"] is not None and abs(sum(quote.values()) - x["cfu"]) < 0.01:
                scartati.add(id(x))
                for f in figli:
                    f["_padre"] = x
            else:  # quote che non fanno il totale: vale il contenitore
                for f in figli:
                    scartati.add(id(f))
        for x in lista:
            if id(x) in scartati:
                continue
            mm = _modulo(x["nome"])
            if mm and "_padre" in x:
                x["modulo_di"] = _senza_ci(x["_padre"]["nome"])
                x["codice_ci"] = x["_padre"]["codice"]
                x["nome"] = nome_modulo(x["modulo_di"], mm[1])
                for k in ("docenti",):  # i docenti del contenitore valgono per il modulo senza docenti propri
                    if not x[k]:
                        x[k] = list(x["_padre"][k])
            elif mm:
                x["modulo_di"] = _senza_ci(mm[0])
                x["nome"] = nome_modulo(x["modulo_di"], mm[1])
            out.append(x)
    return out


def completa_con_csv(righe: list[dict], dati: dict[int, list[dict]], durata: int | None) -> tuple[list[dict], dict]:
    """Aggiunge le voci dei dati aperti: attività senza lezioni negli anni erogati, tutte le voci negli anni non
    erogati. Ritorna (righe nuove, riepilogo per anno)."""
    nuove, riep = [], {}
    codici = {x["codice"] for x in righe if x["codice"]}
    nomi = {_norm(x["nome"]) for x in righe}
    anni_erogati = {x["anno"] for x in righe}
    for anno in sorted(dati):
        if durata and anno > durata:
            continue
        voci = dati[anno]
        cont_con_moduli = {v["padre"] for v in voci if v["padre"]}
        if anno in anni_erogati:
            scelte = [v for v in voci if v["tipo"] == "N" and not v["ssd"] and (v["cfu"] or 0) > 0
                      and ATTIVITA.search(v["nome"]) and v["codice"] not in codici and _norm(v["nome"]) not in nomi]
            tipo = "attivita"
        else:
            scelte = [v for v in voci if (v["cfu"] or 0) > 0 and not (v["tipo"] == "I" and v["codice"] in cont_con_moduli)
                      and v["codice"] not in codici]
            tipo = "anno"
        # attività dello stesso tipo con CFU diversi (tirocinio da 3, 6 o 9 CFU): alternative
        gruppi: dict[str, set] = {}
        for v in scelte:
            gruppi.setdefault(_stem(v["nome"]), set()).add(v["cfu"])
        for v in scelte:
            alt = tipo == "attivita" and len(gruppi[_stem(v["nome"])]) > 1
            attivita = v["tipo"] == "N" and not v["ssd"] and bool(ATTIVITA.search(v["nome"]))
            item = {
                "anno": anno, "codice": v["codice"], "nome": v["nome"], "cfu": v["cfu"], "ssd": v["ssd"],
                "periodo": v["semestre"] if v["semestre"] in ("1", "2") else None, "docenti": [], "curriculum": None,
                # un'attività senza lezioni è obbligatoria (alternative se ce n'è più di una con CFU diversi);
                # se un insegnamento di un anno non erogato sia obbligatorio o a scelta i dati aperti non lo dicono
                "obbl": (False if alt else True) if attivita else None, "_tipo": tipo,
            }
            if v["tipo"] == "M" and v["padre_nome"]:
                item["modulo_di"] = _senza_ci(v["padre_nome"])
                item["codice_ci"] = v["padre"]
                item["nome"] = nome_modulo(item["modulo_di"], v["nome"])
            nuove.append(item)
        riep[anno] = (tipo, len(scelte))
    return nuove, riep


def _sede(corso: dict, tutti: list[dict]) -> str | None:
    """Sede per distinguere corsi omonimi (stesso nome e classe senza sede)."""
    # (Universitaly non dà la sede dei corsi di Palermo: quella già nel database viene da questo adattatore)
    simili = [c for c in tutti if (c["nome"].lower(), c.get("classe")) == (corso["nome"].lower(), corso.get("classe"))]
    if len(simili) < 2:
        return None
    nome, url = corso["nome"], (corso.get("url") or "").lower()
    m = re.search(r"(?i)replica\s+sede\s+([\w' ]+)$", nome)
    luogo = m.group(1).strip().title() if m else "Palermo"
    note = []
    if "online" in url or "corso online" in url or "prevalentemente a distanza" in (corso.get("erogazione") or ""):
        note.append("corso online")
    if "medit" in url:
        note.append("indirizzo tecnologico MED-IT")
    return f"{luogo} ({', '.join(note)})" if note else luogo


def fetch_ateneo(uid: str = "unipa", anno: int | None = None, max_cds: int | None = None, syllabus: bool = True,
                 corsi: list[dict] | None = None, log=print) -> dict:
    """Restituisce un contributo nel formato di database/contrib (vedi build_db.py)."""
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    c = Client(rate=4.0)
    # corsi con l'URL dell'elenco del dipartimento (`/dipartimenti/<dip>/?pagina=cds`) o senza pagina: si
    # cerca il link al corso per nome (e classe, se più ordinamenti hanno lo stesso nome)
    elenchi: dict[str, list[tuple[str, str]]] = {}
    pagine_dip: dict[str, str] = {}
    corsi = [dict(x) for x in corsi]
    for corso in corsi:
        if corso["id"] in PAGINE:
            corso["url"] = PAGINE[corso["id"]]
            continue
        m = re.match(r"https?://(?:www|portale)\.unipa\.it(/dipartimenti/[\w.-]+)/\?pagina=cds", corso.get("url") or "")
        if _pagina(corso.get("url")) or not m:
            continue
        if m.group(1) not in elenchi:
            r = c.get(f"{BASE}{m.group(1)}/?pagina=cds")
            elenchi[m.group(1)] = [(h, re.sub(r"^\s*\d+\s*-\s*", "", _testo(t))) for h, t in re.findall(
                r'href="([^"]*/cds/[\w.-]+/?)"[^>]*>(.*?)</a>', r.text if r else "", re.S)]
        nome = _compatto(corso["nome"])
        cand = sorted({h for h, t in elenchi[m.group(1)] if _compatto(t) and (_compatto(t) == nome or nome.startswith(_compatto(t)))})
        if len(cand) > 1:  # più ordinamenti (e livelli) con lo stesso nome: stessa classe
            giuste = []
            for h in cand:
                u = h if h.startswith("http") else BASE + h
                if u not in pagine_dip:
                    r = c.get(u)
                    cl = re.search(r"Classe:\s*([A-Z]+-[\w-]+)", _testo(r.text if r else ""))
                    pagine_dip[u] = cl.group(1) if cl else ""
                if pagine_dip[u] == corso.get("classe"):
                    giuste.append(h)
            cand = giuste or cand
            cand = [max(cand, key=lambda h: int((_codice_corso(h) or "0")))]
        if len(cand) == 1:
            h = cand[0]
            corso["url"] = h if h.startswith("http") else BASE + h
    sedi = {x["id"]: _sede(x, corsi) for x in corsi}
    for x in corsi:
        x["_sede"] = sedi[x["id"]]
    tutti = corsi
    corsi = [x for x in corsi if _pagina(x.get("url"))]
    if max_cds:
        corsi = corsi[:max_cds]
    log(f"[{uid}] {len(corsi)} corsi con sito su www.unipa.it")
    oggi = time.strftime("%Y-%m-%d")
    csv_dati, csv_url = scarica_csv(c, anno, log)
    vecchio = _libri_gia_raccolti(uid)

    def build(corso: dict) -> dict | None:
        base = _pagina(corso["url"])
        url = base + "?pagina=insegnamenti"
        r = c.get(url)
        if not r:
            return None
        righe = leggi_erogata(r.text)
        coorte = coorti(r.text)
        for x in righe:
            x.update(_base=base, _url=url, _coorte=coorte.get(x["anno"]))
        for extra_base in PAGINE_EXTRA.get(corso["id"], []):
            r2 = c.get(extra_base + "?pagina=insegnamenti")
            if r2:
                co2 = coorti(r2.text)
                anni_presenti = {x["anno"] for x in righe}
                for x in leggi_erogata(r2.text):
                    if x["anno"] not in anni_presenti:
                        x.update(_base=extra_base, _url=extra_base + "?pagina=insegnamenti", _coorte=co2.get(x["anno"]))
                        righe.append(x)
        # contenitori e moduli degli integrati
        righe = integrati(righe)
        durata = corso.get("durata_anni")
        dati_corso = csv_del_corso(csv_dati, _codice_corso(base), corso.get("classe"), corso["nome"])
        extra, riep = completa_con_csv(righe, dati_corso, durata) if dati_corso else ([], {})
        ssd_codice = {}
        for v in dati_corso.values():
            for x in v:
                if x["ssd"]:
                    ssd_codice.setdefault(x["codice"], x["ssd"])
                    ssd_codice.setdefault(x["codice"] + ":p", x["semestre"])
        if not righe and not extra:
            return None
        curricula = {x["curriculum"] for x in righe if x["curriculum"]}
        out: dict[tuple, dict] = {}
        for x in righe:
            key = (x["anno"], x["codice"] or x["nome"])
            item = out.get(key)
            if not item:
                item = out[key] = {
                    "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": None, "cfu": x["cfu"],
                    "ssd": ssd_codice.get(x["codice"]), "obbligatorio": not x["opzionale"], "curriculum": None,
                    "docenti": [], "url": x["_base"] + x["url"] if x["url"] else x["_url"], "libri": [], "esami": [],
                    "fonte": x["_url"], "verificato_il": oggi, "_c": set(), "_pdf": x["id_ins"],
                }
                for k in ("modulo_di", "codice_ci"):
                    if x.get(k):
                        item[k] = x[k]
                if x["_coorte"]:  # a.a. del manifesto da cui viene l'anno
                    item["fonte"] = f"{x['_url']}#manifesto-{x['_coorte'].replace('/', '-')}"
            else:  # stesso codice in più righe (curriculum, cattedra): un solo insegnamento
                item["obbligatorio"] = item["obbligatorio"] or not x["opzionale"]
                if _norm(x["nome"]) != _norm(item["nome"]):
                    item["nome"] = re.sub(r"(?i)\s+(?:cattedra|sede|gruppo)\s+\S+$", "", item["nome"])
            item["docenti"] = sorted(set(item["docenti"]) | set(x["docenti"]))
            item["_c"].add(x["curriculum"])
        for i in out.values():
            cs = i.pop("_c")
            if len(curricula) > 1 and None not in cs and cs != curricula:
                i["curriculum"] = ", ".join(sorted(cs))
        for x in extra:
            key = (x["anno"], x["codice"])
            if key in out:
                continue
            item = out[key] = {
                "codice": x["codice"], "nome": x["nome"], "anno": x["anno"], "periodo": x["periodo"], "cfu": x["cfu"],
                "ssd": x["ssd"], "obbligatorio": x["obbl"],
                "curriculum": None, "docenti": [], "url": base, "libri": [], "esami": [], "fonte": csv_url,
                "verificato_il": oggi,
            }
            if x["periodo"]:
                item["periodo_fonte"] = csv_url
            for k in ("modulo_di", "codice_ci"):
                if x.get(k):
                    item[k] = x[k]
        for i in out.values():
            o = vecchio.get((corso["id"], i["codice"]))
            if o:
                for k in ("libri", "stato_libri", "url_sito"):
                    if o.get(k):
                        i[k] = o[k]
        res = {"id": corso["id"], "nome": corso["nome"], "classe": corso.get("classe"),
               "durata_anni": corso.get("durata_anni"), "url": base,
               "curricula": sorted(curricula) if len(curricula) > 1 else None, "fonte": url,
               "verificato_il": oggi, "insegnamenti": list(out.values())}
        if corso.get("_sede"):
            res["sede"] = corso["_sede"]
        return res

    def build_safe(corso: dict) -> dict | None:
        try:
            return build(corso)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {corso.get('id')} saltato: {e!r}")
            return None

    out = []
    with cf.ThreadPoolExecutor(4) as ex:
        for n, r in enumerate(ex.map(build_safe, corsi), 1):
            if r:
                out.append(r)
            if n % 25 == 0:
                log(f"[{uid}]   corsi {n}/{len(corsi)}")
    # corsi con sede ma senza pagina (non ce ne sono nel catalogo attuale): non si inventano
    jobs: dict[str, list[dict]] = {}
    for x in out:
        for i in x["insegnamenti"]:
            pid = i.pop("_pdf", None)
            if pid and not i["libri"]:
                jobs.setdefault(pid, []).append(i)
    log(f"[{uid}] {len(out)} corsi, {sum(len(x['insegnamenti']) for x in out)} insegnamenti; "
        f"schede PDF da leggere: {len(jobs) if syllabus else 0}")

    firewall = {"n": 0}

    def scheda(pid: str) -> int:
        if firewall["n"] >= 3:  # il sito chiede il CAPTCHA: non si aggira né si insiste
            return 0
        try:
            with c.lock:
                time.sleep(c.min_gap)
                c.requests += 1
            r = c.s.get(SCHEDA + pid, timeout=120, verify=_bundle())
            if r.status_code != 200 or not r.content.startswith(b"%PDF"):
                firewall["n"] += 1
                return 0
            firewall["n"] = 0
            d = leggi_scheda_pdf(r.content)
            for it in jobs[pid]:
                it["periodo"] = d["periodo"] or it["periodo"]  # la scheda di trasparenza prevale sul CSV dei dati aperti
                it["libri"] = d["libri"]
                it["stato_libri"] = "completo" if d["libri"] else "da_aggiungere"
                it["url_sito"] = SCHEDA + pid
            return len(d["libri"])
        except Exception:  # noqa: BLE001
            return 0

    trovati = 0
    if syllabus:
        with cf.ThreadPoolExecutor(1) as ex:
            for n, k in enumerate(ex.map(scheda, list(jobs)), 1):
                trovati += k
                if n % 500 == 0:
                    log(f"[{uid}]   schede {n}/{len(jobs)}")
        if firewall["n"] >= 3:
            log(f"[{uid}] offertaformativa.unipa.it chiede il CAPTCHA: schede di trasparenza non lette")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid,
            "descrizione": "Generato da www.unipa.it, Didattica erogata, e dai dati aperti dell'ateneo (adapters/unipa.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": out, "canali": []}


def _libri_gia_raccolti(uid: str) -> dict[tuple, dict]:
    """(id corso, codice) → libri e scheda già raccolti (contributo precedente e database)."""
    vecchi: dict[tuple, dict] = {}
    for p in (ROOT / "database" / "contrib" / "auto" / f"{uid}.json", ROOT / "database" / "corsi" / f"{uid}.json"):
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        for corso in doc.get("corsi") or []:
            for i in corso.get("insegnamenti") or []:
                if isinstance(i, dict) and i.get("libri") and i.get("codice"):
                    vecchi.setdefault((corso["id"], i["codice"]), i)
    return vecchi
