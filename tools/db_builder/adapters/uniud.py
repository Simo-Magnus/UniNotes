"""Università degli Studi di Udine: piani di studio, syllabus e libri dal Course Catalogue Cineca.

Piani e syllabus: `https://uniud.coursecatalogue.cineca.it` (API pubblica). Rispetto all'adattatore
comune (`cineca_catalogue`) il catalogo dell'Università di Udine richiede:

- piani per coorte: il piano dell'anno k è quello della coorte (anno - k + 1), la coorte degli iscritti oggi
  al k-esimo anno; i codici dei corsi cambiano con il riordino del 2025 (867 «Economia aziendale» nuova, 704
  «Economia e commercio» vecchia): la coorte precedente si ritrova per nome, sede e tipo. Se quella coorte non
  ha l'anno (corso nuovo, corso non più attivo), la coorte più vicina che lo ha. L'url di ogni insegnamento
  riporta la coorte (`?coorte=`);
- percorsi (`pdsCod`): ogni curriculum ha più «schemi» (piano completo, «1 anno», «esami obbligatori»,
  «da sottoporre alla commissione», «riservato studenti incoming», «standard» e «statutario»). Si legge un solo
  schema per curriculum, quello completo e ufficiale; i piani con codice `…-9999` (percorso comune a tutto il
  corso) che hanno nomi diversi sono curricula distinti (Matematica LM, Ingegneria civile LM); le varianti con
  Graz o Klagenfurt (doppio titolo) sono i piani dei curricula con una mobilità: si tiene il piano del curriculum;
  il «piano comune» vale per tutti i curricula;
- gruppi del piano: «Obbligatori» (`OO`) e i gruppi da sostenere per intero (tutte le attività «OBB», senza «scelta»
  nell'etichetta o nella nota: «Primo anno obbligatori», «Obbligatorio tutti i curricola») sono obbligatori, tranne le
  attività «OPZ»; gli altri gruppi (`F` scelta vincolata, `G` scelta tra proposti, `W` elenco per l'area a scelta dello
  studente) sono a scelta; il gruppo `S` («libera scelta», senza attività elencate) dà una voce «Crediti a scelta dello
  studente (N° anno)» con i CFU scritti nell'etichetta o nella nota (non quelli di «fino a un massimo di N CFU» di
  tirocinio), nell'anno che la nota indica («12 CFU sul terzo anno», «del secondo (6 CFU) e del terzo (9 CFU)»): il
  catalogo mette questi gruppi quasi sempre al 1° anno; le attività di un gruppo `W` vanno nello stesso anno;
- attività a 0 CFU (test d'ingresso, prove di accertamento propedeutiche, esercitazioni linguistiche) non si
  riportano: il piano ha i CFU degli insegnamenti;
- stesso codice con CFU diversi nei curricula (es. «Linguistica italiana» da 13 CFU nel piano standard e da 6 negli altri):
  un insegnamento per ogni valore; la variante principale (più curricula) ha l'id del codice, le altre un id proprio
  `<corso>-<codice>-<CFU>cfu` (altrimenti build_db le fonderebbe in una sola con i CFU del primo); l'id del corso è quello che
  build_db darà (lo si legge da `database/corsi/uniud.json`);
- stesso codice obbligatorio in alcuni curricula e a scelta in altri (es. «Lingua inglese» obbligatoria nel curriculum A
  e a scelta nel B): due righe con gli stessi codice e CFU, una per i curricula dove è obbligatorio (tiene l'id del
  codice) e una per quelli dove è a scelta (build_db le dà `-scelta`), con i curricula indicati e disgiunti; se un curriculum
  non ha nome o lo stesso nome ha valori diversi, resta una riga sola (obbligatoria solo se lo è ovunque);
- omonimi nello stesso anno e curriculum (stesso nome con codici diversi: «Archeologia greca» da 6 e da 12 CFU):
  il nome porta i CFU («(12 CFU)») o il codice;
- nomi dei curricula: senza il nome del corso, «curriculum», «piano completo», refusi del catalogo corretti (REFUSI),
  senza virgole (build_db separa i percorsi con la virgola); un curriculum di una coorte precedente prende il nome del
  curriculum della coorte attuale che gli somiglia;
- `PIANO_EXTRA`: voci dei piani di studio ufficiali (PDF su uniud.it) che il catalogo non ha, con la fonte;
- `ID_CORSI`: i corsi del catalogo che vanno a un corso di Universitaly con un altro nome (Infermieristica
  Udine e Pordenone); `CORSI_SENZA_COORTE_ATTUALE`: corsi di Universitaly che il catalogo ha solo nelle coorti passate.

Con la variabile d'ambiente UN_HTTP_CACHE (una cartella) le risposte del catalogo restano su disco.
Richieste al catalogo: al massimo 6 al secondo. I libri e gli altri dati dei syllabus degli insegnamenti già nel
database (stesso codice, con libri) non si rileggono.

Esecuzione locale (scrive `database/contrib/auto/uniud.json`; appelli, periodi e testi sono nei file `uniud_*.json`):

    python tools/db_builder/adapters/uniud.py [--senza-syllabus]
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

BASE = "https://uniud.coursecatalogue.cineca.it"
ROOT = pathlib.Path(__file__).resolve().parents[3]
RATE = 6.0
TIPI_RICHIESTI = {"L2", "LM", "LM5", "LM6"}

# codice del corso nel catalogo (`cdsCod`) → id del corso del database, dove il confronto per nome e classe non basta:
# Universitaly ha «Infermieristica» e «Infermieristica REPLICA SEDE PORDENONE» (sede Udine e sede Pordenone)
ID_CORSI: dict[str, str] = {
    "771": "uniud-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf",
    "782": "uniud-l-snt1-infermieristica-abilitante-alla-professione-sanitaria-di-inf-1634365",
}

# Corsi di Universitaly che il catalogo non ha nella coorte attuale: (cdsCod, coorte dell'ultimo piano pubblicato)
# «Scienze infermieristiche e ostetriche» (LM/SNT1, cds 823): ultime coorti del catalogo 2022 e 2024
CORSI_SENZA_COORTE_ATTUALE: dict[str, int] = {"823": 2024}

# Solo per i controlli: dizionario in cui si raccolgono i gruppi del piano di ogni anno (cdsCod → anno → gruppi)
DIAGNOSTICA: dict | None = None

# Voci dei regolamenti ufficiali che il catalogo non ha: per corso (`cdsCod`) e anno di corso, righe
# (nome, CFU, obbligatoria, curriculum o None, nota con la fonte).
PIANO_EXTRA: dict[tuple[str, int], list[tuple]] = {  # (cdsCod, anno) → [(nome, CFU, obbligatoria, curriculum o None, url della fonte)]
    # crediti a scelta (libera scelta) dei piani di studio ufficiali (PDF «Piano di studio a.a. …» della coorte dell'anno) che il
    # catalogo non ha o mette in un altro anno
    ('891', 2): [
        ('Crediti a scelta dello studente (2° anno)', 9, False, None, 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea-magistrale/storia-dellarte/corso/piano-di-studio/dium-lm-storia-dellarte-3-ante.pdf/download'),
    ],
    ('884', 3): [
        ('Crediti a scelta dello studente (3° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea/filosofia-trasformazione-digitale/corso/piano-di-studio/dium-l-filosofia-digitale-3-ante.pdf/download'),
    ],
    ('837', 3): [
        ('Crediti a scelta dello studente (3° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/agraria/laurea/scienze-per-lambiente-e-la-natura/corso/piano-studio/2024-2025/download'),
        # insegnamento a scelta programmata del 3° anno della coorte 2024 (in entrambi i curricula; il catalogo l'ha solo nel 2° anno)
        ('Agroecology', 6, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/agraria/laurea/scienze-per-lambiente-e-la-natura/corso/piano-studio/2024-2025/download'),
    ],
    ('842', 2): [
        ('Crediti a scelta dello studente (2° anno)', 8, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/biotecnologie/laurea-magistrale/biotecnologie-molecolari/corso/piano-studio/2025-2026/download'),
    ],
    ('840', 2): [
        ('Crediti a scelta dello studente (2° anno)', 10, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/agraria/laurea-magistrale/scienze-e-tecnologie-agrarie/corso/piano-studio/2025-2026/download'),
    ],
    ('895', 2): [
        ('Crediti a scelta dello studente (2° anno)', 6, False, None, 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lingue-comunicazione-formazione/laurea/relazioni-pubbliche/corso/piano-studio/2025-2026/download'),
    ],
    ('858', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/ingegneria-architettura/laurea-magistrale/ingegneria-ambientale-per-la-resilienza-territoriale/corso/piano-studio/2025-2026/download'),
    ],
    ('844', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/agraria/laurea-magistrale/scienze-tecnologie-sostenibili-ambiente/corso/piano-studio/2025-2026/download'),
    ],
    ('885', 3): [
        ('Crediti a scelta dello studente (3° anno)', 12, False, 'Italianistico', 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea/lettere/corso/piano-di-studio-html/dium-l-lettere-7-ante.pdf/download'),
        ('Crediti a scelta dello studente (3° anno)', 12, False, 'Storico', 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea/lettere/corso/piano-di-studio-html/dium-l-lettere-7-ante.pdf/download'),
        ('Crediti a scelta dello studente (3° anno)', 12, False, "Letterature e Civilta' del Mondo Antico", 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea/lettere/corso/piano-di-studio-html/dium-l-lettere-7-ante.pdf/download'),
    ],
    ('853', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/ingegneria-architettura/laurea-magistrale/ingegneria-civile/corso/piano-studio/2025-2026/download'),
    ],
    ('900', 3): [
        ('Crediti a scelta dello studente (3° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea/dams/corso/piano-di-studio-html/2026-2027/download'),
    ],
    ('852', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/ingegneria-architettura/laurea-magistrale/architettura/corso/piano-studio/2025-2026/download'),
    ],
    ('898', 2): [
        ('Crediti a scelta dello studente (2° anno)', 9, False, None, 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lingue-comunicazione-formazione/laurea-magistrale/comunicazione-integrata-per-le-imprese-e-le-organizzazioni/corso/piano-studio/2025-2026/download'),
    ],
    ('856', 1): [
        ('Crediti a scelta dello studente (1° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/ingegneria-architettura/laurea-magistrale/ingegneria-meccanica/corso/piano-studio/2026-2027/download'),
    ],
    ('833', 1): [
        ('Crediti a scelta dello studente (1° anno)', 6, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/agraria/laurea-magistrale/scienza-ed-economia-del-cibo/corso/piano-studio/2026-2027/download'),
    ],
    ('833', 2): [
        ('Crediti a scelta dello studente (2° anno)', 8, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/agraria/laurea-magistrale/scienza-ed-economia-del-cibo/corso/piano-studio/2026-2027/download'),
    ],
    ('863', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/scienze-matematiche-informatiche-multimediali-fisiche/laurea-magistrale/informatica/corso/piano-studio/2025-2026/download'),
    ],
    ('886', 3): [
        ('Crediti a scelta dello studente (3° anno)', 6, False, None, 'https://www.uniud.it/it/didattica/corsi/area-umanistica-formazione/lettere-beni-culturali/laurea/scienze-tecniche-turismo/corso/piano-studio/dium-l-turismo-3-ante.pdf/download'),
    ],
    ('864', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/scienze-matematiche-informatiche-multimediali-fisiche/laurea-magistrale/artificial-intelligence-cybersecurity/corso/piano-studio/2025-2026/download'),
    ],
    ('865', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, 'Artificial Intelligence - Industrial Automation and IoT (Nazionale)', 'https://www.uniud.it/it/didattica/corsi/area-scientifica/scienze-matematiche-informatiche-multimediali-fisiche/laurea-magistrale/comunicazione-multimediale-e-tecnologie-dellinformazione/corso/piano-studio/2025-2026/download'),
        ('Crediti a scelta dello studente (2° anno)', 9, False, 'Sistemi Multimediali e Interaction Design', 'https://www.uniud.it/it/didattica/corsi/area-scientifica/scienze-matematiche-informatiche-multimediali-fisiche/laurea-magistrale/comunicazione-multimediale-e-tecnologie-dellinformazione/corso/piano-studio/2025-2026/download'),
    ],
    ('872', 2): [
        ('Crediti a scelta dello studente (2° anno)', 12, False, None, 'https://www.uniud.it/it/didattica/corsi/area-economico-giuridica/economia/laurea-magistrale/international-marketing-management-organization/corso/piano-di-studio/2025-2026/download'),
    ],
    ('826', 2): [
        ('Crediti a scelta dello studente (2° anno)', 6, False, None, 'https://www.uniud.it/it/didattica/corsi/area-scientifica/ingegneria-architettura/laurea/tecniche-edilizia-territorio-lp/corso/piano-studio/2025-2026/download'),
    ],
}
# Crediti a scelta libera del catalogo (gruppo `S` al 1° anno con la nota) che il piano ufficiale mette in un altro anno: (cdsCod, anno) da non riportare
SENZA_LIBERA_AUTO: set[tuple[str, int]] = {("891", 1), ("884", 1), ("886", 1)}

# Percorsi (`pdsCod`, nome) del catalogo da non leggere perché non sono piani del corso
PERCORSI_ESCLUSI: set[tuple[str, str]] = {
    # Internet of Things, Big Data, Machine Learning: lo stesso piano «da sottoporre alla commissione didattica»
    ("861-9999", "IBML con piano da sottoporre alla commissione didattica"),
}

# Refusi nei nomi dei curricula del catalogo (ricostruiti nelle coorti precedenti)
REFUSI = {"Muscia": "Musica", "Sistmemi": "Sistemi", "Artificila": "Artificial", "Recuro": "Recupero", "Anim,ale": "Animale"}
# Nomi dei curricula con una virgola o con la modalità nel nome del catalogo: nome fisso per il nome semplificato
NOMI_FISSI = {
    "artificial intelligence industrial automation and iot nazionale": "Artificial Intelligence - Industrial Automation and IoT (Nazionale)",
    "artificial intelligence industrial automation and iot internazionale": "Artificial Intelligence - Industrial Automation and IoT (Internazionale)",
}

_NON_PIANO = re.compile(r"(?i)riservat|incoming")
_PARZIALE = re.compile(r"(?i)\b1\s*anno\b|esami\s*obbl|esamiobbl|obbliga[oi]t|obbligao")
_DA_APPROVARE = re.compile(r"(?i)sottopor|commissione|iterazione|da ap+ro?vare|parere")
_MOBILITA = re.compile(r"(?i)^\s*(?:graz|klagenfurt)\s*-\s*")
# parti finali del nome di un percorso che sono varianti dello stesso piano (non un altro curriculum)
_VARIANTE = re.compile(
    r"(?i)(?:\s*[:\-–_]\s*|[\s_]+)(?:1\s*anno\b.*|esam\w*\s*obbl\w*.*|esami\w*.*|piano\s+(?:di\s+studio?i?\s+)?compl\w*.*|"
    r"ad\s+approvazione.*|approvato\b.*|da\s+sottopor.*|da\s+ap+ro?vare\b.*|piano\s+di\s+stud\w*\s+da\s+sottopor.*|riservato\b.*|proposta\b.*|con\s+piano\b.*|"
    r"\(.*)$|^\s*schema\b.*$|^\s*piano\s+statutario\s*$")
_PAROLE_VUOTE = {"della", "degli", "delle", "dello", "dei", "per", "con", "nel", "nella", "and", "the"}
_CFU_ETICHETTA = re.compile(r"(\d+(?:[.,]\d+)?)\s*(?:CFU|cfu|Cfu|crediti)")


def _numero(s: str) -> float:
    return float(s.replace(",", "."))


def _un(d):
    return d[0] if isinstance(d, list) and d else d


def _norm(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


class ClientCache(cc.Client):
    """Course Catalogue con cache su disco (UN_HTTP_CACHE/uniud)."""

    def __init__(self, base: str = BASE, rate: float = RATE):
        super().__init__(base, rate)
        d = os.environ.get("UN_HTTP_CACHE")
        self.cache = pathlib.Path(d) / "uniud" if d else None

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


def _durata(det: dict) -> int | None:
    m = re.match(r"\s*(\d+)", (det or {}).get("durata_it") or "")
    return int(m.group(1)) if m else None


def _pnome(p: dict) -> str:
    n = re.sub(r"\s+", " ", (p.get("des_it") or p.get("pdsDes") or "")).strip()
    for brutto, giusto in REFUSI.items():
        n = re.sub(re.escape(brutto), lambda m, g=giusto: g.upper() if m.group(0).isupper() else g, n, flags=re.I)
    return n


def _nome_curriculum(pnome: str, corso: str) -> str:
    """«ECONOMIA AZIENDALE curriculum AMMINISTRAZIONE E CONTROLLO: piano di studio completo» → «Amministrazione e
    controllo»; «LM ECONOMICS CURRICULUM ECONOMICS» → «Economics»; il nome del corso solo → «»."""
    n = _VARIANTE.sub("", _MOBILITA.sub("", pnome)).strip(" -:")
    fisso = NOMI_FISSI.get(_norm(n))
    if fisso:
        return fisso
    m = re.search(r"(?i)\bcurr(?:iculum|\.)\s*[:\-]?\s*(?!.*\bcurr(?:iculum|\.))(.*)$", n)
    if m:
        n = m.group(1)
    else:
        n = re.sub(r"(?i)^(?:lm|l)\s+", "", n)
        nc = _norm(corso)
        if _norm(n) == nc:
            n = ""
        elif _norm(n).startswith(nc + " "):
            n = re.sub(r"(?i)^\s*" + r"[\s'’\-]*".join(re.escape(w) for w in nc.split()) + r"[\s'’\-]*", "", n)
        n = re.sub(r"(?i)^(?:percorso(?!\s+per\b)|piano di studio|piano di studi|pds)\s*[:\-]?\s*", "", n.strip(" -:."))
    n = re.sub(r"\s*\b\d{2,4}/\d{2}\b\s*", " ", n).strip(" -:.")
    n = re.sub(r"(?i)\bpiano\s+di\s+studio?i?\b\s*", "", n).strip(" -:.")
    n = re.sub(r"(?i)^a\.\s?a\.?\s*", "", n).strip(" -:.")
    if _norm(n) in ("", "a a", "comune", "percorso comune", "piano", "statutario"):
        return ""
    n = cc._titolo(n.replace(",", " -"))
    return re.sub(r"\s+", " ", n[:1].upper() + n[1:])


def _n_attivita(p: dict) -> int:
    return sum(len(g.get("attivita") or []) for a in p.get("anni") or [] for g in a.get("insegnamenti") or [])


def _punteggio(p: dict) -> tuple:
    """Quale schema di un curriculum leggere: quello completo, non riservato, non «da sottoporre» né con una mobilità;
    a parità lo schema statutario e quello con più attività."""
    n = _pnome(p)
    s = (p.get("schemaCod") or "").upper()
    return (not _NON_PIANO.search(n), not _PARZIALE.search(n), not _DA_APPROVARE.search(n), not _MOBILITA.search(n),
            "STATUTARIO" in s or "STATUTARIO" in n.upper(), _n_attivita(p))


def _semplice(p: dict) -> str:
    return _norm(_VARIANTE.sub("", _MOBILITA.sub("", _pnome(p))))


def _quasi_uguali(a: str, b: str) -> bool:
    """Nomi uguali a meno di un refuso («Muscia»/«Musica», «SISTMEMI»): al più 2 caratteri diversi."""
    if a == b:
        return True
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    uguali = sum(m.size for m in sm.get_matching_blocks())
    return max(len(a), len(b)) - uguali <= 2 and abs(len(a) - len(b)) <= 2


def _slug(s: str, maxlen: int = 40) -> str:
    """Come `build_db.slug`: l'id di un insegnamento è `<corso>-<slug del codice>`."""
    t = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", t).strip().replace(" ", "-")[:maxlen].strip("-")


