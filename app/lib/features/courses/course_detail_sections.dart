import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/study.dart';
import '../../utils/grade_math.dart';
import '../../widgets/glass.dart';
import '../../widgets/math_text.dart';
import '../exams/exam_form.dart';
import '../exams/exam_tile.dart';
import '../exams/exam_ui.dart';
import 'course_ui.dart';

/// Contenitore a scheda per le sezioni del dettaglio corso.
class DetailSection extends StatelessWidget {
  const DetailSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(title: title, icon: icon, trailing: trailing),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Testo lungo con "Mostra tutto" se supera poche righe.
class ExpandableText extends StatefulWidget {
  const ExpandableText(this.text, {super.key, this.maxLines = 4});
  final String text;
  final int maxLines;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final long =
        widget.text.length > 280 ||
        '\n'.allMatches(widget.text).length >= widget.maxLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // programmi e descrizioni: le formule $…$ si vedono disegnate
        MathText(
          widget.text,
          maxLines: _expanded ? null : widget.maxLines,
          overflow: _expanded ? null : TextOverflow.fade,
        ),
        if (long)
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? 'Mostra meno' : 'Mostra tutto'),
          ),
      ],
    );
  }
}

/// Info: docente, periodo, CFU, ore, difficoltà, studio stimato, modalità ed esame.
class CourseInfoSection extends StatelessWidget {
  const CourseInfoSection({super.key, required this.course, this.degreeName});
  final Course course;
  final String? degreeName;

  @override
  Widget build(BuildContext context) {
    final c = course;
    return DetailSection(
      title: 'Informazioni',
      icon: Icons.info_outline,
      children: [
        InfoRow.text(
          icon: Icons.person_outline,
          label: 'Docente',
          value: c.teacher,
        ),
        if (degreeName != null)
          InfoRow.text(
            icon: Icons.account_balance_outlined,
            label: 'Corso di laurea',
            value: degreeName,
          ),
        InfoRow.text(
          icon: Icons.date_range_outlined,
          label: 'Anno e periodo',
          value: '${yearLabel(c.year)} · ${semesterLabel(c.semester)}',
        ),
        InfoRow.text(
          icon: Icons.school_outlined,
          label: 'CFU',
          value: c.cfu == null ? null : formatNumber(c.cfu),
        ),
        InfoRow.text(
          icon: Icons.co_present_outlined,
          label: 'Ore di lezione totali',
          value: c.lectureHours == null
              ? null
              : '${formatNumber(c.lectureHours)} ore',
        ),
        InfoRow(
          icon: Icons.whatshot_outlined,
          label: 'Difficoltà',
          child: c.difficulty == null
              ? const Text('—')
              : DifficultyStars(c.difficulty!),
        ),
        InfoRow.text(
          icon: Icons.rule_outlined,
          label: 'Modalità d\'esame',
          value: examModeLabel(c.examMode),
        ),
        InfoRow(
          icon: Icons.account_tree_outlined,
          label: 'Struttura dell\'esame',
          child: c.examStructure == null
              ? const Text('—')
              : ExpandableText(c.examStructure!),
        ),
        InfoRow(
          icon: Icons.record_voice_over_outlined,
          label: 'Orale/Scritto (facoltativo)',
          child: c.optionalOralInfo == null
              ? const Text('—')
              : ExpandableText(c.optionalOralInfo!),
        ),
        InfoRow(
          icon: Icons.topic_outlined,
          label: 'Descrizione e argomenti',
          child: c.description == null
              ? const Text('—')
              : ExpandableText(c.description!, maxLines: 6),
        ),
      ],
    );
  }
}

/// Prove in itinere ed esame finale del corso.
class CourseExamsSection extends StatelessWidget {
  const CourseExamsSection({
    super.key,
    required this.course,
    required this.exams,
    required this.onOpenExam,
  });
  final Course course;
  final List<Exam> exams;
  final ValueChanged<Exam> onOpenExam;

