import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/academic/course_status_sync.dart';
import '../../core/academic/plan_scope.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/university.dart';
import '../../widgets/common.dart';
import '../exams/exam_ui.dart';
import 'course_ui.dart';

/// Dati per la lista corsi.
class CoursesData {
  const CoursesData({
    required this.courses,
    required this.universities,
    required this.passedFinals,
  });

  final List<Course> courses;
  final Map<String, University> universities;

  /// Esame finale superato per corso (per mostrare il voto nella lista).
  final Map<int, Exam> passedFinals;

  /// Con un percorso: solo gli insegnamenti del corso di laurea attuale
  /// nell'anno scelto (quelli senza anno compaiono sempre); gli archiviati
  /// restano, nascosti dal filtro di stato finché non si sceglie di vederli.
  static Future<CoursesData> load(AppServices s) async {
    await s.exams.mergeDuplicateFinals();
    await syncCourseStatuses(s);
    final passed = await s.exams.byStatus([ExamStatus.passed]);
    final scope = s.scope;
    bool shown(Course c) =>
        scope.inDegree(c) &&
        (scope.year == null || c.year == null || c.year == scope.year);
    return CoursesData(
      courses: [
        for (final c in await s.courses.all())
          if (!scope.isFiltered || shown(c)) c,
      ],
      universities: await s.courses.universitiesById(),
      passedFinals: {
        for (final e in passed)
          if (e.kind == ExamKind.finalExam) e.courseId: e,
      },
    );
  }
}

/// Filtri della lista corsi. La pagina si apre con il solo «In corso»;
/// nessuno stato scelto = tutti gli insegnamenti (non c'è «Tutti»).
class CourseFilter {
  const CourseFilter({
    this.query = '',
    this.statuses = const {CourseStatus.active},
    this.universityId,
  });

  final String query;

  /// Stati scelti; vuoto = tutti.
  final Set<CourseStatus> statuses;

  /// null = tutte le università.
  final String? universityId;

  bool matches(Course c) {
    if (statuses.isNotEmpty && !statuses.contains(c.status)) return false;
    if (universityId != null && c.universityId != universityId) return false;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      c.name,
      // anche con il nome ufficiale, se lo studente l'ha cambiato
      if (c.hasCustomName) c.officialName,
      c.code,
      c.teacher,
      c.description,
    ].whereType<String>().any((s) => s.toLowerCase().contains(q));
  }

  CourseFilter copyWith({
    String? query,
    Set<CourseStatus>? statuses,
    String? universityId,
    bool allUniversities = false,
  }) => CourseFilter(
    query: query ?? this.query,
    statuses: statuses ?? this.statuses,
    universityId: allUniversities ? null : (universityId ?? this.universityId),
  );
}

/// Gruppo università → (anno, semestre) → corsi.
class UniversityGroup {
  UniversityGroup(this.universityId, this.periods);
  final String? universityId;
  final List<PeriodGroup> periods;

  int get count => periods.fold(0, (s, p) => s + p.courses.length);
  double get cfu => periods.fold(
    0,
    (s, p) => s + p.courses.fold(0.0, (a, c) => a + (c.cfu ?? 0)),
  );
}

class PeriodGroup {
  PeriodGroup(this.year, this.semester, this.courses);
  final int? year;
  final String? semester;
  final List<Course> courses;

  String get label => '${yearLabel(year)} · ${semesterLabel(semester)}';
}

/// Raggruppa i corsi per università (ordine per nome) e poi per anno/semestre.
List<UniversityGroup> groupCourses(
  Iterable<Course> courses,
  Map<String, University> universities,
) {
  final byUni = <String?, List<Course>>{};
  for (final c in courses) {
    byUni.putIfAbsent(c.universityId, () => []).add(c);
  }
  final uniIds = byUni.keys.toList()
    ..sort((a, b) {
      if (a == null) return 1;
      if (b == null) return -1;
      return (universities[a]?.name ?? a).compareTo(universities[b]?.name ?? b);
    });
  return [
    for (final uid in uniIds) UniversityGroup(uid, _periods(byUni[uid]!)),
  ];
}

List<PeriodGroup> _periods(List<Course> courses) {
  final map = <String, PeriodGroup>{};
  for (final c in courses) {
    final key =
        '${c.year ?? 99}|${semesterOrder(c.semester)}|${c.semester ?? ''}';
    map
        .putIfAbsent(key, () => PeriodGroup(c.year, c.semester, []))
        .courses
        .add(c);
  }
  // In ordine di anno e semestre (1°, 2°, annuale, non indicato), come
  // nella schermata Esami (groupBySemester).
  final groups = map.values.toList()
    ..sort((a, b) {
      final y = (a.year ?? 99).compareTo(b.year ?? 99);
      if (y != 0) return y;
      return semesterOrder(a.semester).compareTo(semesterOrder(b.semester));
    });
  // in ogni periodo gli insegnamenti a scelta per ultimi
  for (final g in groups) {
    g.courses.sort((a, b) {
      final e = electivesLast(a, b);
      if (e != 0) return e;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }
  return groups;
}

/// Lista raggruppata dei corsi.
class CourseGroupedList extends StatelessWidget {
  const CourseGroupedList({
    super.key,
    required this.data,
    required this.groups,
    required this.selectedId,
    required this.onTap,
    this.header,
  });

  final CoursesData data;
  final List<UniversityGroup> groups;
  final int? selectedId;
  final ValueChanged<Course> onTap;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[?header];
    for (final g in groups) {
      final color = universityColor(g.universityId, data.universities);
      final name = g.universityId == null
          ? 'Altri insegnamenti'
          : (data.universities[g.universityId]?.name ?? g.universityId!);
      children.add(
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            border: Border(left: BorderSide(color: color, width: 5)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  // colore dell'ateneo leggibile sul fondo
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: readableOn(color, theme.brightness),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // caratteri grandi: il conteggio va a capo invece di uscire
              Flexible(
                child: Text(
                  '${g.count} ${g.count == 1 ? 'insegnamento' : 'insegnamenti'}'
                  ' · ${formatNumber(g.cfu)} CFU',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      );
      for (final p in g.periods) {
        children.add(SectionHeader(p.label));
        for (final c in p.courses) {
          children.add(
            CourseTile(
              course: c,
              color: courseColor(c, data.universities),
              passed: data.passedFinals[c.id],
              selected: c.id == selectedId,
              onTap: () => onTap(c),
            ),
          );
        }
      }
    }
    children.add(const SizedBox(height: 96));
    return ListView(children: children);
  }
}

class CourseTile extends StatelessWidget {
  const CourseTile({
    super.key,
    required this.course,
    required this.color,
    this.passed,
    this.selected = false,
    this.onTap,
  });

  final Course course;
  final Color color;
  final Exam? passed;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = course;
    final grade = passed == null ? null : gradeLabel(passed!);
    final muted = c.status == CourseStatus.archived;
    return Opacity(
      opacity: muted ? 0.65 : 1,
      child: ListTile(
        selected: selected,
        onTap: onTap,
        leading: Container(
          width: 8,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        title: Text(c.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // «Marco Armandi · 8 CFU · 15AHMYE»
            Text(
              [
                if (c.teacher != null) c.teacher!,
                if (c.cfu != null) formatCfu(c.cfu),
                if (c.code != null) c.code!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                CourseStatusChip(c.status),
                if (grade != null)
                  SmallBadge(
                    label: 'Superato: $grade',
                    color: Colors.green.shade700,
                    icon: Icons.verified,
                  ),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
