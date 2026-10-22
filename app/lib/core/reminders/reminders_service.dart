import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../../features/cloud/cloud_drive_service.dart';
import '../../features/exams/previous_years.dart';
import '../../models/exam.dart';
import '../catalog/catalog_models.dart';
import '../constants/build_flags.dart';
import '../constants/enums.dart';
import '../services/app_services.dart';
import '../services/calendar_export.dart';
import '../services/external_launcher.dart';
import '../services/nudges.dart';
import 'agenda.dart';
import 'apple_calendar_backend.dart';
import 'device_calendar_backend.dart';
import 'home_widgets.dart';
import 'notification_platform.dart';
import 'notification_plan.dart';
import 'notification_prefs.dart';
import 'outlook_calendar_backend.dart';
import 'promo_rules.dart';
import 'system_calendar.dart';

/// Promemoria delle prove: calendario di sistema, notifiche locali e widget
/// della schermata Home, tenuti allineati ai dati dell'app.
///
/// Si aggiorna all'avvio, dopo ogni modifica (`revision.bump()`, con un
/// breve ritardo per raggruppare le scritture), al cambio di corso o
/// percorso, al cambio delle impostazioni e al ritorno nell'app. Ogni
/// aggiornamento: (1) scrive le prove nel calendario se il collegamento è
/// attivo, (2) cancella e ricrea le notifiche pianificate dall'app, (3)
/// aggiorna i widget.
class RemindersService extends ChangeNotifier {
  RemindersService(
    this._s, {
    NotificationPlatform? platform,
    CalendarBackend? calendarBackend,
    bool useDefaultCalendar = true,
    HomeWidgetBridge? widgets,
    String? platformName,
    this.isRecording,
    this.focusQuietUntil,
  }) : platform = platform ?? LocalNotificationPlatform(),
       widgets = widgets ?? HomeWidgetBridge(),
       platformName = platformName ?? Platform.operatingSystem {
    outlook = this.platformName == 'windows'
        ? OutlookCalendarAuth(_s.onedrive)
        : null;
    calendar = SystemCalendarSync(
      _s.settings,
      calendarBackend ??
          (useDefaultCalendar ? _defaultBackend(this.platformName) : null),
      device: CalendarDevice(
        installId: _s.onedrive.installId,
        name: _s.onedrive.deviceName,
      ),
    );
  }

  final AppServices _s;

  /// Registrazione in corso (nei test: finta); null = il registratore
  /// dell'app. Mai richieste di recensione o sostegno mentre si registra.
  final bool Function()? isRecording;
  bool get _recording => isRecording?.call() ?? _s.recorder.active;

  /// Fine della sessione Focus in corso (nei test: finta); null = quella
  /// dell'app. Fino ad allora gli avvisi non urgenti aspettano.
  final DateTime? Function()? focusQuietUntil;
  DateTime? get _quietUntil =>
      focusQuietUntil != null ? focusQuietUntil!() : _s.focus.quietUntil;
  final NotificationPlatform platform;
  final HomeWidgetBridge widgets;

  /// android | ios | macos | windows (nei test si sceglie).
  final String platformName;
  late final SystemCalendarSync calendar;

  /// Accesso al calendario Outlook (solo Windows).
  late final OutlookCalendarAuth? outlook;

  CalendarBackend? _defaultBackend(String p) => switch (p) {
    // Android: calendario vero e sincronizzato (Google…) con codice nativo
    'android' => AndroidCalendarBackend(),
    // iPhone, iPad e Mac: EventKit con codice nativo (calendario predefinito
    // per i nuovi eventi o quello scelto)
    'ios' || 'macos' => AppleCalendarBackend(),
    'windows' => OutlookCalendarBackend(outlook!),
    _ => null,
  };

  /// Notifiche disponibili su questa piattaforma.
  bool get notificationsSupported =>
      const {'android', 'ios', 'macos', 'windows'}.contains(platformName);

  bool _started = false;

  /// Avviato dall'app (main): nei test resta spento.
  bool get started => _started;
  Timer? _debounce;
  Future<void>? _running;
  bool _again = false;
  bool _wasRecording = false;
  bool _wasFocusing = false;
  AppLifecycleListener? _lifecycle;

