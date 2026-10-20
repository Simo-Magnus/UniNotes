"""Università Parthenope (Napoli): piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://uniparthenope.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore comune
(`cineca_catalogue`) servono:

- piano per coorte: per l'anno di corso k nell'a.a. A si legge il piano della coorte A-k+1 (gli iscritti oggi al k-esimo anno).
  Con il riordino del 2025 i corsi hanno cambiato codice («0124» → «R124», «0418» → «R418»): la coorte precedente si ritrova per
  codice (la «R» iniziale vale «0»), per nome, sede e tipo, o per nome e tipo. Nelle coorti 2025/2026 il codice vecchio resta come
  guscio senza anni accanto a quello nuovo: si prende quello che ha l'anno cercato. Il piano di una coorte pubblica di solito
  tutti gli anni, ma i corsi riordinati hanno nel catalogo solo il 1° anno (e a volte il 2°) della coorte 2026/2025: gli anni
  mancanti o con meno di 30 CFU dichiarati si leggono dalla coorte più vicina che li ha;
- durata dal piano («3 anni», «6 anni»);
- gruppi del piano (`cod`): «OO» obbligatori; «F» (OFA, prove a 0 CFU), «G» scelte (una scelta tra, con i CFU nell'etichetta: «ESAMI
  A SCELTA I ANNO (6 CFU)»); «S» crediti liberi senza elenco, con i CFU nell'etichetta («III ANNO A SCELTA (12 CFU)»). Un'attività è
  obbligatoria se sta in «OO» o se il gruppo la richiede per intero (CFU fissi dell'etichetta uguali alla somma delle attività);
- gruppi senza attività elencate: voce a scelta con i CFU dell'etichetta; gli «altreAttivita» (elenco degli insegnamenti erogati,
  non è il piano) non si leggono;
- attività a 0 CFU (OFA, TOLC, test, livello di inglese) non sono insegnamenti del piano;
- sedi: Napoli (1405), Nola (1406), Caivano (1663). Scienze motorie e Giurisprudenza hanno un corso per sede, ognuno con il proprio
  codice e il proprio id Universitaly (`ID_UNIVERSITALY`, dal sito del corso e dal nome inglese);
- percorsi: «comune» (campo del catalogo o nome) valgono per tutti i curricula; lo stesso percorso nelle coorti si riconosce per
  nome, per codice senza anno e «R», o per gli insegnamenti in comune (almeno il 40%);
- il catalogo ha anche dottorati, master e short master: non sono corsi di studio e si saltano.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri già raccolti nel database (`libri_noti`) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/uniparthenope.json`, tenendo gli appelli già presenti):

    python tools/db_builder/adapters/uniparthenope.py [--senza-syllabus]
"""
from __future__ import annotations

import concurrent.futures as cf
import difflib
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import unicodedata

if __package__ in (None, ""):  # esecuzione diretta
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    __package__ = "adapters"

from . import ammissione  # noqa: E402
from . import cineca_catalogue as cc  # noqa: E402
from .uniba import libri_testo_libero  # noqa: E402

BASE = "https://uniparthenope.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI = {"L2", "LM", "LM5", "LM6"}  # lauree (L2 anche le professionalizzanti), magistrali, ciclo unico (non i dottorati e i master)

# Corsi omonimi di sedi diverse (codice del catalogo con la «R» → «0») → id Universitaly. L'abbinamento è per sito del corso
# (il «sitoweb» del catalogo è l'indirizzo orienta.uniparthenope.it di Universitaly) e per nome inglese del corso
# («Human Movement Sciences», «Sport Sciences», «Sports Sciences»).
ID_UNIVERSITALY: dict[str, str] = {
    "0512": "1629344",  # Scienze motorie, Napoli (Human Movement Sciences)
    "0522": "1629345",  # Scienze motorie, Nola (sede-di-nola/scienze-motorie-sede-di-nola; Sport Sciences)
    "0523": "1629346",  # Scienze motorie, Caivano (Sports Sciences)
    "0418": "1629353",  # Giurisprudenza, Napoli (laurea-triennale/giurisprudenza)
    "0249": "1629354",  # Giurisprudenza, Nola (laurea-in-giurisprudenza-nola)
}

# Correzioni al catalogo dove il piano ufficiale dice altro: (cdsCod, anno di corso) → {codice dell'attività: regola}.
# Regole: "escludi" | "scelta" | "cfu=<n>". Fonte nella nota di cfu_verificati/del report dell'agente.
CORREZIONI: dict[tuple[str, int], dict[str, str]] = {}

# Coorte da cui leggere un anno quando il piano della coorte degli iscritti è incompleto: (cdsCod, anno) → coorte
COORTE_ANNO: dict[tuple[str, int], int] = {}

_ETICHETTA_CFU = re.compile(r"(?:\(\s*)?(?:(?:fra|tra)\s+([\d.,]+)\s+e\s+)?(?<![\w.,])([\d.,]*\d)\s*(?:CFU|crediti)\b(?:\s*\))?", re.I)
_NOTA_CFU = re.compile(r"(?i)(?<!max )(?<!massimo )(?<!fino a )(?<!\d)(?:CFU\s+(\d+)\b|\b(\d+)\s*(?:CFU|crediti))")
_COMUNE = re.compile(r"(?i)\bcomune\b")
_SCELTA = re.compile(r"(?i)scelt|opzional|alternativ|elective|optional|oppure|\btra\b|\bor\b|among|betwee?n|beetween|\bone\b")
_SOVRANNUMERARIO = re.compile(r"(?i)sovra\s*n+umerar")  # attività oltre i CFU del corso: non fanno parte del piano
_DEBITO = re.compile(r"(?i)\bdebito\b|obblig\w*\s+formativ|\bofa\b")
_FREQUENZA = re.compile(r"(?i)\(\s*(?:fr|frequency only|solo frequenza)\s*\)\s*$")
_ALTERNATIVA = re.compile(r"(?i)\bOPZ\b|\bopzion|\boppure\b|\balternativ")  # «Tirocinio OPZ 1 (12 CFU)»: una delle due
_CONDIZIONATO = re.compile(r"(?i)\bper chi\b|\bse non\b|\bnon (?:l'ha|ha)\b|\bchi non\b|\boppure\b|\bscelta\b|\balternativ")


