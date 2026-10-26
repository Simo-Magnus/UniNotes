import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/services/loopback_oauth.dart';

export '../../core/services/loopback_oauth.dart'
    show OAuthTokens, OAuthException;

/// Come torna all'app la pagina di accesso di Microsoft.
enum OAuthRedirectMode {
  /// PC e Mac: server locale su `http://localhost:<porta>`.
  loopback,

  /// Telefono: schema personalizzato `msauth.<bundle id>://auth`, aperto
  /// con il browser di sistema (ASWebAuthenticationSession su iOS, Custom
  /// Tabs su Android) tramite `flutter_web_auth_2`.
  customScheme,
}

/// Sul telefono un server su localhost non è affidabile (il sistema può
/// sospendere l'app mentre il browser è in primo piano): si usa lo schema.
OAuthRedirectMode microsoftRedirectMode({required bool mobile}) =>
    mobile ? OAuthRedirectMode.customScheme : OAuthRedirectMode.loopback;

/// Apre [url] e restituisce l'indirizzo di ritorno con lo schema
/// [callbackScheme] (nei test: finto).
typedef WebAuthenticator = Future<String> Function(
  Uri url,
  String callbackScheme,
);

Future<String> _flutterWebAuth(Uri url, String scheme) =>
    FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: scheme,
      options: const FlutterWebAuth2Options(preferEphemeral: false),
    );

/// Accesso con l'account Microsoft per OneDrive e OneNote (Microsoft Graph).
///
/// Client pubblico con PKCE, nessun secret. **Registrazione dell'app in
/// Microsoft Entra** (una sola volta, a cura di chi pubblica l'app; gli
/// studenti non devono fare nulla perché l'ID viene incluso nella build con
/// `--dart-define=MS_CLIENT_ID=<id>`):
///
/// 1. Entra → Registrazioni app → Nuova registrazione; tipi di account:
///    «Account in qualsiasi directory organizzativa e account Microsoft
///    personali» (tenant `common`).
/// 2. Autenticazione → Aggiungi piattaforma «App per dispositivi mobili e
///    desktop» con gli URI di reindirizzamento:
///    - `http://localhost` (Windows, macOS: qualsiasi porta è accettata);
///    - `msauth.io.github.simomagnus.universitynotes://auth` (iOS e Android,
///      [mobileRedirectUri]; su iOS è lo stesso URI che Entra propone per la
///      piattaforma «iOS/macOS» con bundle id
///      `io.github.simomagnus.universitynotes`).
/// 3. Autenticazione → Impostazioni avanzate → «Consenti flussi client
///    pubblici»: Sì.
/// 4. Autorizzazioni API (delegate, Microsoft Graph): `User.Read`,
///    `Files.ReadWrite`, `Notes.Read`, `offline_access`; per il calendario
///    Outlook su Windows anche `Calendars.ReadWrite` ([calendarScope]).
///
/// Dettagli in `docs/onedrive_setup.md`.
class MicrosoftOAuth extends LoopbackOAuth {
  MicrosoftOAuth({
    required super.clientId,
    required super.openBrowser,
    super.httpClient,
    String tenant = defaultTenant,
    this.mode = OAuthRedirectMode.loopback,
    WebAuthenticator? webAuthenticator,
    Uri? authority,
    super.scope = defaultScope,
  }) : _webAuth = webAuthenticator ?? _flutterWebAuth,
       super(
         providerName: 'Microsoft',
         authEndpoint: (authority ?? defaultAuthority).resolve(
           '$tenant/oauth2/v2.0/authorize',
         ),
         tokenEndpoint: (authority ?? defaultAuthority).resolve(
           '$tenant/oauth2/v2.0/token',
         ),
         redirectHost: 'localhost',
         extraAuthParams: const {'prompt': 'select_account'},
         scopeOnRefresh: true,
         explainError: explain,
       );

  /// Server di accesso di Microsoft (nei test: server finto).
  static final defaultAuthority = Uri.https('login.microsoftonline.com', '/');

  final OAuthRedirectMode mode;
  final WebAuthenticator _webAuth;

  /// Schema registrato su iOS e Android (AndroidManifest: CallbackActivity
  /// di flutter_web_auth_2).
  static const mobileScheme = 'msauth.io.github.simomagnus.universitynotes';
  static const mobileRedirectUri = '$mobileScheme://auth';

  /// ID applicazione (client) di UniNotes registrato in Microsoft
  /// Entra: è pubblico (client senza segreti, con PKCE) e vale per tutte le
  /// build; `--dart-define=MS_CLIENT_ID=…` lo sostituisce (es. per un fork).
  static const defaultClientId = '24f57293-12b8-4d3d-b33f-f55effdaa44f';
  static const _envClientId = String.fromEnvironment('MS_CLIENT_ID');

  /// Un `--dart-define=MS_CLIENT_ID=` vuoto (es. secret non configurato nelle
  /// build di GitHub) non deve togliere l'ID: si usa quello dell'app.
  static const builtInClientId = _envClientId == ''
      ? defaultClientId
      : _envClientId;

  @override
  Future<OAuthTokens> signIn({
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
  }) {
    if (mode == OAuthRedirectMode.loopback) {
      return super.signIn(loginHint: loginHint, timeout: timeout);
    }
    return _signInMobile(loginHint: loginHint);
  }

