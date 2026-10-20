"""Semestre degli insegnamenti della Macroarea di Lettere e Filosofia di Roma Tor Vergata.

Per i 24 corsi della Macroarea (più Scienze della nutrizione umana e Scienze dell'educazione) l'API GOMP ha
una sola unità di 12 mesi (`periodLength: 12`) e `uniroma2.py` scrive «annuale» per quasi tutti gli
insegnamenti: GOMP non conosce il semestre. Il semestre vero è nel calendario lezioni ufficiale della Macroarea
(pagina https://www-2024.lettere.uniroma2.it/calendario-lezioni/), che rimanda a un foglio Google pubblico
(`export?format=csv`, colonne Cognome, Nome, email, giorni-orario-aula, «Data inizio - fine lezioni»,
«Denominazione Modulo»; una riga per modulo/canale, senza il corso di laurea). Lo stesso foglio ha le righe
«EROGATO NEL II SEMESTRE». La pagina dice anche che «gli insegnamenti che non sono presenti sul calendario
saranno erogati nel II semestre».

Come si applica (solo agli insegnamenti oggi «annuale» nel database; i «1»/«2» di GOMP non si toccano):
- nome dell'insegnamento = nome del foglio (dopo aver tolto maiuscole, apostrofi, «(12 CFU)», sigle LM/LT/LLEM/…,
  lettere dei moduli A/B), stessi numeri (1/2/3: «Lingua polacca 1/2/3» sono insegnamenti diversi), stesso livello
  (LM/LT dove il foglio lo dice) e modulo compatibile (un insegnamento da 12 CFU si abbina solo se il foglio ha
  entrambi i moduli A e B): date di ottobre-dicembre -> "1"; «EROGATO NEL II SEMESTRE» -> "2".
  Fonte: il foglio.
- stesso nome con righe del foglio in disaccordo (I e II semestre, canali diversi), con righe senza date
  («a distanza», «date da concordare», docente da definire), numero/modulo/livello che non coincide, o nome solo
  simile a uno del foglio: non si abbina (resta «annuale»).
- nome per niente simile a nessuna riga del foglio, e insegnamento vero (non prova finale, tirocinio, attività
  a scelta, altre attività, idoneità, laboratori e seminari, livelli linguistici…): regola della pagina ->
  "2". Fonte: la pagina, con l'ancora `#regola-insegnamenti-non-presenti-nel-calendario-erogati-nel-ii-semestre`
  (il semestre viene da quella regola, non da una riga del foglio).

Il foglio è «in continuo aggiornamento»: rilanciare lo script per riprendere i cambiamenti. Per avere i dettagli
di ogni decisione: `--rapporto <file.json>`.

Come si lancia (da `tools/db_builder`):

    python -X utf8 -m adapters.periodi_uniroma2 [--rapporto rapporto.json]
    python -X utf8 ricostruisci.py uniroma2
    (poi ancora una volta le due righe: con i periodi nuovi `pulizia` non unisce più alcune righe omonime di anni
     diversi, e le righe separate si correggono solo al secondo giro; dal terzo il risultato non cambia più)

Scrive `database/contrib/auto/uniroma2_periodi.json`. Le copie della pagina e del foglio si salvano in
`$UN_HTTP_CACHE/periodi_uniroma2` (se la variabile è impostata). Due richieste in tutto.
"""
from __future__ import annotations

import csv
import difflib
import io
import json
import os
import re
import sys
import unicodedata

import requests

from . import periodi

HEADERS = {"User-Agent": "Mozilla/5.0 (UniversityNotes database builder; +https://github.com/Simo-Magnus/UniNotes)"}
PAGINA = "https://www-2024.lettere.uniroma2.it/calendario-lezioni/"
FOGLIO_ID = "1gP--2cA0kaKB154xOCDm3h3pYCUrqlmQmNpmC59Zcnw"
FOGLIO_CSV = f"https://docs.google.com/spreadsheets/d/{FOGLIO_ID}/export?format=csv"
FOGLIO = f"https://docs.google.com/spreadsheets/d/{FOGLIO_ID}/edit?usp=sharing"
FONTE_REGOLA = PAGINA + "#regola-insegnamenti-non-presenti-nel-calendario-erogati-nel-ii-semestre"

# sigle di corso/canale che il foglio e il database aggiungono ai nomi
DESIGNATORI = {"lt", "llem", "llea", "linfo", "licus", "corlib", "sari", "cdl", "cds", "edu", "spe", "mod", "modulo",
               "canale", "unico"}
