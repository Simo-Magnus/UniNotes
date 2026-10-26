import 'package:flutter/widgets.dart';

/// Schema dei collegamenti dell'app (`uninotes://widget/…`, `focus/…`,
/// `auth`).
const String kAppLinkScheme = 'uninotes';

/// I collegamenti `uninotes://…` li gestisce il codice nativo (tocchi sui
/// widget, ritorno da Comandi, ritorno dall'accesso nel browser). Flutter
/// però li inoltra anche al Navigator come «percorsi» (`/exams`): l'app non
/// ha percorsi con nome, quindi ogni tocco su un widget con l'app aperta
/// lanciava «Could not find a generator for route» e finiva nel registro
/// degli errori. Questo osservatore li dichiara gestiti: va aggiunto prima
/// di `runApp`, perché gli osservatori sono interrogati in ordine e il primo
/// che risponde sì ferma gli altri.
///
/// Anche tutti gli altri indirizzi: su Android un'altra app può aprire
/// l'attività principale (esportata) con un indirizzo qualsiasi
/// (`https://…/testo`), che Flutter passa al Navigator come percorso; l'app
/// non ne ha, quindi l'unico effetto era un errore con il testo scelto da
/// quell'app nel registro degli errori.
class AppLinkGuard with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async => true;
}

final AppLinkGuard _guard = AppLinkGuard();

/// Aggiunge l'[AppLinkGuard] (una sola volta anche se chiamata di nuovo).
void installAppLinkGuard() {
  final binding = WidgetsBinding.instance;
  binding.removeObserver(_guard);
  binding.addObserver(_guard);
}
