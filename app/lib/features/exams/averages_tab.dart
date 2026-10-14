import 'package:flutter/material.dart';

import '../../core/academic/student_profile.dart';
import '../../core/constants/enums.dart';
import '../../core/theme/app_theme.dart';
import '../../models/exam.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../courses/course_ui.dart';
import 'exam_stats.dart';
import 'exam_ui.dart';

/// Tab "Medie": media ponderata (CFU) e aritmetica, CFU acquisiti, complessiva
/// (con la base di laurea su 110) e per anno.
class AveragesTab extends StatelessWidget {
  const AveragesTab({super.key, required this.data, required this.onSelect});

  final ExamsData data;
  final ValueChanged<Exam> onSelect;

  @override
  Widget build(BuildContext context) {
    final profile = data.profile;
    final overall = AverageSummary(
      'Complessiva',
      profile == null ? data.exams : data.pathExams,
      data.courses,
    );
    final wide = context.isWide;

    // Università presenti tra i corsi (o tra le università note).
    final uniIds = <String?>{
      ...data.courses.values.map((c) => c.universityId),
    }.toList()..sort((a, b) => (a ?? 'zzz').compareTo(b ?? 'zzz'));

    final left = <Widget>[
      const SectionHeader('Media complessiva'),
      _SummaryCard(
        summary: overall,
        color: Theme.of(context).colorScheme.primary,
        showBase: true,
      ),
      if (profile != null)
        ..._yearSections(context, profile)
      else
        for (final uid in uniIds) ..._universitySection(context, uid),
    ];
    final right = <Widget>[
      const SectionHeader('Dettaglio per corso'),
      _CourseBreakdown(data: data, onSelect: onSelect),
    ];

    if (data.exams.isEmpty && data.degrees.isEmpty) {
      return const EmptyState(
        icon: Icons.calculate_outlined,
        message: 'Nessun esame registrato.\nLe medie compaiono quando segni un esame come "Superato" con il voto.',
      );
    }

    if (wide) {
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 96),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: left,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: right,
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [...left, ...right],
    );
  }

  /// Media ponderata di ogni anno del piano (esami dei corsi di quell'anno).
  List<Widget> _yearSections(BuildContext context, StudentProfile p) {
    final color = Theme.of(context).colorScheme.primary;
    final exams = data.pathExams;
    return [
      for (final y in planYearsOf(p)) ...[
        SectionHeader(p.yearChipLabel(y)),
        _SummaryCard(
          summary: AverageSummary(
            p.yearChipLabel(y),
            exams.where((e) => data.courses[e.courseId]?.year == y),
            data.courses,
          ),
          color: color,
        ),
      ],
    ];
  }

  List<Widget> _universitySection(BuildContext context, String? uid) {
    final courseIds = {
      for (final c in data.courses.values)
        if (c.universityId == uid) c.id,
    };
    final exams = data.exams
        .where((e) => courseIds.contains(e.courseId))
        .toList();
    final color = universityColor(uid, data.universities);
    final name = uid == null
        ? 'Altri corsi'
        : (data.universities[uid]?.name ?? uid);

    // Corsi di laurea con almeno un corso associato.
    final degreeIds = <String>{
      for (final c in data.courses.values)
        if (c.universityId == uid && c.degreeId != null) c.degreeId!,
    };
    final degreeNames = {for (final d in data.degrees) d.id: d.name};

    return [
      SectionHeader(name),
      _SummaryCard(
        summary: AverageSummary(name, exams, data.courses),
        color: color,
      ),
      if (degreeIds.length > 1)
        for (final did in degreeIds)
          _SummaryCard(
            summary: AverageSummary(
              degreeNames[did] ?? did,
              exams.where((e) => data.courses[e.courseId]?.degreeId == did),
              data.courses,
            ),
            color: color,
            showTitle: true,
          ),
    ];
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.color,
    this.showTitle = false,
    this.showBase = false,
  });
  final AverageSummary summary;
  final Color color;
  final bool showTitle;

  /// Voto di laurea di partenza (media ponderata su 110): solo nella media
  /// complessiva, l'unica che conta per la laurea.
  final bool showBase;

  @override
  Widget build(BuildContext context) {
    final r = summary.result;
    final base = r.graduationBase;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showTitle) ...[
              Text(
                summary.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
            ],
            // Riquadri della stessa larghezza: quanti ne stanno per riga
            // (almeno 150 px l'uno), allargati a riempirla.
            LayoutBuilder(
              builder: (context, c) {
                const gap = 8.0;
                final stats = [
                  _Stat(
                    label: 'Media ponderata (CFU)',
                    value: r.weightedAverage == null
                        ? '—'
                        : r.weightedAverage!
                              .toStringAsFixed(2)
                              .replaceAll('.', ','),
                    color: color,
                    big: true,
                  ),
                  _Stat(
                    label: 'Media aritmetica',
                    value: r.arithmeticAverage == null
                        ? '—'
                        : r.arithmeticAverage!
                              .toStringAsFixed(2)
                              .replaceAll('.', ','),
                    color: color,
                  ),
                  _Stat(
                    label: 'CFU acquisiti',
                    value: formatNumber(summary.cfu),
                    color: color,
                  ),
                  _Stat(
                    label: 'Esami superati',
                    value: '${summary.passed}',
                    color: color,
                  ),
                  if (showBase)
                    _Stat(
                      label: 'Base di laurea',
                      value: base == null
                          ? '—'
                          : '${base.toStringAsFixed(1).replaceAll('.', ',')}/110',
                      color: color,
                    ),
                ];
                final cols = ((c.maxWidth + gap) / (150 + gap)).floor().clamp(
                  1,
                  stats.length,
                );
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final s in stats) SizedBox(width: w, child: s),
                  ],
                );
              },
            ),
            if (r.count > 0 && r.totalCfu == 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Media ponderata non calcolabile: CFU mancanti negli esami e nei corsi.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.color,
    this.big = false,
  });
  final String label;
  final String value;
  final Color color;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: big ? 0.14 : 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style:
                (big
                        ? theme.textTheme.headlineMedium
                        : theme.textTheme.titleLarge)
                    ?.copyWith(color: color, fontWeight: FontWeight.bold),
          ),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _CourseBreakdown extends StatelessWidget {
  const _CourseBreakdown({required this.data, required this.onSelect});
  final ExamsData data;
  final ValueChanged<Exam> onSelect;

  @override
  Widget build(BuildContext context) {
    final passed =
        (data.profile == null ? data.exams : data.pathExams)
            .where(
              (e) =>
                  e.kind == ExamKind.finalExam && e.status == ExamStatus.passed,
            )
            .toList()
          ..sort(
            (a, b) => (data.courses[a.courseId]?.name ?? '').compareTo(
              data.courses[b.courseId]?.name ?? '',
            ),
          );
    if (passed.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Nessun esame finale superato.'),
      );
    }
    final totalCfu = passed.fold<double>(
      0,
      (s, e) =>
          s +
          ((e.grade != null || e.laude)
              ? (e.cfu ?? data.courses[e.courseId]?.cfu ?? 0)
              : 0),
    );
    return GlassCard(
      child: Column(
        children: [for (final e in passed) _breakdownRow(context, e, totalCfu)],
      ),
    );
  }

  Widget _breakdownRow(BuildContext context, Exam e, double totalCfu) {
    final course = data.courses[e.courseId];
    final cfu = e.cfu ?? course?.cfu;
    final graded = e.grade != null || e.laude;
    final weight = graded && cfu != null && totalCfu > 0
        ? cfu / totalCfu * 100
        : null;
    // solo il nome dell'insegnamento: niente pallino né sigla dell'ateneo
    return ListTile(
      dense: true,
      onTap: () => onSelect(e),
      title: Text(course?.name ?? 'Corso sconosciuto'),
      subtitle: Text(
        [
          formatCfu(cfu),
          if (e.date != null) formatDate(e.date!, weekday: false),
          if (weight != null)
            'peso ${weight.toStringAsFixed(1).replaceAll('.', ',')}%',
          if (!graded) 'senza voto (non entra in media)',
        ].join(' · '),
      ),
      trailing: Text(
        gradeLabel(e) ?? 'Idoneo',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}
