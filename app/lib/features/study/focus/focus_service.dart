import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:intl/intl.dart';

import '../../../core/constants/enums.dart';
import '../../../core/feedback/feedback_service.dart';
import '../../../core/reminders/notification_plan.dart';
import '../../../core/services/app_services.dart';
import '../../../models/study.dart';
import 'focus_goal.dart';
import 'focus_plan.dart';
import 'focus_system.dart';
import 'focus_timer.dart';

/// Chiavi delle impostazioni della modalità Focus.
class FocusKeys {
  /// Ultime impostazioni usate (JSON di [FocusSettings]).
  static const settings = 'focus_settings';

  /// Obiettivo giornaliero in minuti.
  static const goal = 'focus_daily_goal';

  /// Silenzio del sistema durante Focus: sempre | mai (chiedi = non
  /// ancora scelto, vedi [DndChoice]).
  static const dnd = 'focus_system_dnd';

  /// Sessione in corso (JSON di [FocusTimer.toJson]): si riprende dopo una
  /// chiusura dell'app.
  static const running = 'focus_running';

  /// Ultimo collegamento scelto (insegnamento, modulo, argomento).
  static const link = 'focus_link';

  /// Permesso delle notifiche già chiesto per il Focus.
  static const notifAsked = 'focus_notif_asked';
}

/// A che cosa si collega la sessione: insegnamento, modulo, argomento di
/// Studio e attività. [label] è il nome da mostrare (riquadro, notifica).
class FocusLink {
  const FocusLink({
    this.courseId,
    this.moduleId,
    this.topicId,
    this.activity = ActivityType.theory,
    this.label,
  });

  final int? courseId;
  final int? moduleId;
  final int? topicId;
  final ActivityType activity;
  final String? label;

  Map<String, Object?> toJson() => {
    'corso': ?courseId,
    'modulo': ?moduleId,
    'argomento': ?topicId,
    'attivita': activity.key,
    'nome': ?label,
  };

  static FocusLink fromJson(Object? j) {
    if (j is! Map) return const FocusLink();
    int? id(Object? v) => v is int ? v : null;
    return FocusLink(
      courseId: id(j['corso']),
      moduleId: id(j['modulo']),
      topicId: id(j['argomento']),
      activity: ActivityType.fromKey(
        j['attivita'] is String ? j['attivita'] as String : null,
      ),
      label: j['nome'] is String ? j['nome'] as String : null,
    );
  }
}

/// Modalità Focus dell'app: la sessione (timer), il collegamento allo
/// Studio, l'obiettivo giornaliero, suoni e vibrazioni, notifiche e
/// «Non disturbare». Vive per tutta l'app: la sessione continua uscendo
/// dalla schermata (riquadro sopra le schermate, come il registratore).
class FocusService extends ChangeNotifier {
  FocusService(this._s, {FocusTimer? timer, FocusSystem? system})
    : timer = timer ?? FocusTimer(),
      system = system ?? const FocusSystem() {
    this.timer.addListener(_timerChanged);
    _events = this.timer.events.listen(_onEvent);
    _apple = FocusSystem.appleResults.listen(_appleResult);
  }

  final AppServices _s;
  final FocusTimer timer;
  final FocusSystem system;
  StreamSubscription<FocusEventKind>? _events;
  StreamSubscription<QuietFailure?>? _apple;
  AppLifecycleListener? _lifecycle;

  FocusSettings settings = const FocusSettings();
  FocusLink link = const FocusLink();
  int dailyGoal = kDefaultDailyGoal;
  DndChoice dnd = DndChoice.ask;

  /// Collegamento della sessione in corso.
  FocusLink current = const FocusLink();

  /// Silenzio del sistema attivo (Non disturbare, sessione di Windows).
  bool systemQuiet = false;

  /// Perché il silenzio del sistema chiesto per la sessione non è attivo
  /// (null = attivo o non chiesto).
  QuietFailure? quietFailure;

  /// Windows ha rifiutato la sessione di concentrazione del sistema.
  bool get windowsFailed =>
      quietFailure != null && system.kind == FocusSystemKind.windowsFocus;

  /// Ultima sessione salvata (riepilogo nella schermata o avviso).
  final ValueNotifier<FocusResult?> completed = ValueNotifier(null);

  /// Errore del salvataggio dell'ultima sessione finita (null = salvata o
  /// non da salvare): il riepilogo lo dice invece di tacere.
  String? saveError;

  Future<void>? _loading;
  bool _inBackground = false;
  final Set<int> _alertIds = {};

  bool get active => timer.active;

