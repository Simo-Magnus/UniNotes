import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/feedback/feedback_service.dart';
import '../../core/feedback/motion.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_theme.dart';
import '../../models/attachment.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'attachments.dart';
import 'course_catalog.dart';
import 'focus/focus_cards.dart';
import 'focus/focus_screen.dart';
import 'focus/focus_service.dart';
import 'focus/focus_setup.dart';
import 'sessions_tab.dart';
import 'study_stats.dart';
import 'study_timer.dart';
import 'study_widgets.dart';

/// Come si conta il tempo in Sessioni Studio.
enum StudyClock { stopwatch, timer }

/// Posizione della scheda «Sessioni Studio» in Studio.
const kStudySessionsTab = 1;

/// «Sessione focus» da Argomenti (card dell'insegnamento, menu di un
/// modulo o di un argomento): Sessioni Studio con insegnamento, modulo e
/// argomento già scelti e il timer pronto. Con una sessione Focus in corso
/// apre quella; con il cronometro in corso non cambia la scelta.
Future<void> openStudySession(
  BuildContext context, {
  required int courseId,
  int? moduleId,
  int? topicId,
}) async {
  final s = context.read<AppServices>();
  if (s.focus.active) return openFocusScreen(context);
  AppFeedback.of(context).tap();
  final sw = StudyTimer.instance;
  if (sw.isActive) {
    StudySessionsTab.clock.value = StudyClock.stopwatch;
    showSnack(
      context,
      'Il cronometro è in corso: salvalo o eliminalo prima di avviare il '
      'timer.',
    );
  } else {
    sw.select(courseId: courseId, moduleId: moduleId, topicId: topicId);
    StudySessionsTab.clock.value = StudyClock.timer;
  }
  final tabs = DefaultTabController.maybeOf(context);
  if (tabs != null && tabs.length > kStudySessionsTab) {
    tabs.animateTo(kStudySessionsTab);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const StudySessionsPage()),
  );
}

/// Sessioni Studio in una pagina a sé (aperta da fuori della sezione).
class StudySessionsPage extends StatelessWidget {
  const StudySessionsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sessioni Studio')),
    body: RevisionBuilder<CourseCatalog>(
      load: CourseCatalog.load,
      builder: (context, catalog) => StudySessionsTab(catalog: catalog),
    ),
  );
}

/// Scheda «Sessioni Studio» (Focus e Sessioni insieme):
/// 1. che cosa si studia: insegnamento → modulo → argomento;
/// 2. le card con i file allegati alla scelta;
/// 3. cronometro (avvia/pausa, poi Salva o Elimina) o timer (come il Focus:
///    durata, pause automatiche, silenzio del sistema);
/// 4. «Obiettivo di oggi» e «Focus questa settimana»;
/// 5. lo storico delle sessioni.
class StudySessionsTab extends StatefulWidget {
  const StudySessionsTab({super.key, required this.catalog});
  final CourseCatalog catalog;

  /// Cronometro o timer (resta cambiando scheda).
  static final clock = ValueNotifier<StudyClock>(StudyClock.stopwatch);

  @override
  State<StudySessionsTab> createState() => _StudySessionsTabState();
}

class _StudySessionsTabState extends State<StudySessionsTab> {
  /// La prima apertura riprende l'ultimo collegamento del Focus.
  static bool _seeded = false;

  final StudyTimer _sw = StudyTimer.instance;
  late final FocusService _focus = context.read<AppServices>().focus;

  @override
  void initState() {
    super.initState();
    if (!_seeded && !_sw.isActive && _sw.courseId == null) {
      final l = _focus.link;
      if (l.courseId != null && widget.catalog.byId.containsKey(l.courseId)) {
        _sw.courseId = l.courseId;
        _sw.moduleId = l.moduleId;
        _sw.topicId = l.topicId;
        _sw.activity = l.activity;
      }
    }
    _seeded = true;
    _last = _snapshot();
    _sw.addListener(_changed);
    _focus.addListener(_changed);
    StudySessionsTab.clock.addListener(_changed);
  }

  @override
  void dispose() {
    _sw.removeListener(_changed);
    _focus.removeListener(_changed);
    StudySessionsTab.clock.removeListener(_changed);
    super.dispose();
  }

