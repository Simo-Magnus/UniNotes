# Atenei e dati non reperiti

Stato al 10/10/2026 (branch `claude/youthful-wright-15peg9`). Sono elencati gli atenei per cui il
database non ha, in tutto o in parte, insegnamenti, libri o appelli, con il motivo verificato.
Nessun dato è stato inventato: dove la fonte pubblica manca o è bloccata, il campo resta vuoto
(`stato_libri` / `stato_esami` = `da_aggiungere`). Le protezioni dei siti (WAF, verifiche anti-bot,
login) non sono state aggirate.

I numeri sono quelli di `database/meta.json`.

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
| Politecnico di Milano | 5.740 | Le date d'esame sono solo nei Servizi online, con login |
| Università di Pisa | 6.858 | La bacheca appelli Esse3 risponde 403 (accesso negato) |
| Università di Palermo | 6.358 | Sito dietro firewall (Barracuda WAF): bloccati appelli e syllabus |
| Università Cattolica | 4.775 | Bacheca Esse3 pubblica raggiungibile ma vuota |
| LUISS | 1.148 | Bacheca Esse3 pubblica vuota |
| Politecnico di Bari | 984 | Bacheca Esse3 pubblica vuota |
| Kore di Enna | 991 | Bacheca Esse3 pubblica vuota |
| IUAV Venezia | 724 | Bacheca Esse3 pubblica vuota |
| IULM | 658 | Bacheca Esse3 con 3 date, nessuna con codici del catalogo |
| Roma Tre | 1.056 | Il portale pubblico GOMP non pubblica gli appelli (verificato sulle schede docente) |
| Roma Tor Vergata | 1.050 | Come Roma Tre (GOMP) |
| Tuscia | 494 | Come Roma Tre (GOMP) |
| UniCamillus | 82 | GOMP, appelli non pubblicati |
| Giustino Fortunato (telematica) | 94 | GOMP, appelli non pubblicati |
| IUL (telematica) | 48 | GOMP, appelli non pubblicati |
| Libera Università di Bolzano | 867 | Date d'esame non pubbliche |
| Campus Bio-Medico | 804 | Bacheca Esse3 con 68 date, codici diversi da quelli del catalogo |
| UNITELMA Sapienza | 102 | Bacheca Esse3 con 221 date, codici diversi da quelli del catalogo |
| UNINT | 726 | Nessuna bacheca appelli pubblica individuata |
| Foro Italico (Roma 4) | 375 | Nessuna bacheca appelli pubblica individuata |
| Humanitas University | 135 | Nessuna bacheca appelli pubblica individuata |
| Niccolò Cusano (telematica) | 492 | Appelli solo nell'area studenti |
| Universitas Mercatorum (telematica) | 436 | Appelli solo nell'area studenti |
| Pegaso (telematica) | 371 | Appelli solo nell'area studenti |
| San Raffaele Roma (telematica) | 424 | Appelli solo nell'area studenti |
| Università Europea di Roma | 192 | Nessuna bacheca appelli pubblica individuata |
| Dante Alighieri (Reggio Calabria) | 75 | Nessuna bacheca appelli pubblica individuata |
| Neuromed | 74 | Nessuna bacheca appelli pubblica individuata |
| UNINETTUNO (telematica) | 19 | Bacheca Esse3 vuota; sito dietro verifica anti-bot (vedi sotto) |

Appelli presenti ma parziali: Università di Genova (solo i 10 corsi su 135 che hanno già pubblicato
il calendario 2026/27, segnato "calendario non approvato"), eCampus (195 date: la bacheca usa
codici diversi dal catalogo e si aggancia solo per nome con docente in comune).

## 3. Atenei senza libri di testo

| Ateneo | Motivo |
|---|---|
| Università di Palermo | Syllabus dietro firewall (Barracuda WAF) |
| eCampus | I syllabus del Course Catalogue non riportano testi |
| Niccolò Cusano | Le schede degli insegnamenti non riportano testi |
| Pegaso | I programmi pubblicati non hanno la sezione testi (2 libri in tutto) |
| Guglielmo Marconi | Il piano viene dai regolamenti didattici (PDF), che non hanno testi |
| Stranieri di Siena | Il piano viene dalle guide didattiche (PDF), senza testi |
| Stranieri di Perugia | Nessun testo nelle fonti pubbliche consultate |
| Leonardo da Vinci (telematica) | Syllabus pubblici fermi al 2023: testi scartati perché non attendibili |
| Humanitas, Università Europea, Dante Alighieri, Neuromed, IUL | Nessun testo nelle pagine pubbliche degli insegnamenti |
| UNINETTUNO | Programmi non raggiungibili (verifica anti-bot) |

## 4. Atenei con insegnamenti solo per una parte dei corsi

| Ateneo | Corsi con insegnamenti / corsi | Motivo |
|---|---:|---|
| UNINETTUNO | 1 / 15 | Il sito risponde con una verifica anti-bot (HTTP 202 vuoto) a intermittenza; non aggirata |
| UNITELMA Sapienza | 3 / 11 | Il Course Catalogue pubblica solo 2 corsi |
| Vanvitelli (Campania) | 44 / 92 | Piani non trovati sul sito per gli altri corsi |
| Magna Græcia (Catanzaro) | 16 / 41 | Il Course Catalogue non ha i piani degli altri corsi |
| Humanitas | 6 / 15 | Piani non trovati sul sito per gli altri corsi |
| Università Europea | 6 / 10 | Piani non trovati sul sito per gli altri corsi |
| Stranieri di Perugia | 3 / 7 | Il Course Catalogue non ha i piani degli altri corsi |
| LUM | 7 / 13 | Piani non trovati sul sito per gli altri corsi |
| LIUC | 5 / 7 | Il Course Catalogue non ha i piani degli altri corsi |
| eCampus, Link, Marconi, UPO, Parthenope, Calabria | 65–80% | Corsi senza piano pubblicato o non associabili con certezza |

Atenei GOMP (Roma Tre, Tor Vergata, Tuscia, Cassino, UniCamillus, Fortunato, IUL): l'API pubblica
espone solo il primo anno della coorte, quindi gli insegnamenti degli anni successivi mancano.

UniCT: CFU e periodo non sono pubblicati nelle pagine dei corsi (solo 2 dipartimenti su 17 hanno
un PDF dell'offerta programmata).

## 5. In corso

- **Politecnico di Milano**: aggiornamento di insegnamenti e libri in esecuzione (non ancora integrato).

## Come aggiornare questo elenco

Dopo ogni ricostruzione (`build_db.py --solo …`) i conteggi per ateneo sono in `database/meta.json`;
i controlli di qualità con `python tools/db_builder/verifica_db.py` e `verifica_fonti.py`.
