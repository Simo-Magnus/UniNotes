/// Testi di luogo per il calendario: niente indirizzi stradali.
library;

final _street = RegExp(
  r"^(c\.?\s?so|corso|via|v\.le|viale|p\.?\s?za|piazza|p\.?\s?le|piazzale|"
  r"largo|lungo\s?\w+|str\.|strada|vicolo|borgo|lungodora|lungopo)\b",
  caseSensitive: false,
);

bool _isStreet(String part) {
  final p = part.trim();
  return _street.hasMatch(p) || RegExp(r'^\d+[a-zA-Z]?$').hasMatch(p);
}

/// Toglie le parti che sono un indirizzo stradale ("C.so Duca degli
/// Abruzzi 24", "Via Verdi 10"); restituisce null se non resta nulla.
/// Esempio: "Sede centrale, C.so Duca degli Abruzzi 24" → "Sede centrale".
String? withoutStreet(String? text) {
  if (text == null) return null;
  final parts = text
      .split(RegExp(r'\s*[,–—]\s*|\s+-\s+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty && !_isStreet(p))
      .toList();
  return parts.isEmpty ? null : parts.join(', ');
}

/// Luogo breve di un evento: aula e nome dell'edificio, senza indirizzo
/// né città.
String calendarLocation(String? room, String? building) {
  final r = withoutStreet(room);
  final b = withoutStreet(building);
  return [r, if (b != null && b != r) b].whereType<String>().join(' · ');
}
