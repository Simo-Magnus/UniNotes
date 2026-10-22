import 'package:flutter/material.dart';

import '../../../core/constants/enums.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/attachment.dart';
import '../../../models/course.dart';
import '../../../models/study.dart';
import '../../../widgets/glass.dart';
import '../../../widgets/math_text.dart';
import '../attachments.dart';
import '../study_widgets.dart';
import 'focus_service.dart';

/// Che cosa si studia nella sessione Focus in corso (insegnamento, modulo,
/// argomento) e i file da aprire dalla schermata della sessione.

/// Gruppo di file nel pannello della sessione Focus.
class FocusFileSection {
  const FocusFileSection(this.title, this.files, {this.current = false});
  final String title;
  final List<Attachment> files;

  /// Argomento della sessione: in cima e segnato.
  final bool current;
}

/// File da mostrare durante la sessione:
/// - argomento scelto: prima i suoi file, poi il materiale del modulo e i
///   file degli altri argomenti del modulo;
/// - modulo scelto: il materiale del modulo, poi un gruppo per argomento;
/// - tutto l'insegnamento: un gruppo per modulo (file del modulo e dei
///   suoi argomenti).
/// Gruppi vuoti esclusi; moduli e argomenti nell'ordine di Studio.
List<FocusFileSection> focusFileSections({
  required List<StudyModule> modules,
  required List<Topic> topics,
  required List<Attachment> attachments,
  int? moduleId,
  int? topicId,
}) {
  final topic = topics.where((t) => t.id == topicId).firstOrNull;
  final module = modules
      .where((m) => m.id == (topic?.moduleId ?? moduleId))
      .firstOrNull;
  List<Attachment> ofTopic(int? id) => [
    for (final a in attachments)
      if (a.topicId == id) a,
  ];
  List<Attachment> ofModule(int? id) => [
    for (final a in attachments)
      if (a.moduleId == id && a.topicId == null) a,
  ];
  final out = <FocusFileSection>[];
  if (module == null) {
    for (final m in modules) {
      final files = [
        ...ofModule(m.id),
        for (final t in topics)
          if (t.moduleId == m.id) ...ofTopic(t.id),
      ];
      if (files.isNotEmpty) out.add(FocusFileSection(m.name, files));
    }
    return out;
  }
  if (topic != null) {
    final files = ofTopic(topic.id);
    if (files.isNotEmpty) {
      out.add(FocusFileSection(topic.name, files, current: true));
    }
  }
  final own = ofModule(module.id);
  if (own.isNotEmpty) out.add(FocusFileSection('Materiale del modulo', own));
  for (final t in topics) {
    if (t.moduleId != module.id || t.id == topic?.id) continue;
    final files = ofTopic(t.id);
    if (files.isNotEmpty) out.add(FocusFileSection(t.name, files));
  }
  return out;
}

/// Insegnamento, modulo e argomento della sessione con i file.
class FocusContext {
  const FocusContext({
    this.course,
    this.module,
    this.topic,
    this.sections = const [],
  });

  final Course? course;
  final StudyModule? module;
  final Topic? topic;
  final List<FocusFileSection> sections;

  /// Sessione su tutto l'insegnamento (nessun modulo scelto).
  bool get wholeCourse => module == null;

  static Future<FocusContext> load(AppServices s, FocusLink link) async {
    final id = link.courseId;
    if (id == null) return const FocusContext();
    final course = await s.courses.byId(id);
    if (course == null) return const FocusContext();
    final modules = await s.study.modules(id);
    final topics = await s.study.topicsOfCourse(id);
    final attachments = await s.study.attachmentsOfCourse(id);
    final topic = topics.where((t) => t.id == link.topicId).firstOrNull;
    final module = modules
        .where((m) => m.id == (topic?.moduleId ?? link.moduleId))
        .firstOrNull;
    return FocusContext(
      course: course,
      module: module,
      topic: topic,
      sections: focusFileSections(
        modules: modules,
        topics: topics,
        attachments: attachments,
        moduleId: module?.id,
        topicId: topic?.id,
      ),
    );
  }
}

/// Intestazione della schermata Focus, sopra il timer: insegnamento (solo
/// il nome, piccolo), modulo (grande), argomento e attività con la sua
/// icona. Senza modulo il titolo è l'insegnamento; senza insegnamento il
/// nome salvato con la sessione.
class FocusContextHeader extends StatelessWidget {
  const FocusContextHeader({super.key, required this.ctx, required this.link});

  /// null mentre si carica.
  final FocusContext? ctx;
  final FocusLink link;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final course = ctx?.course;
    final module = ctx?.module;
    final topic = ctx?.topic;
    final overline = module == null ? null : course?.label;
    final title =
        module?.name ?? course?.label ?? link.label ?? 'Sessione Focus';
    return Semantics(
      container: true,
      child: Column(
        key: const Key('focus-context'),
        children: [
          if (overline != null)
            Text(
              overline,
              key: const Key('focus-course-name'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: t.textSecondary,
                letterSpacing: 0.3,
              ),
            ),
          MathText(
            title,
            key: const Key('focus-title'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              color: t.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (topic != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: MathText(
                    topic.name,
                    key: const Key('focus-topic-name'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: t.textSecondary,
                    ),
                  ),
                ),
              _ActivityChip(activity: link.activity),
            ],
          ),
        ],
      ),
    );
  }
}

/// Attività della sessione: la sua icona e il nome in una pastiglia.
class _ActivityChip extends StatelessWidget {
  const _ActivityChip({required this.activity});
  final ActivityType activity;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      key: const Key('focus-activity'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: t.innerCard,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: t.innerBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(activity.icon, size: 16, color: t.cyanSoft),
          const SizedBox(width: 6),
          Text(
            activity.label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: t.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Pannello dei file della sessione: un tocco apre il file nel lettore
/// sopra la schermata, il timer continua (riquadro della sessione sopra il
/// file). Solo apertura: tipi e rimozione restano in Argomenti.
class FocusFilesPanel extends StatelessWidget {
  const FocusFilesPanel({
    super.key,
    required this.ctx,
    required this.onOpen,
    this.margin = EdgeInsets.zero,
  });

  final FocusContext ctx;
  final void Function(Course course, Attachment a) onOpen;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final course = ctx.course;
    if (course == null) return const SizedBox.shrink();
    final t = context.tokens;
    final theme = Theme.of(context);
    final where = ctx.topic?.name ?? ctx.module?.name ?? course.label;
    return GlassCard(
      key: const Key('focus-files'),
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: ctx.wholeCourse
                  ? 'File dell\'insegnamento'
                  : 'File del modulo',
              icon: Icons.folder_open_outlined,
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
            ),
            if (ctx.sections.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.folder_off_outlined, color: t.textMuted),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Nessun file per «$where». Aggiungili in Studio → '
                        'Argomenti con «Aggiungi file».',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: t.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            for (final sec in ctx.sections) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: sec.title),
                      if (sec.current)
                        TextSpan(
                          text: ' · argomento della sessione',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: t.textMuted,
                          ),
                        ),
                    ],
                  ),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: t.textPrimary,
                  ),
                ),
              ),
              AttachmentList(
                course: course,
                attachments: sec.files,
                editable: false,
                onOpen: (a) => onOpen(course, a),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