MODULI = {"a", "b", "c"}
ROMANI = {"i": 1, "ii": 2, "iii": 3}
# righe del foglio con più insegnamenti o con note nel nome: elenco esplicito dei nomi (senza, si divide
# solo su «;», « / » e «=»)
ELENCHI = {
    "DIRITTO DELL'ECONOMIA DEI BENI CULTURALI LM, STORIA DELL'ARTE; DIRITTO AMMINISTRATIVO DELL'ECONOMIA DEI BENI CULTURALI CORLIB":
        ["Diritto dell'economia dei beni culturali LM", "Diritto amministrativo dell'economia dei beni culturali"],
    "LETTERATURA FRANCESE 2A - 3A LLEM. Lett. Francese 1B (CdS Linfo e Lettere)":
        ["Letteratura Francese 2 A", "Letteratura Francese 3 A", "Letteratura Francese 1 B"],
    "LINGUA TEDESCA LLEA I / II A": ["Lingua Tedesca 1 A", "Lingua Tedesca 2 A"],
    "METODOLOGIE E TECNOLOGIE DIDATTICHE LM - corso LICUS": ["Metodologie e Tecnologie Didattiche LM"],
    "STORIA MODERNA A - LT DI STORIA - CDS IN LINGUA": ["Storia Moderna A LT"],
    "STORIA MODERNA B - LT DI STORIA - CDS IN LINGUA": ["Storia Moderna B LT"],
    "GLOTTOLOGIA A - LINGUISTICA GENERALE E SOCIOLINGUISTICA A - LINGUISTICA GENERALE E APPLICATA A":
        ["Glottologia A", "Linguistica Generale e Sociolinguistica A", "Linguistica Generale e Applicata A"],
    "STORIA DELLA PSICOLOGIA - STORIA DEL PENSIERO SCIENTIFICO": ["Storia della Psicologia", "Storia del Pensiero Scientifico"],
    "PSICOLOGIA GENERALE - FONDAMENTI DI PSICOLOGIA A": ["Psicologia Generale", "Fondamenti di Psicologia A"],
    "ENGLISH LANGUAGE - LINGUA INGLIESE 1": ["English Language", "Lingua Inglese 1"],
    "MUSEOLOGIA E STORIA DEL COLLEZIONISMO A - MUSEOLOGIA E STORIA DEL COLLEZIONISMO LM A":
        ["Museologia e Storia del Collezionismo A", "Museologia e Storia del Collezionismo LM A"],
    "LABORATORIO BABY OBSERVATION - CANALE 1": ["Laboratorio Baby Observation"],
    "ARCHEOLOGIA FENICIO - PUNICA A": ["Archeologia Fenicio-Punica A"],
    "ARCHEOLOGIA FENICIO - PUNICA B": ["Archeologia Fenicio-Punica B"],
    "STORIA DEL TEATRO E DELLA DANZA CONTEMPORANEI (ex-Storia del Teatro contemporaneo A) https://short-url.cc/1zaZD":
        ["Storia del Teatro e della Danza Contemporanei", "Storia del Teatro Contemporaneo A"],
    "LETTERATURA TEATRALE ITALIANA per lettere (valido anche per lett. Italiana per beni culturali)":
        ["Letteratura Teatrale Italiana"],
    "LETTERATURA ITALIANA MOD. A; FILOLOGIA MODERNA (VALIDO PER LM MUSICA E SPETTACOLO)":
        ["Letteratura Italiana A", "Filologia Moderna"],
    "LETTERATURA ITALIANA 2 A - 2 B": ["Letteratura Italiana 2 A", "Letteratura Italiana 2 B"],
    "ARCHEOLOGIA E STORIA DELL'ARTE GRECA E ROMANA A - B (DALLA LETTERA A ALLA M)- IL 23 NOVEMBRE INIZIO: ARCHEOLOGIA ROMANA (SciTur)":
        ["Archeologia e Storia dell'Arte Greca e Romana A-B"],
    "ARCHEOLOGIA E STORIA DELL'ARTE GRECA E ROMANA PER BENI CULTURALI ( M-Z )E LETTERE (A-Z) / ARCHEOLOGIA GRECA PERCORSI TRIENNALE PER SCITUR (A-Z)/ ARCHEOLOGIA E STORIA DELL'ARTE GRECA MAGISTRALE (A-Z)":
        ["Archeologia e Storia dell'Arte Greca e Romana", "Archeologia Greca", "Archeologia e Storia dell'Arte Greca"],
    "LINGUISTICA COMPUTAZIONALE LM A / LINGUISTICA GENERALE E APPLICATA B":
        ["Linguistica Computazionale LM A", "Linguistica Generale e Applicata B"],
    "Corso preparatorio per gli studenti Erasmus - Seminario di lingua e cultura polacca - Seminario di lingua e cultura polacca":
        ["Corso preparatorio per gli studenti Erasmus - Seminario di lingua e cultura polacca"],
    "STORIA DELLA PEDAGOGIA A+B: INTERPRETI, IDEALI, TRADIZIONI (A-L)": ["Storia della Pedagogia A+B"],
    "STORIA DELLA PEDAGOGIA MOD. A: INTERPRETI, IDEALI, TRADIZIONE (CANALE M-Z)": ["Storia della Pedagogia A"],
    "STORIA DELLA PEDAGOGIA MOD. B: INTERPRETI, IDEALI, TRADIZIONE (CANALE M-Z)": ["Storia della Pedagogia B"],
}
# refusi del foglio (nomi riscritti prima del confronto)
REFUSI = [
    (r"archelogia", "archeologia"), (r"archeozzologia", "archeozoologia"), (r"\blenguage\b", "language"),
    (r"\bingliese\b", "inglese"), (r"\bfrancesce\b", "francese"), (r"\binfomativi\b", "informativi"),
    (r"\bpopolar\b", "popular"), (r"\bevent lm\b", "events lm"), (r"\bper turismo\b", "per il turismo"),
    (r"history its theories", "history and its theories"),
]
STOP = {"di", "del", "della", "dei", "delle", "dell", "degli", "e", "ed", "in", "per", "il", "la", "lo", "le", "l", "d", "un", "una",
        "and", "of", "the", "for", "to", "a", "al", "alla", "nel", "nella", "con", "su"}
