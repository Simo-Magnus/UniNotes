import 'package:flutter/material.dart';

import '../core/theme/app_tokens.dart';

/// Riquadro flottante sopra tutte le schermate (registrazione in corso,
/// sessione Focus): fondo scuro quasi opaco (si legge anche sopra altri
/// testi), raggio 32, ombra. A sinistra la parte che si tocca e si
/// trascina (segue il dito dal primo movimento, senza soglia), a destra i
/// pulsanti. Stretto, il testo si accorcia e l'indicatore a destra sparisce:
/// i pulsanti restano sempre visibili.
class FloatingPill extends StatelessWidget {
  const FloatingPill({
    super.key,
    required this.semanticsLabel,
    required this.leading,
    required this.title,
    required this.status,
    required this.onOpen,
    required this.onDrag,
    this.trailing,
    this.actions = const [],
  });

  /// Cosa legge il lettore di schermo sulla parte che si tocca.
  final String semanticsLabel;
  final Widget leading;
  final String title;
  final String status;
  final Widget? trailing;
  final List<Widget> actions;
  final VoidCallback onOpen;
  final ValueChanged<Offset> onDrag;

  /// Fondo del riquadro: il vetro della barra di navigazione steso su una
  /// base quasi opaca (scura nel tema scuro, chiara in quello chiaro).
  static List<Color> background(BuildContext context) {
    final t = context.tokens;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? const Color(0xF20A1424) : const Color(0xF7FFFFFF);
    return [for (final c in t.navGradient) Color.alphaBlend(c, base)];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) => _pill(context, t, theme, box.maxWidth < 280),
    );
  }

  Widget _pill(
    BuildContext context,
    AppTokens t,
    ThemeData theme,
    bool narrow,
  ) {
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: background(context),
          ),
          border: Border.all(color: t.navBorder),
          // tema chiaro: l'ombra leggera degli elementi flottanti
          boxShadow: theme.brightness == Brightness.dark
              ? const [
                  BoxShadow(
                    color: Color(0x99000000),
                    offset: Offset(0, 10),
                    blurRadius: 24,
                    spreadRadius: -6,
                  ),
                ]
              : t.floatShadows,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: semanticsLabel,
                excludeSemantics: true,
                // il trascinamento usa i movimenti grezzi del puntatore: il
                // riquadro segue il dito dal primo pixel; il tocco (senza
                // spostamento) apre
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerMove: (e) => onDrag(e.delta),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onOpen,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Row(
                        children: [
                          leading,
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  // il riquadro ha un'altezza fissa: i
                                  // caratteri grandi non lo devono rompere
                                  textScaler: MediaQuery.textScalerOf(context)
                                      .clamp(maxScaleFactor: 1.3),
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: t.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textScaler: MediaQuery.textScalerOf(context)
                                      .clamp(maxScaleFactor: 1.3),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: t.textSecondary,
                                    fontFamily: 'IBMPlexMono',
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // stretto: l'indicatore lascia spazio ai pulsanti
                          if (!narrow && trailing != null) trailing!,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ...actions,
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// Pulsante rotondo del riquadro: area di tocco 48×48, etichetta per il
/// lettore di schermo.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = color ?? t.textPrimary;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: 48,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: Icon(
            icon,
            size: 26,
            color: onTap == null ? c.withValues(alpha: 0.4) : c,
          ),
        ),
      ),
    );
  }
}
