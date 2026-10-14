"""Elenco degli atenei dalle 4 pagine ufficiali del MUR.

Legge data/raw/mur/*.html (salvate dal sito MUR o scaricate da fetch_sources.py)
e scrive database/universita.json. Un ateneo con più sedi (Cattolica, LUMSA,
Link Campus) diventa una sola voce con l'elenco delle sedi e delle regioni,
così nell'onboarding compare in ogni regione in cui ha una sede.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import unicodedata
from datetime import date

ROOT = pathlib.Path(__file__).resolve().parents[2]
RAW = ROOT / "data" / "raw" / "mur"
OUT = ROOT / "database" / "universita.json"

PAGES = {
    "statale": ("universita-statali.html",
                "https://www.mur.gov.it/it/aree-tematiche/universita/le-universita/universita-statali"),
    "non_statale": ("universita-non-statali-riconosciute.html",
                    "https://www.mur.gov.it/it/aree-tematiche/universita/le-universita/universita-non-statali-riconosciute"),
    "ordinamento_speciale": ("istituti-universitari-ordinamento-speciale.html",
                             "https://www.mur.gov.it/it/aree-tematiche/universita/le-universita/istituti-universitari-ordinamento-speciale"),
    "telematica": ("universita-telematiche.html",
                   "https://www.mur.gov.it/it/aree-tematiche/universita/le-universita/universita-telematiche"),
}

REGIONI = [
    "Abruzzo", "Basilicata", "Calabria", "Campania", "Emilia-Romagna", "Friuli-Venezia Giulia",
    "Lazio", "Liguria", "Lombardia", "Marche", "Molise", "Piemonte", "Puglia", "Sardegna",
    "Sicilia", "Toscana", "Trentino-Alto Adige", "Umbria", "Valle d'Aosta", "Veneto",
]

# Nome canonico (chiave) -> riconosce le sedi decentrate dello stesso ateneo.
MULTI_SEDE = {
    "Università Cattolica del Sacro Cuore": "unicatt",
    "LUMSA": "lumsa",
    "Link Campus University": "unilink",
}

# Sigle e id stabili (usati nei file database/corsi/<id>.json). Chiave: frammento del nome MUR.
SIGLE = {
    "dell’Aquila": ("univaq", "UnivAQ"), "Chieti-Pescara": ("unich", "UdA"), "di Teramo": ("unite", "UniTE"),
    "Basilicata": ("unibas", "UniBas"), "Magna Graecia": ("unicz", "UMG"), "Università della Calabria": ("unical", "UniCal"),
    "Mediterranea\"": ("unirc", "UniRC"), "Federico II": ("unina", "UniNA"), "L'Orientale": ("unior", "UniOR"),
    "Parthenope": ("uniparthenope", "Parthenope"), "Sannio": ("unisannio", "UniSannio"),
    "Vanvitelli": ("unicampania", "Vanvitelli"), "di Salerno": ("unisa", "UniSA"), "di Bologna": ("unibo", "UniBo"),
    "di Ferrara": ("unife", "UniFE"), "Modena e Reggio": ("unimore", "UniMoRe"), "di Parma": ("unipr", "UniPR"),
    "di Trieste": ("units", "UniTS"), "di Udine": ("uniud", "UniUD"), "La Sapienza": ("uniroma1", "Sapienza"),
    "Tor Vergata": ("uniroma2", "Tor Vergata"), "Roma Tre": ("uniroma3", "Roma Tre"), "Foro Italico": ("uniroma4", "Foro Italico"),
    "Cassino": ("unicas", "UniCas"), "Tuscia": ("unitus", "UniTus"), "di Genova": ("unige", "UniGe"),
    "Milano “Statale”": ("unimi", "UniMi"), "Bicocca": ("unimib", "Bicocca"), "Politecnico di Milano": ("polimi", "PoliMi"),
    "di Bergamo": ("unibg", "UniBG"), "di Brescia": ("unibs", "UniBS"), "di Pavia": ("unipv", "UniPV"),
    "Insubria": ("uninsubria", "Insubria"), "Politecnica delle Marche": ("univpm", "UnivPM"), "Camerino": ("unicam", "UniCam"),
    "di Macerata": ("unimc", "UniMC"), "Urbino": ("uniurb", "UniUrb"), "Molise": ("unimol", "UniMol"),
    "di Torino": ("unito", "UniTO"), "Politecnico di Torino": ("polito", "PoliTO"), "Piemonte Orientale": ("uniupo", "UPO"),
    "Aldo Moro": ("uniba", "UniBa"), "Politecnico di Bari": ("poliba", "PoliBa"), "di Foggia": ("unifg", "UniFG"),
    "Salento": ("unisalento", "UniSalento"), "di Cagliari": ("unica", "UniCa"), "di Sassari": ("uniss", "UniSS"),
    "di Palermo": ("unipa", "UniPA"), "di Catania": ("unict", "UniCT"), "di Messina": ("unime", "UniME"),
    "di Firenze": ("unifi", "UniFI"), "di Pisa": ("unipi", "UniPi"), "Università degli Studi di Siena": ("unisi", "UniSi"),
    "Stranieri di Siena": ("unistrasi", "UniStraSi"), "di Trento": ("unitn", "UniTN"),
    "Università degli Studi di Perugia": ("unipg", "UniPG"), "Stranieri di Perugia": ("unistrapg", "UniStraPG"),
    "Ca’ Foscari": ("unive", "Ca' Foscari"), "IUAV": ("iuav", "IUAV"), "di Padova": ("unipd", "UniPD"), "di Verona": ("univr", "UniVR"),
    # non statali
    "Dante Alighieri": ("unidarc", "UniDA"), "Link Campus": ("unilink", "Link"), "Suor Orsola": ("unisob", "UniSOB"),
    "Cattolica": ("unicatt", "Cattolica"), "LUISS": ("luiss", "LUISS"), "LUMSA": ("lumsa", "LUMSA"),
    "Saint Camillus": ("unicamillus", "UniCamillus"), "Campus Bio-medico": ("unicampus", "UCBM"),
    "Studi Europea": ("universitaeuropea", "UER"), "Internazionali di Roma": ("unint", "UNINT"),
    "Humanitas": ("hunimed", "Humanitas"), "IULM": ("iulm", "IULM"), "LIUC": ("liuc", "LIUC"),
    "Bocconi": ("unibocconi", "Bocconi"), "Vita-Salute": ("unisr", "UniSR"), "UNINEUROMED": ("unineuromed", "UNINEUROMED"),
    "Gastronomiche": ("unisg", "UNISG"), "LUM_": ("lum", "LUM"), "Kore": ("unikore", "Kore"),
    "Bolzano": ("unibz", "UniBZ"), "Valle d’Aosta": ("univda", "UniVdA"),
    # ordinamento speciale
    "GSSI": ("gssi", "GSSI"), "SSM": ("ssm", "SSM"), "IASA": ("iasa", "IASA"), "SISSA": ("sissa", "SISSA"),
    "CASD": ("casd", "CASD"), "IUSS": ("iuss", "IUSS"), "IMT": ("imt", "IMT"), "SNS": ("sns", "SNS"),
    "Sant’Anna": ("santanna", "Sant'Anna"),
    # telematiche
    "IUL": ("iul", "IUL"), "e-Campus": ("uniecampus", "eCampus"), "Giustino Fortunato": ("unifortunato", "Fortunato"),
    "Guglielmo Marconi": ("unimarconi", "Marconi"), "Uninettuno": ("uninettuno", "Uninettuno"),
    "Leonardo da Vinci": ("unidav", "UniDAV"), "Niccolò Cusano": ("unicusano", "Unicusano"), "Pegaso": ("unipegaso", "Pegaso"),
    "telematica \"San Raffaele\"": ("uniroma5", "San Raffaele Roma"), "UNITELMA": ("unitelma", "Unitelma"),
    "Mercatorum": ("unimercatorum", "Mercatorum"),
}


# Città della sede quando la pagina MUR non la indica nel nome.
CITTA = {
    "univaq": "L'Aquila", "unich": "Chieti e Pescara", "unite": "Teramo", "unicz": "Catanzaro", "unirc": "Reggio Calabria",
    "unisa": "Fisciano (SA)", "unibo": "Bologna", "unife": "Ferrara", "unimore": "Modena e Reggio Emilia", "unipr": "Parma",
    "units": "Trieste", "uniud": "Udine", "uniroma1": "Roma", "uniroma2": "Roma", "uniroma3": "Roma", "uniroma4": "Roma",
    "unicas": "Cassino (FR)", "unige": "Genova", "unimi": "Milano", "unimib": "Milano", "polimi": "Milano",
    "unibg": "Bergamo", "unibs": "Brescia", "unipv": "Pavia", "unimc": "Macerata", "uniurb": "Urbino (PU)",
    "unito": "Torino", "polito": "Torino", "uniba": "Bari", "poliba": "Bari", "unifg": "Foggia", "unica": "Cagliari",
    "uniss": "Sassari", "unipa": "Palermo", "unict": "Catania", "unime": "Messina", "unifi": "Firenze", "unipi": "Pisa",
    "unisi": "Siena", "unistrasi": "Siena", "unitn": "Trento", "unipg": "Perugia", "unistrapg": "Perugia",
    "unive": "Venezia", "unipd": "Padova", "univr": "Verona", "gssi": "L'Aquila",
    "iul": "Firenze", "uniecampus": "Novedrate (CO)", "unifortunato": "Benevento", "unimarconi": "Roma",
    "uninettuno": "Roma", "unidav": "Torrevecchia Teatina (CH)", "unicusano": "Roma", "unipegaso": "Napoli",
    "uniroma5": "Roma", "unitelma": "Roma", "unimercatorum": "Roma",
}


def norm_regione(s: str) -> str | None:
    k = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    k = re.sub(r"[^a-z]", "", k)
    for r in REGIONI:
        if re.sub(r"[^a-z]", "", r.lower().replace("'", "")) == k:
            return r
    return None


def clean(s: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()


def virgolette(s: str) -> str:
    """Virgolette tipografiche uniformi nei nomi: la pagina MUR mescola " “ ” («"Amedeo
    Avogadro”», «“Foro Italico"»); a coppie diventano “…”. Con un numero dispari di
    virgolette il nome resta com'è."""
    pos = [m.start() for m in re.finditer(r'["“”]', s)]
    if not pos or len(pos) % 2:
        return s
    out = list(s)
    for k, p in enumerate(pos):
        out[p] = "“" if k % 2 == 0 else "”"
    return "".join(out)