# insegnamenti veri ma senza semestre proprio: né abbinati né «non presenti» (restano «annuale»)
NON_INSEGNAMENTO = re.compile(
    r"prova finale|tesi|tirocin|stage|internship|altre attivit|ulteriori attivit|altre conoscenze|conoscenze utili|"
    r"idoneit|a scelta|scelta libera|crediti liberi|attivit[aà] formative|laboratorio|\blab\b|seminar|workshop|"
    r"livello [abc][12]|level\)|abilit[aà]|\bofa\b|corso zero|\bade\b|final exam|thesis|elective|esame finale|"
    r"extra activities|optional courses|other languages|almeno una lingua|conoscenze linguistiche|language test|"
    r"laboratori interdisciplinari|competenze per|\bscavo\b|\bscavi\b", re.I)
# nomi in tedesco: insegnamenti del percorso con l'Università di Halle, non regolati dal calendario di Tor Vergata
TEDESCO = re.compile(r"\bund\b|\bschreiben\b|\bsprache\b|forschungsmodul|\bphilosophie\b|^ma |konzeptionen", re.I)
# Scienze della nutrizione umana è un corso di Medicina (www-2021.scienzenutrizione.uniroma2.it): il calendario
# della Macroarea di Lettere non lo riguarda
CORSI_ESCLUSI = ("uniroma2-lm-61-scienze-della-nutrizione-umana",)
NON_ABBINABILE = re.compile(r"prova finale|tesi di|tirocin|stage|internship|altre attivit|ulteriori attivit|altre conoscenze|"
                            r"conoscenze utili|idoneit|a scelta|scelta libera|crediti liberi|livello [abc][12]|level\)", re.I)


def _ascii(s: str) -> str:
    return unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()


