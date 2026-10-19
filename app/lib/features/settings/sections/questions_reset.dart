import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/services/app_services.dart';
import '../../../repositories/settings_repository.dart';
import '../../../widgets/common.dart';

/// Prefisso delle impostazioni «Non chiedere più» in tutta l'app (es.
/// `dont_ask_attachment_kind`, `dont_ask_delete_recording`): si azzerano
/// tutte insieme con «Ripristina le domande».
const String kDontAskPrefix = 'dont_ask_';

/// Cancella tutte le scelte «Non chiedere più» ([kDontAskPrefix]); restituisce
/// quante erano.
Future<int> resetDontAskQuestions(SettingsRepository settings) async {
  final keys = [
    for (final k in (await settings.allSettings()).keys)
      if (k.startsWith(kDontAskPrefix)) k,
  ];
  await settings.removeKeys(keys);
  return keys.length;
}

/// «Ripristina le domande»: dopo la conferma l'app torna a chiedere tutto
/// ciò che era stato segnato «Non chiedere più».
class ResetQuestionsTile extends StatelessWidget {
  const ResetQuestionsTile({super.key});

  Future<void> _reset(BuildContext context) async {
    AppFeedback.of(context).tap();
    final ok = await confirmDialog(
      context,
      'Ripristinare le domande?',
      'L\'app tornerà a chiedere tutto ciò che hai segnato con «Non chiedere '
          'più» (per esempio il tipo dei file allegati o la conferma '
          'dell\'eliminazione di una registrazione).',
    );
    if (!ok || !context.mounted) return;
    final n = await resetDontAskQuestions(context.read<AppServices>().settings);
    if (!context.mounted) return;
    showSnack(
      context,
      n == 0
          ? 'Nessuna domanda da ripristinare.'
          : 'Domande ripristinate: l\'app chiederà di nuovo.',
    );
  }

  @override
  Widget build(BuildContext context) => ListTile(
    key: const Key('reset-questions'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.restart_alt),
    title: const Text('Ripristina le domande'),
    subtitle: const Text(
      'Torna a chiedere ciò che hai segnato «Non chiedere più»',
    ),
    onTap: () => _reset(context),
  );
}
