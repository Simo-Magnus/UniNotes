# Widget della schermata Home

Android e iPhone/iPad (su iPhone con la Live Activity della registrazione,
aggiunti dalla build automatica: sezione «iOS e macOS»; sul Mac ancora da
agganciare). Due widget con la grafica di Design 3 (docs/SPEC_DESIGN_3.md): vetro scuro
o chiaro secondo il tema del sistema (sfumatura della sezione-card, bordo
sottile, filo di luce in alto, faretto azzurro, raggio 22), titolo piccolo
in maiuscolo nel testo secondario, righe come card interne (raggio 16),
giorni mancanti come nell'app (etichetta con l'orologio, rossa entro 7
giorni, azzurra dopo), azzurro per ciò che fa l'app e un solo arancione per
l'azione (registrare, mettere in pausa).

- **Prossime prove**: le prossime prove ancora da sostenere del corso
  attuale con i giorni mancanti («Oggi», «Domani», «Tra 5 giorni»), quante
  ne stanno: 2×2 una prova grande, 4×1 una riga, 4×2 tre righe con la data
  (due righe compatte in orizzontale), 4×3 cinque, 4×4 sei; le altre come
  «+N» accanto al titolo. Tocco su una prova → l'app apre la sua scheda;
  tocco altrove → pagina Esami.
- **Registra lezione** (2×1, si stringe fino a 1×1): un tocco **avvia
  subito la registrazione**; durante la registrazione il widget mostra
  pallino rosso, stato, corso, il tempo che scorre e i comandi
  **Pausa/Riprendi**, **Salva** ed **Elimina** (vedi sotto).

Material You (colori presi dallo sfondo del telefono) non si usa: la
specifica vuole l'azzurro e l'arancione dell'app in entrambi i temi, e i
colori dinamici cambierebbero il significato dei colori (azzurro = l'app,
arancione = l'azione, rosso = urgente). Il tema chiaro/scuro del sistema sì.
Il carattere è quello del sistema (sans-serif, numeri a larghezza fissa nel
tempo): le RemoteViews non possono usare IBM Plex dell'app senza copiarne i
file nelle risorse Android.

I dati li prepara l'app (`app/lib/core/reminders/home_widgets.dart`,
funzione `widgetPayload`, testata in `app/test/reminders_test.dart`) a ogni
modifica delle prove, all'avvio e al cambio di corso. È un JSON con fino a
6 prove (`kWidgetMaxExams`) e il totale per il «+N»:

```json
{
  "version": 2,
  "total": 9,
  "exams": [
    {
      "id": 12, "title": "Analisi I", "kind": "Esame",
      "date": "martedì 12 gennaio", "isoDate": "2027-01-12", "time": "09:30",
      "days": 7, "daysLabel": "Tra 7 giorni", "route": "prova:12"
    }
  ],
  "emptyText": "Nessuna prova in programma",
  "route": "sezione:Esami"
}
```

I widget ricalcolano i giorni mancanti da `isoDate`, così restano giusti
anche se l'app non viene aperta per giorni. I tocchi aprono l'app con una
«rotta»: `prova:<id>`, `sezione:Esami`, `registra`, `registra:avvia` (le
esegue `AppShell`, vedi `RouteRequests` in `core/services/app_state.dart`).

### Perché prima «Prossime prove» ne mostrava una sola

I dati erano giusti (il JSON aveva già le prossime 3 prove; nessun filtro
in più, `updatePeriodMillis` ricalcola solo i giorni). Il problema era il
layout: uno solo, fisso, con il titolo e tre righe da due testi (~170 dp di
contenuto) in un widget che dichiarava 110 dp di altezza minima e non
guardava la misura vera. Dove il launcher dà meno altezza (widget in
orizzontale: 4×2 ≈ 117 dp secondo la tabella delle celle della
documentazione Android, griglie fitte, caratteri grandi) la seconda e la
terza riga finivano fuori dal riquadro e venivano tagliate. Ora il numero e
la forma delle righe dipendono dallo spazio vero (`WidgetPlan.exams`, con
la dimensione dei caratteri del sistema).

## Android

Codice nativo, nessun pacchetto:

