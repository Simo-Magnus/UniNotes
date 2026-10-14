import 'package:flutter/foundation.dart';

/// Contatore di revisione dei dati: ogni scrittura chiama [bump] e le
/// schermate che lo osservano ricaricano.
class DataRevision extends ChangeNotifier {
  int _value = 0;
  int get value => _value;

  void bump() {
    _value++;
    notifyListeners();
  }
}

/// Richieste di aprire una schermata arrivate da fuori (tocco su una
/// notifica o su un widget della schermata Home): `prova:<id>`,
/// `sezione:<nome>`, `registra`. La shell dell'app le esegue appena c'è.
class RouteRequests extends ChangeNotifier {
  String? _pending;

  /// Percorso in attesa (null se nessuno).
  String? get pending => _pending;

  void call(String route) {
    _pending = route;
    notifyListeners();
  }

  /// Prende il percorso in attesa (una sola volta).
  String? take() {
    final r = _pending;
    _pending = null;
    return r;
  }
}
