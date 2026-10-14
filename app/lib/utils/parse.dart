import 'dart:ui' show Color;

/// Conversioni tolleranti per mappe SQLite/JSON.
int? asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  return int.tryParse(v.toString());
}

double? asDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().replaceAll(',', '.'));
}

bool? asBool(Object? v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().toLowerCase();
  return s == 'true' || s == '1' || s == 'si' || s == 'sì';
}

String? asString(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

DateTime? asDateTime(Object? v) {
  final s = asString(v);
  if (s == null) return null;
  return DateTime.tryParse(s);
}

/// ISO 8601 locale senza fuso (formato usato in tutto il DB).
String isoLocal(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}'
      'T${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String isoDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// Accetta "#RRGGBB", "#AARRGGBB" o un intero ARGB.
int? parseColor(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  var s = v.toString().trim().replaceFirst('#', '');
  if (s.length == 6) s = 'FF$s';
  return int.tryParse(s, radix: 16);
}

String colorToHex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color colorFromInt(int? argb, Color fallback) =>
    argb == null ? fallback : Color(argb);
