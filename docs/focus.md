# Modalità Focus (Studio → Sessioni Studio → Timer)

Sessioni di concentrazione come quelle dell'app **Orologio** di Windows 11:
si sceglie quanto studiare, l'app fa le pause, conta il tempo, lo collega a
un insegnamento (modulo, argomento) e silenzia i propri avvisi non urgenti.
Il tempo di concentrazione finisce nelle sessioni di studio e nelle
statistiche, accanto a quello del cronometro.

Codice: `app/lib/features/study/focus/` (logica pura in `focus_plan.dart` e
`focus_goal.dart`, timer in `focus_timer.dart`, coordinamento in
`focus_service.dart`, silenzio del sistema in `focus_system.dart`,
preparazione in `focus_setup.dart`, card in `focus_cards.dart`, sessione a
tutto schermo in `focus_screen.dart`, riquadro in `focus_pill.dart`, sezione
delle impostazioni in `focus_quiet_section.dart`); la schermata che lo ospita
è `study_sessions_tab.dart` (vedi [studio.md](studio.md)); lato nativo
`android/.../FocusDnd.kt` e `windows/runner/focus_session.cpp`. Test in
`app/test/focus_test.dart`.

## Preparare una sessione

Da **Studio → Sessioni Studio**: si sceglie che cosa si studia
(insegnamento → modulo → argomento, più l'attività) e poi **Timer** (l'altra
scelta è il Cronometro). In Argomenti «Sessione focus» (card
dell'insegnamento, con «Tutto l'insegnamento»), «Sessione focus sul modulo» e
«Sessione focus sull'argomento» aprono Sessioni Studio con la scelta già
fatta e il timer pronto.

- **Durata**: da 15 minuti a 4 ore, con − e + (5 minuti fino a un'ora, poi
  15) o con il cursore. Sotto: le pause previste e l'ora di fine.
- **Pause automatiche**: una pausa di 3, 5, 10 o 15 minuti ogni 20, 25, 30,
  45 o 60 minuti di concentrazione (predefinito 5 ogni 30). La durata scelta
  comprende le pause, come in Windows: 60 minuti = 30 + pausa 5 + 25.
  L'ultimo tratto è sempre di concentrazione e mai sotto i 5 minuti (con 38
  minuti niente pausa).
- **Avvia il timer**: l'unica azione arancione della card.

Le ultime impostazioni e l'ultimo collegamento restano per la volta dopo.

## Durante la sessione

Schermata a tutto schermo con il **timer grande ad anello** (anello di Design
3, §7.2, in scala: azzurro perché il tempo lo conta la macchina, attenuato in
pausa): fase («Concentrazione» o «Pausa»), tempo del tratto in corso, ora
della prossima pausa o della fine. Sotto, i tratti della sessione (barre per
la concentrazione, tratti brevi per le pause), i minuti fatti e le pause
rimaste.

- **Pausa / Riprendi**: ferma il tempo (la sessione si allunga).
- **Salta pausa** (durante una pausa): si riparte subito; la sessione finisce
  prima di quanto manca alla pausa.
- **Termina**: «Terminare la sessione?» → **Termina e salva** (il tempo di
  concentrazione fatto finora diventa una sessione di studio) o **Scarta**;
  toccando fuori la sessione continua (al massimo due pulsanti nei dialoghi).

A fine sessione: riepilogo con spunta animata, minuti di concentrazione e
obiettivo del giorno.

**Uscendo dalla schermata** la sessione continua: compare il riquadro sopra
tutte le schermate, lo stesso del registratore (`widgets/floating_pill.dart`,
ospitato da `RecordingOverlayHost`; con una registrazione in corso i due
riquadri stanno uno sotto l'altro e si trascinano insieme): avanzamento del
tratto, nome, tempo, «Salta pausa» (nelle pause), Pausa/Riprendi e X
(Termina). Un tocco riapre la sessione. Su Android «Indietro» dalla Home
manda l'app in background senza fermare la sessione.

**L'app chiusa non ferma la sessione**: lo stato (`focus_running` nelle
impostazioni) si salva a ogni cambio; riaprendo l'app la sessione riprende
col tempo giusto o, se nel frattempo è finita, si salva con l'ora di fine
prevista.

## Suoni, vibrazioni e notifiche

- Inizio sessione, inizio e fine pausa, fine sessione: suoni brevi e
  vibrazione (Impostazioni → Suoni e vibrazioni).
- **Android**: notifica fissa (canale `focus`, silenziosa) con il **conto
  alla rovescia del sistema** fino alla prossima pausa o alla fine
  (cronometro di Android: si aggiorna da solo anche ad app chiusa).
- **Con l'app in background** (tutti i sistemi con notifiche) si pianificano
  gli avvisi di inizio pausa, fine pausa e fine sessione (canale
  `focus_avvisi`, importanza alta; su iOS «time sensitive», così arrivano
  anche con una Full immersion se lo permetti). Tornando nell'app si
  tolgono: ci pensano i suoni dell'app.
- Il permesso delle notifiche (Android 13+, iOS) si chiede una sola volta,
  al primo avvio di una sessione.

## «Non disturbare»

