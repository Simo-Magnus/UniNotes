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

| Tipo (canale Android) | Quando | Testo | Azioni | Come si disattiva | «Non chiedermelo più» |
|---|---|---|---|---|---|
| **Prove in arrivo** (`prove`) | Esami, prove in itinere, esoneri ancora da sostenere del corso attuale: 7 giorni prima e il giorno prima alle 9:00; se la prova ha l'orario, l'avviso del giorno prima arriva 24 ore prima. Anticipi scelti in Impostazioni → Notifiche (1, 2, 3, 7, 14 giorni). | «Esame domani: Analisi I» · «martedì 12 gennaio alle 9:30 · Aula 1» | Tocco → scheda della prova | Interruttore «Prove in arrivo» | No |
| **Inizio sessione d'esame** (`sessioni`) | Il giorno prima dell'inizio di ogni sessione del corso (dal database `database/sessioni`), alle 9:00 | «Domani inizia la sessione d'esame» · «Sessione invernale, fino al 20 febbraio» | Tocco → Esami | Interruttore «Inizio sessione d'esame» | No |
| **Com'è andata?** (`esiti`) | Il giorno dopo una prova senza esito registrato, alle 18:00; una sola volta per prova (registrando l'esito prima, non arriva) | «Com'è andata?» · «Ieri avevi l'esame di Analisi I. Registra l'esito quando lo sai.» | «Registra l'esito» (apre la scheda), «Non ricordarmelo per questa prova» | Interruttore «Com'è andata?» | Solo per la singola prova |
| **Collegamento interrotto** (`collegamenti`) | Quando OneDrive, Google Drive o il calendario Outlook falliscono per accesso scaduto o revocato (`invalid_grant`, AADSTS700082…); al massimo una ogni 3 giorni per servizio | «OneDrive non è più collegato» · «L'accesso è scaduto o è stato revocato. Ricollegati da Collegamenti…» | Tocco → Collegamenti (o Impostazioni per il calendario) | Interruttore «Collegamento interrotto» | No |
| **Registratore delle lezioni** (`registratore`) | Sul PC, quando chiudi la finestra durante una registrazione (l'app resta nell'area di notifica) o salvi dal menu dell'icona | «UniNotes continua a registrare» · «La registrazione di Analisi I va avanti: trovi UniNotes nell'area di notifica.» | Tocco → registratore | Conseguenza diretta di un tuo gesto: non dipende dagli interruttori | No |
| **Registrazione lezione** (`registrazione_lezione`, Android) | Per tutta la registrazione (servizio in primo piano) | «Registrazione in corso» · «Analisi I · 00:12:34» (tempo aggiornato ogni secondo; «Registrazione in pausa» col tempo fermo) | «Pausa»/«Riprendi», «Salva»; tocco → registratore | Sparisce quando salvi; senza non si può registrare a schermo spento | No |
| **Sessione Focus in corso** (`focus`, Android) | Per tutta la sessione Focus, silenziosa e fissa | «Focus: Analisi I · Limiti» · «Pausa alle 10:30» con il conto alla rovescia del sistema («Focus in pausa» col tempo fermo) | Tocco → sessione Focus | Sparisce a fine sessione | No |
| **Fine della sessione Focus e delle pause** (`focus_avvisi`) | Solo con l'app in background: inizio pausa, fine pausa, fine sessione | «È il momento di una pausa» · «5 minuti, poi si riparte.» | Tocco → sessione Focus | Conseguenza diretta della sessione avviata: non dipende dagli interruttori | No |
| **Recensione** (`recensione`, promozionale) | Una sola richiesta, dopo almeno 14 giorni dall'installazione e 5 giorni di uso effettivo, alle 18:00; mai entro 2 giorni da una prova, mai durante una registrazione | «Ti trovi bene con UniNotes?» · invito a una recensione (store) o a una stella o un commento (GitHub) | «Recensisci», «Più tardi» (dopo 30 giorni, al massimo 2 volte), «Non chiedermelo più» | Interruttore «Richiesta di recensione» | Sì |
| **Sostieni il progetto** (`sostegno`, promozionale) | Solo nelle build con `--dart-define=DONATIONS=link` (APK e versioni del sito per Windows e macOS, Microsoft Store). Dopo 30 giorni dall'installazione e 5 d'uso, poi al massimo ogni 6 mesi; mai nello stesso mese della richiesta di recensione, mai entro 7 giorni da una prova, mai durante una registrazione | «Sostieni UniNotes, se vuoi» · «UniNotes è gratuita e resta completa per tutti. Se ti è utile, una donazione aiuta a mantenerla. È del tutto facoltativo.» | «Dona», «Più tardi» (dopo 30 giorni), «Non chiedermelo più» | Interruttore «Sostieni il progetto» (attivo di default solo in quelle build) | Sì |

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

