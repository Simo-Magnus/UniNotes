# Collegamenti: stati e messaggi

Schermata Collegamenti, card in quest'ordine: **OneDrive**, **Google Drive**,
**Whisper**, **AI di riferimento** (`lib/features/links/links_screen.dart`).
La card «Gemini» non c'è più: non aveva impostazioni (nessuna chiave API dal
2026, la vecchia chiave è già stata tolta da `removeLegacyGemini`); Gemini resta
fra le AI di riferimento, con il link all'offerta di Google per gli studenti quando è
scelto, e «Trascrivi con Gemini» resta sulle registrazioni.

Testi e regole: `lib/features/links/link_status.dart` (`cloudStatus`,
`describeSignInError`, messaggi di successo). Il calendario (Outlook, sistema)
non è in Collegamenti ma in Impostazioni → Calendario.

## OneDrive e Google Drive

Riga di stato in cima alla card (icona azzurra = a posto, rossa = da
sistemare) e, per gli esiti delle azioni, messaggi in basso (snackbar) o un
dialogo con al massimo due pulsanti.

| Stato | Quando | Messaggio nella card | Azione |
|---|---|---|---|
| Non disponibile | la build non include l'ID del servizio | «*Servizio* non è disponibile in questa versione dell'app. Aggiorna UniNotes dal sito o dallo store.» | pulsante di accesso spento |
| Non collegato | mai collegato, scollegato | «Non collegato. Accedi per avere file e dati dell'app su tutti i tuoi dispositivi.» | «Accedi con Microsoft/Google» |
| Ateneo da approvare (OneDrive) | l'account universitario è stato bloccato (AADSTS65001…) | «Il tuo ateneo non permette di collegare l'account universitario. Usa un account Microsoft personale o chiedi all'ateneo di approvare UniNotes (link qui sotto).» | scheda «Il tuo ateneo deve approvare UniNotes» |
| Collegamento in corso | browser aperto per l'accesso | «Accesso a *servizio* in corso nel browser… Completa l'accesso: poi l'app torna in primo piano da sola.» + barra | — |
| Collegato | accesso riuscito, prima sincronizzazione non ancora finita | «Collegato (*account*). Prima sincronizzazione in arrivo.» | — |
| Sincronizzazione in corso | | passo attuale («Dati dell'app: unione con gli altri dispositivi…», «Carico …») + barra | — |
| Sincronizzato | ultima riuscita | «Collegato (*account*) · ultima: *gg/mm hh:mm · esito*» | «Sincronizza ora», «Scollega» |
| Senza rete | servizio non raggiungibile | «Senza connessione: *servizio* non è raggiungibile. Ultima riuscita: … Riparte da sola quando torna internet.» | riprova automatica al ritorno della rete |
| Errore di sincronizzazione | errore del servizio o di un file | «Sincronizzazione non riuscita: *causa* Riprova con «Sincronizza ora».» | «Sincronizza ora» |
| Collegamento interrotto | refresh token scaduto o revocato (`invalid_grant`, AADSTS700082…) | «Collegamento interrotto: l'accesso a *servizio* (*account*) è scaduto o è stato revocato. Premi «Accedi di nuovo»: file e dati restano sul dispositivo e riprendono a sincronizzarsi.» (anche notifica «collegamento interrotto», se attiva) | «Accedi di nuovo» al posto di «Sincronizza ora» |

Esiti delle azioni:

| Azione | Esito | Messaggio |
|---|---|---|
| Accedi | riuscito | snackbar «*Servizio* collegato come *account*. Sincronizzazione avviata: file e dati arrivano su tutti i dispositivi collegati.»; card aggiornata; poi, se arrivano dati, «*Servizio*: N dati arrivati dagli altri dispositivi.» |
| Accedi | senza rete | dialogo «Collegamento a *servizio* non riuscito»: «Nessuna connessione a internet: *servizio* non è raggiungibile. Collegati alla rete e riprova.» — «Chiudi» / «Riprova» |
| Accedi | annullato nel browser o permessi rifiutati | «Accesso annullato: *servizio* non è stato collegato. Riprova quando vuoi e accetta i permessi richiesti (solo i file di UniNotes).» — «Chiudi» / «Riprova» |
| Accedi | nessun ritorno entro 5 minuti | «L'accesso non è stato completato entro 5 minuti. Riprova e completa l'accesso nella pagina che si apre nel browser.» — «Chiudi» / «Riprova» |
| Accedi | browser non apribile | «Non riesco ad aprire il browser per l'accesso. Controlla di avere un browser predefinito e riprova.» |
| Accedi | ateneo che blocca (OneDrive) | scheda «Il tuo ateneo deve approvare UniNotes» (account personale / richiesta all'ateneo) |
| Accedi | altro errore del servizio | «Collegamento a *servizio* non riuscito: *causa spiegata* (`MicrosoftOAuth.explain`, `GoogleOAuth.explain`) Riprova; se l'errore continua, scollega e ricollega l'account.» |
| Sincronizza ora | riuscita | snackbar «*Servizio*: *esito*» (es. «2 caricati, 5 dati aggiornati dagli altri dispositivi») |
| Sincronizza ora | senza rete | «Senza connessione: *servizio* non è raggiungibile. La sincronizzazione riparte da sola quando torna internet.» |
| Sincronizza ora | errore | «Sincronizzazione con *servizio* non riuscita: *causa*. Riprova tra poco.» |
| Scollega | | dialogo di conferma; Google: se la revoca non riesce, «*Servizio* scollegato» con la pagina dell'account |

### Ritorno nell'app dopo l'accesso

- **Android, iOS**: accesso nel browser di sistema (Custom Tabs,
  ASWebAuthenticationSession) che si chiude da solo e torna nell'app con lo
  schema `msauth.…://auth` (Microsoft) o `com.googleusercontent.apps.…:/…`
  (Google); l'app mostra subito l'esito.
- **Windows, macOS** (server locale `http://localhost` / `127.0.0.1`): appena
  il browser torna sul server locale
  1. la finestra di UniNotes torna in primo piano da sola (anche se ridotta a
     icona; `lib/core/services/app_return.dart`, «sempre in primo piano» per un
     istante perché Windows non lascia prendere il primo piano a un'app in
     secondo piano);
  2. la pagina del browser (`returnToAppPage`) apre `uninotes://auth`: il
     browser può chiedere «Aprire UniNotes?» (con «Consenti sempre» non lo
     chiede più); su Windows la copia dell'app avviata dallo schema porta in
     primo piano quella già aperta e si chiude (`windows/runner/main.cpp`), su
     macOS il sistema riattiva l'app (`AppLinks`, host `auth`);
  3. la scheda prova a chiudersi da sola dopo 1,5 secondi (i browser lo
     permettono solo per le schede aperte da uno script: di solito resta una
     pagina minima «Torna a UniNotes» con il pulsante «Apri UniNotes»).
  Non compare più «Accesso completato – Puoi chiudere questa finestra e tornare
  all'app». Lo stesso vale per «Importa da Drive» (Google Picker).
- Registrazione dello schema su Windows: installatore Inno Setup (`[Registry]`,
  tolta alla disinstallazione), al primo avvio per l'utente corrente se manca o
  punta a un programma che non c'è più (copie portatili e di sviluppo), manifest
  del pacchetto per il Microsoft Store (`windows.protocol`).

## Whisper

| Stato | Messaggio |
|---|---|
| Motore pronto / mancante | riga di stato (programma whisper.cpp pronto, da scaricare, incluso nell'app) |
| Modelli | «Le trascrizioni usano: *modello*» o «Nessun modello scaricato: «Trascrivi con Whisper» usa il modello integrato …» |
| Download in corso | barra con avanzamento e «Annulla» |
| Download riuscito | snackbar «Modello *x* scaricato: le prossime trascrizioni possono usarlo.» |
| Download interrotto (rete) | «Download di *x* interrotto: controlla la connessione e premi «Riprendi» (riparte da dove si era fermato).» |
| Spazio insufficiente | «Download di *x* non riuscito: *spazio richiesto e libero*» |
| Download annullato | «Download di *x* annullato. Quando vuoi premi «Riprendi»: riparte da dove si era fermato.» |
| Altro errore | «Download di *x* non riuscito: *causa*. Riprova.» (icona rossa con il dettaglio sul modello) |

## AI di riferimento

Nessun accesso: l'AI si apre con l'account che lo studente ha già.

| Stato | Messaggio |
|---|---|
| Scelta | «In uso: *AI*. *cosa fare dopo l'apertura*» |
| Cambio di AI | snackbar «AI di riferimento: *AI*. In Studio e Registra l'app aprirà *AI* con il prompt pronto.» |
| Gemini scelto | nota sull'offerta di Google per gli studenti (piano e costi nella pagina di Google) e su «Trascrivi con Gemini», link «Offerte di Google per studenti» |
| Sito o app non apribile | messaggio di `showLaunchResult` (nessun browser / app non installata) |
