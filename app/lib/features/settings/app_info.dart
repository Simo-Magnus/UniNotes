/// Informazioni sull'app mostrate in Impostazioni.
/// Versione: la imposta la build automatica a ogni build
/// (`--dart-define=APP_VERSION=AAAA.M.N`, anno e mese della build e numero
/// progressivo dell'esecuzione, sempre crescente; vedi
/// `.github/workflows/app.yml`). Nelle build fatte a mano resta quella di
/// `version:` in pubspec.yaml.
const String kAppName = 'UniNotes';
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '2026.9.0',
);
