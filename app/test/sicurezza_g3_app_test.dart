// Terzo giro della caccia alle falle (app e codice nativo, giro di
// verifica): avvio della registrazione dal widget solo dai widget dell'app,
// comandi del servizio in primo piano filtrati, modalità di prova solo a
// compilazione. Vedi «Giro 3 — App e codice nativo» in docs/sicurezza.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';

import 'support/fake_reminders.dart';

/// Notifiche finte con un tocco che ha «aperto l'app».
class _LaunchPlatform extends FakeNotificationPlatform {
  _LaunchPlatform(this.tap);
  final NotificationTap tap;

  @override
  Future<NotificationTap?> launchTap() async => tap;
}

/// Widget finti con una rotta in attesa.
class _RouteWidgets extends FakeHomeWidgets {
  _RouteWidgets(this.route);
  String? route;

  @override
  Future<String?> takeRoute() async {
    final r = route;
    route = null;
    return r;
  }
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const kotlin =
      'android/app/src/main/kotlin/io/github/simomagnus/universitynotes';

  group('1. registra:avvia solo dai widget dell\'app', () {
    test('dal tocco su una notifica la rotta apre solo il registratore', () {
      expect(
        RemindersService.notificationRoute(AppRoutes.recordStart),
        AppRoutes.record,
      );
      for (final r in [
        AppRoutes.record,
        AppRoutes.exams,
        AppRoutes.exam(12),
        AppRoutes.previousYears,
      ]) {
        expect(RemindersService.notificationRoute(r), r);
      }
    });

    Future<AppServices> services(
      NotificationPlatform platform,
      FakeHomeWidgets widgets,
    ) async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      return AppServices(
        db,
        reminders: (s) => RemindersService(
          s,
          platform: platform,
          calendarBackend: FakeCalendarBackend(),
          widgets: widgets,
          platformName: 'android',
        ),
      );
    }

    test('un intent di un\'altra app con l\'azione delle notifiche e il '
        'payload registra:avvia non avvia il microfono', () async {
      // flutter_local_notifications legge il payload da qualsiasi intent con
      // la sua azione arrivato a MainActivity (esportata): prima la rotta
      // arrivava così com'era e il registratore partiva
      final s = await services(
        _LaunchPlatform(const NotificationTap(AppRoutes.recordStart)),
        FakeHomeWidgets(),
      );
      await s.reminders.start();
      expect(s.openRoute.pending, AppRoutes.record);
    });

    test(
      'dal widget (codice controllato dal lato nativo) la rotta resta',
      () async {
        final s = await services(
          FakeNotificationPlatform(),
          _RouteWidgets(AppRoutes.recordStart),
        );
        await s.reminders.start();
        expect(s.openRoute.pending, AppRoutes.recordStart);
      },
    );

    test('Android: riaperta dalle app recenti o ricreata, l\'attività non '
        'riusa il codice del tocco di allora', () {
      final support = _read('$kotlin/widgets/WidgetSupport.kt');
      expect(support, contains('fresh: Boolean = true'));
      expect(support, contains('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY'));
      expect(
        support,
        contains('if (!fresh || fromHistory) return ROUTE_RECORD'),
      );
      final main = _read('$kotlin/MainActivity.kt');
      expect(
        main,
        contains('routeOf(this, intent, fresh = savedInstanceState == null)'),
      );
    });
  });

  group('2. comandi del servizio in primo piano (Android 7–12)', () {
    test('«Elimina» e comandi sconosciuti non passano mai', () {
      for (final fallback in [true, false]) {
        expect(
          packageCommandAllowed(btnDiscard, fallbackShown: fallback),
          isFalse,
        );
        expect(
          packageCommandAllowed('altro', fallbackShown: fallback),
          isFalse,
        );
        expect(packageCommandAllowed(null, fallbackShown: fallback), isFalse);
        expect(packageCommandAllowed(7, fallbackShown: fallback), isFalse);
      }
    });

    test(
      'Pausa, Riprendi e Salva solo con la notifica di riserva mostrata',
      () {
        for (final id in [btnPause, btnResume, btnSave]) {
          expect(packageCommandAllowed(id, fallbackShown: false), isFalse);
          expect(packageCommandAllowed(id, fallbackShown: true), isTrue);
        }
      },
    );

    test('gli eventi del servizio passano sempre', () {
      for (final id in ['pronto', 'nascosta', 'apri']) {
        expect(packageCommandAllowed(id, fallbackShown: false), isTrue);
      }
    });

    test('il ricevitore della notifica e dei widget resta non esportato e '
        'accetta solo comandi noti', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      final tag = RegExp(r'<receiver[^>]*RecordingCommandReceiver[^>]*>')
          .firstMatch(manifest);
      expect(tag, isNotNull);
      expect(tag!.group(0), contains('android:exported="false"'));
      final src = _read('$kotlin/RecordingNotification.kt');
      expect(
        src,
        contains(
          'val COMMANDS = setOf("pausa", "riprendi", "salva", "nascosta")',
        ),
      );
      // nessun ricevitore registrato a runtime dal codice dell'app
      for (final f
          in Directory(kotlin)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.kt'))) {
        expect(
          f.readAsStringSync(),
          isNot(contains('registerReceiver(')),
          reason: f.path,
        );
      }
    });
  });

  group('3. modalità di prova della finestra di Windows', () {
    test('solo da --dart-define a compilazione, mai da variabili d\'ambiente '
        'o argomenti', () {
      final src = _read('lib/core/services/test_data_dir.dart');
      expect(
        src,
        contains(
          "const String kTestDataDir = String.fromEnvironment('UNINOTES_CARTELLA_PROVA');",
        ),
      );
      expect(src, isNot(contains('Platform.environment')));
      expect(src, isNot(contains('arguments')));
    });

    test('nessuna build automatica la attiva', () {
      final wf = File('../.github/workflows/app.yml');
      if (!wf.existsSync()) return;
      expect(wf.readAsStringSync(), isNot(contains('UNINOTES_CARTELLA_PROVA')));
    });
  });
}
