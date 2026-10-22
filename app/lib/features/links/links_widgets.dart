import 'package:flutter/material.dart';

import '../../core/services/external_launcher.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../settings/widgets/async_action_button.dart' show showErrorDialog;

/// Card di Collegamenti: vetro, titolo piccolo e simbolo in filigrana a
/// destra (Design 3).
class LinksCard extends StatelessWidget {
  const LinksCard({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CardHeader(
              title: title,
              icon: icon,
              padding: const EdgeInsets.only(bottom: 4),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(fontSize: 13, color: t.textSecondary),
              ),
            ],
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Pulsante di Collegamenti. [primary] = l'unica azione arancione della
/// schermata (il prossimo passo da fare); gli altri sono secondari. Durante
/// l'operazione mostra un indicatore; gli errori vanno in un dialogo.
class LinkButton extends StatefulWidget {
  const LinkButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.errorTitle = 'Operazione non riuscita',
  });

  final String label;
  final IconData icon;
  final Future<void> Function()? onPressed;
  final bool primary;
  final String errorTitle;

  @override
  State<LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<LinkButton> {
  bool _busy = false;

  Future<void> _run() async {
    // due tocchi nello stesso fotogramma (prima che il pulsante si spenga):
    // un solo accesso, una sola sincronizzazione
    if (_busy) return;
    setState(() {
      _busy = true;
    });
    try {
      await widget.onPressed!();
    } catch (e) {
      if (mounted) await showErrorDialog(context, widget.errorTitle, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(widget.icon, size: 18);
    final onPressed = _busy || widget.onPressed == null ? null : _run;
    return widget.primary
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: icon,
            label: Text(widget.label),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: icon,
            label: Text(widget.label),
          );
  }
}

/// Link testuale che apre un sito esterno.
class LinkText extends StatelessWidget {
  const LinkText(
    this.label,
    this.url, {
    super.key,
    this.icon = Icons.open_in_new,
  });
  final String label;
  final String url;
  final IconData icon;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () async {
      final r = await ExternalLauncher.openUrl(url);
      if (context.mounted) showLaunchResult(context, r);
    },
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}

/// Stato calcolato: azzurro se a posto, testo normale se da fare, colore
/// d'errore se qualcosa non va. Il dato mancante resta «- -».
class StatusLine extends StatelessWidget {
  const StatusLine(this.text, {super.key, this.ok, this.error = false});
  final String? text;
  final bool? ok;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final color = error
        ? theme.colorScheme.error
        : (ok == true ? t.cyanSoft : t.textSecondary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 8),
          child: Icon(
            error
                ? Icons.error_outline
                : (ok == true
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked),
            size: 18,
            color: color,
          ),
        ),
        Expanded(
          child: SelectableText(
            (text == null || text!.trim().isEmpty) ? kMissing : text!,
            style: TextStyle(fontSize: 13, color: color),
          ),
        ),
      ],
    );
  }
}

/// Passi numerati di una configurazione guidata.
class StepList extends StatelessWidget {
  const StepList(this.steps, {super.key});
  final List<Widget> steps;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(right: 10, top: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: t.innerBorder),
                    color: t.innerCard,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: t.textSecondary,
                    ),
                  ),
                ),
                Expanded(child: steps[i]),
              ],
            ),
          ),
      ],
    );
  }
}

/// Testo di un passo, con eventuali pulsanti sotto.
class StepText extends StatelessWidget {
  const StepText(this.text, {super.key, this.actions = const []});
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text, style: const TextStyle(fontSize: 13)),
      if (actions.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    ],
  );
}

/// Opzioni avanzate, chiuse all'inizio.
class AdvancedSection extends StatelessWidget {
  const AdvancedSection({
    super.key,
    required this.children,
    this.title = 'Avanzate',
  });
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// Nota in piccolo (limiti, privacy).
class NoteText extends StatelessWidget {
  const NoteText(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 1),
              child: Icon(icon, size: 16, color: t.textMuted),
            ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
