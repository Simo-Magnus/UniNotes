import 'package:flutter/material.dart' show ThemeMode, ValueNotifier;

import '../../features/cloud/google_drive_service.dart';
import '../../features/cloud/onedrive_service.dart';
import '../../features/notes/background_jobs.dart';
import '../../features/notes/lecture_recorder.dart';
import '../../features/notes/notes_store.dart';
import '../../features/notes/recycle_bin.dart';
import '../../features/study/focus/focus_service.dart';
import '../../repositories/book_repository.dart';
import '../../repositories/calendar_repository.dart';
import '../../repositories/course_repository.dart';
import '../../repositories/exam_repository.dart';
import '../../repositories/profile_repository.dart';
import '../../repositories/settings_repository.dart';
import '../../repositories/study_repository.dart';
import '../academic/plan_scope.dart';
import '../academic/student_profile.dart';
import '../catalog/catalog_service.dart';
import '../database/app_database.dart';
import '../feedback/feedback_service.dart';
import '../reminders/reminders_service.dart';
import '../theme/display_prefs.dart';
import 'app_state.dart';
import 'backup_service.dart';
import 'book_library.dart';
import 'datapack_importer.dart';
import 'whisper_service.dart';

/// Contenitore delle dipendenze, esposto con Provider.
/// Uso nelle schermate: `context.read<AppServices>().courses`.
class AppServices {
  AppServices(
    this.database, {
    BookLibrary? library,
    BookLibrary? materialsLibrary,
    BookLibrary? attachmentsLibrary,
    NotesStore? notes,
    CatalogService? catalog,
    WhisperService? whisper,
    OneDriveService? onedrive,
    GoogleDriveService? googleDrive,
    RemindersService Function(AppServices s)? reminders,
    LectureRecorder? recorder,
    AppFeedback? feedback,
  }) : _remindersFactory = reminders,
       _feedbackOverride = feedback,
       _recorderOverride = recorder,
       _notesOverride = notes,
       _catalogOverride = catalog,
       _whisperOverride = whisper,
       _onedriveOverride = onedrive,
       _googleDriveOverride = googleDrive,
       library = library ?? BookLibrary(),
       materialsLibrary =
           materialsLibrary ??
           BookLibrary(folderName: BookLibrary.materialsFolder),
       attachmentsLibrary =
           attachmentsLibrary ??
           BookLibrary(folderName: BookLibrary.attachmentsFolder),
       courses = CourseRepository(database),
       calendar = CalendarRepository(database),
       exams = ExamRepository(database),
       study = StudyRepository(database),
       books = BookRepository(database),
       settings = SettingsRepository(database),
       profiles = ProfileRepository(database),
       importer = DataPackImporter(database);

  final AppDatabase database;

  /// File dei libri copiati dentro l'app.
  final BookLibrary library;

  /// File del materiale didattico copiati dentro l'app.
  final BookLibrary materialsLibrary;

  /// File allegati a moduli e argomenti di Studio, copiati dentro l'app.
  final BookLibrary attachmentsLibrary;
  final CourseRepository courses;
  final CalendarRepository calendar;
  final ExamRepository exams;
  final StudyRepository study;
  final BookRepository books;
  final SettingsRepository settings;
  final ProfileRepository profiles;
  final DataPackImporter importer;

  /// Database pubblico degli atenei (asset, cache su disco, rete).
  late final CatalogService catalog =
      _catalogOverride ?? CatalogService(settings);
  final CatalogService? _catalogOverride;

  /// Percorso dello studente (null = onboarding non ancora fatto).
  final ValueNotifier<StudentProfile?> profile = ValueNotifier(null);

  /// Anno del piano mostrato da Home, Studio, Libri ed Esami (selettore
  /// nelle barre); a ogni avvio torna l'anno frequentato.
  final ValueNotifier<int?> selectedYear = ValueNotifier(null);

  /// Filtro dei corsi per il percorso e l'anno scelti.
  PlanScope get scope =>
      PlanScope(profile: profile.value, year: selectedYear.value);

  /// Legge il profilo dal database e riporta il selettore all'anno
  /// frequentato.
  Future<StudentProfile?> loadProfile() async {
    final p = await profiles.load();
    profile.value = p;
    selectedYear.value = p?.currentYear;
    return p;
  }