- `android/app/src/main/kotlin/.../widgets/UpcomingExamsWidget.kt` e
  `RecordWidget.kt` (AppWidgetProvider con RemoteViews), `WidgetSupport.kt`
  (dati, apertura dell'app, misure, aggiornamento), `WidgetPlan.kt` (calcolo
  puro di che cosa entra in ogni misura: lo prova anche un programma sulla
  JVM, vedi «Verifiche»).
- `MainActivity.kt`: canale `io.github.simomagnus.universitynotes/widgets`
  con `update` (ridisegna i widget), `takeRoute` (rotta del widget che ha
  aperto l'app), `moveToBack` (torna alla schermata Home dopo l'avvio della
  registrazione dal widget) e, verso Flutter, `route` (tocco con l'app già
  aperta).
- Layout per misura: su Android 12+ `RemoteViews(Map<SizeF, RemoteViews>)`
  con le misure che il launcher dichiara (`OPTION_APPWIDGET_SIZES`, di solito
  verticale e orizzontale; senza, una serie di misure tipiche), così il
  sistema sceglie il layout giusto anche ruotando. Su Android 8-11 un layout
  solo per la misura più piccola delle due orientazioni
  (`OPTION_APPWIDGET_MIN_WIDTH`/`MIN_HEIGHT`), che entra in entrambe (lì la
  rotazione non ridisegna il widget). Elenchi a righe fisse (fino a 6), non
  `RemoteCollectionItems`/ListView: le righe di una collezione vogliono una
  PendingIntent modello mutabile, qui ogni riga ha la sua PendingIntent
  immutabile; e sei righe non hanno bisogno di scorrere.
- Colori che seguono il tema anche su Android 8-11: nessun colore impostato
  dal codice (resterebbe quello del tema al momento del disegno); per
  l'etichetta rossa o azzurra ci sono due viste nel layout, il codice ne
  mostra una.
- Radice dei layout con `@android:id/background` e `clipToOutline`
  (animazione d'apertura e angoli puliti su Android 12+).
- Dati: l'app li scrive con `shared_preferences` (API classica), che su
  Android usa il file `FlutterSharedPreferences` e il prefisso `flutter.`
  (verificato in `shared_preferences_android` 2.4.28,
  `LegacySharedPreferencesPlugin.kt`): il widget legge la chiave
  `flutter.uninotes_widget_data`.
- Risorse: `res/layout/widget_*.xml`, `res/xml/widget_*_info.xml`
  (ridimensionabili, anteprima e descrizione in italiano per Android 12+),
  colori chiari in `values/colors.xml` e scuri in `values-night/colors.xml`.
- Aggiornamento: a ogni modifica nell'app; per i giorni mancanti a
  mezzanotte (allarme `AlarmManager.RTC` non urgente: nessun risveglio del
  telefono né permessi, arriva alla prima accensione dello schermo) e ogni
  12 ore (`updatePeriodMillis`, anche dopo un riavvio).
- Dati non validi: `WidgetSupport.data` legge le preferenze dentro il
  try (un valore di altro tipo darebbe `ClassCastException` in `onUpdate`) e
  i testi delle prove sono limitati a 200 caratteri (le RemoteViews passano
  per il Binder).

### «Registra lezione»: avvio con un tocco

Cosa vede l'utente:

1. Widget fermo: pulsante arancione «Registra» (tondo con il microfono nel
   1×1). Tocco.
2. Si apre UniNotes sul registratore (ad app chiusa prima la schermata
   d'avvio, circa un secondo; con l'app già in memoria subito). La
   registrazione parte da sola con lo stesso percorso del pulsante
   «Registra»: corso della lezione in calendario (o il primo), lingua delle
   lezioni di quel corso, nome «AAAA-MM-GG HH:MM», segnale d'inizio,
   notifica con il tempo e i pulsanti.
3. Dopo 0,7 secondi (il tempo di vedere il cronometro partire) l'app torna
   da sola alla schermata Home (`moveTaskToBack`): la registrazione continua
   nel servizio in primo piano, come quando si esce dall'app a mano. La
   trascrizione dal vivo gira come sempre in background; il testo si trova
   poi nella registrazione salvata.
4. Il widget ora mostra pallino rosso, «In registrazione», il corso (se c'è
   posto), il tempo che scorre e Pausa (arancione), Salva (azzurro), Elimina
   (rosso). Nel 1×1 c'è posto solo per Pausa/Riprendi (un tocco sul resto
   apre il registratore).
