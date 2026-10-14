import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../academic/year_widgets.dart';
import '../courses/course_ui.dart';
import 'exam_status.dart';
import 'exam_ui.dart';

/// Riga di un esame o prova in itinere.
class ExamTile extends StatelessWidget {
  const ExamTile({
    super.key,
    required this.exam,
    this.course,
    this.showCourse = true,
    this.selected = false,
    this.onTap,
    this.dense = false,
    this.dateHint,
  });

  /// Testo al posto della data quando manca (es. "Prossimo appello: …").
  final String? dateHint;

  final Exam exam;
  final Course? course;
  final bool showCourse;
  final bool selected;
  final bool dense;
  final VoidCallback? onTap;

  String get _title {
    final t = exam.title;
    if (t != null && t.isNotEmpty) return t;
    return exam.kind.label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = exam.status.isPending ? daysUntil(exam) : null;
    final cfu = exam.cfu ?? course?.cfu;
    final subtitle = <String>[
      exam.date == null && dateHint != null ? dateHint! : examDateLabel(exam),
      if (exam.location != null) exam.location!,
      examTypeLabel(exam.examType),
      if (exam.kind == ExamKind.finalExam && cfu != null) formatCfu(cfu),
    ].join(' · ');

    return ListTile(
      selected: selected,
      dense: dense,
      onTap: onTap,
      // toccando l'icona si cambia lo stato (due scelte: vedi
      // changeExamStatus), toccando la riga si apre il dettaglio
      leading: Tooltip(
        message: 'Cambia stato',
        child: InkResponse(
          key: ValueKey('exam-status-${exam.id}'),
          radius: dense ? 22 : 26,
          onTap: exam.id == null ? null : () => changeExamStatus(context, exam),
          child: GradeBadge(
            exam,
            size: dense ? 36 : 44,
            // il colore dice l'esito (superato, non superato, in attesa…),
            // non l'ateneo: prima tutte le prove sostenute erano verdi uguali
            accent: readableOn(
              examStatusColor(context, exam.status),
              theme.brightness,
            ),
          ),
        ),
      ),
      // solo il nome dell'insegnamento: niente pallino né sigla dell'ateneo
      title: Text(
        showCourse && course != null ? course!.name : _title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCourse && course != null)
            Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ExamStatusChip(exam.status),
              if (exam.kind == ExamKind.midterm) ExamKindChip(exam.kind),
              // Date d'esame non ancora nel database pubblico.
              if (exam.kind == ExamKind.finalExam &&
                  exam.date == null &&
                  dateHint == null &&
                  (course?.examsToAdd ?? false))
                const MutedChip('Da aggiungere'),
              if (days != null && days >= 0)
                SmallBadge(
                  label: days == 0
                      ? 'Oggi'
                      : (days == 1 ? 'Domani' : 'Tra $days giorni'),
                  color: days <= 7
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                  icon: Icons.schedule,
                ),
              if (days != null && days < 0)
                SmallBadge(
                  label: 'Data passata: aggiorna lo stato',
                  color: const Color(0xFF818CF8),
                  icon: Icons.update,
                ),
            ],
          ),
        ],
      ),
      isThreeLine: true,
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
    );
  }
}