  /// Mostra l'anno [year] del piano in tutte le schermate.
  void selectYear(int year) {
    if (selectedYear.value == year) return;
    selectedYear.value = year;
    revision.bump();
  }

  /// Appunti dei corsi (registrazioni, trascrizioni, riassunti) come file.
  late final NotesStore notes = _notesOverride ?? NotesStore(settings);
  final NotesStore? _notesOverride;

  /// OneDrive (appunti su tutti i dispositivi) e OneNote.
  late final OneDriveService onedrive =
      _onedriveOverride ?? OneDriveService(settings, notes, sources: _sources);

  /// Google Drive: le stesse funzioni di OneDrive.
  late final GoogleDriveService googleDrive =
      _googleDriveOverride ??
      GoogleDriveService(settings, notes, sources: _sources);
  final GoogleDriveService? _googleDriveOverride;

  /// Servizi cloud (per i controlli comuni: collegati, sincronizzazione).
  List<CloudDriveService> get clouds => [onedrive, googleDrive];

  SyncSources get _sources => SyncSources(
    books: library.directory,
    materials: materialsLibrary.directory,
    attachments: attachmentsLibrary.directory,
    backupJson: () => BackupService(database).exportJson(),
    recordingInProgress: () => recorder.active ? recorder.path : null,
    changeCounter: () async =>
        ((await database.db.rawQuery('SELECT total_changes() AS n')).first['n']
                as num)
            .toInt(),
  );

  /// Whisper locale (modelli, programma, trascrizione).
  late final WhisperService whisper =
      _whisperOverride ?? WhisperService(settings: settings);
  final WhisperService? _whisperOverride;
  final OneDriveService? _onedriveOverride;

  /// Pulizia una tantum: la chiave API di Gemini (nel portachiavi) e le
  /// impostazioni di Gemini via API e di Antigravity non si usano più.
  Future<void> removeLegacyGemini({CloudSecrets? secrets}) async {
    if (await settings.get(SettingKeys.legacyGeminiRemoved) == '1') return;
    await settings.removeKeys(SettingKeys.legacyGemini);
    try {
      await (secrets ?? SecureCloudSecrets()).delete('gemini.apiKey');
    } catch (_) {
      // portachiavi non disponibile: non c'era niente da togliere
    }
    await settings.set(SettingKeys.legacyGeminiRemoved, '1');
  }

  /// Operazioni lunghe in corso (trascrizioni, riassunti, download).
  final BackgroundJobs jobs = BackgroundJobs();

  /// Registratore delle lezioni (uno solo, sopravvive al cambio schermata),
  /// con la trascrizione dal vivo di Whisper.
  late final LectureRecorder recorder =
      _recorderOverride ?? LectureRecorder(whisper: whisper);
  final LectureRecorder? _recorderOverride;

  /// «Eliminati di recente»: registrazioni e appunti eliminati, 30 giorni.
  late final RecycleBin trash = RecycleBin(notes.root);

  /// Tema scelto (Impostazioni → Aspetto); predefinito scuro.
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.dark);

  /// Notifica di modifica dati: chiamare `revision.bump()` dopo ogni scrittura.
  final DataRevision revision = DataRevision();

  /// Schermate da aprire richieste da notifiche e widget.
  final RouteRequests openRoute = RouteRequests();

  /// Calendario di sistema, notifiche locali e widget della Home.
  RemindersService get reminders =>
      _reminders ??= _remindersFactory?.call(this) ?? RemindersService(this);
  RemindersService? _reminders;
  final RemindersService Function(AppServices s)? _remindersFactory;

  /// Promemoria già creati e avviati (all'avvio dell'app; nei test di
  /// solito no): senza, le notifiche immediate non si mostrano.
  bool get remindersStarted => _reminders?.started ?? false;

  /// Suoni e vibrazioni (Impostazioni → Suoni e vibrazioni).
  late final AppFeedback feedback = _feedbackOverride ?? AppFeedback();
  final AppFeedback? _feedbackOverride;

  /// Contrasto, grandezza dei caratteri e animazioni (Impostazioni →
  /// Aspetto).
  final ValueNotifier<DisplayPrefs> display = ValueNotifier(
    const DisplayPrefs(),
  );

  /// Modalità Focus di Studio (una sola sessione, sopravvive al cambio
  /// schermata).
  late final FocusService focus = FocusService(this);
}