def firma(nome: str) -> dict:
    """Nome -> {base: parole del nome, nums: numeri 1/2/3…, livello: LM|LT|None, moduli: {A,B,C}}."""
    s = _ascii(nome)
    s = re.sub(r"https?://\S+", " ", s)
    s = re.sub(r"\(\s*\d+\s*cfu\s*\)", " ", s)
    s = re.sub(r"^\s*curriculum [a-z]\s*:", " ", s)  # (L-15: «CURRICULUM D: …» è il nome nel curriculum)
    s = re.sub(r"\blab\b\.?", "laboratorio", s)
    s = re.sub(r"^\s*laboratorio\s*:?\s*(?:di |del |della )?", "laboratorio ", s)
    for a, b in REFUSI:
        s = re.sub(a, b, s)
    avanzato = bool(re.search(r"corso avanzato", s))
    s = re.sub(r"\(\s*corso avanzato\s*\)", " ", s)
    s = re.sub(r"\(([^)]*)\)", " ", s)
    s = re.sub(r"(?<![\d/])([1-9])\s*-\s*([1-9])(?!\d)",
               lambda m: " " + " ".join(str(k) for k in range(int(m.group(1)), int(m.group(2)) + 1)) + " ", s)
    s = re.sub(r"([1-9])\s*/\s*([1-9])(?:\s*/\s*([1-9]))?", lambda m: " " + " ".join(g for g in m.groups() if g) + " ", s)
    s = re.sub(r"(\d)(?=[a-z])", r"\1 ", s).replace("'", " ")
    nums, livello, moduli, base = set(), None, set(), []
    for x in re.findall(r"[a-z0-9]+", s):
        if x.isdigit():
            nums.add(int(x))
            base.append(("#", x))
        elif x in ("lm", "llea", "licus"):  # (LLEA = LM-37, LICUS = LM-39: magistrali)
            livello = "LM"
        elif x in ("lt", "llem", "linfo"):  # (LLEM = L-11 Lingue e letterature moderne, LINFO = L-11: triennali)
            livello = livello or "LT"
        elif x in ("l", "d") or x in DESIGNATORI:
            pass
        else:
            base.append(("w", x))
    out = []
    for k, (ty, x) in enumerate(base):
        if ty == "w" and x in MODULI:
            prec = out[-1] if out else None
            resto = base[k + 1:]
            if (not resto) or (prec and prec[0] in ("#", "m")) or all(r[0] == "#" or r[1] in MODULI for r in resto):
                moduli.add(x.upper())
                out.append(("m", x))
                continue
        out.append((ty, x))
    parole = [x for ty, x in out if ty == "w"]
    if parole and parole[-1] in ROMANI:
        nums.add(ROMANI[parole.pop()])
    return {"base": tuple(parole) + (("avanzato",) if avanzato else ()), "nums": frozenset(nums), "livello": livello,
            "moduli": frozenset(moduli)}


def leggi_foglio(testo: str) -> list[dict]:
    """Righe del foglio -> [{doc, nome, date, nota, stato: I|II|?, parti: [nomi]}]."""
    righe = list(csv.reader(io.StringIO(testo)))
    out = []
    for r in righe:
        if len(r) < 6 or r[0] == "Cognome" or not any(r) or not r[5].strip():
            continue
        nome = re.sub(r"\s+", " ", r[5]).strip()
        date = re.sub(r"\s+", " ", r[4]).strip()
        nota = re.sub(r"\s+", " ", r[3]).strip()
        ds = re.findall(r"(\d{1,2})\s*/+\s*(\d{1,2})\s*/+\s*(\d{4})", date)
        if re.search(r"ii semestre|secondo semestre", nota, re.I):
            stato = "II"
        elif ds and all(9 <= int(m) <= 12 for _, m, _ in ds):
            stato = "I"
        elif not ds and re.search(r"ottobre|novembre|dicembre", nota, re.I) and not re.search(r"gennaio|febbraio|marzo|aprile|maggio", nota, re.I):
            stato = "I"  # (date scritte nella colonna degli orari: «7 OTTOBRE: MERC. 18-20 …»)
        else:
            stato = "?"  # a distanza, date da concordare, docente da definire…
        parti = ELENCHI.get(nome)
        if parti is None:
            s = re.sub(r"https?://\S+", " ", nome)
            parti = [p.strip() for p in re.split(r"\s*;\s*|\s+/\s*|\s*/\s+|\s*=\s*", s) if p.strip()]
        out.append({"doc": r[0].strip(), "nome": nome, "date": date, "nota": nota, "stato": stato, "parti": parti})
    return out


def indice(voci: list[dict]) -> dict[tuple, list[dict]]:
    idx: dict[tuple, list[dict]] = {}
    for v in voci:
        for p in v["parti"]:
            f = firma(p)
            if f["base"]:
                idx.setdefault(f["base"], []).append({**f, "stato": v["stato"], "riga": v["nome"], "date": v["date"]})
    return idx


def _radice(w: str) -> str:
    w = re.sub(r"(c|g)he$", r"\1a", w)
    return w[:-1] if len(w) >= 5 and w[-1] in "aeio" else w


