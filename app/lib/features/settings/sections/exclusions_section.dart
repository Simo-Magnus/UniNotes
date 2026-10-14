import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/catalog/path_setup.dart';
import '../../../core/services/app_services.dart';
import '../../../repositories/settings_repository.dart';
import '../../../widgets/common.dart';
import '../dialogs/exclusion_confirm_dialog.dart';
import '../logic/exclusion_cleanup.dart';
import '../widgets/settings_card.dart';

/// "Esclusioni": gruppi di corsi, lezioni ed esami (OFA, lingua, facoltativi)
/// da nascondere da Esami, Studio e Libri.
class ExclusionsSection extends StatelessWidget {
  const ExclusionsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: 'Esclusioni',
      icon: Icons.filter_alt_outlined,
      subtitle: 'Scegli cosa rimuovere dalla lista di Esami, Studio e Libri',
      children: [
        RevisionBuilder<List<String>>(
          load: (s) => s.settings.exclusionPatterns(),
          builder: (context, patterns) => _PatternList(patterns: patterns),
        ),
      ],
    );
  }
}

class _PatternList extends StatelessWidget {
  const _PatternList({required this.patterns});
  final List<String> patterns;

  Future<void> _save(BuildContext context, List<String> next) async {
    final s = context.read<AppServices>();
    await s.settings.setExclusionPatterns(next);
    s.revision.bump();
  }

  /// Interruttore di un'esclusione pronta. Attivandola si chiede conferma e si
  /// tolgono gli elementi già importati: con «Annulla» l'interruttore resta
  /// spento. Disattivandola si reimporta il piano (voti, note e libri scelti
  /// restano).
  Future<void> _toggle(BuildContext context, ExclusionPreset g, bool on) async {
    if (on) {
      final next = [
        ...patterns,
        ...g.patterns.where((x) => !patterns.contains(x)),
      ];
      if (await _hideExisting(context, next) && context.mounted) {
        await _save(context, next);
      }
      return;
    }
    await _save(context, [...patterns.where((x) => !g.patterns.contains(x))]);
    if (!context.mounted) return;
    final s = context.read<AppServices>();
    final r = await PathSetupService(s).refresh();
    s.revision.bump();
    if (context.mounted && r.imported) {
      showSnack(context, '${g.label}: di nuovo nel tuo piano.');
    }
  }

  /// Mostra cosa verrà nascosto e lo toglie; false se l'utente annulla.
  Future<bool> _hideExisting(BuildContext context, List<String> next) async {
    final s = context.read<AppServices>();
    final cleanup = ExclusionCleanup(s.database);
    final matches = await cleanup.find(next);
    if (!context.mounted) return false;
    if (matches.isEmpty) return true;
    if (!await showExclusionConfirmDialog(context, matches) ||
        !context.mounted) {
      return false;
    }
    final n = await cleanup.apply(matches);
    s.revision.bump();
    if (context.mounted) showSnack(context, 'Nascosti $n elementi.');
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in kExclusionPresets)
          SwitchListTile(
            key: Key('exclude-${g.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text('Nascondi: ${g.label}'),
            value: g.patterns.every(patterns.contains),
            onChanged: (v) => _toggle(context, g, v),
          ),
      ],
    );
  }
}
