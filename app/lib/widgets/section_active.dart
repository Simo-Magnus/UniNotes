import 'package:flutter/widgets.dart';

/// Dice ai widget di una sezione principale (Home, Registra, Studio…) se la
/// sezione è quella visibile. Le sezioni già aperte restano vive nascoste
/// (`SectionStack` in core/router/section_stack.dart): stato, scorrimento e
/// dati restano, ma chi carica qualcosa una volta sola può ricaricarlo quando
/// la sezione torna visibile ([SectionReturn]).
///
/// Fuori da una sezione (pagine aperte sopra, dialoghi, prove dei singoli
/// widget) vale sempre «visibile».
class SectionActive extends InheritedWidget {
  const SectionActive({super.key, required this.active, required super.child});

  final bool active;

  /// La sezione di [context] è visibile (true anche fuori dalle sezioni).
  /// Chi lo legge si ricostruisce quando cambia.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SectionActive>()?.active ??
      true;

  @override
  bool updateShouldNotify(SectionActive old) => old.active != active;
}

/// Per gli stati che leggono qualcosa all'apertura (stato del collegamento,
/// permessi, file su disco): [onSectionReturn] quando la sezione che li
/// contiene torna visibile dopo essere stata nascosta, come faceva la
/// ricostruzione da zero a ogni visita. I dati già mostrati restano finché
/// arrivano quelli nuovi (niente cerchio di caricamento).
mixin SectionReturn<T extends StatefulWidget> on State<T> {
  bool? _sectionActive;

  /// La sezione è visibile adesso.
  bool get sectionActive => _sectionActive ?? true;

  /// La sezione è tornata visibile. Si chiama durante la ricostruzione:
  /// basta cambiare lo stato (es. il futuro da caricare) senza `setState`.
  void onSectionReturn();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final now = SectionActive.of(context);
    final before = _sectionActive;
    _sectionActive = now;
    if (before == false && now) onSectionReturn();
  }
}
