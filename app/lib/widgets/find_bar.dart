import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants/text_limits.dart';
import '../core/theme/app_tokens.dart';

/// Ctrl+F (⌘F su macOS) apre la ricerca, Esc la chiude; F3 e Maiusc+F3
/// passano al risultato successivo/precedente (se indicati, altrimenti
/// aprono la ricerca). [extra]: altre scorciatoie della schermata.
class FindShortcuts extends StatelessWidget {
  const FindShortcuts({
    super.key,
    required this.onFind,
    required this.onClose,
    required this.child,
    this.onNext,
    this.onPrevious,
    this.extra = const {},
  });

  final VoidCallback onFind;
  final VoidCallback onClose;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final Map<ShortcutActivator, VoidCallback> extra;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): onFind,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): onFind,
        const SingleActivator(LogicalKeyboardKey.f3): onNext ?? onFind,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            onPrevious ?? onFind,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            onNext ?? onFind,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
            onPrevious ?? onFind,
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
        ...extra,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// Barra "Trova nel testo": campo, risultato n/N (azzurro: lo calcola
/// l'app), precedente/successivo. Invio o F3 = successivo, Maiusc+Invio o
/// Maiusc+F3 = precedente, Esc = chiudi.
class FindBar extends StatelessWidget {
  const FindBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
    required this.total,
    this.current,
    this.searching = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onClose;

  /// Risultati trovati e indice (0-based) di quello attivo.
  final int total;
  final int? current;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final empty = controller.text.trim().isEmpty;
    final label = searching
        ? 'Cerco…'
        : empty
        ? ''
        : total == 0
        ? 'Nessun risultato'
        : '${(current ?? 0) + 1} di $total';
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.navGradient,
          ),
          border: Border(bottom: BorderSide(color: t.navBorder)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Icon(Icons.search, size: 20, color: t.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): onNext,
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      shift: true,
                    ): onPrevious,
                    const SingleActivator(LogicalKeyboardKey.f3): onNext,
                    const SingleActivator(LogicalKeyboardKey.f3, shift: true):
                        onPrevious,
                    const SingleActivator(LogicalKeyboardKey.escape): onClose,
                  },
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    inputFormatters: TextLimits.max(TextLimits.findQuery),
                    decoration: const InputDecoration(
                      hintText: 'Trova nel testo',
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    onChanged: onChanged,
                    onSubmitted: (_) {
                      onNext();
                      focusNode.requestFocus();
                    },
                  ),
                ),
              ),
              // con la finestra stretta o i caratteri grandi l'esito cede
              // spazio (puntini) invece di spingere i pulsanti fuori
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: total > 0 ? t.cyanSoft : t.textMuted,
                    fontWeight: total > 0 ? FontWeight.w600 : null,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Precedente (Maiusc+Invio)',
                icon: const Icon(Icons.keyboard_arrow_up),
                onPressed: total == 0 ? null : onPrevious,
              ),
              IconButton(
                tooltip: 'Successivo (Invio)',
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: total == 0 ? null : onNext,
              ),
              IconButton(
                tooltip: 'Chiudi (Esc)',
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
