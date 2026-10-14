import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'core/catalog/course_replacements.dart';
import 'core/catalog/path_setup.dart';
import 'core/database/app_database.dart';
import 'core/router/app_shell.dart';
import 'core/services/app_services.dart';
import 'core/services/install_check.dart';
import 'core/services/temp_files.dart';
import 'core/services/desktop_window.dart';
import 'core/services/nudges.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/display_prefs.dart';
import 'features/academic/new_year_check.dart';
import 'features/notes/recorder/recording_overlay.dart';
import 'features/onboarding/onboarding_flow.dart';
import 'features/onboarding/install_questions.dart';
import 'features/settings/app_info.dart';
import 'features/settings/logic/data_eraser.dart';
import 'features/settings/uninstall_mode.dart';
import 'repositories/settings_repository.dart';
import 'widgets/common.dart';
import 'widgets/glass.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows: il disinstallatore avvia l'app in modalità minima per la
  // pulizia dei dati (vedi features/settings/uninstall_mode.dart).
  if (args.contains(kUninstallArg)) {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
    await runUninstallMode();
    return;
  }
  // Attribuzioni BSD/dominio pubblico di koni_rar (file NOTICE, non incluso in
  // automatico dalla pagina delle licenze, che legge solo i file LICENSE).
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString(
      'assets/licenses/koni_rar_NOTICE.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['koni_rar'], notice);
  });
  // Caratteri IBM Plex inclusi negli asset (non sono un pacchetto: la loro
  // licenza non compare da sola nella pagina delle licenze).
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['IBM Plex (caratteri)'], ofl);
  });
  Intl.defaultLocale = 'it_IT';
  await initializeDateFormatting('it_IT');
  // Primo avvio dopo una (re)installazione: via le credenziali rimaste nel
  // portachiavi; i dati di un'installazione precedente non si rileggono
  // senza chiedere (usa / elimina, oppure usa / ignora per gli appunti in
  // Documenti sul PC).
  final check = InstallCheck.standard(kAppVersion);
  await runInstallQuestions(
    await check.run(),
    eraseLeftover: () async {
      final old = await AppDatabase.open();
      await DataEraser(
        AppServices(old),
      ).run(DataEraser.deviceItems(sharedNotes: Platform.isWindows));
    },
    recheck: check.run,
  );
  final db = await AppDatabase.open();
  final services = AppServices(db);
  services.themeMode.value = parseThemeMode(
    await services.settings.get(SettingKeys.themeMode),
  );
  // Aspetto (contrasto, caratteri, animazioni) e suoni/vibrazioni.
  try {
    services.display.value = DisplayPrefs.parse(
      contrast: await services.settings.get(DisplayKeys.contrast),
      textSize: await services.settings.get(DisplayKeys.textSize),
      reduceMotion: await services.settings.get(DisplayKeys.reduceMotion),
    );
    await services.feedback.load(services.settings);
  } catch (e) {
    debugPrint('Preferenze dell\'aspetto non lette: $e');
  }
  // Inviti non invasivi (recensione, sostegno): conta le aperture.
  try {
    await Nudges(services).registerOpen();
  } catch (_) {}
  // Percorso dello studente: senza profilo si apre l'onboarding.
  try {
    await services.loadProfile();
  } catch (e) {
    debugPrint('Profilo non letto: $e');
  }
  // PC: chiudendo la finestra durante una registrazione l'app resta
  // nell'area di notifica e continua a registrare; la chiusura vera chiede
  // se salvare, e lo spegnimento del PC la salva.
  if (DesktopWindow.supported) {
    try {
      await DesktopWindow(services).init();
    } catch (e) {
      debugPrint('Gestione della finestra non disponibile: $e');
    }
  }
  // chiave API di Gemini e Antigravity tolti dall'app: valori salvati via
  unawaited(services.removeLegacyGemini().catchError((Object _) {}));
  runApp(UniversityNotesApp(services: services));
  // copie temporanee di appunti e file estratti: non restano sul disco
  unawaited(clearTempFiles());
  // OneDrive e Google Drive: sincronizzazione all'avvio e ogni 10 minuti.
  for (final c in services.clouds) {
    c.startAutoSync();
  }
  // Calendario di sistema, notifiche pianificate e widget della Home
  // (nessuna richiesta di permessi all'avvio); poi la sessione Focus
  // rimasta aperta da una chiusura dell'app, che riprende o si salva.
  unawaited(
    services.reminders.start().whenComplete(() => services.focus.load()),
  );
}

