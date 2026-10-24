import 'package:flutter/material.dart';

import '../../../core/constants/build_flags.dart';
import '../../../core/feedback/feedback_service.dart';
import '../../../core/services/external_launcher.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../widgets/common.dart';
import '../../../widgets/glass.dart';
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
    '(MIT), scaricati a parte (su PC e Mac small q5_1 è incluso nell\'app, '
    'convertito in ggml e quantizzato da whisper.cpp); su PC e Mac '
    'sherpa-onnx (Apache-2.0), ONNX '
    'Runtime (MIT), Silero VAD (MIT) e, incluso nell\'app, «NVIDIA Parakeet '
    'TDT 0.6B v3» di NVIDIA (huggingface.co/nvidia/parakeet-tdt-0.6b-v3), '
    'licenza CC BY 4.0 (creativecommons.org/licenses/by/4.0), modificato: '
    'convertito in ONNX e quantizzato int8 da k2-fsa/sherpa-onnx. UniNotes '
    'non è affiliata a NVIDIA né approvata da NVIDIA; il modello è fornito '
    '«così com\'è», senza garanzie (testo completo della licenza qui sotto).\n'
    'Termini d\'uso e informativa privacy: TERMINI.md e PRIVACY.md su '
    'github.com/Simo-Magnus/UniNotes.\n'
    'Qui sotto le licenze delle librerie usate dall\'app.';

/// "Privacy e informazioni": cosa fa l'app con i dati, la versione e due
/// elenchi allineati: i collegamenti (sito, informativa, termini, licenze,
/// sostegno) e, a parte, le azioni che cancellano i dati.
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
          'la tua AI di riferimento o Gemini («Trascrivi con Gemini»).',
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
        const SizedBox(height: 4),
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
        const SizedBox(height: 8),
        // collegamenti e pagine: elenco allineato, una riga per voce
        _LinkList(
          rows: [
            _LinkRow(
              key: const Key('link-project'),
              icon: Icons.public,
              label: 'Sito del progetto',
              external: true,
              onTap: () => _open(context, kProjectUrl),
            ),
            _LinkRow(
              key: const Key('link-privacy'),
              icon: Icons.policy_outlined,
              label: 'Informativa privacy',
              external: true,
              onTap: () => _open(context, kPrivacyUrl),
            ),
            _LinkRow(
              key: const Key('link-terms'),
              icon: Icons.description_outlined,
              label: "Termini d'uso",
              external: true,
              onTap: () => _open(context, kTermsUrl),
            ),
            _LinkRow(
              key: const Key('link-licenses'),
              icon: Icons.gavel_outlined,
              label: 'Licenze',
              onTap: () => showLicensePage(
                context: context,
                applicationName: kAppName,
                applicationVersion: kAppVersion,
                applicationLegalese: kLicensesIntro,
              ),
            ),
            if (kShowDonationLink)
              _LinkRow(
                key: const Key('link-donation'),
                icon: Icons.favorite_outline,
                label: 'Sostieni il progetto',
                external: true,
                onTap: () => _open(context, kDonationUrl),
              ),
          ],
        ),
        const SizedBox(height: 12),
        // azioni che cancellano dati: a parte, in rosso (con conferma)
        _LinkList(
          rows: [
            _LinkRow(
              key: const Key('erase-all'),
              icon: Icons.delete_forever_outlined,
              label: 'Elimina tutti i dati',
              destructive: true,
              onTap: () => eraseAllData(context),
            ),
          ],
        ),
        Padding(
          key: const Key('uninstall-help'),
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'Per togliere l\'app usa il sistema (impostazioni del telefono, '
            '«App installate» di Windows, Cestino su Mac). Prima conviene '
            'usare «Elimina tutti i dati»: toglie anche le cartelle nel '
            'cloud e gli eventi nel calendario.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Riquadro interno con righe separate da una linea sottile che parte dal
/// testo (non dall'icona), come gli elenchi di sistema.
class _LinkList extends StatelessWidget {
  const _LinkList({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlassCard(
      inner: true,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: _LinkRow.textInset,
                color: t.innerBorder,
              ),
            r,
          ],
        ],
      ),
    );
  }
}

/// Riga di «Privacy e informazioni»: icona a sinistra, testo, a destra
/// l'icona «apre fuori dall'app» ([external]) o la freccia (pagina o azione
/// dell'app). Alta almeno 48 dp; colori del tema (chiaro e scuro), rossi
/// per le azioni che cancellano dati ([destructive]).
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.external = false,
    this.destructive = false,
  });

  /// Inizio del testo (e delle linee di separazione) dal bordo sinistro.
  static const double textInset = 12 + 22 + 16;

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool external;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final scheme = Theme.of(context).colorScheme;
    final fg = destructive ? scheme.error : t.textPrimary;
    return Semantics(
      button: !external,
      link: external,
      label: external ? '$label (si apre nel browser)' : label,
      excludeSemantics: true,
      child: InkWell(
        onTap: () {
          AppFeedback.of(context).tap();
          onTap();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: destructive ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: fg, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  external ? Icons.open_in_new : Icons.chevron_right,
                  size: external ? 18 : 22,
                  color: destructive
                      ? scheme.error.withValues(alpha: 0.8)
                      : t.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Apre un link esterno; se non si apre lo dice (es. nessun browser).
Future<void> _open(BuildContext context, String url) async {
  final r = await ExternalLauncher.openUrl(url);
  if (context.mounted) showLaunchResult(context, r);
}
