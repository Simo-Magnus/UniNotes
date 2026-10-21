<#
Crea UniNotes.msix per il Microsoft Store dalla cartella Release della build
Windows (flutter build windows --release --dart-define=STORE=microsoft ...).

- Versione da pubspec.yaml: 2026.9.0+1 -> 2026.9.0.0 (regole dello Store:
  quattro numeri da 0 a 65535, il primo diverso da 0, l'ultimo sempre 0).
- Identita' del pacchetto (Partner Center -> Gestione prodotti -> Identita'
  prodotto) dai parametri o dalle variabili d'ambiente MSSTORE_IDENTITY_NAME,
  MSSTORE_PUBLISHER (CN=...) e MSSTORE_PUBLISHER_DISPLAY_NAME; nome
  visualizzato nello Store da MSSTORE_DISPLAY_NAME (il nome prenotato in
  Partner Center; se manca, "UniNotes"). Dentro l'app il nome resta UniNotes.
- Copia la build, AppxManifest.xml e le icone (Assets), crea resources.pri
  per le icone con piu' dimensioni (makepri) e impacchetta con makeappx del
  Windows SDK. Il pacchetto NON viene firmato: lo firma lo Store.

Uso (dalla cartella app):
  powershell -File windows\msix\crea_msix.ps1 -Output build\msix\UniNotes.msix
In CI lo usa il job microsoft-store di .github/workflows/app.yml.
#>
param(
  [string]$Release = 'build\windows\x64\runner\Release',
  [string]$Output = 'build\msix\UniNotes.msix',
  [string]$Pubspec = 'pubspec.yaml',
  [string]$IdentityName = $env:MSSTORE_IDENTITY_NAME,
  [string]$Publisher = $env:MSSTORE_PUBLISHER,
  [string]$PublisherDisplayName = $env:MSSTORE_PUBLISHER_DISPLAY_NAME,
  [string]$DisplayName = $env:MSSTORE_DISPLAY_NAME
)

$ErrorActionPreference = 'Stop'
$qui = $PSScriptRoot

function Avviso([string]$testo) {
  if ($env:GITHUB_ACTIONS -eq 'true') { Write-Output "::warning title=Microsoft Store::$testo" }
  else { Write-Warning $testo }
}

# --- versione ---------------------------------------------------------------
$riga = Select-String -Path $Pubspec -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $riga) { throw "version: non trovata in $Pubspec" }
$nome = $riga.Matches[0].Groups[1].Value.Split('+')[0]
$parti = $nome.Split('.')
if ($parti.Count -ne 3) { throw "Versione '$nome': servono tre numeri (es. 2026.9.0)" }
foreach ($x in $parti) {
  if ($x -notmatch '^\d+$' -or [int64]$x -gt 65535) {
    throw "Versione '$nome': ogni numero va da 0 a 65535"
  }
}
if ([int64]$parti[0] -eq 0) { throw "Versione '$nome': il primo numero non puo' essere 0" }
$versione = (($parti | ForEach-Object { [string][int64]$_ }) -join '.') + '.0'

# --- identita' di Partner Center ---------------------------------------------
if (-not $IdentityName -or -not $Publisher -or -not $PublisherDisplayName) {
  throw 'Mancano MSSTORE_IDENTITY_NAME, MSSTORE_PUBLISHER o MSSTORE_PUBLISHER_DISPLAY_NAME (Partner Center -> Identita'' prodotto)'
}
$IdentityName = $IdentityName.Trim()
$Publisher = $Publisher.Trim()
$PublisherDisplayName = $PublisherDisplayName.Trim()
if ($IdentityName -notmatch '^[A-Za-z0-9.\-]{3,50}$') {
  throw "MSSTORE_IDENTITY_NAME non valido: solo lettere, cifre, punto e trattino (3-50 caratteri)"
}
if ($Publisher -notmatch '^CN=') { throw 'MSSTORE_PUBLISHER deve iniziare con CN= (es. CN=1A2B3C4D-...)' }
# nome visualizzato: deve coincidere con il nome prenotato in Partner Center
if ($DisplayName) { $DisplayName = $DisplayName.Trim() }
if (-not $DisplayName) { $DisplayName = 'UniNotes' }
if ($DisplayName.Length -gt 256) { throw 'MSSTORE_DISPLAY_NAME troppo lungo (massimo 256 caratteri)' }
Write-Output "Nome nello Store: $DisplayName"