Lo stato «già chiesta / non chiedermelo più» è condiviso con l'invito nella
Home (`core/services/nudges.dart`): chi ha già risposto in un posto non viene
richiesto nell'altro.

## Regola calendario ↔ notifiche

Se il **collegamento al calendario di sistema è attivo e funzionante** e una
prova (o l'inizio di una sessione) **è stata scritta con successo** nel
calendario, l'app **non** pianifica le proprie notifiche per quella prova: gli
avvisi arrivano dal calendario, con gli stessi anticipi. Altrimenti le
pianifica lei.

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
- quelli **non urgenti** («Com'è andata?», collegamento interrotto,
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
sistema solo quando lo si attiva. Si scrivono: esami, prove in itinere ed
esoneri ancora da sostenere del corso attuale (dal database e aggiunti a
mano) e la data d'inizio delle sessioni d'esame del corso.

- **Android**: calendario del dispositivo con `device_calendar`, in un
  calendario locale «UniNotes» (azzurro dell'app); se non si può creare, nel
  calendario predefinito.
- **iOS e macOS**: EventKit con codice nativo (`UniNotesCalendar` in
  `ios/Runner/AppDelegate.swift` e `macos/Runner/MainFlutterWindow.swift`,
  canale `io.github.simomagnus.universitynotes/calendario`, lato Dart
  `apple_calendar_backend.dart`, test in `app/test/system_links_test.dart`).
  Il calendario «UniNotes» nasce nell'account dove l'utente vede i suoi
  calendari (iCloud se attivo, altrimenti sul dispositivo): con
  `device_calendar` su iPhone finiva «Sul mio iPhone», che con iCloud attivo
  l'app Calendario non mostra; un calendario così rimasto da una versione
  precedente viene svuotato degli eventi dell'app ed eliminato se vuoto. Gli
  eventi si aggiornano sul posto (stesso id; se l'evento è stato tolto a
  mano si ricrea), la ricerca va a blocchi di un anno (EventKit cerca al
  massimo 4 anni per volta). Accesso completo (`requestFullAccessToEvents`
  da iOS 17/macOS 14; con l'accesso «solo aggiunta» l'app non può evitare i
  doppioni e lo considera non concesso). Sul Mac: entitlement
  `com.apple.security.personal-information.calendars` e testi del permesso
  nell'Info.plist.
- Android, iOS e macOS: ogni evento porta nella descrizione la riga `Rif. UniNotes: <chiave>` (es.
  `esame-12`, `sessione-20270111-sessione-invernale`): l'app ritrova così i
  propri eventi, li aggiorna o li cancella e toglie i doppioni. Promemoria
  dell'evento agli stessi istanti delle notifiche.
- **Windows**: calendario Outlook dell'account Microsoft già collegato per
  OneDrive, con Microsoft Graph. Lo scope delegato `Calendars.ReadWrite` si
  chiede con il consenso dinamico solo quando si attiva il calendario: prima
  in silenzio (se il consenso c'è già), poi con la pagina di Microsoft
  sull'account collegato; il token è separato da quello di OneDrive, il cui
  flusso non cambia. Calendario «UniNotes» creato con `POST /me/calendars`;
  ogni evento ha la chiave in una proprietà estesa invisibile
  (`singleValueExtendedProperties`) e il suo id è salvato localmente;
  `reminderMinutesBeforeStart` è uno solo per evento (limite di Outlook): si
  usa l'anticipo più vicino alla prova. Senza account Microsoft collegato la
  sezione lo spiega e porta a Collegamenti.
- Il file .ics (`calendar_export.dart`) resta solo per un sistema senza
  calendario collegabile: su Android, iOS, macOS e Windows non c'è più (né nelle Impostazioni,
  né nell'onboarding, né dopo «Aggiorna database»): le prove si aggiungono a
  mano in Esami (o arrivano dal database) e il calendario di sistema le
  riceve da solo.

**Quando si propone il calendario.** Sul telefono (Android, iOS) un passo
dell'onboarding, dopo gli avvisi: «Vuoi le prove nel calendario?» con «Non
ora» e «Collega il calendario» (chiede il permesso del sistema). Il passo
segna `syscal_offered`, così il primo salvataggio di una prova con una data
(`offerExamCalendar` in `exam_form.dart`) non lo richiede di nuovo. Su
Windows (Outlook, serve l'account Microsoft) e per chi ha saltato
l'onboarding la proposta arriva al primo salvataggio di una prova con una
data, una volta sola; poi si decide da Impostazioni → Calendario.

Spegnendo l'interruttore l'app toglie i propri eventi dal calendario. La
sincronizzazione parte all'avvio, dopo ogni modifica delle prove
(`revision.bump()`, con un ritardo di 2 secondi), al cambio di corso o
percorso e al ritorno nell'app.

Nota sulla dipendenza: `device_calendar` 4.3.3 (ultima versione) chiede
`timezone ^0.9`, `flutter_local_notifications` 22 chiede `^0.11`; il
`pubspec.yaml` forza `timezone ^0.11` (`dependency_overrides`): le API usate
dal pacchetto sono invariate (verificato in compilazione e nei test).

## Permessi e consenso

- **Primo ingresso**: penultimi passi dell'onboarding (dopo la scelta
  dell'AI di riferimento), passo «Vuoi gli avvisi?» che spiega cosa arriva
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
- Android 13+: `POST_NOTIFICATIONS`. Pianificazione **inesatta**
  (`AndroidScheduleMode.inexactAllowWhileIdle`): niente
  `SCHEDULE_EXACT_ALARM`, qualche minuto di ritardo è accettabile.
  `RECEIVE_BOOT_COMPLETED` e i receiver del pacchetto ripianificano dopo il
  riavvio. Calendario: `READ_CALENDAR`, `WRITE_CALENDAR`.
- iOS: permesso delle notifiche (avvisi e suoni) e del calendario
  (`NSCalendarsFullAccessUsageDescription`, `NSCalendarsUsageDescription`).
- macOS: permesso delle notifiche.
- Windows: versione del sito non pacchettizzata, inizializzazione con nome
  «UniNotes», AppUserModelID `io.github.simomagnus.universitynotes` e GUID
  fisso (attivazione al tocco anche ad app chiusa); nella versione del
  Microsoft Store (MSIX) l'attivazione dalle notifiche è registrata nel
  manifest (`app/windows/msix/AppxManifest.xml`).

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
- I pulsanti «Più tardi», «Non chiedermelo più» e «Non ricordarmelo per
  questa prova» funzionano senza aprire l'app (Android, iOS): un isolate in
  background li mette in coda e l'app li applica al successivo avvio o
  ritorno. Una richiesta di recensione o sostegno passata senza risposta
  conta come mostrata.
- Icona piccola Android: `drawable-*/ic_stat_uninotes.png`, sagoma bianca del
  logo (`python tools/genera_icona.py --notifiche`), colore d'accento
  azzurro `#38BDF8`; `res/raw/keep.xml` la protegge dalla riduzione delle
  risorse.

## Note legali e regole degli store

- **Apple 4.5.4**: le notifiche non vanno usate per promozioni o marketing
  diretto senza il consenso esplicito dell'utente, con la possibilità di
  disattivarle nell'app. Recensione e sostegno sono quindi trattate come
  promozionali: il dialogo di consenso le nomina, hanno un interruttore
  ciascuna e «Non chiedermelo più»; sull'App Store il sostegno non esiste
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
  sensi di colpa o funzioni bloccate. Nessun dark pattern: «Non chiedermelo
  più» è sempre visibile e vale per sempre.

## Privacy

Tutto avviene sul dispositivo: notifiche pianificate dal sistema, nessun
server, nessun dato inviato allo sviluppatore. Attivando il calendario, le
date delle prove (insegnamento, data, ora, luogo, argomenti e note) vengono
scritte nel calendario dell'utente; se quel calendario è sincronizzato con
un servizio online, finiscono anche lì secondo le sue regole. Su Windows gli
eventi vengono inviati a Microsoft Graph, sull'account Microsoft dell'utente.
Vedi `PRIVACY.md`, paragrafo «Calendario» e «Notifiche».
