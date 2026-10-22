import 'package:flutter/material.dart';

/// [showDatePicker] che non si rompe con date salvate fuori dall'intervallo
/// (dati importati, sincronizzati o inseriti anni fa): l'intervallo si
/// allarga fino a comprendere [initialDate], che altrimenti farebbe fallire
/// l'asserzione del selettore («initialDate must be on or after firstDate»).
Future<DateTime?> showSafeDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  final r = safeDateRange(initialDate, firstDate, lastDate);
  return showDatePicker(
    context: context,
    initialDate: r.initial,
    firstDate: r.first,
    lastDate: r.last,
  );
}

/// Intervallo del selettore che contiene sempre la data iniziale (solo il
/// giorno, senza ora: il selettore confronta i giorni).
({DateTime initial, DateTime first, DateTime last}) safeDateRange(
  DateTime initialDate,
  DateTime firstDate,
  DateTime lastDate,
) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  final initial = day(initialDate);
  var first = day(firstDate);
  var last = day(lastDate);
  if (last.isBefore(first)) last = first;
  if (initial.isBefore(first)) first = initial;
  if (initial.isAfter(last)) last = initial;
  return (initial: initial, first: first, last: last);
}
