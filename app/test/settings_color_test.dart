import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/theme/university_colors.dart';

void main() {
  test('colore deterministico per ogni ateneo', () {
    expect(UniversityColors.forId('unibo'), UniversityColors.forId('unibo'));
    expect(UniversityColors.forId(null), UniversityColors.fallback);
    // Atenei diversi: colori in genere diversi (tonalità distribuite).
    final ids = ['polito', 'unito', 'unibo', 'unipd', 'unina', 'uniroma1'];
    final colors = {for (final id in ids) UniversityColors.forId(id)};
    expect(colors.length, greaterThan(3));
  });
}
