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

/// Canale da cui è stata scaricata l'app: github (predefinito), microsoft,
/// play, appstore, macappstore, fdroid. Decide dove portare «Lascia una
/// recensione» (vedi core/services/nudges.dart).
const String kStoreChannel = String.fromEnvironment(
  'STORE',
  defaultValue: 'github',
);

/// Repository del progetto (per «Metti una stella su GitHub»).
const String kGithubRepoUrl = 'https://github.com/Simo-Magnus/UniNotes';

/// Informativa sulla privacy e termini d'uso (PRIVACY.md e TERMINI.md nel
/// repository), aperti da Impostazioni → Privacy e informazioni.
const String kPrivacyUrl = '$kGithubRepoUrl/blob/main/PRIVACY.md';
const String kTermsUrl = '$kGithubRepoUrl/blob/main/TERMINI.md';

/// ID dell'app negli store che lo richiedono per il link alla recensione.
const String kAppStoreId = String.fromEnvironment('APPSTORE_ID');
const String kMsStoreProductId = String.fromEnvironment('MSSTORE_ID');
