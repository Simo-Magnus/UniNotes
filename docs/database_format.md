# Database pubblico degli atenei (formato v1)

Cartella `database/` del repository. Contiene solo **dati pubblici** (nessun dato
personale). L'app lo legge in due modi:

1. **Incluso nell'app** (asset `app/assets/database/`, circa 1 MB): solo i file
   comuni. `universita.json` e `indice_corsi.json` servono all'onboarding anche
   senza internet; con loro `meta.json` e `corsi_sostituiti.json`. Li copia
   `tools/db_builder/sync_assets.py`, che le build di GitHub Actions eseguono
   senza opzioni.
2. **Scaricato solo per il corso scelto** dal repository:
   `<base>/per_corso/<ateneo>/<corso>.json` (il corso di laurea con tutti gli
   anni, tutti i percorsi, libri, appelli e i moduli di studio dei suoi
   insegnamenti) e `<base>/sessioni/<ateneo>.json` (calendario delle sessioni
   dell'ateneo), quando lo studente sceglie ateneo e corso (onboarding o
   *Cambia corso di laurea*) e a ogni "Aggiorna database". Prima del file del
   corso l'app legge `<base>/per_corso/<ateneo>/indice.json` (pochi KB) per
   sapere se il corso c'è e se è cambiato. I file si salvano nella cartella di
   supporto dell'app (`database_cache/`), da cui l'app li legge anche offline;
   cambiando corso o ateneo quelli del precedente si eliminano (e anche i file
   per ateneo `corsi/` e `moduli/` delle versioni precedenti dell'app). Il file
   di un corso pesa da pochi KB a circa 1,4 MB; il trasferimento è compresso con
   gzip (HttpClient lo decomprime da solo). Durante il download l'app mostra
   file in corso e kilobyte ricevuti. Nell'onboarding non parte nulla da solo
   finché lo studente non ha scelto ateneo, corso e anno. L'elenco dei percorsi
   (curricula, orientamenti) sta solo nel file del corso, non nell'indice
   leggero incluso nell'app: scelto l'anno, l'app scarica il file del corso
   (pochi KB o circa 1 MB) e, se il corso ha più percorsi, mostra il passo
   «Quale percorso segui?»; con un solo percorso il passo si salta da solo.
   Poi, al tocco su «Scarica il piano di studi», si scaricano le sessioni e si
   importa il piano: il file del corso è già sul dispositivo e non si riscarica
   (un solo download). Lo stesso vale per «Cambia corso». I file arrivano a pezzi in un file temporaneo
   (`<corso>.json.part`), si controllano (in un isolate separato se superano
   512 KB) e sostituiscono la copia precedente con una rinomina: un download
   interrotto o un file non valido lasciano intatta la copia salvata, una copia
   illeggibile si elimina e si riscarica. Download dello stesso corso chiesti
   insieme (doppio tocco, ritorno al riepilogo) condividono lo stesso download.
   `<base>` predefinito:
   `https://raw.githubusercontent.com/Simo-Magnus/UniNotes/main/database`
   (modificabile in *Impostazioni → Il mio percorso*).

Aggiornamenti: all'avvio l'app confronta `meta.json.versione` con la versione
importata e propone "Aggiorna database", che riscarica solo i file del proprio
corso e solo se cambiati: il file del corso se la sua impronta in
`per_corso/<ateneo>/indice.json` è diversa da quella salvata (l'indice si legge
solo se è cambiato il suo `sha256_per_corso` in `meta.json`), le sessioni se è
cambiata la `versione`. Un file che risponde 404 (es. un ateneo senza
calendario delle sessioni) si annota e non si richiede di nuovo fino alla
versione successiva. Senza rete restano le copie salvate; se mancano anche
quelle l'app mostra «Serve una connessione per scaricare i dati del tuo corso»
con *Riprova*, e il resto dell'app (corsi aggiunti a mano, appunti,
registratore) funziona comunque. Lo stesso controllo vale ovunque si scarichi o
si aggiorni il database (onboarding, *Aggiorna database*, nuovo anno
accademico, nuova versione, avvio con i dati del corso mancanti:
`aggiornaDatabase` in `app/lib/widgets/catalog_download.dart`): se il sistema non
vede nessuna rete, o il database non risponde e il piano si rilegge dalla copia
salvata, compare «Serve una connessione a internet per aggiornare il database»
con *Riprova*, invece di un falso «Piano aggiornato».