def _contenuto(base: tuple) -> tuple:
    return tuple(_radice(w) for w in base if w not in STOP)


def _simile(base: tuple, idx: dict) -> str | None:
    """Nome del foglio che potrebbe essere lo stesso insegnamento con un titolo un po' diverso: quasi uguale a meno
    di refusi, con le stesse parole di contenuto (singolare/plurale a parte), con una qualificazione in fondo
    («Letteratura latina» / «Letteratura latina medievale») o con una sola parola in più o in meno («Intelligenza
    artificiale» / «Filosofia dell'intelligenza artificiale»). Nel dubbio non si abbina e non si applica la regola."""
    b = " ".join(base)
    cb = _contenuto(base)
    for k in idx:
        if difflib.SequenceMatcher(None, b, " ".join(k)).ratio() >= 0.9:
            return " ".join(k)
        ck = _contenuto(k)
        piccolo, grande = (cb, ck) if len(cb) <= len(ck) else (ck, cb)
        if len(piccolo) < 2:
            continue
        sp, sg = set(piccolo), set(grande)
        if sp == sg or (sp <= sg and grande[:len(piccolo)] == piccolo):
            return " ".join(k)
        if sp <= sg and len(sg - sp) <= 1 and "avanzato" not in sg - sp:
            return " ".join(k)
    return None


def classifica(nome: str, cfu, idx: dict) -> tuple[str, str | None, str]:
    """(esito, periodo, motivo); esito: foglio | assente | dubbio."""
    g = firma(nome)
    if not g["base"]:
        return "dubbio", None, "nome senza parole"
    liv = g["livello"]
    cand = idx.get(g["base"])
    if not cand:
        s = _simile(g["base"], idx)
        return ("dubbio", None, f"nome simile a «{s}»") if s else ("assente", None, "nessuna riga simile nel foglio")
    # numeri
    if g["nums"]:
        cand = [c for c in cand if c["nums"] and g["nums"] <= c["nums"]]
    else:
        cand = [c for c in cand if not c["nums"]]
    if not cand:
        return "dubbio", None, "stesso nome ma numero (1/2/3) diverso o assente nel foglio"
    # livello: «Lm» nel nome = solo le righe LM (o senza livello); senza «Lm» (anche negli insegnamenti condivisi che
    # compaiono nei corsi magistrali) = le righe senza livello o LT, mai quelle solo LM
    if liv == "LM":
        cand = [c for c in cand if c["livello"] == "LM"] or [c for c in cand if c["livello"] is None]
    else:
        cand = [c for c in cand if c["livello"] in (None, "LT")]
    if not cand:
        return "dubbio", None, "stesso nome ma livello (LM/LT) diverso"
    # moduli
    if g["moduli"]:
        cand = [c for c in cand if not c["moduli"] or g["moduli"] <= c["moduli"]]
        if not cand:
            return "dubbio", None, "modulo A/B non presente nel foglio"
    else:
        uniti = set().union(*[c["moduli"] for c in cand])
        if (cfu or 0) >= 12 and uniti and uniti != {"A", "B"} and not any(not c["moduli"] for c in cand):
            return "dubbio", None, "12 CFU ma il foglio ha un solo modulo"
    stati = {c["stato"] for c in cand}
    if stati == {"I"}:
        return "foglio", "1", "; ".join(sorted({c["riga"] for c in cand}))
    if stati == {"II"}:
        return "foglio", "2", "; ".join(sorted({c["riga"] for c in cand}))
    return "dubbio", None, f"righe del foglio in disaccordo o senza date: {sorted(stati)}"


def scarica(log=print) -> tuple[str, str]:
    cache = os.environ.get("UN_HTTP_CACHE")
    if cache:
        cache = os.path.join(cache, "periodi_uniroma2")
        os.makedirs(cache, exist_ok=True)
    r = requests.get(PAGINA, headers=HEADERS, timeout=60)
    r.raise_for_status()
    pagina = r.text
    testo = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", pagina))
    if not re.search(r"CALENDARIO LEZIONI I SEMESTRE 2026/2027", testo):
        raise RuntimeError("la pagina non è più il calendario del I semestre 2026/2027: ricontrollare")
    if FOGLIO_ID not in pagina:
        raise RuntimeError("la pagina del calendario non rimanda più al foglio atteso: ricontrollare")
    if not re.search(r"insegnamenti che non sono presenti sul calendario saranno erogati nel II semestre", testo, re.I):
        raise RuntimeError("la pagina non riporta più la regola «non presenti sul calendario = II semestre»: ricontrollare")
    r = requests.get(FOGLIO_CSV, headers=HEADERS, timeout=60)
    r.raise_for_status()
    foglio = r.content.decode("utf-8")
    if "Denominazione Modulo" not in foglio:
        raise RuntimeError("il foglio non ha più la colonna «Denominazione Modulo»")
    if cache:
        open(os.path.join(cache, "calendario-lezioni.html"), "w", encoding="utf-8").write(pagina)
        open(os.path.join(cache, "foglio.csv"), "w", encoding="utf-8").write(foglio)
    log(f"[uniroma2] pagina {len(pagina)} byte, foglio {len(foglio)} byte")
    return pagina, foglio


