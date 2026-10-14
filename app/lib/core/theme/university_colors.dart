import 'package:flutter/material.dart';

/// Colore identificativo di un ateneo (personalizzabile in Impostazioni).
///
/// Per un ateneo senza colore salvato il colore è **deterministico**: deriva
/// dall'id (hash FNV-1a → una delle tonalità di [hues]), così è lo stesso su
/// tutti i dispositivi e tra un'installazione e l'altra.
class UniversityColors {
  static const fallback = Color(0xFF607D8B);

  /// Tonalità ben distinte tra loro (gradi HSL), lontane dall'arancione
  /// delle azioni.
  static const List<double> hues = [
    212,
    0,
    140,
    270,
    188,
    330,
    100,
    236,
    160,
    300,
    52,
    350,
    120,
    200,
    285,
  ];

  /// Hash FNV-1a a 32 bit dell'id (stabile tra piattaforme).
  static int hashOf(String id) {
    var h = 0x811C9DC5;
    for (final c in id.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  /// Colore deterministico per l'ateneo [id].
  static Color deterministic(String id) {
    final h = hashOf(id);
    final hue = hues[h % hues.length];
    // Piccola variazione di luminosità per atenei con la stessa tonalità.
    final light = 0.40 + ((h >> 8) % 3) * 0.04;
    return HSLColor.fromAHSL(1, hue, 0.62, light).toColor();
  }

  static Color forId(String? id, {Map<String, Color> overrides = const {}}) {
    if (id != null && overrides.containsKey(id)) return overrides[id]!;
    if (id == null || id.isEmpty) return fallback;
    return deterministic(id);
  }
}

/// Colori di risalto per le verifiche, uno per tipo: tonalità lontane dai
/// colori delle lezioni, dall'arancione delle azioni e dall'azzurro degli
/// stati calcolati.
class AssessmentColors {
  static const midterm = Color(0xFF2DD4BF); // verde acqua
  static const exam = Color(0xFFA78BFA); // viola
  static const otherMidterm = Color(0xFF94A3B8);
  static const otherExam = Color(0xFFCBD5E1);

  /// [midterm] true = prova in itinere / esonero, false = esame o sessione.
  /// [universityId] null = verifica non legata a un ateneo.
  static Color forUniversity(String? universityId, {required bool midterm}) =>
      universityId == null
      ? (midterm ? otherMidterm : otherExam)
      : (midterm ? AssessmentColors.midterm : exam);
}
