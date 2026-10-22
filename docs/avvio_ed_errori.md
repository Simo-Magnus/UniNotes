# Avvio dell'app ed errori

Come UniNotes si avvia e cosa fa quando qualcosa va storto (codice in
`app/lib/main.dart`, `app/lib/core/database/app_database.dart`,
`app/lib/core/router/error_screens.dart`, `app/lib/core/services/error_log.dart`).

## Avvio

1. Gestione globale degli errori (`installGlobalErrorHandlers`).
2. Controllo dell'installazione e, se servono, le domande sui dati di
   un'installazione precedente.
3. Apertura del database, servizi e preferenze. Se non riesce (database non
   apribile, disco pieno, permessi) compare la schermata «UniNotes non si è
   avviato» con la spiegazione e «Riprova», invece di una finestra vuota.
4. Prima schermata, poi sincronizzazione, promemoria e sessione Focus: un
   servizio che non parte non ferma gli altri.

Su Windows può esserci una sola copia dell'app aperta: avviarla di nuovo
riporta in primo piano la finestra già aperta (anche dall'area di notifica).

## Database

- Le istruzioni dello schema (tabelle, indici, colonne) si eseguono solo per
  ciò che manca: un database di una versione vecchia, già in parte
  aggiornato o riaperto da una versione precedente dell'app si apre senza
  errori.
- A ogni apertura tabelle, indici e colonne mancanti (database parziale) si
  ricreano, senza toccare i dati.
- Un file danneggiato (non è un database SQLite o è corrotto) non si
  elimina: si rinomina in `university_manager.db.danneggiato-<data>` nella
  cartella di supporto dell'app e l'app riparte con un database nuovo,
  avvisando lo studente (i dati si recuperano da un backup esportato o
  dalla sincronizzazione). Errori passeggeri (disco pieno, file bloccato)
  non spostano mai il file.
- Con il disco pieno all'avvio i dati si leggono lo stesso; le scritture
  danno errore finché non si libera spazio.

## Registro degli errori

`errori.log` nella cartella di supporto dell'app (con la copia precedente
`errori.log.1`, al massimo circa 1 MB in tutto): eccezioni non gestite,
errori dei widget, avvio non riuscito. Resta sul dispositivo, non si invia a
nessuno; lo stesso errore ripetuto si annota una volta ogni 10 secondi e al
massimo 300 voci per avvio. «Elimina tutti i dati» (voce del database) lo
cancella insieme alle copie danneggiate del database.

Un widget che non si costruisce mostra «Qualcosa non ha funzionato» con
«Torna indietro» (se c'è una schermata a cui tornare) al posto della
schermata rossa o grigia.
