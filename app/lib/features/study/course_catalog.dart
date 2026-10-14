import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/academic/course_status_sync.dart';
import '../../core/academic/plan_scope.dart';
import '../../core/theme/university_colors.dart';
import '../../models/course.dart';
import '../../models/university.dart';

/// Corsi + università già caricati, con risoluzione di nomi e colori.
/// Condiviso dalle feature Studio e Libri.
class CourseCatalog {
  /// [visible] limita i corsi mostrati (es. percorso e anno scelti); nomi e
  /// colori restano disponibili per tutti.
  CourseCatalog(
    List<Course> courses,
    List<University> universities, {
    bool Function(Course c)? visible,
  }) : courses = _sorted([
         for (final c in courses)
           if (visible == null || visible(c)) c,
       ]),
       byId = {
         for (final c in courses)
           if (c.id != null) c.id!: c,
       },
       visibleIds = visible == null
           ? null
           : {
               for (final c in courses)
                 if (c.id != null && visible(c)) c.id!,
             },
       universities = {for (final u in universities) u.id: u},
       universityFilter = null;

  CourseCatalog._filtered(CourseCatalog all, String this.universityFilter)
    : courses = [
        for (final c in all.courses)
          if (c.universityId == universityFilter) c,
      ],
      byId = all.byId,
      visibleIds = all.visibleIds,
      universities = all.universities;

  /// Corsi nel filtro di percorso/anno (null = nessun filtro).
  final Set<int>? visibleIds;

  /// Corsi mostrati (filtrati per università se [universityFilter] ≠ null).
  final List<Course> courses;

  /// Tutti i corsi, anche quelli esclusi dal filtro (per nomi e colori).
  final Map<int, Course> byId;
  final Map<String, University> universities;

  /// Università selezionata nel filtro (null = tutte).
  final String? universityFilter;

  /// Stessi dati, solo i corsi dell'università [id] (null = tutti).
  CourseCatalog only(String? id) =>
      id == null ? this : CourseCatalog._filtered(this, id);

  /// Il corso rientra nel filtro (le voci senza corso solo senza filtro).
  bool shows(int? courseId) {
    final ids = visibleIds;
    if (ids != null && courseId != null && !ids.contains(courseId)) {
      return false;
    }
    return universityFilter == null ||
        byId[courseId]?.universityId == universityFilter;
  }

  /// Università dei corsi presenti, in ordine di nome breve.
  List<University> get usedUniversities => [
    for (final id in {for (final c in courses) c.universityId})
      ?universities[id],
  ]..sort((a, b) => a.shortName.compareTo(b.shortName));

  static Future<CourseCatalog> load(AppServices s) async {
    await syncCourseStatuses(s);
    final results = await Future.wait([
      s.courses.all(),
      s.courses.universities(),
    ]);
    final scope = s.scope;
    return CourseCatalog(
      results[0] as List<Course>,
      results[1] as List<University>,
      visible: scope.isFiltered ? scope.includes : null,
    );
  }

  /// Prima gli insegnamenti in corso (semestre attuale), poi quelli da
  /// sostenere, quelli futuri e i superati; archiviati in fondo. Gli
  /// insegnamenti a scelta vengono dopo tutti gli obbligatori.
  static List<Course> _sorted(List<Course> list) {
    int rank(CourseStatus s) => switch (s) {
      CourseStatus.active => 0,
      CourseStatus.toTake => 1,
      CourseStatus.upcoming => 2,
      CourseStatus.completed => 3,
      CourseStatus.archived => 4,
    };
    final copy = [...list];
    copy.sort((a, b) {
      final e = electivesLast(a, b);
      if (e != 0) return e;
      final r = rank(a.status).compareTo(rank(b.status));
      if (r != 0) return r;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return copy;
  }

  bool get isEmpty => courses.isEmpty;

  String nameOf(int? courseId) {
    if (courseId == null) return 'Senza materia';
    return byId[courseId]?.label ?? 'Corso eliminato';
  }

  String? universityShort(Course c) => universities[c.universityId]?.shortName;

  Color universityColor(String? universityId) {
    final u = universities[universityId];
    if (u != null) return Color(u.color);
    return UniversityColors.forId(universityId);
  }

  /// Colore personalizzato del corso, altrimenti quello dell'università.
  Color colorOf(int? courseId) {
    final c = courseId == null ? null : byId[courseId];
    if (c == null) return UniversityColors.fallback;
    if (c.color != null) return Color(c.color!);
    return universityColor(c.universityId);
  }
}
