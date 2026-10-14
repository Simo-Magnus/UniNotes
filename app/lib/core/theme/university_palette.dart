import 'package:flutter/material.dart';

import '../services/app_services.dart';
import 'university_colors.dart';
import '../../models/calendar_entry.dart';
import '../../models/course.dart';
import '../../models/university.dart';

/// Colori e nomi delle università (dal DB, con i default se mancano).
class UniversityPalette {
  const UniversityPalette(this.universities);

  final Map<String, University> universities;

  static Future<UniversityPalette> load(AppServices s) async =>
      UniversityPalette({
        for (final u in await s.courses.universities()) u.id: u,
      });

  Color colorOf(String? id) {
    final u = id == null ? null : universities[id];
    return u != null ? Color(u.color) : UniversityColors.forId(id);
  }

  String nameOf(String id) => universities[id]?.shortName ?? id;

  /// Colore di un corso: personalizzato, altrimenti quello dell'università.
  Color courseColor(Course? c) {
    if (c?.color != null) return Color(c!.color!);
    return colorOf(c?.universityId);
  }

  /// Striscia laterale: sempre il colore dell'università (così atenei
  /// diversi restano distinguibili anche con colori dei corsi personalizzati).
  Color stripeOf(CalendarEntry e) =>
      e.universityId == null ? e.color : colorOf(e.universityId);
}
