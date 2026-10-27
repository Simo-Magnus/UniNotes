#!/usr/bin/env bash
# Chiave API di App Store Connect nella build automatica
# (.github/workflows/app.yml, job «testflight», «mac-app-store» e «macos»):
# controllo dei secret, file temporaneo della chiave, firma nel cloud di Apple
# (xcodebuild -exportArchive), caricamento su App Store Connect,
# notarizzazione e pulizia. Vedi PUBBLICAZIONE.md §6.4, §7.2 e §7.5.
#
# I valori arrivano solo come variabili d'ambiente del passo (ASC_KEY_ID,
# ASC_ISSUER_ID, ASC_KEY_P8_BASE64, APPLE_TEAM_ID, APPSTORE_ID), mai come
# argomenti, e non si scrivono nel log. Ogni valore si controlla prima di
# usarlo in un percorso o in un file.
#
#   controlla <nome>              secret presenti e validi → <nome>=si|no in GITHUB_OUTPUT
#   chiave                        scrive la chiave .p8 (permessi 600) e la controlla
#   esporta <archivio> <uscita> <metodo>
#                                 firma nel cloud ed esporta (.ipa, .pkg, .app)
#                                 (app-store-connect o release-testing, cioè
#                                 «ad hoc» da Xcode 15.3); se un archivio con
#                                 estensioni (widget) non si esporta, riprova
#                                 da una copia senza estensioni (avviso)
#   firma-locale <archivio> <versione> <build>
#                                 firma locale «-» (senza certificati) di app
#                                 ed estensione WidgetUniNotes di un archivio
#                                 non firmato, con gli entitlement dell'App
#                                 Group, dopo il controllo di bundle ID,
#                                 versione e numero di build dell'estensione
#   collegamenti <eseguibile>     ActivityKit e AppIntents collegati come
#                                 facoltativi (l'app parte su iOS 15)
#   senza-estensioni <archivio> [<copia>]
#                                 toglie le estensioni (e la firma locale)
#                                 dall'archivio o da una sua copia
#   profilo <ipa>                 tipo, scadenza e numero di dispositivi del
#                                 profilo incluso nell'IPA (senza gli UDID)
#   manifesto <file> <bundle id> <versione> <build> <url ipa>
#                                 manifest.plist per l'installazione da Safari
#                                 (itms-services) di un IPA ad hoc
#   carica <file> <ios|macos> <bundle id> <versione> <build>
#                                 caricamento su App Store Connect (TestFlight)
#   notarizza <file>              notarizzazione con la chiave API e staple
#   pulisci                       cancella la chiave e i file temporanei
#
# Compatibile con il bash 3.2 di macOS.
set -euo pipefail

CARTELLA_CHIAVI="$HOME/.appstoreconnect/private_keys"
TEMP_ASC="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/asc"
# cartella app/ (entitlement dell'app e dell'estensione dei widget)
CARTELLA_APP="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_APP="io.github.simomagnus.universitynotes"
ESTENSIONE="WidgetUniNotes"
APP_GROUP="group.io.github.simomagnus.universitynotes"

errore() { echo "::error title=App Store Connect::$1"; }
# problemi dei widget: la build ricade senza estensioni, quindi solo un avviso
avviso_widget() { echo "::warning title=Widget iOS::$1"; }

