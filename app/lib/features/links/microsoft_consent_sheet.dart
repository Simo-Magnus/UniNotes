import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show ShareParams;

import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/share_files.dart' show systemShare;
import '../cloud/microsoft_admin_consent.dart';

/// Link della scheda OneDrive (e del calendario Outlook) che riapre la
/// scheda dell'account universitario bloccato.
const kUniversityAccountHelp =
    'Perché non riesco a collegare l\'account universitario?';

/// Riga sotto «Usa un account Microsoft personale» (OneDrive).
const kPersonalAccountHint =
    'Gratuito, con 5 GB di OneDrive. I file e i blocchi OneNote dell\'account '
    'universitario non saranno visibili.';

Widget _sheet(BuildContext c, List<Widget> children) => SafeArea(
  child: ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.9),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  ),
);

/// «Il tuo ateneo deve approvare UniNotes»: l'accesso Microsoft con
/// l'account universitario è bloccato (consenso dell'amministratore). Due
/// azioni: account personale (restituisce true: il chiamante rifà
/// l'accesso con la scelta dell'account) o richiesta all'ateneo.
/// [allowPersonal] false (account già collegato) lascia solo la richiesta.
Future<bool> showUniversityBlockedSheet(
  BuildContext context, {
  required String clientId,
  bool declined = false,
  bool allowPersonal = true,
  String personalHint = kPersonalAccountHint,
}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) {
      final theme = Theme.of(c);
      final muted = theme.textTheme.bodySmall?.copyWith(
        color: c.tokens.textMuted,
      );
      return _sheet(c, [
        Text(
          'Il tuo ateneo deve approvare UniNotes',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Il tuo ateneo non permette agli studenti di collegare app esterne '
          'all\'account universitario. Non è un errore di UniNotes.',
        ),
        if (declined) ...[
          const SizedBox(height: 6),
          Text(
            'Se hai annullato tu la richiesta di autorizzazioni, chiudi e '
            'riprova con «Accedi con Microsoft».',
            style: muted,
          ),
        ],
        const SizedBox(height: 20),
        if (allowPersonal) ...[
          FilledButton.icon(
            key: const Key('consent-personal'),
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.person_outline),
            label: const Text('Usa un account Microsoft personale'),
          ),
          const SizedBox(height: 4),
          Text(personalHint, style: muted, textAlign: TextAlign.center),
          const SizedBox(height: 16),
        ],
        OutlinedButton.icon(
          key: const Key('consent-ask'),
          onPressed: () => showAdminRequestSheet(c, clientId: clientId),
          icon: const Icon(Icons.mail_outline),
          label: const Text('Chiedi all\'ateneo di approvare UniNotes'),
        ),
      ]);
    },
  );
  return r == true;
}

/// Foglio con il testo da mandare al servizio informatico dell'ateneo
/// («Copia», «Condividi») e il suggerimento su «Richiedi approvazione».
Future<void> showAdminRequestSheet(
  BuildContext context, {
  required String clientId,
}) {
  final text = MicrosoftAdminConsent.requestText(clientId: clientId);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) {
      final theme = Theme.of(c);
      final t = c.tokens;
      return _sheet(c, [
        Text(
          'Chiedi all\'ateneo di approvare UniNotes',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Manda questo testo al servizio informatico o all\'help desk del tuo '
          'ateneo.',
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(maxHeight: 280),
          decoration: BoxDecoration(
            color: t.innerCard,
            borderRadius: BorderRadius.circular(AppScale.radiusInner),
            border: Border.all(color: t.innerBorder),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text,
              key: const Key('consent-request-text'),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (c.mounted) showSnack(c, 'Testo copiato.');
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copia'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Builder(
                builder: (b) => FilledButton.icon(
                  onPressed: () => _share(b, text),
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Condividi'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 1),
              child: Icon(Icons.info_outline, size: 18, color: t.textMuted),
            ),
            Expanded(
              child: Text(
                'Se nella pagina di accesso Microsoft vedi «Richiedi '
                'approvazione», puoi usare quel pulsante: la richiesta arriva '
                'direttamente agli amministratori.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: t.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ]);
    },
  );
}

/// Menu di condivisione del sistema; se non c'è, il testo va negli appunti.
Future<void> _share(BuildContext context, String text) async {
  // su Windows la finestra «Condividi» si apre anche se share_plus risponde
  // «non disponibile» (widgets/share_files.dart)
  if (await systemShare(
    context,
    ShareParams(text: text, subject: MicrosoftAdminConsent.requestSubject),
  )) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    showSnack(
      context,
      'Condivisione non disponibile: testo copiato, incollalo nel messaggio.',
    );
  }
}
