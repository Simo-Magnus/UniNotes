import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Voce dell'indice del lettore: titolo, rientro e posizione.
class ReaderTocItem {
  const ReaderTocItem(this.title, this.position, {this.level = 0});
  final String title;
  final int position;
  final int level;
}

/// Ponte tra la cornice del lettore (barra, ricerca, indice, segnalibri,
/// zoom) e la vista del formato. La vista registra ciò che sa fare
/// (`onFind`, `onGoToUnit`, ...) e riporta lo stato con [update]; la
/// cornice mostra solo i comandi disponibili.
class ReaderPaneController extends ChangeNotifier {
  // Ricerca.
  int matchCount = 0;
  int? matchIndex;
  bool searching = false;
  ValueChanged<String>? onFind;

  /// +1 successivo, −1 precedente.
  ValueChanged<int>? onStep;

  // Navigazione per unità (pagina, diapositiva, foglio, capitolo).
  String unitLabel = 'Pagina';
  int unitCount = 0;

  /// Unità corrente, da 1.
  int unit = 0;
  ValueChanged<int>? onGoToUnit;

  // Posizione fine (pagina, blocco, secondi): si salva e si usa per indice
  // e segnalibri.
  int position = 0;
  ValueChanged<int>? onGoToPosition;

  /// Etichetta di una posizione (per i segnalibri).
  String Function(int position)? describe;
  List<ReaderTocItem> outline = const [];

  /// +1 ingrandisci, −1 riduci, 0 adatta alla larghezza / dimensione normale.
  ValueChanged<int>? onZoom;

  /// Testo a tutta larghezza invece della colonna di lettura.
  bool fitWidth = false;
  VoidCallback? onToggleFit;

  /// Testo dell'intero documento, per "Copia tutto" (se disponibile).
  String Function()? plainText;

  bool get canFind => onFind != null;
  bool get canGoTo => onGoToUnit != null && unitCount > 1;
  bool get canZoom => onZoom != null;
  bool get hasPositions => onGoToPosition != null;

  /// Applica [change] e avvisa la cornice (dopo il frame se si è in build).
  void update(void Function() change) {
    change();
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _notify());
    } else {
      _notify();
    }
  }

  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void find(String query) => onFind?.call(query);
  void step(int delta) => onStep?.call(delta);
  void goToUnit(int unit) => onGoToUnit?.call(unit);
  void goToPosition(int p) => onGoToPosition?.call(p);
  void zoom(int dir) => onZoom?.call(dir);
  void toggleFit() => onToggleFit?.call();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
