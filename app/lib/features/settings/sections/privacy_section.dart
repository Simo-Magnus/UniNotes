import 'package:flutter/material.dart';

import '../../../core/constants/build_flags.dart';
import '../../../core/services/external_launcher.dart';
import '../../../widgets/common.dart';
import '../app_info.dart';
import '../erase_all.dart';
import '../widgets/settings_card.dart';

/// Intestazione della pagina «Licenze»: cosa c'è nell'app e da dove viene.
/// Sotto, la pagina elenca le licenze di ogni libreria (una voce per
/// pacchetto, generate dai file LICENSE: non vanno riscritte a mano).
const kLicensesIntro =
    'UniNotes è rilasciata con licenza PolyForm Noncommercial 1.0.0: puoi '
    'usarla, modificarla e ridistribuirla gratuitamente citando l\'autore '
    '(Simo-Magnus) e la fonte originale (github.com/Simo-Magnus/UniNotes); '
    'non può essere venduta né usata a scopo commerciale.\n'
    'Dati dei corsi: elaborati da fonti pubbliche (MUR, Universitaly, siti e '
    'cataloghi degli atenei); ogni dato riporta la sua fonte. UniNotes '
    'non è un servizio ufficiale degli atenei.\n'
    'Caratteri: IBM Plex (SIL Open Font License 1.1).\n'
    'Trascrizione locale: whisper.cpp (MIT) con i modelli Whisper di OpenAI '
    '(MIT), scaricati a parte.\n'
    'Termini d\'uso e informativa privacy: TERMINI.md e PRIVACY.md su '
    'github.com/Simo-Magnus/UniNotes.\n'
    'Qui sotto le licenze delle librerie usate dall\'app.';

/// "Privacy e informazioni".
class PrivacySection extends StatelessWidget {
  const PrivacySection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return SettingsCard(
      title: 'Privacy e informazioni',
      icon: Icons.privacy_tip_outlined,
      children: [
        point(
          Icons.cloud_off_outlined,
          'L\'app funziona interamente sul dispositivo: la rete serve '
          'esclusivamente per scaricare il database pubblico dei corsi e i '
          'modelli Whisper, sincronizzare OneDrive o Google Drive e aprire '
          'Gemini o la tua AI di riferimento.',
        ),
        point(
          Icons.analytics_outlined,
          'Nessuna telemetria, statistica d\'uso o pubblicità è registrata.',
        ),
        point(
          Icons.key_off_outlined,
          'Gli accessi a OneDrive e Google Drive sono cifrati nel portachiavi '
          'del dispositivo e mai inclusi nei backup.',
        ),
        if (kShowDonationLink)
          point(
            Icons.volunteer_activism_outlined,
            'UniNotes è gratuita, senza pubblicità né abbonamenti: se '
            'lo desideri puoi sostenere il progetto con una donazione libera a '
            'piacere con il pulsante «Sostieni il progetto».',
          ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Versione  ',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                TextSpan(
                  text: '$kAppName $kAppVersion',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => _open(context, kProjectUrl),
              icon: const Icon(Icons.public),
              label: const Text('Sito del progetto'),
            ),
            TextButton.icon(
              onPressed: () => _open(context, kPrivacyUrl),
              icon: const Icon(Icons.policy_outlined),
              label: const Text('Informativa privacy'),
            ),
            TextButton.icon(
              onPressed: () => _open(context, kTermsUrl),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Termini d\'uso'),
            ),
            TextButton.icon(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: kAppName,
                applicationVersion: kAppVersion,
                applicationLegalese: kLicensesIntro,
              ),
              icon: const Icon(Icons.gavel_outlined),
              label: const Text('Licenze'),
            ),
            TextButton.icon(
              key: const Key('erase-all'),
              onPressed: () => eraseAllData(context),
              icon: Icon(
                Icons.delete_forever_outlined,
                color: theme.colorScheme.error,
              ),
              label: Text(
                'Elimina tutti i dati',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            TextButton.icon(
              key: const Key('uninstall-app'),
              onPressed: () => uninstallApp(context),
              icon: Icon(
                Icons.delete_sweep_outlined,
                color: theme.colorScheme.error,
              ),
              label: Text(
                'Disinstalla UniNotes',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            if (kShowDonationLink)
              TextButton.icon(
                onPressed: () => _open(context, kDonationUrl),
                icon: const Icon(Icons.favorite_outline),
                label: const Text('Sostieni il progetto'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Apre un link esterno; se non si apre lo dice (es. nessun browser).
Future<void> _open(BuildContext context, String url) async {
  final r = await ExternalLauncher.openUrl(url);
  if (context.mounted) showLaunchResult(context, r);
}
