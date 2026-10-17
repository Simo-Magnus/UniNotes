import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/constants/build_flags.dart';
import '../../core/services/loopback_oauth.dart';
import 'google_oauth.dart' show GoogleOAuth;

/// Risposta della pagina del Picker: file scelti, annullato o errore.
class PickerResult {
  const PickerResult({
    this.ids = const [],
    this.cancelled = false,
    this.error,
  });
  final List<String> ids;
  final bool cancelled;
  final String? error;

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,200}$');

  /// Indirizzo di ritorno della pagina (`…/picker?state=…&ids=a,b`).
  /// Uno [state] diverso da quello atteso è una risposta estranea: errore.
  /// Gli id non validi si scartano, i doppioni pure.
  static PickerResult parse(Uri uri, String state) {
    final q = uri.queryParameters;
    if (q['state'] != state) {
      return const PickerResult(error: 'risposta non valida');
    }
    if (q['error'] case final e? when e.trim().isNotEmpty) {
      return PickerResult(error: e.trim());
    }
    if (q['cancel'] == '1') return const PickerResult(cancelled: true);
    final ids = <String>[];
    for (final raw in (q['ids'] ?? '').split(',')) {
      final id = raw.trim();
      if (_id.hasMatch(id) && !ids.contains(id)) ids.add(id);
    }
    return ids.isEmpty
        ? const PickerResult(cancelled: true)
        : PickerResult(ids: ids);
  }
}

/// «Importa da Drive»: il Google Picker (esiste solo come API web) in una
/// pagina statica del sito del progetto (`sito/drive-picker.html`, GitHub
/// Pages), aperta nel browser. La pagina riceve nel frammento dell'indirizzo
/// (`#…`, che il browser non manda a nessun server) il token di accesso
/// dell'app, la chiave API e il numero del progetto; lo studente sceglie i
/// file e la pagina torna all'app con i soli id:
/// - PC e Mac: `http://127.0.0.1:<porta>/picker` (server locale, come
///   l'accesso);
/// - telefono: lo schema del client Google (`com.googleusercontent.apps.…:
///   /picker`), già registrato per l'accesso.
/// Con `drive.file` i file scelti diventano accessibili all'app.
class DrivePicker {
  DrivePicker({
    required this.openBrowser,
    this.apiKey = defaultApiKey,
    this.projectNumber = defaultProjectNumber,
    this.pageUrl = defaultPageUrl,
    this.mobileClientId,
    Future<String> Function(Uri url, String scheme)? webAuth,
  }) : _webAuth = webAuth ?? _flutterWebAuth;

  /// Chiave API con restrizioni (solo Google Picker API, solo dal sito).
  static const defaultApiKey = String.fromEnvironment('GOOGLE_PICKER_API_KEY');

  /// Numero del progetto Google Cloud (App ID del Picker).
  static const defaultProjectNumber = String.fromEnvironment(
    'GOOGLE_CLOUD_PROJECT_NUMBER',
  );

  static const defaultPageUrl = String.fromEnvironment(
    'GOOGLE_PICKER_URL',
    defaultValue: '${kProjectUrl}drive-picker.html',
  );

  final String apiKey;
  final String projectNumber;
  final String pageUrl;

  /// ID del client iOS/Android (schema di ritorno); null sul PC.
  final String? mobileClientId;
  final Future<bool> Function(Uri url) openBrowser;
  final Future<String> Function(Uri url, String scheme) _webAuth;

  /// Chiave e numero del progetto inclusi nella build.
  bool get available =>
      apiKey.trim().isNotEmpty && projectNumber.trim().isNotEmpty;

  static Future<String> _flutterWebAuth(Uri url, String scheme) =>
      FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: scheme,
        options: const FlutterWebAuth2Options(preferEphemeral: false),
      );

  /// Indirizzo della pagina con i parametri nel frammento.
  Uri pageUri({
    required String token,
    required String returnUrl,
    required String state,
  }) => Uri.parse(pageUrl).replace(
    fragment: Uri(
      queryParameters: {
        'token': token,
        'key': apiKey,
        'app': projectNumber,
        'ret': returnUrl,
        'state': state,
      },
    ).query,
  );

  /// Apre il Picker e restituisce gli id scelti.
  Future<PickerResult> pick(
    String token, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final state = LoopbackOAuth.randomToken(16);
    final client = mobileClientId;
    if (client != null && client.isNotEmpty) {
      final scheme = GoogleOAuth.reverseScheme(client);
      final url = pageUri(
        token: token,
        returnUrl: '$scheme:/picker',
        state: state,
      );
      try {
        return PickerResult.parse(Uri.parse(await _webAuth(url, scheme)), state);
      } catch (e) {
        final text = '$e';
        if (text.contains('CANCELED') || text.contains('canceled')) {
          return const PickerResult(cancelled: true);
        }
        return PickerResult(error: text);
      }
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final url = pageUri(
        token: token,
        returnUrl: 'http://127.0.0.1:${server.port}/picker',
        state: state,
      );
      if (!await openBrowser(url)) {
        return const PickerResult(error: 'impossibile aprire il browser');
      }
      return await waitForReturn(server, state).timeout(
        timeout,
        onTimeout: () => const PickerResult(cancelled: true),
      );
    } finally {
      await server.close(force: true);
    }
  }

  /// Attende sul server locale il ritorno della pagina con lo [state] giusto
  /// (le altre richieste si ignorano).
  static Future<PickerResult> waitForReturn(
    Stream<HttpRequest> server,
    String state,
  ) async {
    await for (final req in server) {
      if (req.uri.path != '/picker' || req.uri.queryParameters['state'] != state) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        continue;
      }
      final r = PickerResult.parse(req.uri, state);
      req.response.headers.contentType = ContentType.html;
      final title = r.error != null
          ? 'Importazione non riuscita'
          : (r.cancelled ? 'Nessun file scelto' : 'File scelti');
      req.response.write(
        '<!doctype html><meta charset="utf-8"><title>UniNotes</title>'
        '<body style="font-family:sans-serif;padding:40px;max-width:720px">'
        '<h2>${const HtmlEscape().convert(title)}</h2>'
        '<p>Puoi chiudere questa finestra e tornare all\'app.</p></body>',
      );
      await req.response.close();
      return r;
    }
    return const PickerResult(cancelled: true);
  }
}
