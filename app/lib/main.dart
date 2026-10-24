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
import 'core/router/app_link_guard.dart';
import 'core/router/app_shell.dart';
import 'core/router/error_screens.dart';
import 'core/router/safe_scroll_action.dart';
import 'core/services/app_return.dart';
import 'core/services/app_services.dart';
import 'core/services/app_uninstall.dart';
import 'core/services/background_sync.dart';
import 'core/services/day_watcher.dart';
import 'core/services/error_log.dart';
import 'core/services/portable_path.dart';
import 'core/services/install_check.dart';
import 'core/services/legacy_data.dart';
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

/// Sincronizzazione ad app chiusa: punto d'ingresso del motore senza
/// interfaccia avviato da Android (BackgroundSync.kt).
@pragma('vm:entry-point')
Future<void> backgroundSyncMain() => runBackgroundSync();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // errori non gestiti nel registro locale, schermata comprensibile al posto
  // di quella rossa/grigia (core/router/error_screens.dart)
  installGlobalErrorHandlers();
  // collegamenti uninotes://… (widget, Comandi): gestiti dal lato nativo, non
  // sono percorsi del Navigator (core/router/app_link_guard.dart)
  installAppLinkGuard();
  // Windows: il disinstallatore avvia l'app in modalità minima per la
  // pulizia dei dati (vedi features/settings/uninstall_mode.dart). Non nella
  // build del Microsoft Store, dove disinstalla Windows.
  if (AppUninstall.handlesUninstallArg(args, kUninstallArg)) {
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
  // Modelli e librerie per la trascrizione inclusi nell'app (non sono
  // pacchetti Dart): Parakeet di NVIDIA (CC BY 4.0: attribuzione, modifiche,
  // testo della licenza), Silero VAD (MIT), ONNX Runtime (MIT, la DLL che
  // arriva con sherpa-onnx, la cui licenza Apache-2.0 compare da sola) e il
  // modello Whisper small q5_1 (MIT).
  LicenseRegistry.addLicense(() async* {
    const parakeet = ['NVIDIA Parakeet TDT 0.6B v3'];
    yield LicenseEntryWithLineBreaks(
      parakeet,
      await rootBundle.loadString('assets/licenses/parakeet_NOTICE.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      parakeet,
      await rootBundle.loadString('assets/licenses/CC-BY-4.0.txt'),
    );
    yield LicenseEntryWithLineBreaks(const [
      'Silero VAD',
    ], await rootBundle.loadString('assets/licenses/silero_vad_LICENSE.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'ONNX Runtime',
    ], await rootBundle.loadString('assets/licenses/onnxruntime_LICENSE.txt'));
    // Whisper small q5_1 incluso nelle app per PC e Mac (pesi di OpenAI e
    // conversione di whisper.cpp, MIT)
    yield LicenseEntryWithLineBreaks(const [
      'Whisper small q5_1 (OpenAI, whisper.cpp)',
    ], await rootBundle.loadString('assets/licenses/whisper_LICENSE.txt'));
  });
  // Caratteri IBM Plex inclusi negli asset (non sono un pacchetto: la loro
  // licenza non compare da sola nella pagina delle licenze).
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['IBM Plex (caratteri)'], ofl);
  });
  Intl.defaultLocale = 'it_IT';
  await initializeDateFormatting('it_IT');
  await _launch();
}

/// Apre i dati e avvia l'app. Se i dati non si aprono (database non
/// apribile, disco pieno…) si mostra cosa è successo con «Riprova» invece
/// di una finestra vuota o della chiusura dell'app.
Future<void> _launch() async {
  final AppServices services;
  try {
    services = await _openServices();
  } catch (e, st) {
    debugPrint('Avvio non riuscito: $e');
    await ErrorLog.record(e, st, context: 'Avvio dell\'app');
    runApp(StartupErrorApp(error: e, onRetry: _launch));
    return;
  }
  runApp(UniversityNotesApp(services: services));
  _afterStart(services);
}

