import 'package:flutter/material.dart';

/// Un segmento di [FitSegmentedButton].
class FitSegment<T> {
  const FitSegment({required this.value, required this.label, this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

/// [SegmentedButton] i cui segmenti non mandano mai a capo la scritta: se
/// con le icone lo spazio non basta (telefono da 320-360 dp, caratteri
/// grandi) le icone spariscono (restano le scritte, il segmento scelto si
/// vede dal colore), e se nemmeno le scritte ci stanno intere si
/// rimpiccioliscono un poco (FittedBox) invece di spezzare le parole.
///
/// Stesse regole di [SegmentedButton] per [selected] e
/// [onSelectionChanged]; [emptySelectionAllowed] e [showSelectedIcon] come
/// nell'originale.
class FitSegmentedButton<T> extends StatelessWidget {
  const FitSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.emptySelectionAllowed = false,
    this.multiSelectionEnabled = false,
    this.showSelectedIcon = true,
  });

  final List<FitSegment<T>> segments;
  final Set<T> selected;
  final void Function(Set<T>) onSelectionChanged;
  final bool emptySelectionAllowed;
  final bool multiSelectionEnabled;
  final bool showSelectedIcon;

  /// Larghezza fissa di un segmento oltre al testo: margini interni di
  /// Material 3 (12 + 12) e, con l'icona, 18 + 8.
  static const double _padding = 26;

  /// Quanto si può rimpicciolire una scritta (6%, non si nota) prima di
  /// togliere le icone.
  static const double _minFit = 0.94;
  static const double _iconExtra = 26;

  @override
  Widget build(BuildContext context) {
    final style =
        (Theme.of(context).segmentedButtonTheme.style?.textStyle
            ?.resolve(const <WidgetState>{}) ??
        Theme.of(context).textTheme.labelLarge)!;
    final base = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, c) {
        final dir = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        double textWidth(String s) {
          final p = TextPainter(
            text: TextSpan(text: s, style: base),
            textDirection: dir,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final w = p.width;
          p.dispose();
          return w;
        }

        final total = c.hasBoundedWidth ? c.maxWidth : double.infinity;
        // i segmenti di Material 3 hanno tutti la larghezza del più largo; il
        // segmento scelto mostra anche la spunta al posto dell'icona
        final check = showSelectedIcon ? _iconExtra : 0.0;
        double widest(bool icons, double fit) =>
            segments.fold<double>(0, (a, s) {
              final w =
                  textWidth(s.label) * fit +
                  _padding +
                  (icons && s.icon != null ? _iconExtra : check);
              return w > a ? w : a;
            });
        final n = segments.length;
        // 1) icone (le scritte possono ridursi del 6%); 2) senza icone (la
        // spunta della selezione resta solo se c'è posto); 3) come la 2, con
        // le scritte che si rimpiccioliscono un poco
        final withIcons = widest(true, _minFit) * n <= total;
        final showCheck =
            showSelectedIcon &&
            (withIcons || (widest(false, 1) + _iconExtra) * n <= total);
        return SegmentedButton<T>(
          showSelectedIcon: showCheck,
          emptySelectionAllowed: emptySelectionAllowed,
          multiSelectionEnabled: multiSelectionEnabled,
          segments: [
            for (final s in segments)
              ButtonSegment<T>(
                value: s.value,
                icon: withIcons && s.icon != null ? Icon(s.icon) : null,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(s.label, maxLines: 1, softWrap: false),
                ),
              ),
          ],
          selected: selected,
          onSelectionChanged: onSelectionChanged,
        );
      },
    );
  }
}