# Key ID (10 caratteri), Issuer ID (UUID), Team ID (10 caratteri), Apple ID
# numerico dell'app: un valore sbagliato si ferma qui con un messaggio chiaro,
# non a metà della firma, e non entra mai in un percorso.
valida() {
  local ok=0
  if ! [[ "${ASC_KEY_ID:-}" =~ ^[A-Z0-9]{10}$ ]]; then
    errore "ASC_KEY_ID non valido: è il «Key ID» di 10 caratteri (lettere maiuscole e cifre) della chiave in App Store Connect → Utenti e accessi → Integrazioni → App Store Connect API."
    ok=1
  fi
  if ! [[ "${ASC_ISSUER_ID:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    errore "ASC_ISSUER_ID non valido: è l'«Issuer ID» (formato 8-4-4-4-12) mostrato sopra l'elenco delle chiavi in App Store Connect → Utenti e accessi → Integrazioni."
    ok=1
  fi
  if [ "${1:-}" = "team" ] && ! [[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]]; then
    errore "APPLE_TEAM_ID non valido: è il Team ID di 10 caratteri (developer.apple.com → Account → Membership details)."
    ok=1
  fi
  if [ -n "${APPSTORE_ID:-}" ] && ! [[ "$APPSTORE_ID" =~ ^[0-9]{6,12}$ ]]; then
    errore "APPSTORE_ID non valido: è l'«Apple ID» numerico dell'app (App Store Connect → App → Informazioni sull'app), facoltativo."
    ok=1
  fi
  return "$ok"
}

file_chiave() { echo "$CARTELLA_CHIAVI/AuthKey_$ASC_KEY_ID.p8"; }

controlla() {
  local nome="$1"
  if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_P8_BASE64:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
    echo "::warning title=App Store Connect::Mancano i secret ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64 o APPLE_TEAM_ID (PUBBLICAZIONE.md §6.4): build per App Store Connect non creata."
    echo "$nome=no" >> "$GITHUB_OUTPUT"
    return 0
  fi
  valida team
  echo "$nome=si" >> "$GITHUB_OUTPUT"
}

chiave() {
  valida
  if [ -z "${ASC_KEY_P8_BASE64:-}" ]; then
    errore "manca il secret ASC_KEY_P8_BASE64"
    exit 1
  fi
  umask 077
  mkdir -p "$CARTELLA_CHIAVI" "$TEMP_ASC"
  chmod 700 "$HOME/.appstoreconnect" "$CARTELLA_CHIAVI" "$TEMP_ASC"
  local f
  f="$(file_chiave)"
  # base64 del file AuthKey_….p8 (anche su più righe); va bene anche il testo
  # del file così com'è (prima riga «BEGIN PRIVATE KEY» tra i trattini)
  if printf '%s' "$ASC_KEY_P8_BASE64" | grep -q 'BEGIN PRIVATE KEY'; then
    printf '%s\n' "$ASC_KEY_P8_BASE64" > "$f"
  elif ! printf '%s' "$ASC_KEY_P8_BASE64" | tr -d ' \r\n\t' | base64 --decode > "$f" 2> /dev/null; then
    rm -f "$f"
    errore "ASC_KEY_P8_BASE64 non è un base64 valido: codifica il file AuthKey_….p8 (PUBBLICAZIONE.md §6.4)."
    exit 1
  fi
  chmod 600 "$f"
  if ! grep -q 'BEGIN PRIVATE KEY' "$f"; then
    rm -f "$f"
    errore "ASC_KEY_P8_BASE64 non contiene una chiave .p8 (manca «BEGIN PRIVATE KEY»): codifica il file AuthKey_….p8 scaricato da App Store Connect."
    exit 1
  fi
  echo "Chiave API scritta in un file temporaneo (permessi 600), cancellata a fine job."
}

esporta() {
  local archivio="$1" uscita="$2" metodo="$3"
  valida team
  # nomi di Xcode 15.3 e successivi: app-store-connect (prima «app-store»),
  # release-testing (prima «ad-hoc»)
  case "$metodo" in
    app-store-connect | release-testing) ;;
    *)
      errore "metodo di esportazione non previsto: $metodo"
      exit 1
      ;;
  esac
  local f
  f="$(file_chiave)"
  [ -f "$f" ] || { errore "chiave API assente: manca il passo «chiave»"; exit 1; }
  mkdir -p "$TEMP_ASC"
  local opzioni="$TEMP_ASC/ExportOptions-$metodo.plist"
  # Solo per App Store Connect: numero di build deciso dalla build
  # (manageAppVersionAndBuildNumber falso) e simboli per i rapporti di crash.
  # L'ad hoc (release-testing) non passa da App Store Connect: il profilo
  # «ad hoc» gestito da Xcode contiene tutti i dispositivi registrati nel
  # team, e senza dispositivi l'esportazione non riesce.
  local solo_app_store=""
  if [ "$metodo" = "app-store-connect" ]; then
    solo_app_store="$(cat << 'SOLO'
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
SOLO
)"
  fi
  # firma automatica con i certificati gestiti nel cloud di Apple: nessun
  # certificato né profilo nei secret
  cat > "$opzioni" << FINE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$metodo</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>$APPLE_TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
