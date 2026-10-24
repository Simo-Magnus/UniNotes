import 'package:flutter/material.dart';

import '../../core/router/safe_pop.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_theme.dart';
import '../../models/book.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/study.dart';
import '../../models/university.dart';
import '../../widgets/common.dart';
import '../exams/exam_detail.dart';
import 'course_detail_sections.dart';
import 'course_form.dart';
import 'course_rename.dart';
import 'course_resources_sections.dart';
import 'course_ui.dart';

/// Tutti i dati mostrati nel dettaglio di un corso.
class CourseDetailData {
  const CourseDetailData({
    required this.course,
    required this.universities,
    required this.degree,
    required this.exams,
    required this.books,
    required this.materials,
    required this.topics,
  });

  final Course? course;
  final Map<String, University> universities;
  final Degree? degree;
  final List<Exam> exams;
  final List<Book> books;
  final List<StudyMaterial> materials;
  final List<Topic> topics;

  static Future<CourseDetailData> load(AppServices s, int courseId) async {
    final course = await s.courses.byId(courseId);
    final degrees = course?.degreeId == null
        ? const <Degree>[]
        : await s.courses.degrees();
    final degree = degrees.where((d) => d.id == course?.degreeId).firstOrNull;
    return CourseDetailData(
      course: course,
      universities: await s.courses.universitiesById(),
      degree: degree,
      exams: course == null ? const [] : await s.exams.byCourse(courseId),
      books: course == null ? const [] : await s.books.all(courseId: courseId),
      materials: course == null
          ? const []
          : await s.books.materials(courseId: courseId),
      topics: course == null
          ? const []
          : await s.study.topicsOfCourse(courseId),
    );
  }
}

/// Pagina di dettaglio corso (layout stretto).
class CourseDetailScreen extends StatelessWidget {
  const CourseDetailScreen({super.key, required this.courseId});
  final int courseId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dettaglio corso')),
      body: CourseDetailView(
        courseId: courseId,
        // dopo l'eliminazione: solo questa pagina (non quella sotto se
        // si è già tornati indietro)
        onDeleted: () => popIfCurrent(context),
      ),
    );
  }
}

/// Dettaglio corso incorporabile (pannello destro su Windows).
class CourseDetailView extends StatelessWidget {
  const CourseDetailView({super.key, required this.courseId, this.onDeleted});
  final int courseId;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<CourseDetailData>(
      deps: [courseId],
      load: (s) => CourseDetailData.load(s, courseId),
      builder: (context, d) {
        final course = d.course;
        if (course == null) {
          return const EmptyState(
            icon: Icons.school_outlined,
            message: 'Corso non trovato.',
          );
        }
        final info = CourseInfoSection(
          course: course,
          degreeName: d.degree?.name,
        );
        final exams = CourseExamsSection(
          course: course,
          exams: d.exams,
          onOpenExam: (e) => _openExam(context, e),
        );
        final progress = CourseProgressSection(topics: d.topics);
        final books = CourseBooksSection(books: d.books, course: course);
        final materials = CourseMaterialsSection(
          course: course,
          materials: d.materials,
        );

        return LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _CourseHeader(course: course, data: d, onDeleted: onDeleted),
              if (constraints.maxWidth >= 900)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Column(children: [info, progress])),
                    Expanded(
                      child: Column(children: [exams, books, materials]),
                    ),
                  ],
                )
              else ...[
                info,
                progress,
                exams,
                books,
                materials,
              ],
            ],
          ),
        );
      },
    );
  }

  void _openExam(BuildContext context, Exam e) {
    if (e.id == null) return;
    if (context.isWide) {
      showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    tooltip: 'Chiudi',
                    onPressed: () => Navigator.pop(c),
                    icon: const Icon(Icons.close),
                  ),
                ),
                Expanded(
                  child: ExamDetailView(
                    examId: e.id!,
                    onDeleted: () => popIfCurrent(c),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ExamDetailScreen(examId: e.id!)),
      );
    }
  }
}

class _CourseHeader extends StatelessWidget {
  const _CourseHeader({
    required this.course,
    required this.data,
    this.onDeleted,
  });
  final Course course;
  final CourseDetailData data;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = courseColor(course, data.universities);
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: color, width: 6)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // toccando il nome lo si cambia (vale in tutta l'app)
                    Tooltip(
                      message: 'Cambia il nome',
                      child: InkWell(
                        key: const Key('course-detail-name'),
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => renameCourseDialog(context, course),
                        child: Text(
                          course.name,
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    ),
                    if (course.hasCustomName)
                      Text(
                        'Nome originale: ${course.officialName}',
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (course.code != null) course.code!,
                        formatCfu(course.cfu),
                      ].join(' · '),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Modifica',
                onPressed: () => openCourseForm(context, course: course),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Elimina',
                onPressed: () async {
                  if (await deleteCourseWithConfirm(context, course)) {
                    onDeleted?.call();
                  }
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              // niente sigla dell'ateneo: l'insegnamento ha solo il suo nome
              CourseStatusChip(course.status),
              if (course.year != null || course.semester != null)
                SmallBadge(
                  label:
                      '${yearLabel(course.year)} · ${semesterLabel(course.semester)}',
                  color: theme.colorScheme.secondary,
                  icon: Icons.date_range,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