I file per ateneo `corsi/<ateneo>.json` e `moduli/<ateneo>.json` restano nel
repository: sono la fonte dei file per corso e li usano le versioni precedenti
dell'app.

Regole generali:

- Testi in italiano, UTF-8, JSON con chiavi in italiano senza accenti.
- Date ISO 8601 (`"2027-01-20"`), ore `"HH:MM"` (Europe/Rome).
- Un campo sconosciuto è `null` (mai inventato). Ciò che manca ha
  `"stato": "da_aggiungere"`.
- Ogni elemento ha un `id` stabile tra un anno e l'altro (slug ASCII minuscolo,
  separatore `-`, prefissato dall'id del livello superiore).
- `fonte` = URL (o descrizione) da cui viene il dato; `verificato_il` = data
  dell'ultima verifica.

## `meta.json`

```jsonc
{
  "schema": 1,
  "anno_accademico": "2026/27",
  "versione": "2026.10.04",          // AAAA.MM.GG della generazione; una seconda generazione lo
                                     // stesso giorno «AAAA.MM.GG.2», «.3»… (ricostruisci.versione_nuova):
                                     // l'app confronta per uguaglianza e mostra la data
  "generato_il": "2026-10-04T18:00:00Z",
  "atenei": {
    "polito": { "corsi": 120, "insegnamenti": 3400, "libri": 900,
                 "esami": 0, "file": "corsi/polito.json",
                 "sha256": "…",
                 "per_corso": "per_corso/polito/indice.json",
                 "sha256_per_corso": "…" }
  }
}
```

## `per_corso/<id_ateneo>/<id_corso>.json` e `indice.json`

Li scrive `tools/db_builder/dividi_per_corso.py` (dopo `build_db.py`, prima di
`sync_assets.py`) dai file per ateneo. Il file di un corso ha la stessa forma
di `corsi/<id_ateneo>.json` con il solo corso in `corsi`, più `moduli`
(id insegnamento → voce di `moduli/<id_ateneo>.json`) con i moduli dei suoi
insegnamenti:

```jsonc
{
  "schema": 1,
  "universita_id": "polito",
  "anno_accademico": "2026/27",
  "aggiornato_il": "2026-10-04",
  "corsi": [ { "id": "polito-l8-ingegneria-informatica", … } ],
  "moduli": { "polito-l8-ingegneria-informatica-01rkcpl": { "moduli": [ … ] } }
}
```

Nei corsi con più percorsi (curricula, orientamenti, percorsi speciali) il
corso ha anche `percorso_classico`, il percorso da proporre già scelto:

```jsonc
"percorso_classico": { "nome": "Percorso", "criterio": "nome" }
```

Gli atenei non pubblicano quanti studenti seguono ogni percorso, quindi lo
sceglie `tools/db_builder/percorso_classico.py` con regole dichiarate in
`criterio`: `nome` (un percorso ha un nome da piano ordinario: «Percorso»,
«Generale», «Statutario», «Standard», «Tradizionale»…; tra più piani per anno
il più recente), `unico_ordinario` (tolti i percorsi speciali, cioè
eccellenza, «Grow Your Talents», «INTRAPRENDENTI», doppio titolo, part-time,
in lingua inglese, online, sedi diverse da quella del corso, percorsi da
30/60 CFU, ne resta uno solo) o `piu_insegnamenti` (percorsi tematici come
«Management» e «Marketing»: quello con più insegnamenti). Nell'app il percorso
è il primo dell'elenco e già scelto, chiamato «Percorso classico» (o «<nome>
(percorso classico)») con i primi due criteri e «<nome> (principale)» con il
terzo; lo studente può sceglierne un altro.

L'indice dell'ateneo elenca ogni corso con impronta e dimensione del file:

```jsonc
{
  "schema": 1,
  "universita_id": "polito",
  "corsi": {
    "polito-l8-ingegneria-informatica": { "sha256": "…", "byte": 482113 }
  }
}
```

## `universita.json`

Generato da `tools/db_builder/parse_mur.py` dalle 4 pagine ufficiali MUR.

