# Notifiche, calendario di sistema e promemoria

Le notifiche di UniNotes sono **locali**: l'app le pianifica in anticipo sul
dispositivo (flutter_local_notifications) e il sistema le mostra anche ad app
chiusa. Non c'è nessun server e nessuna notifica push. Le date delle prove
possono anche finire nel **calendario di sistema**, con i promemoria del
calendario.

Codice: `app/lib/core/reminders/` (logica pura in `agenda.dart`,
`notification_plan.dart`, `promo_rules.dart`; coordinamento in
`reminders_service.dart`), impostazioni in
`app/lib/features/settings/sections/notifications_section.dart` e
`calendar_section.dart`, test in `app/test/reminders_test.dart` e
`app/test/outlook_calendar_test.dart`.

## Tipi di notifica

| Tipo (canale Android) | Quando | Testo | Azioni | Come si disattiva | «Non chiedere più» |
|---|---|---|---|---|---|
| **Prove in arrivo** (`prove`) | Esami, prove in itinere, esoneri ancora da sostenere del corso attuale. Predefiniti: **il giorno prima** (alle 9:00, o 24 ore prima se la prova ha l'orario) e **un'ora prima** (solo con l'orario). Anticipi scelti in Impostazioni → Notifiche: 1, 2 o 3 ore prima e 1, 2, 3, 7, 14 giorni prima; valgono anche per i promemoria degli eventi nel calendario. Fra le 22:00 e le 7:00 arrivano senza suono (`nightQuiet`). | «Esame domani: Analisi I» · «martedì 12 gennaio alle 9:30 · Aula 1»; «Tra 1 ora: Analisi I» · «Esame alle 9:30 · Aula 1» | Tocco → scheda della prova | Interruttore «Prove in arrivo» | No |
| **Inizio sessione d'esame** (`sessioni`) | Il giorno prima dell'inizio di ogni sessione del corso (dal database `database/sessioni`), alle 9:00 | «Domani inizia la sessione d'esame» · «Sessione invernale, fino al 20 febbraio» | Tocco → Esami | Interruttore «Inizio sessione d'esame» | No |
| **Esito delle prove** (`esiti`) | Il giorno dopo una prova senza esito registrato, alle 18:00; una sola volta per prova (registrando l'esito prima, non arriva) | «Com'è andata?» · «Ieri avevi l'esame di Analisi I. Registra l'esito quando lo sai.» | «Registra l'esito» (apre la scheda), «Non ricordarmelo per questa prova» | Interruttore «Com'è andata?» | Solo per la singola prova |
| **Esami degli anni precedenti** (`anni_precedenti`) | Solo per chi ha iniziato a usare l'app dopo il 1° anno e ha ancora esami obbligatori «Da completare» (vedi [esami.md](esami.md#anni-precedenti)): alle 18:00 di 3 giorni dopo l'onboarding o il cambio di corso, e una sola ripetizione dopo 14 giorni | «Completa gli esami degli anni precedenti» · «3 esami del 1° e del 2° anno sono ancora da completare: indica quali hai già sostenuto.» | Tocco → Esami → Anni precedenti | Interruttore «Esami degli anni precedenti» | No (al massimo due, poi basta) |
| **Collegamenti interrotti** (`collegamenti`) | Quando OneDrive, Google Drive o il calendario Outlook falliscono per accesso scaduto o revocato (`invalid_grant`, AADSTS700082…); al massimo una ogni 3 giorni per servizio | «OneDrive non è più collegato» · «L'accesso è scaduto o è stato revocato. Ricollegati da Collegamenti…» | Tocco → Collegamenti (o Impostazioni per il calendario) | Interruttore «Collegamento interrotto» | No |
| **Registratore delle lezioni** (`registratore`) | Sul PC, quando chiudi la finestra durante una registrazione (l'app resta nell'area di notifica) o salvi dal menu dell'icona | «UniNotes continua a registrare» · «La registrazione di Analisi I va avanti: trovi UniNotes nell'area di notifica.» | Tocco → registratore | Conseguenza diretta di un tuo gesto: non dipende dagli interruttori | No |
| **Registrazione lezione** (`registrazione_in_corso`, Android; il vecchio canale `registrazione_lezione`, a importanza bassa, si elimina) | Per tutta la registrazione (servizio in primo piano), importanza predefinita senza suono né vibrazione: visibile anche a schermo bloccato | «Registrazione in corso» · «12:34 · Analisi I» (cronometro del sistema; «Registrazione in pausa» col tempo fermo). Layout proprio (`RecordingNotification.kt`): i pulsanti sono nella vista compressa, non serve espandere la notifica | «Pausa»/«Riprendi», «Salva» (stesso salvataggio dell'app, nome predefinito, nessuna domanda); tocco → registratore | Sparisce quando salvi; senza non si può registrare a schermo spento. Se l'utente la toglie dalla tendina (Android 14+) torna finché la registrazione continua | No |
| **Sessione Focus in corso** (`focus`, Android) | Per tutta la sessione Focus, silenziosa e fissa | «Focus: Analisi I · Limiti» · «Pausa alle 10:30» con il conto alla rovescia del sistema («Focus in pausa» col tempo fermo) | Tocco → sessione Focus | Sparisce a fine sessione | No |
| **Pause e fine della sessione Focus** (`focus_avvisi`) | Solo con l'app in background: inizio pausa, fine pausa, fine sessione | «È il momento di una pausa» · «5 minuti, poi si riparte.» | Tocco → sessione Focus | Conseguenza diretta della sessione avviata: non dipende dagli interruttori | No |
| **Recensione** (`recensione`, promozionale) | Una sola richiesta, dopo almeno 14 giorni dall'installazione e 5 giorni di uso effettivo, alle 18:00; mai entro 2 giorni da una prova, mai durante una registrazione | «Ti trovi bene con UniNotes?» · invito a una recensione (store) o a una stella o un commento (GitHub) | «Recensisci», «Più tardi» (dopo 30 giorni, al massimo 2 volte), «Non chiedere più» | Interruttore «Richiesta di recensione» | Sì |
| **Sostieni il progetto** (`sostegno`, promozionale) | Solo nelle build con `--dart-define=DONATIONS=link` (APK e versioni del sito per Windows e macOS, Microsoft Store). Dopo 30 giorni dall'installazione e 5 d'uso, poi al massimo ogni 6 mesi; mai nello stesso mese della richiesta di recensione, mai entro 7 giorni da una prova, mai durante una registrazione | «Sostieni UniNotes, se vuoi» · «UniNotes è gratuita e resta completa per tutti. Se ti è utile, una donazione aiuta a mantenerla. È del tutto facoltativo.» | «Dona», «Più tardi» (dopo 30 giorni), «Non chiedere più» | Interruttore «Sostieni il progetto» (attivo di default solo in quelle build) | Sì |

«Prova una notifica» (Impostazioni → Notifiche) ne mostra subito una d'esempio.

Su iOS, durante una registrazione, al posto della notifica col tempo c'è la
Live Activity (schermata di blocco e Dynamic Island), se l'estensione è stata
aggiunta in Xcode: vedi [widget.md](widget.md) e
[registratore.md](registratore.md).

### Dove porta la recensione

| Build | Link |
|---|---|
| Android per Google Play (AAB, senza `DONATIONS=link`, o `STORE=play`) | `market://details?id=io.github.simomagnus.universitynotes`, se non si apre `https://play.google.com/store/apps/details?id=…` |
| iPhone e iPad dall'App Store (`STORE=appstore`) | `itms-apps://itunes.apple.com/app/id<APPSTORE_ID>?action=write-review` con `--dart-define=APPSTORE_ID`; senza ID **nessuna** richiesta |
| Microsoft Store (`STORE=microsoft` e `MSSTORE_ID`) | `ms-windows-store://review/?ProductId=…` |
| GitHub (APK, Windows, macOS con `DONATIONS=link`) | `https://github.com/Simo-Magnus/UniNotes` (stella o commento) |

Lo stato «già chiesta / non chiedere più» è condiviso con l'invito nella
Home (`core/services/nudges.dart`): chi ha già risposto in un posto non viene
richiesto nell'altro.

## Regola calendario ↔ notifiche

Niente doppioni. Se il **collegamento al calendario di sistema è attivo e
funzionante** e una prova (o l'inizio di una sessione) **è nel calendario**
(scritta da questo dispositivo o, con la regola dei dispositivi, da quello
che aggiorna il calendario dell'account), l'app **non** pianifica le proprie
notifiche per quella prova: gli avvisi arrivano dal calendario, con gli
stessi anticipi. Altrimenti le pianifica lei («calendario interno»). L'app
manda comunque le notifiche che il calendario non può dare («Com'è andata?»,
anni precedenti, collegamenti).

«Funzionante» vuol dire: l'ultima sincronizzazione è riuscita senza errori e
il permesso (telefono) o il token (Outlook) è valido. Lo stato, con la data
dell'ultima sincronizzazione riuscita, è salvato nelle impostazioni
(`syscal_ok`, `syscal_last_ok`, `syscal_error`) e mostrato in Impostazioni →
Calendario. Se il collegamento smette di funzionare (permesso tolto, token
scaduto, errore di scrittura), alla ripianificazione successiva le notifiche
dell'app tornano **per tutte le prove**.

## Durante una sessione Focus

Mentre una sessione Focus è in corso (Studio → Sessioni Studio → Timer, vedi
[focus.md](focus.md)) l'app fa da «Non disturbare» per sé stessa:

- gli avvisi **urgenti** (`NotificationType.urgent`: prove in arrivo,
  inizio sessione d'esame, registratore, Focus) restano dove sono;
- quelli **non urgenti** («Com'è andata?», anni precedenti, collegamento interrotto,
  recensione, sostegno) che cadrebbero prima della fine prevista si spostano
  a un minuto dopo la fine (`quietAware` in `notification_plan.dart`; per
  «Collegamento interrotto» l'avviso si pianifica invece di comparire
  subito);
- recensione e sostegno non si propongono durante la sessione, come durante
  una registrazione.

All'inizio e alla fine della sessione le notifiche si ripianificano (come per
la registrazione). Il canale Android `focus_avvisi` (inizio e fine pausa,
fine sessione) è creato con `bypassDnd` e usa la categoria «sveglia»: passa
anche con il Non disturbare della sessione Focus. Android lo concede solo
con l'«Accesso a Non disturbare»: se l'accesso arriva dopo la creazione del
canale, `FocusDnd.enable` (Kotlin) aggiorna il canale all'avvio della
sessione. Il silenzio del **sistema** (Non disturbare di Android,
sessione di concentrazione di Windows, Full immersion di iOS e macOS) è
descritto in [focus.md](focus.md#non-disturbare).

## Calendario di sistema

Interruttore in Impostazioni → Calendario, con la richiesta del permesso del
sistema solo quando lo si attiva. Si scrivono **eventi** (non attività:
Google Tasks e Promemoria Apple non sono nel Calendar Provider di Android né
uguali fra le piattaforme, gli eventi hanno ovunque i promemoria nativi):
esami, prove in itinere ed esoneri ancora da sostenere del corso attuale
(dal database e aggiunti a mano) e la data d'inizio delle sessioni d'esame.

**Evento.** Titolo «Esame: Analisi I» / «Prova in itinere/esonero: Fisica ·
Esonero 1»; inizio all'ora della prova e fine 2 ore dopo (giornata intera se
manca l'ora); luogo; descrizione con argomenti e note e la riga
`Rif. UniNotes: <chiave>` (es. `esame-12`,
`sessione-20270111-sessione-invernale`), con cui l'app ritrova i propri
eventi, li aggiorna, li cancella e toglie i doppioni. Promemoria nativi
(Android `METHOD_ALERT`, EventKit `EKAlarm`) agli anticipi scelti
(predefiniti: il giorno prima e un'ora prima). Modifica della prova → evento
aggiornato; prova sostenuta, annullata o eliminata → evento tolto.

**Dove: il calendario vero dello studente**, non più un calendario «UniNotes»
a parte (scelta in Impostazioni → Calendario, «Calendario usato», con nome,
account e colore; senza scelta il predefinito):

- **Android** (`device_calendar_backend.dart` → `AndroidCalendarBackend`,
  codice nativo `android/.../UniNotesCalendar.kt`, canale
  `io.github.simomagnus.universitynotes/calendario`): solo calendari
  scrivibili, con `SYNC_EVENTS=1` e di un account vero (Google, Samsung,
  Exchange…), mai locali; predefinito il principale dell'account Google
  (`IS_PRIMARY` o `OWNER_ACCOUNT` = nome dell'account). Prima l'app creava con
  `device_calendar` un calendario locale «UniNotes» (account locale,
  `SYNC_EVENTS=0`) che Google Calendar mostrava con **«Sync error»**: i suoi
  eventi si spostano nel calendario scelto e il calendario si elimina (come
  sync adapter, solo se è dell'app e vuoto). Il pacchetto `device_calendar`
  non si usa più (si può togliere dal `pubspec.yaml`).
- **iOS e macOS**: EventKit con codice nativo (`UniNotesCalendar` in
  `ios/Runner/AppDelegate.swift` e `macos/Runner/MainFlutterWindow.swift`,
  stesso canale, lato Dart `apple_calendar_backend.dart`): il calendario
  predefinito per i nuovi eventi (o quello scelto); su iPhone senza iCloud va
  bene anche «Sul mio iPhone». Il calendario «UniNotes» delle versioni
  precedenti si svuota e si toglie. Ricerca a blocchi di un anno (EventKit
  cerca al massimo 4 anni per volta). Accesso completo
  (`requestFullAccessToEvents` da iOS 17/macOS 14). Sul Mac: entitlement
  `com.apple.security.personal-information.calendars`.
- **Windows**: calendario Outlook dell'account Microsoft già collegato per
  OneDrive, con Microsoft Graph (`outlook_calendar_backend.dart`). Lo scope
  delegato `Calendars.ReadWrite` si chiede con il consenso dinamico solo
  quando si attiva il calendario (token separato da quello di OneDrive).
  **Causa del «niente nel calendario» (22/10/2026)**: gli eventi venivano
  scritti (stato «Collegamento funzionante») in un calendario a parte
  «UniNotes» creato con `POST /me/calendars`, che Outlook elenca sotto «I miei
  calendari» ma spesso non mostra (casella non spuntata, app Calendario di
  Windows, Outlook sul telefono). Ora vanno nel calendario principale
  dell'account (`isDefaultCalendar`, o quello scelto), quelli vecchi si
  spostano e «UniNotes» vuoto si elimina; lo stato dice in quale calendario e
  di quale account sono. Gli eventi dell'app si leggono con un filtro sulla
  proprietà estesa (`singleValueExtendedProperties/Any(…)`), così nel
  calendario principale non si scorrono quelli dello studente; se Graph non
  accetta il filtro si legge il periodo da 400 giorni fa a 3 anni da oggi
  (`calendarView`). Un solo promemoria per evento (limite di Outlook): il più
  vicino alla prova.
- Il file .ics (`calendar_export.dart`) resta solo per un sistema senza
  calendario collegabile.

**Fuso orario delle prove (22/10/2026).** L'ora di una prova («09:30») è l'ora
dell'ateneo, cioè Europe/Rome (come in `docs/database_format.md`), e non
dipende dal fuso del telefono: chi è in un altro fuso (viaggio, Erasmus) deve
vedere la prova all'ora che corrisponde a quella italiana. Lo stesso criterio
vale ovunque:

- **.ics**: `DTSTART;TZID=Europe/Rome:20270120T093000`, con il `VTIMEZONE`
  completo (regole dell'ora legale europea) nel file. Le cifre sono quelle
  salvate, mai convertite nel fuso del dispositivo; la fine (+2 ore) si calcola
  sulle stesse cifre. Perché non «ora fluttuante» (senza `TZID`): il calendario
  la riporterebbe all'ora del telefono e la prova si sposterebbe; non UTC
  con `Z`: perderebbe l'ora legale se l'evento si modificasse a mano. La
  giornata intera resta `VALUE=DATE` (senza ora né fuso, RFC 5545).
- **Android, iOS, macOS e Outlook**: si scrive l'istante (UTC) dell'ora
  italiana (`romeWallToUtc` in `agenda.dart`, `AgendaItem.startInstant`),
  che il calendario mostra nel fuso del telefono; prima si usava l'ora del
  telefono, uguale solo per chi è in Italia. La giornata intera resta come
  prima (mezzanotte UTC su Android e Outlook, mezzanotte locale su Apple).
- Le notifiche dell'app (sopra) non cambiano: restano agli istanti locali del
  dispositivo (9:00 del giorno N prima, un'ora prima, ecc.).
- Date al limite di `DateTime` (anno 275760): niente eccezioni, la prova vale
  una giornata intera / fine uguale all'inizio.

**Controllo di salute** (all'avvio, al ritorno nell'app, dopo ogni modifica e
una volta al giorno): permesso concesso, calendario ancora esistente e
scrivibile, `SYNC_EVENTS=1`, eventi dell'app riletti (quelli tolti a mano si
ricreano); su Android anche la sincronizzazione automatica dell'account
(`ContentResolver.getSyncAutomatically` + `getMasterSyncAutomatically`): se è
spenta gli eventi si scrivono lo stesso (il telefono avvisa comunque) con un
avviso in Impostazioni. Un problema grave → **calendario interno**.

**Calendario interno** (nessun calendario sincronizzato, permesso tolto,
calendario sparito): l'agenda è quella dell'app (prove e sessioni nel
database, `buildAgenda`), nessun calendario visibile nel telefono; le
notifiche le pianifica l'app (Android: all'ora esatta se il sistema lo
consente, «Avvisi puntuali» in Impostazioni → Calendario chiede
`SCHEDULE_EXACT_ALARM`, altrimenti inesatte; iOS: le 60 più vicine,
ripianificate a ogni apertura e aggiornamento; Windows e macOS: notifiche
pianificate). Se il calendario torna a funzionare le notifiche dell'app per
le prove spariscono da sole.

**Un solo dispositivo scrive per account.** Con i dati sincronizzati fra
dispositivi (OneDrive/Google Drive), l'impostazione sincronizzata
`syscal_writers` dice quale dispositivo aggiorna il calendario di ogni
account (`device:<account>`, `outlook:<indirizzo>`): il primo che lo collega.
Gli altri leggono soltanto gli eventi (per non mandare notifiche doppie) e
mostrano «Calendario aggiornato dal telefono» con «Aggiorna da questo
dispositivo». Se il dispositivo che scriveva non si sente da 21 giorni, il
posto passa a chi sincronizza; spegnendo il calendario su di lui il posto si
libera. Un segno con l'orario nel futuro (dispositivo con l'orologio avanti)
vale come scritto adesso e da lì invecchia, come in «Orologi diversi» della
sincronizzazione: non blocca più gli altri per mesi. Anche se due dispositivi scrivessero insieme, la chiave nella
descrizione fa togliere il doppione.

**Quando si propone il calendario.** Sul telefono (Android, iOS) un passo
dell'onboarding, dopo gli avvisi: «Vuoi le prove nel calendario?» con «Non
ora» e «Collega il calendario» (chiede il permesso del sistema). Il passo
segna `syscal_offered`, così il primo salvataggio di una prova con una data
(`offerExamCalendar` in `exam_form.dart`) non lo richiede di nuovo. Su
Windows (Outlook, serve l'account Microsoft) e per chi ha saltato
l'onboarding la proposta arriva al primo salvataggio di una prova con una
data, una volta sola; poi si decide da Impostazioni → Calendario.

Spegnendo l'interruttore l'app toglie i propri eventi dal calendario (solo
sul dispositivo che li scrive). Test: `app/test/calendar_sync_test.dart`,
`app/test/outlook_calendar_test.dart`, `app/test/system_links_test.dart`.

## Permessi e consenso

- **Primo ingresso**: penultimi passi dell'onboarding (dopo la scelta
  dell'AI di riferimento e della lingua delle lezioni), passo «Vuoi gli
  avvisi?» che spiega cosa arriva
  (prove 7 giorni prima e il giorno prima, fine del timer e delle pause
  anche con il Non disturbare, registrazione in corso fuori dall'app, una
  sola richiesta di recensione e l'eventuale invito al sostegno) **prima**
  del dialogo del sistema. Due pulsanti: «Non ora» (segna `notif_asked`,
  non si richiede più) e «Attiva gli avvisi» (`enableNotifications`: chiede
  il permesso del sistema e salva il consenso). Mai richieste all'avvio a
  freddo dell'app già configurata.
- Chi ha già fatto l'onboarding con una versione precedente (o ha saltato
  il passo perché il sistema non ha notifiche) riceve la richiesta
  contestuale: la prima volta che si salva una prova con una data (dialogo
  «Vuoi un avviso prima delle prove?», una sola volta), oppure usa
  l'interruttore «Notifiche di UniNotes». Senza consenso l'app non
  pianifica nulla.
- Android 13+: `POST_NOTIFICATIONS`. Prove e sessioni all'ora esatta
  (`exactAllowWhileIdle`) se lo studente concede «Sveglie e promemoria»
  (`SCHEDULE_EXACT_ALARM`, pulsante «Avvisi puntuali» con il calendario
  interno), altrimenti inesatte (`inexactAllowWhileIdle`, qualche minuto di
  ritardo).
  `RECEIVE_BOOT_COMPLETED` e i receiver del pacchetto ripianificano dopo il
  riavvio. Calendario: `READ_CALENDAR`, `WRITE_CALENDAR`.
- iOS: permesso delle notifiche (avvisi e suoni) e del calendario
  (`NSCalendarsFullAccessUsageDescription`, `NSCalendarsUsageDescription`).
- macOS: permesso delle notifiche.
- Windows: versione del sito non pacchettizzata, inizializzazione con nome
  «UniNotes», AppUserModelID (AUMID) `SimoMagnus.UniNotes` e GUID fisso
  `5d3f2b7e-91c4-4a8e-b6f1-0c7a2e9d4b13` (attivazione al tocco anche ad app
  chiusa); vedi `windows_aumid.dart`.
  - **Logo in cima al toast.** Accanto a «UniNotes» Windows mette l'`IconUri`
    della chiave `HKCU\Software\Classes\AppUserModelId\<AUMID>`. Il pacchetto
    delle notifiche la scrive all'inizializzazione, quindi prima di qualsiasi
    toast, con il percorso assoluto di
    `data\flutter_assets\assets\notifiche\uninotes.png`; poi l'app la
    ricontrolla e se serve la riscrive (`windows_toast_icon.dart`, rete di
    sicurezza).
  - **Perché l'AUMID è cambiato.** Fino a ottobre 2026 era
    `io.github.simomagnus.universitynotes`. Windows memorizza nome e icona di
    un AUMID al primo toast, e le versioni vecchie mandavano il primo toast con
    l'`IconUri` ancora vuoto: da lì in poi il logo non compariva più, neanche
    con l'`IconUri` corretto (verificato: con un AUMID nuovo e l'`IconUri`
    scritto prima del primo toast il logo c'è).
  - **Passaggio una volta sola** (primo avvio della versione nuova, solo
    senza pacchetto MSIX): il codice nativo (canale
    `io.github.simomagnus.universitynotes/notifiche`, metodo `migraAumid`,
    `windows/runner/notification_identity.cpp`) toglie i toast pianificati e
    la cronologia del vecchio AUMID (`RemoveFromSchedule`,
    `History.ClearWithId`), così i promemoria non arrivano doppi, ed elimina
    le sue chiavi del registro (`AppUserModelId`,
    `PushNotifications\Backup`, `Notifications\Settings`: niente seconda voce
    «UniNotes» nelle impostazioni delle notifiche). Poi il servizio dei
    promemoria, che a ogni avvio cancella e ripianifica tutto, li ripianifica
    con l'AUMID nuovo. Fatto, si segna nelle impostazioni
    (`uninotes_aumid_windows_migrato`); un errore non blocca l'avvio e si
    riprova al prossimo.
  - **Collegamento con l'AUMID** (metodo ufficiale per le app desktop non
    pacchettizzate): i collegamenti dell'installatore nel menu Start e sul
    desktop hanno `AppUserModelID` `SimoMagnus.UniNotes` e
    `AppUserModelToastActivatorCLSID` uguale al GUID qui sopra
    (`app/windows/installer/uninotes.iss`); il processo dichiara lo stesso
    AUMID all'avvio, prima di qualsiasi finestra
    (`SetCurrentProcessExplicitAppUserModelID` in `windows/runner/main.cpp`,
    solo senza identità di pacchetto). Finestra, collegamento e toast sono la
    stessa app per la barra delle applicazioni. Chi aveva **fissato UniNotes
    sulla barra delle applicazioni** con una versione precedente deve
    toglierlo e rimetterlo una volta (il vecchio pulsante non ha l'AUMID e
    resterebbe separato dalla finestra).
  - Disinstallando si tolgono le chiavi dell'AUMID nuovo e di quello vecchio.
  - Microsoft Store (MSIX): l'AUMID lo decide il pacchetto e non cambia nulla
    (al pacchetto delle notifiche si passa ancora l'AUMID vecchio, che con
    l'identità di pacchetto si ignora; niente passaggio); l'attivazione dalle
    notifiche è registrata nel manifest (`app/windows/msix/AppxManifest.xml`).

## Dettagli tecnici

- **ID stabili**: FNV-1a a 31 bit di `tipo:chiave` (es.
  `exam:esame-12:7`), sopra 100000 per non toccare gli ID di altri
  componenti (es. la notifica «Registrazione in corso»).
- **Ripianificazione completa** all'avvio, a ogni `revision.bump()` (con
  ritardo), al cambio delle impostazioni, all'inizio e alla fine di una
  registrazione: si cancellano le notifiche ancora future pianificate la
  volta prima (non quelle già mostrate) e si ricreano.
- Orari: l'istante locale convertito in UTC (`TZDateTime.from(…, tz.UTC)`),
  senza leggere il fuso del sistema.
- iOS tiene al massimo 64 notifiche in attesa: l'app ne pianifica al
  massimo 60, le più vicine.
- I pulsanti «Più tardi», «Non chiedere più» e «Non ricordarmelo per
  questa prova» funzionano senza aprire l'app (Android, iOS): un isolate in
  background li mette in coda e l'app li applica al successivo avvio o
  ritorno. Una richiesta di recensione o sostegno passata senza risposta
  conta come mostrata.
- Icona piccola Android: `drawable-*/ic_stat_uninotes.png`, sagoma bianca del
  logo, la U con il tocco di laurea (`python tools/genera_icona.py
  --notifiche`, dal logo vettoriale `docs/logo.svg`), colore d'accento
  azzurro `#0284C7` (leggibile sulla tendina chiara e su quella scura);
  `res/raw/keep.xml` la protegge dalla riduzione delle risorse. La usa anche
  la notifica «Registrazione in corso» (meta-dato
  `io.github.simomagnus.universitynotes.NOTIFICATION_ICON` nel manifest).

## Aspetto per piattaforma

Ogni tipo ha una grafica con i colori del logo (quadrato blu con la zona in
ombra in basso a destra come nella «U», simbolo bianco del tipo); il logo
dell'app, su una tessera bianca, è il logo dei toast di Windows, l'icona
grande delle notifiche di Android e sta a sinistra nelle immagini larghe
(fondo dal blu notte al blu). Le genera
`python app/tool/genera_grafiche_notifiche.py`: calendario per le prove,
tocco per le sessioni, spunta per gli esiti, catena spezzata per i
collegamenti, microfono, cronometro e sveglia per Focus, stella e cuore
per recensione e sostegno, rotolo con la piuma per gli anni precedenti. Le
notifiche sono raggruppate per sezione dell'app: **Esami** (prove,
sessioni, esiti, anni precedenti), **Studio** (Focus),
**Registra**, **Collegamenti**, più **UniNotes** per le promozionali.
Il codice è in `LocalNotificationPlatform.detailsFor` (test in
`app/test/notification_design_test.dart`).

- **Android**: icona piccola monocromatica e azzurro dell'app; icona
  grande a destra = il logo dell'app (`res/drawable-nodpi/
  ic_notif_uninotes.png`), come su iPhone e iPad: niente calendario,
  microfono e simili. Fanno eccezione la richiesta di recensione e quella di
  sostegno (stella e cuore, `ic_notif_recensione.png` e
  `ic_notif_sostegno.png`) e la registrazione in corso, che ha un layout
  proprio (`RecordingNotification.kt`); la sessione Focus in corso usa il
  logo dell'app (`NotificationType.androidLargeIcon`); la accanto al nome dell'app; testo esteso (le prove: elenco con
  una riga per data e ora e una per il luogo); pulsanti. Nelle impostazioni
  del sistema i canali sono divisi nei gruppi Esami, Studio, Registra,
  Collegamenti e UniNotes. Il raggruppamento nella tendina lo fa il sistema
  (da 4 notifiche dell'app in su): una notifica di riepilogo per le
  notifiche pianificate richiederebbe codice al momento della consegna.
- **iOS e macOS**: la sezione come sottotitolo, notifiche impilate per
  sezione (`threadIdentifier` `uninotes_esami`, …); per l'inizio sessione
  l'immagine larga è allegata (miniatura a destra, intera aprendo la
  notifica); per recensione e sostegno l'allegato è un quadrato con la sola
  stella o il solo cuore (`recensione.png`, `sostegno.png`), così accanto al
  logo dell'app a sinistra non se ne sovrappone un altro
  (`NotificationType.darwinAttachment`). Pulsanti dalle categorie
  registrate all'avvio.
- **Windows**: logo dell'app registrato per i toast (`assets/notifiche/
  uninotes.png`, prima Windows mostrava un'icona vuota), logo del tipo al
  posto di quello dell'app nel toast, immagine larga in cima per inizio
  sessione, recensione e sostegno (`hero_<canale>.png`), intestazione della
  sezione nel Centro notifiche (un clic apre la sezione), toast lunghi per
  prove, sessioni, esiti e avvisi Focus, pulsanti.
- **Linux**: le notifiche non sono attive (nessuna versione per Linux).

## Note legali e regole degli store

- **Apple 4.5.4**: le notifiche non vanno usate per promozioni o marketing
  diretto senza il consenso esplicito dell'utente, con la possibilità di
  disattivarle nell'app. Recensione e sostegno sono quindi trattate come
  promozionali: il dialogo di consenso le nomina, hanno un interruttore
  ciascuna e «Non chiedere più»; sull'App Store il sostegno non esiste
  proprio (vedi sotto).
- **Apple 3.1.1 e Google Play (Payments)**: nelle app distribuite dagli store
  non si possono indirizzare gli utenti a pagamenti esterni per sostenere
  l'app con link o inviti. Per questo la notifica «Sostieni il progetto»
  esiste solo nelle build con `DONATIONS=link` (sito, GitHub e Microsoft
  Store, che ammette le donazioni volontarie con un pagamento di terze parti
  dichiarato), mai nell'AAB per Play né su iOS.
- **UE/Italia**: una richiesta di donazione volontaria, chiara e non
  ingannevole a sostegno di un progetto gratuito è lecita; il testo dice che
  è facoltativa e che l'app resta gratuita e completa, senza scadenze finte,
  sensi di colpa o funzioni bloccate. Nessun dark pattern: «Non chiedere
  più» è sempre visibile e vale per sempre.

## Privacy

Tutto avviene sul dispositivo: notifiche pianificate dal sistema, nessun
server, nessun dato inviato allo sviluppatore. Attivando il calendario, le
date delle prove (insegnamento, data, ora, luogo, argomenti e note) vengono
scritte nel calendario dell'utente; se quel calendario è sincronizzato con
un servizio online, finiscono anche lì secondo le sue regole. Su Windows gli
eventi vengono inviati a Microsoft Graph, sull'account Microsoft dell'utente.
Vedi `PRIVACY.md`, paragrafo «Calendario» e «Notifiche».
