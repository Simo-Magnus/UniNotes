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

/// [showTimePicker] con i caratteri del selettore limitati a ×1,3 (×1 con la finestra bassa; come fa
/// Flutter per il selettore della data): il quadrante e i campi dell'ora
/// hanno misure fisse e, con i caratteri al massimo dell'app (×2) su una
/// finestra bassa o stretta, uscivano dal riquadro (RenderFlex overflowed).
/// Il resto dell'app resta alla grandezza scelta.
Future<TimeOfDay?> showSafeTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
}) => showTimePicker(
  context: context,
  initialTime: initialTime,
  builder: (context, child) {
    final media = MediaQuery.of(context);
    // in orizzontale su un telefono (finestra bassa) il quadrante ha già
    // poco spazio: i caratteri restano a ×1
    final maxScale = media.size.height < 420 ? 1.0 : 1.3;
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(maxScaleFactor: maxScale),
      ),
      child: child!,
    );
  },
);