class UniversityNotesApp extends StatelessWidget {
  const UniversityNotesApp({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return Provider<AppServices>.value(
      value: services,
      child: ListenableBuilder(
        listenable: Listenable.merge([services.themeMode, services.display]),
        builder: (context, _) {
          final display = services.display.value;
          final hc = display.highContrast;
          return MaterialApp(
            title: 'UniNotes',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(highContrast: hc),
            darkTheme: AppTheme.dark(highContrast: hc),
            themeMode: services.themeMode.value,
            // Fondo a strati dietro tutte le schermate (Scaffold trasparenti);
            // icone della barra di stato secondo il tema anche nelle schermate
            // senza AppBar.
            // Sopra il Navigator: i riquadri «Registrazione in corso» e della
            // sessione Focus, che restano su tutte le schermate.
            // Grandezza dei caratteri (sistema × scelta nell'app) e «Riduci
            // animazioni» (sistema o app) per tutta l'app.
            navigatorKey: appNavigatorKey,
            builder: (context, child) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(
                  textScaler: AppTextScaler(
                    media.textScaler,
                    display.textFactor,
                  ),
                  disableAnimations:
                      media.disableAnimations || display.reduceMotion,
                ),
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.overlayStyle(Theme.of(context).brightness),
                  child: AppBackground(
                    child: RecordingOverlayHost(
                      child: child ?? const SizedBox(),
                    ),
                  ),
                ),
              );
            },
            locale: const Locale('it', 'IT'),
            supportedLocales: const [Locale('it', 'IT'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const AppRoot(),
          );
        },
      ),
    );
  }
}

/// Primo avvio (nessun profilo) → onboarding, altrimenti l'app. Con il
/// profilo controlla anche il passaggio al nuovo anno accademico.
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return ValueListenableBuilder(
      valueListenable: services.profile,
      builder: (context, profile, _) => profile == null
          ? const OnboardingFlow()
          : const _NewYearGate(child: AppShell()),
    );
  }
}

class _NewYearGate extends StatefulWidget {
  const _NewYearGate({required this.child});
  final Widget child;

  @override
  State<_NewYearGate> createState() => _NewYearGateState();
}

class _NewYearGateState extends State<_NewYearGate> {
  late final AppServices _services = context.read<AppServices>();
  String? _degreeId;
  bool _noticing = false;

  @override
  void initState() {
    super.initState();
    _degreeId = _services.profile.value?.degreeId;
    _services.profile.addListener(_onProfile);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // corsi di laurea sostituiti nel catalogo (doppioni uniti): il profilo
      // passa al nuovo id prima di tutto il resto
      await PathSetupService(_services).migrateReplacedCourses();
      if (!mounted) return;
      await _showCourseNotice();
      if (!mounted) return;
      final answer = await checkNewAcademicYear(context);
      // Il passaggio d'anno aggiorna già il database.
      if (answer == null && mounted) await checkCatalogUpdate(context);
    });
  }

  @override
  void dispose() {
    _services.profile.removeListener(_onProfile);
    super.dispose();
  }

  /// Il corso del profilo è cambiato (anche dopo «Aggiorna database»):
  /// se è per una sostituzione nel catalogo, avviso discreto una volta sola.
  void _onProfile() {
    final id = _services.profile.value?.degreeId;
    if (id == _degreeId) return;
    _degreeId = id;
    // dopo il messaggio dell'aggiornamento che l'ha causato
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) _showCourseNotice();
    });
  }

  Future<void> _showCourseNotice() async {
    if (_noticing) return;
    _noticing = true;
    try {
      final name = await takeCourseReplacedNotice(_services);
      if (name == null || !mounted) return;
      showSnack(
        context,
        'Il tuo corso è stato aggiornato nel catalogo: ora è "$name"',
      );
    } finally {
      _noticing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