def _id_corsi_db(attuali: list[dict], classi: dict[str, str | None]) -> dict[str, str]:
    """Id del corso del database per ogni corso del catalogo (`cdsCod`): come lo assocerà build_db (id esplicito,
    poi nome e classe) tra i corsi già in `database/corsi/uniud.json`. Serve per dare un id agli insegnamenti con lo
    stesso codice e CFU diversi nei curricula. Vuoto se il file o build_db non ci sono."""
    try:
        import build_db
        vecchi = json.loads((ROOT / "database" / "corsi" / "uniud.json").read_text(encoding="utf-8"))["corsi"]
    except (ImportError, OSError, ValueError, KeyError):
        return {}
    out = {}
    for cur in attuali:
        cds = cur["cdsCod"]
        if cds in ID_CORSI:
            out[cds] = ID_CORSI[cds]
            continue
        t = build_db.trova_corso(vecchi, {"nome": cc._titolo(cur.get("des_it") or ""), "classe": classi.get(cds),
                                          "sede": cur.get("sedeDenominazioneComune") or cur.get("sede_des_it"),
                                          "durata_anni": None})
        if t:
            out[cds] = t["id"]
    return out


def _token(x: str) -> list[str]:
    return [t for t in _norm(x).split() if len(t) >= 3 and t not in _PAROLE_VUOTE]