def _norm(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _nn(s: str | None) -> str:
    """Nome per confrontare gli insegnamenti: le parentesi restano («Tirocinio II (primo semestre)» ≠ «… (secondo semestre)»)."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _numero(s: str) -> float:
    v = float(s.replace(",", "."))
    return int(v) if v == int(v) else v


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _durata(det: dict, tipo: str | None) -> int:
    m = re.match(r"\s*(\d+)", det.get("durata_it") or "")
    if m:
        return int(m.group(1))
    if isinstance(det.get("crediti"), (int, float)) and det["crediti"] >= 60:
        return int(det["crediti"] // 60)
    return {"L2": 3, "LM": 2, "LM5": 5}.get(tipo or "", 3)


def _cod_base(cds: str | None) -> str:
    """Il codice del corso cambia con il riordino («0124» → «R124»): con la «R» iniziale al posto dello zero è lo stesso corso."""
    return re.sub(r"^R(?=\d)", "0", (cds or "").strip())


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/uniparthenope)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "uniparthenope" if d else None

    def get(self, path, params=None):
        if not self.cache:
            return super().get(path, params)
        key = hashlib.sha1((path + json.dumps(params or {}, sort_keys=True)).encode()).hexdigest()
        f = self.cache / key[:2] / f"{key}.json"
        if f.exists():
            return json.loads(f.read_text(encoding="utf-8"))
        dati = super().get(path, params)
        if dati is not None:  # le risposte mancanti (rete, 404) si riprovano alla prossima raccolta
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(dati, ensure_ascii=False), encoding="utf-8")
        return dati


def _titolo_etichetta(s: str) -> str:
    s = re.sub(r"\s+", " ", s).strip(" -–:/")
    if not s.isupper():
        return s[:1].upper() + s[1:]
    return s[:1].upper() + s[1:].lower()


def _cfu_etichetta(label: str):
    """(minimo, massimo) dei CFU nell'etichetta di un gruppo: «(12 CFU)» → (12, 12), «(fra 6 e 18 CFU)» → (6, 18)."""
    m = _ETICHETTA_CFU.search(label or "")
    if not m:
        return None
    try:
        hi = _numero(m.group(2).strip(".,"))
        lo = _numero(m.group(1).strip(".,")) if m.group(1) else hi
    except ValueError:
        return None
    return lo, hi


def _cfu_gruppo(g: dict):
    """CFU di un gruppo senza attività elencate: dall'etichetta («12 CFU a scelta libera», «(6CFU)») o, se manca, dalle
    note del gruppo («deve acquisire 3 CFU», «almeno 9 CFU», «ha a disposizione 8 crediti»)."""
    c = _cfu_etichetta(g.get("label_it"))
    if c:
        return c
    for n in (g.get("nota1_it"), g.get("nota2_it")):
        m = _NOTA_CFU.search(n or "")
        if m:
            v = int(m.group(1) or m.group(2))
            if 0 < v <= 30:
                return v, v
    return None


def _nome_gruppo(label: str) -> str:
    """Nome della voce a scelta di un gruppo «S» senza attività elencate (nel catalogo: «Insegnamenti a scelta su tutti i corsi
    della stessa tipologia e normativa del corso corrente»): l'etichetta è solo anno, percorso e CFU, quindi il nome è uno solo,
    con l'intervallo dei CFU se non è fisso («fra 1 e 12 CFU»)."""
    cfu = _cfu_etichetta(label or "")
    base = "Insegnamenti a scelta libera"
    if re.search(r"(?i)opzionabil", label or ""):
        base += " (opzionabile)"  # «OPZIONABILE 2° ANNO Scelta Libera 12 cfu»
    if cfu and cfu[0] != cfu[1]:
        return f"{base} (fra {cfu[0]:g} e {cfu[1]:g} CFU)"
    return base


def _e_frequenza(att: dict) -> bool:
    return not att.get("crediti") and bool(_FREQUENZA.search((att.get("des_it") or "").strip()))


def _chiave_percorso(nome: str) -> str:
    n = re.sub(r"(?i)\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", " ", nome)
    n = re.sub(r"(?i)\b(?:percorso|curriculum|indirizzo|piano)\b", " ", n)
    return _norm(n)


def _nome_percorso(nome: str) -> str:
    nome = re.sub(r"\s*,\s*", " - ", nome)  # (build_db separa i percorsi con la virgola)
    n = re.sub(r"(?i)[\s,-]*\bcoorte\s*\d{4}(?:[/-]\d{2,4})?", "", nome)
    m = re.match(r"(?i)\s*schema automatico per il pds\s*:\s*(\S+?)(?:/\d{2,4})?\s*$", n)
    if m:  # percorsi senza nome nelle coorti vecchie: resta il codice («L19-AG»)
        n = m.group(1)
    n = re.sub(r"(?i)^\s*(?:piano di studi?|schema (?:di )?piano)\s*[_:-]*\s*", "", n)  # «Piano di studi _arredo» → «arredo»
    n = re.sub(r"\s+", " ", n).strip(" -:,_")
    m = re.match(r"(?i)percorso da (\d+) cfu\s*-\s*allegato (\d+)$", n)
    if m:  # percorsi FI: «PERCORSO DA 30 CFU - ALLEGATO 4», «Percorso da 30 cfu - allegato 4»
        return f"Percorso da {m.group(1)} CFU - Allegato {m.group(2)}"
    if n.isupper():
        n = _maiuscole(n)
    return n[:1].upper() + n[1:]


_PICCOLE = {"e", "di", "del", "della", "dei", "delle", "degli", "per", "in", "con", "da", "a", "al", "alla", "il", "la", "lo", "le",
            "gli", "i", "ed", "nel", "nella", "sul", "tra", "and", "of", "the", "for", "to", "on", "with", "at", "by", "from", "an",
            "or", "its", "as"}


def _maiuscole(des: str) -> str:
    """Nomi in maiuscolo → iniziale maiuscola per parola; sigle (fino a 3 lettere, con cifre o con trattino), numeri romani e lettere
    singole dopo «modulo»/«parte» restano maiuscole, articoli e preposizioni (anche inglesi) in minuscolo."""
    out = []
    prec = ""
    for i, w in enumerate(re.sub(r"\s+", " ", des).strip().split()):
        base = w.strip("()'\",.;:")
        low = base.lower()
        if not w.isupper() and not w.islower():
            out.append(w)
        elif re.fullmatch(r"[IVX]+", base) or re.search(r"\d", base) or (len(base) <= 3 and low not in _PICCOLE)                 or ("-" in base and len(base) <= 6) or (len(base) == 1 and prec in ("modulo", "parte", "mod", "gruppo")):
            out.append(w.upper())
        elif i and low in _PICCOLE:
            out.append(w.lower())
        else:
            k = next((j for j, ch in enumerate(w) if ch.isalpha()), 0)
            out.append(w[:k] + w[k].upper() + w[k + 1:].lower())
        prec = low
    return " ".join(out)


def _titolo(des: str) -> str:
    """Titolo di un insegnamento o di un corso: i nomi tutti in maiuscolo diventano «Parole Con L'iniziale» (con le preposizioni
    anche inglesi in minuscolo); gli altri restano come sono."""
    des = re.sub(r"\s+", " ", des or "").strip()
    return _maiuscole(des) if des.isupper() else des


def _num_codice(cod: str | None) -> int:
    m = re.search(r"(\d+)\s*$", (cod or "").strip())
    return int(m.group(1)) if m else 0


def _num_codice_p(p: dict) -> int:
    return _num_codice(p.get("pdsCod"))


def _stem_percorso(cod: str | None) -> str:
    """Codice del percorso senza l'anno e la «R» del riordino: «L28-BF/24», «L28-BF/26» → «L28-BF»; «L11-24-ESI», «L11R-26ESI» → «L11-ESI»."""
    c = re.sub(r"(?<=\d)R(?=-)", "", (cod or "").strip())
    c = re.sub(r"[-_/]?(?<!\d)2[0-7](?!\d)", "-", c)
    return re.sub(r"-+", "-", c).strip("-_/")


def _adcod_percorso(p: dict) -> set:
    return {t.get("adCod") for a in p.get("anni") or [] if str(a.get("anno")).isdigit()
            for g in a.get("insegnamenti") or [] for t in g.get("attivita") or [] if t.get("adCod")}


_GENERICHE = re.compile(r"(?i)\b(?:coorte|percorso|schema|indirizzo|piano|uni|unico|comune)\b")
_CODICE_DAVANTI = re.compile(r"(?i)^\s*(?:\d{4}_\d\d_\d\d_)?A\d{2,4}(?![\dA-Za-z])[_ ]*(?:20\d\d)?[_ -]*")


def _etichette_percorsi(percorsi: list[dict]) -> list[str]:
    """Nome di ogni percorso di una coorte, unico tra i suoi. Il catalogo dà ai percorsi di molti corsi solo un codice
    («R122-25-25» per tre percorsi diversi, «COORTE 2025», «0125_18_20_A36»): senza un nome vero resta il codice del
    percorso («Percorso A125»); un codice davanti al nome («A164_2026 SICUREZZA») si toglie."""
    nomi = []
    for p in percorsi:
        cod = (p.get("pdsCod") or "").strip()
        m = _CODICE_DAVANTI.sub("", (p.get("des_it") or p.get("pdsDes") or "").strip()).strip()
        if _COMUNE.search(m):
            nomi.append(m)
            continue
        if not re.search(r"[A-Za-z]{4,}", _GENERICHE.sub(" ", m)):
            m = (f"Percorso {cod}" + (f" {m}" if re.fullmatch(r"(?i)LM[- ]?\d+", m) else "")) if cod and cod != "UNI" else (m or "Percorso unico")
        nomi.append(m)
    visti: dict[str, int] = {}
    for n in nomi:
        visti[n] = visti.get(n, 0) + 1
    ris = [n if visti[n] == 1 else f"{n} ({(p.get('pdsCod') or '').strip()})" for n, p in zip(nomi, percorsi)]
    visti = {}
    for n in ris:
        visti[n] = visti.get(n, 0) + 1
    return [n if visti[n] == 1 else f"{n} ({(p.get('des_it') or '').strip()})" for n, p in zip(ris, percorsi)]


def _con_etichette(det: dict) -> dict:
    ps = det.get("percorsi") or []
    return dict(det, percorsi=[dict(p, des_it=e) for p, e in zip(ps, _etichette_percorsi(ps))])


def _gruppi_di_anno(a: dict) -> list[dict]:
    gruppi = a.get("insegnamenti") or ([{"label_it": "", "cod": "OO", "attivita": a["attivita"]}] if a.get("attivita") else [])
    # la regola «S» (scelta libera, senza elenco) con lo stesso intervallo «fra X e Y CFU» di un gruppo «W»/«F» con l'elenco delle
    # attività è la stessa scelta scritta due volte (il paniere del 1° anno e la scelta libera «fra 1 e 12 CFU»): una volta sola.
    # Con CFU fissi (un blocco da 6 CFU a scelta tra due insegnamenti e 6 CFU liberi) sono due scelte diverse.
    con_elenco = {c for g in gruppi if g.get("attivita") for c in [_cfu_etichetta(g.get("label_it"))] if c and c[0] != c[1]}
    return [g for g in gruppi if not _SOVRANNUMERARIO.search(g.get("label_it") or "")
            and (g.get("attivita") or _cfu_gruppo(g) not in con_elenco)]


def _obbligatorio(g: dict, att: dict, atts: list[dict]) -> bool:
    """Un'attività del piano è obbligatoria se sta nel gruppo «OO», se il gruppo la richiede per intero, se il gruppo è di
    insegnamenti obbligatori e l'attività ha il tipo «OBB», o se è l'unica del gruppo (senza una scelta nell'etichetta)."""
    label = (g.get("label_it") or "")
    if g.get("cod") == "OO":
        return True
    cfu = _cfu_etichetta(label)
    tot = sum(float(a.get("crediti") or 0) for a in atts)
    if cfu and cfu[0] == cfu[1] and tot > 0 and abs(tot - cfu[0]) < 1e-6 and not _ALTERNATIVA.search(label):
        return True
    if re.search(r"(?i)obbligator", label) and att.get("tipo_ins_cod") == "OBB" and not re.search(r"(?i)\bper chi\b", label):
        return True
    # gruppo a CFU fissi con attività obbligatorie e scelte («Tirocinio + Prova finale (20 CFU)»: prova finale obbligatoria,
    # tirocinio di 7 o 8 CFU a scelta): le obbligatorie, se stanno nei CFU del gruppo, lo sono
    if cfu and cfu[0] == cfu[1] and att.get("tipo_ins_cod") == "OBB" and len(atts) > 1:
        obb = [a for a in atts if a.get("tipo_ins_cod") == "OBB"]
        if len(obb) < len(atts) and sum(float(a.get("crediti") or 0) for a in obb) <= cfu[0] + 1e-6:
            return True
    if len(atts) == 1 and not _SCELTA.search(label) and not _CONDIZIONATO.search(label):
        return True  # unica attività del gruppo e nessuna scelta nell'etichetta (Poliba non valorizza il tipo «OBB»)
    return len(atts) == 1 and att.get("tipo_ins_cod") == "OBB" and not _CONDIZIONATO.search(label)


_NUMERI = {"due": 2, "tre": 3, "quattro": 4, "cinque": 5, "2": 2, "3": 3, "4": 4, "5": 5}


def _molteplicita(label: str | None) -> int:
    """Quante scelte chiede un gruppo senza CFU nell'etichetta: «Due scelte tra», «Tre insegnamenti a scelta» → 2, 3."""
    m = re.search(r"(?i)\b(due|tre|quattro|cinque|[2-5])\s+(?:scelt\w+|esam\w+|insegname\w+|corsi|attivit\w+|lingue|discipline|materie)", label or "")
    return _NUMERI.get(m.group(1).lower(), 1) if m else 1


_UNO_E_DUE = re.compile(r"(?i)\b1\s*°?\s*e\s*2\s*°?\s*anno")  # «PANIERE 1 e 2° ANNO», «1° e 2° ANNO - COMUNE»


def _espandi_anni(det: dict) -> dict:
    """Gruppi a scelta messi nell'anno sbagliato dal catalogo:
    - i gruppi del 2° anno che l'etichetta dice di «1° e 2° anno» valgono anche per il 1° (una scelta offerta in più anni compare
      in ognuno);
    - i gruppi dell'anno 0 («A 0 [F: 2° ANNO A SCELTA (6 CFU)]» di Costruzioni e gestione ambientale) vanno nell'anno che l'etichetta
      dice («2° ANNO»)."""
    percorsi = []
    for p in det.get("percorsi") or []:
        anni = [dict(a, insegnamenti=list(a.get("insegnamenti") or [])) if a.get("insegnamenti") is not None else dict(a)
                for a in p.get("anni") or []]
        per_anno = {str(a.get("anno")): a for a in anni}
        extra = [g for a in anni if str(a.get("anno")) == "2" for g in a.get("insegnamenti") or []
                 if _UNO_E_DUE.search(g.get("label_it") or "")]
        if extra and "1" in per_anno:
            per_anno["1"]["insegnamenti"] += extra
        zero = per_anno.get("0")
        if zero and zero.get("insegnamenti"):
            tenuti = []
            for g in zero["insegnamenti"]:
                m = re.match(r"\s*(\d)\s*°?\s*anno\b", g.get("label_it") or "", re.I)
                dest = per_anno.get(m.group(1)) if m else None
                if dest is not None and g.get("cod") != "OO":
                    dest["insegnamenti"].append(g)
                else:
                    tenuti.append(g)
            zero["insegnamenti"] = tenuti
        percorsi.append(dict(p, anni=anni))
    return dict(det, percorsi=percorsi)


def _vale(a: dict, k: int, durata: int | None) -> bool:
    """L'anno `a` del piano vale per l'anno di corso k; le attività senza anno (anno 0: scelte libere, altre attività) si
    collocano nell'ultimo anno, come le «altreAttivita» del catalogo comune."""
    if not str(a.get("anno")).isdigit():
        return False
    n = int(a["anno"])
    return n == k or (n == 0 and durata is not None and k == durata)


def _sommario_anno(det: dict, k: int, durata: int | None = None) -> dict:
    """CFU «dichiarati» dall'anno k di un piano, percorso per percorso:
    {percorso: {"obb": CFU obbligatori, "fissi": CFU di gruppi a scelta con CFU fissi o con una sola scelta,
                "intervalli": [(min, max)] dei gruppi con intervallo}}."""
    out = {}
    for p in det.get("percorsi") or []:
        obb, fissi, interv, etich, alt, incerte, visti = 0.0, 0.0, [], [], [], [], set()
        trovato = False
        for a in p.get("anni") or []:
            if not _vale(a, k, durata):
                continue
            trovato = True
            for g in _gruppi_di_anno(a):
                atts = [x for x in g.get("attivita") or [] if not _e_frequenza(x)]
                if not atts and re.search(r"(?i)opzionabil", g.get("label_it") or ""):
                    continue  # scelta libera «opzionabile»: un'alternativa ad altri crediti dell'anno, non crediti in più
                cfu_g = _cfu_etichetta(g.get("label_it")) or (None if atts else _cfu_gruppo(g))
                oblig = [x for x in atts if _obbligatorio(g, x, atts)]
                for x in oblig:
                    ad = x.get("adCod") or x.get("cod")
                    if ad not in visti:
                        visti.add(ad)
                        obb += float(x.get("crediti") or 0)
                if len(oblig) == len(atts) and atts:
                    continue
                if not oblig and re.search(r"(?i)\bper chi\b", g.get("label_it") or ""):
                    continue  # «Insegnamento obbligatorio per chi non l'ha sostenuto…»: vale solo per alcuni studenti
                if cfu_g and cfu_g[0] == cfu_g[1] and _ALTERNATIVA.search(g.get("label_it") or ""):
                    alt.append(cfu_g[0])  # «Tirocinio OPZ 1 (12 CFU)» / «OPZ 2»: una delle opzioni
                elif cfu_g and cfu_g[0] == cfu_g[1]:
                    fissi += cfu_g[0] - (0 if not oblig else sum(float(x.get("crediti") or 0) for x in oblig))
                elif cfu_g:
                    interv.append(cfu_g)
                    etich.append(re.sub(r"\s+", " ", g.get("label_it") or ""))
                elif atts:
                    cf = {float(x.get("crediti") or 0) for x in atts if x.get("crediti")}
                    if cf:
                        fissi += max(cf) * min(_molteplicita(g.get("label_it")), len(atts))
                    etichetta = re.sub(r"\d+\s*°", " ", g.get("label_it") or "")  # «1° anno»: l'anno, non il numero di scelte
                    plurale = re.search(r"(?i)\b(?:scelte|insegnamenti|esami|corsi|lingue|letterature|attivit\w+)\b", etichetta)
                    numero = re.search(r"(?i)\b(?:un|una|uno|1|due|tre|quattro|cinque|[2-5])\b", etichetta)
                    if len(atts) > 1 and plurale and not numero:
                        incerte.append(re.sub(r"\s+", " ", g.get("label_it") or ""))  # quante scelte non è scritto
        if trovato:
            fissi += max(alt, default=0.0)
            out[p.get("des_it") or p.get("pdsDes") or ""] = {"obb": obb, "fissi": fissi, "intervalli": interv, "etichette": etich, "incerte": incerte}
    return out


def _cfu_anno(det: dict, k: int, durata: int | None = None) -> float:
    """CFU dichiarati dall'anno k (percorso più ricco: obbligatori e scelte con CFU fissi, più il minimo degli intervalli)."""
    s = _sommario_anno(det, k, durata)
    if not s:
        return -1.0
    return max(v["obb"] + v["fissi"] + sum(lo for lo, _ in v["intervalli"]) for v in s.values())


def _n_piano(det: dict | None) -> int:
    """Attività negli anni numerati del piano (gli «altreAttivita» sono l'elenco degli insegnamenti erogati, non il piano)."""
    return sum(len(g.get("attivita") or []) + (1 if not g.get("attivita") and g.get("label_it") else 0)
               for p in (det or {}).get("percorsi") or [] for a in p.get("anni") or [] if str(a.get("anno")).isdigit()
               for g in a.get("insegnamenti") or [])


def _fetch_piani(uid: str, anno: int, max_cds: int | None, syllabus: bool, log, client=None, libri_noti=None) -> dict:
    base = BASE
    c = client or ClientCache(BASE)
    libri_noti = libri_noti or {}
    coorti: dict[int, list[dict]] = {}
    for y in range(anno - 6, anno + 1):
        cds: list[dict] = []
        cc._walk_cds(c.get("/corsi", {"anno": y, "minimal": "true"}) or [], cds)
        coorti[y] = [x for x in cds if str(x.get("aa")) == str(y) and x.get("tipo_corso_cod") in TIPI]
    universitaly = _ids_universitaly()
    dettagli: dict[tuple[int, str], dict | None] = {}

    def dettaglio(y: int, x: dict) -> dict | None:
        k = (y, x["cod"])
        if k not in dettagli:
            dettagli[k] = _un(c.get(f"/corso/{y}/{x['cod']}"))
        return dettagli[k]

    def trova(y: int, cur: dict) -> dict | None:
        """Riga dell'elenco della coorte y che è lo stesso corso di `cur`."""
        elenco = coorti.get(y, [])
        # stesso codice (la «R» del riordino vale «0»): nelle coorti 2025/2026 il codice vecchio resta come guscio senza anni
        # accanto a quello nuovo, si prende quello con il piano
        stessi = [x for x in elenco if _cod_base(x["cdsCod"]) == _cod_base(cur["cdsCod"])]
        if stessi:
            return max(stessi, key=lambda x: (_n_piano(dettaglio(y, x)), x["cdsCod"] == cur["cdsCod"]))
        chiave = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [x for x in elenco if (_norm(x.get("des_it")), x.get("sede_cod"), x.get("tipo_corso_cod")) == chiave]
        if len(stessi) == 1:
            return stessi[0]
        return None  # niente confronto per solo nome e tipo: i corsi omonimi di sedi diverse (Scienze motorie, Giurisprudenza) sono corsi diversi

    # corsi attuali: i codici (con la «R» valendo «0») dell'elenco della coorte in corso e della precedente (Informatica
    # applicata c'è solo nella 2025), con la riga che ha il piano più ricco
    famiglie: dict[str, dict] = {}
    for y in (anno - 1, anno):
        for x in coorti.get(y, []):
            b = _cod_base(x["cdsCod"])
            if b not in famiglie or _n_piano(dettaglio(y, x)) >= _n_piano(dettaglio(int(famiglie[b]["aa"]), famiglie[b])):
                famiglie[b] = x
    attuali = [x for x in famiglie.values()
               if any(_n_piano(dettaglio(y, z)) for y in range(anno - 6, anno + 1) for z in [trova(y, x)] if z)]
    attuali.sort(key=lambda x: x["cdsCod"])
    if max_cds:
        attuali = attuali[:max_cds]
    log(f"[{uid}] {len(attuali)} corsi di studio con un piano")

    corsi_out = []
    syllabus_jobs: dict[tuple[str, str], dict] = {}
    oggi = time.strftime("%Y-%m-%d")

    def build_cds(cur: dict) -> list[dict]:
        """Il corso del catalogo come corso del database (con l'id Universitaly dove i corsi omonimi sono più d'uno)."""
        r = _build(cur, universitaly.get(_cod_base(cur.get("cdsCod"))))
        return [r] if r else []

    def _build(cur: dict, id_univ: str | None) -> dict | None:
        cohorts: dict[int, tuple[dict, dict]] = {}
        for y in range(anno - 6, anno + 1):
            x = trova(y, cur)
            d = dettaglio(y, x) if x else None
            if d:
                d = _con_etichette(_espandi_anni(d))
            if d:
                cohorts[y] = (x, d)
        if not cohorts:
            return None
        rec = cohorts.get(anno) or cohorts[max(cohorts)]
        durata = _durata(rec[1], cur.get("tipo_corso_cod"))
        amm = None
        if anno in cohorts:  # requisiti di accesso della coorte che si iscrive ora
            amm = ammissione.da_catalogo(cohorts[anno][1], f"{base}/corsi/{anno}/{cohorts[anno][0].get('cod')}")

        # nome canonico dei percorsi: quello della coorte più recente che li ha. Il confronto è con i percorsi delle
        # coorti già viste (mai con quelli della stessa coorte: «… 1» e «… 2» sono percorsi diversi)
        canon: dict[tuple[int, str], str] = {}
        riferimento: list[tuple] = []  # (chiave, codice, nome canonico, codici delle attività, comune)
        for y in sorted(cohorts, reverse=True):
            det = cohorts[y][1]
            ps = det.get("percorsi") or []
            cods = [p.get("pdsCod") or "" for p in ps]
            visti = list(riferimento)
            nuovi = []
            trovati: dict[str, tuple | None] = {}
            for p in ps:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                ch = _chiave_percorso(pn)
                cod = (p.get("pdsCod") or "").strip()
                num = re.search(r"\d+", ch)
                trovato = next((r for r in visti if r[0] == ch), None)
                if not trovato and cod and cods.count(cod) == 1:
                    cand = [r for r in visti if r[1] == cod and cod not in ("PDS0", "GEN", "COMUNE")]
                    trovato = cand[0] if len(cand) == 1 else None
                st = _stem_percorso(cod)
                if not trovato and st and not st.startswith("PDS0") and [_stem_percorso(c_) for c_ in cods].count(st) == 1:
                    cand = [r for r in visti if _stem_percorso(r[1]) == st]
                    trovato = cand[0] if len(cand) == 1 else None
                if not trovato:  # nome cambiato di poco («Percorso Rigenerazione urbana» → «Percorso Rigenerazione»)
                    num_r = {r[0]: (re.search(r"\d+", r[0]) or [None])[0] for r in visti}
                    stessi = [r[0] for r in visti if (num_r[r[0]] == (num[0] if num else None))
                              and (len(min(ch, r[0], key=len)) >= 6 and (r[0].startswith(ch) or ch.startswith(r[0])))]
                    simili = difflib.get_close_matches(ch, [r[0] for r in visti if num_r[r[0]] == (num[0] if num else None)],
                                                       n=1, cutoff=0.8)
                    scelto = (stessi or simili or [None])[0]
                    trovato = next((r for r in visti if r[0] == scelto), None) if scelto else None
                if not trovato and not _COMUNE.search(pn) and not p.get("comune"):
                    # percorso con un altro nome/codice (riordino): il più simile per insegnamenti in comune
                    mio = _adcod_percorso(p)
                    usati = {t[2] for t in trovati.values() if t}
                    migliori = sorted(((len(mio & r[3]) / max(1, len(mio | r[3])), r) for r in visti
                                       if r[3] and r[2] not in usati and not r[4]), key=lambda t: -t[0])
                    if mio and migliori and migliori[0][0] >= 0.4 and (len(migliori) == 1 or migliori[0][0] - migliori[1][0] >= 0.1):
                        trovato = migliori[0][1]
                trovati[pn] = trovato
            # percorsi non riconosciuti: se restano tanti percorsi del riferimento quanti sono questi, lo stesso rango del codice
            # (le coorti più recenti hanno spesso solo il 1° anno e i percorsi differiscono negli anni dopo: gli insegnamenti in
            # comune non bastano). Dedotto dall'ordine dei codici, non scritto nel catalogo.
            specifici_p = [p for p in ps if not p.get("comune") and not _COMUNE.search(p.get("des_it") or "")]
            senza = sorted((p for p in specifici_p if trovati.get((p.get("des_it") or p.get("pdsDes") or "").strip()) is None),
                           key=_num_codice_p)
            usati = {t[2] for t in trovati.values() if t}
            liberi = sorted((r for r in visti if not r[4] and r[2] not in usati), key=lambda r: _num_codice(r[1]))
            if senza and len(senza) == len(liberi) and len(specifici_p) == len([r for r in visti if not r[4]]):
                for p, r in zip(senza, liberi):
                    trovati[(p.get("des_it") or p.get("pdsDes") or "").strip()] = r
            for p in ps:
                pn = (p.get("des_it") or p.get("pdsDes") or "").strip()
                trovato = trovati.get(pn)
                if not trovato:
                    trovato = (_chiave_percorso(pn), (p.get("pdsCod") or "").strip(), _nome_percorso(pn), _adcod_percorso(p),
                               bool(p.get("comune")) or bool(_COMUNE.search(pn)))
                    nuovi.append(trovato)
                canon[(y, pn)] = trovato[2]
            riferimento.extend(nuovi)

        def coorte_anno(k: int) -> int | None:
            y0 = anno - k + 1
            forzata = COORTE_ANNO.get((cur.get("cdsCod"), k))
            if forzata in cohorts:
                return forzata
            ha = {y: _cfu_anno(d, k, durata) for y, (_, d) in cohorts.items()}
            # un anno con meno di 30 CFU dichiarati è un piano non ancora pubblicato (nel 2024 il 3° anno di «Creatività digitale»
            # ha solo i 12 CFU liberi): si usa la coorte più vicina che lo ha
            completi = {y: v for y, v in ha.items() if v >= 30}
            ha = completi or {y: v for y, v in ha.items() if v > 0}
            if not ha:
                return None
            if y0 in ha:
                return y0
            return min(ha, key=lambda y: (abs(y - y0), -y))

        # stessa attività offerta in altre coorti/anni accademici: schede alternative per i libri
        alt_per_ad: dict[str, dict] = {}
        for y, (_, d) in cohorts.items():
            for p in d.get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            alt_per_ad.setdefault(att.get("adCod") or att.get("cod"), {})[
                                (str(att.get("aa")), str(att.get("cod")))] = (y, att)
        # CFU di un'attività con 0 CFU in un piano e CFU nell'altro
        cfu_noti: dict[str, float] = {}
        for y in sorted(cohorts):
            for p in cohorts[y][1].get("percorsi") or []:
                for a in p.get("anni") or []:
                    for g in _gruppi_di_anno(a):
                        for att in g.get("attivita") or []:
                            if isinstance(att.get("crediti"), (int, float)) and att["crediti"] > 0:
                                cfu_noti[att.get("adCod") or att.get("cod")] = att["crediti"]

        insegnamenti: dict[str, dict] = {}
        percorsi_nomi: set[str] = set()
        debiti: list[str] = []
        piano_anni: dict[str, dict] = {}
        for k in range(1, durata + 1):
            scelta = coorte_anno(k)
            if scelta is None:
                continue
            x, d = cohorts[scelta]
            sommario = _sommario_anno(d, k, durata)
            piano_anni[str(k)] = {"coorte": scelta, "url": f"{base}/corsi/{scelta}/{x['cod']}", "sommario": sommario}
            percorsi_k = [p for p in d.get("percorsi") or []
                          if any(_vale(a, k, durata) for a in p.get("anni") or [])]
            nomi_k = {(p.get("des_it") or p.get("pdsDes") or "").strip(): p for p in percorsi_k}
            anni_p = {n: max(int(a["anno"]) for a in p.get("anni") or [] if str(a.get("anno")).isdigit())
                      for n, p in nomi_k.items()}
            # percorsi comuni: «… comune» o un piano che copre solo i primi anni quando gli altri percorsi li coprono tutti
            # (il campo «comune» del catalogo è «schema automatico del piano» anche per due percorsi diversi, come i piani «arredo» e
            # «prodotto» di Disegno industriale: vale solo se è l'unico percorso dell'anno)
            comuni = {n for n in nomi_k if _COMUNE.search(n)
                      or (nomi_k[n].get("comune") and (len(nomi_k) == 1 or any(not q.get("comune") for q in nomi_k.values())))
                      or (len(nomi_k) > 1 and anni_p[n] < max(anni_p.values()))}
            specifici = [n for n in nomi_k if n not in comuni]
            curricula = {canon[(scelta, n)] for n in specifici} if len(specifici) >= 2 else set()
            for pnome, p in nomi_k.items():
                comune = pnome in comuni or not curricula
                pcur = None if comune else canon[(scelta, pnome)]
                s_visti: dict[tuple, int] = {}
                for a in p.get("anni") or []:
                    if not _vale(a, k, durata):
                        continue
                    for g in _gruppi_di_anno(a):
                        atts = [t for t in g.get("attivita") or [] if not _e_frequenza(t)]
                        label = g.get("label_it") or ""
                        if not atts:  # gruppo senza attività elencate: i CFU sono nell'etichetta
                            cfu_g = _cfu_gruppo(g)
                            nome = _nome_gruppo(label)
                            if not cfu_g or len(nome) < 3:
                                continue
                            # più gruppi uguali nello stesso percorso (due gruppi «A SCELTA LIBERA (6 CFU)»): uno ciascuno
                            idx = s_visti[(nome, cfu_g[1])] = s_visti.get((nome, cfu_g[1]), -1) + 1
                            key = f"{k}:#{_norm(nome)}:{cfu_g[1]:g}:{idx}"
                            item = insegnamenti.get(key)
                            if not item:
                                item = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu_g[1], "_idx": idx,
                                        "ssd": None, "obbligatorio": False, "curriculum": None, "_percorsi": set(),
                                        "_tutti": curricula, "docenti": [], "url": f"{base}/corsi/{scelta}/{x['cod']}",
                                        "libri": [], "esami": [], "fonte": base, "verificato_il": oggi, "_senza_codice": True}
                                insegnamenti[key] = item
                            if pcur:  # (i gruppi dei percorsi comuni valgono per tutti i curricula)
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
                            continue
                        for att in atts:
                            ad = att.get("adCod") or att.get("cod")
                            if _DEBITO.search(att.get("des_it") or "") and not att.get("crediti"):
                                nome_d = re.sub(r"(?i)^\s*debito\s+", "", _titolo(att["des_it"])).strip()
                                debiti.append(nome_d)
                                continue
                            obbl = _obbligatorio(g, att, atts)
                            # obbligatoria in un percorso e a scelta in un altro: due righe, con curricula disgiunti
                            cfu_att = att.get("crediti") or cfu_noti.get(ad)
                            key = f"{k}:{ad}:{cfu_att:g}:{'o' if obbl else 's'}" if isinstance(cfu_att, (int, float))                                 else f"{k}:{ad}::{'o' if obbl else 's'}"
                            item = insegnamenti.get(key)
                            if not item:
                                docenti = [cc._nome(t.get("des")) for t in att.get("docenti") or [] if t.get("des")]
                                item = {
                                    "codice": ad, "nome": _titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": cfu_att, "ssd": None,
                                    "obbligatorio": bool(obbl), "curriculum": None, "_percorsi": set(), "_tutti": curricula,
                                    "docenti": sorted(set(docenti)),
                                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={scelta}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                }
                                insegnamenti[key] = item
                                if syllabus:
                                    syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                                   "af_percorso": att.get("corso_percorso_id"),
                                                   "corso_cod": att.get("corso_cod"), "corso_aa": scelta,
                                                   "schema_id": att.get("schemaId")},
                                        "items": [], "codice": ad,
                                        "alt": [(t, y_) for (_a, _c), (y_, t) in sorted(
                                            alt_per_ad.get(ad, {}).items(), key=lambda kv: kv[0][0], reverse=True)
                                            if (str(t.get("aa")), str(t.get("cod"))) != (str(att.get("aa")), str(att.get("cod")))],
                                    })["items"].append(item)
                            if pcur:
                                item["_percorsi"].add(pcur)
                                percorsi_nomi.add(pcur)
        # una stessa attività obbligatoria e a scelta nello stesso percorso è obbligatoria; la riga a scelta resta solo
        # per i percorsi dove è soltanto a scelta
        def _percorsi_riga(i: dict) -> set:
            return {None} if not i["_tutti"] else (set(i["_percorsi"]) or set(i["_tutti"]))

        for key in [k_ for k_ in insegnamenti if k_.endswith(":s")]:
            ob = insegnamenti.get(key[:-1] + "o")
            if not ob:
                continue
            sc = insegnamenti[key]
            resto = _percorsi_riga(sc) - _percorsi_riga(ob)
            if not resto:
                del insegnamenti[key]
            else:
                sc["_percorsi"] = resto - {None}
        for (cds_c, anno_c), regole in CORREZIONI.items():
            if cds_c != cur.get("cdsCod"):
                continue
            for key, item in list(insegnamenti.items()):
                regola = regole.get(item.get("codice") or item["nome"]) if item["anno"] == anno_c else None
                if regola == "escludi":
                    del insegnamenti[key]
                elif regola == "scelta":
                    item["obbligatorio"] = False
                elif regola and regola.startswith("cfu="):
                    item["cfu"] = int(regola[4:])
        # attività a 0 CFU nel piano (OFA, sicurezza, prove di verifica): non sono insegnamenti del piano
        for key, item in list(insegnamenti.items()):
            if not item.get("cfu"):
                del insegnamenti[key]
        ins = list(insegnamenti.values())
        molt: dict[tuple, int] = {}
        for i in ins:
            if "_idx" in i:
                molt[(i["anno"], i["nome"], i["cfu"])] = max(molt.get((i["anno"], i["nome"], i["cfu"]), 0), i["_idx"] + 1)
        for i in ins:
            idx = i.pop("_idx", None)
            if idx is not None and molt[(i["anno"], i["nome"], i["cfu"])] > 1:
                i["nome"] = f"{i['nome']} ({idx + 1} di {molt[(i['anno'], i['nome'], i['cfu'])]})"
        for i in ins:
            ps, tutti = i.pop("_percorsi"), i.pop("_tutti")
            if ps and ps != tutti:
                i["curriculum"] = ", ".join(sorted(ps))
        # stesso codice con CFU diversi nei curricula (es. «Marketing» da 6 CFU in un curriculum e da 9 in un altro): un
        # insegnamento per ogni valore; la variante principale (più curricula) ha l'id del codice, le altre un id proprio
        # `<corso>-<codice>-<CFU>cfu` (altrimenti build_db le fonderebbe in una sola con i CFU del primo)
        per_codice: dict[tuple, list[dict]] = {}
        for i in ins:
            if i.get("codice"):
                per_codice.setdefault((i["anno"], i["codice"]), []).append(i)
        cid = None
        for (anno_i, codice), gl in per_codice.items():
            per_cfu: dict[float, list[dict]] = {}
            for i in gl:
                per_cfu.setdefault(i["cfu"], []).append(i)
            if len(per_cfu) < 2:
                continue
            if cid is None:
                cid = _id_corso_db(cur, cc._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
                                   rec[1].get("sedeDenominazioneComune"), id_univ) or ""
            varianti = sorted(per_cfu.values(), key=lambda g: (
                -sum(len(i["curriculum"].split(", ")) if i["curriculum"] else 99 for i in g), -g[0]["cfu"]))
            for g in varianti[1:]:
                for n_, altro in enumerate(g):
                    if cid:
                        altro["id"] = f"{cid}-{_slug(codice)}-{altro['cfu']:g}cfu" + (
                            "" if not n_ else "-scelta" if altro["obbligatorio"] is False else "-obbl")
                    else:
                        ins.remove(altro)
        # stesso nome nello stesso anno con codici e CFU diversi (alternative omonime): il nome porta i CFU
        per_nome: dict[tuple, list] = {}
        for i in ins:
            per_nome.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"] if i.get("codice") else None), []).append(i)
        for gruppo_i in per_nome.values():
            if len({i["cfu"] for i in gruppo_i}) > 1 and len({(i["codice"], i["cfu"]) for i in gruppo_i}) > 1:
                for i in gruppo_i:
                    if isinstance(i["cfu"], (int, float)):
                        i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)"
        # stesso nome, anno e curriculum con codici diversi e gli stessi CFU: lo stesso insegnamento a scelta con due codici
        # si unisce; i tirocini e i laboratori in più codici restano distinti e il nome porta il semestre o il codice
        per_nome2: dict[tuple, list] = {}
        for i in ins:
            if i.get("codice"):
                per_nome2.setdefault((i["anno"], _nn(i["nome"]), i["curriculum"]), []).append(i)
        for gruppo_i in per_nome2.values():
            if len({i["codice"] for i in gruppo_i}) < 2:
                continue
            if all(not i["obbligatorio"] for i in gruppo_i) and len({i["cfu"] for i in gruppo_i}) == 1:
                tieni = min(gruppo_i, key=lambda i: str(i["codice"]))
                for altro in gruppo_i:
                    if altro is tieni:
                        continue
                    tieni["docenti"] = sorted(set(tieni["docenti"]) | set(altro["docenti"]))
                    tieni["periodo"] = tieni["periodo"] or altro["periodo"]
                    ins.remove(altro)
                continue
            periodi = [i["periodo"] for i in gruppo_i]
            for i in gruppo_i:
                if all(periodi) and len(set(periodi)) == len(periodi):
                    p = str(i["periodo"])
                    i["nome"] = f"{i['nome']} ({p}° semestre)" if p in ("1", "2") else f"{i['nome']} ({p})"
                else:
                    i["nome"] = f"{i['nome']} ({i['codice']})"
        # voci senza codice con lo stesso nome in anni diversi: il nome porta l'anno (build_db unisce per nome)
        anni_nome: dict[str, set] = {}
        for i in ins:
            if i.pop("_senza_codice", False):
                anni_nome.setdefault(_nn(i["nome"]), set()).add(i["anno"])
                i["_nk"] = _nn(i["nome"])
        for i in ins:
            nk = i.pop("_nk", None)
            if nk and len(anni_nome[nk]) > 1:
                i["nome"] = f"{i['nome']} ({i['anno']}° anno)"
        if amm is not None and debiti:
            nomi = [t for t in dict.fromkeys(debiti) if t]
            frase = "Debiti formativi (OFA) previsti dal piano di studi" + (": " + ", ".join(nomi) if nomi else "")
            if frase.lower() not in (amm.get("requisiti") or "").lower():
                amm["requisiti"] = ((amm.get("requisiti") or "").rstrip() + "\n" + frase + ".").strip()
            if amm.get("ofa") is None:
                amm["ofa"] = True
        sede_cur = rec[1].get("sedeDenominazioneComune") or cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None
        out = {
            "nome": _titolo(rec[1].get("des_it") or cur.get("des_it") or ""),
            "classe": cc._classe(cur.get("classe_cod") or rec[1].get("classe_cod")),
            "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": sede_cur,
            "codice_ateneo": rec[1].get("cdsCod") or cur.get("cdsCod"),
            "url": f"{base}/corsi/{rec[0].get('aa')}/{rec[0].get('cod')}",
            "curricula": sorted({n for i in ins for n in (i["curriculum"] or "").split(", ") if n}) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }
        if id_univ:
            out["id_universitaly"] = id_univ
        return out

    def build_safe(cur: dict) -> list[dict]:
        try:
            return build_cds(cur)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            log(f"[{uid}]   corso {cur.get('cdsCod')} saltato: {e!r}")
            return []

    with cf.ThreadPoolExecutor(4) as ex:
        for rs in ex.map(build_safe, attuali):
            for r in rs:
                if r["insegnamenti"]:
                    corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        noto = libri_noti.get(job.get("codice"))
        if noto and noto.get("libri"):  # libri già raccolti per questo codice: non si rileggono
            for it in job["items"]:
                it["libri"] = noto["libri"]
                it["stato_libri"] = "completo"
                for k_ in ("modalita_esame", "ssd", "url_sito"):
                    if noto.get(k_):
                        it[k_] = noto[k_]
            return len(noto["libri"])
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            sy = {}
        libri, modalita, legati = cc._testi_syllabus(sy) if sy else ([], None, [])
        if not libri and sy:  # testi in forma libera
            libri = libri_testo_libero(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cc.leganto.libri(u)
        nota = None
        if not libri:  # scheda di un'altra coorte o di un altro a.a. dello stesso insegnamento (con la fonte)
            for att, y_ in job.get("alt") or []:
                sy2 = c.get("/insegnamento", {k: v for k, v in {
                    "anno": att.get("aa"), "insegnamento": att.get("cod"), "ordinamento_aa": att.get("ordinamento_aa"),
                    "af_percorso": att.get("corso_percorso_id"), "corso_cod": att.get("corso_cod"), "corso_aa": y_,
                    "schema_id": att.get("schemaId")}.items() if v not in (None, "")})
                if not isinstance(sy2, dict):
                    continue
                l2, m2, g2 = cc._testi_syllabus(sy2)
                l2 = l2 or libri_testo_libero(sy2)
                if not l2:
                    for u in g2:
                        l2 += cc.leganto.libri(u)
                if l2:
                    aa = int(att.get("aa"))
                    url = (f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}/{att.get('ordinamento_aa')}"
                           f"/{att.get('corso_percorso_id')}?coorte={y_}")
                    nota = f"Dal programma dell'a.a. {aa}/{(aa + 1) % 100:02d} dello stesso insegnamento ({url})"
                    libri, modalita, sy = l2, modalita or m2, {**sy2, **{k: v for k, v in sy.items() if v}}
                    break
        if nota:
            libri = [{**b, "note": ((b.get("note") + " | ") if b.get("note") else "") + nota} for b in libri]
        ssd = sy.get("ssd")
        for it in job["items"]:
            it["libri"] = libri
            it["stato_libri"] = "completo" if libri else "da_aggiungere"
            if modalita:
                it["modalita_esame"] = modalita
            if ssd:
                it["ssd"] = ssd
            if sy.get("urlSitoWeb"):
                it["url_sito"] = sy["urlSitoWeb"].strip()
        return len(libri)

    trovati = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for i, n in enumerate(ex.map(do_syllabus, syllabus_jobs.values()), 1):
            trovati += n
            if i % 500 == 0:
                log(f"[{uid}]   syllabus {i}/{len(syllabus_jobs)}")
    log(f"[{uid}] libri trovati: {trovati}; richieste: {c.requests}")
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/uniparthenope.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def _slug(s: str, maxlen: int = 40) -> str:
    """Come `build_db.slug`: l'id di un insegnamento è `<corso>-<slug del codice>`."""
    t = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip().replace(" ", "-")[:maxlen].strip("-")


