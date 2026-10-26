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
#   carica <file> <ios|macos> <bundle id> <versione> <build>
#                                 caricamento su App Store Connect (TestFlight)
#   notarizza <file>              notarizzazione con la chiave API e staple
#   pulisci                       cancella la chiave e i file temporanei
#
# Compatibile con il bash 3.2 di macOS.
set -euo pipefail

CARTELLA_CHIAVI="$HOME/.appstoreconnect/private_keys"
TEMP_ASC="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/asc"

errore() { echo "::error title=App Store Connect::$1"; }

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
  local f
  f="$(file_chiave)"
  [ -f "$f" ] || { errore "chiave API assente: manca il passo «chiave»"; exit 1; }
  mkdir -p "$TEMP_ASC"
  local opzioni="$TEMP_ASC/ExportOptions-$metodo.plist"
  # firma automatica con i certificati gestiti nel cloud di Apple: nessun
  # certificato né profilo nei secret. Numero di build deciso dalla build
  # (manageAppVersionAndBuildNumber falso), simboli per i rapporti di crash.
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
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
FINE
  plutil -lint "$opzioni" > /dev/null
  xcodebuild -exportArchive \
    -archivePath "$archivio" \
    -exportPath "$uscita" \
    -exportOptionsPlist "$opzioni" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$f" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
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
  carica) carica "$@" ;;
  notarizza) notarizza "$@" ;;
  pulisci) pulisci ;;
  *)
    echo "uso: $0 controlla|chiave|esporta|carica|notarizza|pulisci" >&2
    exit 2
    ;;
esac
