# Sincronizzazione dei dati dell'app tra dispositivi

Con OneDrive o Google Drive collegati (Collegamenti), oltre ai file
(registrazioni, appunti, libri, allegati) si sincronizzano anche i **dati
dell'app**: sessioni di Studio, moduli e argomenti con il loro stato, esami e
prove, voti, insegnamenti (anche quelli aggiunti a mano), libri e materiali
(stato, pagina di lettura), eventi, note sui luoghi, percorso dello studente,
stato degli anni del piano e alcune scelte di studio. Casella «Dati dell'app:
Studio, esami, voti, insegnamenti» in ogni servizio (accesa di serie, anche
per chi aveva già scelto le altre caselle).

Codice: `lib/core/database/sync_schema.dart` (metadati e trigger),
`lib/features/cloud/data_sync_snapshot.dart` (registro e unione),
`lib/features/cloud/data_sync.dart` (esportazione, unione, applicazione),
`CloudDriveService._syncData` (`lib/features/cloud/cloud_drive_service.dart`).
Test: `test/data_sync_test.dart`, `test/data_sync_cloud_test.dart`.

## File nel cloud

```
UniNotes/Dati/<dispositivo> <codice>.json.gz
```

Un file per installazione (`PC a1b2c3.json.gz`, `telefono 9f0e11.json.gz`;
il codice è `install_id`). **Ogni dispositivo scrive solo il proprio file** e
legge quelli degli altri: due dispositivi che sincronizzano nello stesso
momento non si sovrascrivono mai. Stessi file e stesse regole per OneDrive e
Google Drive; con entrambi collegati ognuno ha la sua cartella `Dati` e la
base locale è comune.

Formato (JSON compresso con gzip, chiavi in ordine: stessi dati = stessi byte,
così il file non si ricarica se nulla cambia):

```json
{
  "format": "uninotes-sync", "version": 1,
  "device": "PC", "installId": "a1b2c3",
  "tables": {
    "topics": {
      "t:m:c:polito:course:01ABC/limiti/asintoti": {
        "v": {"name": "Asintoti", "status": "done", "module_id": "m:c:polito:course:01ABC/limiti"},
        "t": {"name": 1760000000000, "status": 1761040000000, "module_id": 1760000000000}
      },
      "t:m:c:#4f…/arduino/pwm": {"d": 1761050000000}
    }
  }
}
```

- `v`: valori delle colonne; i riferimenti ad altre righe (`course_id`,
  `module_id`, `topic_id`…) sono l'identificativo della riga puntata, i luoghi
  pubblici il loro `external_id`, i percorsi degli appunti collegati agli
  allegati sono relativi alla cartella degli appunti (`appunti:Corso/…`).
- `t`: ultima modifica di ogni colonna (millisecondi dal 1970); un numero solo
  se è uguale per tutte.
- `d`: eliminazione datata (segnaposto «eliminato»).

## Identificativi stabili

Gli `id` locali sono numeri diversi su ogni dispositivo; ogni riga ha un
`sync_id` uguale ovunque (colonna aggiunta da `SyncSchema.ensure`):

| Tabella | `sync_id` |
|---|---|
| courses, events, exams, books, materials | `c:`/`e:`/`x:`/`b:`/`k:` + `external_id` del database dei corsi; righe create a mano: `#` + codice casuale |
| modules | `m:` + id dell'insegnamento + `/` + nome in minuscolo |
| topics | `t:` + id del modulo + `/` + nome in minuscolo |
| study_sessions | `s:` + inizio + `|` + durata (la stessa sessione, es. da un backup ripristinato, non si duplica) |
| attachments | `a:#` + codice casuale |
| app_settings, profile, plan_years, place_personal | la chiave della tabella |

Così lo stesso catalogo importato su due dispositivi dà le stesse righe (niente
doppioni di moduli e argomenti) e le sessioni create su dispositivi diversi
hanno identificativi diversi: **le sessioni si sommano**. Due righe con lo
stesso identificativo sullo stesso dispositivo (es. due moduli con lo stesso
nome) diventano `…#2`, `…#3` nell'ordine di creazione. L'identificativo non
cambia se la riga si rinomina.

## Orari di modifica ed eliminazioni (trigger)

