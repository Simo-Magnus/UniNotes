import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/feedback/app_modals.dart';
import '../core/theme/app_tokens.dart';
import 'common.dart';

/// Testo da copiare (es. la richiesta per Claude o Gemini): selezionabile
/// riga per riga, con il pulsante «Copia» per prenderlo tutto.
class CopyableBlock extends StatelessWidget {
  const CopyableBlock(this.text, {super.key, this.maxHeight = 260});
  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    // card interna di vetro (Design 3), come i riquadri dentro le card
    return Container(
      decoration: BoxDecoration(
        color: t.innerCard,
        borderRadius: BorderRadius.circular(AppScale.radiusInner),
        border: Border.all(color: t.innerBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: SelectableText(
                text,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) showSnack(context, 'Testo copiato.');
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copia'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Finestra con spiegazione e richiesta copiabile.
Future<void> showPromptDialog(
  BuildContext context, {
  required String title,
  required String intro,
  required String prompt,
  IconData icon = Icons.auto_awesome_outlined,
}) => showAppDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    icon: Icon(icon),
    title: Text(title),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(intro),
            const SizedBox(height: 12),
            CopyableBlock(prompt),
          ],
        ),
      ),
    ),
    actions: [
      FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
    ],
  ),
);