/// Database, servizi e preferenze lette prima della prima schermata.
Future<AppServices> _openServices() async {
  // Android: il giro della sincronizzazione in background avviato ad app
  // chiusa può essere ancora al lavoro sul database (connessione condivisa):
  // la sua transazione non si annulla aprendo, quelle rimaste a metà da un
  // motore già chiuso sì (vedi AppDatabase.rollbackOrphanOnOpen)
  if (Platform.isAndroid) {
    AppDatabase.otherEngineWorking = BackgroundSync.headlessBusy;
  }
  // Windows: i dati delle versioni con il nome vecchio (University Notes)
  // passano alla cartella di UniNotes, prima del controllo dell'installazione
  // (senza, l'app si vedrebbe vuota e il controllo la darebbe per nuova).
  await LegacyData.migrateWindowsSupportDir();
  // Primo avvio dopo una (re)installazione: via le credenziali rimaste nel
  // portachiavi; i dati di un'installazione precedente non si rileggono
  // senza chiedere (usa / elimina, oppure usa / ignora per gli appunti in
  // Documenti sul PC).
  final check = InstallCheck.standard(kAppVersion);
  await runInstallQuestions(
    await check.run(),
    eraseLeftover: () async {
      final old = await AppDatabase.open();
      await DataEraser(AppServices(old))
          .run(DataEraser.deviceItems(sharedNotes: Platform.isWindows));
    },
    recheck: check.run,
  );
  final db = await AppDatabase.open();
  // percorsi dei file dell'app uguali su tutti i dispositivi (posizione del
  // lettore ed evidenziazioni sincronizzate)
  await initPortableBase();
  final services = AppServices(db);
  try {
    services.themeMode.value = parseThemeMode(
      await services.settings.get(SettingKeys.themeMode),
    );
  } catch (e) {
    debugPrint('Tema non letto: $e');
  }
  // Aspetto (contrasto, caratteri, animazioni) e suoni/vibrazioni.
  try {
    services.display.value = DisplayPrefs.parse(
      contrast: await services.settings.get(DisplayKeys.contrast),
      textSize: await services.settings.get(DisplayKeys.textSize),
      reduceMotion: await services.settings.get(DisplayKeys.reduceMotion),
    );
  } catch (e) {
    debugPrint('Preferenze dell\'aspetto non lette: $e');
  }
  try {
    await services.feedback.load(services.settings);
  } catch (e) {
    debugPrint('Preferenze di suoni e vibrazioni non lette: $e');
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
    // dopo l'accesso nel browser (OneDrive, Google Drive) l'app torna in
    // primo piano; Windows: schema uninotes:// per l'utente
    unawaited(AppReturn.init().catchError((Object _) {}));
  }
  // chiave API di Gemini e Antigravity tolti dall'app: valori salvati via
  unawaited(services.removeLegacyGemini().catchError((Object _) {}));
  return services;
}