`SyncSchema.ensure` (a ogni apertura del database, idempotente e senza numero
di versione: le colonne si aggiungono solo se mancano, i trigger si rifanno
con l'elenco attuale delle colonne, nessun dato viene toccato) aggiunge
`sync_mtime` e i trigger:

- **INSERT** → `sync_mtime = -adesso` (negativo = riga solo inserita, es.
  dall'import del database dei corsi) e `sync_id` se manca;
- **UPDATE** che cambia almeno un valore → `sync_mtime = +adesso`;
- **DELETE** → riga in `sync_tombstones (tbl, sync_id, deleted_at)`
  (eliminazioni a cascata comprese; non per profilo e anni del piano, e per le
  impostazioni solo quelle sincronizzate).

Le righe già presenti all'aggiornamento dell'app prendono `sync_mtime =
adesso` (dati veri del dispositivo). Nessun repository deve ricordarsi della
sincronizzazione.

## Unione

A ogni sincronizzazione con novità (registri nuovi scaricati, dati cambiati
qui, nessuna base):

1. il motore dei file scarica i registri nuovi degli altri dispositivi;
2. **esportazione**: ogni riga locale diventa una voce; per ogni colonna
   l'orario è quello della **base** (risultato dell'ultima unione, file
   `dati_sync_base.json.gz` nella cartella dell'app) se il valore non è
   cambiato, altrimenti quello della riga (`|sync_mtime|`). Le righe della
   base che qui non ci sono restano (es. un argomento di un insegnamento che
   questo dispositivo non ha), le eliminazioni di `sync_tombstones` diventano
   segnaposti;
3. **unione** con i registri degli altri (`mergeSnapshots`), per ogni riga e
   colonna:
   - riga nuova → aggiunta;
   - colonna modificata → vince la modifica più recente (colonne diverse della
     stessa riga modificate su dispositivi diversi si tengono entrambe);
   - stesso orario e valori diversi → vince sempre lo stesso valore su tutti i
     dispositivi (testo JSON maggiore);
   - eliminazione → vale se più recente di ogni modifica della riga (a parità
     vince la riga); la riga diventa un segnaposto datato. Una modifica
     successiva la fa tornare;
   - impostazioni che sono insiemi (`removed_catalog_courses`,
     `prefilled_modules`) → unione delle voci;
4. il risultato si **applica** al database in una transazione (prima le
   eliminazioni, figli prima dei genitori; poi aggiunte e modifiche, genitori
   prima dei figli, con i riferimenti tradotti negli `id` locali), diventa la
   nuova base e il registro di questo dispositivo; `sync_tombstones` si
   svuota;
5. se il registro è cambiato si carica subito.

L'unione è commutativa, associativa e **idempotente**: rifarla con gli stessi
registri non cambia nulla (nessuna riga toccata, file invariato, nessun
caricamento). Un'unione alla volta (lock), anche con OneDrive e Google Drive
insieme. Dopo un'unione che porta novità le schermate si aggiornano
(`revision.bump()`, profilo riletto).

### Primo collegamento di un dispositivo

Senza base e con registri di altri dispositivi nel cloud, le righe **solo
inserite** di questo dispositivo (import del catalogo, impostazioni
iniziali) valgono come modificate all'istante 0: i dati già nel cloud
(argomenti completati, voti, impostazioni scelte) hanno la precedenza sui
valori iniziali di un telefono appena configurato. Le righe modificate qui
tengono il loro orario (vince la più recente) e le righe che ci sono solo qui
si aggiungono. Le eliminazioni fatte prima del primo collegamento non si
propagano.

### Casi particolari

- **Riferimento a una riga che qui non c'è** (es. sessione collegata a un
  argomento eliminato): colonna obbligatoria → la riga non si importa e resta
  nel registro (si importa quando arriva la riga puntata); facoltativa → vuota
  sul dispositivo, ma il registro tiene il riferimento (non conta come
  modifica).
- **Stesso `external_id` con un altro identificativo** (insegnamento
  sostituito nel database dei corsi su un solo dispositivo): la riga si collega
  a quella locale, senza doppioni.
- **Colonne di una versione più recente dell'app**: restano nel registro con i
  loro orari anche sui dispositivi che non le conoscono.
- **Ripristino di un backup**: le righe tolte per fare posto al backup non
  sono eliminazioni; il ripristino si unisce ai dati degli altri dispositivi
  (le modifiche più recenti vincono) e non cancella nulla altrove.
- **«Elimina dati» sul dispositivo**: base e copie locali dei registri si
  tolgono con lo stato della sincronizzazione; alla prossima sincronizzazione
  i dati tornano dal cloud (per toglierli anche dal cloud c'è la voce delle
  cartelle UniNotes su OneDrive/Google Drive, che comprende `Dati/`).
- **App reinstallata**: il registro della vecchia installazione resta nel
  cloud e viene letto come quello di un altro dispositivo: i dati tornano.

## Cosa non si sincronizza

- Impostazioni del dispositivo: aspetto, suoni, notifiche, calendario, account
  e token (nel portachiavi, mai nel database), stato della sincronizzazione,
  percorsi, Whisper, domande già fatte. Si sincronizzano solo:
  `exclusion_patterns`, `focus_daily_goal`, `focus_settings`,
  `links_reference_ai`, `removed_catalog_courses`, `prefilled_modules`
  (`SyncSchema.syncedSettings`; aggiungere qui le nuove scelte di studio).
- Colonne con percorsi assoluti del dispositivo (`books.file_path`,
  `materials.local_path`).
- Email (`mail_*`), dati pubblici (atenei, corsi di laurea, luoghi), colori
  delle università.
- Eliminazione del profilo e degli anni del piano («Rifai l'onboarding» su un
  dispositivo non toglie il percorso agli altri).
- Una nuova tabella personale va aggiunta a `SyncSchema.tables` (in ordine di
  dipendenza) per sincronizzarsi.

## Limiti noti

- Gli orari sono quelli degli orologi dei dispositivi (sincronizzati dalla
  rete): con un orologio molto sbagliato una modifica può perdere contro una
  più vecchia.
- Più colonne della stessa riga cambiate fra due unioni prendono l'orario
  dell'ultima modifica della riga.
- I segnaposti delle eliminazioni restano nei registri (pochi byte ciascuno).
- Un modulo o un argomento rinominato su un dispositivo prima del primo
  collegamento, e non sull'altro, resta doppio (identificativi diversi).