  Future<OAuthTokens> _signInMobile({String? loginHint}) async {
    final verifier = LoopbackOAuth.randomToken(48);
    final state = LoopbackOAuth.randomToken(16);
    final url = authorizeUrl(
      redirect: mobileRedirectUri,
      verifier: verifier,
      state: state,
      loginHint: loginHint,
    );
    final String result;
    try {
      result = await _webAuth(url, mobileScheme);
    } on OAuthException {
      rethrow;
    } catch (e) {
      final text = '$e';
      if (text.contains('CANCELED') || text.contains('canceled')) {
        throw OAuthException('Accesso con Microsoft annullato.');
      }
      throw OAuthException('Accesso con Microsoft non riuscito: $text');
    }
    final q = Uri.parse(result).queryParameters;
    final code = q['code'];
    if (q['state'] != state) {
      // ritorno che non viene dalla pagina di accesso aperta dall'app (un'altra
      // app può aprire lo schema): niente codice né testo preso da lì
      throw OAuthException(foreignReturnMessage('Microsoft'));
    }
    if (code == null) {
      throw OAuthException(
        'Accesso con Microsoft non riuscito: '
        '${explain(q['error_description'] ?? q['error'] ?? 'risposta non valida')}',
      );
    }
    return exchangeCode(code, redirect: mobileRedirectUri, verifier: verifier);
  }

  /// «common» = account personali e universitari; «consumers» = solo
  /// personali (outlook/hotmail/live); «organizations» = solo di lavoro o
  /// scuola; oppure l'ID della directory (tenant).
  static const defaultTenant = 'common';

  /// Solo valori validi: common, consumers, organizations, l'ID della
  /// directory (GUID) o un dominio (es. studenti.ateneo.it). Altro (es. un
  /// indirizzo web arrivato da un file) torna a «common», così l'accesso va
  /// sempre a login.microsoftonline.com.
  static String normalizeTenant(String? v) {
    final t = v?.trim().toLowerCase() ?? '';
    final ok = RegExp(
      r'^(common|consumers|organizations|'
      r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|'
      r'[a-z0-9-]+(\.[a-z0-9-]+)+)$',
    ).hasMatch(t);
    return ok ? t : defaultTenant;
  }

  /// Errori di Microsoft Entra (AADSTS…) → causa e rimedio in italiano.
  static String explain(String raw) {
    final code = RegExp(r'AADSTS(\d+)').firstMatch(raw)?.group(1);
    final hint = switch (code) {
      '50011' || '500113' =>
        'L\'indirizzo di reindirizzamento non corrisponde. Nella registrazione '
            'dell\'app (Microsoft Entra → Autenticazione) aggiungi la piattaforma '
            '«App per dispositivi mobili e desktop» con gli URI http://localhost '
            '(PC e Mac) e $mobileRedirectUri (telefono), non «Web» né «SPA».',
      '7000218' || '7000215' =>
        'L\'app è registrata come client riservato. In Autenticazione → '
            'Impostazioni avanzate attiva «Consenti flussi client pubblici» e usa '
            'la piattaforma «App per dispositivi mobili e desktop» (non «Web»).',
      '700016' =>
        'ID applicazione non trovato per questo tipo di account: prova con '
            'un account Microsoft personale (outlook/hotmail). Chi pubblica '
            'l\'app deve accettare in Entra → Manifesto sia gli account personali '
            'sia quelli di lavoro o scuola.',
      '50194' =>
        'L\'app è registrata per una sola organizzazione: chi pubblica l\'app '
            'deve renderla multi-tenant con gli account personali (Microsoft '
            'Entra → Autenticazione → Tipi di account supportati).',
      '50020' || '9002331' || '70000' =>
        'Questo account non è ammesso dalla registrazione dell\'app: prova con '
            'un altro account; chi pubblica l\'app deve accettare in Entra gli '
            '«Account Microsoft personali» e quelli di lavoro o scuola.',
      // l'app mostra la scheda «Il tuo ateneo deve approvare UniNotes»
      // (MicrosoftAdminConsent.isAdminConsentError)
      '65001' || '90094' || '90095' || '50105' =>
        'Il tuo ateneo deve approvare UniNotes: non permette agli studenti di '
            'collegare app esterne all\'account universitario. Usa un account '
            'Microsoft personale (OneDrive gratuito 5 GB) oppure chiedi '
            'all\'ateneo di approvare UniNotes.',
      '65004' =>
        'Autorizzazioni non concesse. Se le hai annullate tu, riprova e '
            'accettale; se Microsoft chiedeva l\'approvazione '
            'dell\'amministratore, il tuo ateneo deve approvare UniNotes.',
      '53003' || '530003' =>
        'Il criterio di accesso condizionale del tuo ateneo blocca questa app: '
            'usa un account Microsoft personale.',
      '9002313' || '900144' =>
        'Richiesta non valida: controlla che l\'ID applicazione sia completo '
            '(formato xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).',
      '700082' || '700084' =>
        'L\'accesso è scaduto (non usato da molto tempo): scollega e accedi di '
            'nuovo.',
      _ => null,
    };
    // il codice AADSTS ha la precedenza: «access_denied» accompagna anche il
    // rifiuto per mancanza del consenso dell'amministratore
    if (hint != null) {
      return '$hint\n(Dettaglio Microsoft: ${raw.split('\n').first.trim()})';
    }
    if (raw.contains('access_denied') || raw.contains('consent_required')) {
      return 'Accesso annullato o permessi non concessi: riprova e accetta le '
          'autorizzazioni richieste.';
    }
    return raw;
  }

  static const defaultScope =
      'offline_access User.Read Files.ReadWrite Notes.Read';

  /// Calendario Outlook (Impostazioni → Calendario, solo su Windows):
  /// chiesto con il consenso dinamico solo quando lo studente attiva il
  /// calendario, con un token separato da quello di OneDrive. Va aggiunto
  /// alle autorizzazioni API della registrazione in Entra
  /// (`Calendars.ReadWrite`, delegata).
  static const calendarScope = 'offline_access User.Read Calendars.ReadWrite';
}
