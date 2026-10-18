# Atenei e dati non reperiti

Stato al 18/10/2026, con i numeri del database versione 2026.10.17 (`database/meta.json`). Sono
elencati gli atenei per cui il database non ha, in tutto o in parte, insegnamenti, libri o appelli,
con il motivo verificato quando i dati sono stati raccolti. Nessun dato è stato inventato: dove la
fonte pubblica manca o è bloccata, il campo resta vuoto (`stato_libri` / `stato_esami` =
`da_aggiungere`). Le protezioni dei siti (WAF, verifiche anti-bot, login) non sono state aggirate.

## 1. Atenei senza alcun dato

Sono scuole a ordinamento speciale: il database parte dai corsi di laurea del catalogo Universitaly,
dove queste scuole non hanno corsi (offrono dottorati e/o corsi ordinari interni, non previsti dal formato).

| Ateneo | Motivo |
|---|---|
| CASD – Centro Alti Studi per la Difesa | Nessun corso di laurea nel catalogo Universitaly |
| GSSI – Gran Sasso Science Institute | Nessun corso di laurea nel catalogo Universitaly (dottorati) |
| IASA – Institute of Advanced Science for Agriculture | Nessun corso di laurea nel catalogo Universitaly |
| IMT Alti Studi Lucca | Nessun corso di laurea nel catalogo Universitaly (dottorati) |
| IUSS Pavia | Nessun corso di laurea nel catalogo Universitaly |
| Scuola Superiore Sant'Anna | Nessun corso di laurea nel catalogo Universitaly |
| SISSA | Nessun corso di laurea nel catalogo Universitaly |
| Scuola Normale Superiore | Nessun corso di laurea nel catalogo Universitaly |
| Scuola Superiore Meridionale | Nessun corso di laurea nel catalogo Universitaly |

## 2. Atenei senza appelli d'esame

| Ateneo | Insegnamenti | Motivo |
|---|---:|---|
| Università di Palermo | 6.992 | Sito dietro firewall (Barracuda WAF): bloccati appelli e syllabus |
| LUISS | 1.124 | Bacheca Esse3 pubblica vuota |
| Kore di Enna | 1.007 | Bacheca Esse3 pubblica vuota |
| IUAV Venezia | 622 | Bacheca Esse3 pubblica vuota |
| IULM | 656 | Bacheca Esse3 con 3 date, nessuna con codici del catalogo |
| Roma Tre | 1.053 | Il portale pubblico GOMP non pubblica gli appelli (verificato sulle schede docente) |
| Tuscia | 482 | Come Roma Tre (GOMP) |
| UniCamillus | 158 | GOMP, appelli non pubblicati |
| Giustino Fortunato (telematica) | 94 | GOMP, appelli non pubblicati |
| IUL (telematica) | 48 | GOMP, appelli non pubblicati |
| Libera Università di Bolzano | 884 | Date d'esame non pubbliche |
| Campus Bio-Medico | 764 | Bacheca Esse3 con 68 date, codici diversi da quelli del catalogo |
| UNINT | 715 | Nessuna bacheca appelli pubblica individuata |
| Foro Italico (Roma 4) | 394 | Nessuna bacheca appelli pubblica individuata |
| Humanitas University | 372 | Nessuna bacheca appelli pubblica individuata |
| Universitas Mercatorum (telematica) | 476 | Appelli solo nell'area studenti |
| Pegaso (telematica) | 405 | Appelli solo nell'area studenti |
| San Raffaele Roma (telematica) | 424 | Appelli solo nell'area studenti |
| Università Europea di Roma | 192 | Nessuna bacheca appelli pubblica individuata |
| Neuromed | 74 | Nessuna bacheca appelli pubblica individuata |
| UNINETTUNO (telematica) | 19 | Bacheca Esse3 vuota; sito dietro verifica anti-bot (vedi sotto) |

Appelli presenti ma da agganciare per nome: eCampus (la bacheca usa codici diversi dal catalogo e le
date si agganciano solo per nome con docente in comune).

## 3. Atenei senza libri di testo

| Ateneo | Motivo |
|---|---|
| Università di Palermo | Syllabus dietro firewall (Barracuda WAF) |
| eCampus | I syllabus del Course Catalogue non riportano testi |
| Niccolò Cusano | Le schede degli insegnamenti non riportano testi |
| Pegaso | I programmi pubblicati non hanno la sezione testi |
| Guglielmo Marconi | Il piano viene dai regolamenti didattici (PDF), che non hanno testi |
| Stranieri di Siena | Il piano viene dalle guide didattiche (PDF), senza testi |
| Leonardo da Vinci (telematica) | Syllabus pubblici fermi al 2023: testi scartati perché non attendibili |
| Università Europea, Dante Alighieri, Neuromed, IUL | Nessun testo nelle pagine pubbliche degli insegnamenti |
| UNINETTUNO | Programmi non raggiungibili (verifica anti-bot) |

## 4. Atenei con insegnamenti solo per una parte dei corsi

Corsi di studio con almeno un insegnamento sul totale (dai file `database/corsi/<ateneo>.json`).

| Ateneo | Corsi con insegnamenti / corsi | Motivo |
|---|---:|---|
| UNINETTUNO | 1 / 15 | Il sito risponde con una verifica anti-bot (HTTP 202 vuoto) a intermittenza; non aggirata |
| Università Europea | 6 / 10 | Piani non trovati sul sito per gli altri corsi |
| Neuromed | 2 / 3 | — |
| eCampus | 26 / 38 | Corsi senza piano pubblicato o non associabili con certezza |
| Link | 40 / 57 | Corsi senza piano pubblicato o non associabili con certezza |
| San Raffaele Milano | 22 / 27 | — |
| Guglielmo Marconi | 17 / 20 | Corsi senza piano pubblicato o non associabili con certezza |
| Stranieri di Siena | 7 / 8 | — |
| Suor Orsola Benincasa | 16 / 18 | — |
| Politecnico di Bari | 36 / 40 | — |
| LUM | 12 / 13 | Piani non trovati sul sito per gli altri corsi |
| Parthenope | 36 / 39 | Corsi senza piano pubblicato o non associabili con certezza |
| Messina | 107 / 113 | — |
| IUAV Venezia | 17 / 18 | — |

Pochi corsi senza insegnamenti anche a Bologna (1), Palermo (1), Ca' Foscari (1), Molise (1), Magna
Græcia (1), Parma (2) e Salento (3). «—»: motivo non ancora verificato.

Atenei GOMP (Roma Tre, Tor Vergata, Tuscia, Cassino, UniCamillus, Fortunato, IUL): l'API pubblica
espone solo il primo anno della coorte, quindi gli insegnamenti degli anni successivi possono
mancare (verificato al 10/10/2026).

UniCT: CFU e periodo non sono pubblicati nelle pagine dei corsi (solo 2 dipartimenti su 17 hanno
un PDF dell'offerta programmata).

## Come aggiornare questo elenco

Dopo ogni ricostruzione (`build_db.py --solo …`) i conteggi per ateneo sono in `database/meta.json`;
i controlli di qualità con `python tools/db_builder/verifica_db.py` e `verifica_fonti.py`.