  /// La schermata della sessione è aperta (niente riquadro sopra).
  bool _screenVisible = false;
  bool get screenVisible => _screenVisible;
  set screenVisible(bool v) {
    if (v == _screenVisible) return;
    _screenVisible = v;
    // Si cambia da initState e dispose della schermata Focus, cioè a metà
    // della costruzione dei widget: avvisare subito le card sotto (Home,
    // Sessioni Studio) farebbe fallire il fotogramma («setState() called
    // during build»). Si avvisa a fotogramma finito, chiedendone un altro.
    final binding = _binding;
    if (binding != null &&
        binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding
        ..addPostFrameCallback((_) => notifyListeners())
        ..scheduleFrame();
      return;
    }
    notifyListeners();
  }

  static SchedulerBinding? get _binding {
    try {
      return SchedulerBinding.instance;
    } catch (_) {
      return null; // test senza binding
    }
  }

  /// Fino a quando le notifiche non urgenti dell'app aspettano (fine
  /// prevista della sessione); null senza sessione.
  DateTime? get quietUntil {
    if (!timer.active || timer.finished) return null;
    return timer.now.add(timer.position.totalRemaining);
  }

  void _timerChanged() => notifyListeners();

  // ------------------------------------------------------------ dati

  /// Impostazioni e sessione rimasta aperta da una chiusura dell'app (una
  /// volta; chi arriva mentre si legge aspetta la stessa lettura).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final st = _s.settings;
    try {
      settings = FocusSettings.fromJson(
        _decode(await st.get(FocusKeys.settings)),
      );
      link = FocusLink.fromJson(_decode(await st.get(FocusKeys.link)));
      dailyGoal = parseDailyGoal(await st.get(FocusKeys.goal));
      dnd = DndChoice.fromKey(await st.get(FocusKeys.dnd));
      final running = _decode(await st.get(FocusKeys.running));
      if (running is Map && timer.restore(running['timer'])) {
        current = FocusLink.fromJson(running['collegamento']);
        systemQuiet = running['silenzio'] == true;
        _listenLifecycle();
        timer.check();
        // notifica col tempo restante di nuovo al suo posto
        unawaited(_updateNotifications());
        // il silenzio del sistema può essere finito ad app chiusa
        unawaited(_checkQuiet());
      }
    } catch (e) {
      debugPrint('Impostazioni Focus non lette: $e');
    }
    notifyListeners();
  }

  static Object? _decode(String? v) {
    if (v == null || v.isEmpty) return null;
    try {
      return jsonDecode(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> setDailyGoal(int minutes) async {
    dailyGoal = minutes;
    notifyListeners();
    await _s.settings.set(FocusKeys.goal, '$minutes');
  }

  /// Il silenzio del sistema si attiva all'avvio delle sessioni.
  bool get systemQuietEnabled => systemQuietOn(system.kind, dnd);

  Future<void> setDnd(DndChoice c) async {
    dnd = c;
    notifyListeners();
    await _s.settings.set(FocusKeys.dnd, c.key);
  }

  Future<void> _persist() async {
    final j = timer.toJson();
    try {
      await _s.settings.set(
        FocusKeys.running,
        j == null
            ? null
            : jsonEncode({
                'timer': j,
                'collegamento': current.toJson(),
                'silenzio': systemQuiet,
              }),
      );
    } catch (e) {
      debugPrint('Sessione Focus non salvata sul disco: $e');
    }
  }

  // ------------------------------------------------------------ sessione

  /// Avvia una sessione con [s] collegata a [to]. Con [systemDnd] prova a
  /// silenziare anche il sistema.
  Future<void> start(
    FocusSettings s,
    FocusLink to, {
    bool systemDnd = false,
  }) async {
    // prima la sessione rimasta aperta da una chiusura dell'app (all'avvio
    // si legge dopo i promemoria, anche qualche secondo dopo): una sessione
    // nuova avviata prima la sovrascriverebbe sul disco e la lettura
    // arrivata dopo rimetterebbe il cronometro di quella vecchia
    await load();
    if (timer.active) return;
    settings = s;
    link = to;
    current = to;
    completed.value = null;
    quietFailure = null;
    systemQuiet = false;
    timer.start(s);
    _listenLifecycle();
    unawaited(_s.feedback.play(FeedbackEvent.focusStart));
    final until = timer.endsAt;
    if (systemDnd && until != null) {
      final r = await system.enable(until);
      systemQuiet = r.on;
      quietFailure = r.failure;
    }
    notifyListeners();
    await _s.settings.set(FocusKeys.settings, jsonEncode(s.toJson()));
    await _s.settings.set(FocusKeys.link, jsonEncode(to.toJson()));
    await _persist();
    await _updateNotifications();
    _s.revision.bump();
  }

  void pause() => timer.pause();
  void resume() => timer.resume();
  void togglePause() => timer.togglePause();
  bool skipBreak() => timer.skipBreak();

  /// Ferma la sessione e salva il tempo di concentrazione (se almeno un
  /// minuto) come sessione di studio.
  Future<StudySession?> finish() async {
    final r = timer.stop();
    if (r == null) {
      await _cleanup();
      return null;
    }
    saveError = null;
    StudySession? saved;
    if (r.focusMinutes >= 1) {
      final c = current;
      saved = StudySession(
        courseId: c.courseId,
        moduleId: c.moduleId,
        topicId: c.topicId,
        start: r.start,
        end: r.end,
        durationMinutes: r.focusMinutes,
        activityType: c.activity,
        focus: true,
        plannedMinutes: r.plannedMinutes,
      );
      // prima si salva, poi si tolgono avvisi e silenzio del sistema (che
      // passano dalla piattaforma e possono tardare): un'app chiusa a metà
      // non perde il tempo
      try {
        await _s.study.insertSession(saved);
      } catch (e) {
        debugPrint('Sessione Focus non salvata: $e');
        saveError = '$e';
        saved = null;
      }
    }
    await _cleanup();
    completed.value = r;
    _s.revision.bump();
    return saved;
  }

  /// Scarta la sessione senza salvarla.
  Future<void> discard() async {
    timer.discard();
    completed.value = null;
    await _cleanup();
    _s.revision.bump();
  }

  Future<void> _cleanup() async {
    await _cancelAlerts();
    await _cancelStatus();
    if (systemQuiet) {
      systemQuiet = false;
      await system.disable();
    }
    try {
      await _s.settings.set(FocusKeys.running, null);
    } catch (_) {}
    notifyListeners();
  }

  void _onEvent(FocusEventKind k) {
    switch (k) {
      case FocusEventKind.breakStarted:
        unawaited(_s.feedback.play(FeedbackEvent.breakStart));
      case FocusEventKind.breakEnded || FocusEventKind.breakSkipped:
        unawaited(_s.feedback.play(FeedbackEvent.breakEnd));
      case FocusEventKind.finished:
        unawaited(_s.feedback.play(FeedbackEvent.focusEnd));
        unawaited(finish());
        return;
      case FocusEventKind.resumed:
        // nuova fine prevista (la pausa allunga la sessione); su iOS/macOS
        // il comando non si riavvia: porterebbe ogni volta nell'app Comandi
        final until = timer.endsAt;
        if (systemQuiet &&
            until != null &&
            system.kind != FocusSystemKind.appleFocus) {
          unawaited(_enableAgain(until));
        }
      default:
        break;
    }
    if (k == FocusEventKind.started || k == FocusEventKind.stopped) return;
    unawaited(_persist());
    unawaited(_updateNotifications());
  }

  /// Dopo una pausa: silenzio fino alla nuova fine; se il sistema non lo
  /// riattiva la sessione lo dice.
  Future<void> _enableAgain(DateTime until) async {
    final r = await system.enable(until);
    if (r.on || !timer.active) return;
    systemQuiet = false;
    quietFailure = r.failure;
    notifyListeners();
    await _persist();
  }

  /// iOS/macOS: esito del comando che attiva il Non disturbare.
  void _appleResult(QuietFailure? f) {
    if (!timer.active || system.kind != FocusSystemKind.appleFocus) return;
    systemQuiet = f == null;
    quietFailure = f;
    notifyListeners();
    unawaited(_persist());
  }

  /// Tornando nell'app: il silenzio è ancora acceso? (l'utente può averlo
  /// spento dalla tendina o dal centro notifiche).
  Future<void> _checkQuiet() async {
    if (!systemQuiet || !timer.active) return;
    if (await system.isActive() != false || !timer.active) return;
    systemQuiet = false;
    quietFailure = QuietFailure.turnedOff;
    notifyListeners();
    await _persist();
  }

  // ------------------------------------------------------------ notifiche

  void _listenLifecycle() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(
        onHide: () {
          _inBackground = true;
          unawaited(_updateNotifications());
        },
        onShow: () {
          _inBackground = false;
          timer.check();
          unawaited(_updateNotifications());
          unawaited(_checkQuiet());
        },
      );
    } catch (_) {}
  }

  bool get _notificationsReady =>
      _s.remindersStarted && _s.reminders.notificationsSupported;

  static final _hm = DateFormat.Hm('it_IT');

  int get _statusId => notificationId(NotificationType.focus, 'stato');

  /// Notifica fissa con il tempo restante (Android) e, con l'app in
  /// background, gli avvisi di inizio e fine pausa e di fine sessione.
  Future<void> _updateNotifications() async {
    if (!_notificationsReady) return;
    if (!timer.active || timer.finished) {
      await _cancelStatus();
      await _cancelAlerts();
      return;
    }
    if (Platform.isAndroid) await _showStatus();
    if (_inBackground && timer.running) {
      await _scheduleAlerts();
    } else {
      await _cancelAlerts();
    }
  }

  Future<void> _showStatus() async {
    final p = timer.position;
    final rest = p.phase == FocusPhase.rest;
    final name = current.label ?? 'Studio';
    final now = timer.now;
    final segmentEnd = now.add(p.segmentRemaining);
    final String title;
    final String body;
    if (!timer.running) {
      title = 'Focus in pausa';
      body = '$name · ${formatFocusLength(p.totalRemaining.inMinutes)} rimasti';
    } else if (rest) {
      title = 'Pausa fino alle ${_hm.format(segmentEnd)}';
      body = '$name · poi si riparte';
    } else {
      final last = p.breaksLeft == 0;
      title = 'Focus: $name';
      body = last
          ? 'Fine alle ${_hm.format(segmentEnd)}'
          : 'Pausa alle ${_hm.format(segmentEnd)}';
    }
    try {
      await _s.reminders.platform.show(
        PlannedNotification(
          id: _statusId,
          type: NotificationType.focus,
          at: now,
          title: title,
          body: body,
          payload: AppRoutes.focus,
          ongoing: true,
          silent: true,
          countdownTo: timer.running ? segmentEnd : null,
        ),
      );
    } catch (e) {
      debugPrint('Notifica Focus non mostrata: $e');
    }
  }

  Future<void> _cancelStatus() async {
    if (!_notificationsReady) return;
    try {
      await _s.reminders.platform.cancel(_statusId);
    } catch (_) {}
  }

  Future<void> _scheduleAlerts() async {
    await _cancelAlerts();
    final plan = timer.plan;
    final t = timer.planElapsed;
    final now = timer.now;
    for (final (i, end) in boundariesAfter(plan, t)) {
      final at = now.add(end - t);
      final last = i == plan.length - 1;
      final next = last ? null : plan[i + 1];
      final String title;
      final String body;
      if (last) {
        title = 'Sessione Focus completata';
        body =
            '${formatFocusLength(planFocusMinutes(plan))} di concentrazione. '
            'Il tempo è già nelle statistiche.';
      } else if (next!.phase == FocusPhase.rest) {
        title = 'È il momento di una pausa';
        body = '${next.length.inMinutes} minuti, poi si riparte.';
      } else {
        title = 'Fine della pausa';
        body =
            'Si riparte: ${formatFocusLength(next.length.inMinutes)} di '
            'concentrazione.';
      }
      final id = notificationId(NotificationType.focusAlert, 'confine:$i');
      try {
        await _s.reminders.platform.schedule(
          PlannedNotification(
            id: id,
            type: NotificationType.focusAlert,
            at: at,
            title: title,
            body: body,
            payload: AppRoutes.focus,
          ),
        );
        _alertIds.add(id);
      } catch (e) {
        debugPrint('Avviso Focus non pianificato: $e');
      }
    }
  }

  Future<void> _cancelAlerts() async {
    if (_alertIds.isEmpty || !_notificationsReady) return;
    for (final id in _alertIds.toList()) {
      try {
        await _s.reminders.platform.cancel(id);
      } catch (_) {}
    }
    _alertIds.clear();
  }

  /// Telefono: chiede una volta il permesso delle notifiche del sistema
  /// (per il tempo restante e la fine della sessione).
  Future<void> askNotificationPermissionOnce() async {
    if (!_notificationsReady || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    if (await _s.settings.get(FocusKeys.notifAsked) == '1') return;
    await _s.settings.set(FocusKeys.notifAsked, '1');
    try {
      final p = _s.reminders.platform;
      if (!await p.permissionGranted()) await p.requestPermission();
    } catch (_) {}
  }

  @override
  void dispose() {
    _events?.cancel();
    _apple?.cancel();
    _lifecycle?.dispose();
    timer.removeListener(_timerChanged);
    super.dispose();
  }
}
