import 'dart:async';

import 'package:flutter/widgets.dart';

/// Avvisa quando cambia il giorno di calendario con l'app aperta: le
/// schermate leggono «oggi» quando caricano i dati, e un'app lasciata aperta
/// (PC nell'area di notifica) o ripresa dopo giorni mostrava ancora il
/// giorno prima (prove «domani», conti alla rovescia, settimana di Studio).
///
/// Controlla a mezzanotte (con un controllo almeno ogni ora: un PC in
/// sospensione ferma i timer) e a ogni ripresa dell'app (in background i
/// timer di Android e iOS non scattano). Anche un orologio spostato
/// indietro a un altro giorno conta come cambio.
class DayWatcher {
  DayWatcher(this.onNewDay, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _day = _dayOf(_clock());
  }

  final void Function() onNewDay;
  final DateTime Function() _clock;
  late DateTime _day;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  static DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

  void start() {
    _schedule();
    try {
      _lifecycle ??= AppLifecycleListener(onResume: check);
    } catch (_) {
      // senza binding (prove senza interfaccia) basta il timer
    }
  }

  /// true se il giorno è cambiato dall'ultimo controllo (e lo si è detto).
  bool check() {
    final d = _dayOf(_clock());
    _schedule();
    if (d == _day) return false;
    _day = d;
    onNewDay();
    return true;
  }

  void _schedule() {
    _timer?.cancel();
    final now = _clock();
    // mezzanotte locale (il costruttore tiene conto dell'ora legale)
    final next = DateTime(now.year, now.month, now.day + 1);
    var wait = next.difference(now) + const Duration(seconds: 1);
    if (wait.isNegative || wait > const Duration(hours: 1)) {
      wait = const Duration(hours: 1);
    }
    _timer = Timer(wait, check);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