5. **Pausa/Riprendi** e **Salva** fanno quello che fanno i pulsanti della
   notifica (Salva: nel corso, con il nome predefinito, senza domande).
   **Elimina**: il primo tocco fa diventare il pulsante rosso pieno e scrive
   «Tocca di nuovo per eliminare»; solo un secondo tocco entro 4 secondi
   elimina, altrimenti tutto torna com'era. Anche dopo la conferma la
   registrazione va in «Eliminati di recente» (recuperabile per 30 giorni,
   con «Annulla» nell'avviso dell'app): niente perdite per un tocco sbagliato,
   senza dialoghi (un widget non ne può aprire).
6. Dopo Salva o Elimina il widget torna fermo.

Se manca il permesso del microfono, al punto 2 Android lo chiede come fa il
pulsante dell'app; se lo si nega, il registratore resta aperto con il
messaggio e niente parte (nessun ritorno alla Home). Senza insegnamenti lo
si dice e niente parte. Se una registrazione è già in corso, un altro tocco
non ne avvia una seconda.

**Perché passa dall'app.** Da Android 14 un servizio in primo piano di tipo
`microphone` va avviato con un'attività dell'app visibile: la
documentazione ufficiale («Restrictions on starting a foreground service
from the background») dice che un servizio che usa permessi «while-in-use»
(microfono) non si può creare con l'app in background «anche se l'app
rientra in una delle eccezioni», e che su Android 14 il sistema lancia
`SecurityException` se manca il permesso `RECORD_AUDIO` in quel momento. La
stessa pagina elenca come eccezione per i permessi «while-in-use» anche
l'interazione con un widget dell'app, ma qui non basterebbe comunque: la
registrazione (microfono, WAV, trascrizione, notifica) vive nel motore
Flutter dell'attività, e il permesso del microfono si chiede solo da
un'attività. Quindi il tocco apre MainActivity (PendingIntent immutabile)
con la rotta `registra:avvia`, il registratore parte con l'app davanti e
poi l'app va in background. I comandi del widget (Pausa, Salva, Elimina)
invece non avviano il servizio: sono broadcast espliciti e immutabili al
ricevitore non esportato `RecordingCommandReceiver` (lo stesso dei pulsanti
della notifica), che accetta solo i comandi noti.

**Sicurezza della rotta.** MainActivity è esportata (è l'icona dell'app):
un'altra app potrebbe mandarle `registra:avvia` e accendere il microfono.
Per questo la rotta vale solo con il codice segreto (128 bit casuali, nelle
preferenze private `uninotes_widgets`) che l'app mette nelle PendingIntent
dei suoi widget; senza (o sbagliato) diventa `registra`, che apre solo il
registratore. Su iOS e macOS lo schema `uninotes://` lo può aprire
chiunque, quindi lì `registra:avvia` apre solo il registratore
(`AppShell.quickStartFromWidget`).

**Un solo stato.** Il widget non ha uno stato suo: lo riceve dalla notifica
della registrazione. Ogni `show` della notifica (inizio, pausa, ripresa,
notifica rimessa) passa lo stesso stato a `RecordWidget.setLive`, e alla fine
(`stopped`, da `AndroidRecordingNotification.stop`) il widget torna fermo,
qualunque sia il punto da cui la registrazione è partita o finita (app,
notifica, riquadro, widget). Lo stato vive solo in memoria nel processo
dell'app, insieme al collegamento con Flutter: se il sistema chiude l'app
durante una registrazione, il primo disegno in un processo nuovo trova lo
stato vuoto e il widget torna fermo. Per non aspettare: durante la
registrazione un allarme non urgente ogni 5 minuti controlla lo stato (nel
processo nuovo lo trova vuoto e ridisegna il widget fermo), lo stesso fa la
riapertura dell'app e ogni tocco su un comando del widget. Alla riapertura
l'app propone poi di recuperare l'audio («Registrazione da recuperare»,
docs/registratore.md). Se il motore Flutter si chiude (attività distrutta)
anche il widget torna fermo (`MainActivity.cleanUpFlutterEngine`).

