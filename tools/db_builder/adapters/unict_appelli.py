"""Appelli d'esame dell'Università di Catania dai siti dei dipartimenti.

La pagina "Calendario esami" di ogni corso (`www.<dip>.unict.it/corsi/<classe>/esami`) ha il
menu dell'anno accademico (`?aa=<id>`) e le sessioni (`?sessione=<n>&aa=<id>`); la tabella
elenca per anno di corso: [codice,] insegnamento, docente e le date ("22/01/2027 10:00",
a volte con l'aula). Non tutti i dipartimenti aggiornano il menu, per cui si leggono l'a.a.
corrente e il precedente e si tengono solo le date future. Senza codice l'insegnamento si
riconosce dal nome, solo se unico nel corso.
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import json
import pathlib
import re
import time
import unicodedata

from .unibo import Client, _testo

ROOT = pathlib.Path(__file__).resolve().parents[3]
DATA = re.compile(r"(\d{2})/(\d{2})/(\d{4})(?:\s+(\d{1,2})[:.](\d{2}))?\s*([^\d][^\n]*?)?(?=\s*\d{2}/\d{2}/\d{4}|$)")


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", (s or "").replace("’", "'")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def leggi_tabella(s: str, fonte: str) -> list[tuple[str | None, str, str | None, list[dict]]]:
    """[(codice, nome, docente, [esame, …])] di una pagina di sessione."""
    out = []
    for tab in re.findall(r"<table.*?</table>", s, re.S):
        righe = re.findall(r"<tr.*?</tr>", tab, re.S)
        if not righe:
            continue
        testa = [_testo(c).lower() for c in re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", righe[0], re.S)]
        if not any("insegnamento" in h for h in testa):
            continue
        cod_col = testa[0].startswith("cod")
        i_ins = next(i for i, h in enumerate(testa) if "insegnamento" in h)
        i_doc = next((i for i, h in enumerate(testa) if "docent" in h), None)
        n_meta = max(i_ins, i_doc if i_doc is not None else -1) + 1
        for tr in righe[1:]:
            c = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
            if len(c) <= n_meta:
                continue
            docente = _testo(c[i_doc]) or None if i_doc is not None else None
            esami = []
            for cella in c[n_meta:]:
                t = _testo(re.sub(r"<br\s*/?>", " ", cella))
                for g, m, a, hh, mm, resto in DATA.findall(t):
                    resto = (resto or "").strip(" -,;") or None
                    nota = resto if resto and re.search(r"(?i)riservat|fuori corso|studenti|solo |esonero|prova", resto) else None
                    esami.append({"tipo": "prova_in_itinere" if nota and re.search(r"(?i)itinere|esonero", nota) else "appello",
                                  "titolo": None, "data": f"{a}-{m}-{g}",
                                  "ora": f"{int(hh):02d}:{mm}" if hh else None,
                                  "luogo": None if nota else resto, "modalita": None,
                                  "iscrizioni_dal": None, "iscrizioni_al": None,
                                  "docenti": docente, "note": nota, "fonte": fonte})
            if esami:
                out.append((_testo(c[0]) if cod_col else None, _testo(c[i_ins]), docente, esami))
    return out


def fetch_appelli(uid: str = "unict", corsi: list[dict] | None = None, anno: int | None = None,
                  log=print) -> dict[str, list[dict]]:
    """{codice insegnamento: [esame, …]} con le date future dei calendari dei corsi."""
    anno = anno or (time.localtime().tm_year if time.localtime().tm_mon >= 9 else time.localtime().tm_year - 1)
    oggi = time.strftime("%Y-%m-%d")
    if corsi is None:
        corsi = json.loads((ROOT / "database" / "corsi" / f"{uid}.json").read_text(encoding="utf-8"))["corsi"]
    c = Client(rate=3.0)

    def corso(x: dict) -> dict[str, list[dict]]:
        m = re.match(r"https?://(www\.\w+\.unict\.it/corsi/[\w-]+)", x.get("url_catalogo") or x.get("url") or "")
        ins = x.get("insegnamenti") or []
        if not m or not ins:
            return {}
        base = "https://" + m.group(1) + "/esami"
        r = c.get(base)
        if not r:
            return {}
        opz = dict((_testo(t), v) for v, t in re.findall(r'<option value="(\d+)"[^>]*>(.*?)</option>', r.text))
        aa = [opz[k] for k in (f"{anno}/{anno + 1}", f"{anno - 1}/{anno}") if k in opz]
        pagine = set()
        for a in aa:
            pagine.add(f"{base}?sessione=1&aa={a}")
            r1 = c.get(f"{base}?sessione=1&aa={a}")
            for h in re.findall(r'href="([^"]*/esami\?sessione=\d+&(?:amp;)?aa=' + a + r')"', r1.text if r1 else ""):
                pagine.add("https://" + m.group(1).split("/")[0] + html.unescape(h) if h.startswith("/") else html.unescape(h))
        per_cod = {i["codice"]: i["codice"] for i in ins if i.get("codice")}
        per_nome: dict[str, set[str]] = {}
        for i in ins:
            if i.get("codice"):
                per_nome.setdefault(_norm(i["nome"]), set()).add(i["codice"])
        out: dict[str, dict[tuple, dict]] = {}
        for p in sorted(pagine):
            rp = c.get(p)
            for cod, nome, _doc, esami in leggi_tabella(rp.text if rp else "", p):
                k = per_cod.get(cod) if cod else None
                if not k and len(per_nome.get(_norm(nome), ())) == 1:
                    k = next(iter(per_nome[_norm(nome)]))
                if not k:
                    continue
                for e in esami:
                    if e["data"] >= oggi:
                        out.setdefault(k, {}).setdefault((e["data"], e["ora"], e["docenti"]), e)
        return {k: list(v.values()) for k, v in out.items()}

    res: dict[str, dict[tuple, dict]] = {}
    with cf.ThreadPoolExecutor(3) as ex:
        for d in ex.map(corso, corsi):
            for k, lst in d.items():
                for e in lst:  # stessa data per più canali/docenti: un appello con tutti i docenti
                    v = res.setdefault(k, {}).setdefault((e["data"], e["ora"]), dict(e))
                    if e["docenti"] and e["docenti"] not in (v["docenti"] or "").split(", "):
                        v["docenti"] = ", ".join(x for x in (v["docenti"], e["docenti"]) if x)
    fin = {k: sorted(v.values(), key=lambda e: (e["data"], e["ora"] or "")) for k, v in res.items()}
    log(f"[{uid}] appelli: {sum(len(v) for v in fin.values())} date future per {len(fin)} insegnamenti; "
        f"richieste: {c.requests}")
    return fin