$solo_app_store
</dict>
</plist>
FINE
  plutil -lint "$opzioni" > /dev/null
  if esporta_da "$archivio" "$uscita" "$opzioni" "$f"; then
    estensioni_esportate "$uscita"
    return 0
  fi
  # Archivio con i widget (WidgetUniNotes.appex) che non si esporta, di
  # solito per l'App Group non registrato nel portale: si riprova senza le
  # estensioni, come le build precedenti, e la build va avanti.
  if ! ls -d "$archivio"/Products/Applications/*.app/PlugIns/*.appex > /dev/null 2>&1; then
    return 1
  fi
  echo "::warning title=Widget iOS::esportazione «$metodo» con i widget non riuscita (errore di xcodebuild qui sopra): rifatta senza widget e Live Activity, come le build precedenti. Di solito manca l'App Group: developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → + → App Groups → $APP_GROUP; poi negli App ID $BUNDLE_APP e $BUNDLE_APP.$ESTENSIONE (crealo se manca: + → App IDs → App) spunta App Groups → Configure → quel gruppo → Save (docs/widget.md, «Portale Apple»)."
  local copia="${archivio%.xcarchive}-senza-estensioni.xcarchive"
  if [ ! -d "$copia" ]; then
    senza_estensioni "$archivio" "$copia"
  fi
  rm -rf "$uscita"
  esporta_da "$copia" "$uscita" "$opzioni" "$f"
  estensioni_esportate "$uscita"
}

esporta_da() {
  local archivio="$1" uscita="$2" opzioni="$3" f="$4"
  xcodebuild -exportArchive \
    -archivePath "$archivio" \
    -exportPath "$uscita" \
    -exportOptionsPlist "$opzioni" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$f" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

# Nel log: l'IPA esportato contiene i widget e la Live Activity?
estensioni_esportate() {
  local ipa contenuto
  for ipa in "$1"/*.ipa; do
    [ -f "$ipa" ] || continue
    contenuto="$(unzip -l "$ipa" 2> /dev/null || true)"
    case "$contenuto" in
      *"PlugIns/$ESTENSIONE.appex/"*) echo "$(basename "$ipa"): con $ESTENSIONE.appex (widget e Live Activity)." ;;
      *) echo "$(basename "$ipa"): senza estensioni (niente widget né Live Activity)." ;;
    esac
  done
}

# Firma locale «-» dell'archivio non firmato (CODE_SIGNING_ALLOWED=NO), come
# la build per il Mac App Store: -exportArchive legge gli entitlement dalla
# firma dell'archivio (qui l'App Group di app ed estensione) e firma di nuovo
# tutto con i certificati del cloud. Prima il codice annidato (framework,
# estensione), poi l'app. Nessun certificato, niente da cancellare.
firma_locale() {
  local archivio="$1" versione="$2" build="$3"
  local app="$archivio/Products/Applications/Runner.app"
  local estensione="$app/PlugIns/$ESTENSIONE.appex"
  local pb=/usr/libexec/PlistBuddy
  if [ ! -d "$estensione" ]; then
    avviso_widget "$ESTENSIONE.appex non è nell'archivio (Runner.app/PlugIns)"
    return 1
  fi
  local plist="$estensione/Info.plist" k
  for k in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion NSExtension:NSExtensionPointIdentifier; do
    echo "$ESTENSIONE.appex: $k = $("$pb" -c "Print :$k" "$plist" 2> /dev/null || echo '(assente)')"
  done
  # stessa versione e stesso numero di build dell'app (Apple rifiuta il
  # caricamento con valori diversi)
  if [ "$("$pb" -c 'Print :CFBundleIdentifier' "$plist" 2> /dev/null)" != "$BUNDLE_APP.$ESTENSIONE" ] \
    || [ "$("$pb" -c 'Print :CFBundleShortVersionString' "$plist" 2> /dev/null)" != "$versione" ] \
    || [ "$("$pb" -c 'Print :CFBundleVersion' "$plist" 2> /dev/null)" != "$build" ] \
    || [ "$("$pb" -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2> /dev/null)" != "com.apple.widgetkit-extension" ]; then
    avviso_widget "$ESTENSIONE.appex: bundle ID, versione, numero di build ($versione, $build) o tipo di estensione non previsti"
    return 1
  fi
  # su iOS 15 (deployment 15.6) ActivityKit e AppIntents non esistono:
  # collegati in modo obbligatorio, app o widget non partirebbero
  collegamenti "$app/Runner" || return 1
  collegamenti "$estensione/$ESTENSIONE" || return 1
  local x
  for x in "$app"/Frameworks/*; do
    case "$x" in
      *.framework | *.dylib) codesign --force --sign - --timestamp=none "$x" ;;
    esac
  done
  codesign --force --sign - --timestamp=none \
    --entitlements "$CARTELLA_APP/ios/$ESTENSIONE/$ESTENSIONE.entitlements" "$estensione"
  codesign --force --sign - --timestamp=none \
    --entitlements "$CARTELLA_APP/ios/Runner/Runner.entitlements" "$app"
  local b ent
  for b in "$estensione" "$app"; do
    ent="$(codesign -d --entitlements - "$b" 2>&1 || true)"
    case "$ent" in
      *"$APP_GROUP"*) echo "$(basename "$b"): firma locale con l'App Group $APP_GROUP." ;;
      *)
        avviso_widget "$(basename "$b"): App Group assente nella firma locale"
        return 1
        ;;
    esac
  done
}

# ActivityKit e AppIntents (iOS 16+) devono essere collegati come facoltativi
# (LC_LOAD_WEAK_DYLIB, -weak_framework negli xcconfig di Flutter): con un
# collegamento obbligatorio l'eseguibile non parte su iOS 15.
collegamenti() {
  local bin="$1" righe
  [ -f "$bin" ] || { avviso_widget "eseguibile non trovato: $bin"; return 1; }
  righe="$(otool -l "$bin" | awk '$1 == "cmd" { c = $2 } $1 == "name" && $2 ~ /\/(ActivityKit|AppIntents)\.framework\// { print c, $2 }')"
  echo "$(basename "$bin"): ${righe:-nessun collegamento ad ActivityKit o AppIntents}"
  case "$righe" in
    *"LC_LOAD_DYLIB "*)
      avviso_widget "$(basename "$bin") collega ActivityKit o AppIntents in modo obbligatorio: non partirebbe su iOS 15"
      return 1
      ;;
  esac
}

# Archivio (o sua copia) senza estensioni: niente PlugIns e niente firma
# locale con gli entitlement, cioè l'archivio delle build senza widget.
senza_estensioni() {
  local origine="$1" dest="${2:-$1}"
  if [ "$dest" != "$origine" ]; then
    rm -rf "$dest"
    ditto "$origine" "$dest"
  fi
  local app x
  app="$(ls -d "$dest"/Products/Applications/*.app | head -n 1)"
  rm -rf "$app/PlugIns"
  rm -rf "$dest"/dSYMs/*.appex.dSYM
  for x in "$app"/Frameworks/* "$app"; do
    codesign --remove-signature "$x" 2> /dev/null || true
  done
  echo "Archivio senza estensioni: $(basename "$dest")"
}

# Profilo incluso in un IPA: nome, scadenza e quanti dispositivi contiene
# (un iPhone non incluso dà «Impossibile installare l'app»). Gli UDID non si
# stampano: si contano soltanto.
profilo() {
  local ipa="$1"
  [ -f "$ipa" ] || { errore "IPA non trovato: $ipa"; exit 1; }
  local tmp="$TEMP_ASC/profilo"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  unzip -q -o "$ipa" 'Payload/*.app/embedded.mobileprovision' -d "$tmp"
  local mp
  mp="$(ls "$tmp"/Payload/*.app/embedded.mobileprovision | head -n 1)"
  security cms -D -i "$mp" > "$tmp/profilo.plist"
  local pb=/usr/libexec/PlistBuddy n
  n="$("$pb" -c 'Print :ProvisionedDevices' "$tmp/profilo.plist" 2> /dev/null | grep -c '^ ' || true)"
  echo "Profilo: $("$pb" -c 'Print :Name' "$tmp/profilo.plist" 2> /dev/null || echo '(senza nome)')"
  echo "Scadenza del profilo: $("$pb" -c 'Print :ExpirationDate' "$tmp/profilo.plist" 2> /dev/null || echo '(assente)')"
  echo "Dispositivi nel profilo: ${n:-0}"
  if [ "${n:-0}" -eq 0 ]; then
    echo "::warning title=Ad hoc::il profilo non contiene dispositivi: registra l'UDID dell'iPhone in developer.apple.com → Devices e rifai la build."
  fi
  rm -rf "$tmp"
}

# manifest.plist per itms-services: Safari lo legge e scarica l'IPA da <url
# ipa> (HTTPS obbligatorio). Valori controllati prima di entrare nel file.
manifesto() {
  local file="$1" bundle="$2" versione="$3" url="$4"
  if ! [[ "$bundle" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    errore "bundle ID non valido per il manifest: $bundle"
    exit 1
  fi
  if ! [[ "$versione" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    errore "versione non valida per il manifest: $versione"
    exit 1
  fi
  if ! [[ "$url" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)+\.ipa$ ]]; then
    errore "indirizzo dell'IPA non valido per il manifest (serve https://…/….ipa): $url"
    exit 1
  fi
  mkdir -p "$(dirname "$file")"
  cat > "$file" << FINE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>$url</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>$bundle</string>
				<key>bundle-version</key>
				<string>$versione</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>UniNotes</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
FINE
  if command -v plutil > /dev/null; then
    plutil -lint "$file" > /dev/null
  fi
  echo "Manifest per l'installazione da Safari: $(basename "$file") → $url"
}

carica() {
  local file="$1" tipo="$2" bundle="$3" versione="$4" build="$5"
  valida
  [ -f "$file" ] || { errore "file da caricare non trovato: $file"; exit 1; }
  [ -f "$(file_chiave)" ] || { errore "chiave API assente: manca il passo «chiave»"; exit 1; }
  # altool cerca AuthKey_<ID>.p8 in questa cartella
  export API_PRIVATE_KEYS_DIR="$CARTELLA_CHIAVI"
  local args
  if [ -n "${APPSTORE_ID:-}" ]; then
    # con l'Apple ID numerico dell'app: altool di Xcode 26 a volte non ricava
    # l'app dal bundle ID («Cannot determine the Apple ID from Bundle ID»)
    args=(--upload-package "$file" --type "$tipo" --apple-id "$APPSTORE_ID"
      --bundle-id "$bundle" --bundle-version "$build"
      --bundle-short-version-string "$versione")
  else
    args=(--upload-app --type "$tipo" --file "$file")
  fi
  args+=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
  mkdir -p "$TEMP_ASC"
  local log="$TEMP_ASC/altool-$tipo.log"
  set +e
  xcrun altool "${args[@]}" 2>&1 | tee "$log"
  local stato=${PIPESTATUS[0]}
  set -e
  # con Xcode 26 altool può uscire con 0 anche se il caricamento non è
  # riuscito: si legge anche il testo
  if [ "$stato" -ne 0 ] || grep -Eiq 'UPLOAD FAILED|(^|[^a-z])error[: ]' "$log"; then
    errore "caricamento di $(basename "$file") non riuscito (codice $stato): leggi le righe con «ERROR» qui sopra (PUBBLICAZIONE.md §6.4, «Se qualcosa va storto»)."
    exit 1
  fi
  if ! grep -Eiq 'UPLOAD SUCCEEDED|No errors uploading' "$log"; then
    echo "::warning title=App Store Connect::altool non ha confermato il caricamento: controlla in App Store Connect → TestFlight che la build $versione ($build) compaia entro un'ora."
  fi
  echo "Caricata la build $versione ($build) per $tipo: in TestFlight dopo l'elaborazione di Apple (10–30 minuti)."
}

notarizza() {
  local file="$1"
  valida
  local f
  f="$(file_chiave)"
  [ -f "$f" ] || { errore "chiave API assente: manca il passo «chiave»"; exit 1; }
  mkdir -p "$TEMP_ASC"
  local log="$TEMP_ASC/notarytool.log"
  set +e
  xcrun notarytool submit "$file" --key "$f" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --wait --timeout 2h 2>&1 | tee "$log"
  local stato=${PIPESTATUS[0]}
  set -e
  # «status: Accepted» = notarizzato; con «Invalid» il registro di Apple dice
  # quale file non va (firma, runtime protetto, entitlement)
  if [ "$stato" -ne 0 ] || ! grep -q 'status: Accepted' "$log"; then
    local id
    id="$(awk '$1 == "id:" { print $2; exit }' "$log")"
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --key "$f" --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" || true
    fi
    errore "notarizzazione di $(basename "$file") non riuscita (codice $stato): il registro di Apple è qui sopra."
    exit 1
  fi
  xcrun stapler staple "$file"
}

pulisci() {
  rm -rf "$CARTELLA_CHIAVI" "$TEMP_ASC"
  echo "Chiave API e file temporanei cancellati."
}

comando="${1:-}"
[ $# -gt 0 ] && shift
case "$comando" in
  controlla) controlla "$@" ;;
  chiave) chiave ;;
  esporta) esporta "$@" ;;
  firma-locale) firma_locale "$@" ;;
  collegamenti) collegamenti "$@" ;;
  senza-estensioni) senza_estensioni "$@" ;;
  profilo) profilo "$@" ;;
  manifesto) manifesto "$@" ;;
  carica) carica "$@" ;;
  notarizza) notarizza "$@" ;;
  pulisci) pulisci ;;
  *)
    echo "uso: $0 controlla|chiave|esporta|firma-locale|collegamenti|senza-estensioni|profilo|manifesto|carica|notarizza|pulisci" >&2
    exit 2
    ;;
esac
