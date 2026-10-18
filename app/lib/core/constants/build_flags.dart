/// Opzioni scelte al momento della build (`--dart-define=…`), vedi
/// impostazioni del repository (secret della build).
library;

/// none | link | iap. Predefinito sicuro per gli store: none (anche se il
/// valore passato alla build è vuoto).
const String _donations = String.fromEnvironment('DONATIONS');
const String kDonations = _donations == '' ? 'none' : _donations;

/// Pulsante «Sostieni il progetto» (solo dove lo store lo consente).
const bool kShowDonationLink = kDonations == 'link';

/// Pagina delle donazioni libere.
const String kDonationUrl = String.fromEnvironment(
  'DONATION_URL',
  defaultValue: 'https://simo-magnus.github.io/UniNotes/sostieni',
);

/// Pagina del progetto (mostrata in tutte le build).
const String kProjectUrl = String.fromEnvironment(
  'PROJECT_URL',
  defaultValue: 'https://simo-magnus.github.io/UniNotes/',
);

/// Canale da cui è stata scaricata l'app: github (predefinito: sito e
/// release di GitHub, anche per macOS), microsoft, play, appstore (iPhone e
/// iPad). Decide dove portare «Lascia una recensione» (vedi
/// core/services/nudges.dart).
const String kStoreChannel = String.fromEnvironment(
  'STORE',
  defaultValue: 'github',
);

/// Build per il Microsoft Store (pacchetto MSIX, `STORE=microsoft`).
const bool kMicrosoftStoreBuild = kStoreChannel == 'microsoft';

/// Cosa l'app può fare da sola secondo il canale di distribuzione [store]
/// (predefinito: quello della build; nei test si passa a mano).
class StoreRules {
  const StoreRules([this.store = kStoreChannel]);

  final String store;

  bool get microsoftStore => store == 'microsoft';

  /// Controllo di nuove versioni dell'app e download dal sito: solo nelle
  /// build del sito (GitHub). Negli store gli aggiornamenti li fa lo store
  /// (il Microsoft Store vieta di aggiornarsi da soli fuori dallo Store).
  /// Gli aggiornamenti del database dei corsi sono dati, non programma, e
  /// restano in tutte le build.
  bool get selfUpdate => store == 'github';

  /// Windows: disinstallatore di UniNotes_setup.exe (Inno Setup) e avvio
  /// `uninotes.exe --disinstalla`. Nel Microsoft Store l'app si toglie da
  /// Windows (Start o «App installate»), che elimina anche i dati in
  /// `%LOCALAPPDATA%\Packages\…`.
  bool get windowsUninstaller => !microsoftStore;
}

/// Repository del progetto (per «Metti una stella su GitHub»).
const String kGithubRepoUrl = 'https://github.com/Simo-Magnus/UniNotes';

/// Informativa sulla privacy e termini d'uso (PRIVACY.md e TERMINI.md nel
/// repository), aperti da Impostazioni → Privacy e informazioni.
const String kPrivacyUrl = '$kGithubRepoUrl/blob/main/PRIVACY.md';
const String kTermsUrl = '$kGithubRepoUrl/blob/main/TERMINI.md';

/// ID dell'app negli store che lo richiedono per il link alla recensione.
const String kAppStoreId = String.fromEnvironment('APPSTORE_ID');
const String kMsStoreProductId = String.fromEnvironment('MSSTORE_ID');
