"""Libri dai testi liberi dei syllabus di UniTS (campi «testi» e «testi del modulo»).

I docenti scrivono il campo a mano: citazioni su una riga o in un unico paragrafo senza a capo,
titolo, autori ed editore su righe diverse, frasi come «Slide su Moodle», «Testi comunicati a lezione».
`unimore_testi.libri_unimore` (estrazione per riga, per autore e per frase) trova la maggior parte dei
riferimenti con editore, anno o ISBN; qui si recupera il resto in modo tollerante ma senza prosa:

1. paragrafo per paragrafo: righe a capo unite quando la prima è solo autori («G. Costa, M. Gianecchini»
   / «Risorse umane» / «McGraw-Hill»);
2. voci separate da numerazione («1) … 2) …»), trattini, asterischi o punti e virgola;
3. frasi con l'aspetto di un riferimento (autore all'inizio, almeno quattro parole) anche senza anno
   o editore («Microeconomia, R. Pindyck & D. Rubinfeld Capitoli 1-11»), mai se contengono parole di
   prosa («sarà fornito», «Moodle», «slide», «appunti»...);
4. frasi successive che completano la citazione precedente («Seconda edizione», «Bologna: Il Mulino»)
   o il titolo dopo i soli autori («Dirk Hovy. Text Processing with Python») si uniscono ad essa.

La citazione resta com'è nel syllabus; autori e titolo si separano solo quando `testi._libero` ne è certo.
"""
from __future__ import annotations

import html
import re

from . import unifi_testi, unimore_testi
from .testi import YEAR, _isbn, _tipo
from .unifi_testi import _AUTORE_INIZIO, _INIZIO_NO, _PROSA, _editore, _solo_nomi

_PROSA_PIU = re.compile(
    r"(?i)(?<![a-zà-ÿ])(?:comunicat[oie]|indicat[oie]|forniti?|fornite|reso|resa|resi|rese|messo|messa|"
    r"verr[aà]|verranno|sar[aà]|saranno|segnalat[oie]|distribuit[oie]|presentat[oie]|"
    r"trascritt[oie]|raccolt[oie]|reperibil[ei]|moodle|teams|piattaforma|slides?|lucidi|appunti|dispense|"
    r"registrazion[ei]|software|articoli|will be|provided|available)(?![a-zà-ÿ])")
_FINE_FRASE = re.compile(r"(?<=[a-zà-ÿ0-9)\]”\"»])\.\s+(?=[A-ZÀ-Ý“\"«(\[])")
_SEP_VOCI = re.compile(
    r"(?:(?<=\S)\s+(?=\d{1,2}[.)]\s+\S)|(?<=\S)\s+(?=\[\d{1,2}\]\s*\S)"
    r"|\s+[-–—]{1,2}\s+(?=[A-ZÀ-Ý])|\s+\*\s*(?=[A-ZÀ-Ý])|;\s+)")
_CODA = re.compile(r"(?i)^(?:(?:\d+\s?[aª°]?|prima|seconda|terza|quarta|quinta|nuova|ultima)\s+ed(?:izione|\.)?"
                   r"|(?:ed\.|edizione|vol\.|volume)\s*\S.{0,25}"
                   r"|[A-ZÀ-Ý][\w'’\-]+(?:\s[A-ZÀ-Ý][\w'’\-]+){0,2}:\s*[A-ZÀ-Ý][\w'’\-]+(?:\s[\w'’\-]+){0,3}"
                   r"|[A-ZÀ-Ý][\w'’\-]+(?:\s[A-ZÀ-Ý][\w'’\-]+){0,2},?\s*(?:19|20)\d\d)$")
_TAGLIO = " .;,-–"


def _testo(raw: str) -> str:
    t = re.sub(r"(?i)<\s*(?:br|/p|/li|/div)\s*/?>", "\n", raw or "")
    t = re.sub(r"(?i)<\s*li[^>]*>", "\n", t)
    t = html.unescape(html.unescape(re.sub(r"<[^>]+>", " ", t)))
    t = re.sub(r"[\xa0 ​]", " ", t)
    t = re.sub(r"[•]", "\n", t)
    t = re.sub(r"(?:https?://|www\.)\S+", " ", t)
    t = re.sub(r"[ \t]+", " ", t)
    return t