def _copre(a: list[str], b: list[str]) -> float:
    """Quota delle parole di `a` che compaiono (anche accorciate o con un refuso) in `b`."""
    if not a:
        return 0.0
    return sum(1 for t in a if any(u.startswith(t) or t.startswith(u) or
                                   difflib.SequenceMatcher(None, t, u).ratio() >= 0.85 for u in b)) / len(a)


def _percorsi_scelti(det: dict, corso: str) -> list[tuple[str, str, bool, dict]]:
    """Percorsi da leggere: (chiave, nome del curriculum, comune, percorso). Uno schema per curriculum.
    I percorsi con lo stesso `pdsCod` e lo stesso nome (a meno di varianti e refusi) sono schemi dello stesso
    curriculum. Il piano «comune» (codice «…-9999») vale per tutti quando il corso ha anche curricula specifici."""
    gruppi: list[tuple[str, str, list[dict]]] = []  # (pdsCod, nome semplice, percorsi)
    validi = []
    for p in det.get("percorsi") or []:
        if (p.get("pdsCod"), _pnome(p)) in PERCORSI_ESCLUSI:
            continue
        if not any(str(a.get("anno")).isdigit() for a in p.get("anni") or []) or not _n_attivita(p):
            continue
        validi.append(p)

    def e_variante(p: dict) -> bool:
        n = _pnome(p)
        return bool(_NON_PIANO.search(n) or _PARZIALE.search(n) or _DA_APPROVARE.search(n))

    def stesso_gruppo(cod: str, nome: str):
        for g in gruppi:
            if g[0] == cod and _quasi_uguali(g[1], nome):
                return g
        return None

    for p in [p for p in validi if not e_variante(p)] + [p for p in validi if e_variante(p)]:
        cod, nome = p.get("pdsCod") or "", _semplice(p)
        g = stesso_gruppo(cod, nome)
        if not g and e_variante(p) and not cod.endswith("-9999") and nome in ("", "piano", "piano di studi"):
            # una variante senza nome proprio («piano da approvare curr. …») va al curriculum con lo stesso codice di
            # percorso: l'unico, o quello con il nome più vicino
            cand = [x for x in gruppi if x[0] == cod]
            if len(cand) > 1:
                t = _token(_pnome(p))
                cand = sorted(cand, key=lambda x: -_copre(t, _token(x[1])))
                cand = cand[:1] if t and _copre(t, _token(cand[0][1])) >= 0.6 else []
            g = cand[0] if cand else None
        if g:
            g[2].append(p)
        else:
            gruppi.append((cod, nome, [p]))
    ci_sono_specifici = any(not g[0].endswith("-9999") for g in gruppi)
    out = []
    for cod, nome, ps in gruppi:
        migliore = max(ps, key=_punteggio)
        cn = _nome_curriculum(_pnome(migliore), corso)
        comune = ci_sono_specifici and cod.endswith("-9999")
        out.append((f"{cod}|{nome}", "" if comune else cn, comune, migliore))
    # più curricula specifici: quello che porta il nome del corso ha il nome del piano
    if len([o for o in out if not o[2]]) > 1:
        out = [(k, cn or cc._titolo(_VARIANTE.sub("", _MOBILITA.sub("", _pnome(p))).strip(" -:")), c, p)
               if not c else (k, cn, c, p) for k, cn, c, p in out]
    # un solo curriculum (o nessuno): non c'è un curriculum da indicare
    if len([o for o in out if not o[2]]) <= 1:
        out = [(k, "", c, p) for k, _, c, p in out]
    return out


