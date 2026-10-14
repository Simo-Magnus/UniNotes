import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/services/app_services.dart';
import '../widgets/settings_card.dart';

/// "Suoni e vibrazioni": suoni brevi e discreti (salvataggi, Focus,
/// registrazione) e vibrazioni sul telefono.
class FeedbackSection extends StatelessWidget {
  const FeedbackSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final fb = s.feedback;
    return SettingsCard(
      title: 'Suoni e vibrazioni',
      icon: Icons.graphic_eq,
      children: [
        ValueListenableBuilder<FeedbackPrefs>(
          valueListenable: fb.prefs,
          builder: (context, p, _) => Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.volume_up_outlined),
                title: const Text('Suoni'),
                subtitle: const Text(
                  'Brevi e discreti: salvataggi, argomenti completati, '
                  'sessioni Focus e registrazione.',
                ),
                value: p.sounds,
                onChanged: (v) => fb.setSounds(s.settings, v),
              ),
              if (fb.phone)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.vibration),
                  title: const Text('Vibrazioni'),
                  subtitle: const Text(
                    'Un tocco leggero su pulsanti, interruttori e '
                    'conferme.',
                  ),
                  value: p.haptics,
                  onChanged: (v) => fb.setHaptics(s.settings, v),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