def _paragrafi(t: str) -> list[list[str]]:
    """Righe del testo raggruppate in blocchi separati da righe vuote."""
    blocchi, cur = [], []
    for r in t.splitlines():
        r = r.strip(" -–*;·")
        if r:
            cur.append(r)
        elif cur:
            blocchi.append(cur)
            cur = []
    if cur:
        blocchi.append(cur)
    return blocchi


def _unisci_righe(righe: list[str]) -> list[str]:
    """Righe a capo di una stessa citazione: una riga di soli autori («G. Costa, M. Gianecchini») o con
    l'autore e senza anno si unisce alle successive finché non c'è prosa."""
    out: list[str] = []
    i = 0
    while i < len(righe):
        r = righe[i]
        if (_solo_nomi(r) or (_AUTORE_INIZIO.match(r) and not YEAR.search(r) and len(r.split()) <= 6)) \
                and i + 1 < len(righe):
            blocco = [r]
            j = i + 1
            while j < len(righe) and len(blocco) < 4 and not _PROSA.search(righe[j]) \
                    and not _PROSA_PIU.search(righe[j]) and len(righe[j]) < 160 \
                    and not (_AUTORE_INIZIO.match(righe[j]) and YEAR.search(righe[j])):
                blocco.append(righe[j])
                j += 1
            if len(blocco) >= 2:
                out.append(" ".join(blocco))
                i = j
                continue
        out.append(r)
        i += 1
    return out


def _voci(riga: str) -> list[tuple[int, int]]:
    """Intervalli (inizio, fine) delle voci di una riga; il testo resta quello originale."""
    out, pos = [], 0
    for m in _SEP_VOCI.finditer(riga):
        if riga[pos:m.start()].strip():
            out.append((pos, m.start()))
        pos = m.end()
    if riga[pos:].strip():
        out.append((pos, len(riga)))
    return out


def _frasi(riga: str) -> list[str]:
    """Voci della riga; dentro una voce, le frasi che completano la citazione (autori seguiti dal titolo,
    «Seconda edizione», «Bologna: Il Mulino») si riuniscono mantenendo il testo originale."""
    uniti: list[tuple[int, int]] = []
    for a, b in _voci(riga):
        testo = riga[a:b].strip(_TAGLIO)
        prec = riga[uniti[-1][0]:uniti[-1][1]].strip(_TAGLIO) if uniti else ""
        # una voce di soli autori è seguita dal titolo: si uniscono (con il separatore originale)
        if uniti and len(prec.split()) <= 7 and _solo_nomi(prec) and not _PROSA.search(testo):
            uniti[-1] = (uniti[-1][0], b)
        else:
            uniti.append((a, b))
    out: list[str] = []
    for a, b in uniti:
        voce = riga[a:b]
        pezzi, pos = [], 0
        for m in _FINE_FRASE.finditer(voce):
            pezzi.append((pos, m.start() + 1))
            pos = m.end()
        pezzi.append((pos, len(voce)))
        cur: tuple[int, int] | None = None
        for x, y in pezzi:
            p = voce[x:y].strip(_TAGLIO)
            if not p:
                continue
            if cur is not None:
                prec = voce[cur[0]:cur[1]].strip(_TAGLIO)
                if (_CODA.match(p) or (_editore(p.lower()) and len(p.split()) <= 5)
                        or (_solo_nomi(prec) and len(prec.split()) <= 7 and not _PROSA.search(p))) \
                        and cur[1] - cur[0] < 380:
                    cur = (cur[0], y)
                    continue
                out.append(voce[cur[0]:cur[1]].strip(_TAGLIO))
            cur = (x, y)
        if cur is not None:
            out.append(voce[cur[0]:cur[1]].strip(_TAGLIO))
    return [p for p in out if p]