_ORDINALI = {"primo": 1, "secondo": 2, "terzo": 3, "quarto": 4, "quinto": 5, "sesto": 6}
_ANNO_NOTA = re.compile(r"(?i)\b(?:sul|al|nel|del|dal)\s+(primo|secondo|terzo|quarto|quinto|sesto|[1-6])\s*[°º]?\s*anno\b")
_MASSIMO = re.compile(r"(?i)\b(?:fino\s+(?:a|ad)\s+(?:un\s+)?massimo\s+di|massimo\s+di|al\s+massimo|fino\s+a)\s*\d+(?:[.,]\d+)?\s*(?:CFU|crediti)?")


def _anno_nota(nota: str | None, predefinito: int) -> int:
    """Anno a cui la nota di un gruppo a scelta assegna i crediti («12 CFU sul terzo anno»), altrimenti quello del gruppo."""
    m = _ANNO_NOTA.search(nota or "")
    if not m:
        return predefinito
    t = m.group(1).lower()
    return _ORDINALI.get(t) or int(t)


def _libera_scelta(g: dict, anno_gruppo: int) -> list[tuple[int, float]]:
    """Crediti a scelta libera di un gruppo senza attività elencate (`S`): [(anno, CFU)]. I CFU stanno nell'etichetta
    («12 CFU a scelta») o nella nota («prevede 12 CFU sul terzo anno», «Totale crediti a scelta autonoma: 12 CFU»); un
    gruppo «6 + 9 CFU a scelta» o «del secondo (6 CFU) e del terzo (9 CFU) anno» dà più anni. Nessun valore se il
    catalogo non lo scrive."""
    label, nota = g.get("label_it") or "", g.get("nota1_it") or ""
    testo = label + " / " + nota.replace("\n", " / ")
    per_anno = re.findall(r"(?i)(?:del\s+)?(primo|secondo|terzo|quarto|quinto)\s*\(\s*(\d+(?:[.,]\d+)?)\s*CFU\s*\)", testo)
    if len(per_anno) >= 2:
        return [(_ORDINALI[a.lower()], _numero(n)) for a, n in per_anno]
    nota_pulita = _MASSIMO.sub(" ", nota)
    n_label = [_numero(x) for x in _CFU_ETICHETTA.findall(label)]
    n_nota = [_numero(x) for x in _CFU_ETICHETTA.findall(nota_pulita)]
    cfu = n_label[-1] if len(n_label) == 1 else None
    if cfu is None and len(set(n_nota)) == 1:
        cfu = n_nota[0]
    if cfu is None and n_nota:
        m = re.search(r"(?i)(?:prevede|a\s+disposizione|scelta\s+di|sono|totale[^0-9]{0,40}|occupare(?:\s+i)?|scegliere\s+in\s+totale)\s*"
                      r"(\d+(?:[.,]\d+)?)", nota_pulita)
        if m:
            cfu = _numero(m.group(1))
    if not cfu:
        return []
    return [(_anno_nota(nota, anno_gruppo), cfu)]