### Verifiche

- `app/test/reminders_test.dart`: JSON con più prove (fino a 6, totale) e
  stato della registrazione (`recordingWidgetState`).
- `app/test/recording_notification_test.dart`: stato nella notifica
  (`recordingShowArgs`), `stopped` alla fine, «Elimina» dal widget → in
  «Eliminati di recente» senza dialoghi.
- `app/test/widget_record_start_test.dart`: rotta `registra:avvia` con un
  registratore finto (parte una volta sola e torna alla Home, permesso
  negato → registratore aperto senza avvio, registratore già aperto, iOS e
  macOS, nessun insegnamento) e controlli statici sul Kotlin e sul manifest
  (PendingIntent immutabili, componenti esportati, ricevitori non
  esportati, rotta protetta, layout per misura, solo viste ammesse dalle
  RemoteViews).
- Risorse e Kotlin (da Windows, senza Gradle): `aapt2 compile`/`link` delle
  risorse con `android.jar` e `kotlinc` con l'`R.java` generato; il calcolo
  delle misure (`WidgetPlan.kt`) gira anche sulla JVM con le misure delle
  celle della documentazione Android.

## iOS e macOS (WidgetKit)

Su **iPhone e iPad** widget e Live Activity sono un'unica estensione
WidgetKit, `WidgetUniNotes` (bundle ID
`io.github.simomagnus.universitynotes.WidgetUniNotes`), che **aggiunge la
build automatica**: niente passi in Xcode e niente Mac. Sul **Mac** i widget
vanno ancora agganciati a mano (sezione «macOS» più sotto).

Codice dell'estensione, in `app/ios/WidgetUniNotes/`:

- `UniNotesWidgets.swift`: i due widget e il `WidgetBundle` con l'unico
  `@main` dell'estensione; la Live Activity entra nel pacchetto con
  `if #available(iOS 16.2, *)`, quindi l'estensione (iOS 15.6, come l'app)
  si installa anche su iOS 15 con i soli widget;
- `RecordingLiveActivity.swift`, `RecordingActivityAttributes.swift` e
  `RecordingIntents.swift` (anche in Runner): Live Activity, sotto;