def _accettabile(p: str) -> bool:
    if not (18 <= len(p) <= 420) or _INIZIO_NO.match(p) or p[0] in "(" or p.endswith((":", "(")):
        return False
    if _PROSA.search(p) or re.search(r"(?i)\b(?:sar[aà]|saranno|verr[aà]|verranno|forniti?|fornite|comunicat\w+|"
                                     r"indicat\w+|disponibil\w+|moodle|teams)\b", p):
        return False
    parole = p.split()
    if len(parole) < 4 or p.count("(") != p.count(")") or p.count("{") != p.count("}"):
        return False
    if re.search(r"(?i)linee guida|\butili\b|\bselezionat\w+|\bautore:|\bautori:|\b(?:e|di|del|della|and|of)$", p):
        return False
    if _solo_nomi(p) and not (YEAR.search(p) or _isbn(p)):
        return False  # solo autori: manca il titolo
    # frase che parla di altro («gli studenti ...», «il corso ...»)
    if re.match(r"(?i)^(?:gli|le|il|lo|la|i|un|una|per|nel|nella|in|con|su|sul|sulla|durante|tutti|tutte|"
                r"studenti|corso|materiale|materiali|testi|libri|bibliografia|autore|university|pubblicazioni)\b", p):
        return False
    autore = bool(_AUTORE_INIZIO.match(p))
    virgolette = bool(re.search(r"[“\"«][^”\"»]{4,}[”\"»]", p))
    segno = bool(YEAR.search(p) or _isbn(p) or _editore(p.lower()) or virgolette)
    return autore and (segno or len(parole) >= 4)


def _libro(p: str) -> dict:
    b = unifi_testi._libro(p)
    b["tipo"] = _tipo(p)
    return b


def libri_lenient(sy: dict) -> list[dict]:
    campi: list[str] = []
    for t in sy.get("testiTotali") or []:
        campi += [t.get(k) or "" for k in ("testi_it", "mod_testi_it")]
    libri, viste = [], set()
    for campo in campi:
        for blocco in _paragrafi(_testo(campo)):
            for riga in _unisci_righe(blocco):
                riga = re.sub(r"(?i)^\s*(?:\d{1,2}[.)]|[a-z]\)|\[\d{1,2}\])\s*", "", riga)
                riga = re.sub(r"(?i)^(?:recommended|testi?|libri?|manuali?|bibliografia|testo|letture)"
                              r"(?:\s+(?:di|d')\s*\w+|\s+\w+)?\s*(?:consigliat\w+|obbligator\w+|d'esame|di riferimento|"
                              r"principale|adottat\w+)?\s*[:\-–]\s*", "", riga).strip()
                for p in _frasi(riga):
                    if _accettabile(p):
                        k = re.sub(r"\W+", "", p.lower())[:120]
                        if k not in viste:
                            viste.add(k)
                            libri.append(_libro(p))
    return libri


_LEGGE = re.compile(r"(?i)\b(?:d\.?\s?lgs|dlgs|decreto|d\.?\s?m\.|d\.?\s?l\.|legge|accordo stato|codice deontologico|"
                    r"costituzione|regolamento|linee guida|direttiva|norme|normativa|syllabus|s\.m\.i|dm|d\.?p\.?r|dpr|indicazioni nazionali|guidelines|documentazione|raccomandazioni)\b")


def _segno(r: str) -> bool:
    return bool(YEAR.search(r) or _isbn(r) or _editore(r.lower()))