def fetch_periodi(uid: str = "uniroma2", log=print, rapporto: list | None = None, foglio: str | None = None) -> dict:
    if foglio is None:
        _, foglio = scarica(log)
    voci = leggi_foglio(foglio)
    idx = indice(voci)
    log(f"[{uid}] foglio: {len(voci)} righe ({sum(v['stato'] == 'I' for v in voci)} del I semestre, "
        f"{sum(v['stato'] == 'II' for v in voci)} del II, {sum(v['stato'] == '?' for v in voci)} senza date)")
    out: dict[str, dict] = {}
    conta = {"abbinati I semestre": 0, "abbinati II semestre": 0, "regola non presente": 0,
             "dubbi (restano annuale)": 0, "attivita senza semestre (restano annuale)": 0}
    conta["corsi fuori dalla Macroarea (restano annuale)"] = 0
    # insegnamenti già corretti da una esecuzione precedente (nel database oggi hanno già 1/2): si riesaminano, così lo
    # script si può rilanciare e il file prodotto è sempre completo
    nostri: set[str] = set()
    vecchio = periodi.DB / "contrib" / "auto" / f"{uid}_periodi.json"
    if vecchio.exists():
        for cc in json.loads(vecchio.read_text(encoding="utf-8")).get("corsi", []):
            nostri.update(ii["id"] for ii in cc["insegnamenti"])
    for c in periodi.carica(uid)["corsi"]:
        if c.get("piano_da"):
            continue
        if c["id"] in CORSI_ESCLUSI:
            conta["corsi fuori dalla Macroarea (restano annuale)"] += sum(
                i.get("periodo") == "annuale" for i in c.get("insegnamenti") or [])
            continue
        for i in c.get("insegnamenti") or []:
            if i.get("periodo") != "annuale" and i["id"] not in nostri:
                continue  # solo quelli che GOMP dà «annuale» (o che questo script ha già corretto): i semestri di GOMP non si toccano
            nome = i.get("nome") or ""
            esito, p, motivo = classifica(nome, i.get("cfu"), idx)
            if esito == "foglio" and NON_ABBINABILE.search(nome):
                esito, p, motivo = "dubbio", None, "attività senza semestre proprio"
            if esito == "foglio":
                out[i["id"]] = {"periodo": p, "fonte": FOGLIO}
                conta["abbinati I semestre" if p == "1" else "abbinati II semestre"] += 1
            elif esito == "assente":
                if NON_INSEGNAMENTO.search(nome) or TEDESCO.search(nome):
                    conta["attivita senza semestre (restano annuale)"] += 1
                    esito, motivo = "attivita", "attività senza semestre proprio o del percorso con Halle"
                else:
                    out[i["id"]] = {"periodo": "2", "fonte": FONTE_REGOLA}
                    conta["regola non presente"] += 1
                    p = "2"
                    esito = "regola"
            else:
                conta["dubbi (restano annuale)"] += 1
            if rapporto is not None:
                rapporto.append({"id": i["id"], "corso": c["id"], "nome": nome, "anno": i.get("anno"), "cfu": i.get("cfu"),
                                 "esito": esito, "periodo": p, "motivo": motivo})
    log(f"[{uid}] {conta}")
    return out


if __name__ == "__main__":
    rap: list = []
    ris = fetch_periodi(rapporto=rap)
    print(periodi.scrivi("uniroma2", ris, unisci=False))
    if "--rapporto" in sys.argv:
        with open(sys.argv[sys.argv.index("--rapporto") + 1], "w", encoding="utf-8") as f:
            json.dump(rap, f, ensure_ascii=False, indent=0)
