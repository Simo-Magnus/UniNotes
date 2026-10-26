import 'dart:io';

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/services/loopback_oauth.dart';
import 'microsoft_oauth.dart' show OAuthRedirectMode, WebAuthenticator;

export '../../core/services/loopback_oauth.dart'
    show OAuthTokens, OAuthException;

Future<String> _flutterWebAuth(Uri url, String scheme) =>
    FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: scheme,
      options: const FlutterWebAuth2Options(preferEphemeral: false),
    );

/// Accesso con l'account Google per Google Drive con lo scope `drive.file`:
/// l'app vede solo i file e le cartelle che ha creato lei (la cartella
/// UniNotes e il suo contenuto, da tutti i dispositivi) e quelli che lo
/// studente sceglie con «Importa da Drive» (Google Picker). Non è uno scope
/// con restrizioni: niente verifica di sicurezza a pagamento.
///
/// **Registrazione in Google Cloud** (una sola volta, a cura di chi pubblica
/// l'app; dettagli in `docs/google_drive_setup.md`):
/// 1. progetto → API e servizi → abilita «Google Drive API» e «Google Picker
///    API»;
/// 2. schermata di consenso OAuth: tipo «Esterno», scope `drive.file`, stato
///    «In produzione» (in «Test» i token scadono dopo 7 giorni);
/// 3. credenziali → ID client OAuth tipo «App desktop» (PC e Mac, ritorno su
///    `http://127.0.0.1:<porta>`), più «iOS» e «Android» per i telefoni, e una
///    chiave API (solo Google Picker API, solo dal sito del progetto).
///
/// Gli ID entrano nella build con `--dart-define`: `GOOGLE_CLIENT_ID` e
/// `GOOGLE_CLIENT_SECRET` (client desktop: Google lo chiama segreto ma per le
/// app installate non lo è, la sicurezza viene da PKCE), `GOOGLE_IOS_CLIENT_ID`,
/// `GOOGLE_ANDROID_CLIENT_ID`; per il Picker `GOOGLE_PICKER_API_KEY` e
/// `GOOGLE_CLOUD_PROJECT_NUMBER` (vedi drive_picker.dart).
class GoogleOAuth extends LoopbackOAuth {
  GoogleOAuth({
    required super.clientId,
    required super.openBrowser,
    super.clientSecret,
    super.httpClient,
    this.mode = OAuthRedirectMode.loopback,
    WebAuthenticator? webAuthenticator,
  }) : _webAuth = webAuthenticator ?? _flutterWebAuth,
       super(
         providerName: 'Google',
         authEndpoint: Uri.https('accounts.google.com', '/o/oauth2/v2/auth'),
         tokenEndpoint: Uri.https('oauth2.googleapis.com', '/token'),
         scope: defaultScope,
         // refresh token sempre restituito, scelta dell'account
         extraAuthParams: const {
           'access_type': 'offline',
           'prompt': 'consent select_account',
         },
         explainError: explain,
       );

  final OAuthRedirectMode mode;
  final WebAuthenticator _webAuth;

  /// Revoca di un token (alla disconnessione, [GoogleDriveService.revoke]).
  static final revokeEndpoint = Uri.https('oauth2.googleapis.com', '/revoke');

  /// Pagina dell'account dove togliere l'accesso a mano.
  static const permissionsPage = 'https://myaccount.google.com/permissions';

  /// Solo i file creati dall'app o scelti dallo studente (non `drive`, che è
  /// uno scope con restrizioni).
  static const defaultScope = 'https://www.googleapis.com/auth/drive.file';

  static const desktopClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const desktopClientSecret = String.fromEnvironment(
    'GOOGLE_CLIENT_SECRET',
  );
  static const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static const androidClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_CLIENT_ID',
  );

  /// ID del client per questa piattaforma (vuoto = non incluso nella build).
  static String get builtInClientId {
    if (Platform.isIOS) return iosClientId;
    if (Platform.isAndroid) return androidClientId;
    return desktopClientId;
  }

  /// Schema di ritorno dei client iOS/Android: l'ID al contrario
  /// (`com.googleusercontent.apps.<numero>`), da registrare nell'Info.plist e
  /// nell'AndroidManifest.
  static String reverseScheme(String clientId) {
    const suffix = '.apps.googleusercontent.com';
    final head = clientId.endsWith(suffix)
        ? clientId.substring(0, clientId.length - suffix.length)
        : clientId;
    return 'com.googleusercontent.apps.$head';
  }

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
    final scheme = reverseScheme(clientId);
    final redirect = '$scheme:/oauth2redirect';
    final verifier = LoopbackOAuth.randomToken(48);
    final state = LoopbackOAuth.randomToken(16);
    final url = authorizeUrl(
      redirect: redirect,
      verifier: verifier,
      state: state,
      loginHint: loginHint,
    );
    final String result;
    try {
      result = await _webAuth(url, scheme);
    } on OAuthException {
      rethrow;
    } catch (e) {
      final text = '$e';
      if (text.contains('CANCELED') || text.contains('canceled')) {
        throw OAuthException('Accesso con Google annullato.');
      }
      throw OAuthException('Accesso con Google non riuscito: $text');
    }
    final q = Uri.parse(result).queryParameters;
    final code = q['code'];
    if (q['state'] != state) {
      // ritorno che non viene dalla pagina di accesso aperta dall'app (un'altra
      // app può aprire lo schema): niente codice né testo preso da lì
      throw OAuthException(foreignReturnMessage('Google'));
    }
    if (code == null) {
      throw OAuthException(
        'Accesso con Google non riuscito: '
        '${explain(q['error_description'] ?? q['error'] ?? 'risposta non valida')}',
      );
    }
    return exchangeCode(code, redirect: redirect, verifier: verifier);
  }

  /// Errori di Google → causa e rimedio in italiano.
  static String explain(String raw) {
    final r = raw.toLowerCase();
    final hint = switch (r) {
      _ when r.contains('redirect_uri_mismatch') =>
        'L\'indirizzo di ritorno non corrisponde: per PC e Mac l\'ID client '
            'deve essere di tipo «App desktop» (non «Applicazione web»).',
      _
          when r.contains('invalid_client') ||
              r.contains('unauthorized_client') =>
        'ID client o segreto non validi: controlla GOOGLE_CLIENT_ID e '
            'GOOGLE_CLIENT_SECRET della build (docs/google_drive_setup.md).',
      _ when r.contains('org_internal') =>
        'La registrazione dell\'app accetta solo gli account della sua '
            'organizzazione: nella schermata di consenso scegli «Esterno».',
      _ when r.contains('invalid_grant') =>
        'L\'accesso è scaduto o è stato revocato: scollega e accedi di nuovo.',
      _ when r.contains('access_denied') =>
        'Accesso annullato o permessi non concessi: riprova e accetta '
            'l\'accesso ai file di Google Drive usati da UniNotes.',
      _ when r.contains('admin_policy_enforced') =>
        'Il tuo ateneo non consente questa app con l\'account istituzionale: '
            'usa un account Google personale.',
      _ => null,
    };
    if (hint == null) return raw;
    return '$hint\n(Dettaglio Google: ${raw.split('\n').first.trim()})';
  }
}
