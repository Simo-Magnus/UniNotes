import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/cloud/microsoft_admin_consent.dart';
import 'package:university_notes/features/cloud/microsoft_oauth.dart';
import 'package:university_notes/features/links/microsoft_consent_sheet.dart';

const _id = '24f57293-12b8-4d3d-b33f-f55effdaa44f';

void main() {
  group('errori di consenso dell\'amministratore', () {
    test('codici AADSTS del blocco dell\'ateneo', () {
      for (final c in ['65001', '65004', '90094', '90095', '50105']) {
        expect(
          MicrosoftAdminConsent.isAdminConsentError('AADSTS$c: qualcosa'),
          isTrue,
          reason: c,
        );
      }
      for (final c in ['50011', '7000218', '700016', '53003', '700082']) {
        expect(
          MicrosoftAdminConsent.isAdminConsentError('AADSTS$c: qualcosa'),
          isFalse,
          reason: c,
        );
      }
    });

    test('testi di Microsoft in inglese e in italiano', () {
      for (final t in [
        'Need admin approval',
        'UniNotes needs permission to access resources in your '
            'organization that only an admin can grant.',
        'Richiede l\'approvazione dell\'amministratore',
        'Richiede l’approvazione dell’amministratore',
      ]) {
        expect(MicrosoftAdminConsent.isAdminConsentError(t), isTrue, reason: t);
      }
      for (final t in [
        null,
        '',
        'access_denied',
        'Accesso con Microsoft annullato.',
        'Microsoft non raggiungibile (rete).',
      ]) {
        expect(
          MicrosoftAdminConsent.isAdminConsentError(t),
          isFalse,
          reason: '$t',
        );
      }
    });

    test('riconosciuto anche dopo la spiegazione dell\'app', () {
      final e = OAuthException(
        'Accesso con Microsoft non riuscito: '
        '${MicrosoftOAuth.explain('AADSTS90094: The grant requires admin permission.')}',
      );
      expect(MicrosoftAdminConsent.isAdminConsentError(e), isTrue);
      expect(e.message, contains('deve approvare UniNotes'));
      expect(e.message, contains('AADSTS90094'));
      // «access_denied» con il codice: vince il codice
      final denied = MicrosoftOAuth.explain(
        'access_denied: AADSTS65001: The user or administrator has not '
        'consented to use the application',
      );
      expect(MicrosoftAdminConsent.isAdminConsentError(denied), isTrue);
      // le altre spiegazioni non aprono la scheda
      for (final c in ['50011', '7000218', '700016', '50020', '53003']) {
        expect(
          MicrosoftAdminConsent.isAdminConsentError(
            MicrosoftOAuth.explain('AADSTS$c: x'),
          ),
          isFalse,
          reason: c,
        );
      }
      expect(
        MicrosoftAdminConsent.isAdminConsentError(
          MicrosoftOAuth.explain('access_denied'),
        ),
        isFalse,
      );
    });

    test('65004: consenso rifiutato, forse dallo studente', () {
      expect(MicrosoftAdminConsent.isDeclined('AADSTS65004: declined'), isTrue);
      expect(MicrosoftAdminConsent.isDeclined('AADSTS90094: admin'), isFalse);
      expect(MicrosoftAdminConsent.isDeclined(null), isFalse);
    });
  });

  group('richiesta all\'ateneo', () {
    test('link di consenso amministratore per tutti i tenant', () {
      final u = MicrosoftAdminConsent.consentUrl(_id)!;
      expect(u.host, 'login.microsoftonline.com');
      expect(u.path, '/organizations/v2.0/adminconsent');
      expect(u.queryParameters['client_id'], _id);
      expect(
        u.queryParameters['redirect_uri'],
        MicrosoftAdminConsent.adminPageUrl,
      );
      final scope = u.queryParameters['scope']!.split(' ');
      expect(scope, contains('https://graph.microsoft.com/Files.ReadWrite'));
      expect(scope, contains('https://graph.microsoft.com/Notes.Read'));
      expect(scope, contains('https://graph.microsoft.com/User.Read'));
      expect(
        scope,
        contains('https://graph.microsoft.com/Calendars.ReadWrite'),
      );
      expect(scope, contains('offline_access'));
    });

    test('la pagina per gli amministratori usa lo stesso link', () {
      final html = File('../sito/amministratori.html').readAsStringSync();
      final href = RegExp(r'id="consenso" href="([^"]+)"').firstMatch(html)!;
      final page = Uri.parse(
        href[1]!.replaceAll('&amp;', '&').replaceAll('__MS_CLIENT_ID__', _id),
      );
      final app = MicrosoftAdminConsent.consentUrl(_id)!;
      expect(page.origin, app.origin);
      expect(page.path, app.path);
      expect(page.queryParameters, app.queryParameters);
      // il workflow sostituisce il segnaposto (.github/workflows/pagina.yml)
      expect(html, contains('<code id="app-id">__MS_CLIENT_ID__</code>'));
    });

    test('testo con nome, ID, permessi, dati e link', () {
      final t = MicrosoftAdminConsent.requestText(clientId: _id);
      expect(t, contains('UniNotes'));
      expect(t, contains('ID applicazione (client): $_id'));
      for (final p in MicrosoftAdminConsent.permissions) {
        expect(t, contains('- ${p.scope}: ${p.reason}'));
      }
      expect(
        t,
        contains(
          'I dati restano sul dispositivo e nell\'account dello studente, '
          'nessun server di UniNotes',
        ),
      );
      expect(t, contains(MicrosoftAdminConsent.adminPageUrl));
      expect(t, contains(MicrosoftAdminConsent.consentUrl(_id).toString()));
      expect(t, isNot(contains('@')));
    });

    test('senza ID (MS_CLIENT_ID vuoto): niente ID né link rotti', () {
      for (final id in ['', '   ', 'non-un-guid', null]) {
        expect(MicrosoftAdminConsent.consentUrl(id), isNull, reason: '$id');
        final t = MicrosoftAdminConsent.requestText(clientId: id);
        expect(t, isNot(contains('ID applicazione')), reason: '$id');
        expect(t, isNot(contains('adminconsent')), reason: '$id');
        expect(t, isNot(contains('client_id')), reason: '$id');
        // la pagina per gli amministratori resta
        expect(t, contains(MicrosoftAdminConsent.adminPageUrl));
      }
    });

    test('account personale: tenant che li ammette', () {
      expect(MicrosoftAdminConsent.tenantForPersonal('common'), 'common');
      expect(MicrosoftAdminConsent.tenantForPersonal('consumers'), 'consumers');
      expect(
        MicrosoftAdminConsent.tenantForPersonal('organizations'),
        'common',
      );
      expect(
        MicrosoftAdminConsent.tenantForPersonal('studenti.ateneo.it'),
        'common',
      );
    });
  });

  group('schede', () {
    /// Apre la scheda; il risultato arriva in [results].
    Future<void> open(
      WidgetTester tester,
      String id, [
      List<bool>? results,
    ]) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () async {
                  final r = await showUniversityBlockedSheet(c, clientId: id);
                  results?.add(r);
                },
                child: const Text('apri'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('apri'));
      await tester.pumpAndSettle();
    }

    testWidgets('due azioni; la richiesta mostra testo, Copia e Condividi', (
      tester,
    ) async {
      await open(tester, _id);
      expect(
        find.text('Il tuo ateneo deve approvare UniNotes'),
        findsOneWidget,
      );
      expect(find.text('Usa un account Microsoft personale'), findsOneWidget);
      expect(find.text(kPersonalAccountHint), findsOneWidget);
      await tester.tap(find.byKey(const Key('consent-ask')));
      await tester.pumpAndSettle();
      expect(find.text('Copia'), findsOneWidget);
      expect(find.text('Condividi'), findsOneWidget);
      expect(find.textContaining('Richiedi approvazione'), findsOneWidget);
      final text = tester
          .widget<SelectableText>(find.byKey(const Key('consent-request-text')))
          .data!;
      expect(text, contains(_id));
      expect(text, contains('adminconsent'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('senza ID: nessun link di consenso nel testo', (tester) async {
      await open(tester, '');
      await tester.tap(find.byKey(const Key('consent-ask')));
      await tester.pumpAndSettle();
      final text = tester
          .widget<SelectableText>(find.byKey(const Key('consent-request-text')))
          .data!;
      expect(text, isNot(contains('adminconsent')));
      expect(text, contains(MicrosoftAdminConsent.adminPageUrl));
    });

    testWidgets('«Usa un account Microsoft personale» → riprova', (
      tester,
    ) async {
      final results = <bool>[];
      await open(tester, _id, results);
      await tester.tap(find.byKey(const Key('consent-personal')));
      await tester.pumpAndSettle();
      expect(results, [true]);
    });
  });
}