def libri_blocchi(sy: dict) -> list[dict]:
    """Titolo, autore ed editore su righe diverse («Chirurgia Odontostomatologica» / «Minerva Medica Torino
    2018»): le righe si accumulano fino a quella con un editore, un anno o un ISBN, che chiude la citazione.
    Si scarta la prosa, le leggi e i regolamenti, i link."""
    campi: list[str] = []
    for t in sy.get("testiTotali") or []:
        campi += [t.get(k) or "" for k in ("testi_it", "mod_testi_it")]
    libri, viste = [], set()
    for campo in campi:
        for blocco in _paragrafi(_testo(campo)):
            cur: list[str] = []
            for riga in blocco:
                riga = re.sub(r"(?i)^\s*(?:\d{1,2}[.)]|[a-z]\)|\[\d{1,2}\])\s*", "", riga).strip(" •-–*")
                if not riga or _PROSA.search(riga) or _PROSA_PIU.search(riga) or _LEGGE.search(riga)                         or re.match(r"(?i)^(?:recommended|testi?|libri?|bibliografia|testo)\b[\w\s]{0,25}:?$", riga):
                    cur = []
                    continue
                cur.append(riga)
                if _segno(riga):
                    p = " ".join(cur).strip(_TAGLIO)
                    cur = []
                    if 20 <= len(p) <= 400 and len(p.split()) >= 4 and p.count("(") == p.count(")")                             and not _LEGGE.search(p) and not _INIZIO_NO.match(p) and not re.match(r"\d{4}\b", p):
                        k = re.sub(r"\W+", "", p.lower())[:120]
                        if k not in viste:
                            viste.add(k)
                            libri.append(_libro(p))
                elif len(cur) > 4:
                    cur = cur[1:]
    return libri


