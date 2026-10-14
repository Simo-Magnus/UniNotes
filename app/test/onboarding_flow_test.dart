import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/exams/exam_form.dart'
    show kCalendarOfferedKey;
import 'package:university_notes/features/links/ai_assistants.dart';
import 'package:university_notes/features/links/link_settings.dart';
import 'package:university_notes/features/onboarding/onboarding_flow.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';
import 'support/fake_reminders.dart';

const _phone = Size(400, 800);
const _desktop = Size(1400, 900);

/// [remote]: database online (mappa modificabile dal test); di default
/// i corsi di PoliTO se [online], niente rete altrimenti.
Future<AppServices> _services({
  bool online = true,
  Map<String, String>? remote,
}) async {
  final db = await AppDatabase.openInMemory();
  // telefono Android finto: notifiche e calendario del dispositivo in memoria
  return AppServices(
    db,
    reminders: (s) => RemindersService(
      s,
      platform: FakeNotificationPlatform(),
      calendarBackend: FakeCalendarBackend(),
      widgets: FakeHomeWidgets(),
      platformName: 'android',
      isRecording: () => false,
      focusQuietUntil: () => null,
    ),
    catalog: fakeCatalog(
      SettingsRepository(db),
      remote:
          remote ??
          (online
              ? {'corsi/polito.json': jsonEncode(corsiPolitoFixture())}
              : const {}),
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}

/// Come [_settle] finché compare [f] (download e import fanno molti accessi
/// al disco: il numero di giri necessari varia).
Future<void> _settleUntil(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 150 && f.evaluate().isEmpty; i++) {
    await _settle(tester, 1);
  }
  await _settle(tester, 2);
}

Future<(AppServices, List<bool>)> _start(
  WidgetTester tester,
  Size size, {
  bool online = true,
  Map<String, String>? remote,
  bool changing = false,
  bool skipAppearance = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final s = (await tester.runAsync(
    () => _services(online: online, remote: remote),
  ))!;
  addTearDown(() => tester.runAsync(s.database.close));
  final finished = <bool>[];
  await tester.pumpWidget(
    Provider.value(
      value: s,
      child: MaterialApp(
        home: OnboardingFlow(
          canCancel: changing,
          onFinished: () => finished.add(true),
        ),
      ),
    ),
  );
  await _settle(tester);
  // primo passo del primo avvio: contrasto e grandezza del testo
  if (!changing && skipAppearance) {
    await _tap(tester, find.byKey(const Key('onboarding-appearance-next')));
  }
  return (s, finished);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  // passi lunghi su telefono: si scorre fino al pulsante
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await _settle(tester, 2);
}

Future<void> _fullFlow(WidgetTester tester, Size size) async {
  final (s, finished) = await _start(tester, size, skipAppearance: false);
  // 1. aspetto, prima della ricerca dell'ateneo
  expect(find.text('Come preferisci leggere?'), findsOneWidget);
  // aspetto, 7 passi del percorso, AI, avvisi, calendario, esclusioni
  expect(find.text('Passo 1 di 12'), findsOneWidget);
  await _tap(tester, find.text('Alto contrasto'));
  expect(s.display.value.highContrast, isTrue);
  expect(
    await tester.runAsync(() => s.settings.get('display_contrast')),
    'alto',
  );
  await _tap(tester, find.byKey(const Key('onboarding-appearance-next')));

  expect(find.text('Che università frequenti?'), findsOneWidget);
  expect(find.text('Passo 2 di 12'), findsOneWidget);

  await _tap(tester, find.text('Statale'));
  expect(find.text('In quale regione?'), findsOneWidget);
  // Solo le regioni con atenei statali.
  expect(find.text('Piemonte'), findsOneWidget);
  expect(find.text('Lazio'), findsNothing);

  await _tap(tester, find.text('Piemonte'));
  expect(find.text('Qual è la tua università?'), findsOneWidget);
  expect(find.text('Torino'), findsOneWidget);

  await _tap(tester, find.text('Politecnico di Torino'));
  expect(find.text('Che tipo di corso frequenti?'), findsOneWidget);
  expect(find.text('Laurea (triennale)'), findsOneWidget);
  expect(find.text('Laurea magistrale'), findsOneWidget);
  expect(find.text('Laurea magistrale a ciclo unico'), findsNothing);
  expect(find.text('Altro'), findsOneWidget);

  await _tap(tester, find.text('Laurea (triennale)'));
  expect(find.text('Qual è il tuo corso di laurea?'), findsOneWidget);
  expect(find.text('Classe L-8 · Torino · italiano · 3 anni'), findsOneWidget);

  await _tap(tester, find.text('Ingegneria Informatica'));
  expect(find.text('Che anno frequenti?'), findsOneWidget);
  expect(find.text('3° anno'), findsOneWidget);
  expect(find.text('Fuori corso'), findsOneWidget);

  await _tap(tester, find.text('2° anno'));
  expect(find.text('Tutto giusto?'), findsOneWidget);
  expect(find.text('Passo 8 di 12'), findsOneWidget);
  // niente più casella del calendario (.ics) nel riepilogo
  expect(find.byKey(const Key('onboarding-calendar')), findsNothing);

  await _tap(tester, find.byKey(const Key('onboarding-confirm')));
  await _settleUntil(tester, find.byKey(const Key('onboarding-next')));
  expect(find.text('Importati 4 insegnamenti e 2 libri.'), findsOneWidget);
  expect(s.profile.value, isNull, reason: 'ancora nel riepilogo');

  // 9. AI di riferimento: la scelta va in Collegamenti
  await _tap(tester, find.byKey(const Key('onboarding-next')));
  expect(find.text('Con quale AI studi?'), findsOneWidget);
  expect(find.text('Passo 9 di 12'), findsOneWidget);
  await _tap(tester, find.text('Claude'));
  expect(
    await tester.runAsync(() => s.settings.referenceAi()),
    ReferenceAi.claude,
  );

  // 10. avvisi: spiegazione, poi il permesso del sistema
  expect(find.text('Vuoi gli avvisi?'), findsOneWidget);
  expect(find.byType(FilledButton), findsOneWidget);
  await _tap(tester, find.byKey(const Key('onboarding-notifications-on')));
  await _settleUntil(tester, find.text('Vuoi le prove nel calendario?'));
  expect(
    await tester.runAsync(() => s.settings.get(NotificationKeys.consent)),
    '1',
  );

  // 11. calendario del telefono: proposto qui, non al primo esame
  await _tap(tester, find.byKey(const Key('onboarding-calendar-on')));
  await _settleUntil(tester, find.text('Vuoi nascondere qualcosa?'));
  expect(await tester.runAsync(() => s.settings.get(kCalendarOfferedKey)), '1');
  expect(await tester.runAsync(s.reminders.calendar.enabled), isTrue);

  // 12. gruppi da nascondere
  expect(find.text('Passo 12 di 12'), findsOneWidget);
  await _tap(tester, find.byKey(const Key('onboarding-exclude-ofa')));
  await _tap(tester, find.byKey(const Key('onboarding-done')));
  await _settle(tester, 20);
  expect(finished, [true]);
  expect(
    await tester.runAsync(s.settings.exclusionPatterns),
    containsAll(kExclusionPresets.first.patterns),
  );
  expect(s.profile.value?.degreeName, 'Ingegneria Informatica');
  expect(s.selectedYear.value, 2);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('percorso completo su telefono', (tester) async {
    await _fullFlow(tester, _phone);
  });

  testWidgets('percorso completo su desktop', (tester) async {
    await _fullFlow(tester, _desktop);
  });

  testWidgets('telematica: salta la regione', (tester) async {
    await _start(tester, _phone);
    await _tap(tester, find.text('Telematica'));
    expect(find.text('In quale regione?'), findsNothing);
    expect(find.text('Qual è la tua università?'), findsOneWidget);
    await _tap(tester, find.text('Università telematica “Pegaso”'));
    await _tap(tester, find.text('Laurea (triennale)'));
    await _tap(tester, find.text('Economia aziendale'));
    expect(find.text('Che anno frequenti?'), findsOneWidget);
    // Indietro: di nuovo i corsi, poi i tipi, poi gli atenei.
    await _tap(tester, find.byTooltip('Indietro'));
    expect(find.text('Qual è il tuo corso di laurea?'), findsOneWidget);
  });

  testWidgets('ricerca diretta: "bicocca" salta tipo, regione e ateneo', (
    tester,
  ) async {
    await _start(tester, _desktop);
    await tester.enterText(
      find.byKey(const Key('onboarding-search')),
      'bicocca',
    );
    await tester.pump();
    expect(find.text('Statale'), findsNothing);
    await _tap(tester, find.text('Università degli Studi di Milano “Bicocca”'));
    expect(find.text('Che tipo di corso frequenti?'), findsOneWidget);
    expect(find.text('Passo 5 di 12'), findsOneWidget);
    await _tap(tester, find.text('Laurea (triennale)'));
    expect(find.text('Scienze psicologiche'), findsOneWidget);
    // Indietro torna alla ricerca.
    await _tap(tester, find.byTooltip('Indietro'));
    await _tap(tester, find.byTooltip('Indietro'));
    expect(find.text('Che università frequenti?'), findsOneWidget);
  });

  testWidgets('corso non presente: inserimento a mano, fuori corso, offline', (
    tester,
  ) async {
    final (s, _) = await _start(tester, _phone, online: false);
    await tester.enterText(
      find.byKey(const Key('onboarding-search')),
      'Napoli',
    );
    await tester.pump();
    await _tap(tester, find.text('Università degli Studi “Federico II”'));
    // Nessun corso nell'indice: resta "Altro".
    expect(find.text('Laurea (triennale)'), findsNothing);
    await _tap(tester, find.text('Altro'));
    await _tap(tester, find.text('Aggiungi corso'));
    await tester.enterText(find.byKey(const Key('manual-name')), 'Fisica');
    await _tap(tester, find.text('Continua'));
    await _tap(tester, find.text('Fuori corso'));
    expect(find.text('Quale anno del piano stai completando?'), findsOneWidget);
    await _tap(tester, find.text('3° anno'));
    expect(find.text('Fuori corso · completo il 3° anno'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('onboarding-confirm')));
    await _settle(tester, 20);
    expect(find.textContaining('Corso inserito a mano'), findsOneWidget);
    final p = (await tester.runAsync(s.profiles.load))!;
    expect(p.manual, isTrue);
    expect(p.fuoriCorso, isTrue);
    expect(p.currentYear, 3);
    expect(p.universityId, 'unina');
  });

  testWidgets('senza rete e senza copia: «Serve una connessione», Riprova', (
    tester,
  ) async {
    final remote = <String, String>{}; // offline
    final (s, _) = await _start(tester, _phone, remote: remote);
    await _tap(tester, find.text('Statale'));
    await _tap(tester, find.text('Piemonte'));
    await _tap(tester, find.text('Politecnico di Torino'));
    await _tap(tester, find.text('Laurea (triennale)'));
    await _tap(tester, find.text('Ingegneria Informatica'));
    await _tap(tester, find.text('1° anno'));
    // il riepilogo prova a scaricare i dati dell'ateneo
    await _settleUntil(tester, find.byKey(const Key('catalog-offline')));
    expect(find.text(kServeConnessione), findsOneWidget);
    expect(
      (await tester.runAsync(() => s.catalog.datiAteneo('polito')))!.corsi,
      isFalse,
    );

    // di nuovo online: Riprova scarica i dati del solo ateneo scelto
    remote['corsi/polito.json'] = jsonEncode(corsiPolitoFixture());
    await _tap(tester, find.byKey(const Key('catalog-retry')));
    for (var i = 0; i < 150; i++) {
      final dati = await tester.runAsync(() => s.catalog.datiAteneo('polito'));
      if (dati!.corsi && s.catalog.progresso.value == null) break;
      await _settle(tester, 1);
    }
    await _settle(tester, 4);
    expect(find.byKey(const Key('catalog-offline')), findsNothing);
    expect(
      (await tester.runAsync(() => s.catalog.datiAteneo('polito')))!.corsi,
      isTrue,
    );
    await _tap(tester, find.byKey(const Key('onboarding-confirm')));
    await _settleUntil(tester, find.byKey(const Key('onboarding-next')));
    expect(find.text('Importati 4 insegnamenti e 2 libri.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'avvisi e calendario «Non ora»: niente permessi, una volta sola',
    (tester) async {
      final (s, finished) = await _start(tester, _phone);
      await _tap(tester, find.text('Statale'));
      await _tap(tester, find.text('Piemonte'));
      await _tap(tester, find.text('Politecnico di Torino'));
      await _tap(tester, find.text('Laurea (triennale)'));
      await _tap(tester, find.text('Ingegneria Informatica'));
      await _tap(tester, find.text('1° anno'));
      await _tap(tester, find.byKey(const Key('onboarding-confirm')));
      await _settleUntil(tester, find.byKey(const Key('onboarding-next')));
      await _tap(tester, find.byKey(const Key('onboarding-next')));
      // dopo l'import non si torna al riepilogo
      expect(find.byTooltip('Indietro'), findsNothing);
      await _tap(tester, find.byKey(const Key('onboarding-ai-skip')));
      await _tap(
        tester,
        find.byKey(const Key('onboarding-notifications-later')),
      );
      await _settleUntil(tester, find.text('Vuoi le prove nel calendario?'));
      await _tap(tester, find.byKey(const Key('onboarding-calendar-later')));
      await _settleUntil(tester, find.byKey(const Key('onboarding-done')));
      await _tap(tester, find.byKey(const Key('onboarding-done')));
      await _settle(tester, 20);
      expect(finished, [true]);
      final settings = (await tester.runAsync(s.settings.allSettings))!;
      expect(settings[NotificationKeys.asked], '1');
      expect(settings[NotificationKeys.consent], isNull);
      expect(settings[kCalendarOfferedKey], '1');
      expect(await tester.runAsync(s.reminders.calendar.enabled), isFalse);
      expect(await tester.runAsync(s.settings.exclusionPatterns), isEmpty);
    },
  );

  testWidgets('cambio corso: solo i passi del percorso, poi l\'app', (
    tester,
  ) async {
    final (s, finished) = await _start(tester, _phone, changing: true);
    expect(find.text('Che università frequenti?'), findsOneWidget);
    expect(find.text('Passo 1 di 7'), findsOneWidget);
    await _tap(tester, find.text('Statale'));
    await _tap(tester, find.text('Piemonte'));
    await _tap(tester, find.text('Politecnico di Torino'));
    await _tap(tester, find.text('Laurea (triennale)'));
    await _tap(tester, find.text('Ingegneria Informatica'));
    await _tap(tester, find.text('1° anno'));
    await _tap(tester, find.byKey(const Key('onboarding-confirm')));
    await _settleUntil(tester, find.byKey(const Key('onboarding-done')));
    expect(find.text('Vai all\'app'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('onboarding-done')));
    await _settle(tester);
    expect(finished, [true]);
    expect(find.text('Con quale AI studi?'), findsNothing);
    expect(s.profile.value?.degreeName, 'Ingegneria Informatica');
  });
}
