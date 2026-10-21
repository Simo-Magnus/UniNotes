import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Token OAuth 2.0 (access token a breve scadenza + refresh token).
class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
  });
  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;

  bool get valid =>
      DateTime.now().isBefore(expiresAt.subtract(const Duration(minutes: 1)));
}

/// Errori di accesso che vogliono un nuovo collegamento (token scaduto o
/// revocato, consenso tolto, password cambiata): `invalid_grant` di Google,
/// AADSTS700082/700084 (scaduto), 50173 (password cambiata), 65001
/// (consenso), `interaction_required`.
bool isExpiredGrant(String error) {
  final e = error.toLowerCase();
  return e.contains('invalid_grant') ||
      e.contains('expired or revoked') ||
      e.contains('interaction_required') ||
      e.contains('consent_required') ||
      RegExp(r'aadsts(700082|700084|50173|65001|50076|50078|54005)')
          .hasMatch(e);
}

/// Schema con cui il browser riapre l'app dopo un accesso (registrato
/// dall'app: Windows al primo avvio e dall'installatore, macOS e iOS
/// nell'Info.plist, Microsoft Store nel manifest).
const kAppReturnUrl = 'uninotes://auth';

/// Chiamata quando il browser torna sul server locale: porta la finestra
/// dell'app in primo piano (impostata all'avvio su PC e Mac, vedi
/// `app_return.dart`; null nei test).
Future<void> Function()? onBrowserReturn;

/// Porta l'app in primo piano con [onBrowserReturn] (errori ignorati).
Future<void> bringAppToFront() async {
  try {
    await onBrowserReturn?.call();
  } catch (_) {
    // finestra non disponibile: l'esito si vede comunque tornando all'app
  }
}

/// Pagina che il browser mostra dopo l'accesso o la scelta dei file: apre
/// subito l'app con [kAppReturnUrl] (il browser può chiedere conferma:
/// «Apri UniNotes»), prova a chiudere la scheda e, se il browser non lo
/// permette, resta una pagina minima con il pulsante «Apri UniNotes».
/// L'esito (riuscito o no, con la causa) lo mostra l'app.
String returnToAppPage({
  required bool ok,
  required String title,
  String? detail,
}) {
  const esc = HtmlEscape();
  final link = '$kAppReturnUrl?esito=${ok ? 'ok' : 'errore'}';
  return '<!doctype html><html lang="it"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>UniNotes</title><style>'
      ':root{color-scheme:light dark}'
      'body{margin:0;min-height:100vh;display:flex;align-items:center;'
      'justify-content:center;font-family:"IBM Plex Sans",system-ui,'
      'sans-serif;background:#0b1220;color:#e6edf7}'
      '@media (prefers-color-scheme:light){body{background:#f4f7fb;'
      'color:#0b1a2e}}'
      'main{max-width:420px;padding:32px 24px;text-align:center}'
      'h1{font-size:22px;margin:0 0 12px}p{margin:0 0 20px;opacity:.8;'
      'line-height:1.45}'
      'a{display:inline-block;padding:12px 22px;border-radius:12px;'
      'background:#ff8a3d;color:#1a0d00;font-weight:600;'
      'text-decoration:none}'
      '</style></head><body><main>'
      '<h1>${esc.convert(title)}</h1>'
      '${detail == null || detail.isEmpty ? '' : '<p>${esc.convert(detail)}</p>'}'
      '<p>${ok ? 'Fatto: UniNotes mostra l\'esito.' : 'UniNotes mostra cosa fare.'}'
      ' Se il browser chiede di aprire UniNotes, scegli «Apri».</p>'
      '<a id="app" href="$link">Apri UniNotes</a>'
      '</main><script>'
      'setTimeout(function(){location.href="$link"},150);'
      'setTimeout(function(){window.close()},1500);'
      '</script></body></html>';
}

class OAuthException implements Exception {
  OAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Accesso OAuth 2.0 per app installate: pagina di login del provider nel
/// browser, ritorno su un server locale (loopback) e PKCE. L'app non vede mai
/// la password; salva solo il refresh token (nel portachiavi del sistema).
///
/// Vale per Google (Gmail) e Microsoft (OneDrive/OneNote): cambiano solo gli
/// endpoint, gli scope e il nome mostrato negli errori.
class LoopbackOAuth {
  LoopbackOAuth({
    required this.providerName,
    required this.authEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    required this.scope,
    this.clientSecret,
    this.redirectHost = '127.0.0.1',
    this.extraAuthParams = const {},
    this.scopeOnRefresh = false,
    required this.openBrowser,
    this.explainError,
    HttpClient Function()? httpClient,
  }) : _httpClient = httpClient ?? HttpClient.new;

  /// Traduce l'errore grezzo del provider (es. «AADSTS50011: …») in una
  /// spiegazione con i passi per risolverlo.
  final String Function(String raw)? explainError;

  String _explain(String raw) => explainError?.call(raw) ?? raw;

  /// Spiegazione leggibile di un errore del provider.
  String describeError(String raw) => _explain(raw);

  /// Nome del provider nei messaggi («Google», «Microsoft»).
  final String providerName;
  final Uri authEndpoint;
  final Uri tokenEndpoint;
  final String clientId;
  final String scope;

  /// Solo per i client che lo richiedono (Google «App desktop»); i client
  /// pubblici Microsoft non hanno secret.
  final String? clientSecret;

  /// Host del redirect: Microsoft accetta `localhost` con qualsiasi porta.
  final String redirectHost;
  final Map<String, String> extraAuthParams;

