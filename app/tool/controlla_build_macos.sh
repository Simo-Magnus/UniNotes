#!/usr/bin/env bash
# Controllo della build per Mac in CI (macos-latest, Apple Silicon), dopo la
# firma: la build fino al 30/10/2026 era «danneggiata» per i Mac perché i
# modelli entravano nel pacchetto dopo la firma (sigillo rotto). Si ferma con
# un errore se:
#   - la firma di UniNotes.app non è intera (codesign --verify --deep --strict:
#     file aggiunti o cambiati dopo la firma, librerie non firmate);
#   - mancano i modelli inclusi (Parakeet, Whisper small);
#   - l'app non parte o si chiude entro 25 s (solo «app»: su Apple Silicon un
#     programma con la firma rotta viene chiuso subito dal sistema).
#
#   bash tool/controlla_build_macos.sh app UniNotes.app
#   bash tool/controlla_build_macos.sh zip uninotes-macos.zip
#   bash tool/controlla_build_macos.sh dmg UniNotes.dmg
set -euo pipefail

errore() {
  echo "::error title=Build per Mac::$1"
  exit 1
}

controlla_app() {
  local app="$1"
  [ -d "$app" ] || errore "UniNotes.app non trovata: $app"
  echo "== firma di $app"
  codesign -dvv "$app" 2>&1 | grep -E "^(Identifier|Format|Signature|Authority|TeamIdentifier|Sealed Resources)" || true
  if ! codesign --verify --deep --strict --verbose=2 "$app"; then
    errore "firma non valida o sigillo rotto in $app: il Mac direbbe che l'app è danneggiata"
  fi
  for f in parakeet/encoder.int8.onnx parakeet/tokens.txt whisper; do
    [ -e "$app/Contents/Resources/$f" ] || errore "manca Contents/Resources/$f in $app"
  done
  # solo informativo: senza notarizzazione Gatekeeper la rifiuta (il primo
  # avvio si fa con «Apri comunque»), con la notarizzazione la accetta
  spctl --assess --type execute --verbose=2 "$app" 2>&1 || true
}

avvia_app() {
  local app="$1"
  local exe
  exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")
  local log="${RUNNER_TEMP:-/tmp}/avvio_uninotes.log"
  echo "== avvio di $exe per 25 s"
  "$app/Contents/MacOS/$exe" > "$log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 25); do
    sleep 1
    kill -0 "$pid" 2> /dev/null || break
  done
  if kill -0 "$pid" 2> /dev/null; then
    echo "UniNotes è partita ed è ancora aperta dopo 25 s"
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    return 0
  fi
  local code=0
  wait "$pid" || code=$?
  tail -n 60 "$log" || true
  errore "UniNotes si è chiusa subito dopo l'avvio (codice $code)"
}

modo="${1:-}"
percorso="${2:-}"
[ -n "$percorso" ] || errore "uso: controlla_build_macos.sh app|zip|dmg <percorso>"
case "$modo" in
  app)
    controlla_app "$percorso"
    avvia_app "$percorso"
    ;;
  zip)
    tmp=$(mktemp -d)
    ditto -x -k "$percorso" "$tmp"
    controlla_app "$tmp/UniNotes.app"
    rm -rf "$tmp"
    ;;
  dmg)
    mnt=$(mktemp -d)
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$percorso" > /dev/null
    trap 'hdiutil detach "$mnt" > /dev/null 2>&1 || true' EXIT
    controlla_app "$mnt/UniNotes.app"
    [ -L "$mnt/Applicazioni" ] || errore "manca il collegamento ad Applicazioni nel DMG"
    ;;
  *)
    errore "modo sconosciuto: $modo (app, zip o dmg)"
    ;;
esac
echo "Build per Mac controllata: $modo $percorso"
