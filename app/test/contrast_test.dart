import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/theme/app_tokens.dart';

void main() {
  test('i colori di stato diventano leggibili (WCAG AA 4,5:1) sulle card', () {
    const colori = [
      Color(0xFF1E88E5), // in corso / prenotato
      Color(0xFFF57C00), // da sostenere
      Color(0xFF7E57C2), // non ancora iniziato / sostenuto
      Color(0xFF2E7D32), // superato
      Color(0xFF78909C), // pianificato
      Color(0xFFC62828), // non superato
    ];
    for (final c in colori) {
      final chiaro = readableOn(c, Brightness.light);
      final scuro = readableOn(c, Brightness.dark);
      expect(
        contrastRatio(chiaro, const Color(0xFFFCFDFF)),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(scuro, const Color(0xFF182335)),
        greaterThanOrEqualTo(4.5),
      );
      // la tinta resta riconoscibile
      expect(
        (HSLColor.fromColor(chiaro).hue - HSLColor.fromColor(c).hue).abs(),
        lessThan(1),
      );
    }
    // un colore già leggibile non cambia
    expect(
      readableOn(const Color(0xFF0B1726), Brightness.light),
      const Color(0xFF0B1726),
    );
  });
}