  /// Ciò che cambia la schermata (non il tempo che scorre: quello lo
  /// ridisegnano solo cronometro e anello).
  Object _snapshot() => (
    _sw.courseId,
    _sw.moduleId,
    _sw.topicId,
    _sw.activity,
    _sw.isActive,
    _focus.active,
    StudySessionsTab.clock.value,
  );
  late Object _last;

  void _changed() {
    final now = _snapshot();
    if (now == _last || !mounted) return;
    _last = now;
    setState(() {});
  }

  /// Collegamento della sessione Focus, con i nomi da mostrare (riquadro,
  /// notifica).
  Future<FocusLink> _link() async {
    final s = context.read<AppServices>();
    final id = _sw.courseId;
    final course = id == null ? null : widget.catalog.byId[id];
    String? detail;
    if (course != null) {
      if (_sw.topicId != null) {
        final topics = await s.study.topicsOfCourse(course.id!);
        detail = topics.where((t) => t.id == _sw.topicId).firstOrNull?.name;
      }
      if (detail == null && _sw.moduleId != null) {
        final modules = await s.study.modules(course.id!);
        detail = modules.where((m) => m.id == _sw.moduleId).firstOrNull?.name;
      }
    }
    return FocusLink(
      courseId: course?.id,
      moduleId: course == null ? null : _sw.moduleId,
      topicId: course == null ? null : _sw.topicId,
      activity: _sw.activity,
      label: course == null
          ? null
          : (detail == null ? course.name : '${course.name} · $detail'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        // con una sessione in corso la scelta resta quella della sessione
        final locked = _focus.active || _sw.isActive;
        final clock = _focus.active
            ? StudyClock.timer
            : (_sw.isActive ? StudyClock.stopwatch : StudySessionsTab.clock.value);
        final choice = _ChoiceCard(
          catalog: widget.catalog,
          timer: _sw,
          locked: locked,
        );
        final files = _FilesCards(
          catalog: widget.catalog,
          courseId: _sw.courseId,
          moduleId: _sw.moduleId,
          topicId: _sw.topicId,
        );
        final clockCard = _ClockCard(
          clock: clock,
          locked: locked,
          focusActive: _focus.active,
          link: _link,
          stopwatchBusy: _sw.isActive,
        );
        final goal = DailyGoalCard(onEditGoal: () => editDailyGoal(context));
        const week = FocusWeekCard();
        final history = SessionHistory(catalog: widget.catalog);
        if (context.isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: [choice, files, history],
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 440,
                child: ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: [clockCard, goal, week],
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [choice, files, clockCard, goal, week, history],
        );
      },
    );
  }
}

