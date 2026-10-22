# Widget della schermata Home

Due widget, con la grafica dell'app (vetro scuro o chiaro secondo il tema
del sistema, testo chiaro sul fondo scuro, accento azzurro, pulsante di
registrazione arancione):

- **Prossime prove**: le prossime 3 prove ancora da sostenere del corso
  attuale con i giorni mancanti («Oggi», «Domani», «Tra 5 giorni»). Tocco su
  una prova → l'app apre la sua scheda; tocco altrove → pagina Esami.
- **Registra lezione** (1×1): apre l'app direttamente nel registratore.

I dati li prepara l'app (`app/lib/core/reminders/home_widgets.dart`,
funzione `widgetPayload`, testata in `app/test/reminders_test.dart`) a ogni
modifica delle prove, all'avvio e al cambio di corso. È un JSON così:

```json
{
  "version": 1,
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
«rotta»: `prova:<id>`, `sezione:Esami`, `registra` (le esegue
`AppShell`, vedi `RouteRequests` in `core/services/app_state.dart`).

## Android

Codice nativo, nessun pacchetto:

- `android/app/src/main/kotlin/.../widgets/UpcomingExamsWidget.kt` e
  `RecordWidget.kt` (AppWidgetProvider con RemoteViews), `WidgetSupport.kt`
  (dati, apertura dell'app, aggiornamento).
- `MainActivity.kt`: canale `io.github.simomagnus.universitynotes/widgets`
  con `update` (ridisegna i widget), `takeRoute` (rotta del widget che ha
  aperto l'app) e, verso Flutter, `route` (tocco con l'app già aperta).
- Dati: l'app li scrive con `shared_preferences` (API classica), che su
  Android usa il file `FlutterSharedPreferences` e il prefisso `flutter.`
  (verificato in `shared_preferences_android` 2.4.28,
  `LegacySharedPreferencesPlugin.kt`): il widget legge la chiave
  `flutter.uninotes_widget_data`.
- Risorse: `res/layout/widget_*.xml`, `res/xml/widget_*_info.xml`
  (ridimensionabili, anteprima e descrizione in italiano per Android 12+),
  colori chiari in `values/colors.xml` e scuri in `values-night/colors.xml`.
- Aggiornamento: a ogni modifica nell'app e, per i giorni mancanti, ogni 12
  ore (`updatePeriodMillis`).
- Dati non validi: `WidgetSupport.data` legge le preferenze dentro il
  try (un valore di altro tipo darebbe `ClassCastException` in `onUpdate`) e
  i testi delle prove sono limitati a 200 caratteri (le RemoteViews passano
  per il Binder).

## iOS e macOS (WidgetKit)

WidgetKit richiede un target di estensione creato in Xcode, che non si può
creare da Windows senza toccare `project.pbxproj` (romperebbe la build della
CI). Il codice Swift dei due widget è pronto, ma **non è agganciato alla
build**:

- `app/ios/WidgetUniNotes_da_aggiungere/UniNotesWidgets.swift` e
  `WidgetUniNotes.entitlements`
- `app/macos/WidgetUniNotes_da_aggiungere/` (stessi file; l'entitlement del
  Mac ha anche la sandbox)

La parte dell'app è già pronta: `ios/Runner/AppDelegate.swift` e
`macos/Runner/MainFlutterWindow.swift` ricevono il JSON sul canale
`io.github.simomagnus.universitynotes/widgets`, lo scrivono nelle
UserDefaults dell'App Group `group.io.github.simomagnus.universitynotes`
(chiave `uninotes_widget_data`) e chiamano
`WidgetCenter.shared.reloadAllTimelines()`.

### Passo per passo, su un Mac (iOS)

1. Apri `app/ios/Runner.xcworkspace` in Xcode (dopo `flutter build ios
   --config-only` o `pod install`).
2. **File → New → Target… → Widget Extension**. Nome: `WidgetUniNotes`;
   togli le spunte «Include Live Activity» e «Include Configuration App
   Intent». Bundle identifier:
   `io.github.simomagnus.universitynotes.WidgetUniNotes`. Alla domanda
   «Activate scheme?» rispondi *Cancel* (resta lo schema Runner).
3. Nel nuovo gruppo `WidgetUniNotes` cancella i file Swift generati da Xcode
   e trascina dentro `UniNotesWidgets.swift` da
   `app/ios/WidgetUniNotes_da_aggiungere/` (spunta solo il target
   `WidgetUniNotes`).
4. Target `WidgetUniNotes` → *General*: **Minimum Deployments** iOS 15.6
   (come l'app).
5. **Signing & Capabilities**, sia per il target **Runner** sia per
   **WidgetUniNotes**: *+ Capability → App Groups* e aggiungi
   `group.io.github.simomagnus.universitynotes` (stesso team). In alternativa
   imposta *Code Signing Entitlements* del widget su
   `WidgetUniNotes_da_aggiungere/WidgetUniNotes.entitlements` e aggiungi la
   stessa chiave a `Runner/Runner.entitlements` (Xcode la crea attivando la
   capability).
6. Target **Runner** → *Build Phases*: verifica che ci sia *Embed Foundation
   Extensions* con `WidgetUniNotes.appex` e sposta la fase **prima** di
   *Thin Binary* / *Run Script* di Flutter (altrimenti l'errore «Cycle inside
   Runner»).
7. Tocchi sui widget: **già pronto nel codice**. Lo schema `uninotes` è in
   `CFBundleURLTypes` dell'Info.plist (iOS e macOS); su iOS i collegamenti
   arrivano alla scena tramite `IncomingFiles` e `AppDelegate.openAppURL`
   (`uninotes://widget/<schermata>` → `openWidgetURL`), sul Mac tramite
   `AppDelegate.application(_:open:)` e `AppLinks` in
   `MainFlutterWindow.swift` (anche `takeRoute` all'avvio). Non serve
   toccare `SceneDelegate.swift`. Lo stesso schema riporta nell'app l'esito
   del comando «UniNotes Focus» (`uninotes://focus/…`, vedi focus.md).
8. Compila ed esegui su un iPhone o sul simulatore, poi aggiungi i widget
   dalla schermata Home (pressione lunga → +). Prova: aggiungi una prova con
   una data nell'app, torna alla Home e controlla il widget.
9. Pubblicazione: nel portale Apple Developer registra anche l'App ID
   dell'estensione e l'App Group, e rigenera i profili di provisioning di
   app ed estensione.

### macOS

Come sopra, con `app/macos/Runner.xcworkspace`:

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

## Live Activity della registrazione (iOS)

Durante una registrazione, sulla schermata di blocco e nella Dynamic Island
compare la Live Activity: pallino rosso, nome del corso, tempo (cronometro
nativo `Text(timerInterval:)`, nessun aggiornamento ogni secondo dall'app)
e, da iOS 17, i pulsanti **Pausa/Riprendi** e **Salva** (App Intents). Il
tocco apre il registratore (`uninotes://widget/registra`). È l'equivalente
della notifica con il tempo e i pulsanti di Android (docs/registratore.md).

Come per i widget, ActivityKit richiede un target di estensione creato in
Xcode: il codice è pronto ma **non è agganciato alla build** (nessuna
modifica a `project.pbxproj`):

- `app/ios/LiveActivity_da_aggiungere/RecordingLiveActivity.swift`: grafica
  (schermata di blocco, Dynamic Island) e `@main` dell'estensione;
- `RecordingActivityAttributes.swift`: dati della Live Activity (solo
  nell'estensione: l'app ha la stessa struttura in `AppDelegate.swift`);
- `RecordingIntents.swift`: i pulsanti (in **entrambi** i target).

Il lato app è già pronto: `ios/Runner/AppDelegate.swift` riceve sul canale
`io.github.simomagnus.universitynotes/live_activity` i comandi `start`
(corso, tempo, pausa), `update` ed `end` da Flutter
(`lib/features/notes/recorder/background_controls.dart`) e rimanda a Flutter
`command` (`toggle`, `save`) quando si preme un pulsante. Il codice è
protetto da `#if canImport(ActivityKit)`, `#available(iOS 16.2, *)` e dal
controllo che `LiveActivityUniNotes.appex` sia dentro l'app: finché
l'estensione non c'è le chiamate non fanno nulla e la build si comporta
come prima.

### Passo per passo, su un Mac

1. Apri `app/ios/Runner.xcworkspace` in Xcode.
2. **File → New → Target… → Widget Extension**. Nome:
   `LiveActivityUniNotes` (il nome conta: l'app cerca
   `LiveActivityUniNotes.appex`); spunta **Include Live Activity**, togli
   «Include Configuration App Intent». Bundle identifier:
   `io.github.simomagnus.universitynotes.LiveActivityUniNotes`. Alla
   domanda «Activate scheme?» rispondi *Cancel*.
3. Nel gruppo `LiveActivityUniNotes` cancella i file Swift generati da Xcode
   e trascina dentro i tre file di `app/ios/LiveActivity_da_aggiungere/`:
   - `RecordingLiveActivity.swift` e `RecordingActivityAttributes.swift`:
     spunta **solo** `LiveActivityUniNotes`;
   - `RecordingIntents.swift`: spunta **sia** `Runner` **sia**
     `LiveActivityUniNotes` (così i pulsanti girano nel processo dell'app,
     anche in background).
4. Target `LiveActivityUniNotes` → *General* → **Minimum Deployments**:
   iOS 16.2 (l'app resta a 15.6: sotto iOS 16.2 la Live Activity
   semplicemente non c'è).
5. Target **Runner** → *Info*: aggiungi la chiave
   `NSSupportsLiveActivities` (*Supports Live Activities*) = `YES`.
6. Target **Runner** → *Build Phases*: controlla che in *Embed Foundation
   Extensions* ci sia `LiveActivityUniNotes.appex` e che la fase stia
   **prima** di *Thin Binary* / *Run Script* di Flutter (altrimenti «Cycle
   inside Runner»).
7. Tocco sulla Live Activity: serve lo schema URL `uninotes` e la
   `SceneDelegate` del punto 7 dei widget qui sopra (se li hai già fatti per
   i widget, niente da aggiungere).
8. Se Xcode, con l'app ancora a iOS 15.6, collega `ActivityKit` in modo
   obbligatorio (errore all'avvio su iOS 15), in *Runner → Build Phases →
   Link Binary With Libraries* imposta `ActivityKit.framework` come
   *Optional*.
9. Prova su un iPhone (le Live Activity nel simulatore funzionano, la
   Dynamic Island solo sui modelli che l'hanno): avvia una registrazione,
   blocca lo schermo, premi Pausa e Salva.
10. Pubblicazione: registra anche l'App ID dell'estensione nel portale Apple
    Developer e rigenera i profili di provisioning.

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