def tokens(page: str):
    """Sequenza di ('regione', nome) e ('ateneo', nome, url) nell'ordine della pagina."""
    main = re.search(r"<main.*?</main>", page, re.S).group(0)
    main = main.split("Naviga la sezione")[0]
    pat = re.compile(
        r'field--name-field-titolo-paragrafo[^>]*>(?P<acc>[^<]+)<'  # titolo accordion (statali)
        r'|<strong>(?P<strong>.*?)</strong>'
        r'|<a\s[^>]*href="(?P<href>[^"]+)"[^>]*>(?P<a>.*?)</a>', re.S)
    for m in pat.finditer(main):
        title = m.group("acc") or m.group("strong")
        if title is not None:
            r = norm_regione(clean(title))
            if r:
                yield ("regione", r)
            continue
        name = clean(m.group("a"))
        href = m.group("href")
        if "mur.gov.it" in href or not name or name.startswith("Decreto") or name == "ANVUR":
            continue
        yield ("ateneo", name, href)


def split_name(name: str):
    """'Università X – Città' -> ('Università X', 'Città'); gestisce 'sede di', 'sede decentrata di'."""
    parts = re.split(r"\s+[–-]\s+", name)
    base = " – ".join(parts[:-1]).strip() if len(parts) > 1 else name.strip()
    citta = parts[-1].strip() if len(parts) > 1 else None
    if citta:
        citta = re.sub(r"^(sede decentrata di|sede di|sedi di)\s+", "", citta).strip()
        citta = re.sub(r"\s*–\s*sito specifico in costruzione$", "", citta)
    base = base.replace("LUISS_", "LUISS – ").replace("LUMSA_", "LUMSA – ").replace("IULM_", "IULM – ") \
        .replace("LIUC_", "LIUC – ").replace("LUM_", "LUM – ")
    return base, citta


