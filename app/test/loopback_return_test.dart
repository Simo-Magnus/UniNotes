import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';

// Senza testWidgets: l'HttpClient vero (il binding dei widget lo
// sostituirebbe con uno finto che risponde sempre 400).
void main() {
  test('pagina di ritorno: apre l\'app, niente più «Puoi chiudere questa '
      'finestra»', () {
    final ok = returnToAppPage(ok: true, title: 'Torna a UniNotes');
    expect(ok, contains('Apri UniNotes'));
    expect(ok, contains('$kAppReturnUrl?esito=ok'));
    expect(ok, contains('window.close()'));
    expect(ok, isNot(contains('Puoi chiudere questa finestra')));
    final ko = returnToAppPage(
      ok: false,
      title: 'Accesso non riuscito',
      detail: '<script>x</script>',
    );
    expect(ko, contains('esito=errore'));
    expect(ko, isNot(contains('<script>x')));
    // errore: la scheda resta aperta con la causa (nessuna chiusura né
    // apertura automatica dell'app)
    expect(ko, isNot(contains('window.close()')));
    expect(ko, isNot(contains('location.href')));
    expect(ko, contains('Torna a UniNotes'));
    // riuscito: testo di riserva se il browser non chiude la scheda
    expect(ok, contains('puoi chiudere questa scheda'));
  });

  test('accesso vero sul server locale: pagina nuova e app in primo piano',
      () async {
    // server dei token finto
    final tokens = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    tokens.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600}),
      );
      await req.response.close();
    });
    var raised = 0;
    onBrowserReturn = () async => raised++;
    addTearDown(() async {
      onBrowserReturn = null;
      await tokens.close(force: true);
    });
    String? page;
    final oauth = LoopbackOAuth(
      providerName: 'Google',
      authEndpoint: Uri.parse('https://login.example/authorize'),
      tokenEndpoint: Uri.parse('http://127.0.0.1:${tokens.port}/token'),
      clientId: 'x',
      scope: 's',
      openBrowser: (url) async {
        // il «browser» torna sul server locale con codice e state
        final q = url.queryParameters;
        final back = Uri.parse(
          q['redirect_uri']!,
        ).replace(queryParameters: {'code': 'c1', 'state': q['state']!});
        () async {
          final c = HttpClient();
          final r = await (await c.getUrl(back)).close();
          page = await r.transform(utf8.decoder).join();
          c.close();
        }();
        return true;
      },
    );
    final t = await oauth.signIn(timeout: const Duration(seconds: 20));
    expect(t.refreshToken, 'r');
    for (var i = 0; i < 100 && page == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(page, contains('Apri UniNotes'));
    expect(page, isNot(contains('Puoi chiudere')));
    expect(raised, 1);
  });
}