  /// Microsoft vuole gli scope anche nel rinnovo del token.
  final bool scopeOnRefresh;
  final Future<bool> Function(Uri url) openBrowser;
  final HttpClient Function() _httpClient;

  static String randomToken(int bytes) => _random(bytes);

  static String _random(int bytes) {
    final r = Random.secure();
    return base64UrlEncode(List.generate(bytes, (_) => r.nextInt(256)))
        .replaceAll('=', '');
  }

  static String challengeFor(String verifier) =>
      base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');

  /// Apre il browser sulla pagina del provider e attende il ritorno.
  Future<OAuthTokens> signIn({
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // «localhost» può diventare ::1 (IPv6) nel browser: si ascolta anche
    // lì, sulla stessa porta, altrimenti il ritorno dal login fallisce.
    HttpServer? server6;
    if (redirectHost == 'localhost') {
      try {
        server6 = await HttpServer.bind(
          InternetAddress.loopbackIPv6,
          server.port,
          v6Only: true,
        );
      } on SocketException {
        server6 = null;
      }
    }
    final requests = StreamController<HttpRequest>();
    var open = server6 == null ? 1 : 2;
    for (final srv in [server, ?server6]) {
      srv.listen(
        requests.add,
        onError: requests.addError,
        onDone: () {
          if (--open == 0) requests.close();
        },
      );
    }
    final redirect = 'http://$redirectHost:${server.port}';
    final verifier = _random(48);
    final state = _random(16);
    final url = authorizeUrl(
      redirect: redirect,
      verifier: verifier,
      state: state,
      loginHint: loginHint,
    );
    try {
      if (!await openBrowser(url)) {
        throw OAuthException('Impossibile aprire il browser.');
      }
      final code = await _waitForCode(requests.stream, state).timeout(
        timeout,
        onTimeout: () =>
            throw OAuthException('Accesso con $providerName non completato.'),
      );
      return await exchangeCode(code, redirect: redirect, verifier: verifier);
    } finally {
      await server.close(force: true);
      await server6?.close(force: true);
    }
  }

  /// Pagina di accesso del provider con PKCE (S256).
  Uri authorizeUrl({
    required String redirect,
    required String verifier,
    required String state,
    String? loginHint,
  }) => authEndpoint.replace(
    queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scope,
      'code_challenge': challengeFor(verifier),
      'code_challenge_method': 'S256',
      'state': state,
      ...extraAuthParams,
      if (loginHint != null && loginHint.isNotEmpty) 'login_hint': loginHint,
    },
  );

  /// Codice di autorizzazione → token.
  Future<OAuthTokens> exchangeCode(
    String code, {
    required String redirect,
    required String verifier,
  }) => _token({
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': redirect,
    'code_verifier': verifier,
  });

  Future<String> _waitForCode(Stream<HttpRequest> server, String state) async {
    await for (final req in server) {
      final q = req.uri.queryParameters;
      if (!q.containsKey('code') && !q.containsKey('error')) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        continue;
      }
      if (q['state'] != state) {
        // richiesta estranea (altra scheda, altro programma): si ignora e si
        // continua ad aspettare il ritorno giusto
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        continue;
      }
      final ok = q['code'] != null;
      final why = ok
          ? ''
          : _explain(
              q['error_description'] ?? q['error'] ?? 'risposta non valida',
            );
      req.response.headers.contentType = ContentType.html;
      req.response.headers.set('Cache-Control', 'no-store');
      req.response.write(
        returnToAppPage(
          ok: ok,
          title: ok
              ? 'Torna a UniNotes'
              : 'Accesso con $providerName non riuscito',
          detail: ok ? null : why,
        ),
      );
      await req.response.close();
      // l'app torna in primo piano (PC e Mac) e mostra l'esito
      unawaited(bringAppToFront());
      if (!ok) {
        throw OAuthException('Accesso con $providerName non riuscito: $why');
      }
      return q['code']!;
    }
    throw OAuthException('Accesso con $providerName interrotto.');
  }

  /// Nuovo access token dal refresh token salvato.
  Future<OAuthTokens> refresh(String refreshToken) async {
    final t = await _token({
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      if (scopeOnRefresh) 'scope': scope,
    });
    return OAuthTokens(
      accessToken: t.accessToken,
      expiresAt: t.expiresAt,
      refreshToken: t.refreshToken ?? refreshToken,
    );
  }

  Future<OAuthTokens> _token(Map<String, String> params) async {
    final client = _httpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client
          .postUrl(tokenEndpoint)
          .timeout(const Duration(seconds: 30));
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.write(
        Uri(
          queryParameters: {
            ...params,
            'client_id': clientId,
            if (clientSecret != null && clientSecret!.isNotEmpty)
              'client_secret': clientSecret!,
          },
        ).query,
      );
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      Map<String, Object?> json;
      try {
        json = (jsonDecode(body) as Map).cast<String, Object?>();
      } on FormatException {
        json = const {};
      }
      if (res.statusCode != 200 || json['access_token'] == null) {
        final err = json['error_description'] ?? json['error'] ?? body;
        throw OAuthException(
          '$providerName ha rifiutato l\'accesso: ${_explain('$err')}',
        );
      }
      return OAuthTokens(
        accessToken: json['access_token'] as String,
        expiresAt: DateTime.now().add(
          Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
        ),
        refreshToken: json['refresh_token'] as String?,
      );
    } on SocketException catch (e) {
      throw OAuthException('$providerName non raggiungibile (${e.message}).');
    } on TimeoutException {
      throw OAuthException('$providerName non risponde: riprova più tardi.');
    } finally {
      client.close();
    }
  }
}
