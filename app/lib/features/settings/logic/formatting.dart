import 'package:intl/intl.dart';

import '../../../utils/parse.dart';

final DateFormat _dateTime = DateFormat('dd/MM/yyyy HH:mm');

/// "dd/MM/yyyy HH:mm" da una stringa ISO; [fallback] se assente o non valida.
String formatIsoDateTime(String? iso, {String fallback = 'mai'}) {
  final d = asDateTime(iso);
  return d == null ? fallback : _dateTime.format(d);
}

/// Suffisso data/ora per i nomi dei file esportati (es. 2026-10-01_1030).
String fileStamp([DateTime? now]) => DateFormat('yyyy-MM-dd_HHmm').format(now ?? DateTime.now());

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