# Riferimenti che l'estrazione automatica non riconosce o spezza male (più titoli sulla stessa riga senza
# separatori, titolo e autore a capo senza editore, elenchi con trattini ripetuti). Per ogni insegnamento
# (codice dell'attività didattica) le citazioni sono porzioni IDENTICHE del testo pubblicato nel syllabus:
# `libri_manuali` le usa solo se le trova nel testo della scheda (spazi e a capo normalizzati), quindi una
# scheda aggiornata che le cambia non produce libri sbagliati. Una lista vuota esclude l'insegnamento
# (norme, linee guida, documenti: non libri).
CITAZIONI: dict[str, list[str]] = {
    "118MI": ["Galgano Alberto, Qualità totale. Il metodo scientifico nella gestione aziendale",
              "Galgano Alberto, I sette strumenti manageriali della qualità",
              "Brandolese – Brugger - Garetti, Analisi dei sistemi di produzione manufatturiera",
              "Salomone - Giovanni Franco - Dalla qualità totale alla qualità integrata. L'integrazione dei sistemi di "
              "gestione qualità, ambiente, sicurezza ed etica per il vantaggio",
              "Andrea Chiarini, La conduzione degli audit. Ricerche e percorsi di audit sui sistemi di gestione qualità, "
              "ambiente, sicurezza, etico-sociale e sui modelli organizzativi previsti dal D.Lgs 231"],
    "478SM": ["Dirk Hovy. Text Processing with Python for Social Scientists.",
              "Dan Jurafsky and James H. Martin. Speech and Language Processing.",
              "Yoav Goldberg. A Primer on Neural Network Models for Natural Language Processing.",
              "I. J. Goodfellow, Y. Bengio, and A. C. Courville, Deep Learning. MIT press, 2016"],
    "123SP": ["Eschilo: Orestiade; Sofocle: Elettra, Antigone Euripide: Medea Aristofane: Lisistrata"],
    "076AR": ["SISTEMI INFORMATIVI TERRITORIALI Principi e applicazioni 2a edizione Federica Migliaccio, Daniela Carrion.",
              "GIS Open Source per geologia e ambiente - Analisi e gestione di dati territoriali e ambientali con QGIS "
              "Valerio Noti II Edizione Dario Flaccovio Editore."],
    "060SM": ["D. Griffiths Introduzione alla Meccanica Quantistica.",
              "McQuarrie, Quantum Chemistry (parte su atomi multielettroni e molecole)"],
    "967SM": ["N. Ashcroft and N.D. Mermin, Solid State Physics.",
              "P.W. Anderson, Basic Notions Of Condensed Matter Physics.",
              "P. Fazekas, Lecture Notes on Electron Correlation and Magnetism.",
              "M. Tinkham, Introduction to Superconductivity."],
    "529MI": ["Sean Luke, Essentials of Metaheuristics.",
              "Thomas Weise, Global Optimization Algorithms – Theory and Application."],
    "039IN": ["Elementi di Fisica Tecnica per l'ingegneria, II Ed. A.A.V.V. Edizione italiana a cura di M. Corticelli. "
              "Casa editrice McGraw Hill",
              "E. Zandegiacomo – Termodinamica applicata, Ed. Goliardiche, Trieste.",
              "G. Comini – Lezioni di Termodinamica Applicata. SGE, Padova",
              "A Heat Transfer Textbook, 5th ed John H. Lienhard IV, University of Houston."],
    "047SP": ["Guido Alfani - Andrea Colli, Tra le onde della globalizzazione. Una storia economica del mondo, "
              "Giappichelli, 2024"],
    "730ME": [],  # standard e linee guida (CLSI, WHO, EFLM), non libri
    "1148ME": ['"Microbiologia Clinica" (Eudes Lanciotti)',
               "“Microbiologia e microbiologia clinica”. (Simona De Grazia)"],
    "616SM": ["Grossman & Nir, The Standard Model", "Fabbrichesi, The Standard Model A Practical Step-by-Step Guide",
              "Tong, The Standard Model (online)", "Donoghue Golowich & Holstein, Dynamics of the Standard Model (online)",
              "Peskin & Schroeder, An Introduction to Quantum Field Theory",
              "Schwartz, Quantum Field Theory and the Standard Model"],
    "033SL": ["Dei, Fabio (2016) Antropologia culturale. Seconda Edizione. Bologna: Il Mulino.",
              "Remotti, Francesco (2007) “Prima lezione di antropologia”. Bari: Laterza.",
              'Brown Nina, Tubelle de Gonzáles Laura, McIlwright Thomas (2017) "Perspectives: An Open Invitation to '
              'Cultural Anthropology". ED. ASA.',
              'Signorelli A. (2011, 2a edizione) "Antropologia culturale”. Milano: McGraw-Hill'],
    "979SM": ["Introduction to Geophysical Fluid Dynamics - Physical and Numerical Aspects’ by B. Cushman-Roisin "
              "J.-M. Beckers", "Physical Fluid Dynamics' by D. J. Tritton", "Fluid Mechanics’ by P. K. Kundu",
              "Atmospheric and Oceanic Fluid Dynamics’ by G.K. Vallis",
              "Essentials of Atmospheric and Oceanic Dynamics', by G.K. Vallis"],
    "640EC": ["Highway Capacity Manual – Transportation Research Board",
              "Transit Capacity and Quality of Service Manual 3rd Edition- – Transportation Research Board"],
    "288MI": ["Highway Capacity Manual – Transportation Research Board",
              "Transit Capacity and Quality of Service Manual 3rd Edition- – Transportation Research Board"],
    "051SM": ["H. Goldstein, Meccanica Classica", "V. I. Arnold, Metodi matematici della meccanica classica",
              "A. Fasano e S. Marmi, Meccanica analitica",
              "Yung-kuo Lim, Problems and Solutions on Mechanics (Chapter II: Analytical Mechanics)"],
    "972MG": ["A. Fasano, S. Marmi: Analytical Mechanics.", "M.J. Hamilton: Mathematical gauge theory",
              "Ana Cannas da Silva: Lectures on symplectic Geometry.",
              "V. Arnold: {Mathematical Methods of Classical Mechanics."],
    "349MI": ["Morrison and Boyd: Organic Chemistry.", "Campbell: Biochemistry."],
    "432SF": ["Angela Vettese, Gillo Dorfles, Arti Visive, Protagonisti e movimenti, Il Novecento, Bergamo, Ed. Atlas, "
              "(qualsiasi edizione).", "Bruno Munari, Fantasia, Bari, Laterza (qualsiasi edizione).",
              "Cristina Francucci, L’esperienza dell’arte. Laboratori e attività creative per l’infanzia, Ferrara, "
              "Lapis. (qualsiasi edizione)",
              "Eleonora Cannoni, Il disegno dei bambini, Roma, Cannoni (qualsiasi edizione).",
              "P. Ciarcià, M. Dallari, Arte per crescere. Idee, Immagini, Laboratori."],
    "973DF": ["Numerical Python in Astronomy and Astrophysics - A Practical Guide to Astrophysical Problem Solving "
              "(Autori: W. Schmidt and M. Völschow",
              "Think Python, 2nd Edition - How to Think Like a Computer Scientist (Autore: A. B. Downey)",
              "Python Scripting for Computational Science (Autore: H. P. Langtangen)",
              "Parallel Programming with Python (Autore: J. Palach)"],
    "121LM": ["Gabriele De Anna, Chi ha paura dell’autorità?, Milano, Solferino, 2025",
              "Francisco Elías de Tejada, Filosofia del diritto pubblico,Napoli, Jovene, 2022"],
    "472SM": ["Dynamics of atmospheric motion; Dutton, John A.", "Atmospheric thermodynamics; Bohren, Craig F.",
              "Termodinamica; Fermi, Enrico", "An introduction to dynamic meteorology; Holton, James R.",
              "Atmosphere-ocean dynamics; Gill, Adrian E.", "Topographic effects in stratified flows; Baines, Peter G.",
              "Weather analysis; Djuric, Dusan",
              "Atmospheric convection: research and operational forecasting aspects; Giaiotti D, Steinacker R., Styel F.",
              "Atmospheric science : an introductory survey; Wallace, John M.",
              "Fundamentals of physics and chemistry of the atmosphere; Visconti, Guido",
              "Principles of atmospheric physics and chemistry; Goody, Richard",
              "Atmosphere, ocean, and climate dynamics: an introductory text; Marshall, John",
              "Waves in the ocean and atmosphere : introduction to wave dynamics; Pedlosky, Joseph",
              "An introduction to fluid dynamics; Batchelor, George Keith",
              "Atmospheric and oceanic fluid dynamics : fundamental and large-scale circulation; Vallis, Geoffrey K.",
              "Introduction to geophysical fluid dynamics : physical and numerical aspects; Cushman-Roisin, Benoit"],
    "941ME": ["White-Pharoah.Radiologia odontoiatrica. Principi ed interpretazione. Delfino Ed, 2021",
              "Perez & Brady’s Principles and Practice of Radiation Oncology"],
    "1314ME": ["Perez & Brady’s Principles and Practice of Radiation Oncology"],
    "1317ME": ["Principles and Practice of Radiation Oncology Autore: Perez and Brady's"],
    "887ME": ["Ortodonzia Moderna. Proffit.", "Polimeni A. Odontoiatria Pediatrica. Elsevier",
              "Franco Panizon Cari genitori: Piccola guida alla salute del bambino Laterza"],
    "010MG": ["Chimica (Nona Edizione) Whitten – Davis – Peck - Stanley Piccin",
              "Chimica Principi e reazioni (Sesta Edizione) Masterton - Hurley Piccin"],
    "723ME": ["Nyberg et al. Diagnostic imaging of fetal anomalies. Lippincott Williams & Wilkins"],
    "1133ME": ["Human Histology A Stevens J Lowe"],
    "071SP": ["M. Ambrosini, Sociologia delle migrazioni (terza edizione), Il Mulino, Bologna, 2020"],
    "645ME": ["MEDICINA DI LABORATORIO Terza edizione Mc Graw Hill A cura di Giorgio Federici"],
    "502MI": ["Internet e reti, Achille Pattavina",
              "Computer Networking: A Top-Down Approach (6th Edition) 6th Edition, James F. Kurose (Author), Keith W. Ross"],
    "107IN": ["Fred Bell Geologia ambientale Teoria e pratica", "Benedetto De Vivo et al Geochimica ambientale"],
    "989SM": ["S. K. Krane, Introductory Nuclear Physics",
              "B. Povh et al., Particles and Nuclei An introduction to the physical concepts",
              "E. Segrè, Nuclei e Particelle"],
    "771ME": ["Applied Dental Materials di John McCabe (9th edition)",
              "Materiali e Tecnologie Odontostomatologiche (Materiali Dentari), Ariesdue"],
    "1276ME": ["Applied Dental Materials di John McCabe (9th edition)",
               "Materiali e Tecnologie Odontostomatologiche (Materiali Dentari), Ariesdue",
               "Francesco Simionato ''Scienza dei materiali dentari'' vol 1/2"],
    "532SM": ["M. P. do Carmo, Riemannian geometry, Birkhäuser."],
    "589ME": ["ECG Interpretation Made Incredibly Easy! Lippincott & Co.", "Interpretazione dell'ECG, Dale Dubin",
              "ECG Interpretation Made Incredibly Easy! di Lippincott & Co.", "Interpretazione dell'ECG di di Dale Dubin"],
    "069EC": ["Andrea Favretto Dalla Terra alla carta. Elementi di cartografia digitale"],
    "155FA": ["Manuale BLS per operatori sanitari dell'American Heart Association"],
    "583ME": ["Infermieristica transculturale e spiritualità. Pratiche assistenziali centrate sul paziente. Arianna Anzini "
              "Edizione A.I.R.O.P."],
    "636SP": ["I conflitti armati contemporanei. Quali soluzioni, Gorizia, Isig 2008.",
              "Fabio Fossati: Interests and stability or ideologies and order in contemporary world politics, "
              "Cambridge Scholars Publishing, Newcastle, 2017."],
    "984SM": ["Longair. High Energy Astrophysics.",
              "De Angelis - Pimenta. Introduction to Particle and Astroparticle Physics (2nd edition)",
              "Spurio. Probes of Multimessenger Astrophysics"],
    "962ME": ["Gray’s Anatomy", "Fitzgerald – Neuroanatomia con riferimenti funzionali e clinici"],
    "114IN": ["Maurizio Trombetta. CORSO INTRODUTTIVO DI MATEMATICA."],
    "118IN": ["Maurizio Trombetta. CORSO INTRODUTTIVO DI MATEMATICA.",
              "Richard Courant; Herbert Robbins. CHE COS'E' LA MATEMATICA. Bollati Boringhieri."],
    "1232ME": ["ACSM. Linee guida per la valutazione funzionale e la prescrizione dell'esercizio fisico"],
    "654ME": ["Atlante di Urologia AIU: Accademia Italiana Urologia"],
    "925SV": ["Epigenetics, 2015; Cold Spring Harbor Laboratory Press",
              "Epigenetics, 2014; Taylor and Francis Group. Autore: Lyle Armstrong",
              "Introduction to Epigenetics, Learning Materials in Biosciences R. Paro et al., 2021; Springer"],
    "181MI": ["Impianti Ferroviari CIFI", "Railway Operation and Control - Pachl"],
    "004SM": ["Serway, R. A. and Jewett, J. W.: FISICA per scienze ed ingegneria, Vol. I Edises"],
    "135EC": ["Piergiorgio Corbetta, Metodologia e tecniche della ricerca sociale, edizione italiana"],
    "635EC": ["Venier, F.; Trasformazione Digitale e Capacità Organizzativa, EUT"],
    "012FA": ["Ezio Ragozzino, ELEMENTI di FISICA Per studenti di scienze biomediche EdiSES editore"],
    "029FA": ["Organic Chemistry. 10th edition. John McMurry.", "Organic Chemistry. 10th edition. Joihn McMurry.",
              "Chimica Organica. Brown, Ivenson, Anslyn, Foote.",
              "Guida Ragionata allo Svolgimento di Esercizi di Chimica Organica, M.V. D'Auria, O.T. Scafati, "
              "A. Zampella, Loghia Publishing & Research"],
    "593ME": ["Salute e migrazione. Strumenti e risorse nella società multiculturale (Concetta Mirisola)"],
    "275SM": ["“Think Python 2nd Edition”", "How to Think Like a Computer Scientist"],
    "480ME": ["Brown- Biotecnologie Molecolari (Zanichelli)"],
    "543SL": ["Mandrioli-Carratta, Corso di diritto processuale civile, editio minor, vol. I, Nozioni introduttive e "
              "disposizioni generali, Giappichelli, ultima edizione disponibile",
              "P. Tonini, Lineamenti di diritto processuale penale, Giuffrè, ultima edizione disponibile",
              "Codice sistematico di procedura penale, a cura di H. Belluta-M. Gialuz-L. Luparia, editore Giappichelli, "
              "ultima edizione disponibile",
              "Diritto processuale penale. Principi, regole, prassi, a cura di A. Gaito, Utet, ultima edizione disponibile"],
    "516SP": ["Manuale a scelta (consigliato il Sabbatucci-Vidotto), che copra il periodo 1848-1968."],
    "1017ME": ["Albera Rossi Otorinolaringoiatria", "Pignataro Trattato di otorinolaringoiatria"],
    "237SF": ["Costruire indagini statistiche su basi solide. Guida pratica alla rilevazione campionaria e alla "
              "gestione degli errori"],
    "592ME": ["Endovascology. Endovascular Treatment of Vascular Systematic Pathologies",
              "Atlas of Vascular Surgery and Endovascular Therapy"],
    "890SV": ["Marine Microbiology Ecology & Applications Third Edition By Colin B. Munn"],
    "124MI-3": ["Handbook of Bioengineering Ed. Bronzino", "Biomedical Instrumentation Ed. Webster"],
    "949SV": ["William F. Ruddiman. Earth’s Climate - Past and Future, Third Edition",
              "Hugues Goosse et al. Introduction to Climate Dynamics and Climate Modelling"],
    "526SM": ["L.C. Evans, Partial Differential Equations"],
    "1091ME": ["Harrison principi di medicina interna"],
    "910ME": ["Harrison principi di medicina interna"],
    "303SM": ["Understanding Deep learning, J. Prince.", "Statistical mechanics of learning. Van Den Broeck Engels"],
    "435SM": ["Vershynin - High-Dimensional Probability, An Introduction with Applications in Data Science.",
              "Baldi - Stochastic Calculus An Introduction Through Theory and Exercises."],
    "1218ME": ["Fisiologia dell'esercizio. L'essenziale. W. McArdle, F.I. Katch and V.L. Katch, a cura di A. Paoli"],
    "801ME": ["Trattato di Anatomia Umana. Giuseppe Anastasi."],
    "638ME": ["Textbook of Oncofertility Research and Practice: A Multidisciplinary Approach. di T Woodruff"],
    "752ME": ["Harrison's Internal Medicine"],
    "014EC": ["Microeconomia , R. Pindyck & D. Rubinfield"],
    "744ME": ["Genetica e Genomica Strachan T"],
    "945ME": ["Harrison's Principi di Medicina Interna"],
    "739ME": ["Cartella logopedica età evolutiva - modulistica e protocolli per il bilancio logopedico, "
              "Vernero, Gambino, Stefanin, Schindler"],
}