/// «Che cosa studi»: insegnamento, poi modulo, poi argomento; e l'attività.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.catalog,
    required this.timer,
    required this.locked,
  });

  final CourseCatalog catalog;
  final StudyTimer timer;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = timer.courseId;
    // solo un insegnamento presente nel menu (filtro università)
    final shown = catalog.courses.any((c) => c.id == id) ? id : null;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const CardHeader(
              title: 'Che cosa studi',
              icon: Icons.school_outlined,
              padding: EdgeInsets.fromLTRB(0, 12, 0, 8),
            ),
            CourseDropdown(
              catalog: catalog,
              value: shown,
              label: 'Insegnamento',
              noneLabel: 'Nessun insegnamento',
              onChanged: locked ? null : timer.setCourse,
            ),
            if (shown != null)
              _ModuleTopicFields(
                courseId: shown,
                moduleId: timer.moduleId,
                topicId: timer.topicId,
                onModule: locked ? null : timer.setModule,
                onTopic: locked ? null : timer.setTopic,
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ActivityType>(
              key: ValueKey('activity-${timer.activity.key}'),
              style: theme.textTheme.bodyLarge,
              initialValue: timer.activity,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Attività',
                isDense: true,
              ),
              items: [
                for (final a in ActivityType.values)
                  DropdownMenuItem(
                    value: a,
                    child: Row(
                      children: [
                        Icon(a.icon, size: 18),
                        const SizedBox(width: 8),
                        Text(a.label),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) timer.setActivity(v);
              },
            ),
            if (locked) ...[
              const SizedBox(height: 8),
              Text(
                'Sessione in corso: insegnamento, modulo e argomento restano '
                'quelli scelti all\'avvio.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Modulo («Tutto l'insegnamento» o uno) e, scelto il modulo, argomento
/// («Tutto il modulo» o uno).
class _ModuleTopicFields extends StatelessWidget {
  const _ModuleTopicFields({
    required this.courseId,
    required this.moduleId,
    required this.topicId,
    required this.onModule,
    required this.onTopic,
  });

  final int courseId;
  final int? moduleId;
  final int? topicId;
  final ValueChanged<int?>? onModule;
  final ValueChanged<int?>? onTopic;

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<(List<StudyModule>, List<Topic>)>(
      deps: [courseId],
      load: (s) async => (
        await s.study.modules(courseId),
        await s.study.topicsOfCourse(courseId),
      ),
      builder: (context, data) {
        final (modules, topics) = data;
        if (modules.isEmpty) return const SizedBox.shrink();
        final m = modules.any((x) => x.id == moduleId) ? moduleId : null;
        final shown = [
          for (final t in topics)
            if (m != null && t.moduleId == m) t,
        ];
        final tp = shown.any((x) => x.id == topicId) ? topicId : null;
        final style = Theme.of(context).textTheme.bodyLarge;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              key: ValueKey('session-module-$courseId-$m'),
              style: style,
              initialValue: m,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Modulo',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('Tutto l\'insegnamento'),
                ),
                for (final x in modules)
                  DropdownMenuItem<int?>(
                    value: x.id,
                    child: Text(x.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: onModule,
            ),
            if (m != null && shown.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                key: ValueKey('session-topic-$courseId-$m-$tp'),
                style: style,
                initialValue: tp,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Argomento',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('Tutto il modulo'),
                  ),
                  for (final x in shown)
                    DropdownMenuItem<int?>(
                      value: x.id,
                      child: Text(x.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: onTopic,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _FilesData {
  const _FilesData(this.modules, this.topics, this.attachments);
  final List<StudyModule> modules;
  final List<Topic> topics;
  final List<Attachment> attachments;
}

/// Una card per ogni modulo della scelta (o una sola per l'argomento) con
/// tutti i file allegati, in ordine di modulo e argomento.
class _FilesCards extends StatelessWidget {
  const _FilesCards({
    required this.catalog,
    required this.courseId,
    required this.moduleId,
    required this.topicId,
  });

  final CourseCatalog catalog;
  final int? courseId;
  final int? moduleId;
  final int? topicId;

  @override
  Widget build(BuildContext context) {
    final id = courseId;
    final course = id == null ? null : catalog.byId[id];
    if (id == null || course == null) return const SizedBox.shrink();
    return RevisionBuilder<_FilesData>(
      deps: [id],
      load: (s) async => _FilesData(
        await s.study.modules(id),
        await s.study.topicsOfCourse(id),
        await s.study.attachmentsOfCourse(id),
      ),
      builder: (context, d) {
        final topic = d.topics.where((t) => t.id == topicId).firstOrNull;
        final module = d.modules
            .where((m) => m.id == (topic?.moduleId ?? moduleId))
            .firstOrNull;
        List<Attachment> filesOf({int? module, int? topic}) => [
          for (final a in d.attachments)
            if ((topic != null && a.topicId == topic) ||
                (module != null && a.moduleId == module && a.topicId == null))
              a,
        ];
        final cards = <Widget>[];
        if (topic != null) {
          final files = filesOf(topic: topic.id);
          if (files.isNotEmpty) {
            cards.add(
              _FilesCard(
                course: course,
                title: topic.name,
                subtitle: module?.name,
                sections: [(null, files)],
              ),
            );
          }
        } else {
          for (final m in module == null ? d.modules : [module]) {
            final sections = <(String?, List<Attachment>)>[
              (null, filesOf(module: m.id)),
              for (final t in d.topics.where((t) => t.moduleId == m.id))
                (t.name, filesOf(topic: t.id)),
            ].where((x) => x.$2.isNotEmpty).toList();
            if (sections.isEmpty) continue;
            cards.add(
              _FilesCard(course: course, title: m.name, sections: sections),
            );
          }
        }
        if (cards.isEmpty) {
          final where = topic?.name ?? module?.name ?? course.name;
          return GlassCard(
            child: ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: Text('Nessun file per «$where»'),
              subtitle: const Text(
                'Aggiungili in Argomenti con «Aggiungi file» sotto ogni '
                'argomento.',
              ),
            ),
          );
        }
        return Column(children: cards);
      },
    );
  }
}

class _FilesCard extends StatelessWidget {
  const _FilesCard({
    required this.course,
    required this.title,
    required this.sections,
    this.subtitle,
  });

  final Course course;
  final String title;
  final String? subtitle;

  /// (nome dell'argomento o null per i file del modulo, file).
  final List<(String?, List<Attachment>)> sections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: title,
              icon: Icons.folder_open_outlined,
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(subtitle!, style: theme.textTheme.bodySmall),
              ),
            for (final (name, files) in sections) ...[
              if (name != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                  child: Text(name, style: theme.textTheme.labelLarge),
                ),
              AttachmentList(course: course, attachments: files),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cronometro o timer.
class _ClockCard extends StatelessWidget {
  const _ClockCard({
    required this.clock,
    required this.locked,
    required this.focusActive,
    required this.stopwatchBusy,
    required this.link,
  });

  final StudyClock clock;
  final bool locked;
  final bool focusActive;
  final bool stopwatchBusy;
  final Future<FocusLink> Function() link;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<StudyClock>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: StudyClock.stopwatch,
                  icon: Icon(Icons.timer_outlined),
                  label: Text('Cronometro'),
                ),
                ButtonSegment(
                  value: StudyClock.timer,
                  icon: Icon(Icons.hourglass_bottom_rounded),
                  label: Text('Timer'),
                ),
              ],
              selected: {clock},
              onSelectionChanged: locked
                  ? null
                  : (v) {
                      AppFeedback.of(context).toggle();
                      StudySessionsTab.clock.value = v.first;
                    },
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: switch (clock) {
                StudyClock.stopwatch => const _StopwatchPanel(
                  key: ValueKey('stopwatch'),
                ),
                StudyClock.timer when focusActive => const FocusRunningPanel(
                  key: ValueKey('focus-running'),
                ),
                StudyClock.timer => FocusTimerSetup(
                  key: const ValueKey('focus-setup'),
                  link: link,
                  enabled: !stopwatchBusy,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Cronometro: tempo grande, Avvia/Pausa; sotto Elimina e Salva.
class _StopwatchPanel extends StatelessWidget {
  const _StopwatchPanel({super.key});

  Future<void> _save(BuildContext context) async {
    final timer = StudyTimer.instance;
    final session = timer.stop();
    if (session == null) {
      showSnack(context, 'Sessione inferiore a un minuto: non salvata.');
      return;
    }
    final s = context.read<AppServices>();
    await s.study.insertSession(session);
    s.revision.bump();
    if (context.mounted) {
      showSuccessSnack(
        context,
        'Sessione salvata: ${formatMinutes(session.durationMinutes)}',
      );
    }
  }

  Future<void> _discard(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      'Eliminare il tempo cronometrato?',
      'La sessione non verrà salvata.',
    );
    if (ok) StudyTimer.instance.reset();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: StudyTimer.instance,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final timer = StudyTimer.instance;
    final status = !timer.isActive
        ? 'Pronto'
        : timer.isRunning
        ? 'In corso'
        : 'In pausa';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          formatElapsed(timer.elapsed),
          textAlign: TextAlign.center,
          style: theme.textTheme.displayMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: timer.isPaused ? theme.colorScheme.outline : null,
          ),
        ),
        Text(
          status,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 16),
        Pressable(
          feedback: FeedbackEvent.tap,
          child: timer.isRunning
              ? OutlinedButton.icon(
                  key: const Key('stopwatch-pause'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: timer.pause,
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('Pausa'),
                )
              : FilledButton.icon(
                  key: const Key('stopwatch-start'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: timer.start,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(timer.isActive ? 'Riprendi' : 'Avvia'),
                ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: const Key('stopwatch-delete'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: timer.isActive ? () => _discard(context) : null,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Elimina'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                key: const Key('stopwatch-save'),
                onPressed: timer.isActive ? () => _save(context) : null,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Salva'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