_ETICHETTA_OBBLIGATORI = re.compile(r"(?i)^\s*(?:(?:primo|secondo|terzo|quarto|quinto)\s+anno\s+)?obbligatori\b")


def _gruppo_obbligatorio(g: dict) -> bool:
    """«Obbligatori» (`OO`) e i gruppi da sostenere per intero («Primo anno obbligatori», «Obbligatorio tutti i curricola»,
    un'attività formativa non assegnata a un anno): tutte le attività «OBB» e nessuna scelta nell'etichetta o nella nota."""
    if g.get("cod") == "OO":
        return True
    atts = g.get("attivita") or []
    lab = g.get("label_it") or ""
    nota = g.get("nota1_it") or ""
    if not atts or re.search(r"(?i)scelta|iterazion|lingua inglese|opzion|propedeut|\btra\b", lab) or re.search(
            r"(?i)\bscegli|uno di|uno dei|una delle|a scelta", nota):
        return False
    if all(t.get("tipo_ins_cod") in ("OBB", "") for t in atts):
        return True
    return g.get("cod") != "G" and bool(_ETICHETTA_OBBLIGATORI.search(lab))


def fetch_ateneo(uid: str = "uniud", anno: int = 2026, max_cds: int | None = None, syllabus: bool = True,
                 log=print, client=None) -> dict:
    c = client or ClientCache()
    base = BASE
    oggi = time.strftime("%Y-%m-%d")
    durata_max = 6
    coorti: dict[int, dict[str, dict]] = {}
    for y in range(anno - durata_max, anno + 1):
        lst = c.get("/corsi", {"anno": y, "minimal": "true"}) or []
        cds: list[dict] = []
        cc._walk_cds(lst, cds)
        coorti[y] = {x["cdsCod"]: x for x in cds if str(x.get("aa")) == str(y)}
    attuali = [x for x in coorti.get(anno, {}).values() if x.get("tipo_corso_cod") in TIPI_RICHIESTI]
    for cod, y in CORSI_SENZA_COORTE_ATTUALE.items():
        if cod not in coorti.get(anno, {}) and cod in coorti.get(y, {}):
            attuali.append(coorti[y][cod])
    if max_cds:
        attuali = attuali[:max_cds]
    log(f"[{uid}] {len(attuali)} corsi di studio nella coorte {anno}")

    cache_piani: dict[tuple[int, str], dict | None] = {}

    def trova(y: int, cur: dict) -> dict | None:
        """Corso della coorte `y` che corrisponde a `cur`: stesso codice, o stesso nome, sede e tipo."""
        x = coorti.get(y, {}).get(cur["cdsCod"])
        if x:
            return x
        k = (_norm(cur.get("des_it")), cur.get("sede_cod"), cur.get("tipo_corso_cod"))
        stessi = [v for v in coorti.get(y, {}).values()
                  if (_norm(v.get("des_it")), v.get("sede_cod"), v.get("tipo_corso_cod")) == k]
        return stessi[0] if len(stessi) == 1 else None

    def piano(y: int, cur: dict) -> dict | None:
        x = trova(y, cur)
        if not x:
            return None
        key = (y, x["cod"])
        if key not in cache_piani:
            d = _un(c.get(f"/corso/{y}/{x['cod']}"))
            cache_piani[key] = d if isinstance(d, dict) else None
        return cache_piani[key]

    syllabus_jobs: dict[tuple[str, str], dict] = {}

    def anno_k(det: dict, k: int) -> bool:
        return any(str(a.get("anno")) == str(k) and any(g.get("attivita") for g in a.get("insegnamenti") or [])
                   for p in det.get("percorsi") or [] for a in p.get("anni") or [])

    def build_cds(cur: dict) -> dict | None:
        cds = cur["cdsCod"]
        y_cur = int(cur.get("aa") or anno)
        det_cur = piano(y_cur, cur) or {}
        durata = _durata(det_cur) or 3
        classe = cc._classe(cur.get("classe_cod") or det_cur.get("classe_cod"))
        corso_nome = cc._titolo(cur.get("des_it") or "")
        insegnamenti: dict[tuple, dict] = {}
        canonici: set[str] = set()  # nomi dei curricula nella coorte attuale
        amm = None
        piano_anni = {}
        for k in range(1, durata + 1):
            y0 = min(anno - k + 1, y_cur)
            # coorte degli iscritti al k-esimo anno; altrimenti la più vicina (prima quelle dopo, poi quelle prima)
            candidate = [y0] + [y0 + i for i in range(1, anno - y0 + 1)] + [y0 - i for i in range(1, durata_max + 1)]
            det = y = None
            for yy in candidate:
                d = piano(yy, cur)
                if d and anno_k(d, k):
                    det, y = d, yy
                    break
            if not det:
                continue
            piano_anni[str(k)] = y
            if amm is None and y == anno:
                amm = ammissione.da_catalogo(det, f"{base}/corsi/{anno}/{cur.get('cod')}")
            scelti = _percorsi_scelti(det, det.get("des_it") or cur.get("des_it") or "")
            specifici = [s for s in scelti if not s[2]]
            for chiave, cnome, comune, p in scelti:
                for a in p.get("anni") or []:
                    if not str(a.get("anno")).isdigit():
                        continue
                    anno_sezione = int(a["anno"])
                    for g in a.get("insegnamenti") or []:
                        obb_gruppo = _gruppo_obbligatorio(g)
                        atts = g.get("attivita") or []
                        libera = g.get("tipSce") == "S" and not atts
                        # i gruppi di libera scelta sono spesso al 1° anno, con la nota «12 CFU sul terzo anno»
                        anni_gruppo = ([ay for ay, _ in _libera_scelta(g, anno_sezione)] if libera else
                                       [_anno_nota(g.get("nota1_it"), anno_sezione) if g.get("tipSce") == "W" else anno_sezione])
                        if k not in anni_gruppo:
                            continue
                        if DIAGNOSTICA is not None:
                            DIAGNOSTICA.setdefault(cds, {}).setdefault(str(k), {"coorte": y, "gruppi": []})["gruppi"].append({
                                "curriculum": cnome or ("*" if comune else ""), "etichetta": g.get("label_it"),
                                "cod": g.get("cod"), "tipSce": g.get("tipSce"), "nota": g.get("nota1_it"),
                                "obb": obb_gruppo,
                                "cfu": [t.get("crediti") for t in atts], "tipi": [t.get("tipo_ins_cod") for t in atts],
                                "codici": [t.get("adCod") for t in atts], "nomi": [t.get("des_it") for t in atts]})
                        if libera:
                            for ay, n in _libera_scelta(g, anno_sezione):
                                if ay != k or (cds, k) in SENZA_LIBERA_AUTO:
                                    continue
                                n = int(n) if n == int(n) else n
                                key = (k, f"libera:{n}")
                                it = insegnamenti.get(key)
                                if not it:
                                    it = insegnamenti[key] = {
                                        "codice": None, "nome": f"Crediti a scelta dello studente ({k}° anno)",
                                        "anno": k, "periodo": None, "periodo_inizio": None, "periodo_fine": None,
                                        "cfu": n, "ssd": None, "obbligatorio": False, "curriculum": None,
                                        "_c": set(), "docenti": [], "libri": [], "esami": [],
                                        "url": f"{base}/corsi/{y}/{det.get('cod')}",
                                        "fonte": base, "verificato_il": oggi, "stato_libri": "nessun_libro"}
                                it["_c"].add(chiave if not comune else "*")
                            continue
                        for att in atts:
                            if not att.get("crediti"):  # test d'ingresso, prove propedeutiche, esercitazioni: 0 CFU
                                continue
                            ad = att.get("adCod") or att.get("cod")
                            key = (k, ad, att.get("crediti"))  # stesso codice con altri CFU in un altro curriculum
                            it = insegnamenti.get(key)
                            obbl = obb_gruppo and att.get("tipo_ins_cod") != "OPZ"
                            if not it:
                                docenti = [cc._nome(x.get("des")) for x in att.get("docenti") or [] if x.get("des")]
                                it = insegnamenti[key] = {
                                    "codice": ad, "nome": cc._titolo(att.get("des_it") or ad), "anno": k,
                                    "periodo": cc._periodo(att.get("periodo_didattico_it")),
                                    "periodo_inizio": att.get("data_inizio_periodo_didattico"),
                                    "periodo_fine": att.get("data_fine_periodo_didattico"),
                                    "cfu": att.get("crediti"), "ssd": None, "obbligatorio": obbl,
                                    "curriculum": None, "_c": set(), "docenti": sorted(set(docenti)),
                                    "url": f"{base}/insegnamenti/{att.get('aa')}/{att.get('cod')}"
                                           f"/{att.get('ordinamento_aa')}/{att.get('corso_percorso_id')}?coorte={y}",
                                    "libri": [], "esami": [], "fonte": base, "verificato_il": oggi,
                                    "_obb": {}}
                                if syllabus:
                                    it["_sj"] = (str(att.get("aa")), str(att.get("cod")))
                                    syllabus_jobs.setdefault((str(att.get("aa")), str(att.get("cod"))), {
                                        "params": {"anno": att.get("aa"), "insegnamento": att.get("cod"),
                                                   "ordinamento_aa": att.get("ordinamento_aa"),
                                                   "af_percorso": att.get("corso_percorso_id"),
                                                   "corso_cod": att.get("corso_cod"), "corso_aa": y,
                                                   "schema_id": att.get("schemaId")},
                                        "items": []})["items"].append(it)
                            it["_obb"][chiave if not comune else "*"] = obbl
                            it["_c"].add(chiave if not comune else "*")
            # voci dei piani ufficiali che il catalogo non ha
            for nome_e, cfu_e, obbl_e, curr_e, fonte_e in PIANO_EXTRA.get((cds, k), []):
                key = (k, f"extra:{nome_e}", cfu_e)
                chiavi_e = {s[0] for s in specifici if curr_e and s[1] == curr_e} if curr_e else {"*"}
                it = insegnamenti.setdefault(key, {
                    "codice": None, "nome": nome_e, "anno": k, "periodo": None, "periodo_inizio": None,
                    "periodo_fine": None, "cfu": cfu_e, "ssd": None, "obbligatorio": obbl_e, "curriculum": None,
                    "_c": set(), "_obb": {}, "docenti": [], "libri": [], "esami": [], "url": fonte_e,
                    "fonte": fonte_e, "verificato_il": oggi, "stato_libri": "nessun_libro"})
                it["_c"] |= chiavi_e
                for ke in chiavi_e:
                    it["_obb"][ke] = obbl_e
            # curricula presenti in questo anno: gli insegnamenti di tutti sono comuni
            chiavi_anno = {s[0] for s in specifici}
            for (kk, *_), it in insegnamenti.items():
                if kk != k:
                    continue
                cs = it.pop("_c", set())
                if "*" in cs or not chiavi_anno or chiavi_anno <= cs:
                    it["_cn"] = []
                else:
                    it["_cn"] = sorted({s[1] for s in specifici if s[0] in cs and s[1]})
                # obbligatorio in alcuni curricula e a scelta in altri: obbligatorietà per nome di curriculum
                # (solo se tutti i curricula dell'anno hanno un nome e uno stesso nome non ha valori diversi)
                ob = it.get("_obb")
                if ob and len(set(ob.values())) > 1 and specifici and all(s[1] for s in specifici):
                    per_nome: dict[str, bool] = {}
                    for s in specifici:
                        v = ob.get(s[0], ob.get("*"))
                        if v is None:
                            continue
                        if per_nome.setdefault(s[1], v) != v:
                            per_nome = {}
                            break
                    if per_nome:
                        it["_obn"] = per_nome
            if y == y_cur:
                canonici.update(s[1] for s in specifici if s[1])
        ins = list(insegnamenti.values())

        def canonico(n: str) -> str:
            """Nome del curriculum in una coorte precedente → quello della coorte attuale (nomi accorciati o cambiati)."""
            if n in canonici or not canonici:
                return n
            t_old = _token(n)
            if not t_old:
                return n
            migliore, punti = n, 0.0
            for cand in canonici:
                t_new = _token(cand)
                if not t_new:
                    continue
                dentro, inverso = _copre(t_old, t_new), _copre(t_new, t_old)
                if dentro >= 0.7 and inverso >= 0.3 and dentro + inverso > punti:
                    migliore, punti = cand, dentro + inverso
            return migliore

        curricula: set[str] = set()
        for i in ins:
            nomi = sorted({canonico(n) for n in i.pop("_cn", [])})
            i["curriculum"] = ", ".join(nomi) or None
            curricula.update(nomi)
            obn = i.pop("_obn", None)
            if obn:
                gr: dict[bool, set[str]] = {True: set(), False: set()}
                for n, v in obn.items():
                    gr[bool(v)].add(canonico(n))
                if gr[True] and gr[False] and not gr[True] & gr[False]:
                    i["_dividi"] = gr
        curricula |= canonici
        for i in list(ins):
            ob = i.pop("_obb", None)
            if ob is not None:  # obbligatorio se lo è in tutti i curricula che lo hanno
                i["obbligatorio"] = all(ob.values())
            i.pop("_c", None)
            gr = i.pop("_dividi", None)
            sj = i.pop("_sj", None)
            if gr:
                # obbligatorio in alcuni curricula e a scelta in altri: due righe con gli stessi codice e CFU, una per
                # i curricula dove è obbligatorio (tiene l'id, build_db dà all'altra «-scelta») e una per gli altri
                altro = {**i, "docenti": list(i["docenti"]), "libri": [], "esami": []}
                i["obbligatorio"], i["curriculum"] = True, ", ".join(sorted(gr[True]))
                altro["obbligatorio"], altro["curriculum"] = False, ", ".join(sorted(gr[False]))
                ins.append(altro)
                if sj in syllabus_jobs:
                    syllabus_jobs[sj]["items"].append(altro)
        # crediti a scelta con CFU diversi nello stesso anno (per curriculum): il nome porta i CFU, altrimenti build_db li fonde
        for k_l in {i["anno"] for i in ins if not i["codice"] and i["nome"].startswith("Crediti a scelta")}:
            libere = [i for i in ins if i["anno"] == k_l and not i["codice"] and i["nome"].startswith("Crediti a scelta")]
            if len({i["cfu"] for i in libere}) > 1:
                for i in libere:
                    i["nome"] = f"Crediti a scelta dello studente ({i['cfu']:g} CFU, {k_l}° anno)"  # (l'id usa 40 caratteri del nome)
        # stesso codice con CFU diversi nei curricula (es. «Linguistica italiana» da 13 CFU nel piano standard e da 6 negli
        # altri): un insegnamento per ogni valore, la variante principale (più curricula) con l'id del codice e le altre
        # con un id proprio, altrimenti build_db le fonderebbe in una sola
        per_codice: dict[tuple, list[dict]] = {}
        for i in ins:
            if i["codice"]:
                per_codice.setdefault((i["anno"], i["codice"]), []).append(i)
        cid = id_db.get(cds)
        for (anno_i, codice), gl in per_codice.items():
            if len(gl) < 2:
                continue
            # (le righe con lo stesso codice e CFU, obbligatoria in alcuni curricula e a scelta negli altri, non sono
            # varianti: l'id lo dà build_db)
            per_cfu: dict[float, list[dict]] = {}
            for i in gl:
                per_cfu.setdefault(i["cfu"], []).append(i)
            if len(per_cfu) < 2:
                continue
            varianti = sorted(per_cfu.values(), key=lambda g: (
                -sum(len(i["curriculum"].split(", ")) if i["curriculum"] else 99 for i in g), -g[0]["cfu"]))
            if not cid:  # nessun id del corso: una sola variante (la principale), senza perdere il resto
                for g in varianti[1:]:
                    for altro in g:
                        ins.remove(altro)
                continue
            for g in varianti[1:]:
                for k, altro in enumerate(g):
                    altro["id"] = f"{cid}-{_slug(codice)}-{altro['cfu']:g}cfu" + (
                        "" if not k else "-scelta" if altro["obbligatorio"] is False else "-obbl")
        # omonimi nello stesso anno con codici diversi: il nome porta i CFU (o il codice)
        gruppi: dict[tuple, list[dict]] = {}
        for i in ins:
            gruppi.setdefault((i["anno"], _norm(i["nome"])), []).append(i)
        for gl in gruppi.values():
            codici = {i["codice"] for i in gl}
            if len(codici) < 2:
                continue
            per_cod = {cod: {i["cfu"] for i in gl if i["codice"] == cod} for cod in codici}
            cfu_distinti = len({c for v in per_cod.values() for c in v}) == len(codici) and all(
                len(v) == 1 for v in per_cod.values())
            for i in gl:
                if not any(j is not i and j["codice"] != i["codice"] and (
                        not i["curriculum"] or not j["curriculum"] or
                        set(i["curriculum"].split(", ")) & set(j["curriculum"].split(", "))) for j in gl):
                    continue  # stesso nome ma in curricula diversi: non si confondono
                i["nome"] = f"{i['nome']} ({i['cfu']:g} CFU)" if cfu_distinti else f"{i['nome']} ({i['codice']})"
        return {
            **({"id": ID_CORSI[cds]} if cds in ID_CORSI else {}),
            "nome": corso_nome, "classe": classe, "tipo_catalogo": cur.get("tipo_corso_cod"), "durata_anni": durata,
            "sede": (cur.get("sedeDenominazioneComune") or cur.get("sede_des_it") or None),
            "codice_ateneo": cds, "url": f"{base}/corsi/{y_cur}/{cur.get('cod')}",
            "curricula": sorted(curricula) or None, "ammissione": amm, "piano_anni": piano_anni,
            "fonte": base, "verificato_il": oggi, "insegnamenti": ins,
        }

    classi_corsi = {}
    for cur in attuali:
        det0 = piano(int(cur.get("aa") or anno), cur) or {}
        classi_corsi[cur["cdsCod"]] = cc._classe(cur.get("classe_cod") or det0.get("classe_cod"))
    id_db = _id_corsi_db(attuali, classi_corsi)
    corsi_out = []

    def build_safe(cur: dict) -> dict | None:
        try:
            return build_cds(cur)
        except Exception as e:  # noqa: BLE001 - si salta solo quel corso
            import traceback
            log(f"[{uid}]   corso {cur.get('cdsCod')} saltato: {e!r}\n{traceback.format_exc()}")
            return None

    with cf.ThreadPoolExecutor(4) as ex:
        for r in ex.map(build_safe, attuali):
            if r and r["insegnamenti"]:
                corsi_out.append(r)
    log(f"[{uid}] piani letti: {len(corsi_out)} corsi, {sum(len(x['insegnamenti']) for x in corsi_out)} "
        f"insegnamenti; syllabus da leggere: {len(syllabus_jobs)}")

    # insegnamenti già nel database con i libri: non si rileggono
    noti: dict[str, dict] = {}
    if syllabus:
        try:
            vecchio = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))
            for co in vecchio.get("corsi") or []:
                for i in co.get("insegnamenti") or []:
                    if i.get("codice") and i.get("libri"):
                        noti.setdefault(str(i["codice"]), i)
        except (OSError, ValueError):
            pass

    def do_syllabus(job: dict) -> int:
        try:
            return _do_syllabus(job)
        except Exception:  # noqa: BLE001 - un syllabus illeggibile non ferma gli altri
            return 0

    def _do_syllabus(job: dict) -> int:
        cod = str(job["params"].get("insegnamento"))
        if cod in noti or any(str(i.get("codice")) in noti for i in job["items"]):
            return 0
        sy = c.get("/insegnamento", {k: v for k, v in job["params"].items() if v not in (None, "")})
        if not isinstance(sy, dict):
            return 0
        libri, modalita, legati = cc._testi_syllabus(sy)
        if not libri:  # testi in forma libera
            libri = libri_testo_libero(sy)
        if not libri:  # la bibliografia è su Leganto
            for u in legati:
                libri += cc.leganto.libri(u)
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
    for co in corsi_out:
        co.pop("piano_anni", None)
    return {"universita_id": uid, "descrizione": f"Generato da {base} (Course Catalogue Cineca, adapters/uniud.py)",
            "generato_il": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "corsi": corsi_out, "canali": []}


def main(argv: list[str]) -> int:
    doc = fetch_ateneo(syllabus="--senza-syllabus" not in argv)
    out = ROOT / "database" / "contrib" / "auto" / "uniud.json"
    try:
        vecchio = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        vecchio = {}
    doc["appelli"] = vecchio.get("appelli") or {}
    doc["canali"] = vecchio.get("canali") or []
    out.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"[uniud] {len(doc['corsi'])} corsi scritti in {out} ({time.strftime('%H:%M:%S')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