/// Servizi avviati dopo la prima schermata: un errore di uno non ferma gli
/// altri (e finisce nel registro locale).
void _afterStart(AppServices services) {
  void step(String what, void Function() run) {
    try {
      run();
    } catch (e, st) {
      debugPrint('$what: $e');
      unawaited(ErrorLog.record(e, st, context: what));
    }
  }

  // database danneggiato messo da parte all'apertura: lo si dice una volta
  final aside = AppDatabase.recoveredCopy;
  if (aside != null) {
    AppDatabase.recoveredCopy = null;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(
        showDatabaseRecoveredNotice(
          aside,
          recoveredRows: AppDatabase.recoveredRows,
        ),
      ),
    );
  }
  // copie temporanee di appunti e file estratti: non restano sul disco
  unawaited(clearTempFiles());
  // OneDrive e Google Drive: sincronizzazione all'avvio e ogni 10 minuti.
  // Telefono: anche con l'app in background (JobScheduler, iOS background
  // fetch; vedi core/services/background_sync.dart).
  step('Sincronizzazione in background', () => BackgroundSync.attach(services));
  for (final c in services.clouds) {
    step('Sincronizzazione automatica', c.startAutoSync);
  }
  // Calendario di sistema, notifiche pianificate e widget della Home
  // (nessuna richiesta di permessi all'avvio); poi la sessione Focus
  // rimasta aperta da una chiusura dell'app, che riprende o si salva.
  step('Promemoria e sessione Focus', () {
    unawaited(
      services.reminders
          .start()
          .catchError((Object e, StackTrace st) {
            unawaited(ErrorLog.record(e, st, context: 'Promemoria'));
          })
          .whenComplete(
            () => services.focus.load().catchError((Object e, StackTrace st) {
              unawaited(ErrorLog.record(e, st, context: 'Sessione Focus'));
            }),
          ),
    );
  });
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
              final reduce = media.disableAnimations || display.reduceMotion;
              // «Riduci animazioni» anche per i riquadri che si aprono
              // (ExpansionTile non guarda il MediaQuery)
              final theme = Theme.of(context);
              child = Theme(
                data: reduce
                    ? theme.copyWith(
                        expansionTileTheme: theme.expansionTileTheme.copyWith(
                          expansionAnimationStyle: AnimationStyle.noAnimation,
                        ),
                      )
                    : theme,
                child: child ?? const SizedBox(),
              );
              return MediaQuery(
                data: media.copyWith(
                  textScaler: AppTextScaler(
                    media.textScaler,
                    display.textFactor,
                  ),
                  disableAnimations: reduce,
                ),
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.overlayStyle(Theme.of(context).brightness),
                  child: AppBackground(
                    child: RecordingOverlayHost(
                      // Pagina giù/su con più liste nella pagina: niente
                      // errore (core/router/safe_scroll_action.dart)
                      child: SafeScrollActions(child: child),
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

  /// Giorno cambiato con l'app aperta o ripresa dopo giorni: le schermate
  /// rileggono i dati («oggi», conti alla rovescia) e, se è iniziato un
  /// nuovo anno accademico, arriva la domanda come all'avvio.
  late final DayWatcher _day = DayWatcher(_onNewDay);
  bool _askingYear = false;

  Future<void> _onNewDay() async {
    _services.revision.bump();
    if (_askingYear || !mounted) return;
    _askingYear = true;
    try {
      await _guard('Nuovo anno accademico', () async {
        await checkNewAcademicYear(context);
      });
    } finally {
      _askingYear = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _degreeId = _services.profile.value?.degreeId;
    _services.profile.addListener(_onProfile);
    _day.start();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // corsi di laurea sostituiti nel catalogo (doppioni uniti): il profilo
      // passa al nuovo id prima di tutto il resto
      await PathSetupService(_services).migrateReplacedCourses();
      if (!mounted) return;
      await _guard('Avviso del corso aggiornato', _showCourseNotice);
      if (!mounted) return;
      // Il passaggio d'anno aggiorna già il database.
      Object? answer;
      _askingYear = true;
      final bool asked;
      try {
        asked = await _guard('Nuovo anno accademico', () async {
          answer = await checkNewAcademicYear(context);
        });
      } finally {
        _askingYear = false;
      }
      if (asked && answer == null && mounted) {
        await _guard(
          'Aggiornamento del database',
          () => checkCatalogUpdate(context),
        );
      }
    });
  }

  /// Un controllo dell'avvio che non riesce (rete, catalogo, database) non
  /// ferma gli altri: finisce nel registro. false = non riuscito.
  Future<bool> _guard(String what, Future<void> Function() run) async {
    try {
      await run();
      return true;
    } catch (e, st) {
      debugPrint('$what: $e');
      await ErrorLog.record(e, st, context: what);
      return false;
    }
  }

  @override
  void dispose() {
    _day.dispose();
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