```jsonc
{
  "schema": 1,
  "generato_il": "2026-10-04",
  "fonti": ["https://www.mur.gov.it/…/universita-statali", "…"],
  "conteggi": {"statale": 61, "non_statale": 21, "ordinamento_speciale": 9, "telematica": 11},
  "regioni": ["Abruzzo", "…"],
  "universita": [
    {
      "id": "polito", "nome": "Politecnico di Torino", "sigla": "PoliTO",
      "tipo": "statale",                 // statale | non_statale | ordinamento_speciale | telematica
      "regioni": ["Piemonte"],           // vuoto per le telematiche
      "sedi": [{"regione": "Piemonte", "citta": "Torino", "sito": "https://www.polito.it/", "nome_mur": "…"}],
      "sito": "https://www.polito.it/",
      "fonte": {"url": "https://www.mur.gov.it/…", "pagina_aggiornata": "4 aprile 2023"}
    }
  ]
}
```

Un ateneo con sedi in più regioni (es. Cattolica, LUMSA, Link Campus) è **una sola
voce** con più `regioni`: nell'onboarding compare in ciascuna.

## `indice_corsi.json`

Elenco compatto di tutti i corsi di studio di tutti gli atenei, per la ricerca
nell'onboarding senza scaricare i file dei corsi.

```jsonc
{
  "schema": 1, "anno_accademico": "2026/27",
  "corsi": [
    ["polito", "polito-l8-ingegneria-informatica", "Ingegneria Informatica", "L", "L-8", 3, "Torino", "it"]
    // [id_ateneo, id_corso, nome, tipo, classe, durata_anni, sede, lingua]
  ]
}
```

## `corsi/<id_ateneo>.json`

```jsonc
{
  "schema": 1,
  "universita_id": "polito",
  "anno_accademico": "2026/27",
  "aggiornato_il": "2026-10-04",
  "fonte": "https://www.universitaly.it/…",
  "corsi": [
    {
      "id": "polito-l8-ingegneria-informatica",
      "nome": "Ingegneria Informatica",
      "tipo": "L",                     // L | LM | LMCU | LP | altro  (vedi sotto)
      "classe": "L-8",                 // classe di laurea MUR
      "durata_anni": 3,
      "sede": "Torino",
      "lingua": "it",                  // it | en | it/en
      "accesso": "programmato",        // libero | programmato | null
      "url": "https://…",              // pagina del corso sul sito dell'ateneo
      "curricula": ["…"],              // facoltativo
      "piano_da": "unito-l-18-…",     // facoltativo: replica di sede con il piano copiato da quel corso (senza docenti, libri, appelli)
      "ammissione": {                  // facoltativo: requisiti di accesso (quadro A3 della SUA-CdS)
        "accesso": "libero",           // libero | programmato | testo dell'ateneo
        "requisiti": "…",              // testo pubblicato dall'ateneo, com'è
        "test": ["TOLC-I"],            // prove citate nel testo (TOLC-*, English TOLC-*, CEnT-S, …)
        "ofa": true,                   // true: il testo prevede OFA/obblighi formativi aggiuntivi;
                                       // false: dice che non ce ne sono; null: non ne parla
        "livello_inglese": "B1",       // livello QCER d'inglese richiesto, se il testo lo indica
        "fonte": "…", "verificato_il": "2026-10-10"
      },
      "stato": "parziale",             // completo | parziale | da_aggiungere (insegnamenti)
      "fonte": "…", "verificato_il": "2026-10-04",
      "insegnamenti": [
        {
          "id": "polito-l8-ingegneria-informatica-01rkcpl",
          "codice": "01RKCPL",
          "nome": "Analisi matematica I",
          "anno": 1,                    // anno di corso (1..durata_anni)
          "periodo": "1",               // semestre: "1" | "2" | "annuale" | null (dalle date del periodo, se pubblicate) | testo libero
          "periodo_inizio": "01/10/2026", "periodo_fine": "31/01/2027",  // dal catalogo, se pubblicati
          "periodo_fonte": "https://…",  // facoltativo: pagina ufficiale che dice il periodo (può essere di un altro a.a./coorte dello stesso insegnamento); da adapters/periodi.py
          "cfu": 10,
          "ssd": "MAT/05",
          "obbligatorio": true,         // false = a scelta
          "curriculum": null,
          "docenti": ["Nome Cognome"],
          "url": "https://…",           // scheda/syllabus
          "url_sito": "https://…",      // pagina del docente/insegnamento, se diversa
          "modalita_esame": "orale",    // dal syllabus: scritto | orale | scritto e orale | …
          "libri": [
            {
              "titolo": "…", "autori": "…", "editore": "…", "anno": 2020,
              "edizione": "3", "isbn": "9788…", "lingua": "italiano",
              "tipo": "obbligatorio",   // obbligatorio | consigliato | null (non indicato)
              "note": null,
              "citazione": "…"          // riferimento come scritto nel syllabus (sempre presente
                                        // per i libri estratti automaticamente: titolo/autori sono
                                        // separati solo quando certi, altrimenti titolo = citazione)
            }
          ],
          "stato_libri": "completo",    // completo | da_aggiungere | nessun_libro
          "esami": [
            {
              "tipo": "appello",        // appello | prova_in_itinere
              "titolo": "Appello invernale",
              "data": "2027-01-20", "ora": "09:00", "luogo": "Aula 1",
              "modalita": "scritto",    // scritto | orale | scritto+orale | progetto | quiz | altro
              "iscrizioni_dal": "2027-01-03", "iscrizioni_al": "2027-01-13",  // da Esse3
              "docenti": "ROSSI MARIO", "note": null, "fonte": "…"
            }
          ],
          "stato_esami": "da_aggiungere", // completo | da_aggiungere
          "fonte": "…", "verificato_il": "2026-10-04"
        }
      ]
    }
  ]
}
```