CITAZIONI_SET = {c for lista in CITAZIONI.values() for c in lista}

def _normalizza(campi: list[str]) -> str:
    return re.sub(r"\s+", " ", " ".join(_testo(c) for c in campi)).strip()


def libri_manuali(sy: dict) -> list[dict] | None:
    """Libri di CITAZIONI per questo insegnamento, solo se la citazione è nel testo della scheda.
    None se l'insegnamento non è nella tabella."""
    cits = CITAZIONI.get(str(sy.get("adCod")))
    if cits is None:
        return None
    campi: list[str] = []
    for t in sy.get("testiTotali") or []:
        campi += [t.get(k) or "" for k in ("testi_it", "mod_testi_it")]
    testo = _normalizza(campi)
    libri = []
    for c in cits:
        if c in testo:
            b = _libro(c)
            b["tipo"] = _tipo(c)
            libri.append(b)
    return libri


def libri_units(sy: dict) -> list[dict]:
    """Estrazione comune per UniTS: quella di UniMoRe (per riga, autore e frase), poi quella tollerante."""
    if not isinstance(sy, dict):
        return []
    manuali = libri_manuali(sy)
    if manuali:  # citazioni verificate a mano per questo insegnamento
        return manuali
    if manuali is not None and not CITAZIONI[str(sy.get("adCod"))]:  # elenco vuoto: non ci sono libri
        return []
    return unimore_testi.libri_unimore(sy) or libri_lenient(sy) or libri_blocchi(sy)
