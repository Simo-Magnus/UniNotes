import 'package:flutter/material.dart';

/// Riga «testo + pulsante» (o «icona + testo + pulsante») che non esce dallo
/// spazio: finché il testo ha abbastanza posto resta una riga sola come
/// prima; quando lo spazio è poco (finestra stretta, caratteri grandi, un
/// pulsante con la scritta lunga) il pulsante va sotto il testo, allineato a
/// destra. Quinto giro della caccia ai crash (overflow dei RenderFlex).
///
/// [actionLabel] è la scritta del pulsante, per calcolare quanto spazio
/// occupa con la scala dei caratteri attuale; [actionExtra] è la parte fissa
/// del pulsante (margini interni, icona): 48 px per un pulsante di testo di
/// Material 3.
class AdaptiveActionRow extends StatelessWidget {
  const AdaptiveActionRow({
    super.key,
    this.leading,
    required this.body,
    required this.action,
    required this.actionLabel,
    this.actionExtra = 48,
    this.gap = 8,
    this.minBody = 140,
    this.actionStyle,
  });

  /// Icona a sinistra (facoltativa), alta come il testo.
  final Widget? leading;

  /// Gap fra l'icona e il testo.
  final double gap;

  /// Il testo (di solito una Column): occupa tutto lo spazio che resta.
  final Widget body;

  /// Il pulsante.
  final Widget action;

  /// Scritta del pulsante, per misurarlo.
  final String actionLabel;
  final double actionExtra;

  /// Larghezza sotto la quale il testo non scende: oltre, il pulsante va
  /// sotto.
  final double minBody;

  /// Stile con cui misurare la scritta (predefinito: labelLarge del tema).
  final TextStyle? actionStyle;

  /// Larghezza che il pulsante occupa in una riga, con i caratteri attuali.
  static double measure(
    BuildContext context,
    String label,
    double extra,
    TextStyle? style,
  ) {
    final st = style ?? Theme.of(context).textTheme.labelLarge;
    final p = TextPainter(
      text: TextSpan(text: label, style: st),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = p.width;
    p.dispose();
    return w + extra;
  }

  @override
  Widget build(BuildContext context) {
    final btn = measure(context, actionLabel, actionExtra, actionStyle);
    return LayoutBuilder(
      builder: (context, c) {
        final lead = leading;
        final leadW = lead == null ? 0.0 : 24 + gap + 4;
        final room = c.maxWidth - leadW - btn - 8;
        final inline = !c.hasBoundedWidth || room >= minBody;
        if (inline) {
          return Row(
            children: [
              ?lead,
              if (lead != null) SizedBox(width: gap),
              Expanded(child: body),
              const SizedBox(width: 8),
              action,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (lead == null)
              body
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  lead,
                  SizedBox(width: gap),
                  Expanded(child: body),
                ],
              ),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: action),
          ],
        );
      },
    );
  }
}

/// Riga «[icona] testo ... elemento a destra» (un'etichetta, un badge, una
/// cifra) in cui l'elemento a destra non supera la frazione [maxTrailing]
/// della riga: se non c'è posto si accorcia (i badge e le etichette del
/// progetto hanno i puntini) invece di spingere il testo fuori dallo
/// schermo. Con spazio a sufficienza è identica a una Row con un Expanded.
class TrailingRow extends StatelessWidget {
  const TrailingRow({
    super.key,
    this.leading,
    this.leadingGap = 8,
    required this.body,
    this.trailing,
    this.gap = 8,
    this.maxTrailing = 0.5,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final Widget? leading;
  final double leadingGap;
  final Widget body;
  final Widget? trailing;
  final double gap;
  final double maxTrailing;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final trail = trailing;
    return LayoutBuilder(
      builder: (context, c) => Row(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          ?leading,
          if (leading != null) SizedBox(width: leadingGap),
          Expanded(child: body),
          if (trail != null) ...[
            SizedBox(width: gap),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: c.hasBoundedWidth ? c.maxWidth * maxTrailing : 400,
              ),
              child: trail,
            ),
          ],
        ],
      ),
    );
  }
}
