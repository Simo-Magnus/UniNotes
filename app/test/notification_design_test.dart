import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/promo_rules.dart';

/// Aspetto delle notifiche su Android, iOS, macOS e Windows (grafiche,
/// raggruppamento, stili), senza toccare quando partono.
void main() {
  PlannedNotification exam() => PlannedNotification(
    id: 123456,
    type: NotificationType.exam,
    at: DateTime(2026, 1, 19, 9),
    title: 'Esame domani: Analisi I',
    body: 'martedì 20 gennaio alle 9:00 · Aula 5',
    payload: AppRoutes.exam(7),
  );

  test('prova: elenco su Android, sezione e grafica del tipo', () {
    final d = LocalNotificationPlatform.detailsFor(
      exam(),
      windowsLogo:
          r'C:\UniNotes\data\flutter_assets\assets\notifiche\prove.png',
    );
    final a = d.android!;
    expect(a.icon, 'ic_stat_uninotes');
    expect(
      (a.largeIcon! as DrawableResourceAndroidBitmap).data,
      'ic_notif_prove',
    );
    expect(a.subText, 'Esami');
    final style = a.styleInformation! as InboxStyleInformation;
    expect(style.lines, ['martedì 20 gennaio alle 9:00', 'Aula 5']);
    expect(style.contentTitle, 'Esame domani: Analisi I');
    // iOS e macOS: sottotitolo e pila della sezione
    expect(d.iOS!.subtitle, 'Esami');
    expect(d.iOS!.threadIdentifier, 'uninotes_esami');
    expect(d.macOS!.threadIdentifier, 'uninotes_esami');
    expect(d.iOS!.attachments, isNull);
    // Windows: intestazione della sezione e logo del tipo
    final w = d.windows!;
    expect(w.header!.title, 'Esami');
    expect(w.header!.arguments, 'sezione:Esami');
    expect(w.images.single.placement, WindowsImagePlacement.appLogoOverride);
    expect(w.duration, WindowsNotificationDuration.long);
  });

  test('una riga sola: testo esteso invece dell\'elenco', () {
    final n = PlannedNotification(
      id: 1,
      type: NotificationType.exam,
      at: DateTime(2026, 1, 19, 9),
      title: 'Esame domani: Analisi I',
      body: 'martedì 20 gennaio',
      payload: AppRoutes.exams,
    );
    final a = LocalNotificationPlatform.detailsFor(n).android!;
    expect(a.styleInformation, isA<BigTextStyleInformation>());
    expect(LocalNotificationPlatform.detailsFor(n).windows!.images, isEmpty);
  });

  test('recensione: nessuna sezione, immagine larga, tre pulsanti', () {
    final n = PlannedNotification(
      id: 2,
      type: NotificationType.review,
      at: DateTime(2026, 3, 1, 18),
      title: 'Ti trovi bene con UniNotes?',
      body: 'Se ti va, lascia una recensione.',
      payload: AppRoutes.review,
      actions: const [
        (NotificationActions.review, 'Recensisci'),
        (NotificationActions.later, 'Più tardi'),
        (NotificationActions.never, 'Non chiedere più'),
      ],
    );
    final d = LocalNotificationPlatform.detailsFor(
      n,
      windowsLogo: r'C:\a\recensione.png',
      windowsHero: r'C:\a\hero_recensione.png',
      darwinAttachment: '/tmp/notifiche/2_hero_recensione.png',
    );
    expect(d.android!.subText, isNull);
    expect(d.android!.priority, Priority.low);
    expect(d.android!.actions, hasLength(3));
    expect(d.windows!.header, isNull);
    expect(d.windows!.images.map((i) => i.placement), [
      WindowsImagePlacement.appLogoOverride,
      WindowsImagePlacement.hero,
    ]);
    expect(d.windows!.actions.first.arguments, 'act:recensisci|recensione');
    expect(d.iOS!.attachments!.single.filePath, endsWith('.png'));
    expect(d.iOS!.threadIdentifier, 'uninotes_uninotes');
  });

  test('sessione Focus in corso: fissa, silenziosa, conto alla rovescia', () {
    final end = DateTime.now().add(const Duration(minutes: 25));
    final d = LocalNotificationPlatform.detailsFor(
      PlannedNotification(
        id: 3,
        type: NotificationType.focus,
        at: DateTime.now(),
        title: 'Focus: Analisi I',
        body: 'Pausa alle 10:30',
        payload: AppRoutes.focus,
        ongoing: true,
        silent: true,
        countdownTo: end,
      ),
    );
    expect(d.android!.ongoing, isTrue);
    expect(d.android!.chronometerCountDown, isTrue);
    expect(d.android!.subText, 'Studio');
    expect(d.windows!.duration, isNull);
  });

  group('sostegno solo nelle build con DONATIONS=link', () {
    final now = DateTime(2027, 3, 1, 10);
    final donation = donationNotification(DateTime(2027, 3, 2, 18));
    const prefs = NotificationPrefs(consent: true, donation: true);

    test('build senza donazioni (predefinita): mai pianificato', () {
      // anche con la preferenza attiva (es. salvata da un'altra build)
      expect(
        planNotifications(
          now: now,
          prefs: prefs,
          agenda: const [],
          donation: donation,
          donationsAllowed: false,
        ),
        isEmpty,
      );
      // i test girano senza --dart-define: il predefinito è «niente sostegno»
      expect(
        planNotifications(
          now: now,
          prefs: prefs,
          agenda: const [],
          donation: donation,
        ),
        isEmpty,
      );
      expect(
        NotificationType.available(donationsAllowed: false),
        isNot(contains(NotificationType.donation)),
      );
      expect(NotificationType.available(), isNot(contains(NotificationType.donation)));
      // nessuna categoria con «Dona» su iOS e macOS
      final cats = LocalNotificationPlatform.categoriesFor(
        donationsAllowed: false,
      );
      expect(cats.map((c) => c.identifier), isNot(contains('uninotes_sostegno')));
      expect(
        cats.expand((c) => c.actions).map((a) => a.identifier),
        isNot(contains(NotificationActions.donate)),
      );
      // ultimo controllo della piattaforma: non si mostra né si pianifica
      final p = LocalNotificationPlatform(null, false);
      expect(p.allows(donation), isFalse);
      expect(p.allows(exam()), isTrue);
    });

    test('build con donazioni: pianificato, con «Dona» e le sue grafiche', () {
      final plan = planNotifications(
        now: now,
        prefs: prefs,
        agenda: const [],
        donation: donation,
        donationsAllowed: true,
      );
      expect(plan.single.type, NotificationType.donation);
      expect(
        plan.single.actions.map((a) => a.$2),
        ['Dona', 'Più tardi', 'Non chiedere più'],
      );
      // la preferenza spenta vale comunque
      expect(
        planNotifications(
          now: now,
          prefs: const NotificationPrefs(consent: true, donation: false),
          agenda: const [],
          donation: donation,
          donationsAllowed: true,
        ),
        isEmpty,
      );
      expect(
        NotificationType.available(donationsAllowed: true),
        contains(NotificationType.donation),
      );
      expect(
        LocalNotificationPlatform.categoriesFor(donationsAllowed: true)
            .expand((c) => c.actions)
            .map((a) => a.identifier),
        contains(NotificationActions.donate),
      );
      expect(LocalNotificationPlatform(null, true).allows(donation), isTrue);
      final d = LocalNotificationPlatform.detailsFor(plan.single);
      expect(
        (d.android!.largeIcon! as DrawableResourceAndroidBitmap).data,
        'ic_notif_sostegno',
      );
    });
  });

  test('ogni tipo ha canale in un gruppo, icona grande e grafica', () {
    final res = Directory('android/app/src/main/res/drawable-nodpi');
    for (final t in NotificationType.values) {
      expect(kNotificationGroups, contains(t.groupId), reason: t.name);
      expect(t.channelName.length, lessThanOrEqualTo(40));
      expect(
        File('${res.path}/ic_notif_${t.artwork}.png').existsSync(),
        isTrue,
        reason: 'icona grande di ${t.name}',
      );
      expect(
        File('assets/notifiche/${t.artwork}.png').existsSync(),
        isTrue,
        reason: 'logo di ${t.name}',
      );
      if (t.hasHero) {
        expect(
          File('assets/notifiche/hero_${t.artwork}.png').existsSync(),
          isTrue,
        );
      }
    }
    expect(File('assets/notifiche/uninotes.png').existsSync(), isTrue);
    // le icone grandi sono protette dalla riduzione delle risorse
    expect(
      File('android/app/src/main/res/raw/keep.xml').readAsStringSync(),
      contains('@drawable/ic_notif_*'),
    );
  });
}
