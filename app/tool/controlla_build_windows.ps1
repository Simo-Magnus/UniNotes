# Controllo della build per Windows in CI (windows-latest), come la usa chi
# la scarica: lo zip estratto e l'installatore installato in silenzio in una
# cartella temporanea. Si ferma con un errore se mancano il programma, le
# librerie della trascrizione o i modelli inclusi, o se UniNotes non parte o
# si chiude entro 25 s. Poi disinstalla.
#
#   pwsh tool/controlla_build_windows.ps1 -Zip uninotes-windows.zip -Setup UniNotes_setup.exe
param(
  [Parameter(Mandatory = $true)][string]$Zip,
  [Parameter(Mandatory = $true)][string]$Setup
)
$ErrorActionPreference = 'Stop'

function Errore([string]$messaggio) {
  Write-Output "::error title=Build per Windows::$messaggio"
  exit 1
}

function Controlla-Cartella([string]$dir) {
  foreach ($f in @(
      'uninotes.exe', 'flutter_windows.dll', 'whisper_ggml.dll',
      'sherpa-onnx-c-api.dll', 'onnxruntime.dll',
      'data\app.so', 'data\flutter_assets',
      'data\parakeet\encoder.int8.onnx', 'data\parakeet\tokens.txt',
      'data\whisper')) {
    if (-not (Test-Path (Join-Path $dir $f))) { Errore "manca $f in $dir" }
  }
}

# Con /SUPPRESSMSGBOXES gli errori di Inno Setup non si vedono: finiscono
# solo nel registro (/LOG). Un «Errore interno» dello script (30/10/2026:
# UninstallSilent chiamato durante l'installazione) fa fallire il controllo.
function Controlla-Registro([string]$registro, [string]$cosa) {
  if (-not (Test-Path $registro)) { Errore "manca il registro di $cosa" }
  $righe = Get-Content $registro
  $err = $righe | Select-String -Pattern 'Errore interno|Internal error|Runtime error|Expression error|Exception message'
  if ($err) {
    $righe | Write-Output
    Errore "$cosa con errori: $($err[0].Line)"
  }
}

function Avvia([string]$exe) {
  Write-Output "== avvio di $exe per 25 s"
  $p = Start-Process -FilePath $exe -PassThru
  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    if ($p.HasExited) { break }
  }
  if ($p.HasExited) { Errore "UniNotes si è chiusa subito dopo l'avvio (codice $($p.ExitCode))" }
  Write-Output 'UniNotes è partita ed è ancora aperta dopo 25 s'
  # chiude anche le finestre figlie (WebView) avviate dall'app
  & taskkill /PID $p.Id /T /F | Out-Null
  Start-Sleep -Seconds 2
}

# zip estratto
$z = Join-Path $env:RUNNER_TEMP 'uninotes_zip'
if (Test-Path $z) { Remove-Item -Recurse -Force $z }
Expand-Archive -Path $Zip -DestinationPath $z
Controlla-Cartella $z
Avvia (Join-Path $z 'uninotes.exe')
Remove-Item -Recurse -Force $z -ErrorAction SilentlyContinue

# installatore (per l'utente, senza amministratore: PrivilegesRequired=lowest)
$dir = Join-Path $env:RUNNER_TEMP 'uninotes_installata'
$logSetup = Join-Path $env:RUNNER_TEMP 'uninotes_setup.log'
$s = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$dir`"", "/LOG=`"$logSetup`"" -Wait -PassThru
if ($s.ExitCode -ne 0) { Errore "installatore non riuscito (codice $($s.ExitCode))" }
Controlla-Registro $logSetup 'installazione'
Controlla-Cartella $dir
Avvia (Join-Path $dir 'uninotes.exe')
$u = Join-Path $dir 'unins000.exe'
if (-not (Test-Path $u)) { Errore 'manca il disinstallatore unins000.exe' }
$logUninst = Join-Path $env:RUNNER_TEMP 'uninotes_disinstallazione.log'
$d = Start-Process -FilePath $u -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$logUninst`"" -Wait -PassThru
if ($d.ExitCode -ne 0) { Errore "disinstallazione non riuscita (codice $($d.ExitCode))" }
# il disinstallatore si copia in una cartella temporanea e finisce da lì:
# si aspetta che la cartella del programma sparisca
for ($i = 0; $i -lt 30 -and (Test-Path (Join-Path $dir 'uninotes.exe')); $i++) { Start-Sleep -Seconds 1 }
Controlla-Registro $logUninst 'disinstallazione'
if (Test-Path (Join-Path $dir 'uninotes.exe')) { Errore 'dopo la disinstallazione uninotes.exe è ancora nella cartella del programma' }
Write-Output 'Build per Windows controllata: zip e installatore'