def _id_corso_db(cds: dict, classe: str | None, sede: str | None, id_univ: str | None) -> str | None:
    """Id che build_db darà al corso (id Universitaly, poi nome e classe tra i corsi già in `database/corsi/uniparthenope.json`):
    serve per dare un id agli insegnamenti con lo stesso codice e CFU diversi nei curricula."""
    try:
        import build_db
        vecchi = json.loads((ROOT / "database" / "corsi" / "uniparthenope.json").read_text(encoding="utf-8"))["corsi"]
    except (ImportError, OSError, ValueError, KeyError):
        return None
    t = build_db.trova_corso(vecchi, {"nome": cc._titolo(cds.get("des_it") or ""), "classe": classe, "sede": sede,
                                      "durata_anni": None, **({"id_universitaly": id_univ} if id_univ else {})})
    return t["id"] if t else None


def _ids_universitaly() -> dict[str, str]:
    """Id Universitaly dei corsi omonimi di sedi diverse, per codice del catalogo (la «R» iniziale vale «0»)."""
    return dict(ID_UNIVERSITALY)


def _libri_database() -> dict[str, dict]:
    """Libri, modalità d'esame, SSD e sito già nel database per codice dell'insegnamento (nessuna nuova richiesta)."""
    p = ROOT / "database" / "corsi" / "uniparthenope.json"
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out: dict[str, dict] = {}
    for corso in doc.get("corsi") or []:
        for i in corso.get("insegnamenti") or []:
            cod = i.get("codice")
            if cod and i.get("libri") and cod not in out:
                out[cod] = {k: i.get(k) for k in ("libri", "modalita_esame", "ssd", "url_sito")}
    return out


def fetch_ateneo(uid: str = "uniparthenope", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    return _fetch_piani(uid, anno, max_cds, syllabus, log, client, _libri_database())


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "uniparthenope.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[uniparthenope] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
