import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';

// Senza testWidgets: l'HttpClient vero (il binding dei widget lo sostituirebbe
// con uno finto che risponde sempre 400). Secondo giro della caccia ai crash,
// categoria «dati esterni letti in modo rigido»: query string del ritorno.
void main() {
  group('accesso OAuth sul server locale', () {
    test('una richiesta con byte non UTF-8 nella query si scarta e '
        'l\'accesso continua', () async {
      final tokens = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      tokens.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({'access_token': 'a', 'refresh_token': 'r'}),
        );
        await req.response.close();
      });
      addTearDown(() => tokens.close(force: true));
      String? firstStatus;
      final oauth = LoopbackOAuth(
        providerName: 'Google',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('http://127.0.0.1:${tokens.port}/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (url) async {
          final q = url.queryParameters;
          final back = Uri.parse(q['redirect_uri']!);
          // il «browser» lavora mentre signIn aspetta il ritorno
          unawaited(() async {
            // richiesta estranea con %FF nel codice (non è UTF-8 valido)
            final sock = await Socket.connect(back.host, back.port);
            sock.write(
              'GET /?code=%FF&state=${q['state']} HTTP/1.1\r\n'
              'Host: x\r\nConnection: close\r\n\r\n',
            );
            await sock.flush();
            firstStatus = (await utf8.decodeStream(sock)).split('\r\n').first;
            // poi il ritorno vero
            final c = HttpClient();
            final r = await (await c.getUrl(
              back.replace(
                queryParameters: {'code': 'c1', 'state': q['state']!},
              ),
            )).close();
            await r.drain<void>();
            c.close();
          }());
          return true;
        },
      );
      onBrowserReturn = () async {};
      addTearDown(() => onBrowserReturn = null);
      final t = await oauth.signIn(timeout: const Duration(seconds: 20));
      expect(t.refreshToken, 'r');
      expect(firstStatus, contains('400'));
    });
  });
}