- `Info.plist` (`NSExtensionPointIdentifier` = `com.apple.widgetkit-extension`,
  versione e numero di build dell'app: `FLUTTER_BUILD_NAME` e
  `FLUTTER_BUILD_NUMBER`), `WidgetUniNotes.entitlements` (App Group) e
  `PrivacyInfo.xcprivacy` (UserDefaults dell'App Group, motivo `1C8F.1`).

La parte dell'app è già pronta: `ios/Runner/AppDelegate.swift` e
`macos/Runner/MainFlutterWindow.swift` ricevono il JSON sul canale
`io.github.simomagnus.universitynotes/widgets`, lo scrivono nelle
UserDefaults dell'App Group `group.io.github.simomagnus.universitynotes`
(chiave `uninotes_widget_data`) e chiamano
`WidgetCenter.shared.reloadAllTimelines()`. L'App Group dell'app è in
`ios/Runner/Runner.entitlements`.

Grafica e contenuto come su Android (stessi colori, card interne,
etichette dei giorni rosse entro 7 giorni): «Prossime prove» in tre misure,
piccolo (la prossima prova, grande), medio (3 righe compatte) e grande (5
righe con la data, quante ne entrano anche nell'iPhone più piccolo), con il
«+N»; «Registra lezione» piccolo con il tondo arancione. Il codice non si
può compilare da Windows: lo compila la build automatica (job
«testflight»), e un errore di compilazione fa solo ricadere la build senza
widget (sotto).

### Come la build automatica aggiunge l'estensione (iPhone e iPad)

Il `project.pbxproj` del repository resta **senza** estensioni: build non
firmata, `flutter run` e ricaduta restano quelli di prima. Nel job
«testflight» di `.github/workflows/app.yml`, dopo `flutter build ios
--config-only`:

1. **Aggiunta al progetto** (passo «Widget e Live Activity nel progetto
   Xcode»): gemma `xcodeproj` di versione fissa (1.28.1, file `.gem`
   scaricato da rubygems.org e controllato con lo SHA-256) e
   `app/tool/aggiungi_estensioni_ios.rb`, che aggiunge il gruppo e il target
   `WidgetUniNotes` (app extension, iOS 15.6, firma automatica, Swift e
   famiglie di dispositivi come Runner, stessi file xcconfig di Flutter di
   Runner, quindi stessa versione e stesso numero di build dell'app),
   `RecordingIntents.swift` anche in Runner, in Runner la dipendenza
   dall'estensione, la fase **«Embed Foundation Extensions»** (PlugIns)
   **prima di «Thin Binary»** di Flutter (dopo darebbe «Cycle inside
   Runner») e `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements`. Lo
   script è idempotente e alla fine rilegge il progetto salvato (target,
   fasi, impostazioni, `xcodebuild -list`, `plutil` e PlistBuddy su
   Info.plist ed entitlement, App Group uguale in AppDelegate e nei widget,
   un solo `@main`): se qualcosa non torna esce con il motivo nel log.
2. **Archivio** non firmato come prima (`CODE_SIGNING_ALLOWED=NO`), poi
   controllo di bundle ID, versione, build e tipo dell'estensione
   (`app_store_connect.sh firma-locale`) e **firma locale «-»** (senza
   certificati) di framework, estensione e app con i loro entitlement:
   `xcodebuild -exportArchive` legge gli entitlement (l'App Group) dalla
   firma dell'archivio e rifirma tutto con i certificati del cloud, come per
   il Mac App Store.
3. **Esportazione** App Store e ad hoc con la firma automatica nel cloud e
   `-allowProvisioningUpdates`: Xcode crea o aggiorna i profili di app ed
   estensione (l'ad hoc anche per l'estensione, con i dispositivi
   registrati). Nel log, dopo ogni esportazione: «UniNotes.ipa: con
   WidgetUniNotes.appex (widget e Live Activity)» oppure «senza estensioni».

**Ricaduta.** Ogni passo che non riesce dà un avviso «Widget iOS» e la build
continua senza estensioni, come prima (TestFlight e ad hoc escono comunque):
aggiunta non riuscita → progetto originale; archivio non riuscito (di
solito un errore nel codice Swift) → progetto originale e secondo archivio
(l'unica seconda compilazione, solo in caso di errore); firma locale o
controllo dell'estensione non riusciti → archivio senza PlugIns e senza
firma locale; esportazione non riuscita → nuova esportazione da una copia
dell'archivio senza estensioni (`Runner-senza-estensioni.xcarchive`).

### Portale Apple (una volta, dal browser)

`-allowProvisioningUpdates` crea e aggiorna profili e App ID, ma Apple non
documenta che registri anche un **App Group** nuovo con la chiave API: va
fatto una volta a mano su developer.apple.com → *Certificates, Identifiers
& Profiles* → *Identifiers* (se manca, l'esportazione con i widget non
riesce e la build ricade senza, con un avviso che ripete questi passi):

1. **+** → *App Groups* → *Continue*; descrizione «UniNotes», identificativo
   `group.io.github.simomagnus.universitynotes` → *Register*.
2. App ID dell'app `io.github.simomagnus.universitynotes` → *Capabilities*:
   spunta **App Groups** → *Configure* → scegli il gruppo → *Continue* →
   *Save* (conferma il messaggio sui profili: Xcode li rifà alla build).
3. **+** → *App IDs* → *App* → descrizione «UniNotes Widget», *Explicit*
   `io.github.simomagnus.universitynotes.WidgetUniNotes`; nelle capability
   spunta **App Groups**, *Continue* → *Register*; poi aprilo, *App Groups*
   → *Configure* → lo stesso gruppo → *Save*.

Niente notifiche push: la Live Activity si aggiorna dall'app
(`pushType: nil`). Nessun profilo da creare a mano: li fa Xcode, anche
quello ad hoc dell'estensione con i dispositivi registrati.

### Avviare la registrazione dal widget su iOS (ancora da fare)

Oggi il widget «Registra lezione» di iOS e macOS apre il registratore
(`uninotes://widget/registra`): serve un tocco su «Registra». Avviare
subito la registrazione da un widget, su iPhone, si può solo con
**`AudioRecordingIntent`** (App Intents, iOS 18 / macOS 15): secondo la
documentazione Apple, adottandolo «you must start a Live Activity when you
begin the audio recording and keep it active as long as you record audio.
If you don't start a Live Activity, the audio recording stops». Le
discussioni sui forum Apple riportano anche che la registrazione deve
partire con l'app in primo piano (errore «Target is not foreground» se
parte da sola in background). Quindi, con l'estensione già nella build:

1. un `AudioRecordingIntent` (iOS 18+) con `openAppWhenRun = true`, nel
   target Runner (come `RecordingIntents.swift`), che apre l'app con la
   rotta `registra:avvia` invece di `registra`;
2. nel widget un `Button(intent:)` (iOS 17+, widget interattivi) al posto
   del `widgetURL`, solo dove `#available(iOS 18, *)`; sotto resta il link;
3. in Flutter, su iOS, `AppShell.quickStartFromWidget` va acceso solo per
   le rotte che arrivano dall'intent (non dallo schema `uninotes://`, che
   può aprire chiunque): per esempio un metodo `route` separato sul canale
   dei widget chiamato dall'intent;
4. la Live Activity parte già con la registrazione (`IosLiveActivity`):
   verificare sul telefono che resti attiva per tutta la registrazione e
   che con la Live Activity disattivata nelle Impostazioni l'avvio dal
   widget si rifiuti in modo chiaro.

Nulla di questo è implementato: va provato su un iPhone vero con iOS 18
(in particolare l'avvio dal background).

### Tocchi e prova sull'iPhone

Tocchi sui widget: lo schema `uninotes` è in `CFBundleURLTypes`
dell'Info.plist (iOS e macOS); su iOS i collegamenti arrivano alla scena
tramite `IncomingFiles` e `AppDelegate.openAppURL`
(`uninotes://widget/<schermata>` → `openWidgetURL`), sul Mac tramite
`AppDelegate.application(_:open:)` e `AppLinks` in `MainFlutterWindow.swift`
(anche `takeRoute` all'avvio). Non serve toccare `SceneDelegate.swift`. Lo
stesso schema riporta nell'app l'esito del comando «UniNotes Focus»
(`uninotes://focus/…`, vedi focus.md).

Prova (build ad hoc o TestFlight con «con WidgetUniNotes.appex» nel log):
aggiungi una prova con una data nell'app, poi nella schermata Home
pressione lunga → **+** → UniNotes → «Prossime prove» (tre misure) o
«Registra lezione»; tocca una prova e il widget di registrazione. Su iOS 15
ci sono i widget ma non la Live Activity.

### macOS (ancora a mano, su un Mac)

Con `app/macos/Runner.xcworkspace` in Xcode:

1. *File → New → Target… → macOS → Widget Extension*, nome
   `WidgetUniNotes`, bundle id
   `io.github.simomagnus.universitynotes.WidgetUniNotes`, deployment macOS
   12.0.
2. Sostituisci il codice generato con
   `app/macos/WidgetUniNotes_da_aggiungere/UniNotesWidgets.swift`.
3. App Group su Runner (in `DebugProfile.entitlements` e
   `Release.entitlements`) e sull'estensione
   (`WidgetUniNotes.entitlements`, che ha anche la sandbox richiesta dalle
   estensioni). Su macOS il nome del gruppo può dover iniziare con l'ID del
   team (`<TEAMID>.io.github.simomagnus.universitynotes`): in quel caso
   aggiorna la costante `appGroup` in `MainFlutterWindow.swift` e in
   `UniNotesWidgets.swift`.
4. Tocchi: schema URL `uninotes` in *Runner → Info → URL Types* e, in
   `macos/Runner/AppDelegate.swift`, un metodo
   `application(_:open urls:)` che passa la rotta (il percorso dopo
   `uninotes://widget/`) a Flutter sul canale dei widget con
   `invokeMethod("route", …)`; finché non c'è, il tocco apre solo l'app.
5. *Embed Foundation Extensions* in Runner prima delle fasi di script di
   Flutter (altrimenti «Cycle inside Runner») e, per il Mac App Store,
   App ID dell'estensione e App Group nel portale Apple come per l'iPhone.

In alternativa si può estendere `app/tool/aggiungi_estensioni_ios.rb` al
progetto `macos/` (sandbox nell'entitlement dell'estensione, deployment
macOS 12.0, gruppo con il prefisso del team se serve) e richiamarlo nel job
«mac-app-store».

## Live Activity della registrazione (iOS)

Durante una registrazione, sulla schermata di blocco e nella Dynamic Island
compare la Live Activity: pallino rosso, nome del corso, tempo (cronometro
nativo `Text(timerInterval:)`, nessun aggiornamento ogni secondo dall'app)
e, da iOS 17, i pulsanti **Pausa/Riprendi** e **Salva** (App Intents). Il
tocco apre il registratore (`uninotes://widget/registra`). È l'equivalente
della notifica con il tempo e i pulsanti di Android (docs/registratore.md).

Come vuole Apple, la Live Activity (`ActivityConfiguration`) sta
nell'estensione WidgetKit, nello **stesso** pacchetto dei widget
(`WidgetUniNotes`, aggiunta dalla build automatica, vedi sopra), solo da
iOS 16.2 (`if #available(iOS 16.2, *)` nel `WidgetBundle`). File in
`app/ios/WidgetUniNotes/`:

- `RecordingLiveActivity.swift`: grafica (schermata di blocco, Dynamic
  Island), senza `@main` (è in `UniNotesWidgets.swift`);
- `RecordingActivityAttributes.swift`: dati della Live Activity (solo
  nell'estensione: l'app ha la stessa struttura, stesso nome e stessi campi,
  in `AppDelegate.swift`, così compila anche senza l'estensione);
- `RecordingIntents.swift`: i pulsanti (iOS 17+), in **entrambi** i target,
  così girano nel processo dell'app anche in background.

`NSSupportsLiveActivities` = `YES` è nell'Info.plist dell'app. ActivityKit
e AppIntents sono collegati come facoltativi (`-weak_framework` in
`ios/Flutter/Debug.xcconfig` e `Release.xcconfig`, usati anche
dall'estensione): l'app e i widget partono anche su iOS 15, dove i due
framework non esistono.

Il lato app è già pronto: `ios/Runner/AppDelegate.swift` riceve sul canale
`io.github.simomagnus.universitynotes/live_activity` i comandi `start`
(corso, tempo, pausa), `update` ed `end` da Flutter
(`lib/features/notes/recorder/background_controls.dart`) e rimanda a Flutter
`command` (`toggle`, `save`) quando si preme un pulsante. Il codice è
protetto da `#if canImport(ActivityKit)`, `#available(iOS 16.2, *)` e dal
controllo che `WidgetUniNotes.appex` sia dentro l'app: in una build senza
estensione (build non firmata, ricaduta) le chiamate non fanno nulla.

Prova su un iPhone con iOS 16.2 o successivo (la Dynamic Island solo sui
modelli che l'hanno; i pulsanti da iOS 17): avvia una registrazione,
blocca lo schermo, premi Pausa e Salva. Il tocco apre il registratore con
lo schema `uninotes` dei widget.

Le impostazioni dell'utente (*Impostazioni → UniNotes → Live Activity*)
possono disattivarle: l'app lo controlla
(`ActivityAuthorizationInfo().areActivitiesEnabled`) e in quel caso non le
avvia. La registrazione in background funziona comunque
(`UIBackgroundModes` → `audio`, già nell'Info.plist).

## Windows

Niente widget: su Windows 11 i widget del pannello Widget richiedono un'app
pacchettizzata MSIX con un provider dedicato (Windows App SDK), mentre
UniNotes è distribuita come programma non pacchettizzato. Le stesse
informazioni arrivano con le notifiche (docs/notifiche.md) e dall'icona
nell'area di notifica durante la registrazione (menu con Apri,
Pausa/Riprendi, Salva ed Esci, vedi docs/registratore.md).
