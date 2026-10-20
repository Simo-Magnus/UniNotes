"""Voci dei piani didattici di Milano-Bicocca che le categorie Moodle degli insegnamenti non hanno.

Le categorie Moodle ("A.A. 2026-2027" → "N° anno") elencano solo gli insegnamenti con un corso e-learning:
mancano idoneità di lingua e di informatica, crediti a scelta dello studente, altre conoscenze utili per il
mondo del lavoro, stage e tirocini, prova finale e tesi, e per le lauree magistrali l'intero 2° anno (le
categorie hanno solo il «1° anno»). Quelle voci stanno nei regolamenti didattici e nei manifesti annuali degli
studi che i corsi di studio pubblicano nelle pagine del corso (cartelle «Regolamenti didattici», «Manifesti
degli studi» di elearning.unimib.it, aperte agli ospiti).

`unimib_piani.json` ha, per ogni corso del database e anno di corso, la coorte il cui piano si applica
nel 2026/27 (l'anno N è frequentato dalla coorte immatricolata N-1 anni prima; se il regolamento di quella coorte
non è pubblicato o il corso non ha ancora quell'anno, la coorte più vicina, dichiarata nel campo `coorte`), il
regolamento (`fonte`) e le righe `[tipo, nome, CFU(, percorso)]` del piano:

- `e` voce obbligatoria;
- `s` crediti a scelta dello studente (attività di libera scelta);
- `o` alternativa di un gruppo «a scelta tra»: da sola non è obbligatoria.

Se `completo` il piano elenca tutti gli insegnamenti dell'anno (professioni sanitarie, Medicina e Chirurgia):
gli insegnamenti Moodle di al più 3 CFU che il piano non ha sono corsi elettivi, cioè a scelta.
Il file è generato leggendo i regolamenti (elenchi «NOME, N CFU, tipo» con un parser; gli altri a mano, con la
verifica che nome e CFU compaiano nel PDF): non si inventa nulla che il regolamento non dica.
"""
from __future__ import annotations

import difflib
import json
import pathlib
import re
import unicodedata

PIANI: dict = json.loads((pathlib.Path(__file__).with_name("unimib_piani.json")).read_text(encoding="utf-8"))

_ROMANI = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5"}


def _nn(s: str) -> str:
    """Nome normalizzato per abbinare le voci del piano agli insegnamenti Moodle: senza parentesi
    («Anatomia e istologia umana (I parte)»), accenti, punteggiatura, con i numeri romani finali in cifre."""
    s = re.sub(r"\([^)]*\)", "", s or "")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    s = " ".join(_ROMANI.get(w, w) if i else w for i, w in enumerate(s.split()))
    return re.sub(r"\ba livello b2\b", "", s).strip()


def _trova(per_nome: dict, k: str, cfu=None, usate: frozenset | set = frozenset()) -> str | None:
    """Chiave della riga Moodle che corrisponde alla voce del piano: stesso nome, nome che ne è il prefisso, oppure
    nome quasi uguale (refusi e varianti, es. «Fisiopatologia generale e ginecologica» / «…e Ginecologia») con
    gli stessi CFU e non già abbinato a un'altra voce."""
    if k in per_nome:
        return k
    c = [x for x in per_nome if x.startswith(k + " ") or k.startswith(x + " ")]
    if len(c) == 1:
        return c[0]
    simili = [x for x in per_nome if x not in usate and difflib.SequenceMatcher(None, x, k).ratio() >= 0.88
              and (cfu is None or all(i.get("cfu") in (None, cfu) for i in per_nome[x]))]
    return simili[0] if len(simili) == 1 else None


def integra(corso: dict, oggi: str, log=print) -> dict:
    """Aggiunge ai `insegnamenti` del corso (id del database) le voci del suo piano e segna a scelta le alternative.
    Restituisce i numeri: voci aggiunte, righe Moodle segnate a scelta."""
    piano_corso = PIANI.get(corso["id"])
    stat = {"aggiunte": 0, "a_scelta": 0}
    if not piano_corso:
        return stat
    for k_str, piano in sorted(piano_corso.items()):
        k = int(k_str)
        dell_anno = [i for i in corso["insegnamenti"] if i.get("anno") == k]
        per_nome: dict[str, list[dict]] = {}
        for i in dell_anno:
            per_nome.setdefault(_nn(i["nome"]), []).append(i)
        usate: set[str] = set()
        for riga in piano["righe"]:
            tipo, nome, cfu = riga[0], riga[1], riga[2]
            percorso = riga[3] if len(riga) > 3 else None
            chiave = _trova(per_nome, _nn(nome), cfu, usate)
            if chiave:
                usate.add(chiave)
                for i in per_nome[chiave]:
                    if tipo in ("s", "o") and i.get("obbligatorio") is not False:
                        i["obbligatorio"] = False
                        stat["a_scelta"] += 1
                    elif tipo == "e" and i.get("obbligatorio") is False:
                        i["obbligatorio"] = None  # il piano la dà obbligatoria (anche se il corso Moodle è elencato in due anni)
                    if i.get("cfu") is None:
                        i["cfu"] = cfu
                continue
            nuova = {"codice": None, "nome": nome, "anno": k, "periodo": None, "cfu": cfu, "ssd": None,
                     "obbligatorio": False if tipo in ("s", "o") else None, "curriculum": percorso,
                     "docenti": [], "url": piano["fonte"], "libri": [], "esami": [], "fonte": piano["fonte"],
                     "verificato_il": oggi, "stato_libri": "nessun_libro"}
            corso["insegnamenti"].append(nuova)
            per_nome.setdefault(_nn(nome), []).append(nuova)
            usate.add(_nn(nome))
            stat["aggiunte"] += 1
        if piano.get("completo"):
            for chiave, righe in per_nome.items():
                if chiave in usate:
                    continue
                for i in righe:
                    if i.get("codice") and (i.get("cfu") or 0) <= 3 and i.get("obbligatorio") is not False:
                        i["obbligatorio"] = False  # corso elettivo: non è nel piano, vale per i crediti a scelta
                        stat["a_scelta"] += 1
    return stat