  @override
  Widget build(BuildContext context) {
    final midterms = exams.where((e) => e.kind == ExamKind.midterm).toList();
    final finals = exams.where((e) => e.kind == ExamKind.finalExam).toList();
    final avg = midtermAverage(exams);
    final theme = Theme.of(context);

    Widget group(String title, List<Exam> list, String empty) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(empty),
          )
        else
          for (final e in list)
            _ExamWithDetails(
              exam: e,
              course: course,
              onTap: () => onOpenExam(e),
            ),
      ],
    );

    return DetailSection(
      title: 'Prove ed esame',
      icon: Icons.assignment_outlined,
      trailing: PopupMenuButton<ExamKind>(
        tooltip: 'Aggiungi',
        icon: const Icon(Icons.add),
        onSelected: (k) => openExamForm(context, courseId: course.id, kind: k),
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: ExamKind.midterm,
            child: Text('Nuova prova in itinere o esonero'),
          ),
          PopupMenuItem(
            value: ExamKind.finalExam,
            child: Text('Nuovo esame finale'),
          ),
        ],
      ),
      children: [
        group(
          avg == null
              ? 'Prove in itinere e esoneri'
              : 'Prove in itinere e esoneri · media ${formatNumber(avg, decimals: 2)}',
          midterms,
          'Nessuna prova in itinere.',
        ),
        group('Esame finale', finals, 'Nessun appello registrato.'),
      ],
    );
  }
}

class _ExamWithDetails extends StatelessWidget {
  const _ExamWithDetails({
    required this.exam,
    required this.course,
    required this.onTap,
  });
  final Exam exam;
  final Course course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasExtra = exam.topics != null || exam.studyMaterials.isNotEmpty;
    final tile = ExamTile(
      exam: exam,
      course: course,
      showCourse: false,
      onTap: onTap,
    );
    if (!hasExtra) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Padding(
          padding: const EdgeInsets.only(left: 56),
          child: ExpansionTile(
            dense: true,
            title: const Text('Argomenti e materiali da studiare'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (exam.topics != null) ...[
                Text(
                  'Argomenti',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                SelectableText(exam.topics!),
                const SizedBox(height: 8),
              ],
              if (exam.studyMaterials.isNotEmpty) ...[
                Text(
                  'Materiali da studiare',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                _MaterialsInline(exam.studyMaterials),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MaterialsInline extends StatelessWidget {
  const _MaterialsInline(this.items);
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in items)
          openablePathTile(
            context,
            m,
            title: looksLikePath(m) ? pathBaseName(m) : m,
          ),
      ],
    );
  }
}

/// ListTile che apre il percorso locale se la voce è un percorso.
Widget openablePathTile(
  BuildContext context,
  String value, {
  required String title,
  String? subtitle,
  Widget? leading,
  bool? forcePath,
}) {
  final isPath = forcePath ?? looksLikePath(value);
  return ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading:
        leading ??
        Icon(isPath ? Icons.insert_drive_file_outlined : Icons.notes, size: 20),
    title: Text(title),
    subtitle: subtitle != null
        ? Text(subtitle)
        : (isPath
              ? Text(value, maxLines: 1, overflow: TextOverflow.ellipsis)
              : null),
    trailing: isPath ? const Icon(Icons.open_in_new, size: 18) : null,
    onTap: isPath ? () => openLocalPath(context, value) : null,
  );
}

/// Avanzamento dello studio sugli argomenti del corso.
class CourseProgressSection extends StatelessWidget {
  const CourseProgressSection({super.key, required this.topics});
  final List<Topic> topics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = courseProgress(topics.map((t) => t.status));
    final counts = <TopicStatus, int>{};
    for (final t in topics) {
      counts[t.status] = (counts[t.status] ?? 0) + 1;
    }
    return DetailSection(
      title: 'Avanzamento dello studio',
      icon: Icons.trending_up,
      children: [
        if (topics.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Nessun argomento: aggiungi moduli e argomenti nella sezione Studio.',
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${(progress * 100).round()}%',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final s in TopicStatus.values)
                  if ((counts[s] ?? 0) > 0)
                    SmallBadge(
                      label: '${s.label}: ${counts[s]}',
                      color: _topicColor(context, s),
                    ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // icone di stato: almeno 3:1 sulle card in entrambi i temi
  Color _topicColor(BuildContext context, TopicStatus s) => readableOn(
    switch (s) {
      TopicStatus.notStarted => Theme.of(context).colorScheme.outline,
      TopicStatus.inProgress => Colors.blue.shade700,
      TopicStatus.partial => const Color(0xFF818CF8),
      TopicStatus.completed => Colors.green.shade700,
      TopicStatus.toReview => Colors.purple.shade400,
    },
    Theme.of(context).brightness,
    minRatio: 3,
  );
}