### Nomi degli insegnamenti

`nome` (anche nelle `varianti`, in `modulo_di` e nei `titolo` degli appelli) è solo
il nome dell'insegnamento: niente CFU («(6 CFU)», «- 6 Cfu», «CFU 6») e niente codice
dell'insegnamento («(01RKCPL)», «[GIU0123]», «(cod. 12345)», «A422439 - …», le sigle di
Roma Tre «Am110 - …»), che hanno i loro campi `cfu` e `codice` (se il campo è vuoto
si riempie con il valore tolto dal nome). Restano le parti con un significato:
moduli («(modulo A)», «(mod. 1)»), canali («(A-L)»), livelli («(livello B1)»,
«(corso avanzato)»), numeri romani, «(c.i.)», «(integrato)», lingue, anni e sedi,
i CFU che descrivono una regola («(fra 6 e 12 CFU)», «Gruppo OPZIONALI DA 8 CFU») e i
numeri senza unità («(2)»). Il settore (SSD) tra parentesi si toglie solo se è
uguale al campo `ssd`. Omonimi (stesso corso e anno, percorsi in comune o non
indicati): con CFU diversi il nome riprende i CFU del campo nel formato «(N CFU)»
(«Inglese (3 CFU)», «Inglese (6 CFU)»), perché nell'app gli insegnamenti si mostrano
solo con il nome; con gli stessi CFU tengono il codice («Core Abroad (ECO1)», «Core
Abroad (ECO2)»). Con percorsi diversi (es. PoliTO Torino e Mondovì) lo studente ne
vede uno solo e il nome resta pulito. Lo fa l'ultimo passo di `build_db.py`
(`pulizia.nomi_insegnamenti`, dopo gli id), di nuovo `dividi_per_corso.py`; per il
database già costruito `tools/db_builder/nomi_insegnamenti.py` (`--verifica` per
controllare). Id e ordine degli insegnamenti non cambiano. Nell'app, «Aggiorna
database» rinomina gli insegnamenti importati; per quelli con la versione in
inglese o modificati dallo studente (che l'aggiornamento non rinomina) toglie dal
nome ufficiale solo CFU e codice; un insegnamento modificato prende il nome del
database se è lo stesso a meno di CFU e codice, così «(N CFU)» degli omonimi resta
(`core/catalog/nome_insegnamento.dart`; il nome scelto dallo studente resta).

### Tipi di corso di studio (`tipo`)

| Codice | Nome nell'app | Durata | Classi |
|---|---|---|---|
| `L` | Laurea (triennale) | 3 anni, 180 CFU | `L-…` |
| `LP` | Laurea professionalizzante | 3 anni, 180 CFU | `L-P0…` |
| `LM` | Laurea magistrale | 2 anni, 120 CFU | `LM-…` |
| `LMCU` | Laurea magistrale a ciclo unico | 5 anni (300 CFU) o 6 anni (360 CFU: Medicina e chirurgia, Odontoiatria) | `LM-4 c.u.`, `LMG/01`, `LM-13`, `LM-41`, `LM-42`, `LM-46`, `LM-85 bis` |
| `altro` | Altro (dottorato, master, corsi ordinari delle Scuole superiori) | variabile | — |

### Da dove vengono i dati

| Dato | Fonte | Script |
|---|---|---|
| Atenei, tipo, regioni, sedi | 4 pagine MUR | `tools/db_builder/fetch_mur.py`, `parse_mur.py` |
| Corsi di studio (tutti, ~5.900) | API pubblica di Universitaly (MUR/Cineca) | `fetch_universitaly.py` |
| Insegnamenti per anno, CFU, periodo, docenti, modalità d'esame, libri | Course Catalogue Cineca dell'ateneo (`<ateneo>.coursecatalogue.cineca.it`) | `adapters/cineca_catalogue.py` |
| Requisiti di accesso (OFA, test d'ingresso, livello d'inglese) | Course Catalogue Cineca (`requisiti_it` del corso, testo della SUA-CdS) | `adapters/ammissione.py`, `adapters/cineca_catalogue.py` |
| Appelli e prove parziali | Bacheca appelli pubblica Esse3 (`<ateneo>.esse3.cineca.it`) | `adapters/esse3_appelli.py` |
| Dati raccolti a mano, segnalazioni degli studenti | `database/contrib/*.json` | — |

Le piattaforme di ogni ateneo sono in `tools/db_builder/piattaforme.json`. Per gli
atenei senza queste piattaforme gli insegnamenti restano `da_aggiungere`.

Contributi (`database/contrib/**/*.json`): stesso formato dei corsi, più
`"appelli": {"<codice insegnamento>": [esami…]}`. Un corso del
contributo viene associato a quello di Universitaly per `id`, `id_universitaly`,
nome + classe, oppure nome o classe se univoci.

## `corsi_sostituiti.json`

Facoltativo. Elenca i corsi di laurea **eliminati** dal database perché doppioni
di un altro corso (es. lo stesso corso presente sia nel sito dell'ateneo sia in
Universitaly) e uniti a quello che resta. Serve all'app per non lasciare orfano
lo studente che aveva scelto il vecchio id.

```jsonc
{
  "schema": 1,
  "corsi": {
    "<id vecchio>": {
      "nuovo": "<id del corso che lo sostituisce>",
      "universita_id": "unibs",
      "motivo": "doppione unito al corso Universitaly",
      "dal": "2026-10-13"            // AAAA-MM-GG
    }
  }
}
```

- La chiave è l'id eliminato; `nuovo` è un corso presente in
  `corsi/<universita_id>.json`. Le **catene** sono ammesse (A→B, B→C: l'app
  segue fino in fondo); i cicli e le voci che puntano a sé stesse vengono
  ignorati. Una voce già nella mappa non va tolta quando il corso nuovo cambia
  a sua volta: si aggiunge una nuova voce.
- Gli id degli insegnamenti cominciano con l'id del corso di laurea: se anche
  gli insegnamenti del corso nuovo mantengono il resto dell'id, l'app ricollega
  esami, voti e libri dello studente senza duplicati.
- L'app lo include negli asset (`tools/db_builder/sync_assets.py`) e lo scarica
  con *Aggiorna database* come gli altri file generali; se manca non è un
  errore. All'avvio e dopo ogni aggiornamento, se il corso del profilo (o un
  insegnamento, esame, libro o data collegato al catalogo) ha un id della
  mappa, lo sostituisce con quello nuovo una volta sola, senza toccare i dati
  dello studente, e mostra un avviso.

