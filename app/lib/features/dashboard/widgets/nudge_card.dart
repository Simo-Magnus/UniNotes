import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/build_flags.dart';
import '../../../core/services/app_services.dart';
import '../../../core/services/external_launcher.dart';
import '../../../core/services/nudges.dart';
import '../../../widgets/glass.dart';

/// Invito non invasivo nella Home: recensione/stella su GitHub o sostegno al
/// progetto (vedi [Nudges] per quando compare). Si chiude con un tocco.
class NudgeCard extends StatefulWidget {
  const NudgeCard({super.key});

  @override
  State<NudgeCard> createState() => _NudgeCardState();
}

class _NudgeCardState extends State<NudgeCard> {
  late final Nudges _n = Nudges(context.read<AppServices>());
  NudgeKind? _kind;

  @override
  void initState() {
    super.initState();
    _n
        .current()
        .then((k) async {
          if (k == null || !mounted) return;
          await _n.shown(k);
          if (mounted) setState(() => _kind = k);
        })
        .catchError((Object e) => debugPrint('NudgeCard: $e'));
  }

  // la card può essere già stata tolta (Home ricaricata) dopo le attese
  void _close() {
    if (mounted) setState(() => _kind = null);
  }

  @override
  Widget build(BuildContext context) {
    final k = _kind;
    if (k == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final review = Nudges.reviewTarget();
    final (icon, title, text, action, url) = switch (k) {
      NudgeKind.review => (
        Icons.star_outline,
        'Ti sta servendo UniNotes?',
        'Una recensione (o una stella su GitHub) aiuta altri studenti a '
            'trovarla. Ci vuole un minuto.',
        review.label,
        review.url,
      ),
      NudgeKind.donation => (
        Icons.volunteer_activism_outlined,
        'UniNotes è gratuita',
        'Senza pubblicità né abbonamenti. Se ti va, puoi sostenere il '
            'progetto con una donazione libera a piacere.',
        'Sostieni il progetto',
        kDonationUrl,
      ),
    };
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Chiudi',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _n.later(k);
                    _close();
                  },
                ),
              ],
            ),
            Text(text),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    // recensione: chiesta una volta sola; donazione: tra 120 giorni
                    k == NudgeKind.review
                        ? await _n.never(k)
                        : await _n.later(k);
                    await ExternalLauncher.openUrl(url);
                    _close();
                  },
                  child: Text(action),
                ),
                TextButton(
                  onPressed: () {
                    _n.never(k);
                    _close();
                  },
                  child: Text(
                    k == NudgeKind.review ? 'No, grazie' : 'Non mostrare più',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
