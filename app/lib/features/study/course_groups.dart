import 'dart:convert';

import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../courses/course_ui.dart';

/// Insegnamenti di Studio divisi per semestre (1°, 2°), annuali e OFA, con
/// l'ordine scelto dallo studente (tieni premuto e trascina nell'elenco
/// degli insegnamenti).

/// Impostazione con l'ordine degli insegnamenti in Studio (id in JSON).
const String kStudyCourseOrderKey = 'study_course_order';

/// OFA e obblighi formativi aggiuntivi: gruppo a parte, in fondo (stesso
/// criterio dell'esclusione «OFA e obblighi formativi»).
final RegExp _ofa = RegExp(r'\bOFA\b|obblighi formativi', caseSensitive: false);

/// Dal nome ufficiale: un OFA rinominato dallo studente resta un OFA.
bool isOfaCourse(Course c) => _ofa.hasMatch(c.officialName);

/// Gruppo dell'elenco degli insegnamenti di Studio.
class StudyCourseGroup {
  StudyCourseGroup(this.label, this.courses);
  final String label;
  final List<Course> courses;
}

/// Divide [courses] per semestre (1°, 2°, annuale, non indicato; con l'anno
/// davanti se gli anni sono più d'uno) e mette gli OFA in un gruppo a parte
/// alla fine. Dentro ogni gruppo resta l'ordine di [courses].
List<StudyCourseGroup> groupStudyCourses(List<Course> courses) {
  final years = {
    for (final c in courses)
      if (!isOfaCourse(c)) c.year,
  };
  final withYear = years.length > 1;
  final keys = <String, (int, int, String)>{};
  final byKey = <String, List<Course>>{};
  final ofa = <Course>[];
  for (final c in courses) {
    if (isOfaCourse(c)) {
      ofa.add(c);
      continue;
    }
    final y = c.year ?? 99;
    final so = semesterOrder(c.semester);
    final key = '$y|$so|${so == 5 ? c.semester!.trim().toLowerCase() : ''}';
    keys[key] ??= (
      y,
      so,
      withYear
          ? '${yearLabel(c.year)} · ${semesterLabel(c.semester)}'
          : semesterLabel(c.semester),
    );
    byKey.putIfAbsent(key, () => []).add(c);
  }
  final ordered = keys.keys.toList()
    ..sort((a, b) {
      final ka = keys[a]!, kb = keys[b]!;
      final y = ka.$1.compareTo(kb.$1);
      if (y != 0) return y;
      final s = ka.$2.compareTo(kb.$2);
      return s != 0 ? s : a.compareTo(b);
    });
  // Semestri scritti in modo diverso con la stessa etichetta («1» e
  // «1° semestre» da dati importati, o un semestre chiamato «OFA»): un
  // gruppo solo, se no due gruppi con lo stesso nome (chiavi doppie negli
  // elenchi, il secondo irraggiungibile dal selettore della Home).
  final position = Map<Course, int>.identity();
  for (var i = 0; i < courses.length; i++) {
    position[courses[i]] = i;
  }
  final merged = <String, List<Course>>{};
  for (final k in ordered) {
    merged.putIfAbsent(keys[k]!.$3, () => []).addAll(byKey[k]!);
  }
  if (ofa.isNotEmpty) merged.putIfAbsent('OFA', () => []).addAll(ofa);
  return [
    for (final e in merged.entries)
      StudyCourseGroup(
        e.key,
        e.value..sort((a, b) => position[a]!.compareTo(position[b]!)),
      ),
  ];
}

/// [courses] nell'ordine salvato [order] (id); quelli non ancora ordinati
/// restano dopo, nell'ordine di partenza.
List<Course> applyCourseOrder(List<Course> courses, List<int> order) {
  if (order.isEmpty) return courses;
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  final indexed = [for (var i = 0; i < courses.length; i++) (i, courses[i])];
  indexed.sort((a, b) {
    final ra = rank[a.$2.id] ?? order.length + a.$1;
    final rb = rank[b.$2.id] ?? order.length + b.$1;
    return ra.compareTo(rb);
  });
  return [for (final x in indexed) x.$2];
}

/// Ordine salvato degli insegnamenti (vuoto = quello predefinito).
Future<List<int>> loadStudyCourseOrder(AppServices s) async {
  final raw = await s.settings.get(kStudyCourseOrderKey);
  if (raw == null || raw.isEmpty) return const [];
  try {
    return [
      for (final v in jsonDecode(raw) as List)
        if (v is num) v.toInt(),
    ];
  } catch (_) {
    return const [];
  }
}

Future<void> saveStudyCourseOrder(AppServices s, List<int> ids) =>
    s.settings.set(kStudyCourseOrderKey, jsonEncode(ids));