  /// Avvio dell'app: notifiche pronte, tocchi in sospeso, ascolto delle
  /// modifiche e primo aggiornamento. Mai richieste di permessi qui.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (notificationsSupported) {
      try {
        await platform.init(_onTap);
        final launch = await platform.launchTap();
        if (launch != null) await _onTap(launch);
      } catch (e) {
        debugPrint('Notifiche non disponibili: $e');
      }
    }
    widgets.listen(_s.openRoute.call);
    final route = await widgets.takeRoute();
    if (route != null) _s.openRoute.call(route);
    await _processQueued();

    _s.revision.addListener(_soon);
    _s.profile.addListener(_soon);
    _s.recorder.addListener(_recorderChanged);
    _s.focus.addListener(_focusChanged);
    for (final c in _s.clouds) {
      c.addListener(() => _cloudChanged(c));
    }
    try {
      _lifecycle = AppLifecycleListener(onResume: _resumed);
    } catch (_) {}
    // controllo di salute del calendario anche una volta al giorno con l'app
    // sempre aperta (PC nell'area di notifica)
    _daily = Timer.periodic(const Duration(hours: 24), (_) => _soon());
    await refresh();
  }

  Timer? _daily;

  Future<void> _resumed() async {
    try {
      await Nudges(_s).registerUseDay();
    } catch (_) {}
    final route = await widgets.takeRoute();
    if (route != null) _s.openRoute.call(route);
    await _processQueued();
    _soon();
  }

  Future<void> _processQueued() async {
    try {
      for (final t in await platform.takeQueuedTaps()) {
        await _applyAction(t);
      }
    } catch (_) {}
  }

  void _recorderChanged() {
    final rec = _s.recorder.active;
    if (rec == _wasRecording) return;
    _wasRecording = rec;
    _soon();
  }

  /// Inizio o fine di una sessione Focus: gli avvisi non urgenti si
  /// spostano dopo la fine (o tornano al loro posto).
  void _focusChanged() {
    final f = _s.focus.active;
    if (f == _wasFocusing) return;
    _wasFocusing = f;
    _soon();
  }

  /// Aggiornamento poco dopo una modifica (le scritture vicine si
  /// raggruppano).
  void _soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => unawaited(refresh()));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _daily?.cancel();
    _lifecycle?.dispose();
    if (_started) {
      _s.revision.removeListener(_soon);
      _s.profile.removeListener(_soon);
      _s.recorder.removeListener(_recorderChanged);
      _s.focus.removeListener(_focusChanged);
    }
    super.dispose();
  }

  /// Aggiorna calendario, notifiche e widget (uno alla volta: una richiesta
  /// durante l'aggiornamento ne fa partire un altro alla fine).
  Future<void> refresh({DateTime? now}) async {
    if (_running != null) {
      _again = true;
      return _running;
    }
    final run = _refresh(now ?? DateTime.now());
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
    if (_again) {
      _again = false;
      await refresh();
    }
  }

  Future<void> _refresh(DateTime now) async {
    final AgendaData data;
    final NotificationPrefs prefs;
    try {
      data = await loadAgenda(now);
      prefs = await NotificationPrefs.load(_s.settings);
    } catch (e) {
      // database non leggibile: si riprova al prossimo aggiornamento (un
      // errore qui arriverebbe ai timer e ai listener, che non lo aspettano)
      debugPrint('Promemoria non aggiornati: $e');
      return;
    }
    var status = CalendarStatus.off;
    try {
      status = await calendar.sync(
        data.agenda,
        prefs.examOffsets,
        offsetHours: prefs.examHours,
        now: now,
      );
    } on CalendarAccessException catch (e) {
      status = await _calendarStatus();
      if (e.expired) await linkBroken('calendario', now: now);
    } catch (e) {
      debugPrint('Calendario non aggiornato: $e');
      status = await _calendarStatus();
    }
    try {
      await reschedule(data, status, now: now);
    } catch (e) {
      debugPrint('Notifiche non pianificate: $e');
    }
    try {
      await widgets.update(widgetPayload(data.agenda, now));
    } catch (_) {}
    notifyListeners();
  }

  /// Stato del calendario dopo un errore (spento se non si legge: le
  /// notifiche le manda l'app).
  Future<CalendarStatus> _calendarStatus() async {
    try {
      return await calendar.status();
    } catch (_) {
      return CalendarStatus.off;
    }
  }

  /// Prove (e sessioni) del corso attuale.
  Future<AgendaData> loadAgenda(DateTime now) async {
    final pending = await CalendarExport(_s).pendingWithDate();
    final courses = {
      for (final c in (await _s.courses.mapById()).values) c.id!: c.name,
    };
    CalendarioSessioni? sessions;
    final p = _s.profile.value;
    if (p != null) {
      try {
        sessions = (await _s.catalog.sessioni(p.universityId))?.data
            .per(p.degreeId);
      } catch (_) {}
    }
    return AgendaData(
      agenda: buildAgenda(
        exams: pending,
        courseNames: courses,
        sessions: sessions,
        now: now,
      ),
      pending: pending,
      courseNames: courses,
    );
  }

  // ------------------------------------------------------------ notifiche

  Future<Map<int, DateTime>> _dateMap(String key) async {
    final raw = await _s.settings.get(key);
    if (raw == null) return {};
    final out = <int, DateTime>{};
    try {
      for (final e in (jsonDecode(raw) as Map).entries) {
        final k = int.tryParse('${e.key}');
        final v = DateTime.tryParse('${e.value}');
        if (k != null && v != null) out[k] = v;
      }
    } catch (_) {}
    return out;
  }

  Future<void> _setDateMap(String key, Map<int, DateTime> m) => _s.settings.set(
    key,
    m.isEmpty
        ? null
        : jsonEncode({
            for (final e in m.entries) '${e.key}': e.value.toIso8601String(),
          }),
  );

  Future<Set<int>> _idSet(String key) async => {
    for (final x in (await _s.settings.get(key) ?? '').split(','))
      ?int.tryParse(x.trim()),
  };

  Future<DateTime?> _date(String key) async =>
      DateTime.tryParse(await _s.settings.get(key) ?? '');

  Future<void> _setDate(String key, DateTime? v) =>
      _s.settings.set(key, v?.toIso8601String());

  /// Le richieste già passate sono state mostrate: si registrano prima di
  /// ripianificare (una sola volta per prova, una sola recensione…).
  Future<void> _recordShown(DateTime now) async {
    final reviewAt = await _date(NotificationKeys.reviewAt);
    if (reviewAt != null && !reviewAt.isAfter(now)) {
      await _s.settings.set(NotificationKeys.reviewState, 'done');
      await _setDate(NotificationKeys.reviewShownAt, reviewAt);
      await _setDate(NotificationKeys.reviewAt, null);
      await _s.settings.set(Nudges.reviewDoneKey, '1');
    }
    final donationAt = await _date(NotificationKeys.donationAt);
    if (donationAt != null && !donationAt.isAfter(now)) {
      await _setDate(NotificationKeys.donationShownAt, donationAt);
      await _setDate(NotificationKeys.donationNext, plusDays(donationAt, 182));
      await _setDate(NotificationKeys.donationAt, null);
    }
    final outcome = await _dateMap(NotificationKeys.outcomeScheduled);
    final done = await _idSet(NotificationKeys.outcomeDone);
    final fired = [
      for (final e in outcome.entries)
        if (!e.value.isAfter(now)) e.key,
    ];
    if (fired.isNotEmpty) {
      done.addAll(fired);
      outcome.removeWhere((k, _) => fired.contains(k));
      await _s.settings.set(NotificationKeys.outcomeDone, done.join(','));
      await _setDateMap(NotificationKeys.outcomeScheduled, outcome);
    }
  }

  Future<PromoState> _promoState(DateTime now) async {
    return PromoState(
      firstOpen: await _date(Nudges.firstOpenKey) ?? now,
      useDays:
          int.tryParse(await _s.settings.get(Nudges.useDaysKey) ?? '') ?? 0,
      reviewClosed:
          await _s.settings.get(NotificationKeys.reviewState) != null ||
          await _s.settings.get(Nudges.reviewDoneKey) != null,
      reviewAt: await _date(NotificationKeys.reviewAt),
      reviewUntil: await _date(NotificationKeys.reviewUntil),
      reviewShownAt: await _date(NotificationKeys.reviewShownAt),
      donationOff:
          await _s.settings.get(NotificationKeys.donationOff) != null ||
          await _s.settings.get(Nudges.donationOffKey) != null,
      donationAt: await _date(NotificationKeys.donationAt),
      donationNext: await _date(NotificationKeys.donationNext),
      donationShownAt: await _date(NotificationKeys.donationShownAt),
    );
  }

  /// Cancella e ricrea le notifiche pianificate dall'app.
  Future<List<PlannedNotification>> reschedule(
    AgendaData data,
    CalendarStatus status, {
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    if (!notificationsSupported) return const [];
    await _recordShown(t);
    final prefs = await NotificationPrefs.load(_s.settings);

    // promemoria promozionali (recensione, sostegno)
    final state = await _promoState(t);
    final examDays = [for (final i in data.agenda) i.date];
    final quietUntil = _quietUntil;
    // mai richieste di recensione o sostegno mentre si registra o durante
    // una sessione Focus
    final recording = _recording || quietUntil != null;
    final dest = reviewDestination(platform: platformName);
    final reviewAt = prefs.consent && prefs.review
        ? reviewSlot(
            now: t,
            state: state,
            examDays: examDays,
            recording: recording,
            available: dest != null,
          )
        : null;
    final donationAt = prefs.consent && prefs.donation
        ? donationSlot(
            now: t,
            state: state,
            examDays: examDays,
            recording: recording,
            available: kShowDonationLink,
            reviewAt: reviewAt,
          )
        : null;

    final outcomes = [
      for (final e in data.pending)
        if (e.date != null && e.id != null)
          OutcomeCandidate(
            examId: e.id!,
            subject: data.courseNames[e.courseId] ?? 'Esame',
            midterm: e.kind == ExamKind.midterm,
            date: e.date!,
          ),
    ];
    final plan = planNotifications(
      now: t,
      prefs: prefs,
      agenda: data.agenda,
      calendarWorking: status.working,
      calendarWritten: status.written,
      outcomes: outcomes,
      outcomeDone: await _idSet(NotificationKeys.outcomeDone),
      review: reviewAt == null ? null : reviewNotification(reviewAt, dest!),
      donation: donationAt == null ? null : donationNotification(donationAt),
      previousYears: prefs.consent && prefs.previousYears
          ? await _previousYears(t)
          : const [],
      quietUntil: quietUntil,
    );

    // senza [start] (motore senza interfaccia della sincronizzazione in
    // background) le notifiche non sono ancora pronte: si preparano qui,
    // altrimenti le vecchie si cancellerebbero e le nuove non partirebbero
    if (!_started) {
      try {
        await platform.init(_onTap);
      } catch (e) {
        debugPrint('Notifiche non disponibili: $e');
        return const [];
      }
    }
    // cancella le notifiche ancora future pianificate l'ultima volta (non
    // quelle già mostrate) e pianifica le nuove
    final old = await _dateMap(NotificationKeys.scheduled);
    for (final e in old.entries) {
      if (e.value.isAfter(t)) {
        try {
          await platform.cancel(e.key);
        } catch (_) {}
      }
    }
    final done = <int, DateTime>{};
    for (final n in plan) {
      try {
        await platform.schedule(n);
        done[n.id] = n.at;
      } catch (e) {
        debugPrint('Notifica non pianificata ($n): $e');
      }
    }
    await _setDateMap(NotificationKeys.scheduled, done);
    await _setDate(
      NotificationKeys.reviewAt,
      plan.any((n) => n.type == NotificationType.review) ? reviewAt : null,
    );
    await _setDate(
      NotificationKeys.donationAt,
      plan.any((n) => n.type == NotificationType.donation) ? donationAt : null,
    );
    final outcomeAt = <int, DateTime>{};
    for (final n in plan) {
      final id = AppRoutes.examId(n.payload);
      if (n.type == NotificationType.outcome && id != null) {
        outcomeAt[id] = n.at;
      }
    }
    await _setDateMap(NotificationKeys.outcomeScheduled, outcomeAt);
    return plan;
  }

  /// Promemoria degli esami degli anni precedenti ancora da completare (3 e
  /// 14 giorni dopo l'onboarding o il cambio di corso, vedi
  /// [PreviousYearsPrompt]); nessuno se non c'è nulla da completare.
  Future<List<PlannedNotification>> _previousYears(DateTime now) async {
    try {
      final d = await loadPreviousYears(_s);
      if (d == null || d.toComplete == 0) return const [];
      return previousYearsReminders(
        since: await PreviousYearsPrompt.since(_s.settings, now: now),
        count: d.toComplete,
        startYear: d.startYear,
        days: PreviousYearsPrompt.reminderDays,
      );
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------ azioni

  Future<void> _onTap(NotificationTap tap) async {
    await _applyAction(tap);
    _soon();
  }

  /// Pulsanti e tocchi delle notifiche.
  Future<void> _applyAction(NotificationTap tap) async {
    final now = DateTime.now();
    final p = tap.payload;
    final a = tap.action;
    final s = _s.settings;
    if (p == AppRoutes.review) {
      switch (a) {
        case NotificationActions.later:
          final n =
              int.tryParse(await s.get(NotificationKeys.reviewLater) ?? '') ??
              0;
          await _setDate(NotificationKeys.reviewAt, null);
          if (n >= 2) {
            await s.set(NotificationKeys.reviewState, 'never');
            await s.set(Nudges.reviewDoneKey, '1');
          } else {
            await s.set(NotificationKeys.reviewLater, '${n + 1}');
            await s.set(NotificationKeys.reviewState, null);
            await _setDate(NotificationKeys.reviewUntil, plusDays(now, 30));
          }
        case NotificationActions.never:
          await s.set(NotificationKeys.reviewState, 'never');
          await s.set(Nudges.reviewDoneKey, '1');
        default:
          await s.set(NotificationKeys.reviewState, 'done');
          await s.set(Nudges.reviewDoneKey, '1');
          final dest = reviewDestination(platform: platformName);
          if (dest != null) {
            final r = await ExternalLauncher.openUrl(dest.url);
            if (!r.ok && dest.fallbackUrl != null) {
              await ExternalLauncher.openUrl(dest.fallbackUrl!);
            }
          }
      }
      return;
    }
    if (p == AppRoutes.donate) {
      switch (a) {
        case NotificationActions.later:
          await _setDate(NotificationKeys.donationAt, null);
          await _setDate(NotificationKeys.donationNext, plusDays(now, 30));
        case NotificationActions.never:
          await s.set(NotificationKeys.donationOff, '1');
          await s.set(Nudges.donationOffKey, '1');
        default:
          await _setDate(NotificationKeys.donationNext, plusDays(now, 182));
          if (kShowDonationLink) await ExternalLauncher.openUrl(kDonationUrl);
      }
      return;
    }
    if (a == NotificationActions.skipExam) {
      final id = AppRoutes.examId(p);
      if (id != null) {
        final done = await _idSet(NotificationKeys.outcomeDone)
          ..add(id);
        await s.set(NotificationKeys.outcomeDone, done.join(','));
      }
      return;
    }
    _s.openRoute.call(p);
  }

  // ------------------------------------------------- consenso e permessi

  /// Attiva le notifiche: chiede il permesso del sistema (Android 13+,
  /// iOS, macOS). Restituisce false se negato.
  Future<bool> enableNotifications() async {
    await _s.settings.set(NotificationKeys.asked, '1');
    var granted = false;
    try {
      await platform.init(_onTap);
      granted =
          await platform.permissionGranted() ||
          await platform.requestPermission();
    } catch (e) {
      debugPrint('Permesso delle notifiche non chiesto: $e');
    }
    await _s.settings.set(NotificationKeys.consent, granted ? '1' : '0');
    await refresh();
    return granted;
  }

  Future<void> disableNotifications() async {
    await _s.settings.set(NotificationKeys.consent, '0');
    await refresh();
  }

  /// Permesso del sistema concesso (false se non si può sapere).
  Future<bool> permissionGranted() async {
    try {
      return await platform.permissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// Notifica di prova, subito.
  Future<void> testNotification() async {
    await platform.init(_onTap);
    await platform.show(
      PlannedNotification(
        id: notificationId(NotificationType.exam, 'prova'),
        type: NotificationType.exam,
        at: DateTime.now(),
        title: 'Esame domani: notifica di prova',
        body: 'Così arriveranno gli avvisi delle prove.',
        payload: AppRoutes.exams,
      ),
    );
  }

  /// Avviso immediato sul registratore (es. «UniNotes continua a
  /// registrare» quando sul PC si chiude la finestra): conseguenza diretta
  /// di un gesto dell'utente, non dipende dalle preferenze delle notifiche
  /// pianificate.
  Future<void> recordingNotice(String title, String body) async {
    if (!notificationsSupported) return;
    try {
      await platform.init(_onTap);
      await platform.show(
        PlannedNotification(
          id: notificationId(NotificationType.recording, 'avviso'),
          type: NotificationType.recording,
          at: DateTime.now(),
          title: title,
          body: body,
          payload: AppRoutes.record,
        ),
      );
    } catch (e) {
      debugPrint('Avviso del registratore non mostrato: $e');
    }
  }

  /// «Collegamento interrotto» per [service] (OneDrive, Google Drive,
  /// calendario): al massimo una ogni 3 giorni per servizio.
  Future<void> linkBroken(String service, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    if (!notificationsSupported) return;
    final String key;
    try {
      final prefs = await NotificationPrefs.load(_s.settings);
      if (!prefs.consent || !prefs.links) return;
      key =
          '${NotificationKeys.linkWarnedPrefix}'
          '${service.toLowerCase().replaceAll(' ', '_')}';
      final last = await _date(key);
      if (last != null && t.difference(last) < const Duration(days: 3)) return;
    } catch (e) {
      // impostazioni non leggibili (chiamata anche dai listener dei servizi
      // cloud, che non aspettano errori): niente avviso questa volta
      debugPrint('Avviso non mostrato: $e');
      return;
    }
    final n = linkBrokenNotification(service, t);
    final quiet = _quietUntil;
    try {
      await platform.init(_onTap);
      if (quiet != null && quiet.isAfter(t)) {
        // sessione Focus: l'avviso arriva un minuto dopo la fine
        await platform.schedule(quietAware(n, quiet));
      } else {
        await platform.show(n);
      }
      await _setDate(key, t);
    } catch (e) {
      debugPrint('Avviso non mostrato: $e');
    }
  }

  /// Servizi con l'accesso già scaduto (si avvisa al passaggio, non a ogni
  /// aggiornamento del servizio).
  final Set<String> _expired = {};

  void _cloudChanged(CloudDriveService c) {
    if (!c.authExpired) {
      _expired.remove(c.serviceName);
    } else if (_expired.add(c.serviceName)) {
      unawaited(linkBroken(c.serviceName));
    }
  }

  /// Il collegamento al calendario è attivo (eventi dell'app da togliere
  /// con «Elimina tutti i dati», se lo studente lo vuole).
  Future<bool> calendarLinked() async {
    try {
      return await calendar.enabled();
    } catch (_) {
      return false;
    }
  }

  /// Toglie dal calendario gli eventi aggiunti dall'app (riconosciuti dal
  /// loro riferimento) e il calendario «UniNotes» se resta vuoto. Rilancia
  /// gli errori (permesso mancante, accesso scaduto, rete).
  Future<void> removeCalendarData() async {
    if (await calendar.enabled()) await calendar.removeAll(dropCalendar: true);
  }

  /// «Elimina tutti i dati»: via le notifiche pianificate e i dati dei
  /// widget; con [disconnect] anche l'accesso al calendario Outlook, con
  /// [calendarEvents] gli eventi dell'app dal calendario (errori ignorati:
  /// per vederli usare prima [removeCalendarData]).
  Future<void> eraseAll({
    bool calendarEvents = true,
    bool disconnect = true,
  }) async {
    _debounce?.cancel();
    final now = DateTime.now();
    for (final e in (await _dateMap(NotificationKeys.scheduled)).entries) {
      if (!e.value.isAfter(now)) continue;
      try {
        await platform.cancel(e.key);
      } catch (_) {}
    }
    if (calendarEvents) {
      try {
        if (await calendar.enabled()) await calendar.removeAll();
      } catch (_) {}
    }
    if (disconnect) {
      try {
        await outlook?.disconnect();
      } catch (_) {}
    }
    await widgets.update(widgetPayload(const [], now));
  }

  // ------------------------------------------------------------ calendario

  /// Attiva il calendario di sistema: permesso del sistema (telefono) o
  /// consenso al calendario dell'account Microsoft (Windows), poi la prima
  /// sincronizzazione. Rilancia gli errori dell'accesso.
  Future<CalendarStatus> enableCalendar() async {
    final b = calendar.backend;
    if (b == null) return CalendarStatus.off;
    if (!await b.hasAccess() && !await b.requestAccess()) {
      throw CalendarAccessException(
        'Permesso del calendario non concesso: puoi darlo dalle impostazioni '
        'del sistema.',
      );
    }
    await calendar.setEnabled(true);
    await refresh();
    return calendar.status();
  }

  /// Spegne il calendario e toglie gli eventi dell'app (le notifiche
  /// dell'app tornano per tutte le prove).
  Future<void> disableCalendar() async {
    try {
      await calendar.removeAll();
    } catch (e) {
      debugPrint('Eventi non tolti dal calendario: $e');
    }
    await calendar.setEnabled(false);
    await refresh();
  }

  /// Calendari tra cui scegliere (Impostazioni → Calendario): scrivibili,
  /// sincronizzati (o, su iPhone e Mac, anche solo sul dispositivo), senza
  /// quello «UniNotes» delle versioni precedenti.
  Future<List<CalendarChoice>> calendarChoices() async {
    final b = calendar.backend;
    if (b == null || !await b.hasAccess()) return const [];
    return [
      for (final c in await b.calendars())
        if (c.writable && !c.legacy && (c.synced || b.localCalendarsAllowed)) c,
    ];
  }

  /// Sceglie il calendario [id] (null = predefinito): gli eventi dell'app si
  /// spostano lì alla prossima sincronizzazione, subito.
  Future<CalendarStatus> chooseCalendar(String? id) async {
    await calendar.choose(id);
    await refresh();
    return calendar.status();
  }

  /// «Aggiorna da questo dispositivo»: il calendario dell'account lo scrive
  /// questo dispositivo invece di quello che lo faceva.
  Future<CalendarStatus> takeOverCalendar() async {
    await calendar.takeOver();
    await refresh();
    return calendar.status();
  }

  /// Avvisi delle prove all'ora esatta (Android, calendario interno).
  Future<bool> exactAlarmsAllowed() async {
    try {
      return await platform.exactAlarmsAllowed();
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestExactAlarms() async {
    try {
      final ok = await platform.requestExactAlarms();
      await refresh();
      return ok;
    } catch (_) {
      return false;
    }
  }
}

/// Prove del corso attuale lette per un aggiornamento.
class AgendaData {
  const AgendaData({
    required this.agenda,
    required this.pending,
    required this.courseNames,
  });
  final List<AgendaItem> agenda;

  /// Prove ancora da sostenere con una data (anche passate, per «Com'è
  /// andata?»).
  final List<Exam> pending;
  final Map<int, String> courseNames;
}

/// Avviso «Collegamento interrotto».
PlannedNotification linkBrokenNotification(String service, DateTime now) {
  final calendar = service == 'calendario';
  return PlannedNotification(
    id: notificationId(NotificationType.link, service.toLowerCase()),
    type: NotificationType.link,
    at: now,
    title: calendar
        ? 'Il calendario non si aggiorna'
        : '$service non è più collegato',
    body: calendar
        ? 'L\'accesso al calendario è scaduto o è stato revocato. Ricollegalo '
              'da Impostazioni, Calendario.'
        : 'L\'accesso è scaduto o è stato revocato. Ricollegati da '
              'Collegamenti per riprendere la sincronizzazione.',
    payload: calendar ? AppRoutes.settings : AppRoutes.links,
  );
}