## Aggiornamento annuale

Il database viene rigenerato dallo sviluppatore e pubblicato in questa repository:

- automaticamente ogni anno a **luglio** (nuova offerta formativa pubblicata),
  **settembre** (inizio anno accademico) e **gennaio** (date d'esame del 2° semestre);
- quando serve, a mano.

L'app, a ogni
avvio con internet, confronta `meta.json.versione` con quella installata e
propone "Aggiorna database"; i dati personali non vengono mai toccati.

## Argomenti degli insegnamenti (`database/argomenti/<ateneo>.json`)

Facoltativo, generato da `tools/db_builder/argomenti.py` (per ora Politecnico di
Torino). Per ogni id di insegnamento: le voci del programma pubblicato nella guida
dell'insegnamento, ripulite da numerazione e ore; i paragrafi descrittivi lunghi
non diventano argomenti.

```json
{
  "polito-l-8-ingegneria-informatica-16acfwz": {
    "argomenti": ["Numeri reali e complessi", "Limiti", "…"],
    "fonte": "https://didattica.polito.it/…sviluppo.guide.visualizza?p_cod_ins=16ACFWZ…",
    "verificato_il": "2026-10-10"
  }
}
```

Il report `docs/argomenti/<ateneo>.md` elenca gli insegnamenti con gli stessi
esatti argomenti in corsi di laurea diversi e quelli che differiscono di meno di 5
argomenti.

## Moduli di Studio (`database/moduli/<ateneo>.json`)

Moduli e argomenti proposti per ogni insegnamento (chiave: id dell'insegnamento).
L'app li crea in Studio per gli insegnamenti che non hanno ancora moduli; quelli
creati o modificati dallo studente non vengono mai toccati.

```json
{
  "schema": 1, "universita_id": "unito", "aggiornato_il": "2026-10-13",
  "fonte": "Indici dei libri di riferimento e programmi ufficiali degli insegnamenti",
  "insegnamenti": {
    "<id insegnamento>": {
      "origine": "indice",
      "fonte": "Indice di «Titolo», Autori, Editore, edizione, anno (ISBN …)",
      "moduli": [{"nome": "Limiti e continuità", "argomenti": ["Limiti di funzioni", "…"]}],
      "programma": [{"nome": "Limiti e continuità di funzioni reali", "argomenti": []}],
      "fonte_programma": "https://…/insegnamenti/2026/…"
    }
  }
}
```

`origine`, in ordine di precedenza:
- `libreria` (o assente): capitoli e sezioni dell'indice di un libro di riferimento consultato;
- `indice`: capitoli e sezioni dell'indice di un libro del programma (prima gli
  obbligatori), pubblicato dall'editore o da un catalogo di biblioteca;
- `programma`: voci del programma ufficiale pubblicato dall'ateneo (la `fonte`
  contiene l'URL della scheda).

Campi facoltativi (i file senza restano validi):
- `programma`: voci del programma ufficiale, stesso formato di `moduli`
  (`nome`, `argomenti`); presente quando i `moduli` vengono dall'indice di un
  libro (`origine` `indice` o `libreria`) e l'ateneo pubblica anche il programma;
- `fonte_programma`: URL della scheda con il programma.

Argomenti d'esame: l'app riempie il campo «Argomenti» dell'esame finale con
`programma` se c'è, altrimenti con `moduli` se `origine` è `programma`,
altrimenti lo lascia vuoto: l'indice di un libro non diventa mai argomento
d'esame (resta solo come moduli di Studio). Il testo ha una riga per modulo,
«• Modulo: argomento, argomento» (solo «• Modulo» senza argomenti), al massimo
8000 caratteri (oltre, le ultime righe diventano «…»). Lo studente può
modificarlo: «Aggiorna database» aggiorna solo i campi che non ha toccato
(vedi [datapack_format.md](datapack_format.md)).

Materiali da studiare: l'app riempie il campo «Materiali da studiare» dell'esame
finale con i libri dell'insegnamento nel database (`libri` del corso), uno per
riga come «Autori — Titolo (Editore, anno)» o con la citazione del syllabus,
prima gli obbligatori, poi i consigliati, poi quelli senza indicazione; anche
questo campo si aggiorna solo finché lo studente non lo modifica.

Solo titoli, sempre in italiano; nessun argomento aggiunto o dedotto. Gli
insegnamenti senza indice né programma pubblicato non compaiono. L'app riceve i
moduli dei soli insegnamenti del corso scelto, dentro il file del corso
(`per_corso/<ateneo>/<corso>.json`, chiave `moduli`), e crea i moduli dopo
l'import del piano; le build pubblicate non li includono negli asset.
