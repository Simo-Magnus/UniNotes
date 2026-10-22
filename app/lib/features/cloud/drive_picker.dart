import 'dart:async';
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

  /// Messaggio quando la chiave API o il numero del progetto non sono
  /// inclusi nella build (cosa deve fare chi pubblica l'app: vedi
  /// docs/google_drive_setup.md).
  static const missingKeyMessage =
      '«Importa da Drive» usa il selettore di Google Drive, che ha bisogno '
      'di una chiave API di Google inclusa nell\'app: questa versione non ce '
      'l\'ha, quindi il selettore non si può aprire. Non devi fare nulla tu: '
      'arriverà con un aggiornamento. Intanto puoi scegliere i file dal '
      'dispositivo (anche dalla cartella di Google Drive, se usi Drive per '
      'desktop o l\'app Drive) oppure condividerli con UniNotes dall\'app '
      'Drive.';

  /// Spiegazione di un errore del selettore (chiave non valida, Google
  /// non raggiungibile, nessuna risposta).
  static String explain(String error) {
    final e = error.toLowerCase();
    if (e.contains('chiave') || e.contains('api key') || e.contains('developer key')) {
      return 'Il selettore di Google Drive ha rifiutato la chiave API '
          'dell\'app (non valida o non autorizzata per questo sito). È un '
          'problema della versione dell\'app, non del tuo account: scegli '
          'intanto i file dal dispositivo.';
    }
    if (e.contains('raggiungibile')) {
      return 'Google non è raggiungibile: controlla la connessione e riprova.';
    }
    if (e.contains('tempo') || e.contains('risposto')) {
      return 'Il selettore di Google Drive non ha risposto: se la pagina nel '
          'browser mostra un errore, chiudila e riprova; altrimenti scegli i '
          'file dal dispositivo.';
    }
    return 'Il selettore di Google Drive non ha funzionato ($error).';
  }

  /// Apre il Picker e restituisce gli id scelti. Si ferma (con un errore,
  /// mai un'attesa infinita) dopo [timeout] senza risposta o quando
  /// [cancel] si completa (pulsante «Annulla» dell'app).
  Future<PickerResult> pick(
    String token, {
    Duration timeout = const Duration(minutes: 5),
    Future<void>? cancel,
  }) async {
    if (!available) return const PickerResult(error: 'chiave API mancante');
    // a fine attesa (risposta, «Annulla», tempo scaduto) il server locale si
    // chiude: niente porte aperte né attese rimaste in sospeso
    final stop = Completer<void>();
    Future<PickerResult> guarded(Future<PickerResult> f) {
      final c = Completer<PickerResult>();
      c.future.whenComplete(() {
        if (!stop.isCompleted) stop.complete();
      }).ignore();
      f.then((r) {
        if (!c.isCompleted) c.complete(r);
      }, onError: (Object e) {
        if (!c.isCompleted) c.complete(PickerResult(error: '$e'));
      });
      cancel?.then((_) {
        if (!c.isCompleted) c.complete(const PickerResult(cancelled: true));
      });
      final timer = Timer(timeout, () {
        if (!c.isCompleted) {
          c.complete(
            const PickerResult(
              error: 'nessuna risposta dal selettore entro il tempo previsto',
            ),
          );
        }
      });
      c.future.whenComplete(timer.cancel).ignore();
      return c.future;
    }

    return guarded(_pick(token, stop.future));
  }

  Future<PickerResult> _pick(String token, Future<void> stop) async {
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
    stop.then((_) => server.close(force: true)).ignore();
    try {
      final url = pageUri(
        token: token,
        returnUrl: 'http://127.0.0.1:${server.port}/picker',
        state: state,
      );
      if (!await openBrowser(url)) {
        return const PickerResult(error: 'impossibile aprire il browser');
      }
      return await waitForReturn(server, state);
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
        returnToAppPage(ok: r.error == null, title: title, detail: r.error),
      );
      await req.response.close();
      unawaited(bringAppToFront());
      return r;
    }
    return const PickerResult(cancelled: true);
  }
}