def ident(base: str):
    """Sigla dal nome senza città: vince il frammento più lungo (es. «Politecnico di Torino» su «di Torino»)."""
    hits = [(len(frag), v) for frag, v in SIGLE.items() if frag in base]
    if not hits:
        raise SystemExit(f"Sigla mancante per: {base}")
    return max(hits)[1]


def build():
    out: dict[str, dict] = {}
    for tipo, (fname, url) in PAGES.items():
        page = (RAW / fname).read_text(encoding="utf-8", errors="replace")
        updated = re.search(r"Pagina aggiornata (?:il |l’)([^)]+)\)", page)
        regione = None
        for t in tokens(page):
            if t[0] == "regione":
                regione = t[1]
                continue
            _, raw_name, href = t
            base, citta = split_name(raw_name)
            uid, sigla = ident(base.replace("LUM – ", "LUM_"))
            citta = citta or CITTA.get(uid)
            entry = out.setdefault(uid, {
                "id": uid, "nome": virgolette(base), "sigla": sigla, "tipo": tipo, "regioni": [], "sedi": [],
                "sito": href, "fonte": {"url": url, "pagina_aggiornata": updated.group(1) if updated else None},
            })
            sede = {"regione": regione if tipo != "telematica" else None, "citta": citta, "sito": href,
                    "nome_mur": raw_name}
            entry["sedi"].append(sede)
            if regione and regione not in entry["regioni"]:
                entry["regioni"].append(regione)
            # la sede centrale (senza "decentrata") fissa nome e sito principali
            if "decentrata" not in raw_name and "sede di" not in raw_name and "sedi di" not in raw_name:
                entry["nome"], entry["sito"] = virgolette(base), href
    unis = sorted(out.values(), key=lambda u: (u["tipo"], u["nome"].lower()))
    data = {
        "schema": 1,
        "generato_il": date.today().isoformat(),
        "fonti": [p[1] for p in PAGES.values()],
        "conteggi": {t: sum(1 for u in unis if u["tipo"] == t) for t in PAGES},
        "regioni": REGIONI,
        "universita": unis,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(data["conteggi"]))


if __name__ == "__main__":
    build()