# --- strumenti del Windows SDK ----------------------------------------------
$kit = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeappx = Get-ChildItem -Path "$kit\10.*\x64\makeappx.exe" -ErrorAction SilentlyContinue |
  Sort-Object { [version]$_.Directory.Parent.Name } | Select-Object -Last 1
if (-not $makeappx) { throw "makeappx.exe non trovato in $kit (serve il Windows 10/11 SDK)" }
$makepri = Join-Path $makeappx.DirectoryName 'makepri.exe'
if (-not (Test-Path $makepri)) { throw "makepri.exe non trovato accanto a $($makeappx.FullName)" }
Write-Output "Windows SDK: $($makeappx.Directory.Parent.Name)"

# --- cartella del pacchetto -------------------------------------------------
if (-not (Test-Path (Join-Path $Release 'uninotes.exe'))) {
  throw "uninotes.exe non trovato in ${Release}: prima flutter build windows --release --dart-define=STORE=microsoft"
}
$uscita = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
$lavoro = Join-Path (Split-Path -Parent $uscita) 'msix_lavoro'
if (Test-Path $lavoro) { Remove-Item -Recurse -Force $lavoro }
$pacchetto = Join-Path $lavoro 'pacchetto'
$risorse = Join-Path $lavoro 'risorse'
New-Item -ItemType Directory -Force -Path $pacchetto, $risorse | Out-Null
Copy-Item -Path (Join-Path $Release '*') -Destination $pacchetto -Recurse
Copy-Item -Path (Join-Path $qui 'Assets') -Destination $pacchetto -Recurse

# testo dal vivo: Parakeet con sherpa-onnx (le DLL del plugin accanto
# all'eseguibile; il modello lo scarica l'app alla prima registrazione)
foreach ($dll in 'sherpa-onnx-c-api.dll', 'onnxruntime.dll') {
  if (-not (Test-Path (Join-Path $pacchetto $dll))) {
    Avviso "Manca $dll accanto a uninotes.exe: il testo dal vivo con Parakeet non funzionera'."
  }
}

# --- manifest -----------------------------------------------------------------
function Xml([string]$s) { [System.Security.SecurityElement]::Escape($s) }
$testo = [IO.File]::ReadAllText((Join-Path $qui 'AppxManifest.xml'), [Text.Encoding]::UTF8)
$testo = $testo.Replace('__MSSTORE_IDENTITY_NAME__', (Xml $IdentityName))
$testo = $testo.Replace('__MSSTORE_PUBLISHER_DISPLAY_NAME__', (Xml $PublisherDisplayName))
$testo = $testo.Replace('__MSSTORE_PUBLISHER__', (Xml $Publisher))
$testo = $testo.Replace('__MSSTORE_DISPLAY_NAME__', (Xml $DisplayName))
$testo = $testo.Replace('__VERSION__', $versione)
if ($testo -match '__[A-Z_]+__') { throw "Segnaposto non sostituito nel manifest: $($Matches[0])" }
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $pacchetto 'AppxManifest.xml'), $testo, $utf8)

# --- resources.pri: le icone in tutte le dimensioni (scale e targetsize) ------
# solo manifest e Assets: le altre migliaia di file non servono all'indice
Copy-Item -Path (Join-Path $pacchetto 'AppxManifest.xml') -Destination $risorse
Copy-Item -Path (Join-Path $qui 'Assets') -Destination $risorse -Recurse
$config = Join-Path $lavoro 'priconfig.xml'
& $makepri createconfig /cf $config /dq it-IT /pv 10.0.0 /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri createconfig: errore $LASTEXITCODE" }
# un solo resources.pri: senza <packaging> makepri non lo divide in pacchetti
# di risorse per scala e lingua, che servono solo ai bundle
$xml = [IO.File]::ReadAllText($config)
$xml = [regex]::Replace($xml, '(?s)\s*<packaging>.*?</packaging>', '')
[IO.File]::WriteAllText($config, $xml, $utf8)
& $makepri new /pr $risorse /cf $config /mn (Join-Path $risorse 'AppxManifest.xml') /of (Join-Path $pacchetto 'resources.pri') /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri new: errore $LASTEXITCODE" }

# --- pacchetto (non firmato) ---------------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $uscita) | Out-Null
& $makeappx.FullName pack /d $pacchetto /p $uscita /o
if ($LASTEXITCODE -ne 0) { throw "makeappx pack: errore $LASTEXITCODE" }
Remove-Item -Recurse -Force $lavoro
Write-Output ("UniNotes.msix {0} creato: {1} ({2:N0} MB), non firmato (lo firma lo Store)" -f $versione, $uscita, ((Get-Item $uscita).Length / 1MB))
