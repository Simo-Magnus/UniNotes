import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_return.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/links/link_status.dart';
import 'package:university_notes/features/links/onedrive_card.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Accesso finto che fallisce la prima volta con [error].
class _OAuth extends LoopbackOAuth {
  _OAuth(this.error)
    : super(
        providerName: 'Microsoft',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('https://login.example/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );
  final Object error;
  int failures = 1;

  @override
  Future<OAuthTokens> signIn({
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (failures-- > 0) throw error;
    return OAuthTokens(
      accessToken: 'a',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'r',
    );
  }

  @override
  Future<OAuthTokens> refresh(String refreshToken) => signIn();
}

Future<void> _settle(WidgetTester tester, [int rounds = 60]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

void main() {
  group('cause degli errori di accesso', () {
    test('rete, annullato, tempo scaduto, ateneo, generico', () {
      expect(
        describeSignInError(const SocketException('x'), 'OneDrive').phase,
        LinkPhase.offline,
      );
      expect(
        describeSignInError(
          OAuthException('Microsoft non raggiungibile (rete).'),
          'OneDrive',
        ).message,
        contains('Nessuna connessione'),
      );
      expect(
        describeSignInError(
          OAuthException('Accesso con Google annullato.'),
          'Google Drive',
        ).message,
        startsWith('Accesso annullato'),
      );
      expect(
        describeSignInError(
          OAuthException('Accesso con Microsoft non completato.'),
          'OneDrive',
        ).message,
        contains('entro 5 minuti'),
      );
      expect(
        describeSignInError(
          OAuthException('AADSTS65001: The user or administrator has not '
              'consented'),
          'OneDrive',
        ).phase,
        LinkPhase.adminConsent,
      );
      final other = describeSignInError(OAuthException('boh'), 'OneDrive');
      expect(other.phase, LinkPhase.error);
      expect(other.message, contains('Riprova'));
    });

    test('stati della card', () {
      LinkStatus s({
        bool connected = true,
        bool expired = false,
        String? last,
        String? error,
      }) => cloudStatus(
        service: 'OneDrive',
        available: true,
        connected: connected,
        expired: expired,
        account: 'Studente · s@outlook.it',
        lastLabel: last,
        lastError: error,
        offlineMessage: 'offline',
      );
      expect(s(connected: false).phase, LinkPhase.notConnected);
      expect(s().phase, LinkPhase.connected);
      expect(s(last: '21/10 10:00 · Tutto già sincronizzato').phase,
          LinkPhase.synced);
      expect(s(expired: true).message, contains('Accedi di nuovo'));
      expect(s(last: '21/10 10:00 · x', error: 'offline').message,
          contains('Ultima riuscita: 21/10 10:00'));
      expect(s(last: 'Errore: 500').message,
          contains('Sincronizzazione non riuscita: 500'));
      expect(
        cloudStatus(service: 'Google Drive', available: false, connected: false)
            .phase,
        LinkPhase.unavailable,
      );
    });
  });

  group('Windows: schema uninotes://', () {
    test('comandi di registrazione e lettura del programma registrato', () {
      final cmds = AppReturn.registerCommands(r'C:\App\uninotes.exe');
      expect(cmds.last, contains(r'"C:\App\uninotes.exe" "%1"'));
      expect(
        AppReturn.registeredExe(
          '    (Predefinito)    REG_SZ    "C:\\App\\uninotes.exe" "%1"',
        ),
        r'C:\App\uninotes.exe',
      );
      expect(AppReturn.registeredExe('ERRORE: chiave non trovata'), isNull);
    });
  });

  group('OneDrive: messaggi dell\'accesso', () {
    Future<(AppServices, Directory, _OAuth)> services(Object error) async {
      final db = await AppDatabase.openInMemory();
      final tmp = await Directory.systemTemp.createTemp('links_status_');
      final settings = SettingsRepository(db);
      final oauth = _OAuth(error);
      final od = OneDriveService(
        settings,
        NotesStore(settings, root: () async => tmp),
        secrets: MemoryCloudSecrets(),
        stateDir: () async => tmp,
        oauthFactory: (_, _) => oauth,
        transport: (m, u, {headers = const {}, body}) async {
          final path = u.path;
          final json = path.endsWith('/me')
              ? {'displayName': 'Studente', 'mail': 's@outlook.it'}
              : {'id': 'f', 'folder': {}};
          return GraphResponse(200, utf8.encode(jsonEncode(json)));
        },
      );
      return (AppServices(db, onedrive: od), tmp, oauth);
    }

    testWidgets('non riuscito: causa e «Riprova»; riuscito: messaggio e card '
        'aggiornata', (tester) async {
      // connettività finta (controlli automatici dopo l'accesso)
      const net = EventChannel('dev.fluttercommunity.plus/connectivity_status');
      tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        net,
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
          net,
          null,
        ),
      );
      final (s, tmp, _) = (await tester.runAsync(
        () => services(const SocketException('offline')),
      ))!;
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: OneDriveCard()),
            ),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('Accedi con Microsoft'));
      await _settle(tester);
      expect(find.text('Collegamento a OneDrive non riuscito'), findsOneWidget);
      expect(find.textContaining('Nessuna connessione'), findsOneWidget);
      await tester.tap(find.text('Riprova'));
      await _settle(tester, 120);
      expect(find.textContaining('OneDrive collegato come Studente'),
          findsOneWidget);
      expect(find.textContaining('Collegato (Studente · s@outlook.it)'),
          findsOneWidget);
      expect(find.text('Scollega'), findsOneWidget);
      // nei test non c'è il plugin della connettività (controlli automatici)
      final ex = tester.takeException();
      expect(ex == null || ex is MissingPluginException, isTrue);
      s.onedrive.stopAutoSync();
      await tester.runAsync(() async {
        await s.database.close();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
    });
  });
}