**Avvisi dell'app**: durante la sessione gli avvisi **non urgenti** («Com'è
andata?», collegamenti interrotti, recensione, sostegno) si spostano a un
minuto dopo la fine prevista; quelli urgenti (prove, inizio sessione
d'esame, registratore, Focus) arrivano come sempre. Vedi
[notifiche.md](notifiche.md#durante-una-sessione-focus).

**Sistema**: durante la sessione si fermano le notifiche di **tutte le app
tranne quelle vitali**, come con il Non disturbare. Gli avvisi di inizio e
fine pausa e di fine sessione di UniNotes (canale `focus_avvisi`, con
`setBypassDnd(true)`) passano lo stesso. Si regola in
**Impostazioni → Focus e Non disturbare** (`FocusQuietSection`, chiave
`focus_system_dnd`: `sempre` | `mai`; senza scelta vale «sempre» su Android e
Windows, «mai» su iOS/macOS). Nella schermata di Studio non c'è più la card
«Non disturbare».

| Sistema | Cosa fa l'app |
|---|---|
| Android | **Non disturbare** del telefono con regole proprie della sessione (`NotificationManager.setNotificationPolicy` + `setInterruptionFilter(INTERRUPTION_FILTER_PRIORITY)`): passano **sveglie**, **chiamate ripetute** (stessa persona entro 15 minuti), **chiamate dai contatti preferiti** e l'**audio dei contenuti** avviato dall'utente; messaggi, conversazioni, promemoria ed eventi sono bloccati (niente suono, vibrazione, comparsa sullo schermo; restano nella tendina). Serve l'«Accesso a Non disturbare» (`ACCESS_NOTIFICATION_POLICY`): le impostazioni mostrano se c'è e il pulsante «Concedi»; all'avvio senza permesso un dialogo spiega a cosa serve («Avvia senza» / «Concedi l'accesso»). A fine sessione tornano **filtro e regole di prima**; un allarme del sistema li ripristina alla fine prevista anche se l'app è stata chiusa. Da Android 15 (targetSdk 35) il sistema applica tutto a una regola automatica dell'app, senza toccare il Non disturbare dell'utente. |
| Windows 11 | Avvia la **sessione di concentrazione di Windows** (`Windows.UI.Shell.FocusSessionManager`), che attiva «Non disturbare», fino alla fine prevista e la chiude a fine sessione o alla chiusura dell'app. `IsSupported` e `GetDefault` funzionano anche da un'app non pacchettizzata; l'avvio è un'API ad accesso limitato e Windows può rifiutarlo: allora la schermata spiega come attivare «Non disturbare» (Win+N) e apre `ms-settings:notifications`. |
| iOS, macOS | **Nessuna API pubblica** permette a un'app di attivare una Full immersion (i *Focus filter* di iOS 16 fanno il contrario: adattano l'app alla Full immersion scelta dall'utente). Soluzione proposta: un **comando dell'app Comandi** di nome «UniNotes Focus» (istruzioni nelle impostazioni: «Ottieni date da input» → «Imposta Full immersion: Non disturbare, Attiva, Fino a: ora»). Con l'interruttore acceso, all'avvio l'app apre `shortcuts://run-shortcut?name=UniNotes%20Focus&input=text&text=<aaaa-mm-gg hh:mm>` (ora di fine) e il comando attiva il Non disturbare fino ad allora. Se la sessione finisce prima va spento dal Centro di Controllo (la schermata lo ricorda); se il comando non c'è, Comandi mostra il proprio errore. Senza comando la sessione spiega come attivarlo dal Centro di Controllo. |

## Obiettivo giornaliero e serie

Sessioni Studio mostra l'**obiettivo di oggi** (anello con la percentuale,
minuti fatti, quanto manca) e la **serie** di giorni consecutivi con
l'obiettivo raggiunto (e il record). L'obiettivo (30 minuti – 4 ore,
predefinito 1 ora) si cambia con «Cambia» (cursore, Annulla/Salva). Contano **tutte** le sessioni di
studio del giorno (Focus, cronometro, aggiunte a mano). Se oggi l'obiettivo
non è ancora raggiunto la serie resta quella fino a ieri; un giorno senza
obiettivo la interrompe.

## Cronologia e statistiche

- Le sessioni Focus sono normali sessioni di studio con `focus = 1`, il
  modulo (`module_id`) e la durata scelta (`planned_minutes`, pause
  comprese) — migrazione v9 dello schema; `duration_minutes` è il tempo di
  concentrazione, pause escluse. Compaiono nello storico di Sessioni Studio
  (icona Focus e «Focus» nella riga) e nelle Statistiche (riquadro «Di cui
  in Focus»).
- Sessioni Studio → «Focus questa settimana»: minuti e sessioni Focus della
  settimana.

## Logica e test

`focus_plan.dart` (tratti, posizione nel tempo, confini per gli avvisi),
`focus_timer.dart` (tempo a orologio, pause manuali, «Salta pausa», stato in
JSON), `focus_goal.dart` (minuti per giorno, serie, record),
`notification_plan.dart` (`quietAware`, `NotificationType.urgent`): tutti
coperti da `test/focus_test.dart`, compreso il salvataggio della sessione nel
database e il riquadro sopra le schermate.
