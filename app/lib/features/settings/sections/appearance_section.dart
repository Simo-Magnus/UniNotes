import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/display_prefs.dart';
import '../../../repositories/settings_repository.dart';
import '../widgets/settings_card.dart';
import 'questions_reset.dart';

/// "Aspetto": tema scuro (predefinito), chiaro o come il sistema;
/// contrasto, grandezza dei caratteri (con anteprima), «Riduci
/// animazioni» e «Ripristina le domande» («Non chiedere più»).
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  /// Applica e salva contrasto, caratteri e animazioni (anche dal primo
  /// passo dell'onboarding).
  static Future<void> saveDisplay(AppServices s, DisplayPrefs p) async {
    s.display.value = p;
    await s.settings.set(DisplayKeys.contrast, p.contrast.key);
    await s.settings.set(DisplayKeys.textSize, '${p.textStep}');
    await s.settings.set(DisplayKeys.reduceMotion, p.reduceMotion ? '1' : '0');
  }

  Future<void> _setDisplay(AppServices s, DisplayPrefs p) => saveDisplay(s, p);

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final theme = Theme.of(context);
    return SettingsCard(
      title: 'Aspetto',
      icon: Icons.contrast,
      children: [
        ValueListenableBuilder<ThemeMode>(
          valueListenable: s.themeMode,
          builder: (context, mode, _) => SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('Scuro'),
                icon: Icon(Icons.dark_mode_outlined),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('Chiaro'),
                icon: Icon(Icons.light_mode_outlined),
              ),
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('Sistema'),
                icon: Icon(Icons.settings_suggest_outlined),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (v) async {
              AppFeedback.of(context).toggle();
              s.themeMode.value = v.first;
              await s.settings.set(SettingKeys.themeMode, switch (v.first) {
                ThemeMode.dark => 'dark',
                ThemeMode.light => 'light',
                ThemeMode.system => 'system',
              });
            },
          ),
        ),
        ValueListenableBuilder<DisplayPrefs>(
          valueListenable: s.display,
          builder: (context, p, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Text('Contrasto', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<ContrastMode>(
                segments: const [
                  ButtonSegment(
                    value: ContrastMode.standard,
                    label: Text('Standard'),
                  ),
                  ButtonSegment(
                    value: ContrastMode.high,
                    label: Text('Alto contrasto'),
                    icon: Icon(Icons.contrast),
                  ),
                ],
                selected: {p.contrast},
                onSelectionChanged: (v) {
                  AppFeedback.of(context).toggle();
                  _setDisplay(s, p.copyWith(contrast: v.first));
                },
              ),
              const SizedBox(height: 4),
              Text(
                'Alto contrasto: testi più chiari, bordi più marcati e card '
                'meno trasparenti.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Text(
                'Grandezza dei caratteri',
                style: theme.textTheme.titleSmall,
              ),
              Slider(
                value: p.textStep.toDouble(),
                min: 0,
                max: (kTextSizeSteps.length - 1).toDouble(),
                divisions: kTextSizeSteps.length - 1,
                label: kTextSizeLabels[p.textStep],
                semanticFormatterCallback: (v) =>
                    'Caratteri: ${kTextSizeLabels[v.round()]}',
                onChanged: (v) {
                  if (v.round() == p.textStep) return;
                  AppFeedback.of(context).toggle();
                  _setDisplay(s, p.copyWith(textStep: v.round()));
                },
              ),
              TextSizePreview(label: kTextSizeLabels[p.textStep]),
              const SizedBox(height: 4),
              Text(
                'Si somma alla grandezza scelta nelle impostazioni del '
                'sistema.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Riduci animazioni'),
                subtitle: Text(
                  MediaQuery.of(context).disableAnimations && !p.reduceMotion
                      ? 'Già attivo nelle impostazioni del sistema'
                      : 'Pagine e conferme compaiono senza movimento',
                ),
                value: p.reduceMotion,
                onChanged: (v) {
                  AppFeedback.of(context).toggle();
                  _setDisplay(s, p.copyWith(reduceMotion: v));
                },
              ),
            ],
          ),
        ),
        // scelte «Non chiedere più» di tutta l'app
        const ResetQuestionsTile(),
      ],
    );
  }
}

/// Anteprima dei caratteri con la grandezza scelta.
class TextSizePreview extends StatelessWidget {
  const TextSizePreview({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    return Semantics(
      label: 'Anteprima dei caratteri: $label',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.innerCard,
          border: Border.all(color: t.innerBorder),
          borderRadius: BorderRadius.circular(AppScale.radiusInner),
        ),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Analisi matematica I', style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Limiti notevoli · 45 min di studio oggi',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
